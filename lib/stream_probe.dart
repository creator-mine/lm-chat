import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'app_version.dart';

/// Records metadata about a streamed chat response for diagnostics.
///
/// LM Studio decides whether model text reaches the app while it is written or
/// only at the end. The probe captures event types, timestamps, sizes and a
/// hash of tool arguments — never prompts, paths, commands or file contents —
/// so a dump can be shared without leaking the conversation.
class StreamProbe extends ChangeNotifier {
  StreamProbe._({
    DateTime Function()? clock,
    this.maxRecords = defaultMaxRecords,
    this.maxDuration = defaultMaxDuration,
  }) : _now = clock ?? DateTime.now;

  @visibleForTesting
  factory StreamProbe.forTest(
    DateTime Function() clock, {
    int maxRecords = defaultMaxRecords,
    Duration maxDuration = defaultMaxDuration,
  }) => StreamProbe._(
    clock: clock,
    maxRecords: maxRecords,
    maxDuration: maxDuration,
  );

  static const int defaultMaxRecords = 20000;
  static const Duration defaultMaxDuration = Duration(minutes: 15);

  static final StreamProbe instance = StreamProbe._();

  final DateTime Function() _now;
  final int maxRecords;
  final Duration maxDuration;

  bool _enabled = false;
  bool _active = false;
  bool _stopped = false;
  bool _truncated = false;
  DateTime? _startedAt;
  DateTime? _lastNotify;
  int _lastAtMs = 0;
  int _maxGapMs = 0;
  int _lastNetMs = 0;
  int _netPending = 0;
  int _totalBytes = 0;
  int _requestBytes = 0;
  int _messages = 0;
  int _sseCount = 0;
  String _stream = '';
  String _model = '';
  String _integrationId = '';
  Duration _idleTimeout = Duration.zero;
  String? _errorType;
  final List<Map<String, Object?>> _records = [];
  final Map<String, int> _typeCounts = {};

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    if (!value) _active = false;
    notifyListeners();
  }

  /// True while a capture is running, so the network layer can count bytes.
  bool get recording => _active && !_stopped;

  bool get hasCapture => _startedAt != null;

  bool get truncated => _truncated;

  int get maxGapMs => _maxGapMs;

  int get totalBytes => _totalBytes;

  int get requestBytes => _requestBytes;

  int get messageCount => _messages;

  int get sseCount => _sseCount;

  String get stream => _stream;

  String get model => _model;

  String get integrationId => _integrationId;

  String? get errorType => _errorType;

  int get durationMs {
    final start = _startedAt;
    if (start == null) return 0;
    final value = _now().difference(start).inMilliseconds;
    return value < 0 ? 0 : value;
  }

  Map<String, int> get typeCounts => Map.unmodifiable(_typeCounts);

  /// Starts a new capture. A previous one is replaced, so save it first.
  void begin({
    required String stream,
    required String model,
    required String integrationId,
    required int messages,
    required int requestBytes,
    required Duration idleTimeout,
  }) {
    _active = _enabled;
    if (!_active) return;
    _startedAt = _now();
    _lastAtMs = 0;
    _maxGapMs = 0;
    _lastNetMs = 0;
    _netPending = 0;
    _totalBytes = 0;
    _requestBytes = requestBytes;
    _messages = messages;
    _sseCount = 0;
    _stream = stream;
    _model = model;
    _integrationId = integrationId;
    _idleTimeout = idleTimeout;
    _errorType = null;
    _truncated = false;
    _stopped = false;
    _records.clear();
    _typeCounts.clear();
    _add({
      'type': 'begin',
      'at': _startedAt?.millisecondsSinceEpoch,
      'stream': stream,
      'model': model,
      if (integrationId.isNotEmpty) 'integration': integrationId,
      'messages': messages,
      'request_bytes': requestBytes,
      'idle_ms': idleTimeout.inMilliseconds,
      'app': appVersionLabel,
    }, countAsEvent: false);
    notifyListeners();
  }

  /// Records one decoded SSE event. Only metadata is kept.
  void event(Map<String, dynamic> json, {required int payloadBytes}) {
    if (!recording) return;
    final type = json['type']?.toString() ?? '';
    final record = <String, Object?>{'type': type, 'len': payloadBytes};
    switch (type) {
      case 'message.delta':
      case 'reasoning.delta':
        record['text_len'] = _textLength(json['content']);
        break;
      case 'tool_call.start':
      case 'tool_call.name':
        final tool = _toolName(json);
        if (tool.isNotEmpty) record['tool'] = tool;
        break;
      case 'tool_call.arguments':
        final tool = _toolName(json);
        if (tool.isNotEmpty) record['tool'] = tool;
        _addArguments(record, json['arguments']);
        break;
      case 'tool_call.success':
        final tool = _toolName(json);
        if (tool.isNotEmpty) record['tool'] = tool;
        _addArguments(record, json['arguments']);
        record['output_len'] = _textLength(json['output']);
        break;
      case 'tool_call.failure':
        final tool = _toolName(json);
        if (tool.isNotEmpty) record['tool'] = tool;
        final metadata = json['metadata'];
        final reason =
            json['reason'] ?? (metadata is Map ? metadata['reason'] : null);
        record['reason_len'] = _textLength(reason);
        break;
      case 'prompt_processing.progress':
        final progress = json['progress'] ?? json['percent'];
        if (progress is num) record['progress'] = progress;
        break;
      case 'chat.end':
        final result = json['result'];
        final stats = result is Map ? result['stats'] : null;
        if (stats is Map) {
          final input = stats['input_tokens'];
          final output = stats['total_output_tokens'];
          if (input is num) record['input_tokens'] = input;
          if (output is num) record['output_tokens'] = output;
        }
        break;
    }
    _add(record);
  }

  /// Counts a received network chunk. Markers are written at most once a
  /// second, which is enough to show whether the server was silent.
  void bytes(int length) {
    if (!recording || length <= 0) return;
    _totalBytes += length;
    final t = _now().difference(_startedAt!).inMilliseconds;
    _netPending += length;
    if (t - _lastNetMs < 1000) return;
    _lastNetMs = t;
    _add({'type': 'net', 'bytes': _netPending});
    _netPending = 0;
  }

  /// Closes the capture. Repeated calls are ignored.
  void finish({String? errorType, int? messageLength}) {
    if (!_active) return;
    _errorType = errorType;
    _add({
      'type': 'end',
      'result': errorType == null ? 'completed' : 'error',
      'error': ?errorType,
      'message_len': ?messageLength,
      'bytes': _totalBytes,
      'truncated': _truncated,
    }, countAsEvent: false);
    _active = false;
    notifyListeners();
  }

  void clear() {
    _records.clear();
    _typeCounts.clear();
    _sseCount = 0;
    _startedAt = null;
    _lastNotify = null;
    _lastAtMs = 0;
    _maxGapMs = 0;
    _lastNetMs = 0;
    _netPending = 0;
    _totalBytes = 0;
    _requestBytes = 0;
    _messages = 0;
    _stream = '';
    _model = '';
    _integrationId = '';
    _idleTimeout = Duration.zero;
    _errorType = null;
    _truncated = false;
    _stopped = false;
    _active = false;
    notifyListeners();
  }

  /// JSON Lines: one metadata record per line.
  String toJsonl() {
    if (_records.isEmpty) return '';
    final buffer = StringBuffer();
    for (final record in _records) {
      buffer.writeln(jsonEncode(record));
    }
    return buffer.toString();
  }

  String get suggestedFileName {
    final at = _startedAt ?? _now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'lm-chat-stream-${at.year}${two(at.month)}${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}${two(at.second)}.jsonl';
  }

  Duration get idleTimeout => _idleTimeout;

  void _add(Map<String, Object?> record, {bool countAsEvent = true}) {
    if (!_active || _stopped) return;
    final t = _now().difference(_startedAt!).inMilliseconds;
    if (t > maxDuration.inMilliseconds || _records.length >= maxRecords) {
      _stopped = true;
      _truncated = true;
      notifyListeners();
      return;
    }
    if (t > _lastAtMs) {
      final gap = t - _lastAtMs;
      if (gap > _maxGapMs) _maxGapMs = gap;
      _lastAtMs = t;
    }
    record['t'] = t;
    _records.add(record);
    final type = record['type']?.toString() ?? '';
    if (countAsEvent && type != 'net' && type != 'begin' && type != 'end') {
      _sseCount++;
      _typeCounts[type] = (_typeCounts[type] ?? 0) + 1;
    }
    _notifyThrottled();
  }

  void _notifyThrottled() {
    final now = _now();
    final last = _lastNotify;
    if (last != null && now.difference(last).inMilliseconds < 500) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _addArguments(Map<String, Object?> record, Object? value) {
    if (value == null) {
      record['args_len'] = 0;
      return;
    }
    final String encoded;
    try {
      encoded = value is String ? value : jsonEncode(value);
    } catch (_) {
      record['args_len'] = value.toString().length;
      record['args_kind'] = 'raw';
      return;
    }
    record['args_len'] = encoded.length;
    record['args_kind'] = value is Map
        ? 'object'
        : value is String
        ? 'string'
        : value is List
        ? 'list'
        : 'other';
    if (value is Map) record['args_keys'] = value.length;
    record['args_sha'] = sha256
        .convert(utf8.encode(encoded))
        .toString()
        .substring(0, 8);
  }

  String _toolName(Map<String, dynamic> json) {
    final raw = json['tool'] ?? json['tool_name'] ?? '';
    final text = raw.toString();
    return text.length <= 64 ? text : text.substring(0, 64);
  }

  int _textLength(Object? value) {
    if (value == null) return 0;
    if (value is String) return value.length;
    try {
      return jsonEncode(value).length;
    } catch (_) {
      return value.toString().length;
    }
  }
}

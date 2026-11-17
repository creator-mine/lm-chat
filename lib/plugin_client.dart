import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class PluginException implements Exception {
  PluginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// REST client for the `lm-computer` diagnostic log.
///
/// The plugin runs next to LM Studio and uses a separate bearer token. Only
/// status and metadata logs are requested here; no tool is executed.
class PluginClient {
  PluginClient(this.server);

  final ServerConfig server;

  static const Duration _timeout = Duration(seconds: 10);

  Map<String, String> get _headers {
    final token = server.pluginToken.trim();
    return {
      'Content-Type': 'application/json',
      ...server.relayHeaders,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  void _ensureConfigured() {
    if (server.effectivePluginUrl.isEmpty) {
      throw PluginException(
        'Адрес плагина не задан. Укажите его в настройках сервера.',
      );
    }
    final security = server.pluginSecurityError;
    if (security != null) throw PluginException(security);
    if (server.pluginToken.trim().isEmpty) {
      throw PluginException('Укажите токен плагина lm-computer.');
    }
  }

  Future<PluginStatus> status() async {
    _ensureConfigured();
    final response = await http
        .get(server.pluginUri('api/status'), headers: _headers)
        .timeout(_timeout);
    return PluginStatus.fromJson(_decode(response));
  }

  Future<PluginLogPage> logs({int limit = 200}) async {
    _ensureConfigured();
    final safe = limit.clamp(1, 1000);
    final response = await http
        .get(server.pluginUri('api/logs?limit=$safe'), headers: _headers)
        .timeout(_timeout);
    return PluginLogPage.fromJson(_decode(response));
  }

  Future<void> setLogLevel(String level) async {
    _ensureConfigured();
    final response = await http
        .post(
          server.pluginUri('api/logs/level'),
          headers: _headers,
          body: jsonEncode({'level': level}),
        )
        .timeout(_timeout);
    _decode(response);
  }

  Future<void> clearLogs() async {
    _ensureConfigured();
    final response = await http
        .delete(server.pluginUri('api/logs'), headers: _headers)
        .timeout(_timeout);
    _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> decoded = const {};
    final body = response.body.trim();
    if (body.isNotEmpty) {
      try {
        final value = jsonDecode(body);
        if (value is Map<String, dynamic>) decoded = value;
      } catch (_) {
        // A proxy or an old plugin may answer with plain text.
      }
    }
    if (response.statusCode == 200 && decoded['ok'] != false) return decoded;
    if (response.statusCode == 401) {
      throw PluginException('Неверный токен плагина (401).');
    }
    if (response.statusCode == 404) {
      throw PluginException(
        'Плагин не поддерживает логи. Обновите lm-computer до 0.1.6.',
      );
    }
    final error = decoded['error']?.toString();
    throw PluginException(
      error == null || error.isEmpty
          ? 'Плагин ответил ошибкой ${response.statusCode}.'
          : error,
    );
  }
}

class PluginStatus {
  const PluginStatus({
    required this.version,
    required this.logLevel,
    required this.logEntries,
    required this.logFile,
  });

  final String version;
  final String logLevel;
  final int logEntries;
  final String logFile;

  factory PluginStatus.fromJson(Map<String, dynamic> json) => PluginStatus(
    version: json['version']?.toString() ?? '',
    logLevel: json['logLevel']?.toString() ?? 'info',
    logEntries: (json['logEntries'] as num?)?.toInt() ?? 0,
    logFile: json['logFile']?.toString() ?? '',
  );
}

class PluginLogEntry {
  const PluginLogEntry({
    required this.seq,
    required this.time,
    required this.level,
    required this.event,
    required this.fields,
    required this.raw,
  });

  final int seq;
  final DateTime? time;
  final String level;
  final String event;
  final Map<String, dynamic> fields;
  final Map<String, dynamic> raw;

  factory PluginLogEntry.fromJson(Map<String, dynamic> json) {
    final ts = (json['ts'] as num?)?.toInt() ?? 0;
    return PluginLogEntry(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      time: ts > 0 ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
      level: json['level']?.toString() ?? 'info',
      event: json['event']?.toString() ?? '',
      fields: Map<String, dynamic>.from(json)
        ..remove('seq')
        ..remove('ts')
        ..remove('level')
        ..remove('event'),
      raw: Map<String, dynamic>.from(json),
    );
  }

  /// The useful numeric/short fields in a stable order.
  String get summary {
    const keys = [
      'tool',
      'origin',
      'method',
      'path',
      'status',
      'decision',
      'ok',
      'ms',
      'arg_keys',
      'args_len',
      'result_len',
      'error_type',
      'error_len',
      'listener',
      'port',
      'bytes',
      'keys',
      'index',
      'seconds',
    ];
    final parts = <String>[];
    for (final key in keys) {
      final value = fields[key];
      if (value == null) continue;
      final text = value is String && value.length > 64
          ? '${value.substring(0, 64)}…'
          : '$value';
      parts.add('$key=$text');
    }
    return parts.join(' ');
  }
}

class PluginLogPage {
  const PluginLogPage({
    required this.level,
    required this.file,
    required this.entries,
  });

  final String level;
  final String file;
  final List<PluginLogEntry> entries;

  factory PluginLogPage.fromJson(Map<String, dynamic> json) {
    final raw = json['entries'];
    final entries = <PluginLogEntry>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          entries.add(PluginLogEntry.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return PluginLogPage(
      level: json['level']?.toString() ?? 'info',
      file: json['file']?.toString() ?? '',
      entries: entries,
    );
  }

  String toJsonl() {
    if (entries.isEmpty) return '';
    return '${entries.map((entry) => jsonEncode(entry.raw)).join('\n')}\n';
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/stream_probe.dart';

void main() {
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 11, 16, 12);
  });

  StreamProbe probe({int maxRecords = StreamProbe.defaultMaxRecords}) =>
      StreamProbe.forTest(() => now, maxRecords: maxRecords);

  test('records event metadata without prompts or file contents', () {
    final stream = probe()..enabled = true;
    stream.begin(
      stream: 'mcp',
      model: 'qwen3',
      integrationId: 'mcp/lm-computer',
      messages: 4,
      requestBytes: 1200,
      idleTimeout: const Duration(minutes: 10),
    );

    now = now.add(const Duration(seconds: 1));
    stream.event({
      'type': 'tool_call.arguments',
      'tool': 'fs_write',
      'arguments': {
        'path': 'sites/secret/index.html',
        'content': '<html>TOP SECRET</html>',
      },
    }, payloadBytes: 500);

    now = now.add(const Duration(seconds: 30));
    stream.event({
      'type': 'tool_call.success',
      'tool': 'fs_write',
      'arguments': {
        'path': 'sites/secret/index.html',
        'content': '<html>TOP SECRET</html>',
      },
      'output': '[{"type":"text","text":"created"}]',
    }, payloadBytes: 700);
    stream.finish();

    final dump = stream.toJsonl();
    expect(dump, contains('"type":"begin"'));
    expect(dump, contains('"type":"tool_call.arguments"'));
    expect(dump, contains('"type":"tool_call.success"'));
    expect(dump, contains('"type":"end"'));
    expect(dump, contains('"args_len"'));
    expect(dump, contains('"args_keys":2'));
    expect(dump, contains('"output_len"'));
    expect(dump, isNot(contains('TOP SECRET')));
    expect(dump, isNot(contains('sites/secret')));
    expect(dump, isNot(contains('chat.start')));
    expect(stream.sseCount, 2);
    expect(stream.maxGapMs, 30000);
    expect(stream.durationMs, 31000);
    expect(stream.toJsonl(), endsWith('\n'));
  });

  test('counts network activity without filling the event summary', () {
    final stream = probe()..enabled = true;
    stream.begin(
      stream: 'mcp',
      model: 'qwen3',
      integrationId: 'mcp/lm-computer',
      messages: 1,
      requestBytes: 10,
      idleTimeout: const Duration(minutes: 10),
    );

    now = now.add(const Duration(milliseconds: 1500));
    stream.bytes(15);

    final dump = stream.toJsonl();
    expect(dump, contains('"type":"net"'));
    expect(dump, contains('"bytes":15'));
    expect(stream.typeCounts.containsKey('net'), isFalse);
    expect(stream.totalBytes, 15);
  });

  test('stops at the configured record limit', () {
    final stream = probe(maxRecords: 3)..enabled = true;
    stream.begin(
      stream: 'mcp',
      model: 'qwen3',
      integrationId: 'mcp/lm-computer',
      messages: 1,
      requestBytes: 10,
      idleTimeout: const Duration(minutes: 10),
    );

    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(milliseconds: 100));
      stream.event({
        'type': 'message.delta',
        'content': 'ok',
      }, payloadBytes: 20);
    }

    expect(stream.truncated, isTrue);
    expect(stream.sseCount, 2);
    expect(
      stream.toJsonl().split('\n').where((line) => line.isNotEmpty),
      hasLength(3),
    );
  });

  test('does nothing while recording is disabled', () {
    final stream = probe();
    stream.begin(
      stream: 'mcp',
      model: 'qwen3',
      integrationId: 'mcp/lm-computer',
      messages: 1,
      requestBytes: 10,
      idleTimeout: const Duration(minutes: 10),
    );
    stream.event({'type': 'message.delta', 'content': 'ok'}, payloadBytes: 20);
    stream.finish();

    expect(stream.hasCapture, isFalse);
    expect(stream.toJsonl(), isEmpty);
  });

  test('records the error category and suggests a safe file name', () {
    final stream = probe()..enabled = true;
    stream.begin(
      stream: 'mcp',
      model: 'qwen3',
      integrationId: 'mcp/lm-computer',
      messages: 1,
      requestBytes: 10,
      idleTimeout: const Duration(minutes: 10),
    );
    stream.finish(errorType: 'TimeoutException', messageLength: 42);

    final dump = stream.toJsonl();
    expect(dump, contains('"result":"error"'));
    expect(dump, contains('"error":"TimeoutException"'));
    expect(dump, contains('"message_len":42'));
    expect(stream.errorType, 'TimeoutException');
    expect(stream.suggestedFileName, 'lm-chat-stream-20261116-120000.jsonl');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/plugin_client.dart';
import 'package:lm_chat/secret_store.dart';

void main() {
  late HttpServer server;
  late ServerConfig config;
  String? lastLevel;
  bool cleared = false;
  bool requireToken = true;
  bool oldPlugin = false;

  setUp(() async {
    lastLevel = null;
    cleared = false;
    oldPlugin = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = ServerConfig(
      id: 's1',
      name: 'LM Studio',
      baseUrl: 'http://127.0.0.1:1234',
      pluginUrl: 'http://127.0.0.1:${server.port}',
      pluginToken: 'plugin-token',
    );

    server.listen((request) async {
      final auth = request.headers.value('Authorization');
      if (requireToken && auth != 'Bearer plugin-token') {
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":false,"error":"Unauthorized"}');
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      if (oldPlugin && path == '/api/logs') {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":false,"error":"Not found"}');
        await request.response.close();
        return;
      }
      if (path == '/api/status') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': true,
            'version': '0.1.6',
            'logLevel': 'debug',
            'logEntries': 2,
            'logFile': '/home/user/.config/lm-computer/logs/lm-computer.jsonl',
          }),
        );
        await request.response.close();
        return;
      }
      if (path == '/api/logs' && request.method == 'GET') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': true,
            'level': 'debug',
            'file': '/tmp/log.jsonl',
            'entries': [
              {
                'seq': 12,
                'ts': 1763300000000,
                'level': 'debug',
                'event': 'tool.call',
                'tool': 'fs_write',
                'origin': 'mcp',
                'ok': true,
                'ms': 14,
                'args_len': 1520,
                'result_len': 38,
              },
              {
                'seq': 11,
                'ts': 1763299999000,
                'level': 'info',
                'event': 'listener.start',
                'listener': 'api',
                'port': 1236,
              },
            ],
          }),
        );
        await request.response.close();
        return;
      }
      if (path == '/api/logs' && request.method == 'DELETE') {
        cleared = true;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
        await request.response.close();
        return;
      }
      if (path == '/api/logs/level' && request.method == 'POST') {
        final body = await utf8.decodeStream(request);
        lastLevel = (jsonDecode(body) as Map<String, dynamic>)['level']
            ?.toString();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true, 'level': lastLevel}));
        await request.response.close();
        return;
      }
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"ok":false,"error":"Not found"}');
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('reads the plugin status and log entries', () async {
    final client = PluginClient(config);
    final status = await client.status();
    expect(status.version, '0.1.6');
    expect(status.logLevel, 'debug');
    expect(status.logEntries, 2);
    expect(status.logFile, contains('lm-computer.jsonl'));

    final page = await client.logs();
    expect(page.level, 'debug');
    expect(page.entries, hasLength(2));
    final first = page.entries.first;
    expect(first.seq, 12);
    expect(first.event, 'tool.call');
    expect(first.fields['tool'], 'fs_write');
    expect(first.summary, contains('tool=fs_write'));
    expect(first.summary, contains('ms=14'));
    expect(first.summary, contains('args_len=1520'));
    expect(first.time?.millisecondsSinceEpoch, 1763300000000);

    final dump = page.toJsonl();
    expect(dump, contains('"event":"tool.call"'));
    expect(dump, isNot(contains('secret content')));
  });

  test('toggles the level and clears the log', () async {
    final client = PluginClient(config);
    await client.setLogLevel('info');
    expect(lastLevel, 'info');
    await client.clearLogs();
    expect(cleared, isTrue);
  });

  test('explains an invalid token and an old plugin', () async {
    requireToken = true;
    final wrong = PluginClient(
      ServerConfig(
        id: 's1',
        name: 'LM Studio',
        baseUrl: config.baseUrl,
        pluginUrl: config.pluginUrl,
        pluginToken: 'wrong',
      ),
    );
    await expectLater(
      wrong.status(),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('401'),
        ),
      ),
    );

    final missing = PluginClient(
      ServerConfig(
        id: 's1',
        name: 'LM Studio',
        baseUrl: config.baseUrl,
        pluginUrl: config.pluginUrl,
      ),
    );
    await expectLater(
      missing.logs(),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('токен'),
        ),
      ),
    );

    final old = PluginClient(
      ServerConfig(
        id: 's1',
        name: 'LM Studio',
        baseUrl: config.baseUrl,
        pluginUrl: config.pluginUrl,
        pluginToken: 'plugin-token',
      ),
    );
    oldPlugin = true;
    await expectLater(
      old.logs(),
      throwsA(
        isA<PluginException>().having(
          (error) => error.message,
          'message',
          contains('0.1.6'),
        ),
      ),
    );
  });

  test('derives the plugin address from a private LM Studio host', () {
    final derived = ServerConfig(
      id: 's1',
      name: 'LM Studio',
      baseUrl: 'http://192.168.0.183:1234',
    );
    expect(derived.effectivePluginUrl, 'http://192.168.0.183:1236');
    expect(derived.hasPlugin, isTrue);

    final publicHost = ServerConfig(
      id: 's2',
      name: 'Cloud',
      baseUrl: 'https://studio.example.com',
    );
    expect(publicHost.effectivePluginUrl, isEmpty);
    expect(publicHost.hasPlugin, isFalse);

    final manual = ServerConfig(
      id: 's3',
      name: 'Custom',
      baseUrl: 'http://192.168.0.183:1234',
      pluginUrl: 'http://192.168.0.183:2236',
    );
    expect(manual.effectivePluginUrl, 'http://192.168.0.183:2236');
  });

  test('keeps the plugin token out of normal JSON', () {
    final json = config.toJson();
    expect(json['pluginUrl'], config.pluginUrl);
    expect(json.containsKey('pluginToken'), isFalse);

    final full = config.toJson(includeSecrets: true);
    expect(full['pluginToken'], 'plugin-token');

    final restored = ServerConfig.fromJson(full);
    expect(restored.pluginUrl, config.pluginUrl);
    expect(restored.pluginToken, 'plugin-token');
  });

  test('the bridge falls back to the plugin token', () {
    final server = ServerConfig(
      id: 's1',
      name: 'LM Studio',
      baseUrl: 'http://192.168.0.183:1234',
      pluginToken: 'plugin-token',
    );
    expect(server.effectiveBridgeToken, 'plugin-token');

    server.bridgeToken = 'bridge-token';
    expect(server.effectiveBridgeToken, 'plugin-token');

    server.pluginToken = '';
    expect(server.effectiveBridgeToken, 'bridge-token');
  });

  test('round-trips the plugin token through the secret store', () async {
    final store = MemorySecretStore();
    await store.write(
      's1',
      const ServerSecrets(
        apiKey: 'key',
        bridgeToken: 'bridge',
        pluginToken: 'plugin',
      ),
    );
    final read = await store.read('s1');
    expect(read.apiKey, 'key');
    expect(read.bridgeToken, 'bridge');
    expect(read.pluginToken, 'plugin');
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/api.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/plugin_client.dart';

void main() {
  ServerConfig relayServer({
    String relayUrl = 'https://lm.example.com/',
    String device = 'home-pc',
    String relayToken = 'relay-token-0123456789',
    String pluginToken = 'plugin-token-0123456789',
  }) => ServerConfig(
    id: 'relay',
    name: 'Relay',
    baseUrl: 'http://192.168.1.10:1234',
    pluginToken: pluginToken,
    relayUrl: relayUrl,
    relayDevice: device,
    relayToken: relayToken,
  );

  test('relay base replaces the local API, plugin and bridge addresses', () {
    final server = relayServer();

    expect(server.hasRelay, isTrue);
    expect(server.normalizedBase, 'https://lm.example.com/d/home-pc');
    expect(server.effectivePluginUrl, 'https://lm.example.com/d/home-pc');
    expect(server.normalizedBridge, 'https://lm.example.com/d/home-pc');
    expect(server.hasBridge, isTrue);
    expect(server.hasPlugin, isTrue);
    expect(
      server.apiV1('models').toString(),
      'https://lm.example.com/d/home-pc/api/v1/models',
    );
    expect(
      server.bridgeUri('health').toString(),
      'https://lm.example.com/d/home-pc/health',
    );
    expect(
      server.pluginUri('api/status').toString(),
      'https://lm.example.com/d/home-pc/api/status',
    );
    expect(server.relayHeaders['X-Relay-Token'], 'relay-token-0123456789');
  });

  test('relay token is not borrowed from the plugin token', () {
    final server = relayServer(relayToken: '');
    expect(server.effectiveRelayToken, isEmpty);
    expect(server.relayHeaders.containsKey('X-Relay-Token'), isFalse);
  });

  test('a device id is encoded in the relay path', () {
    final server = relayServer(device: 'home pc');
    expect(server.normalizedBase, 'https://lm.example.com/d/home%20pc');
  });

  test('public HTTP relay is rejected, HTTPS is accepted', () {
    expect(
      relayServer(relayUrl: 'http://lm.example.com').securityError,
      isNotNull,
    );
    expect(
      relayServer(relayUrl: 'https://lm.example.com').securityError,
      isNull,
    );
    expect(
      relayServer(relayUrl: 'http://192.168.1.5:8787').securityError,
      isNotNull,
    );
    expect(
      relayServer(relayUrl: 'http://127.0.0.1:8787').securityError,
      isNull,
    );
  });

  test('relay token is persisted only with includeSecrets', () {
    final server = relayServer();
    final plain = server.toJson();
    expect(plain['relayUrl'], 'https://lm.example.com/');
    expect(plain['relayDevice'], 'home-pc');
    expect(plain.containsKey('relayToken'), isFalse);

    final full = server.toJson(includeSecrets: true);
    expect(full['relayToken'], 'relay-token-0123456789');

    final restored = ServerConfig.fromJson(full);
    expect(restored.relayUrl, server.relayUrl);
    expect(restored.relayDevice, server.relayDevice);
    expect(restored.relayToken, server.relayToken);
    expect(restored.normalizedBase, server.normalizedBase);
  });

  test('relay can replace a missing local address', () {
    final server = ServerConfig(
      id: 'relay-only',
      name: 'Relay only',
      baseUrl: '',
      relayUrl: 'https://lm.example.com',
      relayDevice: 'home-pc',
      pluginToken: 'shared-token-0123456789',
    );
    expect(server.isValid, isTrue);
    expect(server.normalizedBase, 'https://lm.example.com/d/home-pc');
    expect(server.baseSecurityError, isNull);
  });

  test('API and plugin requests carry the relay token', () async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => httpServer.close(force: true));

    final paths = <String>[];
    final relayHeaders = <String?>[];
    String? pluginAuth;

    httpServer.listen((request) async {
      paths.add(request.uri.path);
      relayHeaders.add(request.headers.value('X-Relay-Token'));
      if (request.uri.path == '/d/dev/api/status') {
        pluginAuth = request.headers.value('Authorization');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': true,
            'version': '0.1.6',
            'logLevel': 'info',
            'logEntries': 1,
            'logFile': '/tmp/log.jsonl',
          }),
        );
      } else if (request.uri.path == '/d/dev/api/v1/models') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'models': <Object>[]}));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });

    final config = ServerConfig(
      id: 'relay-http',
      name: 'Relay',
      baseUrl: '',
      relayUrl: 'http://127.0.0.1:${httpServer.port}',
      relayDevice: 'dev',
      relayToken: 'relay-secret-0123456789',
      pluginToken: 'plugin-secret-0123456789',
    );

    await LmClient().fetchModelsInfo(config);
    await PluginClient(config).status();

    expect(paths, containsAll(['/d/dev/api/v1/models', '/d/dev/api/status']));
    expect(relayHeaders, everyElement('relay-secret-0123456789'));
    expect(pluginAuth, 'Bearer plugin-secret-0123456789');
  });
}

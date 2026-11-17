import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/relay_client.dart';

void main() {
  late HttpServer server;
  late ServerConfig config;
  var online = true;

  setUp(() async {
    online = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    config = ServerConfig(
      id: 'relay',
      name: 'Relay',
      baseUrl: '',
      relayUrl: 'http://127.0.0.1:${server.port}',
      relayDevice: 'dev',
      relayToken: 'relay-token-0123456789',
      pluginToken: 'plugin-token-0123456789',
    );

    server.listen((request) async {
      if (request.uri.path != '/d/dev/_relay/status') {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":false,"error":"not found"}');
        await request.response.close();
        return;
      }
      if (request.headers.value('x-relay-token') != 'relay-token-0123456789') {
        request.response.statusCode = 401;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":false,"error":"unauthorized"}');
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'ok': true,
          'online': online,
          'streams': online ? 2 : 0,
          'version': '0.2.0',
          'uptime_ms': 123456,
        }),
      );
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('reports the online agent and relay version', () async {
    final status = await RelayClient(config).status();
    expect(status.online, isTrue);
    expect(status.streams, 2);
    expect(status.version, '0.2.0');
    expect(status.uptimeMs, 123456);
  });

  test('reports an offline agent without an error', () async {
    online = false;
    final status = await RelayClient(config).status();
    expect(status.online, isFalse);
    expect(status.streams, 0);
  });

  test('a wrong relay token is explained', () async {
    final wrong = config.clone()..relayToken = 'wrong-token-0123456789';
    await expectLater(
      RelayClient(wrong).status(),
      throwsA(
        isA<RelayException>().having(
          (error) => error.message,
          'message',
          contains('токен'),
        ),
      ),
    );
  });

  test('unknown device is reported', () async {
    final wrong = config.clone()..relayDevice = 'other';
    await expectLater(
      RelayClient(wrong).status(),
      throwsA(
        isA<RelayException>().having(
          (error) => error.message,
          'message',
          contains('не найдено'),
        ),
      ),
    );
  });

  test('a server without relay is rejected before any request', () async {
    final direct = ServerConfig(id: 'd', name: 'd', baseUrl: 'http://x:1234');
    await expectLater(
      RelayClient(direct).status(),
      throwsA(isA<RelayException>()),
    );
  });

  test('a missing relay token is rejected', () async {
    final noToken = config.clone()
      ..relayToken = ''
      ..pluginToken = '';
    await expectLater(
      RelayClient(noToken).status(),
      throwsA(
        isA<RelayException>().having(
          (error) => error.message,
          'message',
          contains('токен'),
        ),
      ),
    );
  });
}

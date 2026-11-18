import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/server_share.dart';

ServerConfig localServer() => ServerConfig(
  id: 'local',
  name: 'Домашний ПК',
  baseUrl: 'http://192.168.1.50:1234',
  apiKey: 'api-secret',
  bridgeUrl: 'http://192.168.1.50:1235',
  bridgeToken: 'bridge-secret',
  pluginUrl: 'http://192.168.1.50:1236',
  pluginToken: 'plugin-secret',
  mcpEnabled: true,
);

ServerConfig relayServer({String token = 'relay-secret'}) => ServerConfig(
  id: 'relay',
  name: 'Домашний ПК',
  baseUrl: 'http://192.168.1.50:1234',
  apiKey: 'api-secret',
  bridgeUrl: 'http://192.168.1.50:1235',
  bridgeToken: 'bridge-secret',
  pluginToken: 'plugin-secret',
  relayUrl: 'https://relay.example.com',
  relayDevice: 'home-pc',
  relayToken: token,
  relayE2e: true,
  relayPublicKey: 'public-key',
);

void main() {
  test('without relay strips relay fields and every token', () {
    final code = ServerShareCodec.encodeServer(
      relayServer(),
      ServerShareMode.withoutRelay,
    );
    final bundle = ServerShareCodec.decode(code);
    final server = bundle.servers.single;

    expect(bundle.mode, ServerShareMode.withoutRelay);
    expect(bundle.includesToken, isFalse);
    expect(server.baseUrl, 'http://192.168.1.50:1234');
    expect(server.relayUrl, isEmpty);
    expect(server.relayDevice, isEmpty);
    expect(server.relayToken, isEmpty);
    expect(server.apiKey, isEmpty);
    expect(server.bridgeToken, isEmpty);
    expect(server.pluginToken, isEmpty);
  });

  test('with relay keeps the relay token but no other secrets', () {
    final code = ServerShareCodec.encodeServer(
      relayServer(),
      ServerShareMode.withRelay,
    );
    final bundle = ServerShareCodec.decode(code);
    final server = bundle.servers.single;

    expect(bundle.mode, ServerShareMode.withRelay);
    expect(bundle.includesToken, isTrue);
    expect(bundle.tokenCount, 1);
    expect(server.relayUrl, 'https://relay.example.com');
    expect(server.relayDevice, 'home-pc');
    expect(server.relayToken, 'relay-secret');
    expect(server.relayPublicKey, 'public-key');
    expect(server.apiKey, isEmpty);
    expect(server.bridgeToken, isEmpty);
    expect(server.pluginToken, isEmpty);
  });

  test('with relay does not substitute the plugin token', () {
    final code = ServerShareCodec.encodeServer(
      relayServer(token: ''),
      ServerShareMode.withRelay,
    );
    final bundle = ServerShareCodec.decode(code);
    expect(bundle.includesToken, isFalse);
    expect(bundle.servers.single.relayToken, isEmpty);
    expect(bundle.servers.single.pluginToken, isEmpty);
  });

  test('all filters servers without the requested transport', () {
    final servers = [localServer(), relayServer()..baseUrl = ''];

    final without = ServerShareCodec.decode(
      ServerShareCodec.encodeAll(servers, ServerShareMode.withoutRelay),
    );
    expect(without.all, isTrue);
    expect(without.servers, hasLength(1));
    expect(without.skipped, 1);

    final withRelay = ServerShareCodec.decode(
      ServerShareCodec.encodeAll(servers, ServerShareMode.withRelay),
    );
    expect(withRelay.servers, hasLength(1));
    expect(withRelay.skipped, 1);
    expect(withRelay.servers.single.relayToken, 'relay-secret');
  });

  test('a code in surrounding text is still found', () {
    final code = ServerShareCodec.encodeServer(
      localServer(),
      ServerShareMode.withoutRelay,
    );
    final bundle = ServerShareCodec.decode(
      'Вот сервер:\n$code\nКонец сообщения',
    );
    expect(bundle.servers.single.name, 'Домашний ПК');
  });

  test('corrupted and foreign codes are rejected', () {
    expect(
      () => ServerShareCodec.decode('LMSRV1.%%%'),
      throwsA(isA<ServerShareException>()),
    );
    expect(
      () => ServerShareCodec.decode('hello'),
      throwsA(isA<ServerShareException>()),
    );
  });

  test('QR fits a single server but not an unbounded set', () {
    final single = ServerShareCodec.encodeServer(
      localServer(),
      ServerShareMode.withoutRelay,
    );
    expect(ServerShareCodec.fitsQr(single), isTrue);
  });

  test('import adds a new server and its relay token', () {
    final data = AppData();
    final bundle = ServerShareCodec.decode(
      ServerShareCodec.encodeServer(relayServer(), ServerShareMode.withRelay),
    );
    final result = mergeSharedServers(data, bundle);

    expect(result.added, 1);
    expect(result.tokensImported, 1);
    expect(data.servers, hasLength(1));
    expect(data.servers.single.id, isNot('relay'));
    expect(data.servers.single.relayToken, 'relay-secret');
    expect(data.servers.single.apiKey, isEmpty);
    expect(data.activeServerId, data.servers.single.id);
  });

  test('import fills relay settings without overwriting local tokens', () {
    final data = AppData(
      servers: [
        localServer()
          ..apiKey = 'local-api'
          ..bridgeToken = 'local-bridge'
          ..pluginToken = 'local-plugin',
      ],
    );
    final bundle = ServerShareCodec.decode(
      ServerShareCodec.encodeServer(relayServer(), ServerShareMode.withRelay),
    );

    final result = mergeSharedServers(data, bundle);

    expect(result.added, 0);
    expect(result.updated, 1);
    expect(result.tokensImported, 1);
    expect(data.servers, hasLength(1));
    final server = data.servers.single;
    expect(server.apiKey, 'local-api');
    expect(server.bridgeToken, 'local-bridge');
    expect(server.pluginToken, 'local-plugin');
    expect(server.relayUrl, 'https://relay.example.com');
    expect(server.relayToken, 'relay-secret');
  });

  test('import does not replace a different relay token', () {
    final existing = relayServer(token: 'local-token');
    final data = AppData(servers: [existing]);
    final bundle = ServerShareCodec.decode(
      ServerShareCodec.encodeServer(
        relayServer(token: 'shared-token'),
        ServerShareMode.withRelay,
      ),
    );

    final result = mergeSharedServers(data, bundle);

    expect(result.added, 0);
    expect(result.tokensImported, 0);
    expect(data.servers.single.relayToken, 'local-token');
  });

  test('import does not duplicate a server with the same address', () {
    final data = AppData(servers: [localServer()]);
    final bundle = ServerShareCodec.decode(
      ServerShareCodec.encodeServer(
        localServer(),
        ServerShareMode.withoutRelay,
      ),
    );

    final result = mergeSharedServers(data, bundle);

    expect(result.added, 0);
    expect(data.servers, hasLength(1));
  });

  test('a server with both transports is available in both variants', () {
    final server = relayServer();
    expect(
      ServerShareCodec.supports(server, ServerShareMode.withoutRelay),
      isTrue,
    );
    expect(
      ServerShareCodec.supports(server, ServerShareMode.withRelay),
      isTrue,
    );
    final without = ServerShareCodec.decode(
      ServerShareCodec.encodeServer(server, ServerShareMode.withoutRelay),
    );
    expect(without.servers.single.baseUrl, 'http://192.168.1.50:1234');
    expect(without.servers.single.relayUrl, isEmpty);
  });

  test('the payload is valid JSON after base64 decoding', () {
    final code = ServerShareCodec.encodeServer(
      localServer(),
      ServerShareMode.withoutRelay,
    );
    final body = code.split('.').last;
    final padded = body.padRight((body.length + 3) ~/ 4 * 4, '=');
    final bytes = base64Url.decode(padded);
    final text = utf8.decode(code.contains('Z1.') ? gzipDecode(bytes) : bytes);
    final json = jsonDecode(text) as Map;
    expect(json['kind'], 'lm-chat-server-share');
    expect(json['version'], 1);
    expect(json['servers'], hasLength(1));
  });
}

List<int> gzipDecode(List<int> bytes) {
  // The codec may choose gzip; the test only needs to inspect the JSON.
  try {
    return gzip.decode(bytes);
  } catch (_) {
    return bytes;
  }
}

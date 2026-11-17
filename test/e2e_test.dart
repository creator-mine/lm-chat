import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lm_chat/e2e.dart';
import 'package:lm_chat/models.dart';

const _helloSize = 55;

class FakeRelay {
  FakeRelay(this.server, this.config);

  final HttpServer server;
  final ServerConfig config;
  final List<String> paths = [];
  String? auth;
  String? relayToken;

  Future<void> close() => server.close(force: true);
}

Future<FakeRelay> startFakeRelay({
  bool sse = false,
  String? forcedPublicKey,
}) async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  final config = ServerConfig(
    id: 'e2e',
    name: 'E2E',
    baseUrl: '',
    relayUrl: 'http://127.0.0.1:${server.port}',
    relayDevice: 'dev',
    relayToken: 'relay-token-0123456789',
    relayE2e: true,
    relayPublicKey: forcedPublicKey ?? base64Encode(publicKey.bytes),
    pluginToken: 'plugin-token-0123456789',
  );
  final relay = FakeRelay(server, config);

  server.listen((request) async {
    try {
      if (request.method != 'POST' || request.uri.path != '/d/dev/_e2e') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      relay.relayToken = request.headers.value('x-relay-token');
      final bytes = await request.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      final session = await createE2eAgentSession(
        keyPair,
        Uint8List.fromList(bytes.sublist(0, _helloSize)),
      );

      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.binary;
      request.response.bufferOutput = false;
      await _writeFrame(request.response, session, utf8.encode('{"ok":true}'));
      await request.response.flush();

      var offset = _helloSize;
      final headerFrame = await _readFrame(bytes, offset, session);
      offset = headerFrame.nextOffset;
      final header = jsonDecode(utf8.decode(headerFrame.plain)) as Map;
      relay.paths.add(header['path'] as String);
      final headers = header['headers'];
      if (headers is Map) {
        final authValues = headers['authorization'];
        if (authValues is List && authValues.isNotEmpty) {
          relay.auth = authValues.first.toString();
        }
      }

      final responseHeaders = sse
          ? <String, List<String>>{
              'Content-Type': <String>['text/event-stream'],
            }
          : <String, List<String>>{
              'Content-Type': <String>['application/json'],
            };
      await _writeFrame(
        request.response,
        session,
        utf8.encode(jsonEncode({'status': 200, 'headers': responseHeaders})),
      );

      if (sse) {
        for (var index = 0; index < 3; index++) {
          await _writeFrame(
            request.response,
            session,
            utf8.encode('data: $index\n\n'),
          );
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      } else {
        await _writeFrame(
          request.response,
          session,
          utf8.encode(jsonEncode({'ok': true, 'path': header['path']})),
        );
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {
        // The client already closed the connection.
      }
    }
  });

  return relay;
}

Future<void> _writeFrame(
  HttpResponse response,
  E2eSession session,
  List<int> plain,
) async {
  final sealed = await session.seal(plain);
  final header = ByteData(4)..setUint32(0, sealed.length);
  response.add(header.buffer.asUint8List());
  response.add(sealed);
}

Future<({Uint8List plain, int nextOffset})> _readFrame(
  List<int> bytes,
  int offset,
  E2eSession session,
) async {
  final lengthBytes = Uint8List.fromList(bytes.sublist(offset, offset + 4));
  final length = ByteData.sublistView(lengthBytes).getUint32(0);
  offset += 4;
  final sealed = Uint8List.fromList(bytes.sublist(offset, offset + length));
  final plain = await session.open(sealed);
  return (plain: plain, nextOffset: offset + length);
}

void main() {
  test('parses base64 and hex keys and groups the fingerprint', () async {
    final keyPair = await X25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final bytes = Uint8List.fromList(publicKey.bytes);
    final base64Key = base64Encode(bytes);
    final hexKey = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    expect(parseE2ePublicKey(base64Key), equals(bytes));
    expect(parseE2ePublicKey(hexKey), equals(bytes));
    expect(
      e2eFingerprint(bytes),
      matches(RegExp(r'^[0-9A-F]{4}( [0-9A-F]{4}){15}$')),
    );
    expect(() => parseE2ePublicKey('not-a-key'), throwsA(isA<E2eException>()));
  });

  test('request and response are encrypted end to end', () async {
    final relay = await startFakeRelay();
    addTearDown(relay.close);

    final client = RelayE2eClient(relay.config);
    final response = await client.get(
      Uri.parse('${relay.config.relayBase}/api/status'),
      headers: {'Authorization': 'Bearer plugin-token-0123456789'},
    );

    expect(response.statusCode, 200);
    expect(response.body, contains('"path":"/api/status"'));
    expect(relay.paths, ['/api/status']);
    expect(relay.auth, 'Bearer plugin-token-0123456789');
    expect(relay.relayToken, 'relay-token-0123456789');
  });

  test('SSE frames are decrypted as they arrive', () async {
    final relay = await startFakeRelay(sse: true);
    addTearDown(relay.close);

    final client = RelayE2eClient(relay.config);
    final started = DateTime.now();
    final request = http.Request(
      'GET',
      Uri.parse('${relay.config.relayBase}/v1/events'),
    );
    final response = await client.send(request);

    final stamps = <DateTime>[];
    await for (final chunk in response.stream) {
      if (utf8.decode(chunk).contains('data:')) {
        stamps.add(DateTime.now());
      }
    }

    expect(stamps.length, 3);
    expect(
      stamps.first.difference(started).inMilliseconds,
      lessThan(800),
      reason: 'the first event should not wait for the whole response',
    );
    expect(
      stamps.last.difference(stamps.first).inMilliseconds,
      greaterThan(150),
    );
  });

  test(
    'a wrong pinned key is rejected before any plaintext is trusted',
    () async {
      final other = await X25519().newKeyPair();
      final otherPublic = await other.extractPublicKey();
      final relay = await startFakeRelay(
        forcedPublicKey: base64Encode(otherPublic.bytes),
      );
      addTearDown(relay.close);

      final client = RelayE2eClient(relay.config);
      await expectLater(
        client.get(Uri.parse('${relay.config.relayBase}/api/status')),
        throwsA(isA<E2eException>()),
      );
    },
  );
}

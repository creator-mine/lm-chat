import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

const String _magic = 'LME2E1';
const int _version = 1;
const int _publicKeySize = 32;
const int _saltSize = 16;
const int _maxPlaintext = 32 * 1024;
const int _tagSize = 16;
const int _helloSize = _magic.length + 1 + _publicKeySize + _saltSize;

/// A user-facing E2E failure.
class E2eException implements Exception {
  const E2eException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parses a pinned agent public key in base64 or hex.
Uint8List parseE2ePublicKey(String value) {
  final compact = value.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) {
    throw const E2eException('E2E: укажите публичный ключ устройства');
  }
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(compact)) {
    final bytes = Uint8List(_publicKeySize);
    for (var i = 0; i < _publicKeySize; i++) {
      bytes[i] = int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  var normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
  normalized = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  try {
    final bytes = base64Decode(normalized);
    if (bytes.length != _publicKeySize) {
      throw const E2eException('E2E: публичный ключ должен быть 32 байта');
    }
    return Uint8List.fromList(bytes);
  } on FormatException {
    throw const E2eException('E2E: публичный ключ не в base64 и не в hex');
  }
}

/// SHA-256 fingerprint grouped like the agent prints it.
String e2eFingerprint(List<int> publicKey) {
  final digest = crypto.sha256.convert(publicKey).bytes;
  final text = digest
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  final parts = <String>[];
  for (var i = 0; i < text.length; i += 4) {
    final end = i + 4 > text.length ? text.length : i + 4;
    parts.add(text.substring(i, end));
  }
  return parts.join(' ');
}

class E2eHandshake {
  const E2eHandshake(this.hello, this.session);

  final Uint8List hello;
  final E2eSession session;
}

/// One direction pair for one request.
class E2eSession {
  E2eSession._(
    this._readKey,
    this._writeKey,
    this._readDirection,
    this._writeDirection,
  );

  final SecretKey _readKey;
  final SecretKey _writeKey;
  final int _readDirection;
  final int _writeDirection;
  final AesGcm _cipher = AesGcm.with256bits();

  int _readCounter = 0;
  int _writeCounter = 0;

  Future<Uint8List> seal(List<int> plain) async {
    if (plain.length > _maxPlaintext) {
      throw const E2eException('E2E: слишком большой кадр');
    }
    final counter = _writeCounter++;
    final box = await _cipher.encrypt(
      plain,
      secretKey: _writeKey,
      nonce: _nonce(counter),
      aad: _aad(_writeDirection, counter),
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> open(List<int> sealed) async {
    if (sealed.length < _tagSize) {
      throw const E2eException('E2E: короткий кадр');
    }
    final counter = _readCounter++;
    final box = SecretBox(
      sealed.sublist(0, sealed.length - _tagSize),
      nonce: _nonce(counter),
      mac: Mac(sealed.sublist(sealed.length - _tagSize)),
    );
    try {
      final plain = await _cipher.decrypt(
        box,
        secretKey: _readKey,
        aad: _aad(_readDirection, counter),
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const E2eException(
        'E2E: не удалось проверить ключ устройства. Сверьте отпечаток.',
      );
    }
  }

  static Uint8List _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, counter);
    return nonce;
  }

  static Uint8List _aad(int direction, int counter) {
    final aad = Uint8List(_magic.length + 1 + 1 + 8);
    var offset = 0;
    aad.setRange(offset, offset + _magic.length, ascii.encode(_magic));
    offset += _magic.length;
    aad[offset++] = _version;
    aad[offset++] = direction;
    ByteData.sublistView(aad).setUint64(offset, counter);
    return aad;
  }
}

/// Generates an ephemeral key and the first plaintext hello.
Future<E2eHandshake> createE2eHandshake(Uint8List agentPublicKey) async {
  final algorithm = X25519();
  final keyPair = await algorithm.newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final appPublic = Uint8List.fromList(publicKey.bytes);
  final salt = _randomBytes(_saltSize);
  final shared = await algorithm.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(agentPublicKey, type: KeyPairType.x25519),
  );
  final c2a = await _derive(shared, salt, appPublic, agentPublicKey, 'c2a');
  final a2c = await _derive(shared, salt, appPublic, agentPublicKey, 'a2c');

  final session = E2eSession._(a2c, c2a, 'a'.codeUnitAt(0), 'c'.codeUnitAt(0));
  final hello = Uint8List.fromList([
    ...ascii.encode(_magic),
    _version,
    ...appPublic,
    ...salt,
  ]);
  return E2eHandshake(hello, session);
}

Future<SecretKey> _derive(
  SecretKey shared,
  Uint8List salt,
  Uint8List appPublic,
  Uint8List agentPublic,
  String purpose,
) {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  return hkdf.deriveKey(
    secretKey: shared,
    nonce: salt,
    info: [...ascii.encode('$_magic $purpose'), ...appPublic, ...agentPublic],
  );
}

/// Agent-side session used by tests and by a future Dart agent.
Future<E2eSession> createE2eAgentSession(
  SimpleKeyPair keyPair,
  Uint8List hello,
) async {
  if (hello.length != _helloSize) {
    throw const E2eException('E2E: неверная длина hello');
  }
  if (utf8.decode(hello.sublist(0, _magic.length)) != _magic) {
    throw const E2eException('E2E: неверный hello');
  }
  if (hello[_magic.length] != _version) {
    throw const E2eException('E2E: неподдерживаемая версия');
  }
  var offset = _magic.length + 1;
  final appPublic = Uint8List.fromList(
    hello.sublist(offset, offset + _publicKeySize),
  );
  offset += _publicKeySize;
  final salt = Uint8List.fromList(hello.sublist(offset, offset + _saltSize));
  final publicKey = await keyPair.extractPublicKey();
  final agentPublic = Uint8List.fromList(publicKey.bytes);

  final shared = await X25519().sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(appPublic, type: KeyPairType.x25519),
  );
  final c2a = await _derive(shared, salt, appPublic, agentPublic, 'c2a');
  final a2c = await _derive(shared, salt, appPublic, agentPublic, 'a2c');
  return E2eSession._(c2a, a2c, 'c'.codeUnitAt(0), 'a'.codeUnitAt(0));
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// HTTP client that tunnels requests through the relay with E2E encryption.
///
/// The relay sees only `POST /d/<device>/_e2e` and opaque lengths.
class RelayE2eClient extends http.BaseClient {
  RelayE2eClient(this.server, [http.Client? inner])
    : _inner = inner ?? http.Client();

  final ServerConfig server;
  final http.Client _inner;

  static const Set<String> _skipHeaders = {
    'host',
    'content-length',
    'accept-encoding',
    'x-relay-token',
    'connection',
    'transfer-encoding',
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final agentKey = parseE2ePublicKey(server.relayPublicKey);
    final body = await request.finalize().toBytes();
    final path = _originalPath(request.url);
    final service = _serviceForPath(path);

    final headers = <String, List<String>>{};
    request.headers.forEach((key, value) {
      if (_skipHeaders.contains(key.toLowerCase())) return;
      headers[key.toLowerCase()] = [value];
    });

    final handshake = await createE2eHandshake(agentKey);
    final session = handshake.session;
    final payload = BytesBuilder(copy: false);
    payload.add(handshake.hello);
    payload.add(
      await _sealFrame(
        session,
        utf8.encode(
          jsonEncode({
            'service': service,
            'method': request.method,
            'path': path,
            'headers': headers,
            'body': body.isNotEmpty,
          }),
        ),
      ),
    );
    for (var offset = 0; offset < body.length; offset += _maxPlaintext) {
      final end = min(offset + _maxPlaintext, body.length);
      payload.add(await _sealFrame(session, body.sublist(offset, end)));
    }

    final relayRequest =
        http.Request('POST', Uri.parse('${server.relayBase}/_e2e'))
          ..headers.addAll(server.relayHeaders)
          ..headers['Content-Type'] = 'application/octet-stream'
          ..headers['Accept'] = 'application/octet-stream'
          ..bodyBytes = payload.takeBytes();

    final response = await _inner.send(relayRequest);
    if (response.statusCode != 200) return response;

    final reader = _FrameReader(response.stream);
    try {
      final ack = await reader.next();
      if (ack == null) {
        throw const E2eException('E2E: агент закрыл соединение без ответа');
      }
      final ackText = utf8.decode(await session.open(ack));
      if (ackText != '{"ok":true}') {
        throw const E2eException('E2E: неожиданный ответ агента');
      }

      final headerFrame = await reader.next();
      if (headerFrame == null) {
        throw const E2eException('E2E: нет заголовков ответа');
      }
      final decoded = jsonDecode(utf8.decode(await session.open(headerFrame)));
      if (decoded is! Map) {
        throw const E2eException('E2E: некорректные заголовки ответа');
      }

      final status = (decoded['status'] as num?)?.toInt() ?? 502;
      final responseHeaders = <String, String>{};
      final rawHeaders = decoded['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((key, value) {
          if (value is List) {
            responseHeaders[key.toString()] = value
                .map((item) => item.toString())
                .join(', ');
          } else if (value != null) {
            responseHeaders[key.toString()] = value.toString();
          }
        });
      }

      final controller = StreamController<List<int>>(
        onCancel: () => unawaited(reader.cancel()),
      );
      unawaited(_pump(reader, session, controller));

      return http.StreamedResponse(
        controller.stream,
        status < 100 || status > 599 ? 502 : status,
        contentLength: int.tryParse(responseHeaders['content-length'] ?? ''),
        request: request,
        headers: responseHeaders,
      );
    } catch (_) {
      await reader.cancel();
      rethrow;
    }
  }

  String _originalPath(Uri url) {
    final basePath = Uri.parse(server.relayBase).path;
    var path = url.path;
    if (basePath.isNotEmpty && path.startsWith(basePath)) {
      path = path.substring(basePath.length);
    }
    if (path.isEmpty) path = '/';
    if (!path.startsWith('/')) path = '/$path';
    if (url.hasQuery) path = '$path?${url.query}';
    return path;
  }

  String _serviceForPath(String path) {
    final clean = path.split('?').first;
    if (clean == '/v1' || clean.startsWith('/v1/')) return 'lmstudio';
    if (clean == '/api/v1' || clean.startsWith('/api/v1/')) {
      return 'lmstudio';
    }
    if (clean.startsWith('/api/')) return 'plugin';
    if (clean == '/health' ||
        clean == '/ps' ||
        clean == '/load' ||
        clean == '/unload' ||
        clean == '/estimate' ||
        clean == '/chat' ||
        clean.startsWith('/chat/')) {
      return 'bridge';
    }
    throw E2eException('E2E: неизвестный путь $clean');
  }

  Future<Uint8List> _sealFrame(E2eSession session, List<int> plain) async {
    final sealed = await session.seal(plain);
    final header = ByteData(4)..setUint32(0, sealed.length);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...sealed]);
  }

  Future<void> _pump(
    _FrameReader reader,
    E2eSession session,
    StreamController<List<int>> controller,
  ) async {
    try {
      while (!controller.isClosed) {
        final frame = await reader.next();
        if (frame == null) break;
        controller.add(await session.open(frame));
      }
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
    } finally {
      if (!controller.isClosed) await controller.close();
      await reader.cancel();
    }
  }
}

class _FrameReader {
  _FrameReader(Stream<List<int>> stream) : _iterator = StreamIterator(stream);

  final StreamIterator<List<int>> _iterator;
  final List<int> _buffer = [];
  int _offset = 0;
  bool _cancelled = false;

  int get _length => _buffer.length - _offset;

  Future<Uint8List?> next() async {
    while (_length < 4) {
      if (!await _iterator.moveNext()) {
        if (_length == 0) return null;
        throw const E2eException('E2E: обрезанный кадр');
      }
      _buffer.addAll(_iterator.current);
    }
    final length = _peekUint32();
    if (length == 0 || length > _maxPlaintext + _tagSize) {
      throw const E2eException('E2E: некорректная длина кадра');
    }
    while (_length < 4 + length) {
      if (!await _iterator.moveNext()) {
        throw const E2eException('E2E: обрезанный кадр');
      }
      _buffer.addAll(_iterator.current);
    }

    final frame = Uint8List.fromList(
      _buffer.sublist(_offset + 4, _offset + 4 + length),
    );
    _offset += 4 + length;
    if (_offset > 64 * 1024) {
      _buffer.removeRange(0, _offset);
      _offset = 0;
    }
    return frame;
  }

  int _peekUint32() {
    final bytes = Uint8List.fromList(_buffer.sublist(_offset, _offset + 4));
    return ByteData.sublistView(bytes).getUint32(0);
  }

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _iterator.cancel();
  }
}

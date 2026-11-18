import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';

abstract class SyncServerDelegate {
  SyncIdentity get identity;

  Future<Map<String, dynamic>> handlePairBegin(Map<String, dynamic> body);

  Future<Map<String, dynamic>> handlePairConfirm(Map<String, dynamic> body);

  Future<Map<String, dynamic>> handlePairStatus(Map<String, dynamic> body);

  Future<Map<String, dynamic>> handleExchangeBegin(Map<String, dynamic> body);

  Future<Uint8List> handleExchange(String sessionId, Uint8List sealed);
}

/// Temporary HTTP listener used while the app is open.
class SyncServer {
  SyncServer(this.delegate);

  final SyncServerDelegate delegate;
  HttpServer? _server;

  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  Future<int> start({int port = 0}) async {
    if (_server != null) return this.port;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      if (port == 0) rethrow;
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(_handle);
    return server.port;
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final remote = request.connectionInfo?.remoteAddress;
      if (remote != null && !_isPrivate(remote)) {
        await _error(
          request,
          HttpStatus.forbidden,
          'Локальная сеть недоступна',
        );
        return;
      }

      final path = request.uri.path;
      if (request.method == 'GET' && path == '/sync/info') {
        final publicKey = await delegate.identity.publicKey();
        await _json(request, HttpStatus.ok, {
          'ok': true,
          'protocol': syncProtocolVersion,
          'deviceId': delegate.identity.deviceId,
          'name': delegate.identity.name,
          'publicKey': syncB64(publicKey),
        });
        return;
      }

      if (request.method != 'POST') {
        await _error(request, HttpStatus.notFound, 'Не найдено');
        return;
      }

      if (path == '/sync/exchange') {
        final sessionId = request.headers.value('x-sync-session') ?? '';
        if (sessionId.isEmpty) {
          await _error(request, HttpStatus.badRequest, 'Нет сессии');
          return;
        }
        final body = await _readBytes(request, syncMaxBundleBytes);
        final sealed = await delegate.handleExchange(sessionId, body);
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.binary;
        request.response.add(sealed);
        await request.response.close();
        return;
      }

      final body = await _readJson(request);
      if (path == '/sync/pair/begin') {
        body['_remoteAddress'] =
            request.connectionInfo?.remoteAddress.address ?? '';
      }
      final result = switch (path) {
        '/sync/pair/begin' => await delegate.handlePairBegin(body),
        '/sync/pair/confirm' => await delegate.handlePairConfirm(body),
        '/sync/pair/status' => await delegate.handlePairStatus(body),
        '/sync/exchange/begin' => await delegate.handleExchangeBegin(body),
        _ => null,
      };
      if (result == null) {
        await _error(request, HttpStatus.notFound, 'Не найдено');
        return;
      }
      await _json(request, HttpStatus.ok, result);
    } on SyncException catch (error) {
      await _error(request, HttpStatus.badRequest, error.message);
    } on FormatException {
      await _error(request, HttpStatus.badRequest, 'Некорректные данные');
    } catch (error) {
      await _error(
        request,
        HttpStatus.internalServerError,
        'Ошибка синхронизации',
      );
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final bytes = await _readBytes(request, 1024 * 1024);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const FormatException('JSON object expected');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<Uint8List> _readBytes(HttpRequest request, int limit) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw SyncException('Пакет синхронизации слишком большой');
      }
    }
    return builder.takeBytes();
  }

  Future<void> _json(
    HttpRequest request,
    int status,
    Map<String, dynamic> value,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  Future<void> _error(HttpRequest request, int status, String message) async {
    try {
      await _json(request, status, {'ok': false, 'error': message});
    } catch (_) {
      // The client may already be gone.
    }
  }

  bool _isPrivate(InternetAddress address) {
    if (address.isLoopback) return true;
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return _isPrivateV4(bytes);
    }
    if (bytes.length == 16) {
      final mapped =
          bytes.take(10).every((byte) => byte == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff;
      if (mapped) return _isPrivateV4(bytes.sublist(12));
      final loopback =
          bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
      final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
      final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
      return loopback || uniqueLocal || linkLocal;
    }
    return false;
  }

  bool _isPrivateV4(List<int> bytes) {
    final a = bytes[0];
    final b = bytes[1];
    if (a == 10 || a == 127) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }
}

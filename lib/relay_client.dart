import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class RelayException implements Exception {
  RelayException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Online state reported by the relay itself.
class RelayStatus {
  const RelayStatus({
    required this.online,
    required this.streams,
    required this.version,
    required this.uptimeMs,
  });

  final bool online;
  final int streams;
  final String version;
  final int uptimeMs;

  factory RelayStatus.fromJson(Map<String, dynamic> json) => RelayStatus(
    online: json['online'] == true,
    streams: (json['streams'] as num?)?.toInt() ?? 0,
    version: json['version']?.toString() ?? '',
    uptimeMs: (json['uptime_ms'] as num?)?.toInt() ?? 0,
  );
}

/// Queries the relay-level status endpoint.
///
/// This request is deliberately outside E2E: the relay answers it itself and
/// only reveals whether an agent is connected.
class RelayClient {
  RelayClient(this.server);

  final ServerConfig server;

  static const Duration _timeout = Duration(seconds: 8);

  Future<RelayStatus> status() async {
    if (!server.hasRelay) {
      throw RelayException('Relay не настроен.');
    }
    if (server.relayDevice.trim().isEmpty) {
      throw RelayException('Укажите ID устройства relay.');
    }
    final security = server.relaySecurityError;
    if (security != null) throw RelayException(security);
    final headers = <String, String>{
      'Accept': 'application/json',
      ...server.relayHeaders,
    };
    if (!headers.containsKey('X-Relay-Token')) {
      throw RelayException('Укажите токен relay.');
    }

    final response = await http
        .get(Uri.parse('${server.relayBase}/_relay/status'), headers: headers)
        .timeout(_timeout);

    Map<String, dynamic> decoded = const {};
    if (response.body.trim().isNotEmpty) {
      try {
        final value = jsonDecode(response.body);
        if (value is Map<String, dynamic>) decoded = value;
      } catch (_) {
        // A proxy may answer with plain text.
      }
    }
    if (response.statusCode == 401) {
      throw RelayException('Неверный токен relay (401).');
    }
    if (response.statusCode == 404) {
      throw RelayException('Устройство не найдено на relay (404).');
    }
    if (response.statusCode != 200 || decoded['ok'] == false) {
      final error = decoded['error']?.toString();
      throw RelayException(
        error == null || error.isEmpty
            ? 'Relay ответил ошибкой ${response.statusCode}.'
            : error,
      );
    }
    return RelayStatus.fromJson(decoded);
  }
}

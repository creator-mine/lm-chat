import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

enum ServerShareMode { withoutRelay, withRelay }

class ServerShareException implements Exception {
  ServerShareException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SharedServerBundle {
  const SharedServerBundle({
    required this.servers,
    required this.mode,
    required this.all,
    required this.includesToken,
    required this.skipped,
  });

  final List<ServerConfig> servers;
  final ServerShareMode mode;
  final bool all;
  final bool includesToken;
  final int skipped;

  int get tokenCount => servers.where((server) {
    return server.relayToken.trim().isNotEmpty;
  }).length;
}

class ServerShareImportResult {
  const ServerShareImportResult({
    this.added = 0,
    this.updated = 0,
    this.tokensImported = 0,
    this.skipped = 0,
  });

  final int added;
  final int updated;
  final int tokensImported;
  final int skipped;

  bool get changed => added > 0 || updated > 0 || tokensImported > 0;
}

class ServerShareCodec {
  static const String kind = 'lm-chat-server-share';
  static const int version = 1;
  static const int maxCodeBytes = 64 * 1024;
  static const int maxQrBytes = 1800;

  static bool supports(ServerConfig server, ServerShareMode mode) =>
      mode == ServerShareMode.withoutRelay
      ? server.baseUrl.trim().isNotEmpty
      : server.hasRelay;

  static String encodeServer(ServerConfig server, ServerShareMode mode) {
    if (!supports(server, mode)) {
      throw ServerShareException(
        mode == ServerShareMode.withRelay
            ? 'У сервера не настроен relay'
            : 'У сервера нет локального адреса',
      );
    }
    return _encode([server], mode, all: false);
  }

  static String encodeAll(
    Iterable<ServerConfig> servers,
    ServerShareMode mode,
  ) {
    final all = servers.toList();
    final eligible = all.where((server) => supports(server, mode)).toList();
    if (eligible.isEmpty) {
      throw ServerShareException(
        mode == ServerShareMode.withRelay
            ? 'Нет серверов с relay'
            : 'Нет серверов с локальным адресом',
      );
    }
    return _encode(
      eligible,
      mode,
      all: true,
      skipped: all.length - eligible.length,
    );
  }

  static String _encode(
    List<ServerConfig> servers,
    ServerShareMode mode, {
    required bool all,
    int skipped = 0,
  }) {
    final maps = <Map<String, dynamic>>[];
    var includesToken = false;
    for (final server in servers) {
      final map = server.toJson(includeSecrets: false);
      map.remove('apiKey');
      map.remove('bridgeToken');
      map.remove('pluginToken');
      map.remove('relayToken');
      if (mode == ServerShareMode.withoutRelay) {
        map.remove('relayUrl');
        map.remove('relayDevice');
        map.remove('relayE2e');
        map.remove('relayPublicKey');
      } else {
        final token = server.relayToken.trim();
        if (token.isNotEmpty) {
          map['relayToken'] = token;
          includesToken = true;
        }
      }
      maps.add(map);
    }

    final payload = {
      'kind': kind,
      'version': version,
      'all': all,
      'mode': mode.name,
      'includesToken': includesToken,
      'skipped': skipped,
      'servers': maps,
    };
    final raw = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final compressed = Uint8List.fromList(gzip.encode(raw));
    final useGzip = compressed.length < raw.length;
    final bytes = useGzip ? compressed : raw;
    final body = base64Url.encode(bytes).replaceAll('=', '');
    final prefix = all
        ? (useGzip ? 'LMSRVSZ1.' : 'LMSRVS1.')
        : (useGzip ? 'LMSRVZ1.' : 'LMSRV1.');
    final code = '$prefix$body';
    if (utf8.encode(code).length > maxCodeBytes) {
      throw ServerShareException('Слишком много данных для одного кода');
    }
    return code;
  }

  static bool fitsQr(String code) => utf8.encode(code).length <= maxQrBytes;

  /// Decompresses in chunks and aborts before a small code can expand into a
  /// multi-megabyte payload.
  static List<int> _gunzipLimited(List<int> bytes) {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    final sink = _LimitedSink((data) {
      total += data.length;
      if (total > maxCodeBytes) {
        throw ServerShareException('Код сервера слишком большой');
      }
      builder.add(data);
    });
    final input = gzip.decoder.startChunkedConversion(sink);
    input.add(bytes);
    input.close();
    return builder.takeBytes();
  }

  static SharedServerBundle decode(String text) {
    final matches = RegExp(r'LMSRV(S?)(Z?)1\.([A-Za-z0-9_-]+)')
        .allMatches(text);
    if (matches.isEmpty) {
      throw ServerShareException('Это не код сервера LM Chat');
    }
    final match = matches.last;
    final gzipEncoded = match.group(2) == 'Z';
    final body = match.group(3) ?? '';
    final padded = body.padRight((body.length + 3) ~/ 4 * 4, '=');
    late final List<int> raw;
    try {
      final bytes = base64Url.decode(padded);
      if (bytes.length > maxCodeBytes) {
        throw ServerShareException('Код сервера слишком большой');
      }
      raw = gzipEncoded ? _gunzipLimited(bytes) : bytes;
    } on ServerShareException {
      rethrow;
    } catch (_) {
      throw ServerShareException('Повреждённый код сервера');
    }
    if (raw.length > maxCodeBytes) {
      throw ServerShareException('Код сервера слишком большой');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } catch (_) {
      throw ServerShareException('Повреждённый код сервера');
    }
    if (decoded is! Map) {
      throw ServerShareException('Повреждённый код сервера');
    }
    final json = Map<String, dynamic>.from(decoded);
    if (json['kind'] != kind) {
      throw ServerShareException('Это не код сервера LM Chat');
    }
    final formatVersion = (json['version'] as num?)?.toInt() ?? 0;
    if (formatVersion > version) {
      throw ServerShareException('Обновите LM Chat на обоих устройствах');
    }
    final mode = json['mode'] == ServerShareMode.withRelay.name
        ? ServerShareMode.withRelay
        : ServerShareMode.withoutRelay;
    final rawServers = json['servers'];
    if (rawServers is! List || rawServers.isEmpty) {
      throw ServerShareException('В коде нет серверов');
    }
    if (rawServers.length > 100) {
      throw ServerShareException('Слишком много серверов в коде');
    }

    final servers = <ServerConfig>[];
    var skipped = (json['skipped'] as num?)?.toInt() ?? 0;
    for (final item in rawServers) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final map = Map<String, dynamic>.from(item);
      late final ServerConfig server;
      try {
        server = ServerConfig.fromJson(map);
      } catch (_) {
        skipped++;
        continue;
      }
      server.apiKey = '';
      server.bridgeToken = '';
      server.pluginToken = '';
      if (mode == ServerShareMode.withoutRelay) {
        server.relayUrl = '';
        server.relayDevice = '';
        server.relayToken = '';
        server.relayE2e = false;
        server.relayPublicKey = '';
      } else {
        server.relayToken = server.relayToken.trim();
        if (!server.hasRelay) {
          skipped++;
          continue;
        }
      }
      if (server.securityError != null) {
        skipped++;
        continue;
      }
      if (mode == ServerShareMode.withoutRelay &&
          server.baseUrl.trim().isEmpty) {
        skipped++;
        continue;
      }
      servers.add(server);
    }

    if (servers.isEmpty) {
      throw ServerShareException(
        'В коде нет подходящих серверов${skipped > 0 ? ' ($skipped пропущено)' : ''}',
      );
    }
    final includesToken = servers.any(
      (server) => server.relayToken.trim().isNotEmpty,
    );
    return SharedServerBundle(
      servers: servers,
      mode: mode,
      all: json['all'] == true,
      includesToken: includesToken,
      skipped: skipped,
    );
  }
}

ServerShareImportResult mergeSharedServers(
  AppData data,
  SharedServerBundle bundle,
) {
  var added = 0;
  var updated = 0;
  var tokens = 0;

  for (final shared in bundle.servers) {
    final existing = _findServer(data.servers, shared);
    if (existing == null) {
      final map = shared.toJson(includeSecrets: false);
      map['id'] = newId();
      final token = shared.relayToken.trim();
      if (token.isNotEmpty) {
        map['relayToken'] = token;
      }
      final server = ServerConfig.fromJson(map)
        ..apiKey = ''
        ..bridgeToken = ''
        ..pluginToken = '';
      data.servers.add(server);
      added++;
      if (token.isNotEmpty) tokens++;
      continue;
    }

    var changed = false;
    if (existing.baseUrl.trim().isEmpty && shared.baseUrl.trim().isNotEmpty) {
      existing.baseUrl = shared.baseUrl;
      changed = true;
    }

    final sharedRelay = shared.normalizedRelay.toLowerCase();
    final existingRelay = existing.normalizedRelay.toLowerCase();
    if (sharedRelay.isNotEmpty) {
      final sameRelay = existingRelay.isEmpty || existingRelay == sharedRelay;
      if (sameRelay) {
        if (existing.relayUrl.trim().isEmpty) {
          existing.relayUrl = shared.relayUrl;
          existing.relayDevice = shared.relayDevice;
          existing.relayE2e = shared.relayE2e;
          existing.relayPublicKey = shared.relayPublicKey;
          changed = true;
        }
        final token = shared.relayToken.trim();
        if (existing.relayToken.trim().isEmpty && token.isNotEmpty) {
          existing.relayToken = token;
          changed = true;
          tokens++;
        }
      }
    }

    if (changed) updated++;
  }

  data.activeServerId ??= data.servers.isNotEmpty
      ? data.servers.first.id
      : null;
  return ServerShareImportResult(
    added: added,
    updated: updated,
    tokensImported: tokens,
    skipped: bundle.skipped,
  );
}

ServerConfig? _findServer(List<ServerConfig> servers, ServerConfig shared) {
  for (final server in servers) {
    if (server.id == shared.id) return server;
  }
  final relay = shared.normalizedRelay.toLowerCase();
  if (relay.isNotEmpty) {
    for (final server in servers) {
      if (server.normalizedRelay.toLowerCase() == relay) return server;
    }
  }
  final base = shared.normalizedBase.toLowerCase();
  if (base.isNotEmpty) {
    for (final server in servers) {
      if (server.normalizedBase.toLowerCase() == base) return server;
    }
  }
  final rawBase = shared.baseUrl.trim().toLowerCase();
  if (rawBase.isNotEmpty) {
    for (final server in servers) {
      if (server.baseUrl.trim().toLowerCase() == rawBase) return server;
    }
  }
  return null;
}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this._add);

  final void Function(List<int> data) _add;

  @override
  void add(List<int> data) => _add(data);

  @override
  void close() {}
}

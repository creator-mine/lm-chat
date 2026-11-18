import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../limited_gzip.dart';
import '../models.dart';
import 'crypto.dart';

/// Portable snapshot exchanged between devices.
///
/// Only chats and servers are included. Attachments, prompt templates,
/// appearance and all credentials stay on the device.
class SyncBundle {
  SyncBundle({
    required this.deviceId,
    required this.deviceName,
    required this.exportedAt,
    required this.servers,
    required this.chats,
  });

  static const String kind = 'lm-chat-sync';
  static const int formatVersion = 1;

  final String deviceId;
  final String deviceName;
  final DateTime exportedAt;
  final List<Map<String, dynamic>> servers;
  final List<Map<String, dynamic>> chats;

  int get chatCount => chats.length;
  int get serverCount => servers.length;
  int get messageCount => chats.fold<int>(
    0,
    (sum, chat) => sum + ((chat['messages'] as List?)?.length ?? 0),
  );

  factory SyncBundle.fromData(
    AppData data, {
    required String deviceId,
    required String deviceName,
    Set<String> excludeChatIds = const {},
  }) {
    final servers = <Map<String, dynamic>>[];
    for (final server in data.servers) {
      final json = server.toJson(includeSecrets: false);
      servers.add(json);
    }
    final chats = <Map<String, dynamic>>[];
    for (final chat in data.chats) {
      if (excludeChatIds.contains(chat.id)) continue;
      // A chat with a bridge job still generating is device-specific. Leave it
      // out until the answer is complete.
      if (chat.messages.any((message) => message.hasPendingJob)) continue;
      chats.add(chatToJson(chat));
    }
    return SyncBundle(
      deviceId: deviceId,
      deviceName: deviceName,
      exportedAt: DateTime.now(),
      servers: servers,
      chats: chats,
    );
  }

  static Map<String, dynamic> chatToJson(ChatSession chat) {
    final json = chat.toJson();
    final messages = json['messages'];
    if (messages is List) {
      for (final message in messages) {
        if (message is! Map) continue;
        message.remove('jobId');
        message.remove('jobServerId');
        message.remove('jobSeq');
        message.remove('attachments');
      }
    }
    return json;
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'formatVersion': formatVersion,
    'protocol': syncProtocolVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'exportedAt': exportedAt.toIso8601String(),
    'servers': servers,
    'chats': chats,
  };

  factory SyncBundle.fromJson(Map<String, dynamic> json) {
    if (json['kind'] != kind) {
      throw SyncException('Это не файл синхронизации LM Chat');
    }
    final version = (json['formatVersion'] as num?)?.toInt() ?? 0;
    if (version > formatVersion) {
      throw SyncException('Обновите LM Chat на обоих устройствах');
    }
    final protocol = (json['protocol'] as num?)?.toInt() ?? 0;
    if (protocol != syncProtocolVersion) {
      throw SyncException('Несовместимая версия синхронизации');
    }

    final servers = <Map<String, dynamic>>[];
    final rawServers = json['servers'];
    if (rawServers is List) {
      for (final item in rawServers) {
        if (item is! Map) continue;
        final server = ServerConfig.fromJson(Map<String, dynamic>.from(item));
        server.apiKey = '';
        server.bridgeToken = '';
        server.pluginToken = '';
        server.relayToken = '';
        if (server.generationSecurityError != null) continue;
        servers.add(server.toJson(includeSecrets: false));
      }
    }

    final chats = <Map<String, dynamic>>[];
    final rawChats = json['chats'];
    if (rawChats is List) {
      for (final item in rawChats) {
        if (item is! Map) continue;
        final chat = Map<String, dynamic>.from(item);
        final messages = chat['messages'];
        if (messages is List) {
          for (final message in messages) {
            if (message is! Map) continue;
            message.remove('jobId');
            message.remove('jobServerId');
            message.remove('jobSeq');
            message.remove('attachments');
          }
        }
        // Parse once to validate and normalise timestamps/defaults.
        chat['messages'] = messages;
        ChatSession.fromJson(chat);
        chats.add(chat);
      }
    }

    final deviceId = json['deviceId'] as String? ?? '';
    if (deviceId.trim().isEmpty) {
      throw SyncException(
        'В файле синхронизации нет идентификатора устройства',
      );
    }
    return SyncBundle(
      deviceId: deviceId,
      deviceName: json['deviceName'] as String? ?? 'Устройство',
      exportedAt:
          DateTime.tryParse(json['exportedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      servers: servers,
      chats: chats,
    );
  }

  Uint8List encode() {
    final raw = utf8.encode(jsonEncode(toJson()));
    if (raw.length > syncMaxBundleBytes) {
      throw SyncException('История слишком большая для синхронизации');
    }
    final packed = Uint8List.fromList(gzip.encode(raw));
    if (packed.length > syncMaxBundleBytes) {
      throw SyncException('История слишком большая для синхронизации');
    }
    return packed;
  }

  factory SyncBundle.decode(Uint8List bytes) {
    if (bytes.length > syncMaxBundleBytes) {
      throw SyncException('Пакет синхронизации слишком большой');
    }
    late final List<int> raw;
    try {
      raw = decodeGzipLimited(bytes, syncMaxBundleBytes);
    } on GzipLimitException {
      throw SyncException('История слишком большая для синхронизации');
    } on FormatException {
      throw SyncException('Повреждённый пакет синхронизации');
    } catch (_) {
      throw SyncException('Повреждённый пакет синхронизации');
    }
    if (raw.length > syncMaxBundleBytes) {
      throw SyncException('История слишком большая для синхронизации');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(raw));
    } catch (_) {
      throw SyncException('Повреждённый пакет синхронизации');
    }
    if (decoded is! Map<String, dynamic>) {
      throw SyncException('Повреждённый пакет синхронизации');
    }
    return SyncBundle.fromJson(decoded);
  }

  /// Parses a bundle from a previously decoded JSON file.
  factory SyncBundle.fromDecoded(Object? value) {
    if (value is! Map) {
      throw SyncException('Повреждённый пакет синхронизации');
    }
    return SyncBundle.fromJson(Map<String, dynamic>.from(value));
  }
}

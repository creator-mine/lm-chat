import 'dart:typed_data';

class SyncDiscoveredPeer {
  SyncDiscoveredPeer({
    required this.deviceId,
    required this.name,
    required this.host,
    required this.port,
    required this.publicKey,
    required this.lastSeen,
  });

  final String deviceId;
  String name;
  String host;
  int port;
  Uint8List publicKey;
  DateTime lastSeen;
}

class SyncPairingPrompt {
  SyncPairingPrompt({
    required this.pairingId,
    required this.deviceId,
    required this.deviceName,
    required this.sas,
    required this.incoming,
  });

  final String pairingId;
  final String deviceId;
  final String deviceName;
  final String sas;

  /// true — запрос пришёл от другого устройства, false — мы инициировали.
  final bool incoming;
}

class SyncRunResult {
  const SyncRunResult({
    this.devices = 0,
    this.chatsAdded = 0,
    this.chatsUpdated = 0,
    this.messagesAdded = 0,
    this.messagesMerged = 0,
    this.serversAdded = 0,
    this.errors = const [],
  });

  final int devices;
  final int chatsAdded;
  final int chatsUpdated;
  final int messagesAdded;
  final int messagesMerged;
  final int serversAdded;
  final List<String> errors;

  bool get ok => errors.isEmpty;

  SyncRunResult operator +(SyncRunResult other) => SyncRunResult(
    devices: devices + other.devices,
    chatsAdded: chatsAdded + other.chatsAdded,
    chatsUpdated: chatsUpdated + other.chatsUpdated,
    messagesAdded: messagesAdded + other.messagesAdded,
    messagesMerged: messagesMerged + other.messagesMerged,
    serversAdded: serversAdded + other.serversAdded,
    errors: [...errors, ...other.errors],
  );

  String get summary {
    final parts = <String>[];
    if (chatsAdded > 0) parts.add('+$chatsAdded чатов');
    if (chatsUpdated > 0) parts.add('~$chatsUpdated чатов');
    if (messagesAdded > 0) parts.add('+$messagesAdded сообщений');
    if (messagesMerged > 0) parts.add('~$messagesMerged сообщений');
    if (serversAdded > 0) parts.add('+$serversAdded серверов');
    return parts.isEmpty ? 'Изменений нет' : parts.join(' · ');
  }
}

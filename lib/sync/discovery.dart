import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'crypto.dart';
import 'models.dart';

const int syncTcpPort = 45873;
const int syncDiscoveryPort = 45872;

/// UDP broadcast discovery on the local network. No chat data is announced.
class SyncDiscovery {
  RawDatagramSocket? _socket;
  int _port = syncDiscoveryPort;
  String _announce = '';
  String _deviceId = '';
  void Function(SyncDiscoveredPeer peer)? _onPeer;
  Timer? _scanTimer;
  bool _scanning = false;

  bool get running => _socket != null;
  int get port => _socket?.port ?? 0;

  Future<bool> start({
    required int httpPort,
    required SyncIdentity identity,
    required void Function(SyncDiscoveredPeer peer) onPeer,
    int port = syncDiscoveryPort,
  }) async {
    await stop();
    _port = port;
    _deviceId = identity.deviceId;
    _onPeer = onPeer;
    final publicKey = await identity.publicKey();
    _announce = jsonEncode({
      'kind': 'lm-chat-sync',
      'type': 'announce',
      'protocol': syncProtocolVersion,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'port': httpPort,
      'publicKey': syncB64(publicKey),
    });

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        reuseAddress: true,
      );
      if (_port == 0) _port = socket.port;
      socket.broadcastEnabled = true;
      _socket = socket;
      socket.listen(_onEvent);
      return true;
    } catch (_) {
      // Broadcast may be blocked by the OS or another instance.
      _socket = null;
      return false;
    }
  }

  void _onEvent(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null) return;
    if (event == RawSocketEvent.read) {
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        _handle(datagram!);
      }
    }
  }

  void _handle(Datagram datagram) {
    if (datagram.data.length > 4096) return;
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) return;
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    if (json['kind'] != 'lm-chat-sync' ||
        json['protocol'] != syncProtocolVersion) {
      return;
    }
    final deviceId = json['deviceId'] as String? ?? '';
    if (deviceId.isEmpty || deviceId == _deviceId) return;

    if (json['type'] == 'discover') {
      _send(datagram.address, datagram.port, _announce);
      return;
    }
    if (json['type'] != 'announce') return;
    final port = (json['port'] as num?)?.toInt() ?? 0;
    if (port <= 0 || port > 65535) return;
    try {
      final publicKey = syncUnb64(json['publicKey'] as String? ?? '');
      if (publicKey.length != 32) return;
      _onPeer?.call(
        SyncDiscoveredPeer(
          deviceId: deviceId,
          name: json['name'] as String? ?? 'Устройство',
          host: datagram.address.address,
          port: port,
          publicKey: publicKey,
          lastSeen: DateTime.now(),
        ),
      );
    } on SyncException {
      return;
    }
  }

  void _send(InternetAddress address, int port, String payload) {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.send(utf8.encode(payload), address, port);
    } catch (_) {
      // Ignore a blocked broadcast; manual address remains available.
    }
  }

  /// Broadcasts discovery for [timeout] and waits for answers.
  Future<void> scan({
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    if (_socket == null || _scanning) return;
    _scanning = true;
    final message = jsonEncode({
      'kind': 'lm-chat-sync',
      'type': 'discover',
      'protocol': syncProtocolVersion,
      'deviceId': _deviceId,
    });
    final deadline = DateTime.now().add(timeout);
    void broadcast() {
      if (_socket == null || DateTime.now().isAfter(deadline)) {
        _scanTimer?.cancel();
        _scanTimer = null;
        _scanning = false;
        return;
      }
      _send(InternetAddress('255.255.255.255'), _port, message);
    }

    broadcast();
    _scanTimer = Timer.periodic(const Duration(milliseconds: 350), (_) {
      broadcast();
    });
    await Future<void>.delayed(timeout);
    _scanTimer?.cancel();
    _scanTimer = null;
    _scanning = false;
  }

  Future<void> stop() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    _scanning = false;
    final socket = _socket;
    _socket = null;
    socket?.close();
    _onPeer = null;
  }
}

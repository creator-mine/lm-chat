import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_log.dart';
import 'bundle.dart';
import 'crypto.dart';
import 'discovery.dart';
import 'merge.dart';
import 'models.dart';
import 'server.dart';
import 'store.dart';

typedef SyncBundleBuilder = Future<SyncBundle> Function(SyncIdentity identity);
typedef SyncBundleApplier = Future<SyncMergeResult> Function(SyncBundle bundle);

class _PairingSession {
  _PairingSession({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.peerStatic,
    required this.peerHost,
    required this.peerPort,
    required this.keyA2B,
    required this.keyB2A,
    required this.transcript,
    required this.sas,
    required this.incoming,
    required this.expires,
    this.decision,
  });

  final String id;
  final String peerId;
  final String peerName;
  final Uint8List peerStatic;
  final String? peerHost;
  final int? peerPort;
  final Uint8List keyA2B;
  final Uint8List keyB2A;
  final Uint8List transcript;
  final String sas;
  final bool incoming;
  final DateTime expires;
  final Completer<bool>? decision;

  bool? hostDecision;
  bool clientConfirmed = false;
  bool accepted = false;

  bool get expired => DateTime.now().isAfter(expires);
}

class _ExchangeSession {
  _ExchangeSession({
    required this.peerId,
    required this.requestKey,
    required this.responseKey,
    required this.transcript,
    required this.expires,
  });

  final String peerId;
  final Uint8List requestKey;
  final Uint8List responseKey;
  final Uint8List transcript;
  final DateTime expires;
}

/// Coordinates discovery, pairing and bundle exchange while the app is open.
class SyncService extends ChangeNotifier implements SyncServerDelegate {
  SyncService({
    required this.buildBundle,
    required this.applyBundle,
    SyncStore? store,
    this.useDiscovery = true,
  }) : _store = store ?? SyncStore();

  final SyncBundleBuilder buildBundle;
  final SyncBundleApplier applyBundle;
  final SyncStore _store;
  final bool useDiscovery;

  final http.Client _http = http.Client();
  final StreamController<SyncPairingPrompt> _promptController =
      StreamController<SyncPairingPrompt>();
  final Map<String, SyncDiscoveredPeer> _discovered = {};
  final Map<String, _PairingSession> _pairings = {};
  final Map<String, _ExchangeSession> _exchanges = {};

  SyncServer? _server;
  SyncDiscovery? _discovery;
  bool _initialized = false;
  bool _listening = false;
  bool _syncing = false;
  bool _disposed = false;

  bool get initialized => _initialized;
  bool get listening => _listening;
  bool get discoveryAvailable => _discovery?.running == true;
  bool get syncing => _syncing;
  bool get enabled => _store.settings.enabled;
  bool get autoStart => _store.settings.autoStart;
  int get listenerPort => _server?.port ?? 0;

  Future<List<String>> localAddresses() async {
    final port = listenerPort;
    if (port <= 0) return const [];
    final result = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback) continue;
          result.add('${address.address}:$port');
        }
      }
    } catch (_) {
      // No network interfaces available.
    }
    return result;
  }

  SyncIdentity? get currentIdentity => _store.identity;

  @override
  SyncIdentity get identity => _store.identity!;

  String get deviceName => _store.identity?.name ?? 'Устройство';
  String get deviceId => _store.identity?.deviceId ?? '';
  List<SyncPeer> get pairedPeers {
    final list = _store.peers.values.toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<SyncDiscoveredPeer> get discoveredPeers {
    _pruneDiscovered();
    final list = _discovered.values.toList();
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  SyncDiscoveredPeer? discoveredFor(String deviceId) => _discovered[deviceId];

  Stream<SyncPairingPrompt> get pairingPrompts => _promptController.stream;

  Future<void> init() async {
    await _store.load();
    _initialized = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _store.settings.enabled = value;
    await _store.saveSettings();
    if (value) {
      await _ensureIdentity();
      await startListener();
    } else {
      await stopListener();
    }
    notifyListeners();
  }

  Future<void> setAutoStart(bool value) async {
    _store.settings.autoStart = value;
    await _store.saveSettings();
    notifyListeners();
  }

  Future<void> setDeviceName(String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    final identity = await _ensureIdentity();
    identity.name = name.substring(0, name.length.clamp(1, 80));
    await _store.saveIdentity();
    if (_listening) {
      await _discovery?.stop();
      _discovery = null;
      await startListener();
    }
    notifyListeners();
  }

  Future<void> startAtStartup() async {
    if (!enabled) return;
    await startListener();
    if (!autoStart) return;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (_disposed || !enabled) return;
    try {
      await syncNow(auto: true);
    } catch (_) {
      // Startup sync is best-effort; the manual button reports errors.
    }
  }

  Future<void> startListener() async {
    if (!enabled || _disposed) return;
    final identity = await _ensureIdentity();
    if (_server == null) {
      final server = SyncServer(this);
      await server.start(port: syncTcpPort);
      _server = server;
    }
    if (_discovery == null && useDiscovery) {
      final discovery = SyncDiscovery();
      final available = await discovery.start(
        httpPort: _server!.port,
        identity: identity,
        onPeer: _onDiscovered,
      );
      _discovery = discovery;
      if (!available) {
        AppLog.instance.info('Синхронизация: UDP-поиск недоступен');
      }
    }
    _listening = true;
    notifyListeners();
  }

  Future<void> stopListener() async {
    await _discovery?.stop();
    _discovery = null;
    await _server?.close();
    _server = null;
    _discovered.clear();
    _exchanges.clear();
    for (final session in _pairings.values) {
      final decision = session.decision;
      if (decision != null && !decision.isCompleted) decision.complete(false);
    }
    _pairings.clear();
    _listening = false;
    notifyListeners();
  }

  void _onDiscovered(SyncDiscoveredPeer peer) {
    if (peer.deviceId == deviceId) return;
    _discovered[peer.deviceId] = peer;
    notifyListeners();
  }

  void _pruneDiscovered() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 10));
    _discovered.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
  }

  Future<List<SyncDiscoveredPeer>> scan() async {
    await startListener();
    _discovered.clear();
    notifyListeners();
    await _discovery?.scan();
    _pruneDiscovered();
    notifyListeners();
    return discoveredPeers;
  }

  Future<SyncPeer> pairWith(SyncDiscoveredPeer peer) async {
    await startListener();
    return _pairClient(
      peer.host,
      peer.port,
      peer.deviceId,
      peer.name,
      peer.publicKey,
    );
  }

  Future<SyncPeer> pairWithAddress(String input) async {
    await startListener();
    final parsed = _parseAddress(input);
    final info = await _getJson(
      parsed.$1,
      parsed.$2,
      '/sync/info',
      timeout: const Duration(seconds: 8),
    );
    if (info['ok'] == false) {
      throw SyncException(info['error']?.toString() ?? 'Устройство недоступно');
    }
    if (info['protocol'] != syncProtocolVersion) {
      throw SyncException('Обновите LM Chat на обоих устройствах');
    }
    final deviceId = info['deviceId']?.toString() ?? '';
    final publicKey = syncUnb64(info['publicKey']?.toString() ?? '');
    if (deviceId.isEmpty || publicKey.length != 32) {
      throw SyncException('Устройство не поддерживает синхронизацию');
    }
    return _pairClient(
      parsed.$1,
      parsed.$2,
      deviceId,
      info['name']?.toString() ?? 'Устройство',
      publicKey,
    );
  }

  (String, int) _parseAddress(String input) {
    var value = input.trim();
    if (value.startsWith('http://')) value = value.substring(7);
    if (value.startsWith('https://')) value = value.substring(8);
    value = value.split('/').first;
    final parts = value.split(':');
    if (parts.length != 2) {
      throw SyncException('Укажите адрес в виде 192.168.1.5:12345');
    }
    final host = parts[0].trim();
    final port = int.tryParse(parts[1].trim()) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535) {
      throw SyncException('Некорректный адрес устройства');
    }
    return (host, port);
  }

  Future<SyncPeer> _pairClient(
    String host,
    int port,
    String expectedDeviceId,
    String expectedName,
    Uint8List? expectedPublicKey,
  ) async {
    if (!enabled) throw SyncException('Сначала включите синхронизацию');
    final identity = await _ensureIdentity();
    final staticPublic = await identity.publicKey();
    final ephemeral = await X25519().newKeyPair();
    final ephPublic = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final saltA = syncRandomBytes(16);
    final ts = DateTime.now().millisecondsSinceEpoch;

    final begin = await _postJson(host, port, '/sync/pair/begin', {
      'protocol': syncProtocolVersion,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'ephPub': syncB64(ephPublic),
      'staticPub': syncB64(staticPublic),
      'salt': syncB64(saltA),
      'syncPort': listenerPort,
      'ts': ts,
    });
    if (begin['ok'] == false) {
      throw SyncException(begin['error']?.toString() ?? 'Сопряжение отклонено');
    }
    final pairingId = begin['pairingId']?.toString() ?? '';
    final hostId = begin['deviceId']?.toString() ?? expectedDeviceId;
    final hostName = begin['name']?.toString() ?? expectedName;
    if (hostId != expectedDeviceId) {
      throw SyncException('Устройство не совпадает с найденным');
    }
    final hostEph = syncUnb64(begin['ephPub']?.toString() ?? '');
    final hostStatic = syncUnb64(begin['staticPub']?.toString() ?? '');
    final saltB = syncUnb64(begin['salt']?.toString() ?? '');
    final proof = syncUnb64(begin['proof']?.toString() ?? '');
    if (pairingId.isEmpty ||
        hostId.isEmpty ||
        hostEph.length != 32 ||
        hostStatic.length != 32 ||
        saltB.length != 16) {
      throw SyncException('Некорректный ответ сопряжения');
    }
    if (expectedPublicKey != null &&
        !_sameBytes(hostStatic, expectedPublicKey)) {
      throw SyncException('Ключ устройства не совпадает с найденным');
    }

    final transcript = _pairTranscript(
      clientId: identity.deviceId,
      hostId: hostId,
      clientEph: ephPublic,
      hostEph: hostEph,
      clientStatic: staticPublic,
      hostStatic: hostStatic,
      saltA: saltA,
      saltB: saltB,
    );
    final shared = syncConcat([
      await syncDh(ephemeral, hostEph),
      await syncDh(ephemeral, hostStatic),
      await syncDh(await identity.keyPair(), hostEph),
      await syncDh(await identity.keyPair(), hostStatic),
    ]);
    final salt = syncConcat([saltA, saltB]);
    final keyA2B = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('a2b|'), transcript]),
      32,
    );
    final keyB2A = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('b2a|'), transcript]),
      32,
    );
    final sas = await syncSas(shared, salt, transcript);
    final proofPlain = await SyncCipher.open(
      keyB2A,
      proof,
      syncConcat([transcript, syncUtf8('|begin')]),
    );
    if (utf8.decode(proofPlain) != 'ok') {
      throw SyncException('Сопряжение не подтверждено');
    }

    final session = _PairingSession(
      id: pairingId,
      peerId: hostId,
      peerName: hostName,
      peerStatic: hostStatic,
      peerHost: host,
      peerPort: port,
      keyA2B: keyA2B,
      keyB2A: keyB2A,
      transcript: transcript,
      sas: sas,
      incoming: false,
      expires: DateTime.now().add(const Duration(seconds: 90)),
      decision: Completer<bool>(),
    );
    _pairings[pairingId] = session;
    _promptController.add(
      SyncPairingPrompt(
        pairingId: pairingId,
        deviceId: hostId,
        deviceName: hostName,
        sas: sas,
        incoming: false,
      ),
    );

    bool accepted;
    try {
      accepted = await session.decision!.future.timeout(
        const Duration(seconds: 90),
      );
    } on TimeoutException {
      accepted = false;
    }
    if (!accepted) {
      _pairings.remove(pairingId);
      await _postJson(host, port, '/sync/pair/confirm', {
        'pairingId': pairingId,
        'accepted': false,
      }, ignoreErrors: true);
      throw SyncException('Сопряжение отменено');
    }

    final proofA = await SyncCipher.seal(
      keyA2B,
      syncUtf8('ok'),
      syncConcat([transcript, syncUtf8('|accept')]),
    );
    final confirm = await _postJson(host, port, '/sync/pair/confirm', {
      'pairingId': pairingId,
      'accepted': true,
      'proof': syncB64(proofA),
    });
    if (confirm['accepted'] != true) {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final status = await _postJson(host, port, '/sync/pair/status', {
          'pairingId': pairingId,
        });
        if (status['accepted'] == true) {
          await _storePeer(session);
          final peer = await _rememberAddress(
            _store.peers[hostId]!,
            host,
            port,
          );
          _pairings.remove(pairingId);
          return peer;
        }
        if (status['rejected'] == true || status['expired'] == true) {
          _pairings.remove(pairingId);
          throw SyncException('Сопряжение отклонено');
        }
      }
      _pairings.remove(pairingId);
      throw SyncException('Сопряжение не завершено');
    }

    await _storePeer(session);
    final peer = await _rememberAddress(_store.peers[hostId]!, host, port);
    _pairings.remove(pairingId);
    return peer;
  }

  Future<SyncPeer> _rememberAddress(
    SyncPeer peer,
    String host,
    int port,
  ) async {
    peer.lastHost = host;
    peer.lastPort = port;
    await _store.savePeers();
    return peer;
  }

  bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Uint8List _pairTranscript({
    required String clientId,
    required String hostId,
    required Uint8List clientEph,
    required Uint8List hostEph,
    required Uint8List clientStatic,
    required Uint8List hostStatic,
    required Uint8List saltA,
    required Uint8List saltB,
  }) => syncUtf8(
    [
      syncMagic,
      'pair',
      clientId,
      hostId,
      syncB64(clientEph),
      syncB64(hostEph),
      syncB64(clientStatic),
      syncB64(hostStatic),
      syncB64(saltA),
      syncB64(saltB),
    ].join('|'),
  );

  Uint8List _exchangeTranscript({
    required String clientId,
    required String hostId,
    required Uint8List clientEph,
    required Uint8List hostEph,
    required Uint8List clientStatic,
    required Uint8List hostStatic,
    required int clientTs,
    required int hostTs,
  }) => syncUtf8(
    [
      syncMagic,
      'exchange',
      clientId,
      hostId,
      syncB64(clientEph),
      syncB64(hostEph),
      syncB64(clientStatic),
      syncB64(hostStatic),
      '$clientTs',
      '$hostTs',
    ].join('|'),
  );

  Future<void> _storePeer(_PairingSession session) async {
    final port = session.peerPort;
    final validPort = port != null && port > 0 && port <= 65535 ? port : null;
    _store.peers[session.peerId] = SyncPeer(
      deviceId: session.peerId,
      name: session.peerName,
      publicKey: session.peerStatic,
      lastSync: _store.peers[session.peerId]?.lastSync,
      lastHost: session.peerHost ?? _store.peers[session.peerId]?.lastHost,
      lastPort: validPort ?? _store.peers[session.peerId]?.lastPort,
    );
    await _store.savePeers();
    notifyListeners();
  }

  Future<void> acceptPairing(SyncPairingPrompt prompt) async {
    final session = _pairings[prompt.pairingId];
    if (session == null || session.expired) return;
    if (session.incoming) {
      session.hostDecision = true;
      if (session.clientConfirmed) {
        await _storePeer(session);
        session.accepted = true;
      }
      notifyListeners();
    } else {
      final decision = session.decision;
      if (decision != null && !decision.isCompleted) decision.complete(true);
    }
  }

  Future<void> declinePairing(SyncPairingPrompt prompt) async {
    final session = _pairings[prompt.pairingId];
    if (session == null) return;
    if (session.incoming) {
      session.hostDecision = false;
      _pairings.remove(session.id);
      notifyListeners();
    } else {
      final decision = session.decision;
      if (decision != null && !decision.isCompleted) decision.complete(false);
    }
  }

  Future<void> forgetPeer(String deviceId) async {
    _store.peers.remove(deviceId);
    await _store.savePeers();
    notifyListeners();
  }

  Future<SyncRunResult> syncNow({bool auto = false}) async {
    if (!enabled) {
      throw SyncException('Сначала включите синхронизацию');
    }
    if (_syncing) {
      return const SyncRunResult(errors: ['Синхронизация уже идёт']);
    }
    _syncing = true;
    notifyListeners();
    try {
      await startListener();
      if (!auto) {
        await scan();
      } else {
        await _discovery?.scan();
      }
      final targets = <String, SyncPeer>{};
      for (final peer in _store.peers.values) {
        final found = _discovered[peer.deviceId];
        if (found != null) {
          peer.lastHost = found.host;
          peer.lastPort = found.port;
          targets[peer.deviceId] = peer;
        }
      }
      for (final peer in _store.peers.values) {
        if (targets.containsKey(peer.deviceId)) continue;
        if (peer.hasAddress) targets[peer.deviceId] = peer;
      }

      var result = const SyncRunResult();
      for (final peer in targets.values) {
        try {
          final applied = await _exchangeWith(peer);
          result =
              result +
              SyncRunResult(
                devices: 1,
                chatsAdded: applied.chatsAdded,
                chatsUpdated: applied.chatsUpdated,
                messagesAdded: applied.messagesAdded,
                messagesMerged: applied.messagesMerged,
                serversAdded: applied.serversAdded,
              );
        } catch (error) {
          result = result + SyncRunResult(errors: ['${peer.name}: $error']);
        }
      }
      await _store.savePeers();
      AppLog.instance.info(
        'Синхронизация',
        detail: '${result.devices} устройств · ${result.summary}',
      );
      return result;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<SyncMergeResult> _exchangeWith(SyncPeer peer) async {
    final host = peer.lastHost;
    final port = peer.lastPort;
    if (host == null || port == null) {
      throw SyncException('Адрес устройства неизвестен');
    }
    final identity = await _ensureIdentity();
    final staticPublic = await identity.publicKey();
    final ephemeral = await X25519().newKeyPair();
    final ephPublic = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final clientTs = DateTime.now().millisecondsSinceEpoch;
    final begin = await _postJson(host, port, '/sync/exchange/begin', {
      'protocol': syncProtocolVersion,
      'deviceId': identity.deviceId,
      'ephPub': syncB64(ephPublic),
      'ts': clientTs,
    });
    if (begin['ok'] == false) {
      throw SyncException(
        begin['error']?.toString() ?? 'Устройство недоступно',
      );
    }
    final sessionId = begin['sessionId']?.toString() ?? '';
    final hostEph = syncUnb64(begin['ephPub']?.toString() ?? '');
    final hostTs = (begin['ts'] as num?)?.toInt() ?? 0;
    final proof = syncUnb64(begin['proof']?.toString() ?? '');
    if (sessionId.isEmpty || hostEph.length != 32 || proof.isEmpty) {
      throw SyncException('Некорректный ответ устройства');
    }

    final transcript = _exchangeTranscript(
      clientId: identity.deviceId,
      hostId: peer.deviceId,
      clientEph: ephPublic,
      hostEph: hostEph,
      clientStatic: staticPublic,
      hostStatic: peer.publicKey,
      clientTs: clientTs,
      hostTs: hostTs,
    );
    final shared = syncConcat([
      await syncDh(ephemeral, hostEph),
      await syncDh(await identity.keyPair(), peer.publicKey),
    ]);
    final salt = syncConcat([ephPublic, hostEph]);
    final requestKey = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('c2h|'), transcript]),
      32,
    );
    final responseKey = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('h2c|'), transcript]),
      32,
    );
    final proofPlain = await SyncCipher.open(
      responseKey,
      proof,
      syncConcat([transcript, syncUtf8('|begin')]),
    );
    if (utf8.decode(proofPlain) != 'ok') {
      throw SyncException('Устройство не подтвердило ключ');
    }

    final bundle = await buildBundle(identity);
    final sealed = await SyncCipher.seal(
      requestKey,
      bundle.encode(),
      syncConcat([transcript, syncUtf8('|request')]),
    );
    final response = await _postBytes(
      host,
      port,
      '/sync/exchange',
      sealed,
      sessionId,
    );
    final plain = await SyncCipher.open(
      responseKey,
      response,
      syncConcat([transcript, syncUtf8('|response')]),
    );
    final remote = SyncBundle.decode(plain);
    final applied = await applyBundle(remote);
    peer.lastSync = DateTime.now();
    peer.lastHost = host;
    peer.lastPort = port;
    return applied;
  }

  String peerStatusLabel(String deviceId) {
    final found = _discovered[deviceId];
    if (found == null) return 'не в сети';
    return 'найден';
  }

  Future<Map<String, dynamic>> _getJson(
    String host,
    int port,
    String path, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final response = await _http
        .get(Uri.parse('http://$host:$port$path'))
        .timeout(timeout);
    return _decodeResponse(response);
  }

  Future<Map<String, dynamic>> _postJson(
    String host,
    int port,
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 10),
    bool ignoreErrors = false,
  }) async {
    final response = await _http
        .post(
          Uri.parse('http://$host:$port$path'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (ignoreErrors && response.statusCode != 200) {
      return const {'ok': false};
    }
    return _decodeResponse(response);
  }

  Future<Uint8List> _postBytes(
    String host,
    int port,
    String path,
    Uint8List body,
    String sessionId,
  ) async {
    final request = http.Request('POST', Uri.parse('http://$host:$port$path'))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..headers['X-Sync-Session'] = sessionId
      ..bodyBytes = body;
    final response = await _http
        .send(request)
        .timeout(const Duration(seconds: 90));
    final bytes = await response.stream.toBytes();
    if (response.statusCode != 200) {
      var message = 'Ошибка устройства ${response.statusCode}';
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map && decoded['error'] != null) {
          message = decoded['error'].toString();
        }
      } catch (_) {
        // Keep the generic message.
      }
      throw SyncException(message);
    }
    return Uint8List.fromList(bytes);
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    Map<String, dynamic> decoded = const {};
    if (response.body.trim().isNotEmpty) {
      try {
        final value = jsonDecode(response.body);
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {
        // A non-JSON answer is reported below.
      }
    }
    if (response.statusCode != 200 || decoded['ok'] == false) {
      final error = decoded['error']?.toString();
      throw SyncException(
        error == null || error.isEmpty
            ? 'Устройство ответило ошибкой ${response.statusCode}'
            : error,
      );
    }
    return decoded;
  }

  Future<SyncIdentity> _ensureIdentity() async {
    final identity = await _store.ensureIdentity();
    notifyListeners();
    return identity;
  }

  @override
  Future<Map<String, dynamic>> handlePairBegin(
    Map<String, dynamic> body,
  ) async {
    if (!enabled) throw SyncException('Синхронизация выключена');
    _prunePairings();
    final identity = await _ensureIdentity();
    final clientId = body['deviceId']?.toString() ?? '';
    final rawName = body['name']?.toString() ?? 'Устройство';
    final clientName = rawName.length <= 80
        ? rawName
        : rawName.substring(0, 80);
    final eph = syncUnb64(body['ephPub']?.toString() ?? '');
    final staticPub = syncUnb64(body['staticPub']?.toString() ?? '');
    final saltA = syncUnb64(body['salt']?.toString() ?? '');
    final ts = (body['ts'] as num?)?.toInt() ?? 0;
    if (body['protocol'] != syncProtocolVersion) {
      throw SyncException('Несовместимая версия синхронизации');
    }
    if (clientId.isEmpty ||
        clientId == identity.deviceId ||
        eph.length != 32 ||
        staticPub.length != 32 ||
        saltA.length != 16 ||
        _oldTimestamp(ts)) {
      throw SyncException('Некорректный запрос сопряжения');
    }
    if (_store.peers.containsKey(clientId)) {
      throw SyncException('Устройство уже сопряжено');
    }
    final pendingIncoming = _pairings.values
        .where((session) => session.incoming)
        .length;
    if (pendingIncoming >= 3) {
      throw SyncException('Слишком много запросов сопряжения');
    }
    final pendingFromDevice = _pairings.values.any(
      (session) => session.incoming && session.peerId == clientId,
    );
    if (pendingFromDevice) {
      throw SyncException('Сопряжение уже запрошено');
    }

    final hostEphPair = await X25519().newKeyPair();
    final hostEph = Uint8List.fromList(
      (await hostEphPair.extractPublicKey()).bytes,
    );
    final saltB = syncRandomBytes(16);
    final hostStatic = await identity.publicKey();
    final transcript = _pairTranscript(
      clientId: clientId,
      hostId: identity.deviceId,
      clientEph: eph,
      hostEph: hostEph,
      clientStatic: staticPub,
      hostStatic: hostStatic,
      saltA: saltA,
      saltB: saltB,
    );
    final hostKeyPair = await identity.keyPair();
    final shared = syncConcat([
      await syncDh(hostEphPair, eph),
      await syncDh(hostKeyPair, eph),
      await syncDh(hostEphPair, staticPub),
      await syncDh(hostKeyPair, staticPub),
    ]);
    final salt = syncConcat([saltA, saltB]);
    final keyA2B = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('a2b|'), transcript]),
      32,
    );
    final keyB2A = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('b2a|'), transcript]),
      32,
    );
    final sas = await syncSas(shared, salt, transcript);
    final pairingId = syncRandomId();
    final proof = await SyncCipher.seal(
      keyB2A,
      syncUtf8('ok'),
      syncConcat([transcript, syncUtf8('|begin')]),
    );
    final session = _PairingSession(
      id: pairingId,
      peerId: clientId,
      peerName: clientName,
      peerStatic: staticPub,
      peerHost: body['_remoteAddress']?.toString(),
      peerPort: (body['syncPort'] as num?)?.toInt(),
      keyA2B: keyA2B,
      keyB2A: keyB2A,
      transcript: transcript,
      sas: sas,
      incoming: true,
      expires: DateTime.now().add(const Duration(seconds: 90)),
    );
    _pairings[pairingId] = session;
    _promptController.add(
      SyncPairingPrompt(
        pairingId: pairingId,
        deviceId: clientId,
        deviceName: clientName,
        sas: sas,
        incoming: true,
      ),
    );
    notifyListeners();
    return {
      'ok': true,
      'pairingId': pairingId,
      'protocol': syncProtocolVersion,
      'deviceId': identity.deviceId,
      'name': identity.name,
      'ephPub': syncB64(hostEph),
      'staticPub': syncB64(hostStatic),
      'salt': syncB64(saltB),
      'proof': syncB64(proof),
    };
  }

  @override
  Future<Map<String, dynamic>> handlePairConfirm(
    Map<String, dynamic> body,
  ) async {
    _prunePairings();
    final pairingId = body['pairingId']?.toString() ?? '';
    final session = _pairings[pairingId];
    if (session == null || session.expired) {
      return const {'ok': true, 'accepted': false, 'expired': true};
    }
    final accepted = body['accepted'] == true;
    if (!accepted) {
      session.hostDecision = false;
      _pairings.remove(pairingId);
      return const {'ok': true, 'accepted': false};
    }
    final proof = syncUnb64(body['proof']?.toString() ?? '');
    final plain = await SyncCipher.open(
      session.keyA2B,
      proof,
      syncConcat([session.transcript, syncUtf8('|accept')]),
    );
    if (utf8.decode(plain) != 'ok') {
      throw SyncException('Сопряжение не подтверждено');
    }
    session.clientConfirmed = true;
    if (session.hostDecision == true) {
      await _storePeer(session);
      session.accepted = true;
      return const {'ok': true, 'accepted': true};
    }
    return const {'ok': true, 'accepted': false, 'pending': true};
  }

  @override
  Future<Map<String, dynamic>> handlePairStatus(
    Map<String, dynamic> body,
  ) async {
    _prunePairings();
    final pairingId = body['pairingId']?.toString() ?? '';
    final session = _pairings[pairingId];
    if (session == null || session.expired) {
      return const {'ok': true, 'accepted': false, 'expired': true};
    }
    if (session.hostDecision == false) {
      return const {'ok': true, 'accepted': false, 'rejected': true};
    }
    if (session.accepted ||
        (session.hostDecision == true && session.clientConfirmed)) {
      return const {'ok': true, 'accepted': true};
    }
    return const {'ok': true, 'accepted': false, 'pending': true};
  }

  @override
  Future<Map<String, dynamic>> handleExchangeBegin(
    Map<String, dynamic> body,
  ) async {
    _pruneExchanges();
    final identity = await _ensureIdentity();
    final clientId = body['deviceId']?.toString() ?? '';
    final peer = _store.peers[clientId];
    if (peer == null) throw SyncException('Устройство не сопряжено');
    if (body['protocol'] != syncProtocolVersion) {
      throw SyncException('Несовместимая версия синхронизации');
    }
    final clientEph = syncUnb64(body['ephPub']?.toString() ?? '');
    final clientTs = (body['ts'] as num?)?.toInt() ?? 0;
    if (clientEph.length != 32 || _oldTimestamp(clientTs)) {
      throw SyncException('Некорректный запрос синхронизации');
    }
    final hostEphPair = await X25519().newKeyPair();
    final hostEph = Uint8List.fromList(
      (await hostEphPair.extractPublicKey()).bytes,
    );
    final hostStatic = await identity.publicKey();
    final hostTs = DateTime.now().millisecondsSinceEpoch;
    final transcript = _exchangeTranscript(
      clientId: clientId,
      hostId: identity.deviceId,
      clientEph: clientEph,
      hostEph: hostEph,
      clientStatic: peer.publicKey,
      hostStatic: hostStatic,
      clientTs: clientTs,
      hostTs: hostTs,
    );
    final shared = syncConcat([
      await syncDh(hostEphPair, clientEph),
      await syncDh(await identity.keyPair(), peer.publicKey),
    ]);
    final salt = syncConcat([clientEph, hostEph]);
    final requestKey = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('c2h|'), transcript]),
      32,
    );
    final responseKey = await syncDerive(
      shared,
      salt,
      syncConcat([syncUtf8('h2c|'), transcript]),
      32,
    );
    final sessionId = syncRandomId();
    _exchanges[sessionId] = _ExchangeSession(
      peerId: clientId,
      requestKey: requestKey,
      responseKey: responseKey,
      transcript: transcript,
      expires: DateTime.now().add(const Duration(seconds: 90)),
    );
    final proof = await SyncCipher.seal(
      responseKey,
      syncUtf8('ok'),
      syncConcat([transcript, syncUtf8('|begin')]),
    );
    return {
      'ok': true,
      'sessionId': sessionId,
      'ephPub': syncB64(hostEph),
      'ts': hostTs,
      'proof': syncB64(proof),
    };
  }

  @override
  Future<Uint8List> handleExchange(String sessionId, Uint8List sealed) async {
    _pruneExchanges();
    final session = _exchanges[sessionId];
    if (session == null || session.expires.isBefore(DateTime.now())) {
      throw SyncException('Сессия синхронизации истекла');
    }
    _exchanges.remove(sessionId);
    final plain = await SyncCipher.open(
      session.requestKey,
      sealed,
      syncConcat([session.transcript, syncUtf8('|request')]),
    );
    final remote = SyncBundle.decode(plain);
    await applyBundle(remote);
    final peer = _store.peers[session.peerId];
    if (peer != null) {
      peer.lastSync = DateTime.now();
      await _store.savePeers();
    }
    final identity = await _ensureIdentity();
    final local = await buildBundle(identity);
    final response = await SyncCipher.seal(
      session.responseKey,
      local.encode(),
      syncConcat([session.transcript, syncUtf8('|response')]),
    );
    return response;
  }

  bool _oldTimestamp(int millis) {
    if (millis <= 0) return true;
    final time = DateTime.fromMillisecondsSinceEpoch(millis);
    return DateTime.now().difference(time).abs() > const Duration(minutes: 2);
  }

  void _prunePairings() {
    final now = DateTime.now();
    _pairings.removeWhere((_, session) => session.expires.isBefore(now));
  }

  void _pruneExchanges() {
    final now = DateTime.now();
    _exchanges.removeWhere((_, session) => session.expires.isBefore(now));
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopListener());
    for (final session in _pairings.values) {
      final decision = session.decision;
      if (decision != null && !decision.isCompleted) decision.complete(false);
    }
    _pairings.clear();
    _promptController.close();
    _http.close();
    super.dispose();
  }
}

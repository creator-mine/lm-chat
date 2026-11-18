import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../secret_store.dart';
import 'crypto.dart';

class SyncSettings {
  SyncSettings({this.enabled = false, this.autoStart = true});

  bool enabled;
  bool autoStart;

  Map<String, dynamic> toJson() => {'enabled': enabled, 'autoStart': autoStart};

  factory SyncSettings.fromJson(Map<String, dynamic> json) => SyncSettings(
    enabled: json['enabled'] == true,
    autoStart: json['autoStart'] != false,
  );
}

class SyncStore {
  SyncStore({Future<Directory> Function()? directory, SecretStore? secretStore})
    : _directoryOverride = directory,
      _secretStore = secretStore ?? SecureSecretStore();

  final Future<Directory> Function()? _directoryOverride;
  final SecretStore _secretStore;

  static const String _identitySecretKey = 'sync.identity';

  late Directory directory;
  SyncIdentity? identity;
  SyncSettings settings = SyncSettings();
  final Map<String, SyncPeer> peers = {};

  File get _identityFile => File('${directory.path}/identity.json');
  File get _settingsFile => File('${directory.path}/settings.json');
  File get _peersFile => File('${directory.path}/peers.json');

  Future<void> load() async {
    final base =
        await (_directoryOverride?.call() ?? getApplicationSupportDirectory());
    directory = Directory('${base.path}/sync');
    await directory.create(recursive: true);

    if (await _identityFile.exists()) {
      try {
        final json = jsonDecode(await _identityFile.readAsString());
        if (json is Map<String, dynamic>) {
          identity = SyncIdentity.fromJson(json);
        }
      } catch (_) {
        // A damaged identity is replaced on the next enable.
        identity = null;
      }
    }

    // Prefer the platform keystore. An identity from an older build is moved
    // out of the plaintext file on first load.
    var secureIdentity = false;
    try {
      final raw = await _secretStore.readSecret(_identitySecretKey);
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          final loaded = SyncIdentity.fromJson(json);
          identity = loaded;
          secureIdentity = true;
        }
      }
    } catch (_) {
      // No secure store available for this build/device.
    }
    if (!secureIdentity && identity != null) {
      try {
        await _secretStore.writeSecret(
          _identitySecretKey,
          jsonEncode(identity!.toJson()),
        );
        if (await _identityFile.exists()) await _identityFile.delete();
      } catch (_) {
        // Keep the file fallback when the keystore is unavailable.
      }
    }
    if (await _settingsFile.exists()) {
      try {
        final json = jsonDecode(await _settingsFile.readAsString());
        if (json is Map<String, dynamic>) {
          settings = SyncSettings.fromJson(json);
        }
      } catch (_) {
        settings = SyncSettings();
      }
    }
    if (await _peersFile.exists()) {
      try {
        final json = jsonDecode(await _peersFile.readAsString());
        final list = json is Map ? json['peers'] : null;
        if (list is List) {
          for (final item in list) {
            if (item is! Map) continue;
            final peer = SyncPeer.fromJson(Map<String, dynamic>.from(item));
            if (peer.deviceId.isNotEmpty && peer.publicKey.length == 32) {
              peers[peer.deviceId] = peer;
            }
          }
        }
      } catch (_) {
        // Ignore a damaged peer list; pairing can be repeated.
      }
    }
  }

  Future<SyncIdentity> ensureIdentity() async {
    final current = identity;
    if (current != null) return current;

    final name = Platform.isAndroid
        ? 'Телефон'
        : (Platform.localHostname.trim().isEmpty
              ? 'Компьютер'
              : Platform.localHostname.trim());
    final created = SyncIdentity(
      deviceId: syncRandomId(),
      name: name,
      seed: syncRandomBytes(32),
    );
    identity = created;
    await saveIdentity();
    return created;
  }

  Future<void> saveIdentity() async {
    final value = identity;
    if (value == null) return;
    final payload = jsonEncode(value.toJson());
    try {
      await _secretStore.writeSecret(_identitySecretKey, payload);
      if (await _identityFile.exists()) await _identityFile.delete();
    } catch (_) {
      // Keep the file fallback when the keystore is unavailable.
      await _write(_identityFile, payload);
    }
  }

  Future<void> saveSettings() async {
    await _write(_settingsFile, jsonEncode(settings.toJson()));
  }

  Future<void> savePeers() async {
    await _write(
      _peersFile,
      jsonEncode({'peers': peers.values.map((peer) => peer.toJson()).toList()}),
    );
  }

  Future<void> _write(File file, String content) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      // Windows does not replace an existing file with rename.
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
  SyncStore({Future<Directory> Function()? directory})
    : _directoryOverride = directory;

  final Future<Directory> Function()? _directoryOverride;

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
    await _write(_identityFile, jsonEncode(value.toJson()));
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

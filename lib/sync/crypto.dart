import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// LAN sync protocol version.
const int syncProtocolVersion = 1;
const String syncMagic = 'LMSYNC1';
const int syncMaxBundleBytes = 64 * 1024 * 1024;

class SyncException implements Exception {
  SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

Uint8List syncRandomBytes(int length) {
  final random = Random.secure();
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

String syncB64(List<int> bytes) => base64Encode(bytes);

Uint8List syncUnb64(String value) {
  try {
    return Uint8List.fromList(base64Decode(value));
  } on FormatException {
    throw SyncException('Некорректные данные синхронизации');
  }
}

String syncRandomId() => syncRandomBytes(8).map(_hex).join();

String syncShortId(String deviceId) {
  final value = deviceId.replaceAll('-', '');
  return value.length <= 6
      ? value.toUpperCase()
      : value.substring(0, 6).toUpperCase();
}

/// Stable per-install identity of this app.
class SyncIdentity {
  SyncIdentity({
    required this.deviceId,
    required this.name,
    required this.seed,
  });

  final String deviceId;
  String name;

  /// 32-byte X25519 private seed. Kept in the app's private directory.
  final Uint8List seed;

  SimpleKeyPair? _keyPair;
  Uint8List? _publicKey;

  Future<SimpleKeyPair> keyPair() async =>
      _keyPair ??= await X25519().newKeyPairFromSeed(seed);

  Future<Uint8List> publicKey() async {
    final cached = _publicKey;
    if (cached != null) return cached;
    final key = await (await keyPair()).extractPublicKey();
    return _publicKey = Uint8List.fromList(key.bytes);
  }

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'seed': syncB64(seed),
  };

  factory SyncIdentity.fromJson(Map<String, dynamic> json) {
    final seed = syncUnb64(json['seed'] as String? ?? '');
    if (seed.length != 32) {
      throw SyncException('Повреждён ключ синхронизации');
    }
    return SyncIdentity(
      deviceId:
          json['deviceId'] as String? ?? syncRandomBytes(8).map(_hex).join(),
      name: json['name'] as String? ?? 'Устройство',
      seed: seed,
    );
  }
}

class SyncPeer {
  SyncPeer({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    this.lastSync,
    this.lastHost,
    this.lastPort,
  });

  final String deviceId;
  String name;
  Uint8List publicKey;
  DateTime? lastSync;
  String? lastHost;
  int? lastPort;

  bool get hasAddress =>
      lastHost != null &&
      lastHost!.isNotEmpty &&
      lastPort != null &&
      lastPort! > 0;

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'name': name,
    'publicKey': syncB64(publicKey),
    if (lastSync != null) 'lastSync': lastSync!.toIso8601String(),
    if (lastHost != null) 'lastHost': lastHost,
    if (lastPort != null) 'lastPort': lastPort,
  };

  factory SyncPeer.fromJson(Map<String, dynamic> json) => SyncPeer(
    deviceId: json['deviceId'] as String? ?? '',
    name: json['name'] as String? ?? 'Устройство',
    publicKey: syncUnb64(json['publicKey'] as String? ?? ''),
    lastSync: DateTime.tryParse(json['lastSync'] as String? ?? ''),
    lastHost: json['lastHost'] as String?,
    lastPort: (json['lastPort'] as num?)?.toInt(),
  );
}

String _hex(int value) => value.toRadixString(16).padLeft(2, '0');

Future<Uint8List> syncDh(
  SimpleKeyPair privateKeyPair,
  Uint8List peerPublic,
) async {
  try {
    final secret = await X25519().sharedSecretKey(
      keyPair: privateKeyPair,
      remotePublicKey: SimplePublicKey(peerPublic, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  } catch (_) {
    throw SyncException('Не удалось согласовать ключ синхронизации');
  }
}

Future<Uint8List> syncDerive(
  Uint8List secret,
  Uint8List salt,
  List<int> info,
  int length,
) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(secret),
    nonce: salt,
    info: info,
  );
  return Uint8List.fromList(await key.extractBytes());
}

Uint8List syncConcat(List<Uint8List> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}

Uint8List syncUtf8(String value) => Uint8List.fromList(utf8.encode(value));

/// Eight-digit short authentication string. Both sides must see the same
/// value; a MITM produces different shared secrets and therefore different
/// digits.
Future<String> syncSas(
  Uint8List shared,
  Uint8List salt,
  Uint8List transcript,
) async {
  final bytes = await syncDerive(
    shared,
    salt,
    syncConcat([syncUtf8('sas|'), transcript]),
    4,
  );
  final value = ByteData.sublistView(bytes).getUint32(0) % 100000000;
  final text = value.toString().padLeft(8, '0');
  return '${text.substring(0, 4)} ${text.substring(4)}';
}

class SyncCipher {
  static Future<Uint8List> seal(
    Uint8List key,
    List<int> plain,
    List<int> aad,
  ) async {
    final nonce = syncRandomBytes(12);
    final box = await AesGcm.with256bits().encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> open(
    Uint8List key,
    Uint8List sealed,
    List<int> aad,
  ) async {
    const tagSize = 16;
    if (sealed.length < 12 + tagSize) {
      throw SyncException('Короткий зашифрованный пакет');
    }
    final nonce = sealed.sublist(0, 12);
    final cipherText = sealed.sublist(12, sealed.length - tagSize);
    final mac = sealed.sublist(sealed.length - tagSize);
    try {
      final plain = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(key),
        aad: aad,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw SyncException('Не удалось расшифровать данные синхронизации');
    }
  }
}

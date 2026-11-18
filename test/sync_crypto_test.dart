import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/sync/bundle.dart';
import 'package:lm_chat/sync/crypto.dart';
import 'package:lm_chat/sync/store.dart';

void main() {
  test('two identities derive the same secret and SAS', () async {
    final a = await X25519().newKeyPair();
    final b = await X25519().newKeyPair();
    final aPub = Uint8List.fromList((await a.extractPublicKey()).bytes);
    final bPub = Uint8List.fromList((await b.extractPublicKey()).bytes);

    final sharedA = await syncDh(a, bPub);
    final sharedB = await syncDh(b, aPub);
    expect(sharedA, equals(sharedB));

    final salt = syncRandomBytes(16);
    final transcript = syncUtf8('pair|a|b');
    final sasA = await syncSas(sharedA, salt, transcript);
    final sasB = await syncSas(sharedB, salt, transcript);
    expect(sasA, sasB);
    expect(sasA, matches(RegExp(r'^\d{4} \d{4}$')));

    final other = await X25519().newKeyPair();
    final otherShared = await syncDh(other, aPub);
    expect(await syncSas(otherShared, salt, transcript), isNot(sasA));
  });

  test('cipher round-trips and rejects a tampered packet', () async {
    final key = syncRandomBytes(32);
    final aad = syncUtf8('aad');
    final plain = Uint8List.fromList(List<int>.generate(1024, (i) => i % 251));
    final sealed = await SyncCipher.seal(key, plain, aad);
    final opened = await SyncCipher.open(key, sealed, aad);
    expect(opened, equals(plain));

    sealed[sealed.length - 1] ^= 0xff;
    await expectLater(
      SyncCipher.open(key, sealed, aad),
      throwsA(isA<SyncException>()),
    );
  });

  test('cipher rejects a wrong associated data value', () async {
    final key = syncRandomBytes(32);
    final sealed = await SyncCipher.seal(key, [1, 2, 3], syncUtf8('one'));
    await expectLater(
      SyncCipher.open(key, sealed, syncUtf8('two')),
      throwsA(isA<SyncException>()),
    );
  });

  test('the store creates, persists and reloads an identity', () async {
    final dir = await Directory.systemTemp.createTemp('lm-chat-sync-store');
    addTearDown(() => dir.delete(recursive: true));

    final store = SyncStore(directory: () async => dir);
    await store.load();
    final identity = await store.ensureIdentity();
    expect(identity.deviceId, isNotEmpty);
    expect(identity.seed, hasLength(32));
    final publicKey = await identity.publicKey();
    expect(publicKey, hasLength(32));

    store.peers['peer'] = SyncPeer(
      deviceId: 'peer',
      name: 'Peer',
      publicKey: Uint8List.fromList(List<int>.filled(32, 7)),
      lastHost: '192.168.1.5',
      lastPort: 12345,
    );
    store.settings.enabled = true;
    await store.saveSettings();
    await store.savePeers();

    final reloaded = SyncStore(directory: () async => dir);
    await reloaded.load();
    expect(reloaded.identity!.deviceId, identity.deviceId);
    expect(reloaded.identity!.name, identity.name);
    expect(reloaded.settings.enabled, isTrue);
    expect(reloaded.peers['peer']!.name, 'Peer');
    expect(reloaded.peers['peer']!.lastPort, 12345);
  });

  test('short ids are stable and readable', () {
    expect(syncShortId('abcdef0123456789'), 'ABCDEF');
    expect(syncShortId('abc'), 'ABC');
  });

  test('a gzip bomb in a sync bundle is rejected before it expands', () {
    final bomb = Uint8List.fromList(gzip.encode(Uint8List(70 * 1024 * 1024)));
    expect(() => SyncBundle.decode(bomb), throwsA(isA<SyncException>()));
  });
}

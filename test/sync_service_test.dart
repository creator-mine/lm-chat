import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/sync/bundle.dart';
import 'package:lm_chat/sync/crypto.dart';
import 'package:lm_chat/sync/merge.dart';
import 'package:lm_chat/sync/models.dart';
import 'package:lm_chat/sync/service.dart';
import 'package:lm_chat/sync/store.dart';

AppData dataFor(String name) => AppData(
  servers: [
    ServerConfig(
      id: '$name-server',
      name: name,
      baseUrl: 'http://192.168.1.${name == 'a' ? 5 : 6}:1234',
      apiKey: 'secret-$name',
    ),
  ],
  chats: [
    ChatSession(
      id: '$name-chat',
      title: name,
      serverId: '$name-server',
      messages: [
        ChatMessage(
          id: '$name-message',
          role: 'user',
          content: 'hello from $name',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      ],
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    ),
  ],
);

void main() {
  test('two services pair and exchange chats and servers', () async {
    final dirA = await Directory.systemTemp.createTemp('lm-sync-a');
    final dirB = await Directory.systemTemp.createTemp('lm-sync-b');
    addTearDown(() => dirA.delete(recursive: true));
    addTearDown(() => dirB.delete(recursive: true));

    final dataA = dataFor('a');
    final dataB = dataFor('b');
    final storeA = SyncStore(directory: () async => dirA);
    final storeB = SyncStore(directory: () async => dirB);

    final serviceA = SyncService(
      useDiscovery: false,
      store: storeA,
      buildBundle: (identity) async => SyncBundle.fromData(
        dataA,
        deviceId: identity.deviceId,
        deviceName: identity.name,
      ),
      applyBundle: (bundle) async {
        final result = mergeSyncBundle(
          data: dataA,
          remote: bundle,
          localDeviceId: storeA.identity!.deviceId,
        );
        return result;
      },
    );
    final serviceB = SyncService(
      useDiscovery: false,
      store: storeB,
      buildBundle: (identity) async => SyncBundle.fromData(
        dataB,
        deviceId: identity.deviceId,
        deviceName: identity.name,
      ),
      applyBundle: (bundle) async {
        final result = mergeSyncBundle(
          data: dataB,
          remote: bundle,
          localDeviceId: storeB.identity!.deviceId,
        );
        return result;
      },
    );
    addTearDown(() async {
      await serviceA.stopListener();
      await serviceB.stopListener();
      serviceA.dispose();
      serviceB.dispose();
    });

    final promptsA = <SyncPairingPrompt>[];
    final promptsB = <SyncPairingPrompt>[];
    serviceA.pairingPrompts.listen((prompt) {
      promptsA.add(prompt);
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        serviceA.acceptPairing(prompt);
      });
    });
    serviceB.pairingPrompts.listen((prompt) {
      promptsB.add(prompt);
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        serviceB.acceptPairing(prompt);
      });
    });

    await serviceA.init();
    await serviceB.init();
    await serviceA.setEnabled(true);
    await serviceB.setEnabled(true);

    expect(serviceA.listenerPort, greaterThan(0));
    expect(serviceB.listenerPort, greaterThan(0));

    storeA.peers['fake'] = SyncPeer(
      deviceId: 'fake',
      name: 'Fake',
      publicKey: Uint8List.fromList(List<int>.filled(32, 3)),
      lastHost: '127.0.0.1',
      lastPort: serviceB.listenerPort,
    );
    final denied = await serviceA.syncNow();
    expect(denied.errors, isNotEmpty);
    storeA.peers.remove('fake');
    await storeA.savePeers();

    final paired = await serviceA.pairWithAddress(
      '127.0.0.1:${serviceB.listenerPort}',
    );

    expect(paired.deviceId, serviceB.deviceId);
    expect(serviceA.pairedPeers, hasLength(1));
    expect(serviceB.pairedPeers, hasLength(1));
    expect(serviceB.pairedPeers.single.lastPort, serviceA.listenerPort);
    expect(promptsA, hasLength(1));
    expect(promptsB, hasLength(1));
    expect(promptsA.single.sas, promptsB.single.sas);
    expect(promptsA.single.sas, matches(RegExp(r'^\d{4} \d{4}$')));

    final result = await serviceA.syncNow();
    expect(result.devices, 1);
    expect(result.errors, isEmpty);
    expect(result.chatsAdded, 1);
    expect(result.serversAdded, 1);

    expect(
      dataA.chats.map((chat) => chat.id),
      containsAll(['a-chat', 'b-chat']),
    );
    expect(
      dataB.chats.map((chat) => chat.id),
      containsAll(['a-chat', 'b-chat']),
    );
    expect(dataA.servers.map((server) => server.id), contains('b-server'));
    expect(dataB.servers.map((server) => server.id), contains('a-server'));
    expect(dataA.servers.first.apiKey, 'secret-a');
    expect(dataB.servers.first.apiKey, 'secret-b');
    expect(
      dataA.servers.firstWhere((server) => server.id == 'b-server').apiKey,
      isEmpty,
    );

    final again = await serviceA.syncNow();
    expect(again.changes, isFalse);
    expect(dataA.chats, hasLength(2));
    expect(dataB.chats, hasLength(2));

    final reverse = await serviceB.syncNow();
    expect(reverse.devices, 1);
    expect(reverse.errors, isEmpty);
    expect(reverse.changes, isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

extension on SyncRunResult {
  bool get changes =>
      chatsAdded > 0 ||
      chatsUpdated > 0 ||
      messagesAdded > 0 ||
      messagesMerged > 0 ||
      serversAdded > 0;
}

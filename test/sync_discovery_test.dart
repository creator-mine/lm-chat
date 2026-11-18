import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/sync/crypto.dart';
import 'package:lm_chat/sync/discovery.dart';
import 'package:lm_chat/sync/models.dart';

void main() {
  test(
    'discovery announces and answers a scan without leaking chats',
    () async {
      final identity = SyncIdentity(
        deviceId: 'self',
        name: 'Self',
        seed: syncRandomBytes(32),
      );
      final discovery = SyncDiscovery();
      final peers = <SyncDiscoveredPeer>[];
      final started = await discovery.start(
        httpPort: 55555,
        identity: identity,
        onPeer: peers.add,
        port: 0,
      );
      expect(started, isTrue);
      addTearDown(discovery.stop);
      expect(discovery.port, greaterThan(0));

      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(sender.close);
      final replies = <String>[];
      sender.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = sender.receive();
        if (datagram != null) replies.add(utf8.decode(datagram.data));
      });

      final publicKey = syncB64(List<int>.filled(32, 1));
      sender.send(
        utf8.encode(
          jsonEncode({
            'kind': 'lm-chat-sync',
            'type': 'announce',
            'protocol': syncProtocolVersion,
            'deviceId': 'peer',
            'name': 'Peer',
            'port': 45678,
            'publicKey': publicKey,
          }),
        ),
        InternetAddress.loopbackIPv4,
        discovery.port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(peers, hasLength(1));
      expect(peers.single.deviceId, 'peer');
      expect(peers.single.name, 'Peer');
      expect(peers.single.port, 45678);

      sender.send(
        utf8.encode(
          jsonEncode({
            'kind': 'lm-chat-sync',
            'type': 'discover',
            'protocol': syncProtocolVersion,
            'deviceId': 'seeker',
          }),
        ),
        InternetAddress.loopbackIPv4,
        discovery.port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final announce = replies.firstWhere(
        (reply) => reply.contains('"type":"announce"'),
      );
      expect(announce, contains('"deviceId":"self"'));
      expect(announce, isNot(contains('"chats"')));
      expect(announce, isNot(contains('"messages"')));
    },
  );
}

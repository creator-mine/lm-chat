import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/sync/bundle.dart';
import 'package:lm_chat/sync/merge.dart';

ServerConfig server(String id, String url) => ServerConfig(
  id: id,
  name: id,
  baseUrl: url,
  apiKey: 'secret-api',
  pluginToken: 'secret-plugin',
  bridgeToken: 'secret-bridge',
  relayToken: 'secret-relay',
);

ChatSession chat({
  required String id,
  required String serverId,
  required List<ChatMessage> messages,
  required DateTime updatedAt,
  bool pinned = false,
  bool archived = false,
}) => ChatSession(
  id: id,
  title: 'title-$id',
  serverId: serverId,
  messages: messages,
  updatedAt: updatedAt,
  pinned: pinned,
  archived: archived,
);

ChatMessage message(
  String id,
  String content,
  DateTime createdAt, {
  String role = 'user',
  DateTime? editedAt,
  List<ChatAttachment> attachments = const [],
  String? jobId,
}) => ChatMessage(
  id: id,
  role: role,
  content: content,
  createdAt: createdAt,
  editedAt: editedAt,
  attachments: attachments,
  jobId: jobId,
);

void main() {
  test('merges servers and adds new chats', () {
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [message('m1', 'hello', DateTime.utc(2026, 1, 1))],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    final remoteData = AppData(
      servers: [server('s2', 'http://192.168.1.6:1234')],
      chats: [
        chat(
          id: 'c2',
          serverId: 's2',
          messages: [message('m2', 'remote', DateTime.utc(2026, 1, 2))],
          updatedAt: DateTime.utc(2026, 1, 2),
        ),
      ],
    );
    final remote = SyncBundle.fromData(
      remoteData,
      deviceId: 'remote',
      deviceName: 'Remote',
    );

    final result = mergeSyncBundle(
      data: local,
      remote: remote,
      localDeviceId: 'local',
    );

    expect(result.serversAdded, 1);
    expect(result.chatsAdded, 1);
    expect(local.servers, hasLength(2));
    expect(local.servers.last.id, 's2');
    expect(local.servers.last.apiKey, isEmpty);
    expect(local.servers.last.pluginToken, isEmpty);
    expect(local.chats, hasLength(2));
    expect(local.chats.last.serverId, 's2');
  });

  test('unions messages in the same chat and keeps order', () {
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message('m1', 'one', DateTime.utc(2026, 1, 1, 10)),
            message(
              'm2',
              'two',
              DateTime.utc(2026, 1, 1, 10, 1),
              role: 'assistant',
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 1, 10, 1),
        ),
      ],
    );
    final remoteData = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message('m1', 'one', DateTime.utc(2026, 1, 1, 10)),
            message(
              'm2',
              'two',
              DateTime.utc(2026, 1, 1, 10, 1),
              role: 'assistant',
            ),
            message('m3', 'three', DateTime.utc(2026, 1, 1, 10, 2)),
          ],
          updatedAt: DateTime.utc(2026, 1, 1, 10, 2),
        ),
      ],
    );
    final remote = SyncBundle.fromData(
      remoteData,
      deviceId: 'remote',
      deviceName: 'Remote',
    );

    final result = mergeSyncBundle(
      data: local,
      remote: remote,
      localDeviceId: 'local',
    );

    expect(result.messagesAdded, 1);
    expect(local.chats.single.messages.map((m) => m.id), ['m1', 'm2', 'm3']);
    expect(local.chats.single.updatedAt, DateTime.utc(2026, 1, 1, 10, 2));
    expect(local.chats.single.title, 'title-c1');
  });

  test('newer edit wins and the other text is kept as a version', () {
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message(
              'm2',
              'local text',
              DateTime.utc(2026, 1, 1, 10),
              role: 'assistant',
              editedAt: DateTime.utc(2026, 1, 1, 10, 5),
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 1, 10, 5),
        ),
      ],
    );
    final remoteData = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message(
              'm2',
              'remote text',
              DateTime.utc(2026, 1, 1, 10),
              role: 'assistant',
              editedAt: DateTime.utc(2026, 1, 1, 10, 6),
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 1, 10, 6),
        ),
      ],
    );
    final remote = SyncBundle.fromData(
      remoteData,
      deviceId: 'remote',
      deviceName: 'Remote',
    );

    mergeSyncBundle(data: local, remote: remote, localDeviceId: 'local');

    final merged = local.chats.single.messages.single;
    expect(merged.content, 'remote text');
    expect(merged.versions, hasLength(1));
    expect(merged.versions.single.content, 'local text');
  });

  test('local attachments survive a remote edit and new messages', () {
    final attachment = ChatAttachment(
      id: 'a1',
      mimeType: 'image/png',
      data: 'AAAA',
    );
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message(
              'm1',
              'with image',
              DateTime.utc(2026, 1, 1, 10),
              attachments: [attachment],
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 1, 10),
        ),
      ],
    );
    final remoteData = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message(
              'm1',
              'edited remotely',
              DateTime.utc(2026, 1, 1, 10),
              editedAt: DateTime.utc(2026, 1, 1, 11),
            ),
            message(
              'm2',
              'new',
              DateTime.utc(2026, 1, 1, 11, 1),
              role: 'assistant',
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 1, 11, 1),
        ),
      ],
    );
    final remote = SyncBundle.fromData(
      remoteData,
      deviceId: 'remote',
      deviceName: 'Remote',
    );

    mergeSyncBundle(data: local, remote: remote, localDeviceId: 'local');

    final merged = local.chats.single.messages.first;
    expect(merged.content, 'edited remotely');
    expect(merged.attachments, hasLength(1));
    expect(merged.attachments.single.id, 'a1');
    expect(local.chats.single.messages, hasLength(2));
  });

  test('bundle keeps attachments but omits secrets and pending jobs', () {
    final data = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message('m1', 'pending', DateTime.utc(2026, 1, 1), jobId: 'job-1'),
          ],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
        chat(
          id: 'c2',
          serverId: 's1',
          messages: [
            message(
              'm2',
              'image',
              DateTime.utc(2026, 1, 2),
              attachments: [
                ChatAttachment(id: 'a1', mimeType: 'image/png', data: 'AAAA'),
              ],
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 2),
        ),
      ],
    );

    final bundle = SyncBundle.fromData(
      data,
      deviceId: 'local',
      deviceName: 'Local',
    );
    final json = bundle.toJson();

    expect(json['servers'], hasLength(1));
    expect(json['chats'], hasLength(1));
    final serverJson = (json['servers'] as List).single as Map;
    expect(serverJson.containsKey('apiKey'), isFalse);
    expect(serverJson.containsKey('pluginToken'), isFalse);
    expect(serverJson.containsKey('bridgeToken'), isFalse);
    expect(serverJson.containsKey('relayToken'), isFalse);
    final chatJson = (json['chats'] as List).single as Map;
    final messageJson = (chatJson['messages'] as List).single as Map;
    expect(messageJson.containsKey('attachments'), isTrue);
    final attachment = (messageJson['attachments'] as List).single as Map;
    expect(attachment['data'], 'AAAA');
    expect(messageJson.containsKey('jobId'), isFalse);
  });

  test('merging the same bundle twice changes nothing', () {
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [message('m1', 'one', DateTime.utc(2026, 1, 1))],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    final remote = SyncBundle.fromData(
      AppData(
        servers: [server('s2', 'http://192.168.1.6:1234')],
        chats: [
          chat(
            id: 'c2',
            serverId: 's2',
            messages: [message('m2', 'two', DateTime.utc(2026, 1, 2))],
            updatedAt: DateTime.utc(2026, 1, 2),
          ),
        ],
      ),
      deviceId: 'remote',
      deviceName: 'Remote',
    );

    final first = mergeSyncBundle(
      data: local,
      remote: remote,
      localDeviceId: 'local',
    );
    final second = mergeSyncBundle(
      data: local,
      remote: remote,
      localDeviceId: 'local',
    );

    expect(first.changed, isTrue);
    expect(second.changed, isFalse);
    expect(local.chats, hasLength(2));
    expect(local.servers, hasLength(2));
  });

  test('server ids in chats are remapped to the local server', () {
    final local = AppData(
      servers: [server('local-server', 'http://192.168.1.5:1234')],
    );
    final remoteData = AppData(
      servers: [server('remote-server', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 'remote-server',
          messages: [message('m1', 'one', DateTime.utc(2026, 1, 1))],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    final remote = SyncBundle.fromData(
      remoteData,
      deviceId: 'remote',
      deviceName: 'Remote',
    );

    mergeSyncBundle(data: local, remote: remote, localDeviceId: 'local');

    expect(local.servers, hasLength(1));
    expect(local.chats.single.serverId, 'local-server');
  });

  test('SyncBundle round-trips and rejects foreign files', () {
    final bundle = SyncBundle(
      deviceId: 'd1',
      deviceName: 'D1',
      exportedAt: DateTime.utc(2026, 1, 1),
      servers: const [],
      chats: const [],
    );
    final decoded = SyncBundle.decode(bundle.encode());
    expect(decoded.deviceId, 'd1');
    expect(decoded.deviceName, 'D1');
    expect(
      () => SyncBundle.fromJson(<String, dynamic>{'kind': 'other'}),
      throwsA(isA<Exception>()),
    );
  });

  test('empty bundles do not mutate data', () {
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [message('m1', 'one', DateTime.utc(2026, 1, 1))],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    final bundle = SyncBundle(
      deviceId: 'remote',
      deviceName: 'Remote',
      exportedAt: DateTime.utc(2026, 1, 1),
      servers: const [],
      chats: const [],
    );

    final result = mergeSyncBundle(
      data: local,
      remote: bundle,
      localDeviceId: 'local',
    );
    expect(result.changed, isFalse);
    expect(local.chats, hasLength(1));
  });

  test('image attachments survive the bundle and merge', () {
    final local = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: <ChatSession>[],
    );
    final attachment = ChatAttachment(
      id: 'image-1',
      mimeType: 'image/png',
      data: 'aGVsbG8=',
      name: 'hello.png',
    );
    final remoteData = AppData(
      servers: [server('s1', 'http://192.168.1.5:1234')],
      chats: [
        chat(
          id: 'c1',
          serverId: 's1',
          messages: [
            message(
              'm1',
              'look',
              DateTime.utc(2026, 1, 1),
              attachments: [attachment],
            ),
          ],
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    final bundle = SyncBundle.decode(
      SyncBundle.fromData(
        remoteData,
        deviceId: 'remote',
        deviceName: 'Remote',
      ).encode(),
    );

    final result = mergeSyncBundle(
      data: local,
      remote: bundle,
      localDeviceId: 'local',
    );

    expect(result.chatsAdded, 1);
    final copied = local.chats.single.messages.single.attachments.single;
    expect(copied.data, 'aGVsbG8=');
    expect(copied.mimeType, 'image/png');
  });
}

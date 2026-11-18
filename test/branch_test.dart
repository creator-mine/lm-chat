import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/secret_store.dart';
import 'package:lm_chat/widgets/message_bubble.dart';

ChatMessage _user(String id, String text, {List<ChatAttachment>? files}) =>
    ChatMessage(
      id: id,
      role: 'user',
      content: text,
      attachments: files ?? const [],
    );

ChatMessage _assistant(
  String id,
  String latest, {
  List<ChatMessageVersion>? versions,
  int activeVersion = 0,
}) => ChatMessage(
  id: id,
  role: 'assistant',
  content: latest,
  model: 'model',
  versions: versions,
  activeVersion: activeVersion,
);

ChatSession _source() => ChatSession(
  id: 'source',
  title: 'Исходный чат',
  serverId: 'server',
  model: 'model',
  temperature: 0.4,
  topP: 0.8,
  topK: 20,
  maxTokens: 512,
  systemPrompt: 'system',
  messages: [
    _user('u1', 'вопрос'),
    _assistant(
      'a1',
      'новый ответ',
      versions: [
        ChatMessageVersion(id: 'v1', content: 'старый ответ', model: 'model'),
      ],
      activeVersion: 1,
    ),
    _user('u2', 'продолжение'),
    _assistant('a2', 'финал'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('branch copies only the prefix and keeps its own metadata', () {
    final state = AppState(secretStore: MemorySecretStore());
    addTearDown(state.dispose);
    final source = _source();
    state.data.servers.add(
      ServerConfig(
        id: 'server',
        name: 'PC',
        baseUrl: 'http://192.168.1.5:1234',
      ),
    );
    state.data.chats.add(source);
    state.activeChat = source;

    final branch = state.createBranch(source, source.messages[1]);

    expect(branch.id, isNot(source.id));
    expect(branch.parentChatId, source.id);
    expect(branch.branchFromMessageId, 'a1');
    expect(branch.branchFromVersion, 1);
    expect(branch.title, 'Ветка: Исходный чат');
    expect(branch.messages.map((m) => m.id), ['u1', 'a1']);
    expect(source.messages, hasLength(4));
    expect(branch.model, 'model');
    expect(branch.temperature, 0.4);
    expect(branch.topK, 20);
    expect(branch.systemPrompt, 'system');
    expect(branch.messages[1].activeVersion, 1);
    expect(branch.messages[1].displayContent, 'старый ответ');
    expect(identical(branch.messages[1], source.messages[1]), isFalse);
    expect(state.activeChat, branch);

    final restored = ChatSession.fromJson(branch.toJson());
    expect(restored.parentChatId, source.id);
    expect(restored.branchFromMessageId, 'a1');
    expect(restored.branchFromVersion, 1);
  });

  test('a branch can be created from another branch', () {
    final state = AppState(secretStore: MemorySecretStore());
    addTearDown(state.dispose);
    final source = _source();
    state.data.chats.add(source);
    state.activeChat = source;

    final first = state.createBranch(source, source.messages[0]);
    final second = state.createBranch(first, first.messages[0]);

    expect(second.parentChatId, first.id);
    expect(second.messages, hasLength(1));
    expect(first.messages, hasLength(1));
  });

  test('branch copies attachments', () {
    final state = AppState(secretStore: MemorySecretStore());
    addTearDown(state.dispose);
    final source = ChatSession(
      id: 'source',
      serverId: 'server',
      messages: [
        _user(
          'u1',
          'image',
          files: const [
            ChatAttachment(id: 'a1', mimeType: 'image/png', data: 'AAAA'),
          ],
        ),
      ],
    );
    state.data.chats.add(source);
    state.activeChat = source;

    final branch = state.createBranch(source, source.messages.single);

    expect(branch.messages.single.attachments.single.data, 'AAAA');
    expect(
      identical(
        branch.messages.single.attachments.single,
        source.messages.single.attachments.single,
      ),
      isFalse,
    );
  });

  testWidgets('the message menu offers a branch action', (tester) async {
    var created = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: _user('u1', 'вопрос'),
            onCreateBranch: () => created = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Создать ветку'), findsOneWidget);

    await tester.tap(find.text('Создать ветку'));
    await tester.pumpAndSettle();
    expect(created, isTrue);
  });
}

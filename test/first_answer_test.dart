import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/api.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';

class _FakeClient extends LmClient {
  int calls = 0;

  @override
  Stream<ChatChunk> streamChat({
    required ServerConfig server,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required double topP,
    int topK = 0,
    double repeatPenalty = 1.0,
    required int maxTokens,
    ResponseFormat? format,
    int? ttlSeconds,
  }) async* {
    calls++;
    yield ChatChunk('ответ $calls', '');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the first answer can be generated and regenerated', () async {
    final client = _FakeClient();
    final state = AppState(generationClientFactory: () => client);
    addTearDown(state.dispose);

    final dir = await Directory.systemTemp.createTemp('lm_chat_first_');
    addTearDown(() => dir.delete(recursive: true));
    state.dataFileOverride = () async =>
        File('${dir.path}${Platform.pathSeparator}lm_chat_data.json');

    final config = ServerConfig(
      id: 'server',
      name: 'PC',
      baseUrl: 'http://127.0.0.1:1234',
    );
    final user = ChatMessage(id: 'u1', role: 'user', content: 'вопрос');
    final chat = ChatSession(
      id: 'chat',
      serverId: config.id,
      model: 'model',
      launch: const LaunchSettings(loadOnDemand: false),
      messages: [user],
    );
    state.data.servers.add(config);
    state.data.activeServerId = config.id;
    state.data.chats.add(chat);
    state.activeChat = chat;

    await state.generateAnswerFrom(chat, user);

    expect(chat.messages, hasLength(2));
    expect(chat.messages.last.role, 'assistant');
    expect(chat.messages.last.content, 'ответ 1');
    expect(client.calls, 1);

    await state.generateAnswerFrom(chat, user);

    expect(chat.messages, hasLength(2));
    expect(chat.messages.last.content, 'ответ 2');
    expect(chat.messages.last.versionCount, 2);
    expect(chat.messages.last.variantAt(1).content, 'ответ 1');
    expect(client.calls, 2);
  });
}

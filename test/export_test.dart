import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/export_options.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/widgets/export_sheet.dart';
import 'package:provider/provider.dart';

ChatSession _chat() => ChatSession(
  id: 'chat',
  title: 'Тестовый чат',
  serverId: 'server',
  model: 'model',
  messages: [
    ChatMessage(
      id: 'u1',
      role: 'user',
      content: 'вопрос',
      attachments: [
        ChatAttachment(
          id: 'att1',
          mimeType: 'image/png',
          data: base64Encode([1, 2, 3]),
          name: 'pic.png',
        ),
      ],
    ),
    ChatMessage(
      id: 'a1',
      role: 'assistant',
      content: 'ответ',
      reasoning: 'думаю',
      model: 'model',
      completionTokens: 10,
      totalTokens: 12,
      generationMs: 1000,
      firstTokenMs: 200,
    ),
  ],
);

void main() {
  test('Markdown export follows the chosen options', () {
    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat();

    final full = state.chatToMarkdown(chat);
    expect(full, contains('Размышления'));
    expect(full, contains('токенов'));
    expect(full, contains('pic.png'));

    final lean = state.chatToMarkdown(
      chat,
      options: const ExportOptions(
        includeReasoning: false,
        includeStats: false,
        includeAttachmentNames: false,
      ),
    );
    expect(lean, isNot(contains('Размышления')));
    expect(lean, isNot(contains('токенов')));
    expect(lean, isNot(contains('pic.png')));
    expect(lean, contains('ответ'));
  });

  test('JSON payload omits disabled sections and attachments', () {
    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat();
    state.data.chats.add(chat);
    state.data.servers.add(
      ServerConfig(id: 'server', name: 'PC', baseUrl: 'http://127.0.0.1:1234'),
    );
    state.data.promptTemplates.add(
      const PromptTemplate(id: 't1', name: 'Шаблон', content: 'текст'),
    );

    final payload = state.exportPayload(
      options: const ExportOptions(
        includeServers: false,
        includeTemplates: false,
        includeAttachments: false,
      ),
    );
    expect(payload.containsKey('servers'), isFalse);
    expect(payload.containsKey('promptTemplates'), isFalse);
    final exported = (payload['chats'] as List).first as Map<String, dynamic>;
    final messages = exported['messages'] as List;
    final user = messages.first as Map<String, dynamic>;
    expect(user.containsKey('attachments'), isFalse);
  });

  test('archived chats can be excluded', () {
    final state = AppState();
    addTearDown(state.dispose);
    final active = _chat();
    final archived = ChatSession(
      id: 'old',
      title: 'Архив',
      serverId: 'server',
      model: 'model',
      archived: true,
    );
    state.data.chats
      ..add(active)
      ..add(archived);

    final all = state.exportPayload();
    expect((all['chats'] as List), hasLength(2));

    final withoutArchive = state.exportPayload(
      options: const ExportOptions(includeArchived: false),
    );
    expect((withoutArchive['chats'] as List), hasLength(1));
  });

  test('current chat export keeps the single-chat JSON root', () {
    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat();
    state.data.chats.add(chat);
    state.activeChat = chat;

    final payload = state.exportPayload(
      options: const ExportOptions(scope: ExportScope.currentChat),
    );
    expect(payload['id'], 'chat');
    expect(payload['messages'], isA<List>());
  });

  testWidgets('export sheet switches format and scope', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat();
    state.data.chats.add(chat);
    state.activeChat = chat;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showExportSheet(context, chat: chat),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Что экспортировать'), findsOneWidget);
    expect(find.text('Изображения-вложения'), findsOneWidget);

    await tester.tap(find.text('Все чаты'));
    await tester.pumpAndSettle();
    expect(find.text('Серверы и настройки'), findsOneWidget);

    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    expect(find.text('Размышления модели'), findsOneWidget);
    expect(find.text('Серверы и настройки'), findsNothing);
  });
}

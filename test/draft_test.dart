import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/screens/home_screen.dart';
import 'package:lm_chat/theme.dart';
import 'package:provider/provider.dart';

ChatSession _chat(String id, {bool empty = false}) => ChatSession(
  id: id,
  title: id,
  serverId: '',
  model: 'model',
  messages: empty
      ? []
      : [
          ChatMessage(id: '$id-u', role: 'user', content: 'вопрос'),
          ChatMessage(id: '$id-a', role: 'assistant', content: 'ответ'),
        ],
);

Finder _composer() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.hintText == 'Сообщение' ||
          widget.decoration?.hintText == 'Модель печатает…'),
);

String _composerText(WidgetTester tester) =>
    tester.widget<TextField>(_composer()).controller!.text;

Future<void> _pumpHome(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('openNewChat does nothing while the active chat is empty', () {
    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat('empty', empty: true);
    state.data.chats.add(chat);
    state.activeChat = chat;

    expect(state.openNewChat(), isNull);
    expect(state.data.chats, hasLength(1));
    expect(state.activeChat, same(chat));
  });

  test('openNewChat reuses an existing empty chat', () {
    final state = AppState();
    addTearDown(state.dispose);
    final active = _chat('active');
    final empty = _chat('empty', empty: true);
    state.data.chats
      ..add(active)
      ..add(empty);
    state.activeChat = active;

    expect(state.openNewChat(), same(empty));
    expect(state.activeChat, same(empty));
    expect(state.data.chats, hasLength(2));
  });

  test('openNewChat creates a chat only when no empty one exists', () {
    final state = AppState();
    addTearDown(state.dispose);
    final active = _chat('active');
    state.data.chats.add(active);
    state.activeChat = active;

    final created = state.openNewChat();
    expect(created, isNotNull);
    expect(created!.messages, isEmpty);
    expect(state.activeChat, same(created));
    expect(state.data.chats, hasLength(2));
  });

  testWidgets('the composer keeps a separate draft for each chat', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    final first = _chat('A');
    final second = _chat('B');
    state.data.chats
      ..add(first)
      ..add(second);
    state.activeChat = first;

    await _pumpHome(tester, state);
    await tester.enterText(_composer(), 'черновик A');
    await tester.pump();

    state.selectChat(second);
    await tester.pump();
    expect(_composerText(tester), isEmpty);

    await tester.enterText(_composer(), 'черновик B');
    await tester.pump();

    state.selectChat(first);
    await tester.pump();
    expect(_composerText(tester), 'черновик A');

    state.selectChat(second);
    await tester.pump();
    expect(_composerText(tester), 'черновик B');
  });

  testWidgets('sending a message clears only that chat draft', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final first = _chat('A');
    final second = _chat('B');
    state.data.chats
      ..add(first)
      ..add(second);
    state.activeChat = first;

    await _pumpHome(tester, state);
    state.selectChat(second);
    await tester.pump();
    await tester.enterText(_composer(), 'черновик B');
    await tester.pump();

    state.selectChat(first);
    await tester.pump();
    await tester.enterText(_composer(), 'отправить');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    state.selectChat(second);
    await tester.pump();
    expect(_composerText(tester), 'черновик B');

    state.selectChat(first);
    await tester.pump();
    expect(_composerText(tester), isEmpty);
  });
}

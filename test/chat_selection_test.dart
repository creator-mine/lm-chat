import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/screens/home_screen.dart';
import 'package:lm_chat/theme.dart';
import 'package:lm_chat/widgets/chat_drawer.dart';
import 'package:provider/provider.dart';

ChatSession _chat(String id) => ChatSession(
  id: id,
  title: id,
  serverId: '',
  model: 'model',
  messages: [
    ChatMessage(id: '$id-u', role: 'user', content: 'вопрос'),
    ChatMessage(id: '$id-a', role: 'assistant', content: 'ответ'),
  ],
);

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
  test('deleteChats removes several chats and picks a new active one', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A');
    final b = _chat('B');
    final c = _chat('C');
    state.data.chats.addAll([a, b, c]);
    state.activeChat = a;

    final removed = state.deleteChats([a, b]);

    expect(removed, 2);
    expect(state.data.chats, hasLength(1));
    expect(state.data.chats.single.id, 'C');
    expect(state.activeChat?.id, 'C');
  });

  test('deleteChats creates a new chat when everything is removed', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A');
    final b = _chat('B');
    state.data.chats.addAll([a, b]);
    state.activeChat = a;

    state.deleteChats([a, b]);

    expect(state.data.chats, hasLength(1));
    expect(state.data.chats.single.messages, isEmpty);
    expect(state.activeChat, isNotNull);
  });

  test('setPinnedChats pins and unpins a batch', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A');
    final b = _chat('B');
    state.data.chats.addAll([a, b]);

    state.setPinnedChats([a, b], true);
    expect(a.pinned, isTrue);
    expect(b.pinned, isTrue);

    state.setPinnedChats([a, b], false);
    expect(a.pinned, isFalse);
    expect(b.pinned, isFalse);
  });

  test('archiveChats archives a batch and switches the active chat', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A');
    final b = _chat('B');
    state.data.chats.addAll([a, b]);
    state.activeChat = a;

    state.archiveChats([a]);

    expect(a.archived, isTrue);
    expect(state.activeChat?.id, 'B');

    state.archiveChats([a], archived: false);
    expect(a.archived, isFalse);
  });

  testWidgets('holding the chat for 250 ms opens the menu', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat('A');
    state.data.chats.add(chat);
    state.activeChat = chat;

    await _pumpHome(tester, state);

    final tile = find
        .ancestor(of: find.text('A'), matching: find.byType(ChatTile))
        .first;
    final gesture = await tester.startGesture(tester.getCenter(tile));

    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Переименовать'), findsNothing);

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(find.text('Переименовать'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('right click opens the same chat menu', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    addTearDown(state.dispose);
    final chat = _chat('A');
    state.data.chats.add(chat);
    state.activeChat = chat;

    await _pumpHome(tester, state);

    final tile = find
        .ancestor(of: find.text('A'), matching: find.byType(ChatTile))
        .first;
    await tester.tap(tile, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Переименовать'), findsOneWidget);
    expect(find.text('Выбрать несколько'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('long press opens menu and selects several chats for deletion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A');
    final b = _chat('B');
    final c = _chat('C');
    state.data.chats.addAll([a, b, c]);
    state.activeChat = a;

    await _pumpHome(tester, state);

    Finder tile(String title) => find
        .ancestor(of: find.text(title), matching: find.byType(ChatTile))
        .first;

    await tester.longPress(tile('A'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрать несколько'), findsOneWidget);

    await tester.tap(find.text('Выбрать несколько'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: 1'), findsOneWidget);

    await tester.tap(tile('B'));
    await tester.pump();
    expect(find.text('Выбрано: 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Удалить выбранные'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить выбранные чаты?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();

    expect(state.data.chats, hasLength(1));
    expect(state.data.chats.single.id, 'C');
    expect(find.text('A'), findsNothing);
    expect(find.text('B'), findsNothing);

    // Let the confirmation snackbar timer finish.
    await tester.pump(const Duration(seconds: 5));
  });
}

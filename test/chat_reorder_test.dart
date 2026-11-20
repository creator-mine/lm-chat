import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/screens/home_screen.dart';
import 'package:lm_chat/theme.dart';
import 'package:provider/provider.dart';

final _base = DateTime(2026, 11, 21, 12);

ChatSession _chat(
  String id, {
  bool pinned = false,
  bool archived = false,
  DateTime? updatedAt,
  int? sortOrder,
}) => ChatSession(
  id: id,
  title: id,
  serverId: '',
  model: 'model',
  pinned: pinned,
  archived: archived,
  sortOrder: sortOrder,
  updatedAt: updatedAt ?? _base,
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
  test('the first reorder enables manual order and freezes recency', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A', updatedAt: _base.add(const Duration(hours: 3)));
    final b = _chat('B', updatedAt: _base.add(const Duration(hours: 2)));
    final c = _chat('C', updatedAt: _base.add(const Duration(hours: 1)));
    state.data.chats.addAll([a, b, c]);
    expect(state.chats.map((chat) => chat.id), ['A', 'B', 'C']);

    state.reorderChatGroup([c, b, a], archived: false, pinned: false);

    expect(state.data.manualChatOrder, isTrue);
    expect(state.chats.map((chat) => chat.id), ['C', 'B', 'A']);

    a.updatedAt = _base.add(const Duration(days: 1));
    expect(state.chats.map((chat) => chat.id), ['C', 'B', 'A']);
  });

  test('a new chat goes on top of the regular group', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A', updatedAt: _base.add(const Duration(hours: 2)));
    final b = _chat('B', updatedAt: _base.add(const Duration(hours: 1)));
    state.data.chats.addAll([a, b]);
    state.reorderChatGroup([b, a], archived: false, pinned: false);

    final created = state.newChat();

    expect(state.chats.first.id, created.id);
    expect(state.chats.map((chat) => chat.id).skip(1), ['B', 'A']);
  });

  test('pinned chats keep their own group and reorder separately', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat(
      'A',
      pinned: true,
      updatedAt: _base.add(const Duration(hours: 4)),
    );
    final b = _chat(
      'B',
      pinned: true,
      updatedAt: _base.add(const Duration(hours: 3)),
    );
    final c = _chat('C', updatedAt: _base.add(const Duration(hours: 2)));
    final d = _chat('D', updatedAt: _base.add(const Duration(hours: 1)));
    state.data.chats.addAll([a, b, c, d]);

    state.reorderChatGroup([b, a], archived: false, pinned: true);

    expect(state.chats.map((chat) => chat.id), ['B', 'A', 'C', 'D']);

    state.togglePinned(c);

    expect(state.chats.take(3).map((chat) => chat.id), ['C', 'B', 'A']);
    expect(
      state.data.chats.firstWhere((chat) => chat.id == 'C').pinned,
      isTrue,
    );
  });

  test('archiving and restoring put the chat on top of its group', () {
    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A', updatedAt: _base.add(const Duration(hours: 3)));
    final b = _chat('B', updatedAt: _base.add(const Duration(hours: 2)));
    final c = _chat('C', updatedAt: _base.add(const Duration(hours: 1)));
    state.data.chats.addAll([a, b, c]);
    state.reorderChatGroup([c, b, a], archived: false, pinned: false);

    state.archiveChat(b);

    expect(state.activeChats.map((chat) => chat.id), ['C', 'A']);
    expect(state.archivedChats.first.id, 'B');

    state.unarchiveChat(b);

    expect(state.activeChats.first.id, 'B');
  });

  test('manual order and sortOrder survive a JSON roundtrip', () {
    final data = AppData()
      ..manualChatOrder = true
      ..chats.add(_chat('A', sortOrder: 7))
      ..chats.add(_chat('B', sortOrder: 3));

    final restored = AppData.fromJson(data.toJson());

    expect(restored.manualChatOrder, isTrue);
    expect(
      {for (final chat in restored.chats) chat.id: chat.sortOrder},
      {'A': 7, 'B': 3},
    );
  });

  testWidgets('dragging a chat handle changes the order', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A', updatedAt: _base.add(const Duration(hours: 2)));
    final b = _chat('B', updatedAt: _base.add(const Duration(hours: 1)));
    state.data.chats.addAll([a, b]);
    state.activeChat = a;

    await _pumpHome(tester, state);
    await tester.tap(find.byTooltip('Изменить порядок'));
    await tester.pumpAndSettle();

    final handles = find.byIcon(Icons.drag_indicator_rounded);
    final gesture = await tester.startGesture(tester.getCenter(handles.at(1)));
    await tester.pump(const Duration(milliseconds: 100));
    for (var step = 0; step < 12; step++) {
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    expect(state.data.manualChatOrder, isTrue);
    expect(state.chats.map((chat) => chat.id), ['B', 'A']);
  });

  testWidgets('reorder mode shows drag handles and hides the search field', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    addTearDown(state.dispose);
    final a = _chat('A', updatedAt: _base.add(const Duration(hours: 2)));
    final b = _chat('B', updatedAt: _base.add(const Duration(hours: 1)));
    state.data.chats.addAll([a, b]);
    state.activeChat = a;

    await _pumpHome(tester, state);

    await tester.tap(find.byTooltip('Изменить порядок'));
    await tester.pumpAndSettle();

    expect(find.text('Перетащите чаты вверх или вниз'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-search-field')), findsNothing);
    expect(find.byIcon(Icons.drag_indicator_rounded), findsNWidgets(2));

    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-search-field')), findsOneWidget);
  });
}

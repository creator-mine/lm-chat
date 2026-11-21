import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/screens/home_screen.dart';
import 'package:lm_chat/theme.dart';
import 'package:provider/provider.dart';

AppState _stateWithChat() {
  final state = AppState();
  final chat = ChatSession(
    id: 'chat',
    serverId: '',
    model: 'model',
    title: 'Test chat',
    messages: [
      ChatMessage(id: 'u1', role: 'user', content: 'вопрос'),
      ChatMessage(id: 'a1', role: 'assistant', content: 'ответ'),
    ],
  );
  state.data.chats.add(chat);
  state.activeChat = chat;
  return state;
}

void main() {
  testWidgets('chat parameters sheet keeps copy and clear actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = _stateWithChat();
    addTearDown(state.dispose);

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

    expect(find.byIcon(Icons.more_vert), findsNothing);
    await tester.tap(find.byTooltip('Параметры чата'));
    await tester.pumpAndSettle();

    expect(find.text('Действия с чатом'), findsOneWidget);
    expect(find.text('Копировать чат'), findsOneWidget);
    expect(find.text('Очистить чат'), findsOneWidget);

    await tester.tap(find.text('Очистить чат'));
    await tester.pumpAndSettle();

    expect(state.activeChat!.messages, isEmpty);
    expect(find.text('Чат очищен'), findsOneWidget);

    // Let the confirmation snackbar timer finish.
    await tester.pump(const Duration(seconds: 5));
  });
}

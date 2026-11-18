import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/screens/settings_screen.dart';
import 'package:provider/provider.dart';

ServerConfig _server() => ServerConfig(
  id: 's1',
  name: 'Домашний ПК',
  baseUrl: 'http://192.168.1.50:1234',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disconnect keeps the server but drops the active connection', () {
    final state = AppState();
    addTearDown(state.dispose);
    final server = _server();
    state.data.servers.add(server);
    state.setActiveServer(server.id);

    expect(state.activeServer, server);
    expect(state.isDisconnected, isFalse);

    state.disconnectServer();

    expect(state.isDisconnected, isTrue);
    expect(state.activeServer, isNull);
    expect(state.data.servers, hasLength(1));

    state.setActiveServer(server.id);

    expect(state.isDisconnected, isFalse);
    expect(state.activeServer, server);
  });

  test('sending and switching chats stay offline until reconnect', () async {
    final state = AppState();
    addTearDown(state.dispose);
    final server = _server();
    final chat = ChatSession(id: 'c1', serverId: server.id, model: 'model');
    state.data.servers.add(server);
    state.data.chats.add(chat);
    state.activeChat = chat;
    state.disconnectServer();

    await state.send('привет');

    expect(chat.messages, isEmpty);
    expect(state.statusMessage, contains('отключён'));

    state.selectChat(chat);

    expect(state.isDisconnected, isTrue);
    expect(state.activeServer, isNull);
  });

  test('a new chat has no server while disconnected', () {
    final state = AppState();
    addTearDown(state.dispose);
    state.data.servers.add(_server());
    state.disconnectServer();

    final chat = state.newChat();

    expect(chat.serverId, isEmpty);
    expect(state.isDisconnected, isTrue);
  });

  testWidgets('the server menu connects and disconnects', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final first = _server();
    final second = ServerConfig(
      id: 's2',
      name: 'Ноутбук',
      baseUrl: 'http://192.168.1.51:1234',
    );
    state.data.servers.addAll([first, second]);
    state.data.activeServerId = first.id;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('подключён'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Отключиться'), findsOneWidget);

    await tester.tap(find.text('Отключиться'));
    await tester.pumpAndSettle();

    expect(state.isDisconnected, isTrue);
    expect(find.text('подключён'), findsNothing);

    await tester.tap(find.byType(PopupMenuButton<String>).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Подключиться'), findsOneWidget);
  });
}

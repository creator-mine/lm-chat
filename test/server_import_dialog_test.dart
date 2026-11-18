import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/server_share.dart';
import 'package:lm_chat/widgets/server_import_dialog.dart';
import 'package:provider/provider.dart';

ServerConfig _relayServer() => ServerConfig(
  id: 'relay',
  name: 'Домашний ПК',
  baseUrl: 'http://192.168.1.50:1234',
  relayUrl: 'https://relay.example.com',
  relayDevice: 'home-pc',
  relayToken: 'relay-secret',
  relayE2e: true,
  relayPublicKey: 'public-key',
);

Widget _host(AppState state, String code) {
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showServerImportDialog(context, initialCode: code),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a shared server can be previewed and imported', (tester) async {
    final state = AppState();
    addTearDown(state.dispose);
    final code = ServerShareCodec.encodeServer(
      _relayServer(),
      ServerShareMode.withRelay,
    );

    await tester.pumpWidget(_host(state, code));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();

    expect(find.text('Импорт сервера'), findsOneWidget);
    expect(find.text('Домашний ПК'), findsOneWidget);
    expect(find.textContaining('токен relay'), findsOneWidget);

    await tester.tap(find.text('Импортировать'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 700));

    expect(state.data.servers, hasLength(1));
    expect(state.data.servers.single.relayToken, 'relay-secret');
  });

  testWidgets('preview warns when an existing server gains a relay', (
    tester,
  ) async {
    final state = AppState();
    addTearDown(state.dispose);
    state.data.servers.add(
      ServerConfig(
        id: 'local',
        name: 'Домашний ПК',
        baseUrl: 'http://192.168.1.50:1234',
      ),
    );
    final code = ServerShareCodec.encodeServer(
      _relayServer(),
      ServerShareMode.withRelay,
    );

    await tester.pumpWidget(_host(state, code));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продолжить'));
    await tester.pumpAndSettle();

    expect(
      find.text('Обновит существующий сервер: добавит relay'),
      findsOneWidget,
    );
  });
}

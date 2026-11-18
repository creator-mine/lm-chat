import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/widgets/server_edit_dialog.dart';

void main() {
  test('bridge address uses the server host and the default bridge port', () {
    expect(
      ServerConfig.bridgeUrlForBase('http://192.168.1.50:1234'),
      'http://192.168.1.50:1235',
    );
    expect(
      ServerConfig.bridgeUrlForBase('192.168.1.50:1234'),
      'http://192.168.1.50:1235',
    );
    expect(
      ServerConfig.bridgeUrlForBase('http://ubuntu.local:1234/v1'),
      'http://ubuntu.local:1235',
    );
    expect(
      ServerConfig.bridgeUrlForBase('http://[fd00::1]:1234'),
      'http://[fd00::1]:1235',
    );
    expect(ServerConfig.bridgeUrlForBase(''), '');
    expect(ServerConfig.bridgeUrlForBase('   '), '');
  });

  testWidgets('server dialog enables the bridge without an address field', (
    tester,
  ) async {
    final server = ServerConfig(
      id: 'server',
      name: 'PC',
      baseUrl: 'http://192.168.1.50:1234',
    );
    ServerConfig? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  saved = await showDialog<ServerConfig>(
                    context: context,
                    builder: (_) => ServerEditDialog(server: server),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Адрес мостика'), findsNothing);
    expect(find.text('Включить мост'), findsOneWidget);
    expect(find.text('Токен моста (BRIDGE_TOKEN)'), findsNothing);
    expect(find.text('Токен плагина'), findsOneWidget);

    await tester.ensureVisible(find.text('Включить мост'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Включить мост'));
    await tester.pumpAndSettle();

    expect(find.text('Мост включён'), findsOneWidget);
    expect(find.text('Адрес моста: http://192.168.1.50:1235'), findsOneWidget);

    final tokenField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Токен плагина',
    );
    await tester.ensureVisible(tokenField);
    await tester.enterText(tokenField, 'secret-token');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.bridgeUrl, 'http://192.168.1.50:1235');
    expect(saved!.bridgeToken, isEmpty);
    expect(saved!.pluginToken, 'secret-token');
    expect(saved!.effectiveBridgeToken, 'secret-token');
    expect(saved!.chatViaBridge, isTrue);
  });

  testWidgets('existing custom bridge port is preserved when saving', (
    tester,
  ) async {
    final server = ServerConfig(
      id: 'server',
      name: 'PC',
      baseUrl: 'http://192.168.1.50:1234',
      bridgeUrl: 'http://192.168.1.50:2345',
      bridgeToken: 'old-token',
    );
    ServerConfig? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  saved = await showDialog<ServerConfig>(
                    context: context,
                    builder: (_) => ServerEditDialog(server: server),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Мост включён'), findsOneWidget);
    expect(find.text('Адрес моста: http://192.168.1.50:2345'), findsOneWidget);

    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.bridgeUrl, 'http://192.168.1.50:2345');
    expect(saved!.bridgeToken, isEmpty);
  });

  testWidgets('server dialog saves the plugin token without an address', (
    tester,
  ) async {
    ServerConfig? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  saved = await showDialog<ServerConfig>(
                    context: context,
                    builder: (_) => const ServerEditDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Адрес плагина'), findsNothing);
    expect(find.text('Токен плагина'), findsOneWidget);

    final tokenField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Токен плагина',
    );
    await tester.ensureVisible(tokenField);
    await tester.enterText(tokenField, 'plugin-token');

    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.pluginUrl, isEmpty);
    expect(saved!.pluginToken, 'plugin-token');
    expect(saved!.effectivePluginUrl, 'http://192.168.1.100:1236');
  });
}

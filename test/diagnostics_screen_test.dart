import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_log.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/screens/diagnostics_screen.dart';
import 'package:lm_chat/secret_store.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('diagnostics shows the server state and the app log', (
    tester,
  ) async {
    final state = AppState(secretStore: MemorySecretStore());
    addTearDown(state.dispose);
    addTearDown(AppLog.instance.clear);
    AppLog.instance.info('Тестовое событие', detail: 'без токенов');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: DiagnosticsScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Диагностика'), findsOneWidget);
    expect(find.text('не выбран'), findsOneWidget);
    expect(find.textContaining('Тестовое событие'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/secret_store.dart';
import 'package:lm_chat/widgets/model_settings_sheet.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('model settings edit the default launch settings', (
    tester,
  ) async {
    final state = AppState(secretStore: MemorySecretStore());
    addTearDown(state.dispose);
    final before = state.data.defaultLaunch.loadOnDemand;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModelSettings(context, defaults: true),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Запуск по умолчанию'), findsOneWidget);
    expect(find.text('Применяются к новым чатам'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));

    expect(state.data.defaultLaunch.loadOnDemand, !before);
  });
}

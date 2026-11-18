import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/screens/sync_screen.dart';
import 'package:lm_chat/secret_store.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('sync screen shows the disabled state and device controls', (
    tester,
  ) async {
    final state = AppState(secretStore: MemorySecretStore());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: SyncScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Синхронизация'), findsOneWidget);
    expect(find.text('Синхронизация по локальной сети'), findsOneWidget);
    expect(find.text('Имя устройства'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNWidgets(2));
  });
}

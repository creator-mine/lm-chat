import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_chat/app_state.dart';
import 'package:lm_chat/models.dart';
import 'package:lm_chat/theme.dart';
import 'package:lm_chat/widgets/model_settings_sheet.dart';
import 'package:provider/provider.dart';

const _fast = LaunchSettings(
  contextLength: 4096,
  ttlSeconds: 900,
  gpuRatio: 0.75,
  flashAttention: true,
);

const _quality = LaunchSettings(
  contextLength: 32768,
  loadOnDemand: false,
  ttlSeconds: 3600,
  gpuRatio: 1,
  offloadKvCache: true,
  evalBatchSize: 2048,
);

LaunchPreset _preset(String id, String name, LaunchSettings settings) =>
    LaunchPreset(id: id, name: name, settings: settings);

void main() {
  test('launch presets and the default id survive a JSON roundtrip', () {
    final data = AppData()
      ..launchPresets.add(_preset('fast', 'Быстрый', _fast))
      ..defaultLaunchPresetId = 'fast';

    final restored = AppData.fromJson(data.toJson());

    expect(restored.launchPresets, hasLength(1));
    expect(restored.launchPresets.single.name, 'Быстрый');
    expect(restored.launchPresets.single.settings, _fast);
    expect(restored.defaultLaunchPresetId, 'fast');
  });

  test('old files without presets load with an empty list', () {
    final json = AppData().toJson()
      ..remove('launchPresets')
      ..remove('defaultLaunchPresetId');

    final restored = AppData.fromJson(json);

    expect(restored.launchPresets, isEmpty);
    expect(restored.defaultLaunchPresetId, isEmpty);
  });

  test('presets can be added, renamed and deleted', () {
    final state = AppState();
    addTearDown(state.dispose);

    final preset = state.addLaunchPreset('  Быстрый  ', _fast);
    expect(state.data.launchPresets.single.name, 'Быстрый');
    expect(preset.settings, _fast);

    state.renameLaunchPreset(preset, 'Очень быстрый');
    expect(state.data.launchPresets.single.name, 'Очень быстрый');

    state.deleteLaunchPreset(state.data.launchPresets.single);
    expect(state.data.launchPresets, isEmpty);
  });

  test('a preset can become the default for new chats', () {
    final state = AppState();
    addTearDown(state.dispose);
    final preset = state.addLaunchPreset('Качество', _quality);

    state.setDefaultLaunchPreset(preset);

    expect(state.data.defaultLaunch, _quality);
    expect(state.data.defaultLaunchPresetId, preset.id);

    final chat = state.newChat();
    expect(chat.launch, _quality);
  });

  test('changing defaults by hand clears the selected preset', () {
    final state = AppState();
    addTearDown(state.dispose);
    final preset = state.addLaunchPreset('Качество', _quality);
    state.setDefaultLaunchPreset(preset);

    state.updateDefaultLaunch(_fast);

    expect(state.data.defaultLaunch, _fast);
    expect(state.data.defaultLaunchPresetId, isEmpty);
  });

  test('deleting the default preset keeps the current defaults', () {
    final state = AppState();
    addTearDown(state.dispose);
    final preset = state.addLaunchPreset('Качество', _quality);
    state.setDefaultLaunchPreset(preset);

    state.deleteLaunchPreset(preset);

    expect(state.data.defaultLaunchPresetId, isEmpty);
    expect(state.data.defaultLaunch, _quality);
  });

  testWidgets('a preset can be created from the default launch sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final state = AppState();
    addTearDown(state.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showModelSettings(context, defaults: true),
                  child: const Text('открыть'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Пресеты запуска'), findsOneWidget);

    await tester.tap(find.text('Сохранить пресет'));
    await tester.pumpAndSettle();
    expect(find.text('Новый пресет'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Мой пресет');
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();

    expect(state.data.launchPresets.single.name, 'Мой пресет');
    expect(
      state.data.defaultLaunchPresetId,
      state.data.launchPresets.single.id,
    );
    expect(find.text('Мой пресет'), findsOneWidget);
    expect(find.text('По умолчанию для новых чатов'), findsOneWidget);

    // Let the confirmation snackbar timer finish.
    await tester.pump(const Duration(seconds: 5));
  });
}

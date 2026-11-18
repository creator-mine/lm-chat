import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../app_version.dart';
import '../format_utils.dart';
import '../l10n_text.dart';
import '../models.dart';
import '../server_share.dart';
import '../theme.dart';
import '../widgets/model_picker.dart';
import '../widgets/model_settings_sheet.dart';
import '../widgets/params_sheet.dart';
import '../widgets/profile_sheet.dart';
import '../widgets/prompt_library_sheet.dart';
import '../widgets/server_edit_dialog.dart';
import '../widgets/server_import_dialog.dart';
import '../widgets/server_share_sheet.dart';
import '../widgets/update_banner.dart';
import 'diagnostics_screen.dart';
import 'qr_scan_screen.dart';
import 'sync_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);

    return Scaffold(
      appBar: AppBar(title: const Text('Серверы и настройки')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              _SectionHeader(
                title: 'Серверы',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (state.servers.isNotEmpty)
                      IconButton(
                        onPressed: () => _shareAllServers(context, state),
                        icon: const Icon(Icons.ios_share_rounded),
                        tooltip: L10n.t('Поделиться всеми'),
                      ),
                    PopupMenuButton<String>(
                      onSelected: (value) => _addServerAction(context, value),
                      icon: const Icon(Icons.add_rounded),
                      tooltip: L10n.t('Добавить сервер'),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'add',
                          child: Text(L10n.t('Добавить сервер')),
                        ),
                        PopupMenuItem(
                          value: 'import',
                          child: Text(L10n.t('Импортировать по коду')),
                        ),
                        if (_canScanQr)
                          PopupMenuItem(
                            value: 'scan',
                            child: Text(L10n.t('Сканировать QR')),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (state.servers.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Icon(
                          Icons.dns_outlined,
                          size: 32,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Пока нет ни одного сервера.\nДобавьте адрес LM Studio.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...state.servers.map(
                  (server) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ServerTile(server: server),
                  ),
                ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Параметры по умолчанию'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('Параметры генерации'),
                  subtitle: Text(
                    _defaultsSummary(context, state.data),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showChatParams(context, defaults: true),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Запуск модели по умолчанию'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.memory_rounded),
                  title: const Text('Контекст и загрузка'),
                  subtitle: Text(
                    _launchSummary(state.data.defaultLaunch),
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showModelSettings(context, defaults: true),
                ),
              ),
              const SizedBox(height: 14),
              _SectionHeader(title: desktop ? 'Генерация' : 'Фон и генерация'),
              Card(
                child: Column(
                  children: [
                    if (!desktop) ...[
                      SwitchListTile(
                        value: state.data.backgroundGeneration,
                        onChanged: state.setBackgroundGeneration,
                        secondary: const Icon(Icons.nightlight_round),
                        title: const Text('Продолжать в фоне'),
                        subtitle: const Text(
                          'Foreground-сервис не даёт Android заморозить ответ. '
                          'На Xiaomi/Redmi/POCO также включите «Автозапуск» и '
                          '«Без ограничений» в настройках батареи.',
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                    const ListTile(
                      leading: Icon(Icons.dns_outlined),
                      title: Text('Задания на мостике'),
                      subtitle: Text(
                        'Если у сервера указан мостик, ответ готовится на Ubuntu. '
                        'Сворачивание, потеря Wi-Fi и закрытие приложения его не '
                        'прерывают — при возврате текст догружается.',
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.bug_report_outlined),
                      title: const Text('Диагностика'),
                      subtitle: const Text(
                        'Последние запросы, ошибки и состояние сервера',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DiagnosticsScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Оформление'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Тема приложения',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<AppThemeMode>(
                          segments: const [
                            ButtonSegment(
                              value: AppThemeMode.system,
                              icon: Icon(
                                Icons.brightness_auto_rounded,
                                size: 18,
                              ),
                              label: Text('Системная'),
                            ),
                            ButtonSegment(
                              value: AppThemeMode.light,
                              icon: Icon(Icons.light_mode_rounded, size: 18),
                              label: Text('Светлая'),
                            ),
                            ButtonSegment(
                              value: AppThemeMode.dark,
                              icon: Icon(Icons.dark_mode_rounded, size: 18),
                              label: Text('Тёмная'),
                            ),
                          ],
                          selected: {state.data.themeMode},
                          onSelectionChanged: (selection) =>
                              state.setThemeMode(selection.first),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Шрифт интерфейса',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final font in const [
                            AppFontFamily.system,
                            AppFontFamily.inter,
                            AppFontFamily.manrope,
                          ])
                            _FontOption(
                              family: font.family,
                              label: _fontLabel(font),
                              selected: state.data.fontFamily == font,
                              onTap: () => state.setFontFamily(font),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _CustomFontTile(
                        name: state.data.customFontName,
                        selected: state.data.fontFamily == AppFontFamily.custom,
                        onSelect: () =>
                            state.setFontFamily(AppFontFamily.custom),
                        onImport: () => _importFont(context),
                        onRemove: () => _removeFont(context),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Text(
                            'Размер текста',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const Spacer(),
                          Text(
                            '${(state.data.fontScale * 100).round()}%',
                            style: TextStyle(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Slider(
                        value: state.data.fontScale.clamp(0.9, 1.2),
                        min: 0.9,
                        max: 1.2,
                        divisions: 3,
                        label: '${(state.data.fontScale * 100).round()}%',
                        onChanged: state.setFontScale,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Плотность интерфейса',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 10),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SegmentedButton<UiDensity>(
                          segments: const [
                            ButtonSegment(
                              value: UiDensity.normal,
                              icon: Icon(Icons.view_agenda_outlined, size: 18),
                              label: Text('Обычная'),
                            ),
                            ButtonSegment(
                              value: UiDensity.compact,
                              icon: Icon(Icons.view_headline_rounded, size: 18),
                              label: Text('Компактная'),
                            ),
                          ],
                          selected: {state.data.uiDensity},
                          onSelectionChanged: (selection) =>
                              state.setUiDensity(selection.first),
                        ),
                      ),
                      if (desktop) ...[
                        const SizedBox(height: 14),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.view_sidebar_outlined,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Список чатов на широком экране можно свернуть '
                                'кнопкой в его заголовке или через Ctrl+B. '
                                'Ширина меняется перетаскиванием края, '
                                'двойной щелчок сбрасывает её.',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Icon(
                            Icons.code_rounded,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Шрифт кода',
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                                Text(
                                  'JetBrains Mono',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Язык'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<AppLanguage>(
                      segments: const [
                        ButtonSegment(
                          value: AppLanguage.system,
                          icon: Icon(Icons.language_rounded, size: 18),
                          label: Text('Системный'),
                        ),
                        ButtonSegment(
                          value: AppLanguage.ru,
                          label: Text('Русский'),
                        ),
                        ButtonSegment(
                          value: AppLanguage.en,
                          label: Text('English'),
                        ),
                      ],
                      selected: {state.data.appLanguage},
                      onSelectionChanged: (selection) =>
                          state.setAppLanguage(selection.first),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Промпты'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.bookmarks_outlined),
                  title: const Text('Библиотека промптов'),
                  subtitle: const Text(
                    'Встроенные шаблоны системного промпта и свои',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showPromptLibrary(context),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Профиль настроек'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.upload_file_rounded),
                      title: const Text('Экспорт профиля'),
                      subtitle: const Text(
                        'Серверы, параметры, оформление и промпты — без токенов',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _exportProfile(context),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.download_rounded),
                      title: const Text('Импорт профиля'),
                      subtitle: const Text(
                        'Перенести настройки с другого устройства',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _importProfile(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Синхронизация по локальной сети'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.sync_rounded),
                  title: const Text('Устройства и чаты'),
                  subtitle: const Text(
                    'Объединять чаты и серверы между устройствами в одной сети',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const SyncScreen())),
                ),
              ),
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Обновления'),
              const UpdateSettingsTile(),
              if (desktop) ...[
                const SizedBox(height: 14),
                const _SectionHeader(title: 'Горячие клавиши'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Column(
                      children: const [
                        _ShortcutRow(keys: 'Ctrl+N', label: 'Новый чат'),
                        SizedBox(height: 10),
                        _ShortcutRow(keys: 'Ctrl+F', label: 'Поиск по чатам'),
                        SizedBox(height: 10),
                        _ShortcutRow(keys: 'Ctrl+B', label: 'Свернуть сайдбар'),
                        SizedBox(height: 10),
                        _ShortcutRow(keys: 'Ctrl+,', label: 'Настройки'),
                        SizedBox(height: 10),
                        _ShortcutRow(keys: 'Esc', label: 'Остановить ответ'),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              const _SectionHeader(title: 'Как подключить LM Studio'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Step(
                        '1',
                        'Откройте LM Studio → Developer → Start Server. '
                            'Порт по умолчанию — 1234.',
                      ),
                      _Step(
                        '2',
                        'Включите «Serve on Local Network». '
                            'Для web-клиентов также «Enable CORS».',
                      ),
                      _Step(
                        '3',
                        'Узнайте IP компьютера с Ubuntu: hostname -I или ip -4 addr. '
                            'Нужен адрес вида 192.168.x.x.',
                      ),
                      _Step(
                        '4',
                        'Телефон и компьютер должны быть в одной Wi-Fi сети. '
                            'Если на Ubuntu включён ufw, разрешите порт: '
                            'sudo ufw allow 1234/tcp.',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Адрес сервера указывается без /v1: '
                        'http://192.168.1.50:1234',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  'LM Chat · $appVersionLabel\nРаботает только в локальной сети',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _exportProfile(BuildContext context) async {
  final result = await context.read<AppState>().exportProfile();
  if (!context.mounted || result.cancelled) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(result.error ?? L10n.t('Профиль сохранён'))),
    );
}

Future<void> _importProfile(BuildContext context) async {
  final state = context.read<AppState>();
  final preview = await state.pickProfilePreview();
  if (!context.mounted || preview.cancelled) return;
  if (!preview.ok) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            preview.error ?? L10n.t('Не удалось прочитать профиль'),
          ),
        ),
      );
    return;
  }

  final options = await showProfileImportSheet(context, preview);
  if (!context.mounted || options == null) return;
  final result = state.importProfile(preview, options: options);
  final parts = <String>[
    if (result.serversAdded > 0)
      L10n.tf('новых серверов: {count}', {'count': result.serversAdded}),
    if (result.serversUpdated > 0)
      L10n.tf('обновлено серверов: {count}', {'count': result.serversUpdated}),
    if (result.templates > 0)
      L10n.tf('промптов: {count}', {'count': result.templates}),
  ];
  final message =
      result.error ??
      (parts.isEmpty
          ? L10n.t('Профиль применён')
          : '${L10n.t('Профиль применён')} · ${parts.join(' · ')}');
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.label});

  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          constraints: const BoxConstraints(minWidth: 66),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Text(
            keys,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

String _fontLabel(AppFontFamily font) => switch (font) {
  AppFontFamily.system => L10n.t('Системный'),
  AppFontFamily.inter => 'Inter',
  AppFontFamily.manrope => 'Manrope',
  AppFontFamily.custom => L10n.t('Свой шрифт'),
};

Future<void> _importFont(BuildContext context) async {
  final state = context.read<AppState>();
  final result = await state.importCustomFont();
  if (!context.mounted || result.cancelled) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(result.error ?? L10n.t('Шрифт добавлен'))),
    );
}

Future<void> _removeFont(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Удалить шрифт?'),
      content: const Text(
        'Файл будет удалён с этого устройства, интерфейс вернётся '
        'к системному шрифту.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Удалить'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await context.read<AppState>().removeCustomFont();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(const SnackBar(content: Text('Шрифт удалён')));
}

class _FontOption extends StatelessWidget {
  const _FontOption({
    required this.family,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String? family;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 112,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? scheme.primary
                    : scheme.outlineVariant.withValues(alpha: 0.7),
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aa',
                  style: TextStyle(
                    fontFamily: family,
                    fontSize: 22,
                    height: 1,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomFontTile extends StatelessWidget {
  const _CustomFontTile({
    required this.name,
    required this.selected,
    required this.onSelect,
    required this.onImport,
    required this.onRemove,
  });

  final String name;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onImport;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasFont = name.isNotEmpty;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: hasFont ? onSelect : onImport,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.7),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                hasFont
                    ? Icons.font_download_rounded
                    : Icons.font_download_outlined,
                size: 22,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasFont ? name : 'Свой TTF-шрифт',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasFont
                          ? (selected
                                ? 'Используется'
                                : 'Нажмите, чтобы применить')
                          : 'Файл хранится только на этом устройстве',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasFont) ...[
                IconButton(
                  onPressed: onImport,
                  icon: const Icon(Icons.upload_file_rounded, size: 19),
                  tooltip: L10n.t('Заменить шрифт'),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline_rounded, size: 19),
                  tooltip: L10n.t('Удалить шрифт'),
                  color: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
              ] else
                TextButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: const Text('Импорт'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _defaultsSummary(BuildContext context, AppData data) {
  final format = data.defaultResponseFormat;
  return [
    'T ${data.defaultTemperature.toStringAsFixed(2)}',
    'top_p ${data.defaultTopP.toStringAsFixed(2)}',
    if (data.defaultTopK > 0) 'top_k ${data.defaultTopK}',
    if (data.defaultRepeatPenalty != 1.0)
      'repeat ${data.defaultRepeatPenalty.toStringAsFixed(2)}',
    data.defaultMaxTokens > 0
        ? '${data.defaultMaxTokens} ${L10n.t('ток.')}'
        : L10n.t('без лимита'),
    data.defaultSystemPrompt.isEmpty
        ? L10n.t('без системного промпта')
        : L10n.t('есть системный промпт'),
    if (!format.isText)
      switch (format.mode) {
        ResponseFormatMode.json => 'JSON',
        ResponseFormatMode.jsonSchema => L10n.t('JSON по схеме'),
        ResponseFormatMode.grammar => 'GBNF',
        ResponseFormatMode.text => '',
      },
  ].join(' · ');
}

String _launchSummary(LaunchSettings launch) => [
  launch.loadOnDemand
      ? L10n.t('загрузка по требованию')
      : L10n.t('загрузка заранее'),
  L10n.tf('контекст: {value}', {'value': formatContext(launch.contextLength)}),
  if (launch.gpuRatio != null)
    L10n.tf('GPU: {value}', {'value': formatGpuRatio(launch.gpuRatio)}),
  L10n.tf('TTL: {value}', {'value': formatDuration(launch.ttlSeconds)}),
].join(' · ');

String _hostOf(String url) =>
    url.replaceFirst('http://', '').replaceFirst('https://', '');

bool get _canScanQr =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> _shareAllServers(BuildContext context, AppState state) {
  return showServerShareSheet(context, servers: state.servers, all: true);
}

Future<void> _addServerAction(BuildContext context, String value) async {
  switch (value) {
    case 'add':
      await _editServer(context);
    case 'import':
      await showServerImportDialog(context);
    case 'scan':
      await _scanServerQr(context);
  }
}

Future<void> _scanServerQr(BuildContext context) async {
  final code = await Navigator.of(context)
      .push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
  if (code == null || !context.mounted) return;
  await showServerImportDialog(context, initialCode: code);
}

Future<void> _editServer(BuildContext context, {ServerConfig? server}) async {
  final state = context.read<AppState>();
  final result = await showDialog<ServerConfig>(
    context: context,
    builder: (_) => ServerEditDialog(server: server),
  );
  if (result == null) return;
  if (server == null) {
    state.addServer(result);
  } else {
    state.updateServer(result);
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.server});

  final ServerConfig server;

  Future<void> _test(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Проверяю подключение…')),
    );
    final result = await state.refreshModels(server);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              'Подключено. Доступно моделей: ${result.models.length}',
        ),
      ),
    );
  }

  Future<void> _connect(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(L10n.tf('Подключаюсь к {name}…', {'name': server.name})),
      ),
    );
    final result = await state.connectToServer(server);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              'Подключено. Доступно моделей: ${result.models.length}',
        ),
      ),
    );
  }

  void _disconnect(BuildContext context) {
    context.read<AppState>().disconnectServer();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(L10n.t('Отключено от сервера'))));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final active = state.activeServer?.id == server.id;
    final count = state.modelsFor(server.id).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
        child: Row(
          children: [
            Icon(
              Icons.dns_rounded,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: state.isServerOnline(server.id)
                              ? AppColors.of(context).success
                              : scheme.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          server.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (active) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'подключён',
                            style: TextStyle(
                              fontSize: 10,
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    serverLabel(server),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (count > 0)
                    Text(
                      L10n.tf('Моделей: {count}', {'count': count}),
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                  if (server.hasBridge)
                    Text(
                      L10n.tf('Мостик GPU: {host}', {
                        'host': _hostOf(server.normalizedBridge),
                      }),
                      style: TextStyle(fontSize: 11, color: scheme.tertiary),
                    ),
                  if (server.securityError != null)
                    Text(
                      server.securityError!,
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                ],
              ),
            ),
            if (ServerShareCodec.supports(
                  server,
                  ServerShareMode.withoutRelay,
                ) ||
                ServerShareCodec.supports(server, ServerShareMode.withRelay))
              IconButton(
                onPressed: () => showServerShareSheet(
                  context,
                  servers: [server],
                  all: false,
                ),
                icon: const Icon(Icons.ios_share_rounded, size: 20),
                tooltip: L10n.t('Поделиться сервером'),
                visualDensity: VisualDensity.compact,
              ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                switch (value) {
                  case 'connect':
                    await _connect(context);
                  case 'disconnect':
                    _disconnect(context);
                  case 'test':
                    await _test(context);
                  case 'edit':
                    await _editServer(context, server: server);
                  case 'delete':
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Удалить сервер?'),
                        content: Text(
                          L10n.tf(
                            '«{name}» будет удалён из списка. История чатов сохранится.',
                            {'name': server.name},
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Отмена'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('Удалить'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) state.deleteServer(server.id);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: active ? 'disconnect' : 'connect',
                  child: Row(
                    children: [
                      Icon(
                        active ? Icons.link_off_rounded : Icons.link_rounded,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(active ? 'Отключиться' : 'Подключиться'),
                    ],
                  ),
                ),
                const PopupMenuItem(value: 'test', child: Text('Проверить')),
                const PopupMenuItem(value: 'edit', child: Text('Изменить')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: [
          Text(
            L10n.t(title).toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);

  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

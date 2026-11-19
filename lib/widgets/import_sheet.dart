import 'package:flutter/material.dart' hide Text;

import '../import_options.dart';
import '../l10n_text.dart';

/// Shows import options before the user picks a JSON file.
Future<ImportOptions?> showImportSheet(BuildContext context) {
  return showModalBottomSheet<ImportOptions>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => const _ImportSheet(),
  );
}

class _ImportSheet extends StatefulWidget {
  const _ImportSheet();

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  var _options = const ImportOptions(skipExisting: true);

  void _update(ImportOptions options) => setState(() => _options = options);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.file_open_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Импорт',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  Text(
                    'История, серверы и шаблоны промптов из JSON-файла LM Chat.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel('Что импортировать'),
                  const SizedBox(height: 4),
                  _ImportSwitch(
                    title: 'Серверы и настройки',
                    subtitle: 'Без токенов и паролей',
                    value: _options.includeServers,
                    onChanged: (value) =>
                        _update(_options.copyWith(includeServers: value)),
                  ),
                  _ImportSwitch(
                    title: 'Шаблоны промптов',
                    value: _options.includeTemplates,
                    onChanged: (value) =>
                        _update(_options.copyWith(includeTemplates: value)),
                  ),
                  _ImportSwitch(
                    title: 'Архивные чаты',
                    value: _options.includeArchived,
                    onChanged: (value) =>
                        _update(_options.copyWith(includeArchived: value)),
                  ),
                  const SizedBox(height: 8),
                  _SectionLabel('Параметры'),
                  const SizedBox(height: 4),
                  _ImportSwitch(
                    title: 'Пропускать уже существующие чаты',
                    subtitle: 'Не создавать копии при повторном импорте',
                    value: _options.skipExisting,
                    onChanged: (value) =>
                        _update(_options.copyWith(skipExisting: value)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'После выбора файла можно отметить нужные чаты.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(_options),
                icon: const Icon(Icons.file_open_outlined, size: 19),
                label: const Text('Выбрать файл JSON'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.2),
    );
  }
}

class _ImportSwitch extends StatelessWidget {
  const _ImportSwitch({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
      value: value,
      onChanged: onChanged,
    );
  }
}

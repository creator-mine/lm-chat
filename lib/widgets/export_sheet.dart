import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../export_options.dart';
import '../format_utils.dart';
import '../l10n_text.dart';
import '../models.dart';

/// Opens the export sheet. [chat] preselects the current chat when the sheet
/// was opened from the chat menu.
Future<void> showExportSheet(BuildContext context, {ChatSession? chat}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _ExportSheet(chat: chat),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({this.chat});

  final ChatSession? chat;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late ExportOptions _options = ExportOptions(
    scope: widget.chat == null ? ExportScope.allChats : ExportScope.currentChat,
  );

  void _update(ExportOptions options) => setState(() => _options = options);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<AppState>();
    final current = widget.chat ?? state.activeChat;
    final allChats = [
      for (final chat in state.chats)
        if (_options.includeArchived || !chat.archived) chat,
    ];
    final selectedChats = _options.scope == ExportScope.currentChat
        ? [?current]
        : allChats;
    final messageCount = selectedChats.fold<int>(
      0,
      (sum, chat) => sum + chat.messages.length,
    );
    final attachmentBytes = _options.scope == ExportScope.currentChat
        ? _attachmentBytes(selectedChats)
        : state.exportAttachmentBytes(_options);
    final isJson = _options.format == ExportFormat.json;
    final canExport = selectedChats.isNotEmpty;

    final summary = <String>[
      L10n.tf('Чатов: {count}', {'count': selectedChats.length}),
      L10n.tf('Сообщений: {count}', {'count': messageCount}),
      if (isJson && _options.includeAttachments && attachmentBytes > 0)
        L10n.tf('Изображения: {size}', {'size': formatSize(attachmentBytes)}),
    ].join(' · ');

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
                Icon(Icons.ios_share_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Экспорт',
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
                  SegmentedButton<ExportFormat>(
                    segments: const [
                      ButtonSegment(
                        value: ExportFormat.json,
                        label: Text('JSON'),
                        icon: Icon(Icons.data_object_rounded, size: 18),
                      ),
                      ButtonSegment(
                        value: ExportFormat.markdown,
                        label: Text('Markdown'),
                        icon: Icon(Icons.description_outlined, size: 18),
                      ),
                    ],
                    selected: {_options.format},
                    onSelectionChanged: (selection) =>
                        _update(_options.copyWith(format: selection.first)),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel('Что экспортировать'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      ChoiceChip(
                        label: Text('Все чаты'),
                        selected: _options.scope == ExportScope.allChats,
                        onSelected: (_) => _update(
                          _options.copyWith(scope: ExportScope.allChats),
                        ),
                      ),
                      if (current != null)
                        ChoiceChip(
                          label: const Text('Текущий чат'),
                          selected: _options.scope == ExportScope.currentChat,
                          onSelected: (_) => _update(
                            _options.copyWith(scope: ExportScope.currentChat),
                          ),
                        ),
                    ],
                  ),
                  if (current != null &&
                      _options.scope == ExportScope.currentChat) ...[
                    const SizedBox(height: 6),
                    Text(
                      current.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _SectionLabel('Параметры'),
                  const SizedBox(height: 4),
                  if (isJson) ...[
                    if (_options.scope == ExportScope.allChats)
                      _ExportSwitch(
                        title: 'Серверы и настройки',
                        subtitle: 'Без токенов и паролей',
                        value: _options.includeServers,
                        onChanged: (value) =>
                            _update(_options.copyWith(includeServers: value)),
                      ),
                    if (_options.scope == ExportScope.allChats)
                      _ExportSwitch(
                        title: 'Шаблоны промптов',
                        value: _options.includeTemplates,
                        onChanged: (value) =>
                            _update(_options.copyWith(includeTemplates: value)),
                      ),
                    _ExportSwitch(
                      title: 'Изображения-вложения',
                      subtitle: 'Увеличивают размер файла',
                      value: _options.includeAttachments,
                      onChanged: (value) =>
                          _update(_options.copyWith(includeAttachments: value)),
                    ),
                  ] else ...[
                    _ExportSwitch(
                      title: 'Размышления модели',
                      value: _options.includeReasoning,
                      onChanged: (value) =>
                          _update(_options.copyWith(includeReasoning: value)),
                    ),
                    _ExportSwitch(
                      title: 'Статистика генерации',
                      subtitle: 'Токены, скорость и первый токен',
                      value: _options.includeStats,
                      onChanged: (value) =>
                          _update(_options.copyWith(includeStats: value)),
                    ),
                    _ExportSwitch(
                      title: 'Имена вложений',
                      value: _options.includeAttachmentNames,
                      onChanged: (value) => _update(
                        _options.copyWith(includeAttachmentNames: value),
                      ),
                    ),
                  ],
                  if (_options.scope == ExportScope.allChats)
                    _ExportSwitch(
                      title: 'Включать архивные чаты',
                      value: _options.includeArchived,
                      onChanged: (value) =>
                          _update(_options.copyWith(includeArchived: value)),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    summary,
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
                onPressed: canExport ? _export : null,
                icon: const Icon(Icons.file_download_outlined, size: 19),
                label: const Text('Экспортировать'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _attachmentBytes(List<ChatSession> chats) {
    var total = 0;
    for (final chat in chats) {
      for (final message in chat.messages) {
        for (final attachment in message.attachments) {
          total += attachment.data.length * 3 ~/ 4;
        }
      }
    }
    return total;
  }

  void _export() {
    final state = context.read<AppState>();
    Navigator.of(context).pop();
    state.exportWithOptions(_options, chat: widget.chat);
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

class _ExportSwitch extends StatelessWidget {
  const _ExportSwitch({
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

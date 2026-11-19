import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../l10n_text.dart';
import '../models.dart';
import '../screens/settings_screen.dart';
import '../theme.dart';
import 'export_sheet.dart';
import 'model_picker.dart';

class SidebarResizer extends StatelessWidget {
  const SidebarResizer({
    super.key,
    required this.onDrag,
    required this.onReset,
  });

  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        onDoubleTap: onReset,
        child: Tooltip(
          message: L10n.t('Изменить ширину списка чатов'),
          child: SizedBox(
            width: 8,
            height: double.infinity,
            child: Center(
              child: Container(
                width: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppDrawer extends StatelessWidget {
  const AppDrawer({
    super.key,
    required this.onNewChat,
    required this.onImport,
    required this.onDeleteChat,
    required this.onRenameChat,
    this.onCollapse,
    this.chatListKey,
    this.embedded = false,
    this.closeOnSelect = true,
  });

  final VoidCallback onNewChat;
  final Future<void> Function() onImport;
  final Future<void> Function(ChatSession) onDeleteChat;
  final Future<void> Function(ChatSession) onRenameChat;

  /// Hides the permanent desktop sidebar. Null in drawer mode.
  final VoidCallback? onCollapse;
  final Key? chatListKey;

  /// Desktop sidebar: no drawer animation, always visible.
  final bool embedded;
  final bool closeOnSelect;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final server = state.activeServer;
    final colors = AppColors.of(context);

    final content = SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      colors: [scheme.primary, scheme.tertiary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Icon(
                    Icons.forum_rounded,
                    size: 21,
                    color: scheme.onPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LM Chat',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: server == null
                                  ? scheme.outline
                                  : state.isOffline
                                  ? scheme.error
                                  : colors.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              server == null
                                  ? (state.servers.isEmpty
                                        ? 'нет сервера'
                                        : 'не подключено')
                                  : serverLabel(server),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (onCollapse != null)
                  IconButton(
                    onPressed: onCollapse,
                    icon: const Icon(Icons.menu_open_rounded, size: 20),
                    tooltip: L10n.t('Скрыть список чатов'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: FilledButton.icon(
              onPressed: onNewChat,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Новый чат'),
              style: FilledButton.styleFrom(
                minimumSize: Size.fromHeight(
                  AppDensity.isCompact(context) ? 42 : 46,
                ),
              ),
            ),
          ),
          Expanded(
            child: ChatList(
              key: chatListKey,
              onDeleteChat: onDeleteChat,
              onRenameChat: onRenameChat,
              closeOnSelect: closeOnSelect,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.dns_outlined, size: 20),
                  title: const Text(
                    'Серверы и настройки',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  subtitle: Text(
                    L10n.tf('{count} сервер(ов)', {
                      'count': state.servers.length,
                    }),
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () {
                    if (!embedded) Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    );
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.file_open_outlined, size: 20),
                  title: const Text(
                    'Импорт истории',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  subtitle: const Text(
                    'Объединить с текущими чатами из JSON',
                    style: TextStyle(fontSize: 11),
                  ),
                  onTap: onImport,
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.ios_share_rounded, size: 20),
                  title: const Text(
                    'Экспорт',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  onTap: () {
                    if (!embedded) Navigator.of(context).pop();
                    showExportSheet(context);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (embedded) {
      return Material(
        color: colors.sidebar,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
          child: content,
        ),
      );
    }
    return Drawer(child: content);
  }
}

class ChatList extends StatefulWidget {
  const ChatList({
    super.key,
    required this.onDeleteChat,
    required this.onRenameChat,
    this.closeOnSelect = true,
  });

  final Future<void> Function(ChatSession) onDeleteChat;
  final Future<void> Function(ChatSession) onRenameChat;
  final bool closeOnSelect;

  @override
  State<ChatList> createState() => ChatListState();
}

class ChatListState extends State<ChatList> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';
  bool _showArchived = false;

  void focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  List<ChatSession> _filtered(List<ChatSession> chats) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return chats;
    return chats.where((chat) {
      if (chat.title.toLowerCase().contains(query)) return true;
      if (chat.model.toLowerCase().contains(query)) return true;
      return chat.messages.any(
        (message) => message.displayContent.toLowerCase().contains(query),
      );
    }).toList();
  }

  Future<void> _showActions(ChatSession chat) async {
    final state = context.read<AppState>();
    ChatSession? parent;
    for (final candidate in state.chats) {
      if (candidate.id == chat.parentChatId) {
        parent = candidate;
        break;
      }
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 460),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                chat.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              ),
              title: Text(chat.pinned ? 'Открепить' : 'Закрепить'),
              onTap: () {
                Navigator.pop(sheetContext);
                state.togglePinned(chat);
              },
            ),
            ListTile(
              leading: Icon(
                chat.archived
                    ? Icons.unarchive_rounded
                    : Icons.archive_outlined,
              ),
              title: Text(chat.archived ? 'Вернуть из архива' : 'Архивировать'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (chat.archived) {
                  state.unarchiveChat(chat);
                } else {
                  state.archiveChat(chat);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Переименовать'),
              onTap: () {
                Navigator.pop(sheetContext);
                widget.onRenameChat(chat);
              },
            ),
            if (parent != null)
              ListTile(
                leading: const Icon(Icons.call_split_rounded),
                title: const Text('Открыть исходный чат'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  state.selectChat(parent!);
                },
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(
                'Удалить',
                style: TextStyle(
                  color: Theme.of(sheetContext).colorScheme.error,
                ),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                widget.onDeleteChat(chat);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final source = _showArchived ? state.archivedChats : state.activeChats;
    final chats = _filtered(source);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            key: const ValueKey('chat-search-field'),
            controller: _search,
            focusNode: _searchFocus,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: L10n.t('Поиск по чатам и сообщениям'),
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: L10n.t('Очистить'),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 8, 2),
          child: Row(
            children: [
              Text(
                _showArchived ? 'АРХИВ' : 'ЧАТЫ',
                style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.9,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _showArchived = !_showArchived;
                  _query = '';
                  _search.clear();
                }),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  _showArchived
                      ? L10n.t('К активным')
                      : L10n.tf('Архив ({count})', {
                          'count': state.archivedChats.length,
                        }),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: chats.isEmpty
              ? Center(
                  child: Text(
                    _query.isNotEmpty
                        ? 'Ничего не найдено'
                        : _showArchived
                        ? 'Архив пуст'
                        : 'Пока нет чатов',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  itemCount: chats.length,
                  itemBuilder: (context, index) {
                    final chat = chats[index];
                    return ChatTile(
                      chat: chat,
                      selected: chat.id == state.activeChat?.id,
                      generating: state.isGenerating(chat),
                      onTap: () {
                        state.selectChat(chat);
                        if (widget.closeOnSelect) {
                          Navigator.of(context).maybePop();
                        }
                      },
                      onLongPress: () => _showActions(chat),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.chat,
    required this.selected,
    required this.generating,
    required this.onTap,
    required this.onLongPress,
  });

  final ChatSession chat;
  final bool selected;
  final bool generating;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _chatPreview(chat);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.16)
                        : scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    chat.archived
                        ? Icons.inventory_2_outlined
                        : Icons.chat_bubble_outline_rounded,
                    size: 17,
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              chat.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _formatChatTime(chat.updatedAt),
                            style: TextStyle(
                              fontSize: 10.5,
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (chat.pinned || generating || chat.parentChatId != null) ...[
                  const SizedBox(width: 6),
                  if (chat.parentChatId != null)
                    Icon(
                      Icons.call_split_rounded,
                      size: 14,
                      color: scheme.tertiary,
                    ),
                  if (chat.pinned)
                    Icon(
                      Icons.push_pin_rounded,
                      size: 14,
                      color: scheme.primary,
                    ),
                  if (generating) ...[
                    if (chat.pinned) const SizedBox(width: 5),
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _chatPreview(ChatSession chat) {
  if (chat.messages.isEmpty) {
    return chat.model.isEmpty ? 'Нет сообщений' : chat.model;
  }
  final last = chat.messages.last;
  final text = last.displayContent.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isNotEmpty) return text;
  if (last.attachments.isNotEmpty) return L10n.t('Изображение');
  return chat.model.isEmpty ? 'Нет сообщений' : chat.model;
}

String _formatChatTime(DateTime date) {
  final local = date.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  String two(int value) => value.toString().padLeft(2, '0');
  if (day == today) return '${two(local.hour)}:${two(local.minute)}';
  if (day == today.subtract(const Duration(days: 1))) {
    return L10n.t('Вчера');
  }
  if (local.year == now.year) return '${two(local.day)}.${two(local.month)}';
  return '${two(local.day)}.${two(local.month)}.${local.year % 100}';
}

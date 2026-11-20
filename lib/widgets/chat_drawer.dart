import 'package:flutter/gestures.dart';
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
                                  : server.hasRelay
                                  ? L10n.t('Подключено к реле')
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
  bool _selecting = false;
  bool _reordering = false;
  final Set<String> _selectedChatIds = {};

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

  Future<void> _showActions(ChatSession chat, Offset position) async {
    final state = context.read<AppState>();
    ChatSession? parent;
    for (final candidate in state.chats) {
      if (candidate.id == chat.parentChatId) {
        parent = candidate;
        break;
      }
    }
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.sizeOf(context);
    final action = await showMenu<_ChatAction>(
      context: context,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & size,
      ),
      items: [
        const PopupMenuItem(
          value: _ChatAction.rename,
          child: _ChatMenuRow(Icons.edit_rounded, 'Переименовать'),
        ),
        PopupMenuItem(
          value: chat.pinned ? _ChatAction.unpin : _ChatAction.pin,
          child: _ChatMenuRow(
            chat.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            chat.pinned ? 'Открепить' : 'Закрепить',
          ),
        ),
        PopupMenuItem(
          value: chat.archived ? _ChatAction.unarchive : _ChatAction.archive,
          child: _ChatMenuRow(
            chat.archived ? Icons.unarchive_rounded : Icons.archive_outlined,
            chat.archived ? 'Вернуть из архива' : 'Архивировать',
          ),
        ),
        if (parent != null)
          const PopupMenuItem(
            value: _ChatAction.openParent,
            child: _ChatMenuRow(
              Icons.call_split_rounded,
              'Открыть исходный чат',
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _ChatAction.select,
          child: _ChatMenuRow(Icons.checklist_rounded, 'Выбрать несколько'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _ChatAction.delete,
          child: _ChatMenuRow(
            Icons.delete_outline_rounded,
            'Удалить',
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ChatAction.rename:
        await widget.onRenameChat(chat);
      case _ChatAction.pin:
      case _ChatAction.unpin:
        state.togglePinned(chat);
      case _ChatAction.archive:
        state.archiveChat(chat);
      case _ChatAction.unarchive:
        state.unarchiveChat(chat);
      case _ChatAction.openParent:
        if (parent != null) state.selectChat(parent);
      case _ChatAction.select:
        _startSelection(chat);
      case _ChatAction.delete:
        await widget.onDeleteChat(chat);
    }
  }

  void _startReorder() {
    if (_selecting) return;
    setState(() {
      _reordering = true;
      _query = '';
      _search.clear();
      _searchFocus.unfocus();
    });
  }

  void _exitReorder() {
    if (!_reordering) return;
    setState(() => _reordering = false);
  }

  void _reorderGroup(
    List<ChatSession> group,
    int oldIndex,
    int newIndex, {
    required bool pinned,
  }) {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= group.length) return;
    final ordered = [...group];
    final chat = ordered.removeAt(oldIndex);
    ordered.insert(newIndex.clamp(0, ordered.length), chat);
    context.read<AppState>().reorderChatGroup(
      ordered,
      archived: _showArchived,
      pinned: pinned,
    );
  }

  void _startSelection([ChatSession? chat]) {
    if (_reordering) return;
    setState(() {
      _selecting = true;
      _selectedChatIds.clear();
      if (chat != null) _selectedChatIds.add(chat.id);
      _searchFocus.unfocus();
    });
  }

  void _exitSelection() {
    if (!_selecting) return;
    setState(() {
      _selecting = false;
      _selectedChatIds.clear();
    });
  }

  void _toggleChatSelection(ChatSession chat) {
    setState(() {
      if (!_selectedChatIds.remove(chat.id)) {
        _selectedChatIds.add(chat.id);
      }
    });
  }

  void _toggleSelectAll(List<ChatSession> chats) {
    if (chats.isEmpty) return;
    final allSelected = chats.every(
      (chat) => _selectedChatIds.contains(chat.id),
    );
    setState(() {
      if (allSelected) {
        _selectedChatIds.removeAll(chats.map((chat) => chat.id));
      } else {
        _selectedChatIds.addAll(chats.map((chat) => chat.id));
      }
    });
  }

  List<ChatSession> _selectedChats() {
    final state = context.read<AppState>();
    return [
      for (final chat in state.chats)
        if (_selectedChatIds.contains(chat.id)) chat,
    ];
  }

  void _pinSelected() {
    final selected = _selectedChats();
    if (selected.isEmpty) return;
    final pin = selected.any((chat) => !chat.pinned);
    context.read<AppState>().setPinnedChats(selected, pin);
    _exitSelection();
  }

  void _archiveSelected() {
    final selected = _selectedChats();
    if (selected.isEmpty) return;
    context.read<AppState>().archiveChats(selected, archived: !_showArchived);
    _exitSelection();
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedChats();
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить выбранные чаты?'),
        content: Text(
          L10n.tf('Будет удалено чатов: {count}. Действие нельзя отменить.', {
            'count': selected.length,
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = context.read<AppState>().deleteChats(selected);
    if (!mounted) return;
    _exitSelection();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(L10n.tf('Удалено чатов: {count}', {'count': removed})),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final source = _showArchived ? state.archivedChats : state.activeChats;
    final chats = _filtered(source);
    final selectedChats = _selectedChats();
    final allVisibleSelected =
        chats.isNotEmpty &&
        chats.every((chat) => _selectedChatIds.contains(chat.id));
    final allPinned =
        selectedChats.isNotEmpty && selectedChats.every((chat) => chat.pinned);
    final hasSelection = selectedChats.isNotEmpty;

    return Column(
      children: [
        if (_selecting)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
            child: Row(
              children: [
                IconButton(
                  onPressed: _exitSelection,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: L10n.t('Отмена'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                ),
                Expanded(
                  child: Text(
                    L10n.tf('Выбрано: {count}', {
                      'count': _selectedChatIds.length,
                    }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: chats.isEmpty
                      ? null
                      : () => _toggleSelectAll(chats),
                  icon: Icon(
                    allVisibleSelected
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                    size: 19,
                  ),
                  tooltip: allVisibleSelected
                      ? L10n.t('Снять все')
                      : L10n.t('Выбрать все'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                ),
                IconButton(
                  onPressed: hasSelection ? _pinSelected : null,
                  icon: Icon(
                    allPinned
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                    size: 19,
                  ),
                  tooltip: allPinned
                      ? L10n.t('Открепить выбранные')
                      : L10n.t('Закрепить выбранные'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                ),
                IconButton(
                  onPressed: hasSelection ? _archiveSelected : null,
                  icon: Icon(
                    _showArchived
                        ? Icons.unarchive_rounded
                        : Icons.archive_outlined,
                    size: 19,
                  ),
                  tooltip: _showArchived
                      ? L10n.t('Вернуть выбранные из архива')
                      : L10n.t('Архивировать выбранные'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                ),
                IconButton(
                  onPressed: hasSelection ? _deleteSelected : null,
                  icon: const Icon(Icons.delete_outline_rounded, size: 19),
                  color: hasSelection ? scheme.error : null,
                  tooltip: L10n.t('Удалить выбранные'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 34,
                  ),
                ),
              ],
            ),
          )
        else if (_reordering)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
            child: Row(
              children: [
                IconButton(
                  onPressed: _exitReorder,
                  icon: const Icon(Icons.close_rounded, size: 20),
                  tooltip: L10n.t('Выйти из режима'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Text(
                    L10n.t('Перетащите чаты вверх или вниз'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _exitReorder,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Готово'),
                ),
              ],
            ),
          )
        else ...[
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
                IconButton(
                  onPressed: source.length < 2 ? null : _startReorder,
                  icon: const Icon(Icons.swap_vert_rounded, size: 18),
                  tooltip: L10n.t('Изменить порядок'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
                IconButton(
                  onPressed: chats.isEmpty ? null : () => _startSelection(),
                  icon: const Icon(Icons.checklist_rounded, size: 18),
                  tooltip: L10n.t('Выбрать несколько'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
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
        ],
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
              : _reordering
              ? _buildReorderList(state, chats)
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
                      selectionMode: _selecting,
                      checked: _selectedChatIds.contains(chat.id),
                      selected: !_selecting && chat.id == state.activeChat?.id,
                      generating: state.isGenerating(chat),
                      onTap: () {
                        if (_selecting) {
                          _toggleChatSelection(chat);
                          return;
                        }
                        state.selectChat(chat);
                        if (widget.closeOnSelect) {
                          Navigator.of(context).maybePop();
                        }
                      },
                      onLongPress: (position) {
                        if (_selecting) {
                          _toggleChatSelection(chat);
                          return;
                        }
                        _showActions(chat, position);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildReorderList(AppState state, List<ChatSession> chats) {
    final pinned = chats.where((chat) => chat.pinned).toList(growable: false);
    final regular = chats.where((chat) => !chat.pinned).toList(growable: false);
    return CustomScrollView(
      slivers: [
        if (pinned.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _ChatGroupLabel(title: L10n.t('Закреплённые')),
          ),
          _reorderSliver(state, pinned, pinned: true),
        ],
        if (regular.isNotEmpty) ...[
          if (pinned.isNotEmpty)
            SliverToBoxAdapter(
              child: _ChatGroupLabel(title: L10n.t('Остальные')),
            ),
          _reorderSliver(state, regular, pinned: false),
        ],
      ],
    );
  }

  Widget _reorderSliver(
    AppState state,
    List<ChatSession> group, {
    required bool pinned,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      sliver: SliverReorderableList(
        itemCount: group.length,
        onReorderItem: (oldIndex, newIndex) =>
            _reorderGroup(group, oldIndex, newIndex, pinned: pinned),
        proxyDecorator: (child, index, animation) => Material(
          color: Colors.transparent,
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: child,
        ),
        itemBuilder: (context, index) {
          final chat = group[index];
          return ReorderableDelayedDragStartListener(
            key: ValueKey('reorder-${chat.id}'),
            index: index,
            child: ChatTile(
              chat: chat,
              selected: false,
              generating: state.isGenerating(chat),
              reorderMode: true,
              reorderIndex: index,
              onTap: () {},
              onLongPress: (_) {},
            ),
          );
        },
      ),
    );
  }
}

/// Long press delay for the chat context menu. Faster than Flutter's default
/// 500 ms so the menu feels immediate on phones.
const Duration kChatLongPressDuration = Duration(milliseconds: 250);

class ChatTile extends StatelessWidget {
  const ChatTile({
    super.key,
    required this.chat,
    required this.selected,
    required this.generating,
    required this.onTap,
    required this.onLongPress,
    this.selectionMode = false,
    this.checked = false,
    this.reorderMode = false,
    this.reorderIndex,
  });

  final ChatSession chat;
  final bool selected;
  final bool generating;
  final VoidCallback onTap;
  final ValueChanged<Offset> onLongPress;
  final bool selectionMode;
  final bool checked;
  final bool reorderMode;
  final int? reorderIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _chatPreview(chat);
    final highlighted = selectionMode ? checked : selected;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: RawGestureDetector(
        gestures: reorderMode
            ? const <Type, GestureRecognizerFactory>{}
            : <Type, GestureRecognizerFactory>{
                LongPressGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      LongPressGestureRecognizer
                    >(
                      () => LongPressGestureRecognizer(
                        duration: kChatLongPressDuration,
                      ),
                      (recognizer) {
                        recognizer.onLongPressStart = (details) =>
                            onLongPress(details.globalPosition);
                      },
                    ),
              },
        child: GestureDetector(
          onSecondaryTapUp: (details) => onLongPress(details.globalPosition),
          child: Material(
            color: highlighted
                ? scheme.primary.withValues(alpha: selectionMode ? 0.16 : 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: reorderMode ? null : onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: highlighted
                            ? scheme.primary.withValues(alpha: 0.16)
                            : scheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: selectionMode
                          ? Icon(
                              checked
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              size: 20,
                              color: checked
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            )
                          : Icon(
                              chat.archived
                                  ? Icons.inventory_2_outlined
                                  : Icons.chat_bubble_outline_rounded,
                              size: 17,
                              color: selected
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
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
                                    fontWeight: highlighted
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
                    if (chat.pinned ||
                        generating ||
                        chat.parentChatId != null) ...[
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
                    if (reorderMode && reorderIndex != null) ...[
                      const SizedBox(width: 6),
                      ReorderableDragStartListener(
                        index: reorderIndex!,
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatGroupLabel extends StatelessWidget {
  const _ChatGroupLabel({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.9,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

enum _ChatAction {
  rename,
  pin,
  unpin,
  archive,
  unarchive,
  openParent,
  select,
  delete,
}

class _ChatMenuRow extends StatelessWidget {
  const _ChatMenuRow(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
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

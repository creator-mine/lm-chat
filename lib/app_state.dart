import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'api.dart';
import 'app_log.dart';
import 'custom_font.dart';
import 'export_options.dart';
import 'format_utils.dart';
import 'generation_controller.dart';
import 'history_store.dart';
import 'import_options.dart';
import 'keep_alive.dart';
import 'l10n.dart';
import 'model_catalog.dart';
import 'models.dart';
import 'profile.dart';
import 'secret_store.dart';
import 'server_share.dart';
import 'settings_store.dart';
import 'sync/bundle.dart';
import 'sync/crypto.dart';
import 'sync/merge.dart';
import 'sync/service.dart';

part 'app_state_transfer.dart';

class ModelFetchResult {
  ModelFetchResult({this.models = const [], this.error});

  final List<LmModelInfo> models;
  final String? error;

  bool get ok => error == null;
}

class ImportPreview {
  const ImportPreview({
    this.servers = const [],
    this.chats = const [],
    this.templates = const [],
    this.cancelled = false,
    this.error,
  });

  final List<ServerConfig> servers;
  final List<ChatSession> chats;
  final List<PromptTemplate> templates;
  final bool cancelled;
  final String? error;

  bool get ok => error == null && !cancelled && chats.isNotEmpty;

  int get messageCount =>
      chats.fold(0, (sum, chat) => sum + chat.messages.length);
}

class ImportResult {
  const ImportResult({
    this.chats = 0,
    this.servers = 0,
    this.templates = 0,
    this.skipped = 0,
    this.cancelled = false,
    this.error,
  });

  final int chats;
  final int servers;
  final int templates;
  final int skipped;
  final bool cancelled;
  final String? error;

  bool get ok => error == null && !cancelled;
}

class FontImportResult {
  const FontImportResult({this.cancelled = false, this.error});

  final bool cancelled;
  final String? error;

  bool get ok => error == null && !cancelled;
}

class LaunchApplyResult {
  const LaunchApplyResult({
    this.error,
    this.warning,
    this.command,
    this.viaBridge = false,
  });

  final String? error;
  final String? warning;
  final String? command;
  final bool viaBridge;

  bool get ok => error == null;
}

/// How much of the model context window the current chat occupies.
class ContextUsage {
  const ContextUsage({
    required this.limit,
    required this.used,
    required this.estimated,
    required this.source,
  });

  final int limit;
  final int used;

  /// true — занято посчитано приблизительно, без точного `usage`.
  final bool estimated;

  /// Откуда взят лимит: настройки запуска, загруженный инстанс или модель.
  final String source;

  int get remaining => limit <= used ? 0 : limit - used;

  double get fraction => limit <= 0 ? 0 : (used / limit).clamp(0.0, 1.0);
}

/// Upper bound for a history/profile file before it is read into memory.
const int _maxImportBytes = 32 * 1024 * 1024;

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    LmClient? client,
    SecretStore? secretStore,
    LmClient Function()? generationClientFactory,
  }) : _client = client ?? LmClient(),
       _store = HistoryStore(secretStore: secretStore),
       _generation = GenerationController(
         clientFactory: generationClientFactory,
       ) {
    _store.onStatus = (message) {
      statusMessage = message;
      notifyListeners();
    };
    _settings = SettingsStore(
      dataProvider: () => _store.data,
      onChanged: notifyListeners,
      onSave: _store.scheduleSave,
    );
  }

  final LmClient _client;
  final HistoryStore _store;
  late final SettingsStore _settings;
  final ModelCatalog _catalog = ModelCatalog();

  /// Signature of the launch settings last applied through the GPU bridge,
  /// keyed by server and model. Avoids reloading on every message.
  final Map<String, String> _bridgeApplied = {};

  /// Last known reachability per server. Missing means "not checked yet".
  final Map<String, bool> _serverOnline = {};

  final GenerationController _generation;

  late final SyncService sync = SyncService(
    buildBundle: _buildSyncBundle,
    applyBundle: _applySyncBundle,
  );

  AppData get data => _store.data;

  ChatSession? activeChat;
  bool initialized = false;
  bool checkingConnection = false;
  String? statusMessage;
  String? _lastModel;

  /// Monotonic counter for widgets that need to repaint while the active chat
  /// streams. The home screen selects only stable fields, so the message list
  /// watches this instead of rebuild the whole scaffold on every chunk.
  int revision = 0;

  @override
  void notifyListeners() {
    revision++;
    super.notifyListeners();
  }

  /// Incremented when the app comes back from the background, so the chat can
  /// scroll to the newest text.
  int resumedTick = 0;

  List<ServerConfig> get servers => data.servers;

  List<ChatSession> get chats {
    final list = [...data.chats];
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      if (data.manualChatOrder) {
        final aOrder = a.sortOrder;
        final bOrder = b.sortOrder;
        if (aOrder != null || bOrder != null) {
          if (aOrder == null) return 1;
          if (bOrder == null) return -1;
          final byOrder = aOrder.compareTo(bOrder);
          if (byOrder != 0) return byOrder;
        }
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  bool isGenerating(ChatSession chat) => _generation.isGenerating(chat.id);

  /// Only the open chat controls the composer; other chats may generate in
  /// parallel.
  bool get sending => activeChat != null && isGenerating(activeChat!);

  List<ChatSession> get activeChats =>
      chats.where((chat) => !chat.archived).toList(growable: false);

  List<ChatSession> get archivedChats =>
      chats.where((chat) => chat.archived).toList(growable: false);

  /// Next position that puts a chat on top of its group. Null while the list
  /// still uses the automatic recency order.
  int? _topSortOrder({required bool archived, required bool pinned}) {
    if (!data.manualChatOrder) return null;
    int? min;
    for (final chat in data.chats) {
      if (chat.archived != archived || chat.pinned != pinned) continue;
      final order = chat.sortOrder;
      if (order == null) continue;
      if (min == null || order < min) min = order;
    }
    return min == null ? 0 : min - 1;
  }

  void _placeAtGroupTop(ChatSession chat) {
    final order = _topSortOrder(archived: chat.archived, pinned: chat.pinned);
    if (order != null) chat.sortOrder = order;
  }

  /// Applies the new order of one visible group. The first call switches the
  /// sidebar to manual order, so later messages no longer move chats up.
  void reorderChatGroup(
    List<ChatSession> ordered, {
    required bool archived,
    required bool pinned,
  }) {
    if (ordered.isEmpty) return;
    final current = chats;
    bool inGroup(ChatSession chat) =>
        chat.archived == archived && chat.pinned == pinned;
    final group = current.where(inGroup).toList(growable: false);
    if (group.length != ordered.length) return;
    final expected = {for (final chat in group) chat.id};
    if (expected.length != ordered.length) return;
    if (!ordered.every((chat) => inGroup(chat) && expected.contains(chat.id))) {
      return;
    }
    var unchanged = true;
    for (var i = 0; i < group.length; i++) {
      if (group[i].id != ordered[i].id) {
        unchanged = false;
        break;
      }
    }
    if (unchanged) return;

    final result = <ChatSession>[];
    var inserted = false;
    for (final chat in current) {
      if (inGroup(chat)) {
        if (!inserted) {
          result.addAll(ordered);
          inserted = true;
        }
        continue;
      }
      result.add(chat);
    }
    if (!inserted) return;
    for (var i = 0; i < result.length; i++) {
      result[i].sortOrder = i;
    }
    data.manualChatOrder = true;
    _scheduleSave();
    notifyListeners();
  }

  bool isServerOnline(String? serverId) {
    if (serverId == null) return true;
    return _serverOnline[serverId] ?? true;
  }

  bool get isOffline {
    final server = activeServer;
    return server != null && !isServerOnline(server.id);
  }

  /// Test hook for the connectivity banner.
  @visibleForTesting
  void setServerOnlineForTest(String serverId, bool online) {
    _serverOnline[serverId] = online;
    notifyListeners();
  }

  List<LmModelInfo> modelsFor(String serverId) => _catalog.modelsFor(serverId);

  LmModelInfo? modelInfo(String? serverId, String? modelKey) {
    if (serverId == null || modelKey == null) return null;
    for (final model in _catalog.modelsFor(serverId)) {
      if (model.key == modelKey) return model;
    }
    return null;
  }

  /// Estimates how much of the model context window the chat already uses.
  /// Returns null while the context limit is unknown.
  ContextUsage? contextUsage(ChatSession chat) {
    final info = modelInfo(chat.serverId, chat.model);
    final configured = chat.launch.contextLength;
    int? limit;
    var source = 'модель';
    if (configured != null && configured > 0) {
      limit = configured;
      source = 'настройки запуска';
    } else {
      final loaded = info?.instance?.contextLength;
      if (loaded != null && loaded > 0) {
        limit = loaded;
        source = 'загруженная модель';
      } else if (info?.maxContextLength != null &&
          info!.maxContextLength! > 0) {
        limit = info.maxContextLength;
      }
    }
    if (limit == null) return null;
    final max = info?.maxContextLength;
    if (max != null && max > 0 && limit > max) limit = max;

    var estimated = false;
    var used = 0;
    var baseIndex = -1;
    int? baseTokens;
    for (var i = chat.messages.length - 1; i >= 0; i--) {
      final message = chat.messages[i];
      if (message.role == 'assistant' && message.displayTotalTokens != null) {
        baseIndex = i;
        baseTokens = message.displayTotalTokens;
        estimated = message.displayTokensEstimated;
        break;
      }
    }
    if (baseTokens != null) {
      used = baseTokens;
      // Messages sent after that answer are not included in its prompt yet.
      for (var i = baseIndex + 1; i < chat.messages.length; i++) {
        final message = chat.messages[i];
        final tokens =
            estimateTokens(message.displayContent) +
            message.attachments.length * 256;
        if (tokens > 0) {
          used += tokens;
          estimated = true;
        }
      }
    } else {
      // No exact usage yet: estimate the whole visible history.
      used = estimateTokens(chat.systemPrompt);
      for (final message in chat.messages) {
        used +=
            estimateTokens(message.displayContent) +
            message.attachments.length * 256;
      }
      estimated = true;
    }
    if (used < 0) used = 0;
    if (used > limit) used = limit;

    return ContextUsage(
      limit: limit,
      used: used,
      estimated: estimated,
      source: source,
    );
  }

  /// True when the next message alone would not fit into the free context.
  bool exceedsContext(ChatSession chat, String text, {int imageCount = 0}) {
    final usage = contextUsage(chat);
    if (usage == null) return false;
    return estimateTokens(text) + imageCount * 256 > usage.remaining;
  }

  ServerConfig? serverById(String? id) {
    if (id != null) {
      for (final server in data.servers) {
        if (server.id == id) return server;
      }
    }
    return null;
  }

  ServerConfig? get activeServer {
    final id = data.activeServerId;
    if (id == null) {
      return data.servers.isNotEmpty ? data.servers.first : null;
    }
    return serverById(id);
  }

  /// An empty [AppData.activeServerId] is the explicit "disconnected" state.
  static const String disconnectedServerId = '';

  bool get isDisconnected => data.activeServerId == disconnectedServerId;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sync.dispose();
    _store.dispose();
    _generation.dispose();
    _client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Persist the partial answer immediately: if the process is killed while
      // frozen, the text received so far is not lost.
      unawaited(sync.stopListener());
      _store.cancelScheduledSave();
      _saveNow().catchError((Object error) {
        statusMessage = L10n.tf('Не удалось сохранить: {error}', {
          'error': error,
        });
        notifyListeners();
      });
    } else if (state == AppLifecycleState.resumed) {
      resumedTick++;
      if (sync.enabled) unawaited(sync.startListener());
      // A bridge job may still be generating on the server after the network
      // dropped or the app was frozen. Re-attach the open chat; other chats
      // can be resumed explicitly with the button under the answer.
      unawaited(_resumePendingJobs(onlyChat: activeChat));
      if (isOffline) unawaited(reconnect());
      notifyListeners();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (data.appLanguage == AppLanguage.system) {
      _applyLanguage();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    await _store.load();
    try {
      await sync.init();
    } catch (error) {
      AppLog.instance.warning(
        'Не удалось загрузить настройки синхронизации',
        detail: '$error',
      );
    }
    await _loadCustomFont();
    data.activeServerId ??= data.servers.isNotEmpty
        ? data.servers.first.id
        : null;
    _applyLanguage();
    initialized = true;
    WidgetsBinding.instance.addObserver(this);
    notifyListeners();
    unawaited(_resumePendingJobs());
    if (sync.enabled) unawaited(sync.startAtStartup());
  }

  Future<SyncBundle> _buildSyncBundle(SyncIdentity identity) async =>
      SyncBundle.fromData(
        data,
        deviceId: identity.deviceId,
        deviceName: identity.name,
        excludeChatIds: data.chats
            .where((chat) => isGenerating(chat))
            .map((chat) => chat.id)
            .toSet(),
      );

  Future<SyncMergeResult> _applySyncBundle(SyncBundle bundle) async {
    if (bundle.deviceId == sync.deviceId) return const SyncMergeResult();
    final result = mergeSyncBundle(
      data: data,
      remote: bundle,
      localDeviceId: sync.deviceId,
      busyChatIds: data.chats
          .where((chat) => isGenerating(chat))
          .map((chat) => chat.id)
          .toSet(),
    );
    if (result.changed) {
      if (result.serversAdded > 0) _bridgeApplied.clear();
      _scheduleSave();
      notifyListeners();
      AppLog.instance.info(
        'Синхронизация применена',
        detail:
            'чатов: +${result.chatsAdded} / ~${result.chatsUpdated}, '
            'сообщений: +${result.messagesAdded} / ~${result.messagesMerged}',
      );
    }
    return result;
  }

  /// Test hook: lets a test point the history at a temporary directory.
  @visibleForTesting
  Future<File> Function()? get dataFileOverride => _store.dataFileOverride;

  @visibleForTesting
  set dataFileOverride(Future<File> Function()? value) {
    _store.dataFileOverride = value;
  }

  /// Test hook: runs the same serialised save used by the app.
  @visibleForTesting
  Future<void> saveForTest() => _store.saveForTest();

  /// Test hook: cancels the debounced history save so no timer outlives a
  /// widget test.
  @visibleForTesting
  void cancelPendingSaveForTest() => _store.cancelScheduledSave();

  /// Test hook: fills the model cache without a network request.
  @visibleForTesting
  void setModelsForTest(String serverId, List<LmModelInfo> models) {
    _catalog.set(serverId, models);
  }

  void _scheduleSave() => _store.scheduleSave();

  /// Lets the import/export part call [notifyListeners] without exposing it.
  void _notifyTransfer() => notifyListeners();

  Future<void> _saveNow() => _store.saveNow();

  Future<void> _deleteServerSecrets(String serverId) =>
      _store.deleteServerSecrets(serverId);

  // ------------------------------------------------------------------ servers

  void addServer(ServerConfig server) {
    data.servers.add(server);
    data.activeServerId ??= server.id;
    _store.markSecretsDirty();
    _scheduleSave();
    notifyListeners();
  }

  ServerShareImportResult importSharedServers(SharedServerBundle bundle) {
    final result = mergeSharedServers(data, bundle);
    if (result.changed) {
      if (result.tokensImported > 0) _store.markSecretsDirty();
      _scheduleSave();
      notifyListeners();
      AppLog.instance.info(
        'Импортированы серверы',
        detail:
            'добавлено: ${result.added}, обновлено: ${result.updated}, '
            'токенов: ${result.tokensImported}',
      );
    }
    return result;
  }

  void updateServer(ServerConfig server) {
    final index = data.servers.indexWhere((s) => s.id == server.id);
    if (index == -1) {
      data.servers.add(server);
    } else {
      data.servers[index] = server;
    }
    _bridgeApplied.removeWhere((key, _) => key.startsWith('${server.id}|'));
    _generation.resetBridgeForServer(server.id);
    _store.markSecretsDirty();
    _scheduleSave();
    notifyListeners();
  }

  void deleteServer(String id) {
    data.servers.removeWhere((s) => s.id == id);
    _catalog.remove(id);
    _bridgeApplied.removeWhere((key, _) => key.startsWith('$id|'));
    _generation.resetBridgeForServer(id);
    if (data.activeServerId == id) {
      data.activeServerId = data.servers.isNotEmpty
          ? data.servers.first.id
          : null;
    }
    unawaited(_deleteServerSecrets(id));
    _scheduleSave();
    notifyListeners();
  }

  void setActiveServer(String id) {
    data.activeServerId = id;
    _scheduleSave();
    notifyListeners();
  }

  /// Makes [server] active and checks that it is reachable.
  Future<ModelFetchResult> connectToServer(ServerConfig server) async {
    final chat = activeChat;
    final switched = chat != null && chat.serverId != server.id;
    data.activeServerId = server.id;
    if (switched) {
      // The open chat must follow the newly connected server; otherwise the
      // header shows one server while messages are sent to another.
      chat.serverId = server.id;
      chat.model = '';
    }
    _scheduleSave();
    notifyListeners();

    final result = await refreshModels(server);
    if (result.error == null && chat != null && chat.model.isEmpty) {
      final llm = result.models.where((model) => model.isLlm).toList();
      if (llm.isNotEmpty) setChatModel(chat, llm.first.key);
    }
    return result;
  }

  /// Stops talking to the active server until the user connects again.
  void disconnectServer() {
    if (isDisconnected) return;
    final chat = activeChat;
    if (chat != null && isGenerating(chat)) _generation.stop(chat.id);
    data.activeServerId = disconnectedServerId;
    _scheduleSave();
    notifyListeners();
  }

  void _rejectDisconnected() {
    statusMessage = L10n.t('Сервер отключён. Подключитесь в настройках.');
    notifyListeners();
  }

  Future<ModelFetchResult> refreshModels(ServerConfig server) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final models = await _client.fetchModelsInfo(server);
        _catalog.set(server.id, models);
        _serverOnline[server.id] = true;
        notifyListeners();
        return ModelFetchResult(models: models);
      } catch (error) {
        lastError = error;
        // Retry once for transient network failures. HTTP errors (bad token,
        // wrong address, missing endpoint) will not fix themselves.
        if (attempt == 0 && error is! ApiException) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          continue;
        }
        break;
      }
    }
    final message = lastError is ApiException
        ? lastError.message
        : friendlyNetworkError(lastError ?? 'Неизвестная ошибка');
    // A readable HTTP error still means the server is reachable; only network
    // failures should raise the "нет связи" banner.
    _serverOnline[server.id] = lastError is ApiException;
    AppLog.instance.warning(
      'Не удалось получить список моделей',
      detail: '${server.normalizedBase}: $message',
    );
    notifyListeners();
    return ModelFetchResult(error: message);
  }

  /// Re-checks the active server after the user taps "Повторить".
  Future<void> reconnect() async {
    final server = activeServer;
    if (server == null || checkingConnection) return;
    checkingConnection = true;
    notifyListeners();
    final result = await refreshModels(server);
    checkingConnection = false;
    if (result.error == null) {
      statusMessage = L10n.t('Подключение восстановлено');
    } else if (isServerOnline(server.id)) {
      statusMessage = result.error;
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------- chats

  ChatSession newChat() {
    final server = activeServer;
    final models = server == null
        ? const <LmModelInfo>[]
        : modelsFor(server.id);
    final firstModel = models.where((m) => m.isLlm).toList();
    final chat = ChatSession(
      id: newId(),
      serverId: server?.id ?? '',
      model: _lastModel ?? (firstModel.isNotEmpty ? firstModel.first.key : ''),
      temperature: data.defaultTemperature,
      topP: data.defaultTopP,
      topK: data.defaultTopK,
      repeatPenalty: data.defaultRepeatPenalty,
      maxTokens: data.defaultMaxTokens,
      systemPrompt: data.defaultSystemPrompt,
      responseFormat: data.defaultResponseFormat,
      launch: data.defaultLaunch,
      sortOrder: _topSortOrder(archived: false, pinned: false),
    );
    data.chats.add(chat);
    activeChat = chat;
    _scheduleSave();
    notifyListeners();
    return chat;
  }

  /// Opens the composer for a new chat without collecting empty chats.
  ///
  /// Returns null when the active chat is already empty. Otherwise reuses an
  /// existing empty chat, or creates a new one when none is left.
  ChatSession? openNewChat() {
    final current = activeChat;
    if (current != null && current.messages.isEmpty) return null;
    for (final chat in activeChats) {
      if (chat.messages.isEmpty) {
        selectChat(chat);
        return chat;
      }
    }
    return newChat();
  }

  Future<void> start() async {
    if (activeChat != null) return;
    final available = activeChats;
    if (available.isNotEmpty) {
      activeChat = available.first;
    } else {
      newChat();
    }
    notifyListeners();

    final chat = activeChat;
    final server = serverById(chat?.serverId);
    if (chat != null && server != null && !isDisconnected) {
      if (chat.model.isEmpty) {
        final result = await refreshModels(server);
        final llm = result.models.where((m) => m.isLlm).toList();
        if (chat.model.isEmpty && llm.isNotEmpty) {
          chat.model = llm.first.key;
          notifyListeners();
        }
      } else {
        // Needed for the context-window indicator; harmless when offline.
        unawaited(refreshModels(server));
      }
    }
  }

  void selectChat(ChatSession chat) {
    activeChat = chat;
    if (chat.serverId.isNotEmpty && !isDisconnected) {
      data.activeServerId = chat.serverId;
    }
    final server = serverById(chat.serverId);
    if (server != null && !isDisconnected && _catalog.isStale(server.id)) {
      unawaited(refreshModels(server));
    }
    notifyListeners();
  }

  /// Creates a new chat from the messages up to [from] (inclusive).
  ///
  /// The source chat is never mutated. Branch metadata points at the immediate
  /// parent, so branches of branches form a flat list with a parent chain.
  ChatSession createBranch(ChatSession source, ChatMessage from) {
    final index = source.messages.indexWhere(
      (message) => message.id == from.id,
    );
    if (index < 0) {
      throw ArgumentError.value(from.id, 'from', 'Message is not in the chat');
    }
    final displayedVersion = !from.isUser ? from.displayedVersionNumber : null;
    final messages = <ChatMessage>[];
    for (var i = 0; i <= index; i++) {
      final copy = ChatMessage.fromJson(source.messages[i].toJson())
        ..jobId = null
        ..jobServerId = null
        ..jobSeq = 0
        ..streaming = false
        ..status = null;
      if (i == index && displayedVersion != null) {
        copy.activeVersion = displayedVersion == copy.versionCount
            ? 0
            : displayedVersion;
      }
      messages.add(copy);
    }

    final branch = ChatSession(
      id: newId(),
      title: L10n.tf('Ветка: {title}', {'title': source.title}),
      serverId: source.serverId,
      model: source.model,
      messages: messages,
      temperature: source.temperature,
      topP: source.topP,
      topK: source.topK,
      repeatPenalty: source.repeatPenalty,
      maxTokens: source.maxTokens,
      systemPrompt: source.systemPrompt,
      responseFormat: source.responseFormat,
      launch: source.launch,
      parentChatId: source.id,
      branchFromMessageId: from.id,
      branchFromVersion: displayedVersion,
    );
    data.chats.add(branch);
    activeChat = branch;
    if (source.serverId.isNotEmpty && !isDisconnected) {
      data.activeServerId = source.serverId;
    }
    _scheduleSave();
    notifyListeners();
    AppLog.instance.info(
      'Создана ветка',
      detail:
          'чат ${source.id}, сообщение ${from.id}, '
          'вариант ${displayedVersion ?? '-'}',
    );
    return branch;
  }

  void renameChat(ChatSession chat, String title) {
    chat.title = title.trim().isEmpty ? 'Новый чат' : title.trim();
    chat.updatedAt = DateTime.now();
    _scheduleSave();
    notifyListeners();
  }

  void togglePinned(ChatSession chat) {
    chat.pinned = !chat.pinned;
    _placeAtGroupTop(chat);
    _scheduleSave();
    notifyListeners();
  }

  /// Pins or unpins several chats with a single save and notification.
  void setPinnedChats(Iterable<ChatSession> chats, bool pinned) {
    var changed = false;
    for (final chat in chats) {
      if (chat.pinned == pinned) continue;
      chat.pinned = pinned;
      _placeAtGroupTop(chat);
      changed = true;
    }
    if (!changed) return;
    _scheduleSave();
    notifyListeners();
  }

  void archiveChat(ChatSession chat) {
    if (chat.archived) return;
    chat.archived = true;
    chat.pinned = false;
    _placeAtGroupTop(chat);
    if (activeChat?.id == chat.id) {
      final available = activeChats;
      activeChat = available.isEmpty ? null : available.first;
      if (activeChat == null) newChat();
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Archives or restores several chats at once.
  void archiveChats(Iterable<ChatSession> chats, {bool archived = true}) {
    final ids = <String>{};
    var changed = false;
    for (final chat in chats) {
      ids.add(chat.id);
      if (chat.archived == archived) continue;
      chat.archived = archived;
      if (archived) {
        chat.pinned = false;
      } else {
        chat.updatedAt = DateTime.now();
      }
      _placeAtGroupTop(chat);
      changed = true;
    }
    if (!changed) return;
    if (archived && ids.contains(activeChat?.id)) {
      final available = activeChats;
      activeChat = available.isEmpty ? null : available.first;
      if (activeChat == null) newChat();
    }
    _scheduleSave();
    notifyListeners();
  }

  void unarchiveChat(ChatSession chat) {
    if (!chat.archived) return;
    chat.archived = false;
    chat.updatedAt = DateTime.now();
    _placeAtGroupTop(chat);
    _scheduleSave();
    notifyListeners();
  }

  void deleteChat(ChatSession chat) {
    data.chats.removeWhere((c) => c.id == chat.id);
    if (activeChat?.id == chat.id) {
      final available = activeChats;
      activeChat = available.isEmpty ? null : available.first;
      if (activeChat == null) newChat();
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Deletes several chats and returns how many were removed.
  int deleteChats(Iterable<ChatSession> chats) {
    final ids = {for (final chat in chats) chat.id};
    if (ids.isEmpty) return 0;
    final before = data.chats.length;
    data.chats.removeWhere((chat) => ids.contains(chat.id));
    final removed = before - data.chats.length;
    if (removed == 0) return 0;
    if (ids.contains(activeChat?.id)) {
      final available = activeChats;
      activeChat = available.isEmpty ? null : available.first;
      if (activeChat == null) newChat();
    }
    _scheduleSave();
    notifyListeners();
    return removed;
  }

  void clearChat(ChatSession chat) {
    chat.messages.clear();
    chat.updatedAt = DateTime.now();
    _scheduleSave();
    notifyListeners();
  }

  void setChatModel(ChatSession chat, String model) {
    chat.model = model;
    _lastModel = model;
    _scheduleSave();
    notifyListeners();
  }

  void setChatServer(ChatSession chat, ServerConfig server) {
    chat.serverId = server.id;
    data.activeServerId = server.id;
    _scheduleSave();
    notifyListeners();
  }

  void updateChatParams(
    ChatSession chat, {
    double? temperature,
    double? topP,
    int? topK,
    double? repeatPenalty,
    int? maxTokens,
    String? systemPrompt,
    ResponseFormat? responseFormat,
  }) {
    if (temperature != null) chat.temperature = temperature;
    if (topP != null) chat.topP = topP;
    if (topK != null) chat.topK = topK.clamp(0, 1000);
    if (repeatPenalty != null) {
      chat.repeatPenalty = repeatPenalty.clamp(0.5, 2.0).toDouble();
    }
    if (maxTokens != null) chat.maxTokens = maxTokens;
    if (systemPrompt != null) chat.systemPrompt = systemPrompt;
    if (responseFormat != null) chat.responseFormat = responseFormat;
    _scheduleSave();
    notifyListeners();
  }

  void updateDefaults({
    double? temperature,
    double? topP,
    int? topK,
    double? repeatPenalty,
    int? maxTokens,
    String? systemPrompt,
    ResponseFormat? responseFormat,
  }) => _settings.updateDefaults(
    temperature: temperature,
    topP: topP,
    topK: topK,
    repeatPenalty: repeatPenalty,
    maxTokens: maxTokens,
    systemPrompt: systemPrompt,
    responseFormat: responseFormat,
  );

  List<PromptTemplate> get allPromptTemplates => [
    ...builtInPromptTemplates,
    ...data.promptTemplates,
  ];

  void addPromptTemplate(PromptTemplate template) {
    data.promptTemplates.add(template);
    _scheduleSave();
    notifyListeners();
  }

  void updatePromptTemplate(PromptTemplate template) {
    final index = data.promptTemplates.indexWhere((t) => t.id == template.id);
    if (index == -1) {
      data.promptTemplates.add(template);
    } else {
      data.promptTemplates[index] = template;
    }
    _scheduleSave();
    notifyListeners();
  }

  void deletePromptTemplate(String id) {
    data.promptTemplates.removeWhere((t) => t.id == id);
    _scheduleSave();
    notifyListeners();
  }

  void updateChatLaunch(ChatSession chat, LaunchSettings launch) {
    chat.launch = launch;
    _scheduleSave();
    notifyListeners();
  }

  void updateDefaultLaunch(LaunchSettings launch, {String? presetId}) =>
      _settings.updateDefaultLaunch(launch, presetId: presetId);

  /// Saves [settings] under [name] and returns the new preset.
  LaunchPreset addLaunchPreset(String name, LaunchSettings settings) {
    final trimmed = name.trim();
    final preset = LaunchPreset(
      id: newId(),
      name: trimmed.isEmpty ? 'Пресет' : trimmed,
      settings: settings,
    );
    data.launchPresets.add(preset);
    _scheduleSave();
    notifyListeners();
    return preset;
  }

  void renameLaunchPreset(LaunchPreset preset, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == preset.name) return;
    final index = data.launchPresets.indexWhere((item) => item.id == preset.id);
    if (index == -1) return;
    data.launchPresets[index] = preset.copyWith(name: trimmed);
    _scheduleSave();
    notifyListeners();
  }

  /// Removes a preset. The current defaults stay as they are, so new chats do
  /// not silently change their launch options.
  void deleteLaunchPreset(LaunchPreset preset) {
    final before = data.launchPresets.length;
    data.launchPresets.removeWhere((item) => item.id == preset.id);
    if (data.launchPresets.length == before) return;
    if (data.defaultLaunchPresetId == preset.id) {
      data.defaultLaunchPresetId = '';
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Makes [preset] the launch configuration for new chats.
  void setDefaultLaunchPreset(LaunchPreset preset) =>
      _settings.updateDefaultLaunch(preset.settings, presetId: preset.id);

  void completeSetup() => _settings.completeSetup();

  void setBackgroundGeneration(bool value) =>
      _settings.setBackgroundGeneration(value);

  void setAutoCheckUpdates(bool value) {
    if (data.autoCheckUpdates == value) return;
    data.autoCheckUpdates = value;
    _scheduleSave();
    notifyListeners();
  }

  void markUpdateChecked() {
    data.lastUpdateCheck = DateTime.now();
    _scheduleSave();
  }

  void skipUpdate(String tag) {
    data.skippedUpdateTag = tag;
    _scheduleSave();
    notifyListeners();
  }

  void setThemeMode(AppThemeMode mode) => _settings.setThemeMode(mode);

  void setFontFamily(AppFontFamily family) => _settings.setFontFamily(family);

  /// Restores the imported TTF before the first frame. Falls back to the system
  /// font when the stored file is gone or cannot be parsed.
  Future<void> _loadCustomFont() async {
    if (data.fontFamily != AppFontFamily.custom) return;
    var loaded = false;
    try {
      loaded = await CustomFontService.loadSaved(
        family: data.customFontFamily,
        fileName: data.customFontFile,
      );
    } catch (_) {
      loaded = false;
    }
    if (loaded) return;
    data.fontFamily = AppFontFamily.system;
    data.customFontName = '';
    data.customFontFamily = '';
    data.customFontFile = '';
    _store.scheduleSave();
  }

  /// Lets the user pick a local `.ttf` file, validates it by registering it
  /// with the engine, and makes it the active interface font.
  Future<FontImportResult> importCustomFont() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['ttf'],
        dialogTitle: L10n.t('Выберите TTF-шрифт'),
      );
      if (file == null) return const FontImportResult(cancelled: true);
      final fontLength = await file.length();
      if (fontLength != null && fontLength > CustomFontService.maxBytes) {
        return FontImportResult(
          error: L10n.t('Файл шрифта слишком большой (максимум 32 МБ)'),
        );
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        return FontImportResult(error: L10n.t('Файл шрифта пуст'));
      }
      if (bytes.length > CustomFontService.maxBytes) {
        return FontImportResult(
          error: L10n.t('Файл шрифта слишком большой (максимум 32 МБ)'),
        );
      }
      final saved = await CustomFontService.save(
        bytes,
        oldFileName: data.customFontFile,
      );
      final name = file.name
          .replaceFirst(RegExp(r'\.ttf$', caseSensitive: false), '')
          .trim();
      data.customFontName = name.isEmpty ? L10n.t('Свой шрифт') : name;
      data.customFontFamily = saved.family;
      data.customFontFile = saved.fileName;
      _settings.setFontFamily(AppFontFamily.custom);
      AppLog.instance.info(
        'Шрифт импортирован',
        detail: '${data.customFontName} (${bytes.length} байт)',
      );
      return const FontImportResult();
    } catch (error) {
      AppLog.instance.error('Не удалось импортировать шрифт', detail: '$error');
      return FontImportResult(
        error: L10n.tf('Не удалось импортировать шрифт: {error}', {
          'error': error,
        }),
      );
    }
  }

  Future<void> removeCustomFont() async {
    final fileName = data.customFontFile;
    data.customFontName = '';
    data.customFontFamily = '';
    data.customFontFile = '';
    if (data.fontFamily == AppFontFamily.custom) {
      data.fontFamily = AppFontFamily.system;
    }
    _scheduleSave();
    notifyListeners();
    await CustomFontService.delete(fileName);
  }

  void setFontScale(double scale) => _settings.setFontScale(scale);

  void setUiDensity(UiDensity density) => _settings.setUiDensity(density);

  void setSidebarWidth(double width) => _settings.setSidebarWidth(width);

  void setSidebarCollapsed(bool collapsed) =>
      _settings.setSidebarCollapsed(collapsed);

  void toggleSidebar() => _settings.setSidebarCollapsed(!data.sidebarCollapsed);

  void setAppLanguage(AppLanguage language) {
    data.appLanguage = language;
    _applyLanguage();
    _scheduleSave();
    notifyListeners();
  }

  void _applyLanguage() {
    switch (data.appLanguage) {
      case AppLanguage.ru:
        L10n.setLanguage('ru');
      case AppLanguage.en:
        L10n.setLanguage('en');
      case AppLanguage.system:
        final code =
            WidgetsBinding.instance.platformDispatcher.locale.languageCode;
        L10n.setLanguage(code == 'ru' ? 'ru' : 'en');
    }
  }

  // ------------------------------------------------------------- model loading

  LmModelInfo? _findModel(List<LmModelInfo> models, String key) {
    for (final model in models) {
      if (model.key == key) return model;
    }
    return null;
  }

  String _bridgeKey(ServerConfig server, ChatSession chat) =>
      '${server.id}|${chat.model}';

  String _bridgeSignature(LaunchSettings launch) => [
    launch.contextLength ?? 'auto',
    launch.ttlSeconds ?? 'auto',
    launch.gpuRatio ?? 'auto',
  ].join('|');

  /// Checks that the GPU bridge is reachable and `lms` is installed.
  Future<BridgeHealth> bridgeHealth(ServerConfig server) async {
    try {
      return await _client.bridgeHealth(server);
    } catch (error) {
      return BridgeHealth(ok: false, error: friendlyNetworkError(error));
    }
  }

  /// Asks the bridge how much memory the current launch settings would need.
  Future<BridgeEstimateResult> estimateLaunch(ChatSession chat) async {
    final server = serverById(chat.serverId) ?? activeServer;
    if (server == null || !server.hasBridge) {
      return const BridgeEstimateResult(error: 'Мостик не настроен');
    }
    if (chat.model.isEmpty) {
      return const BridgeEstimateResult(error: 'Сначала выберите модель');
    }
    try {
      return await _client.bridgeEstimate(
        server,
        chat.model,
        contextLength: chat.launch.contextLength,
        gpuRatio: chat.launch.gpuRatio,
      );
    } catch (error) {
      return BridgeEstimateResult(
        error: error is ApiException
            ? error.message
            : friendlyNetworkError(error),
      );
    }
  }

  /// Best-effort restore of the configuration that was loaded before a failed
  /// reload, so an unsuccessful "Загрузить" does not leave the server empty.
  Future<void> _restorePreviousInstance(
    ServerConfig server,
    ChatSession chat,
    LoadedInstance? previous,
  ) async {
    if (previous == null) return;
    try {
      if (server.hasBridge) {
        await _client.bridgeLoad(
          server,
          chat.model,
          contextLength: previous.contextLength,
        );
      } else {
        await _client.loadModel(
          server,
          chat.model,
          contextLength: previous.contextLength,
          evalBatchSize: previous.evalBatchSize,
          flashAttention: previous.flashAttention,
          offloadKvCache: previous.offloadKvCache,
        );
      }
      _catalog.set(server.id, await _client.fetchModelsInfo(server));
    } catch (_) {
      // The error that caused the reload failure is more useful to the user.
    }
  }

  bool _hasExplicitLaunch(LaunchSettings launch) =>
      launch.contextLength != null ||
      launch.gpuRatio != null ||
      launch.flashAttention != null ||
      launch.offloadKvCache != null ||
      launch.evalBatchSize != null;

  /// Unloads existing instances through REST, falling back to `lms unload`
  /// when the bridge is configured and the REST call fails.
  Future<void> _unloadInstances(
    ServerConfig server,
    ChatSession chat,
    LmModelInfo? info,
  ) async {
    if (info == null || info.loadedInstances.isEmpty) return;
    try {
      for (final instance in info.loadedInstances) {
        await _client.unloadModel(server, instance.id);
      }
    } catch (_) {
      if (!server.hasBridge) rethrow;
      await _client.bridgeUnload(server, model: chat.model);
    }
  }

  /// Ensures the model is loaded before the first chat request. Applies the
  /// context window and other launch settings; on old LM Studio builds without
  /// `/api/v1` it silently falls back to server-side JIT loading.
  Future<void> _ensureModelLoaded(
    ServerConfig server,
    ChatSession chat,
    ChatMessage placeholder,
  ) async {
    try {
      final infos = await _client.fetchModelsInfo(server);
      _catalog.set(server.id, infos);
      final info = _findModel(infos, chat.model);

      if (server.hasBridge) {
        final key = _bridgeKey(server, chat);
        final signature = _bridgeSignature(chat.launch);
        final applied = _bridgeApplied[key] == signature;
        // An explicit GPU ratio must be enforced even if LM Studio already
        // JIT-loaded the model with its own (usually smaller) offload.
        final mustReload = chat.launch.gpuRatio != null;
        if (info != null && info.isLoaded && (!mustReload || applied)) {
          notifyListeners();
          return;
        }
        placeholder.status = 'Загружаю модель на GPU через мостик…';
        notifyListeners();
        final previous = info?.instance;
        var unloaded = false;
        try {
          await _unloadInstances(server, chat, info);
          unloaded = true;
          await _client.bridgeLoad(
            server,
            chat.model,
            contextLength: chat.launch.contextLength,
            ttlSeconds: chat.launch.ttlSeconds,
            gpuRatio: chat.launch.gpuRatio,
          );
        } catch (error) {
          if (unloaded) {
            await _restorePreviousInstance(server, chat, previous);
          }
          rethrow;
        }
        _bridgeApplied[key] = signature;
        placeholder.status = null;
        _catalog.set(server.id, await _client.fetchModelsInfo(server));
        notifyListeners();
        return;
      }

      if (info == null || info.isLoaded) {
        notifyListeners();
        return;
      }
      placeholder.status = 'Загружаю модель…';
      notifyListeners();
      final loadResult = await _client.loadModel(
        server,
        chat.model,
        contextLength: chat.launch.contextLength,
        evalBatchSize: chat.launch.evalBatchSize,
        flashAttention: chat.launch.flashAttention,
        offloadKvCache: chat.launch.offloadKvCache,
        gpuRatio: chat.launch.gpuRatio,
      );
      if (loadResult.gpuConfirmed == false) {
        placeholder.notice =
            'Передача на GPU не применилась: LM Studio использует '
            'настройки сервера.';
      }
      placeholder.status = null;
      _catalog.set(server.id, await _client.fetchModelsInfo(server));
    } catch (error) {
      placeholder.status = null;
      final message = error is ApiException
          ? error.message
          : friendlyNetworkError(error);
      AppLog.instance.warning(
        'Не удалось подготовить модель',
        detail: '${chat.model}: $message',
      );
      if (error is! ApiException) _serverOnline[server.id] = false;
      if (server.hasBridge) {
        placeholder.notice = 'Модель не загружена через мостик: $message';
        statusMessage = L10n.tf(
          'Не удалось загрузить через мостик: {message}',
          {'message': message},
        );
      } else if (message.contains('404')) {
        // Older LM Studio builds have no native model API. JIT loading still
        // works, but the launch settings cannot be applied.
        if (_hasExplicitLaunch(chat.launch)) {
          placeholder.notice =
              'LM Studio не поддерживает /api/v1: контекст и '
              'параметры запуска не применены.';
        }
      } else {
        statusMessage = L10n.tf('Не удалось подготовить модель: {message}', {
          'message': message,
        });
      }
    } finally {
      notifyListeners();
    }
  }

  /// Loads (or reloads) the chat model with the configured launch settings.
  Future<LaunchApplyResult> applyLaunchSettings(ChatSession chat) async {
    final server = serverById(chat.serverId) ?? activeServer;
    if (server == null) {
      return const LaunchApplyResult(error: 'Сервер не найден');
    }
    if (chat.model.isEmpty) {
      return const LaunchApplyResult(error: 'Сначала выберите модель');
    }
    try {
      final infos = await _client.fetchModelsInfo(server);
      _catalog.set(server.id, infos);
      final info = _findModel(infos, chat.model);
      final previous = info?.instance;
      var unloaded = false;

      try {
        if (server.hasBridge) {
          await _unloadInstances(server, chat, info);
          unloaded = true;
          await _client.bridgeLoad(
            server,
            chat.model,
            contextLength: chat.launch.contextLength,
            ttlSeconds: chat.launch.ttlSeconds,
            gpuRatio: chat.launch.gpuRatio,
          );
          _bridgeApplied[_bridgeKey(server, chat)] = _bridgeSignature(
            chat.launch,
          );
          _catalog.set(server.id, await _client.fetchModelsInfo(server));
          AppLog.instance.info(
            'Модель загружена через мостик',
            detail: chat.model,
          );
          notifyListeners();
          return const LaunchApplyResult(viaBridge: true);
        }

        await _unloadInstances(server, chat, info);
        unloaded = true;
        final result = await _client.loadModel(
          server,
          chat.model,
          contextLength: chat.launch.contextLength,
          evalBatchSize: chat.launch.evalBatchSize,
          flashAttention: chat.launch.flashAttention,
          offloadKvCache: chat.launch.offloadKvCache,
          gpuRatio: chat.launch.gpuRatio,
        );
        _catalog.set(server.id, await _client.fetchModelsInfo(server));
        AppLog.instance.info(
          result.warning == null
              ? 'Модель загружена'
              : 'Модель загружена с предупреждением',
          detail: result.warning ?? chat.model,
        );
        notifyListeners();
        return LaunchApplyResult(
          warning: result.warning,
          command: result.command,
        );
      } catch (error) {
        // Never leave the user with an unloaded model after a failed reload.
        if (unloaded) {
          await _restorePreviousInstance(server, chat, previous);
        }
        rethrow;
      }
    } catch (error) {
      final message = error is ApiException
          ? error.message
          : friendlyNetworkError(error);
      AppLog.instance.error(
        'Не удалось применить настройки запуска',
        detail: '${chat.model}: $message',
      );
      if (error is! ApiException) _serverOnline[server.id] = false;
      return LaunchApplyResult(
        error: server.hasBridge ? 'Мостик: $message' : message,
      );
    }
  }

  Future<String?> unloadChatModel(ChatSession chat) async {
    final server = serverById(chat.serverId) ?? activeServer;
    if (server == null) return 'Сервер не найден';
    if (chat.model.isEmpty) return 'Модель не выбрана';
    try {
      final infos = await _client.fetchModelsInfo(server);
      _catalog.set(server.id, infos);
      final info = _findModel(infos, chat.model);
      if (info == null || !info.isLoaded) {
        return 'Модель не загружена';
      }
      if (server.hasBridge) {
        await _unloadInstances(server, chat, info);
        _bridgeApplied.remove(_bridgeKey(server, chat));
      } else {
        for (final instance in info.loadedInstances) {
          await _client.unloadModel(server, instance.id);
        }
      }
      _catalog.set(server.id, await _client.fetchModelsInfo(server));
      notifyListeners();
      return null;
    } catch (error) {
      return error is ApiException
          ? error.message
          : friendlyNetworkError(error);
    }
  }

  // -------------------------------------------------------------------- chat

  /// Re-attaches to answers whose bridge jobs were still running when the app
  /// was closed. The generation itself continued on the server.
  Future<void> _resumePendingJobs({ChatSession? onlyChat}) async {
    if (isDisconnected) return;
    final chats = onlyChat == null ? [...data.chats] : [onlyChat];
    for (final chat in chats) {
      if (isGenerating(chat)) continue;
      final messages = [...chat.messages];
      for (final message in messages) {
        if (!message.hasPendingJob) continue;
        final server = serverById(message.jobServerId ?? chat.serverId);
        if (server == null || !server.hasBridge) {
          _clearPendingJob(message);
          _scheduleSave();
          continue;
        }
        await _resumeJob(chat, message, server);
      }
    }
  }

  /// Re-attaches to one answer after a network drop, without restarting the
  /// app. Used by the "Догрузить ответ" action in the message bubble.
  Future<void> resumeMessage(ChatSession chat, ChatMessage message) async {
    if (isGenerating(chat) || !message.hasPendingJob) return;
    if (isDisconnected) {
      _rejectDisconnected();
      return;
    }
    final server = serverById(message.jobServerId ?? chat.serverId);
    if (server == null || !server.hasBridge) {
      _clearPendingJob(message);
      _scheduleSave();
      notifyListeners();
      return;
    }
    await _resumeJob(chat, message, server);
  }

  void _clearPendingJob(ChatMessage message) {
    message.jobId = null;
    message.jobServerId = null;
    message.jobSeq = 0;
  }

  Future<void> _resumeJob(
    ChatSession chat,
    ChatMessage message,
    ServerConfig server,
  ) async {
    if (isGenerating(chat)) return;
    final keepAlive = data.backgroundGeneration;
    message.streaming = true;
    message.activeVersion = 0;
    message.error = null;
    message.generationStartedAt ??= DateTime.now();
    AppLog.instance.info(
      'Догрузка ответа с мостика',
      detail: 'задание ${message.jobId}, модель ${message.model}',
    );
    notifyListeners();
    if (keepAlive) await BackgroundKeepAlive.start('Догружаю ответ…');
    final generation = Stopwatch()..start();
    int? serverElapsedMs;
    try {
      final stream = _generation.attachBridgeJob(
        server: server,
        chat: chat,
        message: message,
        since: message.jobSeq,
        onSeq: (next) => message.jobSeq = next,
      );
      await for (final chunk in stream) {
        if (chunk.usage != null) _applyUsage(message, chunk.usage!);
        if (chunk.elapsedMs != null) serverElapsedMs = chunk.elapsedMs;
        message.content += chunk.content;
        message.reasoning += chunk.reasoning;
        notifyListeners();
      }
    } catch (error) {
      if (!_generation.isAborted(chat.id)) {
        final text = error is ApiException
            ? error.message
            : friendlyNetworkError(error);
        AppLog.instance.warning('Не удалось догрузить ответ', detail: text);
        if (error is! ApiException) _serverOnline[server.id] = false;
        if (message.content.trim().isEmpty) {
          message.error = text;
        } else {
          statusMessage = L10n.tf('Не удалось догрузить ответ: {text}', {
            'text': text,
          });
        }
      }
    } finally {
      generation.stop();
      message.streaming = false;
      final producedNothing =
          message.content.trim().isEmpty && message.reasoning.trim().isEmpty;
      if (producedNothing) {
        message.promptTokens = null;
        message.completionTokens = null;
        message.totalTokens = null;
        message.generationMs = null;
        message.firstTokenMs = null;
        message.tokensEstimated = false;
      } else {
        final started = message.generationStartedAt;
        message.generationMs =
            serverElapsedMs ??
            (started != null
                ? DateTime.now().difference(started).inMilliseconds
                : generation.elapsedMilliseconds);
        _applyTokenFallback(message, _historyFor(chat, message));
      }
      message.generationStartedAt = null;
      message.jobId = null;
      message.jobServerId = null;
      message.jobSeq = 0;
      chat.updatedAt = DateTime.now();
      _scheduleSave();
      _generation.finish(chat.id);
      AppLog.instance.info(
        'Догрузка завершена',
        detail: '${generation.elapsedMilliseconds} мс',
      );
      notifyListeners();
      if (keepAlive) await BackgroundKeepAlive.stop();
    }
  }

  Future<void> send(
    String text, {
    List<ChatAttachment> attachments = const [],
  }) async {
    final chat = activeChat;
    final trimmed = text.trim();
    if (chat == null ||
        isGenerating(chat) ||
        (trimmed.isEmpty && attachments.isEmpty)) {
      return;
    }

    if (isDisconnected) {
      _rejectDisconnected();
      return;
    }

    final server = serverById(chat.serverId) ?? activeServer;
    if (server == null) {
      statusMessage = L10n.t('Сначала добавьте сервер в настройках');
      notifyListeners();
      return;
    }
    if (chat.model.isEmpty) {
      statusMessage = L10n.t('Выберите модель');
      notifyListeners();
      return;
    }
    final formatError = chat.responseFormat.validationError;
    if (formatError != null) {
      statusMessage = L10n.t(formatError);
      notifyListeners();
      return;
    }
    final security = server.generationSecurityError;
    if (security != null) {
      statusMessage = security;
      notifyListeners();
      return;
    }
    if (chat.archived) chat.archived = false;

    chat.messages.add(
      ChatMessage(
        id: newId(),
        role: 'user',
        content: trimmed,
        attachments: attachments,
      ),
    );
    final placeholder = ChatMessage(
      id: newId(),
      role: 'assistant',
      model: chat.model,
    )..streaming = true;
    chat.messages.add(placeholder);
    if (chat.title == 'Новый чат') {
      chat.title = trimmed.isEmpty
          ? L10n.t('Изображение')
          : titleFromPrompt(trimmed);
    }
    await _generate(chat: chat, server: server, placeholder: placeholder);
  }

  /// Continues the last answer instead of starting a new one or replacing it.
  Future<void> continueGeneration() async {
    final chat = activeChat;
    if (chat == null || isGenerating(chat)) return;
    if (isDisconnected) {
      _rejectDisconnected();
      return;
    }
    final index = chat.messages.lastIndexWhere((m) => m.role == 'assistant');
    if (index == -1) return;
    if (index != chat.messages.length - 1) {
      statusMessage = L10n.t('Продолжить можно только последний ответ');
      notifyListeners();
      return;
    }
    final message = chat.messages[index];
    if (message.displayContent.trim().isEmpty) return;
    final server = serverById(chat.serverId) ?? activeServer;
    if (server == null) {
      statusMessage = L10n.t('Сначала добавьте сервер в настройках');
      notifyListeners();
      return;
    }
    if (chat.model.isEmpty) {
      statusMessage = L10n.t('Выберите модель');
      notifyListeners();
      return;
    }
    message.activeVersion = 0;
    message.error = null;
    message.streaming = true;
    final before = message.content;
    await _generate(
      chat: chat,
      server: server,
      placeholder: message,
      isContinuation: true,
    );

    // Some chat templates reject a trailing assistant message or return
    // nothing. Retry once with the partial answer inside a user instruction.
    if (!_generation.isAborted(chat.id) && message.content == before) {
      message.error = null;
      await _generate(
        chat: chat,
        server: server,
        placeholder: message,
        isContinuation: true,
        continuationInstruction: true,
      );
    }
  }

  /// Builds the context from the answers that are currently selected, so a
  /// regenerated chat sends the variant the user sees.
  List<Map<String, dynamic>> _historyFor(
    ChatSession chat,
    ChatMessage placeholder,
  ) {
    final history = <Map<String, dynamic>>[];
    if (chat.systemPrompt.trim().isNotEmpty) {
      history.add({'role': 'system', 'content': chat.systemPrompt.trim()});
    }
    for (final message in chat.messages) {
      if (message.id == placeholder.id) continue;
      final content = message.displayContent.trim();
      if (message.isUser && message.attachments.isNotEmpty) {
        final parts = <Map<String, dynamic>>[
          if (content.isNotEmpty) {'type': 'text', 'text': content},
          for (final attachment in message.attachments)
            {
              'type': 'image_url',
              'image_url': {'url': attachment.dataUrl},
            },
        ];
        if (parts.isNotEmpty) {
          history.add({'role': message.role, 'content': parts});
        }
        continue;
      }
      if (content.isEmpty) continue;
      history.add({'role': message.role, 'content': content});
    }
    return history;
  }

  /// Conversation up to the answer being continued, with that answer as the
  /// final `assistant` message. Chat-completions servers treat a trailing
  /// assistant message as a prefill and continue from it.
  List<Map<String, dynamic>> _historyForContinuation(
    ChatSession chat,
    ChatMessage target, {
    bool asInstruction = false,
  }) {
    final history = _historyFor(chat, target);
    final content = target.displayContent.trim();
    if (content.isEmpty) return history;
    if (asInstruction) {
      history.add({
        'role': 'user',
        'content':
            'Продолжи свой предыдущий ответ с того места, где он остановился. '
            'Не повторяй уже написанное.\n\n'
            'Уже написанное:\n$content\n\nПродолжение:',
      });
    } else {
      history.add({'role': 'assistant', 'content': content});
    }
    return history;
  }

  /// Streams one answer into [placeholder]. Shared by a new message and by
  /// regeneration, so both paths persist partial text and bridge jobs the same
  /// way.
  Future<void> _generate({
    required ChatSession chat,
    required ServerConfig server,
    required ChatMessage placeholder,
    bool isRegeneration = false,
    bool isContinuation = false,
    bool continuationInstruction = false,
  }) async {
    final formatError = chat.responseFormat.validationError;
    if (formatError != null) {
      placeholder.streaming = false;
      placeholder.error = L10n.t(formatError);
      chat.updatedAt = DateTime.now();
      _scheduleSave();
      notifyListeners();
      return;
    }
    final security = server.generationSecurityError;
    if (security != null) {
      placeholder.streaming = false;
      placeholder.error = security;
      chat.updatedAt = DateTime.now();
      _scheduleSave();
      notifyListeners();
      return;
    }
    final contentBefore = placeholder.content;
    final reasoningBefore = placeholder.reasoning;
    final promptBefore = placeholder.promptTokens;
    final completionBefore = placeholder.completionTokens;
    final totalBefore = placeholder.totalTokens;
    final generationBefore = placeholder.generationMs;
    final firstTokenBefore = placeholder.firstTokenMs;
    final estimatedBefore = placeholder.tokensEstimated;
    final toolsBefore = placeholder.toolCalls.length;
    if (isGenerating(chat)) return;
    _lastModel = chat.model;
    placeholder.model = chat.model;
    placeholder.promptTokens = null;
    placeholder.completionTokens = null;
    placeholder.totalTokens = null;
    placeholder.generationMs = null;
    placeholder.firstTokenMs = null;
    placeholder.tokensEstimated = false;
    placeholder.generationStartedAt = null;
    placeholder.editedAt = null;
    placeholder.notice = null;
    placeholder.error = null;
    statusMessage = null;
    chat.updatedAt = DateTime.now();
    notifyListeners();

    final history = isContinuation
        ? _historyForContinuation(
            chat,
            placeholder,
            asInstruction: continuationInstruction,
          )
        : _historyFor(chat, placeholder);
    AppLog.instance.info(
      isContinuation ? 'Продолжение генерации' : 'Начало генерации',
      detail:
          'чат ${chat.id}, модель ${chat.model}, сообщений ${history.length}',
    );

    final stream = _generation.begin(
      server: server,
      chat: chat,
      placeholder: placeholder,
      history: history,
      onBridgeUnsupported: (message) {
        statusMessage = message;
        notifyListeners();
      },
      onJobChanged: _scheduleSave,
    );

    final keepAlive = data.backgroundGeneration;
    if (keepAlive) await BackgroundKeepAlive.start('Готовится ответ…');
    final partial = Stopwatch()..start();
    final uiTicker = Stopwatch()..start();
    var lastUiMs = -1000;
    final generation = Stopwatch();
    int? serverElapsedMs;

    try {
      if (chat.launch.loadOnDemand) {
        await _ensureModelLoaded(server, chat, placeholder);
      }
      // Do not count model loading in the generation speed.
      placeholder.generationStartedAt = DateTime.now();
      generation.start();
      _scheduleSave();
      await for (final chunk in stream) {
        if (chunk.usage != null) _applyUsage(placeholder, chunk.usage!);
        if (chunk.elapsedMs != null) serverElapsedMs = chunk.elapsedMs;
        final toolCall = chunk.toolCall;
        if (toolCall != null) {
          applyToolCallEvent(placeholder.toolCalls, toolCall);
          _scheduleSave();
        }
        if (placeholder.firstTokenMs == null &&
            (chunk.content.isNotEmpty || chunk.reasoning.isNotEmpty)) {
          placeholder.firstTokenMs = generation.elapsedMilliseconds;
        }
        placeholder.content += chunk.content;
        placeholder.reasoning += chunk.reasoning;
        if (partial.elapsed >= const Duration(seconds: 2)) {
          partial.reset();
          _scheduleSave();
        }
        // A model can emit dozens of chunks per second. Rebuilding the whole
        // chat for each token is wasteful; coalesce UI updates to ~20 fps.
        final uiMs = uiTicker.elapsedMilliseconds;
        if (uiMs - lastUiMs >= 50) {
          lastUiMs = uiMs;
          notifyListeners();
        }
      }
    } catch (error) {
      if (!_generation.isAborted(chat.id)) {
        placeholder.error = error is ApiException
            ? error.message
            : friendlyNetworkError(error);
        AppLog.instance.error(
          'Ошибка генерации',
          detail: '${placeholder.model}: ${placeholder.error}',
        );
        if (error is! ApiException) _serverOnline[server.id] = false;
      }
    } finally {
      generation.stop();
      final aborted = _generation.isAborted(chat.id);
      placeholder.streaming = false;
      placeholder.status = null;
      final addedContent = placeholder.content.length > contentBefore.length
          ? placeholder.content.substring(contentBefore.length)
          : '';
      final addedReasoning =
          placeholder.reasoning.length > reasoningBefore.length
          ? placeholder.reasoning.substring(reasoningBefore.length)
          : '';
      final producedNothing =
          addedContent.trim().isEmpty &&
          addedReasoning.trim().isEmpty &&
          placeholder.toolCalls.length == toolsBefore;
      if (placeholder.error == null && producedNothing) {
        if (isContinuation) {
          statusMessage = aborted
              ? 'Продолжение остановлено'
              : 'Модель не продолжила ответ';
        } else {
          placeholder.error = aborted
              ? 'Остановлено'
              : 'Модель вернула пустой ответ';
        }
      }
      // A failed regeneration should not replace the answer the user already
      // had: put the previous variant back and report the problem separately.
      if (isRegeneration && producedNothing && placeholder.hasVersions) {
        final problem = placeholder.error;
        placeholder.restoreLatestArchived();
        placeholder.jobId = null;
        placeholder.jobServerId = null;
        placeholder.jobSeq = 0;
        if (problem != null) {
          statusMessage = L10n.tf('Новый вариант не получен: {problem}', {
            'problem': problem,
          });
        }
      } else if (producedNothing) {
        if (isContinuation) {
          // Keep the statistics that described the original answer.
          placeholder.promptTokens = promptBefore;
          placeholder.completionTokens = completionBefore;
          placeholder.totalTokens = totalBefore;
          placeholder.generationMs = generationBefore;
          placeholder.firstTokenMs = firstTokenBefore;
          placeholder.tokensEstimated = estimatedBefore;
        } else {
          // No answer means no meaningful speed or token statistics.
          placeholder.promptTokens = null;
          placeholder.completionTokens = null;
          placeholder.totalTokens = null;
          placeholder.generationMs = null;
          placeholder.firstTokenMs = null;
          placeholder.tokensEstimated = false;
        }
      } else {
        placeholder.generationMs =
            serverElapsedMs ?? generation.elapsedMilliseconds;
        _applyTokenFallback(
          placeholder,
          history,
          completionText: isContinuation ? addedContent : null,
          reasoningText: isContinuation ? addedReasoning : null,
        );
      }
      placeholder.generationStartedAt = null;
      // A failed bridge job may still be running on the server: keep its id so
      // the next launch can pick the rest of the answer up.
      if (placeholder.error == null || aborted) {
        placeholder.jobId = null;
        placeholder.jobServerId = null;
        placeholder.jobSeq = 0;
      }
      chat.updatedAt = DateTime.now();
      _scheduleSave();
      _generation.finish(chat.id);
      AppLog.instance.info(
        aborted ? 'Генерация остановлена' : 'Генерация завершена',
        detail:
            '${generation.elapsedMilliseconds} мс, '
            'токенов ${placeholder.completionTokens ?? 0}',
      );
      notifyListeners();
      if (keepAlive) await BackgroundKeepAlive.stop();
    }
  }

  void _applyUsage(ChatMessage message, ChatUsage usage) {
    if (usage.promptTokens != null) message.promptTokens = usage.promptTokens;
    if (usage.completionTokens != null) {
      message.completionTokens = usage.completionTokens;
    }
    if (usage.totalTokens != null) message.totalTokens = usage.totalTokens;
    message.tokensEstimated = false;
  }

  /// Fills in token counts when LM Studio did not return `usage`.
  void _applyTokenFallback(
    ChatMessage message,
    List<Map<String, dynamic>> history, {
    String? completionText,
    String? reasoningText,
  }) {
    if (message.promptTokens == null) {
      var prompt = 0;
      for (final item in history) {
        final content = item['content'];
        if (content is String) {
          prompt += estimateTokens(content);
        } else if (content is List) {
          for (final part in content) {
            if (part is Map && part['type'] == 'text') {
              prompt += estimateTokens(part['text']?.toString() ?? '');
            } else if (part is Map && part['type'] == 'image_url') {
              // Rough vision-token estimate; the server's usage is exact.
              prompt += 256;
            }
          }
        }
      }
      message.promptTokens = prompt;
      message.tokensEstimated = true;
    }
    if (message.completionTokens == null) {
      message.completionTokens =
          estimateTokens(completionText ?? message.content) +
          estimateTokens(reasoningText ?? message.reasoning);
      message.tokensEstimated = true;
    }
    message.totalTokens ??=
        (message.promptTokens ?? 0) + (message.completionTokens ?? 0);
  }

  void stop() {
    final chat = activeChat;
    if (chat == null || !isGenerating(chat)) return;
    AppLog.instance.info('Пользователь остановил генерацию');
    _generation.stop(chat.id);
    notifyListeners();
  }

  /// Generates the last answer again, keeping the previous one as a version.
  Future<void> regenerate() async {
    final chat = activeChat;
    if (chat == null || isGenerating(chat)) return;
    final lastUser = chat.messages.lastIndexWhere((m) => m.role == 'user');
    if (lastUser == -1) return;
    await generateAnswerFrom(chat, chat.messages[lastUser]);
  }

  /// Generates or regenerates the answer that follows [userMessage].
  ///
  /// Used by the user-message actions: a branch created from a user message has
  /// no answer yet, while a normal chat can regenerate the first answer. For
  /// older exchanges the caller must create a branch instead, so later messages
  /// are never silently discarded.
  Future<void> generateAnswerFrom(
    ChatSession chat,
    ChatMessage userMessage,
  ) async {
    if (!userMessage.isUser || isGenerating(chat)) return;
    if (isDisconnected) {
      _rejectDisconnected();
      return;
    }
    final index = chat.messages.indexWhere(
      (message) => message.id == userMessage.id,
    );
    if (index < 0) return;

    final server = serverById(chat.serverId) ?? activeServer;
    if (server == null) {
      statusMessage = L10n.t('Сначала добавьте сервер в настройках');
      notifyListeners();
      return;
    }
    if (chat.model.isEmpty) {
      statusMessage = L10n.t('Выберите модель');
      notifyListeners();
      return;
    }

    final next = index + 1 < chat.messages.length
        ? chat.messages[index + 1]
        : null;
    ChatMessage placeholder;
    var isRegeneration = false;
    if (next != null && next.role == 'assistant') {
      if (index + 2 < chat.messages.length) {
        statusMessage = L10n.t('Создайте ветку, чтобы изменить старый ответ');
        notifyListeners();
        return;
      }
      placeholder = next;
      isRegeneration = true;
      placeholder.activeVersion = 0;
      placeholder.archiveCurrent(model: placeholder.model);
    } else if (next == null) {
      placeholder = ChatMessage(
        id: newId(),
        role: 'assistant',
        model: chat.model,
      );
      chat.messages.add(placeholder);
    } else {
      // The next message is another user message: there is no answer to
      // regenerate in this position.
      return;
    }

    placeholder.streaming = true;
    placeholder.error = null;
    await _generate(
      chat: chat,
      server: server,
      placeholder: placeholder,
      isRegeneration: isRegeneration,
    );
  }

  void selectMessageVersion(ChatMessage message, int ordinal) {
    message.selectVersion(ordinal);
    _scheduleSave();
    notifyListeners();
  }

  void deleteMessageVersion(ChatMessage message, int ordinal) {
    message.deleteVersion(ordinal);
    _scheduleSave();
    notifyListeners();
  }

  /// Edits a user message. With [dropFollowing] the rest of the conversation
  /// is removed so the answer can be generated again from this message.
  void editUserMessage(
    ChatSession chat,
    ChatMessage message,
    String text, {
    bool dropFollowing = false,
  }) {
    if (!message.isUser) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty || message.content.trim() == trimmed) return;

    message.content = trimmed;
    if (dropFollowing) {
      final index = chat.messages.indexWhere((m) => m.id == message.id);
      if (index >= 0 && index + 1 < chat.messages.length) {
        chat.messages.removeRange(index + 1, chat.messages.length);
      }
    }
    chat.updatedAt = DateTime.now();
    _scheduleSave();
    notifyListeners();
  }

  /// Replaces the answer with hand-written text. The previous answer stays in
  /// [ChatMessage.versions], so an edit never destroys history.
  void editMessage(ChatSession chat, ChatMessage message, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || message.streaming || message.isUser) return;
    if (message.displayContent.trim() == trimmed) return;

    message.archiveCurrent(model: message.model);
    message.content = trimmed;
    message.reasoning = '';
    message.error = null;
    message.editedAt = DateTime.now();
    message.activeVersion = 0;
    // The old token statistics described the original generation.
    message.promptTokens = null;
    message.completionTokens = null;
    message.totalTokens = null;
    message.generationMs = null;
    message.firstTokenMs = null;
    message.tokensEstimated = false;
    message.generationStartedAt = null;

    chat.updatedAt = DateTime.now();
    _scheduleSave();
    notifyListeners();
  }

  void deleteMessage(ChatSession chat, ChatMessage message) {
    chat.messages.removeWhere((m) => m.id == message.id);
    _scheduleSave();
    notifyListeners();
  }

  // ------------------------------------------------------------------ import

  /// Opens a JSON export and returns its contents without changing anything.
}

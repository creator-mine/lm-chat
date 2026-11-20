part of 'app_state.dart';

extension AppStateTransfer on AppState {
  Future<ImportPreview> pickImportPreview() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) return const ImportPreview(cancelled: true);
      final length = await file.length();
      if (length != null && length > _maxImportBytes) {
        return ImportPreview(
          error: L10n.t('Файл слишком большой для импорта (максимум 32 МБ)'),
        );
      }
      final bytes = await file.readAsBytes();
      return await parseHistoryJsonAsync(
        utf8.decode(bytes, allowMalformed: true),
      );
    } catch (error) {
      AppLog.instance.error(
        'Не удалось импортировать историю',
        detail: '$error',
      );
      return ImportPreview(error: 'Не удалось открыть файл: $error');
    }
  }

  /// Compatibility helper: picks a file and imports every chat.
  Future<ImportResult> importHistoryFromFile() async {
    final preview = await pickImportPreview();
    if (!preview.ok) {
      return ImportResult(cancelled: preview.cancelled, error: preview.error);
    }
    return importPreview(preview);
  }

  /// Parses an export without touching the current history.
  ImportPreview parseHistoryJson(String text) {
    try {
      return _previewFromDecoded(jsonDecode(text));
    } catch (error) {
      AppLog.instance.error('Не удалось прочитать историю', detail: '$error');
      return ImportPreview(
        error: L10n.tf('Не удалось прочитать JSON: {error}', {'error': error}),
      );
    }
  }

  /// Decodes JSON in an isolate, then builds chat objects on the UI isolate.
  Future<ImportPreview> parseHistoryJsonAsync(String text) async {
    try {
      final decoded = await Isolate.run(() => jsonDecode(text));
      return _previewFromDecoded(decoded);
    } catch (error) {
      AppLog.instance.error('Не удалось прочитать историю', detail: '$error');
      return ImportPreview(
        error: L10n.tf('Не удалось прочитать JSON: {error}', {'error': error}),
      );
    }
  }

  ImportPreview _previewFromDecoded(dynamic decoded) {
    try {
      if (decoded is! Map) {
        return const ImportPreview(error: 'Корень JSON должен быть объектом');
      }
      final map = Map<String, dynamic>.from(decoded);
      final isFull = map['chats'] is List;
      final rawChats = isFull ? (map['chats'] as List) : [map];
      final rawServers = isFull && map['servers'] is List
          ? (map['servers'] as List)
          : const <dynamic>[];
      final rawTemplates = isFull && map['promptTemplates'] is List
          ? (map['promptTemplates'] as List)
          : const <dynamic>[];

      final servers = <ServerConfig>[];
      for (final item in rawServers) {
        if (item is Map) {
          final server = ServerConfig.fromJson(Map<String, dynamic>.from(item));
          // Exports never contain credentials. Drop hand-edited tokens and
          // refuse cleartext public addresses before they can become active.
          server.apiKey = '';
          server.bridgeToken = '';
          server.pluginToken = '';
          server.relayToken = '';
          if (server.generationSecurityError != null) {
            AppLog.instance.warning(
              'Пропущен небезопасный сервер из импорта',
              detail: server.baseUrl,
            );
            continue;
          }
          servers.add(server);
        }
      }
      final chats = <ChatSession>[];
      for (final item in rawChats) {
        if (item is Map) {
          chats.add(ChatSession.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      final templates = <PromptTemplate>[];
      for (final item in rawTemplates) {
        if (item is Map) {
          templates.add(
            PromptTemplate.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
      if (chats.isEmpty) {
        return const ImportPreview(error: 'В файле не найдено ни одного чата');
      }
      return ImportPreview(
        servers: servers,
        chats: chats,
        templates: templates,
      );
    } catch (error) {
      AppLog.instance.error('Не удалось прочитать историю', detail: '$error');
      return ImportPreview(
        error: L10n.tf('Не удалось прочитать JSON: {error}', {'error': error}),
      );
    }
  }

  /// Imports every chat from [text]. Kept for automation and tests.
  ImportResult importHistoryJson(String text) {
    final preview = parseHistoryJson(text);
    if (!preview.ok) return ImportResult(error: preview.error);
    return importPreview(preview);
  }

  /// Commits a parsed preview. [selectedChats] contains 0-based indexes into
  /// [ImportPreview.chats]; null means "all chats".
  ImportResult importPreview(
    ImportPreview preview, {
    Set<int>? selectedChats,
    ImportOptions options = const ImportOptions(),
  }) {
    if (!preview.ok) return ImportResult(error: preview.error);
    final selected =
        selectedChats ?? {for (var i = 0; i < preview.chats.length; i++) i};
    final chatsToImport = <ChatSession>[
      for (var i = 0; i < preview.chats.length; i++)
        if (selected.contains(i) &&
            (options.includeArchived || !preview.chats[i].archived))
          preview.chats[i],
    ];
    if (chatsToImport.isEmpty) {
      return const ImportResult(error: 'Не выбран ни один чат');
    }

    try {
      final newTemplates = <PromptTemplate>[];
      final sourceTemplates = options.includeTemplates
          ? preview.templates
          : const <PromptTemplate>[];
      for (final template in sourceTemplates) {
        final idTaken =
            data.promptTemplates.any((t) => t.id == template.id) ||
            newTemplates.any((t) => t.id == template.id);
        newTemplates.add(
          idTaken
              ? PromptTemplate(
                  id: newId(),
                  name: template.name,
                  content: template.content,
                )
              : template,
        );
      }

      final serverMap = <String, String>{};
      final newServers = <ServerConfig>[];
      final sourceServers = options.includeServers
          ? preview.servers
          : const <ServerConfig>[];
      for (final incoming in sourceServers) {
        final server = incoming.clone()
          ..apiKey = ''
          ..bridgeToken = ''
          ..pluginToken = ''
          ..relayToken = '';
        if (server.generationSecurityError != null) continue;
        ServerConfig? existing;
        for (final current in data.servers) {
          if (current.id == server.id ||
              (current.normalizedBase == server.normalizedBase &&
                  current.name == server.name)) {
            existing = current;
            break;
          }
        }
        if (existing != null) {
          serverMap[server.id] = existing.id;
          continue;
        }
        final idTaken =
            data.servers.any((s) => s.id == server.id) ||
            newServers.any((s) => s.id == server.id);
        final target = idTaken
            ? ServerConfig(
                id: newId(),
                name: server.name,
                baseUrl: server.baseUrl,
                apiKey: server.apiKey,
                bridgeUrl: server.bridgeUrl,
                bridgeToken: server.bridgeToken,
                chatViaBridge: server.chatViaBridge,
                pluginUrl: server.pluginUrl,
                pluginToken: server.pluginToken,
                relayUrl: server.relayUrl,
                relayDevice: server.relayDevice,
                relayToken: server.relayToken,
              )
            : server;
        newServers.add(target);
        serverMap[server.id] = target.id;
      }

      final importedIds = <String>{};
      final imported = <ChatSession>[];
      var skipped = 0;
      for (final chat in chatsToImport) {
        if (options.skipExisting &&
            (data.chats.any((c) => c.id == chat.id) ||
                importedIds.contains(chat.id))) {
          skipped++;
          continue;
        }
        final fallbackServerId = data.servers.isNotEmpty
            ? data.servers.first.id
            : newServers.isNotEmpty
            ? newServers.first.id
            : '';
        final mappedServer =
            serverMap[chat.serverId] ??
            serverById(chat.serverId)?.id ??
            activeServer?.id ??
            fallbackServerId;
        var target = chat.clone(serverId: mappedServer);
        if (data.chats.any((c) => c.id == target.id) ||
            importedIds.contains(target.id)) {
          target = target.clone(id: newId());
        }
        importedIds.add(target.id);
        imported.add(target);
      }

      if (imported.isEmpty) {
        return ImportResult(
          skipped: skipped,
          error: 'Все выбранные чаты уже есть в истории',
        );
      }

      // Commit only after the whole selection parsed successfully.
      data.servers.addAll(newServers);
      data.chats.addAll(imported);
      data.promptTemplates.addAll(newTemplates);
      if (newServers.isNotEmpty) _store.markSecretsDirty();
      final importedServers = newServers.length;

      for (final chat in imported) {
        if (chat.archived) continue;
        activeChat = chat;
        if (chat.serverId.isNotEmpty) data.activeServerId = chat.serverId;
        break;
      }
      _scheduleSave();
      _notifyTransfer();
      AppLog.instance.info(
        'Импортировано чатов: ${imported.length}',
        detail: importedServers == 0 && newTemplates.isEmpty && skipped == 0
            ? null
            : 'серверов: $importedServers, промптов: ${newTemplates.length}'
                  '${skipped == 0 ? '' : ', пропущено: $skipped'}',
      );
      return ImportResult(
        chats: imported.length,
        servers: importedServers,
        templates: newTemplates.length,
        skipped: skipped,
      );
    } catch (error) {
      AppLog.instance.error(
        'Не удалось импортировать историю',
        detail: '$error',
      );
      return ImportResult(error: 'Не удалось импортировать: $error');
    }
  }

  // ------------------------------------------------------------------ export

  /// Human-readable Markdown for copying or sharing one chat.
  String chatToMarkdown(
    ChatSession chat, {
    ExportOptions options = const ExportOptions(),
  }) {
    final buffer = StringBuffer('# ${chat.title}\n\n');
    buffer.writeln('_Модель: ${chat.model.isEmpty ? '—' : chat.model}_\n');
    if (chat.systemPrompt.trim().isNotEmpty) {
      buffer.writeln('> System prompt: ${chat.systemPrompt.trim()}\n');
    }
    for (final message in chat.messages) {
      _writeMessageMarkdown(buffer, message, options);
    }
    return buffer.toString();
  }

  /// Human-readable Markdown for the messages the user selected in the chat.
  ///
  /// The order always follows the chat, even when the user selected messages
  /// from the bottom up, so the export reads like a normal conversation.
  String messagesToMarkdown(
    ChatSession chat,
    Iterable<ChatMessage> messages, {
    ExportOptions options = const ExportOptions(),
  }) {
    final selectedIds = {for (final message in messages) message.id};
    final selected = chat.messages
        .where((message) => selectedIds.contains(message.id))
        .toList();
    final buffer = StringBuffer('# ${chat.title}\n\n');
    buffer.writeln('_Модель: ${chat.model.isEmpty ? '—' : chat.model}_\n');
    buffer.writeln(
      '_${L10n.t('Выбранные сообщения')}: ${selected.length} '
      '${L10n.tf('из {count}', {'count': chat.messages.length})}_\n',
    );
    for (final message in selected) {
      _writeMessageMarkdown(buffer, message, options);
    }
    return buffer.toString();
  }

  void _writeMessageMarkdown(
    StringBuffer buffer,
    ChatMessage message,
    ExportOptions options,
  ) {
    if (message.isUser) {
      buffer.writeln('**Вы**\n\n${message.content.trim()}\n');
      if (options.includeAttachmentNames) {
        for (final attachment in message.attachments) {
          buffer.writeln(
            '_${L10n.tf('Изображение: {name}', {'name': attachment.name.isEmpty ? 'image' : attachment.name})}_\n',
          );
        }
      }
      return;
    }
    final model = message.displayModel.isEmpty
        ? ''
        : ' · ${message.displayModel}';
    buffer.writeln('**Ассистент$model**\n');
    if (options.includeReasoning &&
        message.displayReasoning.trim().isNotEmpty) {
      final reasoning = message.displayReasoning.trim().replaceAll(
        '\n',
        '\n> ',
      );
      buffer.writeln('> **Размышления**\n>\n> $reasoning\n');
    }
    buffer.writeln('${message.displayContent.trim()}\n');
    if (options.includeStats && message.displayCompletionTokens != null) {
      final speed = message.displayTokensPerSecond;
      buffer.writeln(
        '_${message.displayCompletionTokens} токенов'
        '${speed == null ? '' : ', ${speed.toStringAsFixed(1)} tok/s'}'
        '${message.displayFirstTokenMs == null ? '' : ', первый токен ${formatGenerationTime(message.displayFirstTokenMs)}'}'
        '_\n',
      );
    }
  }

  /// Human-readable Markdown for the whole history.
  String allChatsToMarkdown({ExportOptions options = const ExportOptions()}) {
    final buffer = StringBuffer('# LM Chat — история\n\n');
    for (final chat in _chatsForExport(options)) {
      buffer.writeln('---\n');
      if (chat.archived) buffer.writeln('_Архив_\n');
      buffer.write(chatToMarkdown(chat, options: options));
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Chats selected by the export scope and archive filter.
  List<ChatSession> _chatsForExport(ExportOptions options) {
    if (options.scope == ExportScope.currentChat) {
      final chat = activeChat;
      return chat == null ? const [] : [chat];
    }
    return [
      for (final chat in chats)
        if (options.includeArchived || !chat.archived) chat,
    ];
  }

  /// Approximate size of the image attachments that will be exported.
  ///
  /// Base64 stores three bytes in four characters, so this is cheap to
  /// compute without encoding anything.
  int exportAttachmentBytes(ExportOptions options) {
    var total = 0;
    for (final chat in _chatsForExport(options)) {
      for (final message in chat.messages) {
        for (final attachment in message.attachments) {
          total += attachment.data.length * 3 ~/ 4;
        }
      }
    }
    return total;
  }

  Future<File?> exportAllChatsMarkdown({
    ExportOptions options = const ExportOptions(),
  }) {
    final current = options.scope == ExportScope.currentChat;
    final chat = current ? activeChat : null;
    final prefix = current ? 'lm_chat_${chat?.id ?? 'chat'}' : 'lm_chat_all';
    return _shareTextFile(
      prefix,
      'md',
      'text/markdown',
      current && chat != null ? chat.title : 'LM Chat — все чаты',
      allChatsToMarkdown(options: options),
    );
  }

  Future<File?> exportChatMarkdown(
    ChatSession chat, {
    ExportOptions options = const ExportOptions(),
  }) => _shareTextFile(
    'lm_chat_${chat.id}',
    'md',
    'text/markdown',
    chat.title,
    chatToMarkdown(chat, options: options),
  );

  Future<File?> exportMessagesMarkdown(
    ChatSession chat,
    List<ChatMessage> messages,
  ) => _shareTextFile(
    'lm_chat_selected_${chat.id}',
    'md',
    'text/markdown',
    '${chat.title} — ${L10n.t('Выбранные сообщения')}',
    messagesToMarkdown(chat, messages),
  );

  Future<File?> exportMessagesJson(
    ChatSession chat,
    List<ChatMessage> messages,
  ) {
    final selectedIds = {for (final message in messages) message.id};
    final selected = chat.messages
        .where((message) => selectedIds.contains(message.id))
        .toList();
    return _shareJson(
      'lm_chat_selected_${chat.id}',
      '${chat.title} — ${L10n.t('Выбранные сообщения')}',
      {
        'app': 'LM Chat',
        'exportedAt': DateTime.now().toIso8601String(),
        'chat': {'id': chat.id, 'title': chat.title, 'model': chat.model},
        'messages': selected.map((message) => message.toJson()).toList(),
      },
    );
  }

  /// Runs the export selected in the export sheet.
  Future<File?> exportWithOptions(
    ExportOptions options, {
    ChatSession? chat,
  }) async {
    if (options.scope == ExportScope.currentChat) {
      final target = chat ?? activeChat;
      if (target == null) return null;
      if (options.format == ExportFormat.markdown) {
        return exportChatMarkdown(target, options: options);
      }
      return exportChats(chat: target, options: options);
    }
    if (options.format == ExportFormat.markdown) {
      return exportAllChatsMarkdown(options: options);
    }
    return exportChats(options: options);
  }

  String _exportStamp() =>
      DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;

  Future<File?> _shareJson(
    String prefix,
    String subject,
    Object payload,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${prefix}_${_exportStamp()}.json',
      );
      final json = await Isolate.run(
        () => const JsonEncoder.withIndent('  ').convert(payload),
      );
      await file.writeAsString(json, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/json')],
          subject: subject,
          title: 'Экспорт LM Chat',
        ),
      );
      return file;
    } catch (error) {
      AppLog.instance.error('Не удалось экспортировать чат', detail: '$error');
      statusMessage = L10n.tf('Не удалось экспортировать: {error}', {
        'error': error,
      });
      _notifyTransfer();
      return null;
    }
  }

  Future<File?> _shareTextFile(
    String prefix,
    String extension,
    String mimeType,
    String subject,
    String text,
  ) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}${prefix}_${_exportStamp()}.$extension',
      );
      await file.writeAsString(text, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mimeType)],
          subject: subject,
          title: 'Экспорт LM Chat',
        ),
      );
      return file;
    } catch (error) {
      AppLog.instance.error('Не удалось экспортировать чат', detail: '$error');
      statusMessage = L10n.tf('Не удалось экспортировать: {error}', {
        'error': error,
      });
      _notifyTransfer();
      return null;
    }
  }

  /// JSON document produced by the export sheet.
  Map<String, dynamic> exportPayload({
    ChatSession? chat,
    ExportOptions options = const ExportOptions(),
  }) {
    final target =
        chat ?? (options.scope == ExportScope.currentChat ? activeChat : null);
    if (target != null) {
      return target.toJson(includeAttachments: options.includeAttachments);
    }
    return {
      'app': 'LM Chat',
      'exportedAt': DateTime.now().toIso8601String(),
      // Export leaves the device via "Share": never include API keys
      // or bridge tokens.
      if (options.includeServers)
        'servers': data.servers
            .map((s) => s.toJson(includeSecrets: false))
            .toList(),
      'chats': _chatsForExport(options)
          .map((c) => c.toJson(includeAttachments: options.includeAttachments))
          .toList(),
      if (options.includeTemplates)
        'promptTemplates': data.promptTemplates.map((t) => t.toJson()).toList(),
    };
  }

  Future<File?> exportChats({
    ChatSession? chat,
    ExportOptions options = const ExportOptions(),
  }) {
    final target =
        chat ?? (options.scope == ExportScope.currentChat ? activeChat : null);
    return _shareJson(
      'lm_chat_${target?.id ?? 'all'}',
      target != null ? target.title : 'LM Chat — экспорт чатов',
      exportPayload(chat: target, options: options),
    );
  }

  // ------------------------------------------------------------- profile sync

  /// Opens a profile file and returns its contents without changing anything.
  Future<ProfilePreview> pickProfilePreview() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: L10n.t('Импорт профиля'),
      );
      if (file == null) return const ProfilePreview(cancelled: true);
      final length = await file.length();
      if (length != null && length > _maxImportBytes) {
        return ProfilePreview(
          sourceName: file.name,
          error: L10n.t('Файл профиля слишком большой (максимум 32 МБ)'),
        );
      }
      final bytes = await file.readAsBytes();
      return await parseProfileJsonAsync(
        utf8.decode(bytes, allowMalformed: true),
        sourceName: file.name,
      );
    } catch (error) {
      AppLog.instance.error('Не удалось прочитать профиль', detail: '$error');
      return ProfilePreview(
        error: L10n.tf('Не удалось прочитать профиль: {error}', {
          'error': error,
        }),
      );
    }
  }

  /// Parses a profile without touching the current settings. Kept synchronous
  /// for automation and tests; the file picker uses the isolate version.
  ProfilePreview parseProfileJson(String text, {String? sourceName}) {
    try {
      return _profilePreviewFromDecoded(jsonDecode(text), sourceName);
    } catch (error) {
      AppLog.instance.error('Не удалось прочитать профиль', detail: '$error');
      return ProfilePreview(
        sourceName: sourceName,
        error: L10n.tf('Не удалось прочитать профиль: {error}', {
          'error': error,
        }),
      );
    }
  }

  Future<ProfilePreview> parseProfileJsonAsync(
    String text, {
    String? sourceName,
  }) async {
    try {
      final decoded = await Isolate.run(() => jsonDecode(text));
      return _profilePreviewFromDecoded(decoded, sourceName);
    } catch (error) {
      AppLog.instance.error('Не удалось прочитать профиль', detail: '$error');
      return ProfilePreview(
        sourceName: sourceName,
        error: L10n.tf('Не удалось прочитать профиль: {error}', {
          'error': error,
        }),
      );
    }
  }

  ProfilePreview _profilePreviewFromDecoded(
    dynamic decoded,
    String? sourceName,
  ) {
    if (decoded is! Map) {
      return ProfilePreview(
        sourceName: sourceName,
        error: 'Корень JSON должен быть объектом',
      );
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map['kind'] != AppProfile.kind) {
      return ProfilePreview(
        sourceName: sourceName,
        error: 'Это не файл профиля LM Chat',
      );
    }
    final hasSettings = map['settings'] is Map;
    final hasServers =
        map['servers'] is List && (map['servers'] as List).isNotEmpty;
    final hasTemplates =
        map['promptTemplates'] is List &&
        (map['promptTemplates'] as List).isNotEmpty;
    if (!hasSettings && !hasServers && !hasTemplates) {
      return ProfilePreview(
        sourceName: sourceName,
        error: 'В файле нет настроек профиля',
      );
    }
    return ProfilePreview(
      profile: AppProfile.fromJson(map),
      sourceName: sourceName,
    );
  }

  /// Saves a profile to a file chosen by the user. No API keys or bridge
  /// tokens are written.
  Future<ProfileExportResult> exportProfile() async {
    try {
      final profile = AppProfile.fromData(data);
      final payload = await Isolate.run(
        () => const JsonEncoder.withIndent('  ').convert(profile.toJson()),
      );
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final uri = await FilePicker.saveFile(
        fileName: 'lm_chat_profile_$stamp.json',
        bytes: Uint8List.fromList(utf8.encode(payload)),
        mimeType: 'application/json',
        dialogTitle: L10n.t('Экспорт профиля'),
      );
      if (uri == null) return const ProfileExportResult(cancelled: true);
      AppLog.instance.info('Профиль сохранён', detail: uri.toString());
      return ProfileExportResult(path: uri.toString());
    } catch (error) {
      AppLog.instance.error('Не удалось сохранить профиль', detail: '$error');
      return ProfileExportResult(
        error: L10n.tf('Не удалось сохранить профиль: {error}', {
          'error': error,
        }),
      );
    }
  }

  /// Merges a profile into the current settings.
  ///
  /// Servers are matched by id first and then by address, so importing the
  /// same profile twice does not create duplicates. Existing access tokens are
  /// preserved because profiles never contain them.
  ProfileImportResult importProfile(
    ProfilePreview preview, {
    ProfileImportOptions options = const ProfileImportOptions(),
  }) {
    if (!preview.ok) {
      return ProfileImportResult(
        cancelled: preview.cancelled,
        error: preview.error,
      );
    }
    if (!options.any) {
      return const ProfileImportResult(error: 'Не выбран ни один раздел');
    }
    final profile = preview.profile!;

    try {
      var serversAdded = 0;
      var serversUpdated = 0;
      var secretsChanged = false;
      if (options.servers) {
        for (final incoming in profile.servers) {
          if (incoming.generationSecurityError != null) continue;
          ServerConfig? match;
          for (final current in data.servers) {
            if (current.id == incoming.id) {
              match = current;
              break;
            }
          }
          if (match == null) {
            final address = incoming.normalizedBase.toLowerCase();
            for (final current in data.servers) {
              if (address.isNotEmpty &&
                  current.normalizedBase.toLowerCase() == address) {
                match = current;
                break;
              }
            }
          }

          if (match == null) {
            final target = incoming.id.trim().isEmpty
                ? ServerConfig(
                    id: newId(),
                    name: incoming.name,
                    baseUrl: incoming.baseUrl,
                    bridgeUrl: incoming.bridgeUrl,
                    chatViaBridge: incoming.chatViaBridge,
                    pluginUrl: incoming.pluginUrl,
                    relayUrl: incoming.relayUrl,
                    relayDevice: incoming.relayDevice,
                  )
                : incoming.clone();
            data.servers.add(target);
            serversAdded++;
            continue;
          }

          final existing = match;
          var changed = false;
          if (existing.name != incoming.name) {
            existing.name = incoming.name;
            changed = true;
          }
          if (existing.baseUrl != incoming.baseUrl) {
            final sameAddress =
                existing.normalizedBase.toLowerCase() ==
                incoming.normalizedBase.toLowerCase();
            existing.baseUrl = incoming.baseUrl;
            if (!sameAddress) {
              // Never send the old token to an address that came from a file.
              existing.apiKey = '';
              secretsChanged = true;
            }
            changed = true;
          }
          if (existing.bridgeUrl != incoming.bridgeUrl) {
            final sameBridge =
                existing.normalizedBridge.toLowerCase() ==
                incoming.normalizedBridge.toLowerCase();
            existing.bridgeUrl = incoming.bridgeUrl;
            if (!sameBridge) {
              // The bridge token belongs to the previous address.
              existing.bridgeToken = '';
              secretsChanged = true;
            }
            changed = true;
          }
          if (existing.chatViaBridge != incoming.chatViaBridge) {
            existing.chatViaBridge = incoming.chatViaBridge;
            changed = true;
          }
          if (existing.pluginUrl != incoming.pluginUrl) {
            final samePlugin =
                existing.normalizedPlugin.toLowerCase() ==
                incoming.normalizedPlugin.toLowerCase();
            existing.pluginUrl = incoming.pluginUrl;
            if (!samePlugin) {
              existing.pluginToken = '';
              secretsChanged = true;
            }
            changed = true;
          }
          if (existing.relayUrl != incoming.relayUrl ||
              existing.relayDevice != incoming.relayDevice) {
            existing.relayUrl = incoming.relayUrl;
            existing.relayDevice = incoming.relayDevice;
            changed = true;
          }
          if (changed) {
            _bridgeApplied.removeWhere(
              (key, _) => key.startsWith('${existing.id}|'),
            );
            _generation.resetBridgeForServer(existing.id);
            serversUpdated++;
          }
        }
        if (data.activeServerId == null && data.servers.isNotEmpty) {
          data.activeServerId = data.servers.first.id;
        }
      }
      if (secretsChanged) _store.markSecretsDirty();

      var templates = 0;
      if (options.prompts) {
        final usedIds = data.promptTemplates.map((t) => t.id).toSet();
        for (final incoming in profile.promptTemplates) {
          final duplicate = data.promptTemplates.any(
            (current) =>
                current.name == incoming.name &&
                current.content == incoming.content,
          );
          if (duplicate) continue;
          final id = incoming.id.trim().isEmpty || usedIds.contains(incoming.id)
              ? newId()
              : incoming.id;
          usedIds.add(id);
          data.promptTemplates.add(
            PromptTemplate(
              id: id,
              name: incoming.name,
              content: incoming.content,
            ),
          );
          templates++;
        }
      }

      if (options.generation) {
        data.defaultTemperature = profile.defaultTemperature;
        data.defaultTopP = profile.defaultTopP;
        data.defaultTopK = profile.defaultTopK.clamp(0, 1000);
        data.defaultRepeatPenalty = profile.defaultRepeatPenalty
            .clamp(0.5, 2.0)
            .toDouble();
        data.defaultMaxTokens = profile.defaultMaxTokens;
        data.defaultSystemPrompt = profile.defaultSystemPrompt;
        data.defaultResponseFormat = profile.defaultResponseFormat;
        data.defaultLaunch = profile.defaultLaunch;
        // The profile carries the settings, not local preset ids.
        data.defaultLaunchPresetId = '';
      }

      if (options.appearance) {
        data.themeMode = profile.themeMode;
        data.appLanguage = profile.appLanguage;
        data.fontFamily = profile.fontFamily;
        data.fontScale = profile.fontScale;
        data.uiDensity = profile.uiDensity;
        _applyLanguage();
      }

      _scheduleSave();
      _notifyTransfer();
      AppLog.instance.info(
        'Профиль применён',
        detail:
            'серверов: +$serversAdded / ~$serversUpdated, '
            'промптов: $templates',
      );
      return ProfileImportResult(
        serversAdded: serversAdded,
        serversUpdated: serversUpdated,
        templates: templates,
      );
    } catch (error) {
      AppLog.instance.error('Не удалось применить профиль', detail: '$error');
      return ProfileImportResult(
        error: L10n.tf('Не удалось применить профиль: {error}', {
          'error': error,
        }),
      );
    }
  }
}

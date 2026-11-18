import 'dart:convert';

import '../models.dart';
import 'bundle.dart';

class SyncMergeResult {
  const SyncMergeResult({
    this.chatsAdded = 0,
    this.chatsUpdated = 0,
    this.messagesAdded = 0,
    this.messagesMerged = 0,
    this.serversAdded = 0,
    this.serverIdsRemapped = 0,
  });

  final int chatsAdded;
  final int chatsUpdated;
  final int messagesAdded;
  final int messagesMerged;
  final int serversAdded;
  final int serverIdsRemapped;

  bool get changed =>
      chatsAdded > 0 ||
      chatsUpdated > 0 ||
      messagesAdded > 0 ||
      messagesMerged > 0 ||
      serversAdded > 0;

  SyncMergeResult operator +(SyncMergeResult other) => SyncMergeResult(
    chatsAdded: chatsAdded + other.chatsAdded,
    chatsUpdated: chatsUpdated + other.chatsUpdated,
    messagesAdded: messagesAdded + other.messagesAdded,
    messagesMerged: messagesMerged + other.messagesMerged,
    serversAdded: serversAdded + other.serversAdded,
    serverIdsRemapped: serverIdsRemapped + other.serverIdsRemapped,
  );
}

/// Merges a remote snapshot into [data] in place.
///
/// Local server settings win on conflicts; missing servers are added without
/// tokens. Chats and messages are unioned by id; when two versions of the same
/// message differ, the newer one wins and the other is preserved as a version.
SyncMergeResult mergeSyncBundle({
  required AppData data,
  required SyncBundle remote,
  required String localDeviceId,
  Set<String> busyChatIds = const {},
}) {
  var result = const SyncMergeResult();

  final serverMap = <String, String>{};
  for (final raw in remote.servers) {
    final incoming = ServerConfig.fromJson(raw);
    incoming.apiKey = '';
    incoming.bridgeToken = '';
    incoming.pluginToken = '';
    incoming.relayToken = '';

    ServerConfig? match;
    for (final current in data.servers) {
      if (current.id == incoming.id) {
        match = current;
        break;
      }
    }
    if (match == null && incoming.normalizedBase.isNotEmpty) {
      for (final current in data.servers) {
        if (current.normalizedBase.toLowerCase() ==
            incoming.normalizedBase.toLowerCase()) {
          match = current;
          break;
        }
      }
    }

    if (match == null) {
      final rawMap = incoming.toJson(includeSecrets: false);
      if ((rawMap['id'] as String? ?? '').trim().isEmpty) {
        rawMap['id'] = newId();
      }
      final target = ServerConfig.fromJson(rawMap)
        ..apiKey = ''
        ..bridgeToken = ''
        ..pluginToken = ''
        ..relayToken = '';
      data.servers.add(target);
      serverMap[incoming.id] = target.id;
      result = result + const SyncMergeResult(serversAdded: 1);
    } else {
      serverMap[incoming.id] = match.id;
    }
  }
  data.activeServerId ??= data.servers.isNotEmpty
      ? data.servers.first.id
      : null;

  final localChats = {for (final chat in data.chats) chat.id: chat};
  for (final raw in remote.chats) {
    final remoteChat = ChatSession.fromJson(raw);
    if (remoteChat.id.trim().isEmpty) continue;

    final mappedServer = serverMap[remoteChat.serverId];
    if (mappedServer != null) {
      if (mappedServer != remoteChat.serverId) {
        result = result + const SyncMergeResult(serverIdsRemapped: 1);
      }
      remoteChat.serverId = mappedServer;
    } else if (remoteChat.serverId.isEmpty ||
        !data.servers.any((server) => server.id == remoteChat.serverId)) {
      final fallback =
          data.activeServerId ??
          (data.servers.isNotEmpty ? data.servers.first.id : '');
      if (fallback.isNotEmpty) remoteChat.serverId = fallback;
    }

    final localChat = localChats[remoteChat.id];
    if (localChat == null) {
      data.chats.add(remoteChat);
      localChats[remoteChat.id] = remoteChat;
      result = result + const SyncMergeResult(chatsAdded: 1);
      continue;
    }

    // Never overwrite a chat that is still generating on this device.
    if (busyChatIds.contains(localChat.id)) continue;
    if (localChat.messages.any((message) => message.hasPendingJob)) continue;

    final chatResult = _mergeChat(localChat, remoteChat);
    if (chatResult.changed) {
      result =
          result +
          SyncMergeResult(
            chatsUpdated: 1,
            messagesAdded: chatResult.messagesAdded,
            messagesMerged: chatResult.messagesMerged,
          );
    }
  }

  return result;
}

class _ChatMerge {
  const _ChatMerge({
    this.metadataChanged = false,
    this.messagesAdded = 0,
    this.messagesMerged = 0,
  });

  final bool metadataChanged;
  final int messagesAdded;
  final int messagesMerged;

  bool get changed =>
      metadataChanged || messagesAdded > 0 || messagesMerged > 0;
}

_ChatMerge _mergeChat(ChatSession local, ChatSession remote) {
  final remoteNewer = remote.updatedAt.isAfter(local.updatedAt);
  if (remoteNewer) {
    local.title = remote.title;
    local.model = remote.model;
    local.temperature = remote.temperature;
    local.topP = remote.topP;
    local.topK = remote.topK;
    local.repeatPenalty = remote.repeatPenalty;
    local.maxTokens = remote.maxTokens;
    local.systemPrompt = remote.systemPrompt;
    local.responseFormat = remote.responseFormat;
    local.launch = remote.launch;
    local.pinned = remote.pinned;
    local.archived = remote.archived;
    if (remote.serverId.isNotEmpty) local.serverId = remote.serverId;
  }

  final localById = {for (final message in local.messages) message.id: message};
  var added = 0;
  var merged = 0;

  for (final remoteMessage in remote.messages) {
    final existing = localById[remoteMessage.id];
    if (existing == null) {
      final copied = _copyMessage(remoteMessage, attachments: const []);
      local.messages.add(copied);
      localById[copied.id] = copied;
      added++;
      continue;
    }

    if (_sameMessage(existing, remoteMessage)) {
      final changed = _mergeVersions(existing, remoteMessage);
      if (changed) merged++;
      continue;
    }

    final remoteTime = _messageTime(remoteMessage);
    final localTime = _messageTime(existing);
    final remoteWins = remoteTime.isAfter(localTime);

    if (remoteWins) {
      final winner = _copyMessage(
        remoteMessage,
        attachments: existing.attachments,
      );
      _addLoserVersion(winner, existing);
      _mergeVersions(winner, existing);
      final index = local.messages.indexOf(existing);
      if (index >= 0) {
        local.messages[index] = winner;
      } else {
        local.messages.add(winner);
      }
      localById[winner.id] = winner;
    } else {
      _addLoserVersion(existing, remoteMessage);
      _mergeVersions(existing, remoteMessage);
    }
    merged++;
  }

  if (added > 0 || merged > 0 || remoteNewer) {
    final order = {
      for (var i = 0; i < local.messages.length; i++) local.messages[i].id: i,
    };
    local.messages.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      if (byTime != 0) return byTime;
      return (order[a.id] ?? 0).compareTo(order[b.id] ?? 0);
    });
    var newest = local.updatedAt;
    if (remote.updatedAt.isAfter(newest)) newest = remote.updatedAt;
    for (final message in local.messages) {
      final time = message.editedAt ?? message.createdAt;
      if (time.isAfter(newest)) newest = time;
    }
    local.updatedAt = newest;
  }

  return _ChatMerge(
    metadataChanged: remoteNewer,
    messagesAdded: added,
    messagesMerged: merged,
  );
}

DateTime _messageTime(ChatMessage message) {
  var time = message.editedAt ?? message.createdAt;
  if (message.versions.isNotEmpty) {
    final last = message.versions.last.createdAt;
    if (last.isAfter(time)) time = last;
  }
  return time;
}

bool _sameMessage(ChatMessage a, ChatMessage b) =>
    a.content == b.content &&
    a.reasoning == b.reasoning &&
    a.model == b.model &&
    a.error == b.error &&
    jsonEncode(a.toolCalls.map((call) => call.toJson()).toList()) ==
        jsonEncode(b.toolCalls.map((call) => call.toJson()).toList());

ChatMessage _copyMessage(
  ChatMessage source, {
  required List<ChatAttachment> attachments,
}) => ChatMessage(
  id: source.id,
  role: source.role,
  content: source.content,
  reasoning: source.reasoning,
  model: source.model,
  attachments: attachments,
  createdAt: source.createdAt,
  error: source.error,
  versions: [...source.versions],
  activeVersion: source.activeVersion,
  promptTokens: source.promptTokens,
  completionTokens: source.completionTokens,
  totalTokens: source.totalTokens,
  generationMs: source.generationMs,
  firstTokenMs: source.firstTokenMs,
  tokensEstimated: source.tokensEstimated,
  generationStartedAt: source.generationStartedAt,
  editedAt: source.editedAt,
  notice: source.notice,
  toolCalls: [...source.toolCalls],
);

void _addLoserVersion(ChatMessage winner, ChatMessage loser) {
  if (_sameMessage(winner, loser)) return;
  final time = loser.editedAt ?? loser.createdAt;
  final duplicate = winner.versions.any(
    (version) =>
        version.content == loser.content &&
        version.reasoning == loser.reasoning &&
        version.model == loser.model &&
        version.createdAt == time,
  );
  if (duplicate) return;
  winner.versions.add(
    ChatMessageVersion(
      id: newId(),
      content: loser.content,
      reasoning: loser.reasoning,
      model: loser.model,
      error: loser.error,
      promptTokens: loser.promptTokens,
      completionTokens: loser.completionTokens,
      totalTokens: loser.totalTokens,
      generationMs: loser.generationMs,
      firstTokenMs: loser.firstTokenMs,
      tokensEstimated: loser.tokensEstimated,
      editedAt: loser.editedAt,
      toolCalls: [...loser.toolCalls],
      createdAt: time,
    ),
  );
  winner.versions.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  if (winner.activeVersion > winner.versions.length) {
    winner.activeVersion = 0;
  }
}

bool _mergeVersions(ChatMessage target, ChatMessage source) {
  var changed = false;
  for (final incoming in source.versions) {
    final duplicate = target.versions.any(
      (version) => version.id == incoming.id,
    );
    if (!duplicate) {
      target.versions.add(incoming);
      changed = true;
    }
  }
  if (changed) {
    target.versions.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (target.activeVersion > target.versions.length) {
      target.activeVersion = 0;
    }
  }
  return changed;
}

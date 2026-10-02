import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';

import '../models/lobe_agent.dart';
import '../models/lobe_drift_models.dart';
import '../models/lobe_json_utils.dart';
import '../models/lobe_message.dart';
import '../models/lobe_topic.dart';

/// Bidirectional entity mappers between LobeHub DTOs and Conduit core models
/// as well as Drift SQLite storage representations.
///
/// Features:
/// - `LobeTopic` <-> `Conversation` (and `ChatRow` / `ChatsCompanion`)
/// - `LobeMessage` <-> `ChatMessage` (and `MessageRow` / `MessagesCompanion`)
/// - `LobeAgent` <-> `Model`
/// - Lossless round-trips for reasoning, tool definitions, and metadata.

// ============================================================================
// 1. LobeTopic <-> Conversation
// ============================================================================

/// Converts a [LobeTopic] into a Conduit [Conversation] model.
Conversation lobeTopicToConversation(
  LobeTopic topic, {
  List<ChatMessage> messages = const <ChatMessage>[],
}) {
  final now = DateTime.now();
  final createdAt = topic.createdAt ?? now;
  final updatedAt = topic.updatedAt ?? createdAt;

  final metadata = <String, dynamic>{
    ...topic.metadata,
    if (topic.agentId != null) 'agentId': topic.agentId,
    if (topic.sessionId != null) 'sessionId': topic.sessionId,
    if (topic.groupId != null) 'groupId': topic.groupId,
    'lobeMetadata': Map<String, dynamic>.from(topic.metadata),
    'lobeTopic': topic.toJson(),
  };

  return Conversation(
    id: topic.id,
    title: (topic.title != null && topic.title!.trim().isNotEmpty)
        ? topic.title!
        : 'Untitled',
    createdAt: createdAt,
    updatedAt: updatedAt,
    pinned: topic.favorite,
    archived: topic.metadata['archived'] == true,
    folderId: topic.groupId,
    model: topic.agentId ?? topic.sessionId,
    messages: messages,
    metadata: metadata,
  );
}

/// Converts a Conduit [Conversation] model back into a [LobeTopic].
LobeTopic conversationToLobeTopic(Conversation conversation) {
  // If original LobeTopic payload was preserved, restore it faithfully.
  final storedTopicRaw = conversation.metadata['lobeTopic'];
  if (storedTopicRaw is Map) {
    final stored = LobeTopic.fromJson(
      Map<String, dynamic>.from(storedTopicRaw),
    );
    Map<String, dynamic> mergedMeta = Map<String, dynamic>.from(stored.metadata);
    if (conversation.metadata['lobeMetadata'] is Map) {
      mergedMeta = Map<String, dynamic>.from(
        conversation.metadata['lobeMetadata'] as Map,
      );
    }
    return stored.copyWith(
      id: conversation.id,
      title: conversation.title,
      favorite: conversation.pinned,
      agentId: conversation.metadata['agentId'] as String? ??
          conversation.model ??
          stored.agentId,
      sessionId: conversation.metadata['sessionId'] as String? ??
          stored.sessionId,
      groupId: conversation.metadata['groupId'] as String? ??
          conversation.folderId ??
          stored.groupId,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      metadata: mergedMeta,
    );
  }

  // Otherwise reconstruct from Conversation fields and metadata.
  Map<String, dynamic> topicMeta = const <String, dynamic>{};
  final lobeMetaRaw = conversation.metadata['lobeMetadata'];
  if (lobeMetaRaw is Map) {
    topicMeta = Map<String, dynamic>.from(lobeMetaRaw);
  } else {
    topicMeta = Map<String, dynamic>.from(conversation.metadata);
    topicMeta.remove('agentId');
    topicMeta.remove('sessionId');
    topicMeta.remove('groupId');
    topicMeta.remove('lobeMetadata');
    topicMeta.remove('lobeTopic');
  }

  final agentId = conversation.metadata['agentId'] as String? ?? conversation.model;
  final sessionId = conversation.metadata['sessionId'] as String? ??
      conversation.metadata['agentId'] as String? ??
      conversation.model;
  final groupId = conversation.metadata['groupId'] as String? ?? conversation.folderId;

  return LobeTopic(
    id: conversation.id,
    title: conversation.title,
    favorite: conversation.pinned,
    agentId: agentId,
    sessionId: sessionId,
    groupId: groupId,
    createdAt: conversation.createdAt,
    updatedAt: conversation.updatedAt,
    metadata: topicMeta,
  );
}

// ============================================================================
// 2. LobeMessage <-> ChatMessage
// ============================================================================

/// Converts a [LobeMessage] into a Conduit [ChatMessage] model.
///
/// Maps reasoning to [ChatMessage.output] (`type: 'reasoning'`) and stores
/// tool definitions in [ChatMessage.embeds] and `metadata['tools']`.
ChatMessage lobeMessageToChatMessage(LobeMessage message) {
  final now = DateTime.now();
  final timestamp = message.createdAt ?? now;

  List<Map<String, dynamic>>? output;
  if (message.reasoning != null && message.reasoning!.isNotEmpty) {
    output = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'reasoning',
        'content': message.reasoning,
        'status': 'completed',
      },
    ];
  }

  List<Map<String, dynamic>>? embeds;
  if (message.tools.isNotEmpty) {
    embeds = List<Map<String, dynamic>>.from(message.tools);
  }

  final metadata = <String, dynamic>{
    if (message.topicId != null) 'topicId': message.topicId,
    if (message.provider != null) 'provider': message.provider,
    if (message.reasoning != null) 'reasoning': message.reasoning,
    if (message.tools.isNotEmpty) 'tools': message.tools,
    if (message.updatedAt != null)
      'updatedAt': message.updatedAt!.toIso8601String(),
    'lobeMessage': message.toJson(),
  };

  return ChatMessage(
    id: message.id,
    role: message.role,
    content: message.content,
    timestamp: timestamp,
    model: message.model,
    output: output,
    embeds: embeds,
    metadata: metadata,
  );
}

/// Converts a Conduit [ChatMessage] model back into a [LobeMessage].
///
/// Supports extracting reasoning from `metadata['reasoning']`, structured
/// `message.output` items, or embedded `<think>...</think>` tags in `message.content`.
LobeMessage chatMessageToLobeMessage(
  ChatMessage message, {
  String? topicId,
}) {
  // If original LobeMessage payload was preserved, restore it faithfully.
  final storedMsgRaw = message.metadata?['lobeMessage'];
  if (storedMsgRaw is Map) {
    final stored = LobeMessage.fromJson(Map<String, dynamic>.from(storedMsgRaw));
    final updatedReasoning =
        message.metadata?['reasoning']?.toString() ?? stored.reasoning;
    final toolsRaw = message.metadata?['tools'];
    final updatedTools = toolsRaw is List
        ? toolsRaw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : stored.tools;

    return stored.copyWith(
      id: message.id,
      role: message.role,
      content: message.content,
      model: message.model ?? stored.model,
      topicId: topicId ?? stored.topicId,
      reasoning: updatedReasoning,
      tools: updatedTools,
      createdAt: message.timestamp,
    );
  }

  // Extract reasoning from metadata, output, or content <think> tags
  String? reasoning = message.metadata?['reasoning']?.toString();
  if (reasoning == null || reasoning.isEmpty) {
    final output = message.output;
    if (output != null) {
      for (final item in output) {
        if (item is Map && item['type']?.toString() == 'reasoning') {
          reasoning = item['content']?.toString() ??
              item['summary']?.toString() ??
              item['text']?.toString() ??
              item['reasoning']?.toString();
          if (reasoning != null && reasoning.isNotEmpty) break;
        }
      }
    }
  }

  var content = message.content;
  if (reasoning == null || reasoning.isEmpty) {
    final thinkMatch =
        RegExp(r'<think>([\s\S]*?)</think>').firstMatch(message.content);
    if (thinkMatch != null) {
      reasoning = thinkMatch.group(1)?.trim();
      // Remove the think tag from the content if output wasn't already structuring it
      content = content.replaceFirst(thinkMatch.group(0)!, '').trim();
    }
  }

  // Extract tools from metadata or embeds
  List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[];
  final toolsRaw = message.metadata?['tools'];
  if (toolsRaw is List) {
    tools = toolsRaw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  } else if (message.embeds != null && message.embeds!.isNotEmpty) {
    tools = message.embeds!
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  final resolvedTopicId = topicId ??
      message.metadata?['topicId']?.toString() ??
      message.metadata?['topic_id']?.toString();

  final rawUpdated = message.metadata?['updatedAt'] ?? message.metadata?['updated_at'];
  final updatedAt = parseLobeDateTime(rawUpdated) ?? message.timestamp;

  return LobeMessage(
    id: message.id,
    topicId: resolvedTopicId,
    role: message.role,
    content: content,
    model: message.model,
    provider: message.metadata?['provider']?.toString(),
    reasoning: reasoning,
    tools: tools,
    createdAt: message.timestamp,
    updatedAt: updatedAt,
  );
}

// ============================================================================
// 3. LobeAgent <-> Conduit Model
// ============================================================================

/// Converts a [LobeAgent] into a Conduit [Model] representation.
Model lobeAgentToModel(LobeAgent agent) {
  final name = (agent.title != null && agent.title!.trim().isNotEmpty)
      ? agent.title!
      : agent.id;

  final metadata = <String, dynamic>{
    if (agent.avatar != null) 'avatar': agent.avatar,
    if (agent.avatar != null) 'icon': agent.avatar,
    if (agent.systemRole != null) 'systemRole': agent.systemRole,
    if (agent.systemRole != null) 'system': agent.systemRole,
    if (agent.model != null) 'model': agent.model,
    if (agent.chatConfig.isNotEmpty) ...{
      'chatConfig': agent.chatConfig,
      'params': agent.chatConfig,
    },
    if (agent.plugins.isNotEmpty) 'plugins': agent.plugins,
    'lobeAgent': agent.toJson(),
  };

  final capabilities = <String, dynamic>{
    if (agent.plugins.isNotEmpty) 'tools': true,
  };

  return Model(
    id: agent.id,
    name: name,
    description: agent.description,
    capabilities: capabilities,
    metadata: metadata,
    toolIds: agent.plugins.isNotEmpty ? List<String>.from(agent.plugins) : null,
  );
}

/// Converts a Conduit [Model] representation back into a [LobeAgent].
LobeAgent modelToLobeAgent(Model model) {
  final storedAgentRaw = model.metadata?['lobeAgent'];
  if (storedAgentRaw is Map) {
    final stored = LobeAgent.fromJson(Map<String, dynamic>.from(storedAgentRaw));
    return stored.copyWith(
      id: model.id,
      title: model.name,
      description: model.description ?? stored.description,
    );
  }

  final meta = model.metadata ?? const <String, dynamic>{};
  final avatar = meta['avatar']?.toString() ?? meta['icon']?.toString();
  final systemRole = meta['systemRole']?.toString() ?? meta['system']?.toString();
  final modelId = meta['model']?.toString();
  final chatConfig = meta['chatConfig'] is Map
      ? Map<String, dynamic>.from(meta['chatConfig'] as Map)
      : (meta['params'] is Map
          ? Map<String, dynamic>.from(meta['params'] as Map)
          : const <String, dynamic>{});
  final plugins = model.toolIds ??
      (meta['plugins'] is List
          ? (meta['plugins'] as List).map((e) => e.toString()).toList()
          : const <String>[]);

  return LobeAgent(
    id: model.id,
    title: model.name,
    description: model.description,
    avatar: avatar,
    systemRole: systemRole,
    model: modelId,
    chatConfig: chatConfig,
    plugins: plugins,
  );
}

// ============================================================================
// 4. Drift Storage Compatibility Helpers (Topic <-> Chats Table)
// ============================================================================

/// Converts a [LobeTopic] to a Drift [ChatsCompanion] ready for database insertion/update.
ChatsCompanion lobeTopicToChatCompanion(LobeTopic topic) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final createdAtSec = (topic.createdAt?.millisecondsSinceEpoch ?? nowMs) ~/ 1000;
  final updatedAtSec =
      ((topic.updatedAt ?? topic.createdAt)?.millisecondsSinceEpoch ?? nowMs) ~/ 1000;

  final metaMap = <String, dynamic>{
    if (topic.agentId != null) 'agentId': topic.agentId,
    if (topic.sessionId != null) 'sessionId': topic.sessionId,
    if (topic.groupId != null) 'groupId': topic.groupId,
    'lobeMetadata': topic.metadata,
    'lobeTopic': topic.toJson(),
  };

  return ChatsCompanion(
    id: Value(topic.id),
    title: Value(topic.title ?? 'Untitled'),
    folderId: topic.groupId == null ? const Value.absent() : Value(topic.groupId),
    pinned: Value(topic.favorite),
    archived: const Value(false),
    createdAt: Value(createdAtSec),
    updatedAt: Value(updatedAtSec),
    rawExtra: Value(jsonEncode(topic.metadata)),
    meta: Value(jsonEncode(metaMap)),
    bodySynced: const Value(true),
  );
}

/// Converts a Drift [ChatRow] back into a [LobeTopic].
LobeTopic chatRowToLobeTopic(ChatRow row) {
  Map<String, dynamic> decodedMeta = const <String, dynamic>{};
  if (row.meta.isNotEmpty && row.meta != '{}') {
    try {
      final d = jsonDecode(row.meta);
      if (d is Map) decodedMeta = Map<String, dynamic>.from(d);
    } catch (_) {}
  }

  final storedTopicRaw = decodedMeta['lobeTopic'];
  if (storedTopicRaw is Map) {
    final stored = LobeTopic.fromJson(Map<String, dynamic>.from(storedTopicRaw));
    return stored.copyWith(
      id: row.id,
      title: row.title,
      favorite: row.pinned,
      groupId: row.folderId ?? stored.groupId,
      createdAt: stored.createdAt ??
          DateTime.fromMillisecondsSinceEpoch(row.createdAt * 1000, isUtc: true),
      updatedAt: stored.updatedAt ??
          DateTime.fromMillisecondsSinceEpoch(row.updatedAt * 1000, isUtc: true),
    );
  }

  Map<String, dynamic> rawExtra = const <String, dynamic>{};
  if (row.rawExtra.isNotEmpty && row.rawExtra != '{}') {
    try {
      final d = jsonDecode(row.rawExtra);
      if (d is Map) rawExtra = Map<String, dynamic>.from(d);
    } catch (_) {}
  }

  final topicMeta = decodedMeta['lobeMetadata'] is Map
      ? Map<String, dynamic>.from(decodedMeta['lobeMetadata'] as Map)
      : rawExtra;

  return LobeTopic(
    id: row.id,
    title: row.title,
    favorite: row.pinned,
    groupId: row.folderId,
    agentId: decodedMeta['agentId']?.toString(),
    sessionId: decodedMeta['sessionId']?.toString(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt * 1000, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt * 1000, isUtc: true),
    metadata: topicMeta,
  );
}

// ============================================================================
// 5. Drift Storage Compatibility Helpers (Message <-> Messages Table)
// ============================================================================

/// Converts a [LobeMessage] to a Drift [MessagesCompanion] ready for database insertion/update.
///
/// Stores the full original message JSON in `payload` column for lossless round-trips.
MessagesCompanion lobeMessageToMessageCompanion(
  LobeMessage message, {
  required String chatId,
  int orderIndex = 0,
}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final createdAtSec = (message.createdAt?.millisecondsSinceEpoch ?? nowMs) ~/ 1000;

  return MessagesCompanion(
    id: Value(message.id),
    chatId: Value(chatId),
    parentId: const Value(null),
    role: Value(message.role),
    content: Value(message.content),
    model: message.model == null ? const Value.absent() : Value(message.model),
    createdAt: Value(createdAtSec),
    orderIndex: Value(orderIndex),
    payload: Value(jsonEncode(message.toJson())),
    dirty: const Value(false),
  );
}

/// Converts a Drift [MessageRow] back into a [LobeMessage].
LobeMessage messageRowToLobeMessage(MessageRow row) {
  if (row.payload.isNotEmpty && row.payload != '{}') {
    try {
      final decoded = jsonDecode(row.payload);
      if (decoded is Map) {
        final fromPayload = LobeMessage.fromJson(Map<String, dynamic>.from(decoded));
        return fromPayload.copyWith(
          id: row.id,
          topicId: fromPayload.topicId ?? row.chatId,
          role: row.role,
          content: row.content,
          model: row.model ?? fromPayload.model,
        );
      }
    } catch (_) {}
  }

  return LobeMessage(
    id: row.id,
    topicId: row.chatId,
    role: row.role,
    content: row.content,
    model: row.model,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt * 1000, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt * 1000, isUtc: true),
  );
}

// ============================================================================
// 6. Map-Based Storage Helpers (Offline & Raw SQLite Fallbacks)
// ============================================================================

/// Converts [LobeTopic] into a raw Map matching the `Chats` table column names.
Map<String, dynamic> lobeTopicToChatRowMap(LobeTopic topic) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final createdAtSec = (topic.createdAt?.millisecondsSinceEpoch ?? nowMs) ~/ 1000;
  final updatedAtSec =
      ((topic.updatedAt ?? topic.createdAt)?.millisecondsSinceEpoch ?? nowMs) ~/ 1000;

  final metaMap = <String, dynamic>{
    if (topic.agentId != null) 'agentId': topic.agentId,
    if (topic.sessionId != null) 'sessionId': topic.sessionId,
    if (topic.groupId != null) 'groupId': topic.groupId,
    'lobeMetadata': topic.metadata,
    'lobeTopic': topic.toJson(),
  };

  return <String, dynamic>{
    'id': topic.id,
    'title': topic.title ?? 'Untitled',
    'folder_id': topic.groupId,
    'pinned': topic.favorite ? 1 : 0,
    'archived': 0,
    'current_message_id': null,
    'created_at': createdAtSec,
    'updated_at': updatedAtSec,
    'server_updated_at': null,
    'dirty': 0,
    'deleted': 0,
    'raw_extra': jsonEncode(topic.metadata),
    'last_read_at': null,
    'share_id': null,
    'user_id': null,
    'meta': jsonEncode(metaMap),
    'blob_meta': '{}',
    'body_synced': 1,
  };
}

/// Converts a raw SQLite `Chats` row Map into a [LobeTopic].
LobeTopic chatRowMapToLobeTopic(Map<String, dynamic> map) {
  final row = ChatRow(
    id: map['id']?.toString() ?? '',
    title: map['title']?.toString() ?? '',
    folderId: map['folder_id']?.toString() ?? map['folderId']?.toString(),
    pinned: map['pinned'] == 1 || map['pinned'] == true,
    archived: map['archived'] == 1 || map['archived'] == true,
    currentMessageId: map['current_message_id']?.toString() ??
        map['currentMessageId']?.toString(),
    createdAt: (map['created_at'] ?? map['createdAt'] ?? 0) as int,
    updatedAt: (map['updated_at'] ?? map['updatedAt'] ?? 0) as int,
    serverUpdatedAt: (map['server_updated_at'] ?? map['serverUpdatedAt']) as int?,
    dirty: map['dirty'] == 1 || map['dirty'] == true,
    deleted: map['deleted'] == 1 || map['deleted'] == true,
    rawExtra: map['raw_extra']?.toString() ?? map['rawExtra']?.toString() ?? '{}',
    lastReadAt: (map['last_read_at'] ?? map['lastReadAt']) as int?,
    shareId: map['share_id']?.toString() ?? map['shareId']?.toString(),
    userId: map['user_id']?.toString() ?? map['userId']?.toString(),
    meta: map['meta']?.toString() ?? '{}',
    blobMeta: map['blob_meta']?.toString() ?? map['blobMeta']?.toString() ?? '{}',
    bodySynced: map['body_synced'] == 1 ||
        map['body_synced'] == true ||
        map['bodySynced'] == true,
  );
  return chatRowToLobeTopic(row);
}

/// Converts [LobeMessage] into a raw Map matching the `Messages` table column names.
Map<String, dynamic> lobeMessageToMessageRowMap(
  LobeMessage message, {
  required String chatId,
  int orderIndex = 0,
}) {
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final createdAtSec = (message.createdAt?.millisecondsSinceEpoch ?? nowMs) ~/ 1000;

  return <String, dynamic>{
    'id': message.id,
    'chat_id': chatId,
    'parent_id': null,
    'role': message.role,
    'content': message.content,
    'model': message.model,
    'created_at': createdAtSec,
    'order_index': orderIndex,
    'payload': jsonEncode(message.toJson()),
    'dirty': 0,
  };
}

/// Converts a raw SQLite `Messages` row Map into a [LobeMessage].
LobeMessage messageRowMapToLobeMessage(Map<String, dynamic> map) {
  final row = MessageRow(
    id: map['id']?.toString() ?? '',
    chatId: map['chat_id']?.toString() ?? map['chatId']?.toString() ?? '',
    parentId: map['parent_id']?.toString() ?? map['parentId']?.toString(),
    role: map['role']?.toString() ?? 'user',
    content: map['content']?.toString() ?? '',
    model: map['model']?.toString(),
    createdAt: (map['created_at'] ?? map['createdAt'] ?? 0) as int,
    orderIndex: (map['order_index'] ?? map['orderIndex'] ?? 0) as int,
    payload: map['payload']?.toString() ?? '{}',
    dirty: map['dirty'] == 1 || map['dirty'] == true,
  );
  return messageRowToLobeMessage(row);
}

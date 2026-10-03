import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

const Object _sentinel = Object();

/// Clean representation of a `Chats` table row in Drift SQLite.
///
/// Corresponds to `@DataClassName('ChatRow') class Chats extends Table`.
/// Pure Dart, fully compatible with Drift runtime operations.
@immutable
class ChatRow extends DataClass implements Insertable<ChatRow> {
  const ChatRow({
    required this.id,
    required this.title,
    this.folderId,
    this.pinned = false,
    this.archived = false,
    this.currentMessageId,
    required this.createdAt,
    required this.updatedAt,
    this.serverUpdatedAt,
    this.dirty = false,
    this.deleted = false,
    this.rawExtra = '{}',
    this.lastReadAt,
    this.shareId,
    this.userId,
    this.meta = '{}',
    this.blobMeta = '{}',
    this.bodySynced = false,
  });

  final String id;
  final String title;
  final String? folderId;
  final bool pinned;
  final bool archived;
  final String? currentMessageId;
  final int createdAt;
  final int updatedAt;
  final int? serverUpdatedAt;
  final bool dirty;
  final bool deleted;
  final String rawExtra;
  final int? lastReadAt;
  final String? shareId;
  final String? userId;
  final String meta;
  final String blobMeta;
  final bool bodySynced;

  @override
  Map<String, Expression<Object>> toColumns(bool nullToAbsent) {
    final map = <String, Expression<Object>>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    map['pinned'] = Variable<bool>(pinned);
    map['archived'] = Variable<bool>(archived);
    if (!nullToAbsent || currentMessageId != null) {
      map['current_message_id'] = Variable<String>(currentMessageId);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || serverUpdatedAt != null) {
      map['server_updated_at'] = Variable<int>(serverUpdatedAt);
    }
    map['dirty'] = Variable<bool>(dirty);
    map['deleted'] = Variable<bool>(deleted);
    map['raw_extra'] = Variable<String>(rawExtra);
    if (!nullToAbsent || lastReadAt != null) {
      map['last_read_at'] = Variable<int>(lastReadAt);
    }
    if (!nullToAbsent || shareId != null) {
      map['share_id'] = Variable<String>(shareId);
    }
    if (!nullToAbsent || userId != null) {
      map['user_id'] = Variable<String>(userId);
    }
    map['meta'] = Variable<String>(meta);
    map['blob_meta'] = Variable<String>(blobMeta);
    map['body_synced'] = Variable<bool>(bodySynced);
    return map;
  }

  ChatsCompanion toCompanion(bool nullToAbsent) {
    return ChatsCompanion(
      id: Value(id),
      title: Value(title),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      pinned: Value(pinned),
      archived: Value(archived),
      currentMessageId: currentMessageId == null && nullToAbsent
          ? const Value.absent()
          : Value(currentMessageId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      serverUpdatedAt: serverUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(serverUpdatedAt),
      dirty: Value(dirty),
      deleted: Value(deleted),
      rawExtra: Value(rawExtra),
      lastReadAt: lastReadAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastReadAt),
      shareId: shareId == null && nullToAbsent
          ? const Value.absent()
          : Value(shareId),
      userId: userId == null && nullToAbsent
          ? const Value.absent()
          : Value(userId),
      meta: Value(meta),
      blobMeta: Value(blobMeta),
      bodySynced: Value(bodySynced),
    );
  }

  factory ChatRow.fromJson(Map<String, dynamic> json) => ChatRow(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    folderId: json['folderId']?.toString() ?? json['folder_id']?.toString(),
    pinned: json['pinned'] == true,
    archived: json['archived'] == true,
    currentMessageId: json['currentMessageId']?.toString() ??
        json['current_message_id']?.toString(),
    createdAt: (json['createdAt'] ?? json['created_at'] ?? 0) as int,
    updatedAt: (json['updatedAt'] ?? json['updated_at'] ?? 0) as int,
    serverUpdatedAt: (json['serverUpdatedAt'] ?? json['server_updated_at']) as int?,
    dirty: json['dirty'] == true,
    deleted: json['deleted'] == true,
    rawExtra: json['rawExtra']?.toString() ?? json['raw_extra']?.toString() ?? '{}',
    lastReadAt: (json['lastReadAt'] ?? json['last_read_at']) as int?,
    shareId: json['shareId']?.toString() ?? json['share_id']?.toString(),
    userId: json['userId']?.toString() ?? json['user_id']?.toString(),
    meta: json['meta']?.toString() ?? '{}',
    blobMeta: json['blobMeta']?.toString() ?? json['blob_meta']?.toString() ?? '{}',
    bodySynced: json['bodySynced'] == true || json['body_synced'] == true,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'folderId': folderId,
    'pinned': pinned,
    'archived': archived,
    'currentMessageId': currentMessageId,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'serverUpdatedAt': serverUpdatedAt,
    'dirty': dirty,
    'deleted': deleted,
    'rawExtra': rawExtra,
    'lastReadAt': lastReadAt,
    'shareId': shareId,
    'userId': userId,
    'meta': meta,
    'blobMeta': blobMeta,
    'bodySynced': bodySynced,
  };

  ChatRow copyWith({
    String? id,
    String? title,
    Object? folderId = _sentinel,
    bool? pinned,
    bool? archived,
    Object? currentMessageId = _sentinel,
    int? createdAt,
    int? updatedAt,
    Object? serverUpdatedAt = _sentinel,
    bool? dirty,
    bool? deleted,
    String? rawExtra,
    Object? lastReadAt = _sentinel,
    Object? shareId = _sentinel,
    Object? userId = _sentinel,
    String? meta,
    String? blobMeta,
    bool? bodySynced,
  }) => ChatRow(
    id: id ?? this.id,
    title: title ?? this.title,
    folderId: identical(folderId, _sentinel) ? this.folderId : folderId as String?,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
    currentMessageId: identical(currentMessageId, _sentinel)
        ? this.currentMessageId
        : currentMessageId as String?,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    serverUpdatedAt: identical(serverUpdatedAt, _sentinel)
        ? this.serverUpdatedAt
        : serverUpdatedAt as int?,
    dirty: dirty ?? this.dirty,
    deleted: deleted ?? this.deleted,
    rawExtra: rawExtra ?? this.rawExtra,
    lastReadAt: identical(lastReadAt, _sentinel)
        ? this.lastReadAt
        : lastReadAt as int?,
    shareId: identical(shareId, _sentinel) ? this.shareId : shareId as String?,
    userId: identical(userId, _sentinel) ? this.userId : userId as String?,
    meta: meta ?? this.meta,
    blobMeta: blobMeta ?? this.blobMeta,
    bodySynced: bodySynced ?? this.bodySynced,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatRow &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          title == other.title &&
          folderId == other.folderId &&
          pinned == other.pinned &&
          archived == other.archived &&
          currentMessageId == other.currentMessageId &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          serverUpdatedAt == other.serverUpdatedAt &&
          dirty == other.dirty &&
          deleted == other.deleted &&
          rawExtra == other.rawExtra &&
          lastReadAt == other.lastReadAt &&
          shareId == other.shareId &&
          userId == other.userId &&
          meta == other.meta &&
          blobMeta == other.blobMeta &&
          bodySynced == other.bodySynced;

  @override
  int get hashCode => Object.hashAll([
    id,
    title,
    folderId,
    pinned,
    archived,
    currentMessageId,
    createdAt,
    updatedAt,
    serverUpdatedAt,
    dirty,
    deleted,
    rawExtra,
    lastReadAt,
    shareId,
    userId,
    meta,
    blobMeta,
    bodySynced,
  ]);

  @override
  String toString() => 'ChatRow(id: $id, title: $title, pinned: $pinned)';
}

/// Clean representation of `ChatsCompanion` in Drift SQLite.
///
/// Uses [Value] to differentiate between absent and explicit null updates.
@immutable
class ChatsCompanion extends UpdateCompanion<ChatRow> {
  const ChatsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.folderId = const Value.absent(),
    this.pinned = const Value.absent(),
    this.archived = const Value.absent(),
    this.currentMessageId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.dirty = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rawExtra = const Value.absent(),
    this.lastReadAt = const Value.absent(),
    this.shareId = const Value.absent(),
    this.userId = const Value.absent(),
    this.meta = const Value.absent(),
    this.blobMeta = const Value.absent(),
    this.bodySynced = const Value.absent(),
  });

  final Value<String> id;
  final Value<String> title;
  final Value<String?> folderId;
  final Value<bool> pinned;
  final Value<bool> archived;
  final Value<String?> currentMessageId;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> serverUpdatedAt;
  final Value<bool> dirty;
  final Value<bool> deleted;
  final Value<String> rawExtra;
  final Value<int?> lastReadAt;
  final Value<String?> shareId;
  final Value<String?> userId;
  final Value<String> meta;
  final Value<String> blobMeta;
  final Value<bool> bodySynced;

  @override
  Map<String, Expression<Object>> toColumns(bool nullToAbsent) {
    final map = <String, Expression<Object>>{};
    if (id.present) map['id'] = Variable<String>(id.value);
    if (title.present) map['title'] = Variable<String>(title.value);
    if (folderId.present) map['folder_id'] = Variable<String>(folderId.value);
    if (pinned.present) map['pinned'] = Variable<bool>(pinned.value);
    if (archived.present) map['archived'] = Variable<bool>(archived.value);
    if (currentMessageId.present) {
      map['current_message_id'] = Variable<String>(currentMessageId.value);
    }
    if (createdAt.present) map['created_at'] = Variable<int>(createdAt.value);
    if (updatedAt.present) map['updated_at'] = Variable<int>(updatedAt.value);
    if (serverUpdatedAt.present) {
      map['server_updated_at'] = Variable<int>(serverUpdatedAt.value);
    }
    if (dirty.present) map['dirty'] = Variable<bool>(dirty.value);
    if (deleted.present) map['deleted'] = Variable<bool>(deleted.value);
    if (rawExtra.present) map['raw_extra'] = Variable<String>(rawExtra.value);
    if (lastReadAt.present) map['last_read_at'] = Variable<int>(lastReadAt.value);
    if (shareId.present) map['share_id'] = Variable<String>(shareId.value);
    if (userId.present) map['user_id'] = Variable<String>(userId.value);
    if (meta.present) map['meta'] = Variable<String>(meta.value);
    if (blobMeta.present) map['blob_meta'] = Variable<String>(blobMeta.value);
    if (bodySynced.present) map['body_synced'] = Variable<bool>(bodySynced.value);
    return map;
  }

  ChatsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String?>? folderId,
    Value<bool>? pinned,
    Value<bool>? archived,
    Value<String?>? currentMessageId,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? serverUpdatedAt,
    Value<bool>? dirty,
    Value<bool>? deleted,
    Value<String>? rawExtra,
    Value<int?>? lastReadAt,
    Value<String?>? shareId,
    Value<String?>? userId,
    Value<String>? meta,
    Value<String>? blobMeta,
    Value<bool>? bodySynced,
  }) => ChatsCompanion(
    id: id ?? this.id,
    title: title ?? this.title,
    folderId: folderId ?? this.folderId,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
    currentMessageId: currentMessageId ?? this.currentMessageId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
    dirty: dirty ?? this.dirty,
    deleted: deleted ?? this.deleted,
    rawExtra: rawExtra ?? this.rawExtra,
    lastReadAt: lastReadAt ?? this.lastReadAt,
    shareId: shareId ?? this.shareId,
    userId: userId ?? this.userId,
    meta: meta ?? this.meta,
    blobMeta: blobMeta ?? this.blobMeta,
    bodySynced: bodySynced ?? this.bodySynced,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatsCompanion &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          title == other.title &&
          folderId == other.folderId &&
          pinned == other.pinned &&
          archived == other.archived &&
          currentMessageId == other.currentMessageId &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          serverUpdatedAt == other.serverUpdatedAt &&
          dirty == other.dirty &&
          deleted == other.deleted &&
          rawExtra == other.rawExtra &&
          lastReadAt == other.lastReadAt &&
          shareId == other.shareId &&
          userId == other.userId &&
          meta == other.meta &&
          blobMeta == other.blobMeta &&
          bodySynced == other.bodySynced;

  @override
  int get hashCode => Object.hashAll([
    id,
    title,
    folderId,
    pinned,
    archived,
    currentMessageId,
    createdAt,
    updatedAt,
    serverUpdatedAt,
    dirty,
    deleted,
    rawExtra,
    lastReadAt,
    shareId,
    userId,
    meta,
    blobMeta,
    bodySynced,
  ]);

  @override
  String toString() => 'ChatsCompanion(id: $id, title: $title)';
}

/// Clean representation of a `Messages` table row in Drift SQLite.
///
/// Corresponds to `@DataClassName('MessageRow') class Messages extends Table`.
/// Pure Dart, fully compatible with Drift runtime operations.
@immutable
class MessageRow extends DataClass implements Insertable<MessageRow> {
  const MessageRow({
    required this.id,
    required this.chatId,
    this.parentId,
    required this.role,
    required this.content,
    this.model,
    required this.createdAt,
    required this.orderIndex,
    required this.payload,
    this.dirty = false,
  });

  final String id;
  final String chatId;
  final String? parentId;
  final String role;
  final String content;
  final String? model;
  final int createdAt;
  final int orderIndex;
  final String payload;
  final bool dirty;

  @override
  Map<String, Expression<Object>> toColumns(bool nullToAbsent) {
    final map = <String, Expression<Object>>{};
    map['id'] = Variable<String>(id);
    map['chat_id'] = Variable<String>(chatId);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    if (!nullToAbsent || model != null) {
      map['model'] = Variable<String>(model);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['order_index'] = Variable<int>(orderIndex);
    map['payload'] = Variable<String>(payload);
    map['dirty'] = Variable<bool>(dirty);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      chatId: Value(chatId),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      role: Value(role),
      content: Value(content),
      model: model == null && nullToAbsent ? const Value.absent() : Value(model),
      createdAt: Value(createdAt),
      orderIndex: Value(orderIndex),
      payload: Value(payload),
      dirty: Value(dirty),
    );
  }

  factory MessageRow.fromJson(Map<String, dynamic> json) => MessageRow(
    id: json['id']?.toString() ?? '',
    chatId: json['chatId']?.toString() ?? json['chat_id']?.toString() ?? '',
    parentId: json['parentId']?.toString() ?? json['parent_id']?.toString(),
    role: json['role']?.toString() ?? 'user',
    content: json['content']?.toString() ?? '',
    model: json['model']?.toString(),
    createdAt: (json['createdAt'] ?? json['created_at'] ?? 0) as int,
    orderIndex: (json['orderIndex'] ?? json['order_index'] ?? 0) as int,
    payload: json['payload']?.toString() ?? '{}',
    dirty: json['dirty'] == true,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'chatId': chatId,
    'parentId': parentId,
    'role': role,
    'content': content,
    'model': model,
    'createdAt': createdAt,
    'orderIndex': orderIndex,
    'payload': payload,
    'dirty': dirty,
  };

  MessageRow copyWith({
    String? id,
    String? chatId,
    Object? parentId = _sentinel,
    String? role,
    String? content,
    Object? model = _sentinel,
    int? createdAt,
    int? orderIndex,
    String? payload,
    bool? dirty,
  }) => MessageRow(
    id: id ?? this.id,
    chatId: chatId ?? this.chatId,
    parentId: identical(parentId, _sentinel) ? this.parentId : parentId as String?,
    role: role ?? this.role,
    content: content ?? this.content,
    model: identical(model, _sentinel) ? this.model : model as String?,
    createdAt: createdAt ?? this.createdAt,
    orderIndex: orderIndex ?? this.orderIndex,
    payload: payload ?? this.payload,
    dirty: dirty ?? this.dirty,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessageRow &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          chatId == other.chatId &&
          parentId == other.parentId &&
          role == other.role &&
          content == other.content &&
          model == other.model &&
          createdAt == other.createdAt &&
          orderIndex == other.orderIndex &&
          payload == other.payload &&
          dirty == other.dirty;

  @override
  int get hashCode => Object.hash(
    id,
    chatId,
    parentId,
    role,
    content,
    model,
    createdAt,
    orderIndex,
    payload,
    dirty,
  );

  @override
  String toString() =>
      'MessageRow(id: $id, chatId: $chatId, role: $role, model: $model)';
}

/// Clean representation of `MessagesCompanion` in Drift SQLite.
///
/// Uses [Value] to differentiate between absent and explicit null updates.
@immutable
class MessagesCompanion extends UpdateCompanion<MessageRow> {
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.chatId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.model = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.orderIndex = const Value.absent(),
    this.payload = const Value.absent(),
    this.dirty = const Value.absent(),
  });

  final Value<String> id;
  final Value<String> chatId;
  final Value<String?> parentId;
  final Value<String> role;
  final Value<String> content;
  final Value<String?> model;
  final Value<int> createdAt;
  final Value<int> orderIndex;
  final Value<String> payload;
  final Value<bool> dirty;

  @override
  Map<String, Expression<Object>> toColumns(bool nullToAbsent) {
    final map = <String, Expression<Object>>{};
    if (id.present) map['id'] = Variable<String>(id.value);
    if (chatId.present) map['chat_id'] = Variable<String>(chatId.value);
    if (parentId.present) map['parent_id'] = Variable<String>(parentId.value);
    if (role.present) map['role'] = Variable<String>(role.value);
    if (content.present) map['content'] = Variable<String>(content.value);
    if (model.present) map['model'] = Variable<String>(model.value);
    if (createdAt.present) map['created_at'] = Variable<int>(createdAt.value);
    if (orderIndex.present) map['order_index'] = Variable<int>(orderIndex.value);
    if (payload.present) map['payload'] = Variable<String>(payload.value);
    if (dirty.present) map['dirty'] = Variable<bool>(dirty.value);
    return map;
  }

  MessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? chatId,
    Value<String?>? parentId,
    Value<String>? role,
    Value<String>? content,
    Value<String?>? model,
    Value<int>? createdAt,
    Value<int>? orderIndex,
    Value<String>? payload,
    Value<bool>? dirty,
  }) => MessagesCompanion(
    id: id ?? this.id,
    chatId: chatId ?? this.chatId,
    parentId: parentId ?? this.parentId,
    role: role ?? this.role,
    content: content ?? this.content,
    model: model ?? this.model,
    createdAt: createdAt ?? this.createdAt,
    orderIndex: orderIndex ?? this.orderIndex,
    payload: payload ?? this.payload,
    dirty: dirty ?? this.dirty,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MessagesCompanion &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          chatId == other.chatId &&
          parentId == other.parentId &&
          role == other.role &&
          content == other.content &&
          model == other.model &&
          createdAt == other.createdAt &&
          orderIndex == other.orderIndex &&
          payload == other.payload &&
          dirty == other.dirty;

  @override
  int get hashCode => Object.hash(
    id,
    chatId,
    parentId,
    role,
    content,
    model,
    createdAt,
    orderIndex,
    payload,
    dirty,
  );

  @override
  String toString() => 'MessagesCompanion(id: $id, chatId: $chatId, role: $role)';
}

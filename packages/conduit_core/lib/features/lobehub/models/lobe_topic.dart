import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'lobe_json_utils.dart';

const Object _sentinel = Object();

/// LobeHub Topic DTO representing a conversation topic thread.
@immutable
class LobeTopic {
  const LobeTopic({
    required this.id,
    this.sessionId,
    this.agentId,
    this.groupId,
    this.title,
    this.favorite = false,
    this.metadata = const <String, dynamic>{},
    this.createdAt,
    this.updatedAt,
  });

  /// Unique topic identifier.
  final String id;

  /// Associated session identifier (often matching the agent id).
  final String? sessionId;

  /// Associated agent identifier.
  final String? agentId;

  /// Optional group identifier.
  final String? groupId;

  /// Topic title.
  final String? title;

  /// Whether the topic is marked as favorite / pinned.
  final bool favorite;

  /// Additional metadata associated with this topic.
  final Map<String, dynamic> metadata;

  /// Timestamp when the topic was created.
  final DateTime? createdAt;

  /// Timestamp when the topic was last updated.
  final DateTime? updatedAt;

  factory LobeTopic.fromJson(Map<String, dynamic> json) => LobeTopic(
    id: json['id']?.toString() ?? '',
    sessionId: json['sessionId']?.toString() ?? json['session_id']?.toString(),
    agentId: json['agentId']?.toString() ?? json['agent_id']?.toString(),
    groupId: json['groupId']?.toString() ?? json['group_id']?.toString(),
    title: json['title']?.toString() ?? json['name']?.toString(),
    favorite: json['favorite'] == true || json['starred'] == true,
    metadata: parseLobeJsonMap(json['metadata'] ?? json['meta']),
    createdAt: parseLobeDateTime(json['createdAt'] ?? json['created_at']),
    updatedAt: parseLobeDateTime(json['updatedAt'] ?? json['updated_at']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (sessionId != null) 'sessionId': sessionId,
    if (agentId != null) 'agentId': agentId,
    if (groupId != null) 'groupId': groupId,
    if (title != null) 'title': title,
    'favorite': favorite,
    'metadata': metadata,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  LobeTopic copyWith({
    String? id,
    Object? sessionId = _sentinel,
    Object? agentId = _sentinel,
    Object? groupId = _sentinel,
    Object? title = _sentinel,
    bool? favorite,
    Map<String, dynamic>? metadata,
    Object? createdAt = _sentinel,
    Object? updatedAt = _sentinel,
  }) => LobeTopic(
    id: id ?? this.id,
    sessionId: identical(sessionId, _sentinel)
        ? this.sessionId
        : sessionId as String?,
    agentId: identical(agentId, _sentinel)
        ? this.agentId
        : agentId as String?,
    groupId: identical(groupId, _sentinel)
        ? this.groupId
        : groupId as String?,
    title: identical(title, _sentinel) ? this.title : title as String?,
    favorite: favorite ?? this.favorite,
    metadata: metadata ?? this.metadata,
    createdAt: identical(createdAt, _sentinel)
        ? this.createdAt
        : createdAt as DateTime?,
    updatedAt: identical(updatedAt, _sentinel)
        ? this.updatedAt
        : updatedAt as DateTime?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeTopic &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          sessionId == other.sessionId &&
          agentId == other.agentId &&
          groupId == other.groupId &&
          title == other.title &&
          favorite == other.favorite &&
          const DeepCollectionEquality().equals(metadata, other.metadata) &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    agentId,
    groupId,
    title,
    favorite,
    const DeepCollectionEquality().hash(metadata),
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'LobeTopic(id: $id, title: $title, favorite: $favorite, createdAt: $createdAt)';
}

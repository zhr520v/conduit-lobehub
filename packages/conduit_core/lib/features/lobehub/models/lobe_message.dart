import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'lobe_json_utils.dart';

const Object _sentinel = Object();

/// LobeHub Message DTO representing a chat message.
@immutable
class LobeMessage {
  const LobeMessage({
    required this.id,
    this.topicId,
    required this.role,
    this.content = '',
    this.model,
    this.provider,
    this.reasoning,
    this.tools = const <Map<String, dynamic>>[],
    this.createdAt,
    this.updatedAt,
  });

  /// Unique message identifier.
  final String id;

  /// Associated topic identifier.
  final String? topicId;

  /// Role of the message sender (e.g. `'user'`, `'assistant'`, `'system'`, `'tool'`).
  final String role;

  /// Text content of the message.
  final String content;

  /// Model identifier used to generate the message.
  final String? model;

  /// Provider identifier (e.g. `'openai'`, `'anthropic'`, `'ollama'`).
  final String? provider;

  /// Thinking / reasoning process content.
  ///
  /// Can originate from a simple string or a structured object in LobeHub.
  final String? reasoning;

  /// Tool calls / plugin executions associated with this message.
  final List<Map<String, dynamic>> tools;

  /// Timestamp when the message was created.
  final DateTime? createdAt;

  /// Timestamp when the message was last updated.
  final DateTime? updatedAt;

  factory LobeMessage.fromJson(Map<String, dynamic> json) => LobeMessage(
    id: json['id']?.toString() ?? '',
    topicId: json['topicId']?.toString() ?? json['topic_id']?.toString(),
    role: json['role']?.toString() ?? 'user',
    content: json['content']?.toString() ?? '',
    model: json['model']?.toString(),
    provider: json['provider']?.toString(),
    reasoning: parseLobeReasoning(json['reasoning']),
    tools: parseLobeJsonList(json['tools']),
    createdAt: parseLobeDateTime(json['createdAt'] ?? json['created_at']),
    updatedAt: parseLobeDateTime(json['updatedAt'] ?? json['updated_at']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (topicId != null) 'topicId': topicId,
    'role': role,
    'content': content,
    if (model != null) 'model': model,
    if (provider != null) 'provider': provider,
    if (reasoning != null) 'reasoning': reasoning,
    'tools': tools,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  LobeMessage copyWith({
    String? id,
    Object? topicId = _sentinel,
    String? role,
    String? content,
    Object? model = _sentinel,
    Object? provider = _sentinel,
    Object? reasoning = _sentinel,
    List<Map<String, dynamic>>? tools,
    Object? createdAt = _sentinel,
    Object? updatedAt = _sentinel,
  }) => LobeMessage(
    id: id ?? this.id,
    topicId: identical(topicId, _sentinel)
        ? this.topicId
        : topicId as String?,
    role: role ?? this.role,
    content: content ?? this.content,
    model: identical(model, _sentinel) ? this.model : model as String?,
    provider: identical(provider, _sentinel)
        ? this.provider
        : provider as String?,
    reasoning: identical(reasoning, _sentinel)
        ? this.reasoning
        : reasoning as String?,
    tools: tools ?? this.tools,
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
      other is LobeMessage &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          topicId == other.topicId &&
          role == other.role &&
          content == other.content &&
          model == other.model &&
          provider == other.provider &&
          reasoning == other.reasoning &&
          const DeepCollectionEquality().equals(tools, other.tools) &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    topicId,
    role,
    content,
    model,
    provider,
    reasoning,
    const DeepCollectionEquality().hash(tools),
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'LobeMessage(id: $id, topicId: $topicId, role: $role, model: $model, createdAt: $createdAt)';
}

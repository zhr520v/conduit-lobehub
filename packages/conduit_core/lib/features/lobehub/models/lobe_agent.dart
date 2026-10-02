import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'lobe_json_utils.dart';

const Object _sentinel = Object();

/// LobeHub Agent (Assistant) DTO representing an agent configuration.
@immutable
class LobeAgent {
  const LobeAgent({
    required this.id,
    this.title,
    this.description,
    this.avatar,
    this.systemRole,
    this.model,
    this.chatConfig = const <String, dynamic>{},
    this.plugins = const <String>[],
    this.createdAt,
    this.updatedAt,
  });

  /// Unique agent identifier.
  final String id;

  /// Agent display title or name.
  final String? title;

  /// Alias for [title] matching LobeHub web API conventions.
  String? get name => title;

  /// Agent description or bio.
  final String? description;

  /// Avatar emoji, image URL, or asset key.
  final String? avatar;

  /// System role prompt / instructions.
  final String? systemRole;

  /// Model identifier configured for this agent (e.g. `'gpt-4o'`).
  final String? model;

  /// Agent chat parameters (temperature, presence_penalty, etc.).
  final Map<String, dynamic> chatConfig;

  /// List of enabled plugin / tool identifiers.
  final List<String> plugins;

  /// Timestamp when the agent was created.
  final DateTime? createdAt;

  /// Timestamp when the agent was last updated.
  final DateTime? updatedAt;

  factory LobeAgent.fromJson(Map<String, dynamic> json) => LobeAgent(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? json['name']?.toString(),
    description: json['description']?.toString(),
    avatar: json['avatar']?.toString(),
    systemRole:
        json['systemRole']?.toString() ?? json['system_role']?.toString(),
    model: json['model']?.toString(),
    chatConfig: parseLobeJsonMap(json['chatConfig'] ?? json['chat_config']),
    plugins: parseLobeStringList(json['plugins']),
    createdAt: parseLobeDateTime(json['createdAt'] ?? json['created_at']),
    updatedAt: parseLobeDateTime(json['updatedAt'] ?? json['updated_at']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (avatar != null) 'avatar': avatar,
    if (systemRole != null) 'systemRole': systemRole,
    if (model != null) 'model': model,
    'chatConfig': chatConfig,
    'plugins': plugins,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  LobeAgent copyWith({
    String? id,
    Object? title = _sentinel,
    Object? description = _sentinel,
    Object? avatar = _sentinel,
    Object? systemRole = _sentinel,
    Object? model = _sentinel,
    Map<String, dynamic>? chatConfig,
    List<String>? plugins,
    Object? createdAt = _sentinel,
    Object? updatedAt = _sentinel,
  }) => LobeAgent(
    id: id ?? this.id,
    title: identical(title, _sentinel) ? this.title : title as String?,
    description: identical(description, _sentinel)
        ? this.description
        : description as String?,
    avatar: identical(avatar, _sentinel) ? this.avatar : avatar as String?,
    systemRole: identical(systemRole, _sentinel)
        ? this.systemRole
        : systemRole as String?,
    model: identical(model, _sentinel) ? this.model : model as String?,
    chatConfig: chatConfig ?? this.chatConfig,
    plugins: plugins ?? this.plugins,
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
      other is LobeAgent &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          title == other.title &&
          description == other.description &&
          avatar == other.avatar &&
          systemRole == other.systemRole &&
          model == other.model &&
          const DeepCollectionEquality().equals(chatConfig, other.chatConfig) &&
          const DeepCollectionEquality().equals(plugins, other.plugins) &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    description,
    avatar,
    systemRole,
    model,
    const DeepCollectionEquality().hash(chatConfig),
    const DeepCollectionEquality().hash(plugins),
    createdAt,
    updatedAt,
  );

  @override
  String toString() =>
      'LobeAgent(id: $id, title: $title, model: $model, plugins: $plugins, createdAt: $createdAt)';
}

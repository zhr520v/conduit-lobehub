import 'package:meta/meta.dart';

import 'lobe_json_utils.dart';

const Object _sentinel = Object();

/// LobeHub User DTO representing user account/profile information.
@immutable
class LobeUser {
  const LobeUser({
    required this.id,
    this.username,
    this.email,
    this.fullName,
    this.avatar,
    this.role,
    this.createdAt,
  });

  /// Unique user identifier.
  final String id;

  /// Username / account handle.
  final String? username;

  /// User email address.
  final String? email;

  /// Full display name of the user.
  final String? fullName;

  /// User avatar image URL or asset.
  final String? avatar;

  /// User authorization role (e.g. `'user'`, `'admin'`).
  final String? role;

  /// Timestamp when the user account was created.
  final DateTime? createdAt;

  factory LobeUser.fromJson(Map<String, dynamic> json) => LobeUser(
    id: json['id']?.toString() ?? '',
    username: json['username']?.toString(),
    email: json['email']?.toString(),
    fullName:
        json['fullName']?.toString() ??
        json['full_name']?.toString() ??
        json['name']?.toString(),
    avatar:
        json['avatar']?.toString() ??
        json['avatarUrl']?.toString() ??
        json['avatar_url']?.toString(),
    role: json['role']?.toString(),
    createdAt: parseLobeDateTime(json['createdAt'] ?? json['created_at']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    if (username != null) 'username': username,
    if (email != null) 'email': email,
    if (fullName != null) 'fullName': fullName,
    if (avatar != null) 'avatar': avatar,
    if (role != null) 'role': role,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
  };

  LobeUser copyWith({
    String? id,
    Object? username = _sentinel,
    Object? email = _sentinel,
    Object? fullName = _sentinel,
    Object? avatar = _sentinel,
    Object? role = _sentinel,
    Object? createdAt = _sentinel,
  }) => LobeUser(
    id: id ?? this.id,
    username: identical(username, _sentinel)
        ? this.username
        : username as String?,
    email: identical(email, _sentinel) ? this.email : email as String?,
    fullName: identical(fullName, _sentinel)
        ? this.fullName
        : fullName as String?,
    avatar: identical(avatar, _sentinel) ? this.avatar : avatar as String?,
    role: identical(role, _sentinel) ? this.role : role as String?,
    createdAt: identical(createdAt, _sentinel)
        ? this.createdAt
        : createdAt as DateTime?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeUser &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          username == other.username &&
          email == other.email &&
          fullName == other.fullName &&
          avatar == other.avatar &&
          role == other.role &&
          createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    username,
    email,
    fullName,
    avatar,
    role,
    createdAt,
  );

  @override
  String toString() =>
      'LobeUser(id: $id, username: $username, email: $email, role: $role)';
}

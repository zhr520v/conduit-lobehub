part of 'api_service.dart';

mixin _AuthApi on _ApiServiceBase {
  void updateAuthToken(String? token) {
    _authInterceptor.updateAuthToken(token);
  }

  /// Prevents a persisted reverse-proxy cookie from being attached to future
  /// requests. Used as a process-local logout fail-safe when durable config
  /// scrubbing cannot be confirmed.
  void setCookieCustomHeaderSuppressed(bool suppressed) {
    _authInterceptor.setCookieCustomHeaderSuppressed(suppressed);
  }

  /// Ensure interceptor callbacks stay in sync if they are set after construction
  void setAuthCallbacks({
    void Function()? onAuthTokenInvalid,
    Future<void> Function()? onTokenInvalidated,
  }) {
    if (onAuthTokenInvalid != null) {
      this.onAuthTokenInvalid = onAuthTokenInvalid;
      _authInterceptor.onAuthTokenInvalid = onAuthTokenInvalid;
    }
    if (onTokenInvalidated != null) {
      this.onTokenInvalidated = onTokenInvalidated;
      _authInterceptor.onTokenInvalidated = onTokenInvalidated;
    }
  }

  // Authentication
  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final response = await _dio.post(
        '/api/v1/auths/signin',
        data: {'email': username, 'password': password},
      );

      return response.data;
    } catch (e) {
      if (e is DioException) {
        // Handle specific redirect cases
        if (e.response?.statusCode == 307 || e.response?.statusCode == 308) {
          final location = e.response?.headers.value('location');
          if (location != null) {
            throw Exception(
              'Server redirect detected. Please check your server URL configuration.',
            );
          }
        }
      }
      rethrow;
    }
  }

  Future<void> logout({ApiAuthSnapshot? authSnapshot}) async {
    await _dio.post(
      '/api/v1/auths/signout',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  /// LDAP authentication - uses username instead of email.
  ///
  /// Returns the same response format as regular login:
  /// `{"token": "...", "token_type": "Bearer", "id": "...", ...}`
  ///
  /// Throws an exception if LDAP is not enabled on the server (400 response).
  Future<Map<String, dynamic>> ldapLogin(
    String username,
    String password,
  ) async {
    try {
      final response = await _dio.post(
        '/api/v1/auths/ldap',
        data: {'user': username, 'password': password},
      );

      return response.data;
    } catch (e) {
      if (e is DioException) {
        // Handle LDAP not enabled
        if (e.response?.statusCode == 400) {
          final data = e.response?.data;
          if (data is Map &&
              data['detail'] == 'LDAP authentication is not enabled') {
            throw Exception('LDAP authentication is not enabled');
          }
          throw Exception('LDAP authentication failed');
        }
        // Handle specific redirect cases
        if (e.response?.statusCode == 307 || e.response?.statusCode == 308) {
          final location = e.response?.headers.value('location');
          if (location != null) {
            throw Exception(
              'Server redirect detected. Please check your server URL configuration.',
            );
          }
        }
      }
      rethrow;
    }
  }

  // User info
  Future<User> getCurrentUser({
    bool suppressAuthFailureNotification = false,
    String? candidateAuthToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final extra = <String, dynamic>{
      if (suppressAuthFailureNotification)
        'suppressAuthFailureNotification': true,
      ApiAuthInterceptor.candidateAuthTokenExtraKey: ?candidateAuthToken,
      ApiAuthInterceptor.authSnapshotExtraKey: ?authSnapshot,
    };
    if (serverConfig.isLobeHub) {
      Response<dynamic> response;
      try {
        response = await _dio.get(
          '/api/v1/users/me',
          options: extra.isEmpty ? null : Options(extra: extra),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          response = await _dio.get(
            '/api/v1/user',
            options: extra.isEmpty ? null : Options(extra: extra),
          );
        } else {
          rethrow;
        }
      }
      DebugLogger.log('user-info', scope: 'api/user');
      final data = response.data;
      final rawMap =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      final userMap = rawMap['data'] is Map
          ? Map<String, dynamic>.from(rawMap['data'] as Map)
          : rawMap['user'] is Map
              ? Map<String, dynamic>.from(rawMap['user'] as Map)
              : rawMap;
      final id = userMap['id']?.toString() ?? 'lobehub_user';
      final username = userMap['fullName']?.toString() ??
          userMap['full_name']?.toString() ??
          userMap['username']?.toString() ??
          userMap['name']?.toString() ??
          'User';
      final email = userMap['email']?.toString() ?? 'user@lobehub';
      final role = userMap['role']?.toString() ?? 'user';
      final avatar = userMap['avatar']?.toString() ??
          userMap['avatarUrl']?.toString() ??
          userMap['avatar_url']?.toString() ??
          userMap['profile_image_url']?.toString();
      return User(
        id: id.isNotEmpty ? id : 'lobehub_user',
        username: username,
        name: username,
        email: email,
        role: role,
        profileImage: avatar,
      );
    }
    final response = await _dio.get(
      '/api/v1/auths/',
      options: extra.isEmpty ? null : Options(extra: extra),
    );
    DebugLogger.log('user-info', scope: 'api/user');
    return User.fromJson(response.data);
  }

  Future<AccountMetadata> getAccountMetadata() async {
    if (serverConfig.isLobeHub) {
      final user = await getCurrentUser();
      return AccountMetadata(
        id: user.id,
        email: user.email,
        name: user.name ?? user.username,
        role: user.role,
        isActive: true,
        profileImageUrl: user.profileImage,
      );
    }
    final results = await Future.wait<dynamic>([
      _dio.get('/api/v1/auths/').then((response) => response.data),
      (() async {
        try {
          return (await _dio.get('/api/v1/users/user/info')).data;
        } catch (_) {
          return null;
        }
      })(),
    ]);

    final accountData = _coerceResponseMap(results[0]);
    if (accountData == null) {
      throw StateError('Unexpected account response type.');
    }

    return AccountMetadata.fromJson(
      accountData,
      info: _coerceResponseMap(results[1]),
    );
  }

  Future<void> updateUserInfo(Map<String, Object?> info) async {
    if (serverConfig.isLobeHub || info.isEmpty) {
      return;
    }
    _traceApi('Updating user info');
    await _dio.post('/api/v1/users/user/info/update', data: info);
  }

  Future<AccountMetadata> updateAccountMetadata({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    if (serverConfig.isLobeHub) {
      return getAccountMetadata();
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('name cannot be empty');
    }

    await _dio.post(
      '/api/v1/auths/update/profile',
      data: {
        'name': trimmedName,
        'profile_image_url': profileImageUrl.trim(),
        'bio': _normalizeNullableString(bio),
        'gender': _normalizeNullableString(gender),
        'date_of_birth': _normalizeNullableString(dateOfBirth),
      },
    );

    if (timezone != null) {
      await _dio.post(
        '/api/v1/auths/update/timezone',
        data: {'timezone': timezone.trim()},
      );
    }

    return getAccountMetadata();
  }

  Future<void> updateAccountPassword({
    required String password,
    required String newPassword,
  }) async {
    if (serverConfig.isLobeHub) {
      throw UnsupportedError('Password update is not supported on LobeHub');
    }
    await _dio.post(
      '/api/v1/auths/update/password',
      data: {'password': password, 'new_password': newPassword},
    );
  }

  Future<WorkspacePagedResponse<WorkspacePrincipalPreview>>
  searchWorkspaceUsers(String query, {int page = 1}) async {
    if (serverConfig.isLobeHub) {
      return const WorkspacePagedResponse(items: [], total: 0);
    }
    final response = await _dio.get(
      '/api/v1/users/search',
      queryParameters: {'query': query, 'page': page},
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspacePrincipalPreview.user,
    );
  }

  Future<List<WorkspacePrincipalPreview>> getWorkspaceGroups() async {
    if (serverConfig.isLobeHub) {
      return const [];
    }
    final response = await _dio.get('/api/v1/groups/');
    return workspaceJsonList(response.data)
        .map(WorkspacePrincipalPreview.group)
        .toList(growable: false);
  }

  // Permissions & Features
  Future<Map<String, dynamic>> getUserPermissions() async {
    if (serverConfig.isLobeHub) {
      return <String, dynamic>{};
    }
    _traceApi('Fetching user permissions');
    try {
      final response = await _dio.get('/api/v1/users/permissions');
      if (response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
      return <String, dynamic>{};
    } catch (e) {
      _traceApi('Error fetching user permissions: $e');
      if (e is DioException) {
        final status = e.response?.statusCode;
        _traceApi('Permissions error response: ${e.response?.data}');
        _traceApi('Permissions error status: $status');
        if (status == 403 || status == 404) {
          // LobeHub routes /api/v1/users/:userId where "permissions" is not a valid user id.
          // Fall back gracefully with default permissions.
          return <String, dynamic>{};
        }
      }
      rethrow;
    }
  }
}

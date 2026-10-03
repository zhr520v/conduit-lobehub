import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';

// ============================================================================
// Exceptions
// ============================================================================

/// Base exception for all LobeHub API client errors.
class LobeHubException implements Exception {
  const LobeHubException(
    this.message, {
    this.statusCode,
    this.responseBody,
    this.cause,
  });

  /// Human-readable error description.
  final String message;

  /// HTTP status code if returned from the server.
  final int? statusCode;

  /// Raw response data associated with the failure.
  final dynamic responseBody;

  /// Original underlying exception if available.
  final Object? cause;

  @override
  String toString() {
    final status = statusCode != null ? ' ($statusCode)' : '';
    return 'LobeHubException$status: $message';
  }
}

/// Thrown when authentication or authorization fails (HTTP 401 or 403).
class LobeHubAuthException extends LobeHubException {
  const LobeHubAuthException(
    super.message, {
    super.statusCode,
    super.responseBody,
    super.cause,
  });

  @override
  String toString() {
    final status = statusCode != null ? ' ($statusCode)' : '';
    return 'LobeHubAuthException$status: $message';
  }
}

/// Thrown when a requested resource is not found (HTTP 404).
class LobeHubNotFoundException extends LobeHubException {
  const LobeHubNotFoundException(
    super.message, {
    super.statusCode,
    super.responseBody,
    super.cause,
  });

  @override
  String toString() {
    final status = statusCode != null ? ' ($statusCode)' : '';
    return 'LobeHubNotFoundException$status: $message';
  }
}

/// Thrown when the LobeHub server returns a 5xx response.
class LobeHubServerException extends LobeHubException {
  const LobeHubServerException(
    super.message, {
    super.statusCode,
    super.responseBody,
    super.cause,
  });

  @override
  String toString() {
    final status = statusCode != null ? ' ($statusCode)' : '';
    return 'LobeHubServerException$status: $message';
  }
}

// ============================================================================
// Interceptors
// ============================================================================

/// Dio interceptor that injects dual authentication headers:
/// - `Authorization: Bearer <token>`
/// - `X-API-Key: <token>`
///
/// Automatically strips any user-entered `Bearer ` prefix (case-insensitive)
/// and trims leading/trailing whitespace.
class LobeAuthInterceptor extends Interceptor {
  LobeAuthInterceptor({
    this.apiKey,
    this.apiKeyProvider,
  });

  /// Static API key string.
  final String? apiKey;

  /// Optional dynamic provider for API keys (e.g. read from secure storage).
  final String? Function()? apiKeyProvider;

  /// Strips any leading 'Bearer ' (case-insensitive) and whitespace.
  static String sanitizeApiKey(String key) {
    var trimmed = key.trim();
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      trimmed = trimmed.substring(7).trim();
    }
    return trimmed;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final rawKey = apiKeyProvider?.call() ?? apiKey;
    if (rawKey != null && rawKey.trim().isNotEmpty) {
      final cleanKey = sanitizeApiKey(rawKey);
      if (cleanKey.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $cleanKey';
        options.headers['X-API-Key'] = cleanKey;
      }
    }
    super.onRequest(options, handler);
  }
}

// ============================================================================
// LobeHubApiClient
// ============================================================================

/// Network client for communicating with self-hosted or cloud LobeHub servers.
///
/// Features:
/// - Base URL normalization handling trailing slashes, subpaths, and `/api/v1` prefixes.
/// - Dual auth header injection (`Authorization: Bearer <key>` and `X-API-Key: <key>`).
/// - Automatic translation of HTTP status codes into typed [LobeHubException]s.
/// - Full CRUD support for Agents, Topics, and Messages.
/// - Flexible list deserialization handling direct lists and wrapped `{data: [...]}`.
class LobeHubApiClient {
  /// Creates a [LobeHubApiClient].
  ///
  /// [baseUrl] is normalized automatically to end with `/api/v1`.
  /// [apiKey] or [apiKeyProvider] supplies the auth token for requests.
  /// An optional [dio] instance can be injected for custom configuration or testing.
  LobeHubApiClient({
    required String baseUrl,
    String? apiKey,
    String? Function()? apiKeyProvider,
    Dio? dio,
  })  : baseUrl = normalizeBaseUrl(baseUrl),
        rootUrl = extractRootUrl(normalizeBaseUrl(baseUrl)),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 45),
                sendTimeout: const Duration(seconds: 45),
              ),
            ) {
    _dio.options.baseUrl = this.baseUrl;
    _dio.options.headers.putIfAbsent('Accept', () => 'application/json');

    // Configure badCertificateCallback for self-hosted instances (e.g. Let's Encrypt ECC, self-signed certs)
    final adapter = _dio.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () {
        final client = HttpClient();
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      };
    }

    // Attach LobeAuthInterceptor if not already registered.
    final hasAuthInterceptor =
        _dio.interceptors.any((i) => i is LobeAuthInterceptor);
    if (!hasAuthInterceptor) {
      _dio.interceptors.add(
        LobeAuthInterceptor(
          apiKey: apiKey,
          apiKeyProvider: apiKeyProvider,
        ),
      );
    }
  }

  /// Normalized API base URL ending with `/api/v1` (e.g. `https://ai.example.com/api/v1`).
  final String baseUrl;

  /// Root URL without the `/api/v1` suffix (e.g. `https://ai.example.com`).
  final String rootUrl;

  final Dio _dio;

  /// Underlying [Dio] instance used by this client.
  Dio get dio => _dio;

  /// Normalizes a user-provided base URL to ensure clean `/api/v1` suffixing.
  ///
  /// Examples:
  /// - `https://ai.opw.ink` -> `https://ai.opw.ink/api/v1`
  /// - `https://ai.opw.ink/` -> `https://ai.opw.ink/api/v1`
  /// - `https://ai.opw.ink/api/v1` -> `https://ai.opw.ink/api/v1`
  /// - `https://ai.opw.ink/api/v1/` -> `https://ai.opw.ink/api/v1`
  /// - `https://ai.opw.ink/custom/path/` -> `https://ai.opw.ink/custom/path/api/v1`
  /// - `https://ai.opw.ink/api/v1/api/v1` -> `https://ai.opw.ink/api/v1`
  static String normalizeBaseUrl(String rawUrl) {
    var trimmed = rawUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    while (trimmed.endsWith('/api/v1')) {
      trimmed = trimmed.substring(0, trimmed.length - '/api/v1'.length);
      while (trimmed.endsWith('/')) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
    }
    if (trimmed.isEmpty) {
      return '/api/v1';
    }
    return '$trimmed/api/v1';
  }

  /// Extracts the host root URL without trailing `/api/v1`.
  static String extractRootUrl(String normalizedBaseUrl) {
    var trimmed = normalizedBaseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.endsWith('/api/v1')) {
      trimmed = trimmed.substring(0, trimmed.length - '/api/v1'.length);
      while (trimmed.endsWith('/')) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
    }
    return trimmed;
  }

  /// Builds a resolved request path incorporating subpaths from [rootUrl].
  String _buildPath(String endpoint) {
    var ep = endpoint.trim();
    if (!ep.startsWith('/')) {
      ep = '/$ep';
    }

    final rootUri = Uri.tryParse(rootUrl);
    final rootPath = (rootUri != null && rootUri.path.isNotEmpty)
        ? (rootUri.path.endsWith('/')
            ? rootUri.path.substring(0, rootUri.path.length - 1)
            : rootUri.path)
        : '';

    return '$rootPath$ep';
  }

  // ==========================================================================
  // Health & User APIs
  // ==========================================================================

  /// Checks server health via `GET /api/v1/health`.
  ///
  /// Falls back to `GET /api/health` if `/api/v1/health` returns 404.
  Future<LobeHealthResponse> checkHealth() async {
    try {
      final response = await _get<dynamic>(_buildPath('/api/v1/health'));
      return _parseHealthResponse(response);
    } on LobeHubNotFoundException {
      final response = await _get<dynamic>(_buildPath('/api/health'));
      return _parseHealthResponse(response);
    }
  }

  /// Retrieves the current authenticated user profile.
  ///
  /// Tries `GET /api/v1/users/me`, falling back to `GET /api/v1/user` on 404.
  Future<LobeUser> getCurrentUser() async {
    try {
      final response = await _get<dynamic>(_buildPath('/api/v1/users/me'));
      return LobeUser.fromJson(_extractMap(response));
    } on LobeHubNotFoundException {
      final response = await _get<dynamic>(_buildPath('/api/v1/user'));
      return LobeUser.fromJson(_extractMap(response));
    }
  }

  // ==========================================================================
  // Agents (Assistants) CRUD
  // ==========================================================================

  /// Lists agents configured on the server.
  ///
  /// Supports optional [page], [pageSize], and [search] filtering.
  Future<List<LobeAgent>> getAgents({
    int? page,
    int? pageSize,
    String? search,
  }) async {
    final queryParameters = <String, dynamic>{
      if (page != null) 'page': page,
      if (pageSize != null) 'pageSize': pageSize,
      if (search != null && search.isNotEmpty) 'search': search,
    };

    final data = await _get<dynamic>(
      _buildPath('/api/v1/agents'),
      queryParameters: queryParameters,
    );

    return _extractList(data)
        .map((item) =>
            item is Map ? LobeAgent.fromJson(Map<String, dynamic>.from(item)) : null)
        .whereNotNull()
        .toList();
  }

  /// Retrieves a single agent by its unique [agentId].
  Future<LobeAgent> getAgent(String agentId) async {
    final data = await _get<dynamic>(_buildPath('/api/v1/agents/$agentId'));
    return LobeAgent.fromJson(_extractMap(data));
  }

  /// Creates a new agent with the given payload [data].
  Future<LobeAgent> createAgent(Map<String, dynamic> data) async {
    final res = await _post<dynamic>(_buildPath('/api/v1/agents'), data: data);
    return LobeAgent.fromJson(_extractMap(res));
  }

  /// Updates an existing agent identified by [agentId] with [data].
  Future<LobeAgent> updateAgent(
    String agentId,
    Map<String, dynamic> data,
  ) async {
    final res = await _patch<dynamic>(
      _buildPath('/api/v1/agents/$agentId'),
      data: data,
    );
    return LobeAgent.fromJson(_extractMap(res));
  }

  /// Deletes an agent by [agentId]. Returns `true` on success.
  Future<bool> deleteAgent(String agentId) async {
    await _delete<dynamic>(_buildPath('/api/v1/agents/$agentId'));
    return true;
  }

  // ==========================================================================
  // Topics CRUD
  // ==========================================================================

  /// Lists conversation topics.
  ///
  /// Optionally filters by [agentId], [page], [pageSize], and [search].
  Future<List<LobeTopic>> getTopics({
    String? agentId,
    int? page,
    int? pageSize,
    String? search,
  }) async {
    final queryParameters = <String, dynamic>{
      if (agentId != null) 'agentId': agentId,
      if (page != null) 'page': page,
      if (pageSize != null) 'pageSize': pageSize,
      if (search != null && search.isNotEmpty) 'search': search,
    };

    final data = await _get<dynamic>(
      _buildPath('/api/v1/topics'),
      queryParameters: queryParameters,
    );

    return _extractList(data)
        .map((item) =>
            item is Map ? LobeTopic.fromJson(Map<String, dynamic>.from(item)) : null)
        .whereNotNull()
        .toList();
  }

  /// Creates a new topic thread.
  Future<LobeTopic> createTopic({
    required String title,
    String? agentId,
    String? sessionId,
    Map<String, dynamic>? metadata,
  }) async {
    final payload = <String, dynamic>{
      'title': title,
      if (agentId != null) 'agentId': agentId,
      if (sessionId != null) 'sessionId': sessionId,
      if (metadata != null) 'metadata': metadata,
    };

    final res = await _post<dynamic>(
      _buildPath('/api/v1/topics'),
      data: payload,
    );
    return LobeTopic.fromJson(_extractMap(res));
  }

  /// Updates an existing topic identified by [topicId].
  Future<LobeTopic> updateTopic(
    String topicId, {
    String? title,
    bool? favorite,
    Map<String, dynamic>? metadata,
  }) async {
    final payload = <String, dynamic>{
      if (title != null) 'title': title,
      if (favorite != null) 'favorite': favorite,
      if (metadata != null) 'metadata': metadata,
    };

    final res = await _patch<dynamic>(
      _buildPath('/api/v1/topics/$topicId'),
      data: payload,
    );
    return LobeTopic.fromJson(_extractMap(res));
  }

  /// Deletes a topic thread by [topicId]. Returns `true` on success.
  Future<bool> deleteTopic(String topicId) async {
    await _delete<dynamic>(_buildPath('/api/v1/topics/$topicId'));
    return true;
  }

  // ==========================================================================
  // Messages CRUD
  // ==========================================================================

  /// Lists chat messages.
  ///
  /// Optionally filters by [topicId], [agentId], [page], [pageSize], and [order].
  Future<List<LobeMessage>> getMessages({
    String? topicId,
    String? agentId,
    int? page,
    int? pageSize,
    String? order,
  }) async {
    final queryParameters = <String, dynamic>{
      if (topicId != null) 'topicId': topicId,
      if (agentId != null) 'agentId': agentId,
      if (page != null) 'page': page,
      if (pageSize != null) 'pageSize': pageSize,
      if (order != null) 'order': order,
    };

    final data = await _get<dynamic>(
      _buildPath('/api/v1/messages'),
      queryParameters: queryParameters,
    );

    return _extractList(data)
        .map((item) =>
            item is Map ? LobeMessage.fromJson(Map<String, dynamic>.from(item)) : null)
        .whereNotNull()
        .toList();
  }

  /// Creates a new chat message.
  Future<LobeMessage> createMessage({
    required String role,
    required String content,
    String? topicId,
    String? agentId,
    String? model,
    String? provider,
    String? reasoning,
    List<Map<String, dynamic>>? tools,
  }) async {
    final payload = <String, dynamic>{
      'role': role,
      'content': content,
      if (topicId != null) 'topicId': topicId,
      if (agentId != null) 'agentId': agentId,
      if (model != null) 'model': model,
      if (provider != null) 'provider': provider,
      if (reasoning != null) 'reasoning': reasoning,
      if (tools != null) 'tools': tools,
    };

    final res = await _post<dynamic>(
      _buildPath('/api/v1/messages'),
      data: payload,
    );
    return LobeMessage.fromJson(_extractMap(res));
  }

  /// Sends a streaming chat completion request to `POST /api/v1/responses`.
  Future<ResponseBody> createResponsesStream({
    required Map<String, dynamic> data,
    CancelToken? cancelToken,
  }) async {
    return _send<ResponseBody>(
      () => _dio.post<ResponseBody>(
        _buildPath('/api/v1/responses'),
        data: data,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
        ),
      ),
    );
  }

  /// Updates an existing message identified by [messageId].
  Future<LobeMessage> updateMessage(
    String messageId, {
    String? content,
    String? reasoning,
  }) async {
    final payload = <String, dynamic>{
      if (content != null) 'content': content,
      if (reasoning != null) 'reasoning': reasoning,
    };

    final res = await _patch<dynamic>(
      _buildPath('/api/v1/messages/$messageId'),
      data: payload,
    );
    return LobeMessage.fromJson(_extractMap(res));
  }

  /// Deletes a chat message by [messageId]. Returns `true` on success.
  Future<bool> deleteMessage(String messageId) async {
    await _delete<dynamic>(_buildPath('/api/v1/messages/$messageId'));
    return true;
  }

  /// Closes the client and its underlying Dio instance.
  void close({bool force = false}) {
    _dio.close(force: force);
  }

  // ==========================================================================
  // Internal HTTP Helpers
  // ==========================================================================

  Future<T> _get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) =>
      _send<T>(() => _dio.get<T>(
            path,
            queryParameters: queryParameters,
            options: options,
          ));

  Future<T> _post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) =>
      _send<T>(() => _dio.post<T>(
            path,
            data: data,
            queryParameters: queryParameters,
            options: options,
          ));

  Future<T> _patch<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) =>
      _send<T>(() => _dio.patch<T>(
            path,
            data: data,
            queryParameters: queryParameters,
            options: options,
          ));

  Future<T> _delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) =>
      _send<T>(() => _dio.delete<T>(
            path,
            data: data,
            queryParameters: queryParameters,
            options: options,
          ));

  Future<T> _send<T>(Future<Response<T>> Function() request) async {
    try {
      final response = await request();
      return response.data as T;
    } on DioException catch (e) {
      throw _mapDioException(e);
    } catch (e) {
      if (e is LobeHubException) rethrow;
      throw LobeHubException(e.toString(), cause: e);
    }
  }

  /// Maps a [DioException] to a typed [LobeHubException].
  LobeHubException mapDioException(DioException e) => _mapDioException(e);

  LobeHubException _mapDioException(DioException e) {
    final statusCode = e.response?.statusCode;
    var rawMessage = e.message ?? 'HTTP request failed with status $statusCode';
    if (e.response == null && e.error != null) {
      rawMessage = '$rawMessage (${e.error})';
    }
    final message = _extractErrorMessage(
      e.response,
      rawMessage,
    );
    final responseBody = e.response?.data;

    if (statusCode == 401 || statusCode == 403) {
      return LobeHubAuthException(
        message,
        statusCode: statusCode,
        responseBody: responseBody,
        cause: e,
      );
    }

    if (statusCode == 404) {
      return LobeHubNotFoundException(
        message,
        statusCode: statusCode,
        responseBody: responseBody,
        cause: e,
      );
    }

    if (statusCode != null && statusCode >= 500 && statusCode < 600) {
      return LobeHubServerException(
        message,
        statusCode: statusCode,
        responseBody: responseBody,
        cause: e,
      );
    }

    return LobeHubException(
      message,
      statusCode: statusCode,
      responseBody: responseBody,
      cause: e,
    );
  }

  static String _extractErrorMessage(Response? response, String fallback) {
    if (response?.data != null) {
      final data = response!.data;
      if (data is Map) {
        if (data['message'] != null) return data['message'].toString();
        if (data['error'] is Map && data['error']['message'] != null) {
          return data['error']['message'].toString();
        }
        if (data['error'] != null) return data['error'].toString();
        if (data['detail'] != null) return data['detail'].toString();
      } else if (data is String && data.trim().isNotEmpty) {
        return data;
      }
    }
    return fallback;
  }

  static Map<String, dynamic> _extractMap(dynamic responseData) {
    if (responseData is Map) {
      final map = Map<String, dynamic>.from(responseData);
      if (map['data'] is Map) {
        return Map<String, dynamic>.from(map['data'] as Map);
      }
      if (map['user'] is Map) {
        return Map<String, dynamic>.from(map['user'] as Map);
      }
      return map;
    }
    return <String, dynamic>{};
  }

  static List<dynamic> _extractList(dynamic responseData) {
    if (responseData is List) {
      return responseData;
    }
    if (responseData is Map) {
      if (responseData['data'] is List) {
        return responseData['data'] as List;
      }
      if (responseData['items'] is List) {
        return responseData['items'] as List;
      }
      if (responseData['list'] is List) {
        return responseData['list'] as List;
      }
      if (responseData['topics'] is List) {
        return responseData['topics'] as List;
      }
      if (responseData['agents'] is List) {
        return responseData['agents'] as List;
      }
      if (responseData['messages'] is List) {
        return responseData['messages'] as List;
      }
    }
    return const [];
  }

  static LobeHealthResponse _parseHealthResponse(dynamic data) {
    if (data is Map) {
      return LobeHealthResponse.fromJson(Map<String, dynamic>.from(data));
    }
    if (data is String && data.toLowerCase().contains('ok')) {
      return const LobeHealthResponse(service: 'lobehub', status: 'ok');
    }
    return const LobeHealthResponse(service: 'lobehub', status: 'unknown');
  }
}

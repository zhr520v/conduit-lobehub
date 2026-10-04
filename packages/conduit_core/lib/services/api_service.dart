import 'package:meta/meta.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http_parser/http_parser.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/sse_frame_scanner.dart';

import 'package:conduit_core/network/io/public_health_probe.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/knowledge_base.dart';
import 'package:conduit_core/models/knowledge_base_file.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/models/server_about_info.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';

import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:conduit_core/network/same_origin_redirect_interceptor.dart';
export 'package:conduit_core/network/same_origin_redirect_interceptor.dart'
    show isCredentialSafeRedirectTarget, nextSameOriginRedirectRequest;

import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';

import 'package:conduit_core/error/api_error_interceptor.dart';

import 'package:conduit_core/sync/sync_api_client.dart'
    show SyncTerminalException;
// Tool-call details are parsed in the UI layer to render collapsible blocks
import 'package:conduit_core/services/connectivity_service.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_markdown/conduit_markdown.dart';

import 'package:conduit_core/utils/openwebui_message_payload.dart';
import 'package:conduit_core/utils/json_normalization.dart';

import 'package:conduit_core/utils/message_tree_utils.dart' as message_tree;
import 'package:conduit_core/services/conversation_parsing.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'package:conduit_core/services/worker_manager.dart';

import 'package:conduit_core/services/server_tls_http_client_factory.dart';

/// Re-exported so the health prober's move into `conduit_core` is invisible
/// to callers: these six names were public here before the extraction.
export 'package:conduit_core/network/io/public_health_probe.dart'
    show
        PublicHealthAddressResolver,
        PublicHealthSocketConnector,
        PublicHealthSocketUpgrader,
        isPublicHealthRedirectAddress,
        isPublicHealthRedirectAddressWithNat64DiscoveryForTest,
        requestUsesServerConnectivityOrigin;
part 'api_service_auth.dart';
part 'api_service_base.dart';
part 'api_service_channels.dart';
part 'api_service_chat_completions.dart';
part 'api_service_chat_lists.dart';
part 'api_service_chats.dart';
part 'api_service_chats_raw.dart';
part 'api_service_evaluations.dart';
part 'api_service_files.dart';
part 'api_service_folders_tags.dart';
part 'api_service_health.dart';
part 'api_service_knowledge_bases.dart';
part 'api_service_media_retrieval.dart';
part 'api_service_models.dart';
part 'api_service_notes.dart';
part 'api_service_prompts_skills.dart';
part 'api_service_tools_functions.dart';
part 'api_service_user_settings.dart';
part 'api_service_workspace_knowledge.dart';

const bool _traceApiLogs = false;
const int _conversationWorkerByteThreshold = 50 * 1024;
const int _conversationSummaryWorkerItemThreshold = 24;
const int _fileUploadTimeoutBytesPerSecondFloor = 128 * 1024;
const Duration _minimumFileUploadTimeout = Duration(minutes: 5);

Future<void> _cancelPublicHealthResponse(Response<dynamic>? response) async {
  final body = response?.data;
  if (body is! ResponseBody) return;
  try {
    final subscription = body.stream.listen(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await subscription.cancel();
  } catch (_) {
    // The request client may already have closed the native response stream.
  }
}

CancelToken _linkedPublicHealthCancelToken(CancelToken parent) {
  final child = CancelToken();
  if (parent.isCancelled) {
    child.cancel(parent.cancelError);
    return child;
  }
  unawaited(
    parent.whenCancel.then<void>((_) {
      if (!child.isCancelled) child.cancel(parent.cancelError);
    }),
  );
  return child;
}

final class FileContentTooLargeException implements Exception {
  const FileContentTooLargeException();

  @override
  String toString() => 'File content exceeds the configured byte limit.';
}

/// Forwards caller cancellation without giving request-local guards ownership
/// of a token that may be shared with other file lookups.
final class _FileContentCancellationLink {
  _FileContentCancellationLink(CancelToken? caller) {
    if (caller == null) return;
    final cancellation = caller.cancelError;
    if (cancellation != null) {
      requestToken.cancel(cancellation.error);
      return;
    }

    // CancelToken exposes a Future rather than a removable listener. Keep only
    // a weak link in that future so a completed request and its transport are
    // collectible even when a long-lived shared caller token is never cancelled.
    final weakLink = WeakReference<_FileContentCancellationLink>(this);
    unawaited(
      caller.whenCancel.then<void>(
        (error) => weakLink.target?._forward(error),
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  final CancelToken requestToken = CancelToken();
  bool _attached = true;

  void _forward(DioException error) {
    if (_attached && !requestToken.isCancelled) {
      requestToken.cancel(error.error);
    }
  }

  void detach() => _attached = false;
}

Future<bool> _moveFileContentStreamOrCancel(
  StreamIterator<List<int>> iterator,
  CancelToken? cancelToken,
) {
  final cancellation = cancelToken?.cancelError;
  if (cancellation != null) return Future<bool>.error(cancellation);
  final move = iterator.moveNext();
  if (cancelToken == null) return move;
  // Future.any observes the losing stream move as well as the cancellation
  // branch, so a source that reports a late error after cancellation cannot
  // escape through the zone.
  return Future.any<bool>(<Future<bool>>[
    move,
    cancelToken.whenCancel.then<bool>((error) => throw error),
  ]);
}

void _cancelFileContentStreamIterator(StreamIterator<List<int>> iterator) {
  try {
    unawaited(
      iterator.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  } catch (_) {
    // The request token already revoked transport ownership. Source teardown
    // is best effort and must not delay Stop or replace the primary error.
  }
}

void _traceApi(String message) {
  if (!_traceApiLogs) {
    return;
  }
  DebugLogger.log(message, scope: 'api/trace');
}

Duration _fileUploadTimeoutForBytes(int bytes) {
  final estimatedUploadSeconds =
      (bytes / _fileUploadTimeoutBytesPerSecondFloor).ceil() + 120;
  final timeout = Duration(seconds: estimatedUploadSeconds);
  return timeout < _minimumFileUploadTimeout
      ? _minimumFileUploadTimeout
      : timeout;
}

@visibleForTesting
bool isTlsHandshakeFailureForTest(DioException error) {
  final rawError = error.error;
  if (rawError is HandshakeException || rawError is TlsException) {
    return true;
  }

  final message = (rawError?.toString() ?? error.message ?? '').toLowerCase();
  return message.contains('mtls certificate setup failed') ||
      message.contains('handshakeexception') ||
      message.contains('tlsexception') ||
      message.contains('certificate_verify_failed') ||
      message.contains('alert bad certificate');
}

/// Get MIME type from file extension.
String? _getMimeType(String fileName) {
  final ext = fileName.toLowerCase().split('.').last;
  return switch (ext) {
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'aac' => 'audio/aac',
    'ogg' => 'audio/ogg',
    'webm' => 'audio/webm',
    'mp4' => 'video/mp4',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'json' => 'application/json',
    _ => null,
  };
}

/// Result of body-sniffing during chat completion response classification.
sealed class _SniffResult {}

/// The body looks like SSE data (starts with `data:`).
final class _SniffSse extends _SniffResult {
  _SniffSse({required this.buffered, this.rest});

  /// Chunks already consumed during sniffing.
  final List<List<int>> buffered;

  /// The paused subscription for the remaining stream, if any.
  final StreamSubscription<List<int>>? rest;
}

/// The body is valid JSON.
final class _SniffJson extends _SniffResult {
  _SniffJson({required this.json});

  /// The parsed JSON map, or `null` for a literal JSON null body.
  final Map<String, dynamic>? json;
}

enum _ChatRequestMetadataFormat { modernV09, legacyPreV09 }

/// Result of a health check with proxy detection.
///
/// This enum distinguishes between different failure modes:
/// - [healthy]: Server is reachable and responding normally
/// - [unhealthy]: Server responded but not with expected status
/// - [proxyAuthRequired]: Server is behind an auth proxy (oauth2-proxy, etc.)
/// - [unreachable]: Server could not be reached at all
enum HealthCheckResult {
  /// Server is healthy and responding normally
  healthy,

  /// Server responded but not with expected status
  unhealthy,

  /// Server appears to be behind an authentication proxy
  /// (detected via redirect or HTML login page response)
  proxyAuthRequired,

  /// Server could not be reached
  unreachable,
}

/// The Open WebUI HTTP client.
///
/// The class itself is only an assembly point: the transport -- the Dio
/// instance, the auth interceptor, and the private helpers that every
/// endpoint shares -- lives in [_ApiServiceBase], and each API family lives
/// in a mixin beside it. Mixin members are ordinary virtual members, so a
/// test double can still subclass this and override any endpoint.
class ApiService extends _ApiServiceBase
    with
        _AuthApi,
        _HealthApi,
        _ChatsApi,
        _ChatsRawApi,
        _ChatListsApi,
        _ChatCompletionsApi,
        _FoldersTagsApi,
        _FilesApi,
        _KnowledgeBasesApi,
        _WorkspaceKnowledgeApi,
        _ModelsApi,
        _PromptsSkillsApi,
        _ToolsFunctionsApi,
        _ChannelsApi,
        _NotesApi,
        _UserSettingsApi,
        _MediaRetrievalApi,
        _EvaluationsApi {
  ApiService({
    required super.serverConfig,
    required super.workerManager,
    super.authToken,
    super.suppressCookieCustomHeader,
    super.shouldSuppressCookieCustomHeader,
    super.publicHealthAddressResolver,
    super.publicHealthSocketConnector,
    super.publicHealthSocketUpgrader,
    super.publicHealthPinnedConnectTimeout,
    super.publicHealthRequestTimeout,
  });
}

List<Map<String, dynamic>> _normalizeMapListWorker(
  Map<String, dynamic> payload,
) {
  final raw = payload['list'];
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  final normalized = <Map<String, dynamic>>[];
  for (final entry in raw) {
    if (entry is Map) {
      normalized.add(Map<String, dynamic>.from(entry));
    }
  }
  return normalized;
}

/// Top-level worker entrypoint (CDT-RFC-001 Phase 1): decodes a raw
/// `ChatResponse` byte payload into its JSON map form WITHOUT any
/// `Conversation` parsing, so the sync engine keeps the blob and the
/// epoch-second ints intact. Returns null when the body is JSON `null`
/// (the route's `response_model` allows `None`).
Map<String, dynamic>? decodeChatResponseEnvelopeWorker(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return null;
}

/// Helper to extract raw message list from various LobeHub message response formats.
List<dynamic> _extractLobeMessagesList(dynamic data) {
  if (data is Map) {
    final inner = data['data'];
    if (inner is Map && inner['messages'] is List) {
      return inner['messages'] as List;
    } else if (data['messages'] is List) {
      return data['messages'] as List;
    } else if (inner is List) {
      return inner;
    }
  } else if (data is List) {
    return data;
  }
  return const [];
}

/// Helper to extract raw topics list from various LobeHub topic response formats.
List<dynamic> _extractLobeTopicsList(dynamic data) {
  if (data is Map) {
    final innerData = data['data'];
    if (innerData is Map && innerData['topics'] is List) {
      return innerData['topics'] as List;
    } else if (data['topics'] is List) {
      return data['topics'] as List;
    } else if (innerData is List) {
      return innerData;
    }
  } else if (data is List) {
    return data;
  }
  return const [];
}

int? _parseEpochSeconds(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsedInt = int.tryParse(value);
    if (parsedInt != null) return parsedInt;
    final dt = DateTime.tryParse(value);
    if (dt != null) return dt.millisecondsSinceEpoch ~/ 1000;
  }
  return null;
}

Future<List<Map<String, dynamic>>> fetchLobeHubTopicListPageRaw(
  Dio dio, {
  required int page,
}) async {
  final response = await dio.get(
    '/api/v1/topics',
    queryParameters: {
      'page': page,
      'pageSize': 60,
    },
  );
  final topicsList = _extractLobeTopicsList(response.data);
  if (topicsList.isEmpty) {
    return const <Map<String, dynamic>>[];
  }

  final result = <Map<String, dynamic>>[];
  for (final topic in topicsList) {
    if (topic is! Map) continue;
    final id = topic['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    final title = (topic['title'] as String?)?.trim();
    final effectiveTitle =
        (title != null && title.isNotEmpty) ? title : 'New Chat';
    final updatedAt = _parseEpochSeconds(
          topic['updatedAt'] ?? topic['updated_at'],
        ) ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final createdAt = _parseEpochSeconds(
          topic['createdAt'] ?? topic['created_at'],
        ) ??
        updatedAt;
    final pinned = topic['favorite'] == true || topic['starred'] == true;
    final folderId = topic['groupId']?.toString();

    result.add({
      'id': id,
      'title': effectiveTitle,
      'updated_at': updatedAt,
      'created_at': createdAt,
      'last_read_at': updatedAt,
      'pinned': pinned,
      'folder_id': ?folderId,
    });
  }
  return result;
}

/// Fetches all pages of messages for [topicId] from LobeHub `/api/v1/messages`.
Future<List<Map<String, dynamic>>> fetchAllLobeHubMessages(
  Dio dio, {
  required String topicId,
}) async {
  const pageSize = 100;
  var page = 1;
  final allMessages = <Map<String, dynamic>>[];
  while (true) {
    final resp = await dio.get(
      '/api/v1/messages',
      queryParameters: {
        'topicId': topicId,
        'page': page,
        'pageSize': pageSize,
      },
    );
    final rawList = _extractLobeMessagesList(resp.data);
    if (rawList.isEmpty) break;
    var countOnThisPage = 0;
    for (final item in rawList) {
      if (item is Map) {
        allMessages.add(Map<String, dynamic>.from(item));
        countOnThisPage++;
      }
    }
    if (countOnThisPage < pageSize) {
      break;
    }
    page++;
    if (page > 100) break;
  }
  return allMessages;
}

Future<Map<String, dynamic>?> fetchLobeHubChatRaw(Dio dio, String id) async {
  try {
    final messagesList = await fetchAllLobeHubMessages(dio, topicId: id);

    String title = 'New Chat';
    int createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int updatedAt = createdAt;
    bool pinned = false;
    String? folderId;
    String? model;
    String? agentId;

    Map<String, dynamic>? topicObj;
    if (messagesList.isNotEmpty) {
      final firstMsg = messagesList.first;
      if (firstMsg['topic'] is Map) {
        topicObj = Map<String, dynamic>.from(firstMsg['topic'] as Map);
      }
    }

    if (topicObj == null) {
      try {
        final topicResp = await dio.get('/api/v1/topics/$id');
        final tData = topicResp.data;
        if (tData is Map && tData['data'] is Map) {
          topicObj = Map<String, dynamic>.from(tData['data'] as Map);
        } else if (tData is Map) {
          topicObj = Map<String, dynamic>.from(tData);
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          rethrow;
        }
      }
    }

    if (topicObj != null) {
      final tTitle = (topicObj['title'] as String?)?.trim();
      if (tTitle != null && tTitle.isNotEmpty) {
        title = tTitle;
      }
      createdAt = _parseEpochSeconds(topicObj['createdAt'] ?? topicObj['created_at']) ?? createdAt;
      updatedAt = _parseEpochSeconds(topicObj['updatedAt'] ?? topicObj['updated_at']) ?? updatedAt;
      pinned = topicObj['favorite'] == true || topicObj['starred'] == true;
      folderId = topicObj['groupId']?.toString();
      model = topicObj['model']?.toString();
      agentId = topicObj['agentId']?.toString();
    }

    final messagesMap = <String, Map<String, dynamic>>{};
    String? currentId;

    for (final m in messagesList) {
      final mId = m['id']?.toString() ?? '';
      if (mId.isEmpty) continue;
      final role = m['role']?.toString() ?? 'user';
      final content = m['content']?.toString() ?? '';
      final mCreatedAt = _parseEpochSeconds(m['createdAt'] ?? m['created_at']) ?? createdAt;
      final mUpdatedAt = _parseEpochSeconds(m['updatedAt'] ?? m['updated_at']) ?? updatedAt;
      final mModel = m['model']?.toString() ?? model;
      final reasoning = m['reasoning']?.toString();

      final meta = m['metadata'] is Map
          ? Map<String, dynamic>.from(m['metadata'] as Map)
          : (m['meta'] is Map
              ? Map<String, dynamic>.from(m['meta'] as Map)
              : <String, dynamic>{});
      final conduitClientId = meta['conduitClientId']?.toString();
      final effectiveId = (conduitClientId != null && conduitClientId.isNotEmpty)
          ? conduitClientId
          : mId;
      meta['serverMessageId'] = mId;
      currentId = effectiveId;

      messagesMap[effectiveId] = {
        'id': effectiveId,
        'role': role,
        'content': content,
        'timestamp': mCreatedAt,
        'created_at': mCreatedAt,
        'updated_at': mUpdatedAt,
        if (m['parentId'] != null || m['parent_id'] != null)
          'parentId': (m['parentId'] ?? m['parent_id']).toString(),
        'childrenIds': ?m['childrenIds'],
        'model': ?mModel,
        if (reasoning != null && reasoning.isNotEmpty) 'reasoning': reasoning,
        'meta': meta,
        'chatId': id,
      };
    }

    return {
      'id': id,
      'title': title,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'pinned': pinned,
      'archived': false,
      'folder_id': ?folderId,
      'meta': {
        'agentId': ?agentId,
        'model': ?model,
      },
      'chat': {
        'title': title,
        if (model != null) 'models': [model],
        'history': {
          'currentId': ?currentId,
          'messages': messagesMap,
        },
      },
    };
  } on DioException catch (e) {
    if (e.response?.statusCode == 404) return null;
    rethrow;
  }
}

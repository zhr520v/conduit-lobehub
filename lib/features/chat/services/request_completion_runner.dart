import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/chat_message.dart';

import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit_core/services/conversation_parsing.dart';

import 'package:conduit_core/services/worker_manager.dart';

import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/sync_api_client.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import '../providers/chat_providers.dart';

part 'request_completion_runner.g.dart';

/// Transient error thrown when a queued completion cannot run RIGHT NOW because
/// a live interactive stream already owns the chat (R5). The drainer's default
/// terminal classifier treats it as transient, so the op stays pending and is
/// re-attempted on a later drain (after the live stream finishes) instead of
/// burning toward the N=5 park budget unfairly.
class CompletionBusyException implements OutboxDeferralException {
  const CompletionBusyException(this.chatId);

  final String chatId;

  @override
  String toString() => 'CompletionBusyException(chat: $chatId)';
}

/// Transient session-switch race: the selected server/database is briefly
/// absent, so the outbox op should retry without burning parking budget.
class CompletionDatabaseUnavailableException
    implements OutboxDeferralException {
  const CompletionDatabaseUnavailableException();

  @override
  String toString() => 'CompletionDatabaseUnavailableException()';
}

/// Concrete [RequestCompletionRunner] (Wiring D). Re-enters the EXISTING
/// streaming pipeline ([runQueuedCompletion]) for a drained `requestCompletion`
/// op — it never forks a second streaming implementation, and it is no-op-safe
/// on re-entry (idempotent if the turn already completed).
///
/// The runner drives the LIVE streaming pipeline only when the target chat is
/// already the user's active conversation (and its placeholder is loaded);
/// otherwise it runs HEADLESS without switching the active conversation. Either
/// way the D-07 echo (`upsertLocalEcho` keyed on the PK
/// `{chatId, assistantMessageId}`) updates the SAME placeholder row the
/// `*WithOutbox` DAO wrote at enqueue, guaranteeing one row per turn (R8).
class ChatRequestCompletionRunner implements RequestCompletionRunner {
  ChatRequestCompletionRunner(
    this._ref, {
    int recoveryAttempts = 6,
    Duration recoveryDelay = const Duration(seconds: 2),
  }) : _recoveryAttempts = recoveryAttempts,
       _recoveryDelay = recoveryDelay;

  final Ref _ref;
  final int _recoveryAttempts;
  final Duration _recoveryDelay;

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) {
    final releaseGeneration = holdLocalChatGeneration(_ref);
    return _run(
      chatId: chatId,
      payload: payload,
    ).whenComplete(releaseGeneration);
  }

  Future<void> _run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    final decoded = RequestCompletionPayload.fromJson(payload);
    final assistantMessageId = decoded.assistantMessageId;

    // Capture database, API, auth epoch, and database certification as one
    // synchronous ownership tuple. Reading only the database first leaves an
    // ABA window where the same object can be reused by a different account
    // before the completion owner is captured.
    final conversationOwnership = captureOpenWebUiConversationRead(_ref);
    final db = conversationOwnership?.database;
    if (db == null) {
      DebugLogger.log(
        'completion-deferred-no-db',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
      );
      throw const CompletionDatabaseUnavailableException();
    }
    final ownedConversationSession = conversationOwnership!;

    final owner = OpenWebUiCompletionOwner(
      chatId: chatId,
      database: db,
      api: ownedConversationSession.api,
      authSessionEpoch: ownedConversationSession.authSessionEpoch,
      contextWasCoherent: true,
    );

    void requireCurrentConversationOwner() {
      if (!openWebUiConversationReadIsCurrent(_ref, ownedConversationSession) ||
          !openWebUiCompletionContextIsCurrent(_ref, owner)) {
        throw const CompletionDatabaseUnavailableException();
      }
    }

    requireCurrentConversationOwner();

    // Streaming-conflict guard (R5): if a LIVE interactive stream owns this
    // exact chat, unsent work defers so it can never clobber that stream.
    void deferIfTargetIsBusy() {
      requireCurrentConversationOwner();
      if (activeOpenWebUiChatIdForMutation(_ref, owner) == null ||
          !_ref.read(isChatStreamingProvider)) {
        return;
      }
      final activeMessages = _ref.read(chatMessagesProvider);
      final activeLastMessage = activeMessages.isNotEmpty
          ? activeMessages.last
          : null;
      final activeStreamingAssistantId =
          activeLastMessage?.role == 'assistant' &&
              activeLastMessage?.isStreaming == true
          ? activeLastMessage?.id
          : null;
      if (activeStreamingAssistantId != assistantMessageId) {
        DebugLogger.log(
          'completion-deferred-busy',
          scope: 'chat/completion',
          data: {
            'chatId': chatId,
            'assistantMessageId': assistantMessageId,
            'activeStreamingAssistantId': activeStreamingAssistantId,
          },
        );
        throw CompletionBusyException(chatId);
      }
    }

    // 2. Idempotency / already-completed guard (R3): a completed turn leaves a
    //    durable marker on the placeholder row. Non-empty content alone is not
    //    enough: pause checkpoints also persist partial assistant text while
    //    the requestCompletion op is still pending/inFlight.
    final placeholder = await db.messagesDao.getMessage(
      chatId,
      assistantMessageId,
    );
    requireCurrentConversationOwner();
    if (placeholder == null) {
      DebugLogger.log(
        'completion-placeholder-absent',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
      );
      return;
    }
    if (_placeholderMarkedComplete(placeholder)) {
      DebugLogger.log(
        'completion-already-done',
        scope: 'chat/completion',
        data: {'chatId': chatId, 'assistantMessageId': assistantMessageId},
      );
      return;
    }
    final completionWasSubmitted = _placeholderMarkedSubmitted(placeholder);
    // Once the POST crossed the server boundary this op is pull-only recovery;
    // another live stream must not prevent collecting the accepted response.
    if (!completionWasSubmitted) {
      deferIfTargetIsBusy();
      final placeholderPayload = _decodeMessagePayload(placeholder.payload);
      final placeholderMeta = _asJsonMap(placeholderPayload['metadata']);
      if (placeholderMeta['terminal'] == true ||
          (placeholderPayload['error'] != null &&
              placeholderMeta['completionSubmitted'] != true)) {
        await db.messagesDao.rearmAssistantCompletion(
          chatId: chatId,
          messageId: assistantMessageId,
        );
        requireCurrentConversationOwner();
        if (activeOpenWebUiChatIdForMutation(_ref, owner) != null) {
          _ref.read(chatMessagesProvider.notifier).updateMessageById(
            assistantMessageId,
            (message) => message.copyWith(
              isStreaming: true,
              error: null,
            ),
          );
        }
      }
    }

    // 3. Path choice (Option B):
    //    - The target chat IS the one the user is viewing → drive the LIVE
    //      streaming pipeline so they watch their reply stream in (Option A).
    //    - Otherwise (a different chat is foregrounded, or none is) → run
    //      HEADLESS: fire the completion, let the server persist it, pull it
    //      into the local DB — WITHOUT switching the user's active conversation.
    final chatRow = await db.chatsDao.getChat(chatId);
    requireCurrentConversationOwner();
    if (chatRow == null) {
      // Chat row vanished (e.g. a delete won the race): nothing to complete.
      DebugLogger.log(
        'completion-chat-absent',
        scope: 'chat/completion',
        data: {'chatId': chatId},
      );
      return;
    }

    if (completionWasSubmitted) {
      // The POST already crossed the server boundary before a prior run lost
      // foreground ownership or its byte stream failed. Recover by pull only;
      // replaying the request here would duplicate the assistant generation.
      owner.chatId = await resolveOpenWebUiCompletionChatId(
        _ref,
        owner: owner,
        assistantMessageId: assistantMessageId,
      );
      requireCurrentConversationOwner();
      await recoverSubmittedOpenWebUiCompletion(
        _ref,
        owner: owner,
        assistantMessageId: assistantMessageId,
        recoveryAttempts: _recoveryAttempts,
        recoveryDelay: _recoveryDelay,
      );
      requireCurrentConversationOwner();
      return;
    }

    // Both database reads above are async. Re-read the global owner and stream
    // state now; the user may have navigated while either query was queued.
    deferIfTargetIsBusy();
    final targetIsActive =
        activeOpenWebUiChatIdForMutation(_ref, owner) != null;

    try {
      if (targetIsActive &&
          _ref
              .read(chatMessagesProvider)
              .any((message) => message.id == assistantMessageId)) {
        // Live drive — the placeholder is loaded + marked streaming inside
        // runQueuedCompletion; the stream final + D-07 echo land on the SAME
        // assistantMessageId row (R8 one-row-per-turn).
        await runQueuedCompletion(
          _ref,
          chatId: chatId,
          assistantMessageId: assistantMessageId,
          model: decoded.model,
          toolIds: decoded.toolIds,
          filterIds: decoded.filterIds,
          terminalId: decoded.terminalId,
          enableWebSearch: decoded.enableWebSearch,
          enableImageGeneration: decoded.enableImageGeneration,
          isVoiceMode: decoded.isVoiceMode,
          sessionIdOverride: decoded.sessionIdOverride,
          completionOwner: owner,
        );
        return;
      }

      // Headless drive — no active-conversation switch, no chatMessagesProvider
      // mutation. Builds the request from this chat's DB rows.
      final rows = await db.messagesDao.getForChat(chatId);
      requireCurrentConversationOwner();
      final conversation = await assembleConversationGuarded(
        chatRow,
        rows,
        offload: (envelope) => _ref
            .read(workerManagerProvider)
            .schedule(
              parseFullConversationModelWorker,
              envelope,
              debugLabel: 'headless.assembleConversation',
            ),
      );
      requireCurrentConversationOwner();
      await runHeadlessCompletion(
        _ref,
        chatId: chatId,
        assistantMessageId: assistantMessageId,
        messages: conversation.messages,
        conversation: conversation,
        model: decoded.model,
        toolIds: decoded.toolIds,
        filterIds: decoded.filterIds,
        terminalId: decoded.terminalId,
        enableWebSearch: decoded.enableWebSearch,
        enableImageGeneration: decoded.enableImageGeneration,
        isVoiceMode: decoded.isVoiceMode,
        sessionIdOverride: decoded.sessionIdOverride,
        completionOwner: owner,
      );
    } catch (error) {
      if (_isTerminalCompletionError(error)) {
        await _settleTerminalPreSubmissionFailure(
          chatId: chatId,
          assistantMessageId: assistantMessageId,
          error: error,
          owner: owner,
          session: ownedConversationSession,
        );
        throw _asTerminalCompletionException(error);
      }
      rethrow;
    }
  }

  Future<void> _settleTerminalPreSubmissionFailure({
    required String chatId,
    required String assistantMessageId,
    required Object error,
    required OpenWebUiCompletionOwner owner,
    required OpenWebUiConversationReadSnapshot session,
  }) async {
    if (!openWebUiConversationReadIsCurrent(_ref, session) ||
        !openWebUiCompletionContextIsCurrent(_ref, owner)) {
      throw const CompletionDatabaseUnavailableException();
    }
    final db = owner.database;
    if (db == null) return;

    final current = await db.messagesDao.getMessage(chatId, assistantMessageId);
    if (current != null && _placeholderMarkedSubmitted(current)) {
      return;
    }

    final errorMessage = _cleanErrorMessage(error);

    await db.messagesDao.markAssistantCompletionPreSubmissionFailed(
      chatId: chatId,
      messageId: assistantMessageId,
      error: errorMessage,
    );

    if (activeOpenWebUiChatIdForMutation(_ref, owner) != null) {
      _ref.read(chatMessagesProvider.notifier).updateMessageById(
        assistantMessageId,
        (message) => message.copyWith(
          isStreaming: false,
          error: ChatMessageError(content: errorMessage),
        ),
      );
    }
  }
}

bool _placeholderMarkedComplete(MessageRow placeholder) {
  final payload = _decodeMessagePayload(placeholder.payload);
  final metadata = _asJsonMap(payload['metadata']);
  if (metadata['terminal'] == true ||
      (payload['error'] != null && metadata['completionSubmitted'] != true)) {
    return false;
  }
  return metadata['responseDone'] == true ||
      payload['done'] == true ||
      payload['isStreaming'] == false;
}

bool _isTerminalCompletionError(Object error) {
  if (error is SyncTerminalException) {
    final status = error.statusCode;
    return status == null || status == 400 || status == 401 || status == 403;
  }
  if (error is DioException) {
    final status = error.response?.statusCode;
    return status == 400 || status == 401 || status == 403;
  }
  return false;
}

SyncTerminalException _asTerminalCompletionException(Object error) {
  if (error is SyncTerminalException) {
    return error;
  }
  if (error is DioException) {
    final status = error.response?.statusCode ?? 400;
    return SyncTerminalException(
      statusCode: status,
      message: _cleanErrorMessage(error, defaultStatus: status),
    );
  }
  return SyncTerminalException(
    statusCode: 400,
    message: _cleanErrorMessage(error, defaultStatus: 400),
  );
}

String _cleanErrorMessage(Object error, {int? defaultStatus}) {
  if (error is SyncTerminalException) {
    final msg = error.message.trim();
    if (msg.isNotEmpty && !_looksLikeStackTraceOrCredential(msg)) {
      return msg;
    }
    return _fallbackMessageForStatus(error.statusCode ?? defaultStatus);
  }
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map) {
      final msg = _extractStringFromMap(data);
      if (msg != null &&
          msg.isNotEmpty &&
          !_looksLikeStackTraceOrCredential(msg)) {
        return msg;
      }
    } else if (data is String &&
        data.isNotEmpty &&
        !_looksLikeStackTraceOrCredential(data)) {
      return data.trim();
    }
    return _fallbackMessageForStatus(
      error.response?.statusCode ?? defaultStatus,
    );
  }
  return _fallbackMessageForStatus(defaultStatus);
}

bool _looksLikeStackTraceOrCredential(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('bearer ') ||
      lower.contains('sk-') ||
      lower.contains('token=') ||
      lower.contains('password') ||
      lower.contains('#0 ') ||
      lower.contains('stack trace:')) {
    return true;
  }
  return false;
}

String _fallbackMessageForStatus(int? status) {
  switch (status) {
    case 400:
      return 'The request was rejected by the model service (unsupported content or format).';
    case 401:
      return 'Authentication failed. Please verify your credentials.';
    case 403:
      return 'Access forbidden. You do not have permission to access this model.';
    default:
      return 'The request could not be completed.';
  }
}

String? _extractStringFromMap(Map data) {
  final detail = data['detail'];
  if (detail is String) return detail.trim();
  final error = data['error'];
  if (error is Map) {
    final msg = error['message'] ?? error['content'];
    if (msg is String) return msg.trim();
  } else if (error is String) {
    return error.trim();
  }
  final message = data['message'];
  if (message is String) return message.trim();
  return null;
}

bool _placeholderMarkedSubmitted(MessageRow placeholder) {
  final payload = _decodeMessagePayload(placeholder.payload);
  final metadata = _asJsonMap(payload['metadata']);
  return metadata['completionSubmitted'] == true;
}

Map<String, dynamic> _decodeMessagePayload(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {
    // Malformed legacy rows are treated as not-complete so the op re-runs
    // rather than being marked done against an ambiguous partial reply.
  }
  return const <String, dynamic>{};
}

Map<String, dynamic> _asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, dynamic>{};
}

/// Concrete runner provider; overrides the core/sync seam at startup.
/// `keepAlive` so its `ref` survives for the engine's lifetime.
@Riverpod(keepAlive: true)
RequestCompletionRunner chatRequestCompletionRunner(Ref ref) =>
    ChatRequestCompletionRunner(ref);

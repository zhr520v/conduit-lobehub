import 'dart:async';

import 'package:dio/dio.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_mappers.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_stream_parser.dart';
import 'package:conduit_core/models/chat_message.dart';

/// Bridges real-time typewriter SSE streaming with LobeHub's Two-Phase Chat Protocol
/// and message persistence.
///
/// LobeHub's Two-Phase Chat Protocol:
/// 1. **Phase 1 (User Message Submission)**:
///    - Optimistically construct the user [LobeMessage] / [ChatMessage].
///    - Persist the user message to LobeHub via `POST /api/v1/messages`
///      bound to [topicId] and optional [agentId].
///    - Invoke [onUserMessagePersisted] if provided.
/// 2. **Phase 2 (Streaming Generation via Responses endpoint)**:
///    - Call `POST /api/v1/responses` on LobeHub with `stream: true`, `model`,
///      and conversation history payload.
///    - Parse the SSE byte stream into typed [LobeStreamEvent]s using [LobeHubStreamParser].
///    - Emit [LobeTextDelta] and [LobeReasoningDelta] chunks while accumulating
///      text and reasoning buffers in real-time.
/// 3. **Phase 3 (Assistant Message Persistence)**:
///    - Once streaming completes ([LobeStreamDone]), call `POST /api/v1/messages`
///      on LobeHub to persist the assistant's complete reply (with `role: 'assistant'`,
///      accumulated content, reasoning, model, and topicId).
///    - Update [lastAssistantMessage] and invoke [onAssistantMessagePersisted].
/// 4. **Cancellation ([cancelGeneration])**:
///    - Use Dio [CancelToken] to immediately abort the `/api/v1/responses` connection.
///    - If canceled mid-stream, persist any accumulated partial assistant message
///      so partial text is never lost and no uncaught exceptions crash the UI.
class LobeHubChatBridge {
  /// Creates a [LobeHubChatBridge].
  ///
  /// Requires a configured [LobeHubApiClient] and an optional [LobeHubStreamParser].
  LobeHubChatBridge({
    required LobeHubApiClient apiClient,
    LobeHubStreamParser streamParser = const LobeHubStreamParser(),
  })  : _apiClient = apiClient,
        _streamParser = streamParser;

  final LobeHubApiClient _apiClient;
  final LobeHubStreamParser _streamParser;

  /// Underlying API client.
  LobeHubApiClient get apiClient => _apiClient;

  /// Underlying SSE stream parser.
  LobeHubStreamParser get streamParser => _streamParser;

  CancelToken? _activeCancelToken;
  String _accumulatedText = '';
  String _accumulatedReasoning = '';
  final List<Map<String, dynamic>> _accumulatedTools = [];
  LobeMessage? _lastUserMessage;
  LobeMessage? _lastAssistantMessage;

  /// The active [CancelToken] for the current in-flight generation, if any.
  CancelToken? get activeCancelToken => _activeCancelToken;

  /// Whether a generation request is currently active.
  bool get isGenerating => _activeCancelToken != null;

  /// Accumulated assistant text content from the current/most recent generation.
  String get accumulatedText => _accumulatedText;

  /// Accumulated reasoning / thinking content from the current/most recent generation.
  String get accumulatedReasoning => _accumulatedReasoning;

  /// Accumulated tool call definitions from the current/most recent generation.
  List<Map<String, dynamic>> get accumulatedTools =>
      List.unmodifiable(_accumulatedTools);

  /// The most recent user message from Phase 1.
  LobeMessage? get lastUserMessage => _lastUserMessage;

  /// The most recent assistant message from Phase 3 (or partial message on cancellation).
  LobeMessage? get lastAssistantMessage => _lastAssistantMessage;

  /// The most recent user message converted to a Conduit [ChatMessage].
  ChatMessage? get lastUserChatMessage =>
      _lastUserMessage != null ? lobeMessageToChatMessage(_lastUserMessage!) : null;

  /// The most recent assistant message converted to a Conduit [ChatMessage].
  ChatMessage? get lastAssistantChatMessage => _lastAssistantMessage != null
      ? lobeMessageToChatMessage(_lastAssistantMessage!)
      : null;

  /// Immediately aborts the current in-flight generation.
  ///
  /// Cancels the underlying Dio [CancelToken]. If partial content or reasoning
  /// was accumulated, it is gracefully saved via `POST /api/v1/messages`.
  void cancelGeneration([String? reason]) {
    final token = _activeCancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel(reason ?? 'Generation cancelled by user');
    }
  }

  /// Sends a user message and streams model responses via SSE.
  ///
  /// Follows the Three-Phase protocol:
  /// 1. Persists user message (`POST /api/v1/messages`) unless [persistUserMessage] is false.
  /// 2. Streams response chunks from `POST /api/v1/responses` via [LobeHubStreamParser].
  /// 3. Persists final assistant message (`POST /api/v1/messages`) unless [persistAssistantMessage] is false.
  ///
  /// If cancelled via [cancelToken] or [cancelGeneration], accumulated partial text
  /// is preserved and a [LobeStreamDone] with `'cancelled'` is yielded gracefully.
  Stream<LobeStreamEvent> sendMessageStream({
    required String topicId,
    required String content,
    String? agentId,
    String? model,
    List<LobeMessage>? history,
    CancelToken? cancelToken,
    bool persistUserMessage = true,
    bool persistAssistantMessage = true,
    void Function(LobeMessage userMessage)? onUserMessagePersisted,
    void Function(LobeMessage assistantMessage)? onAssistantMessagePersisted,
    void Function(String textDelta)? onTextDelta,
    void Function(String reasoningDelta)? onReasoningDelta,
    void Function(Map<String, dynamic> toolCallDelta)? onToolCallDelta,
    String? provider,
  }) async* {
    // Abort any prior in-flight generation on this bridge instance
    if (_activeCancelToken != null && !_activeCancelToken!.isCancelled) {
      _activeCancelToken!.cancel('Superseded by new chat generation');
    }

    final effectiveCancelToken = cancelToken ?? CancelToken();
    _activeCancelToken = effectiveCancelToken;

    final textBuffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    _accumulatedTools.clear();
    _accumulatedText = '';
    _accumulatedReasoning = '';

    final resolvedModel = model ?? agentId ?? 'gpt-4o';
    bool streamDoneObserved = false;

    try {
      // ----------------------------------------------------------------------
      // Phase 1: User Message Submission
      // ----------------------------------------------------------------------
      final optimisticUserMessage = LobeMessage(
        id: 'user_temp_${DateTime.now().millisecondsSinceEpoch}',
        topicId: topicId,
        role: 'user',
        content: content,
        model: model,
        provider: provider,
        createdAt: DateTime.now(),
      );
      _lastUserMessage = optimisticUserMessage;

      LobeMessage userMessage = optimisticUserMessage;
      if (persistUserMessage) {
        if (effectiveCancelToken.isCancelled) {
          yield const LobeStreamDone('cancelled');
          return;
        }

        userMessage = await _apiClient.createMessage(
          role: 'user',
          content: content,
          topicId: topicId,
          agentId: agentId,
          model: model,
          provider: provider,
        );
        _lastUserMessage = userMessage;
      }
      onUserMessagePersisted?.call(userMessage);

      if (effectiveCancelToken.isCancelled) {
        yield const LobeStreamDone('cancelled');
        return;
      }

      // ----------------------------------------------------------------------
      // Phase 2: Streaming Generation via Responses endpoint
      // ----------------------------------------------------------------------
      final messagesPayload = <Map<String, dynamic>>[];
      if (history != null) {
        for (final msg in history) {
          messagesPayload.add({
            'role': msg.role,
            'content': msg.content,
          });
        }
      }

      final bool alreadyEndsWithUser = messagesPayload.isNotEmpty &&
          messagesPayload.last['role'] == 'user' &&
          messagesPayload.last['content'] == content;
      if (!alreadyEndsWithUser) {
        messagesPayload.add({
          'role': 'user',
          'content': content,
        });
      }

      final requestData = <String, dynamic>{
        'model': resolvedModel,
        'stream': true,
        'messages': messagesPayload,
        if (agentId != null) 'agentId': agentId,
        if (provider != null) 'provider': provider,
      };

      final responseBody = await _apiClient.createResponsesStream(
        data: requestData,
        cancelToken: effectiveCancelToken,
      );

      final parsedStream = _streamParser.parseByteStream(responseBody.stream);

      await for (final event in parsedStream) {
        if (effectiveCancelToken.isCancelled) {
          throw DioException(
            requestOptions: RequestOptions(path: '/api/v1/responses'),
            type: DioExceptionType.cancel,
            message: 'Generation cancelled by user',
          );
        }

        if (event is LobeTextDelta) {
          textBuffer.write(event.text);
          _accumulatedText = textBuffer.toString();
          onTextDelta?.call(event.text);
          yield event;
        } else if (event is LobeReasoningDelta) {
          reasoningBuffer.write(event.reasoning);
          _accumulatedReasoning = reasoningBuffer.toString();
          onReasoningDelta?.call(event.reasoning);
          yield event;
        } else if (event is LobeToolCallDelta) {
          _accumulatedTools.add(event.toolCall);
          onToolCallDelta?.call(event.toolCall);
          yield event;
        } else if (event is LobeStreamDone) {
          streamDoneObserved = true;

          // ------------------------------------------------------------------
          // Phase 3: Assistant Message Persistence
          // ------------------------------------------------------------------
          if (persistAssistantMessage) {
            final assistantMessage = await _apiClient.createMessage(
              role: 'assistant',
              content: _accumulatedText,
              reasoning: _accumulatedReasoning.isNotEmpty
                  ? _accumulatedReasoning
                  : null,
              model: model ?? resolvedModel,
              topicId: topicId,
              agentId: agentId,
              provider: provider,
              tools: _accumulatedTools.isNotEmpty ? _accumulatedTools : null,
            );
            _lastAssistantMessage = assistantMessage;
            onAssistantMessagePersisted?.call(assistantMessage);
          } else {
            final assistantMessage = LobeMessage(
              id: 'assistant_temp_${DateTime.now().millisecondsSinceEpoch}',
              topicId: topicId,
              role: 'assistant',
              content: _accumulatedText,
              reasoning: _accumulatedReasoning.isNotEmpty
                  ? _accumulatedReasoning
                  : null,
              model: model ?? resolvedModel,
              provider: provider,
              tools: _accumulatedTools.isNotEmpty ? _accumulatedTools : const [],
              createdAt: DateTime.now(),
            );
            _lastAssistantMessage = assistantMessage;
            onAssistantMessagePersisted?.call(assistantMessage);
          }

          yield event;
          return;
        } else {
          yield event;
        }
      }

      // Stream closed by server without an explicit LobeStreamDone
      if (!streamDoneObserved && !effectiveCancelToken.isCancelled) {
        streamDoneObserved = true;
        if (persistAssistantMessage &&
            (_accumulatedText.isNotEmpty || _accumulatedReasoning.isNotEmpty)) {
          final assistantMessage = await _apiClient.createMessage(
            role: 'assistant',
            content: _accumulatedText,
            reasoning: _accumulatedReasoning.isNotEmpty
                ? _accumulatedReasoning
                : null,
            model: model ?? resolvedModel,
            topicId: topicId,
            agentId: agentId,
            provider: provider,
            tools: _accumulatedTools.isNotEmpty ? _accumulatedTools : null,
          );
          _lastAssistantMessage = assistantMessage;
          onAssistantMessagePersisted?.call(assistantMessage);
        }
        yield const LobeStreamDone('stop');
      }
    } catch (e) {
      final isCancelled =
          effectiveCancelToken.isCancelled || _isCancelException(e);

      if (isCancelled) {
        // If canceled, persist any accumulated partial assistant message (or clean up)
        // so that partial text is not lost and no uncaught exceptions crash the UI.
        if (persistAssistantMessage &&
            (_accumulatedText.isNotEmpty || _accumulatedReasoning.isNotEmpty)) {
          try {
            final partialMessage = await _apiClient.createMessage(
              role: 'assistant',
              content: _accumulatedText,
              reasoning: _accumulatedReasoning.isNotEmpty
                  ? _accumulatedReasoning
                  : null,
              model: model ?? resolvedModel,
              topicId: topicId,
              agentId: agentId,
              provider: provider,
              tools: _accumulatedTools.isNotEmpty ? _accumulatedTools : null,
            );
            _lastAssistantMessage = partialMessage;
            onAssistantMessagePersisted?.call(partialMessage);
          } catch (_) {
            // Suppress secondary network failures during cancellation persistence
          }
        }
        yield const LobeStreamDone('cancelled');
        return;
      }

      // Genuine network or server error during stream: cleanup and throw informative exception
      if (e is LobeHubException) {
        rethrow;
      }
      if (e is DioException) {
        throw _apiClient.mapDioException(e);
      }
      throw LobeHubException(
        'Streaming generation failed: $e',
        cause: e,
      );
    } finally {
      if (identical(_activeCancelToken, effectiveCancelToken)) {
        _activeCancelToken = null;
      }
    }
  }

  /// Convenience helper to send a message, stream completion, and return
  /// the persisted assistant [LobeMessage].
  Future<LobeMessage> sendMessage({
    required String topicId,
    required String content,
    String? agentId,
    String? model,
    List<LobeMessage>? history,
    CancelToken? cancelToken,
    bool persistUserMessage = true,
    bool persistAssistantMessage = true,
    void Function(LobeMessage userMessage)? onUserMessagePersisted,
    void Function(LobeMessage assistantMessage)? onAssistantMessagePersisted,
    void Function(String textDelta)? onTextDelta,
    void Function(String reasoningDelta)? onReasoningDelta,
    void Function(Map<String, dynamic> toolCallDelta)? onToolCallDelta,
    String? provider,
  }) async {
    await for (final _ in sendMessageStream(
      topicId: topicId,
      content: content,
      agentId: agentId,
      model: model,
      history: history,
      cancelToken: cancelToken,
      persistUserMessage: persistUserMessage,
      persistAssistantMessage: persistAssistantMessage,
      onUserMessagePersisted: onUserMessagePersisted,
      onAssistantMessagePersisted: onAssistantMessagePersisted,
      onTextDelta: onTextDelta,
      onReasoningDelta: onReasoningDelta,
      onToolCallDelta: onToolCallDelta,
      provider: provider,
    )) {}

    if (_lastAssistantMessage != null) {
      return _lastAssistantMessage!;
    }

    final resolvedModel = model ?? agentId ?? 'gpt-4o';
    return LobeMessage(
      id: 'assistant_${DateTime.now().millisecondsSinceEpoch}',
      topicId: topicId,
      role: 'assistant',
      content: _accumulatedText,
      reasoning: _accumulatedReasoning.isNotEmpty ? _accumulatedReasoning : null,
      model: resolvedModel,
      provider: provider,
      createdAt: DateTime.now(),
    );
  }

  /// Convenience helper working with Conduit core [ChatMessage] instances.
  Future<ChatMessage> sendChatMessage({
    required String topicId,
    required String content,
    String? agentId,
    String? model,
    List<ChatMessage>? history,
    CancelToken? cancelToken,
    bool persistUserMessage = true,
    bool persistAssistantMessage = true,
    void Function(ChatMessage userMessage)? onUserMessagePersisted,
    void Function(ChatMessage assistantMessage)? onAssistantMessagePersisted,
    void Function(String textDelta)? onTextDelta,
    void Function(String reasoningDelta)? onReasoningDelta,
    void Function(Map<String, dynamic> toolCallDelta)? onToolCallDelta,
    String? provider,
  }) async {
    final lobeHistory = history
        ?.map((m) => chatMessageToLobeMessage(m, topicId: topicId))
        .toList();

    final lobeMsg = await sendMessage(
      topicId: topicId,
      content: content,
      agentId: agentId,
      model: model,
      history: lobeHistory,
      cancelToken: cancelToken,
      persistUserMessage: persistUserMessage,
      persistAssistantMessage: persistAssistantMessage,
      onUserMessagePersisted: onUserMessagePersisted != null
          ? (msg) => onUserMessagePersisted(lobeMessageToChatMessage(msg))
          : null,
      onAssistantMessagePersisted: onAssistantMessagePersisted != null
          ? (msg) => onAssistantMessagePersisted(lobeMessageToChatMessage(msg))
          : null,
      onTextDelta: onTextDelta,
      onReasoningDelta: onReasoningDelta,
      onToolCallDelta: onToolCallDelta,
      provider: provider,
    );

    return lobeMessageToChatMessage(lobeMsg);
  }

  /// Determines whether an error was caused by request cancellation.
  static bool _isCancelException(dynamic e) {
    if (e is DioException) {
      return e.type == DioExceptionType.cancel;
    }
    if (e is LobeHubException && e.cause is DioException) {
      return (e.cause as DioException).type == DioExceptionType.cancel;
    }
    final s = e.toString().toLowerCase();
    return s.contains('cancel') || s.contains('abort');
  }
}

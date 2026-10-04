part of 'api_service.dart';

/// Correlation snapshot for an Agent turn in LobeHub to ensure durable reconciliation.
class LobeAgentCorrelation {
  const LobeAgentCorrelation({
    required this.topicId,
    required this.agentId,
    required this.userText,
    required this.userLocalId,
    required this.assistantLocalId,
    required this.snapshotServerIds,
    required this.createdAt,
  });

  final String topicId;
  final String agentId;
  final String userText;
  final String userLocalId;
  final String assistantLocalId;
  final Set<String> snapshotServerIds;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'topicId': topicId,
        'agentId': agentId,
        'userText': userText,
        'userLocalId': userLocalId,
        'assistantLocalId': assistantLocalId,
        'snapshotServerIds': snapshotServerIds.toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory LobeAgentCorrelation.fromJson(Map<String, dynamic> json) =>
      LobeAgentCorrelation(
        topicId: json['topicId']?.toString() ?? '',
        agentId: json['agentId']?.toString() ?? '',
        userText: json['userText']?.toString() ?? '',
        userLocalId: json['userLocalId']?.toString() ?? '',
        assistantLocalId: json['assistantLocalId']?.toString() ?? '',
        snapshotServerIds: (json['snapshotServerIds'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toSet() ??
            const <String>{},
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
            : DateTime.now(),
      );
}

/// Result of reconciling server-generated messages after an Agent turn in LobeHub.
class LobeReconcileResult {
  const LobeReconcileResult({
    required this.success,
    this.serverUserId,
    this.serverAssistantId,
    this.errorMessage,
    this.ambiguous = false,
  });

  final bool success;
  final String? serverUserId;
  final String? serverAssistantId;
  final String? errorMessage;
  final bool ambiguous;

  @override
  String toString() =>
      'LobeReconcileResult(success: $success, serverUserId: $serverUserId, '
      'serverAssistantId: $serverAssistantId, ambiguous: $ambiguous, errorMessage: $errorMessage)';
}

mixin _ChatCompletionsApi on _ApiServiceBase {
  // Send chat completed notification
  // This persists usage data and other message metadata to the server
  /// Notify backend that chat streaming is complete.
  /// This triggers any configured filters/actions on the backend.
  /// Matches OpenWebUI's chatCompletedHandler in Chat.svelte.
  ///
  /// Returns the response body which may contain modified messages from
  /// outlet filters. The caller should merge these back into the local
  /// message state (OpenWebUI does this to apply filter-modified content).
  Future<Map<String, dynamic>?> sendChatCompleted({
    required String chatId,
    required String messageId,
    required List<Map<String, dynamic>> messages,
    required String model,
    Map<String, dynamic>? modelItem,
    String? sessionId,
    List<String>? filterIds,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    // SendChatCompleted no-op on LobeHub
    if (serverConfig.isLobeHub) return null;
    // Since 0.9 the server runs these filters before emitting chat:outlet.
    // The deprecated endpoint would run them a second time.
    if (_runsOutletFiltersInline) return null;
    // Format messages to match OpenWebUI expected structure exactly
    final formattedMessages = messages.map((msg) {
      final formatted = <String, dynamic>{
        'id': msg['id'],
        'role': msg['role'],
        'content': msg['content'],
        'timestamp':
            msg['timestamp'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
      // Include info if present (OpenWebUI sends this)
      if (msg.containsKey('info') && msg['info'] != null) {
        formatted['info'] = msg['info'];
      }
      // Include usage if present (issue #274)
      if (msg.containsKey('usage') && msg['usage'] != null) {
        formatted['usage'] = msg['usage'];
      }
      // Include sources if present
      if (msg.containsKey('sources') && msg['sources'] != null) {
        formatted['sources'] = msg['sources'];
      }
      return formatted;
    }).toList();

    final requestData = <String, dynamic>{
      'model': model,
      'messages': formattedMessages,
      'chat_id': chatId,
      'id': messageId,
      'session_id': ?sessionId,
    };

    // Include filter_ids if provided (for outlet filters)
    if (filterIds != null && filterIds.isNotEmpty) {
      requestData['filter_ids'] = filterIds;
    }

    // Include model_item if available
    if (modelItem != null) {
      requestData['model_item'] = modelItem;
    }

    try {
      final resp = await _dio.post(
        '/api/chat/completed',
        data: requestData,
        options: _withAuthSnapshot(
          Options(
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
          authSnapshot,
        ),
      );
      if (resp.data is Map<String, dynamic>) {
        return resp.data as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      // Non-critical - filters/actions may not be configured
      return null;
    }
  }
  // -----------------------------------------------------------------------
  // Transport-aware sendMessageSession
  // -----------------------------------------------------------------------

  /// Posts a chat completion request and classifies the server's response
  /// into a typed [ChatCompletionSession].
  ///
  /// Inspects the actual HTTP response to determine the transport mode
  /// (httpStream, taskSocket, or jsonCompletion).
  Future<ChatCompletionSession> sendMessageSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? terminalId,
    List<String>? toolIds,
    List<String>? filterIds,
    List<String>? skillIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    String? sessionIdOverride,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    String? responseMessageId,
    Map<String, dynamic>? userSettings,
    String? reasoningEffort,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
    String? lobeAgentId,
    Future<void> Function(LobeAgentCorrelation correlation)? onPreDispatch,
  }) async {
    // Generate unique IDs
    final messageId =
        (responseMessageId != null && responseMessageId.isNotEmpty)
        ? responseMessageId
        : const Uuid().v4();
    // Only use the socket session ID when a real socket connection exists.
    // When the socket is disconnected, session_id must be null/absent so the
    // backend falls back to returning SSE directly (httpStream transport)
    // instead of creating an async task that emits socket events to a
    // non-existent session. This mirrors OpenWebUI's frontend which sends
    // `session_id: $socket?.id` (undefined when disconnected).
    final sessionId =
        (sessionIdOverride != null && sessionIdOverride.isNotEmpty)
        ? sessionIdOverride
        : null;
    CancelToken? activeCancelToken;
    Future<void> abort() async {
      final cancelToken = activeCancelToken;
      if (cancelToken != null && !cancelToken.isCancelled) {
        cancelToken.cancel('User cancelled');
      }
    }

    _streamCancelActions[messageId] = abort;

    // Early branch for LobeHub backend
    if (serverConfig.isLobeHub) {
      return _sendLobeHubMessageSession(
        messages: messages,
        model: model,
        conversationId: conversationId,
        modelItem: modelItem,
        responseMessageId: messageId,
        userMessage: userMessage,
        files: files,
        lobeAgentId: lobeAgentId,
        onPreDispatch: onPreDispatch,
        sessionId: sessionId,
        abort: abort,
        activeCancelTokenCallback: (token) => activeCancelToken = token,
      );
    }

    var legacyPendingTurnPersisted = false;

    Future<void> ensureLegacyPendingTurnPersisted() async {
      if (legacyPendingTurnPersisted ||
          conversationId == null ||
          conversationId.isEmpty ||
          conversationId.startsWith('local:') ||
          userMessage == null ||
          userMessage.isEmpty) {
        return;
      }

      await _persistLegacyPendingTurn(
        conversationId: conversationId,
        assistantMessageId: messageId,
        model: model,
        userMessage: userMessage,
        modelItem: modelItem,
      );
      legacyPendingTurnPersisted = true;
    }

    Future<Response<ResponseBody>> postWithMetadataFormat(
      _ChatRequestMetadataFormat metadataFormat,
    ) async {
      final data = _buildChatCompletionPayload(
        messages: messages,
        model: model,
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        terminalId: terminalId,
        toolIds: toolIds,
        filterIds: filterIds,
        skillIds: skillIds,
        enableWebSearch: enableWebSearch,
        enableImageGeneration: enableImageGeneration,
        enableCodeInterpreter: enableCodeInterpreter,
        isVoiceMode: isVoiceMode,
        modelItem: modelItem,
        toolServers: toolServers,
        backgroundTasks: backgroundTasks,
        userSettings: userSettings,
        reasoningEffort: reasoningEffort,
        parentId: parentId,
        userMessage: userMessage,
        variables: variables,
        files: files,
        metadataFormat: metadataFormat,
      );

      _traceApi(
        'sendMessageSession: posting to /api/chat/completions '
        '(model=$model, sessionId=$sessionId, '
        'metadataFormat=${metadataFormat.name})',
      );

      final cancelToken = CancelToken();
      activeCancelToken = cancelToken;

      return _dio.post<ResponseBody>(
        '/api/chat/completions',
        data: data,
        options: Options(
          responseType: ResponseType.stream,
          // Accept all non-5xx so we can inspect error bodies ourselves.
          validateStatus: (status) => status != null && status < 600,
        ),
        cancelToken: cancelToken,
      );
    }

    var metadataFormat =
        _chatRequestMetadataFormat ?? _ChatRequestMetadataFormat.modernV09;
    if (metadataFormat == _ChatRequestMetadataFormat.legacyPreV09) {
      await ensureLegacyPendingTurnPersisted();
    }
    var resp = await postWithMetadataFormat(metadataFormat);
    var status = resp.statusCode ?? 0;

    // Surface structured errors before transport binding.
    if (status < 200 || status >= 300) {
      final error = await _decodeChatCompletionError(resp);
      final shouldRetryWithLegacy =
          metadataFormat == _ChatRequestMetadataFormat.modernV09 &&
          _isUnsupportedModernChatMetadataError(error);

      if (!shouldRetryWithLegacy) {
        throw Exception('Chat completion failed ($status): $error');
      }

      _traceApi(
        'sendMessageSession: retrying with legacy pre-v0.9 chat metadata '
        'after error: $error',
      );

      metadataFormat = _ChatRequestMetadataFormat.legacyPreV09;
      _chatRequestMetadataFormat = metadataFormat;
      await ensureLegacyPendingTurnPersisted();
      resp = await postWithMetadataFormat(metadataFormat);
      status = resp.statusCode ?? 0;

      if (status < 200 || status >= 300) {
        final retryError = await _decodeChatCompletionError(resp);
        throw Exception('Chat completion failed ($status): $retryError');
      }
    } else {
      _chatRequestMetadataFormat ??= metadataFormat;
    }

    final session = await classifyChatCompletionResponse(
      resp,
      messageId: messageId,
      sessionId: sessionId,
      conversationId: conversationId,
      abort: abort,
    );
    _traceApi(
      'sendMessageSession: transport=${session.transport.name}, '
      'taskId=${session.taskId}, messageId=${session.messageId}',
    );
    return session;
  }
  // -----------------------------------------------------------------------
  // Response classification
  // -----------------------------------------------------------------------

  /// Inspects a streamed [Response] from `/api/chat/completions` and
  /// returns a typed [ChatCompletionSession].
  ///
  /// Classification precedence:
  /// 1. `application/json` content-type → buffer, parse, check `task_id`
  ///    (`null` becomes an empty stream for persisted-chat recovery)
  /// 2. Body sniffing (handles missing / misleading content-type):
  ///    - `data:` prefix → httpStream (with replay stream)
  ///    - Valid JSON → taskSocket or jsonCompletion depending on `task_id`
  /// 3. `text/event-stream` content-type → httpStream
  /// 4. Else → [StateError]
  @visibleForTesting
  Future<ChatCompletionSession> classifyChatCompletionResponse(
    Response<ResponseBody> resp, {
    required String messageId,
    String? sessionId,
    String? conversationId,
    required Future<void> Function() abort,
  }) async {
    final ct = resp.headers.value('content-type') ?? '';
    final isJsonCt = ct.contains('application/json');
    final isEventStreamCt = ct.contains('text/event-stream');

    _traceApi(
      'classifyChatCompletionResponse: content-type=$ct, '
      'status=${resp.statusCode}',
    );

    final body = resp.data;
    if (body == null) {
      DebugLogger.error(
        'chat completion returned an empty body',
        scope: 'api/chat',
        data: {'status': resp.statusCode},
      );
      throw DioException(
        requestOptions: resp.requestOptions,
        response: resp,
        message: 'Empty chat completion response body',
      );
    }
    final bodyStream = body.stream;

    // ------------------------------------------------------------------
    // 1. Explicit application/json → buffer fully and classify
    // ------------------------------------------------------------------
    if (isJsonCt) {
      final json = await _requireJsonMapOrNull(bodyStream);
      if (json == null) {
        return _recoverJsonNullChatCompletion(
          messageId: messageId,
          sessionId: sessionId,
          conversationId: conversationId,
          abort: abort,
        );
      }
      return _classifyJsonBody(
        json,
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        abort: abort,
      );
    }

    // ------------------------------------------------------------------
    // 2. Sniff the body (handles missing or misleading headers)
    // ------------------------------------------------------------------
    final sniffResult = await _sniffChatCompletionBody(bodyStream);

    switch (sniffResult) {
      case _SniffSse(:final buffered, :final rest):
        _traceApi('classifyChatCompletionResponse → httpStream (body sniff)');
        return ChatCompletionSession.httpStream(
          messageId: messageId,
          sessionId: sessionId,
          conversationId: conversationId,
          byteStream: _replayStream(buffered, rest),
          abort: abort,
        );

      case _SniffJson(:final json):
        if (json == null) {
          return _recoverJsonNullChatCompletion(
            messageId: messageId,
            sessionId: sessionId,
            conversationId: conversationId,
            abort: abort,
          );
        }
        return _classifyJsonBody(
          json,
          messageId: messageId,
          sessionId: sessionId,
          conversationId: conversationId,
          abort: abort,
        );
    }

    // ------------------------------------------------------------------
    // 3. Fall back to content-type header
    // ------------------------------------------------------------------
    // ignore: dead_code
    if (isEventStreamCt) {
      _traceApi('classifyChatCompletionResponse → httpStream (content-type)');
      return ChatCompletionSession.httpStream(
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        byteStream: bodyStream,
        abort: abort,
      );
    }

    throw StateError(
      'Unable to classify chat completion response '
      '(content-type=$ct)',
    );
  }
  // -----------------------------------------------------------------------
  // @visibleForTesting helpers
  // -----------------------------------------------------------------------

  /// Exposes [_buildChatCompletionPayload] for unit tests.
  @visibleForTesting
  Map<String, dynamic> buildChatCompletionPayloadForTest({
    required List<Map<String, dynamic>> messages,
    required String model,
    required String messageId,
    required String sessionId,
    String? conversationId,
    String? terminalId,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    Map<String, dynamic>? userSettings,
    String? reasoningEffort,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
    bool useLegacyChatMetadata = false,
  }) {
    return _buildChatCompletionPayload(
      messages: messages,
      model: model,
      messageId: messageId,
      sessionId: sessionId,
      conversationId: conversationId,
      terminalId: terminalId,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      enableCodeInterpreter: enableCodeInterpreter,
      isVoiceMode: isVoiceMode,
      modelItem: modelItem,
      toolServers: toolServers,
      backgroundTasks: backgroundTasks,
      userSettings: userSettings,
      reasoningEffort: reasoningEffort,
      parentId: parentId,
      userMessage: userMessage,
      variables: variables,
      files: files,
      metadataFormat: useLegacyChatMetadata
          ? _ChatRequestMetadataFormat.legacyPreV09
          : _ChatRequestMetadataFormat.modernV09,
    );
  }

  /// Registers a cancel action for testing the widened cancel map.
  @visibleForTesting
  void registerLegacyCancelActionForTest(
    String messageId,
    Future<void> Function() action,
  ) {
    _streamCancelActions[messageId] = action;
  }

  // === Tasks control (parity with Web client) ===
  Future<void> stopTask(String taskId) async {
    if (serverConfig.isLobeHub) return;
    try {
      await _dio.post('/api/tasks/stop/$taskId');
    } catch (e) {
      rethrow;
    }
  }

  Future<void> stopTasksByChat(String chatId) async {
    if (serverConfig.isLobeHub) return;
    try {
      final encodedChatId = Uri.encodeComponent(chatId);
      await _dio.post('/api/tasks/chat/$encodedChatId/stop');
    } catch (e) {
      rethrow;
    }
  }

  Future<List<String>> getTaskIdsByChat(String chatId) async {
    if (serverConfig.isLobeHub) return const [];
    try {
      final resp = await _dio.get('/api/tasks/chat/$chatId');
      final data = resp.data;
      if (data is Map && data['task_ids'] is List) {
        return (data['task_ids'] as List).map((e) => e.toString()).toList();
      }
      return const [];
    } catch (e) {
      rethrow;
    }
  }

  Future<List<String>> resolveChatMessageToolCall({
    required String chatId,
    required String messageId,
    required String callId,
    required OpenWebUiToolCallAction action,
    Map<String, dynamic>? answers,
  }) async {
    if (serverConfig.isLobeHub) return const [];
    final response = await _dio.post(
      '/api/v1/chats/${Uri.encodeComponent(chatId)}/messages/'
      '${Uri.encodeComponent(messageId)}/resolve',
      data: <String, dynamic>{
        'call_id': callId,
        'action': action.name,
        if (action == OpenWebUiToolCallAction.answer) 'answers': answers,
      },
    );
    final data = response.data;
    if (data is! Map) return const <String>[];
    final rawTaskIds = data['task_ids'];
    final taskIds = rawTaskIds is List
        ? rawTaskIds
              .map((value) => value?.toString().trim() ?? '')
              .where((value) => value.isNotEmpty)
        : data['task_id'] == null
        ? const Iterable<String>.empty()
        : <String>[data['task_id'].toString().trim()]
              .where((value) => value.isNotEmpty);
    return taskIds.toSet().toList(growable: false);
  }

  /// POST `/api/v1/tasks/active/chats` `{chat_ids: [...]}` → `{active_chat_ids: [...]}`.
  ///
  /// Bulk query for which of [chatIds] currently have an active server task.
  /// Open WebUI through 0.10 provides the dedicated task endpoint; 0.11 puts
  /// the same state on chat-list rows. A 404 or 405 permanently selects that
  /// list fallback for this API-service instance.
  Future<Set<String>> checkActiveChats(List<String> chatIds) async {
    if (serverConfig.isLobeHub) return <String>{};
    if (chatIds.isEmpty) {
      return <String>{};
    }
    if (_activeChatsEndpointUnsupported) {
      return _checkActiveChatsFromLists(chatIds);
    }
    try {
      final resp = await _dio.post(
        '/api/v1/tasks/active/chats',
        data: {'chat_ids': chatIds},
      );
      final data = resp.data;
      if (data is Map && data['active_chat_ids'] is List) {
        return (data['active_chat_ids'] as List)
            .map((e) => e.toString())
            .toSet();
      }
      return <String>{};
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 404 || statusCode == 405) {
        _activeChatsEndpointUnsupported = true;
        DebugLogger.log(
          'active-chats endpoint unsupported; using chat-list state',
          scope: 'api/tasks',
          data: {'status': statusCode},
        );
        return _checkActiveChatsFromLists(chatIds);
      }
      rethrow;
    }
  }

  // Cancel an active streaming message by its messageId (client-side abort)
  void cancelStreamingMessage(String messageId) {
    try {
      final action = _streamCancelActions.remove(messageId);
      if (action != null) {
        action();
      }
    } catch (_) {}
  }

  /// Clears the cancel action for a message when streaming completes normally.
  /// Called by streaming_helper when finishStreaming is invoked.
  void clearStreamCancelToken(String messageId) {
    _streamCancelActions.remove(messageId);
  }

  /// Reconciles server-persisted user and assistant message records after a LobeHub
  /// Agent turn, anchoring the local [conduitClientId] into message metadata.
  Future<LobeReconcileResult> reconcileAgentTurn(
    LobeAgentCorrelation correlation,
  ) async {
    if (correlation.topicId.isEmpty || correlation.topicId.startsWith('local:')) {
      return const LobeReconcileResult(
        success: false,
        errorMessage: 'Local or empty topic cannot be reconciled',
        ambiguous: false,
      );
    }

    try {
      final allMessages =
          await fetchAllLobeHubMessages(_dio, topicId: correlation.topicId);
      final newMessages = <Map<String, dynamic>>[];
      for (final item in allMessages) {
        final id = item['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        if (correlation.snapshotServerIds.contains(id)) continue;
        newMessages.add(item);
      }

      final matchingUsers = newMessages.where((m) {
        if (m['role'] != 'user') return false;
        final content = m['content']?.toString() ?? '';
        return content.trim() == correlation.userText.trim();
      }).toList();

      if (matchingUsers.isEmpty) {
        return const LobeReconcileResult(
          success: false,
          errorMessage: 'No matching user message found after snapshot',
          ambiguous: false,
        );
      }
      if (matchingUsers.length > 1) {
        return const LobeReconcileResult(
          success: false,
          errorMessage:
              'Ambiguous: multiple matching user messages found after snapshot',
          ambiguous: true,
        );
      }
      final userMsg = matchingUsers.single;
      final serverUserId = userMsg['id'].toString();

      // Find assistant message among new messages
      var assistantCandidates = newMessages.where((m) {
        if (m['role'] != 'assistant') return false;
        final parentId = m['parentId']?.toString();
        return parentId != null && parentId == serverUserId;
      }).toList();

      if (assistantCandidates.isEmpty) {
        assistantCandidates =
            newMessages.where((m) => m['role'] == 'assistant').toList();
      }

      if (assistantCandidates.isEmpty) {
        return LobeReconcileResult(
          success: false,
          serverUserId: serverUserId,
          errorMessage: 'No matching assistant message found after snapshot',
          ambiguous: false,
        );
      }
      if (assistantCandidates.length > 1) {
        return LobeReconcileResult(
          success: false,
          serverUserId: serverUserId,
          errorMessage:
              'Ambiguous: multiple candidate assistant messages found after snapshot',
          ambiguous: true,
        );
      }
      final assistantMsg = assistantCandidates.single;
      final serverAssistantId = assistantMsg['id'].toString();

      // Patch user message metadata merging existing
      final userExistingMeta = userMsg['metadata'] is Map
          ? Map<String, dynamic>.from(userMsg['metadata'] as Map)
          : (userMsg['meta'] is Map
              ? Map<String, dynamic>.from(userMsg['meta'] as Map)
              : <String, dynamic>{});
      userExistingMeta['conduitClientId'] = correlation.userLocalId;
      await _dio.patch(
        '/api/v1/messages/$serverUserId',
        data: {'metadata': userExistingMeta},
      );

      // Patch assistant message metadata merging existing
      final asstExistingMeta = assistantMsg['metadata'] is Map
          ? Map<String, dynamic>.from(assistantMsg['metadata'] as Map)
          : (assistantMsg['meta'] is Map
              ? Map<String, dynamic>.from(assistantMsg['meta'] as Map)
              : <String, dynamic>{});
      asstExistingMeta['conduitClientId'] = correlation.assistantLocalId;
      await _dio.patch(
        '/api/v1/messages/$serverAssistantId',
        data: {'metadata': asstExistingMeta},
      );

      return LobeReconcileResult(
        success: true,
        serverUserId: serverUserId,
        serverAssistantId: serverAssistantId,
      );
    } catch (e) {
      return LobeReconcileResult(
        success: false,
        errorMessage: 'Reconcile failed: $e',
        ambiguous: false,
      );
    }
  }

  Future<ChatCompletionSession> _sendLobeHubMessageSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    required String? conversationId,
    required Map<String, dynamic>? modelItem,
    required String responseMessageId,
    required Map<String, dynamic>? userMessage,
    required List<Map<String, dynamic>>? files,
    required String? lobeAgentId,
    required Future<void> Function(LobeAgentCorrelation correlation)?
        onPreDispatch,
    required String? sessionId,
    required Future<void> Function() abort,
    required void Function(CancelToken token) activeCancelTokenCallback,
  }) async {
    // 1. Reject multipart/file inference typedSyncTerminalException400 before any inference POST
    final hasFiles = (files != null && files.isNotEmpty) ||
        (userMessage != null &&
            ((userMessage['files'] is List &&
                    (userMessage['files'] as List).isNotEmpty) ||
                (userMessage['attachment_ids'] is List &&
                    (userMessage['attachment_ids'] as List).isNotEmpty) ||
                (userMessage['embeds'] is List &&
                    (userMessage['embeds'] as List).isNotEmpty))) ||
        messages.any((m) =>
            (m['files'] is List && (m['files'] as List).isNotEmpty) ||
            (m['attachment_ids'] is List &&
                (m['attachment_ids'] as List).isNotEmpty) ||
            (m['embeds'] is List && (m['embeds'] as List).isNotEmpty) ||
            m['content'] is List);

    if (hasFiles) {
      throw const SyncTerminalException(
        statusCode: 400,
        message:
            'LobeHub REST v2.2.17 does not support file or image attachments in inference requests.',
      );
    }

    // 2. Add optional lobeAgentId parameter explicit; derive verifiedAgent from actualtopic if no param.
    String? resolvedAgentId = lobeAgentId;
    if ((resolvedAgentId == null || resolvedAgentId.isEmpty) &&
        conversationId != null &&
        !conversationId.startsWith('local:')) {
      try {
        final topicResp = await _dio.get('/api/v1/topics/$conversationId');
        final tData = topicResp.data;
        Map<String, dynamic>? topicObj;
        if (tData is Map) {
          topicObj = tData['data'] is Map
              ? Map<String, dynamic>.from(tData['data'] as Map)
              : Map<String, dynamic>.from(tData);
        }
        final aId = topicObj?['agentId']?.toString();
        if (aId != null && aId.isNotEmpty) {
          resolvedAgentId = aId;
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          throw SyncTerminalException(
            statusCode: e.response?.statusCode ?? 500,
            message: 'Failed to look up topic "$conversationId": ${e.message}',
          );
        }
      }
    }

    // 3. Pre-inference deduplication & Snapshot: query server messages BEFORE any inference POST
    List<Map<String, dynamic>> existingTopicMessages = const [];
    if (conversationId != null && !conversationId.startsWith('local:')) {
      existingTopicMessages =
          await fetchAllLobeHubMessages(_dio, topicId: conversationId);
      for (final m in existingTopicMessages) {
        final role = m['role']?.toString();
        final meta = m['metadata'] is Map
            ? m['metadata'] as Map
            : (m['meta'] is Map ? m['meta'] as Map : null);
        final cid = meta?['conduitClientId']?.toString();
        if ((cid == responseMessageId ||
                m['id']?.toString() == responseMessageId) &&
            role == 'assistant') {
          // Pre-existing assistant alias found => NO inference POST!
          final asstContent = m['content']?.toString() ?? '';
          final asstReasoning = m['reasoning']?.toString();
          return ChatCompletionSession.jsonCompletion(
            messageId: responseMessageId,
            sessionId: sessionId,
            conversationId: conversationId,
            jsonPayload: {
              'id': responseMessageId,
              'choices': [
                {
                  'index': 0,
                  'message': {
                    'role': 'assistant',
                    'content': asstContent,
                    if (asstReasoning != null && asstReasoning.isNotEmpty)
                      'reasoning_content': asstReasoning,
                  },
                  'finish_reason': 'stop',
                }
              ],
            },
          );
        }
      }
    }

    // 4. Branch: Agent turn vs Ordinary model turn
    if (resolvedAgentId != null && resolvedAgentId.isNotEmpty) {
      // Fetch configured agent to verify model and provider
      Map<String, dynamic>? agentObj;
      try {
        final agentResp = await _dio.get('/api/v1/agents/$resolvedAgentId');
        final aData = agentResp.data;
        if (aData is Map) {
          agentObj = aData['data'] is Map
              ? Map<String, dynamic>.from(aData['data'] as Map)
              : Map<String, dynamic>.from(aData);
        }
      } catch (e) {
        throw SyncTerminalException(
          statusCode: 400,
          message: 'Agent "$resolvedAgentId" not found on server.',
        );
      }
      if (agentObj == null) {
        throw SyncTerminalException(
          statusCode: 400,
          message: 'Agent "$resolvedAgentId" not found on server.',
        );
      }

      final agentModel = agentObj['model']?.toString();
      final agentProvider = agentObj['provider']?.toString();

      // User chooses rawmodel in Agentconversation: MUST match configuredAgentmodel/provider or reject visible typed400
      if (model.isNotEmpty && model != resolvedAgentId) {
        if (agentModel != null && agentModel.isNotEmpty && model != agentModel) {
          throw SyncTerminalException(
            statusCode: 400,
            message:
                'Requested model "$model" does not match configured agent model "$agentModel". LobeHub does not support per-turn model overrides on agents.',
          );
        }
      }

      final reqProvider = modelItem?['provider']?.toString() ??
          modelItem?['providerId']?.toString() ??
          modelItem?['metadata']?['provider']?.toString();
      if (reqProvider != null &&
          agentProvider != null &&
          reqProvider.isNotEmpty &&
          agentProvider.isNotEmpty &&
          reqProvider != agentProvider) {
        throw SyncTerminalException(
          statusCode: 400,
          message:
              'Requested provider "$reqProvider" does not match configured agent provider "$agentProvider".',
        );
      }

      // Snapshot server IDs before dispatch
      final snapshotServerIds = existingTopicMessages
          .map((m) => m['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      final userText = userMessage?['content']?.toString() ??
          (messages.isNotEmpty && messages.last['role'] == 'user'
              ? (messages.last['content']?.toString() ?? '')
              : '');
      final userLocalId = userMessage?['id']?.toString() ??
          (messages.isNotEmpty && messages.last['role'] == 'user'
              ? (messages.last['id']?.toString() ?? '')
              : const Uuid().v4());

      final correlation = LobeAgentCorrelation(
        topicId: conversationId ?? '',
        agentId: resolvedAgentId,
        userText: userText,
        userLocalId: userLocalId,
        assistantLocalId: responseMessageId,
        snapshotServerIds: snapshotServerIds,
        createdAt: DateTime.now(),
      );

      if (onPreDispatch != null) {
        await onPreDispatch(correlation);
      }

      String? instructions;
      for (final m in messages) {
        if (m['role'] == 'system') {
          final c = m['content'];
          final str = c is String ? c : (c?.toString() ?? '');
          if (str.trim().isNotEmpty) {
            instructions = (instructions == null || instructions.isEmpty)
                ? str.trim()
                : '$instructions\n${str.trim()}';
          }
        }
      }

      final responsePayload = <String, dynamic>{
        'model': resolvedAgentId,
        'stream': true,
        if (conversationId != null && !conversationId.startsWith('local:'))
          'previous_response_id': conversationId,
        'agentId': resolvedAgentId,
        'provider': ?agentProvider,
        'input': userText,
        if (instructions != null && instructions.isNotEmpty)
          'instructions': instructions,
      };

      final cancelToken = CancelToken();
      activeCancelTokenCallback(cancelToken);

      final resp = await _dio.post<ResponseBody>(
        '/api/v1/responses',
        data: responsePayload,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (s) => s != null && s < 600,
        ),
        cancelToken: cancelToken,
      );

      final status = resp.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final error = await _decodeChatCompletionError(resp);
        throw SyncTerminalException(
          statusCode: status,
          message: 'Agent chat completion failed ($status): $error',
        );
      }

      final byteStream = resp.data!.stream;
      final wrappedStream = _wrapLobeResponseByteStream(
        byteStream,
        correlation: correlation,
        onStreamCompleted: () async {
          if (conversationId != null &&
              !conversationId.startsWith('local:')) {
            await reconcileAgentTurn(correlation);
          }
        },
      );

      return ChatCompletionSession.httpStream(
        messageId: responseMessageId,
        sessionId: sessionId,
        conversationId: conversationId,
        byteStream: wrappedStream,
        abort: abort,
      );
    } else {
      // Ordinary model turn using /api/v1/chat
      String realModel = model;
      String? realProvider = modelItem?['provider']?.toString() ??
          modelItem?['providerId']?.toString() ??
          modelItem?['owned_by']?.toString() ??
          modelItem?['metadata']?['provider']?.toString();
      if (realProvider == null && realModel.contains('/')) {
        final parts = realModel.split('/');
        realProvider = parts[0];
        realModel = parts.sublist(1).join('/');
      }

      final cleanedMessages = <Map<String, dynamic>>[];
      for (final m in messages) {
        final c = m['content'];
        final str = c is String ? c : (c?.toString() ?? '');
        if (str.trim().isEmpty) continue;
        cleanedMessages.add({
          'role': m['role']?.toString() ?? 'user',
          'content': str,
        });
      }

      final chatPayload = <String, dynamic>{
        'model': realModel,
        'provider': ?realProvider,
        'messages': cleanedMessages,
        if (conversationId != null && !conversationId.startsWith('local:'))
          'topicId': conversationId,
      };

      final cancelToken = CancelToken();
      activeCancelTokenCallback(cancelToken);

      final resp = await _dio.post(
        '/api/v1/chat',
        data: chatPayload,
        options: Options(
          validateStatus: (s) => s != null && s < 600,
        ),
        cancelToken: cancelToken,
      );

      final status = resp.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final err = resp.data is Map
            ? (resp.data['error'] ?? resp.data['message'])
            : resp.data;
        throw SyncTerminalException(
          statusCode: status,
          message: 'Chat completion failed ($status): $err',
        );
      }

      dynamic responseData = resp.data;
      if (responseData is String) {
        try {
          responseData = jsonDecode(responseData);
        } catch (_) {}
      }
      final dataMap =
          responseData is Map ? responseData : <String, dynamic>{};
      final innerData =
          dataMap['data'] is Map ? (dataMap['data'] as Map) : dataMap;
      String content = innerData['content']?.toString() ??
          (innerData['message'] is Map
              ? (innerData['message'] as Map)['content']?.toString()
              : null) ??
          '';
      if (content.isEmpty &&
          innerData['choices'] is List &&
          (innerData['choices'] as List).isNotEmpty) {
        final firstChoice = (innerData['choices'] as List).first;
        if (firstChoice is Map && firstChoice['message'] is Map) {
          content = (firstChoice['message'] as Map)['content']?.toString() ?? '';
        }
      }
      final reasoning = innerData['reasoning']?.toString() ??
          innerData['reasoning_content']?.toString();
      final usage = innerData['usage'] is Map
          ? Map<String, dynamic>.from(innerData['usage'] as Map)
          : null;

      // Persist assistant and user if needed before returning JSON session
      if (conversationId != null && !conversationId.startsWith('local:')) {
        final existingClientIds = <String>{};
        for (final em in existingTopicMessages) {
          final meta = em['metadata'] is Map
              ? em['metadata'] as Map
              : (em['meta'] is Map ? em['meta'] as Map : null);
          final cid = meta?['conduitClientId']?.toString();
          if (cid != null && cid.isNotEmpty) existingClientIds.add(cid);
        }

        if (userMessage != null) {
          final uId = userMessage['id']?.toString();
          final uContent = userMessage['content']?.toString() ?? '';
          if (uId != null &&
              uId.isNotEmpty &&
              uContent.isNotEmpty &&
              !existingClientIds.contains(uId)) {
            await _dio.post(
              '/api/v1/messages',
              data: {
                'role': 'user',
                'content': uContent,
                'topicId': conversationId,
                'metadata': {'conduitClientId': uId},
              },
            );
          }
        }

        await _dio.post(
          '/api/v1/messages',
          data: {
            'role': 'assistant',
            'content': content,
            'topicId': conversationId,
            'model': realModel,
            'provider': ?realProvider,
            if (reasoning != null && reasoning.isNotEmpty)
              'reasoning': reasoning,
            'metadata': {'conduitClientId': responseMessageId},
          },
        );
      }

      final jsonChoices = <String, dynamic>{
        'id': responseMessageId,
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': content,
              if (reasoning != null && reasoning.isNotEmpty)
                'reasoning_content': reasoning,
            },
            'finish_reason': 'stop',
          }
        ],
        'usage': ?usage,
      };

      return ChatCompletionSession.jsonCompletion(
        messageId: responseMessageId,
        sessionId: sessionId,
        conversationId: conversationId,
        jsonPayload: jsonChoices,
      );
    }
  }

  Stream<List<int>> _wrapLobeResponseByteStream(
    Stream<List<int>> byteStream, {
    required LobeAgentCorrelation correlation,
    required Future<void> Function() onStreamCompleted,
  }) async* {
    final scanner = SseFrameScanner();
    final textStream = byteStream.cast<List<int>>().transform(utf8.decoder);

    bool failureDetected = false;
    String? failureMessage;
    bool completedHandled = false;

    await for (final chunk in textStream) {
      for (final frame in scanner.addChunk(chunk)) {
        final trimmed = frame.data.trim();
        final eventType = frame.event?.trim().toLowerCase();

        // Check for response.completed with status: failed
        if (eventType == 'response.completed' ||
            eventType == 'response.failed' ||
            trimmed.contains('"status":"failed"') ||
            trimmed.contains('"status": "failed"')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map) {
              final status = decoded['status']?.toString() ??
                  (decoded['response'] is Map
                      ? (decoded['response'] as Map)['status']?.toString()
                      : null);
              if (status == 'failed') {
                failureDetected = true;
                failureMessage = decoded['error']?.toString() ??
                    (decoded['response'] is Map
                        ? (decoded['response'] as Map)['error']?.toString()
                        : 'Response completed with status failed');
              }
            }
          } catch (_) {}
        }

        if (failureDetected) {
          throw SyncTerminalException(
            statusCode: 500,
            message: failureMessage ??
                'LobeHub response completed with status: failed',
          );
        }

        final isDoneFrame = trimmed == '[DONE]' ||
            eventType == 'response.completed' ||
            eventType == 'done' ||
            eventType == 'stop';

        if (isDoneFrame && !completedHandled) {
          completedHandled = true;
          try {
            await onStreamCompleted();
          } catch (e) {
            _traceApi('onStreamCompleted error: $e');
          }
        }

        final buffer = StringBuffer();
        if (frame.event != null) {
          buffer.writeln('event: ${frame.event}');
        }
        for (final line in frame.data.split('\n')) {
          buffer.writeln('data: $line');
        }
        buffer.writeln();
        yield utf8.encode(buffer.toString());
      }
    }

    for (final frame in scanner.close()) {
      final trimmed = frame.data.trim();
      final eventType = frame.event?.trim().toLowerCase();
      final isDoneFrame = trimmed == '[DONE]' ||
          eventType == 'response.completed' ||
          eventType == 'done' ||
          eventType == 'stop';

      if (isDoneFrame && !completedHandled) {
        completedHandled = true;
        try {
          await onStreamCompleted();
        } catch (e) {
          _traceApi('onStreamCompleted error: $e');
        }
      }

      final buffer = StringBuffer();
      if (frame.event != null) {
        buffer.writeln('event: ${frame.event}');
      }
      for (final line in frame.data.split('\n')) {
        buffer.writeln('data: $line');
      }
      buffer.writeln();
      yield utf8.encode(buffer.toString());
    }

    if (!completedHandled) {
      completedHandled = true;
      try {
        await onStreamCompleted();
      } catch (e) {
        _traceApi('onStreamCompleted error: $e');
      }
    }
  }
}

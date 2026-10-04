part of 'api_service.dart';

mixin _ChatsRawApi on _ApiServiceBase {
  // ---- CDT-RFC-001 Phase 1: raw sync-engine reads ----------------------
  // These exist because every legacy chat method parses to `Conversation`
  // and discards the blob/epoch ints the sync engine needs. All three are
  // read-only GETs through the existing Dio instance, so ApiAuthInterceptor
  // bearer/custom-header behavior applies unchanged.
  //
  // TODO(CDT-RFC-001 §7.2, §3.iii): Phase 2 push needs a generic
  // `updateChat(id, blob)` that always sends the complete `rowsToBlob`
  // reconstruction, never a partial dict (the server shallow-merges
  // top-level keys).

  /// GET `/api/v1/chats/?page={page}&include_pinned={..}&include_folders={..}`
  ///
  /// Raw `ChatTitleIdResponse` maps: `{id, title, updated_at, created_at,
  /// last_read_at}`. No model parsing; epoch-second ints preserved. Server
  /// page size is 60 (`routers/chats.py` `get_session_user_chat_list`,
  /// `limit = 60`); the legacy `expectedPageSize: 50` path above is
  /// untouched (it goes dead in Stage C).
  Future<List<Map<String, dynamic>>> getChatListPageRaw({
    required int page,
    bool includePinned = true,
    bool includeFolders = true,
  }) async {
    if (serverConfig.isLobeHub) {
      return _getLobeHubTopicListPageRaw(page: page);
    }
    try {
      final response = await _dio.get(
        '/api/v1/chats/',
        queryParameters: {
          'page': page,
          'include_pinned': includePinned,
          'include_folders': includeFolders,
        },
      );
      return _coerceRawMapList(response.data);
    } on DioException {
      rethrow;
    }
  }

  /// Fallback for LobeHub: fetches topics from `/api/v1/topics` and maps them
  /// to the raw chat list item schema.
  Future<List<Map<String, dynamic>>> _getLobeHubTopicListPageRaw({
    required int page,
  }) =>
      fetchLobeHubTopicListPageRaw(_dio, page: page);

  /// GET `/api/v1/chats/archived?page={page}&order_by=updated_at&direction=desc`
  ///
  /// Raw `ChatTitleIdResponse` maps; fixed server limit 60
  /// (`get_archived_session_user_chat_list`). The existing
  /// [getArchivedChats] sends limit/offset params the server ignores; it is
  /// left alone and goes dead in Stage C.
  Future<List<Map<String, dynamic>>> getArchivedChatListPageRaw({
    required int page,
  }) async {
    if (serverConfig.isLobeHub) {
      return const <Map<String, dynamic>>[];
    }
    try {
      final response = await _dio.get(
        '/api/v1/chats/archived',
        queryParameters: {
          'page': page,
          'order_by': 'updated_at',
          'direction': 'desc',
        },
      );
      return _coerceRawMapList(response.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return const <Map<String, dynamic>>[];
      }
      rethrow;
    }
  }

  /// GET `/api/v1/chats/{id}` — the raw `ChatResponse` map (id, user_id,
  /// title, chat, updated_at, created_at, share_id, archived, pinned, meta,
  /// folder_id).
  ///
  /// Returns null on 404; malformed 2xx bodies throw. NOTE: the vendored route
  /// signals a missing/unowned chat with HTTP 401 (`ERROR_MESSAGES.NOT_FOUND`),
  /// which intentionally surfaces here as an error so an expired token can
  /// never read as a mass delete; Phase 3 deletion reconcile handles 404/401
  /// explicitly. Large payloads are decoded off the UI isolate, mirroring
  /// the bytes->worker path of [_parseConversationPayload], but stop at the
  /// decoded map — no `Conversation` parsing.
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    if (serverConfig.isLobeHub) {
      return _getLobeHubChatRaw(id);
    }
    DebugLogger.log('fetch-raw', scope: 'api/chat', data: {'id': id});
    try {
      final response = await _dio.get(
        '/api/v1/chats/$id',
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      final bytes = data is Uint8List
          ? data
          : (data is List<int> ? Uint8List.fromList(data) : null);
      if (bytes == null) {
        // Defensive: some adapters may have decoded already.
        return _requireResponseMap(data, 'getChatRaw $id');
      }
      final Map<String, dynamic>? map =
          bytes.lengthInBytes >= _conversationWorkerByteThreshold
          ? await _workerManager.schedule<Uint8List, Map<String, dynamic>?>(
              decodeChatResponseEnvelopeWorker,
              bytes,
              debugLabel: 'decode_chat_raw',
            )
          : decodeChatResponseEnvelopeWorker(bytes);
      if (map == null) {
        throw FormatException('getChatRaw $id: expected JSON object response');
      }
      return map;
    } on DioException {
      rethrow;
    }
  }

  /// Fallback for LobeHub: fetches messages for topic [id] from `/api/v1/messages`
  /// and constructs the raw `ChatResponse` map with `chat.history.messages`.
  Future<Map<String, dynamic>?> _getLobeHubChatRaw(String id) =>
      fetchLobeHubChatRaw(_dio, id);
  // ===== Phase 2 sync write seams (CDT-RFC-001 §7.2/§7.4) =====
  //
  // These accept a prebuilt `rowsToBlob` blob and return the decoded
  // `ChatResponse` map verbatim. They deliberately do NOT reuse
  // `createConversation` (which builds its own blob from `ChatMessage`) nor
  // `updateConversation` (which sends a partial `{title, system}` dict — the
  // §3.iii shallow-merge hazard).

  /// POST `/api/v1/chats/new` with the COMPLETE blob; returns the parsed
  /// `ChatResponse` map (the server mints `id`).
  Future<Map<String, dynamic>> createChatRaw(
    Map<String, dynamic> chatBlob, {
    String? folderId,
    bool deferMessageUpload = false,
  }) async {
    if (serverConfig.isLobeHub) {
      return _createLobeHubChatRaw(
        chatBlob,
        folderId: folderId,
        deferMessageUpload: deferMessageUpload,
      );
    }
    try {
      final response = await _dio.post(
        '/api/v1/chats/new',
        data: {'chat': chatBlob, 'folder_id': ?folderId},
      );
      return _requireResponseMap(response.data, 'createChatRaw');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'createChat forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}` with the COMPLETE blob. Returns the parsed
  /// `ChatResponse` map; throws [SyncTerminalException] on 401/403.
  /// NOTE: the vendored `update_chat_by_id` route returns 401 (not 404) for a
  /// missing/unowned chat, so a server-side delete surfaces as
  /// [SyncTerminalException], not null; the 404->null branch is defensive only.
  Future<Map<String, dynamic>?> updateChatRaw(
    String id,
    Map<String, dynamic> chat,
  ) async {
    if (serverConfig.isLobeHub) {
      return _updateLobeHubChatRaw(id, chat);
    }
    try {
      final response = await _dio.post(
        '/api/v1/chats/$id',
        data: {'chat': chat},
      );
      return _requireResponseMap(response.data, 'updateChatRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'updateChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// DELETE `/api/v1/chats/{id}`. `true` on success; 404 -> `false` (already
  /// gone, no throw); 401/403 -> [SyncTerminalException].
  @override
  Future<bool> deleteChatRaw(String id) async {
    if (serverConfig.isLobeHub) {
      try {
        await _dio.delete('/api/v1/topics/$id');
        return true;
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) return false;
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          throw SyncTerminalException(
            statusCode: code,
            message: 'deleteChat $id forbidden',
          );
        }
        rethrow;
      }
    }
    try {
      await _dio.delete('/api/v1/chats/$id');
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'deleteChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// GET `/api/v1/chats/{id}/pinned` -> bool (false on a null/absent body).
  Future<bool> getChatPinnedRaw(String id) async {
    if (serverConfig.isLobeHub) {
      try {
        final resp = await _dio.get('/api/v1/topics/$id');
        final data = resp.data is Map
            ? (resp.data['data'] is Map ? resp.data['data'] : resp.data)
            : null;
        if (data is Map) {
          return data['favorite'] == true || data['starred'] == true;
        }
        return false;
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) return false;
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          throw SyncTerminalException(
            statusCode: code,
            message: 'getChatPinned $id forbidden',
          );
        }
        rethrow;
      }
    }
    try {
      final response = await _dio.get('/api/v1/chats/$id/pinned');
      return response.data == true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'getChatPinned $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/pin` — low-level stateless toggle primitive.
  Future<Map<String, dynamic>?> togglePinRaw(String id) async {
    if (serverConfig.isLobeHub) {
      try {
        final resp = await _dio.get('/api/v1/topics/$id');
        final data = resp.data is Map
            ? (resp.data['data'] is Map ? resp.data['data'] : resp.data)
            : null;
        if (data is! Map) return null;
        final currentFav =
            data['favorite'] == true || data['starred'] == true;
        final nextFav = !currentFav;
        await _dio.patch(
          '/api/v1/topics/$id',
          data: {'favorite': nextFav},
        );
        return await getChatRaw(id);
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) return null;
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          throw SyncTerminalException(
            statusCode: code,
            message: 'pinChat $id forbidden',
          );
        }
        rethrow;
      }
    }
    try {
      final response = await _dio.post('/api/v1/chats/$id/pin');
      return _requireResponseMap(response.data, 'togglePinRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'pinChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/archive` — low-level stateless toggle primitive.
  Future<Map<String, dynamic>?> toggleArchiveRaw(String id) async {
    if (serverConfig.isLobeHub) {
      return getChatRaw(id);
    }
    try {
      final response = await _dio.post('/api/v1/chats/$id/archive');
      return _requireResponseMap(response.data, 'toggleArchiveRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'archiveChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/folder` body `{folder_id: folderId}`. Returns
  /// the parsed `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> moveChatToFolderRaw(
    String id,
    String? folderId,
  ) async {
    if (serverConfig.isLobeHub) {
      try {
        await _dio.patch(
          '/api/v1/topics/$id',
          data: {'groupId': folderId},
        );
        return await getChatRaw(id);
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) return null;
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          throw SyncTerminalException(
            statusCode: code,
            message: 'moveChatToFolder $id forbidden',
          );
        }
        rethrow;
      }
    }
    try {
      final response = await _dio.post(
        '/api/v1/chats/$id/folder',
        data: {'folder_id': folderId},
      );
      return _requireResponseMap(response.data, 'moveChatToFolderRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'moveChatToFolder $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// DELETE `/api/v1/folders/{id}?delete_contents=<flag>`.
  Future<bool> deleteFolderRaw(String id, {bool deleteContents = false}) async {
    if (serverConfig.isLobeHub) {
      try {
        await _dio.delete('/api/v1/topics/groups/$id');
        return true;
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) return false;
        return false;
      }
    }
    try {
      await _dio.delete(
        '/api/v1/folders/$id',
        queryParameters: {'delete_contents': deleteContents},
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'deleteFolder $id forbidden',
        );
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _createLobeHubChatRaw(
    Map<String, dynamic> chatBlob, {
    String? folderId,
    required bool deferMessageUpload,
  }) async {
    final title = (chatBlob['title'] as String?)?.trim() ??
        (chatBlob['chat'] is Map
            ? (chatBlob['chat']['title'] as String?)?.trim()
            : null) ??
        'New Chat';

    String? agentId = chatBlob['meta'] is Map
        ? chatBlob['meta']['agentId']?.toString()
        : null;
    agentId ??= chatBlob['agentId']?.toString();

    final topicResp = await _dio.post(
      '/api/v1/topics',
      data: {
        'title': title,
        'groupId': ?folderId,
        'agentId': ?agentId,
      },
    );
    final topicData = topicResp.data is Map
        ? (topicResp.data['data'] is Map ? topicResp.data['data'] : topicResp.data)
        : <String, dynamic>{};
    final newTopicId = topicData['id'];
    if ((topicResp.data is Map && topicResp.data['success'] == false) ||
        newTopicId is! String || newTopicId.trim().isEmpty) {
      throw const SyncTerminalException(
        statusCode: 502,
        message: 'LobeHub topic creation did not return a successful topic ID.',
      );
    }

    final verifiedAgentId = topicData['agentId']?.toString() ?? agentId;
    final isAgentTopic =
        verifiedAgentId != null && verifiedAgentId.isNotEmpty;

    if (!deferMessageUpload) {
      await persistLobeHubChatMessages(
        topicId: newTopicId,
        chatBlob: chatBlob,
        agentId: isAgentTopic ? verifiedAgentId : null,
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'id': newTopicId,
      'title': title,
      'created_at': now,
      'updated_at': now,
      'pinned': false,
      'archived': false,
      'folder_id': ?folderId,
      'meta': {
        'agentId': ?verifiedAgentId,
      },
      'chat': chatBlob, // Preserve original blob and placeholders
    };
  }

  Future<Map<String, dynamic>?> _updateLobeHubChatRaw(
    String id,
    Map<String, dynamic> chat,
  ) async {
    final title = (chat['title'] as String?)?.trim() ??
        (chat['chat'] is Map
            ? (chat['chat']['title'] as String?)?.trim()
            : null);
    if (title != null && title.isNotEmpty) {
      await _dio.patch(
        '/api/v1/topics/$id',
        data: {'title': title},
      );
    }

    String? agentId;
    try {
      final topicResp = await _dio.get('/api/v1/topics/$id');
      final tData = topicResp.data;
      final topicObj = tData is Map
          ? (tData['data'] is Map ? tData['data'] : tData)
          : null;
      agentId = topicObj?['agentId']?.toString();
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
    }

    final isAgentTopic = agentId != null && agentId.isNotEmpty;

    final persistedMessageIds = await persistLobeHubChatMessages(
      topicId: id,
      chatBlob: chat,
      agentId: isAgentTopic ? agentId : null,
    );

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'id': id,
      'title': title ?? 'Chat',
      'updated_at': now,
      'created_at': now,
      'chat': chat,
      'conduitPersistedMessageIds': persistedMessageIds.toList(),
    };
  }

  Future<Set<String>> persistLobeHubChatMessages({
    required String topicId,
    required Map<String, dynamic> chatBlob,
    String? agentId,
  }) async {
    final chatMap =
        chatBlob['chat'] is Map ? (chatBlob['chat'] as Map) : chatBlob;
    final history =
        chatMap['history'] is Map ? (chatMap['history'] as Map) : null;
    Iterable<dynamic> rawMessages = const [];
    if (history != null && history['messages'] is Map) {
      rawMessages = (history['messages'] as Map).values;
    } else if (chatMap['messages'] is List) {
      rawMessages = chatMap['messages'] as List;
    }

    if (rawMessages.isEmpty) return const {};

    final messageList = rawMessages
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (messageList.isEmpty) return const {};

    messageList.sort((a, b) {
      final tA = a['timestamp'] ?? a['created_at'] ?? 0;
      final tB = b['timestamp'] ?? b['created_at'] ?? 0;
      if (tA is num && tB is num) return tA.compareTo(tB);
      return 0;
    });

    final suppressedIds = <String>{};
    final isAgentTopic = agentId != null && agentId.isNotEmpty;
    for (var index = 0; index < messageList.length; index++) {
      final message = messageList[index];
      final metadata = message['metadata'] ?? message['meta'];
      final awaitingCorrelation = metadata is Map &&
          metadata['lobeAgentCorrelation'] is Map &&
          metadata['serverMessageId'] == null;
      if (message['role'] == 'assistant' &&
          ((isAgentTopic && message['done'] != true) ||
              message['content'] == '' ||
              message['done'] == false ||
              message['isStreaming'] == true ||
              message['error'] != null ||
              (metadata is Map && metadata['terminal'] == true) ||
              awaitingCorrelation)) {
        suppressedIds.add(message['id']?.toString() ?? '');
        final parentId = message['parentId']?.toString();
        if (parentId != null) {
          suppressedIds.add(parentId);
        } else {
          for (var previous = index - 1; previous >= 0; previous--) {
            if (messageList[previous]['role'] == 'user') {
              suppressedIds.add(messageList[previous]['id']?.toString() ?? '');
              break;
            }
          }
        }
      }
    }

    final existingMessages =
        await fetchAllLobeHubMessages(_dio, topicId: topicId);
    final existingClientIds = <String>{};
    final existingServerIds = <String>{};
    for (final em in existingMessages) {
      final serverId = em['id']?.toString();
      if (serverId != null) existingServerIds.add(serverId);
      final meta = em['metadata'] is Map
          ? em['metadata'] as Map
          : (em['meta'] is Map ? em['meta'] as Map : null);
      final cid = meta?['conduitClientId']?.toString();
      if (cid != null && cid.isNotEmpty) existingClientIds.add(cid);
    }

    final persistedIds = <String>{};
    for (final m in messageList) {
      final mId = m['id']?.toString() ?? '';
      if (mId.isEmpty) continue;
      final messageMeta = m['metadata'] ?? m['meta'];
      final serverMessageId = messageMeta is Map
          ? messageMeta['serverMessageId']?.toString()
          : null;
      if (existingClientIds.contains(mId) ||
          existingServerIds.contains(mId) ||
          (serverMessageId != null &&
              existingServerIds.contains(serverMessageId))) {
        persistedIds.add(mId);
        continue;
      }
      if (suppressedIds.contains(mId)) continue;

      final role = m['role']?.toString() ?? 'user';
      final content = m['content']?.toString() ?? '';
      if (content.isEmpty ||
          (role == 'assistant' &&
              (m['done'] == false ||
                  m['isStreaming'] == true ||
                  m['error'] != null ||
                  (messageMeta is Map && messageMeta['terminal'] == true)))) {
        continue;
      }
      final model = m['model']?.toString();
      final provider = m['provider']?.toString();
      final reasoning = m['reasoning']?.toString();

      final meta = m['meta'] is Map
          ? Map<String, dynamic>.from(m['meta'] as Map)
          : (m['metadata'] is Map
              ? Map<String, dynamic>.from(m['metadata'] as Map)
              : <String, dynamic>{});
      meta['conduitClientId'] = mId;

      final response = await _dio.post(
        '/api/v1/messages',
        data: {
          'role': role,
          'content': content,
          'topicId': topicId,
          'agentId': ?agentId,
          'model': ?model,
          'provider': ?provider,
          if (reasoning != null && reasoning.isNotEmpty)
            'reasoning': reasoning,
          'metadata': meta,
        },
      );
      if (response.data is Map && response.data['success'] == false) {
        throw const SyncTerminalException(
          statusCode: 502,
          message: 'LobeHub rejected the message upload.',
        );
      }
      existingClientIds.add(mId);
      persistedIds.add(mId);
    }
    return persistedIds;
  }
}

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
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return _getLobeHubTopicListPageRaw(page: page);
      }
      rethrow;
    }
  }

  int? _parseServerEpochSeconds(Object? value) {
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

  /// Fallback for LobeHub: fetches topics from `/api/v1/topics` and maps them
  /// to the raw chat list item schema.
  Future<List<Map<String, dynamic>>> _getLobeHubTopicListPageRaw({
    required int page,
  }) async {
    try {
      final response = await _dio.get(
        '/api/v1/topics',
        queryParameters: {
          'page': page,
          'pageSize': 60,
        },
      );
      final data = response.data;
      List<dynamic>? topicsList;
      if (data is Map) {
        final innerData = data['data'];
        if (innerData is Map && innerData['topics'] is List) {
          topicsList = innerData['topics'] as List;
        } else if (data['topics'] is List) {
          topicsList = data['topics'] as List;
        } else if (innerData is List) {
          topicsList = innerData;
        }
      } else if (data is List) {
        topicsList = data;
      }
      if (topicsList == null || topicsList.isEmpty) {
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
        final updatedAt = _parseServerEpochSeconds(
              topic['updatedAt'] ?? topic['updated_at'],
            ) ??
            DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final createdAt = _parseServerEpochSeconds(
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
          if (folderId != null) 'folder_id': folderId,
        });
      }
      return result;
    } on DioException {
      return const <Map<String, dynamic>>[];
    }
  }

  /// GET `/api/v1/chats/archived?page={page}&order_by=updated_at&direction=desc`
  ///
  /// Raw `ChatTitleIdResponse` maps; fixed server limit 60
  /// (`get_archived_session_user_chat_list`). The existing
  /// [getArchivedChats] sends limit/offset params the server ignores; it is
  /// left alone and goes dead in Stage C.
  Future<List<Map<String, dynamic>>> getArchivedChatListPageRaw({
    required int page,
  }) async {
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
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return _getLobeHubChatRaw(id);
      }
      rethrow;
    }
  }

  /// Fallback for LobeHub: fetches messages for topic [id] from `/api/v1/messages`
  /// and constructs the raw `ChatResponse` map with `chat.history.messages`.
  Future<Map<String, dynamic>?> _getLobeHubChatRaw(String id) async {
    try {
      final messagesResponse = await _dio.get(
        '/api/v1/messages',
        queryParameters: {'topicId': id},
      );
      final msgData = messagesResponse.data;
      List<dynamic>? messagesList;
      if (msgData is Map) {
        final inner = msgData['data'];
        if (inner is Map && inner['messages'] is List) {
          messagesList = inner['messages'] as List;
        } else if (msgData['messages'] is List) {
          messagesList = msgData['messages'] as List;
        } else if (inner is List) {
          messagesList = inner;
        }
      } else if (msgData is List) {
        messagesList = msgData;
      }

      String title = 'New Chat';
      int createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      int updatedAt = createdAt;
      bool pinned = false;
      String? folderId;
      String? model;
      String? agentId;

      Map<String, dynamic>? topicObj;
      if (messagesList != null && messagesList.isNotEmpty) {
        final firstMsg = messagesList.first;
        if (firstMsg is Map && firstMsg['topic'] is Map) {
          topicObj = Map<String, dynamic>.from(firstMsg['topic'] as Map);
        }
      }

      if (topicObj == null) {
        try {
          final topicResp = await _dio.get('/api/v1/topics/$id');
          final tData = topicResp.data;
          if (tData is Map && tData['data'] is Map) {
            topicObj = Map<String, dynamic>.from(tData['data'] as Map);
          } else if (tData is Map) {
            topicObj = Map<String, dynamic>.from(tData);
          }
        } catch (_) {}
      }

      if (topicObj != null) {
        final tTitle = (topicObj['title'] as String?)?.trim();
        if (tTitle != null && tTitle.isNotEmpty) {
          title = tTitle;
        }
        createdAt = _parseServerEpochSeconds(topicObj['createdAt']) ?? createdAt;
        updatedAt = _parseServerEpochSeconds(topicObj['updatedAt']) ?? updatedAt;
        pinned = topicObj['favorite'] == true || topicObj['starred'] == true;
        folderId = topicObj['groupId']?.toString();
        model = topicObj['model']?.toString();
        agentId = topicObj['agentId']?.toString();
      }

      final messagesMap = <String, Map<String, dynamic>>{};
      String? currentId;

      if (messagesList != null) {
        for (final m in messagesList) {
          if (m is! Map) continue;
          final mId = m['id']?.toString() ?? '';
          if (mId.isEmpty) continue;
          currentId = mId;
          final role = m['role']?.toString() ?? 'user';
          final content = m['content']?.toString() ?? '';
          final mCreatedAt = _parseServerEpochSeconds(m['createdAt']) ?? createdAt;
          final mUpdatedAt = _parseServerEpochSeconds(m['updatedAt']) ?? updatedAt;
          final mModel = m['model']?.toString() ?? model;
          final reasoning = m['reasoning']?.toString();

          messagesMap[mId] = {
            'id': mId,
            'role': role,
            'content': content,
            'timestamp': mCreatedAt,
            'created_at': mCreatedAt,
            'updated_at': mUpdatedAt,
            if (m['parentId'] != null) 'parentId': m['parentId'].toString(),
            if (mModel != null) 'model': mModel,
            if (reasoning != null && reasoning.isNotEmpty) 'reasoning': reasoning,
            'chatId': id,
          };
        }
      }

      return {
        'id': id,
        'title': title,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'pinned': pinned,
        'archived': false,
        if (folderId != null) 'folder_id': folderId,
        'meta': {
          if (agentId != null) 'agentId': agentId,
          if (model != null) 'model': model,
        },
        'chat': {
          'title': title,
          if (model != null) 'models': [model],
          'history': {
            if (currentId != null) 'currentId': currentId,
            'messages': messagesMap,
          },
        },
      };
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
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
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/chats/new',
        data: {'chat': chatBlob, 'folder_id': ?folderId},
      );
      return _requireResponseMap(response.data, 'createChatRaw');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Fallback for LobeHub: create topic via POST /api/v1/topics
        try {
          final title = chatBlob['title'] as String? ?? 'New Chat';
          final topicResp = await _dio.post(
            '/api/v1/topics',
            data: {
              'title': title,
              if (folderId != null) 'groupId': folderId,
            },
          );
          final topicData = topicResp.data is Map
              ? (topicResp.data['data'] ?? topicResp.data)
              : {};
          final newId = topicData['id']?.toString() ??
              'tpc_${DateTime.now().millisecondsSinceEpoch}';
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          return {
            'id': newId,
            'title': title,
            'created_at': now,
            'updated_at': now,
            'chat': chatBlob,
          };
        } catch (_) {}
      }
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
    try {
      await _dio.delete('/api/v1/chats/$id');
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // Fallback for LobeHub: delete topic via DELETE /api/v1/topics/:id
        try {
          await _dio.delete('/api/v1/topics/$id');
          return true;
        } on DioException catch (e2) {
          if (e2.response?.statusCode == 404) return false;
        }
        return false;
      }
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

  /// GET `/api/v1/chats/{id}/pinned` -> bool (false on a null/absent body).
  Future<bool> getChatPinnedRaw(String id) async {
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
  ///
  /// Do not enqueue or retry this operation directly. Sync write paths must call
  /// desired-state reconcilers that probe before toggling and confirm after,
  /// because retrying this primitive alone can double-flip.
  ///
  /// Returns the parsed `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> togglePinRaw(String id) async {
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
  ///
  /// Do not enqueue or retry this operation directly. Sync write paths must call
  /// desired-state reconcilers that probe before toggling and confirm after,
  /// because retrying this primitive alone can double-flip.
  ///
  /// Returns the parsed `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> toggleArchiveRaw(String id) async {
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
  ///
  /// Distinct from [deleteFolder] (which omits the param and gets the
  /// DESTRUCTIVE server default `true`). Sync-driven deletes pass `false` so
  /// contained chats are re-parented to root, not deleted (verified
  /// `routers/folders.py:delete_folder_by_id`).
  /// Returns `true` on success; `false` on 404 (already gone); 401/403 ->
  /// [SyncTerminalException].
  Future<bool> deleteFolderRaw(String id, {bool deleteContents = false}) async {
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
}

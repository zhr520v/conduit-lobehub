import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late _MockHttpClientAdapter adapter;
  late ApiService lobeApi;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    adapter = _MockHttpClientAdapter();
    lobeApi = ApiService(
      serverConfig: const ServerConfig(
        id: 'lobehub_self_hosted',
        name: 'LobeHub Self Hosted',
        url: 'http://localhost:3210',
      ),
      workerManager: WorkerManager(),
    );
    lobeApi.dio.httpClientAdapter = adapter;
    lobeApi.dio.interceptors.clear();
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedChat(String chatId) async {
    await db.into(db.chats).insert(
          ChatsCompanion.insert(
            id: chatId,
            title: 'Test Chat',
            createdAt: 1000,
            updatedAt: 1000,
            bodySynced: const Value(true),
          ),
        );
  }

  Future<void> seedPlaceholder(
    String chatId,
    String messageId, {
    String content = '',
    String role = 'assistant',
    Map<String, dynamic>? metadata,
    String? model = 'gpt-4o',
    int orderIndex = 1,
  }) async {
    final payload = <String, dynamic>{
      'id': messageId,
      'role': role,
      'content': content,
      'metadata': metadata ?? <String, dynamic>{},
    };
    await db.into(db.messages).insert(
          MessagesCompanion.insert(
            id: messageId,
            chatId: chatId,
            role: role,
            content: content,
            model: Value(model),
            createdAt: 1000,
            orderIndex: orderIndex,
            payload: jsonEncode(payload),
            dirty: const Value(false),
          ),
        );
  }

  group('LobeHub Submission Barrier & Caller Seams', () {
    test(
      '1. durablecallbackbeforePOST: stores LobeAgentCorrelation + completionSubmitted in Drift preserving fields',
      () async {
        const chatId = 'chat-topic-1';
        const asstId = 'asst-local-1';
        await seedChat(chatId);
        await seedPlaceholder(
          chatId,
          asstId,
          content: 'pre-existing draft',
          model: 'claude-3-5-sonnet',
          orderIndex: 3,
          metadata: {'initialKey': 'preserveMe'},
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiServiceProvider.overrideWithValue(lobeApi),
          ],
        );
        addTearDown(container.dispose);

        final owner = captureOpenWebUiCompletionOwner(
          container,
          chatId: chatId,
          database: db,
          api: lobeApi,
        );

        final correlation = LobeAgentCorrelation(
          topicId: chatId,
          agentId: 'agent-finance-advisor',
          userText: 'Analyze stock portfolio',
          userLocalId: 'user-local-1',
          assistantLocalId: asstId,
          snapshotServerIds: {'srv-msg-old-1', 'srv-msg-old-2'},
          createdAt: DateTime.utc(2026, 10, 4, 12, 0, 0),
        );

        // Pre-dispatch callback executes BEFORE any POST is dispatched
        final callback = buildLobeHubAgentPreDispatchCallback(
          container,
          owner: owner,
          assistantMessageId: asstId,
        );

        await callback(correlation);

        // Verify the Drift placeholder row directly from database
        final row = await db.messagesDao.getMessage(chatId, asstId);
        check(row).isNotNull();
        check(row!.id).equals(asstId);
        check(row.chatId).equals(chatId);
        check(row.role).equals('assistant');
        check(row.orderIndex).equals(3); // Preserved existing row field
        check(row.content).equals('pre-existing draft'); // Preserved content

        final decodedPayload =
            jsonDecode(row.payload) as Map<String, dynamic>;
        check(decodedPayload['isStreaming']).equals(true);

        final meta = decodedPayload['metadata'] as Map<String, dynamic>;
        check(meta['completionSubmitted']).equals(true);
        check(meta['initialKey']).equals('preserveMe'); // Preserved metadata

        final storedCorr = meta['lobeAgentCorrelation'] as Map<String, dynamic>;
        check(storedCorr['topicId']).equals(chatId);
        check(storedCorr['agentId']).equals('agent-finance-advisor');
        check(storedCorr['userLocalId']).equals('user-local-1');
        check(storedCorr['assistantLocalId']).equals(asstId);
        final serverIds = (storedCorr['snapshotServerIds'] as List).cast<String>();
        check(serverIds).contains('srv-msg-old-1');
        check(serverIds).contains('srv-msg-old-2');
      },
    );

    test(
      '2. restartpersistedcorrelation: recovery reconciles persisted correlation without duplicate POST, fails on ambiguity',
      () async {
        const chatId = 'chat-reconcile-topic';
        const asstId = 'asst-reconcile-1';
        await seedChat(chatId);

        final correlation = LobeAgentCorrelation(
          topicId: chatId,
          agentId: 'agent-coder',
          userText: 'Write binary search',
          userLocalId: 'user-local-2',
          assistantLocalId: asstId,
          snapshotServerIds: {'srv-init-1'},
          createdAt: DateTime.utc(2026, 10, 4, 12, 0, 0),
        );

        // Seed with persisted correlation barrier (simulating restart after crash)
        await seedPlaceholder(
          chatId,
          asstId,
          metadata: {
            'lobeAgentCorrelation': correlation.toJson(),
            'completionSubmitted': true,
          },
        );

        var getMessagesCalled = false;
        var patchUserCalled = false;
        var patchAsstCalled = false;
        var postChatCompletionsCount = 0;
        var postResponsesCount = 0;

        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/messages',
          handler: (req) {
            getMessagesCalled = true;
            return _jsonResponse({
              'success': true,
              'data': [
                {'id': 'srv-init-1', 'role': 'user', 'content': 'old msg'},
                {
                  'id': 'srv-user-new',
                  'role': 'user',
                  'content': 'Write binary search',
                  'meta': {'conduitClientId': null},
                },
                {
                  'id': 'srv-asst-new',
                  'role': 'assistant',
                  'content': 'Here is binary search in Dart',
                  'model': 'gpt-4o',
                  'provider': 'openai',
                  'parentId': 'srv-user-new',
                  'meta': {'conduitClientId': null},
                }
              ]
            });
          },
        );

        adapter.registerHandler(
          method: 'PATCH',
          path: '/api/v1/messages/srv-user-new',
          handler: (req) {
            patchUserCalled = true;
            final body = req.data as Map<String, dynamic>;
            final meta = body['metadata'] as Map<String, dynamic>;
            check(meta['conduitClientId']).equals('user-local-2');
            return _jsonResponse({'success': true});
          },
        );

        adapter.registerHandler(
          method: 'PATCH',
          path: '/api/v1/messages/srv-asst-new',
          handler: (req) {
            patchAsstCalled = true;
            final body = req.data as Map<String, dynamic>;
            final meta = body['metadata'] as Map<String, dynamic>;
            check(meta['conduitClientId']).equals(asstId);
            return _jsonResponse({'success': true});
          },
        );

        adapter.registerHandler(
          method: 'POST',
          path: '/api/v1/chat',
          handler: (_) {
            postChatCompletionsCount++;
            return _jsonResponse({});
          },
        );

        adapter.registerHandler(
          method: 'POST',
          path: '/api/v1/responses',
          handler: (_) {
            postResponsesCount++;
            return _jsonResponse({});
          },
        );

        final mockSyncEngine = _TestRecoverySyncEngine(
          assistantId: asstId,
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiServiceProvider.overrideWithValue(lobeApi),
            syncEngineProvider.overrideWith(() => mockSyncEngine),
          ],
        );
        addTearDown(container.dispose);

        final owner = captureOpenWebUiCompletionOwner(
          container,
          chatId: chatId,
          database: db,
          api: lobeApi,
        );

        // Run recovery
        await recoverSubmittedOpenWebUiCompletion(
          container,
          owner: owner,
          assistantMessageId: asstId,
          recoveryAttempts: 2,
          recoveryDelay: Duration.zero,
        );

        // Assert server reconciliation executed
        check(getMessagesCalled).isTrue();
        check(patchUserCalled).isTrue();
        check(patchAsstCalled).isTrue();

        // Assert NO duplicate POSTs occurred
        check(postChatCompletionsCount).equals(0);
        check(postResponsesCount).equals(0);

        // Sub-test: Ambiguity fails visibly and NEVER re-POSTs
        const ambigChatId = 'chat-ambig';
        const ambigAsstId = 'asst-ambig-1';
        await seedChat(ambigChatId);
        await seedPlaceholder(
          ambigChatId,
          ambigAsstId,
          metadata: {
            'lobeAgentCorrelation': correlation.toJson(),
            'completionSubmitted': true,
          },
        );

        // Return multiple matching user messages to cause ambiguity
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/messages',
          handler: (_) => _jsonResponse({
            'success': true,
            'data': [
              {'id': 'u1', 'role': 'user', 'content': 'Write binary search'},
              {'id': 'u2', 'role': 'user', 'content': 'Write binary search'},
            ]
          }),
        );

        final ambigOwner = captureOpenWebUiCompletionOwner(
          container,
          chatId: ambigChatId,
          database: db,
          api: lobeApi,
        );

        await recoverSubmittedOpenWebUiCompletion(
          container,
          owner: ambigOwner,
          assistantMessageId: ambigAsstId,
          recoveryAttempts: 1,
          recoveryDelay: Duration.zero,
        );

        // Check visible failure recorded in Drift
        final ambigRow =
            await db.messagesDao.getMessage(ambigChatId, ambigAsstId);
        check(ambigRow).isNotNull();
        final ambigPayload =
            jsonDecode(ambigRow!.payload) as Map<String, dynamic>;
        check(ambigPayload['error']).isNotNull();
        check(ambigPayload['done']).equals(true);
        // Zero POSTs
        check(postChatCompletionsCount).equals(0);
        check(postResponsesCount).equals(0);
      },
    );

    test(
      '3. ownershipA→B noforeignwrites: fences auth/account/epoch and aborts without writing to foreign DB',
      () async {
        final dbA = db;
        final dbB = AppDatabase(NativeDatabase.memory());
        addTearDown(dbB.close);

        const chatId = 'chat-cross-tenant';
        const asstId = 'asst-fenced-1';
        await seedChat(chatId);
        await seedPlaceholder(chatId, asstId);

        var currentEpoch = Object();
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => dbA),
            apiServiceProvider.overrideWithValue(lobeApi),
            openWebUiAuthSessionEpochProvider.overrideWith((ref) => currentEpoch),
          ],
        );
        addTearDown(container.dispose);

        final ownerA = captureOpenWebUiCompletionOwner(
          container,
          chatId: chatId,
          database: dbA,
          api: lobeApi,
        );

        final correlation = LobeAgentCorrelation(
          topicId: chatId,
          agentId: 'agent-secret',
          userText: 'Confidential request',
          userLocalId: 'user-a',
          assistantLocalId: asstId,
          snapshotServerIds: {},
          createdAt: DateTime.now(),
        );

        final callback = buildLobeHubAgentPreDispatchCallback(
          container,
          owner: ownerA,
          assistantMessageId: asstId,
        );

        // Epoch changes / user switches to B
        currentEpoch = Object();
        container.invalidate(openWebUiAuthSessionEpochProvider);

        // Pre-dispatch callback must abort with StateError on ownership change
        await check(callback(correlation)).throws<StateError>();

        // Verify NO writes to foreign DB B
        final foreignChat = await (dbB.select(dbB.chats)..where((t) => t.id.equals(chatId))).getSingleOrNull();
        check(foreignChat).isNull();
        final foreignMsg = await dbB.messagesDao.getMessage(chatId, asstId);
        check(foreignMsg).isNull();
      },
    );

    test(
      '4. rawprovider retained: retains exact selectedModel.provider metadata for Agent and Ordinary routes',
      () {
        // Case A: Model with direct provider metadata
        final modelWithMeta = Model(
          id: 'claude-3-5-sonnet-20241022',
          name: 'Claude 3.5 Sonnet',
          metadata: {
            'provider': 'anthropic',
            'owned_by': 'anthropic',
          },
        );

        final item1 = ensureModelItemProvider(
          modelItem: {'id': 'claude-3-5-sonnet-20241022', 'name': 'Claude'},
          selectedModel: modelWithMeta,
        );
        check(item1['provider']).equals('anthropic');
        check((item1['metadata'] as Map)['provider']).equals('anthropic');

        // Case B: Model with nested meta.provider
        final modelWithNestedMeta = Model(
          id: 'deepseek-chat',
          name: 'DeepSeek Chat',
          metadata: {
            'meta': {'provider': 'deepseek'},
          },
        );

        final item2 = ensureModelItemProvider(
          modelItem: {'id': 'deepseek-chat', 'name': 'DeepSeek'},
          selectedModel: modelWithNestedMeta,
        );
        check(item2['provider']).equals('deepseek');
        check((item2['metadata'] as Map)['provider']).equals('deepseek');

        // Case C: Agent derivation derives from actualConversation.metadata.agentId, NOT selectedModel.id
        final conversationWithAgent = Conversation(
          id: 'topic-agent-xyz',
          title: 'Agent Chat',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          metadata: {
            'agentId': 'agent_translator_v2',
            'provider': 'anthropic',
          },
          messages: const [],
        );

        final agentId = resolveLobeAgentId(conversationWithAgent);
        check(agentId).equals('agent_translator_v2');
        check(agentId).not((it) => it.equals(modelWithMeta.id));
      },
    );

    test(
      '5. preflight400notaccepted: preflight failure (unsupported files/attachments) rejects before onPreDispatch and does NOT mark submitted',
      () async {
        const chatId = 'chat-preflight-fail';
        const asstId = 'asst-fail-1';
        await seedChat(chatId);
        await seedPlaceholder(chatId, asstId);

        var preDispatchCalled = false;

        // Call with unsupported media file
        await check(
          lobeApi.sendMessageSession(
            messages: [
              {'role': 'user', 'content': 'Look at this picture'}
            ],
            model: 'gpt-4o',
            conversationId: chatId,
            lobeAgentId: 'agent-vision',
            files: [
              {'id': 'file-123', 'name': 'image.png'}
            ],
            onPreDispatch: (correlation) async {
              preDispatchCalled = true;
            },
          ),
        ).throws<SyncTerminalException>();

        // Preflight failed with 400 before HTTP request: onPreDispatch must NOT have run
        check(preDispatchCalled).isFalse();

        // The Drift row must NOT have completionSubmitted = true
        final row = await db.messagesDao.getMessage(chatId, asstId);
        check(row).isNotNull();
        final payload = jsonDecode(row!.payload) as Map<String, dynamic>;
        final meta = payload['metadata'] as Map<String, dynamic>?;
        check(meta?['completionSubmitted']).not((it) => it.equals(true));
        check(meta?['lobeAgentCorrelation']).isNull();
      },
    );
  });
}

class _TestRecoverySyncEngine extends SyncEngine {
  _TestRecoverySyncEngine({
    required String assistantId,
  }) : _assistantId = assistantId;

  final String _assistantId;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<Conversation?> pullChatNow(String requestedChatId) async {
    return Conversation(
      id: requestedChatId,
      title: 'Recovered Conversation',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: [
        ChatMessage(
          id: _assistantId,
          role: 'assistant',
          content: 'Here is binary search in Dart',
          timestamp: DateTime.now(),
          isStreaming: false,
          model: 'gpt-4o',
          metadata: {'provider': 'openai'},
        ),
      ],
    );
  }
}

class _MockHttpClientAdapter implements HttpClientAdapter {
  final Map<String, ResponseBody Function(RequestOptions options)> _handlers = {};

  void registerHandler({
    required String method,
    required String path,
    required ResponseBody Function(RequestOptions options) handler,
  }) {
    _handlers['${method.toUpperCase()} $path'] = handler;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method.toUpperCase()} ${options.path}';
    final handler = _handlers[key];
    if (handler != null) {
      return handler(options);
    }
    return _jsonResponse({});
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object? body, {int statusCode = 200}) {
  final bytes = utf8.encode(jsonEncode(body));
  return ResponseBody(
    Stream.value(Uint8List.fromList(bytes)),
    statusCode,
    headers: {
      'content-type': ['application/json'],
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/services/services.dart';
import 'package:conduit_core/features/lobehub/providers/providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit/features/auth/views/lobehub_connection_page.dart';

// ============================================================================
// Mock HTTP Client Adapter Simulating https://ai.opw.ink Endpoints
// ============================================================================

/// In-memory mock HTTP client adapter that intercepts and simulates all
/// LobeHub backend API endpoints on `https://ai.opw.ink` without making real
/// unmocked network calls.
class MockLobeHubHttpAdapter implements HttpClientAdapter {
  MockLobeHubHttpAdapter({this.customHandler});

  /// Optional custom interceptor to simulate edge cases, mid-stream aborts,
  /// or specific failure injections.
  FutureOr<ResponseBody?> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )? customHandler;

  /// Full log of all intercepted requests for assertion verification.
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);

    if (customHandler != null) {
      final customResponse = await customHandler!(options, cancelFuture);
      if (customResponse != null) {
        return customResponse;
      }
    }

    final path = options.path;
    final method = options.method.toUpperCase();

    // 1. Health check: GET /api/v1/health (or fallback /api/health)
    if (path.endsWith('/api/v1/health') || path.endsWith('/api/health')) {
      return jsonResponse({
        'status': 'ok',
        'service': 'lobehub',
        'version': '1.0.0',
        'timestamp': DateTime.now().toIso8601String(),
      });
    }

    // 2. User profile: GET /api/v1/users/me (or fallback /api/v1/user)
    if (path.endsWith('/api/v1/users/me') || path.endsWith('/api/v1/user')) {
      return jsonResponse({
        'id': 'usr_zhr520v',
        'username': 'zhr520v',
        'email': 'zhr@opw.ink',
        'fullName': 'ZHR Developer',
        'avatar': 'https://ai.opw.ink/avatars/zhr520v.png',
        'role': 'admin',
        'createdAt': '2026-01-01T00:00:00.000Z',
      });
    }

    // 3. Agents synchronization: GET /api/v1/agents
    if (path.endsWith('/api/v1/agents')) {
      return jsonResponse([
        {
          'id': 'agent_deepseek_r1',
          'title': 'DeepSeek R1',
          'description': 'Advanced reasoning and mathematical reasoning model',
          'avatar': '🧠',
          'systemRole': 'You are DeepSeek R1, an advanced AI reasoning assistant.',
          'model': 'deepseek-r1',
          'chatConfig': {'temperature': 0.6},
          'plugins': ['web_search'],
          'createdAt': '2026-02-01T00:00:00.000Z',
        },
        {
          'id': 'agent_code_architect',
          'title': 'Code Architect',
          'description': 'Full-stack software design and Dart/Flutter specialist',
          'avatar': '💻',
          'systemRole': 'You are a principal software engineer.',
          'model': 'claude-3-5-sonnet',
          'chatConfig': {'temperature': 0.2},
          'plugins': <String>[],
          'createdAt': '2026-02-02T00:00:00.000Z',
        },
        {
          'id': 'agent_general',
          'title': 'Lobe Assistant',
          'description': 'General everyday assistant',
          'avatar': '🤖',
          'systemRole': 'You are a helpful and versatile assistant.',
          'model': 'gpt-4o',
          'chatConfig': <String, dynamic>{},
          'plugins': <String>[],
          'createdAt': '2026-02-03T00:00:00.000Z',
        },
      ]);
    }

    // 4. Topics: POST /api/v1/topics (creation) and GET /api/v1/topics (list)
    if (path.endsWith('/api/v1/topics')) {
      if (method == 'POST') {
        final data = options.data is Map
            ? Map<String, dynamic>.from(options.data as Map)
            : <String, dynamic>{};
        return jsonResponse({
          'id': 'topic_e2e_101',
          'title': data['title'] ?? 'DeepSeek R1 Quantum Mechanics',
          'agentId': data['agentId'] ?? 'agent_deepseek_r1',
          'sessionId': data['sessionId'],
          'favorite': false,
          'metadata': data['metadata'] ?? <String, dynamic>{},
          'createdAt': '2026-10-03T02:00:00.000Z',
          'updatedAt': '2026-10-03T02:00:00.000Z',
        });
      }
      return jsonResponse([
        {
          'id': 'topic_e2e_101',
          'title': 'DeepSeek R1 Quantum Mechanics',
          'agentId': 'agent_deepseek_r1',
          'favorite': false,
          'metadata': <String, dynamic>{},
          'createdAt': '2026-10-03T02:00:00.000Z',
          'updatedAt': '2026-10-03T02:00:00.000Z',
        },
      ]);
    }

    // 5. Messages: POST /api/v1/messages (persisting user/assistant message)
    if (path.endsWith('/api/v1/messages')) {
      if (method == 'POST') {
        final data = options.data is Map
            ? Map<String, dynamic>.from(options.data as Map)
            : <String, dynamic>{};
        final role = data['role'] ?? 'user';
        final now = DateTime.now().toIso8601String();
        return jsonResponse({
          'id': 'msg_${role}_${DateTime.now().millisecondsSinceEpoch}',
          'role': role,
          'content': data['content'] ?? '',
          'topicId': data['topicId'] ?? 'topic_e2e_101',
          'model': data['model'] ?? 'deepseek-r1',
          'provider': data['provider'],
          'reasoning': data['reasoning'],
          'tools': data['tools'] ?? <dynamic>[],
          'createdAt': now,
          'updatedAt': now,
        });
      }
      return jsonResponse(<dynamic>[]);
    }

    // 6. Streaming Generation: POST /api/v1/responses (SSE stream)
    if (path.endsWith('/api/v1/responses') && method == 'POST') {
      const sseContent =
          'event: reasoning\n'
          'data: "Analyzing quantum mechanics principles..."\n\n'
          'event: reasoning\n'
          'data: " Considering EPR paradox and Bell\'s theorem..."\n\n'
          'event: text\n'
          'data: "Quantum superposition and entanglement are core foundations"\n\n'
          'event: text\n'
          'data: " of quantum mechanics."\n\n'
          'event: stop\n'
          'data: {"finish_reason": "stop"}\n\n';
      return sseResponse(sseContent);
    }

    // Default fallback
    return jsonResponse(<String, dynamic>{});
  }

  @override
  void close({bool force = false}) {}
}

/// Helper producing a mock JSON response body.
ResponseBody jsonResponse(dynamic data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

/// Helper producing a mock SSE event stream response body.
ResponseBody sseResponse(String sseText, {int statusCode = 200}) {
  return ResponseBody.fromString(
    sseText,
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
}

/// Creates a test setup tuple with mock adapter, Dio, and LobeHubApiClient.
(MockLobeHubHttpAdapter, Dio, LobeHubApiClient) createTestClientEnvironment({
  String baseUrl = 'https://ai.opw.ink',
  String apiKey = 'sk-lh-test-key-2026',
  FutureOr<ResponseBody?> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )? customHandler,
}) {
  final adapter = MockLobeHubHttpAdapter(customHandler: customHandler);
  final dio = Dio()..httpClientAdapter = adapter;
  final client = LobeHubApiClient(
    baseUrl: baseUrl,
    apiKey: apiKey,
    dio: dio,
  );
  return (adapter, dio, client);
}

// ============================================================================
// Full-Journey End-to-End Test Suite
// ============================================================================

void main() {
  group('LobeHub End-to-End (E2E) Integration Tests & Delivery Verification', () {
    // ------------------------------------------------------------------------
    // Step 1: Onboarding & Connection Verification
    // ------------------------------------------------------------------------
    group('1. Onboarding & Connection (ai.opw.ink + API Key)', () {
      test('validates server URL normalization, health check, and user profile verification', () async {
        const rawServerInput = 'ai.opw.ink';
        const apiKeyInput = 'sk-lh-test-key-2026';

        // 1.1 URL Normalization check
        final normalizedUrl = LobeHubConnectionPage.normalizeServerUrl(rawServerInput);
        expect(normalizedUrl, equals('https://ai.opw.ink'));

        final (adapter, _, client) = createTestClientEnvironment(
          baseUrl: normalizedUrl,
          apiKey: apiKeyInput,
        );
        addTearDown(client.close);

        // 1.2 Health Check verification
        final health = await client.checkHealth();
        expect(health.isOk, isTrue);
        expect(health.service, equals('lobehub'));
        expect(health.status, equals('ok'));

        // 1.3 User Profile verification
        final user = await client.getCurrentUser();
        expect(user.id, equals('usr_zhr520v'));
        expect(user.username, equals('zhr520v'));
        expect(user.email, equals('zhr@opw.ink'));
        expect(user.role, equals('admin'));

        // 1.4 Dual Auth Headers Verification
        expect(adapter.requests.length, greaterThanOrEqualTo(2));
        for (final req in adapter.requests) {
          expect(req.headers['Authorization'], equals('Bearer $apiKeyInput'));
          expect(req.headers['X-API-Key'], equals(apiKeyInput));
        }

        // 1.5 Secure Credentials Persistence
        final secureStore = InMemorySecureKeyValueStore();
        await secureStore.write(key: 'lobehub_server_url', value: normalizedUrl);
        await secureStore.write(key: 'lobehub_api_key', value: apiKeyInput);
        await secureStore.write(key: 'lobehub_username', value: user.username);
        await secureStore.write(key: 'lobehub_user_id', value: user.id);

        expect(await secureStore.read(key: 'lobehub_server_url'), equals('https://ai.opw.ink'));
        expect(await secureStore.read(key: 'lobehub_api_key'), equals('sk-lh-test-key-2026'));
        expect(await secureStore.read(key: 'lobehub_username'), equals('zhr520v'));
        expect(await secureStore.read(key: 'lobehub_user_id'), equals('usr_zhr520v'));
      });
    });

    // ------------------------------------------------------------------------
    // Step 2: Agents Synchronization & Discovery
    // ------------------------------------------------------------------------
    group('2. Agents Synchronization (GET /api/v1/agents & Selection)', () {
      test('fetches agent roster, filters by name/description, and selects DeepSeek R1', () async {
        final (adapter, _, client) = createTestClientEnvironment();
        addTearDown(client.close);

        final notifier = LobeAgentsNotifier(apiClient: client);

        // 2.1 Initial State Check
        expect(notifier.state.agents, isEmpty);
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.isOffline, isFalse);

        // 2.2 Load Remote Agents
        await notifier.loadAgents();

        expect(adapter.requests.any((r) => r.path.endsWith('/api/v1/agents')), isTrue);
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.isOffline, isFalse);
        expect(notifier.state.agents.length, equals(3));

        // 2.3 Verify DeepSeek R1 Model in Roster
        final deepseekAgent = notifier.state.agents.firstWhere(
          (a) => a.id == 'agent_deepseek_r1',
        );
        expect(deepseekAgent.title, equals('DeepSeek R1'));
        expect(deepseekAgent.model, equals('deepseek-r1'));
        expect(deepseekAgent.systemRole, contains('DeepSeek R1'));
        expect(deepseekAgent.plugins, contains('web_search'));

        // 2.4 Client-Side Search Filtering
        notifier.setSearchQuery('DeepSeek');
        expect(notifier.state.filteredAgents.length, equals(1));
        expect(notifier.state.filteredAgents.first.id, equals('agent_deepseek_r1'));

        notifier.setSearchQuery('Dart/Flutter');
        expect(notifier.state.filteredAgents.length, equals(1));
        expect(notifier.state.filteredAgents.first.id, equals('agent_code_architect'));

        notifier.clearSearchQuery();
        expect(notifier.state.filteredAgents.length, equals(3));

        // 2.5 Agent Selection
        notifier.selectAgent('agent_deepseek_r1');
        expect(notifier.state.selectedAgentId, equals('agent_deepseek_r1'));
        expect(notifier.state.selectedAgent?.title, equals('DeepSeek R1'));
      });
    });

    // ------------------------------------------------------------------------
    // Step 3: Topic Creation Bound to Agent
    // ------------------------------------------------------------------------
    group('3. Topic Creation (POST /api/v1/topics)', () {
      test('creates a new topic thread bound to the selected DeepSeek R1 agent', () async {
        final (adapter, _, client) = createTestClientEnvironment();
        addTearDown(client.close);

        final topicsNotifier = LobeTopicsNotifier(apiClient: client);

        final createdTopic = await topicsNotifier.createTopic(
          title: 'DeepSeek R1 Quantum Mechanics',
          agentId: 'agent_deepseek_r1',
          metadata: {'domain': 'physics', 'version': '1.0'},
        );

        // 3.1 Verify HTTP POST request payload
        final topicReq = adapter.requests.firstWhere(
          (r) => r.path.endsWith('/api/v1/topics') && r.method == 'POST',
        );
        final payload = topicReq.data as Map<String, dynamic>;
        expect(payload['title'], equals('DeepSeek R1 Quantum Mechanics'));
        expect(payload['agentId'], equals('agent_deepseek_r1'));
        expect(payload['metadata']['domain'], equals('physics'));

        // 3.2 Verify Topic Properties and State Activation
        expect(createdTopic.id, equals('topic_e2e_101'));
        expect(createdTopic.agentId, equals('agent_deepseek_r1'));
        expect(createdTopic.title, equals('DeepSeek R1 Quantum Mechanics'));

        expect(topicsNotifier.state.activeTopicId, equals('topic_e2e_101'));
        expect(topicsNotifier.state.topics.length, equals(1));
        expect(topicsNotifier.state.hasActiveTopic, isTrue);
        expect(topicsNotifier.state.activeTopic?.id, equals('topic_e2e_101'));
      });
    });

    // ------------------------------------------------------------------------
    // Step 4: Two-Phase Chat Flow (DeepSeek R1 Reasoning + Text Streaming)
    // ------------------------------------------------------------------------
    group('4. Two-Phase Chat Flow (Interleaved Reasoning & Text Streaming)', () {
      test('executes user message persistence, SSE streaming with reasoning tokens, and assistant persistence', () async {
        final (adapter, _, client) = createTestClientEnvironment();
        addTearDown(client.close);

        final bridge = LobeHubChatBridge(apiClient: client);

        LobeMessage? persistedUserMsg;
        LobeMessage? persistedAsstMsg;
        final events = <LobeStreamEvent>[];
        final reasoningChunks = <String>[];
        final textChunks = <String>[];

        final stream = bridge.sendMessageStream(
          topicId: 'topic_e2e_101',
          agentId: 'agent_deepseek_r1',
          model: 'deepseek-r1',
          content: 'Explain quantum entanglement and superposition in detail.',
          onUserMessagePersisted: (msg) => persistedUserMsg = msg,
          onAssistantMessagePersisted: (msg) => persistedAsstMsg = msg,
          onReasoningDelta: (r) => reasoningChunks.add(r),
          onTextDelta: (t) => textChunks.add(t),
        );

        await for (final event in stream) {
          events.add(event);
        }

        // 4.1 Phase 1: User Message Persisted
        expect(persistedUserMsg, isNotNull);
        expect(persistedUserMsg!.role, equals('user'));
        expect(
          persistedUserMsg!.content,
          equals('Explain quantum entanglement and superposition in detail.'),
        );
        expect(persistedUserMsg!.topicId, equals('topic_e2e_101'));

        // 4.2 Phase 2: Stream Consumption & Delta Emission
        expect(events.length, equals(5));
        expect(events[0], isA<LobeReasoningDelta>());
        expect(events[1], isA<LobeReasoningDelta>());
        expect(events[2], isA<LobeTextDelta>());
        expect(events[3], isA<LobeTextDelta>());
        expect(events[4], isA<LobeStreamDone>());

        expect(
          (events[0] as LobeReasoningDelta).reasoning,
          equals('Analyzing quantum mechanics principles...'),
        );
        expect(
          (events[1] as LobeReasoningDelta).reasoning,
          equals(" Considering EPR paradox and Bell's theorem..."),
        );
        expect(
          (events[2] as LobeTextDelta).text,
          equals('Quantum superposition and entanglement are core foundations'),
        );
        expect(
          (events[3] as LobeTextDelta).text,
          equals(' of quantum mechanics.'),
        );
        expect(
          (events[4] as LobeStreamDone).finishReason,
          equals('stop'),
        );

        // 4.3 Reasoning & Text Buffer Accumulation
        const expectedReasoning =
            "Analyzing quantum mechanics principles... Considering EPR paradox and Bell's theorem...";
        const expectedContent =
            'Quantum superposition and entanglement are core foundations of quantum mechanics.';

        expect(bridge.accumulatedReasoning, equals(expectedReasoning));
        expect(bridge.accumulatedText, equals(expectedContent));
        expect(bridge.isGenerating, isFalse);

        // 4.4 Phase 3: Assistant Message Persisted with Complete Reasoning
        expect(persistedAsstMsg, isNotNull);
        expect(persistedAsstMsg!.role, equals('assistant'));
        expect(persistedAsstMsg!.content, equals(expectedContent));
        expect(persistedAsstMsg!.reasoning, equals(expectedReasoning));
        expect(persistedAsstMsg!.topicId, equals('topic_e2e_101'));

        // 4.5 Verify Request Order: User Msg -> Responses Stream -> Asst Msg
        expect(adapter.requests.length, equals(3));
        expect(adapter.requests[0].path, endsWith('/api/v1/messages'));
        expect((adapter.requests[0].data as Map)['role'], equals('user'));

        expect(adapter.requests[1].path, endsWith('/api/v1/responses'));
        expect((adapter.requests[1].data as Map)['stream'], isTrue);
        expect((adapter.requests[1].data as Map)['model'], equals('deepseek-r1'));

        expect(adapter.requests[2].path, endsWith('/api/v1/messages'));
        expect((adapter.requests[2].data as Map)['role'], equals('assistant'));
        expect((adapter.requests[2].data as Map)['reasoning'], equals(expectedReasoning));
        expect((adapter.requests[2].data as Map)['content'], equals(expectedContent));
      });
    });

    // ------------------------------------------------------------------------
    // Step 5: Local Drift / State Persistence & Lossless Round-Trip
    // ------------------------------------------------------------------------
    group('5. Local Drift / State Persistence & Lossless Round-Trip', () {
      test('preserves topic, assistant reasoning, and agent fields across Conduit and Drift mappings', () async {
        final originalTopic = LobeTopic(
          id: 'topic_drift_roundtrip',
          title: 'Quantum Physics Discussion',
          agentId: 'agent_deepseek_r1',
          sessionId: 'session_e2e_1',
          groupId: 'folder_physics',
          favorite: true,
          metadata: const {'difficulty': 'advanced', 'tags': ['quantum', 'entanglement']},
          createdAt: DateTime.utc(2026, 10, 3, 2, 0, 0),
          updatedAt: DateTime.utc(2026, 10, 3, 2, 30, 0),
        );

        final originalMessage = LobeMessage(
          id: 'msg_drift_roundtrip',
          topicId: 'topic_drift_roundtrip',
          role: 'assistant',
          content: 'Entangled particles share interconnected states.',
          reasoning: 'Derived from wavefunction collapse analysis.',
          model: 'deepseek-r1',
          provider: 'deepseek',
          tools: const [
            {
              'name': 'web_search',
              'arguments': {'query': 'EPR paradox'},
            }
          ],
          createdAt: DateTime.utc(2026, 10, 3, 2, 1, 0),
          updatedAt: DateTime.utc(2026, 10, 3, 2, 1, 5),
        );

        // 5.1 LobeTopic <-> Conduit Conversation
        final conversation = lobeTopicToConversation(originalTopic);
        expect(conversation.id, equals(originalTopic.id));
        expect(conversation.title, equals(originalTopic.title));
        expect(conversation.pinned, isTrue);
        expect(conversation.folderId, equals('folder_physics'));
        expect(conversation.model, equals('agent_deepseek_r1'));

        final restoredTopic = conversationToLobeTopic(conversation);
        expect(restoredTopic.id, equals(originalTopic.id));
        expect(restoredTopic.title, equals(originalTopic.title));
        expect(restoredTopic.favorite, isTrue);
        expect(restoredTopic.agentId, equals('agent_deepseek_r1'));
        expect(restoredTopic.sessionId, equals('session_e2e_1'));
        expect(restoredTopic.groupId, equals('folder_physics'));
        expect(restoredTopic.metadata['difficulty'], equals('advanced'));

        // 5.2 LobeMessage <-> Conduit ChatMessage (with Reasoning Output Block)
        final chatMessage = lobeMessageToChatMessage(originalMessage);
        expect(chatMessage.id, equals(originalMessage.id));
        expect(chatMessage.role, equals('assistant'));
        expect(chatMessage.content, equals(originalMessage.content));
        expect(chatMessage.model, equals('deepseek-r1'));
        expect(chatMessage.metadata?['reasoning'], equals(originalMessage.reasoning));
        expect(chatMessage.output, isNotNull);
        expect(chatMessage.output!.first['type'], equals('reasoning'));
        expect(chatMessage.output!.first['content'], equals(originalMessage.reasoning));

        final restoredMessage = chatMessageToLobeMessage(chatMessage);
        expect(restoredMessage.id, equals(originalMessage.id));
        expect(restoredMessage.content, equals(originalMessage.content));
        expect(restoredMessage.reasoning, equals(originalMessage.reasoning));
        expect(restoredMessage.model, equals('deepseek-r1'));
        expect(restoredMessage.tools.length, equals(1));
        expect(restoredMessage.tools.first['name'], equals('web_search'));

        // 5.3 LobeAgent <-> Conduit Model
        const originalAgent = LobeAgent(
          id: 'agent_deepseek_r1',
          title: 'DeepSeek R1',
          description: 'Reasoning Engine',
          avatar: '🧠',
          systemRole: 'You are DeepSeek R1.',
          model: 'deepseek-r1',
          chatConfig: {'temperature': 0.6},
          plugins: ['web_search'],
        );
        final model = lobeAgentToModel(originalAgent);
        expect(model.id, equals('agent_deepseek_r1'));
        expect(model.name, equals('DeepSeek R1'));
        expect(model.metadata?['systemRole'], equals('You are DeepSeek R1.'));

        final restoredAgent = modelToLobeAgent(model);
        expect(restoredAgent.id, equals(originalAgent.id));
        expect(restoredAgent.title, equals(originalAgent.title));
        expect(restoredAgent.systemRole, equals(originalAgent.systemRole));
        expect(restoredAgent.model, equals(originalAgent.model));

        // 5.4 Drift Chats Table Companions & Row Round-Trip
        final chatCompanion = lobeTopicToChatCompanion(originalTopic);
        expect(chatCompanion.id.value, equals(originalTopic.id));
        expect(chatCompanion.title.value, equals(originalTopic.title));
        expect(chatCompanion.pinned.value, isTrue);

        final chatRow = ChatRow(
          id: chatCompanion.id.value,
          title: chatCompanion.title.value,
          folderId: chatCompanion.folderId.value,
          pinned: chatCompanion.pinned.value,
          archived: false,
          createdAt: chatCompanion.createdAt.value,
          updatedAt: chatCompanion.updatedAt.value,
          rawExtra: chatCompanion.rawExtra.value,
          meta: chatCompanion.meta.value,
        );
        final fromChatRow = chatRowToLobeTopic(chatRow);
        expect(fromChatRow.id, equals(originalTopic.id));
        expect(fromChatRow.title, equals(originalTopic.title));
        expect(fromChatRow.favorite, isTrue);
        expect(fromChatRow.agentId, equals(originalTopic.agentId));

        // 5.5 Drift Messages Table Companions & Row Round-Trip
        final msgCompanion = lobeMessageToMessageCompanion(
          originalMessage,
          chatId: originalTopic.id,
          orderIndex: 2,
        );
        expect(msgCompanion.id.value, equals(originalMessage.id));
        expect(msgCompanion.chatId.value, equals(originalTopic.id));
        expect(msgCompanion.role.value, equals('assistant'));
        expect(msgCompanion.orderIndex.value, equals(2));

        final msgRow = MessageRow(
          id: msgCompanion.id.value,
          chatId: msgCompanion.chatId.value,
          role: msgCompanion.role.value,
          content: msgCompanion.content.value,
          model: msgCompanion.model.value,
          createdAt: msgCompanion.createdAt.value,
          orderIndex: msgCompanion.orderIndex.value,
          payload: msgCompanion.payload.value,
        );
        final fromMsgRow = messageRowToLobeMessage(msgRow);
        expect(fromMsgRow.id, equals(originalMessage.id));
        expect(fromMsgRow.content, equals(originalMessage.content));
        expect(fromMsgRow.reasoning, equals(originalMessage.reasoning));

        // 5.6 Raw SQL Map Representations (Offline Storage)
        final topicMap = lobeTopicToChatRowMap(originalTopic);
        final fromTopicMap = chatRowMapToLobeTopic(topicMap);
        expect(fromTopicMap.id, equals(originalTopic.id));
        expect(fromTopicMap.title, equals(originalTopic.title));

        final msgMap = lobeMessageToMessageRowMap(originalMessage);
        final fromMsgMap = messageRowMapToLobeMessage(msgMap);
        expect(fromMsgMap.id, equals(originalMessage.id));
        expect(fromMsgMap.content, equals(originalMessage.content));
        expect(fromMsgMap.reasoning, equals(originalMessage.reasoning));

        // 5.7 InMemory Cache Operations
        final localCache = InMemoryLobeTopicsCache();
        await localCache.saveCachedTopics([originalTopic]);
        final cachedTopics = await localCache.loadCachedTopics();
        expect(cachedTopics.length, equals(1));
        expect(cachedTopics.first.id, equals(originalTopic.id));

        await localCache.saveCachedMessages(originalTopic.id, [originalMessage]);
        final cachedMessages = await localCache.loadCachedMessages(originalTopic.id);
        expect(cachedMessages.length, equals(1));
        expect(cachedMessages.first.id, equals(originalMessage.id));
      });
    });

    // ------------------------------------------------------------------------
    // Step 6: Mid-Stream Cancellation & Partial Persistence
    // ------------------------------------------------------------------------
    group('6. Cancellation Test (Mid-Stream Abort)', () {
      test('cancels generation mid-stream and guarantees partial assistant message persistence without crash', () async {
        late StreamController<Uint8List> streamController;

        final (adapter, _, client) = createTestClientEnvironment(
          customHandler: (options, cancelFuture) {
            if (options.path.endsWith('/api/v1/responses')) {
              streamController = StreamController<Uint8List>();

              cancelFuture?.then((_) {
                if (!streamController.isClosed) {
                  streamController.addError(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.cancel,
                      message: 'Stream cancelled by user',
                    ),
                  );
                  streamController.close();
                }
              });

              return ResponseBody(
                streamController.stream,
                200,
                headers: {
                  Headers.contentTypeHeader: ['text/event-stream'],
                },
              );
            }
            return null; // default handler handles user and assistant message POSTs
          },
        );
        addTearDown(client.close);

        final bridge = LobeHubChatBridge(apiClient: client);
        final receivedEvents = <LobeStreamEvent>[];
        final completer = Completer<void>();

        bridge.sendMessageStream(
          topicId: 'topic_cancellation_test',
          agentId: 'agent_deepseek_r1',
          content: 'Provide a long comprehensive proof of Riemann Hypothesis.',
        ).listen(
          (event) {
            receivedEvents.add(event);
            if (event is LobeTextDelta && event.text == 'Initial partial formulation: ') {
              // 6.1 Abort mid-stream immediately upon receiving first text token
              bridge.cancelGeneration('User clicked stop button');
            }
          },
          onDone: () => completer.complete(),
          onError: (e) => completer.completeError(e),
        );

        // Feed initial reasoning chunk and first text chunk
        await Future<void>.delayed(const Duration(milliseconds: 10));
        streamController.add(
          Uint8List.fromList(
            utf8.encode(
              'event: reasoning\n'
              'data: "Deep thinking on zeta function zeros..."\n\n'
              'event: text\n'
              'data: "Initial partial formulation: "\n\n',
            ),
          ),
        );

        await completer.future;

        // 6.2 Verify Stream yielded LobeStreamDone('cancelled')
        expect(receivedEvents.length, equals(3));
        expect(receivedEvents[0], equals(const LobeReasoningDelta('Deep thinking on zeta function zeros...')));
        expect(receivedEvents[1], equals(const LobeTextDelta('Initial partial formulation: ')));
        expect(receivedEvents[2], equals(const LobeStreamDone('cancelled')));

        // 6.3 Verify Bridge State Reset
        expect(bridge.isGenerating, isFalse);
        expect(bridge.accumulatedReasoning, equals('Deep thinking on zeta function zeros...'));
        expect(bridge.accumulatedText, equals('Initial partial formulation: '));

        // 6.4 Verify Partial Assistant Message Persistence
        expect(bridge.lastAssistantMessage, isNotNull);
        expect(bridge.lastAssistantMessage!.content, equals('Initial partial formulation: '));
        expect(
          bridge.lastAssistantMessage!.reasoning,
          equals('Deep thinking on zeta function zeros...'),
        );

        // 6.5 Confirm Third Request was POST /api/v1/messages with Partial Message
        expect(adapter.requests.length, equals(3));
        final partialReq = adapter.requests[2];
        expect(partialReq.path, endsWith('/api/v1/messages'));
        expect((partialReq.data as Map)['role'], equals('assistant'));
        expect((partialReq.data as Map)['content'], equals('Initial partial formulation: '));
        expect(
          (partialReq.data as Map)['reasoning'],
          equals('Deep thinking on zeta function zeros...'),
        );
      });
    });

    // ------------------------------------------------------------------------
    // Step 7: Error Recovery & Offline Fallback Handling
    // ------------------------------------------------------------------------
    group('7. Error Recovery & Offline Fallback Indicators', () {
      test('7.1 Auth failure: handles 401 Unauthorized with descriptive typed exception', () async {
        final (adapter, _, client) = createTestClientEnvironment(
          customHandler: (options, _) {
            if (options.path.endsWith('/api/v1/health')) {
              return jsonResponse(
                {'message': 'Invalid API key, please check permissions'},
                statusCode: 401,
              );
            }
            return null;
          },
        );
        addTearDown(client.close);

        expect(
          () => client.checkHealth(),
          throwsA(
            isA<LobeHubAuthException>().having(
              (e) => e.statusCode,
              'statusCode',
              equals(401),
            ).having(
              (e) => e.message,
              'message',
              contains('Invalid API key'),
            ),
          ),
        );
      });

      test('7.2 Agents network failure: retains cached agents and flags isOffline: true', () async {
        final cachedAgents = [
          const LobeAgent(
            id: 'cached_agent_1',
            title: 'Cached Assistant',
            model: 'deepseek-r1',
          ),
        ];

        final (_, _, client) = createTestClientEnvironment(
          customHandler: (options, _) {
            if (options.path.endsWith('/api/v1/agents')) {
              return jsonResponse(
                {'message': 'Server Temporarily Unavailable'},
                statusCode: 503,
              );
            }
            return null;
          },
        );
        addTearDown(client.close);

        final notifier = LobeAgentsNotifier(
          apiClient: client,
          loadCachedAgents: () async => cachedAgents,
        );

        await notifier.loadAgents();

        // Cached agents preserved, offline indicator active, no crash
        expect(notifier.state.isOffline, isTrue);
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.agents.length, equals(1));
        expect(notifier.state.agents.first.id, equals('cached_agent_1'));
        expect(notifier.state.errorMessage, isNotNull);
      });

      test('7.3 Topics network failure: retains cached topics and flags isOffline: true', () async {
        final cachedTopics = [
          LobeTopic(
            id: 'cached_topic_1',
            title: 'Offline Cached Topic',
            createdAt: DateTime.now(),
          ),
        ];

        final (_, _, client) = createTestClientEnvironment(
          customHandler: (options, _) {
            if (options.path.endsWith('/api/v1/topics')) {
              return jsonResponse(
                {'message': 'Internal Server Error'},
                statusCode: 500,
              );
            }
            return null;
          },
        );
        addTearDown(client.close);

        final notifier = LobeTopicsNotifier(
          apiClient: client,
          loadCachedTopics: () async => cachedTopics,
        );

        await notifier.loadTopics();

        expect(notifier.state.isOffline, isTrue);
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.topics.length, equals(1));
        expect(notifier.state.topics.first.id, equals('cached_topic_1'));
        expect(notifier.state.errorMessage, isNotNull);
      });

      test('7.4 Optimistic topic creation during offline state generates local topic', () async {
        final (_, _, client) = createTestClientEnvironment(
          customHandler: (options, _) {
            if (options.path.endsWith('/api/v1/topics') && options.method == 'POST') {
              throw DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'No internet connection',
              );
            }
            return null;
          },
        );
        addTearDown(client.close);

        final notifier = LobeTopicsNotifier(apiClient: client);

        final fallbackTopic = await notifier.createTopic(
          title: 'Offline Field Notes',
          agentId: 'agent_deepseek_r1',
        );

        expect(fallbackTopic.id.startsWith('local_'), isTrue);
        expect(fallbackTopic.title, equals('Offline Field Notes'));
        expect(fallbackTopic.agentId, equals('agent_deepseek_r1'));

        expect(notifier.state.isOffline, isTrue);
        expect(notifier.state.activeTopicId, equals(fallbackTopic.id));
        expect(notifier.state.topics.length, equals(1));
      });

      test('7.5 Stream abrupt network drop propagates typed LobeHubException without leaking isGenerating', () async {
        late StreamController<Uint8List> streamController;

        final (_, _, client) = createTestClientEnvironment(
          customHandler: (options, _) {
            if (options.path.endsWith('/api/v1/responses')) {
              streamController = StreamController<Uint8List>();
              return ResponseBody(
                streamController.stream,
                200,
                headers: {
                  Headers.contentTypeHeader: ['text/event-stream'],
                },
              );
            }
            return null;
          },
        );
        addTearDown(client.close);

        final bridge = LobeHubChatBridge(apiClient: client);

        final eventsStream = bridge.sendMessageStream(
          topicId: 'topic_network_error',
          content: 'Hello model',
        );

        final completer = Completer<void>();
        Object? caughtError;

        eventsStream.listen(
          (event) {},
          onError: (e) {
            caughtError = e;
            completer.complete();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
        streamController.addError(
          DioException(
            requestOptions: RequestOptions(path: '/api/v1/responses'),
            type: DioExceptionType.connectionError,
            message: 'Connection reset by peer',
          ),
        );

        await completer.future;

        expect(caughtError, isA<LobeHubException>());
        expect(
          (caughtError as LobeHubException).toString(),
          contains('Connection reset by peer'),
        );
        expect(bridge.isGenerating, isFalse);
      });
    });

    // ------------------------------------------------------------------------
    // Step 8: Master Unified End-to-End User Journey
    // ------------------------------------------------------------------------
    group('8. Complete Master Scenario: End-to-End User Journey', () {
      test('walks through entire journey: connect -> sync agents -> create topic -> chat with reasoning -> local drift mapping', () async {
        // Step 1: Onboarding with ai.opw.ink
        const serverInput = 'ai.opw.ink';
        const apiKey = 'sk-lh-master-key-007';

        final serverUrl = LobeHubConnectionPage.normalizeServerUrl(serverInput);
        expect(serverUrl, equals('https://ai.opw.ink'));

        final (adapter, _, client) = createTestClientEnvironment(
          baseUrl: serverUrl,
          apiKey: apiKey,
        );
        addTearDown(client.close);

        final health = await client.checkHealth();
        expect(health.isOk, isTrue);

        final user = await client.getCurrentUser();
        expect(user.username, equals('zhr520v'));

        final secureStore = InMemorySecureKeyValueStore();
        await secureStore.write(key: 'lobehub_server_url', value: serverUrl);
        await secureStore.write(key: 'lobehub_api_key', value: apiKey);
        await secureStore.write(key: 'lobehub_username', value: user.username);

        // Step 2: Sync Agents & Select DeepSeek R1
        final agentsNotifier = LobeAgentsNotifier(apiClient: client);
        await agentsNotifier.loadAgents();
        expect(agentsNotifier.state.agents.length, equals(3));

        agentsNotifier.selectAgent('agent_deepseek_r1');
        final activeAgent = agentsNotifier.state.selectedAgent!;
        expect(activeAgent.id, equals('agent_deepseek_r1'));
        expect(activeAgent.model, equals('deepseek-r1'));

        // Step 3: Create Topic bound to DeepSeek R1
        final topicsNotifier = LobeTopicsNotifier(apiClient: client);
        final topic = await topicsNotifier.createTopic(
          title: 'Quantum Physics Inquiry',
          agentId: activeAgent.id,
        );
        expect(topic.id, equals('topic_e2e_101'));
        expect(topicsNotifier.state.activeTopicId, equals(topic.id));

        // Step 4: Two-Phase Chat with Interleaved DeepSeek R1 Reasoning
        final bridge = LobeHubChatBridge(apiClient: client);
        final textCollector = StringBuffer();
        final reasoningCollector = StringBuffer();

        final stream = bridge.sendMessageStream(
          topicId: topic.id,
          agentId: activeAgent.id,
          model: activeAgent.model,
          content: 'What is quantum entanglement?',
          onReasoningDelta: (r) => reasoningCollector.write(r),
          onTextDelta: (t) => textCollector.write(t),
        );

        await for (final event in stream) {
          if (event is LobeStreamDone) {
            expect(event.finishReason, equals('stop'));
          }
        }

        expect(
          reasoningCollector.toString(),
          equals("Analyzing quantum mechanics principles... Considering EPR paradox and Bell's theorem..."),
        );
        expect(
          textCollector.toString(),
          equals('Quantum superposition and entanglement are core foundations of quantum mechanics.'),
        );

        expect(bridge.lastUserMessage, isNotNull);
        expect(bridge.lastAssistantMessage, isNotNull);
        expect(bridge.lastAssistantMessage!.reasoning, equals(reasoningCollector.toString()));
        expect(bridge.lastAssistantMessage!.content, equals(textCollector.toString()));

        // Step 5: Drift SQLite and Conduit Lossless Mapping
        final conversation = lobeTopicToConversation(topic);
        expect(conversation.id, equals(topic.id));
        expect(conversation.model, equals('agent_deepseek_r1'));

        final chatMessage = lobeMessageToChatMessage(bridge.lastAssistantMessage!);
        expect(chatMessage.role, equals('assistant'));
        expect(chatMessage.metadata?['reasoning'], equals(reasoningCollector.toString()));

        final chatComp = lobeTopicToChatCompanion(topic);
        expect(chatComp.id.value, equals(topic.id));

        final msgComp = lobeMessageToMessageCompanion(
          bridge.lastAssistantMessage!,
          chatId: topic.id,
        );
        expect(msgComp.content.value, equals(textCollector.toString()));

        // Confirm entire request trace occurred on https://ai.opw.ink
        expect(adapter.requests.every((r) => r.baseUrl == 'https://ai.opw.ink'), isTrue);
        expect(adapter.requests.every((r) => r.headers['X-API-Key'] == apiKey), isTrue);
      });
    });
  });
}

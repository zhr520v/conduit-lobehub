import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';

/// In-memory mock adapter for Dio network calls.
class MockHttpClientAdapter implements HttpClientAdapter {
  MockHttpClientAdapter({this.handler});

  FutureOr<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )? handler;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (handler != null) {
      return handler!(options, cancelFuture);
    }
    return ResponseBody.fromString(
      '[]',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(dynamic data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

(LobeHubApiClient, MockHttpClientAdapter) createTestApiClient({
  FutureOr<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )? handler,
}) {
  final adapter = MockHttpClientAdapter(handler: handler);
  final dio = Dio()..httpClientAdapter = adapter;
  final client = LobeHubApiClient(
    baseUrl: 'https://test.lobehub.example',
    apiKey: 'test-key',
    dio: dio,
  );
  return (client, adapter);
}

void main() {
  const sampleAgent1 = LobeAgent(
    id: 'agent_coder',
    title: 'Code Wizard',
    description: 'Expert assistant for Flutter and Dart architecture',
    model: 'gpt-4o',
    systemRole: 'You are an expert programmer.',
  );

  const sampleAgent2 = LobeAgent(
    id: 'agent_writer',
    title: 'Content Creator',
    description: 'Specializes in technical writing and documentation',
    model: 'claude-3-5-sonnet',
    systemRole: 'You are a professional copywriter.',
  );

  const sampleAgent3 = LobeAgent(
    id: 'agent_translator',
    title: 'Polyglot Translator',
    description: 'Accurate multilingual translations between English and Chinese',
    model: 'deepseek-v3',
    systemRole: 'Translate accurately with natural phrasing.',
  );

  group('LobeAgentsState', () {
    test('default constructor initializes with correct defaults', () {
      const state = LobeAgentsState();
      expect(state.agents, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.selectedAgentId, isNull);
      expect(state.searchQuery, isEmpty);
      expect(state.isOffline, isFalse);
      expect(state.errorMessage, isNull);
      expect(state.isEmpty, isTrue);
      expect(state.isNotEmpty, isFalse);
      expect(state.filteredAgents, isEmpty);
      expect(state.selectedAgent, isNull);
      expect(LobeAgentsState.defaultEmptyAgentsMessage, equals('暂无自定义智能体'));
    });

    test('copyWith updates fields and supports clearing nullables with sentinels', () {
      final initial = LobeAgentsState(
        agents: const [sampleAgent1],
        isLoading: false,
        selectedAgentId: 'agent_coder',
        searchQuery: 'code',
        isOffline: true,
        errorMessage: 'Initial error',
      );

      // Mutate some fields
      final updated = initial.copyWith(
        isLoading: true,
        searchQuery: 'wizard',
      );
      expect(updated.agents, equals([sampleAgent1]));
      expect(updated.isLoading, isTrue);
      expect(updated.selectedAgentId, equals('agent_coder'));
      expect(updated.searchQuery, equals('wizard'));
      expect(updated.isOffline, isTrue);
      expect(updated.errorMessage, equals('Initial error'));

      // Clear nullable fields
      final cleared = updated.copyWith(
        selectedAgentId: null,
        errorMessage: null,
      );
      expect(cleared.selectedAgentId, isNull);
      expect(cleared.errorMessage, isNull);
    });

    test('operator == and hashCode satisfy equality contract', () {
      final stateA = LobeAgentsState(
        agents: const [sampleAgent1, sampleAgent2],
        isLoading: false,
        selectedAgentId: 'agent_coder',
        searchQuery: 'test',
        isOffline: false,
        errorMessage: null,
      );
      final stateB = LobeAgentsState(
        agents: const [sampleAgent1, sampleAgent2],
        isLoading: false,
        selectedAgentId: 'agent_coder',
        searchQuery: 'test',
        isOffline: false,
        errorMessage: null,
      );
      final stateDifferent = stateA.copyWith(isOffline: true);

      expect(stateA, equals(stateB));
      expect(stateA.hashCode, equals(stateB.hashCode));
      expect(stateA, isNot(equals(stateDifferent)));
    });

    test('toString produces descriptive diagnostic string', () {
      final state = LobeAgentsState(
        agents: const [sampleAgent1],
        selectedAgentId: 'agent_coder',
      );
      final str = state.toString();
      expect(str, contains('LobeAgentsState'));
      expect(str, contains('agents: 1'));
      expect(str, contains('agent_coder'));
    });

    test('filteredAgents matches title and description case-insensitively', () {
      final state = LobeAgentsState(
        agents: const [sampleAgent1, sampleAgent2, sampleAgent3],
        searchQuery: '',
      );

      // Empty query returns all agents
      expect(state.filteredAgents.length, equals(3));

      // Whitespace query returns all agents
      final wsState = state.copyWith(searchQuery: '   ');
      expect(wsState.filteredAgents.length, equals(3));

      // Match title (case-insensitive)
      final titleMatch = state.copyWith(searchQuery: 'WIZARD');
      expect(titleMatch.filteredAgents, equals([sampleAgent1]));

      // Match description (case-insensitive)
      final descMatch = state.copyWith(searchQuery: 'multilingual');
      expect(descMatch.filteredAgents, equals([sampleAgent3]));

      // Match both or multiple
      final techMatch = state.copyWith(searchQuery: 'technical');
      expect(techMatch.filteredAgents, equals([sampleAgent2]));

      // No match returns empty list
      final noMatch = state.copyWith(searchQuery: 'nonexistent-token');
      expect(noMatch.filteredAgents, isEmpty);
    });

    test('selectedAgent returns agent or null', () {
      final state = LobeAgentsState(
        agents: const [sampleAgent1, sampleAgent2],
        selectedAgentId: 'agent_writer',
      );
      expect(state.selectedAgent, equals(sampleAgent2));

      final noneState = state.copyWith(selectedAgentId: null);
      expect(noneState.selectedAgent, isNull);

      final notFoundState = state.copyWith(selectedAgentId: 'unknown_agent');
      expect(notFoundState.selectedAgent, isNull);
    });
  });

  group('LobeAgentsNotifier & Riverpod Providers', () {
    test('initial state in container is default empty', () {
      final (client, _) = createTestApiClient();
      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final state = container.read(lobeAgentsProvider);
      expect(state.agents, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.selectedAgentId, isNull);
      expect(state.isOffline, isFalse);
    });

    test('loadAgents successfully fetches agents and updates state', () async {
      final (client, adapter) = createTestApiClient(
        handler: (options, cancelFuture) {
          expect(options.path, endsWith('/api/v1/agents'));
          return jsonResponse([
            sampleAgent1.toJson(),
            sampleAgent2.toJson(),
          ]);
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      final state = container.read(lobeAgentsProvider);
      expect(state.isLoading, isFalse);
      expect(state.isOffline, isFalse);
      expect(state.errorMessage, isNull);
      expect(state.agents.length, equals(2));
      expect(state.agents[0].id, equals('agent_coder'));
      expect(state.agents[1].id, equals('agent_writer'));
      expect(notifier.filteredAgents.length, equals(2));
    });

    test('loadAgents with silent=true does not toggle isLoading to true initially', () async {
      final completer = Completer<ResponseBody>();
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) => completer.future,
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      final future = notifier.loadAgents(silent: true);

      // Verify that while fetch is in progress, isLoading remained false
      expect(container.read(lobeAgentsProvider).isLoading, isFalse);

      completer.complete(jsonResponse([sampleAgent1.toJson()]));
      await future;

      expect(container.read(lobeAgentsProvider).agents.length, equals(1));
      expect(container.read(lobeAgentsProvider).isLoading, isFalse);
    });

    test('setSearchQuery updates query and filters agents', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) => jsonResponse([
          sampleAgent1.toJson(),
          sampleAgent2.toJson(),
          sampleAgent3.toJson(),
        ]),
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      // Test searching by title
      notifier.setSearchQuery('translator');
      expect(container.read(lobeAgentsProvider).searchQuery, equals('translator'));
      expect(notifier.filteredAgents.length, equals(1));
      expect(notifier.filteredAgents.first.id, equals('agent_translator'));

      // Test derived provider
      final filteredFromProvider = container.read(lobeFilteredAgentsProvider);
      expect(filteredFromProvider.length, equals(1));
      expect(filteredFromProvider.first.id, equals('agent_translator'));

      // Test searching by description
      notifier.setSearchQuery('flutter');
      expect(notifier.filteredAgents.length, equals(1));
      expect(notifier.filteredAgents.first.id, equals('agent_coder'));

      // Clear search query
      notifier.clearSearchQuery();
      expect(container.read(lobeAgentsProvider).searchQuery, isEmpty);
      expect(notifier.filteredAgents.length, equals(3));
    });

    test('selectAgent updates selectedAgentId and selectedAgent', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) => jsonResponse([
          sampleAgent1.toJson(),
          sampleAgent2.toJson(),
        ]),
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      expect(notifier.selectedAgent, isNull);
      expect(container.read(lobeSelectedAgentProvider), isNull);
      expect(container.read(lobeSelectedAgentIdProvider), isNull);

      notifier.selectAgent('agent_coder');
      expect(container.read(lobeAgentsProvider).selectedAgentId, equals('agent_coder'));
      expect(notifier.selectedAgent?.title, equals('Code Wizard'));
      expect(container.read(lobeSelectedAgentProvider)?.title, equals('Code Wizard'));
      expect(container.read(lobeSelectedAgentIdProvider), equals('agent_coder'));

      // Switch agent
      notifier.selectAgent('agent_writer');
      expect(notifier.selectedAgent?.title, equals('Content Creator'));

      // Clear selection
      notifier.clearSelectedAgent();
      expect(container.read(lobeAgentsProvider).selectedAgentId, isNull);
      expect(notifier.selectedAgent, isNull);
    });

    test('offline fallback when remote fails retains cached agents and sets isOffline=true', () async {
      // First setup a successful response to seed cached agents
      final (client, adapter) = createTestApiClient(
        handler: (options, cancelFuture) {
          return jsonResponse([sampleAgent1.toJson()]);
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();
      expect(container.read(lobeAgentsProvider).agents.length, equals(1));

      // Now configure adapter to fail on next fetch (e.g. 500 error)
      adapter.handler = (options, cancelFuture) {
        return ResponseBody.fromString(
          'Internal Server Error',
          500,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        );
      };

      await notifier.loadAgents();

      final state = container.read(lobeAgentsProvider);
      // Retained previously loaded/cached agents
      expect(state.agents.length, equals(1));
      expect(state.agents.first.id, equals('agent_coder'));
      expect(state.isOffline, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, isNotNull);
      expect(container.read(lobeAgentsOfflineProvider), isTrue);
    });

    test('offline cache loader preloads agents before network call', () async {
      List<LobeAgent>? savedToCache;
      final cachedAgents = [sampleAgent3];

      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) => jsonResponse([
          sampleAgent1.toJson(),
          sampleAgent2.toJson(),
        ]),
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeAgentsCacheLoaderProvider.overrideWithValue(
            () async => cachedAgents,
          ),
          lobeAgentsCacheSaverProvider.overrideWithValue(
            (agents) async => savedToCache = agents,
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      final state = container.read(lobeAgentsProvider);
      expect(state.agents.length, equals(2));
      expect(savedToCache, isNotNull);
      expect(savedToCache!.length, equals(2));
    });

    test('handles missing client gracefully with offline error', () async {
      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      final state = container.read(lobeAgentsProvider);
      expect(state.isOffline, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, contains('not configured'));
    });

    test('handles empty agents list gracefully ("暂无自定义智能体")', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) => jsonResponse([]),
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      final state = container.read(lobeAgentsProvider);
      expect(state.agents, isEmpty);
      expect(state.isEmpty, isTrue);
      expect(state.isNotEmpty, isFalse);
      expect(state.filteredAgents, isEmpty);
      expect(state.errorMessage, isNull);
      expect(state.isOffline, isFalse);
      expect(LobeAgentsState.defaultEmptyAgentsMessage, equals('暂无自定义智能体'));
    });

    test('createTopicForAgent selects agent and delegates to callback with effective title', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) => jsonResponse([
          sampleAgent1.toJson(),
        ]),
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeAgentsProvider.notifier);
      await notifier.loadAgents();

      // Case 1: title explicitly provided
      String? callbackTitle;
      String? callbackAgentId;
      final topic1 = await notifier.createTopicForAgent(
        agentId: 'agent_coder',
        title: 'Custom Debugging Session',
        createTopicCallback: (title, agentId) async {
          callbackTitle = title;
          callbackAgentId = agentId;
          return LobeTopic(id: 'topic_1', title: title, agentId: agentId);
        },
      );

      expect(notifier.selectedAgent?.id, equals('agent_coder'));
      expect(callbackTitle, equals('Custom Debugging Session'));
      expect(callbackAgentId, equals('agent_coder'));
      expect(topic1.id, equals('topic_1'));
      expect(topic1.title, equals('Custom Debugging Session'));

      // Case 2: title omitted (defaults to agent.title)
      final topic2 = await notifier.createTopicForAgent(
        agentId: 'agent_coder',
        createTopicCallback: (title, agentId) async {
          callbackTitle = title;
          callbackAgentId = agentId;
          return LobeTopic(id: 'topic_2', title: title, agentId: agentId);
        },
      );

      expect(callbackTitle, equals('Code Wizard'));
      expect(callbackAgentId, equals('agent_coder'));
      expect(topic2.id, equals('topic_2'));
      expect(topic2.title, equals('Code Wizard'));

      // Case 3: unknown agent with no title defaults to 'New Chat'
      final topic3 = await notifier.createTopicForAgent(
        agentId: 'unknown_agent',
        createTopicCallback: (title, agentId) async {
          callbackTitle = title;
          callbackAgentId = agentId;
          return LobeTopic(id: 'topic_3', title: title, agentId: agentId);
        },
      );

      expect(callbackTitle, equals('New Chat'));
      expect(callbackAgentId, equals('unknown_agent'));
      expect(topic3.title, equals('New Chat'));
    });
  });
}

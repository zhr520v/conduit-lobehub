import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/providers/providers.dart';
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
  final sampleTopic1 = LobeTopic(
    id: 'topic_1',
    title: 'Flutter Architecture Review',
    agentId: 'agent_coder',
    favorite: false,
    createdAt: DateTime.parse('2026-03-01T10:00:00Z'),
    updatedAt: DateTime.parse('2026-03-01T10:30:00Z'),
  );

  final sampleTopic2 = LobeTopic(
    id: 'topic_2',
    title: 'Riverpod 3 Migration Plan',
    agentId: 'agent_architect',
    favorite: true,
    createdAt: DateTime.parse('2026-03-02T11:00:00Z'),
    updatedAt: DateTime.parse('2026-03-02T11:45:00Z'),
  );

  final sampleTopic3 = LobeTopic(
    id: 'topic_3',
    title: 'LobeHub Two-Phase Protocol',
    agentId: 'agent_designer',
    favorite: true,
    createdAt: DateTime.parse('2026-03-03T14:00:00Z'),
    updatedAt: DateTime.parse('2026-03-03T15:20:00Z'),
  );

  final sampleMessage1 = LobeMessage(
    id: 'msg_1',
    topicId: 'topic_1',
    role: 'user',
    content: 'How should we structure state providers?',
    createdAt: DateTime.parse('2026-03-01T10:01:00Z'),
  );

  final sampleMessage2 = LobeMessage(
    id: 'msg_2',
    topicId: 'topic_1',
    role: 'assistant',
    content: 'Use pure Dart Notifier with cache-first sync.',
    createdAt: DateTime.parse('2026-03-01T10:02:00Z'),
  );

  group('LobeTopicsState', () {
    test('default constructor initializes with valid initial values', () {
      const state = LobeTopicsState();
      expect(state.topics, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.activeTopicId, isNull);
      expect(state.isOffline, isFalse);
      expect(state.errorMessage, isNull);
      expect(state.activeMessages, isEmpty);
      expect(state.messagesCache, isEmpty);
      expect(state.hasActiveTopic, isFalse);
      expect(state.activeTopic, isNull);
      expect(state.favoriteTopics, isEmpty);
    });

    test('copyWith updates state and clears nullable fields via sentinels', () {
      final initial = LobeTopicsState(
        topics: [sampleTopic1],
        isLoading: false,
        activeTopicId: 'topic_1',
        isOffline: true,
        errorMessage: 'Connection lost',
        activeMessages: [sampleMessage1],
        messagesCache: {'topic_1': [sampleMessage1]},
      );

      final updated = initial.copyWith(
        isLoading: true,
        isOffline: false,
      );
      expect(updated.topics, equals([sampleTopic1]));
      expect(updated.isLoading, isTrue);
      expect(updated.activeTopicId, equals('topic_1'));
      expect(updated.isOffline, isFalse);
      expect(updated.errorMessage, equals('Connection lost'));

      // Clear nullable activeTopicId and errorMessage
      final cleared = updated.copyWith(
        activeTopicId: null,
        errorMessage: null,
      );
      expect(cleared.activeTopicId, isNull);
      expect(cleared.errorMessage, isNull);
    });

    test('activeTopic and favoriteTopics getters return expected items', () {
      final state = LobeTopicsState(
        topics: [sampleTopic1, sampleTopic2, sampleTopic3],
        activeTopicId: 'topic_2',
      );

      expect(state.hasActiveTopic, isTrue);
      expect(state.activeTopic, equals(sampleTopic2));
      expect(state.favoriteTopics, equals([sampleTopic2, sampleTopic3]));
    });

    test('operator == and hashCode satisfy equality contracts', () {
      final stateA = LobeTopicsState(
        topics: [sampleTopic1, sampleTopic2],
        isLoading: false,
        activeTopicId: 'topic_1',
        isOffline: false,
        activeMessages: [sampleMessage1],
        messagesCache: {'topic_1': [sampleMessage1]},
      );
      final stateB = LobeTopicsState(
        topics: [sampleTopic1, sampleTopic2],
        isLoading: false,
        activeTopicId: 'topic_1',
        isOffline: false,
        activeMessages: [sampleMessage1],
        messagesCache: {'topic_1': [sampleMessage1]},
      );
      final stateDifferent = stateA.copyWith(isOffline: true);

      expect(stateA, equals(stateB));
      expect(stateA.hashCode, equals(stateB.hashCode));
      expect(stateA, isNot(equals(stateDifferent)));
    });

    test('toString provides informative debugging representation', () {
      final state = LobeTopicsState(
        topics: [sampleTopic1],
        activeTopicId: 'topic_1',
      );
      expect(state.toString(), contains('LobeTopicsState'));
      expect(state.toString(), contains('topics: 1'));
      expect(state.toString(), contains('activeTopicId: topic_1'));
    });
  });

  group('InMemoryLobeTopicsCache', () {
    test('supports saving, loading, and deleting cached topics and messages', () async {
      final cache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
        initialMessages: {'topic_1': [sampleMessage1, sampleMessage2]},
      );

      final loadedTopics = await cache.loadCachedTopics();
      expect(loadedTopics, equals([sampleTopic1]));

      final loadedMessages = await cache.loadCachedMessages('topic_1', limit: 1);
      expect(loadedMessages.length, equals(1));
      expect(loadedMessages.first, equals(sampleMessage2));

      await cache.saveCachedTopics([sampleTopic1, sampleTopic2]);
      expect((await cache.loadCachedTopics()).length, equals(2));

      await cache.deleteCachedTopic('topic_1');
      final afterDelete = await cache.loadCachedTopics();
      expect(afterDelete, equals([sampleTopic2]));
      expect(await cache.loadCachedMessages('topic_1'), isEmpty);
    });
  });

  group('LobeTopicsNotifier & Riverpod Providers', () {
    test('initial state in container is default empty', () {
      final (client, _) = createTestApiClient();
      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final state = container.read(lobeTopicsProvider);
      expect(state.topics, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.activeTopicId, isNull);
      expect(state.isOffline, isFalse);
    });

    test('loadTopics with cache-first loads cache immediately then syncs remote', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
      );

      final (client, adapter) = createTestApiClient(
        handler: (options, cancelFuture) {
          expect(options.path, endsWith('/api/v1/topics'));
          return jsonResponse([
            sampleTopic1.toJson(),
            sampleTopic2.toJson(),
          ]);
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();

      final state = container.read(lobeTopicsProvider);
      expect(state.isLoading, isFalse);
      expect(state.isOffline, isFalse);
      expect(state.topics.length, equals(2));
      expect(state.topics[0].id, equals('topic_1'));
      expect(state.topics[1].id, equals('topic_2'));

      // Check that local cache was updated with the remote topics
      final cached = await localCache.loadCachedTopics();
      expect(cached.length, equals(2));
    });

    test('loadTopics with silent: true does not flash isLoading flag', () async {
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

      final notifier = container.read(lobeTopicsProvider.notifier);
      final future = notifier.loadTopics(silent: true);

      // Verify that isLoading stayed false
      expect(container.read(lobeTopicsProvider).isLoading, isFalse);

      completer.complete(jsonResponse([sampleTopic1.toJson()]));
      await future;

      final state = container.read(lobeTopicsProvider);
      expect(state.topics.length, equals(1));
      expect(state.isLoading, isFalse);
    });

    test('loadTopics falls back to offline mode gracefully on network failure', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
      );

      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'Connection refused',
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();

      final state = container.read(lobeTopicsProvider);
      // Preserved cached topics without failing!
      expect(state.topics, equals([sampleTopic1]));
      expect(state.isLoading, isFalse);
      expect(state.isOffline, isTrue);
      expect(state.errorMessage, contains('Connection refused'));
    });

    test('loadTopics marks isOffline: true when apiClient is not configured', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic2],
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(null),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();

      final state = container.read(lobeTopicsProvider);
      expect(state.topics, equals([sampleTopic2]));
      expect(state.isLoading, isFalse);
      expect(state.isOffline, isTrue);
    });

    test('selectTopic provides 0ms transition from cache and updates from server', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
        initialMessages: {'topic_1': [sampleMessage1]},
      );

      final (client, adapter) = createTestApiClient(
        handler: (options, cancelFuture) {
          expect(options.path, endsWith('/api/v1/messages'));
          expect(options.queryParameters['topicId'], equals('topic_1'));
          return jsonResponse([
            sampleMessage1.toJson(),
            sampleMessage2.toJson(),
          ]);
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.selectTopic('topic_1');

      final state = container.read(lobeTopicsProvider);
      expect(state.activeTopicId, equals('topic_1'));
      expect(state.activeMessages.length, equals(2));
      expect(state.activeMessages[1].id, equals('msg_2'));

      // Verify cached messages in storage
      final storedMessages = await localCache.loadCachedMessages('topic_1');
      expect(storedMessages.length, equals(2));
    });

    test('selectTopic handles network failure gracefully by retaining cached messages', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
        initialMessages: {'topic_1': [sampleMessage1]},
      );

      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
            error: 'Timeout fetching messages',
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.selectTopic('topic_1');

      final state = container.read(lobeTopicsProvider);
      expect(state.activeTopicId, equals('topic_1'));
      // Kept cached message
      expect(state.activeMessages, equals([sampleMessage1]));
      expect(state.isOffline, isTrue);
    });

    test('createTopic calls server, appends to state, and activates new topic', () async {
      final createdTopic = LobeTopic(
        id: 'topic_new_99',
        title: 'New Discussion Thread',
        agentId: 'agent_coder',
        createdAt: DateTime.parse('2026-03-04T12:00:00Z'),
      );

      final (client, adapter) = createTestApiClient(
        handler: (options, cancelFuture) {
          expect(options.path, endsWith('/api/v1/topics'));
          expect(options.method, equals('POST'));
          final body = options.data is String ? jsonDecode(options.data) : options.data;
          expect(body['title'], equals('New Discussion Thread'));
          expect(body['agentId'], equals('agent_coder'));
          return jsonResponse(createdTopic.toJson(), statusCode: 201);
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      final result = await notifier.createTopic(
        title: 'New Discussion Thread',
        agentId: 'agent_coder',
      );

      expect(result.id, equals('topic_new_99'));

      final state = container.read(lobeTopicsProvider);
      expect(state.activeTopicId, equals('topic_new_99'));
      expect(state.topics.first.id, equals('topic_new_99'));
      expect(state.activeMessages, isEmpty);
      expect(state.isOffline, isFalse);
    });

    test('createTopic creates optimistic fallback topic in offline mode', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'No internet',
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      final created = await notifier.createTopic(
        title: 'Offline Draft Topic',
        agentId: 'agent_coder',
      );

      expect(created.title, equals('Offline Draft Topic'));
      expect(created.id, startsWith('local_'));

      final state = container.read(lobeTopicsProvider);
      expect(state.activeTopicId, equals(created.id));
      expect(state.topics.first.id, equals(created.id));
      expect(state.isOffline, isTrue);
    });

    test('deleteTopic removes topic and switches active topic', () async {
      var serverDeleteCalled = false;
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/topics/topic_1') && options.method == 'DELETE') {
            serverDeleteCalled = true;
            return jsonResponse({'success': true});
          }
          if (options.path.endsWith('/api/v1/topics') && options.method == 'GET') {
            return jsonResponse([
              sampleTopic1.toJson(),
              sampleTopic2.toJson(),
            ]);
          }
          if (options.path.endsWith('/api/v1/messages') && options.method == 'GET') {
            final topicId = options.queryParameters['topicId'];
            if (topicId == 'topic_2') {
              return jsonResponse([sampleMessage2.toJson()]);
            }
            return jsonResponse([sampleMessage1.toJson()]);
          }
          return jsonResponse({});
        },
      );

      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1, sampleTopic2],
        initialMessages: {
          'topic_1': [sampleMessage1],
          'topic_2': [sampleMessage2],
        },
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();
      await notifier.selectTopic('topic_2');
      await notifier.selectTopic('topic_1');

      expect(container.read(lobeTopicsProvider).activeTopicId, equals('topic_1'));

      final success = await notifier.deleteTopic('topic_1');
      expect(success, isTrue);
      expect(serverDeleteCalled, isTrue);

      final state = container.read(lobeTopicsProvider);
      expect(state.topics.any((t) => t.id == 'topic_1'), isFalse);
      // Active topic automatically switched to next available topic
      expect(state.activeTopicId, equals('topic_2'));
      expect(state.activeMessages, equals([sampleMessage2]));

      // Verify removal from local cache
      final cached = await localCache.loadCachedTopics();
      expect(cached.any((t) => t.id == 'topic_1'), isFalse);
    });

    test('deleteTopic clears activeTopicId when last topic is deleted', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/topics') && options.method == 'GET') {
            return jsonResponse([sampleTopic1.toJson()]);
          }
          return jsonResponse({'success': true});
        },
      );

      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();
      await notifier.selectTopic('topic_1');

      await notifier.deleteTopic('topic_1');

      final state = container.read(lobeTopicsProvider);
      expect(state.topics, isEmpty);
      expect(state.activeTopicId, isNull);
      expect(state.activeMessages, isEmpty);
    });

    test('updateTopic updates title and favorite status locally and remotely', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          expect(options.path, endsWith('/api/v1/topics/topic_1'));
          expect(options.method, equals('PATCH'));
          final body = options.data is String ? jsonDecode(options.data) : options.data;
          expect(body['title'], equals('Updated Title'));
          expect(body['favorite'], isTrue);

          return jsonResponse(
            sampleTopic1
                .copyWith(title: 'Updated Title', favorite: true)
                .toJson(),
          );
        },
      );

      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();

      final updated = await notifier.updateTopic(
        'topic_1',
        title: 'Updated Title',
        favorite: true,
      );

      expect(updated?.title, equals('Updated Title'));
      expect(updated?.favorite, isTrue);

      final state = container.read(lobeTopicsProvider);
      expect(state.topics.first.title, equals('Updated Title'));
      expect(state.topics.first.favorite, isTrue);
      expect(state.isOffline, isFalse);

      final cached = await localCache.loadCachedTopics();
      expect(cached.first.title, equals('Updated Title'));
      expect(cached.first.favorite, isTrue);
    });

    test('updateTopic maintains local change and marks offline when server call fails', () async {
      final (client, _) = createTestApiClient(
        handler: (options, cancelFuture) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'Server unreachable',
          );
        },
      );

      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
      );

      final container = ProviderContainer(
        overrides: [
          lobeHubApiClientProvider.overrideWithValue(client),
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();

      final updated = await notifier.updateTopic(
        'topic_1',
        title: 'Offline Edited Title',
      );

      expect(updated?.title, equals('Offline Edited Title'));

      final state = container.read(lobeTopicsProvider);
      expect(state.topics.first.title, equals('Offline Edited Title'));
      expect(state.isOffline, isTrue);
    });

    test('appendActiveMessage and clearActiveTopic manage active message state', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1],
      );

      final container = ProviderContainer(
        overrides: [
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();
      await notifier.selectTopic('topic_1');

      await notifier.appendActiveMessage(sampleMessage1);
      expect(container.read(lobeActiveMessagesProvider), equals([sampleMessage1]));

      await notifier.appendActiveMessage(sampleMessage2);
      expect(
        container.read(lobeActiveMessagesProvider),
        equals([sampleMessage1, sampleMessage2]),
      );

      // Updating existing message by id replaces it
      final updatedMsg1 = sampleMessage1.copyWith(content: 'Revised question');
      await notifier.appendActiveMessage(updatedMsg1);
      expect(container.read(lobeActiveMessagesProvider)[0].content, equals('Revised question'));

      notifier.clearActiveTopic();
      expect(container.read(lobeActiveTopicIdProvider), isNull);
      expect(container.read(lobeActiveMessagesProvider), isEmpty);
    });

    test('derived providers expose selected slices of state accurately', () async {
      final localCache = InMemoryLobeTopicsCache(
        initialTopics: [sampleTopic1, sampleTopic2],
      );

      final container = ProviderContainer(
        overrides: [
          lobeTopicsLocalCacheProvider.overrideWithValue(localCache),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(lobeTopicsProvider.notifier);
      await notifier.loadTopics();
      await notifier.selectTopic('topic_2');

      expect(container.read(lobeActiveTopicIdProvider), equals('topic_2'));
      expect(container.read(lobeActiveTopicProvider)?.title, equals('Riverpod 3 Migration Plan'));
      expect(container.read(lobeTopicsLoadingProvider), isFalse);
      expect(container.read(lobeTopicsOfflineProvider), isTrue); // no client
      expect(container.read(lobeFavoriteTopicsProvider), equals([sampleTopic2]));
    });
  });
}

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import '../models/models.dart';
import '../services/lobehub_api_client.dart';
import 'lobehub_agents_provider.dart' show lobeHubApiClientProvider;

export 'lobehub_agents_provider.dart' show lobeHubApiClientProvider;

const Object _sentinel = Object();

/// State representation for LobeHub conversation topics.
@immutable
class LobeTopicsState {
  const LobeTopicsState({
    this.topics = const <LobeTopic>[],
    this.isLoading = false,
    this.activeTopicId,
    this.isOffline = false,
    this.errorMessage,
    this.activeMessages = const <LobeMessage>[],
    this.messagesCache = const <String, List<LobeMessage>>{},
  });

  /// All known conversation topics, ordered by priority / recent activity.
  final List<LobeTopic> topics;

  /// Whether topics are actively loading in the foreground.
  final bool isLoading;

  /// Identifier of the currently active/selected topic.
  final String? activeTopicId;

  /// Whether the client is operating in offline fallback mode.
  final bool isOffline;

  /// Optional error message from the most recent failed operation.
  final String? errorMessage;

  /// Pre-fetched recent messages for the active topic (0ms transition cache).
  final List<LobeMessage> activeMessages;

  /// Map of topicId to cached messages for instantaneous switching.
  final Map<String, List<LobeMessage>> messagesCache;

  /// Convenient lookup for the active topic object.
  LobeTopic? get activeTopic {
    if (activeTopicId == null) return null;
    return topics.firstWhereOrNull((t) => t.id == activeTopicId);
  }

  /// Whether an active topic is currently selected.
  bool get hasActiveTopic => activeTopicId != null;

  /// Favorite / pinned topics.
  List<LobeTopic> get favoriteTopics =>
      topics.where((t) => t.favorite).toList();

  LobeTopicsState copyWith({
    List<LobeTopic>? topics,
    bool? isLoading,
    Object? activeTopicId = _sentinel,
    bool? isOffline,
    Object? errorMessage = _sentinel,
    List<LobeMessage>? activeMessages,
    Map<String, List<LobeMessage>>? messagesCache,
  }) {
    return LobeTopicsState(
      topics: topics ?? this.topics,
      isLoading: isLoading ?? this.isLoading,
      activeTopicId: identical(activeTopicId, _sentinel)
          ? this.activeTopicId
          : activeTopicId as String?,
      isOffline: isOffline ?? this.isOffline,
      errorMessage: identical(errorMessage, _sentinel)
          ? this.errorMessage
          : errorMessage as String?,
      activeMessages: activeMessages ?? this.activeMessages,
      messagesCache: messagesCache ?? this.messagesCache,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeTopicsState &&
          runtimeType == other.runtimeType &&
          const ListEquality<LobeTopic>().equals(topics, other.topics) &&
          isLoading == other.isLoading &&
          activeTopicId == other.activeTopicId &&
          isOffline == other.isOffline &&
          errorMessage == other.errorMessage &&
          const ListEquality<LobeMessage>().equals(
            activeMessages,
            other.activeMessages,
          ) &&
          const MapEquality<String, List<LobeMessage>>(
            values: ListEquality<LobeMessage>(),
          ).equals(messagesCache, other.messagesCache);

  @override
  int get hashCode => Object.hash(
    const ListEquality<LobeTopic>().hash(topics),
    isLoading,
    activeTopicId,
    isOffline,
    errorMessage,
    const ListEquality<LobeMessage>().hash(activeMessages),
    const MapEquality<String, List<LobeMessage>>(
      values: ListEquality<LobeMessage>(),
    ).hash(messagesCache),
  );

  @override
  String toString() =>
      'LobeTopicsState(topics: ${topics.length}, activeTopicId: $activeTopicId, '
      'isLoading: $isLoading, isOffline: $isOffline, errorMessage: $errorMessage, '
      'activeMessages: ${activeMessages.length})';
}

/// Abstract contract for local topic and recent message persistence.
abstract class LobeTopicsLocalCache {
  /// Loads all locally cached topics.
  Future<List<LobeTopic>> loadCachedTopics();

  /// Persists the full list of topics locally.
  Future<void> saveCachedTopics(List<LobeTopic> topics);

  /// Deletes a cached topic and its associated cached messages.
  Future<void> deleteCachedTopic(String topicId);

  /// Loads cached messages for a topic.
  Future<List<LobeMessage>> loadCachedMessages(
    String topicId, {
    int limit = 50,
  });

  /// Saves recent cached messages for a topic.
  Future<void> saveCachedMessages(
    String topicId,
    List<LobeMessage> messages,
  );
}

/// Default in-memory implementation of [LobeTopicsLocalCache].
class InMemoryLobeTopicsCache implements LobeTopicsLocalCache {
  InMemoryLobeTopicsCache({
    List<LobeTopic>? initialTopics,
    Map<String, List<LobeMessage>>? initialMessages,
  })  : _topics = initialTopics != null
            ? List<LobeTopic>.from(initialTopics)
            : <LobeTopic>[],
        _messages = initialMessages != null
            ? Map<String, List<LobeMessage>>.from(
                initialMessages.map(
                  (k, v) => MapEntry(k, List<LobeMessage>.from(v)),
                ),
              )
            : <String, List<LobeMessage>>{};

  final List<LobeTopic> _topics;
  final Map<String, List<LobeMessage>> _messages;

  @override
  Future<List<LobeTopic>> loadCachedTopics() async =>
      List<LobeTopic>.unmodifiable(_topics);

  @override
  Future<void> saveCachedTopics(List<LobeTopic> topics) async {
    _topics
      ..clear()
      ..addAll(topics);
  }

  @override
  Future<void> deleteCachedTopic(String topicId) async {
    _topics.removeWhere((t) => t.id == topicId);
    _messages.remove(topicId);
  }

  @override
  Future<List<LobeMessage>> loadCachedMessages(
    String topicId, {
    int limit = 50,
  }) async {
    final list = _messages[topicId] ?? const <LobeMessage>[];
    if (list.length > limit) {
      return List<LobeMessage>.unmodifiable(list.sublist(list.length - limit));
    }
    return List<LobeMessage>.unmodifiable(list);
  }

  @override
  Future<void> saveCachedMessages(
    String topicId,
    List<LobeMessage> messages,
  ) async {
    _messages[topicId] = List<LobeMessage>.from(messages);
  }
}

/// Riverpod provider for the local topic cache.
final lobeTopicsLocalCacheProvider = Provider<LobeTopicsLocalCache>((ref) {
  return InMemoryLobeTopicsCache();
});

/// Optional provider for a cached topics loader function.
final lobeTopicsCacheLoaderProvider =
    Provider<Future<List<LobeTopic>> Function()?>((ref) => null);

/// Optional provider for a cached topics saver function.
final lobeTopicsCacheSaverProvider =
    Provider<Future<void> Function(List<LobeTopic> topics)?>((ref) => null);

/// Riverpod notifier provider managing LobeHub topics.
final lobeTopicsProvider =
    NotifierProvider<LobeTopicsNotifier, LobeTopicsState>(
  LobeTopicsNotifier.new,
);

/// Derived provider exposing the active topic object.
final lobeActiveTopicProvider = Provider<LobeTopic?>((ref) {
  return ref.watch(lobeTopicsProvider.select((s) => s.activeTopic));
});

/// Derived provider exposing the active topic identifier.
final lobeActiveTopicIdProvider = Provider<String?>((ref) {
  return ref.watch(lobeTopicsProvider.select((s) => s.activeTopicId));
});

/// Derived provider exposing whether topics are currently loading.
final lobeTopicsLoadingProvider = Provider<bool>((ref) {
  return ref.watch(lobeTopicsProvider.select((s) => s.isLoading));
});

/// Derived provider exposing whether topics are in offline mode.
final lobeTopicsOfflineProvider = Provider<bool>((ref) {
  return ref.watch(lobeTopicsProvider.select((s) => s.isOffline));
});

/// Derived provider exposing active topic messages.
final lobeActiveMessagesProvider = Provider<List<LobeMessage>>((ref) {
  return ref.watch(lobeTopicsProvider.select((s) => s.activeMessages));
});

/// Derived provider exposing favorite/pinned topics.
final lobeFavoriteTopicsProvider = Provider<List<LobeTopic>>((ref) {
  return ref.watch(lobeTopicsProvider.select((s) => s.favoriteTopics));
});

/// Riverpod state notifier for LobeHub topic threads.
///
/// Features:
/// - Cache-first loading with silent incremental remote synchronization.
/// - Offline fallback gracefully setting `isOffline: true` on network faults.
/// - Instant 0ms topic switching by loading cached recent messages.
/// - Full CRUD (create, select, update, delete) operations.
class LobeTopicsNotifier extends Notifier<LobeTopicsState> {
  LobeTopicsNotifier({
    LobeHubApiClient? apiClient,
    LobeTopicsLocalCache? localCache,
    Future<List<LobeTopic>> Function()? loadCachedTopics,
    Future<void> Function(List<LobeTopic> topics)? saveCachedTopics,
    LobeTopicsState? initialState,
  })  : _injectedApiClient = apiClient,
        _injectedLocalCache = localCache,
        _injectedLoadCachedTopics = loadCachedTopics,
        _injectedSaveCachedTopics = saveCachedTopics,
        _initialState = initialState;

  final LobeHubApiClient? _injectedApiClient;
  final LobeTopicsLocalCache? _injectedLocalCache;
  final Future<List<LobeTopic>> Function()? _injectedLoadCachedTopics;
  final Future<void> Function(List<LobeTopic> topics)? _injectedSaveCachedTopics;
  final LobeTopicsState? _initialState;

  LobeTopicsState? _manualState;

  @override
  LobeTopicsState build() {
    return _initialState ?? const LobeTopicsState();
  }

  @override
  LobeTopicsState get state {
    try {
      return super.state;
    } catch (_) {
      return _manualState ?? _initialState ?? const LobeTopicsState();
    }
  }

  @override
  set state(LobeTopicsState value) {
    try {
      super.state = value;
    } catch (_) {
      _manualState = value;
    }
  }

  LobeHubApiClient? get _client {
    if (_injectedApiClient != null) return _injectedApiClient;
    try {
      return ref.read(lobeHubApiClientProvider);
    } catch (_) {
      return null;
    }
  }

  LobeTopicsLocalCache get _cache {
    if (_injectedLocalCache != null) return _injectedLocalCache;
    try {
      return ref.read(lobeTopicsLocalCacheProvider);
    } catch (_) {
      return InMemoryLobeTopicsCache();
    }
  }

  Future<List<LobeTopic>> _loadCache() async {
    final loader = _injectedLoadCachedTopics;
    if (loader != null) {
      return await loader();
    }
    try {
      final callback = ref.read(lobeTopicsCacheLoaderProvider);
      if (callback != null) {
        return await callback();
      }
    } catch (_) {}
    return await _cache.loadCachedTopics();
  }

  Future<void> _saveCache(List<LobeTopic> topics) async {
    final saver = _injectedSaveCachedTopics;
    if (saver != null) {
      await saver(topics);
    }
    try {
      final callback = ref.read(lobeTopicsCacheSaverProvider);
      if (callback != null) {
        await callback(topics);
      }
    } catch (_) {}
    await _cache.saveCachedTopics(topics);
  }

  /// Loads topics with a cache-first strategy.
  ///
  /// 1. Immediately restores cached topics from [LobeTopicsLocalCache].
  /// 2. If [silent] is false and no cached topics exist, sets `isLoading: true`.
  /// 3. Asynchronously calls `LobeHubApiClient.getTopics()` for silent sync.
  /// 4. If offline or network call fails, preserves cached topics and sets `isOffline: true`.
  Future<void> loadTopics({bool silent = false}) async {
    if (!silent && state.topics.isEmpty) {
      state = state.copyWith(isLoading: true, errorMessage: null);
    }

    // Step 1: Load cached topics immediately
    try {
      final cachedTopics = await _loadCache();
      if (cachedTopics.isNotEmpty) {
        state = state.copyWith(
          topics: cachedTopics,
          isLoading: silent ? state.isLoading : false,
        );
      }
    } catch (_) {
      // Local cache failure ignored; proceed to remote sync
    }

    final client = _client;
    if (client == null) {
      state = state.copyWith(
        isLoading: false,
        isOffline: true,
      );
      return;
    }

    // Step 2: Asynchronously sync with remote
    try {
      final remoteTopics = await client.getTopics();
      await _saveCache(remoteTopics);
      state = state.copyWith(
        topics: remoteTopics,
        isLoading: false,
        isOffline: false,
        errorMessage: null,
      );
    } catch (e) {
      // Step 3: Offline fallback — keep cached topics and mark offline
      state = state.copyWith(
        isLoading: false,
        isOffline: true,
        errorMessage: e.toString(),
      );
    }
  }

  /// Activates the topic identified by [topicId], pre-fetching/loading recent
  /// messages (up to [messageLimit], default 50) for a 0ms transition.
  Future<void> selectTopic(String topicId, {int messageLimit = 50}) async {
    // 0ms transition: Check in-memory message cache first, then local cache
    List<LobeMessage> messages = state.messagesCache[topicId] ?? const [];
    if (messages.isEmpty) {
      try {
        messages = await _cache.loadCachedMessages(
          topicId,
          limit: messageLimit,
        );
      } catch (_) {
        messages = const [];
      }
    }

    final updatedCache = Map<String, List<LobeMessage>>.from(state.messagesCache);
    if (messages.isNotEmpty) {
      updatedCache[topicId] = messages;
    }

    state = state.copyWith(
      activeTopicId: topicId,
      activeMessages: messages,
      messagesCache: updatedCache,
      errorMessage: null,
    );

    // Asynchronously fetch latest messages from remote
    final client = _client;
    if (client != null) {
      try {
        final remoteMessages = await client.getMessages(
          topicId: topicId,
          pageSize: messageLimit,
        );
        await _cache.saveCachedMessages(topicId, remoteMessages);

        final newCache = Map<String, List<LobeMessage>>.from(state.messagesCache);
        newCache[topicId] = remoteMessages;

        if (state.activeTopicId == topicId) {
          state = state.copyWith(
            activeMessages: remoteMessages,
            messagesCache: newCache,
            isOffline: false,
          );
        } else {
          state = state.copyWith(messagesCache: newCache);
        }
      } catch (e) {
        state = state.copyWith(isOffline: true);
      }
    }
  }

  /// Creates a new topic thread on the server via `POST /api/v1/topics`.
  ///
  /// Appends the topic to state, caches it locally, and activates it.
  /// In offline mode or on network error, creates an optimistic local topic.
  Future<LobeTopic> createTopic({
    required String title,
    String? agentId,
    String? sessionId,
    Map<String, dynamic>? metadata,
  }) async {
    final client = _client;
    if (client != null) {
      try {
        final created = await client.createTopic(
          title: title,
          agentId: agentId,
          sessionId: sessionId,
          metadata: metadata,
        );
        final updatedTopics = <LobeTopic>[
          created,
          ...state.topics.where((t) => t.id != created.id),
        ];
        await _saveCache(updatedTopics);

        final newCache = Map<String, List<LobeMessage>>.from(state.messagesCache);
        newCache[created.id] = const <LobeMessage>[];

        state = state.copyWith(
          topics: updatedTopics,
          activeTopicId: created.id,
          activeMessages: const <LobeMessage>[],
          messagesCache: newCache,
          isOffline: false,
          errorMessage: null,
        );
        return created;
      } catch (e) {
        // Offline / network failure fallback
      }
    }

    // Optimistic fallback topic for offline resilience
    final fallback = LobeTopic(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      agentId: agentId,
      sessionId: sessionId,
      metadata: metadata ?? const <String, dynamic>{},
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final updatedTopics = <LobeTopic>[
      fallback,
      ...state.topics.where((t) => t.id != fallback.id),
    ];
    await _saveCache(updatedTopics);

    final newCache = Map<String, List<LobeMessage>>.from(state.messagesCache);
    newCache[fallback.id] = const <LobeMessage>[];

    state = state.copyWith(
      topics: updatedTopics,
      activeTopicId: fallback.id,
      activeMessages: const <LobeMessage>[],
      messagesCache: newCache,
      isOffline: true,
    );
    return fallback;
  }

  /// Deletes a topic thread identified by [topicId] via `DELETE /api/v1/topics/:id`.
  ///
  /// Removes the topic from state and local cache immediately. If the deleted
  /// topic was active, switches to the next available topic or clears active state.
  Future<bool> deleteTopic(String topicId) async {
    final updatedTopics = state.topics.where((t) => t.id != topicId).toList();
    final newActiveId = (state.activeTopicId == topicId)
        ? (updatedTopics.isNotEmpty ? updatedTopics.first.id : null)
        : state.activeTopicId;

    final newCache = Map<String, List<LobeMessage>>.from(state.messagesCache)
      ..remove(topicId);

    final newActiveMessages = newActiveId != null
        ? (newCache[newActiveId] ?? const <LobeMessage>[])
        : const <LobeMessage>[];

    await _cache.deleteCachedTopic(topicId);
    await _saveCache(updatedTopics);

    state = state.copyWith(
      topics: updatedTopics,
      activeTopicId: newActiveId,
      activeMessages: newActiveMessages,
      messagesCache: newCache,
      errorMessage: null,
    );

    final client = _client;
    if (client != null) {
      try {
        await client.deleteTopic(topicId);
        state = state.copyWith(isOffline: false);
        return true;
      } catch (e) {
        state = state.copyWith(isOffline: true);
        return true;
      }
    }

    return true;
  }

  /// Updates an existing topic identified by [topicId] locally and on the server
  /// via `PATCH /api/v1/topics/:id`.
  Future<LobeTopic?> updateTopic(
    String topicId, {
    String? title,
    bool? favorite,
    Map<String, dynamic>? metadata,
  }) async {
    final index = state.topics.indexWhere((t) => t.id == topicId);
    if (index == -1) return null;

    final existing = state.topics[index];
    final updatedLocal = existing.copyWith(
      title: title ?? existing.title,
      favorite: favorite ?? existing.favorite,
      metadata: metadata != null
          ? <String, dynamic>{...existing.metadata, ...metadata}
          : existing.metadata,
      updatedAt: DateTime.now(),
    );

    final updatedTopics = List<LobeTopic>.from(state.topics);
    updatedTopics[index] = updatedLocal;

    // Optimistic local state update
    state = state.copyWith(
      topics: updatedTopics,
      errorMessage: null,
    );
    await _saveCache(updatedTopics);

    final client = _client;
    if (client != null) {
      try {
        final serverTopic = await client.updateTopic(
          topicId,
          title: title,
          favorite: favorite,
          metadata: metadata,
        );

        final finalTopics = List<LobeTopic>.from(state.topics);
        final serverIdx = finalTopics.indexWhere((t) => t.id == topicId);
        if (serverIdx != -1) {
          finalTopics[serverIdx] = serverTopic;
          state = state.copyWith(
            topics: finalTopics,
            isOffline: false,
          );
          await _saveCache(finalTopics);
        }
        return serverTopic;
      } catch (e) {
        state = state.copyWith(isOffline: true);
        return updatedLocal;
      }
    }

    return updatedLocal;
  }

  /// Appends or updates a message in the active topic's message list.
  Future<void> appendActiveMessage(LobeMessage message) async {
    final activeId = state.activeTopicId;
    if (activeId == null) return;

    final existing = state.activeMessages;
    final updatedMessages = List<LobeMessage>.from(existing);
    final idx = updatedMessages.indexWhere((m) => m.id == message.id);
    if (idx != -1) {
      updatedMessages[idx] = message;
    } else {
      updatedMessages.add(message);
    }

    final newCache = Map<String, List<LobeMessage>>.from(state.messagesCache);
    newCache[activeId] = updatedMessages;

    state = state.copyWith(
      activeMessages: updatedMessages,
      messagesCache: newCache,
    );

    await _cache.saveCachedMessages(activeId, updatedMessages);
  }

  /// Explicitly clears the active topic selection.
  void clearActiveTopic() {
    state = state.copyWith(
      activeTopicId: null,
      activeMessages: const <LobeMessage>[],
    );
  }
}

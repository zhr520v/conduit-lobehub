import 'dart:async';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';

import '../models/lobe_agent.dart';
import '../models/lobe_topic.dart';
import '../services/lobehub_api_client.dart';

const Object _sentinel = Object();

/// Immutable state holding the list of LobeHub agents, selection state,
/// filtering parameters, and network status.
@immutable
class LobeAgentsState {
  const LobeAgentsState({
    this.agents = const <LobeAgent>[],
    this.isLoading = false,
    this.selectedAgentId,
    this.searchQuery = '',
    this.isOffline = false,
    this.errorMessage,
  });

  /// The full list of fetched or cached agents.
  final List<LobeAgent> agents;

  /// Whether an active network fetch or reload is in progress.
  final bool isLoading;

  /// The unique identifier of the currently selected agent, or null if none.
  final String? selectedAgentId;

  /// Current search query string used for client-side agent filtering.
  final String searchQuery;

  /// Indicates whether the provider is operating in offline mode (e.g. network failure).
  final bool isOffline;

  /// Last error message encountered during network or caching operations.
  final String? errorMessage;

  /// Default localized placeholder when no custom agents are present.
  static const String defaultEmptyAgentsMessage = '暂无自定义智能体';

  /// Whether the agents list is completely empty.
  bool get isEmpty => agents.isEmpty;

  /// Whether the agents list contains at least one agent.
  bool get isNotEmpty => agents.isNotEmpty;

  /// Filtered list of agents matching [searchQuery] in title or description (case-insensitive).
  ///
  /// Returns all [agents] if [searchQuery] is empty or whitespace-only.
  List<LobeAgent> get filteredAgents {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return agents;

    return agents.where((agent) {
      final titleMatch =
          agent.title?.toLowerCase().contains(query) ?? false;
      final descriptionMatch =
          agent.description?.toLowerCase().contains(query) ?? false;
      return titleMatch || descriptionMatch;
    }).toList();
  }

  /// The currently selected [LobeAgent], or null if none is selected or found.
  LobeAgent? get selectedAgent {
    if (selectedAgentId == null) return null;
    return agents.firstWhereOrNull((agent) => agent.id == selectedAgentId);
  }

  /// Creates a copy of this state with the given fields replaced.
  LobeAgentsState copyWith({
    List<LobeAgent>? agents,
    bool? isLoading,
    Object? selectedAgentId = _sentinel,
    String? searchQuery,
    bool? isOffline,
    Object? errorMessage = _sentinel,
  }) => LobeAgentsState(
    agents: agents ?? this.agents,
    isLoading: isLoading ?? this.isLoading,
    selectedAgentId: identical(selectedAgentId, _sentinel)
        ? this.selectedAgentId
        : selectedAgentId as String?,
    searchQuery: searchQuery ?? this.searchQuery,
    isOffline: isOffline ?? this.isOffline,
    errorMessage: identical(errorMessage, _sentinel)
        ? this.errorMessage
        : errorMessage as String?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeAgentsState &&
          runtimeType == other.runtimeType &&
          const DeepCollectionEquality().equals(agents, other.agents) &&
          isLoading == other.isLoading &&
          selectedAgentId == other.selectedAgentId &&
          searchQuery == other.searchQuery &&
          isOffline == other.isOffline &&
          errorMessage == other.errorMessage;

  @override
  int get hashCode => Object.hash(
    const DeepCollectionEquality().hash(agents),
    isLoading,
    selectedAgentId,
    searchQuery,
    isOffline,
    errorMessage,
  );

  @override
  String toString() =>
      'LobeAgentsState(agents: ${agents.length}, isLoading: $isLoading, selectedAgentId: $selectedAgentId, searchQuery: "$searchQuery", isOffline: $isOffline, errorMessage: $errorMessage)';
}

/// Provider for supplying the [LobeHubApiClient] to LobeHub feature notifiers.
final lobeHubApiClientProvider = Provider<LobeHubApiClient?>((ref) => null);

/// Provider for an optional cached agents loader callback: `Future<List<LobeAgent>> Function()`.
final lobeAgentsCacheLoaderProvider =
    Provider<Future<List<LobeAgent>> Function()?>((ref) => null);

/// Provider for an optional cached agents saver callback: `Future<void> Function(List<LobeAgent> agents)`.
final lobeAgentsCacheSaverProvider =
    Provider<Future<void> Function(List<LobeAgent> agents)?>((ref) => null);

/// Riverpod [Notifier] managing LobeHub agents, searching, selection, and offline caching.
class LobeAgentsNotifier extends Notifier<LobeAgentsState> {
  LobeAgentsNotifier({
    LobeHubApiClient? apiClient,
    Future<List<LobeAgent>> Function()? loadCachedAgents,
    Future<void> Function(List<LobeAgent> agents)? saveCachedAgents,
    LobeAgentsState? initialState,
  }) : _injectedApiClient = apiClient,
       _injectedLoadCachedAgents = loadCachedAgents,
       _injectedSaveCachedAgents = saveCachedAgents,
       _initialState = initialState;

  final LobeHubApiClient? _injectedApiClient;
  final Future<List<LobeAgent>> Function()? _injectedLoadCachedAgents;
  final Future<void> Function(List<LobeAgent> agents)? _injectedSaveCachedAgents;
  final LobeAgentsState? _initialState;

  @override
  LobeAgentsState build() {
    return _initialState ?? const LobeAgentsState();
  }

  /// The filtered list of agents matching current [LobeAgentsState.searchQuery].
  List<LobeAgent> get filteredAgents => state.filteredAgents;

  /// The currently selected [LobeAgent], or null.
  LobeAgent? get selectedAgent => state.selectedAgent;

  /// Updates the active search query for filtering agents.
  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  /// Clears the active search query.
  void clearSearchQuery() {
    setSearchQuery('');
  }

  /// Sets the currently active agent by [agentId].
  void selectAgent(String agentId) {
    state = state.copyWith(selectedAgentId: agentId);
  }

  /// Clears the active agent selection.
  void clearSelectedAgent() {
    state = state.copyWith(selectedAgentId: null);
  }

  /// Loads agents.
  ///
  /// If [silent] is false (default), sets [LobeAgentsState.isLoading] to true.
  /// First loads cached agents (if any cache loader is configured), then calls
  /// [LobeHubApiClient.getAgents] to update the state with fresh server data.
  /// If the network call fails, retains cached/existing agents and sets [LobeAgentsState.isOffline] to true.
  Future<void> loadAgents({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(isLoading: true, errorMessage: null);
    }

    final cacheLoader =
        _injectedLoadCachedAgents ?? ref.read(lobeAgentsCacheLoaderProvider);
    if (cacheLoader != null) {
      try {
        final cached = await cacheLoader();
        if (ref.mounted && cached.isNotEmpty) {
          state = state.copyWith(agents: cached);
        }
      } catch (_) {
        // Cache read failure is non-fatal; continue with remote fetch.
      }
    }

    final client =
        _injectedApiClient ?? ref.read(lobeHubApiClientProvider);
    if (client == null) {
      if (ref.mounted) {
        state = state.copyWith(
          isLoading: false,
          isOffline: true,
          errorMessage: 'LobeHub API client is not configured',
        );
      }
      return;
    }

    try {
      final remoteAgents = await client.getAgents();
      final cacheSaver =
          _injectedSaveCachedAgents ?? ref.read(lobeAgentsCacheSaverProvider);
      if (cacheSaver != null) {
        try {
          await cacheSaver(remoteAgents);
        } catch (_) {
          // Cache write failure is non-fatal.
        }
      }

      if (ref.mounted) {
        state = state.copyWith(
          agents: remoteAgents,
          isLoading: false,
          isOffline: false,
          errorMessage: null,
        );
      }
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          isLoading: false,
          isOffline: true,
          errorMessage: e.toString(),
        );
      }
    }
  }

  /// Creates a new topic for the given [agentId] using the provided [createTopicCallback].
  ///
  /// Selects the agent as active, resolves an effective title (using [title] or the agent's title),
  /// and invokes [createTopicCallback] to initialize the topic thread.
  Future<LobeTopic> createTopicForAgent({
    required String agentId,
    String? title,
    required Future<LobeTopic> Function(String title, String agentId)
        createTopicCallback,
  }) async {
    selectAgent(agentId);
    final agent = selectedAgent;
    final effectiveTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : (agent?.title != null && agent!.title!.isNotEmpty
            ? agent.title!
            : 'New Chat');

    return await createTopicCallback(effectiveTitle, agentId);
  }
}

/// Main Riverpod provider managing [LobeAgentsState] and [LobeAgentsNotifier].
final lobeAgentsProvider =
    NotifierProvider<LobeAgentsNotifier, LobeAgentsState>(
      LobeAgentsNotifier.new,
    );

/// Derived provider exposing the list of filtered agents based on search query.
final lobeFilteredAgentsProvider = Provider<List<LobeAgent>>((ref) {
  return ref.watch(lobeAgentsProvider.select((s) => s.filteredAgents));
});

/// Derived provider exposing the currently selected agent.
final lobeSelectedAgentProvider = Provider<LobeAgent?>((ref) {
  return ref.watch(lobeAgentsProvider.select((s) => s.selectedAgent));
});

/// Derived provider exposing the active selected agent identifier.
final lobeSelectedAgentIdProvider = Provider<String?>((ref) {
  return ref.watch(lobeAgentsProvider.select((s) => s.selectedAgentId));
});

/// Derived provider exposing whether agents are currently loading.
final lobeAgentsLoadingProvider = Provider<bool>((ref) {
  return ref.watch(lobeAgentsProvider.select((s) => s.isLoading));
});

/// Derived provider exposing whether the agent manager is in offline mode.
final lobeAgentsOfflineProvider = Provider<bool>((ref) {
  return ref.watch(lobeAgentsProvider.select((s) => s.isOffline));
});

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/models/lobe_topic.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_topics_provider.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_mappers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../navigation/providers/conversation_selection_provider.dart';
import '../../navigation/views/main_navigation_shell.dart';

/// State of an in-flight or completed agent chat start operation.
@immutable
class LobehubChatStartState {
  const LobehubChatStartState({
    this.isStarting = false,
    this.error,
  });

  final bool isStarting;
  final String? error;

  LobehubChatStartState copyWith({
    bool? isStarting,
    String? error,
  }) =>
      LobehubChatStartState(
        isStarting: isStarting ?? this.isStarting,
        error: error,
      );
}

/// Provider managing the production Agent-to-chat wiring.
///
/// Features:
/// 1. Creates a server topic thread strictly bound to [chosenAgent.id].
/// 2. Selects the real underlying model separately by BOTH `modelID` + `provider`
///    from the model roster; refuses to inject agents into the roster, fallback
///    to firstAgent, or set `agt_` as model.
/// 3. Preserves `agentId`, `agentTitle`, and `systemRole` inside [Conversation.metadata]
///    for central backend mapper round-trips.
/// 4. Connects seamlessly to [conversationSelectionProvider.select] seam.
/// 5. Preserves authentication context across async boundaries.
/// 6. Surfaces errors via [SnackBar] and prevents navigation tab switching on failure.
final lobehubChatStartProvider =
    NotifierProvider<LobehubChatStartNotifier, LobehubChatStartState>(
  LobehubChatStartNotifier.new,
);

class LobehubChatStartNotifier extends Notifier<LobehubChatStartState> {
  @override
  LobehubChatStartState build() => const LobehubChatStartState();

  /// Starts a new conversation bound to the chosen [agent].
  ///
  /// Returns `true` if the server topic was created and successfully activated,
  /// or `false` if the process failed or was canceled.
  Future<bool> startAgentChat({
    required BuildContext context,
    required LobeAgent agent,
  }) async {
    state = state.copyWith(isStarting: true, error: null);

    // 1. Initial connection & auth check
    LobeHubApiClient? client;
    try {
      client = ref.read(lobeHubApiClientProvider);
    } catch (_) {
      client = null;
    }

    String? initialToken;
    try {
      final initialApi = ref.read(apiServiceProvider);
      initialToken = initialApi?.authToken;
    } catch (_) {
      initialToken = null;
    }

    if (!_isAuthValid()) {
      _reportError(context, 'Authentication required to start chat.');
      return false;
    }

    // 2. Refresh or retrieve full agent details if available
    LobeAgent fullAgent = agent;
    if (client != null) {
      try {
        fullAgent = await client.getAgent(agent.id);
      } catch (_) {
        // Fall back gracefully to provided agent representation
        fullAgent = agent;
      }
    }

    // Verify auth context survived the async call
    if (!context.mounted) return false;
    try {
      final afterApi = ref.read(apiServiceProvider);
      if (initialToken != null && afterApi?.authToken == null) {
        _reportError(context, 'Authentication expired while preparing agent.');
        return false;
      }
    } catch (_) {}

    if (!_isAuthValid()) {
      _reportError(context, 'Authentication expired while preparing agent.');
      return false;
    }

    // 3. Select actual underlying model from roster by BOTH modelID and provider
    final targetModelId = fullAgent.model ?? agent.model;
    final targetProvider = fullAgent.provider ?? agent.provider;

    List<Model> roster = const <Model>[];
    try {
      final modelsAsync = ref.read(modelsProvider);
      roster = modelsAsync.hasValue
          ? modelsAsync.value!
          : await ref.read(modelsProvider.future);
    } catch (_) {}

    Model? resolvedModel;
    if (targetModelId != null && targetModelId.isNotEmpty) {
      // Step A: Priority match by BOTH modelId and provider
      if (targetProvider != null && targetProvider.isNotEmpty) {
        resolvedModel = roster.firstWhereOrNull((m) {
          if (m.id != targetModelId) return false;
          final p = m.metadata?['provider']?.toString() ??
              m.metadata?['providerId']?.toString() ??
              m.metadata?['owned_by']?.toString();
          return p?.toLowerCase() == targetProvider.toLowerCase();
        });
      }
      // Step B: Secondary match by modelId alone
      resolvedModel ??= roster.firstWhereOrNull((m) => m.id == targetModelId);
    }

    // Guard: Do not fallback to firstAgent and do not set `agt_` as model
    if (resolvedModel != null) {
      ref.read(selectedModelProvider.notifier).set(resolvedModel, allowHidden: true);
      ref.read(isManualModelSelectionProvider.notifier).set(true);
    } else if (targetModelId != null &&
        !targetModelId.startsWith('agt_') &&
        targetModelId.isNotEmpty) {
      // Retain true underlying model identifier without setting agt_ as model
      final placeholderModel = Model(
        id: targetModelId,
        name: targetModelId,
        metadata: <String, dynamic>{
          if (targetProvider != null) 'provider': targetProvider,
        },
      );
      ref
          .read(selectedModelProvider.notifier)
          .set(placeholderModel, allowHidden: true);
      ref.read(isManualModelSelectionProvider.notifier).set(true);
    }

    // 4. Create server topic bound to chosenAgent
    final effectiveTitle = (fullAgent.title?.trim().isNotEmpty == true)
        ? fullAgent.title!.trim()
        : (fullAgent.name?.trim().isNotEmpty == true
            ? fullAgent.name!.trim()
            : 'New Chat');

    final effectiveSystemRole =
        fullAgent.systemRole?.trim().isNotEmpty == true
            ? fullAgent.systemRole!.trim()
            : agent.systemRole?.trim();

    LobeTopic createdTopic;
    try {
      createdTopic = await ref.read(lobeTopicsProvider.notifier).createTopic(
        title: effectiveTitle,
        agentId: fullAgent.id,
        metadata: <String, dynamic>{
          'agentId': fullAgent.id,
          'agentTitle': effectiveTitle,
          if (effectiveSystemRole != null && effectiveSystemRole.isNotEmpty)
            'systemRole': effectiveSystemRole,
          if (targetModelId != null) 'agentModel': targetModelId,
          if (targetProvider != null) 'agentProvider': targetProvider,
        },
      );
    } catch (error) {
      if (!context.mounted) return false;
      _reportError(context, 'Failed to create topic: $error');
      return false;
    }

    // 5. Build Conduit Conversation model preserving agent metadata & systemRole
    final effectiveModelForConversation = resolvedModel?.id ??
        (targetModelId != null && !targetModelId.startsWith('agt_')
            ? targetModelId
            : null);

    final conversation = lobeTopicToConversation(createdTopic).copyWith(
      model: effectiveModelForConversation,
      metadata: <String, dynamic>{
        ...createdTopic.metadata,
        'agentId': fullAgent.id,
        'agentTitle': effectiveTitle,
        if (effectiveSystemRole != null && effectiveSystemRole.isNotEmpty) ...{
          'systemRole': effectiveSystemRole,
          'system': effectiveSystemRole,
        },
        'lobeTopic': createdTopic.toJson(),
        'lobeMetadata': createdTopic.metadata,
      },
    );

    // 6. Activate conversation via conversationSelectionProvider seam
    final selectionResult = await ref
        .read(conversationSelectionProvider.notifier)
        .select(conversation);

    if (selectionResult.disposition ==
        ConversationSelectionDisposition.committed) {
      state = state.copyWith(isStarting: false);
      if (context.mounted) {
        // Navigate seamlessly to Chats tab on success
        ref.read(mainNavigationIndexProvider.notifier).state = 0;
      }
      return true;
    }

    // If failed or canceled, keep tab position and show error visible in SnackBar
    final errMsg = selectionResult.error?.toString() ??
        'Conversation selection failed or was canceled.';
    if (!context.mounted) return false;
    _reportError(context, errMsg);
    return false;
  }

  void _reportError(BuildContext context, String message) {
    state = state.copyWith(isStarting: false, error: message);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  bool _isAuthValid() {
    try {
      final authState = ref.read(authStateManagerProvider).asData?.value;
      if (authState != null) {
        return authState.isAuthenticated;
      }
    } catch (_) {}
    return true;
  }
}

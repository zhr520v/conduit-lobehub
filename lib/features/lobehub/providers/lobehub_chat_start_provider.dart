import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_mappers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
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
    if (state.isStarting) return false;
    state = const LobehubChatStartState(isStarting: true);
    var action = 'Failed to prepare Agent';
    try {
      final api = ref.read(apiServiceProvider);
      final client = ref.read(lobeHubApiClientProvider);
      final owner = captureOpenWebUiConversationSelectionOwner(ref);
      if (api == null || client == null || !api.serverConfig.isLobeHub) {
        throw StateError('An online LobeHub connection is required to start chat.');
      }
      if (owner == null || api.authToken != owner.authToken) {
        throw StateError('Authentication required to start chat.');
      }
      if (client.baseUrl != LobeHubApiClient.normalizeBaseUrl(api.serverConfig.url)) {
        throw StateError('The Agent client does not belong to the current server.');
      }
      final authenticationEpoch = api.authenticationEpoch;
      final server = ref.read(activeServerProvider).value;

      void requireCurrentOwner() {
        if (!ref.mounted ||
            !context.mounted ||
            !identical(ref.read(apiServiceProvider), api) ||
            !identical(ref.read(lobeHubApiClientProvider), client) ||
            ref.read(activeServerProvider).value != server ||
            api.authenticationEpoch != authenticationEpoch ||
            !openWebUiConversationSelectionOwnerIsCurrent(ref, owner)) {
          throw StateError('Account or server changed while starting the Agent chat. Please retry.');
        }
      }

      requireCurrentOwner();
      final fullAgent = await client.getAgent(agent.id);
      requireCurrentOwner();
      if (fullAgent.id.isEmpty || fullAgent.id != agent.id) {
        throw StateError('Agent details do not match the selected Agent.');
      }
      final modelId = fullAgent.model?.trim();
      final provider = fullAgent.provider?.trim();
      if (modelId == null || modelId.isEmpty || modelId.startsWith('agt_') ||
          modelId == fullAgent.id || provider == null || provider.isEmpty) {
        throw StateError('The Agent has no valid underlying model/provider configuration.');
      }
      final roster = await ref.read(modelsProvider.future);
      requireCurrentOwner();
      final resolvedModel = roster.firstWhereOrNull((model) {
        final modelProvider = model.metadata?['provider'] ??
            model.metadata?['providerId'] ?? model.metadata?['owned_by'];
        return model.id == modelId && modelProvider?.toString() == provider;
      });
      if (resolvedModel == null) {
        throw StateError('Configured model "$modelId" from provider "$provider" is unavailable. Check the Agent configuration on LobeHub.');
      }
      final title = fullAgent.title?.trim();
      final effectiveTitle = title == null || title.isEmpty ? fullAgent.id : title;
      action = 'Failed to create topic';
      final createdTopic = await client.createTopic(
        title: effectiveTitle,
        agentId: fullAgent.id,
      );
      requireCurrentOwner();
      if (createdTopic.id.trim().isEmpty ||
          createdTopic.id.startsWith('local_') ||
          createdTopic.id.startsWith('local:') ||
          createdTopic.agentId != agent.id) {
        throw StateError('The server did not return a verified topic bound to the selected Agent.');
      }
      final systemRole = fullAgent.systemRole?.trim();
      final conversation = withChatStorageProvenance(
        lobeTopicToConversation(createdTopic).copyWith(
          model: modelId,
          systemPrompt: systemRole,
          metadata: <String, dynamic>{
            ...createdTopic.metadata,
            'backend': 'lobehub',
            'agentId': fullAgent.id,
            'agentTitle': effectiveTitle,
            'agentModel': modelId,
            'provider': provider,
            if (systemRole != null && systemRole.isNotEmpty) 'systemRole': systemRole,
            'lobeTopic': createdTopic.toJson(),
          },
        ),
        ChatStorageKind.openWebUi,
      );
      action = 'Failed to activate Agent conversation';
      final selection = await ref.read(conversationSelectionProvider.notifier)
          .select(conversation);
      requireCurrentOwner();
      if (selection.disposition != ConversationSelectionDisposition.committed) {
        throw StateError(selection.error?.toString() ?? 'Conversation selection was canceled.');
      }
      final active = ref.read(activeConversationProvider);
      if (active?.id != createdTopic.id ||
          active?.metadata['backend'] != 'lobehub' ||
          active?.metadata['agentId'] != agent.id ||
          active?.metadata['agentModel'] != modelId ||
          active?.metadata['provider'] != provider) {
        throw StateError('Reloaded conversation does not match the verified Agent configuration.');
      }
      ref.read(selectedModelProvider.notifier).set(resolvedModel, allowHidden: true);
      requireCurrentOwner();
      ref.read(isManualModelSelectionProvider.notifier).set(true);
      requireCurrentOwner();
      ref.read(mainNavigationIndexProvider.notifier).state = 0;
      return true;
    } catch (error) {
      if (ref.mounted) {
        final message = '$action: $error';
        state = state.copyWith(isStarting: false, error: message);
        if (context.mounted) {
          _reportError(context, message);
        }
      }
      return false;
    } finally {
      if (ref.mounted) {
        state = state.copyWith(isStarting: false, error: state.error);
      }
    }
  }

  void _reportError(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

}

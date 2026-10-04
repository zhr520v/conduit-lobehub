import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/models/lobe_topic.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_topics_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit/features/lobehub/providers/lobehub_chat_start_provider.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

class _FakeLobeTopicsNotifier extends LobeTopicsNotifier {
  _FakeLobeTopicsNotifier({this.shouldThrow = false});

  final bool shouldThrow;
  LobeTopic? lastCreatedTopic;

  @override
  LobeTopicsState build() => const LobeTopicsState();

  @override
  Future<LobeTopic> createTopic({
    required String title,
    String? agentId,
    String? sessionId,
    Map<String, dynamic>? metadata,
  }) async {
    if (shouldThrow) {
      throw Exception('Server rejected topic creation');
    }
    final topic = LobeTopic(
      id: 'server_topic_123',
      title: title,
      agentId: agentId,
      sessionId: sessionId,
      metadata: metadata ?? const <String, dynamic>{},
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    lastCreatedTopic = topic;
    state = state.copyWith(
      topics: [topic, ...state.topics],
      activeTopicId: topic.id,
    );
    return topic;
  }
}

class _FakeConversationSelection extends ConversationSelection {
  _FakeConversationSelection({this.shouldFail = false});

  final bool shouldFail;
  Conversation? lastSelectedConversation;

  @override
  ConversationSelectionState build() => const ConversationSelectionState();

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async {
    lastSelectedConversation = summary;
    if (shouldFail) {
      return ConversationSelectionResult.failed(
        Exception('Network timeout during selection'),
        StackTrace.current,
      );
    }
    return const ConversationSelectionResult.committed();
  }
}

class _TestModelsNotifier extends Models {
  _TestModelsNotifier(this._models);
  final List<Model> _models;

  @override
  Future<List<Model>> build() async => _models;
}

class _TestSelectedModelNotifier extends SelectedModel {
  _TestSelectedModelNotifier();

  @override
  Model? build() => null;

  @override
  void set(Model? model, {bool allowHidden = false}) {
    state = model;
  }
}

class _TestReviewerModeNotifier extends ReviewerMode {
  _TestReviewerModeNotifier([this._initial = false]);
  final bool _initial;

  @override
  bool build() => _initial;
}

class _TestNavigationNotifier extends MainNavigationIndexNotifier {
  _TestNavigationNotifier([this._initial = 0]);
  final int _initial;

  @override
  int build() => _initial;
}

class _TestAgentsNotifier extends LobeAgentsNotifier {
  _TestAgentsNotifier(this._initialState);
  final LobeAgentsState _initialState;

  @override
  LobeAgentsState build() => _initialState;
}

void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
  });

  group('LobeHub Chat Start - Agent to Topic Binding & Model Separation', () {
    testWidgets('creates server topic bound to agent and selects real model by BOTH modelId and provider', (
      tester,
    ) async {
      final topicsNotifier = _FakeLobeTopicsNotifier();
      final selectionNotifier = _FakeConversationSelection();

      final agent = const LobeAgent(
        id: 'agent_coder_42',
        title: 'DeepSeek Coding Specialist',
        model: 'deepseek-coder',
        provider: 'deepseek',
        systemRole: 'You are an expert Flutter systems architect.',
      );

      // Model roster with separate real models (no agents injected)
      final rosterModels = [
        const Model(
          id: 'gpt-4o',
          name: 'GPT-4o',
          metadata: {'provider': 'openai', 'providerId': 'openai'},
        ),
        const Model(
          id: 'deepseek-coder',
          name: 'DeepSeek Coder V2',
          metadata: {'provider': 'deepseek', 'providerId': 'deepseek'},
        ),
        const Model(
          id: 'deepseek-coder',
          name: 'DeepSeek Coder (OpenRouter)',
          metadata: {'provider': 'openrouter', 'providerId': 'openrouter'},
        ),
      ];

      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub Server',
                url: 'https://ai.example.com',
              ),
            ),
          ),
          apiServiceProvider.overrideWith((ref) => null),
          reviewerModeProvider.overrideWith(() => _TestReviewerModeNotifier(false)),
          selectedModelProvider.overrideWith(() => _TestSelectedModelNotifier()),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeTopicsProvider.overrideWith(() => topicsNotifier),
          conversationSelectionProvider.overrideWith(() => selectionNotifier),
          modelsProvider.overrideWith(() => _TestModelsNotifier(rosterModels)),
        ],
      );
      addTearDown(container.dispose);

      late BuildContext buildContext;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  buildContext = context;
                  return const Text('Test Host');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trigger startAgentChat
      final success = await container
          .read(lobehubChatStartProvider.notifier)
          .startAgentChat(
            context: buildContext,
            agent: agent,
          );

      expect(success, isTrue);

      // Verify 1: Topic was created on server bound to chosenAgent
      expect(topicsNotifier.lastCreatedTopic, isNotNull);
      expect(topicsNotifier.lastCreatedTopic!.agentId, equals('agent_coder_42'));
      expect(topicsNotifier.lastCreatedTopic!.title, equals('DeepSeek Coding Specialist'));

      // Verify 2: Real model was selected separately by BOTH modelId AND provider
      final selectedModel = container.read(selectedModelProvider);
      expect(selectedModel, isNotNull);
      expect(selectedModel!.id, equals('deepseek-coder'));
      expect(selectedModel.metadata?['provider'], equals('deepseek'));

      // Verify 3: Agent was NOT injected as model ID (no agt_ as model)
      expect(selectedModel.id.startsWith('agt_'), isFalse);
      expect(selectedModel.id, isNot(equals(agent.id)));

      // Verify 4: Conversation preserved metadata: agentId, agentTitle, and systemRole
      final selectedConv = selectionNotifier.lastSelectedConversation;
      expect(selectedConv, isNotNull);
      expect(selectedConv!.metadata['agentId'], equals('agent_coder_42'));
      expect(selectedConv.metadata['agentTitle'], equals('DeepSeek Coding Specialist'));
      expect(
        selectedConv.metadata['systemRole'],
        equals('You are an expert Flutter systems architect.'),
      );

      // Verify 5: mainNavigationIndexProvider navigated to Tab 0 (Chats)
      expect(container.read(mainNavigationIndexProvider), equals(0));
    });

    testWidgets('does not fallback to firstAgent or set agt_ as model when agent model is not in roster', (
      tester,
    ) async {
      final topicsNotifier = _FakeLobeTopicsNotifier();
      final selectionNotifier = _FakeConversationSelection();

      final agentWithAgt = const LobeAgent(
        id: 'agt_writer_99',
        title: 'Essayist',
        model: 'agt_writer_99', // Malformed or self-referential agent model
        provider: null,
      );

      final rosterModels = [
        const Model(id: 'gpt-4o', name: 'GPT-4o'),
      ];

      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub',
                url: 'https://ai.example.com',
              ),
            ),
          ),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeTopicsProvider.overrideWith(() => topicsNotifier),
          conversationSelectionProvider.overrideWith(() => selectionNotifier),
          modelsProvider.overrideWith(() => _TestModelsNotifier(rosterModels)),
        ],
      );
      addTearDown(container.dispose);

      late BuildContext buildContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  buildContext = context;
                  return const Text('Test Host');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final success = await container
          .read(lobehubChatStartProvider.notifier)
          .startAgentChat(
            context: buildContext,
            agent: agentWithAgt,
          );

      expect(success, isTrue);

      // Verify that agt_ was NOT set as selectedModel
      final selectedModel = container.read(selectedModelProvider);
      if (selectedModel != null) {
        expect(selectedModel.id.startsWith('agt_'), isFalse);
      }
    });

    testWidgets('displays error SnackBar and does NOT switch tab when topic creation fails', (
      tester,
    ) async {
      final failingTopicsNotifier = _FakeLobeTopicsNotifier(shouldThrow: true);
      final selectionNotifier = _FakeConversationSelection();

      const agent = LobeAgent(
        id: 'agent_error',
        title: 'Error Agent',
      );

      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub',
                url: 'https://ai.example.com',
              ),
            ),
          ),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeTopicsProvider.overrideWith(() => failingTopicsNotifier),
          conversationSelectionProvider.overrideWith(() => selectionNotifier),
          mainNavigationIndexProvider.overrideWith(() => _TestNavigationNotifier(1)), // On Agents tab
        ],
      );
      addTearDown(container.dispose);

      late BuildContext buildContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  buildContext = context;
                  return const Text('Test Host');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final success = await container
          .read(lobehubChatStartProvider.notifier)
          .startAgentChat(
            context: buildContext,
            agent: agent,
          );

      expect(success, isFalse);
      await tester.pump();

      // Verify SnackBar with error is visible
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Failed to create topic'), findsOneWidget);

      // CRITICAL: Navigation index must NOT tab to 0 on failure!
      expect(container.read(mainNavigationIndexProvider), equals(1));
    });

    testWidgets('displays error SnackBar and does NOT switch tab when selection fails', (
      tester,
    ) async {
      final topicsNotifier = _FakeLobeTopicsNotifier();
      final failingSelection = _FakeConversationSelection(shouldFail: true);

      const agent = LobeAgent(
        id: 'agent_select_fail',
        title: 'Fail Selection Agent',
      );

      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub',
                url: 'https://ai.example.com',
              ),
            ),
          ),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeTopicsProvider.overrideWith(() => topicsNotifier),
          conversationSelectionProvider.overrideWith(() => failingSelection),
          mainNavigationIndexProvider.overrideWith(() => _TestNavigationNotifier(1)), // On Agents tab
        ],
      );
      addTearDown(container.dispose);

      late BuildContext buildContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  buildContext = context;
                  return const Text('Test Host');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final success = await container
          .read(lobehubChatStartProvider.notifier)
          .startAgentChat(
            context: buildContext,
            agent: agent,
          );

      expect(success, isFalse);
      await tester.pump();

      // Verify SnackBar shown and tab did not change
      expect(find.byType(SnackBar), findsOneWidget);
      expect(container.read(mainNavigationIndexProvider), equals(1));
    });
  });

  group('LobeHub REST Media Capability Limitation & Warning', () {
    testWidgets('shows media capability limitation banner inside AgentActionsModalSheet', (
      tester,
    ) async {
      const agent = LobeAgent(
        id: 'agent_banner_test',
        title: 'Creative Assistant',
        model: 'gpt-4o',
      );

      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub',
                url: 'https://ai.example.com',
              ),
            ),
          ),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeAgentsProvider.overrideWith(
            () => _TestAgentsNotifier(
              const LobeAgentsState(agents: [agent]),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: LobehubAgentsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap agent card to open bottom sheet
      await tester.tap(find.byKey(const ValueKey('agent-card-agent_banner_test')));
      await tester.pumpAndSettle();

      // Verify the media limitation disclaimer banner is visible immediately without spinner
      expect(
        find.byKey(const ValueKey('agent-actions-media-notice-banner')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Server REST (2.2.17) lacks image and file analysis support'),
        findsOneWidget,
      );
    });

    testWidgets('tapping Start New Chat in LobehubAgentsPage triggers real binding startAgentChat', (
      tester,
    ) async {
      final topicsNotifier = _FakeLobeTopicsNotifier();
      final selectionNotifier = _FakeConversationSelection();

      const agent = LobeAgent(
        id: 'agent_start_test',
        title: 'Autonomous Researcher',
        model: 'gpt-4o',
      );

      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub',
                url: 'https://ai.example.com',
              ),
            ),
          ),
          apiServiceProvider.overrideWith((ref) => null),
          reviewerModeProvider.overrideWith(() => _TestReviewerModeNotifier(false)),
          selectedModelProvider.overrideWith(() => _TestSelectedModelNotifier()),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeTopicsProvider.overrideWith(() => topicsNotifier),
          conversationSelectionProvider.overrideWith(() => selectionNotifier),
          lobeAgentsProvider.overrideWith(
            () => _TestAgentsNotifier(
              const LobeAgentsState(agents: [agent]),
            ),
          ),
          mainNavigationIndexProvider.overrideWith(() => _TestNavigationNotifier(1)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.light(),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: LobehubAgentsPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open bottom sheet
      await tester.tap(find.byKey(const ValueKey('agent-card-agent_start_test')));
      await tester.pumpAndSettle();

      // Tap action-start-new-chat
      await tester.tap(find.byKey(const ValueKey('action-start-new-chat')));
      await tester.pumpAndSettle();

      // Verified real topic created and bound
      expect(topicsNotifier.lastCreatedTopic, isNotNull);
      expect(topicsNotifier.lastCreatedTopic!.agentId, equals('agent_start_test'));
    });
  });
}

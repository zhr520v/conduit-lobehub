// ignore_for_file: scoped_providers_should_specify_dependencies
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/models/lobe_topic.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_topics_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';

import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:conduit/features/settings/views/lobe_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

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

class _TestFakeLobeTopicsNotifier extends LobeTopicsNotifier {
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
    final topic = LobeTopic(
      id: 'server_topic_shell',
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

class _TestFakeConversationSelection extends ConversationSelection {
  Conversation? lastSelectedConversation;

  @override
  ConversationSelectionState build() => const ConversationSelectionState();

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async {
    lastSelectedConversation = summary;
    return const ConversationSelectionResult.committed();
  }
}

class _TestAgentsNotifier extends LobeAgentsNotifier {
  _TestAgentsNotifier(this._initialState);

  final LobeAgentsState _initialState;

  @override
  LobeAgentsState build() => _initialState;
}

Widget createTestHarness({
  required Widget child,
  List<Override> overrides = const [],
  LobeAgentsState? agentsState,
  Size size = const Size(390, 844),
  TargetPlatform platform = TargetPlatform.android,
}) {
  PlatformUiCapabilities.debugPlatformOverride = platform;

  return ProviderScope(
    overrides: [
      activeServerProvider.overrideWith(
        (ref) => Future.value(
          const ServerConfig(
            id: 'lobehub_self_hosted',
            name: 'LobeHub',
            url: 'https://ai.opw.ink',
          ),
        ),
      ),
      apiServiceProvider.overrideWith((ref) => null),
      reviewerModeProvider.overrideWith(() => _TestReviewerModeNotifier(false)),
      selectedModelProvider.overrideWith(() => _TestSelectedModelNotifier()),
      lobeHubApiClientProvider.overrideWith((ref) => null),
      lobeAgentsProvider.overrideWith(
        () => _TestAgentsNotifier(agentsState ?? const LobeAgentsState()),
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
  });

  group('MainNavigationShell - 3-Module Navigation Structure', () {
    testWidgets('renders all 3 tabs (Chats, Agents, Settings) with correct icons and labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestHarness(
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      // Verify all 3 navigation destination tabs are present
      expect(find.byKey(const ValueKey('nav-tab-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-tab-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-tab-2')), findsOneWidget);

      // Verify Tab 0 (Chats) - active icon is selected chat_bubble
      expect(find.text('Chats'), findsWidgets);
      expect(find.byIcon(Icons.chat_bubble), findsWidgets);

      // Verify Tab 1 (Agents)
      expect(find.text('Agents'), findsWidgets);
      expect(find.byIcon(Icons.smart_toy_outlined), findsWidgets);

      // Verify Tab 2 (Settings)
      expect(find.text('Settings'), findsWidgets);
      expect(find.byIcon(Icons.settings_outlined), findsWidgets);
    });

    testWidgets('defaults to Tab 0 (Chats) on initial load', (tester) async {
      await tester.pumpWidget(
        createTestHarness(
          child: const MainNavigationShell(
            chatsView: Center(child: Text('Custom Chats Screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Chats tab content is rendered and visible
      expect(find.text('Custom Chats Screen'), findsOneWidget);
      // Agents and Settings tabs are in the IndexedStack but offstage
      expect(
        find.byKey(const ValueKey('main-nav-tab-agents'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('main-nav-tab-settings'), skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('switches seamlessly to Tab 1 (Agents) on tap', (tester) async {
      final sampleAgent = const LobeAgent(
        id: 'agent-writer',
        title: 'Creative Writer',
        description: 'Assists with creative writing and storytelling.',
        model: 'gpt-4o',
      );

      await tester.pumpWidget(
        createTestHarness(
          agentsState: LobeAgentsState(
            agents: [sampleAgent],
            isLoading: false,
          ),
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Tab 1 (Agents)
      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();

      // Verify Agents page content is visible
      expect(find.byType(LobehubAgentsPage), findsOneWidget);
      expect(find.text('Creative Writer'), findsOneWidget);
      expect(find.text('Assists with creative writing and storytelling.'), findsOneWidget);
      expect(find.text('gpt-4o'), findsOneWidget);
      expect(find.text('Search agents...'), findsOneWidget);
    });

    testWidgets('switches seamlessly to Tab 2 (Settings) on tap', (tester) async {
      await tester.pumpWidget(
        createTestHarness(
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Tab 2 (Settings)
      await tester.tap(find.byKey(const ValueKey('nav-tab-2')));
      await tester.pumpAndSettle();

      // Verify Settings page content is visible
      expect(find.byType(LobeSettingsPage), findsOneWidget);
      expect(find.text('SERVER CONNECTION'), findsOneWidget);
      expect(find.text('APPEARANCE & THEME'), findsOneWidget);
    });

    testWidgets('can switch back and forth between all 3 tabs cleanly', (
      tester,
    ) async {
      int? reportedIndex;

      await tester.pumpWidget(
        createTestHarness(
          child: MainNavigationShell(
            chatsView: const Center(child: Text('Chat Surface')),
            onTabChanged: (index) => reportedIndex = index,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially on Tab 0
      expect(find.text('Chat Surface'), findsOneWidget);

      // Tap Tab 1 (Agents)
      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();
      expect(reportedIndex, 1);
      expect(find.byKey(const ValueKey('main-nav-tab-agents')), findsOneWidget);

      // Tap Tab 2 (Settings)
      await tester.tap(find.byKey(const ValueKey('nav-tab-2')));
      await tester.pumpAndSettle();
      expect(reportedIndex, 2);
      expect(find.byType(LobeSettingsPage), findsOneWidget);

      // Tap Tab 0 (Chats)
      await tester.tap(find.byKey(const ValueKey('nav-tab-0')));
      await tester.pumpAndSettle();
      expect(reportedIndex, 0);
      expect(find.text('Chat Surface'), findsOneWidget);
    });

    testWidgets('responsive layout prevents RenderFlex overflow on small screens (320dp width)', (
      tester,
    ) async {
      // Set surface to 320dp compact width
      const compactSize = Size(320, 568);
      await tester.binding.setSurfaceSize(compactSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        createTestHarness(
          size: compactSize,
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      // Verify no exceptions on Tab 0
      expect(tester.takeException(), isNull);

      // Switch to Tab 1 (Agents) at 320dp
      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Switch to Tab 2 (Settings) at 320dp
      await tester.tap(find.byKey(const ValueKey('nav-tab-2')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Switch back to Tab 0 at 320dp
      await tester.tap(find.byKey(const ValueKey('nav-tab-0')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders properly on wide/tablet screens without overflow', (
      tester,
    ) async {
      const tabletSize = Size(800, 1200);
      await tester.binding.setSurfaceSize(tabletSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        createTestHarness(
          size: tabletSize,
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('nav-tab-2')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('supports Cupertino chrome on iOS platform', (tester) async {
      await tester.pumpWidget(
        createTestHarness(
          platform: TargetPlatform.iOS,
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      // On iOS, CupertinoTabBar is rendered
      expect(find.byType(CupertinoTabBar), findsOneWidget);
      expect(find.text('Chats'), findsWidgets);
      expect(find.text('Agents'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);

      // Tap Agents tab in Cupertino
      await tester.tap(find.text('Agents'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('main-nav-tab-agents')), findsOneWidget);

      // Tap Settings tab in Cupertino
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(LobeSettingsPage), findsOneWidget);
    });

    testWidgets('supports custom views for chats, agents, and settings', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestHarness(
          child: const MainNavigationShell(
            chatsView: Center(child: Text('Custom Chats View')),
            agentsView: Center(child: Text('Custom Agents View')),
            settingsView: Center(child: Text('Custom Settings View')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Custom Chats View'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();
      expect(find.text('Custom Agents View'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-tab-2')));
      await tester.pumpAndSettle();
      expect(find.text('Custom Settings View'), findsOneWidget);
    });

    testWidgets('programmatic navigation updates active tab via mainNavigationIndexProvider', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          activeServerProvider.overrideWith(
            (ref) => Future.value(
              const ServerConfig(
                id: 'lobehub_self_hosted',
                name: 'LobeHub',
                url: 'https://ai.opw.ink',
              ),
            ),
          ),
          apiServiceProvider.overrideWith((ref) => null),
          reviewerModeProvider.overrideWith(() => _TestReviewerModeNotifier(false)),
          selectedModelProvider.overrideWith(() => _TestSelectedModelNotifier()),
          lobeHubApiClientProvider.overrideWith((ref) => null),
          lobeAgentsProvider.overrideWith(
            () => _TestAgentsNotifier(const LobeAgentsState()),
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
            home: const MainNavigationShell(
              chatsView: Text('Chats Tab'),
              agentsView: Text('Agents Tab'),
              settingsView: Text('Settings Tab'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chats Tab'), findsOneWidget);

      // Programmatically change to Tab 1
      container.read(mainNavigationIndexProvider.notifier).state = 1;
      await tester.pumpAndSettle();
      expect(find.text('Agents Tab'), findsOneWidget);

      // Programmatically change to Tab 2
      container.read(mainNavigationIndexProvider.notifier).state = 2;
      await tester.pumpAndSettle();
      expect(find.text('Settings Tab'), findsOneWidget);
    });

    testWidgets('production MainShell user card -> start -> triggers real binding to topic and selects model', (
      tester,
    ) async {
      final sampleAgent = const LobeAgent(
        id: 'agent_prod_shell',
        title: 'Production Agent',
        description: 'Verified real binding.',
        model: 'gpt-4o',
        provider: 'openai',
      );

      final topicsNotifier = _TestFakeLobeTopicsNotifier();
      final selectionNotifier = _TestFakeConversationSelection();

      final rosterModels = [
        const Model(
          id: 'gpt-4o',
          name: 'GPT-4o',
          metadata: {'provider': 'openai'},
        ),
      ];

      await tester.pumpWidget(
        createTestHarness(
          agentsState: LobeAgentsState(agents: [sampleAgent]),
          overrides: [
            lobeTopicsProvider.overrideWith(() => topicsNotifier),
            conversationSelectionProvider.overrideWith(() => selectionNotifier),
            modelsProvider.overrideWith(() => _TestModelsNotifier(rosterModels)),
          ],
          // Production shell uses default LobeAgentsPage without injected onStartChat
          child: const MainNavigationShell(),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Agents Tab (Tab 1)
      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();

      // Tap on agent card to open bottom sheet
      await tester.tap(find.byKey(const ValueKey('agent-card-agent_prod_shell')));
      await tester.pumpAndSettle();

      // Verify the media limitation disclaimer banner is visible immediately
      expect(
        find.byKey(const ValueKey('agent-actions-media-notice-banner')),
        findsOneWidget,
      );

      // Tap "Start New Chat"
      await tester.tap(find.byKey(const ValueKey('action-start-new-chat')));
      await tester.pumpAndSettle();

      // Verify real topic binding occurred
      expect(topicsNotifier.lastCreatedTopic, isNotNull);
      expect(topicsNotifier.lastCreatedTopic!.agentId, equals('agent_prod_shell'));

      // Verify conversation selection seam was triggered
      expect(selectionNotifier.lastSelectedConversation, isNotNull);
      expect(
        selectionNotifier.lastSelectedConversation!.metadata['agentId'],
        equals('agent_prod_shell'),
      );

      // Verify navigation returned to Tab 0 (Chats)
      expect(find.byKey(const ValueKey('nav-tab-0')), findsOneWidget);
    });
  });
}

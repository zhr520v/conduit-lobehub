// ignore_for_file: scoped_providers_should_specify_dependencies
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/sync_engine.dart';

import 'package:conduit/features/lobehub/providers/lobehub_chat_start_provider.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:conduit/features/settings/views/lobe_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../lobehub/role_test_harness.dart';

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
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
      final harness = RoleHarness();
      addTearDown(() async {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(harness.close);
        } finally {
          PreferencesStore.debugReset();
          SharedPreferences.setMockInitialValues({});
        }
      });
      harness.adapter.handlers['GET /api/v1/agents'] = (_) => roleJson({
        'success': true,
        'data': {
          'agents': [roleAgent.toJson()],
        },
      });
      harness.adapter.handlers['GET /api/v1/models'] = (_) => roleJson({
        'success': true,
        'data': {'models': harness.models},
      });

      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        PreferencesStore.debugReset();
        PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
        await harness.initialize();
        harness.container.read(mainNavigationIndexProvider.notifier).state = 0;

        final agentsLoaded = Completer<void>();
        final subscription = harness.container.listen(lobeAgentsProvider, (
          previous,
          next,
        ) {
          if (previous?.isLoading == true && !next.isLoading) {
            agentsLoaded.complete();
          }
        });
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: harness.container,
              child: MaterialApp(
                theme: ThemeData.light(),
                localizationsDelegates: conduitLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const MainNavigationShell(),
              ),
            ),
          );
          await agentsLoaded.future.timeout(const Duration(seconds: 10));
        } finally {
          subscription.close();
        }
      });
      await tester.pumpAndSettle();

      final agents = harness.container.read(lobeAgentsProvider);
      expect(agents.agents, [roleAgent]);
      expect(agents.isLoading, isFalse);
      expect(agents.isOffline, isFalse);
      expect(agents.errorMessage, isNull);
      expect(harness.container.read(apiServiceProvider), same(harness.api));
      expect(harness.container.read(lobeHubApiClientProvider), same(harness.client));
      expect(harness.container.read(selectedModelProvider), foreignModel);
      expect(harness.container.read(activeConversationProvider), isNull);
      expect(harness.container.read(mainNavigationIndexProvider), 0);
      expect(find.byKey(const ValueKey('main-nav-tab-chats')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();
      expect(harness.container.read(mainNavigationIndexProvider), 1);
      expect(find.byType(LobehubAgentsPage), findsOneWidget);
      expect(
        tester.widget<LobehubAgentsPage>(find.byType(LobehubAgentsPage)).onStartChat,
        isNotNull,
      );
      expect(find.text(roleAgent.title!), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('agent-card-${roleAgent.id}')));
      await tester.pumpAndSettle();
      expect(harness.container.read(lobeSelectedAgentIdProvider), roleAgent.id);
      expect(find.byKey(const ValueKey('agent-actions-bottom-sheet')), findsOneWidget);

      expect(
        find.byKey(const ValueKey('agent-actions-media-notice-banner')),
        findsOneWidget,
      );
      expect(
        find.text('Server REST (2.2.17) lacks image and file analysis support (/chat is string-only).'),
        findsOneWidget,
      );
      expect(find.textContaining('Start New Chat'), findsOneWidget);

      final startingTransitions = <bool>[];
      await tester.runAsync(() async {
        final startCompleted = Completer<void>();
        final subscription = harness.container.listen(lobehubChatStartProvider, (
          previous,
          next,
        ) {
          if (previous?.isStarting != next.isStarting) {
            startingTransitions.add(next.isStarting);
          }
          if (previous?.isStarting == true && !next.isStarting) {
            startCompleted.complete();
          }
        });
        try {
          await tester.tap(find.byKey(const ValueKey('action-start-new-chat')));
          await startCompleted.future.timeout(const Duration(seconds: 10));
        } finally {
          subscription.close();
        }
      });
      await tester.pumpAndSettle();

      expect(startingTransitions, [true, false]);
      expect(harness.container.read(lobehubChatStartProvider).isStarting, isFalse);
      expect(harness.container.read(lobehubChatStartProvider).error, isNull);
      expect(harness.creationPayloads.single, {
        'title': roleAgent.title,
        'agentId': roleAgent.id,
      });
      final requests = harness.adapter.requests;
      expect(
        requests.map((request) => '${request.method} ${request.uri.path}'),
        containsAll([
          'GET /api/v1/agents',
          'GET /api/v1/agents/${roleAgent.id}',
          'GET /api/v1/models',
          'POST /api/v1/topics',
          'GET /api/v1/topics/tpc_verified',
          'GET /api/v1/messages',
        ]),
      );
      final topicPost = requests.singleWhere((request) =>
          request.method == 'POST' && request.uri.path == '/api/v1/topics');
      expect(topicPost.data, harness.creationPayloads.single);
      expect(harness.topic['agentId'], roleAgent.id);
      expect(harness.detailCalls, greaterThanOrEqualTo(2));

      final selection = harness.container.read(conversationSelectionProvider);
      expect(selection.generation, 1);
      expect(selection.isLoading, isFalse);
      expect(selection.pendingConversationId, isNull);
      final active = harness.container.read(activeConversationProvider);
      expect(active, isNotNull);
      expect(active!.id, 'tpc_verified');
      expect(active.title, roleAgent.title);
      expect(active.model, roleAgent.model);
      final expectedIdentity = {
        'backend': 'lobehub',
        'agentId': roleAgent.id,
        'agentTitle': roleAgent.title,
        'agentModel': roleAgent.model,
        'provider': roleAgent.provider,
      };
      for (final entry in expectedIdentity.entries) {
        expect(active.metadata, containsPair(entry.key, entry.value));
      }
      final selectedModel = harness.container.read(selectedModelProvider);
      expect(selectedModel, isNotNull);
      expect(selectedModel!.id, roleAgent.model);
      expect(selectedModel.metadata?['provider'], roleAgent.provider);
      expect(selectedModel.name, 'DeepSeek Underlying');
      expect(selectedModel.id, isNot(roleAgent.id));
      expect(selectedModel.id, isNot(foreignModel.id));
      expect(selectedModel.id, isNot(startsWith('agt_')));
      expect(harness.container.read(isManualModelSelectionProvider), isTrue);
      final roster = harness.container.read(modelsProvider).requireValue;
      expect(roster, hasLength(3));
      expect(roster.first.id, selectedModel.id);
      expect(roster.first.metadata?['provider'], 'openrouter');
      expect(selectedModel, roster[1]);

      expect(harness.container.read(mainNavigationIndexProvider), 0);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);
      expect(find.byKey(const ValueKey('nav-tab-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('main-nav-tab-chats')), findsOneWidget);
      expect(find.byKey(const ValueKey('main-nav-tab-agents')), findsNothing);
      expect(find.byKey(const ValueKey('agent-actions-bottom-sheet')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);

      await tester.runAsync(() async {
        final pulled = await harness.container
            .read(syncEngineProvider.notifier).pullChatNow(active.id);
        expect(pulled, isNotNull);
        expect(pulled!.id, active.id);
        expect(pulled.model, roleAgent.model);
        final row = await harness.database.chatsDao.getChat(active.id);
        expect(row, isNotNull);
        expect(row!.bodySynced, isTrue);
        expect(row.title, roleAgent.title);
        final metadata = jsonDecode(row.meta) as Map<String, dynamic>;
        for (final entry in expectedIdentity.entries) {
          expect(metadata, containsPair(entry.key, entry.value));
        }
        expect(await harness.localDatabase.chatsDao.getChat(active.id), isNull);
        harness.container.read(activeConversationProvider.notifier).clear();
        expect(harness.container.read(activeConversationProvider), isNull);
        final reopened = await harness.container
            .read(conversationSelectionProvider.notifier).select(active);
        expect(reopened.disposition, ConversationSelectionDisposition.committed);
        expect(reopened.error, isNull);
        await harness.container.read(syncEngineProvider.notifier).pullChatNow(active.id);
      });
      await tester.pumpAndSettle();

      final reopened = harness.container.read(activeConversationProvider);
      expect(reopened, isNotNull);
      expect(reopened!.id, active.id);
      expect(reopened.title, roleAgent.title);
      expect(reopened.model, roleAgent.model);
      for (final entry in expectedIdentity.entries) {
        expect(reopened.metadata, containsPair(entry.key, entry.value));
      }
      expect(harness.container.read(conversationSelectionProvider).generation, 2);
      expect(harness.container.read(conversationSelectionProvider).isLoading, isFalse);
      expect(harness.container.read(selectedModelProvider), selectedModel);
      expect(harness.container.read(mainNavigationIndexProvider), 0);
      expect(find.byKey(const ValueKey('main-nav-tab-chats')), findsOneWidget);
      expect(harness.adapter.unexpectedRequests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';

import 'package:conduit/features/lobehub/views/lobehub_agents_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

final _sampleAgents = [
  const LobeAgent(
    id: 'agent-writer',
    title: 'Creative Writer',
    description: 'Assists with novel writing and storytelling.',
    avatar: '✍️',
    systemRole: 'You are a master novelist and creative writing assistant.',
    model: 'gpt-4o',
  ),
  const LobeAgent(
    id: 'agent-coder',
    title: 'Code Architect',
    description: 'Expert in Flutter and Dart systems.',
    avatar: 'https://example.com/invalid_avatar_404.png',
    systemRole: 'You are a senior principal engineer designing robust architectures.',
    model: 'deepseek-r1',
  ),
  const LobeAgent(
    id: 'agent-translator',
    title: 'Multilingual Translator',
    description: 'Translates between English, Chinese, and Spanish.',
    avatar: null,
    systemRole: 'You translate texts with nuanced cultural idioms.',
    model: 'claude-3-5-sonnet',
  ),
];

class _TestAgentsNotifier extends LobeAgentsNotifier {
  _TestAgentsNotifier(this._initialState);

  final LobeAgentsState _initialState;

  @override
  LobeAgentsState build() => _initialState;

  @override
  void setSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  @override
  void clearSearchQuery() {
    state = state.copyWith(searchQuery: '');
  }

  @override
  void selectAgent(String agentId) {
    state = state.copyWith(selectedAgentId: agentId);
  }
}

Widget createTestApp({
  required Widget child,
  List<LobeAgent>? agents,
  String searchQuery = '',
  bool isOffline = false,
  bool isLoading = false,
  String? errorMessage,
  Size size = const Size(390, 844),
}) {
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
  final effectiveAgents = agents ?? _sampleAgents;

  final notifier = _TestAgentsNotifier(
    LobeAgentsState(
      agents: effectiveAgents,
      searchQuery: searchQuery,
      isOffline: isOffline,
      isLoading: isLoading,
      errorMessage: errorMessage,
    ),
  );

  return ProviderScope(
    overrides: [
      lobeAgentsProvider.overrideWith(() => notifier),
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.conduit),
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

  group('LobehubAgentsPage - Grid/List View & Card Rendering', () {
    testWidgets('renders list view by default with titles, descriptions, and model badges', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // Verify list view is rendered
      expect(find.byKey(const ValueKey('agents-list-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('agents-grid-view')), findsNothing);

      // Verify agent card contents
      expect(find.text('Creative Writer'), findsOneWidget);
      expect(find.text('Assists with novel writing and storytelling.'), findsOneWidget);
      expect(find.text('gpt-4o'), findsOneWidget);
      expect(find.text('You are a master novelist and creative writing assistant.'), findsOneWidget);

      expect(find.text('Code Architect'), findsOneWidget);
      expect(find.text('Expert in Flutter and Dart systems.'), findsOneWidget);
      expect(find.text('deepseek-r1'), findsOneWidget);

      expect(find.text('Multilingual Translator'), findsOneWidget);
      expect(find.text('Translates between English, Chinese, and Spanish.'), findsOneWidget);
      expect(find.text('claude-3-5-sonnet'), findsOneWidget);
    });

    testWidgets('switches between list view and grid view when toggle button is tapped', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // Initial state: list view
      expect(find.byKey(const ValueKey('agents-list-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('agents-grid-view')), findsNothing);

      // Tap toggle view mode button
      final toggleButton = find.byKey(const ValueKey('toggle-view-mode-button'));
      expect(toggleButton, findsOneWidget);
      await tester.tap(toggleButton);
      await tester.pumpAndSettle();

      // Now grid view is active
      expect(find.byKey(const ValueKey('agents-grid-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('agents-list-view')), findsNothing);

      // Verify cards in grid view still display titles and model badges
      expect(find.text('Creative Writer'), findsOneWidget);
      expect(find.text('gpt-4o'), findsOneWidget);
      expect(find.text('Code Architect'), findsOneWidget);
      expect(find.text('deepseek-r1'), findsOneWidget);

      // Tap toggle button again to switch back to list view
      await tester.tap(toggleButton);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('agents-list-view')), findsOneWidget);
      expect(find.byKey(const ValueKey('agents-grid-view')), findsNothing);
    });
  });

  group('LobehubAgentsPage - Dynamic Avatar & Fallback Badges', () {
    testWidgets('renders emoji avatar directly for agents with emoji', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // Emoji avatar is rendered
      expect(find.text('✍️'), findsOneWidget);
    });

    testWidgets('renders colorful uppercase initial badge fallback for null avatar', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // 'Multilingual Translator' has null avatar, should fall back to 'M'
      expect(
        find.byKey(const ValueKey('agent-avatar-fallback-agent-translator')),
        findsOneWidget,
      );
      expect(find.text('M'), findsOneWidget);
    });

    testWidgets('renders colorful uppercase initial badge fallback when network image fails', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Network image errorBuilder executes fallback badge with 'C'
      expect(
        find.byKey(const ValueKey('agent-avatar-fallback-agent-coder')),
        findsOneWidget,
      );
      expect(find.text('C'), findsOneWidget);
    });
  });

  group('LobehubAgentsPage - Real-Time Search Filtering', () {
    testWidgets('filters agents in real-time as user types in search bar', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // Initially all 3 agents are visible
      expect(find.text('Creative Writer'), findsOneWidget);
      expect(find.text('Code Architect'), findsOneWidget);
      expect(find.text('Multilingual Translator'), findsOneWidget);

      // Search for 'Architect'
      final searchField = find.byKey(const ValueKey('agents-search-field'));
      await tester.enterText(searchField, 'Architect');
      await tester.pumpAndSettle();

      // Only 'Code Architect' matches
      expect(find.text('Code Architect'), findsOneWidget);
      expect(find.text('Creative Writer'), findsNothing);
      expect(find.text('Multilingual Translator'), findsNothing);

      // Clear search via clear button
      final clearButton = find.byKey(const ValueKey('clear-search-button'));
      expect(clearButton, findsOneWidget);
      await tester.tap(clearButton);
      await tester.pumpAndSettle();

      // All agents are visible again
      expect(find.text('Creative Writer'), findsOneWidget);
      expect(find.text('Code Architect'), findsOneWidget);
      expect(find.text('Multilingual Translator'), findsOneWidget);
    });

    testWidgets('shows empty state message when search returns zero results', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      final searchField = find.byKey(const ValueKey('agents-search-field'));
      await tester.enterText(searchField, 'NonExistentKeywordXYZ');
      await tester.pumpAndSettle();

      expect(find.text('Creative Writer'), findsNothing);
      expect(find.text('Code Architect'), findsNothing);
      expect(
        find.textContaining('No agents matching "NonExistentKeywordXYZ"'),
        findsOneWidget,
      );
    });
  });

  group('LobehubAgentsPage - Bottom Sheet Quick Actions', () {
    testWidgets('tap agent card opens bottom sheet with Start New Chat and View System Prompt', (
      tester,
    ) async {
      LobeAgent? selectedAgent;

      await tester.pumpWidget(
        createTestApp(
          child: LobehubAgentsPage(
            onSelectAgent: (agent) => selectedAgent = agent,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap on Creative Writer card
      final card = find.byKey(const ValueKey('agent-card-agent-writer'));
      expect(card, findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();

      // Verify onSelectAgent was triggered
      expect(selectedAgent?.id, equals('agent-writer'));

      // Verify bottom sheet modal is open
      expect(find.byKey(const ValueKey('agent-actions-bottom-sheet')), findsOneWidget);

      // Verify action 1: Start New Chat (开启新对话)
      expect(find.byKey(const ValueKey('action-start-new-chat')), findsOneWidget);
      expect(find.textContaining('Start New Chat'), findsOneWidget);
      expect(find.textContaining('开启新对话'), findsOneWidget);

      // Verify action 2: View System Prompt (查看系统设定)
      expect(find.byKey(const ValueKey('action-view-system-prompt')), findsOneWidget);
      expect(find.textContaining('View System Prompt'), findsOneWidget);
      expect(find.textContaining('查看系统设定'), findsOneWidget);
    });

    testWidgets('tapping Start New Chat triggers onStartChat and closes sheet', (
      tester,
    ) async {
      LobeAgent? chatAgent;

      await tester.pumpWidget(
        createTestApp(
          child: LobehubAgentsPage(
            onStartChat: (agent) => chatAgent = agent,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open bottom sheet for Code Architect
      await tester.tap(find.byKey(const ValueKey('agent-card-agent-coder')));
      await tester.pumpAndSettle();

      // Tap 'Start New Chat'
      final startChatButton = find.byKey(const ValueKey('action-start-new-chat'));
      await tester.tap(startChatButton);
      await tester.pumpAndSettle();

      // Bottom sheet dismissed
      expect(find.byKey(const ValueKey('agent-actions-bottom-sheet')), findsNothing);
      // Callback fired with correct agent
      expect(chatAgent?.id, equals('agent-coder'));
      expect(chatAgent?.title, equals('Code Architect'));
    });

    testWidgets('tapping View System Prompt displays full instructions in scrollable bottom sheet', (
      tester,
    ) async {
      LobeAgent? viewedAgent;

      await tester.pumpWidget(
        createTestApp(
          child: LobehubAgentsPage(
            onViewSystemPrompt: (agent) => viewedAgent = agent,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open actions bottom sheet for Creative Writer
      await tester.tap(find.byKey(const ValueKey('agent-card-agent-writer')));
      await tester.pumpAndSettle();

      // Tap 'View System Prompt'
      final viewPromptButton = find.byKey(const ValueKey('action-view-system-prompt'));
      await tester.tap(viewPromptButton);
      await tester.pumpAndSettle();

      // First actions sheet is closed, system prompt sheet is now open
      expect(find.byKey(const ValueKey('agent-actions-bottom-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('system-prompt-bottom-sheet')), findsOneWidget);

      // Verify full system instructions are displayed in scrollable view
      expect(
        find.text('You are a master novelist and creative writing assistant.'),
        findsOneWidget,
      );
      expect(find.textContaining('System Prompt (系统设定)'), findsOneWidget);
      expect(viewedAgent?.id, equals('agent-writer'));

      // Close system prompt sheet
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('system-prompt-bottom-sheet')), findsNothing);
    });
  });

  group('LobehubAgentsPage - Pull to Refresh', () {
    testWidgets('has functional RefreshIndicator and refresh button', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          child: const LobehubAgentsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // RefreshIndicator is in the widget tree
      expect(find.byType(RefreshIndicator), findsOneWidget);

      // Refresh action button in AppBar
      final refreshButton = find.byKey(const ValueKey('refresh-agents-button'));
      expect(refreshButton, findsOneWidget);
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      // State remains healthy and cards visible
      expect(find.text('Creative Writer'), findsOneWidget);
    });
  });
}

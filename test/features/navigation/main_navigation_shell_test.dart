import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';

import 'package:conduit/features/agents/views/lobe_agents_page.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:conduit/features/settings/views/lobe_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

Widget createTestHarness({
  required Widget child,
  List<Override> overrides = const [],
  Size size = const Size(390, 844),
  TargetPlatform platform = TargetPlatform.android,
}) {
  PlatformUiCapabilities.debugPlatformOverride = platform;
  final theme = AppTheme.light(TweakcnThemes.conduit);

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: theme,
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

      // Verify Tab 0 (Chats)
      expect(find.text('Chats'), findsWidgets);
      expect(find.byIcon(Icons.chat_bubble_outline), findsWidgets);

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
      // Agents and Settings pages are in the IndexedStack but not active
      expect(find.byType(LobeAgentsPage), findsOneWidget);
      expect(find.byType(LobeSettingsPage), findsOneWidget);
    });

    testWidgets('switches seamlessly to Tab 1 (Agents) on tap', (tester) async {
      final sampleAgent = LobeAgent(
        id: 'agent-writer',
        title: 'Creative Writer',
        description: 'Assists with creative writing and storytelling.',
        model: 'gpt-4o',
      );

      final container = ProviderContainer(
        overrides: [
          lobeAgentsProvider.overrideWith(
            () => _TestAgentsNotifier(
              LobeAgentsState(
                agents: [sampleAgent],
                isLoading: false,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.conduit),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const MainNavigationShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Tab 1 (Agents)
      await tester.tap(find.byKey(const ValueKey('nav-tab-1')));
      await tester.pumpAndSettle();

      // Verify Agents page content is visible
      expect(find.byType(LobeAgentsPage), findsOneWidget);
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
      expect(find.text('PREFERENCES'), findsOneWidget);
      expect(find.text('ABOUT'), findsOneWidget);
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
      expect(find.byType(LobeAgentsPage), findsOneWidget);

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
      expect(find.byType(LobeAgentsPage), findsOneWidget);

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
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.conduit),
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
  });
}

class _TestAgentsNotifier extends LobeAgentsNotifier {
  _TestAgentsNotifier(this._initialState);

  final LobeAgentsState _initialState;

  @override
  LobeAgentsState build() => _initialState;
}

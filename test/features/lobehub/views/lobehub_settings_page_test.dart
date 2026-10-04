import 'package:flutter/material.dart' as flutter_material;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:conduit/features/lobehub/views/lobehub_settings_page.dart';
import 'package:conduit/features/settings/views/lobe_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

void _setTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget createTestHarness({
  required Widget child,
  List<Override> overrides = const [],
  Size size = const Size(390, 844),
}) {
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
  final theme = AppTheme.light(TweakcnThemes.conduit);

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: theme,
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: flutter_material.ScaffoldMessenger(
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: child,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LobehubSettingsPage - Server & User Info', () {
    testWidgets('renders default server URL and online indicator correctly', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestHarness(
          child: const LobehubSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      // Verify Section Header
      expect(find.text('SERVER CONNECTION'), findsOneWidget);

      // Verify default server URL is displayed
      expect(find.byKey(const Key('lobehub-server-url-text')), findsOneWidget);
      expect(find.text('https://ai.opw.ink'), findsOneWidget);

      // Verify online status indicator
      expect(
        find.byKey(const Key('lobehub-server-status-indicator')),
        findsOneWidget,
      );
      expect(find.text('Online'), findsOneWidget);
    });

    testWidgets('renders custom server URL and user profile information', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestHarness(
          child: const LobehubSettingsPage(
            initialServerUrl: 'https://lobe.my-corp.internal',
            initialServerName: 'Corporate LobeHub',
            initialUserName: 'Alice Developer',
            initialUserRole: 'Administrator',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Corporate LobeHub'), findsOneWidget);
      expect(find.text('https://lobe.my-corp.internal'), findsOneWidget);
      expect(find.text('Alice Developer'), findsOneWidget);
      expect(find.text('Role: Administrator'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
    });

    testWidgets('tapping Modify Connection / Sign Out shows confirmation dialog', (
      tester,
    ) async {
      bool signOutCalled = false;

      await tester.pumpWidget(
        createTestHarness(
          child: LobehubSettingsPage(
            onSignOut: () {
              signOutCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find and tap the sign out / modify connection button
      final signOutBtn = find.byKey(const Key('lobehub-sign-out-button'));
      expect(signOutBtn, findsOneWidget);
      await tester.tap(signOutBtn);
      await tester.pumpAndSettle();

      // Confirmation dialog should be displayed
      expect(
        find.byKey(const Key('lobehub-sign-out-dialog')),
        findsOneWidget,
      );
      expect(
        find.text('Modify Connection / Sign Out (修改连接 / 重新登录)'),
        findsWidgets,
      );

      // Test Cancel Path
      final cancelBtn = find.byKey(const Key('lobehub-sign-out-cancel-button'));
      expect(cancelBtn, findsOneWidget);
      await tester.tap(cancelBtn);
      await tester.pumpAndSettle();

      // Dialog dismissed, onSignOut was NOT called
      expect(find.byKey(const Key('lobehub-sign-out-dialog')), findsNothing);
      expect(signOutCalled, isFalse);

      // Open dialog again and test Confirm Path
      await tester.tap(signOutBtn);
      await tester.pumpAndSettle();

      final confirmBtn = find.byKey(const Key('lobehub-sign-out-confirm-button'));
      expect(confirmBtn, findsOneWidget);
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      // On confirm, callback was invoked
      expect(signOutCalled, isTrue);
    });
  });

  group('LobehubSettingsPage - Appearance & Theme Switcher Reactivity', () {
    testWidgets('renders 3-way theme toggle and switches reactively', (
      tester,
    ) async {
      ThemeMode? lastSelectedTheme;

      await tester.pumpWidget(
        createTestHarness(
          child: LobehubSettingsPage(
            initialThemeMode: ThemeMode.system,
            onThemeModeChanged: (mode) {
              lastSelectedTheme = mode;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('APPEARANCE & THEME'), findsOneWidget);

      // Verify all 3 mode buttons exist
      final systemBtn = find.byKey(const Key('lobehub-theme-system-button'));
      final lightBtn = find.byKey(const Key('lobehub-theme-light-button'));
      final darkBtn = find.byKey(const Key('lobehub-theme-dark-button'));

      expect(systemBtn, findsOneWidget);
      expect(lightBtn, findsOneWidget);
      expect(darkBtn, findsOneWidget);

      // Tap Dark Mode
      await tester.tap(darkBtn);
      await tester.pumpAndSettle();
      expect(lastSelectedTheme, equals(ThemeMode.dark));

      // Tap Light Mode
      await tester.tap(lightBtn);
      await tester.pumpAndSettle();
      expect(lastSelectedTheme, equals(ThemeMode.light));

      // Tap System Mode
      await tester.tap(systemBtn);
      await tester.pumpAndSettle();
      expect(lastSelectedTheme, equals(ThemeMode.system));
    });
  });

  group('LobehubSettingsPage - Typography & Font Size', () {
    testWidgets('renders preset buttons and slider, updating scale reactively', (
      tester,
    ) async {
      double? lastReportedScale;

      await tester.pumpWidget(
        createTestHarness(
          child: LobehubSettingsPage(
            onFontScaleChanged: (scale) {
              lastReportedScale = scale;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('TYPOGRAPHY & FONT SIZE'), findsOneWidget);
      expect(
        find.byKey(const Key('lobehub-font-scale-current-label')),
        findsOneWidget,
      );
      expect(find.text('100% · Standard (标准)'), findsOneWidget);

      final smallBtn = find.byKey(const Key('lobehub-font-scale-small-button'));
      final standardBtn = find.byKey(
        const Key('lobehub-font-scale-standard-button'),
      );
      final largeBtn = find.byKey(const Key('lobehub-font-scale-large-button'));
      final slider = find.byKey(const Key('lobehub-font-scale-slider'));

      expect(smallBtn, findsOneWidget);
      expect(standardBtn, findsOneWidget);
      expect(largeBtn, findsOneWidget);
      expect(slider, findsOneWidget);

      // Tap Small preset
      await tester.tap(smallBtn);
      await tester.pumpAndSettle();
      expect(lastReportedScale, equals(0.85));
      expect(find.text('85% · Small (小号)'), findsOneWidget);

      // Tap Large preset
      await tester.tap(largeBtn);
      await tester.pumpAndSettle();
      expect(lastReportedScale, equals(1.15));
      expect(find.text('115% · Large (大号)'), findsOneWidget);

      // Tap Standard preset
      await tester.tap(standardBtn);
      await tester.pumpAndSettle();
      expect(lastReportedScale, equals(1.0));
      expect(find.text('100% · Standard (标准)'), findsOneWidget);
    });
  });

  group('LobehubSettingsPage - Data & Storage (Clear Cache Safety)', () {
    testWidgets('Cancel path leaves cache intact without calling clear or showing toast', (
      tester,
    ) async {
      _setTallViewport(tester);
      bool clearCacheCalled = false;

      await tester.pumpWidget(
        createTestHarness(
          child: LobehubSettingsPage(
            onClearCache: () {
              clearCacheCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final clearCacheBtn = find.byKey(
        const Key('lobehub-clear-cache-button'),
      );
      await tester.scrollUntilVisible(clearCacheBtn, 200);

      expect(find.text('DATA & STORAGE'), findsOneWidget);
      expect(clearCacheBtn, findsOneWidget);

      // Tap button to open dialog
      await tester.tap(clearCacheBtn);
      await tester.pumpAndSettle();

      // Verify safety confirmation dialog
      expect(
        find.byKey(const Key('lobehub-clear-cache-dialog')),
        findsOneWidget,
      );
      expect(find.text('Clear Local Cache (清空本地缓存)'), findsOneWidget);

      // Tap Cancel button
      final cancelBtn = find.byKey(
        const Key('lobehub-clear-cache-cancel-button'),
      );
      expect(cancelBtn, findsOneWidget);
      await tester.tap(cancelBtn);
      await tester.pumpAndSettle();

      // Dialog dismissed, cache was NOT cleared, toast not shown
      expect(
        find.byKey(const Key('lobehub-clear-cache-dialog')),
        findsNothing,
      );
      expect(clearCacheCalled, isFalse);
      expect(find.text('Local cache cleared'), findsNothing);
    });

    testWidgets('Confirm path triggers clear callback and shows success toast', (
      tester,
    ) async {
      _setTallViewport(tester);
      bool clearCacheCalled = false;

      await tester.pumpWidget(
        createTestHarness(
          child: LobehubSettingsPage(
            onClearCache: () {
              clearCacheCalled = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final clearCacheBtn = find.byKey(
        const Key('lobehub-clear-cache-button'),
      );
      await tester.scrollUntilVisible(clearCacheBtn, 200);
      await tester.tap(clearCacheBtn);
      await tester.pumpAndSettle();

      // Tap Confirm button
      final confirmBtn = find.byKey(
        const Key('lobehub-clear-cache-confirm-button'),
      );
      expect(confirmBtn, findsOneWidget);
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      // Dialog dismissed
      expect(
        find.byKey(const Key('lobehub-clear-cache-dialog')),
        findsNothing,
      );

      // Cache clear callback was executed
      expect(clearCacheCalled, isTrue);

      // Success toast / SnackBar is displayed
      expect(find.byKey(const Key('lobehub-clear-cache-toast')), findsOneWidget);
      expect(find.text('Local cache cleared'), findsOneWidget);
    });
  });

  group('LobehubSettingsPage - About Section', () {
    testWidgets('renders all about section information accurately', (
      tester,
    ) async {
      _setTallViewport(tester);
      await tester.pumpWidget(
        createTestHarness(
          child: const LobehubSettingsPage(
            version: 'v1.0.0-rc1',
            licenseText: 'GPL-3.0 License',
            repoCredits: 'GitHub: cogwheel0/conduit & LobeHub',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('ABOUT'), 200);

      // Verify About section exists
      expect(find.text('ABOUT'), findsOneWidget);

      // Verify App Title
      expect(
        find.byKey(const Key('lobehub-about-app-title')),
        findsOneWidget,
      );
      expect(find.text('LobeChat Native (Conduit Edition)'), findsOneWidget);

      // Verify Version
      expect(
        find.byKey(const Key('lobehub-about-version-text')),
        findsOneWidget,
      );
      expect(find.text('v1.0.0-rc1'), findsOneWidget);

      // Verify License link
      expect(
        find.byKey(const Key('lobehub-about-license-text')),
        findsOneWidget,
      );
      expect(find.text('License: GPL-3.0 License'), findsOneWidget);

      // Verify GitHub repo credits
      expect(
        find.byKey(const Key('lobehub-about-credits-text')),
        findsOneWidget,
      );
      expect(find.text('GitHub: cogwheel0/conduit & LobeHub'), findsOneWidget);
    });
  });

  group('LobeSettingsPage - Re-export & Backward Compatibility', () {
    testWidgets('LobeSettingsPage typedef creates LobehubSettingsPage seamlessly', (
      tester,
    ) async {
      _setTallViewport(tester);
      await tester.pumpWidget(
        createTestHarness(
          child: const LobeSettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LobeSettingsPage), findsOneWidget);
      expect(find.byType(LobehubSettingsPage), findsOneWidget);
      expect(find.text('SERVER CONNECTION'), findsOneWidget);
      expect(find.text('APPEARANCE & THEME'), findsOneWidget);
      expect(find.text('TYPOGRAPHY & FONT SIZE'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('DATA & STORAGE'), 200);
      expect(find.text('DATA & STORAGE'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('PREFERENCES'), 200);
      expect(find.text('PREFERENCES'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('ABOUT'), 200);
      expect(find.text('ABOUT'), findsOneWidget);
    });
  });
}

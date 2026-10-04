import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit/features/chat/views/chat_page.dart';
import 'package:conduit/features/lobehub/widgets/lobehub_role_header.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart' as legacy_material show Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_fonts.dart';
import 'role_test_harness.dart';

Conversation _conversation({
  Map<String, dynamic>? metadata,
  String agentTitle = 'Coding Specialist',
}) => Conversation(
  id: 'tpc_verified',
  title: 'User-renamed conversation, not role title',
  createdAt: DateTime.utc(2026, 10, 4),
  updatedAt: DateTime.utc(2026, 10, 4),
  model: 'shared-model',
  metadata: metadata ?? {
    'backend': 'lobehub',
    'agentId': 'agt_coder_42',
    'agentTitle': agentTitle,
    'agentModel': 'shared-model',
    'provider': 'deepseek',
  },
);

Future<void> _loadRoleFonts() async {
  await loadTestFonts();
  final cjkPath = Platform.environment['ROLE_UI_CJK_FONT'];
  if (Platform.environment.containsKey('ROLE_UI_EVIDENCE_DIR')) {
    expect(cjkPath, isNotNull, reason: 'CJK captures require a real CJK font');
  }
  if (cjkPath != null) {
    final cjk = await File(cjkPath).readAsBytes();
    await (FontLoader('RoleCjk')
          ..addFont(Future.value(ByteData.sublistView(cjk))))
        .load();
  }
  await (FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
      .load();
}

ThemeData _roleTheme(bool dark) {
  final theme = dark
      ? AppTheme.dark(TweakcnThemes.conduit)
      : AppTheme.light(TweakcnThemes.conduit);
  TextStyle? withFont(TextStyle? style) => style?.copyWith(
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['RoleCjk'],
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['RoleCjk'],
    ),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: 'Roboto',
      fontFamilyFallback: const ['RoleCjk'],
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: withFont(theme.appBarTheme.titleTextStyle),
      toolbarTextStyle: withFont(theme.appBarTheme.toolbarTextStyle),
    ),
  );
}

void _setViewport(WidgetTester tester, double width) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _registerHarnessCleanup(WidgetTester tester, RoleHarness harness) {
  addTearDown(harness.close);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

void _expectRoleLayout(WidgetTester tester, String title) {
  final header = find.byKey(const ValueKey('lobehub-role-header'));
  final titleFinder = find.byKey(const ValueKey('lobehub-role-title'));
  final configurationFinder = find.byKey(
    const ValueKey('lobehub-role-configuration'),
  );
  final headerRect = tester.getRect(header);
  final titleRect = tester.getRect(titleFinder);
  final configurationRect = tester.getRect(configurationFinder);
  final titleText = tester.widget<Text>(titleFinder);
  final configurationText = tester.widget<Text>(configurationFinder);
  final context = tester.element(header);
  expect(titleText.data, title);
  expect(configurationText.data, 'shared-model / deepseek');
  expect(titleText.maxLines, 1);
  expect(configurationText.maxLines, 1);
  expect(titleText.overflow, TextOverflow.ellipsis);
  expect(configurationText.overflow, TextOverflow.ellipsis);
  expect(titleText.style!.color, context.conduitTheme.textPrimary);
  expect(configurationText.style!.color, context.conduitTheme.textSecondary);
  expect(titleText.style!.fontSize, greaterThan(configurationText.style!.fontSize!));
  expect(headerRect.height, greaterThanOrEqualTo(TouchTarget.minimum));
  expect(headerRect.left, greaterThanOrEqualTo(0));
  expect(headerRect.right, lessThanOrEqualTo(MediaQuery.sizeOf(context).width));
  expect(titleRect.bottom, lessThanOrEqualTo(configurationRect.top));
  expect(titleRect.top, greaterThanOrEqualTo(headerRect.top));
  expect(configurationRect.bottom, lessThanOrEqualTo(headerRect.bottom));
  expect(titleRect.left, greaterThanOrEqualTo(headerRect.left));
  expect(configurationRect.right, lessThanOrEqualTo(headerRect.right));
  expect(tester.takeException(), isNull);
}

class _RoleToolbar extends ConsumerWidget {
  const _RoleToolbar({this.isLoading = false});
  final bool isLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = LobeHubRolePresentation.fromConversation(ref.watch(activeConversationProvider))!;
    return AdaptiveScaffold(
        appBar: buildConduitCenteredAdaptiveAppBar(
          context: context,
          tintColor: context.conduitTheme.textPrimary,
          centerTitle: false,
          leading: ConduitAdaptiveAppBarIconButton(icon: Icons.menu,
              semanticLabel: 'Chats', onPressed: () {}),
          title: LobeHubRoleHeader(
            role: role,
            maxWidth: resolveConduitAdaptiveLeadingPillWidth(context,
                trailingActionCount: 2,
                maxWidth: kConduitAdaptiveToolbarMaxModelSelectorWidth),
            isLoading: isLoading,
          ),
          actions: buildConduitAdaptiveToolbarActionWidgets([
            ConduitAdaptiveAppBarIconButton(icon: Icons.add_comment,
                semanticLabel: 'New chat', onPressed: () {}),
            ConduitAdaptiveAppBarIconButton(icon: Icons.more_horiz,
                semanticLabel: 'Chat actions', onPressed: () {}),
          ]),
        ),
        body: const Center(child: Text('Bound Agent conversation')),
      );
  }
}

Future<void> _mount(WidgetTester tester, RoleHarness harness, {
  bool dark = false,
  bool isLoading = false,
  double textScale = 1,
}) async {
  await tester.runAsync(harness.initialize);
  harness.container.read(activeConversationProvider.notifier).set(
    _conversation(agentTitle: harness.agent.title!),
  );
  harness.container.read(mainNavigationIndexProvider.notifier).state = 0;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: harness.container,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _roleTheme(dark),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: LegacyDesignCompatibility(child: child!),
      ),
      home: RepaintBoundary(
        key: const ValueKey('role-surface-capture'),
        child: MainNavigationShell(
          chatsView: _RoleToolbar(isLoading: isLoading),
          settingsView: const Center(child: Text('Settings')),
        ),
      ),
    ),
  ));
  await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['ROLE_UI_EVIDENCE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('role-surface-capture')));
  expect(boundary.debugNeedsPaint, isFalse);
  final context = tester.element(find.byKey(const ValueKey('role-surface-capture')));
  final textScale = MediaQuery.textScalerOf(context).scale(10) / 10;
  final dark = context.conduitTheme.isDark;
  final container = ProviderScope.containerOf(context);
  final navigationIndex = container.read(mainNavigationIndexProvider);
  final role = LobeHubRolePresentation.fromConversation(
    container.read(activeConversationProvider),
  )!;
  await tester.runAsync(() async {
    expect(await Directory(directory).exists(), isTrue);
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      expect(image.width, boundary.size.width.round());
      expect(image.height, boundary.size.height.round());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);
      final png = bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      final file = File('$directory/$name.png');
      await file.writeAsBytes(png, flush: true);
      final written = await file.readAsBytes();
      expect(written.take(8), orderedEquals([137, 80, 78, 71, 13, 10, 26, 10]));
      final header = ByteData.sublistView(written);
      expect(header.getUint32(16), image.width);
      expect(header.getUint32(20), image.height);
      final codec = await ui.instantiateImageCodec(written);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, image.width);
          expect(frame.image.height, image.height);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      await File('$directory/$name.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'surface': 'Real Flutter widget-test engine render; not Android on-device or browser',
          'capture': 'RenderRepaintBoundary.toImage',
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'width': image.width,
          'height': image.height,
          'pixelRatio': 1,
          'textScale': textScale,
          'theme': dark ? 'Conduit dark' : 'Conduit light',
          'navigationIndex': navigationIndex,
          'agentId': role.agentId,
          'agentTitle': role.title,
          'configuredModel': role.modelId,
          'provider': role.provider,
          'accessibleLabel': role.accessibleLabel,
          'fonts': {
            'latin': 'test/assets/fonts/Roboto.ttf',
            'cjk': Platform.environment['ROLE_UI_CJK_FONT'],
            'icons': 'fonts/MaterialIcons-Regular.otf',
          },
          'pngSignatureVerified': true,
          'pngDecodedDimensionsVerified': true,
        }),
        flush: true,
      );
    } finally {
      image.dispose();
    }
  });
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(_loadRoleFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    PreferencesStore.debugReset();
    PlatformUiCapabilities.resetDebugOverrides();
  });

  test('role presentation trusts bound topic metadata, never conversation title or global model', () {
    final role = LobeHubRolePresentation.fromConversation(_conversation())!;
    expect(role.title, 'Coding Specialist');
    expect(role.agentId, roleAgent.id);
    expect(role.configurationLabel, 'shared-model / deepseek');
    expect(role.accessibleLabel, contains('Read-only'));
    expect(LobeHubRolePresentation.fromConversation(_conversation(metadata: const {})), isNull);
    expect(LobeHubRolePresentation.fromConversation(_conversation(metadata: const {
      'backend': 'hermes', 'agentId': 'hermes-bot', 'agentTitle': 'Hermes',
    })), isNull);
    expect(shouldShowChatModelDropdown(selectedModel: foreignModel, isHermesOnly: false), isTrue);
    final missing = LobeHubRolePresentation.fromConversation(_conversation(metadata: const {
      'backend': 'lobehub', 'agentId': 'agt_unknown',
    }))!;
    expect(missing.title, 'agt_unknown');
    expect(missing.configurationLabel, 'Model unavailable / Provider unavailable');
  });

  testWidgets('role title plus read-only configuration remains accessible and opens actual Agents tab', (tester) async {
    _setViewport(tester, 375);
    final harness = RoleHarness();
    _registerHarnessCleanup(tester, harness);
    final semantics = tester.ensureSemantics();
    try {
      await _mount(tester, harness);
      expect(find.text('Coding Specialist'), findsOneWidget);
      expect(find.text('shared-model / deepseek'), findsOneWidget);
      expect(find.text(foreignModel.name), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Agent: Coding Specialist.*Read-only')), findsOneWidget);
      final header = find.byKey(const ValueKey('lobehub-role-header'));
      expect(tester.getSize(header).height, greaterThanOrEqualTo(TouchTarget.minimum));
      _expectRoleLayout(tester, roleAgent.title!);
      await _capture(tester, 'role-header-light');
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(harness.container.read(mainNavigationIndexProvider), 1);
      expect(harness.container.read(lobeAgentsProvider).selectedAgentId, roleAgent.id);
      expect(find.byType(LobehubAgentsPage), findsOneWidget);
      expect(find.byKey(ValueKey('agent-card-${roleAgent.id}')), findsOneWidget);
      expect(find.text('More models'), findsNothing);
      await _capture(tester, 'role-header-agents-destination');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    }
  });

  testWidgets('loading role cannot navigate and keyboard activation uses the existing tab', (tester) async {
    _setViewport(tester, 375);
    final harness = RoleHarness();
    _registerHarnessCleanup(tester, harness);
    await _mount(tester, harness, isLoading: true);
    await tester.tap(find.byKey(const ValueKey('lobehub-role-header')));
    expect(harness.container.read(mainNavigationIndexProvider), 0);
    await _mount(tester, harness);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(harness.container.read(mainNavigationIndexProvider), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 375.0, 768.0, 1280.0]) {
    for (final dark in [false, true]) {
      testWidgets('role toolbar at $width ${dark ? 'dark' : 'light'} is bounded and stable under global model changes', (tester) async {
        _setViewport(tester, width);
        final harness = RoleHarness();
        _registerHarnessCleanup(tester, harness);
        await _mount(tester, harness, dark: dark);
        harness.container.read(selectedModelProvider.notifier).set(foreignModel);
        await tester.pump();
        expect(find.text('Coding Specialist'), findsOneWidget);
        expect(find.text('shared-model / deepseek'), findsOneWidget);
        expect(tester.takeException(), isNull);
        _expectRoleLayout(tester, roleAgent.title!);
        await _capture(tester, 'role-header-${width.toInt()}-${dark ? 'dark' : 'light'}');
        await tester.tap(find.byKey(const ValueKey('lobehub-role-header')));
        await tester.pumpAndSettle();
        expect(harness.container.read(mainNavigationIndexProvider), 1);
        expect(harness.container.read(lobeAgentsProvider).selectedAgentId, roleAgent.id);
        expect(find.byType(LobehubAgentsPage), findsOneWidget);
        expect(find.byKey(ValueKey('agent-card-${roleAgent.id}')).hitTestable(), findsOneWidget);
        expect(find.text('More models'), findsNothing);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'role-agents-${width.toInt()}-${dark ? 'dark' : 'light'}');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final dark in [false, true]) {
    testWidgets('long CJK role at 320 ${dark ? 'dark' : 'light'} preserves full identity at text scale 1.3', (tester) async {
      _setViewport(tester, 320);
      const title = '多语言软件架构与代码审查专家及复杂系统问题解决助手';
      final harness = RoleHarness(agent: roleAgent.copyWith(title: title));
      _registerHarnessCleanup(tester, harness);
      final semantics = tester.ensureSemantics();
      try {
        await _mount(tester, harness, dark: dark, textScale: 1.3);
        harness.container.read(selectedModelProvider.notifier).set(foreignModel);
        await tester.pump();
        _expectRoleLayout(tester, title);
        final header = find.byKey(const ValueKey('lobehub-role-header'));
        final presentation = LobeHubRolePresentation.fromConversation(
          harness.container.read(activeConversationProvider),
        )!;
        expect(find.bySemanticsLabel(presentation.accessibleLabel), findsOneWidget);
        expect(presentation.accessibleLabel, contains(title));
        expect(presentation.accessibleLabel, contains('Configured model: shared-model'));
        expect(presentation.accessibleLabel, contains('Provider: deepseek'));
        expect(presentation.accessibleLabel, contains('per-turn model overrides'));
        expect(tester.getSize(header).height, greaterThanOrEqualTo(TouchTarget.minimum * 1.3));
        final tooltipFinder = find.ancestor(
          of: header,
          matching: find.byType(legacy_material.Tooltip),
        );
        expect(
          tester.widget<legacy_material.Tooltip>(tooltipFinder).message,
          presentation.accessibleLabel,
        );
        await _capture(tester, 'role-header-320-cjk-scale-1_3-${dark ? 'dark' : 'light'}');
        await tester.tap(header);
        await tester.pumpAndSettle();
        expect(harness.container.read(mainNavigationIndexProvider), 1);
        expect(harness.container.read(lobeAgentsProvider).selectedAgentId, roleAgent.id);
        expect(find.byType(LobehubAgentsPage), findsOneWidget);
        expect(find.byKey(ValueKey('agent-card-${roleAgent.id}')).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'role-agents-320-cjk-scale-1_3-${dark ? 'dark' : 'light'}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    });
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit/features/lobehub/providers/lobehub_chat_start_provider.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'role_test_harness.dart';

Future<BuildContext> _host(WidgetTester tester, RoleHarness harness) async {
  late BuildContext host;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: harness.container,
    child: MaterialApp(
      theme: ThemeData.light(),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) {
        host = context;
        return const Text('Online role test host');
      })),
    ),
  ));
  await tester.runAsync(harness.initialize);
  return host;
}

Future<bool> _start(
  WidgetTester tester,
  RoleHarness harness,
  BuildContext context,
) async => (await tester.runAsync(() => harness.container
        .read(lobehubChatStartProvider.notifier)
        .startAgentChat(context: context, agent: harness.agent)))!;

void _expectFailure(RoleHarness harness) {
  expect(harness.container.read(lobehubChatStartProvider).isStarting, isFalse);
  expect(harness.container.read(lobehubChatStartProvider).error, isNotEmpty);
  expect(harness.container.read(mainNavigationIndexProvider), 1);
  expect(harness.container.read(selectedModelProvider), foreignModel);
  expect(harness.container.read(activeConversationProvider), isNull);
}

void main() {
  setUp(() async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(() {
    PreferencesStore.debugReset();
    PlatformUiCapabilities.resetDebugOverrides();
  });

  testWidgets('online creation binds exact Agent and survives production reload and Drift reopen', (tester) async {
    final harness = RoleHarness();
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isTrue);
    expect(harness.creationPayloads.single, {
      'title': roleAgent.title,
      'agentId': roleAgent.id,
    });
    expect(harness.detailCalls, greaterThanOrEqualTo(2));
    final active = harness.container.read(activeConversationProvider)!;
    expect(active.id, 'tpc_verified');
    expect(active.model, roleAgent.model);
    expect(active.metadata, containsPair('backend', 'lobehub'));
    expect(active.metadata, containsPair('agentId', roleAgent.id));
    expect(active.metadata, containsPair('agentTitle', roleAgent.title));
    expect(active.metadata, containsPair('agentModel', roleAgent.model));
    expect(active.metadata, containsPair('provider', roleAgent.provider));
    expect(harness.container.read(selectedModelProvider)!.metadata?['provider'], 'deepseek');
    expect(harness.container.read(selectedModelProvider)!.id, isNot(roleAgent.id));
    expect(harness.container.read(mainNavigationIndexProvider), 0);
    expect(harness.container.read(lobehubChatStartProvider).isStarting, isFalse);

    await tester.runAsync(() async {
      await harness.container.read(syncEngineProvider.notifier).pullChatNow(active.id);
      final row = await harness.database.chatsDao.getChat(active.id);
      expect(row, isNotNull);
      expect(jsonDecode(row!.meta), containsPair('agentId', roleAgent.id));
      expect(jsonDecode(row.meta), containsPair('provider', roleAgent.provider));
      harness.container.read(activeConversationProvider.notifier).clear();
      harness.container.read(selectedModelProvider.notifier).set(foreignModel);
      final reopened = await harness.container
          .read(conversationSelectionProvider.notifier).select(active);
      expect(reopened.disposition, ConversationSelectionDisposition.committed);
    });
    final reopened = harness.container.read(activeConversationProvider)!;
    expect(reopened.model, roleAgent.model);
    expect(reopened.metadata['agentTitle'], roleAgent.title);
    expect(reopened.metadata['agentId'], roleAgent.id);
    expect(reopened.metadata['provider'], roleAgent.provider);
  });

  testWidgets('missing client cannot fabricate a successful offline Agent topic', (tester) async {
    final harness = RoleHarness(clientAvailable: false);
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
    expect(harness.creationPayloads, isEmpty);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  for (final status in [401, 500]) {
    testWidgets('Agent detail HTTP $status is visible and never uses stale card configuration', (tester) async {
      final harness = RoleHarness()..detailStatus = status;
      addTearDown(harness.close);
      final context = await _host(tester, harness);
      expect(await _start(tester, harness, context), isFalse);
      _expectFailure(harness);
      expect(harness.creationPayloads, isEmpty);
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
    });
  }

  testWidgets('unavailable configured provider does not match ID-only or invent a model', (tester) async {
    final harness = RoleHarness()..models.removeWhere((model) => model['provider'] == 'deepseek');
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
    expect(harness.creationPayloads, isEmpty);
    expect(harness.container.read(lobehubChatStartProvider).error, contains('deepseek'));
  });

  testWidgets('self-referential Agent model is rejected rather than dispatching first roster entry', (tester) async {
    final harness = RoleHarness()..detail = roleAgent.copyWith(model: roleAgent.id).toJson();
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
    expect(harness.creationPayloads, isEmpty);
  });

  testWidgets('failed topic POST keeps model and Agents tab unchanged', (tester) async {
    final harness = RoleHarness()..creationStatus = 500;
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Failed to create topic'), findsOneWidget);
  });

  for (final returnedAgent in [null, 'agt_someone_else']) {
    testWidgets('returned topic Agent $returnedAgent must not be patched into apparent success', (tester) async {
      final harness = RoleHarness()..returnedAgentId = returnedAgent;
      addTearDown(harness.close);
      final context = await _host(tester, harness);
      expect(await _start(tester, harness, context), isFalse);
      _expectFailure(harness);
    });
  }

  for (final returnedId in ['', 'local_123', 'local:123']) {
    testWidgets('unverified topic ID "$returnedId" is rejected', (tester) async {
      final harness = RoleHarness()..returnedTopicId = returnedId;
      addTearDown(harness.close);
      final context = await _host(tester, harness);
      expect(await _start(tester, harness, context), isFalse);
      _expectFailure(harness);
    });
  }

  testWidgets('detail identity mismatch cannot start another Agent', (tester) async {
    final harness = RoleHarness()..detail = roleAgent.copyWith(id: 'agt_wrong').toJson();
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
    expect(harness.creationPayloads, isEmpty);
  });

  testWidgets('production selection reload failure keeps original model and tab', (tester) async {
    final harness = RoleHarness()..reloadStatus = 500;
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
  });

  for (final stage in ['detail', 'models', 'create', 'reload']) {
    testWidgets('same API account swap during $stage has no stale model/tab/selection commit', (tester) async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      Future<void> swap() async => harness.changeAccount('synthetic-account-b');
      switch (stage) {
        case 'detail': harness.beforeDetail = swap;
        case 'models': harness.beforeModels = swap;
        case 'create': harness.beforeCreate = swap;
        case 'reload': harness.beforeReload = swap;
      }
      final context = await _host(tester, harness);
      expect(await _start(tester, harness, context), isFalse);
      _expectFailure(harness);
      if (stage == 'detail' || stage == 'models') {
        expect(harness.creationPayloads, isEmpty);
      }
    });
  }

  testWidgets('expired authentication fails closed before any HTTP request', (tester) async {
    final harness = RoleHarness();
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    harness.changeAccount(null);
    expect(await _start(tester, harness, context), isFalse);
    _expectFailure(harness);
    expect(harness.adapter.requests, isEmpty);
  });

  testWidgets('unmounted host settles isStarting without late activation', (tester) async {
    final harness = RoleHarness();
    addTearDown(harness.close);
    final context = await _host(tester, harness);
    late Completer<void> entered;
    late Completer<void> released;
    late Future<bool> pending;
    await tester.runAsync(() async {
      entered = Completer<void>();
      released = Completer<void>();
      harness.beforeDetail = () async {
        entered.complete();
        await released.future;
      };
      pending = harness.container.read(lobehubChatStartProvider.notifier)
          .startAgentChat(context: context, agent: roleAgent);
      await entered.future;
    });
    await tester.pumpWidget(const SizedBox.shrink());
    expect(await tester.runAsync(() async {
      released.complete();
      return pending;
    }), isFalse);
    expect(harness.container.read(lobehubChatStartProvider).isStarting, isFalse);
    expect(harness.container.read(activeConversationProvider), isNull);
    expect(harness.creationPayloads, isEmpty);
  });

  testWidgets('Agent sheet retains REST media notice and uses actual online start action', (tester) async {
    final harness = RoleHarness();
    addTearDown(harness.close);
    await tester.runAsync(harness.initialize);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: ThemeData.light(),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: LobehubAgentsPage()),
      ),
    ));
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('agent-card-${roleAgent.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent-actions-media-notice-banner')), findsOneWidget);
    expect(find.textContaining('Server REST (2.2.17) lacks image and file analysis support'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('action-start-new-chat')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(harness.creationPayloads.single['agentId'], roleAgent.id);
    expect(harness.container.read(activeConversationProvider)!.metadata['agentId'], roleAgent.id);
    expect(harness.container.read(mainNavigationIndexProvider), 0);
  });
}

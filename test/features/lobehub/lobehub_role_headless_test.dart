import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'role_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  for (final selectedId in ['foreign-model', 'shared-model']) {
    test('real headless Agent completion ignores foreign global provider for $selectedId', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      final timestamp = DateTime.utc(2026, 10, 4);
      final messages = [
        ChatMessage(id: 'queued-user', role: 'user', content: 'Write Dart', timestamp: timestamp),
        ChatMessage(id: 'queued-assistant', role: 'assistant', content: '', timestamp: timestamp,
            model: roleAgent.model),
      ];
      for (var index = 0; index < messages.length; index++) {
        final message = messages[index];
        await harness.database.into(harness.database.messages).insert(
          MessagesCompanion.insert(
            id: message.id,
            chatId: conversation.id,
            role: message.role,
            content: message.content,
            model: Value(message.model),
            createdAt: timestamp.millisecondsSinceEpoch ~/ 1000,
            orderIndex: index,
            payload: jsonEncode(message.toJson()),
          ),
        );
      }
      harness.container.read(selectedModelProvider.notifier).set(Model(
        id: selectedId,
        name: 'Different Agent model',
        metadata: const {'provider': 'openrouter'},
      ));
      harness.beforeResponse = () async {
        final row = await harness.database.messagesDao.getMessage(conversation.id, 'queued-assistant');
        final metadata = (jsonDecode(row!.payload) as Map)['metadata'] as Map;
        expect((metadata['lobeAgentCorrelation'] as Map)['agentId'], roleAgent.id);
        expect(metadata['completionSubmitted'], isTrue);
      };
      await runHeadlessCompletion(
        harness.container,
        chatId: conversation.id,
        assistantMessageId: 'queued-assistant',
        messages: messages,
        conversation: conversation,
        model: roleAgent.model!,
        sessionIdOverride: 'synthetic-session',
      );
      expect(harness.responsePayloads.single['model'], roleAgent.id);
      expect(harness.responsePayloads.single['previous_response_id'], conversation.id);
      expect(harness.responsePayloads.single['input'], 'Write Dart');
      expect(harness.container.read(activeConversationProvider), isNull);
      expect(harness.container.read(selectedModelProvider)!.metadata?['provider'], 'openrouter');
      final row = await harness.database.messagesDao.getMessage(conversation.id, 'queued-assistant');
      expect(row, isNotNull);
      expect(row!.content, 'Verified role response');
      final reloaded = await harness.container.read(
        loadConversationProvider(conversationScopedId(conversation)).future,
      );
      expect(reloaded.metadata['agentId'], roleAgent.id);
      expect(reloaded.metadata['provider'], roleAgent.provider);
    });
  }

  group('submitted Agent recovery', () {
    test('reconciles delayed persistence before the next pull without inference', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      await _seedSubmittedTurn(harness, conversation);
      final owner = captureOpenWebUiCompletionOwner(harness.container, chatId: conversation.id);
      var messageReads = 0;
      harness.adapter.handlers['GET /api/v1/messages'] = (request) {
        expect(request.queryParameters['topicId'], conversation.id);
        messageReads++;
        if (messageReads == 2) harness.messages = _persistedAgentPair();
        return roleJson({'success': true, 'data': harness.messages});
      };

      await recoverSubmittedOpenWebUiCompletion(
        harness.container,
        owner: owner,
        assistantMessageId: 'queued-assistant',
        recoveryAttempts: 3,
        recoveryDelay: Duration.zero,
      );

      expect(messageReads, 4);
      final patches = harness.adapter.requests.where((request) => request.method == 'PATCH').toList();
      expect(patches.map((request) => request.uri.path), [
        '/api/v1/messages/server-user',
        '/api/v1/messages/server-assistant',
      ]);
      expect((harness.messages.first['metadata'] as Map)['conduitClientId'], 'queued-user');
      expect((harness.messages.last['metadata'] as Map)['conduitClientId'], 'queued-assistant');
      expect(harness.messages.every((message) => (message['metadata'] as Map)['serverOwned'] == true), isTrue);
      final rows = await harness.database.messagesDao.getForChat(conversation.id);
      expect(rows, hasLength(2));
      expect(rows.map((row) => row.id), ['queued-user', 'queued-assistant']);
      expect(rows.last.parentId, 'queued-user');
      expect(rows.last.content, 'Verified role response');
      final payload = jsonDecode(rows.last.payload) as Map;
      expect(payload['done'], isTrue);
      expect(payload['isStreaming'], isFalse);
      expect(payload['error'], isNull);
      expect(harness.adapter.requests.where((request) => request.method == 'POST'), isEmpty);
      expect(harness.container.read(activeConversationProvider), isNull);
    });

    test('later ambiguous persistence fails visibly without pull or inference replay', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      await _seedSubmittedTurn(harness, conversation);
      final owner = captureOpenWebUiCompletionOwner(harness.container, chatId: conversation.id);
      var messageReads = 0;
      harness.adapter.handlers['GET /api/v1/messages'] = (_) {
        messageReads++;
        return roleJson({'success': true, 'data': messageReads < 3 ? [] : [
          {'id': 'candidate-user-1', 'role': 'user', 'content': 'Write Dart'},
          {'id': 'candidate-user-2', 'role': 'user', 'content': 'Write Dart'},
        ]});
      };

      await recoverSubmittedOpenWebUiCompletion(
        harness.container,
        owner: owner,
        assistantMessageId: 'queued-assistant',
        recoveryAttempts: 3,
        recoveryDelay: Duration.zero,
      );

      expect(messageReads, 3);
      final rows = await harness.database.messagesDao.getForChat(conversation.id);
      expect(rows, hasLength(2));
      expect(rows.last.parentId, 'queued-user');
      expect(rows.last.content, isEmpty);
      final payload = jsonDecode(rows.last.payload) as Map;
      expect(payload['isStreaming'], isFalse);
      expect((payload['error'] as Map)['content'], isNotEmpty);
      expect((payload['metadata'] as Map)['completionSubmitted'], isTrue);
      expect(harness.adapter.requests.where((request) => request.method == 'PATCH' || request.method == 'POST'), isEmpty);
    });

    test('owner switch during persisted correlation read stops reconciliation and local writes', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      await _seedSubmittedTurn(harness, conversation);
      final owner = captureOpenWebUiCompletionOwner(harness.container, chatId: conversation.id);
      final before = (await harness.database.messagesDao
          .getMessage(conversation.id, 'queued-assistant'))!.payload;
      final requestCount = harness.adapter.requests.length;
      final entered = Completer<void>();
      final release = Completer<void>();
      final transaction = harness.database.transaction(() async {
        entered.complete();
        await release.future;
      });
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await transaction;
      });
      await entered.future.timeout(const Duration(seconds: 5));
      final recovery = recoverSubmittedOpenWebUiCompletion(
        harness.container,
        owner: owner,
        assistantMessageId: 'queued-assistant',
        recoveryAttempts: 3,
        recoveryDelay: Duration.zero,
      );
      try {
        harness.changeAccount('synthetic-account-b');
      } finally {
        release.complete();
        await transaction;
        await recovery;
      }

      expect(harness.adapter.requests, hasLength(requestCount));
      expect((await harness.database.messagesDao
          .getMessage(conversation.id, 'queued-assistant'))!.payload, before);
    });

    for (final result in ['pending', 'ambiguous', 'mapped']) {
      test('owner switch while reconciliation returns $result prevents pull and failure writes', () async {
        final harness = RoleHarness();
        addTearDown(harness.close);
        await harness.initialize();
        final conversation = (await harness.container
            .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
        await _seedSubmittedTurn(harness, conversation);
        final owner = captureOpenWebUiCompletionOwner(harness.container, chatId: conversation.id);
        final before = (await harness.database.messagesDao
            .getMessage(conversation.id, 'queued-assistant'))!.payload;
        final requestCount = harness.adapter.requests.length;
        if (result == 'mapped') {
          harness.messages = _persistedAgentPair();
          final patchAssistant = harness.adapter.handlers['PATCH /api/v1/messages/server-assistant']!;
          harness.adapter.handlers['PATCH /api/v1/messages/server-assistant'] = (request) async {
            final response = await patchAssistant(request);
            harness.changeAccount('synthetic-account-b');
            return response;
          };
        } else {
          harness.adapter.handlers['GET /api/v1/messages'] = (_) {
            harness.changeAccount('synthetic-account-b');
            return roleJson({'success': true, 'data': result == 'pending' ? [] : [
              {'id': 'candidate-user-1', 'role': 'user', 'content': 'Write Dart'},
              {'id': 'candidate-user-2', 'role': 'user', 'content': 'Write Dart'},
            ]});
          };
        }

        await recoverSubmittedOpenWebUiCompletion(
          harness.container,
          owner: owner,
          assistantMessageId: 'queued-assistant',
          recoveryAttempts: 3,
          recoveryDelay: Duration.zero,
        );

        final recoveryRequests = harness.adapter.requests.skip(requestCount).toList();
        expect(recoveryRequests.map((request) => '${request.method} ${request.uri.path}'), [
          'GET /api/v1/messages',
          if (result == 'mapped') 'PATCH /api/v1/messages/server-user',
          if (result == 'mapped') 'PATCH /api/v1/messages/server-assistant',
        ]);
        expect((await harness.database.messagesDao
            .getMessage(conversation.id, 'queued-assistant'))!.payload, before);
        expect(await harness.database.messagesDao.getForChat(conversation.id), hasLength(2));
        expect(harness.container.read(activeConversationProvider), isNull);
      });
    }
  });

  for (final foreground in [false, true]) {
    final mode = foreground ? 'foreground' : 'headless';
    for (final provider in ['deepseek', 'openrouter', 'Custom.Provider/A']) {
      test('$mode raw turn uses captured $provider, not same-ID global or topic', () async {
        final harness = RoleHarness();
        addTearDown(harness.close);
        final foreignProvider = provider == 'deepseek' ? 'openrouter' : 'deepseek';
        _configureRawTopic(harness, provider: foreignProvider);
        if (provider == 'Custom.Provider/A') {
          harness.models.addAll([
            {'id': roleAgent.model, 'name': 'Wrong Case', 'provider': 'custom.provider/a'},
            {'id': roleAgent.model, 'name': 'Exact Provider', 'provider': provider},
          ]);
        }
        await harness.initialize();
        final conversation = (await harness.container
            .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
        final messages = await _seedTurn(harness, conversation, provider: provider);
        _selectProvider(harness, foreignProvider);

        await _driveTurn(harness, conversation, messages, foreground: foreground);

        final request = harness.adapter.requests.singleWhere((request) =>
            request.method == 'POST' && request.uri.path == '/api/v1/chat');
        expect((request.data as Map)['provider'], provider);
        expect((request.data as Map)['model'], roleAgent.model);
        expect(harness.messages.last['provider'], provider);
        final row = await harness.database.messagesDao
            .getMessage(conversation.id, 'queued-assistant');
        expect(row!.content, 'Verified raw response');
        expect(harness.responsePayloads, isEmpty);
        expect(harness.container.read(selectedModelProvider)!.metadata?['provider'], foreignProvider);
        if (foreground) {
          expect(harness.container.read(chatMessagesProvider)
              .firstWhere((message) => message.id == 'queued-assistant').content,
              'Verified raw response');
        } else {
          expect(harness.container.read(activeConversationProvider), isNull);
        }
      });
    }

    test('$mode Agent uses captured provider with same-ID foreign global${foreground ? ' across headless handoff' : ''}', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      final messages = await _seedTurn(harness, conversation, provider: roleAgent.provider);
      _selectProvider(harness, 'openrouter');
      harness.beforeResponse = () async {
        final row = await harness.database.messagesDao.getMessage(conversation.id, 'queued-assistant');
        final metadata = (jsonDecode(row!.payload) as Map)['metadata'] as Map;
        expect(metadata['provider'], roleAgent.provider);
        expect(metadata['model'], roleAgent.model);
        expect((metadata['lobeAgentCorrelation'] as Map)['agentId'], roleAgent.id);
        expect(metadata['completionSubmitted'], isTrue);
        if (foreground) {
          harness.container.read(activeConversationProvider.notifier).clear();
        }
      };

      await _driveTurn(harness, conversation, messages, foreground: foreground);

      expect(harness.responsePayloads.single['model'], roleAgent.id);
      expect(harness.responsePayloads.single['input'], 'Write Dart');
      expect(harness.responsePayloads.single['previous_response_id'], conversation.id);
      expect(harness.responsePayloads.single.containsKey('provider'), isFalse);
      final row = await harness.database.messagesDao.getMessage(conversation.id, 'queued-assistant');
      expect(row!.content, 'Verified role response');
      expect(harness.container.read(selectedModelProvider)!.metadata?['provider'], 'openrouter');
    });

    test('$mode Agent rejects captured same-ID provider override despite matching global', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      final messages = await _seedTurn(harness, conversation, provider: 'openrouter');
      _selectProvider(harness, 'deepseek');

      await expectLater(
        _driveTurn(harness, conversation, messages, foreground: foreground),
        throwsA(isA<SyncTerminalException>().having(
          (error) => error.statusCode, 'statusCode', 400,
        ).having((error) => error.message, 'message', contains('overrides'))),
      );
      expect(harness.responsePayloads, isEmpty);
    });

    for (final missingField in ['agentModel', 'provider']) {
      test('$mode Agent captured identity cannot replace missing verified $missingField', () async {
        final harness = RoleHarness();
        addTearDown(harness.close);
        await harness.initialize();
        final verified = (await harness.container
            .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
        final conversation = verified.copyWith(metadata: {
          ...verified.metadata,
        }..remove(missingField));
        final messages = await _seedTurn(harness, conversation, provider: roleAgent.provider);
        _selectProvider(harness, roleAgent.provider!);

        await expectLater(
          _driveTurn(harness, conversation, messages, foreground: foreground),
          throwsA(isA<SyncTerminalException>().having(
            (error) => error.statusCode, 'statusCode', 400,
          ).having((error) => error.message, 'message', contains('verified'))),
        );
        expect(harness.responsePayloads, isEmpty);
      });
    }

    test('$mode exact selected tuple sends without an unnecessary roster lookup', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      _configureRawTopic(harness, provider: 'openrouter');
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      final messages = await _seedTurn(harness, conversation, provider: 'deepseek');
      _selectProvider(harness, 'deepseek');

      await _driveTurn(harness, conversation, messages, foreground: foreground);

      final request = harness.adapter.requests.singleWhere((request) =>
          request.method == 'POST' && request.uri.path == '/api/v1/chat');
      expect((request.data as Map)['provider'], 'deepseek');
      expect(harness.adapter.requests.where((request) =>
          request.uri.path == '/api/v1/models'), isEmpty);
      final row = await harness.database.messagesDao.getMessage(conversation.id, 'queued-assistant');
      expect(row!.content, 'Verified raw response');
    });

    for (final agent in [false, true]) {
      test('$mode ${agent ? 'Agent' : 'raw'} legacy turn uses verified topic provider', () async {
        final harness = RoleHarness();
        addTearDown(harness.close);
        if (!agent) _configureRawTopic(harness, provider: roleAgent.provider!);
        await harness.initialize();
        final conversation = (await harness.container
            .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
        final messages = await _seedTurn(harness, conversation);
        _selectProvider(harness, 'openrouter');
        if (agent && foreground) {
          harness.beforeResponse = () async {
            harness.container.read(activeConversationProvider.notifier).clear();
          };
        }

        await _driveTurn(harness, conversation, messages, foreground: foreground);

        final row = await harness.database.messagesDao.getMessage(conversation.id, 'queued-assistant');
        expect(row!.content, agent ? 'Verified role response' : 'Verified raw response');
        if (!agent) {
          final request = harness.adapter.requests.singleWhere((request) =>
              request.method == 'POST' && request.uri.path == '/api/v1/chat');
          expect((request.data as Map)['provider'], roleAgent.provider);
        }
      });
    }

    for (final capturedProvider in [null, '', '   ']) {
      test('$mode rejects unproven raw provider $capturedProvider instead of global fallback', () async {
        final harness = RoleHarness();
        addTearDown(harness.close);
        _configureRawTopic(harness, provider: 'deepseek');
        if (capturedProvider == null) harness.topic.remove('provider');
        await harness.initialize();
        final conversation = (await harness.container
            .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
        final messages = await _seedTurn(harness, conversation, provider: capturedProvider);
        _selectProvider(harness, 'deepseek');

        await expectLater(
          _driveTurn(harness, conversation, messages, foreground: foreground),
          throwsA(isA<SyncTerminalException>().having(
            (error) => error.statusCode, 'statusCode', 400,
          )),
        );
        expect(harness.adapter.requests.where((request) => request.method == 'POST'), isEmpty);
      });
    }

    for (final unavailable in [true, false]) {
      test('$mode rejects ${unavailable ? 'missing' : 'ambiguous'} exact provider instead of ID-only roster match', () async {
        final harness = RoleHarness();
        addTearDown(harness.close);
        _configureRawTopic(harness, provider: 'openrouter');
        if (unavailable) {
          harness.models.removeWhere((model) => model['provider'] == 'deepseek');
        } else {
          harness.models.add({'id': roleAgent.model, 'name': 'Duplicate', 'provider': 'deepseek'});
        }
        await harness.initialize();
        final conversation = (await harness.container
            .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
        final messages = await _seedTurn(harness, conversation, provider: 'deepseek');
        _selectProvider(harness, 'openrouter');

        await expectLater(
          _driveTurn(harness, conversation, messages, foreground: foreground),
          throwsA(isA<SyncTerminalException>().having(
            (error) => error.statusCode, 'statusCode', 400,
          )),
        );
        expect(harness.adapter.requests.where((request) => request.method == 'POST'), isEmpty);
      });
    }

    test('$mode fences ownership after exact-provider roster lookup', () async {
      final harness = RoleHarness();
      addTearDown(harness.close);
      await harness.initialize();
      final conversation = (await harness.container
          .read(syncEngineProvider.notifier).pullChatNow('tpc_verified'))!;
      final messages = await _seedTurn(harness, conversation, provider: 'deepseek');
      _selectProvider(harness, 'openrouter');
      harness.beforeModels = () async {
        if (foreground) {
          harness.container.read(activeConversationProvider.notifier).clear();
        } else {
          harness.changeAccount('synthetic-account-b');
        }
      };

      await expectLater(
        _driveTurn(harness, conversation, messages, foreground: foreground),
        throwsA(isA<OutboxDeferralException>()),
      );
      expect(harness.responsePayloads, isEmpty);
    });
  }
}

void _selectProvider(RoleHarness harness, String provider) {
  harness.container.read(selectedModelProvider.notifier).set(Model(
    id: roleAgent.model!,
    name: 'Same-ID model from $provider',
    metadata: {'provider': provider},
  ));
}

Future<void> _seedSubmittedTurn(RoleHarness harness, Conversation conversation) async {
  final timestamp = DateTime.utc(2026, 10, 4);
  final messages = [
    ChatMessage(id: 'queued-user', role: 'user', content: 'Write Dart', timestamp: timestamp),
    ChatMessage(id: 'queued-assistant', role: 'assistant', content: '', timestamp: timestamp,
        model: roleAgent.model, metadata: {'model': roleAgent.model, 'provider': roleAgent.provider}),
  ];
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final parentId = message.role == 'assistant' ? 'queued-user' : null;
    await harness.database.into(harness.database.messages).insert(
      MessagesCompanion.insert(
        id: message.id,
        chatId: conversation.id,
        parentId: Value(parentId),
        role: message.role,
        content: message.content,
        model: Value(message.model),
        createdAt: timestamp.millisecondsSinceEpoch ~/ 1000,
        orderIndex: index,
        payload: jsonEncode({...message.toJson(), 'parentId': parentId}),
      ),
    );
  }
  await storeLobeAgentCorrelationBarrier(
    db: harness.database,
    chatId: conversation.id,
    assistantMessageId: 'queued-assistant',
    correlation: LobeAgentCorrelation(
      topicId: conversation.id,
      agentId: roleAgent.id,
      userText: 'Write Dart',
      userLocalId: 'queued-user',
      assistantLocalId: 'queued-assistant',
      snapshotServerIds: const {},
      createdAt: timestamp,
    ),
  );
}

List<Map<String, dynamic>> _persistedAgentPair() => [
  {
    'id': 'server-user', 'role': 'user', 'content': 'Write Dart',
    'metadata': {'serverOwned': true},
  },
  {
    'id': 'server-assistant', 'role': 'assistant', 'content': 'Verified role response',
    'parentId': 'server-user', 'model': roleAgent.model, 'provider': roleAgent.provider,
    'metadata': {'serverOwned': true},
  },
];

Future<List<ChatMessage>> _seedTurn(
  RoleHarness harness,
  Conversation conversation, {
  String? provider,
}) async {
  final timestamp = DateTime.utc(2026, 10, 4);
  final messages = [
    ChatMessage(
      id: 'earlier-assistant',
      role: 'assistant',
      content: 'Prior turn',
      timestamp: timestamp,
      model: roleAgent.model,
      metadata: const {
        'backend': 'lobehub',
        'model': 'shared-model',
        'provider': 'unrelated-provider',
      },
    ),
    ChatMessage(
      id: 'queued-user',
      role: 'user',
      content: 'Write Dart',
      timestamp: timestamp,
    ),
    ChatMessage(
      id: 'queued-assistant',
      role: 'assistant',
      content: '',
      timestamp: timestamp,
      model: roleAgent.model,
      metadata: provider == null ? null : {
        'backend': 'lobehub',
        'model': roleAgent.model,
        'provider': provider,
      },
    ),
  ];
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    await harness.database.into(harness.database.messages).insert(
      MessagesCompanion.insert(
        id: message.id,
        chatId: conversation.id,
        role: message.role,
        content: message.content,
        model: Value(message.model),
        createdAt: timestamp.millisecondsSinceEpoch ~/ 1000,
        orderIndex: index,
        payload: jsonEncode(message.toJson()),
      ),
    );
  }
  return messages;
}

Future<void> _driveTurn(
  RoleHarness harness,
  Conversation conversation,
  List<ChatMessage> messages, {
  required bool foreground,
}) async {
  if (!foreground) {
    await runHeadlessCompletion(
      harness.container,
      chatId: conversation.id,
      assistantMessageId: 'queued-assistant',
      messages: messages,
      conversation: conversation,
      model: roleAgent.model!,
      sessionIdOverride: 'synthetic-session',
    );
    return;
  }
  harness.container.read(activeConversationProvider.notifier)
      .set(conversation.copyWith(messages: messages));
  harness.container.read(chatMessagesProvider.notifier).setMessages(messages);
  final completed = Completer<void>();
  final subscription = harness.container.listen(chatMessagesProvider, (_, next) {
    final assistant = next.where((message) => message.id == 'queued-assistant').firstOrNull;
    if (assistant != null && assistant.content.isNotEmpty && !assistant.isStreaming &&
        !completed.isCompleted) {
      completed.complete();
    }
  });
  try {
    await runQueuedCompletion(
      harness.container,
      chatId: conversation.id,
      assistantMessageId: 'queued-assistant',
      model: roleAgent.model!,
      sessionIdOverride: 'synthetic-session',
    );
    if (harness.container.read(activeConversationProvider)?.id != conversation.id) {
      return;
    }
    await completed.future.timeout(const Duration(seconds: 5));
    await harness.container.read(syncEngineProvider.notifier).pullChatNow(conversation.id);
  } finally {
    subscription.close();
  }
}

void _configureRawTopic(RoleHarness harness, {required String provider}) {
  harness.topic = {
    'id': 'tpc_verified',
    'title': 'Raw model topic',
    'model': roleAgent.model,
    'provider': provider,
    'createdAt': 1700000000000,
    'updatedAt': 1700000000000,
  };
  harness.adapter.handlers['POST /api/v1/chat'] = (request) {
    final payload = request.data as Map;
    expect(payload['model'], roleAgent.model);
    expect(payload['stream'], isFalse);
    expect(payload['messages'], [
      {'role': 'assistant', 'content': 'Prior turn'},
      {'role': 'user', 'content': 'Write Dart'},
    ]);
    return roleJson({
      'success': true,
      'data': {'content': 'Verified raw response'},
    });
  };
  harness.adapter.handlers['POST /api/v1/messages'] = (request) {
    final payload = Map<String, dynamic>.from(request.data as Map);
    expect(payload['topicId'], 'tpc_verified');
    final isAssistant = payload['role'] == 'assistant';
    expect(payload['content'], isAssistant ? 'Verified raw response' : 'Write Dart');
    expect((payload['metadata'] as Map)['conduitClientId'],
        isAssistant ? 'queued-assistant' : 'queued-user');
    final id = isAssistant ? 'server-assistant' : 'server-user';
    harness.messages.add({
      ...payload,
      'id': id,
      if (isAssistant) 'parentId': 'server-user',
    });
    return roleJson({'success': true, 'data': {'id': id}});
  };
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/ports/worker_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _modelId = 'shared-model-id';
const _providerId = 'Custom.Provider/A';
const _timestamp = 1791072000;
const _selectedModel = Model(
  id: _modelId,
  name: ' Selected Model ',
  metadata: {'providerId': _providerId},
);
const _collidingModel = Model(
  id: _modelId,
  name: 'Same ID, different provider',
  metadata: {'provider': 'provider-b'},
);

Map<String, dynamic> _identity(String provider) => {
  'backend': 'lobehub',
  'model': _modelId,
  'provider': provider,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'durableSend captures a new turn before same-ID provider selection changes',
    () async {
      final harness = await _Harness.open();
      expect(await harness.container.read(modelsProvider.future), [
        _collidingModel,
        _selectedModel,
      ]);
      ChatMessage? optimistic;
      final handle = await harness.send(
        onPlaceholder: (handle) {
          optimistic = harness.container
              .read(chatMessagesProvider)
              .singleWhere(
                (message) => message.id == handle.assistantMessageId,
              );
          harness.select(_collidingModel);
        },
      );

      final assistant = await harness.assistant(handle);
      expect(
        _payload(assistant)['metadata'],
        _identity(_providerId),
        reason: 'The actual pending assistant row must own its provider',
      );
      _expectPendingShape(assistant, handle, provider: _providerId);
      expect(optimistic!.metadata, {
        'parentId': handle.userMessageId,
        'childrenIds': <String>[],
        'modelName': 'Selected Model',
        ..._identity(_providerId),
      });
      expect(optimistic!.isStreaming, true);
      expect(harness.container.read(selectedModelProvider), _collidingModel);
      final active = harness.container.read(activeConversationProvider)!;
      expect(active.model, _modelId);
      expect(active.metadata, _identity(_providerId));
      expect(active.metadata.containsKey('agentId'), false);
      final blob = await harness.blob();
      expect(blob['meta'], _identity(_providerId));
      expect(blob['metadata'], _identity(_providerId));
      final rebuilt = await harness.conversation();
      expect(rebuilt.metadata, _identity(_providerId));
      expect(
        rebuilt.messages
            .singleWhere((message) => message.id == handle.assistantMessageId)
            .metadata,
        containsPair('provider', _providerId),
      );
      await harness.expectCompletion(handle);
    },
  );

  test(
    'two pending same-ID turns retain different providers on their own rows',
    () async {
      final harness = await _Harness.open();
      await harness.seed(_identity('topic-default-provider'));
      final first = await harness.send();
      final firstBeforeSwitch = (await harness.assistant(first)).payload;
      harness.select(_collidingModel);
      final second = await harness.send();

      final firstRow = await harness.assistant(first);
      final secondRow = await harness.assistant(second);
      expect(firstRow.payload, firstBeforeSwitch);
      _expectPendingShape(firstRow, first, provider: _providerId);
      _expectPendingShape(
        secondRow,
        second,
        provider: 'provider-b',
        modelName: _collidingModel.name,
      );
      expect(firstRow.model, secondRow.model);
      final conversation = await harness.conversation();
      expect(conversation.metadata['provider'], 'topic-default-provider');
      for (final (handle, provider) in [
        (first, _providerId),
        (second, 'provider-b'),
      ]) {
        expect(
          conversation.messages
              .singleWhere((message) => message.id == handle.assistantMessageId)
              .metadata,
          containsPair('provider', provider),
        );
        await harness.expectCompletion(handle);
      }
    },
  );

  for (final (source, metadata) in <(String, Map<String, dynamic>)>[
    ('provider', {'provider': _providerId, 'providerId': 'not-selected'}),
    ('owned_by', {'owned_by': _providerId}),
    (
      'nested meta.provider',
      {
        'meta': {'provider': _providerId},
      },
    ),
  ]) {
    test(
      'durableSend canonicalizes established $source metadata without fallback',
      () async {
        final harness = await _Harness.open();
        harness.select(
          Model(id: _modelId, name: 'Selected Model', metadata: metadata),
        );
        final handle = await harness.send();
        _expectPendingShape(
          await harness.assistant(handle),
          handle,
          provider: _providerId,
        );
        await harness.expectCompletion(handle);
      },
    );
  }

  for (final metadata in <Map<String, dynamic>?>[
    null,
    {'provider': ''},
    {'provider': '   '},
    {'provider': '', 'providerId': 'provider-b'},
  ]) {
    test(
      'durableSend rejects missing/blank provider $metadata before any write',
      () async {
        final harness = await _Harness.open();
        await harness.seed(_identity('provider-b'));
        harness.select(
          Model(id: _modelId, name: 'No provider', metadata: metadata),
        );
        var createdPlaceholder = false;
        await expectLater(
          durableSend(
            harness.container,
            'Do not route to provider-b',
            null,
            onAssistantPlaceholderCreated: (_) => createdPlaceholder = true,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('provider'),
            ),
          ),
        );
        expect(createdPlaceholder, false);
        expect(
          await harness.db.messagesDao.getForChat(harness.chatId),
          isEmpty,
        );
        expect(await harness.db.select(harness.db.outboxOps).get(), isEmpty);
        expect(harness.container.read(chatMessagesProvider), isEmpty);
        expect(harness.engine._drainedDatabases, isEmpty);
      },
    );
  }

  test('a failed drain leaves the captured provider durable, never the replacement', () async {
    final harness = await _Harness.open();
    await harness.seed(_identity('provider-b'));
    harness.engine._failure = StateError('Synthetic drain failure');
    ChatSendPlaceholderHandle? handle;
    await expectLater(
      durableSend(
        harness.container,
        'Keep the failed turn identity',
        null,
        onAssistantPlaceholderCreated: (created) => handle = created,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Synthetic drain failure',
        ),
      ),
    );
    harness.select(_collidingModel);
    _expectPendingShape(
      await harness.assistant(handle!),
      handle!,
      provider: _providerId,
    );
    await harness.expectCompletion(handle!);
  });

  test('durableSend preserves verified topic Agent binding, not global Agent state', () async {
    final harness = await _Harness.open();
    final binding = <String, dynamic>{
      'backend': 'lobehub',
      'agentId': 'verified-topic-agent',
      'agentTitle': 'Verified topic role',
      'agentModel': _modelId,
      'provider': _providerId,
      'systemRole': 'Retain the verified instructions',
      'lobeTopic': {'id': 'existing-topic', 'agentId': 'verified-topic-agent'},
    };
    await harness.seed(binding);
    final boundBeforeSend = await harness.conversation();
    final handle = await harness.send();
    expect(
      harness.container.read(activeConversationProvider)!.metadata,
      binding,
    );
    expect((await harness.blob())['metadata'], binding);
    expect((await harness.conversation()).metadata, boundBeforeSend.metadata);
    expect(boundBeforeSend.metadata, {
      'backend': 'lobehub',
      'agentId': 'verified-topic-agent',
      'agentTitle': 'Verified topic role',
      'agentModel': _modelId,
      'provider': _providerId,
    });
    _expectPendingShape(
      await harness.assistant(handle),
      handle,
      provider: _providerId,
    );
    expect(
      harness.container.read(lobeSelectedAgentIdProvider),
      'foreign-global-agent',
    );
  });

  for (final existing in [false, true]) {
    test(
      'OpenWebUI ${existing ? 'existing' : 'new'} durable serialization is unchanged',
      () async {
        final harness = await _Harness.open(lobeHub: false);
        if (existing) await harness.seed(const {});
        final handle = await harness.send();
        _expectPendingShape(await harness.assistant(handle), handle);
        final optimistic = harness.container
            .read(chatMessagesProvider)
            .singleWhere((message) => message.id == handle.assistantMessageId);
        expect(optimistic.metadata, {
          'parentId': handle.userMessageId,
          'childrenIds': <String>[],
          'modelName': 'Selected Model',
        });
        final blob = await harness.blob();
        expect(blob.keys.toSet(), {'title', 'models', 'history'});
        final messages =
            (blob['history'] as Map<String, dynamic>)['messages']
                as Map<String, dynamic>;
        expect(messages[handle.userMessageId], {
          'id': handle.userMessageId,
          'parentId': null,
          'childrenIds': [handle.assistantMessageId],
          'role': 'user',
          'content': 'A pending identity turn',
          'files': <Map<String, dynamic>>[],
          'models': [_modelId],
          'timestamp': _timestamp,
        });
        expect(
          harness.container.read(activeConversationProvider)!.metadata,
          isEmpty,
        );
        expect(
          harness.container.read(activeConversationProvider)!.model,
          isNull,
        );
        await harness.expectCompletion(handle);
      },
    );
  }
}

Map<String, dynamic> _payload(MessageRow row) =>
    jsonDecode(row.payload) as Map<String, dynamic>;

void _expectPendingShape(
  MessageRow row,
  ChatSendPlaceholderHandle handle, {
  String? provider,
  String modelName = 'Selected Model',
}) {
  expect(row.role, 'assistant');
  expect(row.content, '');
  expect(row.model, _modelId);
  expect(row.parentId, handle.userMessageId);
  expect(_payload(row), {
    'id': handle.assistantMessageId,
    'parentId': handle.userMessageId,
    'childrenIds': <String>[],
    'role': 'assistant',
    'content': '',
    'model': _modelId,
    'modelName': modelName,
    'timestamp': _timestamp,
    if (provider != null) 'metadata': _identity(provider),
  });
  expect(_payload(row).containsKey('done'), false);
  expect(_payload(row).containsKey('isStreaming'), false);
}

class _Harness {
  _Harness(this.db, this.container, this.engine);

  final AppDatabase db;
  final ProviderContainer container;
  final _HeldSyncEngine engine;

  String get chatId => container.read(activeConversationProvider)!.id;

  static Future<_Harness> open({bool lobeHub = true}) async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    addTearDown(PreferencesStore.debugReset);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final worker = WorkerManager(worker: const InlineWorkerPort());
    addTearDown(worker.dispose);
    final config = ServerConfig(
      id: lobeHub ? 'lobehub_self_hosted' : 'openwebui-test',
      name: 'No-network durable identity fixture',
      url: 'https://durable-identity.invalid',
    );
    final adapter = _RejectNetworkAdapter();
    final api = ApiService(serverConfig: config, workerManager: worker);
    api.dio.httpClientAdapter = adapter;
    addTearDown(() {
      api.dispose();
      api.dio.close(force: true);
      expect(adapter.requests, isEmpty);
      expect(adapter.closed, true);
    });
    final engine = _HeldSyncEngine();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        apiServiceProvider.overrideWithValue(api),
        activeServerProvider.overrideWith((ref) async => config),
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        selectedModelProvider.overrideWith(_SendSelection.new),
        modelsProvider.overrideWith(_CollisionRoster.new),
        chatMessagesProvider.overrideWith(_SendMessages.new),
        syncEngineProvider.overrideWith(() => engine),
        syncClockProvider.overrideWithValue(const _FixedClock()),
        socketServiceProvider.overrideWithValue(null),
        reviewerModeProvider.overrideWithValue(false),
        temporaryChatEnabledProvider.overrideWithValue(false),
        selectedTerminalIdProvider.overrideWithValue(null),
        webSearchEnabledProvider.overrideWith(_DisabledWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(
          _DisabledImageGeneration.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeServerProvider.future);
    container
        .read(lobeAgentsProvider.notifier)
        .selectAgent('foreign-global-agent');
    container.read(selectedModelProvider.notifier).set(_selectedModel);
    return _Harness(db, container, engine);
  }

  void select(Model model) =>
      container.read(selectedModelProvider.notifier).set(model);

  Future<void> seed(Map<String, dynamic> metadata) async {
    final blob = <String, dynamic>{
      'title': 'Existing topic',
      'models': [_modelId],
      if (metadata.isNotEmpty) 'meta': metadata,
      if (metadata.isNotEmpty) 'metadata': metadata,
      'history': {'currentId': null, 'messages': <String, dynamic>{}},
    };
    final rows = ChatBlobMapper.blobToRows(
      chatId: 'existing-topic',
      blob: blob,
      title: 'Existing topic',
      createdAt: _timestamp,
      updatedAt: _timestamp,
    );
    await db
        .into(db.chats)
        .insert(
          ChatsCompanion.insert(
            id: rows.chat.id,
            title: rows.chat.title,
            createdAt: _timestamp,
            updatedAt: _timestamp,
            bodySynced: const Value(true),
            rawExtra: Value(jsonEncode(rows.chat.rawExtra)),
            blobMeta: Value(
              jsonEncode({
                'blobHadTitle': true,
                'blobTitleValue': rows.blobTitleValue,
                'blobHadHistory': true,
                'historyHadMessages': true,
                'historyHadCurrentId': true,
              }),
            ),
          ),
        );
    container
        .read(activeConversationProvider.notifier)
        .set(
          Conversation(
            id: rows.chat.id,
            title: rows.chat.title,
            createdAt: DateTime.utc(2026, 10, 4),
            updatedAt: DateTime.utc(2026, 10, 4),
            metadata: metadata,
          ),
        );
  }

  Future<ChatSendPlaceholderHandle> send({
    void Function(ChatSendPlaceholderHandle)? onPlaceholder,
  }) async {
    ChatSendPlaceholderHandle? handle;
    await durableSend(
      container,
      'A pending identity turn',
      null,
      onAssistantPlaceholderCreated: (created) {
        handle = created;
        onPlaceholder?.call(created);
      },
    );
    expect(engine._drainedDatabases.last, same(db));
    return handle!;
  }

  Future<MessageRow> assistant(ChatSendPlaceholderHandle handle) async =>
      (await db.messagesDao.getMessage(chatId, handle.assistantMessageId))!;

  Future<Map<String, dynamic>> blob() async => ChatBlobMapper.rowsToBlob(
    chatRowsFromDb(
      (await db.chatsDao.getChat(chatId))!,
      await db.messagesDao.getForChat(chatId),
    ),
  );

  Future<Conversation> conversation() async => assembleConversationGuarded(
    (await db.chatsDao.getChat(chatId))!,
    await db.messagesDao.getForChat(chatId),
    offload: null,
  );

  Future<void> expectCompletion(ChatSendPlaceholderHandle handle) async {
    final ops = await db.select(db.outboxOps).get();
    final completion = ops.singleWhere(
      (op) =>
          op.kind == 'requestCompletion' &&
          (jsonDecode(op.payload)
                  as Map<String, dynamic>)['assistantMessageId'] ==
              handle.assistantMessageId,
    );
    expect(completion.chatId, chatId);
    expect(completion.status, OutboxStatus.pending);
    expect(completion.attempts, 0);
    expect(jsonDecode(completion.payload), {
      'assistantMessageId': handle.assistantMessageId,
      'model': _modelId,
      'toolIds': <String>[],
      'filterIds': <String>[],
      'enableWebSearch': false,
      'enableImageGeneration': false,
      'isVoiceMode': false,
    });
  }
}

class _SendSelection extends SelectedModel {
  @override
  Model? build() => null;
}

class _CollisionRoster extends Models {
  @override
  Future<List<Model>> build() async => [_collidingModel, _selectedModel];
}

class _SendMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void addMessages(List<ChatMessage> messages) =>
      state = [...state, ...messages];
}

class _DisabledWebSearch extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

class _DisabledImageGeneration extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

class _HeldSyncEngine extends SyncEngine {
  final List<AppDatabase> _drainedDatabases = [];
  StateError? _failure;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNowForDatabase(AppDatabase database) async {
    _drainedDatabases.add(database);
    if (_failure != null) throw _failure!;
  }
}

class _FixedClock implements SyncClock {
  const _FixedClock();

  @override
  int nowEpochSeconds() => _timestamp;
}

class _RejectNetworkAdapter implements HttpClientAdapter {
  final List<String> requests = [];
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    throw StateError('Network is forbidden in durable identity tests');
  }

  @override
  void close({bool force = false}) => closed = true;
}

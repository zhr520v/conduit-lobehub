import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/request_completion_runner.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Targeted guards for [ChatRequestCompletionRunner] (Wiring D / R3 / R5).
///
/// These cover the no-stream control paths the runner takes BEFORE re-entering
/// the streaming pipeline (which needs a full api/socket stack out of scope
/// here): the live-stream busy-skip (R5), the already-completed idempotent
/// re-entry (R3), and the chat-absent early-return. The "drives the stream"
/// acceptance is covered by `test/core/sync/write_path_acceptance_test.dart`.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// Builds the real [ChatRequestCompletionRunner] with a genuine [Ref] via a
  /// throwaway provider, under the given overrides. Headless model resolution
  /// uses a concrete roster fixture instead of requiring Hive bootstrap.
  ({ProviderContainer container, RequestCompletionRunner runner}) makeRunner({
    bool? isStreaming,
    Conversation? active,
    bool attachDatabase = true,
    int recoveryAttempts = 6,
    Duration recoveryDelay = const Duration(seconds: 2),
    Object Function()? authSessionEpoch,
    ApiService? apiService,
  }) {
    final runnerProvider = Provider<RequestCompletionRunner>((ref) {
      return ChatRequestCompletionRunner(
        ref,
        recoveryAttempts: recoveryAttempts,
        recoveryDelay: recoveryDelay,
      );
    });
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => attachDatabase ? db : null),
        if (isStreaming != null)
          isChatStreamingProvider.overrideWithValue(isStreaming),
        chatMessagesProvider.overrideWith(() => _TestMessagesNotifier()),
        activeConversationProvider.overrideWith(() => _SeededActive(active)),
        modelsProvider.overrideWith(() => _TestModels()),
        apiServiceProvider.overrideWithValue(apiService),
        socketServiceProvider.overrideWithValue(null),
        if (authSessionEpoch != null)
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => authSessionEpoch(),
          ),
      ],
    );
    addTearDown(container.dispose);
    return (container: container, runner: container.read(runnerProvider));
  }

  Future<void> seedChat(String chatId) async {
    await db
        .into(db.chats)
        .insert(
          ChatsCompanion.insert(
            id: chatId,
            title: 'T',
            createdAt: 1,
            updatedAt: 1,
            bodySynced: const Value(true),
          ),
        );
  }

  Future<void> seedMessage(
    String chatId,
    String id,
    String content, {
    Map<String, dynamic>? payload,
  }) async {
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: id,
            chatId: chatId,
            role: 'assistant',
            content: content,
            createdAt: 1,
            orderIndex: 0,
            payload: jsonEncode(payload ?? const <String, dynamic>{}),
          ),
        );
  }

  Conversation conv(String id) => Conversation(
    id: id,
    title: 'C',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    messages: const [],
  );

  Map<String, dynamic> payload(String assistantId) => RequestCompletionPayload(
    assistantMessageId: assistantId,
    model: 'model-1',
  ).toJson();

  OutboxDrainer makeDrainer(RequestCompletionRunner runner) => OutboxDrainer(
    db: db,
    clock: const _TestSyncClock(),
    backoff: Backoff(jitter: () => 0),
    isOnline: () => true,
    completion: runner,
    adapters: const [],
  );

  test('defers (throws CompletionBusyException) when a live stream owns the '
      'chat', () async {
    const chatId = 'chat-busy';
    await seedChat(chatId);
    await seedMessage(chatId, 'asst-1', '');

    final (:container, :runner) = makeRunner(
      isStreaming: true,
      active: conv(chatId),
    );
    container; // silence unused.

    await check(runner.run(chatId: chatId, payload: payload('asst-1')))
        .throws<CompletionBusyException>();
  });

  test(
    'recovers a submitted marker while another live stream owns the chat',
    () async {
      const chatId = 'chat-submitted-recovery';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        'asst-submitted',
        'partial submitted response',
        payload: const <String, dynamic>{
          'id': 'asst-submitted',
          'role': 'assistant',
          'content': 'partial submitted response',
          'metadata': <String, dynamic>{'completionSubmitted': true},
        },
      );

      final (:container, :runner) = makeRunner(
        isStreaming: true,
        active: conv(chatId),
        recoveryAttempts: 1,
        recoveryDelay: Duration.zero,
      );
      container.read(chatMessagesProvider.notifier).setMessages([
        ChatMessage(
          id: 'other-live-assistant',
          role: 'assistant',
          content: 'another turn is streaming',
          timestamp: DateTime.utc(2026, 7, 14),
          isStreaming: true,
        ),
      ]);

      // The durable submitted marker makes this pull-only recovery. It must
      // not wait for the unrelated live stream or issue another completion.
      await runner.run(chatId: chatId, payload: payload('asst-submitted'));

      final row = await db.messagesDao.getMessage(chatId, 'asst-submitted');
      check(row?.content).equals('partial submitted response');
    },
  );

  test('does not defer its own optimistic streaming placeholder', () async {
    const chatId = 'chat-own-placeholder';
    await seedChat(chatId);
    await seedMessage(chatId, 'asst-own', '');

    final (:container, :runner) = makeRunner(
      isStreaming: true,
      active: conv(chatId),
    );
    container.read(chatMessagesProvider.notifier).setMessages([
      ChatMessage(
        id: 'user-own',
        role: 'user',
        content: 'hello',
        timestamp: DateTime.now(),
      ),
      ChatMessage(
        id: 'asst-own',
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        isStreaming: true,
      ),
    ]);

    await check(runner.run(chatId: chatId, payload: payload('asst-own')))
        .throws<StateError>();
  });

  test('defers when no active database is attached', () async {
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: null,
      attachDatabase: false,
    );
    container;

    await check(
      runner.run(chatId: 'chat-no-db', payload: payload('asst-no-db')),
    ).throws<CompletionDatabaseUnavailableException>();
  });

  test('returns early (idempotent) when the turn already completed', () async {
    const chatId = 'chat-done';
    await seedChat(chatId);
    await seedMessage(
      chatId,
      'asst-2',
      'already answered',
      payload: const <String, dynamic>{
        'id': 'asst-2',
        'role': 'assistant',
        'content': 'already answered',
        'timestamp': 1,
        'isStreaming': false,
      },
    );

    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv(chatId),
    );
    container;

    // Completes without throwing and without touching the api (none provided).
    await runner.run(chatId: chatId, payload: payload('asst-2'));

    // The completed row is left untouched (still exactly one assistant row).
    final rows = await db.messagesDao.getForChat(chatId);
    check(rows.where((r) => r.id == 'asst-2')).length.equals(1);
    check(rows.single.content).equals('already answered');
  });

  test(
    'returns early for a headless submitted marker with empty content',
    () async {
      const chatId = 'chat-headless-marker';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        'asst-headless',
        '',
        payload: const <String, dynamic>{
          'id': 'asst-headless',
          'role': 'assistant',
          'content': '',
          'metadata': {'responseDone': true},
        },
      );

      final (:container, :runner) = makeRunner(
        isStreaming: false,
        active: conv('a-different-chat'),
      );

      await runner.run(chatId: chatId, payload: payload('asst-headless'));

      check(container.read(activeConversationProvider)?.id)
          .equals('a-different-chat');
    },
  );

  test('does not treat pause-checkpoint content as completed', () async {
    const chatId = 'chat-partial';
    await seedChat(chatId);
    await seedMessage(
      chatId,
      'asst-partial',
      'partial answer',
      payload: const <String, dynamic>{
        'id': 'asst-partial',
        'role': 'assistant',
        'content': 'partial answer',
        'timestamp': 1,
        'isStreaming': true,
      },
    );

    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv(chatId),
    );
    container;

    await check(runner.run(chatId: chatId, payload: payload('asst-partial')))
        .throws<StateError>();
  });

  test('returns early when the chat row vanished (delete won the race)', () async {
    const chatId = 'chat-absent';
    // No active conversation, so the runner takes the activate branch, finds no
    // row, and returns. (A DIFFERENT active chat would now defer first — see the
    // Option B test below.)
    final (:container, :runner) = makeRunner(isStreaming: false, active: null);
    container;

    // No chat seeded: must return without throwing.
    await runner.run(chatId: chatId, payload: payload('asst-3'));

    final rows = await db.messagesDao.getForChat(chatId);
    check(rows).isEmpty();
  });

  test('returns early when the assistant placeholder row vanished', () async {
    const chatId = 'chat-missing-placeholder';
    await seedChat(chatId);
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv('a-different-chat'),
    );
    container;

    await runner.run(chatId: chatId, payload: payload('missing-asst'));

    final rows = await db.messagesDao.getForChat(chatId);
    check(rows).isEmpty();
  });

  test(
    'same-database auth-session switch defers after an awaited read',
    () async {
      const chatId = 'chat-session-switch';
      const assistantId = 'asst-session-switch';
      await seedChat(chatId);
      await seedMessage(chatId, assistantId, '');
      var authSessionEpoch = Object();
      final (:container, :runner) = makeRunner(
        isStreaming: false,
        active: conv(chatId),
        authSessionEpoch: () => authSessionEpoch,
      );

      final transactionEntered = Completer<void>();
      final releaseTransaction = Completer<void>();
      final transaction = db.transaction(() async {
        transactionEntered.complete();
        await releaseTransaction.future;
      });
      await transactionEntered.future;

      final completion = runner.run(
        chatId: chatId,
        payload: payload(assistantId),
      );
      await Future<void>.delayed(Duration.zero);
      authSessionEpoch = Object();
      container.invalidate(openWebUiAuthSessionEpochProvider);
      releaseTransaction.complete();
      await transaction;

      await check(completion).throws<CompletionDatabaseUnavailableException>();
    },
  );

  test('Option B: runs HEADLESS (never switches the active chat) when a '
      'DIFFERENT chat is foregrounded', () async {
    const chatId = 'chat-bg';
    await seedChat(chatId);
    await seedMessage(chatId, 'asst-4', '');

    // The user is viewing a different chat: the completion must NOT switch the
    // active conversation to chat-bg — it runs headless. With no api stack the
    // headless drive fails downstream, but it is NOT a deferral and NOT a
    // switch (proving the headless, non-disruptive path).
    final (:container, :runner) = makeRunner(
      isStreaming: false,
      active: conv('a-different-chat'),
    );

    await check(
      runner.run(chatId: chatId, payload: payload('asst-4')),
    ).throws<StateError>(); // "runHeadlessCompletion requires an API service"

    // The user's active conversation is untouched (Option B: no yank).
    check(container.read(activeConversationProvider)?.id)
        .equals('a-different-chat');
  });

  test(
    'runs HEADLESS (does not activate) when no chat is being viewed',
    () async {
      const chatId = 'chat-idle';
      await seedChat(chatId);
      await seedMessage(chatId, 'asst-5', '');
      final (:container, :runner) = makeRunner(
        isStreaming: false,
        active: null,
      );

      await check(runner.run(chatId: chatId, payload: payload('asst-5')))
          .throws<StateError>();
      // Headless never sets an active conversation.
      check(container.read(activeConversationProvider)).isNull();
    },
  );

  test('DB await followed by a colliding direct-local active chat chooses headless', () async {
    const chatId = 'storage-collision';
    const assistantId = 'shared-assistant';
    await seedChat(chatId);
    await seedMessage(chatId, assistantId, '');

    final (:container, :runner) = makeRunner(
      isStreaming: true,
      active: conv(chatId),
    );
    final aMessages = <ChatMessage>[
      ChatMessage(
        id: 'user-a',
        role: 'user',
        content: 'A',
        timestamp: DateTime.utc(2026, 7, 13),
      ),
      ChatMessage(
        id: assistantId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
        isStreaming: true,
      ),
    ];
    container.read(chatMessagesProvider.notifier).setMessages(aMessages);

    final transactionEntered = Completer<void>();
    final releaseTransaction = Completer<void>();
    final transaction = db.transaction(() async {
      transactionEntered.complete();
      await releaseTransaction.future;
    });
    await transactionEntered.future;

    final completion = runner.run(
      chatId: chatId,
      payload: payload(assistantId),
    );
    final expectation = expectLater(
      completion,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('runHeadlessCompletion'),
        ),
      ),
    );

    final bMessages = <ChatMessage>[
      ChatMessage(
        id: 'user-b',
        role: 'user',
        content: 'B must stay intact',
        timestamp: DateTime.utc(2026, 7, 13),
      ),
      ChatMessage(
        id: assistantId,
        role: 'assistant',
        content: 'B streaming bytes',
        timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
        isStreaming: true,
      ),
    ];
    final directB = withChatStorageProvenance(
      conv(chatId).copyWith(messages: bMessages),
      ChatStorageKind.directLocal,
    );
    container.read(activeConversationProvider.notifier).set(directB);
    container.read(chatMessagesProvider.notifier).setMessages(bMessages);
    final bSnapshot = jsonEncode(
      bMessages.map((message) => message.toJson()).toList(),
    );

    releaseTransaction.complete();
    await transaction;
    await expectation;

    check(
      jsonEncode(
        container
            .read(chatMessagesProvider)
            .map((message) => message.toJson())
            .toList(),
      ),
    ).equals(bSnapshot);
    check(chatStorageKindOf(container.read(activeConversationProvider)))
        .equals(ChatStorageKind.directLocal);
  });

  test(
    'live drive terminal 400 unsupported vision settles Drift row and active UI with isStreaming=false and visible error, and re-arms on manual retry',
    () async {
      const chatId = 'chat-terminal-live';
      const assistantId = 'asst-terminal-live';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        assistantId,
        '',
        payload: const <String, dynamic>{
          'id': assistantId,
          'role': 'assistant',
          'content': '',
          'isStreaming': true,
        },
      );

      final fakeApi = _FakeCompletionApiService(
        onSendMessageSession: () async {
          throw const SyncTerminalException(
            statusCode: 400,
            message: 'unsupported vision',
          );
        },
      );

      final (:container, :runner) = makeRunner(
        active: conv(chatId),
        apiService: fakeApi,
      );

      container.read(chatMessagesProvider.notifier).setMessages([
        ChatMessage(
          id: 'user-live',
          role: 'user',
          content: 'look at this image',
          timestamp: DateTime.utc(2026, 7, 14),
        ),
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 7, 14, 0, 0, 1),
          isStreaming: true,
        ),
      ]);

      await check(
        runner.run(chatId: chatId, payload: payload(assistantId)),
      ).throws<SyncTerminalException>();

      // Drift DB row must be settled with isStreaming=false, visible error,
      // completionSubmitted=false, terminal=true, and no responseDone.
      final row = await db.messagesDao.getMessage(chatId, assistantId);
      check(row).isNotNull();
      final payloadMap = jsonDecode(row!.payload) as Map<String, dynamic>;
      final metadata = payloadMap['metadata'] as Map<String, dynamic>;
      check(payloadMap['isStreaming']).equals(false);
      check(payloadMap['done']).isNull();
      check((payloadMap['error'] as Map)['content']).equals('unsupported vision');
      check(metadata['completionSubmitted']).equals(false);
      check(metadata['terminal']).equals(true);
      check(metadata.containsKey('responseDone')).isFalse();

      // Active UI must be updated immediately with isStreaming=false and error.
      final activeMsgs = container.read(chatMessagesProvider);
      final activeAsst = activeMsgs.firstWhere((m) => m.id == assistantId);
      check(activeAsst.isStreaming).equals(false);
      check(activeAsst.error?.content).equals('unsupported vision');
      check(container.read(isChatStreamingProvider)).equals(false);

      // Manual retry requeue semantics:
      // A subsequent run on the terminal placeholder must not be bypassed as
      // "already completed"; it must re-arm the row in DB and active UI!
      var retryCallCount = 0;
      final retryFakeApi = _FakeCompletionApiService(
        onSendMessageSession: () async {
          retryCallCount++;
          throw const SyncTerminalException(
            statusCode: 400,
            message: 'unsupported vision second attempt',
          );
        },
      );
      final (container: retryContainer, runner: retryRunner) = makeRunner(
        active: conv(chatId),
        apiService: retryFakeApi,
      );
      retryContainer.read(chatMessagesProvider.notifier).setMessages([
        activeAsst, // row is currently in failed terminal state (isStreaming: false)
      ]);

      await check(
        retryRunner.run(chatId: chatId, payload: payload(assistantId)),
      ).throws<SyncTerminalException>();
      check(retryCallCount).equals(1); // Not bypassed by _placeholderMarkedComplete!
    },
  );

  test(
    'live drive DioException 401 terminal error sanitizes credentials and settles row in Drift and active UI',
    () async {
      const chatId = 'chat-dio-401';
      const assistantId = 'asst-dio-401';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        assistantId,
        '',
        payload: const <String, dynamic>{
          'id': assistantId,
          'role': 'assistant',
          'content': '',
          'isStreaming': true,
        },
      );

      final fakeApi = _FakeCompletionApiService(
        onSendMessageSession: () async {
          throw DioException(
            requestOptions: RequestOptions(
              path: '/api/chat/completions',
              headers: {'Authorization': 'Bearer secret-token-xyz'},
            ),
            response: Response(
              requestOptions: RequestOptions(path: '/api/chat/completions'),
              statusCode: 401,
              data: {'detail': 'Invalid API Key Bearer secret-token-xyz'},
            ),
          );
        },
      );

      final (:container, :runner) = makeRunner(
        active: conv(chatId),
        apiService: fakeApi,
      );

      container.read(chatMessagesProvider.notifier).setMessages([
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 7, 14),
          isStreaming: true,
        ),
      ]);

      SyncTerminalException? thrown;
      try {
        await runner.run(chatId: chatId, payload: payload(assistantId));
      } on SyncTerminalException catch (e) {
        thrown = e;
      }
      check(thrown).isNotNull();
      check(thrown!.statusCode).equals(401);

      // Check Drift row
      final row = await db.messagesDao.getMessage(chatId, assistantId);
      check(row).isNotNull();
      final payloadMap = jsonDecode(row!.payload) as Map<String, dynamic>;
      final metadata = payloadMap['metadata'] as Map<String, dynamic>;
      check(payloadMap['isStreaming']).equals(false);
      final errorContent = (payloadMap['error'] as Map)['content'] as String;
      check(errorContent.contains('secret-token-xyz')).isFalse();
      check(metadata['completionSubmitted']).equals(false);
      check(metadata['terminal']).equals(true);

      // Check Active UI
      final activeMsgs = container.read(chatMessagesProvider);
      final activeAsst = activeMsgs.firstWhere((m) => m.id == assistantId);
      check(activeAsst.isStreaming).equals(false);
      check(activeAsst.error?.content?.contains('secret-token-xyz') ?? false)
          .isFalse();
    },
  );

  test(
    'headless drive terminal 400 failure settles DB row without mutating active foreign chat',
    () async {
      const chatId = 'chat-headless-fail';
      const assistantId = 'asst-headless-fail';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        assistantId,
        '',
        payload: const <String, dynamic>{
          'id': assistantId,
          'role': 'assistant',
          'content': '',
          'isStreaming': true,
        },
      );

      final fakeApi = _FakeCompletionApiService(
        onSendMessageSession: () async {
          throw const SyncTerminalException(
            statusCode: 400,
            message: 'unsupported vision',
          );
        },
      );

      final foreignMessage = ChatMessage(
        id: 'foreign-msg',
        role: 'user',
        content: 'I am in a different chat',
        timestamp: DateTime.utc(2026, 7, 14),
      );

      final (:container, :runner) = makeRunner(
        active: conv('a-different-chat'),
        apiService: fakeApi,
      );
      container.read(chatMessagesProvider.notifier).setMessages([foreignMessage]);

      await check(
        runner.run(chatId: chatId, payload: payload(assistantId)),
      ).throws<SyncTerminalException>();

      // Target chat row is settled in DB
      final row = await db.messagesDao.getMessage(chatId, assistantId);
      check(row).isNotNull();
      final payloadMap = jsonDecode(row!.payload) as Map<String, dynamic>;
      check(payloadMap['isStreaming']).equals(false);
      check((payloadMap['error'] as Map)['content']).equals('unsupported vision');
      final metadata = payloadMap['metadata'] as Map<String, dynamic>;
      check(metadata['completionSubmitted']).equals(false);
      check(metadata['terminal']).equals(true);

      // Active foreign conversation UI was NOT mutated
      check(container.read(activeConversationProvider)?.id)
          .equals('a-different-chat');
      final activeMsgs = container.read(chatMessagesProvider);
      check(activeMsgs.single.id).equals('foreign-msg');
    },
  );

  test(
    'transient network failure leaves placeholder streaming and does not mark terminal or responseDone',
    () async {
      const chatId = 'chat-transient-net';
      const assistantId = 'asst-transient-net';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        assistantId,
        '',
        payload: const <String, dynamic>{
          'id': assistantId,
          'role': 'assistant',
          'content': '',
          'isStreaming': true,
        },
      );

      final fakeApi = _FakeCompletionApiService(
        onSendMessageSession: () async {
          throw DioException(
            requestOptions: RequestOptions(path: '/api/chat/completions'),
            type: DioExceptionType.connectionTimeout,
            message: 'Connection timed out',
          );
        },
      );

      final (:container, :runner) = makeRunner(
        active: conv(chatId),
        apiService: fakeApi,
      );
      container.read(chatMessagesProvider.notifier).setMessages([
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 7, 14),
          isStreaming: true,
        ),
      ]);

      await check(
        runner.run(chatId: chatId, payload: payload(assistantId)),
      ).throws<DioException>();

      // Drift DB row must remain streaming, no terminal marker, no error, no responseDone!
      final row = await db.messagesDao.getMessage(chatId, assistantId);
      check(row).isNotNull();
      final payloadMap = jsonDecode(row!.payload) as Map<String, dynamic>;
      check(payloadMap['isStreaming']).equals(true);
      check(payloadMap.containsKey('error')).isFalse();
      final metadata = payloadMap['metadata'] as Map<String, dynamic>?;
      check(metadata?['terminal'] == true).isFalse();
      check(metadata?['responseDone'] == true).isFalse();

      // Active UI also remains streaming
      final activeAsst = container.read(chatMessagesProvider).single;
      check(activeAsst.isStreaming).equals(true);
      check(activeAsst.error).isNull();
    },
  );

  test(
    'accepted submitted completion uses recovery path and does not re-POST or settle pre-submission failure',
    () async {
      const chatId = 'chat-submitted-no-repost';
      const assistantId = 'asst-submitted-no-repost';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        assistantId,
        'prior partial content',
        payload: const <String, dynamic>{
          'id': assistantId,
          'role': 'assistant',
          'content': 'prior partial content',
          'metadata': <String, dynamic>{'completionSubmitted': true},
        },
      );

      var sendCalled = false;
      final fakeApi = _FakeCompletionApiService(
        onSendMessageSession: () async {
          sendCalled = true;
          throw const SyncTerminalException(
            statusCode: 400,
            message: 'should not be called',
          );
        },
      );

      final (:container, :runner) = makeRunner(
        active: conv(chatId),
        apiService: fakeApi,
        recoveryAttempts: 1,
        recoveryDelay: Duration.zero,
      );

      await runner.run(chatId: chatId, payload: payload(assistantId));

      check(sendCalled).isFalse(); // Never re-POSTs an accepted submission!
      final row = await db.messagesDao.getMessage(chatId, assistantId);
      check(row?.content).equals('prior partial content');
    },
  );

  group('parked terminal settlement', () {
    const cases = [
      (
        status: 404,
        submitted: false,
        message: 'The LobeHub topic no longer exists.',
        visible: 'The LobeHub topic no longer exists.',
      ),
      (
        status: 409,
        submitted: false,
        message: 'Ambiguous alias: Bearer synthetic-secret token=fixture',
        visible: 'The request could not be completed.',
      ),
      (
        status: 503,
        submitted: false,
        message: 'This completion cannot be executed by the Agent service.',
        visible: 'This completion cannot be executed by the Agent service.',
      ),
      (
        status: 400,
        submitted: true,
        message: 'The submitted stream was rejected.',
        visible: 'The submitted stream was rejected.',
      ),
      (
        status: 409,
        submitted: true,
        message: 'LobeHub could not reconcile this submitted turn.',
        visible: 'LobeHub could not reconcile this submitted turn.',
      ),
      (
        status: 500,
        submitted: true,
        message:
            'response.failed: Bearer synthetic-secret Stack trace: #0 error',
        visible: 'The request could not be completed.',
      ),
      (
        status: 500,
        submitted: true,
        message: 'response.failed: Agent execution failed.',
        visible: 'response.failed: Agent execution failed.',
      ),
    ];
    for (final failure in cases) {
      for (final targetIsActive in [true, false]) {
        test(
          'typed ${failure.status} ${failure.message == failure.visible ? 'safe message' : 'sanitized message'} ${failure.submitted ? 'with a barrier written during send' : 'before submission'} settles ${targetIsActive ? 'Drift and live target UI' : 'Drift without touching a colliding foreign UI'} without automatic re-POST',
          () async {
            const chatId = 'chat-parked';
            const assistantId = 'asst-parked';
            await seedChat(chatId);
            await seedMessage(
              chatId,
              assistantId,
              '',
              payload: const <String, dynamic>{
                'id': assistantId,
                'role': 'assistant',
                'content': '',
                'isStreaming': true,
              },
            );
            final seq = await db.transaction(
              () => db.outboxDao.enqueue(
                kind: OutboxKind.requestCompletion,
                chatId: chatId,
                payload: payload(assistantId),
              ),
            );
            final correlation = LobeAgentCorrelation(
              topicId: chatId,
              agentId: 'fixture-agent',
              userText: 'fixture prompt',
              userLocalId: 'fixture-user',
              assistantLocalId: assistantId,
              snapshotServerIds: {'fixture-prior-server-message'},
              createdAt: DateTime.utc(2026, 10, 4),
            );
            var sendCalls = 0;
            final fakeApi = _FakeCompletionApiService(
              preDispatchCorrelation: failure.submitted ? correlation : null,
              onSendMessageSession: () async {
                sendCalls++;
                final sendingRow = await db.messagesDao.getMessage(
                  chatId,
                  assistantId,
                );
                final sendingPayload =
                    jsonDecode(sendingRow!.payload) as Map<String, dynamic>;
                final sendingMeta =
                    sendingPayload['metadata'] as Map<String, dynamic>?;
                expect(sendingPayload['isStreaming'], isTrue);
                expect(sendingPayload['error'], isNull);
                expect(sendingMeta?['terminal'], isNot(true));
                expect(
                  sendingMeta?['completionSubmitted'] == true,
                  failure.submitted,
                );
                throw SyncTerminalException(
                  statusCode: failure.status,
                  message: failure.message,
                );
              },
            );
            final active = targetIsActive
                ? conv(chatId)
                : withChatStorageProvenance(
                    conv(chatId),
                    ChatStorageKind.directLocal,
                  );
            final (:container, :runner) = makeRunner(
              active: active,
              apiService: fakeApi,
              recoveryAttempts: 1,
              recoveryDelay: Duration.zero,
            );
            final initialMessages = [
              ChatMessage(
                id: assistantId,
                role: 'assistant',
                content: targetIsActive ? '' : 'foreign streaming bytes',
                timestamp: DateTime.utc(2026, 10, 4),
                isStreaming: true,
              ),
            ];
            container
                .read(chatMessagesProvider.notifier)
                .setMessages(initialMessages);
            final initialUi = jsonEncode(
              initialMessages.map((message) => message.toJson()).toList(),
            );
            final drainer = makeDrainer(runner);

            await drainer.drain();

            final op = await (db.select(
              db.outboxOps,
            )..where((row) => row.seq.equals(seq))).getSingle();
            expect(op.status, OutboxStatus.failed);
            expect(op.attempts, 1);
            final row = await db.messagesDao.getMessage(chatId, assistantId);
            final settled = jsonDecode(row!.payload) as Map<String, dynamic>;
            expect(settled['isStreaming'], isFalse);
            expect((settled['error'] as Map)['content'], failure.visible);
            final metadata = settled['metadata'] as Map<String, dynamic>;
            expect(op.lastError, contains('(${failure.status})'));
            expect(op.lastError, contains(failure.visible));
            expect(op.lastError, isNot(contains('synthetic-secret')));
            expect(row.content, isEmpty);
            expect(settled['content'], isEmpty);
            expect(metadata['completionSubmitted'], failure.submitted);
            if (failure.submitted) {
              expect(metadata['lobeAgentCorrelation'], correlation.toJson());
              expect(metadata['terminal'], isNot(true));
              expect(metadata['responseDone'], isTrue);
              expect(settled['done'], isTrue);
            } else {
              expect(metadata['terminal'], isTrue);
              expect(metadata['responseDone'], isNull);
              expect(settled['done'], isNull);
            }
            final activeAssistant = container.read(chatMessagesProvider).single;
            if (targetIsActive) {
              expect(activeAssistant.isStreaming, isFalse);
              expect(activeAssistant.error?.content, failure.visible);
              expect(container.read(isChatStreamingProvider), isFalse);
            } else {
              expect(
                jsonEncode(
                  container
                      .read(chatMessagesProvider)
                      .map((message) => message.toJson())
                      .toList(),
                ),
                initialUi,
              );
              expect(container.read(isChatStreamingProvider), isTrue);
              expect(
                chatStorageKindOf(container.read(activeConversationProvider)),
                ChatStorageKind.directLocal,
              );
            }

            await drainer.drain();
            expect(sendCalls, 1);
            if (failure.submitted) {
              final (runner: restartedRunner, container: _) = makeRunner(
                active: active,
                apiService: fakeApi,
                recoveryAttempts: 1,
                recoveryDelay: Duration.zero,
              );
              await restartedRunner.run(
                chatId: chatId,
                payload: payload(assistantId),
              );
              expect(sendCalls, 1);
              expect(
                (await db.messagesDao.getMessage(chatId, assistantId))!.payload,
                row.payload,
              );
              await db.outboxDao.requeueParked(seq, nowEpochSeconds: 1000);
              await drainer.drain();
              expect(sendCalls, 1);
              expect(await db.select(db.outboxOps).get(), isEmpty);
              expect(
                (await db.messagesDao.getMessage(chatId, assistantId))!.payload,
                row.payload,
              );
            } else {
              await db.outboxDao.requeueParked(seq, nowEpochSeconds: 1000);
              await drainer.drain();
              expect(sendCalls, 2);
              final retried = await (db.select(
                db.outboxOps,
              )..where((row) => row.seq.equals(seq))).getSingle();
              expect(retried.status, OutboxStatus.failed);
            }
          },
        );
      }
    }

    test(
      'auth epoch change during terminal settlement read defers without Drift or live UI writes',
      () async {
        const chatId = 'chat-terminal-owner-switch';
        const assistantId = 'asst-terminal-owner-switch';
        await seedChat(chatId);
        await seedMessage(
          chatId,
          assistantId,
          '',
          payload: const <String, dynamic>{'isStreaming': true},
        );
        var authSessionEpoch = Object();
        final failureReady = Completer<void>();
        final transactionEntered = Completer<void>();
        final releaseTransaction = Completer<void>();
        late Future<void> transaction;
        final fakeApi = _FakeCompletionApiService(
          onSendMessageSession: () async {
            transaction = db.transaction(() async {
              transactionEntered.complete();
              await releaseTransaction.future;
            });
            await transactionEntered.future;
            failureReady.complete();
            throw const SyncTerminalException(
              statusCode: 400,
              message: 'fixture terminal rejection',
            );
          },
        );
        final (:container, :runner) = makeRunner(
          active: conv(chatId),
          apiService: fakeApi,
          authSessionEpoch: () => authSessionEpoch,
        );
        container.read(chatMessagesProvider.notifier).setMessages([
          ChatMessage(
            id: assistantId,
            role: 'assistant',
            content: '',
            timestamp: DateTime.utc(2026, 10, 4),
            isStreaming: true,
          ),
        ]);
        final expectation = expectLater(
          runner.run(chatId: chatId, payload: payload(assistantId)),
          throwsA(isA<CompletionDatabaseUnavailableException>()),
        );
        await failureReady.future;
        await Future<void>.delayed(Duration.zero);
        authSessionEpoch = Object();
        container.invalidate(openWebUiAuthSessionEpochProvider);
        releaseTransaction.complete();
        await transaction;
        await expectation;

        final row = await db.messagesDao.getMessage(chatId, assistantId);
        final unchanged = jsonDecode(row!.payload) as Map<String, dynamic>;
        expect(unchanged['isStreaming'], isTrue);
        expect(unchanged['error'], isNull);
        expect(
          (unchanged['metadata'] as Map?)?['completionSubmitted'],
          isNot(true),
        );
        expect(container.read(chatMessagesProvider).single.isStreaming, isTrue);
        expect(container.read(chatMessagesProvider).single.error, isNull);
      },
    );
  });

  test(
    'submitted terminal 500 surfaced from a failed byte stream retains partial content and visibly settles without replay',
    () async {
      const chatId = 'chat-failed-stream';
      const assistantId = 'asst-failed-stream';
      const partialContent = 'partial response before failure';
      const failureMessage = 'response.failed: Agent execution failed.';
      await seedChat(chatId);
      await seedMessage(
        chatId,
        assistantId,
        partialContent,
        payload: const <String, dynamic>{
          'id': assistantId,
          'role': 'assistant',
          'content': partialContent,
          'isStreaming': true,
        },
      );
      final correlation = LobeAgentCorrelation(
        topicId: chatId,
        agentId: 'fixture-agent',
        userText: 'fixture prompt',
        userLocalId: 'fixture-user',
        assistantLocalId: assistantId,
        snapshotServerIds: const {'prior-server-message'},
        createdAt: DateTime.utc(2026, 10, 4),
      );
      var sendCalls = 0;
      final fakeApi = _FakeCompletionApiService(
        preDispatchCorrelation: correlation,
        onSendMessageSession: () async {
          sendCalls++;
          await Stream<List<int>>.error(
            const SyncTerminalException(
              statusCode: 500,
              message: failureMessage,
            ),
          ).drain<void>();
          throw StateError('Expected the failed byte stream to throw');
        },
      );
      final (:container, :runner) = makeRunner(
        active: conv(chatId),
        apiService: fakeApi,
      );
      container.read(chatMessagesProvider.notifier).setMessages([
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: partialContent,
          timestamp: DateTime.utc(2026, 10, 4),
          isStreaming: true,
        ),
      ]);
      final observedUi = <List<ChatMessage>>[];
      final subscription = container.listen(
        chatMessagesProvider,
        (previous, next) => observedUi.add(next),
      );
      addTearDown(subscription.close);
      final seq = await db.transaction(
        () => db.outboxDao.enqueue(
          kind: OutboxKind.requestCompletion,
          chatId: chatId,
          payload: payload(assistantId),
        ),
      );
      final drainer = makeDrainer(runner);

      await drainer.drain();

      final op = await (db.select(
        db.outboxOps,
      )..where((row) => row.seq.equals(seq))).getSingle();
      expect(op.status, OutboxStatus.failed);
      expect(op.lastError, contains('(500)'));
      expect(op.lastError, contains(failureMessage));
      final row = await db.messagesDao.getMessage(chatId, assistantId);
      final settled = jsonDecode(row!.payload) as Map<String, dynamic>;
      final metadata = settled['metadata'] as Map<String, dynamic>;
      expect(row.content, partialContent);
      expect(settled['content'], partialContent);
      expect(settled['isStreaming'], isFalse);
      expect(settled['done'], isTrue);
      expect((settled['error'] as Map)['content'], failureMessage);
      expect(metadata['completionSubmitted'], isTrue);
      expect(metadata['responseDone'], isTrue);
      expect(metadata['lobeAgentCorrelation'], correlation.toJson());
      expect(metadata['terminal'], isNot(true));
      expect(observedUi.last.single.isStreaming, isFalse);
      expect(observedUi.last.single.content, partialContent);
      expect(observedUi.last.single.error?.content, failureMessage);
      expect(container.read(isChatStreamingProvider), isFalse);

      await db.outboxDao.requeueParked(seq, nowEpochSeconds: 1000);
      await drainer.drain();
      await runner.run(chatId: chatId, payload: payload(assistantId));

      expect(sendCalls, 1);
      expect(await db.select(db.outboxOps).get(), isEmpty);
      expect(
        (await db.messagesDao.getMessage(chatId, assistantId))!.payload,
        row.payload,
      );
      expect(
        container.read(chatMessagesProvider).single.error?.content,
        failureMessage,
      );
    },
  );

  group('transport failures remain retryable', () {
    const cases = [
      (type: DioExceptionType.connectionTimeout, status: null),
      (type: DioExceptionType.sendTimeout, status: 400),
      (type: DioExceptionType.receiveTimeout, status: 401),
      (type: DioExceptionType.connectionError, status: 403),
      (type: DioExceptionType.badResponse, status: 404),
      (type: DioExceptionType.badResponse, status: 409),
      (type: DioExceptionType.badResponse, status: 500),
      (type: DioExceptionType.badResponse, status: 503),
    ];
    for (final failure in cases) {
      test(
        '${failure.type.name} ${failure.status} retries unsubmitted work',
        () async {
          const chatId = 'chat-retryable';
          const assistantId = 'asst-retryable';
          await seedChat(chatId);
          await seedMessage(
            chatId,
            assistantId,
            '',
            payload: const <String, dynamic>{'isStreaming': true},
          );
          var sendCalls = 0;
          final options = RequestOptions(path: '/fixture/completion');
          final failureError = DioException(
            requestOptions: options,
            type: failure.type,
            response: failure.status == null
                ? null
                : Response(requestOptions: options, statusCode: failure.status),
          );
          final fakeApi = _FakeCompletionApiService(
            onSendMessageSession: () async {
              sendCalls++;
              throw failureError;
            },
          );
          final (:container, :runner) = makeRunner(
            active: conv(chatId),
            apiService: fakeApi,
          );
          container.read(chatMessagesProvider.notifier).setMessages([
            ChatMessage(
              id: assistantId,
              role: 'assistant',
              content: '',
              timestamp: DateTime.utc(2026, 10, 4),
              isStreaming: true,
            ),
          ]);
          final seq = await db.transaction(
            () => db.outboxDao.enqueue(
              kind: OutboxKind.requestCompletion,
              chatId: chatId,
              payload: payload(assistantId),
            ),
          );
          final drainer = makeDrainer(runner);
          await drainer.drain();
          final op = await (db.select(
            db.outboxOps,
          )..where((row) => row.seq.equals(seq))).getSingle();
          expect(op.status, OutboxStatus.pending);
          expect(op.attempts, 1);
          expect(op.nextAttemptAt, greaterThan(1000));
          expect(sendCalls, 1);

          await db.outboxDao.retryPendingNow(seq, nowEpochSeconds: 1000);
          await drainer.drain();
          expect(sendCalls, 2);
          final row = await db.messagesDao.getMessage(chatId, assistantId);
          final unsettled = jsonDecode(row!.payload) as Map<String, dynamic>;
          final metadata = unsettled['metadata'] as Map<String, dynamic>?;
          expect(unsettled['isStreaming'], isTrue);
          expect(unsettled['error'], isNull);
          expect(metadata?['terminal'], isNot(true));
          expect(metadata?['responseDone'], isNot(true));
          expect(metadata?['completionSubmitted'], isNot(true));
          expect(
            container.read(chatMessagesProvider).single.isStreaming,
            isTrue,
          );
          expect(container.read(chatMessagesProvider).single.error, isNull);
        },
      );
    }
  });

  for (final status in <int?>[503, null]) {
    test(
      'submitted ${status == null ? 'Dio timeout' : 'Dio $status'} remains pending and keeps its dispatch barrier',
      () async {
        const chatId = 'chat-submitted-transient';
        const assistantId = 'asst-submitted-transient';
        await seedChat(chatId);
        await seedMessage(
          chatId,
          assistantId,
          '',
          payload: const <String, dynamic>{'isStreaming': true},
        );
        final correlation = LobeAgentCorrelation(
          topicId: chatId,
          agentId: 'fixture-agent',
          userText: 'fixture prompt',
          userLocalId: 'fixture-user',
          assistantLocalId: assistantId,
          snapshotServerIds: const {},
          createdAt: DateTime.utc(2026, 10, 4),
        );
        final options = RequestOptions(path: '/fixture/completion');
        final error = DioException(
          requestOptions: options,
          type: status == null
              ? DioExceptionType.connectionTimeout
              : DioExceptionType.badResponse,
          response: status == null
              ? null
              : Response(requestOptions: options, statusCode: status),
        );
        var sendCalls = 0;
        final fakeApi = _FakeCompletionApiService(
          preDispatchCorrelation: correlation,
          onSendMessageSession: () async {
            sendCalls++;
            throw error;
          },
        );
        final (:container, :runner) = makeRunner(
          active: conv(chatId),
          apiService: fakeApi,
        );
        container.read(chatMessagesProvider.notifier).setMessages([
          ChatMessage(
            id: assistantId,
            role: 'assistant',
            content: '',
            timestamp: DateTime.utc(2026, 10, 4),
            isStreaming: true,
          ),
        ]);
        final seq = await db.transaction(
          () => db.outboxDao.enqueue(
            kind: OutboxKind.requestCompletion,
            chatId: chatId,
            payload: payload(assistantId),
          ),
        );
        final drainer = makeDrainer(runner);

        await drainer.drain();
        await drainer.drain();

        final op = await (db.select(
          db.outboxOps,
        )..where((row) => row.seq.equals(seq))).getSingle();
        expect(op.status, OutboxStatus.pending);
        expect(op.attempts, 1);
        expect(op.nextAttemptAt, greaterThan(1000));
        expect(sendCalls, 1);
        final row = await db.messagesDao.getMessage(chatId, assistantId);
        final unsettled = jsonDecode(row!.payload) as Map<String, dynamic>;
        final metadata = unsettled['metadata'] as Map<String, dynamic>;
        expect(unsettled['isStreaming'], isTrue);
        expect(unsettled['error'], isNull);
        expect(metadata['completionSubmitted'], isTrue);
        expect(metadata['lobeAgentCorrelation'], correlation.toJson());
        expect(metadata['terminal'], isNot(true));
        expect(metadata['responseDone'], isNot(true));
        expect(container.read(chatMessagesProvider).single.isStreaming, isTrue);
        expect(container.read(chatMessagesProvider).single.error, isNull);
      },
    );
  }
}

class _FakeCompletionApiService extends Fake implements ApiService {
  _FakeCompletionApiService({
    this.onSendMessageSession,
    this.preDispatchCorrelation,
  });

  @override
  final ServerConfig serverConfig = const ServerConfig(
    id: 'server-1',
    name: 'S',
    url: 'http://localhost',
  );

  final Future<ChatCompletionSession> Function()? onSendMessageSession;
  final LobeAgentCorrelation? preDispatchCorrelation;

  @override
  Future<Map<String, dynamic>> getUserSettings({
    ApiAuthSnapshot? authSnapshot,
  }) async => <String, dynamic>{};

  @override
  Future<ChatCompletionSession> sendMessageSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? terminalId,
    List<String>? toolIds,
    List<String>? filterIds,
    List<String>? skillIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    String? sessionIdOverride,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    String? responseMessageId,
    Map<String, dynamic>? userSettings,
    String? reasoningEffort,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
    String? lobeAgentId,
    Future<void> Function(LobeAgentCorrelation correlation)? onPreDispatch,
  }) async {
    final correlation = preDispatchCorrelation;
    if (correlation != null) {
      await onPreDispatch!(correlation);
    }
    if (onSendMessageSession != null) {
      return await onSendMessageSession!();
    }
    throw UnimplementedError();
  }
}

class _TestModels extends Models {
  @override
  Future<List<Model>> build() async => const [
    Model(id: 'model-1', name: 'Model 1', supportsStreaming: true),
  ];
}

class _TestSyncClock implements SyncClock {
  const _TestSyncClock();

  @override
  int nowEpochSeconds() => 1000;
}

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this._initial);

  final Conversation? _initial;

  @override
  Conversation? build() => _initial;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }
}

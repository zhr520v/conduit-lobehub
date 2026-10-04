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
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
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
  /// throwaway provider, under the given overrides.
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
}

class _FakeCompletionApiService extends Fake implements ApiService {
  _FakeCompletionApiService({this.onSendMessageSession});

  @override
  final ServerConfig serverConfig = const ServerConfig(
    id: 'server-1',
    name: 'S',
    url: 'http://localhost',
  );

  final Future<ChatCompletionSession> Function()? onSendMessageSession;

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
    if (onSendMessageSession != null) {
      return await onSendMessageSession!();
    }
    throw UnimplementedError();
  }
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

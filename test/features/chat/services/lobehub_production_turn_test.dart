import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/request_completion_runner.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/persistence_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/request_completion_runner_provider.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

const _localChatId = 'local:production-first-turn';
const _userId = 'fixture-user';
const _assistantId = 'fixture-assistant';
const _modelId = 'fixture-model';
const _providerId = 'anthropic';
const _agentId = 'agent-research';
const _foreignModelId = 'foreign-model';
const _foreignChatId = 'foreign-topic';
const _prompt = 'Synthetic loopback prompt';
const _answer = 'A real production turn reached assistant persistence.';
const _partialAnswer = 'Partial foreground answer';
const _streamSecret = 'sk-synthetic-stream-secret';
const _token = 'loopback-fixture-not-a-user-credential';
const _durableTimestamp = 1791072000;

final _targetModel = Model(
  id: _modelId,
  name: 'Fixture Model',
  metadata: const {'provider': _providerId},
);
final _foreignModel = Model(
  id: _foreignModelId,
  name: 'Foreign Model',
  metadata: const {'provider': 'openai'},
);
const _collidingModel = Model(
  id: _modelId,
  name: 'Same ID on foreign provider',
  metadata: {'provider': 'openai'},
);
const _pinnedModel = Model(
  id: 'fixture-pinned-model',
  name: 'Verified topic runtime',
  metadata: {'provider': 'google'},
);

enum _Result {
  success,
  rejected,
  failedStream,
  incompleteStream,
  delayedPersistence,
  interruptedPersistence,
  incompletePersistence,
  partialToFinalPersistence,
  interruptedSnapshot,
}

void main() {
  _LoopbackBinding();

  test('headless landing preserves mapped terminal flags, output, errors and OpenWebUI content', () {
    final completed = ChatMessage(
      id: 'mapped-assistant',
      role: 'assistant',
      content: _answer,
      timestamp: DateTime.utc(2026, 10, 4),
      metadata: const {'model': _modelId, 'provider': _providerId},
    );
    expect(headlessAssistantLandedForTest(completed, isLobeHub: true), true);
    for (final unfinished in <Map<String, dynamic>>[
      {'interruptedMidStream': true},
      {'finishType': 'length'},
      {'operationId': 'unfinished-operation'},
      {'done': false},
      {'isStreaming': true},
      {'responseDone': false},
    ]) {
      final partial = completed.copyWith(
        content: _partialAnswer,
        metadata: {...completed.metadata!, ...unfinished},
      );
      expect(headlessAssistantLandedForTest(partial, isLobeHub: true), false);
      expect(headlessAssistantLandedForTest(partial), true,
          reason: 'OpenWebUI retains its established nonempty-content landing policy');
    }
    final streaming = completed.copyWith(
      isStreaming: true,
      metadata: {...completed.metadata!, 'responseDone': true},
    );
    expect(headlessAssistantLandedForTest(streaming, isLobeHub: true), false);
    final outputOnly = completed.copyWith(
      content: '',
      output: const [{'type': 'reasoning', 'summary': 'Final structured result'}],
      metadata: const {'responseDone': true, 'operationId': 'finished-operation'},
    );
    expect(headlessAssistantLandedForTest(outputOnly, isLobeHub: true), true);
    expect(headlessAssistantLandedForTest(outputOnly.copyWith(
      metadata: const {'responseDone': false},
    ), isLobeHub: true), false);
    final failure = streaming.copyWith(
      error: const ChatMessageError(content: 'Synthetic persisted failure'),
    );
    expect(lobeHubAssistantResultComplete(failure.toJson()), false);
    expect(headlessAssistantLandedForTest(failure, isLobeHub: true), true,
        reason: 'A persisted error lands as a visible error, not successful recovery');
  });

  test('raw flag-free durable first turn executes and persists exactly one pair',
      () async {
    await _runCase('raw-first-turn', (harness) async {
      await harness.drain();
      await harness.expectSuccessfulPair();
      expect(harness.server.executionRequests.single['path'], '/api/v1/chat');
      final body = harness.server.executionRequests.single['body'] as Map;
      expect(body['model'], _modelId);
      expect(body['provider'], _providerId);
      expect(body['stream'], false);
      expect(body['messages'], [
        {'role': 'user', 'content': _prompt},
      ]);
      expect(harness.server.createdMessages.map((message) => message['role']),
          ['user', 'assistant']);
      final atDispatch = harness.server.executionSnapshots.single;
      expect(atDispatch['serverMessageCount'], 0);
      expect(atDispatch['outbox'], [
        allOf(containsPair('kind', 'requestCompletion'),
            containsPair('status', 'inFlight')),
      ]);
      await harness.expectRecoveryDoesNotExecuteAgain();
    });
  });

  test('Agent-bound pending pair skips CRUD and preserves target role binding',
      () async {
    await _runCase('agent-pending-pair', (harness) async {
      await harness.drain();
      await harness.expectSuccessfulPair();
      final execution = harness.server.executionRequests.single;
      expect(execution['path'], '/api/v1/responses');
      final body = execution['body'] as Map;
      expect(body['model'], _agentId);
      expect(body['model'], isNot(_foreignModelId));
      expect(body['previous_response_id'], harness.topicId);
      expect(body['input'], _prompt);
      expect(body['stream'], true);
      expect(harness.server.createdMessages, isEmpty);
      expect(harness.server.topics.single['agentId'], _agentId);
      final atDispatch = harness.server.executionSnapshots.single;
      expect(atDispatch['serverMessageCount'], 0);
      final placeholder = atDispatch['placeholder'] as Map;
      final metadata = placeholder['metadata'] as Map;
      expect(metadata['completionSubmitted'], true);
      final correlation = metadata['lobeAgentCorrelation'] as Map;
      expect(correlation['topicId'], harness.topicId);
      expect(correlation['agentId'], _agentId);
      expect(correlation['userLocalId'], _userId);
      expect(correlation['assistantLocalId'], _assistantId);
      expect(correlation['snapshotServerIds'], isEmpty);
      expect(harness.server.messages.singleWhere(
        (message) => message['role'] == 'assistant',
      )['parentId'], harness.server.messages.singleWhere(
        (message) => message['role'] == 'user',
      )['id']);
      await harness.expectRecoveryDoesNotExecuteAgain();
    }, agent: true, foreignSelection: true);
  });

  test('raw target provider is not borrowed from the foreign active selection',
      () async {
    await _runCase('raw-foreign-provider', (harness) async {
      expect(harness.container.read(selectedModelProvider)?.id, _foreignModelId);
      await harness.drain();
      await harness.expectSuccessfulPair();
      final body = harness.server.executionRequests.single['body'] as Map;
      expect(body['model'], _modelId);
      expect(body['provider'], _providerId);
      expect(body['provider'], isNot('openai'));
      expect(harness.container.read(selectedModelProvider)?.id, _foreignModelId);
      await harness.expectRecoveryDoesNotExecuteAgain();
    }, foreignSelection: true);
  });

  test('real HTTP 400 parks the completion with a visible non-streaming error',
      () async {
    await _runCase('raw-http-400', (harness) async {
      await harness.drain();
      final ops = await harness.db.select(harness.db.outboxOps).get();
      expect(ops, hasLength(1));
      expect(ops.single.kind, 'requestCompletion');
      expect(ops.single.chatId, harness.topicId);
      expect(ops.single.status, OutboxStatus.failed);
      expect(ops.single.attempts, 1);
      expect(ops.single.lastError, contains('400'));
      await harness.expectVisibleFailure();
      final before = harness.server.executionRequests.length;
      await harness.drain();
      await harness.drain();
      expect(harness.server.executionRequests.length, before);
      expect(harness.server.messages, isEmpty);
      expect(await harness.db.messagesDao.getForChat(harness.topicId),
          hasLength(2));
      expect(harness.container.read(localChatGenerationActiveProvider), false);
    }, result: _Result.rejected);
  });

  test('accepted response.failed settles visibly and recovery never re-POSTs',
      () async {
    await _runCase('agent-failed-generation', (harness) async {
      await harness.drain();
      await harness.expectVisibleFailure();
      expect(harness.server.executionRequests, hasLength(1));
      expect(harness.server.executionRequests.single['path'], '/api/v1/responses');
      expect(harness.server.createdMessages, isEmpty);
      expect(harness.server.messages, isEmpty);
      expect(await harness.db.messagesDao.getForChat(harness.topicId),
          hasLength(2));
      final row = await harness.db.messagesDao.getMessage(
        harness.topicId, _assistantId,
      );
      expect((jsonDecode(row!.payload) as Map)['metadata'],
          containsPair('completionSubmitted', true));
      await harness.expectRecoveryDoesNotExecuteAgain(success: false);
    }, agent: true, result: _Result.failedStream);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('bounded real recovery polls collect delayed server persistence once',
      () async {
    await _runCase('agent-recovery-poll', (harness) async {
      await harness.drain();
      await harness.expectSuccessfulPair();
      expect(harness.server.messageReadsAfterExecution, greaterThanOrEqualTo(5));
      expect(harness.server.executionRequests, hasLength(1));
      expect(harness.server.createdMessages, isEmpty);
      expect(harness.server.executionSnapshots.single['serverMessageCount'], 0);
      await harness.expectRecoveryDoesNotExecuteAgain();
    }, agent: true, result: _Result.delayedPersistence);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('foreground raw durableSend retains its captured same-ID provider',
      () async {
    await _runForegroundCase('foreground-raw-captured-provider', (harness) async {
      await harness.sendForeground();
      harness.expectForegroundDispatch();
      final body = harness.server.executionRequests.single['body'] as Map;
      expect(body, containsPair('model', _modelId));
      expect(body, containsPair('provider', _providerId));
      expect(body['messages'], [
        {'role': 'user', 'content': _prompt},
      ]);
      expect(body['stream'], false);
      expect(harness.server.createdMessages.map((message) => message['role']),
          ['user', 'assistant']);
      expect(harness.observedTransports, contains('jsonCompletion'));
      expect(harness.container.read(selectedModelProvider), _collidingModel);
      await harness.expectForegroundPair();
      await harness.expectForegroundRecovery();
    });
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('foreground Agent durableSend uses verified topic pin after roster changes',
      () async {
    await _runForegroundCase('foreground-agent-pinned-runtime', (harness) async {
      await harness.sendForeground();
      harness.expectForegroundDispatch();
      final execution = harness.server.executionRequests.single;
      expect(execution['path'], '/api/v1/responses');
      final body = execution['body'] as Map;
      expect(body['model'], _agentId);
      expect(body['previous_response_id'], harness.topicId);
      expect(body['input'], _prompt);
      expect(body['stream'], true);
      expect(harness.server.topics.single['agentId'], _agentId);
      expect(harness.server.topics.single['model'], _pinnedModel.id);
      expect(harness.server.topics.single['provider'], 'google');
      final assistant = harness.server.messages.singleWhere(
        (message) => message['role'] == 'assistant',
      );
      expect(assistant['model'], _pinnedModel.id);
      expect(assistant['provider'], 'google');
      expect(harness.server.createdMessages, isEmpty);
      expect(harness.observedTransports, contains('httpStream'));
      expect(harness.container.read(lobeSelectedAgentIdProvider),
          'foreign-global-agent');
      expect(await harness.container.read(modelsProvider.future),
          [_collidingModel, _pinnedModel, _foreignModel]);
      final placeholder = harness.server.executionSnapshots.single['placeholder']
          as Map;
      final metadata = placeholder['metadata'] as Map;
      expect(metadata['completionSubmitted'], true);
      expect(metadata['lobeAgentCorrelation'], allOf(
        containsPair('topicId', harness.topicId),
        containsPair('agentId', _agentId),
        containsPair('userLocalId', harness.sentUserId),
        containsPair('assistantLocalId', harness.sentAssistantId),
        containsPair('snapshotServerIds', isEmpty),
      ));
      await harness.expectForegroundPair();
      await harness.expectForegroundRecovery();
    }, agent: true);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('foreground durableSend HTTP 400 clears the visible streaming placeholder',
      () async {
    await _runForegroundCase('foreground-raw-http-400', (harness) async {
      await harness.sendForeground();
      harness.expectForegroundDispatch();
      expect(harness.observedTransports, isEmpty);
      expect(harness.server.messages, isEmpty);
      final ops = await harness.db.select(harness.db.outboxOps).get();
      expect(ops, hasLength(1));
      expect(ops.single.kind, 'requestCompletion');
      expect(ops.single.chatId, harness.topicId);
      expect(ops.single.status, OutboxStatus.failed);
      expect(ops.single.attempts, 1);
      expect(ops.single.lastError, contains('400'));
      expect((jsonDecode(ops.single.payload) as Map)['assistantMessageId'],
          harness.sentAssistantId);
      await harness.engine.drainOutbox();
      await harness.engine.drainOutbox();
      expect(harness.server.executionRequests, hasLength(1));
      await harness.expectForegroundPair(success: false);
    }, result: _Result.rejected);
  }, timeout: const Timeout(Duration(seconds: 45)));

  for (final result in [_Result.failedStream, _Result.incompleteStream]) {
    final event = result == _Result.failedStream
        ? 'response.failed' : 'response.incomplete';
    test('foreground Agent $event settles durably without false success or replay',
        () async {
      await _runForegroundCase('foreground-agent-$event', (harness) async {
        await harness.sendForeground();
        harness.expectForegroundDispatch();
        expect(harness.observedTransports, contains('httpStream'));
        expect(harness.server.executionRequests.single['path'], '/api/v1/responses');
        expect(harness.server.createdMessages, isEmpty);
        expect(harness.server.messages, isEmpty);
        final partial = result == _Result.incompleteStream ? _partialAnswer : '';
        await harness.expectForegroundPair(success: false, failureContent: partial);
        await harness.expectForegroundSubmissionBarrier();
        final visibleError = harness.container.read(chatMessagesProvider)
            .last.error!.content!;
        expect(visibleError, isNot(contains(_streamSecret)));
        expect(visibleError, isNot(contains(_token)));
        expect(visibleError, isNot(contains('Authorization')));
        expect(visibleError, isNot(contains('Cookie')));
        await harness.expectForegroundRecovery(
          success: false, failureContent: partial,
        );
        expect(harness.server.createdMessages, isEmpty);
        expect(harness.server.messages, isEmpty);
        expect(harness.server.sequence.where((request) =>
            request['method'] == 'PATCH' &&
            (request['path'] as String).startsWith('/api/v1/messages/')), isEmpty);
      }, agent: true, result: result);
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  test('foreground Agent delayed persistence recovers one canonical pair without replay',
      () async {
    await _runForegroundCase('foreground-agent-delayed-persistence', (harness) async {
      await harness.sendForeground();
      harness.expectForegroundDispatch();
      expect(harness.observedTransports, contains('httpStream'));
      expect(harness.server.executionRequests.single['path'], '/api/v1/responses');
      expect(harness.server.messageReadsAfterExecution, greaterThanOrEqualTo(5));
      expect(harness.server.createdMessages, isEmpty);
      await harness.expectForegroundPair();
      await harness.expectForegroundSubmissionBarrier();
      final aliasPatches = harness.server.sequence.where((request) =>
          request['method'] == 'PATCH' &&
          (request['path'] as String).startsWith('/api/v1/messages/')).toList();
      expect(aliasPatches.map((request) => request['path']), [
        '/api/v1/messages/server-agent-user',
        '/api/v1/messages/server-agent-assistant',
      ]);
      await harness.expectForegroundRecovery();
      expect(harness.server.sequence.where((request) =>
          request['method'] == 'PATCH' &&
          (request['path'] as String).startsWith('/api/v1/messages/')), hasLength(2));
      expect(harness.server.createdMessages, isEmpty);
    }, agent: true, result: _Result.delayedPersistence);
  }, timeout: const Timeout(Duration(seconds: 45)));

  for (final loss in ['stop', 'navigation', 'auth']) {
    test('foreground Agent recovery fences $loss during a pending HTTP read',
        () async {
      await _runForegroundCase('foreground-agent-recovery-$loss', (harness) async {
        final entered = harness.server.recoveryReadEntered = Completer<void>();
        final release = harness.server.releaseRecoveryRead = Completer<void>();
        final interceptorCount = harness._api!.dio.interceptors.length;
        await harness.sendForeground(waitForSettlement: false);
        await entered.future.timeout(const Duration(seconds: 10));
        expect(harness.server.executionRequests, hasLength(1));
        final notifier = harness.container.read(chatMessagesProvider.notifier);
        if (loss == 'stop') {
          notifier.cancelActiveMessageStreamPreservingContent();
          notifier.finishStreaming();
        } else if (loss == 'navigation') {
          harness.container.read(activeConversationProvider.notifier).set(
            Conversation(
              id: _foreignChatId,
              title: 'Foreign active chat',
              createdAt: DateTime.utc(2026, 10, 4),
              updatedAt: DateTime.utc(2026, 10, 4),
              messages: [ChatMessage(
                id: 'foreign-user', role: 'user', content: 'Untouched foreign turn',
                timestamp: DateTime.utc(2026, 10, 4),
              )],
            ),
          );
        } else {
          harness._api!.updateAuthToken('synthetic-rotated-session');
          harness._api!.updateAuthToken(_token);
        }
        final transcript = jsonEncode(harness.container.read(chatMessagesProvider)
            .map((message) => message.toJson()..remove('timestamp')).toList());
        final row = await harness.db.messagesDao.getMessage(
          harness.topicId, harness.sentAssistantId,
        );
        release.complete();
        final elapsed = Stopwatch()..start();
        while (harness._api!.dio.interceptors.length != interceptorCount &&
            elapsed.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(harness._api!.dio.interceptors.length, interceptorCount);
        expect(jsonEncode(harness.container.read(chatMessagesProvider)
            .map((message) => message.toJson()..remove('timestamp')).toList()), transcript);
        final after = await harness.db.messagesDao.getMessage(
          harness.topicId, harness.sentAssistantId,
        );
        expect(after!.content, row!.content);
        expect(jsonDecode(after.payload)['error'], isNull);
        expect(harness.server.executionRequests, hasLength(1));
        expect(harness.server.messageReadsAfterExecution, 2);
        expect(harness.server.sequence.where((request) =>
            request['method'] == 'PATCH' &&
            (request['path'] as String).startsWith('/api/v1/messages/')), isEmpty);
      }, agent: true, result: _Result.delayedPersistence);
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  for (final result in [
    _Result.interruptedPersistence,
    _Result.incompletePersistence,
  ]) {
    final event = result == _Result.interruptedPersistence
        ? 'response.failed' : 'response.incomplete';
    test('foreground Agent persisted interrupted $event remains a failure without replay',
        () async {
      await _runForegroundCase('foreground-agent-persisted-$event', (harness) async {
        await harness.sendForeground();
        harness.expectForegroundDispatch();
        expect(harness.observedTransports, contains('httpStream'));
        expect(harness.server.executionRequests.single['path'], '/api/v1/responses');
        expect(harness.server.messages, hasLength(2));
        final assistant = harness.server.messages.last;
        expect(assistant['content'], _partialAnswer);
        expect(assistant['parentId'], harness.server.messages.first['id']);
        expect(assistant['model'], _pinnedModel.id);
        expect(assistant['provider'], _pinnedModel.metadata!['provider']);
        expect(assistant.containsKey('status'), false);
        expect(assistant.containsKey('error'), false);
        expect(assistant['metadata'], containsPair('interruptedMidStream', true));
        expect(harness.server.messageReadsAfterExecution, 6);
        expect(harness.server.createdMessages, isEmpty);
        expect(harness.server.sequence.where((request) =>
            request['method'] == 'PATCH' &&
            (request['path'] as String).startsWith('/api/v1/messages/')), isEmpty);
        await harness.expectForegroundPair(success: false, failureContent: _partialAnswer);
        await harness.expectForegroundSubmissionBarrier();
        harness.expectNoSuccessfulPartial();
        final error = harness.container.read(chatMessagesProvider).last.error!.content!;
        for (final secret in [_streamSecret, _token, 'Authorization', 'Cookie']) {
          expect(error, isNot(contains(secret)));
        }
        final row = await harness.db.messagesDao.getMessage(
          harness.topicId, harness.sentAssistantId,
        );
        await harness.container.read(chatRequestCompletionRunnerProvider).run(
          chatId: harness.topicId,
          payload: RequestCompletionPayload(
            assistantMessageId: harness.sentAssistantId,
            model: harness.admittedModel.id,
          ).toJson(),
        );
        await harness.engine.drainOutbox();
        await harness.engine.drainOutbox();
        expect(harness.server.executionRequests, hasLength(1));
        expect(harness.server.messageReadsAfterExecution, 6);
        expect((await harness.db.messagesDao.getMessage(
          harness.topicId, harness.sentAssistantId,
        ))!.payload, row!.payload);
        await harness.expectForegroundPair(success: false, failureContent: _partialAnswer);
        await harness.expectForegroundSubmissionBarrier();
      }, agent: true, result: result);
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  test('foreground Agent persisted partial snapshot waits for the same final row without replay',
      () async {
    await _runForegroundCase('foreground-agent-partial-to-final', (harness) async {
      await harness.sendForeground();
      harness.expectForegroundDispatch();
      expect(harness.observedTransports, contains('httpStream'));
      expect(harness.server.executionRequests.single['path'], '/api/v1/responses');
      harness.expectNoSuccessfulPartial();
      expect(harness.server.messageReadsAfterExecution, 5);
      final reads = harness.server.sequence.where((request) =>
          request['method'] == 'GET' && request.containsKey('persistedAssistant')).toList();
      expect(reads.map((request) => request['persistedAssistant']), [
        'partial', 'partial', 'final', 'stale-partial', 'final',
      ]);
      expect(reads.map((request) => request['assistantServerId']).toSet(),
          {'server-agent-assistant'});
      final stale = (reads[3]['response'] as Map)['data']['messages'].last as Map;
      expect(stale['content'], _partialAnswer);
      expect(stale.containsKey('status'), false);
      expect(stale.containsKey('error'), false);
      expect(stale['metadata'], allOf(
        containsPair('interruptedMidStream', true),
        containsPair('conduitClientId', harness.sentAssistantId),
        containsPair('completionSubmitted', true),
      ));
      harness.expectNoSuccessfulPartial();
      harness.expectMappedPartialUnfinished();
      await harness.expectForegroundPair();
      await harness.expectForegroundSubmissionBarrier();
      final reopened = (await harness.readConversation()).messages.last;
      expect(reopened.metadata, allOf(
        containsPair('responseDone', true),
        containsPair('interruptedMidStream', false),
        containsPair('finishType', 'stop'),
        containsPair('serverMessageId', 'server-agent-assistant'),
      ));
      expect(lobeHubAssistantResultComplete(reopened.toJson()), true);
      expect(harness.server.createdMessages, isEmpty);
      final patches = harness.server.sequence.where((request) =>
          request['method'] == 'PATCH' &&
          (request['path'] as String).startsWith('/api/v1/messages/')).toList();
      expect(patches.map((request) => request['path']), [
        '/api/v1/messages/server-agent-user',
        '/api/v1/messages/server-agent-assistant',
      ]);
      await harness.expectForegroundRecovery();
      expect(harness.server.executionRequests, hasLength(1));
      expect(harness.server.sequence.where((request) =>
          request['method'] == 'PATCH' &&
          (request['path'] as String).startsWith('/api/v1/messages/')), hasLength(2));
      harness.expectNoSuccessfulPartial();
    }, agent: true, result: _Result.partialToFinalPersistence);
  }, timeout: const Timeout(Duration(seconds: 45)));

  test('foreground Agent persisted interrupted snapshot exhausts with partial text and an error',
      () async {
    await _runForegroundCase('foreground-agent-interrupted-snapshot', (harness) async {
      await harness.sendForeground();
      harness.expectForegroundDispatch();
      expect(harness.server.executionRequests.single['path'], '/api/v1/responses');
      harness.expectNoSuccessfulPartial();
      expect(harness.server.messageReadsAfterExecution, 7);
      final reads = harness.server.sequence.where((request) =>
          request['method'] == 'GET' && request.containsKey('persistedAssistant')).toList();
      expect(reads.map((request) => request['persistedAssistant']), [
        'partial', 'partial', 'final',
        'stale-partial', 'stale-partial', 'stale-partial', 'stale-partial',
      ]);
      await harness.expectForegroundPair(success: false, failureContent: _partialAnswer);
      await harness.expectForegroundSubmissionBarrier();
      final reopened = (await harness.readConversation()).messages.last;
      expect(reopened.metadata, allOf(
        containsPair('interruptedMidStream', true),
        containsPair('serverMessageId', 'server-agent-assistant'),
        containsPair('provider', _pinnedModel.metadata!['provider']),
      ));
      expect(lobeHubAssistantResultComplete(reopened.toJson()), false);
      harness.expectNoSuccessfulPartial();
      harness.expectMappedPartialUnfinished();
      final error = reopened.error!.content!;
      for (final secret in [_streamSecret, _token, 'Authorization', 'Cookie']) {
        expect(error, isNot(contains(secret)));
      }
      await harness.container.read(chatRequestCompletionRunnerProvider).run(
        chatId: harness.topicId,
        payload: RequestCompletionPayload(
          assistantMessageId: harness.sentAssistantId,
          model: harness.admittedModel.id,
        ).toJson(),
      );
      await harness.engine.drainOutbox();
      await harness.engine.drainOutbox();
      expect(harness.server.executionRequests, hasLength(1));
      expect(harness.server.messageReadsAfterExecution, 7);
      expect(harness.server.sequence.where((request) =>
          request['method'] == 'PATCH' &&
          (request['path'] as String).startsWith('/api/v1/messages/')), hasLength(2));
      expect(harness.server.createdMessages, isEmpty);
      await harness.expectForegroundPair(success: false, failureContent: _partialAnswer);
      await harness.expectForegroundSubmissionBarrier();
    }, agent: true, result: _Result.interruptedSnapshot);
  }, timeout: const Timeout(Duration(seconds: 45)));
}

Map<String, dynamic> _firstTurn({required bool agent}) => {
  'title': _prompt,
  'models': <String>[_modelId],
  'meta': {
    'backend': 'lobehub',
    if (agent) 'agentId': _agentId,
    if (agent) 'agentModel': _modelId,
    'provider': _providerId,
    'model': _modelId,
  },
  'metadata': {
    'backend': 'lobehub',
    if (agent) 'agentId': _agentId,
    if (agent) 'agentModel': _modelId,
    'provider': _providerId,
    'model': _modelId,
  },
  'history': {
    'currentId': _assistantId,
    'messages': {
      _userId: {
        'id': _userId,
        'parentId': null,
        'childrenIds': <String>[_assistantId],
        'role': 'user',
        'content': _prompt,
        'files': <Map<String, dynamic>>[],
        'models': <String>[_modelId],
        'timestamp': _durableTimestamp,
      },
      _assistantId: {
        'id': _assistantId,
        'parentId': _userId,
        'childrenIds': <String>[],
        'role': 'assistant',
        'content': '',
        'model': _modelId,
        'modelName': 'Fixture Model',
        'timestamp': _durableTimestamp,
      },
    },
  },
};

Future<void> _runCase(
  String name,
  Future<void> Function(_Harness harness) exercise, {
  bool agent = false,
  bool foreignSelection = false,
  _Result result = _Result.success,
}) async {
  final harness = _Harness(name, agent: agent, result: result);
  try {
    await harness.open(foreignSelection: foreignSelection);
    await harness.seed();
    await exercise(harness);
    expect(harness.server.errors, isEmpty,
        reason: 'Strict HTTP server must not forgive unknown routes or contracts');
    expect(harness.server.credentialLeaks, 0);
  } finally {
    try {
      await harness.snapshot('final');
    } finally {
      await harness.close();
      debugPrint('PRODUCTION_TURN ${jsonEncode(harness.receipt)}');
    }
  }
}

Future<void> _runForegroundCase(
  String name,
  Future<void> Function(_Harness harness) exercise, {
  bool agent = false,
  _Result result = _Result.success,
}) async {
  final harness = _Harness(name,
      agent: agent, result: result, foreground: true);
  try {
    await harness.open(foreignSelection: true);
    await harness.openForegroundTopic();
    await exercise(harness);
    expect(harness.server.errors, isEmpty,
        reason: 'Unknown HTTP routes must remain errors in foreground cases');
    expect(harness.server.credentialLeaks, 0);
  } finally {
    try {
      await harness.snapshot('final');
    } finally {
      await harness.close();
      debugPrint('PRODUCTION_TURN ${jsonEncode(harness.receipt)}');
    }
  }
}

class _Harness {
  _Harness(this.name, {
    required this.agent,
    required _Result result,
    this.foreground = false,
  }) : server = _LoopbackServer(result, pinnedAgentRuntime: foreground && agent),
        db = AppDatabase(NativeDatabase.memory());

  final String name;
  final bool agent;
  final bool foreground;
  final AppDatabase db;
  final _LoopbackServer server;
  final List<Map<String, dynamic>> phases = [];
  final Map<String, bool> cleanup = {};
  final List<Box<dynamic>> boxes = [];
  Directory? temporaryDirectory;
  ProviderContainer? _container;
  ApiService? _api;
  WorkerManager? _worker;
  LobeHubApiClient? collectionClient;
  StreamSubscription<List<OutboxOp>>? outboxSubscription;
  String? _topicId;
  String? foreignSnapshot;
  ChatSendPlaceholderHandle? sendHandle;
  ProviderSubscription<List<ChatMessage>>? transcriptSubscription;
  final Set<String> observedTransports = {};
  final List<Map<String, dynamic>> foregroundUpdates = [];

  ProviderContainer get container => _container!;
  String get topicId => _topicId ?? server.topics.single['id'] as String;
  SyncEngine get engine => container.read(syncEngineProvider.notifier);
  String get sentUserId => sendHandle?.userMessageId ?? _userId;
  String get sentAssistantId => sendHandle?.assistantMessageId ?? _assistantId;
  Model get admittedModel => agent ? _pinnedModel : _targetModel;

  Map<String, dynamic> get receipt => {
    'case': name,
    'http': server.sequence,
    'topicCount': server.topics.length,
    'messageCount': server.messages.length,
    'executionCount': server.executionRequests.length,
    'messageReadsAfterExecution': server.messageReadsAfterExecution,
    'serverErrors': server.errors,
    'credentialLeaks': server.credentialLeaks,
    'finalState': phases.isEmpty ? null : phases.last,
    'milestones': [for (final phase in phases)
      if (!(phase['phase'] as String).startsWith('GET ') &&
          !(phase['phase'] as String).startsWith('POST ') &&
          !(phase['phase'] as String).startsWith('PATCH ')) {
        'phase': phase['phase'],
        'outbox': phase['outbox'],
        if (phase.containsKey('rowCount')) 'rowCount': phase['rowCount'],
      },
    ],
    'executionSnapshots': server.executionSnapshots,
    if (foreground) 'foregroundUpdates': foregroundUpdates,
    'cleanup': cleanup,
  };

  Future<void> open({required bool foreignSelection}) async {
    await server.open();
    temporaryDirectory = await Directory.systemTemp.createTemp('lobe-turn-');
    Hive.init(temporaryDirectory!.path);
    for (final name in ['preferences', 'caches', 'attachments', 'metadata']) {
      boxes.add(await Hive.openBox<dynamic>(name));
    }
    final hiveBoxes = HiveBoxes(
      preferences: boxes[0], caches: boxes[1],
      attachmentQueue: boxes[2], metadata: boxes[3],
    );
    final config = ServerConfig(
      id: 'lobehub_self_hosted', name: 'Loopback only', url: server.url,
    );
    PreferencesStore.debugOverride(InMemoryKeyValueStore({
      PreferenceKeys.activeServerId: config.id,
    }));
    _container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      hiveBoxesProvider.overrideWithValue(hiveBoxes),
      secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
      authStateManagerProvider.overrideWith(_BootAuth.new),
      activeServerProvider.overrideWith((ref) async => config),
      modelsProvider.overrideWith(() => _BootModels([
        _targetModel,
        if (foreground) _collidingModel,
        if (foreground && agent) _pinnedModel,
        _foreignModel,
      ])),
      syncClockProvider.overrideWith((ref) => _FixedClock(server.epoch + 3600)),
      socketServiceProvider.overrideWithValue(null),
      optimizedStorageServiceProvider.overrideWith((ref) => OptimizedStorageService(
        secureStorage: InMemorySecureKeyValueStore(),
        boxes: hiveBoxes,
        workerManager: ref.read(workerManagerProvider),
        database: () => db,
      )),
      apiServiceProvider.overrideWith((ref) {
        final api = ApiService(
          serverConfig: config,
          workerManager: ref.read(workerManagerProvider),
          authToken: _token,
        );
        ref.onDispose(api.dispose);
        return _api = api;
      }),
      requestCompletionRunnerProvider.overrideWith(
        (ref) => ref.read(chatRequestCompletionRunnerProvider),
      ),
    ]);
    await container.read(authStateManagerProvider.future);
    await container.read(activeServerProvider.future);
    await container.read(modelsProvider.future);
    container.read(openWebUiCertifiedDatabaseServerProvider.notifier).set(config.id);
    container.read(openWebUiDatabaseAccessProvider.notifier).open();
    container.read(selectedModelProvider.notifier).set(
      foreignSelection ? _foreignModel : _targetModel,
    );
    container.read(activeConversationProvider.notifier).set(Conversation(
      id: _foreignChatId,
      title: 'Foreign active chat',
      createdAt: DateTime.utc(2026, 10, 4),
      updatedAt: DateTime.utc(2026, 10, 4),
      model: _foreignModelId,
      metadata: const {'backend': 'lobehub', 'provider': 'openai'},
      messages: [ChatMessage(
        id: 'foreign-user', role: 'user', content: 'Foreign transcript stays intact',
        timestamp: DateTime.utc(2026, 10, 4),
      )],
    ));
    foreignSnapshot = jsonEncode(container.read(chatMessagesProvider)
        .map((message) => message.toJson()).toList());
    collectionClient = LobeHubApiClient(baseUrl: server.url, apiKey: _token);
    final agents = await collectionClient!.getAgents();
    expect(agents.single.id, _agentId);
    expect(agents.single.model, _modelId);
    expect(agents.single.provider, _providerId);
    final configuredAgent = await collectionClient!.getAgent(_agentId);
    expect(configuredAgent.model, _targetModel.id);
    expect(configuredAgent.provider, _targetModel.metadata!['provider']);
    expect(await collectionClient!.getTopics(), isEmpty);
    expect(container.read(apiServiceProvider), isA<ApiService>());
    _worker = container.read(workerManagerProvider);
    expect(container.read(chatRequestCompletionRunnerProvider),
        isA<ChatRequestCompletionRunner>());
    server.beforeRequest = (label) => snapshot(label);
    outboxSubscription = db.select(db.outboxOps).watch().listen((ops) {
      phases.add({'phase': 'outbox-emission', 'outbox': _ops(ops)});
    });
    if (foreground) {
      transcriptSubscription = container.listen(chatMessagesProvider, (_, next) {
        for (final message in next) {
          final transport = message.metadata?['transport'];
          if (transport is String) observedTransports.add(transport);
        }
        foregroundUpdates.add({
          'activeChatId': container.read(activeConversationProvider)?.id,
          'messages': _transcript(next),
        });
      });
    }
  }

  Future<void> openForegroundTopic() async {
    final topic = await collectionClient!.createTopic(
      title: _prompt,
      agentId: agent ? _agentId : null,
      metadata: {
        'backend': 'lobehub', 'model': _modelId,
        'provider': agent ? _providerId : 'openai',
      },
    );
    _topicId = topic.id;
    final conversation = await engine.pullChatNow(topicId);
    expect(conversation, isNotNull);
    expect(conversation!.metadata['backend'], 'lobehub');
    expect(conversation.model, admittedModel.id);
    expect(conversation.metadata['provider'],
        agent ? admittedModel.metadata!['provider'] : 'openai');
    if (agent) {
      expect(conversation.metadata['agentId'], _agentId);
      expect(conversation.metadata['agentModel'], _pinnedModel.id);
    }
    expect(conversation.messages, isEmpty);
    expect(await db.messagesDao.getForChat(topicId), isEmpty);
    expect(await db.select(db.outboxOps).get(), isEmpty);
    container.read(selectedModelProvider.notifier).set(admittedModel);
    container.read(activeConversationProvider.notifier).set(conversation);
    container.read(chatMessagesProvider.notifier).setMessages(conversation.messages);
    expect(container.read(chatMessagesProvider), isEmpty);
    await snapshot('foreground-topic-loaded-from-real-http-and-db');
  }

  Future<void> sendForeground({bool waitForSettlement = true}) async {
    await durableSend(
      container,
      _prompt,
      null,
      onAssistantPlaceholderCreated: (handle) {
        sendHandle = handle;
        final visible = container.read(chatMessagesProvider);
        expect(visible.map((message) => message.id),
            [handle.userMessageId, handle.assistantMessageId]);
        expect(visible.first.content, _prompt);
        expect(visible.last.isStreaming, true);
        expect(visible.last.metadata, allOf(
          containsPair('backend', 'lobehub'),
          containsPair('model', admittedModel.id),
          containsPair('provider', admittedModel.metadata!['provider']),
        ));
        container.read(selectedModelProvider.notifier).set(_collidingModel);
        (container.read(modelsProvider.notifier) as _BootModels)
            .replace([_collidingModel, admittedModel, _foreignModel]);
        container.read(lobeAgentsProvider.notifier)
            .selectAgent('foreign-global-agent');
      },
    ).timeout(const Duration(seconds: 30));
    expect(sendHandle, isNotNull);
    if (waitForSettlement) await waitForForegroundSettlement();
    await snapshot('after-actual-durable-send-and-foreground-settlement');
  }

  Future<void> waitForForegroundSettlement() async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < const Duration(seconds: 15)) {
      expect(server.errors, isEmpty,
          reason: 'Strict foreground HTTP contracts must not be forgiven');
      final visible = container.read(chatMessagesProvider);
      final row = await db.messagesDao.getMessage(topicId, sentAssistantId);
      final ops = await db.select(db.outboxOps).get();
      final persisted = row == null ? null : (await readConversation()).messages
          .where((message) => message.id == sentAssistantId).firstOrNull;
      if (visible.length == 2 && !visible.last.isStreaming && row != null &&
          persisted != null && !persisted.isStreaming &&
          persisted.content == visible.last.content &&
          persisted.error?.content == visible.last.error?.content &&
          ops.every((op) => op.status != OutboxStatus.inFlight)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('Foreground transcript/DB did not settle within fifteen seconds: '
        '${jsonEncode(await snapshot('foreground-settlement-timeout'))}');
  }

  void expectForegroundDispatch() {
    expect(server.executionRequests, hasLength(1));
    final snapshot = server.executionSnapshots.single;
    expect(snapshot['activeChatId'], topicId);
    expect(snapshot['isChatStreaming'], true);
    expect(snapshot['localGenerationActive'], true);
    expect(snapshot['serverMessageCount'], 0);
    final visible = snapshot['activeMessages'] as List;
    expect(visible.map((message) => message['id']), [sentUserId, sentAssistantId]);
    expect(visible.last['isStreaming'], true);
    final placeholder = snapshot['placeholder'] as Map;
    expect(placeholder['id'], sentAssistantId);
    expect(placeholder['parentId'], sentUserId);
    expect(placeholder['role'], 'assistant');
    expect(placeholder['content'], isEmpty);
    expect(placeholder['model'], admittedModel.id);
    if (!agent) {
      expect(placeholder.containsKey('done'), false);
      expect(placeholder.containsKey('isStreaming'), false);
    }
    expect(placeholder['metadata'], allOf(
      containsPair('backend', 'lobehub'),
      containsPair('model', admittedModel.id),
      containsPair('provider', admittedModel.metadata!['provider']),
    ));
    expect(snapshot['selectedModel'],
        {'id': _modelId, 'provider': 'openai'});
    expect(snapshot['outbox'], [allOf(
      containsPair('kind', 'requestCompletion'),
      containsPair('status', OutboxStatus.inFlight),
    )]);
    expect(snapshot['completionPayloads'], [{
      'assistantMessageId': sentAssistantId,
      'model': admittedModel.id,
      'toolIds': <String>[],
      'filterIds': <String>[],
      'enableWebSearch': false,
      'enableImageGeneration': false,
      'isVoiceMode': false,
    }]);
  }

  Future<void> expectForegroundPair({
    bool success = true,
    String failureContent = '',
  }) async {
    expect(server.topics, hasLength(1));
    expect(server.executionRequests, hasLength(1));
    expect(container.read(activeConversationProvider)?.id, topicId);
    final rows = await db.messagesDao.getForChat(topicId);
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.id).toSet(), {sentUserId, sentAssistantId});
    expect(rows.singleWhere((row) => row.id == sentUserId).content, _prompt);
    final assistant = rows.singleWhere((row) => row.id == sentAssistantId);
    expect(assistant.parentId, sentUserId);
    final visible = container.read(chatMessagesProvider);
    expect(visible.map((message) => message.id), [sentUserId, sentAssistantId]);
    expect(visible.map((message) => message.role), ['user', 'assistant']);
    expect(visible.first.content, _prompt);
    expect(visible.every((message) => !message.isStreaming), true);
    final expectedContent = success ? _answer
        : failureContent.isEmpty ? isEmpty : failureContent;
    expect(visible.last.content, expectedContent);
    expect(visible.last.error?.content, success ? isNull : isNotEmpty);
    expect(assistant.content, expectedContent);
    expect(container.read(isChatStreamingProvider), false);
    expect(container.read(localChatGenerationActiveProvider), false);
    if (success) {
      expect(server.messages, hasLength(2));
      expect(await db.select(db.outboxOps).get(), isEmpty);
      final serverUser = server.messages.singleWhere(
        (message) => message['role'] == 'user',
      );
      final serverAssistant = server.messages.singleWhere(
        (message) => message['role'] == 'assistant',
      );
      expect((serverUser['metadata'] as Map)['conduitClientId'], sentUserId);
      expect((serverAssistant['metadata'] as Map)['conduitClientId'], sentAssistantId);
      expect(serverAssistant['parentId'], serverUser['id']);
    }
    final reopened = (await readConversation()).messages;
    expect(reopened.map((message) => message.id), [sentUserId, sentAssistantId]);
    expect(reopened.first.content, _prompt);
    expect(reopened.last.content, expectedContent);
    expect(reopened.last.isStreaming, false);
    expect(reopened.last.error?.content, success ? isNull : isNotEmpty);
  }

  Future<void> expectForegroundSubmissionBarrier() async {
    final placeholder = server.executionSnapshots.single['placeholder'] as Map;
    final expectedMetadata = placeholder['metadata'] as Map;
    expect(expectedMetadata['completionSubmitted'], true);
    final correlation = expectedMetadata['lobeAgentCorrelation'] as Map;
    expect(correlation, allOf(
      containsPair('topicId', topicId),
      containsPair('agentId', _agentId),
      containsPair('userLocalId', sentUserId),
      containsPair('assistantLocalId', sentAssistantId),
      containsPair('snapshotServerIds', isEmpty),
    ));
    final row = await db.messagesDao.getMessage(topicId, sentAssistantId);
    final payload = jsonDecode(row!.payload) as Map;
    for (final metadata in [
      container.read(chatMessagesProvider).last.metadata,
      payload['metadata'],
      (await readConversation()).messages.last.metadata,
    ]) {
      expect(metadata, allOf(
        containsPair('completionSubmitted', true),
        containsPair('lobeAgentCorrelation', correlation),
      ));
    }
  }

  void expectNoSuccessfulPartial() {
    for (final update in foregroundUpdates) {
      for (final message in update['messages'] as List) {
        if (message['role'] == 'assistant' && message['content'] == _partialAnswer) {
          expect(message['isStreaming'] == false && message['error'] == null,
              false, reason: 'Persisted partial text must never become successful completion');
          expect(message['responseDone'] == true && message['error'] == null,
              false, reason: 'An unfinished result must not gain an error-free done marker');
        }
      }
    }
  }

  void expectMappedPartialUnfinished() {
    final snapshots = phases.map((phase) => phase['placeholder']).whereType<Map>()
        .where((payload) => payload['content'] == _partialAnswer &&
            payload['error'] == null &&
            (payload['metadata'] as Map?)?['serverMessageId'] == 'server-agent-assistant');
    expect(snapshots, isNotEmpty,
        reason: 'Recovery must actually pull an unfinished mapped assistant before settlement');
    for (final payload in snapshots) {
      expect(payload['isStreaming'], true);
      expect(payload['done'], false);
      expect(payload['metadata'], allOf(
        containsPair('responseDone', false),
        containsPair('interruptedMidStream', true),
        containsPair('completionSubmitted', true),
        containsPair('provider', _pinnedModel.metadata!['provider']),
      ));
    }
  }

  Future<void> expectForegroundRecovery({
    bool success = true,
    String failureContent = '',
  }) async {
    await container.read(chatRequestCompletionRunnerProvider).run(
      chatId: topicId,
      payload: RequestCompletionPayload(
        assistantMessageId: sentAssistantId, model: admittedModel.id,
      ).toJson(),
    );
    expect(await engine.pullChatNow(topicId), isNotNull);
    await engine.drainOutbox().timeout(const Duration(seconds: 10));
    await engine.drainOutbox().timeout(const Duration(seconds: 10));
    await waitForForegroundSettlement();
    await expectForegroundPair(success: success, failureContent: failureContent);
    if (agent) await expectForegroundSubmissionBarrier();
    await snapshot('after-foreground-runner-reentry-pull-and-drain');
  }

  Future<void> seed() async {
    final blob = _firstTurn(agent: agent);
    final rows = ChatBlobMapper.blobToRows(
      chatId: _localChatId, blob: blob, title: _prompt,
      createdAt: _durableTimestamp, updatedAt: _durableTimestamp,
    );
    await db.chatsDao.insertLocalChatWithCreateOp(
      chat: rows.chat, messages: rows.messages, blobRows: rows,
      contentHash: createChatContentHash(rows),
      completion: const RequestCompletionPayload(
        assistantMessageId: _assistantId, model: _modelId,
      ),
    );
    final chat = await db.chatsDao.getChat(_localChatId);
    final storedRows = await db.messagesDao.getForChat(_localChatId);
    expect(ChatBlobMapper.rowsToBlob(chatRowsFromDb(chat!, storedRows)), blob);
    expect(storedRows.map((row) => row.id), [_userId, _assistantId]);
    final placeholder = jsonDecode(storedRows.last.payload) as Map;
    expect(placeholder.containsKey('done'), false);
    expect(placeholder.containsKey('isStreaming'), false);
    expect(storedRows.last.parentId, _userId);
    final ops = await db.select(db.outboxOps).get();
    expect(ops.map((op) => op.kind), ['createChat', 'requestCompletion']);
    expect(ops.every((op) => op.status == OutboxStatus.pending), true);
    await snapshot('seeded-exact-durable-blob');
  }

  Future<void> drain() async {
    await engine.drainOutbox().timeout(const Duration(seconds: 35));
    _topicId = server.topics.single['id'] as String;
    await snapshot('after-real-engine-drain');
    expect(container.read(activeConversationProvider)?.id, _foreignChatId);
    expect(jsonEncode(container.read(chatMessagesProvider)
        .map((message) => message.toJson()).toList()), foreignSnapshot);
  }

  Future<Map<String, dynamic>> snapshot(String label) async {
    final chatId = _topicId ?? (server.topics.isEmpty
        ? _localChatId : server.topics.single['id'] as String);
    final rows = await db.messagesDao.getForChat(chatId);
    final placeholder = rows.where((row) => row.id == sentAssistantId).firstOrNull;
    final outbox = await db.select(db.outboxOps).get();
    final phase = <String, dynamic>{
      'phase': label,
      'chatId': chatId,
      'outbox': _ops(outbox),
      if (foreground) 'completionPayloads': [
        for (final op in outbox)
          if (op.kind == 'requestCompletion') jsonDecode(op.payload),
      ],
      'rowCount': rows.length,
      'rows': [for (final row in rows) {
        'id': row.id, 'parentId': row.parentId, 'role': row.role,
        'content': row.content, 'dirty': row.dirty,
      }],
      'placeholder': placeholder == null ? null : jsonDecode(placeholder.payload),
      'serverMessageCount': server.messages.length,
      'activeChatId': container.read(activeConversationProvider)?.id,
      'activeMessages': _transcript(container.read(chatMessagesProvider)),
      'isChatStreaming': container.read(isChatStreamingProvider),
      'localGenerationActive': container.read(localChatGenerationActiveProvider),
      'selectedModel': {
        'id': container.read(selectedModelProvider)?.id,
        'provider': resolveModelProvider(container.read(selectedModelProvider)),
      },
    };
    final chat = await db.chatsDao.getChat(chatId);
    if (chat != null) {
      phase['currentMessageId'] = chat.currentMessageId;
      phase['blobMeta'] = jsonDecode(chat.blobMeta);
      final visible = await assembleConversationGuarded(chat, rows, offload: null);
      phase['visibleMessages'] = [for (final message in visible.messages) {
        'id': message.id, 'role': message.role, 'content': message.content,
        'isStreaming': message.isStreaming, 'error': message.error?.content,
      }];
      phase['visibleMetadata'] = visible.metadata;
    }
    phases.add(phase);
    return phase;
  }

  Future<Conversation> readConversation() async {
    final chat = await db.chatsDao.getChat(topicId);
    expect(chat, isNotNull);
    return assembleConversationGuarded(chat!,
        await db.messagesDao.getForChat(topicId), offload: null);
  }

  Future<void> expectSuccessfulPair() async {
    expect(server.topics, hasLength(1));
    expect(server.messages, hasLength(2));
    expect(server.executionRequests, hasLength(1));
    expect(await db.chatsDao.getChat(_localChatId), isNull);
    expect(await db.syncMetaDao.getChatRemapTarget(_localChatId), topicId);
    expect(await db.select(db.outboxOps).get(), isEmpty);
    final rows = await db.messagesDao.getForChat(topicId);
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.id).toSet(), {_userId, _assistantId});
    expect(rows.singleWhere((row) => row.id == _userId).content, _prompt);
    final assistant = rows.singleWhere((row) => row.id == _assistantId);
    expect(assistant.role, 'assistant');
    expect(assistant.content, _answer);
    expect(assistant.parentId, _userId);
    final visible = (await readConversation()).messages
        .singleWhere((message) => message.id == _assistantId);
    expect(visible.content, _answer);
    expect(visible.isStreaming, false);
    expect(visible.error, isNull);
    expect(container.read(localChatGenerationActiveProvider), false);
    expect(server.messages.every((message) =>
        (message['content'] as String).isNotEmpty), true);
  }

  Future<void> expectVisibleFailure() async {
    final rows = await db.messagesDao.getForChat(topicId);
    expect(rows, hasLength(2));
    final assistant = rows.singleWhere((row) => row.id == _assistantId);
    expect(assistant.parentId, _userId);
    expect(assistant.content, isEmpty);
    final payload = jsonDecode(assistant.payload) as Map;
    expect(payload['isStreaming'], false);
    expect(payload['error'], isNotNull);
    final visible = (await readConversation()).messages
        .singleWhere((message) => message.id == _assistantId);
    expect(visible.content, isEmpty);
    expect(visible.isStreaming, false);
    expect(visible.error?.content, isNotEmpty);
    expect(container.read(isChatStreamingProvider), false);
    expect(container.read(localChatGenerationActiveProvider), false);
  }

  Future<void> expectRecoveryDoesNotExecuteAgain({bool success = true}) async {
    final before = server.executionRequests.length;
    await container.read(chatRequestCompletionRunnerProvider).run(
      chatId: topicId,
      payload: const RequestCompletionPayload(
        assistantMessageId: _assistantId, model: _modelId,
      ).toJson(),
    );
    final pulled = await engine.pullChatNow(topicId);
    expect(pulled, isNotNull);
    await drain();
    expect(server.executionRequests.length, before);
    if (success) {
      await expectSuccessfulPair();
    } else {
      await expectVisibleFailure();
    }
    await snapshot('after-pull-and-runner-reentry');
  }

  Future<void> close() async {
    transcriptSubscription?.close();
    if (foreground) cleanup['foregroundTranscriptSubscriptionClosed'] = true;
    await outboxSubscription?.cancel();
    cleanup['outboxSubscriptionCancelled'] = true;
    _container?.dispose();
    await Future<void>.delayed(Duration.zero);
    cleanup['providersDisposed'] = true;
    _api?.dio.close(force: true);
    cleanup['apiDioClosed'] = true;
    if (_worker != null) {
      await expectLater(_worker!.schedule((int value) => value, 1),
          throwsStateError);
    }
    cleanup['providerOwnedWorkerDisposed'] = true;
    collectionClient?.close(force: true);
    cleanup['collectionDioClosed'] = true;
    await server.close();
    cleanup['httpServerAndSubscriptionClosed'] = true;
    await db.close();
    cleanup['memoryDatabaseClosed'] = true;
    for (final box in boxes.reversed) {
      await box.close();
    }
    await Hive.close();
    cleanup['hiveBoxesClosed'] = boxes.every((box) => !box.isOpen);
    if (temporaryDirectory != null) {
      await temporaryDirectory!.delete(recursive: true);
      cleanup['temporaryDirectoryDeleted'] =
          !await temporaryDirectory!.exists();
    }
    PreferencesStore.debugReset();
    cleanup['preferencesReset'] = true;
    cleanup['testStreamControllersCreated'] = false;
  }
}

List<Map<String, dynamic>> _ops(List<OutboxOp> ops) => [
  for (final op in ops) {
    'kind': op.kind, 'chatId': op.chatId, 'status': op.status,
    'attempts': op.attempts, 'nextAttemptAt': op.nextAttemptAt,
    'lastError': op.lastError,
  },
];

List<Map<String, dynamic>> _transcript(List<ChatMessage> messages) => [
  for (final message in messages) {
    'id': message.id,
    'role': message.role,
    'content': message.content,
    'isStreaming': message.isStreaming,
    'error': message.error?.content,
    'transport': message.metadata?['transport'],
    'responseDone': message.metadata?['responseDone'],
  },
];

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _BootAuth extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated, token: _token,
    user: User(id: 'fixture-account', username: 'fixture',
        email: 'fixture@example.invalid', role: 'user'),
  );
}

class _BootModels extends Models {
  _BootModels(this.roster);
  final List<Model> roster;
  @override
  Future<List<Model>> build() async => roster;
  void replace(List<Model> models) => state = AsyncData(models);
}

class _FixedClock implements SyncClock {
  const _FixedClock(this.now);
  final int now;
  @override
  int nowEpochSeconds() => now;
}

class _LoopbackServer {
  _LoopbackServer(this.result, {this.pinnedAgentRuntime = false});

  final _Result result;
  final bool pinnedAgentRuntime;
  final int epoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final List<Map<String, dynamic>> topics = [];
  final List<Map<String, dynamic>> messages = [];
  final List<Map<String, dynamic>> createdMessages = [];
  final List<Map<String, dynamic>> sequence = [];
  final List<Map<String, dynamic>> executionRequests = [];
  final List<Map<String, dynamic>> executionSnapshots = [];
  final List<String> errors = [];
  final Set<Future<void>> _requests = {};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Future<Map<String, dynamic>> Function(String label)? beforeRequest;
  int credentialLeaks = 0;
  int messageReadsAfterExecution = 0;
  bool _agentTurnSubmitted = false;
  Map<String, dynamic>? _partialAssistantSnapshot;
  Completer<void>? recoveryReadEntered;
  Completer<void>? releaseRecoveryRead;

  String get url => 'http://127.0.0.1:${_server!.port}';
  Map<String, dynamic> get agent => {
    'id': _agentId, 'title': 'Research Agent',
    'model': _modelId, 'provider': _providerId,
    'createdAt': epoch, 'updatedAt': epoch,
  };

  Future<void> open() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _subscription = _server!.listen((request) {
      late final Future<void> task;
      task = _handle(request).whenComplete(() => _requests.remove(task));
      _requests.add(task);
    });
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    final event = <String, dynamic>{
      'sequence': sequence.length + 1, 'method': method, 'path': path,
      'query': request.uri.queryParameters,
    };
    sequence.add(event);
    try {
      final authorization = request.headers.value('authorization');
      final apiKey = request.headers.value('x-api-key');
      event['headers'] = {
        'authorization': authorization,
        'x-api-key': apiKey,
        'content-type': request.headers.value('content-type'),
      };
      if ((authorization != null && authorization != 'Bearer $_token') ||
          (apiKey != null && apiKey != _token) ||
          request.headers.value('cookie') != null) {
        credentialLeaks++;
        throw StateError('Non-synthetic credentials reached loopback');
      }
      final text = await utf8.decoder.bind(request).join();
      final body = text.isEmpty ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
      if (body.isNotEmpty) event['body'] = body;
      final snapshot = await beforeRequest?.call('$method $path');
      if (method == 'GET' && path == '/health') {
        await _json(request, event, {'status': true});
      } else if (method == 'GET' && path == '/api/v1/agents') {
        await _json(request, event, {
          'success': true, 'data': {'agents': [agent], 'total': 1},
        });
      } else if (method == 'GET' && path == '/api/v1/agents/$_agentId') {
        await _json(request, event, {'success': true, 'data': agent});
      } else if (method == 'GET' && path == '/api/v1/topics') {
        await _json(request, event, {
          'success': true, 'data': {'topics': topics, 'total': topics.length},
        });
      } else if (method == 'POST' && path == '/api/v1/topics') {
        _require(body['title'] is String && (body['title'] as String).isNotEmpty,
            'Topic title must be nonempty');
        _require(body['agentId'] == null || body['agentId'] == _agentId,
            'Topic bound to an unexpected Agent');
        final topic = <String, dynamic>{
          'id': 'server-topic-${topics.length + 1}', 'title': body['title'],
          'agentId': body['agentId'], 'createdAt': epoch, 'updatedAt': epoch + 1,
          'metadata': body['metadata'] ?? <String, dynamic>{},
          if (pinnedAgentRuntime) 'model': _pinnedModel.id,
          if (pinnedAgentRuntime) 'provider': _pinnedModel.metadata!['provider'],
        };
        topics.add(topic);
        await _json(request, event, {'success': true, 'data': topic});
      } else if (method == 'GET' && path.startsWith('/api/v1/topics/')) {
        final topic = _topic(path.substring('/api/v1/topics/'.length));
        await _json(request, event, {'success': true, 'data': topic});
      } else if (method == 'PATCH' && path.startsWith('/api/v1/topics/')) {
        final topic = _topic(path.substring('/api/v1/topics/'.length));
        topic.addAll(body);
        topic['updatedAt'] = epoch + sequence.length;
        await _json(request, event, {'success': true, 'data': topic});
      } else if (method == 'GET' && path == '/api/v1/messages') {
        final topicId = request.uri.queryParameters['topicId'];
        _topic(topicId);
        if (_agentTurnSubmitted) {
          messageReadsAfterExecution++;
          if (messageReadsAfterExecution == 2 && recoveryReadEntered != null) {
            recoveryReadEntered!.complete();
            await releaseRecoveryRead!.future;
          }
          if (result == _Result.delayedPersistence &&
              messageReadsAfterExecution == 5) {
            _persistAgentPair(topicId!);
          }
          if ((result == _Result.partialToFinalPersistence ||
                  result == _Result.interruptedSnapshot) &&
              messageReadsAfterExecution == 3) {
            final assistant = messages.singleWhere((message) => message['role'] == 'assistant');
            assistant['content'] = _answer;
            assistant['updatedAt'] = epoch + sequence.length;
            assistant['metadata'] = {
              ...assistant['metadata'] as Map,
              'interruptedMidStream': false,
              'finishType': 'stop',
            };
          }
        }
        var matching = messages.where((message) =>
            message['topicId'] == topicId).toList();
        if (_partialAssistantSnapshot != null) {
          final assistant = matching.singleWhere((message) => message['role'] == 'assistant');
          final staleSnapshot =
              result == _Result.partialToFinalPersistence && messageReadsAfterExecution == 4 ||
              result == _Result.interruptedSnapshot && messageReadsAfterExecution >= 4;
          if (staleSnapshot) {
            matching = [
              for (final message in matching)
                if (message['role'] != 'assistant') message else {
                  ..._partialAssistantSnapshot!,
                  'metadata': {
                    ...assistant['metadata'] as Map,
                    ..._partialAssistantSnapshot!['metadata'] as Map,
                  },
                },
            ];
          }
          event['persistedAssistant'] = staleSnapshot ? 'stale-partial'
              : assistant['content'] == _answer ? 'final' : 'partial';
          event['assistantServerId'] = assistant['id'];
        }
        await _json(request, event, {
          'success': true, 'data': {'messages': matching, 'total': matching.length},
        });
      } else if (method == 'POST' && path == '/api/v1/messages') {
        _topic(body['topicId']?.toString());
        if (body['content'] is! String || (body['content'] as String).isEmpty) {
          await _json(request, event, {
            'success': false, 'error': {
              'message': 'content: String must contain at least 1 character(s)',
              'schema': 'z.string().min(1)',
            },
          }, status: 400);
          return;
        }
        final stored = <String, dynamic>{
          ...body, 'id': 'server-message-${messages.length + 1}',
          'createdAt': epoch + messages.length + 1,
          'updatedAt': epoch + messages.length + 1,
        };
        messages.add(stored);
        createdMessages.add(stored);
        _topic(body['topicId']?.toString())['updatedAt'] = epoch + sequence.length;
        await _json(request, event, {'success': true, 'data': stored});
      } else if (method == 'PATCH' && path.startsWith('/api/v1/messages/')) {
        final id = path.substring('/api/v1/messages/'.length);
        final stored = messages.singleWhere((message) => message['id'] == id);
        stored.addAll(body);
        stored['updatedAt'] = epoch + sequence.length;
        await _json(request, event, {'success': true, 'data': stored});
      } else if (method == 'POST' && path == '/api/v1/chat') {
        executionRequests.add(event);
        if (snapshot != null) executionSnapshots.add(snapshot);
        _require(body['model'] == _modelId, 'Raw request chose the wrong model');
        _require(body['provider'] == _providerId, 'Raw request chose the wrong provider');
        _require(body['stream'] == false, 'Raw route must request non-stream JSON');
        _require((body['messages'] as List).any((message) =>
            message['role'] == 'user' && message['content'] == _prompt),
            'Raw route lost the durable user prompt');
        if (result == _Result.rejected) {
          await _json(request, event, {
            'success': false, 'error': {'message': 'Synthetic generation rejected'},
          }, status: 400);
        } else {
          await _json(request, event, {
            'success': true, 'data': {
              'content': _answer, 'model': _modelId, 'provider': _providerId,
              'usage': {'total_tokens': 12},
            },
          });
        }
      } else if (method == 'POST' && path == '/api/v1/responses') {
        executionRequests.add(event);
        if (snapshot != null) executionSnapshots.add(snapshot);
        final topicId = body['previous_response_id']?.toString();
        final topic = _topic(topicId);
        _require(topic['agentId'] == _agentId, 'Responses topic lost its Agent binding');
        _require(body['model'] == topic['agentId'], 'Responses dispatched a model instead of the bound Agent');
        _require(body['input'] == _prompt, 'Responses lost the durable prompt');
        _require(body['stream'] == true, 'Responses must stream');
        _agentTurnSubmitted = true;
        if (result == _Result.success) _persistAgentPair(topicId!);
        final persistedPartial = result == _Result.interruptedPersistence ||
            result == _Result.incompletePersistence ||
            result == _Result.partialToFinalPersistence ||
            result == _Result.interruptedSnapshot;
        if (persistedPartial) {
          _persistAgentPair(topicId!, interrupted: true);
        }
        event['status'] = 200;
        request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        _sse(request, event, 'response.created', {
          'type': 'response.created', 'response': {
            'id': 'response-fixture', 'status': 'in_progress', 'output': <Object>[],
          },
        });
        if (result == _Result.failedStream || result == _Result.incompleteStream ||
            persistedPartial) {
          final incomplete = result == _Result.incompleteStream ||
              result == _Result.incompletePersistence ||
              result == _Result.partialToFinalPersistence;
          if (incomplete || persistedPartial) {
            _sse(request, event, 'response.output_text.delta', {
              'type': 'response.output_text.delta', 'delta': _partialAnswer,
              'item_id': 'response-output', 'output_index': 0, 'content_index': 0,
            });
          }
          final eventType = incomplete ? 'response.incomplete' : 'response.failed';
          _sse(request, event, eventType, {
            'type': eventType, 'response': {
              'id': 'response-fixture', 'status': incomplete ? 'incomplete' : 'failed',
              if (incomplete) 'incomplete_details': {
                'reason': 'Synthetic limit; Authorization: Bearer $_streamSecret; Cookie: $_token',
              } else 'error': {
                'message': 'Synthetic Agent generation failed; Authorization: Bearer $_streamSecret; Cookie: $_token',
              },
            },
          });
        } else {
          _sse(request, event, 'response.output_text.delta', {
            'type': 'response.output_text.delta', 'delta': _answer,
            'item_id': 'response-output', 'output_index': 0, 'content_index': 0,
          });
          _sse(request, event, 'response.completed', {
            'type': 'response.completed', 'response': {
              'id': 'response-fixture', 'status': 'completed',
              'output': [{
                'id': 'response-output', 'type': 'message', 'role': 'assistant',
                'status': 'completed',
                'content': [{'type': 'output_text', 'text': _answer}],
              }],
              'usage': {'total_tokens': 12},
            },
          });
        }
        await request.response.close();
      } else {
        throw StateError('Unexpected loopback route: $method ${request.uri}');
      }
    } catch (error) {
      errors.add('$method $path: $error');
      await _json(request, event, {
        'success': false, 'error': {'message': error.toString()},
      }, status: 500);
    }
  }

  Map<String, dynamic> _topic(String? id) {
    _require(id != null && topics.any((topic) => topic['id'] == id),
        'Unknown topic $id');
    return topics.singleWhere((topic) => topic['id'] == id);
  }

  void _persistAgentPair(String topicId, {bool interrupted = false}) {
    _require(messages.isEmpty, 'Agent generation attempted to duplicate its pair');
    messages.addAll([
      {
        'id': 'server-agent-user', 'role': 'user', 'content': _prompt,
        'topicId': topicId, 'agentId': _agentId, 'parentId': null,
        'childrenIds': ['server-agent-assistant'],
        'metadata': {'serverOwned': true}, 'createdAt': epoch + 2,
      },
      {
        'id': 'server-agent-assistant', 'role': 'assistant',
        'content': interrupted ? _partialAnswer : _answer,
        'topicId': topicId, 'agentId': _agentId,
        'model': _topic(topicId)['model'] ?? _modelId,
        'provider': _topic(topicId)['provider'] ?? _providerId,
        'parentId': 'server-agent-user', 'childrenIds': <String>[],
        'metadata': {
          'serverOwned': true,
          if (interrupted) 'interruptedMidStream': true,
        },
        'createdAt': epoch + 3,
      },
    ]);
    if (interrupted) {
      _partialAssistantSnapshot = jsonDecode(jsonEncode(messages.last)) as Map<String, dynamic>;
    }
    _topic(topicId)['updatedAt'] = epoch + sequence.length + 1;
  }

  void _require(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  void _sse(HttpRequest request, Map<String, dynamic> capture,
      String event, Map<String, dynamic> data) {
    final frame = 'event: $event\ndata: ${jsonEncode(data)}\n\n';
    final frames = capture.putIfAbsent('sseFrames', () => <String>[])
        as List<String>;
    frames.add(frame);
    request.response.write(frame);
  }

  Future<void> _json(HttpRequest request, Map<String, dynamic> event,
      Map<String, dynamic> data, {int status = 200}) async {
    event['status'] = status;
    final responseText = jsonEncode(data);
    event['response'] = jsonDecode(responseText);
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(responseText);
    await request.response.close();
  }

  Future<void> close() async {
    final release = releaseRecoveryRead;
    if (release != null && !release.isCompleted) release.complete();
    await _server?.close(force: true);
    await _subscription?.cancel();
    await Future.wait(_requests.toList());
  }
}

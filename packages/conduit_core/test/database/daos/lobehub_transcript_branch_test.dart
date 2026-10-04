import 'dart:convert';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() async {
    await db.close();
    print('cleanup: NativeDatabase.memory closed; no server or files created');
  });

  ChatRows emptyTopic({int stamp = 1, bool rawBackend = false}) =>
      ChatBlobMapper.blobToRows(
        chatId: 'topic',
        title: 'Topic',
        createdAt: 1,
        updatedAt: stamp,
        blob: {
          if (rawBackend) 'metadata': {'backend': 'lobehub'},
          'history': {'messages': <String, dynamic>{}},
        },
      );

  List<MessageRowData> pair({
    String answer = '',
    Map<String, dynamic> metadata = const {},
  }) => ChatBlobMapper.blobToRows(
    chatId: 'topic',
    title: 'Topic',
    createdAt: 1,
    updatedAt: 2,
    blob: {
      'history': {
        'currentId': 'A',
        'messages': {
          'U': {
            'id': 'U', 'role': 'user', 'content': 'Prompt',
            'parentId': null, 'childrenIds': ['A'], 'timestamp': 2,
          },
          'A': {
            'id': 'A', 'role': 'assistant', 'content': answer,
            'parentId': 'U', 'childrenIds': <String>[], 'timestamp': 2,
            'isStreaming': false,
            'metadata': metadata,
          },
        },
      },
    },
  ).messages;

  Future<void> append({
    String answer = '',
    Map<String, dynamic> metadata = const {},
    bool queued = false,
  }) => db.chatsDao.appendMessagesWithUpdateOp(
    chatId: 'topic',
    messages: pair(answer: answer, metadata: metadata),
    currentMessageId: 'A',
    updatedAt: 2,
    enqueueUpdate: false,
    enqueueCompletion: queued,
    completion: queued
        ? const RequestCompletionPayload(assistantMessageId: 'A', model: 'model')
        : null,
  );

  Future<void> expectVisible({String answer = '', String? error}) async {
    final chat = (await db.chatsDao.getChat('topic'))!;
    final messages = await db.messagesDao.getForChat('topic');
    expect(messages.map((row) => row.id), ['U', 'A']);
    expect(chat.currentMessageId, 'A');
    expect(messages.last.parentId, 'U');
    final reopened = await assembleConversationGuarded(chat, messages, offload: null);
    expect(reopened.messages.map((message) => message.id), ['U', 'A']);
    expect(reopened.messages.first.content, 'Prompt');
    expect(reopened.messages.last.content, answer);
    expect(reopened.messages.last.isStreaming, false);
    expect(reopened.messages.last.error?.content, error);
    final blob = ChatBlobMapper.rowsToBlob(chatRowsFromDb(chat, messages));
    expect((blob['history'] as Map)['currentId'], 'A');
    expect(ChatBlobMapper.treeIsConsistent(blob), true);
  }

  for (final rawBackend in [false, true]) {
    test('raw success reopens active parent branch (raw backend: $rawBackend)', () async {
      await db.chatsDao.mergeServerChat(
        server: emptyTopic(rawBackend: rawBackend),
        meta: rawBackend ? const {} : const {'backend': 'lobehub'},
      );
      expect(jsonDecode((await db.chatsDao.getChat('topic'))!.blobMeta)
          ['historyHadCurrentId'], false);
      await append(answer: 'Actual answer');
      await expectVisible(answer: 'Actual answer');
    });
  }

  test('parked local terminal error stays visible during empty remote pull', () async {
    await db.chatsDao.mergeServerChat(server: emptyTopic(), meta: {'backend': 'lobehub'});
    await append(queued: true);
    await db.messagesDao.markAssistantCompletionPreSubmissionFailed(
      chatId: 'topic', messageId: 'A', error: 'HTTP 400 rejection',
    );
    final completion = (await db.outboxDao.pendingForChat('topic')).single;
    await db.outboxDao.markParked(completion.seq, error: 'HTTP 400 rejection');
    await db.chatsDao.mergeServerChat(server: emptyTopic(stamp: 3));
    await expectVisible(error: 'HTTP 400 rejection');
    await db.delete(db.outboxOps).go();
    await db.chatsDao.mergeServerChat(server: emptyTopic(stamp: 4));
    await expectVisible(error: 'HTTP 400 rejection');
  });

  test('unresolved Agent correlation retains branch after op consumption', () async {
    await db.chatsDao.mergeServerChat(server: emptyTopic(), meta: {'backend': 'lobehub'});
    await append(metadata: {
      'completionSubmitted': true,
      'lobeAgentCorrelation': {'topicId': 'topic', 'userLocalId': 'U', 'assistantLocalId': 'A'},
    });
    await db.chatsDao.mergeServerChat(server: emptyTopic(stamp: 3));
    await expectVisible();
    expect(await db.select(db.outboxOps).get(), isEmpty);
    final assistant = (await db.messagesDao.getForChat('topic')).last;
    expect(jsonDecode(assistant.payload)['metadata']['lobeAgentCorrelation']['topicId'], 'topic');
  });

  test('preservation repairs a missing marker even when rows and tip survive', () async {
    await db.chatsDao.mergeServerChat(server: emptyTopic(), meta: {'backend': 'lobehub'});
    await append(metadata: {'completionSubmitted': true});
    await db.customStatement(
      "UPDATE chats SET blob_meta = json_set(blob_meta, '\$.historyHadCurrentId', json('false')) WHERE id = 'topic'",
    );
    await db.chatsDao.mergeServerChat(server: emptyTopic(stamp: 3));
    await expectVisible();
  });

  for (final blob in <Map<String, dynamic>>[
    {'models': ['lobehub-looking-model'], 'metadata': {'provider': 'lobehub'}},
    {'history': {'messages': <String, dynamic>{}}},
  ]) {
    test('OpenWebUI arbitrary blob remains exact: $blob', () async {
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'topic', blob: blob, title: 'Topic', createdAt: 1, updatedAt: 1,
      );
      await db.chatsDao.upsertServerChat(rows: rows);
      await append(answer: 'Answer');
      final chat = (await db.chatsDao.getChat('topic'))!;
      final messages = await db.messagesDao.getForChat('topic');
      final rebuilt = ChatBlobMapper.rowsToBlob(chatRowsFromDb(chat, messages));
      if (blob.containsKey('history')) {
        expect((rebuilt['history'] as Map).containsKey('currentId'), false);
      } else {
        expect(rebuilt, blob);
      }
      expect(jsonDecode(chat.blobMeta)['historyHadCurrentId'], false);
    });
  }
}

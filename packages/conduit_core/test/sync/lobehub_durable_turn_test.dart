import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/sync/chat_adapter.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';

Map<String, dynamic> _firstTurn({bool flags = false, bool agent = false}) => {
  'title': 'Synthetic loopback prompt',
  'models': ['fixture-model'],
  if (agent) 'meta': {'agentId': 'fixture-agent'},
  'history': {
    'currentId': 'A',
    'messages': {
      'U': {
        'id': 'U',
        'parentId': null,
        'childrenIds': ['A'],
        'role': 'user',
        'content': 'Synthetic loopback prompt',
        'files': <Object>[],
        'models': ['fixture-model'],
        'timestamp': 1791072000,
      },
      'A': {
        'id': 'A',
        'parentId': 'U',
        'childrenIds': <String>[],
        'role': 'assistant',
        'content': '',
        'model': 'fixture-model',
        'modelName': 'Fixture Model',
        'timestamp': 1791072000,
        if (flags) 'isStreaming': true,
        if (flags) 'done': false,
      },
    },
  },
};

void main() {
  late _Harness fixture;
  tearDown(() async => fixture.close());

  for (final flags in [false, true]) {
    test('durable first turn ($flags flags) reaches one actual raw inference', () async {
      fixture = await _Harness.open();
      await fixture.seed(_firstTurn(flags: flags));
      await fixture.drainer.drain();
      expect(fixture.http.inferences, 1);
      expect(fixture.http.topicCreates, 1);
      expect(fixture.http.invalidMessages, isEmpty);
      expect(await fixture.db.chatsDao.getChat('local:turn'), isNull);
      expect(await fixture.db.syncMetaDao.getChatRemapTarget('local:turn'), 'topic-1');
      expect(await fixture.db.select(fixture.db.outboxOps).get(), isEmpty);
      expect(fixture.http.messages.map((m) => m['role']), ['user', 'assistant']);
      expect(fixture.http.messages.last['content'], 'Loopback answer');
      expect(fixture.http.timeline.indexOf('POST /api/v1/chat'), lessThan(fixture.http.timeline.indexOf('POST /api/v1/messages')));
      expect((await fixture.db.messagesDao.getMessage('topic-1', 'A'))!.content, 'Loopback answer');
      expect(fixture.http.unexpected, isEmpty);
    });
  }

  test('message failure after remote create adopts identity before retry', () async {
    fixture = await _Harness.open();
    final blob = _firstTurn();
    final history = blob['history'] as Map;
    (history['messages'] as Map)['A'] = {
      'id': 'A', 'parentId': 'U', 'role': 'assistant',
      'content': 'Historical reply', 'done': true, 'timestamp': 1791072001,
    };
    fixture.http.failNextMessage = true;
    fixture.http.failMessageRole = 'assistant';
    fixture.http.beforeMessageWrite = () async {
      expect(await fixture.db.chatsDao.getChat('local:turn'), isNull);
      expect(await fixture.db.syncMetaDao.getChatRemapTarget('local:turn'), 'topic-1');
      expect((await fixture.db.select(fixture.db.outboxOps).get()).every((op) => op.chatId == 'topic-1'), isTrue);
    };
    await fixture.seed(blob, completion: false);
    await fixture.drainer.drain();
    expect(fixture.http.topicCreates, 1);
    expect(await fixture.db.chatsDao.getChat('local:turn'), isNull);
    expect(await fixture.db.syncMetaDao.getChatRemapTarget('local:turn'), 'topic-1');
    final ops = await fixture.db.select(fixture.db.outboxOps).get();
    expect(ops.single.chatId, 'topic-1');
    expect(ops.single.attempts, 1);
    expect(ops.single.lastError, isNotEmpty);
    expect(fixture.http.messages.single['role'], 'user');
    expect((await fixture.db.messagesDao.getForChat('topic-1')).every((m) => m.dirty), isTrue);
    fixture.clock.now++;
    await fixture.drainer.drain();
    expect(fixture.http.topicCreates, 1);
    expect(fixture.http.messages.length, 2);
    expect(await fixture.db.select(fixture.db.outboxOps).get(), isEmpty);
    expect(fixture.http.unexpected, isEmpty);
  });

  test('Responses owns active Agent pair, not CRUD, including empty pull', () async {
    fixture = await _Harness.open(agent: true);
    fixture.runner.pullBeforeInference = true;
    await fixture.seed(_firstTurn(agent: true));
    await fixture.drainer.drain();
    expect(fixture.http.inferences, 1);
    expect(fixture.http.crudPosts, 0);
    expect(fixture.runner.correlationStored, isTrue);
    expect(fixture.http.messages.map((m) => m['role']), ['user', 'assistant']);
    expect((await fixture.db.messagesDao.getMessage('topic-1', 'A'))!.content, 'Loopback answer');
    expect(await fixture.db.select(fixture.db.outboxOps).get(), isEmpty);
    expect(fixture.http.unexpected, isEmpty);
  });

  test('empty pull preserves submitted clean correlation rows and queued completion', () async {
    fixture = await _Harness.open(agent: true);
    await fixture.seed(_firstTurn(agent: true));
    await fixture.push.pushCreateChat('local:turn');
    await (fixture.db.update(fixture.db.chats)..where((c) => c.id.equals('topic-1')))
        .write(ChatsCompanion(serverUpdatedAt: Value(fixture.http.stamp)));
    await fixture.db.messagesDao.markAssistantCompletionSubmitted(chatId: 'topic-1', messageId: 'A');
    final assistant = (await fixture.db.messagesDao.getMessage('topic-1', 'A'))!;
    final payload = jsonDecode(assistant.payload) as Map<String, dynamic>;
    (payload['metadata'] as Map)['lobeAgentCorrelation'] = {'topicId': 'topic-1', 'userLocalId': 'U', 'assistantLocalId': 'A'};
    await (fixture.db.update(fixture.db.messages)..where((m) => m.chatId.equals('topic-1')))
        .write(const MessagesCompanion(dirty: Value(false)));
    await (fixture.db.update(fixture.db.messages)..where((m) => m.id.equals('A')))
        .write(MessagesCompanion(payload: Value(jsonEncode(payload))));
    await fixture.pull.pullChat('topic-1');
    final messages = await fixture.db.messagesDao.getForChat('topic-1');
    expect(messages.map((m) => m.id), ['U', 'A']);
    expect(jsonDecode(messages.last.payload)['metadata']['lobeAgentCorrelation']['topicId'], 'topic-1');
    expect((await fixture.db.chatsDao.getChat('topic-1'))!.currentMessageId, 'A');
    expect((await fixture.db.select(fixture.db.outboxOps).get()).any((op) => op.kind == 'requestCompletion'), isTrue);
    expect(fixture.http.unexpected, isEmpty);
  });

  test('correlation survives empty pull after completion op is consumed', () async {
    fixture = await _Harness.open(agent: true);
    await fixture.seed(_firstTurn(agent: true));
    await fixture.push.pushCreateChat('local:turn');
    final assistant = (await fixture.db.messagesDao.getMessage('topic-1', 'A'))!;
    final payload = jsonDecode(assistant.payload) as Map<String, dynamic>;
    payload['done'] = true;
    payload['metadata'] = {'completionSubmitted': true, 'lobeAgentCorrelation': {'topicId': 'topic-1'}};
    await (fixture.db.update(fixture.db.messages)..where((m) => m.chatId.equals('topic-1'))).write(const MessagesCompanion(dirty: Value(false)));
    await (fixture.db.update(fixture.db.messages)..where((m) => m.id.equals('A'))).write(MessagesCompanion(payload: Value(jsonEncode(payload))));
    await fixture.db.delete(fixture.db.outboxOps).go();
    await fixture.pull.pullChat('topic-1');
    final messages = await fixture.db.messagesDao.getForChat('topic-1');
    expect(messages.map((m) => m.id), ['U', 'A']);
    expect(jsonDecode(messages.last.payload)['metadata']['lobeAgentCorrelation']['topicId'], 'topic-1');
    expect(await fixture.db.select(fixture.db.outboxOps).get(), isEmpty);
    expect(fixture.http.unexpected, isEmpty);
  });

  test('parked terminal local error survives pull without being uploaded', () async {
    fixture = await _Harness.open();
    await fixture.seed(_firstTurn());
    await fixture.push.pushCreateChat('local:turn');
    await fixture.db.messagesDao.markAssistantCompletionPreSubmissionFailed(chatId: 'topic-1', messageId: 'A', error: 'Synthetic rejection');
    final completion = (await fixture.db.select(fixture.db.outboxOps).get()).firstWhere((op) => op.kind == 'requestCompletion');
    await fixture.db.outboxDao.markParked(completion.seq, error: 'Synthetic rejection');
    await (fixture.db.update(fixture.db.messages)..where((m) => m.chatId.equals('topic-1'))).write(const MessagesCompanion(dirty: Value(false)));
    await fixture.pull.pullChat('topic-1');
    expect((await fixture.db.messagesDao.getForChat('topic-1')).map((m) => m.id), ['U', 'A']);
    await fixture.push.pushUpdateChat('topic-1');
    expect(fixture.http.crudPosts, 0);
    expect(fixture.http.inferences, 0);
    expect(fixture.http.unexpected, isEmpty);
  });

  for (final body in <Map<String, dynamic>>[
    {'success': true, 'data': <String, dynamic>{}},
    {'success': false, 'data': {'id': 'must-not-adopt'}},
  ]) {
    test('invalid topic envelope surfaces typed error: $body', () async {
      fixture = await _Harness.open();
      fixture.http.createEnvelope = body;
      await expectLater(fixture.api.createChatRaw(_firstTurn()), throwsA(isA<SyncTerminalException>()));
      expect(fixture.http.crudPosts, 0);
      expect(fixture.http.unexpected, isEmpty);
    });
  }

  test('OpenWebUI create still sends complete original placeholder blob', () async {
    fixture = await _Harness.open(openWebUi: true);
    await fixture.seed(_firstTurn(), completion: false);
    await fixture.drainer.drain();
    expect(fixture.http.topicCreates, 1);
    final history = fixture.http.openWebUiBlob!['history'] as Map;
    expect((history['messages'] as Map)['A']['content'], '');
    expect((await fixture.db.messagesDao.getForChat('topic-1')).every((m) => !m.dirty), isTrue);
    expect(await fixture.db.select(fixture.db.outboxOps).get(), isEmpty);
    expect(fixture.http.unexpected, isEmpty);
  });
}

class _Clock implements SyncClock {
  int now = 1791072000;
  @override
  int nowEpochSeconds() => now;
}

class _Harness {
  _Harness(this.http, this.api, this.workers, this.db, this.remapper, this.clock, this.push, this.pull, this.runner, this.drainer);
  final _Loopback http;
  final ApiService api;
  final WorkerManager workers;
  final AppDatabase db;
  final IdRemapper remapper;
  final _Clock clock;
  final PushSync push;
  final PullSync pull;
  final _ActualCompletion runner;
  final OutboxDrainer drainer;

  static Future<_Harness> open({bool agent = false, bool openWebUi = false}) async {
    final http = await _Loopback.open(agent: agent, openWebUi: openWebUi);
    final workers = WorkerManager();
    final api = ApiService(
      serverConfig: ServerConfig(id: openWebUi ? 'openwebui' : 'lobehub_self_hosted', name: 'Loopback fixture', url: http.url),
      workerManager: workers,
      authToken: 'loopback-fixture-not-a-user-credential',
    );
    final db = AppDatabase(NativeDatabase.memory());
    final remapper = IdRemapper(db);
    final locks = ConversationLocks();
    final clock = _Clock();
    final client = ApiSyncApiClient(api);
    final push = PushSync(client: client, db: db, chatLocks: locks, folderLocks: FolderLocks(), clock: clock, remapper: remapper);
    final pull = PullSync(client: client, db: db, locks: locks, remapper: remapper);
    final runner = _ActualCompletion(api, db, pull, agent);
    final drainer = OutboxDrainer(db: db, clock: clock, backoff: Backoff(jitter: () => 0), isOnline: () => true, completion: runner, adapters: [ChatAdapter(pull: pull, push: push)]);
    return _Harness(http, api, workers, db, remapper, clock, push, pull, runner, drainer);
  }

  Future<void> seed(Map<String, dynamic> blob, {bool completion = true}) async {
    final rows = ChatBlobMapper.blobToRows(chatId: 'local:turn', blob: blob, title: 'Synthetic loopback prompt', createdAt: clock.now, updatedAt: clock.now);
    await db.chatsDao.insertLocalChatWithCreateOp(chat: rows.chat, messages: rows.messages, blobRows: rows, contentHash: createChatContentHash(rows), completion: completion ? const RequestCompletionPayload(assistantMessageId: 'A', model: 'fixture-model') : null);
  }

  Future<void> close() async {
    final outbox = await db.select(db.outboxOps).get();
    api.dispose();
    workers.dispose();
    await remapper.dispose();
    await db.close();
    await http.server.close(force: true);
    await http.subscription.cancel();
    print(jsonEncode({
      'loopbackOnly': true,
      'topicCreates': http.topicCreates,
      'inferenceRequests': http.inferences,
      'crudPosts': http.crudPosts,
      'invalidMessagePosts': http.invalidMessages.length,
      'unexpectedRoutes': http.unexpected,
      'http': http.timeline,
      'outbox': [for (final op in outbox) {'kind': op.kind, 'chatId': op.chatId, 'status': op.status, 'attempts': op.attempts}],
      'cleanup': ['apiDisposed', 'workersDisposed', 'remapperClosed', 'databaseClosed', 'serverClosed', 'subscriptionCancelled'],
    }));
  }
}

class _ActualCompletion implements RequestCompletionRunner {
  _ActualCompletion(this.api, this.db, this.pull, this.agent);
  final ApiService api;
  final AppDatabase db;
  final PullSync pull;
  final bool agent;
  bool pullBeforeInference = false;
  bool correlationStored = false;

  @override
  Future<void> run({required String chatId, required Map<String, dynamic> payload}) async {
    expect(chatId, 'topic-1');
    if (pullBeforeInference) await pull.pullChat(chatId);
    final rows = await db.messagesDao.getForChat(chatId);
    expect(rows.map((m) => m.id), ['U', 'A']);
    final user = jsonDecode(rows.first.payload) as Map<String, dynamic>;
    final session = await api.sendMessageSession(
      messages: [{'role': 'user', 'content': user['content']}],
      model: payload['model'] as String,
      conversationId: chatId,
      responseMessageId: payload['assistantMessageId'] as String,
      userMessage: user,
      onPreDispatch: agent ? (correlation) async {
        final assistant = (await db.messagesDao.getMessage(chatId, 'A'))!;
        final stored = jsonDecode(assistant.payload) as Map<String, dynamic>;
        stored['metadata'] = {'completionSubmitted': true, 'lobeAgentCorrelation': correlation.toJson()};
        await (db.update(db.messages)..where((m) => m.chatId.equals(chatId) & m.id.equals('A'))).write(MessagesCompanion(payload: Value(jsonEncode(stored))));
        correlationStored = true;
      } : null,
    );
    if (session.byteStream != null) {
      await session.byteStream!.drain<void>();
    } else {
      expect((session.jsonPayload!['choices'] as List).first['message']['content'], 'Loopback answer');
    }
    await db.messagesDao.markAssistantResponseDone(chatId: chatId, messageId: 'A');
    await pull.pullChat(chatId);
  }
}

class _Loopback {
  _Loopback(this.server, this.agent, this.openWebUi);
  final HttpServer server;
  final bool agent;
  final bool openWebUi;
  final int stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  late StreamSubscription<HttpRequest> subscription;
  String get url => 'http://127.0.0.1:${server.port}';
  int topicCreates = 0;
  int inferences = 0;
  int crudPosts = 0;
  bool failNextMessage = false;
  String? failMessageRole;
  Future<void> Function()? beforeMessageWrite;
  Map<String, dynamic>? createEnvelope;
  Map<String, dynamic>? openWebUiBlob;
  final messages = <Map<String, dynamic>>[];
  final unexpected = <String>[];
  final invalidMessages = <Map<String, dynamic>>[];
  final timeline = <String>[];

  static Future<_Loopback> open({required bool agent, required bool openWebUi}) async {
    final fixture = _Loopback(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), agent, openWebUi);
    fixture.subscription = fixture.server.listen(fixture.handle);
    return fixture;
  }

  Future<void> handle(HttpRequest request) async {
    final key = '${request.method} ${request.uri.path}';
    timeline.add(key);
    final text = await utf8.decoder.bind(request).join();
    final body = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
    request.response.headers.contentType = ContentType.json;
    Object response;
    if (request.headers.value('authorization') != 'Bearer loopback-fixture-not-a-user-credential') {
      unexpected.add('Unexpected credentials: $key');
      request.response.statusCode = 401;
      response = {'error': 'fixture credentials required'};
    } else if (!openWebUi && key == 'POST /api/v1/topics') {
      topicCreates++;
      response = createEnvelope ?? {'success': true, 'data': {'id': 'topic-$topicCreates', 'agentId': agent ? 'fixture-agent' : null}};
    } else if (!openWebUi && key == 'GET /api/v1/topics/topic-1') {
      response = {'success': true, 'data': {'id': 'topic-1', 'title': 'Synthetic loopback prompt', 'createdAt': stamp, 'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 1, 'agentId': agent ? 'fixture-agent' : null}};
    } else if (!openWebUi && key == 'PATCH /api/v1/topics/topic-1') {
      response = {'success': true};
    } else if (!openWebUi && key == 'GET /api/v1/messages' && request.uri.queryParameters['topicId'] == 'topic-1') {
      response = {'success': true, 'data': {'messages': messages, 'total': messages.length}};
    } else if (!openWebUi && key == 'POST /api/v1/messages') {
      await beforeMessageWrite?.call();
      crudPosts++;
      if (body['content'] is! String || (body['content'] as String).isEmpty) {
        invalidMessages.add(body);
        request.response.statusCode = 400;
        response = {'success': false, 'error': {'message': 'content: String must contain at least 1 character(s)'}};
      } else if (failNextMessage && (failMessageRole == null || failMessageRole == body['role'])) {
        failNextMessage = false;
        request.response.statusCode = 503;
        response = {'success': false, 'error': 'synthetic message write failure'};
      } else {
        messages.add({...body, 'id': 'message-${messages.length + 1}'});
        response = {'success': true, 'data': messages.last};
      }
    } else if (!openWebUi && !agent && key == 'POST /api/v1/chat') {
      inferences++;
      response = {'success': true, 'data': {'content': 'Loopback answer'}};
    } else if (!openWebUi && agent && key == 'GET /api/v1/agents/fixture-agent') {
      response = {'success': true, 'data': {'id': 'fixture-agent', 'model': 'fixture-model', 'provider': 'fixture-provider'}};
    } else if (!openWebUi && agent && key == 'POST /api/v1/responses') {
      inferences++;
      messages.addAll([
        {'id': 'server-U', 'role': 'user', 'content': body['input']},
        {'id': 'server-A', 'parentId': 'server-U', 'role': 'assistant', 'content': 'Loopback answer', 'model': 'fixture-model', 'provider': 'fixture-provider'},
      ]);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('event: response.completed\ndata: ${jsonEncode({'type': 'response.completed', 'response': {'status': 'completed', 'output_text': 'Loopback answer'}})}\n\ndata: [DONE]\n\n');
      await request.response.close();
      return;
    } else if (!openWebUi && agent && (key == 'PATCH /api/v1/messages/server-U' || key == 'PATCH /api/v1/messages/server-A')) {
      final id = request.uri.path.split('/').last;
      messages.firstWhere((m) => m['id'] == id).addAll(body);
      response = {'success': true};
    } else if (openWebUi && key == 'POST /api/v1/chats/new') {
      topicCreates++;
      openWebUiBlob = body['chat'] as Map<String, dynamic>;
      response = {'id': 'topic-1', 'created_at': 1791072000, 'updated_at': 1791072000, 'chat': openWebUiBlob};
    } else {
      unexpected.add(key);
      request.response.statusCode = 500;
      response = {'error': 'Unexpected loopback route: $key'};
    }
    request.response.write(jsonEncode(response));
    await request.response.close();
  }
}

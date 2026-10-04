import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

void main() {
  late ApiService api;
  late _StrictAdapter adapter;
  late AppDatabase db;
  setUp(() {
    adapter = _StrictAdapter();
    api = ApiService(
      serverConfig: const ServerConfig(
        id: 'lobehub_self_hosted',
        name: 'Lobe',
        url: 'http://localhost:3210',
      ),
      workerManager: WorkerManager(),
    );
    api.dio.interceptors.clear();
    api.dio.httpClientAdapter = adapter;
    db = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    api.dio.close();
    await db.close();
  });

  void routes({
    bool deleted = false,
    List<Map<String, dynamic>>? messages,
    Map<String, dynamic> topicFields = const {},
  }) {
    adapter.handlers['/api/v1/topics/topic-1'] = (_) => _response({
      'id': 'topic-1',
      'agentId': 'agt_writer',
      'title': 'Discussion',
      'createdAt': 1700000000,
      'updatedAt': 1700000010,
      'metadata': {
        'model': 'unsupported-override',
        'provider': 'wrong-provider',
        'agentTitle': 'Known writer',
        'agentModel': 'known-model',
        'agentProvider': 'known-provider',
        'systemRole': 'private prompt',
      },
      ...topicFields,
    });
    adapter.handlers['/api/v1/agents/agt_writer'] = (_) => _response({
      'id': 'agt_writer',
      'title': 'Exact Writer',
      'model': 'claude-exact',
      'provider': 'anthropic',
      'systemRole': 'private prompt',
    }, status: deleted ? 404 : 200);
    adapter.handlers['/api/v1/messages'] = (options) {
      expect(options.queryParameters, {
        'topicId': 'topic-1',
        'page': 1,
        'pageSize': 100,
      });
      final items =
          messages ??
          [
            {
              'id': 'srv-u',
              'role': 'user',
              'content': 'Hello',
              'childrenIds': ['srv-a'],
              'metadata': {'conduitClientId': 'local-u'},
            },
            {
              'id': 'srv-a',
              'role': 'assistant',
              'content': 'Hi',
              'parentId': 'srv-u',
              'metadata': {'conduitClientId': 'local-a'},
            },
          ];
      return _response({'messages': items, 'total': items.length});
    };
  }

  test(
    'real GET envelopes preserve agent identity and aliases through SQLite',
    () async {
      routes();
      final raw = (await api.getChatRaw('topic-1'))!;
      final identity = {
        'backend': 'lobehub',
        'agentId': 'agt_writer',
        'agentTitle': 'Exact Writer',
        'agentModel': 'claude-exact',
        'provider': 'anthropic',
        'model': 'claude-exact',
      };
      expect(raw['meta'], identity);
      expect(raw['metadata'], identity);
      final blob = raw['chat'] as Map<String, dynamic>;
      expect(blob['metadata'], identity);
      final parsed = parseFullConversationModel(raw);
      expect(parsed.metadata, identity);
      expect(parsed.model, 'claude-exact');
      expect(parsed.systemPrompt, isNull);
      expect(jsonEncode(raw), isNot(contains('private prompt')));
      expect(parsed.messages.map((message) => message.id), [
        'local-u',
        'local-a',
      ]);
      expect(parsed.messages.last.metadata?['parentId'], 'local-u');
      expect(parsed.messages.first.metadata?['childrenIds'], ['local-a']);
      expect(parsed.messages.last.metadata?['serverMessageId'], 'srv-a');
      await db.chatsDao.upsertServerChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: raw['id'] as String,
          blob: blob,
          title: raw['title'] as String,
          createdAt: raw['created_at'] as int,
          updatedAt: raw['updated_at'] as int,
        ),
        meta: raw['meta'] as Map<String, dynamic>,
      );
      final reopened = assembleConversation(
        (await db.chatsDao.getChat('topic-1'))!,
        await db.messagesDao.getForChat('topic-1'),
      );
      expect(reopened.metadata, identity);
      expect(reopened.model, parsed.model);
      expect(reopened.messages.map((message) => message.id), [
        'local-u',
        'local-a',
      ]);
      expect(reopened.messages.last.metadata?['parentId'], 'local-u');
      expect(reopened.messages.last.metadata?['serverMessageId'], 'srv-a');
      expect(adapter.paths, contains('/api/v1/agents/agt_writer'));
    },
  );

  test(
    'deleted agent keeps binding and known identity without raw override',
    () async {
      routes(deleted: true);
      final parsed = parseFullConversationModel(
        (await api.getChatRaw('topic-1'))!,
      );
      expect(parsed.metadata['agentId'], 'agt_writer');
      expect(parsed.metadata['agentTitle'], 'Known writer');
      expect(parsed.metadata['agentModel'], 'known-model');
      expect(parsed.metadata['provider'], 'known-provider');
      expect(parsed.model, 'known-model');
    },
  );

  for (final groupId in [null, 'group-1']) {
    test('top-level topic pins survive SQLite with group $groupId', () async {
      routes(topicFields: {
        'model': 'gpt-pinned',
        'provider': 'openai',
        'groupId': ?groupId,
      });
      final raw = (await api.getChatRaw('topic-1'))!;
      final identity = {
        'backend': 'lobehub',
        'agentId': 'agt_writer',
        'agentTitle': 'Exact Writer',
        'agentModel': 'gpt-pinned',
        'provider': 'openai',
        'model': 'gpt-pinned',
      };
      expect(raw['model'], 'gpt-pinned');
      expect(raw['meta'], identity);
      expect(raw['metadata'], identity);
      final blob = raw['chat'] as Map<String, dynamic>;
      expect(blob['metadata'], identity);
      expect(blob['models'], ['gpt-pinned']);
      final parsed = parseFullConversationModel(raw);
      expect(parsed.model, 'gpt-pinned');
      expect(parsed.metadata, identity);
      await db.chatsDao.upsertServerChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: 'topic-1',
          blob: blob,
          title: raw['title'] as String,
          createdAt: raw['created_at'] as int,
          updatedAt: raw['updated_at'] as int,
        ),
        meta: raw['meta'] as Map<String, dynamic>,
      );
      final reopened = assembleConversation(
        (await db.chatsDao.getChat('topic-1'))!,
        await db.messagesDao.getForChat('topic-1'),
      );
      expect(reopened.model, 'gpt-pinned');
      expect(reopened.metadata, identity);
      expect(reopened.messages.last.metadata?['parentId'], 'local-u');
      expect(reopened.messages.last.metadata?['serverMessageId'], 'srv-a');
    });
  }

  for (final provider in [null, '']) {
    test('topic pin with provider $provider uses Agent provider', () async {
      routes(topicFields: {'model': 'pinned-model', 'provider': provider});
      final parsed = parseFullConversationModel((await api.getChatRaw('topic-1'))!);
      expect(parsed.model, 'pinned-model');
      expect(parsed.metadata['agentModel'], 'pinned-model');
      expect(parsed.metadata['provider'], 'anthropic');
    });
  }

  for (final model in [null, '']) {
    test('provider alone with topic model $model does not override defaults', () async {
      routes(topicFields: {'model': model, 'provider': 'openai'});
      final parsed = parseFullConversationModel((await api.getChatRaw('topic-1'))!);
      expect(parsed.model, 'claude-exact');
      expect(parsed.metadata['agentModel'], 'claude-exact');
      expect(parsed.metadata['provider'], 'anthropic');
    });
  }

  for (final deleted in [false, true]) {
    test('page shares Agent GET including deleted=$deleted but reopen is fresh', () async {
      routes(deleted: deleted);
      adapter.handlers['/api/v1/topics'] = (_) => _response({
        'topics': [
          for (var index = 0; index < 3; index++)
            {
              'id': 'topic-$index',
              'agentId': 'agt_writer',
              'model': 'pinned-$index',
              'provider': 'openai',
              'metadata': {'agentTitle': 'Snapshot $index'},
            },
        ],
      });
      final summaries = await fetchLobeHubTopicListPageRaw(api.dio, page: 1);
      int agentGets() => adapter.paths
          .where((path) => path == '/api/v1/agents/agt_writer')
          .length;
      expect(agentGets(), 1);
      for (var index = 0; index < summaries.length; index++) {
        final parsed = parseConversationSummary(summaries[index]);
        expect(parsed['model'], 'pinned-$index');
        expect((parsed['metadata'] as Map)['agentModel'], 'pinned-$index');
        expect((parsed['metadata'] as Map)['agentTitle'],
            deleted ? 'Snapshot $index' : 'Exact Writer');
      }
      await fetchLobeHubTopicListPageRaw(api.dio, page: 2);
      expect(agentGets(), 2);
      adapter.handlers['/api/v1/agents/agt_writer'] = (_) => _response({
        'id': 'agt_writer',
        'title': 'Updated Writer',
        'model': 'fresh-model',
        'provider': 'fresh-provider',
      });
      final reopened = parseFullConversationModel((await api.getChatRaw('topic-1'))!);
      expect(agentGets(), 3);
      expect(reopened.model, 'fresh-model');
      expect(reopened.metadata['agentTitle'], 'Updated Writer');
      expect(reopened.metadata['provider'], 'fresh-provider');
    });
  }

  test('aliases resolve forward parent references in a second pass', () async {
    routes(
      messages: [
        {
          'id': 'srv-a',
          'role': 'assistant',
          'content': 'Hi',
          'parentId': 'srv-u',
          'metadata': {'conduitClientId': 'local-a'},
        },
        {
          'id': 'srv-u',
          'role': 'user',
          'content': 'Hello',
          'metadata': {'conduitClientId': 'local-u'},
        },
      ],
    );
    final raw = (await api.getChatRaw('topic-1'))!;
    final history = (raw['chat'] as Map)['history'] as Map;
    expect((history['messages'] as Map)['local-a']['parentId'], 'local-u');
  });

  test('topic list summary resolves the bound agent rather than a list-first model', () async {
    routes();
    adapter.handlers['/api/v1/topics'] = (options) {
      expect(options.queryParameters, {'page': 1, 'pageSize': 60});
      return _response({
        'topics': [
          {'id': 'topic-1', 'agentId': 'agt_writer', 'title': 'Discussion'},
        ],
      });
    };
    final summaries = await fetchLobeHubTopicListPageRaw(api.dio, page: 1);
    final parsed = parseConversationSummary(summaries.single);
    expect(parsed['model'], 'claude-exact');
    expect(parsed['metadata'], {
      'backend': 'lobehub',
      'agentId': 'agt_writer',
      'agentTitle': 'Exact Writer',
      'agentModel': 'claude-exact',
      'provider': 'anthropic',
      'model': 'claude-exact',
    });
  });

  test(
    'deleted agent without a snapshot remains visibly bound by ID',
    () async {
      routes(deleted: true);
      adapter.handlers['/api/v1/topics/topic-1'] = (_) => _response({
        'id': 'topic-1',
        'agentId': 'agt_writer',
        'title': 'Discussion',
        'metadata': {'model': 'not-an-agent-model'},
      });
      final parsed = parseFullConversationModel(
        (await api.getChatRaw('topic-1'))!,
      );
      expect(parsed.metadata['agentId'], 'agt_writer');
      expect(parsed.metadata['agentTitle'], 'agt_writer');
      expect(parsed.model, isNull);
    },
  );

  test(
    'mismatched agent detail is rejected instead of binding another actor',
    () async {
      routes();
      adapter.handlers['/api/v1/agents/agt_writer'] = (_) => _response({
        'id': 'agt_other',
        'title': 'Wrong Actor',
        'model': 'wrong-model',
      });
      await expectLater(api.getChatRaw('topic-1'), throwsFormatException);
    },
  );

  test(
    'unbound topic retains explicit raw model metadata without agent lookup',
    () async {
      routes();
      adapter.handlers['/api/v1/topics/topic-1'] = (_) => _response({
        'id': 'topic-1',
        'title': 'Raw Discussion',
        'metadata': {'model': 'gpt-exact', 'provider': 'openai'},
      });
      final parsed = parseFullConversationModel(
        (await api.getChatRaw('topic-1'))!,
      );
      expect(parsed.model, 'gpt-exact');
      expect(parsed.metadata['provider'], 'openai');
      expect(parsed.metadata.containsKey('agentId'), isFalse);
      expect(adapter.paths, isNot(contains('/api/v1/agents/agt_writer')));
    },
  );

  for (final agentBound in [false, true]) {
    test('persisted result retains completion and provider with Agent=$agentBound', () async {
      routes(messages: [
        {
          'id': 'srv-u', 'role': 'user', 'content': 'Synthetic question',
          'childrenIds': ['srv-a'],
          'metadata': {'conduitClientId': 'local-u'},
        },
        {
          'id': 'srv-a', 'role': 'assistant', 'content': 'Synthetic result',
          'parentId': 'srv-u', 'model': 'same-model', 'provider': 'original-provider',
          'error': null,
          'metadata': {
            'conduitClientId': 'local-a',
            'model': 'stale-model', 'provider': 'foreign-provider',
            if (agentBound) 'operationId': 'operation-1',
            if (agentBound) 'finishType': 'stop',
          },
        },
      ]);
      if (!agentBound) {
        adapter.handlers['/api/v1/topics/topic-1'] = (_) => _response({
          'id': 'topic-1', 'title': 'Raw topic',
        });
      }
      for (var pull = 0; pull < 2; pull++) {
        final raw = (await api.getChatRaw('topic-1'))!;
        final blob = raw['chat'] as Map<String, dynamic>;
        final assistant = ((blob['history'] as Map)['messages'] as Map)['local-a'] as Map;
        expect(assistant['done'], true);
        expect(assistant['isStreaming'], false);
        expect(assistant['provider'], 'original-provider');
        await db.chatsDao.upsertServerChat(
          rows: ChatBlobMapper.blobToRows(
            chatId: 'topic-1', blob: blob, title: raw['title'] as String,
            createdAt: raw['created_at'] as int, updatedAt: raw['updated_at'] as int,
          ),
          meta: raw['meta'] as Map<String, dynamic>,
        );
        final rows = await db.messagesDao.getForChat('topic-1');
        expect(rows.map((row) => row.id), ['local-u', 'local-a']);
        final payload = jsonDecode(rows.last.payload) as Map;
        final metadata = payload['metadata'] as Map;
        expect(metadata['responseDone'], true);
        expect(metadata['provider'], 'original-provider');
        expect(metadata['model'], 'same-model');
        expect(metadata['serverMessageId'], 'srv-a');
        expect(payload['parentId'], 'local-u');
        expect(metadata['terminal'], isNot(true));
        expect(payload['error'], isNull);
        final reopened = assembleConversation(
          (await db.chatsDao.getChat('topic-1'))!, rows,
        );
        expect(reopened.messages.last.isStreaming, false);
        expect(reopened.messages.last.metadata?['responseDone'], true);
        expect(reopened.messages.last.metadata?['provider'], 'original-provider');
      }
      expect(adapter.paths.where((path) => path == '/api/v1/messages'), hasLength(2));
    });
  }

  for (final state in <Map<String, dynamic>>[
    {'content': ''},
    {'content': '   '},
    {'content': '...'},
    {'status': 'pending'},
    {'status': 'in_progress'},
    {'status': 'incomplete'},
    {'done': false},
    {'isStreaming': true},
    {'responseDone': false},
    {'incomplete_details': {'reason': 'client_tool_execution'}},
    {'model': null, 'provider': null},
    {'provider': ''},
    {'metadata': {'status': 'pending'}},
    {'status': 'completed', 'metadata': {'status': 'incomplete'}},
    {'metadata': {'incomplete_details': {'reason': 'max_output_tokens'}}},
    {'metadata': {'done': false, 'finishType': 'stop'}},
    {'metadata': {'isStreaming': true}},
    {'metadata': {'responseDone': false}},
    {'metadata': {'operationId': 'operation-1'}},
    {'metadata': {'finishType': 'length'}},
    {'metadata': {'finishType': 'abort'}},
    {'metadata': {'interruptedMidStream': true, 'finishType': 'stop'}},
    {'status': 'failed', 'error': {'message': 'Synthetic failure'}},
    {'done': true, 'error': {'message': 'Synthetic failure'}},
  ]) {
    test('unfinished or failed remote result is not success: $state', () async {
      routes(messages: [{
        'id': 'srv-a', 'role': 'assistant', 'content': 'Partial synthetic text',
        'model': 'same-model', 'provider': 'original-provider',
        ...state,
      }]);
      final raw = (await api.getChatRaw('topic-1'))!;
      final blob = raw['chat'] as Map<String, dynamic>;
      final mapped = ((blob['history'] as Map)['messages'] as Map)['srv-a'] as Map;
      expect(mapped['done'], false);
      expect(mapped['isStreaming'], true);
      expect((mapped['metadata'] as Map)['responseDone'], false);
      if (state.containsKey('status')) {
        expect((mapped['metadata'] as Map)['status'], state['status']);
      }
      await db.chatsDao.upsertServerChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: 'topic-1', blob: blob, title: raw['title'] as String,
          createdAt: raw['created_at'] as int, updatedAt: raw['updated_at'] as int,
        ), meta: raw['meta'] as Map<String, dynamic>,
      );
      final reopened = assembleConversation(
        (await db.chatsDao.getChat('topic-1'))!,
        await db.messagesDao.getForChat('topic-1'),
      );
      expect(reopened.messages.single.isStreaming, true);
      expect(reopened.messages.single.metadata?['responseDone'], false);
      expect(reopened.messages.single.error?.content,
          state.containsKey('error') ? 'Synthetic failure' : isNull);
    });
  }

  for (final output in <Map<String, dynamic>>[
    {'reasoning': 'Final reasoning'},
    {'reasoning': {'content': 'Final reasoning'}},
    {'reasoning_content': 'Final reasoning'},
    {'tools': [{'id': 'tool-1', 'type': 'function'}]},
  ]) {
    test('mapper accepts final nontext output: $output', () async {
      routes(messages: [{
        'id': 'srv-a', 'role': 'assistant', 'content': '', ...output,
        'metadata': {'operationId': 'operation-1', 'finishType': 'stop'},
      }]);
      final raw = (await api.getChatRaw('topic-1'))!;
      final mapped = ((raw['chat'] as Map)['history']['messages'] as Map)['srv-a'];
      expect(mapped['done'], true);
      expect(mapped['isStreaming'], false);
      expect(mapped['metadata']['responseDone'], true);
    });
  }

  for (final aliases in [
    ['same', 'same'],
    ['srv-a', ''],
  ]) {
    test(
      'colliding aliases $aliases fail explicitly without dropping rows',
      () async {
        routes(
          messages: [
            {
              'id': 'srv-u',
              'role': 'user',
              'content': 'One',
              'metadata': {'conduitClientId': aliases.first},
            },
            {
              'id': 'srv-a',
              'role': 'assistant',
              'content': 'Two',
              'metadata': {'conduitClientId': aliases.last},
            },
          ],
        );
        await expectLater(api.getChatRaw('topic-1'), throwsFormatException);
      },
    );
  }
}

class _StrictAdapter implements HttpClientAdapter {
  final handlers = <String, ResponseBody Function(RequestOptions)>{};
  final paths = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET');
    paths.add(options.path);
    final handler = handlers[options.path];
    if (handler == null) throw StateError('Unexpected route: ${options.path}');
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode({'success': status == 200, 'data': data}),
      status,
      headers: {
        'content-type': ['application/json'],
      },
    );

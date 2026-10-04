import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/openwebui_stream_parser.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:test/test.dart';

void main() {
  late _LocalBoundaryServer server;
  late ApiService api;
  late WorkerManager workers;

  setUp(() async {
    server = await _LocalBoundaryServer.start();
    workers = WorkerManager();
    api = ApiService(
      serverConfig: ServerConfig(
        id: 'lobehub_self_hosted',
        name: 'Execution boundary',
        url: 'http://127.0.0.1:${server.http.port}',
      ),
      workerManager: workers,
    );
    api.dio.interceptors.clear();
  });
  tearDown(() async {
    api.dio.close(force: true);
    workers.dispose();
    await server.close();
  });

  Future<ChatCompletionSession> send({
    String? agent = 'agt_verified',
    String model = 'gpt-4o',
    String provider = 'openai',
  }) => api.sendMessageSession(
    messages: const [
      {'role': 'user', 'content': 'Hello'},
    ],
    model: model,
    modelItem: {'provider': provider},
    conversationId: 'tpc_verified',
    lobeAgentId: agent,
    responseMessageId: 'local_assistant',
    userMessage: const {'id': 'local_user', 'content': 'Hello'},
  );

  test('explicit local Agent must match verified topic Agent', () async {
    server.topicAgent = 'agt_other';
    await expectLater(send(), throwsA(isA<SyncTerminalException>()));
    expect(server.inferencePosts, isEmpty);
  });

  test('raw topic cannot be overridden with a local Agent', () async {
    server.topicAgent = null;
    await expectLater(send(), throwsA(isA<SyncTerminalException>()));
    expect(server.inferencePosts, isEmpty);
  });

  for (final agent in <String?>['agt_verified', null]) {
    test('missing topic never falls through to inference ($agent)', () async {
      server.topicStatus = 404;
      await expectLater(
        send(agent: agent),
        throwsA(isA<SyncTerminalException>()),
      );
      expect(server.inferencePosts, isEmpty);
    });
  }

  test(
    'blank assistant alias is not a completed result or replay license',
    () async {
      server.messages.add(server.assistant(content: ''));
      await expectLater(send(), throwsA(isA<SyncTerminalException>()));
      expect(server.inferencePosts, isEmpty);
    },
  );

  test('duplicate assistant aliases fail rather than picking first', () async {
    server.messages.addAll([
      server.assistant(content: 'first'),
      {...server.assistant(content: 'second'), 'id': 'server_other'},
    ]);
    await expectLater(send(), throwsA(isA<SyncTerminalException>()));
    expect(server.inferencePosts, isEmpty);
  });

  for (final state in <Map<String, dynamic>>[
    {'metadata': {'interruptedMidStream': true}},
    {'metadata': {'finishType': 'length'}},
    {'metadata': {'finishType': 'abort'}},
    {'metadata': {'operationId': 'operation-1'}},
    {'done': false},
    {'isStreaming': true},
    {'responseDone': false},
    {'incomplete_details': {'reason': 'max_output_tokens'}},
    {'status': 'pending'},
    {'status': 'completed', 'metadata': {'status': 'incomplete'}},
    {'status': 'completed', 'metadata': {'interruptedMidStream': true}},
    {'metadata': {'done': false, 'finishType': 'stop'}},
    {'metadata': {'isStreaming': true, 'finishType': 'stop'}},
    {'metadata': {'responseDone': false, 'finishType': 'stop'}},
    {'metadata': {'incomplete_details': {'reason': 'max_output_tokens'}}},
    {'finishType': 'abort', 'status': 'completed'},
    {'operationId': 'operation-1'},
    {'interruptedMidStream': true, 'done': true},
    {'meta': {'interruptedMidStream': true}, 'metadata': {'done': true}},
  ]) {
    test('unfinished persisted row cannot correlate or cache: $state', () async {
      final metadata = state['metadata'] as Map? ?? const {};
      server.messages.addAll([
        {'id': 'server_user', 'role': 'user', 'content': 'Hello'},
        {
          ...server.assistant(content: 'Partial answer'),
          'model': 'gpt-4o', 'provider': 'openai',
          ...state,
          'metadata': {'conduitClientId': 'local_assistant', ...metadata},
        },
      ]);
      final result = await api.reconcileAgentTurn(LobeAgentCorrelation(
        topicId: 'tpc_verified', agentId: 'agt_verified', userText: 'Hello',
        userLocalId: 'local_user', assistantLocalId: 'local_assistant',
        snapshotServerIds: {}, createdAt: DateTime.now(),
      ));
      expect(result.success, false);
      expect(server.patches, 0);
      await expectLater(send(), throwsA(isA<SyncTerminalException>()));
      expect(server.inferencePosts, isEmpty);
      expect(server.messageCreates, 0);
    });
  }

  test('snapshot failure prevents inference', () async {
    server.messageStatus = 500;
    await expectLater(send(), throwsA(anything));
    expect(server.inferencePosts, isEmpty);
  });

  for (final provider in <String?>['anthropic', null, '']) {
    test(
      'verified top-level topic pin executes exactly one Agent turn ($provider)',
      () async {
        server.topicFields = {
          'model': 'claude-topic',
          'provider': provider,
          'groupId': 'group-owned',
          'metadata': {
            'model': 'ignored-metadata',
            'provider': 'ignored-provider',
          },
        };
        final session = await send(
          agent: null,
          model: 'claude-topic',
          provider: provider == null || provider.isEmpty ? 'openai' : provider,
        );
        final updates = await parseOpenWebUIStream(session.byteStream!)
            .toList();
        expect(updates.whereType<OpenWebUIStreamDone>(), hasLength(1));
        expect(server.inferencePosts, ['/api/v1/responses']);
        expect(server.responsePayload, {
          'model': 'agt_verified',
          'previous_response_id': 'tpc_verified',
          'stream': true,
          'input': 'Hello',
        });
        expect(server.patches, 2);
        expect(server.messageCreates, 0);
      },
    );
  }

  test('topic pin rejects Agent default model and wrong provider', () async {
    server.topicFields = {'model': 'claude-topic', 'provider': 'anthropic'};
    await expectLater(send(), throwsA(isA<SyncTerminalException>()));
    await expectLater(
      send(model: 'claude-topic', provider: 'openai'),
      throwsA(isA<SyncTerminalException>()),
    );
    expect(server.inferencePosts, isEmpty);
  });

  test('metadata-only topic override is not an authoritative pin', () async {
    server.topicFields = {
      'metadata': {'model': 'claude-topic', 'provider': 'anthropic'},
    };
    await expectLater(
      send(model: 'claude-topic', provider: 'anthropic'),
      throwsA(isA<SyncTerminalException>()),
    );
    expect(server.inferencePosts, isEmpty);
  });

  test('provider-only topic field does not override Agent default', () async {
    server.topicFields = {'provider': 'anthropic'};
    final session = await send();
    await session.byteStream!.toList();
    expect(server.inferencePosts, ['/api/v1/responses']);
  });

  test('selected model and provider mismatches stay visible even with cached alias', () async {
    server.messages.add(server.assistant(content: 'cached'));
    await expectLater(
      send(model: 'wrong-model'),
      throwsA(isA<SyncTerminalException>()),
    );
    await expectLater(
      send(provider: 'wrong-provider'),
      throwsA(isA<SyncTerminalException>()),
    );
    expect(server.inferencePosts, isEmpty);
  });

  test('reasoning-only persisted alias is authoritative', () async {
    server.messages.add({
      ...server.assistant(content: ''),
      'reasoning': {'content': 'Reasoned answer'},
    });
    final session = await send();
    expect(
      session.jsonPayload!['choices'][0]['message']['reasoning_content'],
      'Reasoned answer',
    );
    expect(server.inferencePosts, isEmpty);
  });

  for (final output in <Map<String, dynamic>>[
    {'reasoning': 'Final reasoning'},
    {'reasoning': {'content': 'Final reasoning'}},
    {'reasoning_content': 'Final reasoning'},
    {'tools': [{'id': 'tool-1', 'type': 'function'}]},
  ]) {
    test('final nontext output shares completion contract: $output', () async {
      final assistant = {
        ...server.assistant(content: ''),
        ...output,
        'metadata': {
          'conduitClientId': 'local_assistant',
          'operationId': 'operation-1', 'finishType': 'stop',
        },
      };
      expect(lobeHubAssistantResultComplete(assistant), true);
      expect(lobeHubAssistantResultComplete({
        ...assistant, 'done': false,
      }), false);
      server.messages.addAll([
        {'id': 'server_user', 'role': 'user', 'content': 'Hello'},
        assistant,
      ]);
      final result = await api.reconcileAgentTurn(LobeAgentCorrelation(
        topicId: 'tpc_verified', agentId: 'agt_verified', userText: 'Hello',
        userLocalId: 'local_user', assistantLocalId: 'local_assistant',
        snapshotServerIds: {}, createdAt: DateTime.now(),
      ));
      expect(result.success, true);
      expect(server.patches, 2);
      final session = await send();
      expect(session.jsonPayload!['choices'][0]['finish_reason'], 'stop');
      final message = session.jsonPayload!['choices'][0]['message'];
      if (output.containsKey('tools')) {
        expect(message['tool_calls'], output['tools']);
      } else {
        expect(message['reasoning_content'], 'Final reasoning');
      }
      expect(server.inferencePosts, isEmpty);
    });
  }

  test('interrupted persisted row can become final without inference replay', () async {
    final assistant = {
      ...server.assistant(content: 'Partial answer'),
      'metadata': {'operationId': 'operation-1', 'interruptedMidStream': true},
    };
    server.messages.addAll([
      {'id': 'server_user', 'role': 'user', 'content': 'Hello'},
      assistant,
    ]);
    final correlation = LobeAgentCorrelation(
      topicId: 'tpc_verified', agentId: 'agt_verified', userText: 'Hello',
      userLocalId: 'local_user', assistantLocalId: 'local_assistant',
      snapshotServerIds: {}, createdAt: DateTime.now(),
    );
    expect((await api.reconcileAgentTurn(correlation)).success, false);
    expect(server.patches, 0);
    assistant['content'] = 'Canonical final answer';
    assistant['metadata'] = {'operationId': 'operation-1', 'finishType': 'stop'};
    expect((await api.reconcileAgentTurn(correlation)).success, true);
    expect(server.patches, 2);
    final session = await send();
    expect(session.jsonPayload!['choices'][0]['message']['content'],
        'Canonical final answer');
    expect(server.inferencePosts, isEmpty);
  });

  test('persisted error is visible, never completed or redispatched', () async {
    server.messages.add({
      ...server.assistant(content: ''),
      'error': {'message': 'Quota'},
    });
    await expectLater(send(), throwsA(isA<SyncTerminalException>()));
    expect(server.inferencePosts, isEmpty);
  });

  test(
    'raw topic uses stateless chat and persists its actual result',
    () async {
      server.topicAgent = null;
      final session = await send(agent: null);
      expect(
        session.jsonPayload!['choices'][0]['message']['content'],
        'Raw reply',
      );
      expect(server.responsePayload, {
        'model': 'gpt-4o',
        'provider': 'openai',
        'stream': false,
        'messages': [
          {'role': 'user', 'content': 'Hello'},
        ],
      });
      expect(server.messageCreates, 2);
    },
  );

  for (final body in <Object>[
    {'success': false, 'error': 'Rejected'},
    <String, Object>{},
    {
      'success': true,
      'data': {'content': ''},
    },
    {'success': true, 'data': {'content': 'Partial', 'done': false}},
    {'success': true, 'data': {'content': 'Partial', 'metadata': {'interruptedMidStream': true}}},
    {'success': true, 'data': {'content': 'Partial', 'metadata': {'finishType': 'length'}}},
    'not JSON',
  ]) {
    test('raw HTTP 200 cannot fake success: $body', () async {
      server.topicAgent = null;
      server.rawBody = body;
      await expectLater(
        send(agent: null),
        throwsA(isA<SyncTerminalException>()),
      );
      expect(server.messageCreates, 0);
    });
  }

  for (final terminal in <String>[
    'event: response.completed\ndata: {"response":{"status":"failed"}}\n\n',
    'event: response.failed\ndata: {"response":{"error":"failed"}}\n\n',
    'event: response.incomplete\ndata: {"response":{"status":"incomplete"}}\n\n',
    'event: response.completed\ndata: {"response":{"status":"incomplete"}}\n\n',
    'event: response.completed\ndata: {"response":{"status":"completed","output":[]}}\n\n',
    'event: response.output_text.delta\ndata: {"delta":"partial"}\n\n',
    'data: [DONE]\n\n',
    'data: {"success":false,"error":"rejected"}\n\n',
    'event: response.completed\ndata: {"response":{"status":"failed"}}',
  ]) {
    test('non-success terminal or EOF is an error: $terminal', () async {
      server.frames = terminal;
      final session = await send();
      await expectLater(
        session.byteStream!.toList(),
        throwsA(isA<SyncTerminalException>()),
      );
      expect(server.patches, 0);
    });
  }

  test('normal completion reports reconciliation failure', () async {
    server.persistPair = false;
    final session = await send();
    await expectLater(
      session.byteStream!.toList(),
      throwsA(isA<SyncTerminalException>()),
    );
  });

  test(
    'real POST Responses named SSE succeeds with persisted assistant retrieval',
    () async {
      final session = await send();
      final updates = await parseOpenWebUIStream(session.byteStream!).toList();
      expect(updates.whereType<OpenWebUIStreamDone>(), hasLength(1));
      final finalEvent = updates.whereType<OpenWebUIResponseStreamEvent>().last;
      expect(finalEvent.event['response']['status'], 'completed');
      expect(server.inferencePosts, ['/api/v1/responses']);
      expect(server.responsePayload, {
        'model': 'agt_verified',
        'previous_response_id': 'tpc_verified',
        'stream': true,
        'input': 'Hello',
      });
      final retrieved = await fetchAllLobeHubMessages(
        api.dio,
        topicId: 'tpc_verified',
      );
      expect(
        retrieved.where((m) => m['role'] == 'assistant').single['content'],
        'Hello back',
      );
      expect(server.messages.last['metadata'], {
        'conduitClientId': 'local_assistant',
      });
      expect(server.patches, 2);
      expect(server.messageCreates, 0);
    },
  );
}

class _LocalBoundaryServer {
  _LocalBoundaryServer(this.http);
  final HttpServer http;
  late final StreamSubscription<HttpRequest> subscription;
  String? topicAgent = 'agt_verified';
  Map<String, dynamic> topicFields = {};
  int topicStatus = 200;
  int messageStatus = 200;
  bool persistPair = true;
  Object rawBody = const {
    'success': true,
    'data': {'content': 'Raw reply'},
  };
  String frames =
      'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"Hello back","output_index":0}\n\n'
      'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","output_text":"Hello back","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello back"}]}]}}\n\n';
  final List<Map<String, dynamic>> messages = [];
  final List<String> inferencePosts = [];
  Map<String, dynamic>? responsePayload;
  int patches = 0;
  int messageCreates = 0;

  Map<String, dynamic> assistant({required String content}) => {
    'id': 'server_assistant',
    'role': 'assistant',
    'content': content,
    'parentId': 'server_user',
    'model': 'gpt-4o',
    'provider': 'openai',
    'metadata': {'conduitClientId': 'local_assistant'},
  };

  static Future<_LocalBoundaryServer> start() async {
    final server = _LocalBoundaryServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server.subscription = server.http.listen(server.handle);
    return server;
  }

  Future<void> handle(HttpRequest request) async {
    final path = request.uri.path;
    Object body;
    if (request.method == 'GET' && path == '/api/v1/topics/tpc_verified') {
      request.response.statusCode = topicStatus;
      body = {
        'success': topicStatus == 200,
        'data': {'id': 'tpc_verified', 'agentId': topicAgent, ...topicFields},
      };
    } else if (request.method == 'GET' &&
        path == '/api/v1/agents/agt_verified') {
      body = {
        'success': true,
        'data': {'id': 'agt_verified', 'model': 'gpt-4o', 'provider': 'openai'},
      };
    } else if (request.method == 'GET' && path == '/api/v1/messages') {
      request.response.statusCode = messageStatus;
      body = {
        'success': messageStatus == 200,
        'data': {'messages': messages},
      };
    } else if (request.method == 'POST' && path == '/api/v1/responses') {
      inferencePosts.add(path);
      responsePayload = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      if (persistPair) {
        messages.add({'id': 'server_user', 'role': 'user', 'content': 'Hello'});
        messages.add({
          ...assistant(content: 'Hello back'),
          'metadata': <String, dynamic>{},
        });
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(frames);
      await request.response.close();
      return;
    } else if (request.method == 'POST' && path == '/api/v1/chat') {
      inferencePosts.add(path);
      responsePayload = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      body = rawBody;
    } else if (request.method == 'PATCH' &&
        path.startsWith('/api/v1/messages/')) {
      patches++;
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      messages.singleWhere((m) => path.endsWith('/${m['id']}'))['metadata'] =
          payload['metadata'];
      body = {'success': true};
    } else if (request.method == 'POST' && path == '/api/v1/messages') {
      messageCreates++;
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      final message = {...payload, 'id': 'server_created_$messageCreates'};
      messages.add(message);
      body = {'success': true, 'data': message};
    } else {
      request.response.statusCode = 500;
      body = {'error': 'Unexpected ${request.method} $path'};
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(body is String ? body : jsonEncode(body));
    await request.response.close();
  }

  Future<void> close() async {
    await http.close(force: true);
    await subscription.cancel();
  }
}

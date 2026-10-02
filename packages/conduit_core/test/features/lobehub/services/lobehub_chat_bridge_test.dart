import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_chat_bridge.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_stream_parser.dart';
import 'package:conduit_core/models/chat_message.dart';

/// In-memory mock adapter for Dio network testing.
class MockHttpClientAdapter implements HttpClientAdapter {
  MockHttpClientAdapter({this.handler});

  FutureOr<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )? handler;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (handler != null) {
      return handler!(options, cancelFuture);
    }
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(
  dynamic data, {
  int statusCode = 200,
}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

ResponseBody sseResponse(String sseText, {int statusCode = 200}) {
  return ResponseBody.fromString(
    sseText,
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
}

(LobeHubChatBridge, MockHttpClientAdapter, LobeHubApiClient) createTestBridge({
  String baseUrl = 'https://ai.opw.ink',
  FutureOr<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )? handler,
}) {
  final adapter = MockHttpClientAdapter(handler: handler);
  final dio = Dio()..httpClientAdapter = adapter;
  final client = LobeHubApiClient(
    baseUrl: baseUrl,
    apiKey: 'test-key-123',
    dio: dio,
  );
  final bridge = LobeHubChatBridge(apiClient: client);
  return (bridge, adapter, client);
}

void main() {
  group('LobeHubChatBridge', () {
    test('full happy path lifecycle (POST user -> POST responses -> POST assistant)', () async {
      int messageCreateCount = 0;
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            messageCreateCount++;
            final data = options.data as Map<String, dynamic>;
            final role = data['role'];
            return jsonResponse({
              'id': 'msg_${role}_$messageCreateCount',
              'role': role,
              'content': data['content'],
              'topicId': data['topicId'],
              'model': data['model'],
              'reasoning': data['reasoning'],
              'createdAt': '2026-10-03T12:00:00.000Z',
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            const sseBody =
                'event: text\n'
                'data: "Hello "\n\n'
                'event: text\n'
                'data: "world!"\n\n'
                'event: stop\n'
                'data: {"finish_reason":"stop"}\n\n';
            return sseResponse(sseBody);
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final collectedTextDeltas = <String>[];
      LobeMessage? persistedUser;
      LobeMessage? persistedAssistant;

      final events = await bridge.sendMessageStream(
        topicId: 'topic_123',
        content: 'Hi assistant',
        agentId: 'agent_456',
        model: 'gpt-4o',
        onTextDelta: (delta) => collectedTextDeltas.add(delta),
        onUserMessagePersisted: (msg) => persistedUser = msg,
        onAssistantMessagePersisted: (msg) => persistedAssistant = msg,
      ).toList();

      // 1. Verify stream events
      expect(events, [
        const LobeTextDelta('Hello '),
        const LobeTextDelta('world!'),
        const LobeStreamDone('stop'),
      ]);

      // 2. Verify callbacks and buffer accumulation
      expect(collectedTextDeltas, ['Hello ', 'world!']);
      expect(bridge.accumulatedText, 'Hello world!');
      expect(bridge.isGenerating, isFalse);

      // 3. Verify user message Phase 1
      expect(persistedUser, isNotNull);
      expect(persistedUser!.id, 'msg_user_1');
      expect(persistedUser!.role, 'user');
      expect(persistedUser!.content, 'Hi assistant');
      expect(bridge.lastUserMessage, equals(persistedUser));
      expect(bridge.lastUserChatMessage?.content, 'Hi assistant');

      // 4. Verify assistant message Phase 3
      expect(persistedAssistant, isNotNull);
      expect(persistedAssistant!.id, 'msg_assistant_2');
      expect(persistedAssistant!.role, 'assistant');
      expect(persistedAssistant!.content, 'Hello world!');
      expect(bridge.lastAssistantMessage, equals(persistedAssistant));
      expect(bridge.lastAssistantChatMessage?.content, 'Hello world!');

      // 5. Verify HTTP request sequence
      expect(adapter.requests.length, 3);
      // Request 0: POST /api/v1/messages (user)
      expect(adapter.requests[0].method, 'POST');
      expect(adapter.requests[0].path, endsWith('/api/v1/messages'));
      expect((adapter.requests[0].data as Map)['role'], 'user');
      expect((adapter.requests[0].data as Map)['content'], 'Hi assistant');
      expect((adapter.requests[0].data as Map)['topicId'], 'topic_123');
      expect((adapter.requests[0].data as Map)['agentId'], 'agent_456');

      // Request 1: POST /api/v1/responses (stream)
      expect(adapter.requests[1].method, 'POST');
      expect(adapter.requests[1].path, endsWith('/api/v1/responses'));
      final responsesData = adapter.requests[1].data as Map<String, dynamic>;
      expect(responsesData['model'], 'gpt-4o');
      expect(responsesData['stream'], isTrue);
      expect(responsesData['agentId'], 'agent_456');
      expect(responsesData['messages'], [
        {'role': 'user', 'content': 'Hi assistant'},
      ]);

      // Request 2: POST /api/v1/messages (assistant)
      expect(adapter.requests[2].method, 'POST');
      expect(adapter.requests[2].path, endsWith('/api/v1/messages'));
      expect((adapter.requests[2].data as Map)['role'], 'assistant');
      expect((adapter.requests[2].data as Map)['content'], 'Hello world!');
      expect((adapter.requests[2].data as Map)['topicId'], 'topic_123');
      expect((adapter.requests[2].data as Map)['model'], 'gpt-4o');
    });

    test('reasoning chain accumulation (DeepSeek R1 reasoning + text)', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}',
              'role': data['role'],
              'content': data['content'],
              'reasoning': data['reasoning'],
              'model': data['model'],
              'topicId': data['topicId'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            const sseBody =
                'event: reasoning\n'
                'data: "Thinking step 1..."\n\n'
                'event: reasoning\n'
                'data: " Step 2 confirmed."\n\n'
                'event: text\n'
                'data: "The final answer is 42."\n\n'
                'event: stop\n'
                'data: {"finish_reason":"stop"}\n\n';
            return sseResponse(sseBody);
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final reasoningDeltas = <String>[];
      final textDeltas = <String>[];

      final events = await bridge.sendMessageStream(
        topicId: 'topic_r1',
        content: 'Solve problem',
        model: 'deepseek-r1',
        onReasoningDelta: (r) => reasoningDeltas.add(r),
        onTextDelta: (t) => textDeltas.add(t),
      ).toList();

      expect(events, [
        const LobeReasoningDelta('Thinking step 1...'),
        const LobeReasoningDelta(' Step 2 confirmed.'),
        const LobeTextDelta('The final answer is 42.'),
        const LobeStreamDone('stop'),
      ]);

      expect(reasoningDeltas, ['Thinking step 1...', ' Step 2 confirmed.']);
      expect(textDeltas, ['The final answer is 42.']);
      expect(bridge.accumulatedReasoning, 'Thinking step 1... Step 2 confirmed.');
      expect(bridge.accumulatedText, 'The final answer is 42.');

      // Check assistant message persistence included reasoning
      final asstReq = adapter.requests.last;
      expect(asstReq.path, endsWith('/api/v1/messages'));
      expect((asstReq.data as Map)['reasoning'], 'Thinking step 1... Step 2 confirmed.');
      expect((asstReq.data as Map)['content'], 'The final answer is 42.');
      expect((asstReq.data as Map)['model'], 'deepseek-r1');
    });

    test('mid-stream cancellation with CancelToken persists partial assistant message and stops gracefully', () async {
      late StreamController<Uint8List> streamController;
      final cancelToken = CancelToken();

      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}_partial',
              'role': data['role'],
              'content': data['content'],
              'reasoning': data['reasoning'],
              'topicId': data['topicId'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            streamController = StreamController<Uint8List>();

            cancelFuture?.then((_) {
              if (!streamController.isClosed) {
                streamController.addError(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.cancel,
                    message: 'Generation aborted by user',
                  ),
                );
                streamController.close();
              }
            });

            return ResponseBody(
              streamController.stream,
              200,
              headers: {
                Headers.contentTypeHeader: ['text/event-stream'],
              },
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final receivedEvents = <LobeStreamEvent>[];
      final completer = Completer<void>();

      bridge.sendMessageStream(
        topicId: 'topic_cancel',
        content: 'Long prompt',
        cancelToken: cancelToken,
      ).listen(
        (event) {
          receivedEvents.add(event);
          if (event is LobeTextDelta && event.text == 'Part 1 ') {
            // Cancel immediately upon receiving Part 1
            cancelToken.cancel('User clicked stop');
          }
        },
        onDone: () => completer.complete(),
        onError: (e) => completer.completeError(e),
      );

      // Feed initial reasoning and text chunk
      await Future<void>.delayed(const Duration(milliseconds: 10));
      streamController.add(
        Uint8List.fromList(
          utf8.encode(
            'event: reasoning\n'
            'data: "Thinking partially..."\n\n'
            'event: text\n'
            'data: "Part 1 "\n\n',
          ),
        ),
      );

      await completer.future;

      // 1. Verify events end with LobeStreamDone('cancelled')
      expect(receivedEvents, [
        const LobeReasoningDelta('Thinking partially...'),
        const LobeTextDelta('Part 1 '),
        const LobeStreamDone('cancelled'),
      ]);

      // 2. Verify state is not generating
      expect(bridge.isGenerating, isFalse);
      expect(bridge.accumulatedText, 'Part 1 ');
      expect(bridge.accumulatedReasoning, 'Thinking partially...');

      // 3. Verify partial assistant message was persisted
      expect(bridge.lastAssistantMessage, isNotNull);
      expect(bridge.lastAssistantMessage!.content, 'Part 1 ');
      expect(bridge.lastAssistantMessage!.reasoning, 'Thinking partially...');

      // 4. Verify HTTP requests: User message -> Responses -> Assistant partial
      expect(adapter.requests.length, 3);
      final partialMsgReq = adapter.requests[2];
      expect(partialMsgReq.path, endsWith('/api/v1/messages'));
      expect((partialMsgReq.data as Map)['role'], 'assistant');
      expect((partialMsgReq.data as Map)['content'], 'Part 1 ');
      expect((partialMsgReq.data as Map)['reasoning'], 'Thinking partially...');
    });

    test('mid-stream cancellation via bridge.cancelGeneration() works gracefully', () async {
      late StreamController<Uint8List> streamController;

      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}',
              'role': data['role'],
              'content': data['content'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            streamController = StreamController<Uint8List>();

            cancelFuture?.then((_) {
              if (!streamController.isClosed) {
                streamController.addError(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.cancel,
                    message: 'Bridge cancel',
                  ),
                );
                streamController.close();
              }
            });

            return ResponseBody(
              streamController.stream,
              200,
              headers: {
                Headers.contentTypeHeader: ['text/event-stream'],
              },
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final receivedEvents = <LobeStreamEvent>[];
      final completer = Completer<void>();

      bridge.sendMessageStream(
        topicId: 'topic_bridge_cancel',
        content: 'Tell me a story',
      ).listen(
        (event) {
          receivedEvents.add(event);
          if (event is LobeTextDelta && event.text == 'Once upon ') {
            bridge.cancelGeneration('Stopped by user via button');
          }
        },
        onDone: () => completer.complete(),
        onError: (e) => completer.completeError(e),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      streamController.add(
        Uint8List.fromList(
          utf8.encode(
            'event: text\n'
            'data: "Once upon "\n\n',
          ),
        ),
      );

      await completer.future;

      expect(receivedEvents, [
        const LobeTextDelta('Once upon '),
        const LobeStreamDone('cancelled'),
      ]);
      expect(bridge.accumulatedText, 'Once upon ');
      expect(bridge.isGenerating, isFalse);
    });

    test('network error during responses stream cleans up and surfaces informative exception', () async {
      late StreamController<Uint8List> streamController;

      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            return jsonResponse({
              'id': 'msg_user',
              'role': 'user',
              'content': 'hello',
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            streamController = StreamController<Uint8List>();
            return ResponseBody(
              streamController.stream,
              200,
              headers: {
                Headers.contentTypeHeader: ['text/event-stream'],
              },
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final eventsStream = bridge.sendMessageStream(
        topicId: 'topic_err',
        content: 'hello',
      );

      final completer = Completer<void>();
      Object? caughtError;

      eventsStream.listen(
        (event) {},
        onError: (e) {
          caughtError = e;
          completer.complete();
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Inject connection drop error
      streamController.addError(
        DioException(
          requestOptions: RequestOptions(path: '/api/v1/responses'),
          type: DioExceptionType.connectionError,
          message: 'Connection closed prematurely by peer',
        ),
      );

      await completer.future;

      expect(caughtError, isA<LobeHubException>());
      expect(
        (caughtError as LobeHubException).toString(),
        contains('Connection closed prematurely by peer'),
      );
      expect(bridge.isGenerating, isFalse);
    });

    test('server 500 error on /api/v1/responses throws LobeHubServerException', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            return jsonResponse({
              'id': 'msg_user',
              'role': 'user',
              'content': 'hi',
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            return jsonResponse(
              {'message': 'Internal inference engine failure'},
              statusCode: 500,
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      expect(
        () => bridge.sendMessageStream(
          topicId: 't500',
          content: 'hi',
        ).toList(),
        throwsA(
          isA<LobeHubServerException>()
              .having((e) => e.statusCode, 'statusCode', equals(500)),
        ),
      );
    });

    test('convenience helper sendMessage returns final assistant LobeMessage', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}',
              'role': data['role'],
              'content': data['content'],
              'model': data['model'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            return sseResponse(
              'event: text\n'
              'data: "Final answer"\n\n'
              'event: stop\n'
              'data: [DONE]\n\n',
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final result = await bridge.sendMessage(
        topicId: 't_conv',
        content: 'Question?',
        model: 'gpt-4o-mini',
      );

      expect(result.role, 'assistant');
      expect(result.content, 'Final answer');
      expect(result.model, 'gpt-4o-mini');
      expect(bridge.lastAssistantMessage, equals(result));
    });

    test('convenience helper sendChatMessage works with ChatMessage model', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}',
              'role': data['role'],
              'content': data['content'],
              'model': data['model'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            return sseResponse(
              'event: text\n'
              'data: "ChatMessage answer"\n\n'
              'event: stop\n'
              'data: {"finish_reason":"stop"}\n\n',
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final priorMessages = [
        ChatMessage(
          id: 'prev_1',
          role: 'user',
          content: 'Prior user turn',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: 'prev_2',
          role: 'assistant',
          content: 'Prior assistant turn',
          timestamp: DateTime.now(),
        ),
      ];

      final chatMsg = await bridge.sendChatMessage(
        topicId: 't_chat_msg',
        content: 'Next turn',
        history: priorMessages,
        model: 'claude-3-5-sonnet',
      );

      expect(chatMsg.role, 'assistant');
      expect(chatMsg.content, 'ChatMessage answer');
      expect(chatMsg.model, 'claude-3-5-sonnet');

      // Verify responses payload included history
      final responsesReq = adapter.requests.firstWhere(
        (r) => r.path.endsWith('/api/v1/responses'),
      );
      final messages = (responsesReq.data as Map)['messages'] as List;
      expect(messages.length, 3);
      expect(messages[0], {'role': 'user', 'content': 'Prior user turn'});
      expect(messages[1], {'role': 'assistant', 'content': 'Prior assistant turn'});
      expect(messages[2], {'role': 'user', 'content': 'Next turn'});
    });

    test('persistUserMessage and persistAssistantMessage can be disabled', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/responses')) {
            return sseResponse(
              'event: text\n'
              'data: "Transient response"\n\n'
              'event: stop\n'
              'data: {"finish_reason":"stop"}\n\n',
            );
          }
          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final events = await bridge.sendMessageStream(
        topicId: 't_transient',
        content: 'No persist please',
        persistUserMessage: false,
        persistAssistantMessage: false,
      ).toList();

      expect(events, [
        const LobeTextDelta('Transient response'),
        const LobeStreamDone('stop'),
      ]);

      // Only /api/v1/responses was called, NO /api/v1/messages
      expect(adapter.requests.length, 1);
      expect(adapter.requests[0].path, endsWith('/api/v1/responses'));
      expect(bridge.lastUserMessage?.content, 'No persist please');
      expect(bridge.lastAssistantMessage?.content, 'Transient response');
    });

    test('stream terminating without explicit stop event defaults to LobeStreamDone and persists', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}',
              'role': data['role'],
              'content': data['content'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            // Emits text chunks and closes connection without event: stop
            return sseResponse(
              'event: text\n'
              'data: "Finished without stop"\n\n',
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final events = await bridge.sendMessageStream(
        topicId: 't_nostop',
        content: 'Testing no stop',
      ).toList();

      expect(events, [
        const LobeTextDelta('Finished without stop'),
        const LobeStreamDone('stop'),
      ]);
      expect(bridge.accumulatedText, 'Finished without stop');
      expect(bridge.lastAssistantMessage?.content, 'Finished without stop');
    });

    test('tool call delta accumulation and persistence', () async {
      final (bridge, adapter, client) = createTestBridge(
        handler: (options, cancelFuture) {
          if (options.path.endsWith('/api/v1/messages')) {
            final data = options.data as Map<String, dynamic>;
            return jsonResponse({
              'id': 'msg_${data['role']}',
              'role': data['role'],
              'content': data['content'],
              'tools': data['tools'],
            });
          }

          if (options.path.endsWith('/api/v1/responses')) {
            return sseResponse(
              'event: tool_calls\n'
              'data: [{"id":"call_abc","type":"function","function":{"name":"weather","arguments":"{\\"city\\":\\"Paris\\"}"}}]\n\n'
              'event: stop\n'
              'data: {"finish_reason":"tool_calls"}\n\n',
            );
          }

          return jsonResponse({});
        },
      );
      addTearDown(client.close);

      final collectedTools = <Map<String, dynamic>>[];

      final events = await bridge.sendMessageStream(
        topicId: 't_tools',
        content: 'What is the weather in Paris?',
        onToolCallDelta: (tool) => collectedTools.add(tool),
      ).toList();

      expect(events, [
        const LobeToolCallDelta({
          'id': 'call_abc',
          'type': 'function',
          'function': {'name': 'weather', 'arguments': '{"city":"Paris"}'},
        }),
        const LobeStreamDone('tool_calls'),
      ]);

      expect(collectedTools.length, 1);
      expect(collectedTools[0]['id'], 'call_abc');
      expect(bridge.accumulatedTools.length, 1);
      expect(bridge.accumulatedTools[0]['id'], 'call_abc');

      final lastReq = adapter.requests.last;
      expect(lastReq.path, endsWith('/api/v1/messages'));
      expect((lastReq.data as Map)['role'], 'assistant');
      expect((lastReq.data as Map)['tools'], isNotEmpty);
    });
  });
}

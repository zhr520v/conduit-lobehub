import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('LobeHub Chat Transport (/api/v1/chat and /api/v1/responses)', () {
    late _MockHttpClientAdapter adapter;
    late ApiService lobeApi;

    setUp(() {
      adapter = _MockHttpClientAdapter();
      lobeApi = ApiService(
        serverConfig: const ServerConfig(
          id: 'lobehub_self_hosted',
          name: 'LobeHub Test',
          url: 'http://localhost:3210',
        ),
        workerManager: WorkerManager(),
      );
      lobeApi.dio.httpClientAdapter = adapter;
      lobeApi.dio.interceptors.clear();
      for (final topic in <String, String?>{
        'tpc_100': null,
        'tpc_agent_chat': 'agt_coder',
        'tpc_snapshot_fault': 'agt_coder',
        'tpc_persist_fault': null,
        'tpc_existing_alias': null,
        'tpc_fail': 'agt_fail',
      }.entries) {
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/topics/${topic.key}',
          handler: (_) => _jsonResponse({
            'success': true,
            'data': {'id': topic.key, 'agentId': topic.value},
          }),
        );
      }
    });

    test('Rejects multipart/file inference with typed SyncTerminalException 400 before inference POST', () async {
      // 1. Files parameter non-empty
      await check(
        lobeApi.sendMessageSession(
          messages: [
            {'role': 'user', 'content': 'Hello'},
          ],
          model: 'gpt-4o',
          files: [
            {'id': 'f1', 'name': 'pic.png'},
          ],
        ),
      ).throws<SyncTerminalException>();

      // 2. UserMessage has files
      await check(
        lobeApi.sendMessageSession(
          messages: [
            {'role': 'user', 'content': 'Hello'},
          ],
          model: 'gpt-4o',
          userMessage: {
            'role': 'user',
            'content': 'Hello',
            'files': ['f1'],
          },
        ),
      ).throws<SyncTerminalException>();

      // 3. Message contains attachment_ids
      await check(
        lobeApi.sendMessageSession(
          messages: [
            {
              'role': 'user',
              'content': 'Hello',
              'attachment_ids': ['att_1'],
            },
          ],
          model: 'gpt-4o',
        ),
      ).throws<SyncTerminalException>();

      // Verify zero inference requests were made
      check(adapter.requests).isEmpty();
    });

    test('Ordinary models use POST /api/v1/chat with real provider/model and full string history', () async {
      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/chat',
        handler: (options) {
          final body = options.data as Map<String, dynamic>;
          check(body['model']).equals('claude-3-5-sonnet');
          check(body['provider']).equals('anthropic');
          check(body.containsKey('topicId')).isFalse();
          check(body['stream']).equals(false);

          final msgs = body['messages'] as List;
          // Empty placeholder messages must be skipped
          check(msgs.length).equals(2);
          check(msgs[0]['role']).equals('system');
          check(msgs[0]['content']).equals('You are helpful');
          check(msgs[1]['role']).equals('user');
          check(msgs[1]['content']).equals('What is Dart?');

          return _jsonResponse({
            'success': true,
            'data': {
              'content': 'Dart is a modern language.',
              'reasoning': 'Thinking about Dart architecture...',
              'usage': {'total_tokens': 42},
            },
          });
        },
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {'messages': []},
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/messages',
        handler: (options) {
          final data = options.data as Map<String, dynamic>;
          check(data['topicId']).equals('tpc_100');
          return _jsonResponse({'id': 'msg_server_1'});
        },
      );

      final session = await lobeApi.sendMessageSession(
        messages: [
          {'role': 'system', 'content': 'You are helpful'},
          {'role': 'assistant', 'content': ''}, // empty placeholder to skip
          {'role': 'user', 'content': 'What is Dart?'},
        ],
        model: 'anthropic/claude-3-5-sonnet',
        conversationId: 'tpc_100',
        responseMessageId: 'resp_asst_1',
        userMessage: {'id': 'user_local_1', 'content': 'What is Dart?'},
      );

      check(session.transport).equals(ChatCompletionTransport.jsonCompletion);
      check(session.messageId).equals('resp_asst_1');
      check(session.jsonPayload).isNotNull();

      final choices = session.jsonPayload!['choices'] as List;
      check(choices.length).equals(1);
      final msg = choices[0]['message'] as Map;
      check(msg['role']).equals('assistant');
      check(msg['content']).equals('Dart is a modern language.');
      check(msg['reasoning_content'])
          .equals('Thinking about Dart architecture...');
      check(session.jsonPayload!['usage']?['total_tokens']).equals(42);

      // Verify POST /api/v1/chat was called
      check(adapter.requestedPaths).contains('/api/v1/chat');
    });

    for (final existing in [false, true]) {
      for (final wrapped in [false, true]) {
        test(
          'raw assistant uses verified server parent existing=$existing wrapped=$wrapped',
          () async {
            adapter.registerHandler(
              method: 'GET',
              path: '/api/v1/messages',
              handler: (_) => _jsonResponse({
                'data': {
                  'messages': [
                    {
                      'id': 'server-older',
                      'role': 'assistant',
                      'metadata': {'conduitClientId': 'older-local'},
                    },
                    if (existing)
                      {
                        'id': 'server-user',
                        'role': 'user',
                        'metadata': {'conduitClientId': 'user-local'},
                      },
                  ],
                },
              }),
            );
            adapter.registerHandler(
              method: 'POST',
              path: '/api/v1/chat',
              handler: (_) => _jsonResponse({
                'success': true,
                'data': {'content': 'Reply'},
              }),
            );
            final writes = <Map<String, dynamic>>[];
            adapter.registerHandler(
              method: 'POST',
              path: '/api/v1/messages',
              handler: (options) {
                final body = options.data as Map<String, dynamic>;
                writes.add(body);
                if (body['role'] == 'user') {
                  expect(body['parentId'], 'server-older');
                  expect(body['metadata'], {
                    'retained': true,
                    'conduitClientId': 'user-local',
                  });
                } else {
                  expect(body['parentId'], 'server-user');
                  expect(
                    body['metadata']['conduitClientId'],
                    'assistant-local',
                  );
                }
                final data = {
                  'id': body['role'] == 'user'
                      ? 'server-user'
                      : 'server-assistant',
                };
                return _jsonResponse(
                  wrapped ? {'success': true, 'data': data} : data,
                );
              },
            );
            await lobeApi.sendMessageSession(
              messages: const [
                {'role': 'user', 'content': 'Prompt'},
              ],
              model: 'gpt-4o',
              conversationId: 'tpc_100',
              responseMessageId: 'assistant-local',
              userMessage: const {
                'id': 'user-local',
                'content': 'Prompt',
                'parentId': 'older-local',
                'metadata': {'retained': true},
              },
            );
            expect(writes.length, existing ? 1 : 2);
            expect(
              adapter.requests.where((r) => r.path == '/api/v1/chat').length,
              1,
            );
          },
        );
      }
    }

    test(
      'raw existing user alias without a server ID is not recreated',
      () async {
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/messages',
          handler: (_) => _jsonResponse({
            'data': {
              'messages': [
                {
                  'role': 'user',
                  'metadata': {'conduitClientId': 'user-local'},
                },
              ],
            },
          }),
        );
        adapter.registerHandler(
          method: 'POST',
          path: '/api/v1/chat',
          handler: (_) => _jsonResponse({
            'success': true,
            'data': {'content': 'Reply'},
          }),
        );
        await expectLater(
          lobeApi.sendMessageSession(
            messages: const [
              {'role': 'user', 'content': 'Prompt'},
            ],
            model: 'gpt-4o',
            conversationId: 'tpc_100',
            userMessage: const {'id': 'user-local', 'content': 'Prompt'},
          ),
          throwsA(isA<SyncTerminalException>()),
        );
        expect(
          adapter.requests.where(
            (r) => r.method == 'POST' && r.path == '/api/v1/messages',
          ),
          isEmpty,
        );
      },
    );

    for (final role in ['user', 'assistant']) {
      for (final acknowledgement in <Object?>[
        null,
        {},
        {
          'success': false,
          'data': {'id': 'server-message'},
        },
        {
          'success': true,
          'data': {'id': ''},
        },
        {
          'success': true,
          'data': {'id': 42},
        },
        {
          'success': true,
          'data': {'id': 'local:fake'},
        },
        {
          'success': true,
          'data': {'id': '   '},
        },
      ]) {
        test(
          'raw $role requires valid persistence acknowledgement $acknowledgement',
          () async {
            adapter.registerHandler(
              method: 'GET',
              path: '/api/v1/messages',
              handler: (_) => _jsonResponse({
                'data': {'messages': []},
              }),
            );
            adapter.registerHandler(
              method: 'POST',
              path: '/api/v1/chat',
              handler: (_) => _jsonResponse({
                'success': true,
                'data': {'content': 'Reply'},
              }),
            );
            adapter.registerHandler(
              method: 'POST',
              path: '/api/v1/messages',
              handler: (options) => _jsonResponse(
                (options.data as Map)['role'] == role
                    ? acknowledgement
                    : {
                        'success': true,
                        'data': {'id': 'server-user'},
                      },
              ),
            );
            await expectLater(
              lobeApi.sendMessageSession(
                messages: const [
                  {'role': 'user', 'content': 'Prompt'},
                ],
                model: 'gpt-4o',
                conversationId: 'tpc_100',
                userMessage: const {'id': 'user-local', 'content': 'Prompt'},
              ),
              throwsA(isA<SyncTerminalException>()),
            );
            if (role == 'user') {
              expect(
                adapter.requests
                    .where(
                      (r) => r.path == '/api/v1/messages' && r.method == 'POST',
                    )
                    .length,
                1,
              );
            }
          },
        );
      }
    }

    test('Agent turn with explicit lobeAgentId uses POST /api/v1/responses with exactAgentID notLLM and string input', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/agents/agt_coder',
        handler: (_) => _jsonResponse({
          'data': {
            'id': 'agt_coder',
            'model': 'gpt-4o', // Underlying LLM
            'provider': 'openai',
          },
        }),
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {
            'messages': [
              {
                'id': 'srv_msg_init',
                'role': 'user',
                'content': 'initial prompt',
                'metadata': {'conduitClientId': 'c_init'},
              },
            ],
          },
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/responses',
        handler: (options) {
          final data = options.data as Map<String, dynamic>;
          // Server-contract regression assertion: exactAgentID, NOT underlying LLM!
          check(data['model']).equals('agt_coder');
          check(data['model']).not((m) => m.equals('gpt-4o'));
          check(data.containsKey('agentId')).isFalse();
          check(data.containsKey('provider')).isFalse();
          check(data['previous_response_id']).equals('tpc_agent_chat');
          // input must be current user text string per contract
          check(data['input']).equals('Write some code');
          check(data['instructions']).equals('You are an expert coder');

          return _sseResponse([
            'event: response.output_text.delta\ndata: {"delta":"Sure, here is code."}\n\n',
            'event: response.completed\ndata: {"response":{"status":"completed","output_text":"Sure, here is code."}}\n\n',
          ]);
        },
      );

      adapter.registerHandler(
        method: 'PATCH',
        path: '/api/v1/messages/srv_user_2',
        handler: (_) => _jsonResponse({'success': true}),
      );
      adapter.registerHandler(
        method: 'PATCH',
        path: '/api/v1/messages/srv_asst_2',
        handler: (_) => _jsonResponse({'success': true}),
      );

      LobeAgentCorrelation? preDispatchCorrelation;

      final session = await lobeApi.sendMessageSession(
        messages: [
          {'role': 'system', 'content': 'You are an expert coder'},
          {'role': 'user', 'content': 'Write some code'},
        ],
        model: 'gpt-4o',
        conversationId: 'tpc_agent_chat',
        lobeAgentId: 'agt_coder',
        responseMessageId: 'asst_local_id',
        userMessage: {'id': 'user_local_id', 'content': 'Write some code'},
        onPreDispatch: (correlation) async {
          preDispatchCorrelation = correlation;
        },
      );

      check(session.transport).equals(ChatCompletionTransport.httpStream);
      check(session.messageId).equals('asst_local_id');

      // Verify correlation was snapshotted
      check(preDispatchCorrelation).isNotNull();
      check(preDispatchCorrelation!.agentId).equals('agt_coder');
      check(preDispatchCorrelation!.topicId).equals('tpc_agent_chat');
      check(preDispatchCorrelation!.userText).equals('Write some code');
      check(preDispatchCorrelation!.userLocalId).equals('user_local_id');
      check(preDispatchCorrelation!.assistantLocalId).equals('asst_local_id');
      check(preDispatchCorrelation!.snapshotServerIds.contains('srv_msg_init'))
          .isTrue();

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {
            'messages': [
              {
                'id': 'srv_msg_init',
                'role': 'user',
                'content': 'initial prompt',
              },
              {
                'id': 'srv_user_2',
                'role': 'user',
                'content': 'Write some code',
              },
              {
                'id': 'srv_asst_2',
                'role': 'assistant',
                'content': 'Sure, here is code.',
                'parentId': 'srv_user_2',
                'model': 'gpt-4o',
                'provider': 'openai',
              },
            ],
          },
        }),
      );
      // Read stream
      final events = <String>[];
      await for (final chunk in session.byteStream!) {
        events.add(utf8.decode(chunk));
      }
      check(events.isNotEmpty).isTrue();
    });

    test('Agent turn rejects raw model mismatch with typed SyncTerminalException 400', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {'messages': []},
        }),
      );
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/agents/agt_coder',
        handler: (_) => _jsonResponse({
          'data': {'id': 'agt_coder', 'model': 'gpt-4o', 'provider': 'openai'},
        }),
      );

      await check(
        lobeApi.sendMessageSession(
          messages: [
            {'role': 'user', 'content': 'Hello'},
          ],
          model: 'claude-3-opus', // does NOT match configured gpt-4o
          conversationId: 'tpc_agent_chat',
          lobeAgentId: 'agt_coder',
        ),
      ).throws<SyncTerminalException>();
    });

    for (final path in [
      '/api/v1/topics/tpc_agent_chat',
      '/api/v1/agents/agt_coder',
    ]) {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        test('preflight preserves $type from $path without dispatch', () async {
          adapter.registerHandler(
            method: 'GET',
            path: '/api/v1/messages',
            handler: (_) => _jsonResponse({
              'data': {'messages': []},
            }),
          );
          DioException? failure;
          adapter.registerHandler(
            method: 'GET',
            path: path,
            handler: (options) {
              failure = DioException(requestOptions: options, type: type);
              throw failure!;
            },
          );
          await expectLater(
            lobeApi.sendMessageSession(
              messages: const [
                {'role': 'user', 'content': 'Hello'},
              ],
              model: 'gpt-4o',
              conversationId: 'tpc_agent_chat',
              lobeAgentId: 'agt_coder',
            ),
            throwsA(isA<DioException>().having((e) => e.type, 'type', type)),
          );
          expect(failure, isNotNull);
          expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
        });
      }
      for (final status in [404, 500, 503]) {
        test(
          'preflight classifies HTTP $status from $path without dispatch',
          () async {
            adapter.registerHandler(
              method: 'GET',
              path: '/api/v1/messages',
              handler: (_) => _jsonResponse({
                'data': {'messages': []},
              }),
            );
            adapter.registerHandler(
              method: 'GET',
              path: path,
              handler: (_) =>
                  _jsonResponse({'error': 'Lookup failed'}, statusCode: status),
            );
            await expectLater(
              lobeApi.sendMessageSession(
                messages: const [
                  {'role': 'user', 'content': 'Hello'},
                ],
                model: 'gpt-4o',
                conversationId: 'tpc_agent_chat',
                lobeAgentId: 'agt_coder',
              ),
              throwsA(
                status == 404
                    ? isA<SyncTerminalException>().having(
                        (e) => e.statusCode,
                        'status',
                        404,
                      )
                    : isA<DioException>().having(
                        (e) => e.response?.statusCode,
                        'status',
                        status,
                      ),
              ),
            );
            expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
          },
        );
      }
    }

    test(
      'unbound Agent cannot use an unverified global model override',
      () async {
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/agents/agt_coder',
          handler: (_) => _jsonResponse({
            'data': {
              'id': 'agt_coder',
              'model': 'gpt-4o',
              'provider': 'openai',
            },
          }),
        );
        await expectLater(
          lobeApi.sendMessageSession(
            messages: const [
              {'role': 'user', 'content': 'Hello'},
            ],
            model: 'claude-topic',
            modelItem: const {
              'provider': 'anthropic',
              'metadata': {'model': 'claude-topic'},
            },
            lobeAgentId: 'agt_coder',
          ),
          throwsA(isA<SyncTerminalException>()),
        );
        expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      },
    );

    for (final lookup in ['topics/tpc_agent_chat', 'agents/agt_coder']) {
      test(
        'mismatched authoritative ID rejects $lookup before dispatch',
        () async {
          adapter.registerHandler(
            method: 'GET',
            path: '/api/v1/messages',
            handler: (_) => _jsonResponse({
              'data': {'messages': []},
            }),
          );
          adapter.registerHandler(
            method: 'GET',
            path: '/api/v1/$lookup',
            handler: (_) => _jsonResponse({
              'success': true,
              'data': {
                'id': 'wrong-id',
                'agentId': 'agt_coder',
                'model': 'gpt-4o',
                'provider': 'openai',
              },
            }),
          );
          await expectLater(
            lobeApi.sendMessageSession(
              messages: const [
                {'role': 'user', 'content': 'Hello'},
              ],
              model: 'gpt-4o',
              conversationId: 'tpc_agent_chat',
              lobeAgentId: 'agt_coder',
            ),
            throwsA(
              isA<SyncTerminalException>().having(
                (e) => e.message,
                'message',
                contains('lookup did not return the requested'),
              ),
            ),
          );
          expect(adapter.requests.where((r) => r.method == 'POST'), isEmpty);
        },
      );
    }

    test('Derives verified Agent from actual topic when lobeAgentId is not provided', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/topics/tpc_agent_derived',
        handler: (_) => _jsonResponse({
          'data': {
            'id': 'tpc_agent_derived',
            'agentId': 'agt_auto_verified',
            'title': 'Agent Chat',
          },
        }),
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/agents/agt_auto_verified',
        handler: (_) => _jsonResponse({
          'data': {
            'id': 'agt_auto_verified',
            'model': 'gpt-4o',
            'provider': 'openai',
          },
        }),
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {'messages': []},
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/responses',
        handler: (options) {
          final data = options.data as Map<String, dynamic>;
          check(data.containsKey('agentId')).isFalse();
          check(data['model']).equals('agt_auto_verified');
          check(data['model']).not((m) => m.equals('gpt-4o'));
          check(data['input']).equals('Hello Agent');
          check(data['previous_response_id']).equals('tpc_agent_derived');
          return _sseResponse([
            'event: response.completed\ndata: {"response":{"status":"completed","output_text":"Hello"}}\n\n',
          ]);
        },
      );

      final session = await lobeApi.sendMessageSession(
        messages: [
          {'role': 'user', 'content': 'Hello Agent'},
        ],
        model: 'gpt-4o',
        conversationId: 'tpc_agent_derived',
      );

      check(session.transport).equals(ChatCompletionTransport.httpStream);
      check(adapter.requestedPaths).contains('/api/v1/responses');
    });

    test(
      'HTTP fault test: snapshot error => zero POST to /api/v1/responses',
      () async {
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/agents/agt_coder',
          handler: (_) => _jsonResponse({
            'data': {
              'id': 'agt_coder',
              'model': 'gpt-4o',
              'provider': 'openai',
            },
          }),
        );

        // Snapshot endpoint fails with 500 error
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/messages',
          handler: (_) => _jsonResponse({
            'error': 'Internal database failure',
          }, statusCode: 500),
        );

        // Must throw and MUST NOT execute POST /api/v1/responses
        await check(
          lobeApi.sendMessageSession(
            messages: [
              {'role': 'user', 'content': 'Hello'},
            ],
            model: 'gpt-4o',
            conversationId: 'tpc_snapshot_fault',
            lobeAgentId: 'agt_coder',
          ),
        ).throws<DioException>();

        // Assert zero POST to /api/v1/responses
        check(adapter.requestedPaths.contains('/api/v1/responses')).isFalse();
      },
    );

    test('HTTP fault test: raw persist failure => no json success', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {'messages': []},
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/chat',
        handler: (_) => _jsonResponse({
          'success': true,
          'data': {'content': 'Generated reply'},
        }),
      );

      // Persisting assistant message fails with 500 error
      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/messages',
        handler: (_) =>
            _jsonResponse({'error': 'Failed to save message'}, statusCode: 500),
      );

      // Must throw and NOT return jsonCompletion success
      await check(
        lobeApi.sendMessageSession(
          messages: [
            {'role': 'user', 'content': 'Test persist failure'},
          ],
          model: 'gpt-4o',
          conversationId: 'tpc_persist_fault',
          responseMessageId: 'resp_fault_1',
          userMessage: {'id': 'user_fault', 'content': 'Test persist failure'},
        ),
      ).throws<SyncTerminalException>();
    });

    test(
      'HTTP fault test: preexisting assistant alias => no inference POST',
      () async {
        // Server already contains assistant message with conduitClientId = resp_existing_alias
        adapter.registerHandler(
          method: 'GET',
          path: '/api/v1/messages',
          handler: (_) => _jsonResponse({
            'data': {
              'messages': [
                {
                  'id': 'srv_asst_cached',
                  'role': 'assistant',
                  'content': 'Already generated cached content',
                  'model': 'gpt-4o',
                  'provider': 'openai',
                  'reasoning': 'Already reasoned',
                  'metadata': {'conduitClientId': 'resp_existing_alias'},
                },
              ],
            },
          }),
        );

        final session = await lobeApi.sendMessageSession(
          messages: [
            {'role': 'user', 'content': 'Prompt'},
          ],
          model: 'gpt-4o',
          conversationId: 'tpc_existing_alias',
          responseMessageId: 'resp_existing_alias',
        );

        // Returns completed session with existing content
        check(session.transport).equals(ChatCompletionTransport.jsonCompletion);
        check(session.messageId).equals('resp_existing_alias');
        final msg =
            (session.jsonPayload!['choices'] as List).first['message'] as Map;
        check(msg['content']).equals('Already generated cached content');
        check(msg['reasoning_content']).equals('Already reasoned');

        // Assert zero inference POST to /api/v1/chat or /api/v1/responses
        check(adapter.requestedPaths.contains('/api/v1/chat')).isFalse();
        check(adapter.requestedPaths.contains('/api/v1/responses')).isFalse();
      },
    );

    test('Fails on response.completed status failed in SSE stream', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/agents/agt_fail',
        handler: (_) => _jsonResponse({
          'data': {'id': 'agt_fail', 'model': 'gpt-4o'},
        }),
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {'messages': []},
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/responses',
        handler: (_) => _sseResponse([
          'event: response.completed\ndata: {"status":"failed","error":"Model provider quota exceeded"}\n\n',
        ]),
      );

      final session = await lobeApi.sendMessageSession(
        messages: [
          {'role': 'user', 'content': 'Hello'},
        ],
        model: 'gpt-4o',
        conversationId: 'tpc_fail',
        lobeAgentId: 'agt_fail',
      );

      await check(session.byteStream!.toList()).throws<SyncTerminalException>();
    });

    test(
      'sendChatCompleted and task endpoints are safe no-ops on LobeHub',
      () async {
        final res = await lobeApi.sendChatCompleted(
          chatId: 'c1',
          messageId: 'm1',
          messages: [],
          model: 'gpt-4o',
        );
        check(res).isNull();

        await lobeApi.stopTask('task_123');
        await lobeApi.stopTasksByChat('c1');
        final taskIds = await lobeApi.getTaskIdsByChat('c1');
        check(taskIds).isEmpty();

        final active = await lobeApi.checkActiveChats(['c1']);
        check(active).isEmpty();

        check(adapter.requests).isEmpty();
      },
    );
  });
}

class _MockHttpClientAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<String> requestedPaths = [];
  final Map<String, ResponseBody Function(RequestOptions options)> _handlers =
      {};

  void registerHandler({
    required String method,
    required String path,
    required ResponseBody Function(RequestOptions options) handler,
  }) {
    _handlers['${method.toUpperCase()} $path'] = handler;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    requestedPaths.add(options.path);

    final key = '${options.method.toUpperCase()} ${options.path}';
    final handler = _handlers[key];
    if (handler != null) {
      return handler(options);
    }
    throw StateError('Unregistered mock request: $key');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object? body, {int statusCode = 200}) {
  final bytes = utf8.encode(jsonEncode(body));
  return ResponseBody(
    Stream.value(Uint8List.fromList(bytes)),
    statusCode,
    headers: {
      'content-type': ['application/json'],
    },
  );
}

ResponseBody _sseResponse(List<String> frames, {int statusCode = 200}) {
  final controller = StreamController<Uint8List>();
  for (final frame in frames) {
    controller.add(Uint8List.fromList(utf8.encode(frame)));
  }
  controller.close();

  return ResponseBody(
    controller.stream,
    statusCode,
    headers: {
      'content-type': ['text/event-stream'],
    },
  );
}

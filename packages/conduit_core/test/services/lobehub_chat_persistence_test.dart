import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('LobeHub Chat Persistence & Message Deduplication', () {
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
    });

    test('getChatRaw maps incoming server id via metadata.conduitClientId and preserves metadata serverMessageId', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (options) {
          check(options.queryParameters['topicId']).equals('tpc_mapped');
          return _jsonResponse({
            'data': {
              'messages': [
                {
                  'id': 'srv_u_123',
                  'role': 'user',
                  'content': 'Hello from Conduit',
                  'createdAt': 1700000000,
                  'metadata': {'conduitClientId': 'client_u_local_1'},
                },
                {
                  'id': 'srv_a_456',
                  'role': 'assistant',
                  'content': 'Hello from LobeHub',
                  'createdAt': 1700000005,
                  'parentId': 'srv_u_123',
                  'reasoning': 'Let me greet the user',
                  'metadata': {
                    'conduitClientId': 'client_a_local_1',
                    'customKey': 'preserved_value',
                  },
                },
              ]
            }
          });
        },
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/topics/tpc_mapped',
        handler: (_) => _jsonResponse({
          'data': {
            'id': 'tpc_mapped',
            'title': 'Test Mapping',
            'createdAt': 1700000000,
            'favorite': true,
          }
        }),
      );

      final rawChat = await lobeApi.getChatRaw('tpc_mapped');
      check(rawChat).isNotNull();
      check(rawChat!['title']).equals('Test Mapping');
      check(rawChat['pinned']).equals(true);

      final messages = (rawChat['chat'] as Map)['history']['messages'] as Map<String, dynamic>;
      check(messages.length).equals(2);

      // Keyed by conduitClientId!
      check(messages.containsKey('client_u_local_1')).isTrue();
      check(messages.containsKey('client_a_local_1')).isTrue();

      final userMsg = messages['client_u_local_1'] as Map<String, dynamic>;
      check(userMsg['id']).equals('client_u_local_1');
      check(userMsg['meta']['serverMessageId']).equals('srv_u_123');
      check(userMsg['content']).equals('Hello from Conduit');

      final asstMsg = messages['client_a_local_1'] as Map<String, dynamic>;
      check(asstMsg['id']).equals('client_a_local_1');
      check(asstMsg['meta']['serverMessageId']).equals('srv_a_456');
      check(asstMsg['meta']['customKey']).equals('preserved_value');
      check(asstMsg['reasoning']).equals('Let me greet the user');
      check(asstMsg['parentId']).equals('srv_u_123');
    });

    test('createChatRaw queries server before writing and avoids duplicating existing messages', () async {
      final postedMessages = <Map<String, dynamic>>[];

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/topics',
        handler: (options) {
          final data = options.data as Map<String, dynamic>;
          check(data['title']).equals('Pushed Chat');
          return _jsonResponse({
            'data': {'id': 'tpc_created_99', 'title': 'Pushed Chat'}
          });
        },
      );

      // Server already has message with conduitClientId: msg_1
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {
            'messages': [
              {
                'id': 'srv_existing_1',
                'role': 'user',
                'content': 'Existing Message',
                'metadata': {'conduitClientId': 'msg_1'},
              }
            ]
          }
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/messages',
        handler: (options) {
          final data = options.data as Map<String, dynamic>;
          postedMessages.add(data);
          return _jsonResponse({'id': 'srv_new_${postedMessages.length}'});
        },
      );

      final blob = {
        'title': 'Pushed Chat',
        'chat': {
          'title': 'Pushed Chat',
          'messages': [
            {
              'id': 'msg_1', // Already exists on server -> MUST SKIP
              'role': 'user',
              'content': 'Existing Message',
            },
            {
              'id': 'msg_2', // New -> MUST POST
              'role': 'assistant',
              'content': 'New Assistant Reply',
              'done': true,
              'model': 'gpt-4o',
              'reasoning': 'Deep thought',
            }
          ],
        }
      };

      final result = await lobeApi.createChatRaw(blob);
      check(result['id']).equals('tpc_created_99');
      // Preserves original local blob
      check(result['chat']).isNotNull();

      // Only msg_2 should have been posted!
      check(postedMessages.length).equals(1);
      check(postedMessages.first['content']).equals('New Assistant Reply');
      check(postedMessages.first['metadata']?['conduitClientId']).equals('msg_2');
      check(postedMessages.first['model']).equals('gpt-4o');
      check(postedMessages.first['reasoning']).equals('Deep thought');
    });

    test('Agent topic suppresses active in-flight user/assistant turn during sync push', () async {
      final postedMessages = <Map<String, dynamic>>[];

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/topics',
        handler: (_) => _jsonResponse({
          'data': {'id': 'tpc_agent_sync', 'agentId': 'agt_writer'}
        }),
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {'messages': []}
        }),
      );

      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/messages',
        handler: (options) {
          final data = options.data as Map<String, dynamic>;
          postedMessages.add(data);
          return _jsonResponse({'id': 'srv_posted'});
        },
      );

      final blob = {
        'title': 'Agent Chat',
        'meta': {'agentId': 'agt_writer'},
        'chat': {
          'title': 'Agent Chat',
          'messages': [
            // Historical finished turn
            {
              'id': 'hist_u1',
              'role': 'user',
              'content': 'Hello',
              'done': true,
              'timestamp': 100,
            },
            {
              'id': 'hist_a1',
              'role': 'assistant',
              'content': 'Hi there!',
              'done': true,
              'timestamp': 101,
            },
            // Active in-flight turn: user paired with incomplete assistant
            {
              'id': 'pending_u2',
              'role': 'user',
              'content': 'Tell me a story',
              'done': true,
              'timestamp': 102,
            },
            {
              'id': 'in_flight_a2',
              'role': 'assistant',
              'content': 'Once upon a time',
              'done': false, // In progress / isStreaming assistant!
              'timestamp': 103,
            }
          ],
        }
      };

      await lobeApi.createChatRaw(blob);

      // Only hist_u1 and hist_a1 should be persisted; pending_u2 and in_flight_a2 are suppressed!
      check(postedMessages.length).equals(2);
      check(postedMessages[0]['metadata']?['conduitClientId']).equals('hist_u1');
      check(postedMessages[1]['metadata']?['conduitClientId']).equals('hist_a1');
    });

    test('reconcileAgentTurn anchors conduitClientId to both server user and assistant messages', () async {
      final patchedMessages = <String, Map<String, dynamic>>{};

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {
            'messages': [
              // Prior message from snapshot
              {
                'id': 'old_srv_1',
                'role': 'user',
                'content': 'old prompt',
              },
              // New user message generated by server during /api/v1/responses
              {
                'id': 'new_srv_user_2',
                'role': 'user',
                'content': 'Write a poem',
                'metadata': {'provider': 'openai'},
              },
              // New assistant message generated by server during /api/v1/responses
              {
                'id': 'new_srv_asst_2',
                'role': 'assistant',
                'content': 'Roses are red...',
                'parentId': 'new_srv_user_2',
                'metadata': {'tokens': 15},
              },
            ]
          }
        }),
      );

      adapter.registerHandler(
        method: 'PATCH',
        path: '/api/v1/messages/new_srv_user_2',
        handler: (options) {
          patchedMessages['new_srv_user_2'] = options.data as Map<String, dynamic>;
          return _jsonResponse({'success': true});
        },
      );

      adapter.registerHandler(
        method: 'PATCH',
        path: '/api/v1/messages/new_srv_asst_2',
        handler: (options) {
          patchedMessages['new_srv_asst_2'] = options.data as Map<String, dynamic>;
          return _jsonResponse({'success': true});
        },
      );

      final correlation = LobeAgentCorrelation(
        topicId: 'tpc_poem',
        agentId: 'agt_poet',
        userText: 'Write a poem',
        userLocalId: 'client_u_local_id',
        assistantLocalId: 'client_a_local_id',
        snapshotServerIds: {'old_srv_1'},
        createdAt: DateTime.now(),
      );

      final result = await lobeApi.reconcileAgentTurn(correlation);
      check(result.success).isTrue();
      check(result.serverUserId).equals('new_srv_user_2');
      check(result.serverAssistantId).equals('new_srv_asst_2');
      check(result.ambiguous).isFalse();

      // Verify metadata was patched and merged existing keys
      final userMeta = patchedMessages['new_srv_user_2']?['metadata'] as Map;
      check(userMeta['conduitClientId']).equals('client_u_local_id');
      check(userMeta['provider']).equals('openai');

      final asstMeta = patchedMessages['new_srv_asst_2']?['metadata'] as Map;
      check(asstMeta['conduitClientId']).equals('client_a_local_id');
      check(asstMeta['tokens']).equals(15);
    });

    test('reconcileAgentTurn fails with ambiguous=true when multiple user messages match', () async {
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({
          'data': {
            'messages': [
              {
                'id': 'srv_u_dup1',
                'role': 'user',
                'content': 'Write a poem',
              },
              {
                'id': 'srv_u_dup2',
                'role': 'user',
                'content': 'Write a poem',
              },
              {
                'id': 'srv_a_1',
                'role': 'assistant',
                'content': 'Violets are blue',
              },
            ]
          }
        }),
      );

      final correlation = LobeAgentCorrelation(
        topicId: 'tpc_poem',
        agentId: 'agt_poet',
        userText: 'Write a poem',
        userLocalId: 'u_local',
        assistantLocalId: 'a_local',
        snapshotServerIds: {},
        createdAt: DateTime.now(),
      );

      final result = await lobeApi.reconcileAgentTurn(correlation);
      check(result.success).isFalse();
      check(result.ambiguous).isTrue();
    });

    test('Topic CRUD bypasses OpenWebUI paths and calls LobeHub /api/v1/topics', () async {
      // 1. Delete topic
      adapter.registerHandler(
        method: 'DELETE',
        path: '/api/v1/topics/tpc_del',
        handler: (_) => _jsonResponse({'success': true}),
      );
      final deleted = await lobeApi.deleteChatRaw('tpc_del');
      check(deleted).isTrue();
      check(adapter.requestedPaths).contains('/api/v1/topics/tpc_del');

      // 2. Get pinned
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/topics/tpc_pin',
        handler: (_) => _jsonResponse({
          'data': {'id': 'tpc_pin', 'favorite': true}
        }),
      );
      final pinned = await lobeApi.getChatPinnedRaw('tpc_pin');
      check(pinned).isTrue();

      // 3. Toggle pin
      adapter.registerHandler(
        method: 'PATCH',
        path: '/api/v1/topics/tpc_pin',
        handler: (options) {
          final data = options.data as Map;
          check(data['favorite']).equals(false);
          return _jsonResponse({'success': true});
        },
      );
      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (_) => _jsonResponse({'data': {'messages': []}}),
      );

      await lobeApi.togglePinRaw('tpc_pin');
      check(adapter.requestedPaths).contains('/api/v1/topics/tpc_pin');

      // 4. Move to folder
      adapter.registerHandler(
        method: 'PATCH',
        path: '/api/v1/topics/tpc_move',
        handler: (options) {
          final data = options.data as Map;
          check(data['groupId']).equals('grp_1');
          return _jsonResponse({'success': true});
        },
      );
      await lobeApi.moveChatToFolderRaw('tpc_move', 'grp_1');
      check(adapter.requestedPaths).contains('/api/v1/topics/tpc_move');
    });

    test('Queries all message pages when topic history exceeds page size', () async {
      final requestedPages = <int>[];

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (options) {
          final page =
              int.parse(options.queryParameters['page']?.toString() ?? '1');
          requestedPages.add(page);

          if (page == 1) {
            // Return 100 messages (pageSize=100)
            final msgs = List.generate(
              100,
              (i) => {
                'id': 'srv_page1_$i',
                'role': 'user',
                'content': 'Page 1 item $i',
                'metadata': {'conduitClientId': 'client_p1_$i'},
              },
            );
            return _jsonResponse({'data': {'messages': msgs}});
          } else if (page == 2) {
            // Return 1 message on page 2
            return _jsonResponse({
              'data': {
                'messages': [
                  {
                    'id': 'srv_page2_target',
                    'role': 'assistant',
                    'content': 'Target message on page 2',
                    'metadata': {'conduitClientId': 'client_p2_target'},
                  }
                ]
              }
            });
          }
          return _jsonResponse({'data': {'messages': []}});
        },
      );

      final messages =
          await fetchAllLobeHubMessages(lobeApi.dio, topicId: 'tpc_large');

      check(requestedPages).contains(1);
      check(requestedPages).contains(2);
      check(messages.length).equals(101);
      check(messages.last['id']).equals('srv_page2_target');
    });

    test('createChatRaw respects deduplication across multiple pages', () async {
      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/topics',
        handler: (_) => _jsonResponse({
          'data': {'id': 'tpc_multi_page', 'title': 'Multi Page'}
        }),
      );

      adapter.registerHandler(
        method: 'GET',
        path: '/api/v1/messages',
        handler: (options) {
          final page =
              int.parse(options.queryParameters['page']?.toString() ?? '1');
          if (page == 1) {
            final msgs = List.generate(
              100,
              (i) => {
                'id': 'srv_old_$i',
                'role': 'user',
                'content': 'Old message $i',
                'metadata': {'conduitClientId': 'old_cid_$i'},
              },
            );
            return _jsonResponse({'data': {'messages': msgs}});
          } else if (page == 2) {
            return _jsonResponse({
              'data': {
                'messages': [
                  {
                    'id': 'srv_old_101',
                    'role': 'assistant',
                    'content': 'Old message 101',
                    'metadata': {'conduitClientId': 'cid_on_page_2'},
                  }
                ]
              }
            });
          }
          return _jsonResponse({'data': {'messages': []}});
        },
      );

      final postedMessages = <Map<String, dynamic>>[];
      adapter.registerHandler(
        method: 'POST',
        path: '/api/v1/messages',
        handler: (options) {
          postedMessages.add(options.data as Map<String, dynamic>);
          return _jsonResponse({'id': 'srv_brand_new'});
        },
      );

      final blob = {
        'title': 'Multi Page',
        'chat': {
          'title': 'Multi Page',
          'messages': [
            {
              'id': 'cid_on_page_2', // Exists on page 2 -> MUST SKIP
              'role': 'assistant',
              'content': 'Old message 101',
            },
            {
              'id': 'cid_truly_new', // Does not exist -> MUST POST
              'role': 'user',
              'content': 'Brand new content',
            }
          ],
        }
      };

      await lobeApi.createChatRaw(blob);

      check(postedMessages.length).equals(1);
      check(postedMessages.single['metadata']?['conduitClientId'])
          .equals('cid_truly_new');
    });
  });
}

class _MockHttpClientAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<String> requestedPaths = [];
  final Map<String, ResponseBody Function(RequestOptions options)> _handlers = {};

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
    return _jsonResponse({});
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

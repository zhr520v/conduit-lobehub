import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';

/// In-memory mock adapter for Dio network testing.
class MockHttpClientAdapter implements HttpClientAdapter {
  MockHttpClientAdapter({this.handler});

  FutureOr<ResponseBody> Function(RequestOptions options)? handler;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (handler != null) {
      return handler!(options);
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

(LobeHubApiClient, MockHttpClientAdapter) createTestClient({
  String baseUrl = 'https://ai.opw.ink',
  String? apiKey,
  String? Function()? apiKeyProvider,
  FutureOr<ResponseBody> Function(RequestOptions options)? handler,
}) {
  final adapter = MockHttpClientAdapter(handler: handler);
  final dio = Dio()..httpClientAdapter = adapter;
  final client = LobeHubApiClient(
    baseUrl: baseUrl,
    apiKey: apiKey,
    apiKeyProvider: apiKeyProvider,
    dio: dio,
  );
  return (client, adapter);
}

void main() {
  group('Collection decoding', () {
    final loaders = <String, Future<List<dynamic>> Function(LobeHubApiClient)>{
      'agents': (client) => client.getAgents(),
      'topics': (client) => client.getTopics(),
      'messages': (client) => client.getMessages(),
    };
    final fixtures = <String, List<Map<String, dynamic>>>{
      'agents': List.generate(11, (index) => {
        'id': 'synthetic_agent_$index',
        'title': 'Synthetic Assistant $index',
        'model': 'synthetic-model-$index',
        'provider': 'synthetic-provider',
        'params': {'temperature': 0.5},
      }),
      'topics': [
        {'id': 'synthetic_topic', 'title': 'Synthetic Topic',
          'agentId': 'synthetic_agent_0', 'favorite': true},
      ],
      'messages': [
        {'id': 'synthetic_message', 'role': 'assistant',
          'content': 'Synthetic reply', 'topicId': 'synthetic_topic',
          'model': 'synthetic-model-0', 'provider': 'synthetic-provider'},
      ],
    };

    for (final entry in loaders.entries) {
      final key = entry.key;
      final load = entry.value;
      final rows = fixtures[key]!;
      final unrelatedKey = key == 'agents' ? 'topics' : 'agents';

      test('$key decodes nested success envelope with total', () async {
        final (client, adapter) = createTestClient(handler: (options) =>
          jsonResponse({'success': true, 'data': {key: rows, 'total': rows.length}}));
        addTearDown(client.close);
        final result = await load(client);
        expect(result.map((dynamic row) => row.id), rows.map((row) => row['id']));
        expect(adapter.requests.single.path, '/api/v1/$key');
        if (key == 'agents') {
          expect(result, hasLength(11));
          for (var index = 0; index < 11; index++) {
            final agent = result[index] as LobeAgent;
            expect(agent.title, rows[index]['title']);
            expect(agent.model, rows[index]['model']);
            expect(agent.provider, rows[index]['provider']);
            expect(agent.params, rows[index]['params']);
          }
        } else if (key == 'topics') {
          final topic = result.single as LobeTopic;
          expect(topic.title, 'Synthetic Topic');
          expect(topic.agentId, 'synthetic_agent_0');
          expect(topic.favorite, isTrue);
        } else {
          final message = result.single as LobeMessage;
          expect(message.content, 'Synthetic reply');
          expect(message.role, 'assistant');
          expect(message.topicId, 'synthetic_topic');
          expect(message.model, 'synthetic-model-0');
          expect(message.provider, 'synthetic-provider');
        }
      });

      test('$key preserves shipped list shapes', () async {
        for (final body in <dynamic>[
          rows, {'data': rows}, {'items': rows}, {'list': rows}, {key: rows},
        ]) {
          final (client, _) = createTestClient(handler: (_) => jsonResponse(body));
          addTearDown(client.close);
          expect(await load(client), hasLength(rows.length));
        }
      });

      test('$key accepts valid empty collections', () async {
        for (final body in <dynamic>[
          [], {'data': []}, {'items': []}, {'list': []}, {key: []},
          {'success': true, 'data': {key: [], 'total': 0}},
        ]) {
          final (client, _) = createTestClient(handler: (_) => jsonResponse(body));
          addTearDown(client.close);
          expect(await load(client), isEmpty);
        }
      });

      test('$key rejects malformed or unrelated collection envelopes', () async {
        for (final body in <dynamic>[
          null, 'invalid', 42, {}, {'success': true}, {'data': null},
          {'data': {}}, {'data': {key: {}}}, {key: 'invalid'},
          {unrelatedKey: rows}, {'data': {unrelatedKey: rows}},
          {'data': {key: null}, 'items': rows},
          {'success': 'true', 'data': rows},
        ]) {
          final (client, _) = createTestClient(handler: (_) => jsonResponse(body));
          addTearDown(client.close);
          await expectLater(load(client), throwsA(isA<LobeHubException>()),
            reason: 'Malformed $key envelope: $body');
        }
      });

      test('$key rejects malformed rows rather than dropping them', () async {
        for (final badRow in <dynamic>[null, 42, 'invalid', [], {},
          {'id': null}, {'id': ''}]) {
          for (final body in <dynamic>[
            [rows.first, badRow],
            {'data': [badRow]},
            {'success': true, 'data': {key: [rows.first, badRow], 'total': 2}},
          ]) {
            final (client, _) = createTestClient(handler: (_) => jsonResponse(body));
            addTearDown(client.close);
            await expectLater(load(client), throwsA(isA<LobeHubException>()),
              reason: 'Malformed $key row: $badRow');
          }
        }
      });

      test('$key rejects success false even with a valid collection', () async {
        for (final body in <dynamic>[
          {'success': false, 'error': {'message': 'Synthetic failure'}},
          {'success': false, 'data': []},
          {'success': false, 'data': rows},
          {'success': false, key: rows},
          {'success': false, 'data': {key: rows, 'total': rows.length}},
        ]) {
          final (client, _) = createTestClient(handler: (_) => jsonResponse(body));
          addTearDown(client.close);
          await expectLater(load(client), throwsA(isA<LobeHubException>()
            .having((error) => error.responseBody, 'responseBody', body)));
        }
      });
    }

    test('public collection APIs decode over credential-free loopback HTTP', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var success = true;
      final subscription = server.listen((request) {
        final key = request.uri.pathSegments.last;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'success': success,
          'data': {key: fixtures[key], 'total': fixtures[key]!.length},
        }));
        unawaited(request.response.close());
      });
      addTearDown(subscription.cancel);
      final client = LobeHubApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      addTearDown(client.close);
      for (final entry in loaders.entries) {
        expect(await entry.value(client), hasLength(fixtures[entry.key]!.length));
      }
      success = false;
      for (final load in loaders.values) {
        await expectLater(load(client), throwsA(isA<LobeHubException>()));
      }
    });

    test('getAgent preserves flat fields inside success detail envelope', () async {
      final row = fixtures['agents']!.first;
      final (client, _) = createTestClient(handler: (_) =>
        jsonResponse({'success': true, 'data': row}));
      addTearDown(client.close);
      final agent = await client.getAgent(row['id'] as String);
      expect(agent.id, row['id']);
      expect(agent.title, row['title']);
      expect(agent.model, row['model']);
      expect(agent.provider, row['provider']);
      expect(agent.params, row['params']);
    });
  });

  group('Base URL normalization', () {
    test('normalizes root URL with no trailing slash', () {
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink'),
        equals('https://ai.opw.ink/api/v1'),
      );
    });

    test('normalizes root URL with trailing slash', () {
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink/'),
        equals('https://ai.opw.ink/api/v1'),
      );
    });

    test('normalizes URL already containing /api/v1', () {
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink/api/v1'),
        equals('https://ai.opw.ink/api/v1'),
      );
    });

    test('normalizes URL containing /api/v1 with trailing slash', () {
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink/api/v1/'),
        equals('https://ai.opw.ink/api/v1'),
      );
    });

    test('normalizes URL with subpaths and ports', () {
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink:8443/custom/subpath/'),
        equals('https://ai.opw.ink:8443/custom/subpath/api/v1'),
      );
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink:8443/custom/subpath/api/v1/'),
        equals('https://ai.opw.ink:8443/custom/subpath/api/v1'),
      );
    });

    test('normalizes duplicate /api/v1/api/v1 cleanly', () {
      expect(
        LobeHubApiClient.normalizeBaseUrl('https://ai.opw.ink/api/v1/api/v1/'),
        equals('https://ai.opw.ink/api/v1'),
      );
    });

    test('extracts root URL accurately', () {
      expect(
        LobeHubApiClient.extractRootUrl('https://ai.opw.ink/api/v1'),
        equals('https://ai.opw.ink'),
      );
      expect(
        LobeHubApiClient.extractRootUrl('https://ai.opw.ink:8080/sub/api/v1/'),
        equals('https://ai.opw.ink:8080/sub'),
      );
    });
  });

  group('LobeAuthInterceptor', () {
    test('injects Authorization Bearer and X-API-Key with clean token', () async {
      final (client, adapter) = createTestClient(
        apiKey: 'secret-token-xyz',
        handler: (options) => jsonResponse({'status': 'ok'}),
      );
      addTearDown(client.close);

      await client.checkHealth();

      expect(adapter.requests, hasLength(1));
      final headers = adapter.requests.first.headers;
      expect(headers['Authorization'], equals('Bearer secret-token-xyz'));
      expect(headers['X-API-Key'], equals('secret-token-xyz'));
    });

    test('strips user-entered Bearer prefix (case-insensitive)', () async {
      final (client, adapter) = createTestClient(
        apiKey: 'Bearer my-user-entered-token',
        handler: (options) => jsonResponse({'status': 'ok'}),
      );
      addTearDown(client.close);

      await client.checkHealth();

      expect(adapter.requests, hasLength(1));
      final headers = adapter.requests.first.headers;
      expect(headers['Authorization'], equals('Bearer my-user-entered-token'));
      expect(headers['X-API-Key'], equals('my-user-entered-token'));
    });

    test('strips lowercase bearer with extra whitespace', () async {
      final (client, adapter) = createTestClient(
        apiKey: 'bearer   token-with-spaces  ',
        handler: (options) => jsonResponse({'status': 'ok'}),
      );
      addTearDown(client.close);

      await client.checkHealth();

      expect(adapter.requests, hasLength(1));
      final headers = adapter.requests.first.headers;
      expect(headers['Authorization'], equals('Bearer token-with-spaces'));
      expect(headers['X-API-Key'], equals('token-with-spaces'));
    });

    test('supports dynamic apiKeyProvider', () async {
      var currentKey = 'initial-key';
      final (client, adapter) = createTestClient(
        apiKeyProvider: () => currentKey,
        handler: (options) => jsonResponse({'status': 'ok'}),
      );
      addTearDown(client.close);

      await client.checkHealth();
      expect(adapter.requests.last.headers['X-API-Key'], equals('initial-key'));

      currentKey = 'Bearer updated-key';
      await client.checkHealth();
      expect(adapter.requests.last.headers['X-API-Key'], equals('updated-key'));
      expect(
        adapter.requests.last.headers['Authorization'],
        equals('Bearer updated-key'),
      );
    });

    test('does not set auth headers when apiKey is null or empty', () async {
      final (client, adapter) = createTestClient(
        apiKey: '',
        handler: (options) => jsonResponse({'status': 'ok'}),
      );
      addTearDown(client.close);

      await client.checkHealth();

      expect(adapter.requests, hasLength(1));
      final headers = adapter.requests.first.headers;
      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers.containsKey('X-API-Key'), isFalse);
    });
  });

  group('Error mapping', () {
    test('401 throws LobeHubAuthException with extracted error message', () async {
      final (client, _) = createTestClient(
        handler: (options) => jsonResponse(
          {'message': 'Invalid API Key'},
          statusCode: 401,
        ),
      );
      addTearDown(client.close);

      expect(
        () => client.getCurrentUser(),
        throwsA(
          isA<LobeHubAuthException>()
              .having((e) => e.statusCode, 'statusCode', equals(401))
              .having((e) => e.message, 'message', equals('Invalid API Key')),
        ),
      );
    });

    test('403 throws LobeHubAuthException with nested error object', () async {
      final (client, _) = createTestClient(
        handler: (options) => jsonResponse(
          {
            'error': {'message': 'Permission denied'}
          },
          statusCode: 403,
        ),
      );
      addTearDown(client.close);

      expect(
        () => client.getAgents(),
        throwsA(
          isA<LobeHubAuthException>()
              .having((e) => e.statusCode, 'statusCode', equals(403))
              .having((e) => e.message, 'message', equals('Permission denied')),
        ),
      );
    });

    test('404 throws LobeHubNotFoundException', () async {
      final (client, _) = createTestClient(
        handler: (options) => jsonResponse(
          {'detail': 'Resource not found'},
          statusCode: 404,
        ),
      );
      addTearDown(client.close);

      expect(
        () => client.getAgent('non-existent-id'),
        throwsA(
          isA<LobeHubNotFoundException>()
              .having((e) => e.statusCode, 'statusCode', equals(404))
              .having((e) => e.message, 'message', equals('Resource not found')),
        ),
      );
    });

    test('500/503 throws LobeHubServerException', () async {
      final (client, _) = createTestClient(
        handler: (options) => jsonResponse(
          {'message': 'Internal Server Error'},
          statusCode: 500,
        ),
      );
      addTearDown(client.close);

      expect(
        () => client.getTopics(),
        throwsA(
          isA<LobeHubServerException>()
              .having((e) => e.statusCode, 'statusCode', equals(500)),
        ),
      );
    });

    test('other HTTP errors throw base LobeHubException', () async {
      final (client, _) = createTestClient(
        handler: (options) => jsonResponse(
          {'message': 'Bad Request'},
          statusCode: 400,
        ),
      );
      addTearDown(client.close);

      expect(
        () => client.getMessages(),
        throwsA(
          isA<LobeHubException>()
              .having((e) => e.statusCode, 'statusCode', equals(400))
              .having((e) => e.message, 'message', equals('Bad Request')),
        ),
      );
    });
  });

  group('Health check & User API', () {
    test('checkHealth succeeds on primary /api/v1/health', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/health'));
          return jsonResponse({
            'service': 'lobehub-server',
            'status': 'ok',
            'timestamp': '2026-10-02T12:00:00Z',
          });
        },
      );
      addTearDown(client.close);

      final health = await client.checkHealth();

      expect(health.service, equals('lobehub-server'));
      expect(health.status, equals('ok'));
      expect(health.isOk, isTrue);
      expect(adapter.requests, hasLength(1));
    });

    test('checkHealth falls back to /api/health when /api/v1/health is 404', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          if (options.path.endsWith('/api/v1/health')) {
            return jsonResponse({'message': 'Not found'}, statusCode: 404);
          }
          if (options.path.endsWith('/api/health')) {
            return jsonResponse({'service': 'lobehub-legacy', 'status': 'ok'});
          }
          return jsonResponse({}, statusCode: 500);
        },
      );
      addTearDown(client.close);

      final health = await client.checkHealth();

      expect(health.service, equals('lobehub-legacy'));
      expect(health.isOk, isTrue);
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].path, endsWith('/api/v1/health'));
      expect(adapter.requests[1].path, endsWith('/api/health'));
    });

    test('getCurrentUser succeeds on primary /api/v1/users/me', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/users/me'));
          return jsonResponse({
            'id': 'usr_100',
            'username': 'alice',
            'email': 'alice@example.com',
            'role': 'admin',
          });
        },
      );
      addTearDown(client.close);

      final user = await client.getCurrentUser();

      expect(user.id, equals('usr_100'));
      expect(user.username, equals('alice'));
      expect(user.email, equals('alice@example.com'));
      expect(user.role, equals('admin'));
      expect(adapter.requests, hasLength(1));
    });

    test('getCurrentUser falls back to /api/v1/user on 404 and handles wrapped {data: ...}', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          if (options.path.endsWith('/api/v1/users/me')) {
            return jsonResponse({'message': 'Not found'}, statusCode: 404);
          }
          if (options.path.endsWith('/api/v1/user')) {
            return jsonResponse({
              'data': {
                'id': 'usr_200',
                'username': 'bob',
                'email': 'bob@example.com',
              }
            });
          }
          return jsonResponse({}, statusCode: 500);
        },
      );
      addTearDown(client.close);

      final user = await client.getCurrentUser();

      expect(user.id, equals('usr_200'));
      expect(user.username, equals('bob'));
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests[0].path, endsWith('/api/v1/users/me'));
      expect(adapter.requests[1].path, endsWith('/api/v1/user'));
    });
  });

  group('Agents CRUD', () {
    test('getAgents handles direct list and wrapped in {data: [...]}', () async {
      // Test direct list
      final (client1, _) = createTestClient(
        handler: (options) => jsonResponse([
          {
            'id': 'agent_1',
            'title': 'Assistant 1',
            'model': 'gpt-4o',
          },
          {
            'id': 'agent_2',
            'title': 'Assistant 2',
            'model': 'claude-3-5-sonnet',
          }
        ]),
      );
      addTearDown(client1.close);

      final agents1 = await client1.getAgents();
      expect(agents1, hasLength(2));
      expect(agents1[0].id, equals('agent_1'));
      expect(agents1[0].title, equals('Assistant 1'));
      expect(agents1[1].id, equals('agent_2'));

      // Test wrapped in {data: [...]}
      final (client2, _) = createTestClient(
        handler: (options) => jsonResponse({
          'data': [
            {
              'id': 'agent_wrapped',
              'title': 'Wrapped Assistant',
            }
          ]
        }),
      );
      addTearDown(client2.close);

      final agents2 = await client2.getAgents();
      expect(agents2, hasLength(1));
      expect(agents2.first.id, equals('agent_wrapped'));
      expect(agents2.first.title, equals('Wrapped Assistant'));
    });

    test('getAgents passes pagination and search query parameters', () async {
      final (client, adapter) = createTestClient(
        handler: (options) => jsonResponse([]),
      );
      addTearDown(client.close);

      await client.getAgents(page: 2, pageSize: 25, search: 'code');

      expect(adapter.requests, hasLength(1));
      final qp = adapter.requests.first.queryParameters;
      expect(qp['page'], equals(2));
      expect(qp['pageSize'], equals(25));
      expect(qp['search'], equals('code'));
    });

    test('getAgent retrieves single agent by agentId', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/agents/agent_target'));
          return jsonResponse({
            'id': 'agent_target',
            'title': 'Target Agent',
            'description': 'Target description',
            'model': 'gpt-4o-mini',
          });
        },
      );
      addTearDown(client.close);

      final agent = await client.getAgent('agent_target');

      expect(agent.id, equals('agent_target'));
      expect(agent.title, equals('Target Agent'));
      expect(agent.description, equals('Target description'));
      expect(agent.model, equals('gpt-4o-mini'));
      expect(adapter.requests.first.method, equals('GET'));
    });

    test('createAgent sends POST with payload and deserializes response', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/agents'));
          expect(options.method, equals('POST'));
          final payload = options.data as Map<String, dynamic>;
          expect(payload['title'], equals('New Bot'));
          expect(payload['model'], equals('gpt-4o'));
          return jsonResponse({
            'id': 'agent_created',
            'title': payload['title'],
            'model': payload['model'],
            'createdAt': '2026-10-02T10:00:00Z',
          });
        },
      );
      addTearDown(client.close);

      final created = await client.createAgent({
        'title': 'New Bot',
        'model': 'gpt-4o',
      });

      expect(created.id, equals('agent_created'));
      expect(created.title, equals('New Bot'));
      expect(created.model, equals('gpt-4o'));
      expect(adapter.requests.first.method, equals('POST'));
    });

    test('updateAgent sends PATCH with payload and deserializes response', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/agents/agent_edit'));
          expect(options.method, equals('PATCH'));
          final payload = options.data as Map<String, dynamic>;
          expect(payload['title'], equals('Updated Bot'));
          return jsonResponse({
            'id': 'agent_edit',
            'title': payload['title'],
            'updatedAt': '2026-10-02T10:05:00Z',
          });
        },
      );
      addTearDown(client.close);

      final updated = await client.updateAgent('agent_edit', {
        'title': 'Updated Bot',
      });

      expect(updated.id, equals('agent_edit'));
      expect(updated.title, equals('Updated Bot'));
      expect(adapter.requests.first.method, equals('PATCH'));
    });

    test('deleteAgent sends DELETE and returns true', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/agents/agent_del'));
          expect(options.method, equals('DELETE'));
          return jsonResponse({'success': true});
        },
      );
      addTearDown(client.close);

      final result = await client.deleteAgent('agent_del');

      expect(result, isTrue);
      expect(adapter.requests.first.method, equals('DELETE'));
    });
  });

  group('Topics CRUD', () {
    test('getTopics handles wrapped {items: [...]} and query params', () async {
      final (client, adapter) = createTestClient(
        handler: (options) => jsonResponse({
          'items': [
            {
              'id': 'top_1',
              'title': 'Topic One',
              'favorite': true,
              'agentId': 'agent_1',
            },
            {
              'id': 'top_2',
              'title': 'Topic Two',
              'favorite': false,
              'agentId': 'agent_1',
            }
          ]
        }),
      );
      addTearDown(client.close);

      final topics = await client.getTopics(
        agentId: 'agent_1',
        page: 1,
        pageSize: 10,
        search: 'One',
      );

      expect(topics, hasLength(2));
      expect(topics[0].id, equals('top_1'));
      expect(topics[0].title, equals('Topic One'));
      expect(topics[0].favorite, isTrue);
      expect(topics[1].id, equals('top_2'));

      final qp = adapter.requests.first.queryParameters;
      expect(qp['agentId'], equals('agent_1'));
      expect(qp['page'], equals(1));
      expect(qp['pageSize'], equals(10));
      expect(qp['search'], equals('One'));
    });

    test('createTopic sends POST with title, agentId, sessionId, metadata', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/topics'));
          expect(options.method, equals('POST'));
          final payload = options.data as Map<String, dynamic>;
          expect(payload['title'], equals('New Topic Thread'));
          expect(payload['agentId'], equals('agent_123'));
          expect(payload['sessionId'], equals('sess_456'));
          expect(payload['metadata'], equals({'pinned': true}));
          return jsonResponse({
            'id': 'top_created',
            'title': payload['title'],
            'agentId': payload['agentId'],
            'sessionId': payload['sessionId'],
            'metadata': payload['metadata'],
          });
        },
      );
      addTearDown(client.close);

      final created = await client.createTopic(
        title: 'New Topic Thread',
        agentId: 'agent_123',
        sessionId: 'sess_456',
        metadata: {'pinned': true},
      );

      expect(created.id, equals('top_created'));
      expect(created.title, equals('New Topic Thread'));
      expect(created.agentId, equals('agent_123'));
      expect(created.sessionId, equals('sess_456'));
      expect(created.metadata['pinned'], isTrue);
    });

    test('updateTopic sends PATCH with title, favorite, metadata', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/topics/top_edit'));
          expect(options.method, equals('PATCH'));
          final payload = options.data as Map<String, dynamic>;
          expect(payload['title'], equals('Renamed Topic'));
          expect(payload['favorite'], isTrue);
          return jsonResponse({
            'id': 'top_edit',
            'title': payload['title'],
            'favorite': payload['favorite'],
          });
        },
      );
      addTearDown(client.close);

      final updated = await client.updateTopic(
        'top_edit',
        title: 'Renamed Topic',
        favorite: true,
      );

      expect(updated.id, equals('top_edit'));
      expect(updated.title, equals('Renamed Topic'));
      expect(updated.favorite, isTrue);
    });

    test('deleteTopic sends DELETE and returns true', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/topics/top_del'));
          expect(options.method, equals('DELETE'));
          return jsonResponse({'success': true});
        },
      );
      addTearDown(client.close);

      final result = await client.deleteTopic('top_del');

      expect(result, isTrue);
      expect(adapter.requests.first.method, equals('DELETE'));
    });
  });

  group('Messages CRUD', () {
    test('getMessages handles direct list and wrapped in {messages: [...]}', () async {
      final (client, adapter) = createTestClient(
        handler: (options) => jsonResponse({
          'messages': [
            {
              'id': 'msg_1',
              'role': 'user',
              'content': 'Hello LobeHub',
              'topicId': 'top_1',
            },
            {
              'id': 'msg_2',
              'role': 'assistant',
              'content': 'Hello! How can I help you today?',
              'model': 'gpt-4o',
              'provider': 'openai',
              'reasoning': 'Thinking process content',
              'topicId': 'top_1',
            }
          ]
        }),
      );
      addTearDown(client.close);

      final messages = await client.getMessages(
        topicId: 'top_1',
        agentId: 'agent_1',
        page: 1,
        pageSize: 20,
        order: 'asc',
      );

      expect(messages, hasLength(2));
      expect(messages[0].id, equals('msg_1'));
      expect(messages[0].role, equals('user'));
      expect(messages[0].content, equals('Hello LobeHub'));

      expect(messages[1].id, equals('msg_2'));
      expect(messages[1].role, equals('assistant'));
      expect(messages[1].model, equals('gpt-4o'));
      expect(messages[1].provider, equals('openai'));
      expect(messages[1].reasoning, equals('Thinking process content'));

      final qp = adapter.requests.first.queryParameters;
      expect(qp['topicId'], equals('top_1'));
      expect(qp['agentId'], equals('agent_1'));
      expect(qp['page'], equals(1));
      expect(qp['pageSize'], equals(20));
      expect(qp['order'], equals('asc'));
    });

    test('createMessage sends POST with full message properties', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/messages'));
          expect(options.method, equals('POST'));
          final payload = options.data as Map<String, dynamic>;
          expect(payload['role'], equals('assistant'));
          expect(payload['content'], equals('Function call result'));
          expect(payload['topicId'], equals('top_99'));
          expect(payload['model'], equals('gpt-4o'));
          expect(payload['provider'], equals('openai'));
          expect(payload['reasoning'], equals('Reasoning step'));
          expect(payload['tools'], isNotEmpty);
          return jsonResponse({
            'id': 'msg_created',
            ...payload,
            'createdAt': '2026-10-02T11:00:00Z',
          });
        },
      );
      addTearDown(client.close);

      final message = await client.createMessage(
        role: 'assistant',
        content: 'Function call result',
        topicId: 'top_99',
        model: 'gpt-4o',
        provider: 'openai',
        reasoning: 'Reasoning step',
        tools: [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'search', 'arguments': '{}'}
          }
        ],
      );

      expect(message.id, equals('msg_created'));
      expect(message.role, equals('assistant'));
      expect(message.content, equals('Function call result'));
      expect(message.topicId, equals('top_99'));
      expect(message.model, equals('gpt-4o'));
      expect(message.provider, equals('openai'));
      expect(message.reasoning, equals('Reasoning step'));
      expect(message.tools, hasLength(1));
      expect(message.tools.first['id'], equals('call_1'));
    });

    test('updateMessage sends PATCH with content and reasoning', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/messages/msg_edit'));
          expect(options.method, equals('PATCH'));
          final payload = options.data as Map<String, dynamic>;
          expect(payload['content'], equals('Regenerated content'));
          expect(payload['reasoning'], equals('Refined reasoning'));
          return jsonResponse({
            'id': 'msg_edit',
            'role': 'assistant',
            'content': payload['content'],
            'reasoning': payload['reasoning'],
          });
        },
      );
      addTearDown(client.close);

      final updated = await client.updateMessage(
        'msg_edit',
        content: 'Regenerated content',
        reasoning: 'Refined reasoning',
      );

      expect(updated.id, equals('msg_edit'));
      expect(updated.content, equals('Regenerated content'));
      expect(updated.reasoning, equals('Refined reasoning'));
    });

    test('deleteMessage sends DELETE and returns true', () async {
      final (client, adapter) = createTestClient(
        handler: (options) {
          expect(options.path, endsWith('/api/v1/messages/msg_del'));
          expect(options.method, equals('DELETE'));
          return jsonResponse({'success': true});
        },
      );
      addTearDown(client.close);

      final result = await client.deleteMessage('msg_del');

      expect(result, isTrue);
      expect(adapter.requests.first.method, equals('DELETE'));
    });
  });
}

import 'package:test/test.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';

void main() {
  group('LobeHealthResponse', () {
    test('deserializes sample health JSON successfully', () {
      final json = <String, dynamic>{
        'service': 'lobe-chat-api',
        'status': 'ok',
        'timestamp': '2026-10-02T14:31:10.941Z',
      };

      final response = LobeHealthResponse.fromJson(json);

      expect(response.service, equals('lobe-chat-api'));
      expect(response.status, equals('ok'));
      expect(response.isOk, isTrue);
      expect(response.timestamp, isNotNull);
      expect(response.timestamp!.year, equals(2026));
      expect(response.timestamp!.month, equals(10));
      expect(response.timestamp!.day, equals(2));

      final serialized = response.toJson();
      expect(serialized['service'], equals('lobe-chat-api'));
      expect(serialized['status'], equals('ok'));
      expect(serialized['timestamp'], equals('2026-10-02T14:31:10.941Z'));
    });

    test('handles null and edge case fields safely', () {
      final response = LobeHealthResponse.fromJson(<String, dynamic>{});

      expect(response.service, equals(''));
      expect(response.status, equals(''));
      expect(response.isOk, isFalse);
      expect(response.timestamp, isNull);
      expect(response.toJson(), equals({'service': '', 'status': ''}));

      final updated = response.copyWith(status: 'OK');
      expect(updated.isOk, isTrue);
    });

    test('equality and copyWith work as expected', () {
      const resp1 = LobeHealthResponse(service: 'api', status: 'ok');
      const resp2 = LobeHealthResponse(service: 'api', status: 'ok');
      final resp3 = resp1.copyWith(service: 'other');

      expect(resp1, equals(resp2));
      expect(resp1.hashCode, equals(resp2.hashCode));
      expect(resp1, isNot(equals(resp3)));
    });
  });

  group('LobeAgent', () {
    test('deserializes sample agent JSON successfully', () {
      final json = <String, dynamic>{
        'id': 'agent-1',
        'title': 'Default Assistant',
        'description': 'Helpful AI',
        'avatar': '🤖',
        'systemRole': 'You are helpful',
        'model': 'gpt-4o',
        'chatConfig': {'temperature': 0.7},
        'plugins': ['search', 'web'],
        'createdAt': '2026-10-02T12:00:00.000Z',
        'updatedAt': '2026-10-02T12:05:00.000Z',
      };

      final agent = LobeAgent.fromJson(json);

      expect(agent.id, equals('agent-1'));
      expect(agent.title, equals('Default Assistant'));
      expect(agent.description, equals('Helpful AI'));
      expect(agent.avatar, equals('🤖'));
      expect(agent.systemRole, equals('You are helpful'));
      expect(agent.model, equals('gpt-4o'));
      expect(agent.chatConfig, equals({'temperature': 0.7}));
      expect(agent.plugins, equals(['search', 'web']));
      expect(agent.createdAt, equals(DateTime.parse('2026-10-02T12:00:00.000Z')));
      expect(agent.updatedAt, equals(DateTime.parse('2026-10-02T12:05:00.000Z')));

      final serialized = agent.toJson();
      expect(serialized['id'], equals('agent-1'));
      expect(serialized['title'], equals('Default Assistant'));
      expect(serialized['model'], equals('gpt-4o'));
      expect(serialized['plugins'], equals(['search', 'web']));
    });

    test('supports alternative field names and null safety', () {
      final json = <String, dynamic>{
        'id': 'agent-2',
        'name': 'Assistant from Name',
        'description': null,
        'avatar': null,
        'system_role': 'System instructions via snake_case',
        'model': null,
        'chat_config': null,
        'plugins': null,
        'created_at': 1710000000000,
      };

      final agent = LobeAgent.fromJson(json);

      expect(agent.id, equals('agent-2'));
      expect(agent.title, equals('Assistant from Name'));
      expect(agent.description, isNull);
      expect(agent.avatar, isNull);
      expect(agent.systemRole, equals('System instructions via snake_case'));
      expect(agent.model, isNull);
      expect(agent.chatConfig, isEmpty);
      expect(agent.plugins, isEmpty);
      expect(agent.createdAt, equals(DateTime.fromMillisecondsSinceEpoch(1710000000000, isUtc: true)));
    });

    test('copyWith allows clearing nullable fields with null', () {
      const agent = LobeAgent(
        id: 'agent-1',
        title: 'Original Title',
        model: 'gpt-4o',
      );

      final updated = agent.copyWith(title: null, model: 'claude-3-5-sonnet');
      expect(updated.title, isNull);
      expect(updated.model, equals('claude-3-5-sonnet'));
      expect(updated.id, equals('agent-1'));
    });
  });

  group('LobeTopic', () {
    test('deserializes sample topic JSON successfully', () {
      final json = <String, dynamic>{
        'id': 'topic-1',
        'sessionId': 'agent-1',
        'agentId': 'agent-1',
        'title': 'New Chat',
        'favorite': false,
        'metadata': {'tags': ['work']},
        'createdAt': '2026-10-02T12:00:00.000Z',
        'updatedAt': '2026-10-02T12:01:00.000Z',
      };

      final topic = LobeTopic.fromJson(json);

      expect(topic.id, equals('topic-1'));
      expect(topic.sessionId, equals('agent-1'));
      expect(topic.agentId, equals('agent-1'));
      expect(topic.title, equals('New Chat'));
      expect(topic.favorite, isFalse);
      expect(topic.metadata, equals({'tags': ['work']}));
      expect(topic.createdAt, isNotNull);

      final serialized = topic.toJson();
      expect(serialized['id'], equals('topic-1'));
      expect(serialized['favorite'], isFalse);
    });

    test('handles snake_case and starred alias for favorite', () {
      final json = <String, dynamic>{
        'id': 'topic-2',
        'session_id': 'sess-2',
        'agent_id': 'agent-2',
        'group_id': 'grp-1',
        'name': 'Favorite Topic',
        'starred': true,
        'meta': {'custom': 123},
        'created_at': 1710000000, // 10-digit epoch seconds
      };

      final topic = LobeTopic.fromJson(json);

      expect(topic.id, equals('topic-2'));
      expect(topic.sessionId, equals('sess-2'));
      expect(topic.agentId, equals('agent-2'));
      expect(topic.groupId, equals('grp-1'));
      expect(topic.title, equals('Favorite Topic'));
      expect(topic.favorite, isTrue);
      expect(topic.metadata, equals({'custom': 123}));
      expect(topic.createdAt, equals(DateTime.fromMillisecondsSinceEpoch(1710000000 * 1000, isUtc: true)));
    });

    test('copyWith updates topic correctly', () {
      const topic = LobeTopic(id: 'topic-1', title: 'Old Title', favorite: false);
      final updated = topic.copyWith(title: 'New Title', favorite: true);

      expect(updated.title, equals('New Title'));
      expect(updated.favorite, isTrue);
      expect(updated.id, equals('topic-1'));
    });
  });

  group('LobeMessage', () {
    test('deserializes sample message JSON successfully', () {
      final json = <String, dynamic>{
        'id': 'msg-1',
        'topicId': 'topic-1',
        'role': 'assistant',
        'content': 'Hello',
        'model': 'gpt-4o',
        'provider': 'openai',
        'reasoning': 'Thinking process...',
        'tools': [
          {'name': 'webSearch', 'arguments': '{"query":"LobeHub"}'}
        ],
        'createdAt': '2026-10-02T12:00:01.000Z',
        'updatedAt': '2026-10-02T12:00:05.000Z',
      };

      final message = LobeMessage.fromJson(json);

      expect(message.id, equals('msg-1'));
      expect(message.topicId, equals('topic-1'));
      expect(message.role, equals('assistant'));
      expect(message.content, equals('Hello'));
      expect(message.model, equals('gpt-4o'));
      expect(message.provider, equals('openai'));
      expect(message.reasoning, equals('Thinking process...'));
      expect(message.tools.length, equals(1));
      expect(message.tools.first['name'], equals('webSearch'));

      final serialized = message.toJson();
      expect(serialized['id'], equals('msg-1'));
      expect(serialized['reasoning'], equals('Thinking process...'));
      expect(serialized['tools'], isA<List>());
    });

    test('handles reasoning as structured Map gracefully', () {
      final jsonWithContent = <String, dynamic>{
        'id': 'msg-structured-1',
        'role': 'assistant',
        'content': 'Result',
        'reasoning': {
          'content': 'Step by step deductions...',
          'duration': 1500,
        },
      };

      final msg1 = LobeMessage.fromJson(jsonWithContent);
      expect(msg1.reasoning, equals('Step by step deductions...'));

      final jsonWithJsonMap = <String, dynamic>{
        'id': 'msg-structured-2',
        'role': 'assistant',
        'content': 'Result',
        'reasoning': {
          'steps': ['Step 1', 'Step 2'],
        },
      };

      final msg2 = LobeMessage.fromJson(jsonWithJsonMap);
      expect(msg2.reasoning, contains('"steps"'));
      expect(msg2.reasoning, contains('Step 1'));
    });

    test('handles null reasoning, empty tools, and default values', () {
      final json = <String, dynamic>{
        'id': 'msg-minimal',
        'role': 'user',
        'content': 'Hi',
      };

      final message = LobeMessage.fromJson(json);

      expect(message.id, equals('msg-minimal'));
      expect(message.topicId, isNull);
      expect(message.role, equals('user'));
      expect(message.content, equals('Hi'));
      expect(message.model, isNull);
      expect(message.provider, isNull);
      expect(message.reasoning, isNull);
      expect(message.tools, isEmpty);
      expect(message.createdAt, isNull);
      expect(message.updatedAt, isNull);
    });

    test('copyWith and equality work properly', () {
      const msg1 = LobeMessage(id: 'm1', role: 'user', content: 'hello');
      const msg2 = LobeMessage(id: 'm1', role: 'user', content: 'hello');
      final msg3 = msg1.copyWith(content: 'world');

      expect(msg1, equals(msg2));
      expect(msg1.hashCode, equals(msg2.hashCode));
      expect(msg1, isNot(equals(msg3)));
      expect(msg3.content, equals('world'));
    });
  });

  group('LobeUser', () {
    test('deserializes sample user JSON successfully', () {
      final json = <String, dynamic>{
        'id': 'usr-1',
        'username': 'user1',
        'email': 'user@test.com',
        'fullName': 'Test User',
        'avatar': null,
        'role': 'user',
        'createdAt': '2026-10-02T10:00:00.000Z',
      };

      final user = LobeUser.fromJson(json);

      expect(user.id, equals('usr-1'));
      expect(user.username, equals('user1'));
      expect(user.email, equals('user@test.com'));
      expect(user.fullName, equals('Test User'));
      expect(user.avatar, isNull);
      expect(user.role, equals('user'));
      expect(user.createdAt, equals(DateTime.parse('2026-10-02T10:00:00.000Z')));

      final serialized = user.toJson();
      expect(serialized['id'], equals('usr-1'));
      expect(serialized['username'], equals('user1'));
      expect(serialized.containsKey('avatar'), isFalse);
    });

    test('handles snake_case aliases and null fields', () {
      final json = <String, dynamic>{
        'id': 'usr-2',
        'username': 'admin2',
        'full_name': 'Admin User',
        'avatar_url': 'https://example.com/avatar.png',
        'role': 'admin',
      };

      final user = LobeUser.fromJson(json);

      expect(user.id, equals('usr-2'));
      expect(user.fullName, equals('Admin User'));
      expect(user.avatar, equals('https://example.com/avatar.png'));
      expect(user.role, equals('admin'));
    });

    test('copyWith updates user correctly', () {
      const user = LobeUser(id: 'usr-1', username: 'user1', role: 'user');
      final updated = user.copyWith(role: 'admin', fullName: 'Super User');

      expect(updated.role, equals('admin'));
      expect(updated.fullName, equals('Super User'));
      expect(updated.username, equals('user1'));
    });
  });

  group('parseLobeDateTime utility', () {
    test('parses ISO-8601 strings', () {
      final dt = parseLobeDateTime('2026-10-02T12:00:00.000Z');
      expect(dt, isNotNull);
      expect(dt!.year, equals(2026));
      expect(dt.month, equals(10));
      expect(dt.day, equals(2));
    });

    test('parses 10-digit epoch seconds', () {
      final dt = parseLobeDateTime(1710000000);
      expect(dt, isNotNull);
      expect(dt!.isUtc, isTrue);
    });

    test('parses 13-digit epoch milliseconds', () {
      final dt = parseLobeDateTime(1710000000000);
      expect(dt, isNotNull);
      expect(dt!.isUtc, isTrue);
    });

    test('handles null, empty, and invalid inputs gracefully', () {
      expect(parseLobeDateTime(null), isNull);
      expect(parseLobeDateTime(''), isNull);
      expect(parseLobeDateTime('   '), isNull);
      expect(parseLobeDateTime('not-a-date'), isNull);
    });
  });
}

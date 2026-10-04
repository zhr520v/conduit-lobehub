import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:test/test.dart';

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/services/services.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';

void main() {
  group('LobeTopic <-> Conversation Mappers', () {
    final sampleTopic = LobeTopic(
      id: 'topic-123',
      title: 'AI Engineering Discussion',
      sessionId: 'session-456',
      agentId: 'agent-789',
      groupId: 'group-folder-1',
      favorite: true,
      createdAt: DateTime.utc(2026, 10, 2, 10, 30, 0),
      updatedAt: DateTime.utc(2026, 10, 2, 11, 45, 0),
      metadata: <String, dynamic>{
        'customTag': 'flutter',
        'priority': 'high',
        'tags': ['dart', 'mobile'],
      },
    );

    test('lobeTopicToConversation maps all fields accurately', () {
      final msg = ChatMessage(
        id: 'msg-1',
        role: 'user',
        content: 'Hello',
        timestamp: DateTime.utc(2026, 10, 2, 10, 31, 0),
      );

      final conversation = lobeTopicToConversation(
        sampleTopic,
        messages: [msg],
      );

      expect(conversation.id, equals('topic-123'));
      expect(conversation.title, equals('AI Engineering Discussion'));
      expect(conversation.pinned, isTrue);
      expect(conversation.archived, isFalse);
      expect(conversation.folderId, equals('group-folder-1'));
      expect(conversation.model, equals('agent-789'));
      expect(conversation.createdAt, equals(sampleTopic.createdAt));
      expect(conversation.updatedAt, equals(sampleTopic.updatedAt));
      expect(conversation.messages.length, equals(1));
      expect(conversation.messages.first.id, equals('msg-1'));

      // Check metadata preservation
      expect(conversation.metadata['agentId'], equals('agent-789'));
      expect(conversation.metadata['sessionId'], equals('session-456'));
      expect(conversation.metadata['groupId'], equals('group-folder-1'));
      expect(conversation.metadata['customTag'], equals('flutter'));
      expect(conversation.metadata['lobeMetadata'], isA<Map<String, dynamic>>());
      expect(
        (conversation.metadata['lobeMetadata'] as Map)['priority'],
        equals('high'),
      );
    });

    test('lobeTopicToConversation handles empty/null title and timestamps safely', () {
      const minimalTopic = LobeTopic(id: 'topic-minimal');
      final conversation = lobeTopicToConversation(minimalTopic);

      expect(conversation.id, equals('topic-minimal'));
      expect(conversation.title, equals('Untitled'));
      expect(conversation.pinned, isFalse);
      expect(conversation.createdAt, isNotNull);
      expect(conversation.updatedAt, isNotNull);
      expect(conversation.messages, isEmpty);
    });

    test('conversationToLobeTopic round-trip preserves original data losslessly', () {
      final conversation = lobeTopicToConversation(sampleTopic);
      final restoredTopic = conversationToLobeTopic(conversation);

      expect(restoredTopic.id, equals(sampleTopic.id));
      expect(restoredTopic.title, equals(sampleTopic.title));
      expect(restoredTopic.agentId, equals(sampleTopic.agentId));
      expect(restoredTopic.sessionId, equals(sampleTopic.sessionId));
      expect(restoredTopic.groupId, equals(sampleTopic.groupId));
      expect(restoredTopic.favorite, equals(sampleTopic.favorite));
      expect(restoredTopic.createdAt, equals(sampleTopic.createdAt));
      expect(restoredTopic.updatedAt, equals(sampleTopic.updatedAt));
      expect(restoredTopic.metadata, equals(sampleTopic.metadata));
      expect(restoredTopic, equals(sampleTopic));
    });

    test('conversationToLobeTopic fallback path when lobeTopic metadata is absent', () {
      final customConversation = Conversation(
        id: 'conv-fallback-99',
        title: 'Fresh Conversation',
        createdAt: DateTime.utc(2026, 10, 2, 12, 0, 0),
        updatedAt: DateTime.utc(2026, 10, 2, 12, 30, 0),
        pinned: true,
        folderId: 'folder-abc',
        model: 'gpt-4o',
        metadata: <String, dynamic>{
          'agentId': 'agent-custom',
          'sessionId': 'session-custom',
          'customProperty': 42,
        },
      );

      final topic = conversationToLobeTopic(customConversation);

      expect(topic.id, equals('conv-fallback-99'));
      expect(topic.title, equals('Fresh Conversation'));
      expect(topic.favorite, isTrue);
      expect(topic.agentId, equals('agent-custom'));
      expect(topic.sessionId, equals('session-custom'));
      expect(topic.groupId, equals('folder-abc'));
      expect(topic.createdAt, equals(customConversation.createdAt));
      expect(topic.updatedAt, equals(customConversation.updatedAt));
      expect(topic.metadata['customProperty'], equals(42));
    });
  });

  group('LobeMessage <-> ChatMessage Mappers', () {
    final sampleMessage = LobeMessage(
      id: 'msg-abc-123',
      topicId: 'topic-xyz',
      role: 'assistant',
      content: 'Here is the technical architecture diagram.',
      model: 'claude-3-5-sonnet',
      provider: 'anthropic',
      reasoning: 'The user is requesting an architecture diagram for mobile.',
      tools: <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'render_mermaid',
          'arguments': {'syntax': 'graph TD; A-->B;'},
        },
      ],
      createdAt: DateTime.utc(2026, 10, 2, 14, 0, 0),
      updatedAt: DateTime.utc(2026, 10, 2, 14, 1, 0),
    );

    test('lobeMessageToChatMessage maps reasoning, tools, and envelope correctly', () {
      final chatMessage = lobeMessageToChatMessage(sampleMessage);

      expect(chatMessage.id, equals('msg-abc-123'));
      expect(chatMessage.role, equals('assistant'));
      expect(chatMessage.content, equals('Here is the technical architecture diagram.'));
      expect(chatMessage.model, equals('claude-3-5-sonnet'));
      expect(chatMessage.timestamp, equals(sampleMessage.createdAt));

      // Reasoning mapped to structured output
      expect(chatMessage.output, isNotNull);
      expect(chatMessage.output!.length, equals(1));
      expect(chatMessage.output!.first['type'], equals('reasoning'));
      expect(
        chatMessage.output!.first['content'],
        equals('The user is requesting an architecture diagram for mobile.'),
      );
      expect(chatMessage.output!.first['status'], equals('completed'));

      // Tools mapped to embeds and metadata
      expect(chatMessage.embeds, isNotNull);
      expect(chatMessage.embeds!.length, equals(1));
      expect(chatMessage.embeds!.first['name'], equals('render_mermaid'));

      expect(chatMessage.metadata, isNotNull);
      expect(chatMessage.metadata!['reasoning'], equals(sampleMessage.reasoning));
      expect(chatMessage.metadata!['topicId'], equals('topic-xyz'));
      expect(chatMessage.metadata!['provider'], equals('anthropic'));
      expect(chatMessage.metadata!['tools'], equals(sampleMessage.tools));
    });

    test('chatMessageToLobeMessage round-trip preserves all fields losslessly', () {
      final chatMessage = lobeMessageToChatMessage(sampleMessage);
      final restoredMessage = chatMessageToLobeMessage(chatMessage);

      expect(restoredMessage.id, equals(sampleMessage.id));
      expect(restoredMessage.topicId, equals(sampleMessage.topicId));
      expect(restoredMessage.role, equals(sampleMessage.role));
      expect(restoredMessage.content, equals(sampleMessage.content));
      expect(restoredMessage.model, equals(sampleMessage.model));
      expect(restoredMessage.provider, equals(sampleMessage.provider));
      expect(restoredMessage.reasoning, equals(sampleMessage.reasoning));
      expect(restoredMessage.tools, equals(sampleMessage.tools));
      expect(restoredMessage.createdAt, equals(sampleMessage.createdAt));
      expect(restoredMessage, equals(sampleMessage));
    });

    test('chatMessageToLobeMessage fallback: extracts reasoning from output items', () {
      final chatMessage = ChatMessage(
        id: 'msg-fallback-output',
        role: 'assistant',
        content: 'Response without metadata envelope',
        timestamp: DateTime.utc(2026, 10, 2, 14, 10, 0),
        model: 'deepseek-r1',
        output: <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'reasoning',
            'content': 'Thinking steps extracted from output...',
            'status': 'completed',
          },
        ],
      );

      final lobeMessage = chatMessageToLobeMessage(chatMessage, topicId: 'topic-999');

      expect(lobeMessage.id, equals('msg-fallback-output'));
      expect(lobeMessage.topicId, equals('topic-999'));
      expect(lobeMessage.role, equals('assistant'));
      expect(lobeMessage.content, equals('Response without metadata envelope'));
      expect(lobeMessage.model, equals('deepseek-r1'));
      expect(
        lobeMessage.reasoning,
        equals('Thinking steps extracted from output...'),
      );
    });

    test('chatMessageToLobeMessage fallback: extracts reasoning from <think> tags in content', () {
      final chatMessage = ChatMessage(
        id: 'msg-think-tag',
        role: 'assistant',
        content: '<think>\nFirst analyze query requirements.\nThen format solution.\n</think>\nHere is the answer.',
        timestamp: DateTime.utc(2026, 10, 2, 14, 20, 0),
        model: 'deepseek-v3',
      );

      final lobeMessage = chatMessageToLobeMessage(chatMessage);

      expect(lobeMessage.id, equals('msg-think-tag'));
      expect(lobeMessage.role, equals('assistant'));
      expect(lobeMessage.content, equals('Here is the answer.'));
      expect(
        lobeMessage.reasoning,
        equals('First analyze query requirements.\nThen format solution.'),
      );
    });

    test('chatMessageToLobeMessage fallback: extracts tools from embeds', () {
      final chatMessage = ChatMessage(
        id: 'msg-embeds-tools',
        role: 'assistant',
        content: 'Executing search...',
        timestamp: DateTime.utc(2026, 10, 2, 14, 30, 0),
        embeds: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'web_search',
            'arguments': {'query': 'conduit lobehub'},
          },
        ],
      );

      final lobeMessage = chatMessageToLobeMessage(chatMessage);

      expect(lobeMessage.tools.length, equals(1));
      expect(lobeMessage.tools.first['name'], equals('web_search'));
      expect(
        lobeMessage.tools.first['arguments'],
        equals({'query': 'conduit lobehub'}),
      );
    });
  });

  group('LobeAgent <-> Model Mappers', () {
    const sampleAgent = LobeAgent(
      id: 'agent-flutter-pro',
      title: 'Flutter Expert',
      description: 'Senior Flutter architect and Dart developer assistant.',
      avatar: '🚀',
      systemRole: 'You are an expert Flutter engineer. Write idiomatic Dart.',
      model: 'gpt-4o',
      chatConfig: <String, dynamic>{
        'temperature': 0.7,
        'top_p': 0.9,
        'presence_penalty': 0.2,
      },
      plugins: <String>['search', 'mermaid', 'code_runner'],
    );

    test('lobeAgentToModel maps all agent fields to Conduit Model', () {
      final model = lobeAgentToModel(sampleAgent);

      expect(model.id, equals('agent-flutter-pro'));
      expect(model.name, equals('Flutter Expert'));
      expect(
        model.description,
        equals('Senior Flutter architect and Dart developer assistant.'),
      );
      expect(model.toolIds, equals(['search', 'mermaid', 'code_runner']));
      expect(model.capabilities?['tools'], isTrue);

      final meta = model.metadata!;
      expect(meta['avatar'], equals('🚀'));
      expect(meta['icon'], equals('🚀'));
      expect(
        meta['systemRole'],
        equals('You are an expert Flutter engineer. Write idiomatic Dart.'),
      );
      expect(meta['model'], equals('gpt-4o'));
      expect(meta['chatConfig']['temperature'], equals(0.7));
      expect(meta['chatConfig']['top_p'], equals(0.9));
      expect(meta['params']['temperature'], equals(0.7));
      expect(meta['lobeAgent'], isA<Map<String, dynamic>>());
    });

    test('lobeAgentToModel handles empty title safely', () {
      const minimalAgent = LobeAgent(id: 'agent-fallback-id');
      final model = lobeAgentToModel(minimalAgent);

      expect(model.id, equals('agent-fallback-id'));
      expect(model.name, equals('agent-fallback-id'));
      expect(model.description, isNull);
      expect(model.toolIds, isNull);
    });

    test('modelToLobeAgent round-trip preserves all agent data losslessly', () {
      final model = lobeAgentToModel(sampleAgent);
      final restoredAgent = modelToLobeAgent(model);

      expect(restoredAgent.id, equals(sampleAgent.id));
      expect(restoredAgent.title, equals(sampleAgent.title));
      expect(restoredAgent.description, equals(sampleAgent.description));
      expect(restoredAgent.avatar, equals(sampleAgent.avatar));
      expect(restoredAgent.systemRole, equals(sampleAgent.systemRole));
      expect(restoredAgent.model, equals(sampleAgent.model));
      expect(restoredAgent.chatConfig, equals(sampleAgent.chatConfig));
      expect(restoredAgent.plugins, equals(sampleAgent.plugins));
      expect(restoredAgent, equals(sampleAgent));
    });

    test('modelToLobeAgent fallback path reconstructs from Model fields', () {
      final rawModel = Model(
        id: 'model-raw-1',
        name: 'Raw Model Name',
        description: 'Plain Model Description',
        toolIds: ['plugin-a', 'plugin-b'],
        metadata: <String, dynamic>{
          'avatar': '💡',
          'systemRole': 'Direct system prompt instruction.',
          'model': 'claude-3-haiku',
          'chatConfig': {'temperature': 0.5},
        },
      );

      final agent = modelToLobeAgent(rawModel);

      expect(agent.id, equals('model-raw-1'));
      expect(agent.title, equals('Raw Model Name'));
      expect(agent.description, equals('Plain Model Description'));
      expect(agent.avatar, equals('💡'));
      expect(agent.systemRole, equals('Direct system prompt instruction.'));
      expect(agent.model, equals('claude-3-haiku'));
      expect(agent.chatConfig, equals({'temperature': 0.5}));
      expect(agent.plugins, equals(['plugin-a', 'plugin-b']));
    });
  });

  group('Drift SQLite Storage Helpers', () {
    final sampleTopic = LobeTopic(
      id: 'drift-topic-1',
      title: 'Drift Topic Test',
      agentId: 'agent-db-1',
      sessionId: 'session-db-1',
      groupId: 'folder-drift',
      favorite: true,
      createdAt: DateTime.utc(2026, 10, 2, 8, 0, 0),
      updatedAt: DateTime.utc(2026, 10, 2, 8, 30, 0),
      metadata: <String, dynamic>{'syncState': 'synced', 'version': 2},
    );

    final sampleMessage = LobeMessage(
      id: 'drift-msg-1',
      topicId: 'drift-topic-1',
      role: 'user',
      content: 'Testing SQLite payload preservation',
      model: 'gpt-4o-mini',
      provider: 'openai',
      reasoning: 'Detailed reasoning step',
      tools: <Map<String, dynamic>>[
        {'tool': 'calc', 'input': '2+2'},
      ],
      createdAt: DateTime.utc(2026, 10, 2, 8, 5, 0),
      updatedAt: DateTime.utc(2026, 10, 2, 8, 6, 0),
    );

    test('lobeTopicToChatCompanion generates valid Drift ChatsCompanion', () {
      final companion = lobeTopicToChatCompanion(sampleTopic);

      expect(companion.id.present, isTrue);
      expect(companion.id.value, equals('drift-topic-1'));
      expect(companion.title.present, isTrue);
      expect(companion.title.value, equals('Drift Topic Test'));
      expect(companion.folderId.present, isTrue);
      expect(companion.folderId.value, equals('folder-drift'));
      expect(companion.pinned.present, isTrue);
      expect(companion.pinned.value, isTrue);
      expect(companion.archived.present, isTrue);
      expect(companion.archived.value, isFalse);

      final createdSec = sampleTopic.createdAt!.millisecondsSinceEpoch ~/ 1000;
      final updatedSec = sampleTopic.updatedAt!.millisecondsSinceEpoch ~/ 1000;
      expect(companion.createdAt.value, equals(createdSec));
      expect(companion.updatedAt.value, equals(updatedSec));

      expect(companion.rawExtra.present, isTrue);
      expect(jsonDecode(companion.rawExtra.value), equals(sampleTopic.metadata));

      expect(companion.meta.present, isTrue);
      final metaDecoded = jsonDecode(companion.meta.value) as Map<String, dynamic>;
      expect(metaDecoded['agentId'], equals('agent-db-1'));
      expect(metaDecoded['sessionId'], equals('session-db-1'));
      expect(metaDecoded['groupId'], equals('folder-drift'));
      expect(metaDecoded['lobeMetadata'], equals(sampleTopic.metadata));
      expect(metaDecoded['lobeTopic'], isNotNull);

      // Verify Drift toColumns() contract
      final columns = companion.toColumns(false);
      expect(columns.containsKey('id'), isTrue);
      expect(columns.containsKey('title'), isTrue);
      expect(columns.containsKey('pinned'), isTrue);
      expect(columns.containsKey('created_at'), isTrue);
    });

    test('chatRowToLobeTopic restores LobeTopic from ChatRow', () {
      final companion = lobeTopicToChatCompanion(sampleTopic);
      final row = ChatRow(
        id: companion.id.value,
        title: companion.title.value,
        folderId: companion.folderId.value,
        pinned: companion.pinned.value,
        archived: companion.archived.value,
        createdAt: companion.createdAt.value,
        updatedAt: companion.updatedAt.value,
        rawExtra: companion.rawExtra.value,
        meta: companion.meta.value,
      );

      final restored = chatRowToLobeTopic(row);

      expect(restored.id, equals(sampleTopic.id));
      expect(restored.title, equals(sampleTopic.title));
      expect(restored.favorite, equals(sampleTopic.favorite));
      expect(restored.agentId, equals(sampleTopic.agentId));
      expect(restored.sessionId, equals(sampleTopic.sessionId));
      expect(restored.groupId, equals(sampleTopic.groupId));
      expect(restored.createdAt, equals(sampleTopic.createdAt));
      expect(restored.updatedAt, equals(sampleTopic.updatedAt));
      expect(restored.metadata, equals(sampleTopic.metadata));
    });

    test('chatRowToLobeTopic fallback when meta lacks lobeTopic envelope', () {
      final plainRow = ChatRow(
        id: 'plain-row-1',
        title: 'Plain Chat',
        folderId: 'folder-plain',
        pinned: false,
        archived: false,
        createdAt: 1760000000,
        updatedAt: 1760000500,
        rawExtra: jsonEncode({'legacyKey': 'legacyValue'}),
        meta: jsonEncode({'agentId': 'legacy-agent'}),
      );

      final topic = chatRowToLobeTopic(plainRow);

      expect(topic.id, equals('plain-row-1'));
      expect(topic.title, equals('Plain Chat'));
      expect(topic.groupId, equals('folder-plain'));
      expect(topic.favorite, isFalse);
      expect(topic.agentId, equals('legacy-agent'));
      expect(
        topic.createdAt,
        equals(DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000, isUtc: true)),
      );
      expect(topic.createdAt?.isUtc, isTrue);
      expect(
        topic.updatedAt,
        equals(DateTime.fromMillisecondsSinceEpoch(1760000500 * 1000, isUtc: true)),
      );
      expect(topic.updatedAt?.isUtc, isTrue);
      expect(topic.metadata['legacyKey'], equals('legacyValue'));
    });

    test('lobeMessageToMessageCompanion stores full original JSON in payload', () {
      final companion = lobeMessageToMessageCompanion(
        sampleMessage,
        chatId: 'drift-topic-1',
        orderIndex: 3,
      );

      expect(companion.id.present, isTrue);
      expect(companion.id.value, equals('drift-msg-1'));
      expect(companion.chatId.present, isTrue);
      expect(companion.chatId.value, equals('drift-topic-1'));
      expect(companion.role.present, isTrue);
      expect(companion.role.value, equals('user'));
      expect(companion.content.present, isTrue);
      expect(companion.content.value, equals('Testing SQLite payload preservation'));
      expect(companion.model.present, isTrue);
      expect(companion.model.value, equals('gpt-4o-mini'));
      expect(companion.orderIndex.present, isTrue);
      expect(companion.orderIndex.value, equals(3));
      expect(companion.dirty.present, isTrue);
      expect(companion.dirty.value, isFalse);

      final createdSec = sampleMessage.createdAt!.millisecondsSinceEpoch ~/ 1000;
      expect(companion.createdAt.value, equals(createdSec));

      expect(companion.payload.present, isTrue);
      final payloadJson = jsonDecode(companion.payload.value) as Map<String, dynamic>;
      expect(payloadJson['id'], equals('drift-msg-1'));
      expect(payloadJson['topicId'], equals('drift-topic-1'));
      expect(payloadJson['reasoning'], equals('Detailed reasoning step'));
      expect(payloadJson['tools'], isA<List>());

      // Verify Drift toColumns() contract
      final columns = companion.toColumns(false);
      expect(columns.containsKey('id'), isTrue);
      expect(columns.containsKey('chat_id'), isTrue);
      expect(columns.containsKey('role'), isTrue);
      expect(columns.containsKey('content'), isTrue);
      expect(columns.containsKey('payload'), isTrue);
    });

    test('messageRowToLobeMessage restores complete LobeMessage from payload', () {
      final companion = lobeMessageToMessageCompanion(
        sampleMessage,
        chatId: 'drift-topic-1',
        orderIndex: 0,
      );
      final row = MessageRow(
        id: companion.id.value,
        chatId: companion.chatId.value,
        role: companion.role.value,
        content: companion.content.value,
        model: companion.model.value,
        createdAt: companion.createdAt.value,
        orderIndex: companion.orderIndex.value,
        payload: companion.payload.value,
      );

      final restored = messageRowToLobeMessage(row);

      expect(restored.id, equals(sampleMessage.id));
      expect(restored.topicId, equals(sampleMessage.topicId));
      expect(restored.role, equals(sampleMessage.role));
      expect(restored.content, equals(sampleMessage.content));
      expect(restored.model, equals(sampleMessage.model));
      expect(restored.provider, equals(sampleMessage.provider));
      expect(restored.reasoning, equals(sampleMessage.reasoning));
      expect(restored.tools, equals(sampleMessage.tools));
      expect(restored.createdAt, equals(sampleMessage.createdAt));
      expect(restored, equals(sampleMessage));
    });

    test('messageRowToLobeMessage fallback when payload is missing or invalid', () {
      const fallbackRow = MessageRow(
        id: 'row-no-payload',
        chatId: 'chat-99',
        role: 'assistant',
        content: 'Direct content from row',
        model: 'gemini-1.5-pro',
        createdAt: 1760000000,
        orderIndex: 1,
        payload: '',
      );

      final msg = messageRowToLobeMessage(fallbackRow);

      expect(msg.id, equals('row-no-payload'));
      expect(msg.topicId, equals('chat-99'));
      expect(msg.role, equals('assistant'));
      expect(msg.content, equals('Direct content from row'));
      expect(msg.model, equals('gemini-1.5-pro'));
      expect(
        msg.createdAt,
        equals(DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000, isUtc: true)),
      );
      expect(msg.createdAt?.isUtc, isTrue);
      expect(msg.tools, isEmpty);
      expect(msg.reasoning, isNull);
    });

    test('Map-based Drift helpers round-trip correctly', () {
      // Topic Map round-trip
      final chatMap = lobeTopicToChatRowMap(sampleTopic);
      expect(chatMap['id'], equals(sampleTopic.id));
      expect(chatMap['title'], equals(sampleTopic.title));
      expect(chatMap['folder_id'], equals(sampleTopic.groupId));
      expect(chatMap['pinned'], equals(1));
      expect(chatMap['body_synced'], equals(1));

      final restoredTopicFromMap = chatRowMapToLobeTopic(chatMap);
      expect(restoredTopicFromMap.id, equals(sampleTopic.id));
      expect(restoredTopicFromMap.title, equals(sampleTopic.title));
      expect(restoredTopicFromMap.favorite, isTrue);
      expect(restoredTopicFromMap.groupId, equals(sampleTopic.groupId));

      // Message Map round-trip
      final messageMap = lobeMessageToMessageRowMap(
        sampleMessage,
        chatId: 'drift-topic-1',
        orderIndex: 2,
      );
      expect(messageMap['id'], equals(sampleMessage.id));
      expect(messageMap['chat_id'], equals('drift-topic-1'));
      expect(messageMap['role'], equals(sampleMessage.role));
      expect(messageMap['content'], equals(sampleMessage.content));
      expect(messageMap['order_index'], equals(2));

      final restoredMessageFromMap = messageRowMapToLobeMessage(messageMap);
      expect(restoredMessageFromMap.id, equals(sampleMessage.id));
      expect(restoredMessageFromMap.role, equals(sampleMessage.role));
      expect(restoredMessageFromMap.content, equals(sampleMessage.content));
      expect(restoredMessageFromMap.reasoning, equals(sampleMessage.reasoning));
      expect(restoredMessageFromMap.tools, equals(sampleMessage.tools));
    });
  });
}

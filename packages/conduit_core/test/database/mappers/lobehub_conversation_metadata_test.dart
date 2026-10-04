import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

import '../support/chat_blob_fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('LobeHub metadata SQLite reconstruction roundtrip', () {
    test(
      'metadata.backend=lobehub,agentId,provider survives '
      'ApiService envelope -> ChatBlobMapper -> ChatsDao -> assembleConversation',
      () async {
        final chatBlob = <String, dynamic>{
          'id': 'tpc_lobe_test_1',
          'title': 'Lobe Agent Discussion',
          'metadata': {
            'backend': 'lobehub',
            'agentId': 'agent_assistant_42',
            'provider': 'anthropic',
          },
          'history': {
            'currentId': 'msg-2',
            'messages': {
              'msg-1': {
                'id': 'msg-1',
                'parentId': null,
                'role': 'user',
                'content': 'Help me write code',
                'timestamp': 1749701000,
              },
              'msg-2': {
                'id': 'msg-2',
                'parentId': 'msg-1',
                'role': 'assistant',
                'content': 'I am ready to help you write code.',
                'timestamp': 1749701010,
              },
            },
          },
        };

        final rows = ChatBlobMapper.blobToRows(
          chatId: 'tpc_lobe_test_1',
          blob: chatBlob,
          title: 'Lobe Agent Discussion',
          createdAt: 1749701000,
          updatedAt: 1749701010,
        );

        await db.chatsDao.upsertServerChat(
          rows: rows,
          meta: const {
            'backend': 'lobehub',
            'agentId': 'agent_assistant_42',
            'provider': 'anthropic',
          },
        );

        final chatRow = (await db.chatsDao.getChat('tpc_lobe_test_1'))!;
        final messageRows = await db.messagesDao.getForChat('tpc_lobe_test_1');
        final conversation = assembleConversation(chatRow, messageRows);

        check(conversation.id).equals('tpc_lobe_test_1');
        check(conversation.title).equals('Lobe Agent Discussion');
        check(conversation.metadata['backend']).equals('lobehub');
        check(conversation.metadata['agentId']).equals('agent_assistant_42');
        check(conversation.metadata['provider']).equals('anthropic');
        check(conversation.messages.length).equals(2);
      },
    );

    test('merges with top-level metadata precedence over blob metadata', () async {
      final chatBlob = <String, dynamic>{
        'id': 'tpc_lobe_precedence',
        'title': 'Precedence Test',
        'metadata': {
          'backend': 'lobehub',
          'agentId': 'agent_from_blob',
          'provider': 'openai',
        },
        'history': {
          'currentId': 'm-1',
          'messages': {
            'm-1': {
              'id': 'm-1',
              'parentId': null,
              'role': 'user',
              'content': 'Test precedence',
              'timestamp': 1749702000,
            },
          },
        },
      };

      final rows = ChatBlobMapper.blobToRows(
        chatId: 'tpc_lobe_precedence',
        blob: chatBlob,
        title: 'Precedence Test',
        createdAt: 1749702000,
        updatedAt: 1749702010,
      );

      // Top-level meta overrides agentId and provider
      await db.chatsDao.upsertServerChat(
        rows: rows,
        meta: const {
          'backend': 'lobehub',
          'agentId': 'agent_from_top_meta',
          'provider': 'anthropic',
        },
      );

      final chatRow = (await db.chatsDao.getChat('tpc_lobe_precedence'))!;
      final messageRows = await db.messagesDao.getForChat('tpc_lobe_precedence');
      final conversation = assembleConversation(chatRow, messageRows);

      check(conversation.metadata['backend']).equals('lobehub');
      check(conversation.metadata['agentId']).equals('agent_from_top_meta');
      check(conversation.metadata['provider']).equals('anthropic');
    });

    test('retains metadata when only blob.metadata carries the Lobe marker', () async {
      final chatBlob = <String, dynamic>{
        'id': 'tpc_lobe_blob_only',
        'title': 'Blob Only Marker',
        'metadata': {
          'backend': 'lobehub',
            'agentId': 'agent_blob_solo',
            'agentTitle': 'Blob Solo Agent',
            'agentModel': 'gemini-exact',
            'model': 'gemini-exact',
          'provider': 'gemini',
        },
        'history': {
          'currentId': 'm-solo',
          'messages': {
            'm-solo': {
              'id': 'm-solo',
              'parentId': null,
              'role': 'user',
              'content': 'Solo marker',
              'timestamp': 1749703000,
            },
          },
        },
      };

      final rows = ChatBlobMapper.blobToRows(
        chatId: 'tpc_lobe_blob_only',
        blob: chatBlob,
        title: 'Blob Only Marker',
        createdAt: 1749703000,
        updatedAt: 1749703010,
      );

      // Top-level meta is empty
      await db.chatsDao.upsertServerChat(
        rows: rows,
        meta: const {},
      );

      final chatRow = (await db.chatsDao.getChat('tpc_lobe_blob_only'))!;
      final messageRows = await db.messagesDao.getForChat('tpc_lobe_blob_only');
      final conversation = assembleConversation(chatRow, messageRows);

      check(conversation.metadata['backend']).equals('lobehub');
      check(conversation.metadata['agentId']).equals('agent_blob_solo');
      check(conversation.metadata['agentTitle']).equals('Blob Solo Agent');
      check(conversation.metadata['agentModel']).equals('gemini-exact');
      check(conversation.metadata['model']).equals('gemini-exact');
      check(conversation.metadata['provider']).equals('gemini');
    });

    test('maps agent_id alias in top-level meta to agentId', () async {
      final chatBlob = <String, dynamic>{
        'id': 'tpc_lobe_alias',
        'title': 'Alias Test',
        'metadata': {
          'backend': 'lobehub',
          'provider': 'anthropic',
        },
        'history': {
          'currentId': 'm-a',
          'messages': {
            'm-a': {
              'id': 'm-a',
              'parentId': null,
              'role': 'user',
              'content': 'Alias test',
              'timestamp': 1749704000,
            },
          },
        },
      };

      final rows = ChatBlobMapper.blobToRows(
        chatId: 'tpc_lobe_alias',
        blob: chatBlob,
        title: 'Alias Test',
        createdAt: 1749704000,
        updatedAt: 1749704010,
      );

      await db.chatsDao.upsertServerChat(
        rows: rows,
        meta: const {
          'backend': 'lobehub',
          'agent_id': 'agent_snake_case',
        },
      );

      final chatRow = (await db.chatsDao.getChat('tpc_lobe_alias'))!;
      final messageRows = await db.messagesDao.getForChat('tpc_lobe_alias');
      final conversation = assembleConversation(chatRow, messageRows);

      check(conversation.metadata['backend']).equals('lobehub');
      check(conversation.metadata['agentId']).equals('agent_snake_case');
      check(conversation.metadata['provider']).equals('anthropic');
    });
  });

  group('OWUI metadata regression guard', () {
    test(
      'ordinary OWUI fixture roundtrip preserves existing metadata behavior',
      () async {
        final fixture = loadChatBlobFixtures().singleWhere(
          (f) => f.name == '02_linear_multi_turn',
        );
        await db.chatsDao.upsertServerChat(
          rows: rowsFromFixture(fixture),
          meta: const {
            'tags': ['work', 'coding'],
          },
        );

        final chatRow = (await db.chatsDao.getChat(fixture.chatId))!;
        final messageRows = await db.messagesDao.getForChat(fixture.chatId);
        final conversation = assembleConversation(chatRow, messageRows);

        check(conversation.id).equals(fixture.chatId);
        // Absent marker: no Lobe keys projected
        check(conversation.metadata.containsKey('backend')).isFalse();
        check(conversation.metadata.containsKey('agentId')).isFalse();
        check(conversation.metadata.containsKey('provider')).isFalse();
        // OWUI meta tags are not promoted to conversation.metadata
        check(conversation.metadata.containsKey('tags')).isFalse();
        // OWUI tags are parsed into conversation.tags
        check(conversation.tags).deepEquals(['work', 'coding']);
      },
    );

    test('absent marker untouched: does not generically promote arbitrary OWUI meta', () async {
      final chatBlob = <String, dynamic>{
        'id': 'owui-chat-1',
        'title': 'OWUI Chat',
        'history': {
          'currentId': 'owui-m1',
          'messages': {
            'owui-m1': {
              'id': 'owui-m1',
              'parentId': null,
              'role': 'user',
              'content': 'Hello OWUI',
              'timestamp': 1749705000,
            },
          },
        },
      };

      final rows = ChatBlobMapper.blobToRows(
        chatId: 'owui-chat-1',
        blob: chatBlob,
        title: 'OWUI Chat',
        createdAt: 1749705000,
        updatedAt: 1749705010,
      );

      await db.chatsDao.upsertServerChat(
        rows: rows,
        meta: const {
          'tags': ['project-alpha'],
          'custom_setting': 'value_xyz',
          'nested': {'flag': true},
        },
      );

      final chatRow = (await db.chatsDao.getChat('owui-chat-1'))!;
      final messageRows = await db.messagesDao.getForChat('owui-chat-1');
      final conversation = assembleConversation(chatRow, messageRows);

      check(conversation.metadata.containsKey('custom_setting')).isFalse();
      check(conversation.metadata.containsKey('nested')).isFalse();
      check(conversation.metadata.containsKey('backend')).isFalse();
      check(conversation.metadata.containsKey('agentId')).isFalse();
    });

    test('no heuristic ID: chat ID with lobehub prefix without backend marker is not Lobe', () async {
      final chatBlob = <String, dynamic>{
        'id': 'lobehub_topic_12345',
        'title': 'Heuristic ID Trap',
        'history': {
          'currentId': 'm-trap',
          'messages': {
            'm-trap': {
              'id': 'm-trap',
              'parentId': null,
              'role': 'user',
              'content': 'Should not be detected as LobeHub by ID alone',
              'timestamp': 1749706000,
            },
          },
        },
      };

      final rows = ChatBlobMapper.blobToRows(
        chatId: 'lobehub_topic_12345',
        blob: chatBlob,
        title: 'Heuristic ID Trap',
        createdAt: 1749706000,
        updatedAt: 1749706010,
      );

      await db.chatsDao.upsertServerChat(
        rows: rows,
        meta: const {
          'agentId': 'sneaky_agent',
        },
      );

      final chatRow = (await db.chatsDao.getChat('lobehub_topic_12345'))!;
      final messageRows = await db.messagesDao.getForChat('lobehub_topic_12345');
      final conversation = assembleConversation(chatRow, messageRows);

      // Exact marker required: since backend != lobehub, agentId is not promoted
      check(conversation.metadata.containsKey('backend')).isFalse();
      check(conversation.metadata.containsKey('agentId')).isFalse();
    });

    test('exact backend marker: arbitrary chat ID with backend=lobehub is treated as Lobe', () async {
      final chatBlob = <String, dynamic>{
        'id': 'plain-guid-8f4b',
        'title': 'Exact Marker Test',
        'metadata': {
          'backend': 'lobehub',
          'agentId': 'agent_real',
          'provider': 'openai',
        },
        'history': {
          'currentId': 'm-exact',
          'messages': {
            'm-exact': {
              'id': 'm-exact',
              'parentId': null,
              'role': 'user',
              'content': 'Exact marker works regardless of ID',
              'timestamp': 1749707000,
            },
          },
        },
      };

      final rows = ChatBlobMapper.blobToRows(
        chatId: 'plain-guid-8f4b',
        blob: chatBlob,
        title: 'Exact Marker Test',
        createdAt: 1749707000,
        updatedAt: 1749707010,
      );

      await db.chatsDao.upsertServerChat(rows: rows);

      final chatRow = (await db.chatsDao.getChat('plain-guid-8f4b'))!;
      final messageRows = await db.messagesDao.getForChat('plain-guid-8f4b');
      final conversation = assembleConversation(chatRow, messageRows);

      check(conversation.metadata['backend']).equals('lobehub');
      check(conversation.metadata['agentId']).equals('agent_real');
      check(conversation.metadata['provider']).equals('openai');
    });
  });

  group('Stream placeholder and parseFullConversation metadata', () {
    test('stream placeholder message metadata unchanged', () {
      final chatData = <String, dynamic>{
        'id': 'stream-chat-1',
        'title': 'Streaming Chat',
        'created_at': 1749708000,
        'updated_at': 1749708010,
        'metadata': {
          'existing_stream_key': 'stream_val',
        },
        'chat': {
          'history': {
            'currentId': 'stream-assistant',
            'messages': {
              'stream-user': {
                'id': 'stream-user',
                'parentId': null,
                'role': 'user',
                'content': 'Stream prompt',
                'timestamp': 1749708000,
              },
              'stream-assistant': {
                'id': 'stream-assistant',
                'parentId': 'stream-user',
                'role': 'assistant',
                'content': 'Streaming partial...',
                'timestamp': 1749708010,
                'isStreaming': true,
                'done': false,
              },
            },
          },
        },
      };

      final parsed = parseFullConversation(chatData);
      check(parsed['metadata'] as Map<String, dynamic>).deepEquals({
        'existing_stream_key': 'stream_val',
      });
      final messages = parsed['messages'] as List<Map<String, dynamic>>;
      final assistantMsg = messages.singleWhere((m) => m['role'] == 'assistant');
      check(assistantMsg['isStreaming']).equals(true);
    });

    test('parseFullConversation projects LobeHub metadata from direct ApiService envelope', () {
      final envelope = <String, dynamic>{
        'id': 'tpc_direct_api',
        'title': 'Direct API Envelope',
        'created_at': 1749709000,
        'updated_at': 1749709010,
        'meta': {
          'backend': 'lobehub',
          'agentId': 'agent_direct',
          'provider': 'anthropic',
        },
        'chat': {
          'metadata': {
            'backend': 'lobehub',
            'agentId': 'agent_direct',
            'provider': 'anthropic',
          },
          'history': {
            'currentId': 'm-d1',
            'messages': {
              'm-d1': {
                'id': 'm-d1',
                'parentId': null,
                'role': 'user',
                'content': 'Direct test',
                'timestamp': 1749709000,
              },
            },
          },
        },
      };

      final conversation = parseFullConversationModel(envelope);
      check(conversation.metadata['backend']).equals('lobehub');
      check(conversation.metadata['agentId']).equals('agent_direct');
      check(conversation.metadata['provider']).equals('anthropic');
    });
  });
}

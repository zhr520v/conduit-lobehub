import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late WorkerManager worker;
  late ApiService lobeApi;
  late ApiService openWebUiApi;

  setUp(() {
    worker = WorkerManager();
    lobeApi = ApiService(
      serverConfig: const ServerConfig(
        id: 'lobehub_self_hosted',
        name: 'LobeHub fixture',
        url: 'http://127.0.0.1:1',
      ),
      workerManager: worker,
    );
    openWebUiApi = ApiService(
      serverConfig: const ServerConfig(
        id: 'openwebui-fixture',
        name: 'Open WebUI fixture',
        url: 'http://127.0.0.1:1',
      ),
      workerManager: worker,
    );
  });

  tearDown(() {
    for (final api in [lobeApi, openWebUiApi]) {
      api.dispose();
      api.dio.close(force: true);
    }
    worker.dispose();
  });

  test(
    'persisted LobeHub first turn retains the durable user prompt',
    () async {
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: lobeApi,
        isTemporary: false,
        messages: [
          _message('user', 'user', 'Synthetic loopback prompt'),
          _message('assistant', 'assistant', ''),
        ],
      );

      expect(messages, [
        {'role': 'user', 'content': 'Synthetic loopback prompt'},
      ]);
    },
  );

  test('persisted LobeHub active text history preserves sanitization and eligibility', () async {
    const raw = '  literal <tag> & &lt;entity&gt;  ';
    final history = [
      _message('first-user', 'user', '  First prompt  '),
      _message(
        'completed',
        'assistant',
        '<details type="reasoning"><summary>Thinking</summary>'
            'Private reasoning</details>Completed answer: '
            '<details type="tool_calls" result="&lt;verified&gt; &amp; useful">'
            '<summary>Lookup</summary>Ignored tool body</details>',
      ),
      _message(
        'response-done',
        'assistant',
        'Final streamed answer',
      ).copyWith(isStreaming: true, metadata: const {'responseDone': true}),
      _message(
        'archived',
        'assistant',
        'Archived answer',
      ).copyWith(metadata: const {'archivedVariant': true}),
      _message(
        'in-progress',
        'assistant',
        'Partial answer',
      ).copyWith(isStreaming: true),
      _message('placeholder', 'assistant', ''),
      _message('empty-user', 'user', ''),
      _message('empty-role', '', 'Not history'),
      _message('raw-assistant', 'assistant', 'Escaped presentation').copyWith(
        metadata: const {
          'transport': kDirectTransport,
          kDirectRawAssistantContentMetadataKey: raw,
        },
      ),
      _message('current-user', 'user', 'Next prompt'),
    ];
    final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
      api: lobeApi,
      isTemporary: false,
      conversationSystemPrompt: '  Conversation system  ',
      userSystemPrompt: 'User system',
      messages: history,
    );

    expect(messages, [
      {'role': 'system', 'content': 'Conversation system'},
      {'role': 'user', 'content': 'First prompt'},
      {'role': 'assistant', 'content': 'Completed answer: <verified> & useful'},
      {'role': 'assistant', 'content': 'Final streamed answer'},
      {'role': 'assistant', 'content': raw},
      {'role': 'user', 'content': 'Next prompt'},
    ]);
    messages.last['content'] = 'Request-local edit';
    expect(history.last.content, 'Next prompt');
  });

  test(
    'persisted LobeHub history preserves attachment files and output',
    () async {
      const image = 'data:image/png;base64,AQID';
      const files = [
        {'type': 'file', 'id': 'document', 'url': 'document'},
      ];
      const output = [
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'Completed answer'},
          ],
        },
      ];
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: lobeApi,
        isTemporary: false,
        messages: [
          _message(
            'user',
            'user',
            'Describe the image',
          ).copyWith(attachmentIds: const [image], files: files),
          _message(
            'assistant',
            'assistant',
            'Completed answer',
          ).copyWith(files: files, output: output),
        ],
      );

      expect(messages, [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Describe the image'},
            {
              'type': 'image_url',
              'image_url': {'url': image},
            },
          ],
          'files': files,
        },
        {
          'role': 'assistant',
          'content': 'Completed answer',
          'files': files,
          'output': output,
        },
      ]);
    },
  );

  test('persisted LobeHub uses the user system prompt fallback', () async {
    final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
      api: lobeApi,
      isTemporary: false,
      conversationSystemPrompt: '  ',
      userSystemPrompt: 'User system',
      messages: [_message('user', 'user', 'Prompt')],
    );

    expect(messages, [
      {'role': 'system', 'content': 'User system'},
      {'role': 'user', 'content': 'Prompt'},
    ]);
  });

  test(
    'persisted LobeHub preserves an existing system without duplication',
    () async {
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: lobeApi,
        isTemporary: false,
        conversationSystemPrompt: 'Conversation system',
        userSystemPrompt: 'User system',
        messages: [
          _message('system', 'system', 'Existing system'),
          _message('user', 'user', 'Prompt'),
        ],
      );

      expect(messages, [
        {'role': 'system', 'content': 'Existing system'},
        {'role': 'user', 'content': 'Prompt'},
      ]);
    },
  );

  test(
    'actual persisted Open WebUI still sends only the effective system',
    () async {
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: openWebUiApi,
        isTemporary: false,
        conversationSystemPrompt: 'Conversation system',
        userSystemPrompt: 'User system',
        messages: [
          _message('user', 'user', 'Prompt'),
          _message('assistant', 'assistant', 'Completed answer'),
        ],
      );

      expect(messages, [
        {'role': 'system', 'content': 'Conversation system'},
      ]);
    },
  );

  test(
    'actual temporary Open WebUI still sends its full eligible history',
    () async {
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: openWebUiApi,
        isTemporary: true,
        userSystemPrompt: 'User system',
        messages: [
          _message('user', 'user', 'Prompt'),
          _message('assistant', 'assistant', 'Completed answer'),
          _message('placeholder', 'assistant', ''),
        ],
      );

      expect(messages, [
        {'role': 'system', 'content': 'User system'},
        {'role': 'user', 'content': 'Prompt'},
        {'role': 'assistant', 'content': 'Completed answer'},
      ]);
    },
  );

  test(
    'persisted Open WebUI without a system prompt keeps history server-owned',
    () async {
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: openWebUiApi,
        isTemporary: false,
        messages: [
          _message('user', 'user', 'Prompt'),
          _message('assistant', 'assistant', 'Completed answer'),
        ],
      );

      expect(messages, isEmpty);
    },
  );

  test(
    'persisted LobeHub does not invent a prompt for ineligible history',
    () async {
      final messages = await buildOpenWebUiCompletionRequestMessagesForTest(
        api: lobeApi,
        isTemporary: false,
        messages: [
          _message('empty-user', 'user', ''),
          _message('placeholder', 'assistant', ''),
          _message(
            'partial',
            'assistant',
            'Partial answer',
          ).copyWith(isStreaming: true),
        ],
      );

      expect(messages, isEmpty);
    },
  );
}

ChatMessage _message(String id, String role, String content) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime.utc(2026, 10, 4),
);

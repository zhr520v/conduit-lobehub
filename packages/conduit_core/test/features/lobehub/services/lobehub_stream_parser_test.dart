import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/lobehub/services/lobehub_stream_parser.dart';
import 'package:conduit_core/services/sse_frame_scanner.dart';
import 'package:test/test.dart';

void main() {
  const parser = LobeHubStreamParser();

  group('LobeHubStreamParser', () {
    group('DeepSeek R1 streaming sample (OpenResponses protocol)', () {
      test('parses interleaved reasoning, text, and stop events', () async {
        const sseStream =
            'event: reasoning\n'
            'data: "Thinking about the user\'s problem..."\n\n'
            'event: reasoning\n'
            'data: " Let\'s break it down."\n\n'
            'event: text\n'
            'data: "The solution is"\n\n'
            'event: text\n'
            'data: " 42."\n\n'
            'event: stop\n'
            'data: {"finish_reason":"stop"}\n\n';

        final stream = Stream.value(utf8.encode(sseStream));
        final events = await parser.parseByteStream(stream).toList();

        expect(events, [
          const LobeReasoningDelta("Thinking about the user's problem..."),
          const LobeReasoningDelta(" Let's break it down."),
          const LobeTextDelta("The solution is"),
          const LobeTextDelta(" 42."),
          const LobeStreamDone("stop"),
        ]);
      });

      test('parses reasoning and text when data is JSON object with delta', () async {
        const sseStream =
            'event: reasoning\n'
            'data: {"delta":"Thinking..."}\n\n'
            'event: text\n'
            'data: {"delta":"Hello world"}\n\n'
            'event: stop\n'
            'data: {"finishReason":"stop"}\n\n';

        final stream = Stream.value(utf8.encode(sseStream));
        final events = await parser.parseByteStream(stream).toList();

        expect(events, [
          const LobeReasoningDelta("Thinking..."),
          const LobeTextDelta("Hello world"),
          const LobeStreamDone("stop"),
        ]);
      });
    });

    group('OpenAI-compatible streaming fallback', () {
      test('parses choices delta with reasoning_content and content', () async {
        const sseStream =
            'data: {"choices":[{"delta":{"reasoning_content":"Step 1"}}]}\n\n'
            'data: {"choices":[{"delta":{"reasoning_content":" done."}}]}\n\n'
            'data: {"choices":[{"delta":{"content":"Result is"}}]}\n\n'
            'data: {"choices":[{"delta":{"content":" success."}}]}\n\n'
            'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeReasoningDelta("Step 1"),
          const LobeReasoningDelta(" done."),
          const LobeTextDelta("Result is"),
          const LobeTextDelta(" success."),
          const LobeStreamDone("stop"),
        ]);
      });

      test('supports thinking and reasoning keys in OpenAI delta', () async {
        const sseStream =
            'data: {"choices":[{"delta":{"thinking":"Ollama thought"}}]}\n\n'
            'data: {"choices":[{"delta":{"reasoning":"OpenRouter thought"}}]}\n\n'
            'data: [DONE]\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeReasoningDelta("Ollama thought"),
          const LobeReasoningDelta("OpenRouter thought"),
          const LobeStreamDone(),
        ]);
      });

      test('parses tool_calls in OpenAI choices delta', () async {
        const sseStream =
            'data: {"choices":[{"delta":{"tool_calls":[{"id":"call_123","type":"function","function":{"name":"search","arguments":"{\\"q\\":\\"dart\\"}"}}]}}]}\n\n'
            'data: [DONE]\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeToolCallDelta({
            'id': 'call_123',
            'type': 'function',
            'function': {'name': 'search', 'arguments': '{"q":"dart"}'},
          }),
          const LobeStreamDone(),
        ]);
      });

      test('parses OpenAI error payload without event header', () async {
        const sseStream =
            'data: {"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit"}}\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, hasLength(1));
        final error = events.first as LobeStreamError;
        expect(error.message, 'Rate limit reached');
        expect(error.raw, isA<Map<String, dynamic>>());
      });
    });

    group('OpenResponses tool calls', () {
      test('parses event: tool_calls with array of calls', () async {
        const sseStream =
            'event: tool_calls\n'
            'data: [{"id":"call_a","type":"function","function":{"name":"calc"}},{"id":"call_b","type":"function","function":{"name":"log"}}]\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeToolCallDelta({
            'id': 'call_a',
            'type': 'function',
            'function': {'name': 'calc'},
          }),
          const LobeToolCallDelta({
            'id': 'call_b',
            'type': 'function',
            'function': {'name': 'log'},
          }),
        ]);
      });

      test('parses event: tool_call with single map', () async {
        const sseStream =
            'event: tool_call\n'
            'data: {"id":"call_single","function":{"name":"query"}}\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeToolCallDelta({
            'id': 'call_single',
            'function': {'name': 'query'},
          }),
        ]);
      });

      test('parses event: tool_calls with wrapped tool_calls map', () async {
        const sseStream =
            'event: tool_calls\n'
            'data: {"tool_calls":[{"id":"call_wrapped"}]}\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeToolCallDelta({'id': 'call_wrapped'}),
        ]);
      });
    });

    group('Chunk fragmentation and boundary splitting', () {
      test('handles SSE frames split across tiny byte chunks', () async {
        final fullText =
            'event: text\n'
            'data: "Hello world!"\n\n'
            'event: stop\n'
            'data: "stop"\n\n';

        final bytes = utf8.encode(fullText);

        // Feed bytes 2 at a time
        final controller = StreamController<List<int>>();
        final parsedFuture = parser.parseByteStream(controller.stream).toList();

        for (var i = 0; i < bytes.length; i += 2) {
          final end = (i + 2 < bytes.length) ? i + 2 : bytes.length;
          controller.add(bytes.sublist(i, end));
        }
        await controller.close();

        final events = await parsedFuture;
        expect(events, [
          const LobeTextDelta("Hello world!"),
          const LobeStreamDone("stop"),
        ]);
      });

      test('handles multi-byte UTF-8 split across byte chunks', () async {
        // '你好世界 🚀' contains multi-byte characters and 4-byte emoji
        const text = '你好世界 🚀';
        final jsonText = jsonEncode(text);
        final sse = 'event: text\ndata: $jsonText\n\n';
        final bytes = utf8.encode(sse);

        // Split in the middle of UTF-8 multi-byte sequence
        final controller = StreamController<List<int>>();
        final parsedFuture = parser.parseByteStream(controller.stream).toList();

        for (var i = 0; i < bytes.length; i += 3) {
          final end = (i + 3 < bytes.length) ? i + 3 : bytes.length;
          controller.add(bytes.sublist(i, end));
        }
        await controller.close();

        final events = await parsedFuture;
        expect(events, [
          const LobeTextDelta(text),
        ]);
      });

      test('handles CRLF line boundaries split across chunks', () async {
        final chunks = [
          'event: reasoning\r',
          '\ndata: "Thought"\r\n\r',
          '\nevent: stop\r\ndata: [DONE]\r\n\r\n',
        ];

        final stream = Stream.fromIterable(chunks);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeReasoningDelta("Thought"),
          const LobeStreamDone(),
        ]);
      });
    });

    group('Termination (event: stop and [DONE])', () {
      test('terminates on event: stop with finish_reason', () async {
        const sseStream =
            'event: text\n'
            'data: "Final sentence."\n\n'
            'event: stop\n'
            'data: {"finish_reason":"length"}\n\n'
            'event: text\n'
            'data: "Should not be read"\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("Final sentence."),
          const LobeStreamDone("length"),
        ]);
      });

      test('terminates on bare data: [DONE]', () async {
        const sseStream =
            'event: text\n'
            'data: "The end"\n\n'
            'data: [DONE]\n\n'
            'event: text\n'
            'data: "Ignored"\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("The end"),
          const LobeStreamDone(),
        ]);
      });

      test('handles event: stop with empty data', () async {
        const sseStream =
            'event: text\n'
            'data: "Hi"\n\n'
            'event: stop\n'
            'data:\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("Hi"),
          const LobeStreamDone(),
        ]);
      });
    });

    group('Error handling', () {
      test('parses event: error with structured JSON', () async {
        const sseStream =
            'event: error\n'
            'data: {"error":{"message":"Invalid model selected","code":400}}\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, hasLength(1));
        final error = events.first as LobeStreamError;
        expect(error.message, 'Invalid model selected');
        expect((error.raw as Map)['error']['code'], 400);
      });

      test('parses event: error with plain text string', () async {
        const sseStream =
            'event: error\n'
            'data: Internal Server Error\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeStreamError('Internal Server Error', 'Internal Server Error'),
        ]);
      });
    });

    group('Malformed and unknown events handling without crashing', () {
      test('gracefully ignores comment lines and ping frames', () async {
        const sseStream =
            ': ping\n'
            ': keepalive\n\n'
            'event: ping\n'
            'data: pong\n\n'
            'event: text\n'
            'data: "Valid text"\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("Valid text"),
        ]);
      });

      test('gracefully ignores unknown event types', () async {
        const sseStream =
            'event: custom_metrics\n'
            'data: {"latency": 120}\n\n'
            'event: random_event\n'
            'data: random data\n\n'
            'event: text\n'
            'data: "Surviving text"\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("Surviving text"),
        ]);
      });

      test('gracefully handles malformed JSON in tool_calls', () async {
        const sseStream =
            'event: tool_calls\n'
            'data: {broken json\n\n'
            'event: text\n'
            'data: "Recovered"\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("Recovered"),
        ]);
      });

      test('parses unquoted plain text for event: text', () async {
        const sseStream =
            'event: text\n'
            'data: Plain unquoted content\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("Plain unquoted content"),
        ]);
      });

      test('handles empty lines between frames', () async {
        const sseStream =
            '\n\n\n'
            'event: text\n'
            'data: "One"\n\n'
            '\n\n'
            'event: text\n'
            'data: "Two"\n\n';

        final stream = Stream.value(sseStream);
        final events = await parser.parseTextStream(stream).toList();

        expect(events, [
          const LobeTextDelta("One"),
          const LobeTextDelta("Two"),
        ]);
      });
    });

    group('parseFrame direct invocation', () {
      test('parses individual SseFrame correctly', () {
        final frame1 = const SseFrame(event: 'text', data: '"Hello"');
        expect(parser.parseFrame(frame1), [const LobeTextDelta('Hello')]);

        final frame2 = const SseFrame(event: 'reasoning', data: '"Thinking"');
        expect(parser.parseFrame(frame2), [const LobeReasoningDelta('Thinking')]);

        final frame3 = const SseFrame(event: 'stop', data: '{"finish_reason":"stop"}');
        expect(parser.parseFrame(frame3), [const LobeStreamDone('stop')]);

        final frame4 = const SseFrame(event: null, data: '[DONE]');
        expect(parser.parseFrame(frame4), [const LobeStreamDone()]);

        final frame5 = const SseFrame(event: 'unknown', data: 'data');
        expect(parser.parseFrame(frame5), isEmpty);
      });
    });

    group('LobeStreamEvent equality and toString', () {
      test('LobeTextDelta equality', () {
        expect(const LobeTextDelta('a'), equals(const LobeTextDelta('a')));
        expect(const LobeTextDelta('a'), isNot(equals(const LobeTextDelta('b'))));
        expect(const LobeTextDelta('a').toString(), 'LobeTextDelta(text: a)');
      });

      test('LobeReasoningDelta equality', () {
        expect(const LobeReasoningDelta('a'), equals(const LobeReasoningDelta('a')));
        expect(const LobeReasoningDelta('a'), isNot(equals(const LobeReasoningDelta('b'))));
        expect(const LobeReasoningDelta('a').toString(), 'LobeReasoningDelta(reasoning: a)');
      });

      test('LobeToolCallDelta equality with nested map', () {
        final t1 = const LobeToolCallDelta({'id': '1', 'args': {'x': 10}});
        final t2 = const LobeToolCallDelta({'id': '1', 'args': {'x': 10}});
        final t3 = const LobeToolCallDelta({'id': '2', 'args': {'x': 10}});
        expect(t1, equals(t2));
        expect(t1, isNot(equals(t3)));
      });

      test('LobeStreamDone equality', () {
        expect(const LobeStreamDone('stop'), equals(const LobeStreamDone('stop')));
        expect(const LobeStreamDone(), equals(const LobeStreamDone()));
        expect(const LobeStreamDone('stop'), isNot(equals(const LobeStreamDone('length'))));
        expect(const LobeStreamDone('stop').toString(), 'LobeStreamDone(finishReason: stop)');
      });

      test('LobeStreamError equality', () {
        expect(const LobeStreamError('err', 1), equals(const LobeStreamError('err', 1)));
        expect(const LobeStreamError('err1'), isNot(equals(const LobeStreamError('err2'))));
        expect(const LobeStreamError('msg').toString(), 'LobeStreamError(message: msg, raw: null)');
      });
    });
  });
}

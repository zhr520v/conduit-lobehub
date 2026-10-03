import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/services/sse_frame_scanner.dart';

/// Base class for all stream events emitted by the LobeHub SSE parser.
sealed class LobeStreamEvent {
  const LobeStreamEvent();
}

/// A text content delta chunk from the model.
final class LobeTextDelta extends LobeStreamEvent {
  const LobeTextDelta(this.text);

  /// The incremental text chunk.
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeTextDelta &&
          runtimeType == other.runtimeType &&
          text == other.text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'LobeTextDelta(text: $text)';
}

/// A reasoning/thinking delta chunk (e.g. DeepSeek R1 chain-of-thought tokens).
final class LobeReasoningDelta extends LobeStreamEvent {
  const LobeReasoningDelta(this.reasoning);

  /// The incremental reasoning text chunk.
  final String reasoning;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeReasoningDelta &&
          runtimeType == other.runtimeType &&
          reasoning == other.reasoning;

  @override
  int get hashCode => reasoning.hashCode;

  @override
  String toString() => 'LobeReasoningDelta(reasoning: $reasoning)';
}

/// A tool/function call delta or complete call definition.
final class LobeToolCallDelta extends LobeStreamEvent {
  const LobeToolCallDelta(this.toolCall);

  /// The raw or structured tool call map.
  final Map<String, dynamic> toolCall;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeToolCallDelta &&
          runtimeType == other.runtimeType &&
          _deepEquals(toolCall, other.toolCall);

  @override
  int get hashCode => Object.hashAll(toolCall.entries);

  @override
  String toString() => 'LobeToolCallDelta(toolCall: $toolCall)';
}

/// Terminal event indicating the stream has finished.
final class LobeStreamDone extends LobeStreamEvent {
  const LobeStreamDone([this.finishReason]);

  /// Optional finish reason (e.g. 'stop', 'length', 'tool_calls').
  final String? finishReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeStreamDone &&
          runtimeType == other.runtimeType &&
          finishReason == other.finishReason;

  @override
  int get hashCode => finishReason.hashCode;

  @override
  String toString() => 'LobeStreamDone(finishReason: $finishReason)';
}

/// An error event emitted during streaming.
final class LobeStreamError extends LobeStreamEvent {
  const LobeStreamError(this.message, [this.raw]);

  /// Human-readable error message.
  final String message;

  /// Raw error payload (Map, String, or other object from the server).
  final dynamic raw;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeStreamError &&
          runtimeType == other.runtimeType &&
          message == other.message &&
          _deepEquals(raw, other.raw);

  @override
  int get hashCode => Object.hash(message, raw);

  @override
  String toString() => 'LobeStreamError(message: $message, raw: $raw)';
}

/// Parses OpenResponses protocol Server-Sent Events (SSE) and OpenAI-compatible
/// streams from LobeHub (`POST /api/v1/responses`).
final class LobeHubStreamParser {
  const LobeHubStreamParser();

  /// Parses an SSE byte stream into typed [LobeStreamEvent]s.
  ///
  /// Splits chunks using [utf8.decoder] and [SseFrameScanner] to safely handle
  /// multi-byte UTF-8 sequences and fragmented SSE frames.
  Stream<LobeStreamEvent> parseByteStream(Stream<List<int>> byteStream) {
    return parseTextStream(utf8.decoder.bind(byteStream.cast<List<int>>()));
  }

  /// Parses a decoded SSE text stream into typed [LobeStreamEvent]s.
  Stream<LobeStreamEvent> parseTextStream(Stream<String> textStream) async* {
    final scanner = SseFrameScanner();

    await for (final chunk in textStream) {
      for (final frame in scanner.addChunk(chunk)) {
        for (final event in parseFrame(frame)) {
          yield event;
          if (event is LobeStreamDone) {
            return;
          }
        }
      }
    }

    for (final frame in scanner.close()) {
      for (final event in parseFrame(frame)) {
        yield event;
        if (event is LobeStreamDone) {
          return;
        }
      }
    }
  }

  /// Parses a single [SseFrame] into zero or more [LobeStreamEvent]s.
  Iterable<LobeStreamEvent> parseFrame(SseFrame frame) sync* {
    final trimmedData = frame.data.trim();

    // Explicit done sentinel
    if (trimmedData == '[DONE]') {
      yield const LobeStreamDone();
      return;
    }

    final eventType = frame.event?.trim().toLowerCase();

    // Blank data handling: keepalive comments / heartbeats, unless event is stop
    if (trimmedData.isEmpty) {
      if (eventType == 'stop' || eventType == 'done' || eventType == 'finish') {
        yield const LobeStreamDone();
      }
      return;
    }

    switch (eventType) {
      case 'text':
      case 'text.delta':
      case 'content':
      case 'message.delta':
      case 'response.output_text.delta':
      case 'output_text.delta':
        final text = _extractTextContent(
          frame.data,
          const ['text', 'delta', 'content'],
        );
        if (text != null && text.isNotEmpty) {
          yield LobeTextDelta(text);
        }
        return;

      case 'reasoning':
      case 'reasoning.delta':
      case 'thinking':
      case 'response.reasoning.delta':
      case 'response.output_reasoning.delta':
      case 'response.reasoning_text.delta':
        final reasoning = _extractTextContent(
          frame.data,
          const [
            'reasoning',
            'reasoning_content',
            'thinking',
            'delta',
            'text',
            'content',
          ],
        );
        if (reasoning != null && reasoning.isNotEmpty) {
          yield LobeReasoningDelta(reasoning);
        }
        return;

      case 'tool_calls':
      case 'tool_call':
      case 'tools':
      case 'tool.delta':
        yield* _parseToolCallPayload(frame.data);
        return;

      case 'stop':
      case 'done':
      case 'finish':
      case 'response.completed':
      case 'response.done':
      case 'response.output_item.done':
        yield _parseStopPayload(frame.data);
        return;

      case 'error':
        yield _parseErrorPayload(frame.data);
        return;

      case null:
      case '':
      case 'message':
        yield* _parseUntypedPayload(frame.data);
        return;

      default:
        // Ignore unrecognized SSE event types gracefully (e.g. 'ping', 'heartbeat')
        return;
    }
  }

  /// Extracts text or reasoning delta string from [rawData].
  ///
  /// Handles JSON-quoted string (`"content"`), JSON object (`{"text":"..."}`),
  /// or unquoted raw text string.
  static String? _extractTextContent(
    String rawData,
    List<String> preferredKeys,
  ) {
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is String) {
        return decoded;
      }
      if (decoded is Map) {
        for (final key in preferredKeys) {
          final val = decoded[key];
          if (val is String) return val;
        }
        final delta = decoded['delta'];
        if (delta is Map) {
          for (final key in preferredKeys) {
            final val = delta[key];
            if (val is String) return val;
          }
        } else if (delta is String) {
          return delta;
        }
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map && first['delta'] is Map) {
            final deltaMap = first['delta'] as Map;
            for (final key in preferredKeys) {
              final val = deltaMap[key];
              if (val is String) return val;
            }
          }
        }
        return null;
      }
      if (decoded is num || decoded is bool) {
        return decoded.toString();
      }
    } catch (_) {
      // Non-JSON raw text payload
      return rawData;
    }
    return rawData;
  }

  /// Parses tool call event data from [rawData].
  static Iterable<LobeStreamEvent> _parseToolCallPayload(String rawData) sync* {
    try {
      var decoded = jsonDecode(rawData);
      if (decoded is String) {
        try {
          final nested = jsonDecode(decoded);
          if (nested is Map || nested is List) {
            decoded = nested;
          }
        } catch (_) {}
      }

      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            yield LobeToolCallDelta(item.cast<String, dynamic>());
          }
        }
        return;
      }

      if (decoded is Map) {
        final toolCalls =
            decoded['tool_calls'] ?? decoded['toolCalls'] ?? decoded['tools'];
        if (toolCalls is List) {
          for (final item in toolCalls) {
            if (item is Map) {
              yield LobeToolCallDelta(item.cast<String, dynamic>());
            }
          }
          return;
        }

        final singleCall = decoded['tool_call'] ?? decoded['toolCall'];
        if (singleCall is Map) {
          yield LobeToolCallDelta(singleCall.cast<String, dynamic>());
          return;
        }

        yield LobeToolCallDelta(decoded.cast<String, dynamic>());
        return;
      }
    } catch (_) {
      // Ignore malformed tool call JSON gracefully
    }
  }

  /// Parses stop/finish event data from [rawData].
  static LobeStreamDone _parseStopPayload(String rawData) {
    final trimmed = rawData.trim();
    if (trimmed == '[DONE]' || trimmed.isEmpty) {
      return const LobeStreamDone();
    }
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is Map) {
        final finishReason =
            decoded['finish_reason']?.toString() ??
            decoded['finishReason']?.toString() ??
            decoded['reason']?.toString() ??
            decoded['status']?.toString();
        return LobeStreamDone(finishReason);
      } else if (decoded is String) {
        return LobeStreamDone(decoded);
      }
    } catch (_) {}
    return LobeStreamDone(trimmed);
  }

  /// Parses error event data from [rawData].
  static LobeStreamError _parseErrorPayload(String rawData) {
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is Map) {
        final errorField = decoded['error'];
        String? message;
        if (errorField is Map) {
          message =
              errorField['message']?.toString() ??
              errorField['detail']?.toString();
        } else if (errorField is String && errorField.isNotEmpty) {
          message = errorField;
        }
        message ??=
            decoded['message']?.toString() ??
            decoded['detail']?.toString() ??
            decoded['msg']?.toString();
        return LobeStreamError(
          message ?? rawData,
          decoded.cast<String, dynamic>(),
        );
      }
      if (decoded is String) {
        return LobeStreamError(decoded, decoded);
      }
    } catch (_) {}
    return LobeStreamError(rawData, rawData);
  }

  /// Parses untyped payloads (such as OpenAI-compatible `choices[].delta` stream).
  static Iterable<LobeStreamEvent> _parseUntypedPayload(String rawData) sync* {
    Object? decoded;
    try {
      decoded = jsonDecode(rawData);
    } catch (_) {
      // Non-JSON untyped frame, ignore safely
      return;
    }

    if (decoded is String) {
      if (decoded.toLowerCase() == 'done') {
        yield const LobeStreamDone();
      } else if (decoded.isNotEmpty) {
        yield LobeTextDelta(decoded);
      }
      return;
    }

    if (decoded is! Map) return;
    final map = decoded;

    // Error frame without event: error
    if (map['error'] != null) {
      yield _parseErrorPayload(rawData);
      return;
    }

    // OpenAI-compatible chat completion chunks
    final choices = map['choices'];
    if (choices is List && choices.isNotEmpty) {
      final firstChoice = choices.first;
      if (firstChoice is Map) {
        final delta = firstChoice['delta'];
        if (delta is Map) {
          // 1. Reasoning/Thinking delta
          final reasoning = _extractReasoningFromDelta(delta);
          if (reasoning != null && reasoning.isNotEmpty) {
            yield LobeReasoningDelta(reasoning);
          }

          // 2. Content delta
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            yield LobeTextDelta(content);
          }

          // 3. Tool calls delta
          final toolCalls = delta['tool_calls'] ?? delta['toolCalls'];
          if (toolCalls is List) {
            for (final tc in toolCalls) {
              if (tc is Map) {
                yield LobeToolCallDelta(tc.cast<String, dynamic>());
              }
            }
          }
        }

        // Finish reason in choice
        final finishReason =
            firstChoice['finish_reason']?.toString() ??
            firstChoice['finishReason']?.toString();
        if (finishReason != null &&
            finishReason.isNotEmpty &&
            finishReason != 'null') {
          yield LobeStreamDone(finishReason);
        }
      }
      return;
    }

    // Direct typed envelopes inside payload
    final embeddedType = (map['type'] ?? map['event'])?.toString().toLowerCase();
    if (embeddedType != null) {
      if (embeddedType == 'text' || embeddedType == 'text.delta') {
        final text = _extractTextContent(rawData, const ['text', 'delta', 'content']);
        if (text != null && text.isNotEmpty) yield LobeTextDelta(text);
        return;
      }
      if (embeddedType == 'reasoning' || embeddedType == 'reasoning.delta') {
        final reasoning = _extractTextContent(
          rawData,
          const ['reasoning', 'reasoning_content', 'thinking', 'delta', 'text'],
        );
        if (reasoning != null && reasoning.isNotEmpty) {
          yield LobeReasoningDelta(reasoning);
        }
        return;
      }
      if (embeddedType.contains('tool')) {
        yield* _parseToolCallPayload(rawData);
        return;
      }
      if (embeddedType == 'stop' || embeddedType == 'done') {
        yield _parseStopPayload(rawData);
        return;
      }
    }

    // Direct field fallbacks
    if (map['reasoning'] is String && (map['reasoning'] as String).isNotEmpty) {
      yield LobeReasoningDelta(map['reasoning'] as String);
    }
    if (map['text'] is String && (map['text'] as String).isNotEmpty) {
      yield LobeTextDelta(map['text'] as String);
    }
    if (map['tool_calls'] is List || map['tool_call'] is Map) {
      yield* _parseToolCallPayload(rawData);
    }
    if (map['finish_reason'] != null) {
      yield LobeStreamDone(map['finish_reason'].toString());
    }
  }

  /// Extracts reasoning text from an OpenAI delta map.
  static String? _extractReasoningFromDelta(Map delta) {
    for (final key in const ['reasoning_content', 'reasoning', 'thinking']) {
      final value = delta[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }
}

/// Recursive deep equality check for Map and List structures.
bool _deepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;

  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }

  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }

  return a == b;
}

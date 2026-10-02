import 'dart:convert';

/// Parses dynamic value into a [DateTime], supporting ISO-8601 strings and
/// timestamps in seconds or milliseconds.
DateTime? parseLobeDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) {
    if (value > 10000000000) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }
  if (value is num) {
    final intVal = value.toInt();
    if (intVal > 10000000000) {
      return DateTime.fromMillisecondsSinceEpoch(intVal, isUtc: true);
    }
    return DateTime.fromMillisecondsSinceEpoch(intVal * 1000, isUtc: true);
  }
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsedInt = int.tryParse(trimmed);
    if (parsedInt != null) {
      if (parsedInt > 10000000000) {
        return DateTime.fromMillisecondsSinceEpoch(parsedInt, isUtc: true);
      }
      return DateTime.fromMillisecondsSinceEpoch(parsedInt * 1000, isUtc: true);
    }
    return DateTime.tryParse(trimmed);
  }
  return null;
}

/// Safely casts or converts a dynamic value into a `Map<String, dynamic>`.
Map<String, dynamic> parseLobeJsonMap(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return const <String, dynamic>{};
}

/// Safely extracts a `List<String>` from a dynamic list.
List<String> parseLobeStringList(dynamic value) {
  if (value is List) {
    return value
        .where((item) => item != null)
        .map((item) => item.toString())
        .toList(growable: false);
  }
  return const <String>[];
}

/// Safely extracts a `List<Map<String, dynamic>>` from a dynamic list.
List<Map<String, dynamic>> parseLobeJsonList(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }
  return const <Map<String, dynamic>>[];
}

/// Parses reasoning field which can be either a String or a structured Map.
String? parseLobeReasoning(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is Map) {
    if (value.isEmpty) return null;
    final content =
        value['content'] ??
        value['text'] ??
        value['reasoning_content'] ??
        value['reasoning'];
    if (content != null) {
      return content.toString();
    }
    return jsonEncode(value);
  }
  return value.toString();
}

import 'package:meta/meta.dart';

import 'lobe_json_utils.dart';

const Object _sentinel = Object();

/// Health check response model from LobeHub API (`/api/v1/health` or `/api/health`).
@immutable
class LobeHealthResponse {
  const LobeHealthResponse({
    required this.service,
    required this.status,
    this.timestamp,
  });

  /// Service identifier (e.g. `'lobe-chat-api'`).
  final String service;

  /// Service status (e.g. `'ok'`).
  final String status;

  /// Service timestamp from the response.
  final DateTime? timestamp;

  /// Returns true if status is `'ok'` (case-insensitive).
  bool get isOk => status.toLowerCase() == 'ok';

  factory LobeHealthResponse.fromJson(Map<String, dynamic> json) =>
      LobeHealthResponse(
        service: json['service']?.toString() ?? '',
        status: json['status']?.toString() ?? '',
        timestamp: parseLobeDateTime(json['timestamp']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'service': service,
    'status': status,
    if (timestamp != null) 'timestamp': timestamp!.toIso8601String(),
  };

  LobeHealthResponse copyWith({
    String? service,
    String? status,
    Object? timestamp = _sentinel,
  }) => LobeHealthResponse(
    service: service ?? this.service,
    status: status ?? this.status,
    timestamp: identical(timestamp, _sentinel)
        ? this.timestamp
        : timestamp as DateTime?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LobeHealthResponse &&
          runtimeType == other.runtimeType &&
          service == other.service &&
          status == other.status &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(service, status, timestamp);

  @override
  String toString() =>
      'LobeHealthResponse(service: $service, status: $status, timestamp: $timestamp)';
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lobehub_upload_test_');
  });

  tearDown(() async {
    for (final adapter in _activeAdapters) {
      await adapter.drainCompleted;
    }
    _activeAdapters.clear();

    for (final api in _activeApiServices) {
      api.dio.close(force: true);
    }
    _activeApiServices.clear();
    for (final worker in _activeWorkerManagers) {
      worker.dispose();
    }
    _activeWorkerManagers.clear();

    if (await tempDir.exists()) {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.value();
        await Future<void>(() {});
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    }
  });

  File createTestFile(String name, String content) {
    final file = File('${tempDir.path}/$name');
    file.writeAsStringSync(content);
    return file;
  }

  group('ApiService.uploadFile & uploadFileBytes (LobeHub vs OpenWebUI)', () {
    test('LobeHub uploadFile uses /api/v1/files and accepts data.file.id', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'success': true,
          'data': {
            'file': {
              'id': 'lobe-file-uuid-123',
              'name': 'document.txt',
              'size': 13,
            },
            'parsed': {'text': 'Hello LobeHub'},
          },
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('document.txt', 'Hello LobeHub');

      final fileId = await api.uploadFile(file.path, 'document.txt');

      check(fileId).equals('lobe-file-uuid-123');
      check(adapter.requestedPath).equals('/api/v1/files');
      check(adapter.requestedMethod).equals('POST');
      check(adapter.requestedData).isA<FormData>();
      final formData = adapter.requestedData as FormData;
      check(formData.files.any((f) => f.key == 'file' && f.value.filename == 'document.txt')).isTrue();
    });

    test('LobeHub uploadFileBytes uses /api/v1/files and accepts data.file.id', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'success': true,
          'data': {
            'file': {
              'id': 'lobe-bytes-uuid-456',
              'name': 'bytes.bin',
            },
          },
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final fileId = await api.uploadFileBytes(
        'bytes.bin',
        utf8.encode('raw byte content'),
      );

      check(fileId).equals('lobe-bytes-uuid-456');
      check(adapter.requestedPath).equals('/api/v1/files');
      check(adapter.requestedMethod).equals('POST');
      check(adapter.requestedData).isA<FormData>();
      final formData = adapter.requestedData as FormData;
      check(formData.files.any((f) => f.key == 'file' && f.value.filename == 'bytes.bin')).isTrue();
    });

    test('OpenWebUI uploadFile uses /api/v1/files/ and accepts flat id', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'id': 'owui-file-uuid-789',
          'filename': 'notes.txt',
          'size': 10,
        },
      );
      final api = _buildApiService(adapter, serverId: 'open_webui');
      final file = createTestFile('notes.txt', 'OpenWebUI');

      final fileId = await api.uploadFile(file.path, 'notes.txt');

      check(fileId).equals('owui-file-uuid-789');
      check(adapter.requestedPath).equals('/api/v1/files/');
      check(adapter.requestedMethod).equals('POST');
      check(adapter.requestedData).isA<FormData>();
      final formData = adapter.requestedData as FormData;
      check(formData.files.any((f) => f.key == 'file' && f.value.filename == 'notes.txt')).isTrue();
    });

    test('OpenWebUI uploadFileBytes uses /api/v1/files/ and accepts flat id', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'id': 'owui-bytes-uuid-101',
          'filename': 'notes_bytes.txt',
        },
      );
      final api = _buildApiService(adapter, serverId: 'default_server');

      final fileId = await api.uploadFileBytes(
        'notes_bytes.txt',
        utf8.encode('bytes data'),
      );

      check(fileId).equals('owui-bytes-uuid-101');
      check(adapter.requestedPath).equals('/api/v1/files/');
      check(adapter.requestedMethod).equals('POST');
      check(adapter.requestedData).isA<FormData>();
    });
  });

  group('Invalid responses fail explicitly without fallback shapes or numeric IDs', () {
    test('LobeHub rejects arbitrary numeric IDs in data.file.id', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'success': true,
          'data': {
            'file': {'id': 12345},
          },
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('num.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'num.txt'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        api.uploadFileBytes('num.txt', [1, 2, 3]),
        throwsA(isA<FormatException>()),
      );
    });

    test('LobeHub rejects missing data.file.id envelope', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'success': true,
          'data': {'file': <String, dynamic>{}},
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('missing.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'missing.txt'),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        api.uploadFileBytes('missing.txt', [1, 2, 3]),
        throwsA(isA<FormatException>()),
      );
    });

    test('LobeHub rejects undocumented flat id fallback', () async {
      final adapter = _UploadCaptureAdapter(
        response: {'id': 'flat-id-should-not-be-accepted-for-lobehub'},
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('flat_fallback.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'flat_fallback.txt'),
        throwsA(isA<FormatException>()),
      );
    });

    test('LobeHub rejects success: false with explicit failure', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'success': false,
          'message': 'Quota exceeded',
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('failed.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'failed.txt'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Quota exceeded'),
          ),
        ),
      );
    });

    test('OpenWebUI rejects arbitrary numeric ID', () async {
      final adapter = _UploadCaptureAdapter(response: {'id': 9999});
      final api = _buildApiService(adapter, serverId: 'open_webui');
      final file = createTestFile('num_owui.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'num_owui.txt'),
        throwsA(isA<FormatException>()),
      );
    });

    test('OpenWebUI rejects missing flat id', () async {
      final adapter = _UploadCaptureAdapter(response: {'status': 'uploaded'});
      final api = _buildApiService(adapter, serverId: 'open_webui');
      final file = createTestFile('no_id.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'no_id.txt'),
        throwsA(isA<FormatException>()),
      );
    });

    test('OpenWebUI rejects undocumented nested data.file.id fallback', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'data': {
            'file': {'id': 'nested-id-should-not-be-accepted-for-owui'},
          },
        },
      );
      final api = _buildApiService(adapter, serverId: 'open_webui');
      final file = createTestFile('nested_owui.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'nested_owui.txt'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty or whitespace file id', () async {
      final adapterLobe = _UploadCaptureAdapter(
        response: {
          'success': true,
          'data': {
            'file': {'id': '   '},
          },
        },
      );
      final apiLobe = _buildApiService(adapterLobe, serverId: 'lobehub_self_hosted');
      final fileLobe = createTestFile('empty_lobe.txt', 'test');

      await expectLater(
        apiLobe.uploadFile(fileLobe.path, 'empty_lobe.txt'),
        throwsA(isA<FormatException>()),
      );

      final adapterOwui = _UploadCaptureAdapter(response: {'id': ''});
      final apiOwui = _buildApiService(adapterOwui, serverId: 'open_webui');
      final fileOwui = createTestFile('empty_owui.txt', 'test');

      await expectLater(
        apiOwui.uploadFile(fileOwui.path, 'empty_owui.txt'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects non-map responses', () async {
      final adapter = _UploadCaptureAdapter(response: 'Not JSON Map');
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('non_map.txt', 'test');

      await expectLater(
        api.uploadFile(file.path, 'non_map.txt'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Request cancellation and non-2xx error handling', () {
    test('forwards request cancellation without swallowing', () async {
      final cancelToken = CancelToken();
      final adapter = _CancellingUploadAdapter();
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final file = createTestFile('cancel.txt', 'cancel me');

      final uploadFuture = api.uploadFile(
        file.path,
        'cancel.txt',
        cancelToken: cancelToken,
      );

      await adapter.requestReceived.future.timeout(const Duration(seconds: 1));
      cancelToken.cancel('Upload aborted by user');

      await expectLater(
        uploadFuture,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );

      await adapter.drainCompleted;
    });

    test('forwards non-2xx HTTP errors (400, 500) without retrying or swallowing', () async {
      final adapter400 = _UploadCaptureAdapter(
        response: {'detail': 'Invalid file format'},
        statusCode: 400,
      );
      final api400 = _buildApiService(adapter400, serverId: 'lobehub_self_hosted');
      final file = createTestFile('err.txt', 'content');

      await expectLater(
        api400.uploadFile(file.path, 'err.txt'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
      check(adapter400.requestCount).equals(1);

      final adapter500 = _UploadCaptureAdapter(
        response: {'detail': 'Server error'},
        statusCode: 500,
      );
      final api500 = _buildApiService(adapter500, serverId: 'open_webui');

      await expectLater(
        api500.uploadFile(file.path, 'err.txt'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
      check(adapter500.requestCount).equals(1);
    });
  });

  group('ApiService.getFileInfo response normalization', () {
    test('normalizes documented LobeHub data.file envelope for uploaded metadata', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'success': true,
          'data': {
            'file': {
              'id': 'lobe-file-doc-1',
              'name': 'document.pdf',
              'size': 2048,
              'fileType': 'application/pdf',
              'createdAt': 1713786305000,
              'updatedAt': 1713789905000,
            },
            'parsed': {
              'pages': 5,
              'extractedText': 'Preview of parsed document',
            },
          },
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final raw = await api.getFileInfo('lobe-file-doc-1');

      check(raw['id']).equals('lobe-file-doc-1');
      check(raw['filename']).equals('document.pdf');
      check(raw['original_filename']).equals('document.pdf');
      check(raw['size']).equals(2048);
      check(raw['content_type']).equals('application/pdf');
      check(raw['created_at']).equals(1713786305000);
      check(raw['updated_at']).equals(1713789905000);
      check(raw['metadata']).isA<Map>();
      final metadata = raw['metadata'] as Map;
      check(metadata['parsed']).isNotNull();

      final fileInfo = FileInfo.fromJson(raw);
      check(fileInfo.id).equals('lobe-file-doc-1');
      check(fileInfo.displayName).equals('document.pdf');
      check(fileInfo.size).equals(2048);
      check(fileInfo.mimeType).equals('application/pdf');
      check(fileInfo.metadata?['parsed']).isNotNull();
    });

    test('preserves flat OpenWebUI response shape', () async {
      final adapter = _UploadCaptureAdapter(
        response: {
          'id': 'owui-file-doc-2',
          'user_id': 'user-1',
          'filename': 'plain.txt',
          'original_filename': 'original_plain.txt',
          'content_type': 'text/plain',
          'size': 512,
          'created_at': 1713786305,
          'updated_at': 1713789905,
        },
      );
      final api = _buildApiService(adapter, serverId: 'open_webui');

      final raw = await api.getFileInfo('owui-file-doc-2');

      check(raw['id']).equals('owui-file-doc-2');
      check(raw['filename']).equals('plain.txt');
      check(raw['original_filename']).equals('original_plain.txt');
      check(raw['content_type']).equals('text/plain');
      check(raw['size']).equals(512);

      final fileInfo = FileInfo.fromJson(raw);
      check(fileInfo.id).equals('owui-file-doc-2');
      check(fileInfo.displayName).equals('original_plain.txt');
      check(fileInfo.size).equals(512);
      check(fileInfo.mimeType).equals('text/plain');
    });
  });
}

abstract interface class _TrackedUploadAdapter implements HttpClientAdapter {
  Future<void> get drainCompleted;
}

class _UploadCaptureAdapter implements _TrackedUploadAdapter {
  _UploadCaptureAdapter({
    required this.response,
    this.statusCode = 200,
  });

  final Object? response;
  final int statusCode;
  String? requestedPath;
  String? requestedMethod;
  dynamic requestedData;
  int requestCount = 0;
  final Completer<void> _drainCompleter = Completer<void>();

  @override
  Future<void> get drainCompleted => _drainCompleter.future;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    requestedPath = options.path;
    requestedMethod = options.method;
    requestedData = options.data;

    if (requestStream != null) {
      try {
        await requestStream.drain<void>();
      } catch (_) {}
    }
    if (!_drainCompleter.isCompleted) {
      _drainCompleter.complete();
    }

    final encoded = utf8.encode(jsonEncode(response));

    return ResponseBody(
      Stream.value(Uint8List.fromList(encoded)),
      statusCode,
      headers: const {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    if (!_drainCompleter.isCompleted) {
      _drainCompleter.complete();
    }
  }
}

class _CancellingUploadAdapter implements _TrackedUploadAdapter {
  final requestReceived = Completer<void>();
  final requestCancelled = Completer<void>();
  final Completer<void> _drainCompleter = Completer<void>();

  @override
  Future<void> get drainCompleted => _drainCompleter.future;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final streamFuture = () async {
      if (requestStream != null) {
        try {
          await requestStream.drain<void>();
        } catch (_) {}
      }
      await Future<void>.value();
      await Future<void>(() {});
      await Future<void>(() {});
    }();

    unawaited(
      streamFuture.whenComplete(() {
        if (!_drainCompleter.isCompleted) {
          _drainCompleter.complete();
        }
      }),
    );

    if (!requestReceived.isCompleted) {
      requestReceived.complete();
    }
    if (cancelFuture != null) {
      unawaited(
        cancelFuture.then<void>((_) {
          if (!requestCancelled.isCompleted) {
            requestCancelled.complete();
          }
        }),
      );
      await cancelFuture;
    }
    await streamFuture;
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      message: 'Request was cancelled',
    );
  }

  @override
  void close({bool force = false}) {
    if (!_drainCompleter.isCompleted) {
      _drainCompleter.complete();
    }
  }
}

final _activeAdapters = <_TrackedUploadAdapter>[];
final _activeApiServices = <ApiService>[];
final _activeWorkerManagers = <WorkerManager>[];

ApiService _buildApiService(
  HttpClientAdapter adapter, {
  required String serverId,
  String serverUrl = 'http://localhost:0',
}) {
  if (adapter is _TrackedUploadAdapter) {
    _activeAdapters.add(adapter);
  }
  final workerManager = WorkerManager();
  final service = ApiService(
    serverConfig: ServerConfig(
      id: serverId,
      name: serverId == 'lobehub_self_hosted' ? 'LobeHub' : 'OpenWebUI',
      url: serverUrl,
    ),
    workerManager: workerManager,
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  _activeApiServices.add(service);
  _activeWorkerManagers.add(workerManager);
  addTearDown(() async {
    if (adapter is _TrackedUploadAdapter) {
      await adapter.drainCompleted;
    }
    service.dio.close(force: true);
    workerManager.dispose();
  });
  return service;
}

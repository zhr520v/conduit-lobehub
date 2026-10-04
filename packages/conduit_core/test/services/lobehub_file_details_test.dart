import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() {
    for (final api in _activeApiServices) {
      api.dio.close(force: true);
    }
    _activeApiServices.clear();
    for (final worker in _activeWorkerManagers) {
      worker.dispose();
    }
    _activeWorkerManagers.clear();
  });

  group('ApiService.getFileInfo (LobeHub vs OpenWebUI)', () {
    test('LobeHub normalizes documented data.file envelope with ISO 8601 timestamps', () async {
      final adapter = _MockFileAdapter(
        handler: (options) {
          check(options.path).equals('/api/v1/files/lobe-file-iso-1');
          check(options.method).equals('GET');
          return _jsonResponse({
            'success': true,
            'data': {
              'file': {
                'id': 'lobe-file-iso-1',
                'name': 'document.pdf',
                'fileType': 'application/pdf',
                'size': 4096,
                'createdAt': '2026-04-20T10:00:00.000Z',
                'updatedAt': '2026-04-20T11:00:00.000Z',
                'url': 'https://s3.example.com/document.pdf',
                'metadata': {'pageCount': 10},
              },
              'parsed': {
                'pages': 10,
                'extractedText': 'Full PDF parsed text preview',
              },
            },
            'message': 'File details retrieved successfully',
          });
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final raw = await api.getFileInfo('lobe-file-iso-1');

      check(raw['id']).equals('lobe-file-iso-1');
      check(raw['filename']).equals('document.pdf');
      check(raw['original_filename']).equals('document.pdf');
      check(raw['size']).equals(4096);
      check(raw['content_type']).equals('application/pdf');
      check(raw['created_at']).equals('2026-04-20T10:00:00.000Z');
      check(raw['updated_at']).equals('2026-04-20T11:00:00.000Z');
      check(raw['metadata']).isA<Map>();
      final metadata = raw['metadata'] as Map;
      check(metadata['parsed']).isNotNull();
      check(metadata['url']).equals('https://s3.example.com/document.pdf');

      final fileInfo = FileInfo.fromJson(raw);
      check(fileInfo.id).equals('lobe-file-iso-1');
      check(fileInfo.displayName).equals('document.pdf');
      check(fileInfo.size).equals(4096);
      check(fileInfo.mimeType).equals('application/pdf');
      check(fileInfo.createdAt).equals(DateTime.parse('2026-04-20T10:00:00.000Z'));
      check(fileInfo.updatedAt).equals(DateTime.parse('2026-04-20T11:00:00.000Z'));
      check(fileInfo.metadata?['parsed']).isNotNull();
    });

    test('LobeHub normalizes documented data.file envelope with epoch ms timestamps', () async {
      final adapter = _MockFileAdapter(
        handler: (options) {
          check(options.path).equals('/api/v1/files/lobe-file-ms-2');
          return _jsonResponse({
            'success': true,
            'data': {
              'file': {
                'id': 'lobe-file-ms-2',
                'name': 'image.png',
                'fileType': 'image/png',
                'size': 8192,
                'createdAt': 1713786305000,
                'updatedAt': 1713789905000,
              },
            },
          });
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final raw = await api.getFileInfo('lobe-file-ms-2');

      check(raw['id']).equals('lobe-file-ms-2');
      check(raw['filename']).equals('image.png');
      check(raw['content_type']).equals('image/png');
      check(raw['size']).equals(8192);

      final fileInfo = FileInfo.fromJson(raw);
      check(fileInfo.id).equals('lobe-file-ms-2');
      check(fileInfo.displayName).equals('image.png');
      check(fileInfo.mimeType).equals('image/png');
      check(fileInfo.isImage).isTrue();
    });

    test('LobeHub rejects success: false with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': false,
          'error': 'File not found or permission denied',
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getFileInfo('non-existent'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('File not found or permission denied'),
          ),
        ),
      );
    });

    test('LobeHub rejects missing data.file envelope with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': true,
          'data': {'something_else': 123},
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getFileInfo('missing-file'),
        throwsA(isA<FormatException>()),
      );
    });

    test('LobeHub rejects invalid or numeric id in data.file with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': true,
          'data': {
            'file': {
              'id': 12345,
              'name': 'invalid.txt',
            },
          },
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getFileInfo('num-id'),
        throwsA(isA<FormatException>()),
      );
    });

    test('LobeHub rejects undocumented flat id fallback with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'id': 'flat-id-should-be-rejected-on-lobehub',
          'filename': 'flat.txt',
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getFileInfo('flat-fallback'),
        throwsA(isA<FormatException>()),
      );
    });

    test('OpenWebUI preserves flat response shape without requiring data.file envelope', () async {
      final adapter = _MockFileAdapter(
        handler: (options) {
          check(options.path).equals('/api/v1/files/owui-flat-3');
          return _jsonResponse({
            'id': 'owui-flat-3',
            'user_id': 'user-42',
            'filename': 'openwebui_doc.txt',
            'original_filename': 'original_doc.txt',
            'content_type': 'text/plain',
            'size': 128,
            'created_at': 1713786305,
            'updated_at': 1713789905,
          });
        },
      );
      final api = _buildApiService(adapter, serverId: 'open_webui');

      final raw = await api.getFileInfo('owui-flat-3');

      check(raw['id']).equals('owui-flat-3');
      check(raw['filename']).equals('openwebui_doc.txt');
      check(raw['original_filename']).equals('original_doc.txt');
      check(raw['content_type']).equals('text/plain');
      check(raw['size']).equals(128);

      final fileInfo = FileInfo.fromJson(raw);
      check(fileInfo.id).equals('owui-flat-3');
      check(fileInfo.displayName).equals('original_doc.txt');
      check(fileInfo.size).equals(128);
      check(fileInfo.mimeType).equals('text/plain');
    });
  });

  group('ApiService.getUserFilesPage & getUserFilesPageForSession (LobeHub vs OpenWebUI)', () {
    test('LobeHub requests /api/v1/files and unwraps data.files list with total', () async {
      final adapter = _MockFileAdapter(
        handler: (options) {
          check(options.path).equals('/api/v1/files');
          check(options.queryParameters['page']).equals(1);
          check(options.queryParameters.containsKey('content')).isFalse();
          return _jsonResponse({
            'success': true,
            'data': {
              'files': [
                {
                  'id': 'lobe-item-1',
                  'name': 'first.pdf',
                  'fileType': 'application/pdf',
                  'size': 1024,
                  'createdAt': '2026-04-20T10:00:00.000Z',
                  'updatedAt': '2026-04-20T10:30:00.000Z',
                  'url': 'https://s3.example.com/first.pdf',
                },
                {
                  'id': 'lobe-item-2',
                  'name': 'second.png',
                  'fileType': 'image/png',
                  'size': 2048,
                  'createdAt': '2026-04-20T11:00:00.000Z',
                  'updatedAt': '2026-04-20T11:30:00.000Z',
                  'url': 'https://s3.example.com/second.png',
                },
              ],
              'total': 2,
              'totalSize': '3072',
            },
            'message': 'Files retrieved successfully',
          });
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final result = await api.getUserFilesPageForSession(page: 1);

      check(result.isPaginated).isTrue();
      check(result.total).equals(2);
      check(result.items.length).equals(2);

      final first = result.items[0];
      check(first.id).equals('lobe-item-1');
      check(first.displayName).equals('first.pdf');
      check(first.mimeType).equals('application/pdf');
      check(first.size).equals(1024);
      check(first.metadata?['url']).equals('https://s3.example.com/first.pdf');

      final second = result.items[1];
      check(second.id).equals('lobe-item-2');
      check(second.displayName).equals('second.png');
      check(second.mimeType).equals('image/png');
      check(second.size).equals(2048);
      check(second.isImage).isTrue();
    });

    test('LobeHub rejects success: false on user files with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': false,
          'error': 'Unauthorized file list access',
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getUserFilesPageForSession(page: 1),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unauthorized file list access'),
          ),
        ),
      );
    });

    test('LobeHub rejects missing data.files with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': true,
          'data': {'items': []},
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getUserFilesPageForSession(page: 1),
        throwsA(isA<FormatException>()),
      );
    });

    test('LobeHub handles empty files: [] cleanly', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': true,
          'data': {
            'files': [],
            'total': 0,
          },
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final result = await api.getUserFilesPageForSession(page: 1);

      check(result.items).isEmpty();
      check(result.total).equals(0);
      check(result.isPaginated).isTrue();
    });

    test('OpenWebUI requests /api/v1/files/ with content: false and parses paginated collection', () async {
      final adapter = _MockFileAdapter(
        handler: (options) {
          check(options.path).equals('/api/v1/files/');
          check(options.queryParameters['content']).equals(false);
          check(options.queryParameters['page']).equals(1);
          return _jsonResponse({
            'items': [
              {
                'id': 'owui-item-1',
                'filename': 'owui_test.txt',
                'content_type': 'text/plain',
                'size': 64,
                'created_at': 1713786305,
                'updated_at': 1713789905,
              },
            ],
            'total': 1,
          });
        },
      );
      final api = _buildApiService(adapter, serverId: 'open_webui');

      final result = await api.getUserFilesPageForSession(page: 1);

      check(result.isPaginated).isTrue();
      check(result.total).equals(1);
      check(result.items.length).equals(1);
      check(result.items[0].id).equals('owui-item-1');
      check(result.items[0].displayName).equals('owui_test.txt');
    });
  });

  group('ApiService.getFileContent (LobeHub /:id/url flow vs OpenWebUI /content flow)', () {
    test('LobeHub requests /:id/url then downloads raw stream from returned URL without sending credentials', () async {
      final requestedUrls = <String>[];
      final headersPerRequest = <String, Map<String, List<String>>>{};

      final testBytes = utf8.encode('Hello LobeHub Secure Bytes');

      final adapter = _MockFileAdapter(
        handler: (options) {
          requestedUrls.add(options.path);
          headersPerRequest[options.path] = options.headers.map(
            (k, v) => MapEntry(k, [v.toString()]),
          );

          if (options.path == '/api/v1/files/lobe-content-1/url') {
            return _jsonResponse({
              'success': true,
              'data': {
                'url': 'https://s3.bucket.aws.com/files/lobe-content-1?X-Amz-Signature=abc123signed',
                'fileId': 'lobe-content-1',
                'name': 'document.txt',
                'expiresIn': 3600,
                'expiresAt': '2026-04-20T11:00:00.000Z',
              },
            });
          }

          if (options.path.startsWith('https://s3.bucket.aws.com/files/lobe-content-1')) {
            return _streamResponse(
              testBytes,
              contentType: 'text/plain; charset=utf-8',
            );
          }

          return _jsonResponse({}, statusCode: 404);
        },
      );

      final api = _buildApiService(
        adapter,
        serverId: 'lobehub_self_hosted',
        authToken: 'secret-bearer-token',
        clearInterceptors: false,
      );

      final content = await api.getFileContent('lobe-content-1');

      check(requestedUrls.length).equals(2);
      check(requestedUrls[0]).equals('/api/v1/files/lobe-content-1/url');
      check(requestedUrls[1]).startsWith('https://s3.bucket.aws.com/files/lobe-content-1');

      // Crucial: The S3 URL request MUST NOT have leaked the server's Authorization bearer token!
      final s3Headers = headersPerRequest[requestedUrls[1]] ?? {};
      check(s3Headers.containsKey('authorization')).isFalse();
      check(s3Headers.containsKey('Authorization')).isFalse();

      // Document is non-image, so raw base64 is returned
      final expectedBase64 = base64Encode(testBytes);
      check(content).equals(expectedBase64);
    });

    test('LobeHub getFileContent returns data URL for image content', () async {
      final imageBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]; // PNG header

      final adapter = _MockFileAdapter(
        handler: (options) {
          if (options.path == '/api/v1/files/img-file-1/url') {
            return _jsonResponse({
              'success': true,
              'data': {
                'url': 'https://s3.bucket.aws.com/files/img-file-1.png?signed=1',
                'fileId': 'img-file-1',
                'name': 'photo.png',
              },
            });
          }
          if (options.path.startsWith('https://s3.bucket.aws.com/files/img-file-1.png')) {
            return _streamResponse(imageBytes, contentType: 'image/png');
          }
          return _jsonResponse({}, statusCode: 404);
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final content = await api.getFileContent('img-file-1');

      final expectedBase64 = base64Encode(imageBytes);
      check(content).equals('data:image/png;base64,$expectedBase64');
    });

    test('LobeHub getFileContent enforces maxBytes cap and throws FileContentTooLargeException', () async {
      final bigBytes = List<int>.filled(5000, 42);

      final adapter = _MockFileAdapter(
        handler: (options) {
          if (options.path == '/api/v1/files/large-file/url') {
            return _jsonResponse({
              'success': true,
              'data': {
                'url': 'https://s3.bucket.aws.com/files/large-file',
                'fileId': 'large-file',
                'name': 'big.bin',
              },
            });
          }
          if (options.path.startsWith('https://s3.bucket.aws.com/files/large-file')) {
            return _streamResponse(
              bigBytes,
              contentType: 'application/octet-stream',
              contentLength: 5000,
            );
          }
          return _jsonResponse({}, statusCode: 404);
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getFileContent('large-file', maxBytes: 1000),
        throwsA(isA<FileContentTooLargeException>()),
      );
    });

    test('LobeHub getFileContent rejects success: false from /url with FormatException', () async {
      final adapter = _MockFileAdapter(
        handler: (options) => _jsonResponse({
          'success': false,
          'error': 'Permission denied for file url',
        }),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await expectLater(
        api.getFileContent('forbidden-file'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Permission denied for file url'),
          ),
        ),
      );
    });

    test('OpenWebUI preserves direct /api/v1/files/:id/content stream flow', () async {
      final testBytes = utf8.encode('OWUI Direct Stream');

      final adapter = _MockFileAdapter(
        handler: (options) {
          check(options.path).equals('/api/v1/files/owui-content-1/content');
          check(options.responseType).equals(ResponseType.stream);
          return _streamResponse(testBytes, contentType: 'text/plain');
        },
      );

      final api = _buildApiService(adapter, serverId: 'open_webui');

      final content = await api.getFileContent('owui-content-1');

      check(content).equals(base64Encode(testBytes));
    });
  });
}

class _MockFileAdapter implements HttpClientAdapter {
  _MockFileAdapter({required this.handler});

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      try {
        await requestStream.drain<void>();
      } catch (_) {}
    }
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object? body, {int statusCode = 200}) {
  final bytes = utf8.encode(jsonEncode(body));
  return ResponseBody(
    Stream.value(Uint8List.fromList(bytes)),
    statusCode,
    headers: {
      'content-type': ['application/json; charset=utf-8'],
    },
  );
}

ResponseBody _streamResponse(
  List<int> bytes, {
  required String contentType,
  int? contentLength,
  int statusCode = 200,
}) {
  final length = contentLength ?? bytes.length;
  return ResponseBody(
    Stream.value(Uint8List.fromList(bytes)),
    statusCode,
    headers: {
      'content-type': [contentType],
      'content-length': [length.toString()],
    },
  );
}

final _activeApiServices = <ApiService>[];
final _activeWorkerManagers = <WorkerManager>[];

ApiService _buildApiService(
  HttpClientAdapter adapter, {
  required String serverId,
  String serverUrl = 'http://localhost:3210',
  String? authToken = 'test-bearer-token',
  bool clearInterceptors = true,
}) {
  final workerManager = WorkerManager();
  final service = ApiService(
    serverConfig: ServerConfig(
      id: serverId,
      name: serverId == 'lobehub_self_hosted' ? 'LobeHub' : 'OpenWebUI',
      url: serverUrl,
    ),
    workerManager: workerManager,
    authToken: authToken,
  );
  service.dio.httpClientAdapter = adapter;
  if (clearInterceptors) {
    service.dio.interceptors.clear();
  }
  _activeApiServices.add(service);
  _activeWorkerManagers.add(workerManager);
  return service;
}

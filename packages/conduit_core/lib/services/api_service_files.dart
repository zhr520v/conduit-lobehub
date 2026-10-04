part of 'api_service.dart';

mixin _FilesApi on _ApiServiceBase {
  // Files
  Future<String> getFileContent(
    String fileId, {
    int? maxBytes,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    _traceApi('Fetching file content: $fileId');
    if (maxBytes != null && maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }
    // The Open-WebUI endpoint returns the raw file bytes with appropriate
    // Content-Type headers, not JSON. We must read bytes and base64-encode
    // them for consistent handling across platforms/widgets.
    // Dio wraps streamed response bodies. A request-local token is therefore
    // required to tear down the adapter's upstream subscription on a size
    // rejection; cancelling only the exposed body stream is insufficient. A
    // caller token may be shared, so it can cancel this token but never vice
    // versa.
    final cancellationLink = _FileContentCancellationLink(cancelToken);
    final requestCancelToken = cancellationLink.requestToken;
    try {
      final Response<ResponseBody> response;
      String? fallbackFileName;

      if (_isLobeHub) {
        // Step 1: Query documented LobeHub GET /files/:id/url endpoint
        // Routes plural files.route.ts has GET detail /:id /url, NOT /content.
        final urlResponse = await _dio.get(
          '/api/v1/files/$fileId/url',
          options: _withAuthSnapshot(Options(), authSnapshot),
          cancelToken: requestCancelToken,
        );
        final rawData = urlResponse.data;
        if (rawData is! Map) {
          throw const FormatException('Invalid file URL response: expected Map');
        }
        if (rawData['success'] == false) {
          final message = rawData['message'] ?? rawData['error'] ?? 'Unknown error';
          throw FormatException('Failed to get file URL on server: $message');
        }
        final data = rawData['data'];
        if (data is! Map) {
          throw const FormatException(
            'Invalid file URL response: missing data map in LobeHub getFileUrl',
          );
        }
        final rawUrl = data['url'];
        if (rawUrl is! String || rawUrl.trim().isEmpty) {
          throw const FormatException(
            'Invalid file URL response: missing or invalid url in LobeHub getFileUrl',
          );
        }
        final downloadUrl = rawUrl.trim();
        final rawName = data['name'];
        if (rawName is String && rawName.trim().isNotEmpty) {
          fallbackFileName = rawName.trim();
        }

        // Step 2: Stream bytes from downloadUrl without leaking server credentials
        // to S3 or cross-origin endpoints.
        response = await _dio.get<ResponseBody>(
          downloadUrl,
          options: Options(
            responseType: ResponseType.stream,
            headers: const {'Accept': '*/*'},
            extra: <String, dynamic>{
              ApiAuthInterceptor.candidateAuthTokenExtraKey: '',
            },
          ),
          cancelToken: requestCancelToken,
        );
      } else {
        response = await _dio.get<ResponseBody>(
          '/api/v1/files/$fileId/content',
          options: _withAuthSnapshot(
            Options(responseType: ResponseType.stream),
            authSnapshot,
          ),
          cancelToken: requestCancelToken,
        );
      }

      // Try to determine the mime type from response headers; fallback to text/plain
      final contentType =
          response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      String mimeType = 'text/plain';
      if (contentType.isNotEmpty && contentType != 'application/octet-stream') {
        // Strip charset if present
        mimeType = contentType.split(';').first.trim();
      } else if (fallbackFileName != null) {
        mimeType = _getMimeType(fallbackFileName) ?? 'text/plain';
      }

      final advertisedLength = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      final body = response.data;
      if (body == null) {
        throw const FormatException('File content response is empty.');
      }
      if (maxBytes != null &&
          advertisedLength != null &&
          advertisedLength > maxBytes) {
        requestCancelToken.cancel('File content exceeded the byte limit.');
        throw const FileContentTooLargeException();
      }
      final bytes = BytesBuilder(copy: false);
      var receivedBytes = 0;
      final iterator = StreamIterator<List<int>>(body.stream);
      try {
        // Per-chunk races must stay on the request-local token. Racing the
        // shared caller token here would attach one non-removable listener per
        // chunk instead of the single weak link above.
        while (await _moveFileContentStreamOrCancel(
          iterator,
          requestCancelToken,
        )) {
          final chunk = iterator.current;
          receivedBytes += chunk.length;
          if (maxBytes != null && receivedBytes > maxBytes) {
            throw const FileContentTooLargeException();
          }
          bytes.add(chunk);
        }
      } on FileContentTooLargeException {
        requestCancelToken.cancel('File content exceeded the byte limit.');
        rethrow;
      } finally {
        _cancelFileContentStreamIterator(iterator);
      }

      final base64Data = base64Encode(bytes.takeBytes());

      // For images, return a data URL so UI can render directly; otherwise return raw base64
      if (mimeType.startsWith('image/')) {
        return 'data:$mimeType;base64,$base64Data';
      }

      return base64Data;
    } finally {
      cancellationLink.detach();
    }
  }

  Future<Map<String, dynamic>> getFileInfo(
    String fileId, {
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    _traceApi('Fetching file info: $fileId');
    final response = await _dio.get(
      '/api/v1/files/$fileId',
      options: _withAuthSnapshot(Options(), authSnapshot),
      cancelToken: cancelToken,
    );
    final rawData = response.data;
    if (rawData is! Map) {
      throw const FormatException('Invalid file info response: expected Map');
    }
    return _normalizeFileInfoResponse(rawData);
  }

  Map<String, dynamic> _normalizeLobeHubFileItem(Map fileField) {
    final id = fileField['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException(
        'Invalid response format: missing or invalid file ID in LobeHub file',
      );
    }
    final name = fileField['name'] ?? fileField['filename'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException(
        'Invalid response format: missing or invalid filename in LobeHub file',
      );
    }
    final normalized = Map<String, dynamic>.from(fileField);
    normalized['id'] = id.trim();
    normalized['filename'] = name.trim();
    normalized['original_filename'] = (normalized['original_filename'] ??
            normalized['originalFilename'] ??
            normalized['filename'])
        .toString()
        .trim();
    if (normalized['content_type'] == null) {
      if (normalized['fileType'] != null) {
        normalized['content_type'] = normalized['fileType'];
      } else if (normalized['mimeType'] != null) {
        normalized['content_type'] = normalized['mimeType'];
      }
    }
    if (normalized['created_at'] == null && normalized['createdAt'] != null) {
      normalized['created_at'] = normalized['createdAt'];
    }
    if (normalized['updated_at'] == null && normalized['updatedAt'] != null) {
      normalized['updated_at'] = normalized['updatedAt'];
    }
    final existingMeta = normalized['metadata'] ?? normalized['meta'];
    final metaMap = existingMeta is Map
        ? Map<String, dynamic>.from(existingMeta)
        : <String, dynamic>{};
    if (normalized['url'] != null && !metaMap.containsKey('url')) {
      metaMap['url'] = normalized['url'];
    }
    normalized['metadata'] = metaMap;
    return normalized;
  }

  Map<String, dynamic> _normalizeFileInfoResponse(Map rawData) {
    if (_isLobeHub) {
      if (rawData['success'] == false) {
        final message = rawData['message'] ?? rawData['error'] ?? 'Unknown error';
        throw FormatException('Failed to get file info on server: $message');
      }
      final dataField = rawData['data'];
      if (dataField is! Map) {
        throw const FormatException(
          'Invalid file info response: missing data envelope in LobeHub getFileInfo',
        );
      }
      final fileField = dataField['file'];
      if (fileField is! Map) {
        throw const FormatException(
          'Invalid file info response: missing data.file envelope in LobeHub getFileInfo',
        );
      }
      final normalized = _normalizeLobeHubFileItem(fileField);
      if (dataField['parsed'] != null) {
        final metaMap = normalized['metadata'] is Map
            ? Map<String, dynamic>.from(normalized['metadata'] as Map)
            : <String, dynamic>{};
        if (!metaMap.containsKey('parsed')) {
          metaMap['parsed'] = dataField['parsed'];
        }
        normalized['metadata'] = metaMap;
      }
      return normalized;
    }

    final dataField = rawData['data'];
    if (dataField is Map) {
      final fileField = dataField['file'];
      if (fileField is Map) {
        final normalized = Map<String, dynamic>.from(fileField);
        if (normalized['filename'] == null && normalized['name'] != null) {
          normalized['filename'] = normalized['name'];
        }
        if (normalized['original_filename'] == null &&
            normalized['filename'] != null) {
          normalized['original_filename'] = normalized['filename'];
        }
        if (normalized['content_type'] == null) {
          if (normalized['fileType'] != null) {
            normalized['content_type'] = normalized['fileType'];
          } else if (normalized['mimeType'] != null) {
            normalized['content_type'] = normalized['mimeType'];
          }
        }
        if (normalized['created_at'] == null &&
            normalized['createdAt'] != null) {
          normalized['created_at'] = normalized['createdAt'];
        }
        if (normalized['updated_at'] == null &&
            normalized['updatedAt'] != null) {
          normalized['updated_at'] = normalized['updatedAt'];
        }
        if (dataField['parsed'] != null) {
          final existingMeta = normalized['metadata'] ?? normalized['meta'];
          final metaMap = existingMeta is Map
              ? Map<String, dynamic>.from(existingMeta)
              : <String, dynamic>{};
          if (!metaMap.containsKey('parsed')) {
            metaMap['parsed'] = dataField['parsed'];
          }
          normalized['metadata'] = metaMap;
        }
        return normalized;
      }
    }
    return Map<String, dynamic>.from(rawData);
  }

  Future<List<FileInfo>> getUserFilesForSession({
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) => _getUserFilesWith(
    (page) => getUserFilesPageForSession(
      page: page,
      authSnapshot: authSnapshot,
      cancelToken: cancelToken,
    ),
  );

  /// Fetches a single page of the current user's files.
  ///
  /// Supports both the current paginated OpenWebUI response shape and the
  /// legacy plain-list payload used by older servers.
  Future<({List<FileInfo> items, int? total, bool isPaginated})>
  getUserFilesPage({int page = 1}) => getUserFilesPageForSession(page: page);
  Future<({List<FileInfo> items, int? total, bool isPaginated})>
  getUserFilesPageForSession({
    int page = 1,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    if (_isLobeHub) {
      final response = await _dio.get(
        '/api/v1/files',
        queryParameters: {'page': page},
        options: _withAuthSnapshot(Options(), authSnapshot),
        cancelToken: cancelToken,
      );
      final rawData = response.data;
      if (rawData is! Map) {
        throw const FormatException('Invalid user files response: expected Map');
      }
      if (rawData['success'] == false) {
        final message = rawData['message'] ?? rawData['error'] ?? 'Unknown error';
        throw FormatException('Failed to get user files on server: $message');
      }
      final dataField = rawData['data'];
      if (dataField is! Map) {
        throw const FormatException(
          'Invalid user files response: missing data envelope in LobeHub getFiles',
        );
      }
      final filesList = dataField['files'];
      if (filesList is! List) {
        throw const FormatException(
          'Invalid user files response: missing data.files list in LobeHub getFiles',
        );
      }
      final totalValue = dataField['total'];
      final total = switch (totalValue) {
        int raw => raw,
        num raw => raw.toInt(),
        String raw => int.tryParse(raw),
        _ => null,
      };
      final items = <FileInfo>[];
      for (final item in filesList) {
        if (item is! Map) {
          throw const FormatException(
            'Invalid user files response: expected file item Map in data.files',
          );
        }
        final normalized = _normalizeLobeHubFileItem(item);
        items.add(FileInfo.fromJson(normalized));
      }
      return (
        items: List<FileInfo>.unmodifiable(items),
        total: total,
        isPaginated: true,
      );
    }

    final response = await _dio.get(
      '/api/v1/files/',
      queryParameters: {'page': page, 'content': false},
      options: _withAuthSnapshot(Options(), authSnapshot),
      cancelToken: cancelToken,
    );
    return _parseFileInfoCollection(
      response.data,
      debugLabel: 'parse_file_list_page_$page',
    );
  }

  // Enhanced File Operations
  Future<List<FileInfo>> searchFiles({
    String? query,
    String? contentType,
    int? limit,
    int? offset,
  }) async =>
      await searchFilesForSession(
        query: query,
        contentType: contentType,
        limit: limit,
        offset: offset,
      ) ??
      const <FileInfo>[];

  /// Searches the current user's files while keeping a long-running operation
  /// pinned to its originating auth session.
  ///
  /// Returns null when the server does not expose the file-search endpoint, so
  /// callers that require compatibility with older OpenWebUI releases can fall
  /// back to paginated listing. A supported search with no matches returns an
  /// empty list.
  Future<List<FileInfo>?> searchFilesForSession({
    String? query,
    String? contentType,
    int? limit,
    int? offset,
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    _traceApi('Searching files with query: $query');
    final trimmedQuery = query?.trim();
    if (trimmedQuery == null || trimmedQuery.isEmpty) {
      return const <FileInfo>[];
    }

    final queryParams = <String, dynamic>{};
    queryParams['filename'] = trimmedQuery.contains('*')
        ? trimmedQuery
        : '*$trimmedQuery*';
    queryParams['content'] = false;
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['skip'] = offset;

    try {
      final response = await _dio.get(
        '/api/v1/files/search',
        queryParameters: queryParams,
        options: _withAuthSnapshot(Options(), authSnapshot),
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data is List) {
        final normalized = await _normalizeList(
          data,
          debugLabel: 'parse_file_search',
        );
        var results = normalized.map(FileInfo.fromJson).toList(growable: false);
        if (contentType != null && contentType.trim().isNotEmpty) {
          results = results
              .where((file) => file.mimeType.startsWith(contentType))
              .toList(growable: false);
        }
        return results;
      }
      return const <FileInfo>[];
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        final responseData = error.response?.data;
        final detail = responseData is Map ? responseData['detail'] : null;
        if (detail == 'No files found matching the pattern.') {
          return const <FileInfo>[];
        }
        return null;
      }
      rethrow;
    }
  }

  Future<void> deleteFile(String fileId) async {
    _traceApi('Deleting file: $fileId');
    await _dio.delete('/api/v1/files/$fileId');
  }

  /// Renames a file on the server; the only file field Open WebUI lets a
  /// client change after upload.
  Future<Map<String, dynamic>> renameFile(
    String fileId,
    String filename,
  ) async {
    _traceApi('Renaming file: $fileId');
    final response = await _dio.post(
      '/api/v1/files/$fileId/rename',
      data: {'filename': filename},
    );
    return response.data as Map<String, dynamic>;
  }

  bool get _isLobeHub => serverConfig.id == 'lobehub_self_hosted';

  String _parseUploadResponse(dynamic responseData) {
    if (responseData is! Map) {
      throw const FormatException('Invalid response format: missing file ID');
    }
    if (_isLobeHub) {
      if (responseData['success'] == false) {
        final message = responseData['message'] ?? responseData['error'];
        throw FormatException('Upload failed on server: $message');
      }
      final data = responseData['data'];
      if (data is Map) {
        final file = data['file'];
        if (file is Map) {
          final id = file['id'];
          if (id is String && id.trim().isNotEmpty) {
            return id.trim();
          }
        }
      }
      throw const FormatException(
        'Invalid response format: missing or invalid file ID in data.file.id',
      );
    } else {
      final id = responseData['id'];
      if (id is String && id.trim().isNotEmpty) {
        return id.trim();
      }
      throw const FormatException(
        'Invalid response format: missing or invalid file ID',
      );
    }
  }

  /// Uploads an in-memory file to `/files/` (or `/files` on LobeHub) and
  /// returns the new file id. Used by the workspace knowledge browser for both
  /// binary uploads and generated text files. Mirrors [uploadFile] but takes
  /// bytes directly.
  Future<String> uploadFileBytes(
    String fileName,
    List<int> bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Uploading file bytes: $fileName (${bytes.length} bytes)');
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: fileName),
    });
    final uploadPath = _isLobeHub ? '/api/v1/files' : '/api/v1/files/';
    final response = await _dio.post(
      uploadPath,
      data: formData,
      cancelToken: cancelToken,
      options: _withAuthSnapshot(Options(), authSnapshot),
      onSendProgress: onProgress,
    );
    final fileId = _parseUploadResponse(response.data);
    _traceApi('File uploaded bytes successfully with ID: $fileId');
    return fileId;
  }

  // File upload for RAG
  Future<String> uploadFile(
    String filePath,
    String fileName, {
    String? contentType,
    Map<String, dynamic>? metadata,
    CancelToken? cancelToken,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Starting file upload: $fileName from $filePath');

    try {
      // Check if file exists
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('File does not exist: $filePath');
      }
      final fileSize = await file.length();
      final uploadTimeout = _fileUploadTimeoutForBytes(fileSize);

      // Determine content type from file extension if not provided
      final mimeType = contentType ?? _getMimeType(fileName);

      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          filePath,
          filename: fileName,
          contentType: mimeType != null ? DioMediaType.parse(mimeType) : null,
        ),
        if (metadata != null && metadata.isNotEmpty)
          'metadata': jsonEncode(metadata),
      });

      final uploadPath = _isLobeHub ? '/api/v1/files' : '/api/v1/files/';
      _traceApi('Uploading to $uploadPath');
      final response = await _dio.post(
        uploadPath,
        data: formData,
        cancelToken: cancelToken,
        options: _withAuthSnapshot(
          Options(sendTimeout: uploadTimeout, receiveTimeout: uploadTimeout),
          authSnapshot,
        ),
      );

      DebugLogger.log(
        'upload-status',
        scope: 'api/files',
        data: {'code': response.statusCode},
      );
      DebugLogger.log('upload-ok', scope: 'api/files');

      final fileId = _parseUploadResponse(response.data);
      _traceApi('File uploaded successfully with ID: $fileId');
      return fileId;
    } catch (e) {
      DebugLogger.error('upload-failed', scope: 'api/files', error: e);
      rethrow;
    }
  }
}

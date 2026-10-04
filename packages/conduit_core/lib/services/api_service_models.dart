part of 'api_service.dart';

mixin _ModelsApi on _ApiServiceBase {
  bool get _isLobeHub => serverConfig.id == 'lobehub_self_hosted';

  // Models
  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    Response? response;
    if (_isLobeHub) {
      response = await _dio.get('/api/v1/models');
    } else {
      try {
        response = await _dio.get('/api/v1/models');
      } catch (_) {
        try {
          response = await _dio.get('/api/models');
        } catch (e) {
          DebugLogger.error(
            'models-fetch-failed',
            scope: 'api/models',
            error: e,
          );
        }
      }
    }

    if (response == null) {
      return const [];
    }

    // Normalize common response formats:
    // - {"data": {"models": [...]}} (LobeHub)
    // - {"data": [...]} (OpenAI)
    // - {"models": [...]} (some proxies)
    // - [...] (raw array)
    // - String payloads that need JSON decoding
    dynamic payload = response.data;
    if (payload is String) {
      try {
        payload = json.decode(payload);
      } catch (_) {}
    }

    final payloadMap = _coerceJsonMap(payload);
    if (_isLobeHub && payloadMap != null && payloadMap['success'] == false) {
      final message =
          payloadMap['message'] ?? payloadMap['error'] ?? 'Unknown error';
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
        error: message,
        message: 'LobeHub models fetch failed: $message',
      );
    }

    List<dynamic>? rawModels;
    if (payloadMap != null) {
      final innerData = _coerceJsonMap(payloadMap['data']);
      rawModels =
          _asListOrNull(innerData?['models']) ??
          _asListOrNull(payloadMap['data']) ??
          _asListOrNull(payloadMap['models']);
    } else {
      rawModels = _asListOrNull(payload);
    }

    if (rawModels == null) {
      DebugLogger.error(
        'models-format',
        scope: 'api/models',
        data: {'type': payload.runtimeType},
      );
      if (_isLobeHub) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          error: 'Invalid LobeHub models response format',
          message: 'Invalid LobeHub models response format',
        );
      }
      return const [];
    }

    final models = <Model>[];
    var hiddenModelCount = 0;
    for (final raw in rawModels) {
      try {
        if (raw is String) {
          models.add(Model(
            id: raw,
            name: raw,
            supportsStreaming: _isLobeHub ? false : true,
          ));
          continue;
        }
        if (raw is Map) {
          final normalized = raw.map(
            (key, value) => MapEntry(key.toString(), value),
          );

          final providerId = (normalized['providerId'] ??
                  normalized['provider_id'] ??
                  normalized['provider'] ??
                  normalized['owned_by'])
              ?.toString();
          final displayName = (normalized['displayName'] ??
                  normalized['display_name'] ??
                  normalized['name'])
              ?.toString();
          final modelId = (normalized['id'] ??
                  normalized['model_id'] ??
                  normalized['modelId'])
              ?.toString();

          if (_isLobeHub) {
            normalized['supportsStreaming'] = false;
            normalized['supports_streaming'] = false;
            if (providerId != null && providerId.isNotEmpty) {
              normalized['owned_by'] ??= providerId;
              normalized['provider'] ??= providerId;
              normalized['providerId'] ??= providerId;
            }
            if (displayName != null && displayName.isNotEmpty) {
              normalized['name'] ??= displayName;
              normalized['displayName'] ??= displayName;
            }
            if (modelId != null && modelId.isNotEmpty) {
              normalized['id'] = modelId;
            }

            final abilities = normalized['abilities'];
            if (abilities is Map) {
              if (abilities['vision'] == true) {
                normalized['isMultimodal'] ??= true;
                normalized['is_multimodal'] ??= true;
              }
              if (normalized['capabilities'] == null) {
                normalized['capabilities'] =
                    Map<String, dynamic>.from(abilities);
              }
            }
            if (normalized['contextWindowTokens'] != null) {
              normalized['context_length'] ??=
                  normalized['contextWindowTokens'];
            }
            if (normalized['enabled'] == false) {
              normalized['hidden'] ??= true;
            }
          } else {
            if (normalized['name'] == null &&
                normalized['displayName'] != null) {
              normalized['name'] = normalized['displayName'];
            }
          }

          final existingMeta = (normalized['metadata'] is Map)
              ? Map<String, dynamic>.from(normalized['metadata'] as Map)
              : <String, dynamic>{};
          if (providerId != null && providerId.isNotEmpty) {
            existingMeta['provider'] ??= providerId;
            existingMeta['providerId'] ??= providerId;
            existingMeta['provider_id'] ??= providerId;
            existingMeta['owned_by'] ??= providerId;
          }
          if (displayName != null && displayName.isNotEmpty) {
            existingMeta['displayName'] ??= displayName;
            existingMeta['display_name'] ??= displayName;
          }
          if (modelId != null && modelId.isNotEmpty) {
            existingMeta['modelId'] ??= modelId;
            existingMeta['id'] ??= modelId;
          }
          if (_isLobeHub) {
            if (normalized['type'] != null) {
              existingMeta['type'] ??= normalized['type'];
            }
            if (normalized['source'] != null) {
              existingMeta['source'] ??= normalized['source'];
            }
            if (normalized['sort'] != null) {
              existingMeta['sort'] ??= normalized['sort'];
            }
          }
          normalized['metadata'] = existingMeta;

          final model = Model.fromJson(normalized);
          if (model.isHidden) {
            hiddenModelCount++;
          }
          if (model.isHidden && !includeHidden) {
            continue;
          }
          models.add(model);
          continue;
        }
        DebugLogger.warning(
          'models-entry-unknown',
          scope: 'api/models',
          data: {'type': raw.runtimeType},
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'model-parse-failed',
          scope: 'api/models',
          error: error,
          stackTrace: stackTrace,
          data: {'type': raw.runtimeType},
        );
      }
    }

    DebugLogger.log(
      'models-count',
      scope: 'api/models',
      data: {'count': models.length, 'hidden': hiddenModelCount},
    );
    return models;
  }

  // Get default model configuration from OpenWebUI user settings
  Future<String?> getDefaultModel() async {
    if (_isLobeHub) {
      final models = await getModels();
      return models.isNotEmpty ? models.first.id : null;
    }

    try {
      final settings = await getServerUserSettingsModel();
      final defaultModel = settings.defaultModelId;
      if (defaultModel != null) {
        DebugLogger.log(
          'default-model',
          scope: 'api/user-settings',
          data: {'id': defaultModel, 'source': 'user-settings'},
        );
        return defaultModel;
      }
    } catch (e) {
      DebugLogger.error(
        'default-model-error',
        scope: 'api/user-settings',
        error: e,
      );
    }

    try {
      final response = await _dio.get('/api/config');
      final config = _coerceResponseMap(response.data);
      final defaultModels = _coerceConfigStringList(config?['default_models']);
      if (defaultModels.isNotEmpty) {
        final defaultModel = defaultModels.first;
        DebugLogger.log(
          'default-model',
          scope: 'api/user-settings',
          data: {'id': defaultModel, 'source': 'server-config'},
        );
        return defaultModel;
      }
    } catch (e) {
      DebugLogger.error(
        'default-model-config-error',
        scope: 'api/user-settings',
        error: e,
      );
    }

    DebugLogger.log('default-model-fallback', scope: 'api/user-settings');
    return _getFirstAvailableModelId();
  }

  // Get detailed model information
  Future<Map<String, dynamic>?> getModelDetails(String modelId) async {
    if (_isLobeHub) {
      final models = await getModels(includeHidden: true);
      for (final model in models) {
        if (model.id == modelId) {
          return model.toJson();
        }
      }
      return null;
    }

    try {
      final response = await _dio.get(
        '/api/v1/models/model',
        queryParameters: {'id': modelId},
      );

      if (response.statusCode == 200 && response.data != null) {
        final modelData = response.data as Map<String, dynamic>;
        DebugLogger.log('details', scope: 'api/models', data: {'id': modelId});
        return modelData;
      }
    } catch (e) {
      _traceApi('Failed to get model details for $modelId: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> updateModel(Map<String, dynamic> model) async {
    if (_isLobeHub) return null;

    final payload = <String, dynamic>{
      'id': model['id'],
      'base_model_id': model['base_model_id'],
      'name': model['name'],
      'meta': _coerceJsonMap(model['meta']) ?? <String, dynamic>{},
      'params': _coerceJsonMap(model['params']) ?? <String, dynamic>{},
      'access_grants': model['access_grants'],
      'is_active': model['is_active'],
    };
    payload.removeWhere((_, value) => value == null);

    final response = await _dio.post(
      '/api/v1/models/model/update',
      data: payload,
    );
    final data = response.data;
    return data is Map<String, dynamic> ? data : null;
  }

  Future<Map<String, dynamic>?> updateModelSystemPrompt(
    String modelId,
    String? systemPrompt,
  ) async {
    if (_isLobeHub) {
      throw StateError('Model "$modelId" has no editable server record.');
    }

    final model = await getModelDetails(modelId);
    if (model == null) {
      throw StateError('Model "$modelId" has no editable server record.');
    }

    final params = _coerceJsonMap(model['params']) ?? <String, dynamic>{};
    final trimmed = systemPrompt?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      params.remove('system');
    } else {
      params['system'] = trimmed;
    }

    final updated = await updateModel({...model, 'params': params});
    if (updated == null) {
      throw StateError('Model "$modelId" update returned no server record.');
    }
    return updated;
  }

  Future<WorkspacePagedResponse<WorkspaceModelSummary>> getWorkspaceModels({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async {
    if (_isLobeHub) {
      return const WorkspacePagedResponse(items: [], total: 0);
    }

    final response = await _dio.get(
      '/api/v1/models/list',
      queryParameters: _workspaceListQuery(
        query: query,
        viewOption: viewOption,
        tag: tag,
        orderBy: orderBy,
        direction: direction,
        page: page,
      ),
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspaceModelSummary.fromJson,
    );
  }

  Future<WorkspaceModelDetail?> getWorkspaceModel(String id) async {
    if (_isLobeHub) return null;

    final response = await _dio.get(
      '/api/v1/models/model',
      queryParameters: {'id': id},
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceModelDetail?> createWorkspaceModel(
    WorkspaceModelForm form,
  ) async {
    if (_isLobeHub) return null;

    final response = await _dio.post(
      '/api/v1/models/create',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceModelDetail?> updateWorkspaceModel(
    WorkspaceModelForm form,
  ) async {
    if (_isLobeHub) return null;

    final response = await _dio.post(
      '/api/v1/models/model/update',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceModelDetail?> updateWorkspaceModelAccess(
    String id,
    String name,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    if (_isLobeHub) return null;

    final response = await _dio.post(
      '/api/v1/models/model/access/update',
      data: {
        'id': id,
        'name': name,
        'access_grants': workspaceGrantInputs(grants),
      },
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<List<WorkspaceModelDetail>> exportWorkspaceModels() async {
    if (_isLobeHub) return const [];

    final response = await _dio.get('/api/v1/models/export');
    return workspaceJsonList(response.data)
        .map(WorkspaceModelSummary.fromJson)
        .toList(growable: false);
  }

  Future<bool> importWorkspaceModels(List<Map<String, dynamic>> models) async {
    if (_isLobeHub) return false;

    final response = await _dio.post(
      '/api/v1/models/import',
      data: {'models': models},
    );
    return response.data == true;
  }

  Future<List<WorkspaceModelDetail>> syncWorkspaceModels() async {
    if (_isLobeHub) return const [];

    final response = await _dio.post('/api/v1/models/sync');
    return workspaceJsonList(response.data)
        .map(WorkspaceModelSummary.fromJson)
        .toList(growable: false);
  }

  /// Base models available to compose custom workspace models from. Open WebUI
  /// serves these at `/api/v1/models/base` (the raw connections/pipelines,
  /// distinct from the user-facing `/models/list`).
  Future<List<WorkspaceModelSummary>> getWorkspaceBaseModels() async {
    if (_isLobeHub) return const [];

    final response = await _dio.get('/api/v1/models/base');
    return workspaceJsonList(response.data)
        .map(WorkspaceModelSummary.fromJson)
        .toList(growable: false);
  }

  /// Fetches a model's profile image bytes from the dedicated
  /// `/api/v1/models/model/profile/image` endpoint. Returns null when the
  /// server has no stored image (or serves a redirect to a remote URL).
  Future<List<int>?> getWorkspaceModelProfileImage(String id) async {
    if (_isLobeHub) return null;

    try {
      final response = await _dio.get<List<int>>(
        '/api/v1/models/model/profile/image',
        queryParameters: {'id': id},
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final data = response.data;
      return data == null || data.isEmpty ? null : data;
    } on DioException {
      return null;
    }
  }

  Future<WorkspaceModelDetail?> toggleWorkspaceModel(String id) async {
    if (_isLobeHub) return null;

    final response = await _dio.post(
      '/api/v1/models/model/toggle',
      queryParameters: {'id': id},
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<bool> deleteWorkspaceModel(String id) async {
    if (_isLobeHub) return false;

    final response = await _dio.post(
      '/api/v1/models/model/delete',
      data: {'id': id},
    );
    return response.data == true;
  }
}

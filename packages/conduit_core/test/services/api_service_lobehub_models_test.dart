import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('LobeHub ApiService.getModels contract & roster cleanup', () {
    test('fetches real LLM IDs only from /api/v1/models, reports supportsStreaming false, preserves provider', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': true,
            'data': {
              'models': [
                {
                  'id': 'gpt-4o',
                  'providerId': 'openai',
                  'displayName': 'GPT-4o',
                  'description': 'OpenAI flagship model',
                  'type': 'chat',
                  'enabled': true,
                  'abilities': {
                    'functionCall': true,
                    'reasoning': false,
                    'vision': true,
                  },
                  'contextWindowTokens': 128000,
                },
                {
                  'id': 'claude-3-5-sonnet-20241022',
                  'providerId': 'anthropic',
                  'displayName': 'Claude 3.5 Sonnet',
                  'description': 'Anthropic powerful model',
                  'type': 'chat',
                  'enabled': true,
                  'abilities': {
                    'functionCall': true,
                    'vision': true,
                  },
                  'contextWindowTokens': 200000,
                },
              ],
              'total': 2,
            },
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final models = await api.getModels();

      // Only real models returned, exactly 2
      check(models.length).equals(2);

      // Model 1: gpt-4o
      final gpt4o = models[0];
      check(gpt4o.id).equals('gpt-4o');
      check(gpt4o.name).equals('GPT-4o');
      check(gpt4o.supportsStreaming).isFalse();
      check(gpt4o.isMultimodal).isTrue();
      check(gpt4o.metadata?['provider']).equals('openai');
      check(gpt4o.metadata?['providerId']).equals('openai');
      check(gpt4o.metadata?['owned_by']).equals('openai');
      check(gpt4o.metadata?['displayName']).equals('GPT-4o');
      check(gpt4o.metadata?['modelId']).equals('gpt-4o');

      // Model 2: claude-3-5-sonnet-20241022
      final claude = models[1];
      check(claude.id).equals('claude-3-5-sonnet-20241022');
      check(claude.name).equals('Claude 3.5 Sonnet');
      check(claude.supportsStreaming).isFalse();
      check(claude.isMultimodal).isTrue();
      check(claude.metadata?['provider']).equals('anthropic');
      check(claude.metadata?['providerId']).equals('anthropic');
      check(claude.metadata?['owned_by']).equals('anthropic');
      check(claude.metadata?['displayName']).equals('Claude 3.5 Sonnet');
      check(claude.metadata?['modelId']).equals('claude-3-5-sonnet-20241022');

      // Crucial: No /api/v1/agents or /api/models requests made
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/v1/agents')).isFalse();
      check(adapter.requestPaths.contains('/api/models')).isFalse();

      // No agent source metadata present on models
      check(gpt4o.metadata?['source']).not((s) => s.equals('lobehub-agent'));
      check(claude.metadata?['source']).not((s) => s.equals('lobehub-agent'));
    });

    test('respects enabled: false as hidden model', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': true,
            'data': {
              'models': [
                {
                  'id': 'gpt-4o',
                  'providerId': 'openai',
                  'displayName': 'GPT-4o',
                  'enabled': true,
                },
                {
                  'id': 'deprecated-model',
                  'providerId': 'openai',
                  'displayName': 'Deprecated Model',
                  'enabled': false,
                },
              ],
            },
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final activeModels = await api.getModels(includeHidden: false);
      check(activeModels.length).equals(1);
      check(activeModels.first.id).equals('gpt-4o');

      final allModels = await api.getModels(includeHidden: true);
      check(allModels.length).equals(2);
      check(allModels[1].isHidden).isTrue();
    });
  });

  group('LobeHub error propagation (no bogus /api/models fallback)', () {
    test('propagates HTTP 401 Unauthorized without calling /api/models', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse(
            {'success': false, 'error': 'Unauthorized'},
            statusCode: 401,
          );
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await check(api.getModels()).throws<DioException>();
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/models')).isFalse();
    });

    test('propagates HTTP 403 Forbidden without calling /api/models', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse(
            {'success': false, 'error': 'Forbidden'},
            statusCode: 403,
          );
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await check(api.getModels()).throws<DioException>();
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/models')).isFalse();
    });

    test('propagates HTTP 500 Server Error without calling /api/models', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse(
            {'success': false, 'error': 'Internal Server Error'},
            statusCode: 500,
          );
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await check(api.getModels()).throws<DioException>();
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/models')).isFalse();
    });

    test('propagates success: false payload without calling /api/models', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': false,
            'error': 'API quota exhausted',
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await check(api.getModels()).throws<DioException>();
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/models')).isFalse();
    });
  });

  group('LobeHub getDefaultModel resolution', () {
    test('returns first known actual model without requesting /api/config or user settings', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': true,
            'data': {
              'models': [
                {
                  'id': 'gpt-4o',
                  'providerId': 'openai',
                  'displayName': 'GPT-4o',
                },
                {
                  'id': 'claude-3-5-sonnet',
                  'providerId': 'anthropic',
                  'displayName': 'Claude 3.5',
                },
              ],
            },
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final defaultModel = await api.getDefaultModel();

      check(defaultModel).equals('gpt-4o');
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/config')).isFalse();
      check(adapter.requestPaths.contains('/api/v1/users/user/settings')).isFalse();
    });

    test('returns null when model roster is empty without extra requests', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': true,
            'data': {'models': []},
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final defaultModel = await api.getDefaultModel();

      check(defaultModel).isNull();
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
    });
  });

  group('LobeHub getModelDetails resolution', () {
    test('resolves from fetched real roster without calling /api/v1/models/model', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': true,
            'data': {
              'models': [
                {
                  'id': 'gpt-4o',
                  'providerId': 'openai',
                  'displayName': 'GPT-4o',
                  'description': 'Flagship',
                },
              ],
            },
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final details = await api.getModelDetails('gpt-4o');

      check(details).isNotNull();
      check(details!['id']).equals('gpt-4o');
      check(details['name']).equals('GPT-4o');
      check(details['supportsStreaming']).equals(false);
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/v1/models/model')).isFalse();
    });

    test('returns null for unknown model ID without hitting /api/v1/models/model', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'success': true,
            'data': {
              'models': [
                {
                  'id': 'gpt-4o',
                  'providerId': 'openai',
                  'displayName': 'GPT-4o',
                },
              ],
            },
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
      final details = await api.getModelDetails('unknown-model');

      check(details).isNull();
      check(adapter.requestPaths).deepEquals(['/api/v1/models']);
      check(adapter.requestPaths.contains('/api/v1/models/model')).isFalse();
    });
  });

  group('LobeHub profile & workspace getters skip unsupported OWUI paths', () {
    test('all unsupported OWUI model/profile getters return empty/null with 0 HTTP requests', () async {
      final adapter = _StrictLobeHubAdapter(allowedPaths: {});
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      // Profile image
      final profileImage = await api.getWorkspaceModelProfileImage('gpt-4o');
      check(profileImage).isNull();

      // Workspace model detail
      final workspaceModel = await api.getWorkspaceModel('gpt-4o');
      check(workspaceModel).isNull();

      // Workspace models list
      final paged = await api.getWorkspaceModels();
      check(paged.items).isEmpty();
      check(paged.total).equals(0);

      // Base models list
      final baseModels = await api.getWorkspaceBaseModels();
      check(baseModels).isEmpty();

      // Export workspace models
      final exported = await api.exportWorkspaceModels();
      check(exported).isEmpty();

      // Zero HTTP requests made to unadvertised paths
      check(adapter.requests).isEmpty();
    });
  });

  group('LobeHub unsafe writes are rejected without HTTP calls', () {
    test('updateModel returns null with 0 HTTP requests', () async {
      final adapter = _StrictLobeHubAdapter(allowedPaths: {});
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final result = await api.updateModel({'id': 'gpt-4o', 'name': 'Updated'});
      check(result).isNull();
      check(adapter.requests).isEmpty();
    });

    test('updateModelSystemPrompt throws StateError with 0 write requests', () async {
      final adapter = _StrictLobeHubAdapter(allowedPaths: {});
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await check(
        api.updateModelSystemPrompt('gpt-4o', 'system prompt'),
      ).throws<StateError>();
      check(adapter.requests).isEmpty();
    });

    test('workspace mutation operations return null/false/empty with 0 HTTP requests', () async {
      final adapter = _StrictLobeHubAdapter(allowedPaths: {});
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final created = await api.createWorkspaceModel(
        const WorkspaceModelForm(id: 'new', name: 'New'),
      );
      check(created).isNull();

      final updated = await api.updateWorkspaceModel(
        const WorkspaceModelForm(id: 'existing', name: 'Updated'),
      );
      check(updated).isNull();

      final accessUpdated = await api.updateWorkspaceModelAccess(
        'm1',
        'Model 1',
        const [],
      );
      check(accessUpdated).isNull();

      final imported = await api.importWorkspaceModels([{'id': 'm1'}]);
      check(imported).isFalse();

      final synced = await api.syncWorkspaceModels();
      check(synced).isEmpty();

      final toggled = await api.toggleWorkspaceModel('m1');
      check(toggled).isNull();

      final deleted = await api.deleteWorkspaceModel('m1');
      check(deleted).isFalse();

      check(adapter.requests).isEmpty();
    });
  });

  group('OpenWebUI behavior preservation (when serverId is openwebui)', () {
    test('OpenWebUI models default to supportsStreaming true', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models'},
        handler: (options) {
          return _jsonResponse({
            'data': [
              {
                'id': 'gpt-4',
                'name': 'GPT-4',
              },
            ],
          });
        },
      );

      final api = _buildApiService(adapter, serverId: 'openwebui');
      final models = await api.getModels();

      check(models.length).equals(1);
      check(models.first.id).equals('gpt-4');
      check(models.first.supportsStreaming).isTrue();
    });

    test('OpenWebUI preserves /api/models fallback on /api/v1/models failure', () async {
      final adapter = _StrictLobeHubAdapter(
        allowedPaths: {'/api/v1/models', '/api/models'},
        handler: (options) {
          if (options.path == '/api/v1/models') {
            return _jsonResponse({'error': 'not found'}, statusCode: 404);
          }
          if (options.path == '/api/models') {
            return _jsonResponse({
              'data': [
                {
                  'id': 'owui-legacy-model',
                  'name': 'OWUI Legacy Model',
                },
              ],
            });
          }
          return _jsonResponse({});
        },
      );

      final api = _buildApiService(adapter, serverId: 'openwebui');
      final models = await api.getModels();

      check(models.length).equals(1);
      check(models.first.id).equals('owui-legacy-model');
      check(adapter.requestPaths).deepEquals(['/api/v1/models', '/api/models']);
    });
  });
}

class _StrictLobeHubAdapter implements HttpClientAdapter {
  _StrictLobeHubAdapter({
    required this.allowedPaths,
    this.handler,
  });

  final Set<String> allowedPaths;
  final ResponseBody Function(RequestOptions options)? handler;
  final List<RequestOptions> requests = [];
  final List<String> requestPaths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    requestPaths.add(options.path);

    if (!allowedPaths.contains(options.path)) {
      throw AssertionError(
        'Unadvertised path requested on server: ${options.method} ${options.path}',
      );
    }

    if (handler != null) {
      return handler!(options);
    }

    return _jsonResponse({});
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
      'content-type': ['application/json'],
    },
  );
}

ApiService _buildApiService(
  HttpClientAdapter adapter, {
  required String serverId,
}) {
  final service = ApiService(
    serverConfig: ServerConfig(
      id: serverId,
      name: serverId == 'lobehub_self_hosted' ? 'LobeHub' : 'OpenWebUI',
      url: 'http://localhost:3000',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

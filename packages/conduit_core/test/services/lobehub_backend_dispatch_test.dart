import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

void main() {
  group('ServerConfigBackend.isLobeHub', () {
    test('isLobeHub is true exclusively for id == lobehub_self_hosted', () {
      check(
        const ServerConfig(
          id: 'lobehub_self_hosted',
          name: 'LobeHub',
          url: 'http://localhost:3210',
        ).isLobeHub,
      ).isTrue();

      check(
        const ServerConfig(
          id: 'openwebui_instance',
          name: 'OpenWebUI',
          url: 'http://localhost:8080',
        ).isLobeHub,
      ).isFalse();

      check(
        const ServerConfig(
          id: 'default',
          name: 'Default',
          url: 'http://localhost:3000',
        ).isLobeHub,
      ).isFalse();

      check(
        const ServerConfig(
          id: 'lobehub_cloud',
          name: 'LobeHub Cloud',
          url: 'https://lobehub.com',
        ).isLobeHub,
      ).isFalse();
    });
  });

  group('LobeHub connection endpoint bypassing (no HTTP requests made)', () {
    late _TrackingAdapter adapter;
    late ApiService lobeApi;

    setUp(() {
      adapter = _TrackingAdapter();
      lobeApi = _buildApiService(adapter, serverId: 'lobehub_self_hosted');
    });

    test('getNotes and searchNotes return empty/disabled with 0 HTTP requests', () async {
      final (notes, enabled) = await lobeApi.getNotes();
      check(notes).isEmpty();
      check(enabled).isFalse();

      final searchResults = await lobeApi.searchNotes(query: 'test');
      check(searchResults).isEmpty();

      check(adapter.requests).isEmpty();
    });

    test('getTools, getWorkspaceTools, and getFunctions return empty with 0 HTTP requests', () async {
      final tools = await lobeApi.getTools();
      check(tools).isEmpty();

      final workspaceTools = await lobeApi.getWorkspaceTools();
      check(workspaceTools).isEmpty();

      final functions = await lobeApi.getFunctions();
      check(functions).isEmpty();

      check(adapter.requests).isEmpty();
    });

    test('getFolders, getSharedFolders, getSharedFolderChatsPage return empty with 0 HTTP requests', () async {
      final (folders, enabled) = await lobeApi.getFolders();
      check(folders).isEmpty();
      check(enabled).isFalse();

      final sharedFolders = await lobeApi.getSharedFolders();
      check(sharedFolders).isEmpty();

      final (pageChats, hasMore) = await lobeApi.getSharedFolderChatsPage('f1', page: 1);
      check(pageChats).isEmpty();
      check(hasMore).isFalse();

      final allChats = await lobeApi.getSharedFolderChats('f1');
      check(allChats).isEmpty();

      check(adapter.requests).isEmpty();
    });

    test('chat tags return empty with 0 HTTP requests', () async {
      final tags = await lobeApi.getAllChatTags();
      check(tags).isEmpty();

      final added = await lobeApi.addChatTag('c1', 'tag');
      check(added).isEmpty();

      final removed = await lobeApi.removeChatTag('c1', 'tag');
      check(removed).isEmpty();

      final chatsByTag = await lobeApi.getChatsByTag('tag');
      check(chatsByTag).isEmpty();

      check(adapter.requests).isEmpty();
    });

    test('user settings and memories return empty/disabled with 0 HTTP requests', () async {
      final settings = await lobeApi.getUserSettings();
      check(settings).isEmpty();

      final settingsModel = await lobeApi.getServerUserSettingsModel();
      check(settingsModel.systemPrompt).isNull();
      check(settingsModel.memoryEnabled).isFalse();

      await lobeApi.updateUserSettings({'theme': 'dark'});

      final memories = await lobeApi.getMemories();
      check(memories).isEmpty();

      check(adapter.requests).isEmpty();
    });

    test('user permissions return empty with 0 HTTP requests', () async {
      final perms = await lobeApi.getUserPermissions();
      check(perms).isEmpty();
      check(adapter.requests).isEmpty();
    });

    test('getBackendConfig, verifyAndGetConfig, and getServerAboutInfo return consistent disabled config with 0 HTTP requests', () async {
      final config = await lobeApi.getBackendConfig();
      check(config).isNotNull();
      check(config!.serverId).equals('lobehub_self_hosted');
      check(config.enableWebsocket).equals(false);
      check(config.enableWebSearch).equals(false);
      check(config.enableDirectConnections).equals(false);
      check(config.enableMessageRating).equals(false);
      check(config.enableAudioInput).equals(false);
      check(config.enableAudioOutput).equals(false);
      check(config.pollingOnly).isTrue();
      check(config.enforcedTransportMode).equals('polling');

      final verified = await lobeApi.verifyAndGetConfig();
      check(verified).isNotNull();
      check(verified!.enableWebsocket).equals(false);

      final about = await lobeApi.getServerAboutInfo();
      check(about.version).equals('LobeHub');

      check(adapter.requests).isEmpty();
    });
  });

  group('LobeHub user auth & health checks (correct endpoint routing)', () {
    test('getCurrentUser requests /api/v1/users/me and parses LobeUser', () async {
      final adapter = _TrackingAdapter(
        handler: (options) {
          if (options.path.endsWith('/api/v1/users/me')) {
            return _jsonResponse({
              'id': 'lobe_user_1',
              'username': 'lobe_admin',
              'email': 'admin@lobehub.local',
              'fullName': 'Lobe Administrator',
              'role': 'admin',
              'avatar': 'https://example.com/avatar.png',
            });
          }
          return _jsonResponse({}, statusCode: 404);
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final user = await api.getCurrentUser();

      check(user.id).equals('lobe_user_1');
      check(user.username).equals('Lobe Administrator');
      check(user.email).equals('admin@lobehub.local');
      check(user.role).equals('admin');
      check(user.profileImage).equals('https://example.com/avatar.png');

      check(adapter.requestPaths).contains('/api/v1/users/me');
      check(adapter.requestPaths.any((p) => p.contains('/api/v1/auths/'))).isFalse();
    });

    test('getCurrentUser falls back to /api/v1/user when /api/v1/users/me returns 404', () async {
      final adapter = _TrackingAdapter(
        handler: (options) {
          if (options.path.endsWith('/api/v1/users/me')) {
            return _jsonResponse({'error': 'Not found'}, statusCode: 404);
          }
          if (options.path.endsWith('/api/v1/user')) {
            return _jsonResponse({
              'data': {
                'id': 'lobe_user_2',
                'username': 'bob',
                'email': 'bob@lobehub.local',
                'role': 'user',
              },
            });
          }
          return _jsonResponse({}, statusCode: 500);
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final user = await api.getCurrentUser();

      check(user.id).equals('lobe_user_2');
      check(user.username).equals('bob');
      check(user.email).equals('bob@lobehub.local');

      check(adapter.requestPaths.length).equals(2);
      check(adapter.requestPaths[0]).endsWith('/api/v1/users/me');
      check(adapter.requestPaths[1]).endsWith('/api/v1/user');
      check(adapter.requestPaths.any((p) => p.contains('/api/v1/auths/'))).isFalse();
    });

    test('getAccountMetadata delegates to getCurrentUser without requesting OWUI auths/ or users/user/info', () async {
      final adapter = _TrackingAdapter(
        handler: (options) {
          if (options.path.endsWith('/api/v1/users/me')) {
            return _jsonResponse({
              'id': 'usr_99',
              'name': 'Metadata User',
              'email': 'meta@lobehub.local',
              'role': 'user',
            });
          }
          return _jsonResponse({}, statusCode: 404);
        },
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      final metadata = await api.getAccountMetadata();

      check(metadata.id).equals('usr_99');
      check(metadata.name).equals('Metadata User');
      check(metadata.email).equals('meta@lobehub.local');

      check(adapter.requestPaths).contains('/api/v1/users/me');
      check(adapter.requestPaths.any((p) => p.contains('/api/v1/auths/'))).isFalse();
      check(adapter.requestPaths.any((p) => p.contains('/api/v1/users/user/info'))).isFalse();
    });

    test('warmConnectionPool uses /api/v1/health for LobeHub', () async {
      final adapter = _TrackingAdapter(
        handler: (options) => _jsonResponse({'status': 'ok'}),
      );
      final api = _buildApiService(adapter, serverId: 'lobehub_self_hosted');

      await api.warmConnectionPool();

      check(adapter.requestPaths).contains('/api/v1/health');
      check(adapter.requestPaths.contains('/health')).isFalse();
    });
  });

  group('OpenWebUI preservation (existing OWUI endpoints requested when not LobeHub)', () {
    late _TrackingAdapter adapter;
    late ApiService owuiApi;

    setUp(() {
      adapter = _TrackingAdapter(
        handler: (options) {
          final path = options.path;
          if (path.endsWith('/api/v1/notes/')) {
            return _jsonResponse([{'id': 'n1', 'title': 'Note 1'}]);
          }
          if (path.endsWith('/api/v1/tools/')) {
            return _jsonResponse([{'id': 't1', 'name': 'Tool 1'}]);
          }
          if (path.endsWith('/api/v1/functions/')) {
            return _jsonResponse([{'id': 'f1', 'name': 'Function 1'}]);
          }
          if (path.endsWith('/api/v1/folders/')) {
            return _jsonResponse([{'id': 'fold1', 'name': 'Folder 1'}]);
          }
          if (path.endsWith('/api/v1/users/user/settings')) {
            return _jsonResponse({'ui': {'theme': 'dark'}});
          }
          if (path.endsWith('/api/v1/users/permissions')) {
            return _jsonResponse({'chat.deletion': true});
          }
          if (path.endsWith('/api/config')) {
            return _jsonResponse({
              'status': true,
              'version': '0.11.4',
              'features': {'enable_websocket': true},
            });
          }
          if (path.endsWith('/api/v1/auths/')) {
            return _jsonResponse({
              'id': 'owui_user_1',
              'name': 'OWUI User',
              'email': 'owui@example.com',
              'role': 'admin',
            });
          }
          if (path.endsWith('/health')) {
            return _jsonResponse({'status': true});
          }
          return _jsonResponse({});
        },
      );
      owuiApi = _buildApiService(adapter, serverId: 'owui_server_id');
    });

    test('preserves OWUI notes, tools, functions, folders, settings, permissions, config, auths, health', () async {
      final (notes, enabledNotes) = await owuiApi.getNotes();
      check(notes.length).equals(1);
      check(enabledNotes).isTrue();
      check(adapter.requestPaths).contains('/api/v1/notes/');

      final tools = await owuiApi.getTools();
      check(tools.length).equals(1);
      check(adapter.requestPaths).contains('/api/v1/tools/');

      final functions = await owuiApi.getFunctions();
      check(functions.length).equals(1);
      check(adapter.requestPaths).contains('/api/v1/functions/');

      final (folders, enabledFolders) = await owuiApi.getFolders();
      check(folders.length).equals(1);
      check(enabledFolders).isTrue();
      check(adapter.requestPaths).contains('/api/v1/folders/');

      final settings = await owuiApi.getUserSettings();
      check(settings['ui']).isNotNull();
      check(adapter.requestPaths).contains('/api/v1/users/user/settings');

      final permissions = await owuiApi.getUserPermissions();
      check(permissions['chat.deletion']).equals(true);
      check(adapter.requestPaths).contains('/api/v1/users/permissions');

      final config = await owuiApi.getBackendConfig();
      check(config).isNotNull();
      check(config!.version).equals('0.11.4');
      check(config.enableWebsocket).equals(true);
      check(adapter.requestPaths).contains('/api/config');

      final user = await owuiApi.getCurrentUser();
      check(user.id).equals('owui_user_1');
      check(adapter.requestPaths).contains('/api/v1/auths/');

      await owuiApi.warmConnectionPool();
      check(adapter.requestPaths).contains('/health');
    });
  });
}

class _TrackingAdapter implements HttpClientAdapter {
  _TrackingAdapter({this.handler});

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

ApiService _buildApiService(HttpClientAdapter adapter, {required String serverId}) {
  final service = ApiService(
    serverConfig: ServerConfig(
      id: serverId,
      name: 'Server $serverId',
      url: 'http://localhost:3000',
    ),
    workerManager: WorkerManager(),
  );
  service.dio.httpClientAdapter = adapter;
  service.dio.interceptors.clear();
  return service;
}

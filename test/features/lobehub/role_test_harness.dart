import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/lobehub/models/lobe_agent.dart';
import 'package:conduit_core/features/lobehub/providers/lobehub_agents_provider.dart';
import 'package:conduit_core/features/lobehub/services/lobehub_api_client.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit/features/navigation/views/main_navigation_shell.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const roleAgent = LobeAgent(
  id: 'agt_coder_42',
  title: 'Coding Specialist',
  model: 'shared-model',
  provider: 'deepseek',
  systemRole: 'You are an expert Flutter systems architect.',
);

const foreignModel = Model(
  id: 'foreign-model',
  name: 'Other Chat Model',
  metadata: {'provider': 'openai'},
);

class RoleTestAuth extends AuthStateManager {
  @override
  Future<AuthState> build() async => const AuthState(
    status: AuthStatus.authenticated,
    token: 'synthetic-account-a',
    user: User(
      id: 'account-a',
      username: 'a',
      email: 'a@example.invalid',
      role: 'user',
    ),
  );

  void changeAccount(String? token) {
    state = AsyncData(AuthState(
      status: token == null
          ? AuthStatus.unauthenticated
          : AuthStatus.authenticated,
      token: token,
      user: token == null
          ? null
          : const User(
              id: 'account-b',
              username: 'b',
              email: 'b@example.invalid',
              role: 'user',
            ),
    ));
  }
}

class _CertifiedTestStorage extends OpenWebUiAccountStorageIsolation {
  @override
  void build() {}
}

class _OnlineModels extends Models {
  @override
  Future<List<Model>> build() => ref.watch(apiServiceProvider)!.getModels();
}

class _InitialSelectedModel extends SelectedModel {
  @override
  Model? build() => foreignModel;
}

class _AgentsTab extends MainNavigationIndexNotifier {
  @override
  int build() => 1;
}

class StrictRoleAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final unexpectedRequests = <String>[];
  final handlers = <String, FutureOr<ResponseBody> Function(RequestOptions)>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final key = '${options.method} ${options.uri.path}';
    final handler = handlers[key];
    if (handler == null || options.uri.host != 'role.example.invalid') {
      unexpectedRequests.add(key);
      throw StateError('Unexpected synthetic HTTP request: $key');
    }
    expect(options.headers['Authorization'], startsWith('Bearer synthetic-'));
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody roleJson(Object? body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );

class RoleHarness {
  RoleHarness({this.agent = roleAgent, this.clientAvailable = true}) {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    api = ApiService(
      serverConfig: server,
      authToken: 'synthetic-account-a',
      workerManager: worker,
    );
    api.dio.httpClientAdapter = adapter;
    currentApi = api;
    client = LobeHubApiClient(
      baseUrl: server.url,
      apiKeyProvider: () => api.authToken,
      dio: Dio()..httpClientAdapter = adapter,
    );
    adapter.handlers.addAll({
      'GET /api/v1/agents/${agent.id}': (_) async {
        detailCalls++;
        if (beforeDetail != null) await beforeDetail!();
        return roleJson(
          detailStatus == 200
              ? {'success': true, 'data': detail ?? agent.toJson()}
              : {'success': false, 'error': 'Agent detail rejected'},
          status: detailStatus,
        );
      },
      'GET /api/v1/agents': (_) => roleJson({
        'success': true,
        'data': [agent.toJson()],
      }),
      'GET /api/v1/models': (_) async {
        if (beforeModels != null) await beforeModels!();
        return roleJson({'success': true, 'data': models});
      },
      'POST /api/v1/topics': (request) async {
        if (beforeCreate != null) await beforeCreate!();
        final payload = Map<String, dynamic>.from(request.data as Map);
        creationPayloads.add(payload);
        if (creationStatus != 200) {
          return roleJson({'success': false, 'error': 'Creation rejected'},
              status: creationStatus);
        }
        topic = {
          'id': returnedTopicId,
          'title': payload['title'],
          if (returnedAgentId != null) 'agentId': returnedAgentId,
          'createdAt': 1700000000000,
          'updatedAt': 1700000000000,
        };
        return roleJson({'success': true, 'data': topic});
      },
      'GET /api/v1/topics/tpc_verified': (_) async {
        if (beforeReload != null) await beforeReload!();
        return roleJson(
          reloadStatus == 200
              ? {'success': true, 'data': topic}
              : {'success': false, 'error': 'Reload rejected'},
          status: reloadStatus,
        );
      },
      'GET /api/v1/messages': (request) {
        expect(request.queryParameters['topicId'], 'tpc_verified');
        return roleJson({'success': true, 'data': messages});
      },
      'PATCH /api/v1/messages/server-user': (request) {
        final metadata = (request.data as Map)['metadata'];
        messages.first['metadata'] = metadata;
        return roleJson({'success': true});
      },
      'PATCH /api/v1/messages/server-assistant': (request) {
        final metadata = (request.data as Map)['metadata'];
        messages.last['metadata'] = metadata;
        return roleJson({'success': true});
      },
      'POST /api/v1/responses': (request) async {
        if (beforeResponse != null) await beforeResponse!();
        responsePayloads.add(Map<String, dynamic>.from(request.data as Map));
        messages = [
          {'id': 'server-user', 'role': 'user', 'content': 'Write Dart'},
          {
            'id': 'server-assistant',
            'role': 'assistant',
            'content': 'Verified role response',
            'parentId': 'server-user',
            'model': agent.model,
            'provider': agent.provider,
          },
        ];
        return ResponseBody.fromString(
          'data: {"type":"response.completed","response":{"status":"completed","output_text":"Verified role response"}}\n\n',
          200,
          headers: {Headers.contentTypeHeader: ['text/event-stream']},
        );
      },
    });
    container = ProviderContainer(retry: (count, error) => null, overrides: [
      authStateManagerProvider.overrideWith(RoleTestAuth.new),
      activeServerProvider.overrideWith((ref) async => currentServer),
      apiServiceProvider.overrideWith((ref) => currentApi),
      lobeHubApiClientProvider.overrideWith(
          (ref) => clientAvailable ? client : null),
      appDatabaseProvider.overrideWithValue(database),
      directLocalDatabaseProvider.overrideWithValue(localDatabase),
      openWebUiAccountStorageIsolationProvider
          .overrideWith(_CertifiedTestStorage.new),
      workerManagerProvider.overrideWithValue(worker),
      appSettingsProvider.overrideWithValue(const AppSettings()),
      modelsProvider.overrideWith(_OnlineModels.new),
      selectedModelProvider.overrideWith(_InitialSelectedModel.new),
      mainNavigationIndexProvider.overrideWith(_AgentsTab.new),
      socketServiceProvider.overrideWithValue(null),
    ]);
  }

  final LobeAgent agent;
  final bool clientAvailable;
  final server = const ServerConfig(
    id: 'lobehub_self_hosted',
    name: 'Synthetic LobeHub',
    url: 'https://role.example.invalid',
  );
  ServerConfig? currentServer = const ServerConfig(
    id: 'lobehub_self_hosted',
    name: 'Synthetic LobeHub',
    url: 'https://role.example.invalid',
  );
  late final database = AppDatabase(NativeDatabase.memory());
  late final localDatabase = AppDatabase(NativeDatabase.memory());
  final worker = WorkerManager();
  final adapter = StrictRoleAdapter();
  late final ApiService api;
  ApiService? currentApi;
  late final LobeHubApiClient client;
  late final ProviderContainer container;
  int detailCalls = 0;
  int detailStatus = 200;
  int creationStatus = 200;
  int reloadStatus = 200;
  String? returnedAgentId = roleAgent.id;
  String returnedTopicId = 'tpc_verified';
  Map<String, dynamic>? detail;
  Map<String, dynamic> topic = {
    'id': 'tpc_verified',
    'agentId': roleAgent.id,
    'title': 'User-renamed conversation',
    'createdAt': 1700000000000,
    'updatedAt': 1700000000000,
  };
  List<Map<String, dynamic>> models = [
    {'id': 'shared-model', 'name': 'OpenRouter Copy', 'provider': 'openrouter'},
    {'id': 'shared-model', 'name': 'DeepSeek Underlying', 'provider': 'deepseek'},
    {'id': 'foreign-model', 'name': 'Other Chat Model', 'provider': 'openai'},
  ];
  List<Map<String, dynamic>> messages = [];
  final creationPayloads = <Map<String, dynamic>>[];
  final responsePayloads = <Map<String, dynamic>>[];
  Future<void> Function()? beforeDetail;
  Future<void> Function()? beforeModels;
  Future<void> Function()? beforeCreate;
  Future<void> Function()? beforeReload;
  Future<void> Function()? beforeResponse;

  Future<void> initialize() async {
    await container.read(authStateManagerProvider.future);
    await container.read(activeServerProvider.future);
    container.read(openWebUiCertifiedDatabaseServerProvider.notifier).set(server.id);
    container.read(openWebUiDatabaseAccessProvider.notifier).open();
  }

  void changeAccount(String? token) {
    api.updateAuthToken(token);
    (container.read(authStateManagerProvider.notifier) as RoleTestAuth)
        .changeAccount(token);
  }

  Future<void> close() async {
    expect(adapter.unexpectedRequests, isEmpty);
    container.dispose();
    client.dio.close(force: true);
    api.dio.close(force: true);
    worker.dispose();
    await database.close();
    await localDatabase.close();
  }
}

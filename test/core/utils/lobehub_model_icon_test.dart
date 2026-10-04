import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_symbol_image_service.dart';
import 'package:conduit/core/utils/model_icon_utils.dart';
import 'package:conduit/core/utils/model_logos.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/direct_connections/services/model_logo_catalog.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:flutter_test/flutter_test.dart';

ApiService _createApiService({
  required String serverId,
  required String serverUrl,
}) {
  final workerManager = WorkerManager();
  addTearDown(workerManager.dispose);
  final api = ApiService(
    serverConfig: ServerConfig(
      id: serverId,
      name: serverId == 'lobehub_self_hosted' ? 'LobeHub' : 'Open WebUI',
      url: serverUrl,
    ),
    workerManager: workerManager,
  );
  addTearDown(api.dispose);
  return api;
}

void main() {
  setUpAll(() {
    final catalogFile = File('assets/model_logos/catalog.json');
    if (catalogFile.existsSync()) {
      ModelLogos.debugSetCatalog(
        ModelLogoCatalog.fromJson(
          jsonDecode(catalogFile.readAsStringSync()) as Map<String, dynamic>,
        ),
      );
    }
  });
  tearDownAll(() => ModelLogos.debugSetCatalog(null));

  group('LobeHub model icon URL resolution', () {
    test('returns null for model without icon on LobeHub server', () {
      final api = _createApiService(
        serverId: 'lobehub_self_hosted',
        serverUrl: 'https://lobehub.example.com',
      );
      const model = Model(id: 'gpt-4o', name: 'GPT-4o');

      check(buildModelAvatarUrl(api, 'gpt-4o')).isNull();
      check(resolveModelIconUrlForModel(api, model)).isNull();
    });

    test('returns null for model with relative icon path on LobeHub server', () {
      final api = _createApiService(
        serverId: 'lobehub_self_hosted',
        serverUrl: 'https://lobehub.example.com',
      );
      const model = Model(
        id: 'custom-model',
        name: 'Custom Model',
        metadata: {'icon': '/icons/custom.png'},
      );

      check(resolveModelIconUrlForModel(api, model)).isNull();
    });

    test('keeps explicit data URI icon on LobeHub server', () {
      final api = _createApiService(
        serverId: 'lobehub_self_hosted',
        serverUrl: 'https://lobehub.example.com',
      );
      const dataUri = 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=';
      const model = Model(
        id: 'data-model',
        name: 'Data Model',
        metadata: {'icon': dataUri},
      );

      check(resolveModelIconUrlForModel(api, model)).equals(dataUri);
    });

    test('keeps explicit external http/https icon on LobeHub server', () {
      final api = _createApiService(
        serverId: 'lobehub_self_hosted',
        serverUrl: 'https://lobehub.example.com',
      );
      const externalUrl = 'https://example.com/model-avatar.png';
      const model = Model(
        id: 'ext-model',
        name: 'External Model',
        metadata: {'profile_image_url': externalUrl},
      );

      check(resolveModelIconUrlForModel(api, model)).equals(externalUrl);
    });

    test('normal OpenWebUI server still generates profile image endpoint', () {
      final api = _createApiService(
        serverId: 'open_webui',
        serverUrl: 'https://owui.example.com',
      );
      const model = Model(id: 'gpt-4o', name: 'GPT-4o');

      check(buildModelAvatarUrl(api, 'gpt-4o'))
          .equals('https://owui.example.com/api/v1/models/model/profile/image?id=gpt-4o');
      check(resolveModelIconUrlForModel(api, model))
          .equals('https://owui.example.com/api/v1/models/model/profile/image?id=gpt-4o');
    });

    test('Hermes, Apple, and Direct models retain their native marks on LobeHub server', () {
      final api = _createApiService(
        serverId: 'lobehub_self_hosted',
        serverUrl: 'https://lobehub.example.com',
      );

      final hermes = hermesSyntheticModel();
      check(resolveModelIconUrlForModel(api, hermes))
          .equals('asset:$kHermesModelAvatarAsset');

      final registry = DirectModelRegistry();
      final apple = registry.replaceProfileModels(
        DirectConnectionProfile.appleOnDevice(),
        [DirectRemoteModel(id: kAppleOnDeviceRemoteModelId, name: 'Apple On-Device')],
      );
      check(resolveModelIconUrlForModel(api, apple.single))
          .equals('$kNativeSymbolUrlScheme$kAppleIntelligenceSymbol');

      final direct = registry.replaceProfileModels(
        DirectConnectionProfile(
          id: 'provider',
          name: 'Provider',
          adapterKey: kOpenAiCompatibleAdapterKey,
          baseUrl: 'https://api.openai.com/v1',
        ),
        [DirectRemoteModel(id: 'gpt-4o', name: 'GPT-4o')],
      );
      check(resolveModelIconUrlForModel(api, direct.single)).isNotNull();
    });
  });
}

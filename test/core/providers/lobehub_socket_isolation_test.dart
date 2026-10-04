import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/socket_transport_availability.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _TestAuthState = ({bool authenticated, String? token, Object epoch});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const owuiServer = ServerConfig(
    id: 'server-owui',
    name: 'OpenWebUI Server',
    url: 'https://owui.example.test',
  );

  const lobeHubServer = ServerConfig(
    id: 'lobehub_self_hosted',
    name: 'LobeHub Self-Hosted',
    url: 'https://lobehub.example.test',
  );

  group('LobeHub Socket Isolation', () {
    test(
      'initial LobeHub connection never invokes factory and yields null socket',
      () async {
        final harness = _SocketIsolationHarness(
          initialServer: Future<ServerConfig?>.value(lobeHubServer),
          initialAuth: (
            authenticated: true,
            token: 'token-lobe',
            epoch: Object(),
          ),
        );
        final container = harness.createContainer();
        addTearDown(container.dispose);

        final subscription = container.listen(
          socketServiceManagerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final result = await container.read(
          socketServiceManagerProvider.future,
        );
        await _flushMicrotasks();

        check(result).isNull();
        check(harness.factoryCalls).equals(0);
        check(harness.services).isEmpty();
        check(
          container.read(socketServiceManagerProvider.notifier).currentService,
        ).isNull();
        check(container.read(socketServiceProvider)).isNull();
      },
    );

    test(
      'switching OWUI -> LobeHub disposes active socket and leaves factory counter unchanged',
      () async {
        final harness = _SocketIsolationHarness(
          initialServer: Future<ServerConfig?>.value(owuiServer),
          initialAuth: (
            authenticated: true,
            token: 'token-owui',
            epoch: Object(),
          ),
        );
        final container = harness.createContainer();
        addTearDown(container.dispose);

        final subscription = container.listen(
          socketServiceManagerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        final owuiService =
            await container.read(socketServiceManagerProvider.future)
                as _TestSocketService;

        check(harness.factoryCalls).equals(1);
        check(owuiService.disposeCalls).equals(0);
        check(container.read(socketServiceProvider)).identicalTo(owuiService);

        // Switch active server to LobeHub
        harness.setServer(container, Future<ServerConfig?>.value(lobeHubServer));
        final lobeResult = await container.read(
          socketServiceManagerProvider.future,
        );
        await _flushMicrotasks();

        // Must return null, must dispose the old socket, and factory count must stay 1 (0 for LobeHub)
        check(lobeResult).isNull();
        check(owuiService.disposeCalls).equals(1);
        check(harness.factoryCalls).equals(1);
        check(
          container.read(socketServiceManagerProvider.notifier).currentService,
        ).isNull();
        check(container.read(socketServiceProvider)).isNull();
      },
    );

    test('switching LobeHub -> OWUI constructs socket and connects', () async {
      final harness = _SocketIsolationHarness(
        initialServer: Future<ServerConfig?>.value(lobeHubServer),
        initialAuth: (
          authenticated: true,
          token: 'token-active',
          epoch: Object(),
        ),
      );
      final container = harness.createContainer();
      addTearDown(container.dispose);

      final subscription = container.listen(
        socketServiceManagerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final initialResult = await container.read(
        socketServiceManagerProvider.future,
      );
      check(initialResult).isNull();
      check(harness.factoryCalls).equals(0);

      // Switch to OWUI
      harness.setServer(container, Future<ServerConfig?>.value(owuiServer));
      final owuiResult =
          await container.read(socketServiceManagerProvider.future)
              as _TestSocketService;
      await _flushMicrotasks();

      check(harness.factoryCalls).equals(1);
      check(owuiResult.serverConfig).equals(owuiServer);
      check(owuiResult.authToken).equals('token-active');
      check(
        container.read(socketServiceManagerProvider.notifier).currentService,
      ).identicalTo(owuiResult);
      check(container.read(socketServiceProvider)).identicalTo(owuiResult);
    });

    test(
      'ABA guard: stale LobeHub build cannot dispose newer OWUI socket',
      () async {
        final pendingLobeHub = Completer<ServerConfig?>();
        final harness = _SocketIsolationHarness(
          initialServer: pendingLobeHub.future,
          initialAuth: (
            authenticated: true,
            token: 'token-initial',
            epoch: Object(),
          ),
        );
        final container = harness.createContainer();
        addTearDown(container.dispose);

        final subscription = container.listen(
          socketServiceManagerProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        await _flushMicrotasks();

        // Switch to OWUI with new auth before pending LobeHub resolves
        harness.setAuth(container, (
          authenticated: true,
          token: 'token-owui',
          epoch: Object(),
        ));
        harness.setServer(container, Future<ServerConfig?>.value(owuiServer));

        final owuiService =
            await container.read(socketServiceManagerProvider.future)
                as _TestSocketService;
        check(harness.factoryCalls).equals(1);
        check(owuiService.disposeCalls).equals(0);

        // Obsolete build completes with LobeHub
        pendingLobeHub.complete(lobeHubServer);
        await _flushMicrotasks();

        // Obsolete completion must not dispose or replace the newer OWUI socket
        check(owuiService.disposeCalls).equals(0);
        check(harness.factoryCalls).equals(1);
        check(
          container.read(socketServiceManagerProvider.notifier).currentService,
        ).identicalTo(owuiService);
        check(container.read(socketServiceProvider)).identicalTo(owuiService);
      },
    );

    test('ABA guard: stale OWUI build cannot install socket into active LobeHub session', () async {
      final pendingOwui = Completer<ServerConfig?>();
      final harness = _SocketIsolationHarness(
        initialServer: pendingOwui.future,
        initialAuth: (
          authenticated: true,
          token: 'token-owui',
          epoch: Object(),
        ),
      );
      final container = harness.createContainer();
      addTearDown(container.dispose);

      final subscription = container.listen(
        socketServiceManagerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _flushMicrotasks();

      // Switch to LobeHub with distinct epoch
      harness.setAuth(container, (
        authenticated: true,
        token: 'token-lobe',
        epoch: Object(),
      ));
      harness.setServer(container, Future<ServerConfig?>.value(lobeHubServer));

      final lobeResult = await container.read(
        socketServiceManagerProvider.future,
      );
      check(lobeResult).isNull();
      check(harness.factoryCalls).equals(0);

      // Now stale OWUI server future resolves
      pendingOwui.complete(owuiServer);
      await _flushMicrotasks();

      // Factory must STILL be 0, and socket must stay null
      check(harness.factoryCalls).equals(0);
      check(
        container.read(socketServiceManagerProvider.notifier).currentService,
      ).isNull();
      check(container.read(socketServiceProvider)).isNull();
    });
  });
}

final class _SocketIsolationHarness {
  _SocketIsolationHarness({
    required Future<ServerConfig?> initialServer,
    required _TestAuthState initialAuth,
  }) : authProvider = NotifierProvider<_AuthNotifier, _TestAuthState>(
         () => _AuthNotifier(initialAuth),
       ),
       serverProvider =
           NotifierProvider<_ServerFutureNotifier, Future<ServerConfig?>>(
             () => _ServerFutureNotifier(initialServer),
           );

  final NotifierProvider<_AuthNotifier, _TestAuthState> authProvider;
  final NotifierProvider<_ServerFutureNotifier, Future<ServerConfig?>>
  serverProvider;
  final List<_TestSocketService> services = <_TestSocketService>[];
  int factoryCalls = 0;

  ProviderContainer createContainer() {
    return ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        isAuthenticatedProvider2.overrideWith(
          (ref) => ref.watch(authProvider).authenticated,
        ),
        authTokenProvider3.overrideWith((ref) => ref.watch(authProvider).token),
        openWebUiAuthSessionEpochProvider.overrideWith(
          (ref) => ref.watch(authProvider).epoch,
        ),
        activeServerProvider.overrideWith((ref) => ref.watch(serverProvider)),
        appSettingsProvider.overrideWithValue(const AppSettings()),
        socketTransportOptionsProvider.overrideWithValue(
          const SocketTransportAvailability(
            allowPolling: true,
            allowWebsocketOnly: true,
          ),
        ),
        connectivityStatusProvider.overrideWithValue(ConnectivityStatus.online),
        appLifecycleProvider.overrideWithValue(const StaticAppLifecycle()),
        postFrameSchedulerProvider.overrideWithValue(
          const MicrotaskPostFrameScheduler(),
        ),
        socketServiceFactoryProvider.overrideWithValue(({
          required serverConfig,
          required authToken,
          required websocketOnly,
          required allowWebsocketUpgrade,
        }) {
          factoryCalls += 1;
          final service = _TestSocketService(
            serverConfig: serverConfig,
            authToken: authToken,
            websocketOnly: websocketOnly,
            allowWebsocketUpgrade: allowWebsocketUpgrade,
          );
          services.add(service);
          return service;
        }),
      ],
    );
  }

  void setAuth(ProviderContainer container, _TestAuthState auth) {
    container.read(authProvider.notifier).set(auth);
  }

  void setServer(ProviderContainer container, Future<ServerConfig?> server) {
    container.read(serverProvider.notifier).set(server);
  }
}

final class _AuthNotifier extends Notifier<_TestAuthState> {
  _AuthNotifier(this.initial);

  final _TestAuthState initial;

  @override
  _TestAuthState build() => initial;

  void set(_TestAuthState next) => state = next;
}

final class _ServerFutureNotifier extends Notifier<Future<ServerConfig?>> {
  _ServerFutureNotifier(this.initial);

  final Future<ServerConfig?> initial;

  @override
  Future<ServerConfig?> build() => initial;

  void set(Future<ServerConfig?> next) => state = next;
}

final class _TestSocketService implements SocketService {
  _TestSocketService({
    required this.serverConfig,
    required this.authToken,
    required this.websocketOnly,
    required this.allowWebsocketUpgrade,
  });

  @override
  final ServerConfig serverConfig;
  @override
  final String authToken;
  @override
  final bool websocketOnly;
  @override
  final bool allowWebsocketUpgrade;

  int connectCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> connect({bool force = false}) async {
    connectCalls += 1;
  }

  @override
  void connectBestEffort({bool force = false, required String reason}) {
    connectCalls += 1;
  }

  @override
  void dispose() {
    disposeCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> _flushMicrotasks() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

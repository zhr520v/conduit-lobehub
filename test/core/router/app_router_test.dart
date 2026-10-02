import 'package:checks/checks.dart';
import 'package:conduit/core/router/app_router.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

final class _MockBuildContext extends Mock implements BuildContext {}

final class _MockGoRouterState extends Mock implements GoRouterState {}

final class _FixedPreferredBackendController
    extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.unset;
}

final class _FixedHermesConfigController extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

final class _SignedOutAuthStateManager extends AuthStateManager {
  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);
}

final class _FixedDirectProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer createContainer() {
    return ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        activeServerProvider.overrideWith((_) async => null),
        preferredBackendProvider.overrideWith(
          _FixedPreferredBackendController.new,
        ),
        hermesConfigProvider.overrideWith(
          _FixedHermesConfigController.new,
        ),
        directConnectionProfilesProvider.overrideWith(
          _FixedDirectProfiles.new,
        ),
        authStateManagerProvider.overrideWith(
          _SignedOutAuthStateManager.new,
        ),
      ],
    );
  }

  GoRoute? findRoute(List<RouteBase> routes, String path) {
    for (final route in routes) {
      if (route is GoRoute && route.path == path) return route;
      if (route is ShellRoute) {
        final nested = findRoute(route.routes, path);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  group('app_router legacy route redirection', () {
    late ProviderContainer container;
    late GoRouter router;
    late BuildContext mockContext;
    late GoRouterState mockState;

    setUp(() {
      container = createContainer();
      router = container.read(goRouterProvider);
      mockContext = _MockBuildContext();
      mockState = _MockGoRouterState();
    });

    tearDown(() {
      container.dispose();
    });

    test('pruned legacy OpenWebUI routes redirect cleanly to Routes.chat', () {
      final legacyPaths = <String>[
        '/',
        Routes.notes,
        Routes.noteEditor,
        Routes.channel,
        '/channel',
        '/channels',
        '/channels/:id',
        '/terminal',
        '/terminal/:id',
        '/hermes',
        '/hermes/:id',
      ];

      for (final path in legacyPaths) {
        final route = findRoute(router.configuration.routes, path);
        check(
          because: 'Route for $path should be registered in appRoutes',
          route,
        ).isNotNull();

        final redirect = route!.redirect;
        check(
          because: 'Route $path should have a redirect callback',
          redirect,
        ).isNotNull();

        final destination = redirect!(mockContext, mockState);
        check(
          because: 'Route $path should redirect to ${Routes.chat}',
          destination,
        ).equals(Routes.chat);
      }
    });

    test('core chat and shell routes are preserved and not redirected', () {
      final chatRoute = findRoute(router.configuration.routes, Routes.chat);
      check(chatRoute).isNotNull();
      check(chatRoute!.redirect).isNull();
      check(chatRoute.name).equals(RouteNames.chat);

      final folderRoute = findRoute(router.configuration.routes, Routes.folder);
      check(folderRoute).isNotNull();
      check(folderRoute!.redirect).isNull();
      check(folderRoute.name).equals(RouteNames.folder);
    });

    test('core app routes remain accessible', () {
      final splashRoute = findRoute(router.configuration.routes, Routes.splash);
      check(splashRoute).isNotNull();
      check(splashRoute!.redirect).isNull();

      final profileRoute = findRoute(
        router.configuration.routes,
        Routes.profile,
      );
      check(profileRoute).isNotNull();
      check(profileRoute!.redirect).isNull();

      final directRoute = findRoute(
        router.configuration.routes,
        Routes.directConnections,
      );
      check(directRoute).isNotNull();
      check(directRoute!.redirect).isNull();

      final serverConnectionRoute = findRoute(
        router.configuration.routes,
        Routes.serverConnection,
      );
      check(serverConnectionRoute).isNotNull();
      check(serverConnectionRoute!.redirect).isNull();

      final backendChooserRoute = findRoute(
        router.configuration.routes,
        Routes.backendChooser,
      );
      check(backendChooserRoute).isNotNull();
      final chooserRedirect = backendChooserRoute!.redirect;
      check(chooserRedirect).isNotNull();
      check(chooserRedirect!(mockContext, mockState)).equals(Routes.serverConnection);
    });
  });
}

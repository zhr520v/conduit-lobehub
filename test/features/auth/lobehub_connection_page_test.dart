import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/misc.dart' show Override;

import 'package:conduit_core/features/lobehub/models/models.dart';
import 'package:conduit_core/features/lobehub/services/services.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';

import 'package:conduit/features/auth/views/lobehub_connection_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';

class MockLobeHubApiClient extends Mock implements LobeHubApiClient {}

Widget createTestHarness({
  required Widget child,
  List<Override> overrides = const [],
  Size size = const Size(390, 844),
}) {
  final theme = AppTheme.light(TweakcnThemes.conduit);

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: theme,
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: child,
        ),
      ),
    ),
  );
}

Widget createRouterTestHarness({
  required Widget connectionPage,
  List<Override> overrides = const [],
  void Function(String path)? onNavigated,
  Size size = const Size(390, 844),
}) {
  final theme = AppTheme.light(TweakcnThemes.conduit);
  final router = GoRouter(
    initialLocation: Routes.serverConnection,
    routes: [
      GoRoute(
        path: Routes.serverConnection,
        builder: (_, _) => connectionPage,
      ),
      GoRoute(
        path: Routes.chat,
        builder: (_, _) {
          onNavigated?.call(Routes.chat);
          return const Scaffold(
            body: Center(child: Text('Chat Page Destination')),
          );
        },
      ),
    ],
  );

  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: theme,
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

void main() {
  late MockLobeHubApiClient mockApiClient;
  late InMemorySecureKeyValueStore mockSecureStorage;

  setUp(() {
    mockApiClient = MockLobeHubApiClient();
    mockSecureStorage = InMemorySecureKeyValueStore();
  });

  group('LobeHubConnectionPage - URL normalization unit tests', () {
    test('prepends https:// when domain is entered without protocol', () {
      expect(
        LobeHubConnectionPage.normalizeServerUrl('ai.opw.ink'),
        equals('https://ai.opw.ink'),
      );
      expect(
        LobeHubConnectionPage.normalizeServerUrl('my-server.local:8080'),
        equals('https://my-server.local:8080'),
      );
    });

    test('preserves existing https:// and http:// schemes', () {
      expect(
        LobeHubConnectionPage.normalizeServerUrl('https://ai.opw.ink'),
        equals('https://ai.opw.ink'),
      );
      expect(
        LobeHubConnectionPage.normalizeServerUrl('http://192.168.1.100:3210'),
        equals('http://192.168.1.100:3210'),
      );
    });

    test('defaults to https://ai.opw.ink on empty input', () {
      expect(
        LobeHubConnectionPage.normalizeServerUrl(''),
        equals('https://ai.opw.ink'),
      );
      expect(
        LobeHubConnectionPage.normalizeServerUrl('   '),
        equals('https://ai.opw.ink'),
      );
    });
  });

  group('LobeHubConnectionPage - Widget Rendering', () {
    testWidgets('renders header, pre-filled default URL, API key field, and connect button', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          child: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      // Header copy
      expect(find.text('Connect to LobeHub'), findsOneWidget);
      expect(find.text('连接到自建 LobeHub 服务'), findsOneWidget);

      // Pre-filled URL field
      final urlFieldFinder = find.byKey(const Key('lobehub-server-url-field'));
      expect(urlFieldFinder, findsOneWidget);
      final urlFieldWidget = tester.widget<AccessibleFormField>(urlFieldFinder);
      expect(urlFieldWidget.controller?.text, equals('https://ai.opw.ink'));

      // API key field
      final apiKeyFieldFinder = find.byKey(const Key('lobehub-api-key-field'));
      expect(apiKeyFieldFinder, findsOneWidget);
      final apiKeyFieldWidget = tester.widget<AccessibleFormField>(apiKeyFieldFinder);
      expect(apiKeyFieldWidget.obscureText, isTrue);

      // Connect button
      expect(find.byKey(const Key('lobehub-connect-button')), findsOneWidget);
      expect(find.text('Test and Connect (测试并连接)'), findsOneWidget);
    });

    testWidgets('toggles API key obscureText on visibility button click', (tester) async {
      await tester.pumpWidget(
        createTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          child: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      final toggleFinder = find.byKey(const Key('lobehub-api-key-toggle-button'));
      expect(toggleFinder, findsOneWidget);

      // Initially obscured
      var apiKeyField = tester.widget<AccessibleFormField>(
        find.byKey(const Key('lobehub-api-key-field')),
      );
      expect(apiKeyField.obscureText, isTrue);

      // Tap toggle
      await tester.tap(toggleFinder);
      await tester.pumpAndSettle();

      // Now revealed
      apiKeyField = tester.widget<AccessibleFormField>(
        find.byKey(const Key('lobehub-api-key-field')),
      );
      expect(apiKeyField.obscureText, isFalse);
    });

    testWidgets('shows validation error when fields are empty', (tester) async {
      await tester.pumpWidget(
        createTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          child: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      // Clear URL field
      final urlInput = find.descendant(
        of: find.byKey(const Key('lobehub-server-url-field')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(urlInput, '');

      // Tap connect
      await tester.tap(find.byKey(const Key('lobehub-connect-button')));
      await tester.pumpAndSettle();

      // Validation errors should appear
      expect(find.text('Please enter server URL'), findsOneWidget);
      expect(find.text('Please enter API Key'), findsOneWidget);
    });
  });

  group('LobeHubConnectionPage - Happy Path & Navigation', () {
    testWidgets('successful health check & user profile saves credentials, shows welcome, and navigates to Routes.chat', (
      tester,
    ) async {
      // Mock API responses
      when(() => mockApiClient.checkHealth()).thenAnswer(
        (_) async => const LobeHealthResponse(service: 'lobehub', status: 'ok'),
      );
      when(() => mockApiClient.getCurrentUser()).thenAnswer(
        (_) async => const LobeUser(
          id: 'usr_123',
          username: 'darren',
          fullName: 'Darren X',
          email: 'darren@example.com',
        ),
      );

      String? navigatedRoute;

      await tester.pumpWidget(
        createRouterTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          onNavigated: (route) => navigatedRoute = route,
          connectionPage: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      // Enter API key
      final apiKeyInput = find.descendant(
        of: find.byKey(const Key('lobehub-api-key-field')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(apiKeyInput, 'sk-lh-test-secret-key');

      // Tap connect button
      await tester.tap(find.byKey(const Key('lobehub-connect-button')));
      await tester.pump();

      // Verify health check & getCurrentUser were called
      verify(() => mockApiClient.checkHealth()).called(1);
      verify(() => mockApiClient.getCurrentUser()).called(1);

      await tester.pumpAndSettle();

      // Verify credentials were saved to secure storage
      expect(
        await mockSecureStorage.read(key: 'lobehub_server_url'),
        equals('https://ai.opw.ink'),
      );
      expect(
        await mockSecureStorage.read(key: 'lobehub_api_key'),
        equals('sk-lh-test-secret-key'),
      );
      expect(
        await mockSecureStorage.read(key: 'lobehub_username'),
        equals('Darren X'),
      );
      expect(
        await mockSecureStorage.read(key: 'lobehub_user_id'),
        equals('usr_123'),
      );

      // Verify welcome message and navigation
      expect(find.text('Welcome, Darren X'), findsWidgets);
      expect(find.text('Chat Page Destination'), findsOneWidget);
      expect(navigatedRoute, equals(Routes.chat));
    });

    testWidgets('URL auto-completion: entering bare domain auto-prepends https:// on submission', (
      tester,
    ) async {
      when(() => mockApiClient.checkHealth()).thenAnswer(
        (_) async => const LobeHealthResponse(service: 'lobehub', status: 'ok'),
      );
      when(() => mockApiClient.getCurrentUser()).thenAnswer(
        (_) async => const LobeUser(id: 'usr_operator', username: 'operator'),
      );

      await tester.pumpWidget(
        createRouterTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          connectionPage: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      // Enter domain without protocol
      final urlInput = find.descendant(
        of: find.byKey(const Key('lobehub-server-url-field')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(urlInput, 'ai.opw.ink');

      final apiKeyInput = find.descendant(
        of: find.byKey(const Key('lobehub-api-key-field')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(apiKeyInput, 'sk-lh-my-token');

      await tester.tap(find.byKey(const Key('lobehub-connect-button')));
      await tester.pumpAndSettle();

      // Saved URL must have https:// prepended
      expect(
        await mockSecureStorage.read(key: 'lobehub_server_url'),
        equals('https://ai.opw.ink'),
      );
    });
  });

  group('LobeHubConnectionPage - Failure Paths & Error Display', () {
    testWidgets('displays invalid API key message on 401 Unauthorized and enables button', (
      tester,
    ) async {
      when(() => mockApiClient.checkHealth()).thenAnswer(
        (_) async => const LobeHealthResponse(service: 'lobehub', status: 'ok'),
      );
      when(() => mockApiClient.getCurrentUser()).thenThrow(
        const LobeHubAuthException('Unauthorized', statusCode: 401),
      );

      await tester.pumpWidget(
        createTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          child: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      final apiKeyInput = find.descendant(
        of: find.byKey(const Key('lobehub-api-key-field')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(apiKeyInput, 'sk-lh-invalid-key');

      await tester.tap(find.byKey(const Key('lobehub-connect-button')));
      await tester.pumpAndSettle();

      // Error banner with clear copy
      expect(find.byKey(const Key('lobehub-error-banner')), findsOneWidget);
      expect(
        find.text('Invalid API key, please check permissions'),
        findsOneWidget,
      );

      // Button is reset and enabled
      final connectBtnFinder = find.byKey(const Key('lobehub-connect-button'));
      expect(connectBtnFinder, findsOneWidget);
      final connectBtn = tester.widget<ConduitButton>(connectBtnFinder);
      expect(connectBtn.isLoading, isFalse);
    });

    testWidgets('displays unable to connect message on network failure / invalid URL', (
      tester,
    ) async {
      when(() => mockApiClient.checkHealth()).thenThrow(
        const LobeHubException('Failed host lookup: ai.opw.ink.invalid'),
      );

      await tester.pumpWidget(
        createTestHarness(
          overrides: [
            secureStorageProvider.overrideWithValue(mockSecureStorage),
          ],
          child: LobeHubConnectionPage(apiClient: mockApiClient),
        ),
      );
      await tester.pumpAndSettle();

      final apiKeyInput = find.descendant(
        of: find.byKey(const Key('lobehub-api-key-field')),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(apiKeyInput, 'sk-lh-test-key');

      await tester.tap(find.byKey(const Key('lobehub-connect-button')));
      await tester.pumpAndSettle();

      // Error banner with clear connection error copy
      expect(find.byKey(const Key('lobehub-error-banner')), findsOneWidget);
      expect(find.text('Unable to connect to server'), findsOneWidget);

      // Button is reset and enabled
      final connectBtn = tester.widget<ConduitButton>(
        find.byKey(const Key('lobehub-connect-button')),
      );
      expect(connectBtn.isLoading, isFalse);
    });
  });
}

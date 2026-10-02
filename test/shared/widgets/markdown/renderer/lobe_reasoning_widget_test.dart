import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/streaming_markdown_widget.dart';
import 'package:conduit_markdown/conduit_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _buildTestHarness({
  required String content,
  bool isStreaming = false,
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Scaffold(
        body: SingleChildScrollView(
          child: StreamingMarkdownWidget(
            content: content,
            isStreaming: isStreaming,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LobeHub Reasoning Tags & Parser Support', () {
    test('ReasoningParser supports all 8 primary thinking tags', () {
      final tags = [
        '<think>',
        '<thought>',
        '<reasoning>',
        '<antThinking>',
        '<brainstorm>',
        '<reflection>',
        '<inner_monologue>',
        '<justification>',
      ];

      for (final tag in tags) {
        final tagName = tag.replaceAll('<', '').replaceAll('>', '');
        final endTag = '</$tagName>';
        final content = '$tag Thinking deeply about $tagName $endTag Final text';

        check(ReasoningParser.hasReasoningContent(content)).isTrue();

        final segments = ReasoningParser.segments(content);
        check(segments).isNotNull();
        check(segments!.length).equals(2);
        check(segments[0].isReasoning).isTrue();
        check(segments[0].entry!.reasoning).contains('Thinking deeply about $tagName');
        check(segments[1].isReasoning).isFalse();
        check(segments[1].text).equals('Final text');
      }
    });

    test('ReasoningParser.countWords correctly counts Latin, CJK, and mixed text', () {
      // English / Latin
      check(ReasoningParser.countWords('')).equals(0);
      check(ReasoningParser.countWords('   ')).equals(0);
      check(ReasoningParser.countWords('Thought for 5 seconds')).equals(4);

      // CJK
      check(ReasoningParser.countWords('已深度思考')).equals(5);
      check(ReasoningParser.countWords('人工智能深度推理测试')).equals(10);

      // Mixed
      check(ReasoningParser.countWords('DeepSeek R1 深度思考 123')).equals(6);
    });

    test('ReasoningParser.formatCompletedSummary produces accurate English and Chinese labels', () {
      // English
      check(ReasoningParser.formatCompletedSummary(
        seconds: 5,
        words: 42,
        isChinese: false,
      )).equals('Thought for 5s (42 words)');

      check(ReasoningParser.formatCompletedSummary(
        seconds: 0,
        words: 42,
        isChinese: false,
      )).equals('Thought (42 words)');

      // Chinese
      check(ReasoningParser.formatCompletedSummary(
        seconds: 5,
        words: 42,
        isChinese: true,
      )).equals('已深度思考 5秒 (42字)');

      check(ReasoningParser.formatCompletedSummary(
        seconds: 0,
        words: 42,
        isChinese: true,
      )).equals('已深度思考 (42字)');

      check(ReasoningParser.formatCompletedSummary(
        seconds: 0,
        words: 0,
        isChinese: true,
      )).equals('已深度思考');
    });

    test('StreamingReasoningTagSplitter splits all 8 thinking tags accurately', () {
      final tags = [
        ('think', 'thought content'),
        ('antThinking', 'claude reasoning'),
        ('brainstorm', 'ideas and exploration'),
        ('reflection', 'self correction'),
        ('inner_monologue', 'deliberation'),
        ('justification', 'proof steps'),
      ];

      for (final (tag, text) in tags) {
        final splitter = StreamingReasoningTagSplitter();
        final events = [
          ...splitter.feed('<$tag>$text</$tag>Final answer'),
          ...splitter.flush(),
        ];

        final reasoningEvents = events.whereType<RawReasoningTagReasoning>();
        final textEvents = events.whereType<RawReasoningTagText>();

        check(reasoningEvents.isNotEmpty).isTrue();
        check(reasoningEvents.first.text).equals(text);
        check(textEvents.any((e) => e.text.contains('Final answer'))).isTrue();
      }
    });
  });

  group('LobeHub Reasoning Widget Rendering', () {
    testWidgets('Active streaming reasoning is expanded by default with shimmer', (
      tester,
    ) async {
      const streamingContent = '''
<details type="reasoning" client="lobehub" done="false" open="true">
<summary>Thinking…</summary>
Analyzing problem constraints and designing architecture...
</details>
''';

      await tester.pumpWidget(_buildTestHarness(
        content: streamingContent,
        isStreaming: true,
        locale: const Locale('en'),
      ));
      await tester.pump();

      // Capsule header is displayed with active thinking indicator
      expect(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')), findsOneWidget);
      expect(find.text('Deep thinking in progress…'), findsOneWidget);

      // Reasoning body is expanded by default during active streaming
      expect(find.textContaining('Analyzing problem constraints'), findsOneWidget);
    });

    testWidgets('Active streaming displays localized Chinese thinking indicator', (
      tester,
    ) async {
      const streamingContent = '''
<details type="reasoning" client="lobehub" done="false" open="true">
<summary>Thinking…</summary>
正在分析问题约束...
</details>
''';

      await tester.pumpWidget(_buildTestHarness(
        content: streamingContent,
        isStreaming: true,
        locale: const Locale('zh'),
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')), findsOneWidget);
      expect(find.text('正在深度思考…'), findsOneWidget);
      expect(find.textContaining('正在分析问题约束'), findsOneWidget);
    });

    testWidgets('Completed stream automatically collapses into capsule with word count and duration', (
      tester,
    ) async {
      const completedContent = '''
<details type="reasoning" client="lobehub" done="true" duration="8">
<summary>Thinking…</summary>
First step is complete and verified with extensive tests.
</details>
Here is the final response.
''';

      await tester.pumpWidget(_buildTestHarness(
        content: completedContent,
        isStreaming: false,
        locale: const Locale('en'),
      ));
      await tester.pumpAndSettle();

      // Capsule header is present with duration and word count
      expect(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')), findsOneWidget);
      expect(find.textContaining('Thought for 8s'), findsOneWidget);
      expect(find.textContaining('words)'), findsOneWidget);

      // Collapsed by default: reasoning body is not visible
      expect(find.text('First step is complete and verified with extensive tests.'), findsNothing);

      // Final response text is visible
      expect(find.text('Here is the final response.'), findsOneWidget);

      // Tapping capsule seamlessly toggles inline expansion
      await tester.tap(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')));
      await tester.pumpAndSettle();

      // Now expanded inline
      expect(find.textContaining('First step is complete'), findsOneWidget);

      // Tap again to collapse
      await tester.tap(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')));
      await tester.pumpAndSettle();

      expect(find.text('First step is complete and verified with extensive tests.'), findsNothing);
    });

    testWidgets('Non-thinking models with empty or null reasoning do not render empty placeholder', (
      tester,
    ) async {
      const emptyReasoningContent = '''
<details type="reasoning" client="lobehub" done="true">
<summary>Thinking…</summary>
</details>
Direct response without any thinking.
''';

      await tester.pumpWidget(_buildTestHarness(
        content: emptyReasoningContent,
        isStreaming: false,
      ));
      await tester.pumpAndSettle();

      // No capsule header or empty placeholder is rendered
      expect(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')), findsNothing);
      expect(find.text('Thinking…'), findsNothing);
      expect(find.text('Thoughts'), findsNothing);

      // Content flows immediately
      expect(find.text('Direct response without any thinking.'), findsOneWidget);
    });

    testWidgets('Raw <think> tags in markdown are normalized and rendered smoothly', (
      tester,
    ) async {
      const rawThinkContent = '''
<think>
Deep reasoning executed here.
</think>
Calculated result is 42.
''';

      await tester.pumpWidget(_buildTestHarness(
        content: rawThinkContent,
        isStreaming: false,
      ));
      await tester.pumpAndSettle();

      // Rendered as Lobe reasoning capsule
      expect(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')), findsOneWidget);
      expect(find.text('Calculated result is 42.'), findsOneWidget);

      // Tap to expand
      await tester.tap(find.byKey(const ValueKey<String>('lobe-reasoning-capsule-header')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Deep reasoning executed here.'), findsOneWidget);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/utils/syntax_highlighter.dart';

void main() {
  group('detectCodeLanguage', () {
    test('detects Dart by .dart extension', () {
      expect(detectCodeLanguage('lib/main.dart'), CodeLanguage.dart);
    });

    test('detects Kotlin and Java by extensions', () {
      expect(detectCodeLanguage('App.kt'), CodeLanguage.kotlinJava);
      expect(detectCodeLanguage('build.gradle.kts'), CodeLanguage.kotlinJava);
      expect(detectCodeLanguage('MainActivity.java'), CodeLanguage.kotlinJava);
    });

    test('detects JS and TS by extensions', () {
      expect(detectCodeLanguage('index.js'), CodeLanguage.javascriptTypescript);
      expect(
        detectCodeLanguage('component.tsx'),
        CodeLanguage.javascriptTypescript,
      );
      expect(
        detectCodeLanguage('server.mjs'),
        CodeLanguage.javascriptTypescript,
      );
    });

    test('detects Python by extensions', () {
      expect(detectCodeLanguage('script.py'), CodeLanguage.python);
      expect(detectCodeLanguage('gui.pyw'), CodeLanguage.python);
    });

    test('detects JSON and YAML by extensions', () {
      expect(detectCodeLanguage('pubspec.yaml'), CodeLanguage.jsonYaml);
      expect(detectCodeLanguage('config.yml'), CodeLanguage.jsonYaml);
      expect(detectCodeLanguage('data.json'), CodeLanguage.jsonYaml);
    });

    test('falls back to plainText for unknown or missing extensions', () {
      expect(detectCodeLanguage('README.md'), CodeLanguage.plainText);
      expect(detectCodeLanguage('notes.txt'), CodeLanguage.plainText);
      expect(detectCodeLanguage('LICENSE'), CodeLanguage.plainText);
      expect(detectCodeLanguage(null), CodeLanguage.plainText);
      expect(detectCodeLanguage(''), CodeLanguage.plainText);
    });
  });

  group('SyntaxHighlighter.highlight', () {
    test('plain-text fallback returns single uncolored TextSpan', () {
      const code = 'class Foo extends Bar { void test() {} }';
      final spans = SyntaxHighlighter.highlight(
        text: code,
        language: CodeLanguage.plainText,
        isDark: false,
      );

      expect(spans.length, 1);
      expect(spans.first.text, code);
      expect(spans.first.style?.color, isNull);
    });

    test(
      'highlights Dart keywords, strings, comments, numbers, and identifiers in light mode',
      () {
        const code = '''
// Header comment
class MyWidget {
  final int count = 42;
  String message = "hello";
}
''';
        final spans = SyntaxHighlighter.highlight(
          text: code,
          language: CodeLanguage.dart,
          isDark: false,
        );

        final palette = SyntaxPalette.light;

        // Comment
        final commentSpan = spans.firstWhere(
          (s) => s.text?.contains('// Header comment') ?? false,
        );
        expect(commentSpan.style?.color, palette.comment);

        // Keywords: class, final
        final classSpan = spans.firstWhere((s) => s.text == 'class');
        expect(classSpan.style?.color, palette.keyword);
        expect(classSpan.style?.fontWeight, FontWeight.w600);

        final finalSpan = spans.firstWhere((s) => s.text == 'final');
        expect(finalSpan.style?.color, palette.keyword);

        // Identifiers / Types: MyWidget, int, String
        final widgetSpan = spans.firstWhere((s) => s.text == 'MyWidget');
        expect(widgetSpan.style?.color, palette.identifier);

        final intSpan = spans.firstWhere((s) => s.text == 'int');
        expect(intSpan.style?.color, palette.identifier);

        final stringSpan = spans.firstWhere((s) => s.text == 'String');
        expect(stringSpan.style?.color, palette.identifier);

        // Number: 42
        final numberSpan = spans.firstWhere((s) => s.text == '42');
        expect(numberSpan.style?.color, palette.number);

        // String literal: "hello"
        final strLitSpan = spans.firstWhere((s) => s.text == '"hello"');
        expect(strLitSpan.style?.color, palette.string);
      },
    );

    test('highlights Dart in dark mode using dark palette', () {
      const code = 'final double pi = 3.14; // constant';
      final spans = SyntaxHighlighter.highlight(
        text: code,
        language: CodeLanguage.dart,
        isDark: true,
      );

      final palette = SyntaxPalette.dark;

      final finalSpan = spans.firstWhere((s) => s.text == 'final');
      expect(finalSpan.style?.color, palette.keyword);

      final numSpan = spans.firstWhere((s) => s.text == '3.14');
      expect(numSpan.style?.color, palette.number);

      final commentSpan = spans.firstWhere(
        (s) => s.text?.contains('// constant') ?? false,
      );
      expect(commentSpan.style?.color, palette.comment);
    });

    test(
      'bounds highlighting for large inputs exceeding maxHighlightChars',
      () {
        final largeCode = 'class Foo {} ' * 5000; // ~65,000 chars
        expect(largeCode.length > SyntaxHighlighter.maxHighlightChars, isTrue);

        final spans = SyntaxHighlighter.highlight(
          text: largeCode,
          language: CodeLanguage.dart,
          isDark: false,
        );

        // Verify that full text is preserved across all spans
        final totalLength = spans.fold<int>(
          0,
          (sum, s) => sum + (s.text?.length ?? 0),
        );
        expect(totalLength, largeCode.length);

        // The final span should contain the overflow text without crashing
        expect(spans.last.style?.color, isNull);
      },
    );
  });

  group('SyntaxTextEditingController selection and editing behavior', () {
    testWidgets('builds text span and preserves editing and selection', (
      tester,
    ) async {
      final controller = SyntaxTextEditingController(
        text: 'void main() {\n  print("hello");\n}',
        language: CodeLanguage.dart,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(body: TextField(controller: controller)),
        ),
      );

      // Verify initial text
      expect(controller.text, 'void main() {\n  print("hello");\n}');

      // Test cursor selection
      controller.selection = const TextSelection.collapsed(offset: 4);
      expect(controller.selection.baseOffset, 4);
      expect(controller.selection.extentOffset, 4);

      // Test text range selection
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      expect(controller.selection.textInside(controller.text), 'void');

      // Test text editing / mutation
      controller.text = 'int calculate() => 42;';
      expect(controller.text, 'int calculate() => 42;');

      // Changing language notifies listeners and rebuilds
      controller.language = CodeLanguage.python;
      expect(controller.language, CodeLanguage.python);

      controller.dispose();
    });

    testWidgets('respects IME composing underline when active', (tester) async {
      final controller = SyntaxTextEditingController(
        text: 'hello world',
        language: CodeLanguage.dart,
      );

      late BuildContext buildCtx;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                buildCtx = ctx;
                return TextField(controller: controller);
              },
            ),
          ),
        ),
      );

      // Set composing range
      controller.value = const TextEditingValue(
        text: 'hello world',
        composing: TextRange(start: 0, end: 5),
      );

      final span = controller.buildTextSpan(
        context: buildCtx,
        withComposing: true,
      );

      expect(span.children?.length, 3);
      // The composing span has underline decoration
      expect(span.children![1].style?.decoration, TextDecoration.underline);

      controller.dispose();
    });
  });
}

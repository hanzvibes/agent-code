import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/core/ui.dart';
import 'package:code_harness/widgets/markdown_message_view.dart';

void main() {
  testWidgets(
    'renders markdown headings, lists, inline code, and fenced code block',
    (tester) async {
      const markdown = '''
# Main Title
Here is a paragraph with `inline code` and **bold text**.

* Bullet 1
* Bullet 2

```dart
void main() {
  print('hello');
}
```
''';

      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final t = AppTokens.of(context);
                return MarkdownMessageView(content: markdown, t: t);
              },
            ),
          ),
        ),
      );

      expect(find.text('Main Title'), findsOneWidget);
      expect(find.text('Bullet 1'), findsOneWidget);
      expect(find.text('Bullet 2'), findsOneWidget);
      expect(find.text('inline code'), findsOneWidget);
      expect(find.text('dart'), findsOneWidget);
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'explicit code-block copy button copies code block to clipboard',
    (tester) async {
      const markdown = '''
```dart
int add(int a, int b) => a + b;
```
''';

      String? copiedClipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<dynamic, dynamic>;
              copiedClipboardText = args['text'] as String?;
              return null;
            }
            return null;
          });

      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final t = AppTokens.of(context);
                return MarkdownMessageView(content: markdown, t: t);
              },
            ),
          ),
        ),
      );

      final copyBtn = find.byTooltip('Copy code block');
      expect(copyBtn, findsOneWidget);
      await tester.tap(copyBtn);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      expect(copiedClipboardText, contains('int add(int a, int b) => a + b;'));
    },
  );
}

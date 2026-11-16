import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/utils/unified_patch.dart';

void main() {
  group('ProviderProfile endpoint', () {
    ProviderProfile profile(String url) => ProviderProfile(
      id: 'test',
      name: 'Gateway',
      baseUrl: url,
      modelId: 'model-id',
    );

    test('adds the standard v1 endpoint to a host-only URL', () {
      expect(
        profile('https://gateway.example').chatCompletionsUrl,
        'https://gateway.example/v1/chat/completions',
      );
    });

    test('appends chat completions to a versioned API base', () {
      expect(
        profile('https://gateway.example/api/v2/').chatCompletionsUrl,
        'https://gateway.example/api/v2/chat/completions',
      );
    });

    test('preserves a full chat completions endpoint', () {
      expect(
        profile(
          'https://gateway.example/v1/chat/completions/',
        ).chatCompletionsUrl,
        'https://gateway.example/v1/chat/completions',
      );
    });

    test('rejects unsafe or malformed base URLs', () {
      expect(
        ProviderProfile.validateBaseUrl('ftp://gateway.example'),
        isNotNull,
      );
      expect(
        ProviderProfile.validateBaseUrl('httpx://gateway.example'),
        isNotNull,
      );
      expect(
        ProviderProfile.validateBaseUrl('https://user:pass@gateway.example'),
        isNotNull,
      );
      expect(
        ProviderProfile.validateBaseUrl('https://gateway.example?token=x'),
        isNotNull,
      );
    });
  });

  group('UnifiedPatchParser', () {
    test('extracts and applies a fenced patch with exact context', () {
      const response = '''Change the greeting.
```diff
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1,3 +1,3 @@
 void main() {
-  print('hello');
+  print('hello from AI');
 }
```
''';
      final patch = UnifiedPatchParser.extract(response)!;
      final changes = UnifiedPatchParser.apply(patch, {
        'lib/main.dart': "void main() {\n  print('hello');\n}\n",
      });
      expect(
        changes.single.after,
        "void main() {\n  print('hello from AI');\n}\n",
      );
    });

    test('allows a new file', () {
      const patch = '''--- /dev/null
+++ b/lib/new_file.dart
@@ -0,0 +1,1 @@
+void main() {}
''';
      final changes = UnifiedPatchParser.apply(patch, const {});
      expect(changes.single.path, 'lib/new_file.dart');
      expect(changes.single.before, isEmpty);
    });

    test('rejects context that no longer matches', () {
      const patch = '''--- a/main.dart
+++ b/main.dart
@@ -1,1 +1,1 @@
-old
+new
''';
      expect(
        () => UnifiedPatchParser.apply(patch, {'main.dart': 'changed\n'}),
        throwsA(isA<UnifiedPatchException>()),
      );
    });

    test('rejects path traversal, deletion, and rename', () {
      const traversal = '''--- a/../outside.txt
+++ b/../outside.txt
@@ -1,1 +1,1 @@
-old
+new
''';
      const deletion = '''--- a/old.txt
+++ /dev/null
@@ -1,1 +0,0 @@
-old
''';
      const rename = '''--- a/old.txt
+++ b/new.txt
@@ -1,1 +1,1 @@
-old
+new
''';
      expect(
        () => UnifiedPatchParser.outputPaths(traversal),
        throwsA(isA<UnifiedPatchException>()),
      );
      expect(
        () => UnifiedPatchParser.apply(deletion, {'old.txt': 'old\n'}),
        throwsA(isA<UnifiedPatchException>()),
      );
      expect(
        () => UnifiedPatchParser.apply(rename, {'new.txt': 'old\n'}),
        throwsA(isA<UnifiedPatchException>()),
      );
    });

    test('rejects duplicate target paths', () {
      const patch = '''--- a/main.dart
+++ b/main.dart
@@ -1,1 +1,1 @@
-old
+first
--- a/main.dart
+++ b/main.dart
@@ -1,1 +1,1 @@
-old
+second
''';
      expect(
        () => UnifiedPatchParser.apply(patch, {'main.dart': 'old\n'}),
        throwsA(isA<UnifiedPatchException>()),
      );
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/controllers/app_controller.dart';
import 'package:code_harness/controllers/project_controller.dart';
import 'package:code_harness/controllers/review_controller.dart';
import 'package:code_harness/models/app_prefs.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/repositories/prefs_repository.dart';
import 'package:code_harness/repositories/profile_repository.dart';
import 'package:code_harness/utils/unified_patch.dart';

class _FakePrefsRepo extends PrefsRepository {
  final AppPrefs _prefs = AppPrefs();
  @override
  AppPrefs get prefs => _prefs;
  @override
  Future<void> save(AppPrefs prefs) async {}
}

class _FakeProfileRepo extends ProfileRepository {
  @override
  List<ProviderProfile> getAll() => [];
}

void main() {
  group('Per-hunk diff parser & reconstruction', () {
    test('parses multiple distant hunks in a single file', () {
      final original =
          '${List.generate(30, (i) => 'line ${i + 1}').join('\n')}\n';
      const patch = '''
--- a/file.txt
+++ b/file.txt
@@ -4,4 +4,4 @@
 line 4
-line 5
+line 5 modified
 line 6
 line 7
@@ -20,4 +20,4 @@
 line 20
-line 21
+line 21 modified
 line 22
 line 23
''';

      final changes = UnifiedPatchParser.apply(patch, {'file.txt': original});
      expect(changes.length, 1);
      final change = changes.first;
      expect(change.hunks.length, 2);

      // Verify hunk 1 properties
      expect(change.hunks[0].oldStart, 4);
      expect(change.hunks[0].oldCount, 4);
      expect(change.hunks[0].newStart, 4);
      expect(change.hunks[0].newCount, 4);
      expect(change.hunks[0].isSelected, isTrue);

      // Verify hunk 2 properties
      expect(change.hunks[1].oldStart, 20);
      expect(change.hunks[1].oldCount, 4);
      expect(change.hunks[1].newStart, 20);
      expect(change.hunks[1].newCount, 4);
      expect(change.hunks[1].isSelected, isTrue);
    });

    test(
      'selecting one of multiple distant hunks (hunk 1 selected, hunk 2 unselected)',
      () {
        final original =
            '${List.generate(30, (i) => 'line ${i + 1}').join('\n')}\n';
        const patch = '''
--- a/file.txt
+++ b/file.txt
@@ -4,4 +4,4 @@
 line 4
-line 5
+line 5 modified
 line 6
 line 7
@@ -20,4 +20,4 @@
 line 20
-line 21
+line 21 modified
 line 22
 line 23
''';

        final changes = UnifiedPatchParser.apply(patch, {'file.txt': original});
        final hunks = changes.first.hunks;

        // Select only Hunk 1, unselect Hunk 2
        final selection = [
          hunks[0].copyWith(isSelected: true),
          hunks[1].copyWith(isSelected: false),
        ];

        final reconstructed = UnifiedPatchParser.reconstructFile(
          original: original,
          hunks: selection,
          isNewFile: false,
        );

        expect(reconstructed, contains('line 5 modified'));
        expect(reconstructed, contains('line 21\n'));
        expect(reconstructed, isNot(contains('line 21 modified')));
      },
    );

    test(
      'selecting one of multiple distant hunks (hunk 1 unselected, hunk 2 selected)',
      () {
        final original =
            '${List.generate(30, (i) => 'line ${i + 1}').join('\n')}\n';
        const patch = '''
--- a/file.txt
+++ b/file.txt
@@ -4,4 +4,4 @@
 line 4
-line 5
+line 5 modified
 line 6
 line 7
@@ -20,4 +20,4 @@
 line 20
-line 21
+line 21 modified
 line 22
 line 23
''';

        final changes = UnifiedPatchParser.apply(patch, {'file.txt': original});
        final hunks = changes.first.hunks;

        // Unselect Hunk 1, select Hunk 2
        final selection = [
          hunks[0].copyWith(isSelected: false),
          hunks[1].copyWith(isSelected: true),
        ];

        final reconstructed = UnifiedPatchParser.reconstructFile(
          original: original,
          hunks: selection,
          isNewFile: false,
        );

        expect(reconstructed, contains('line 5\n'));
        expect(reconstructed, isNot(contains('line 5 modified')));
        expect(reconstructed, contains('line 21 modified'));
      },
    );

    test('none selected results in content identical to before', () {
      final original =
          '${List.generate(20, (i) => 'line ${i + 1}').join('\n')}\n';
      const patch = '''
--- a/file.txt
+++ b/file.txt
@@ -2,3 +2,3 @@
 line 2
-line 3
+line 3 new
 line 4
@@ -8,3 +8,3 @@
 line 8
-line 9
+line 9 new
 line 10
''';

      final changes = UnifiedPatchParser.apply(patch, {'file.txt': original});
      final hunks = changes.first.hunks
          .map((h) => h.copyWith(isSelected: false))
          .toList();

      final reconstructed = UnifiedPatchParser.reconstructFile(
        original: original,
        hunks: hunks,
        isNewFile: false,
      );

      expect(reconstructed, equals(original));
    });

    test('stale or invalid context throws UnifiedPatchException', () {
      const original = 'line 1\nstale line 2\nline 3\n';
      const patch = '''
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 line 1
-expected line 2
+new line 2
 line 3
''';

      expect(
        () => UnifiedPatchParser.apply(patch, {'file.txt': original}),
        throwsA(isA<UnifiedPatchException>()),
      );
    });

    test('rejects inconsistent new-side hunk line count', () {
      const patch = '''
--- a/file.txt
+++ b/file.txt
@@ -1,1 +1,2 @@
-original
+modified
''';

      expect(
        () => UnifiedPatchParser.apply(patch, {'file.txt': 'original\n'}),
        throwsA(isA<UnifiedPatchException>()),
      );
    });
  });

  group('ReviewController & ProjectController hunk selection', () {
    late Directory tempDir;
    late ProjectController projectController;
    late AppController appController;
    late ReviewController reviewController;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hunk_test_');
      appController = AppController(
        prefsRepo: _FakePrefsRepo(),
        profileRepo: _FakeProfileRepo(),
      );
      appController.onInit();
      projectController = ProjectController(appController);
      await projectController.openWorkspace(tempDir.path);
      reviewController = ReviewController();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'mixed file and hunk selections apply only chosen hunks across files',
      () async {
        // Create two workspace files
        final fileA = File('${tempDir.path}/a.txt');
        final fileB = File('${tempDir.path}/b.txt');
        await fileA.writeAsString('a1\na2\na3\na4\na5\n');
        await fileB.writeAsString('b1\nb2\nb3\nb4\nb5\n');

        const patch = '''
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
 a1
-a2
+a2_modified
 a3
@@ -4,2 +4,2 @@
-a4
+a4_modified
 a5
--- a/b.txt
+++ b/b.txt
@@ -1,3 +1,3 @@
 b1
-b2
+b2_modified
 b3
''';

        reviewController.loadPatch(
          patch,
          {'a.txt': 'a1\na2\na3\na4\na5\n', 'b.txt': 'b1\nb2\nb3\nb4\nb5\n'},
          existedAtPreview: {'a.txt': true, 'b.txt': true},
        );

        expect(reviewController.totalHunks, 3);
        expect(reviewController.selectedHunksCount, 3);
        expect(reviewController.hasSelectedHunks, isTrue);

        // Unselect second hunk of a.txt (fileIndex 0, hunkIndex 1)
        reviewController.toggleHunk(0, 1);
        expect(reviewController.selectedHunksCount, 2);

        // Unselect only hunk of b.txt (fileIndex 1, hunkIndex 0)
        reviewController.toggleHunk(1, 0);
        expect(reviewController.selectedHunksCount, 1);

        // Apply the review controller's current patchFiles to disk
        await projectController.applyPatch(reviewController.patchFiles);

        // a.txt: hunk 1 should be applied, hunk 2 should be original!
        final contentA = await fileA.readAsString();
        expect(contentA, contains('a2_modified'));
        expect(contentA, contains('a4\n'));
        expect(contentA, isNot(contains('a4_modified')));

        // b.txt: hunk was unselected, file content should be completely unchanged!
        final contentB = await fileB.readAsString();
        expect(contentB, equals('b1\nb2\nb3\nb4\nb5\n'));
      },
    );

    test('none selected results in no file writes', () async {
      final fileA = File('${tempDir.path}/a.txt');
      await fileA.writeAsString('original\n');

      const patch = '''
--- a/a.txt
+++ b/a.txt
@@ -1,1 +1,1 @@
-original
+modified
''';

      reviewController.loadPatch(
        patch,
        {'a.txt': 'original\n'},
        existedAtPreview: {'a.txt': true},
      );

      // Deselect all
      reviewController.selectAllHunks(false);
      expect(reviewController.selectedHunksCount, 0);
      expect(reviewController.hasSelectedHunks, isFalse);

      await projectController.applyPatch(reviewController.patchFiles);

      // Disk content must remain untouched
      final content = await fileA.readAsString();
      expect(content, equals('original\n'));
      expect(projectController.lastAppliedPatch.value, isNull);
    });
  });
}

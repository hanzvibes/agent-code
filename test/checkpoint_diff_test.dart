import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/controllers/review_controller.dart';
import 'package:code_harness/models/checkpoint.dart';
import 'package:code_harness/utils/text_diff.dart';
import 'package:code_harness/utils/unified_patch.dart';

/// Verifies a generated diff round-trips through the existing parser:
/// applying it to [before] must reproduce [after] exactly.
String _roundTrip(String path, String before, String after) {
  final diff = buildUnifiedDiff(path: path, before: before, after: after);
  expect(diff, isNotEmpty);
  final changes = UnifiedPatchParser.apply(diff, {path: before});
  expect(changes, hasLength(1));
  return changes.first.after;
}

void main() {
  group('buildUnifiedDiff', () {
    test('simple edit round-trips through the parser', () {
      const before = 'line one\nline two\nline three\n';
      const after = 'line one\nline TWO\nline three\n';
      expect(_roundTrip('a.txt', before, after), after);
    });

    test('insertion and deletion round-trip', () {
      const before = 'a\nb\nc\nd\ne\nf\ng\n';
      const after = 'a\nX\nb\nc\nd\nf\ng\nh\n';
      expect(_roundTrip('a.txt', before, after), after);
    });

    test('two distant edits produce two hunks', () {
      final beforeLines = List.generate(30, (i) => 'line ${i + 1}');
      final afterLines = List.of(beforeLines)
        ..[1] = 'CHANGED 2'
        ..[27] = 'CHANGED 28';
      final before = '${beforeLines.join('\n')}\n';
      final after = '${afterLines.join('\n')}\n';
      final diff = buildUnifiedDiff(path: 'a.txt', before: before, after: after);
      expect(_roundTrip('a.txt', before, after), after);
      final hunkHeaders = diff
          .split('\n')
          .where((line) => line.startsWith('@@ '))
          .toList();
      expect(hunkHeaders, hasLength(2));
    });

    test('new file diff uses /dev/null and round-trips', () {
      const after = 'hello\nworld\n';
      final diff = buildUnifiedDiff(
        path: 'new.txt',
        before: '',
        after: after,
        isNewFile: true,
      );
      expect(diff, contains('--- /dev/null'));
      final changes = UnifiedPatchParser.apply(diff, {'new.txt': ''});
      expect(changes.first.after, after);
    });

    test('deleted file diff shows every line removed', () {
      const before = 'gone\nfor good\n';
      final diff = buildUnifiedDiff(path: 'old.txt', before: before, after: '');
      expect(diff, contains('--- a/old.txt'));
      final changes = UnifiedPatchParser.apply(diff, {'old.txt': before});
      expect(changes, hasLength(1));
      // The parser appends a trailing newline for display purposes;
      // the hunks themselves are what the history view renders.
      expect(changes.first.after.trim(), isEmpty);
      expect(
        changes.first.hunks.expand((h) => h.lines).every(
          (l) => l.startsWith('-'),
        ),
        isTrue,
      );
    });

    test('identical contents produce no diff', () {
      expect(
        buildUnifiedDiff(
          path: 'a.txt',
          before: 'same\n',
          after: 'same\n',
        ),
        isEmpty,
      );
    });

    test('trailing-newline-only change produces no diff', () {
      // The unified-diff parser cannot represent this; callers show a
      // note instead of an empty diff card.
      expect(
        buildUnifiedDiff(path: 'a.txt', before: 'same\n', after: 'same'),
        isEmpty,
      );
    });

    test('large files fall back to prefix/suffix and still round-trip', () {
      final beforeLines = List.generate(3000, (i) => 'line ${i + 1}');
      final afterLines = List.of(beforeLines)..[1500] = 'CHANGED';
      final before = '${beforeLines.join('\n')}\n';
      final after = '${afterLines.join('\n')}\n';
      expect(_roundTrip('big.txt', before, after), after);
    });

    test('empty to empty produces no diff', () {
      expect(buildUnifiedDiff(path: 'a.txt', before: '', after: ''), isEmpty);
    });
  });

  group('ReviewController.loadCheckpoints', () {
    test('edit checkpoint becomes a PatchFile with hunks', () {
      final ctrl = ReviewController();
      ctrl.loadCheckpoints([
        Checkpoint(
          taskId: 't1',
          stepId: 's1',
          path: 'lib/a.dart',
          before: 'void main() {}\n',
          after: 'void main() {\n  print(1);\n}\n',
          kind: CheckpointKind.write,
        ),
      ]);
      expect(ctrl.patchFiles, hasLength(1));
      final file = ctrl.patchFiles.first;
      expect(file.path, 'lib/a.dart');
      expect(file.before, 'void main() {}\n');
      expect(file.after, 'void main() {\n  print(1);\n}\n');
      expect(file.hunks, isNotEmpty);
      expect(
        file.hunks.expand((h) => h.lines).any((l) => l.startsWith('+')),
        isTrue,
      );
    });

    test('create checkpoint shows all lines added', () {
      final ctrl = ReviewController();
      ctrl.loadCheckpoints([
        Checkpoint(
          taskId: 't1',
          stepId: 's1',
          path: 'new.txt',
          before: null,
          after: 'fresh\nfile\n',
          kind: CheckpointKind.write,
        ),
      ]);
      final file = ctrl.patchFiles.first;
      expect(file.existedAtPreview, isFalse);
      expect(
        file.hunks.expand((h) => h.lines).every((l) => l.startsWith('+')),
        isTrue,
      );
    });

    test('delete checkpoint shows all lines removed', () {
      final ctrl = ReviewController();
      ctrl.loadCheckpoints([
        Checkpoint(
          taskId: 't1',
          stepId: 's1',
          path: 'old.txt',
          before: 'gone\n',
          after: null,
          trashPath: '.codeharness-trash/t1/old.txt',
          kind: CheckpointKind.delete,
        ),
      ]);
      final file = ctrl.patchFiles.first;
      expect(file.after, isEmpty);
      expect(
        file.hunks.expand((h) => h.lines).every((l) => l.startsWith('-')),
        isTrue,
      );
    });

    test('trailing-newline-only change gets a note hunk', () {
      final ctrl = ReviewController();
      ctrl.loadCheckpoints([
        Checkpoint(
          taskId: 't1',
          stepId: 's1',
          path: 'a.txt',
          before: 'same\n',
          after: 'same',
          kind: CheckpointKind.write,
        ),
      ]);
      final file = ctrl.patchFiles.first;
      expect(file.hunks, hasLength(1));
      expect(file.hunks.first.header, contains('@@'));
      expect(
        file.hunks.first.lines.join('\n'),
        contains('line ending only'),
      );
    });
  });
}

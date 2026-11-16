import 'package:get/get.dart';

import '../models/checkpoint.dart';
import '../utils/text_diff.dart';
import '../utils/unified_patch.dart';

class PatchFile {
  final String path;
  final String before;
  final String after;
  final bool existedAtPreview;
  final List<PatchHunk> hunks;

  const PatchFile({
    required this.path,
    required this.before,
    required this.after,
    required this.existedAtPreview,
    this.hunks = const [],
  });

  PatchFile copyWith({
    String? path,
    String? before,
    String? after,
    bool? existedAtPreview,
    List<PatchHunk>? hunks,
  }) {
    return PatchFile(
      path: path ?? this.path,
      before: before ?? this.before,
      after: after ?? this.after,
      existedAtPreview: existedAtPreview ?? this.existedAtPreview,
      hunks: hunks ?? this.hunks,
    );
  }
}

class ReviewController extends GetxController {
  final RxList<PatchFile> patchFiles = <PatchFile>[].obs;
  final RxString rawPatch = ''.obs;
  final RxString parseError = ''.obs;

  int get totalHunks {
    var count = 0;
    for (final f in patchFiles) {
      count += f.hunks.length;
    }
    return count;
  }

  int get selectedHunksCount {
    var count = 0;
    for (final f in patchFiles) {
      for (final h in f.hunks) {
        if (h.isSelected) count++;
      }
    }
    return count;
  }

  bool get hasSelectedHunks => selectedHunksCount > 0;

  void toggleHunk(int fileIndex, int hunkIndex) {
    if (fileIndex < 0 || fileIndex >= patchFiles.length) return;
    final file = patchFiles[fileIndex];
    if (hunkIndex < 0 || hunkIndex >= file.hunks.length) return;

    final targetHunk = file.hunks[hunkIndex];
    final updatedHunks = List<PatchHunk>.from(file.hunks);
    updatedHunks[hunkIndex] = targetHunk.copyWith(
      isSelected: !targetHunk.isSelected,
    );

    final newAfter = UnifiedPatchParser.reconstructFile(
      original: file.before,
      hunks: updatedHunks,
      isNewFile: !file.existedAtPreview,
    );

    patchFiles[fileIndex] = file.copyWith(after: newAfter, hunks: updatedHunks);
    patchFiles.refresh();
  }

  void selectAllHunks(bool selectAll) {
    for (var i = 0; i < patchFiles.length; i++) {
      final file = patchFiles[i];
      final updatedHunks = file.hunks
          .map((h) => h.copyWith(isSelected: selectAll))
          .toList();
      final newAfter = UnifiedPatchParser.reconstructFile(
        original: file.before,
        hunks: updatedHunks,
        isNewFile: !file.existedAtPreview,
      );
      patchFiles[i] = file.copyWith(after: newAfter, hunks: updatedHunks);
    }
    patchFiles.refresh();
  }

  /// Builds the change-history view of agent checkpoints (Batch 2 —
  /// desain D2/D9): one [PatchFile] per checkpoint, with hunks computed
  /// from the before/after contents through [UnifiedPatchParser] so the
  /// existing diff rendering can be reused. The files are display-only
  /// history — undo goes through [CheckpointStore], not apply.
  void loadCheckpoints(List<Checkpoint> checkpoints) {
    rawPatch.value = '';
    parseError.value = '';
    patchFiles.clear();

    final built = <PatchFile>[];
    for (final cp in checkpoints) {
      final before = cp.before ?? '';
      // A delete is shown as "every line removed" (after is empty).
      final after = cp.isDelete ? '' : (cp.after ?? '');
      final diff = buildUnifiedDiff(
        path: cp.path,
        before: before,
        after: after,
        isNewFile: cp.isCreate,
      );
      var hunks = const <PatchHunk>[];
      if (diff.isNotEmpty) {
        try {
          final changes = UnifiedPatchParser.apply(diff, {cp.path: before});
          hunks = changes.first.hunks;
        } catch (_) {
          hunks = const [];
        }
      } else if (before != after) {
        // Contents differ only in a trailing newline / line endings,
        // which a unified diff cannot represent: show a note instead
        // of an empty diff card.
        hunks = const [
          PatchHunk(
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            header: '@@ -1 +1 @@',
            lines: [
              '- (content changed: line ending only)',
              '+ (open the file to see the current content)',
            ],
          ),
        ];
      }
      built.add(
        PatchFile(
          path: cp.path,
          before: before,
          after: after,
          existedAtPreview: cp.isDelete ? true : cp.before != null,
          hunks: hunks,
        ),
      );
    }
    patchFiles.value = built;
  }

  void loadPatch(
    String patch,
    Map<String, String> fileContents, {
    Map<String, bool> existedAtPreview = const {},
  }) {
    rawPatch.value = patch;
    parseError.value = '';
    patchFiles.clear();

    try {
      final changes = UnifiedPatchParser.apply(patch, fileContents);
      patchFiles.value = changes
          .map(
            (change) => PatchFile(
              path: change.path,
              before: change.before,
              after: change.after,
              existedAtPreview:
                  existedAtPreview[change.path] ?? change.before.isNotEmpty,
              hunks: change.hunks,
            ),
          )
          .toList();
    } on UnifiedPatchException catch (error) {
      parseError.value = error.message;
    } catch (error) {
      parseError.value = 'Could not prepare the patch: $error';
    }
  }
}

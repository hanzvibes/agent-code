import 'package:get/get.dart';

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

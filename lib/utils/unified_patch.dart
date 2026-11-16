class UnifiedPatchException implements Exception {
  final String message;
  const UnifiedPatchException(this.message);

  @override
  String toString() => message;
}

/// Represents an individual diff hunk within a file change.
class PatchHunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final String header;
  final List<String> lines; // raw lines starting with ' ', '-', or '+'
  final bool isSelected;

  const PatchHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.header,
    required this.lines,
    this.isSelected = true,
  });

  PatchHunk copyWith({
    int? oldStart,
    int? oldCount,
    int? newStart,
    int? newCount,
    String? header,
    List<String>? lines,
    bool? isSelected,
  }) {
    return PatchHunk(
      oldStart: oldStart ?? this.oldStart,
      oldCount: oldCount ?? this.oldCount,
      newStart: newStart ?? this.newStart,
      newCount: newCount ?? this.newCount,
      header: header ?? this.header,
      lines: lines ?? this.lines,
      isSelected: isSelected ?? this.isSelected,
    );
  }
}

class UnifiedPatchChange {
  final String path;
  final String before;
  final String after;
  final List<PatchHunk> hunks;

  const UnifiedPatchChange({
    required this.path,
    required this.before,
    required this.after,
    this.hunks = const [],
  });
}

/// A deliberately strict, small unified-diff reader for assistant proposals.
/// It accepts ordinary `--- a/...` / `+++ b/...` headers and only applies a
/// patch when every removed/context line exactly matches the current file.
class UnifiedPatchParser {
  static String? extract(String response) {
    final fenced = RegExp(r'```[^\n]*\n([\s\S]*?)```').allMatches(response);
    for (final match in fenced) {
      final candidate = match.group(1)?.trim();
      if (candidate != null && _looksLikePatch(candidate)) return candidate;
    }
    final start = response.indexOf('--- a/');
    if (start >= 0) {
      final candidate = response.substring(start).trim();
      if (_looksLikePatch(candidate)) return candidate;
    }
    return null;
  }

  static bool _looksLikePatch(String text) =>
      RegExp(r'^\+\+\+ (?:b/|/dev/null)', multiLine: true).hasMatch(text) &&
      RegExp(r'^@@ ', multiLine: true).hasMatch(text);

  static List<String> outputPaths(String patch) {
    final result = <String>[];
    final lines = patch.replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < lines.length - 1; i++) {
      if (!lines[i].startsWith('--- ')) continue;
      final next = lines[i + 1];
      if (!next.startsWith('+++ ')) continue;
      final path = _normalisePath(next.substring(4));
      if (path != null && path != '/dev/null') result.add(path);
      i++;
    }
    return result.toSet().toList(growable: false);
  }

  /// Parses a unified patch and applies all hunks by default, returning
  /// [UnifiedPatchChange]s with per-file [PatchHunk] structure.
  static List<UnifiedPatchChange> apply(
    String patch,
    Map<String, String> originals,
  ) {
    final lines = patch.replaceAll('\r\n', '\n').split('\n');
    final changes = <UnifiedPatchChange>[];
    final seenPaths = <String>{};
    var cursor = 0;

    while (cursor < lines.length) {
      if (!lines[cursor].startsWith('--- ')) {
        cursor++;
        continue;
      }
      if (cursor + 1 >= lines.length || !lines[cursor + 1].startsWith('+++ ')) {
        cursor++;
        continue;
      }

      final oldPathRaw = lines[cursor].substring(4);
      final newPathRaw = lines[cursor + 1].substring(4);
      final oldPath = _normalisePath(oldPathRaw);
      final newPath = _normalisePath(newPathRaw);
      if (newPath == null || newPath == '/dev/null') {
        throw const UnifiedPatchException('File deletion is not supported.');
      }
      if (oldPath != null && oldPath != '/dev/null' && oldPath != newPath) {
        throw const UnifiedPatchException('File renames are not supported.');
      }
      if (!seenPaths.add(newPath)) {
        throw UnifiedPatchException(
          'Patch contains duplicate file path $newPath.',
        );
      }

      final isNewFile = oldPath == '/dev/null';
      final original = isNewFile ? '' : originals[newPath];
      if (original == null) {
        throw UnifiedPatchException(
          'No current content was loaded for $newPath.',
        );
      }

      final fileHunks = <PatchHunk>[];
      cursor += 2;

      while (cursor < lines.length) {
        final line = lines[cursor];
        if (line.startsWith('--- ') || line.startsWith('diff --git ')) break;
        if (!line.startsWith('@@ ')) {
          cursor++;
          continue;
        }

        final hunkMatch = RegExp(
          r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
        ).firstMatch(line);
        if (hunkMatch == null) {
          throw const UnifiedPatchException(
            'Malformed unified diff hunk header.',
          );
        }
        final oldStart = int.parse(hunkMatch.group(1)!);
        final oldCount = int.tryParse(hunkMatch.group(2) ?? '1') ?? 1;
        final newStart = int.parse(hunkMatch.group(3)!);
        final newCount = int.tryParse(hunkMatch.group(4) ?? '1') ?? 1;
        final hunkHeader = line;
        final hunkLines = <String>[];
        cursor++;

        while (cursor < lines.length) {
          final changeLine = lines[cursor];
          if (changeLine.startsWith('@@ ') ||
              changeLine.startsWith('--- ') ||
              changeLine.startsWith('diff --git ')) {
            break;
          }
          if (changeLine == r'\ No newline at end of file') {
            cursor++;
            continue;
          }
          if (changeLine.isEmpty) break;
          final prefix = changeLine[0];
          if (prefix == ' ' || prefix == '-' || prefix == '+') {
            hunkLines.add(changeLine);
          } else {
            break;
          }
          cursor++;
        }

        fileHunks.add(
          PatchHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            header: hunkHeader,
            lines: hunkLines,
            isSelected: true,
          ),
        );
      }

      if (fileHunks.isEmpty) {
        throw UnifiedPatchException(
          'No applicable hunks were found for $newPath.',
        );
      }

      // Reconstruct file with all hunks selected by default
      final updated = reconstructFile(
        original: original,
        hunks: fileHunks,
        isNewFile: isNewFile,
      );

      changes.add(
        UnifiedPatchChange(
          path: newPath,
          before: original,
          after: updated,
          hunks: fileHunks,
        ),
      );
    }

    if (changes.isEmpty) {
      throw const UnifiedPatchException('No supported unified diff was found.');
    }
    return changes;
  }

  /// Reconstructs the full file content from [original] using the given [hunks].
  ///
  /// For hunks with `isSelected == true`, changes are applied.
  /// For hunks with `isSelected == false`, original before-content remains unchanged.
  /// Strict context checking is performed for both selected and unselected hunks.
  static String reconstructFile({
    required String original,
    required List<PatchHunk> hunks,
    required bool isNewFile,
  }) {
    final sourceLines = _splitLines(original);
    final output = <String>[];
    var sourceCursor = 0;

    for (final hunk in hunks) {
      final target = hunk.oldStart == 0 ? 0 : hunk.oldStart - 1;
      if (target < sourceCursor || target > sourceLines.length) {
        throw const UnifiedPatchException(
          'Patch line positions do not match the current file.',
        );
      }

      // Copy untouched lines prior to this hunk
      output.addAll(sourceLines.sublist(sourceCursor, target));
      sourceCursor = target;
      var consumedOld = 0;
      var consumedNew = 0;

      for (final changeLine in hunk.lines) {
        if (changeLine == r'\ No newline at end of file') continue;
        if (changeLine.isEmpty) continue;
        final prefix = changeLine[0];
        final text = changeLine.substring(1);

        if (prefix == ' ' || prefix == '-') {
          if (sourceCursor >= sourceLines.length ||
              sourceLines[sourceCursor] != text) {
            throw const UnifiedPatchException(
              'Patch context does not match the file. No files were changed.',
            );
          }
          if (prefix == ' ') {
            output.add(text);
            consumedNew++;
          } else if (!hunk.isSelected) {
            // Unselected hunk: keep the line that would have been removed
            output.add(sourceLines[sourceCursor]);
          }
          sourceCursor++;
          consumedOld++;
        } else if (prefix == '+') {
          if (hunk.isSelected) {
            output.add(text);
          }
          consumedNew++;
        }
      }

      if (consumedOld != hunk.oldCount || consumedNew != hunk.newCount) {
        throw const UnifiedPatchException('Patch hunk length is inconsistent.');
      }
    }

    // Copy remaining untouched lines after the last hunk
    output.addAll(sourceLines.sublist(sourceCursor));
    final hadFinalNewline = original.endsWith('\n');
    return output.join('\n') + (hadFinalNewline || isNewFile ? '\n' : '');
  }

  static List<String> _splitLines(String text) {
    if (text.isEmpty) return <String>[];
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    if (text.endsWith('\n')) lines.removeLast();
    return lines;
  }

  static String? _normalisePath(String raw) {
    var path = raw.trim();
    if (path == '/dev/null') return path;
    if (path.startsWith('a/') || path.startsWith('b/')) {
      path = path.substring(2);
    }
    path = path.replaceAll('\\', '/');
    if (path.isEmpty ||
        path.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      throw const UnifiedPatchException(
        'Patch paths must be relative to the project.',
      );
    }
    final segments = path.split('/');
    if (segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const UnifiedPatchException('Patch contains an unsafe file path.');
    }
    return segments.join('/');
  }
}

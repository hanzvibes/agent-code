import 'dart:typed_data';

import 'unified_patch.dart';

/// Builds a unified diff from [before] to [after] contents, in the
/// format [UnifiedPatchParser] reads (`--- a/...` / `+++ b/...` /
/// `@@` hunks with 3 lines of context).
///
/// Returns `''` when the line contents are identical (for example the
/// change only touched a trailing newline, which the parser cannot
/// represent). Callers should treat an empty result with
/// `before != after` as "changed, but not displayable as a diff".
///
/// The diff is computed with an exact line LCS when the file pair is
/// small enough; for large files it falls back to a single hunk built
/// from the common prefix/suffix, which is still exact (every old line
/// removed, every new line added) and still parses.
String buildUnifiedDiff({
  required String path,
  required String before,
  required String after,
  bool isNewFile = false,
}) {
  final beforeLines = _splitLines(before);
  final afterLines = _splitLines(after);
  if (_linesEqual(beforeLines, afterLines)) return '';

  final ops = _diffOps(beforeLines, afterLines);
  final hunks = _groupHunks(ops, beforeLines, afterLines);
  if (hunks.isEmpty) return '';

  final buffer = StringBuffer();
  buffer.writeln(isNewFile ? '--- /dev/null' : '--- a/$path');
  buffer.writeln('+++ b/$path');
  for (final hunk in hunks) {
    buffer.writeln(
      '@@ -${hunk.oldStart},${hunk.oldCount} '
      '+${hunk.newStart},${hunk.newCount} @@',
    );
    for (final line in hunk.lines) {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}

enum _OpKind { equal, remove, add }

class _Op {
  final _OpKind kind;

  /// Index into the before lines (`-1` for adds).
  final int oldIndex;

  /// Index into the after lines (`-1` for removes).
  final int newIndex;

  const _Op(this.kind, this.oldIndex, this.newIndex);
}

class _Hunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<String> lines;

  const _Hunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.lines,
  });
}

/// Maximum DP table size for the exact LCS; above it the prefix/suffix
/// fallback is used so a 512 KB file cannot blow up memory or time.
const int _maxLcsCells = 2000000;

/// 3 lines of context on each side of a change, as in unified diffs.
const int _contextLines = 3;

List<_Op> _diffOps(List<String> before, List<String> after) {
  final n = before.length;
  final m = after.length;
  if ((n + 1) * (m + 1) <= _maxLcsCells) return _lcsOps(before, after);

  // Fallback: common prefix + common suffix, one changed block between.
  var prefix = 0;
  while (prefix < n && prefix < m && before[prefix] == after[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < n - prefix &&
      suffix < m - prefix &&
      before[n - 1 - suffix] == after[m - 1 - suffix]) {
    suffix++;
  }
  final ops = <_Op>[];
  for (var i = 0; i < prefix; i++) {
    ops.add(_Op(_OpKind.equal, i, i));
  }
  for (var i = prefix; i < n - suffix; i++) {
    ops.add(_Op(_OpKind.remove, i, -1));
  }
  for (var j = prefix; j < m - suffix; j++) {
    ops.add(_Op(_OpKind.add, -1, j));
  }
  for (var k = 0; k < suffix; k++) {
    ops.add(_Op(_OpKind.equal, n - suffix + k, m - suffix + k));
  }
  return ops;
}

List<_Op> _lcsOps(List<String> before, List<String> after) {
  final n = before.length;
  final m = after.length;
  final width = m + 1;
  // Flat DP table: dp[i * width + j] = LCS length of before[:i], after[:j].
  final dp = Int32List((n + 1) * width);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      dp[i * width + j] = before[i - 1] == after[j - 1]
          ? dp[(i - 1) * width + (j - 1)] + 1
          : (dp[(i - 1) * width + j] > dp[i * width + (j - 1)]
                ? dp[(i - 1) * width + j]
                : dp[i * width + (j - 1)]);
    }
  }
  // Backtrack from (n, m).
  final reversed = <_Op>[];
  var i = n;
  var j = m;
  while (i > 0 && j > 0) {
    if (before[i - 1] == after[j - 1]) {
      reversed.add(_Op(_OpKind.equal, i - 1, j - 1));
      i--;
      j--;
    } else if (dp[(i - 1) * width + j] >= dp[i * width + (j - 1)]) {
      reversed.add(_Op(_OpKind.remove, i - 1, -1));
      i--;
    } else {
      reversed.add(_Op(_OpKind.add, -1, j - 1));
      j--;
    }
  }
  while (i > 0) {
    reversed.add(_Op(_OpKind.remove, i - 1, -1));
    i--;
  }
  while (j > 0) {
    reversed.add(_Op(_OpKind.add, -1, j - 1));
    j--;
  }
  return reversed.reversed.toList();
}

List<_Hunk> _groupHunks(
  List<_Op> ops,
  List<String> beforeLines,
  List<String> afterLines,
) {
  // Group changes separated by at most 2 * context equal lines.
  final changeIndices = <int>[];
  for (var i = 0; i < ops.length; i++) {
    if (ops[i].kind != _OpKind.equal) changeIndices.add(i);
  }
  if (changeIndices.isEmpty) return const [];

  final groups = <(int, int)>[]; // (firstChange, lastChange) op indices
  var groupStart = changeIndices.first;
  var groupEnd = changeIndices.first;
  for (final idx in changeIndices.skip(1)) {
    if (idx - groupEnd - 1 <= 2 * _contextLines) {
      groupEnd = idx;
    } else {
      groups.add((groupStart, groupEnd));
      groupStart = idx;
      groupEnd = idx;
    }
  }
  groups.add((groupStart, groupEnd));

  final hunks = <_Hunk>[];
  for (final (firstChange, lastChange) in groups) {
    final start = firstChange - _contextLines < 0
        ? 0
        : firstChange - _contextLines;
    final end = lastChange + _contextLines + 1 > ops.length
        ? ops.length
        : lastChange + _contextLines + 1;
    final lines = <String>[];
    var oldCount = 0;
    var newCount = 0;
    // 1-based start of the first old/new line in this hunk; 0 when the
    // hunk has no lines on that side (insert at the start of the file).
    var oldStart = 0;
    var newStart = 0;
    var oldSeen = 0; // old lines consumed before the current op
    var newSeen = 0; // new lines consumed before the current op
    for (var i = 0; i < end; i++) {
      final op = ops[i];
      if (i < start) {
        if (op.kind != _OpKind.add) oldSeen++;
        if (op.kind != _OpKind.remove) newSeen++;
        continue;
      }
      if (oldCount == 0 && newCount == 0) {
        oldStart = op.kind == _OpKind.add ? oldSeen : oldSeen + 1;
        newStart = op.kind == _OpKind.remove ? newSeen : newSeen + 1;
      }
      switch (op.kind) {
        case _OpKind.equal:
          lines.add(' ${beforeLines[op.oldIndex]}');
          oldCount++;
          newCount++;
          oldSeen++;
          newSeen++;
        case _OpKind.remove:
          lines.add('-${beforeLines[op.oldIndex]}');
          oldCount++;
          oldSeen++;
        case _OpKind.add:
          lines.add('+${afterLines[op.newIndex]}');
          newCount++;
          newSeen++;
      }
    }
    // A hunk with no old lines only parses when it starts at the top
    // of the file (oldStart 0); with 3 context lines that is the only
    // way a zero-count hunk arises, and likewise for the new side.
    hunks.add(
      _Hunk(
        oldStart: oldCount == 0 ? 0 : oldStart,
        oldCount: oldCount,
        newStart: newCount == 0 ? 0 : newStart,
        newCount: newCount,
        lines: lines,
      ),
    );
  }
  return hunks;
}

List<String> _splitLines(String text) {
  if (text.isEmpty) return <String>[];
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  if (text.endsWith('\n')) lines.removeLast();
  return lines;
}

bool _linesEqual(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

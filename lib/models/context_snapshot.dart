import 'package:path/path.dart' as p;

/// One file included in an assistant context request.
class ContextFile {
  /// Path relative to the workspace root (e.g. `lib/main.dart`).
  final String relativePath;

  /// Canonical absolute path at snapshot time.
  final String absolutePath;

  /// Full source content at request time (up to 512 KB). For the open file this
  /// may be an unsaved editor buffer; review/apply requires the saved file to
  /// match this exact baseline before writing a patch.
  final String baseline;

  /// True when the content sent to the model was truncated to fit the budget.
  final bool truncated;

  const ContextFile({
    required this.relativePath,
    required this.absolutePath,
    required this.baseline,
    required this.truncated,
  });
}

/// Immutable snapshot of exactly what was sent in the latest successful
/// assistant request. Used by the review/apply flow to validate that
/// workspace files have not changed since the request was made.
class ContextSnapshot {
  /// Canonical absolute path of the workspace root.
  final String workspaceRoot;

  /// Canonical absolute path of the open file at request time.
  final String openFilePath;

  /// Context files in send order: open file first, then extras.
  /// Never empty.
  final List<ContextFile> files;

  /// Wall-clock time the snapshot was taken (just before the request).
  final DateTime takenAt;

  const ContextSnapshot({
    required this.workspaceRoot,
    required this.openFilePath,
    required this.files,
    required this.takenAt,
  });

  /// Returns the [ContextFile] whose [absolutePath] matches [absolute],
  /// or null if the path was not in this context.
  ContextFile? forAbsolutePath(String absolute) {
    for (final f in files) {
      if (p.equals(f.absolutePath, absolute)) return f;
    }
    return null;
  }
}

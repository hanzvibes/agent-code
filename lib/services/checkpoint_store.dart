import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/checkpoint.dart';
import 'workspace_service.dart';

/// Result of an undo attempt (Batch 2 — desain §6).
class UndoResult {
  final bool ok;

  /// Human-readable reason when [ok] is false. For a partial failure
  /// this also says which files were already restored.
  final String? error;

  /// How many checkpoints were actually undone by this call.
  final int undoneCount;

  /// Workspace-relative paths that were restored.
  final List<String> undonePaths;

  const UndoResult({
    required this.ok,
    this.error,
    this.undoneCount = 0,
    this.undonePaths = const [],
  });
}

/// In-memory store of agent file-change checkpoints (Batch 2 — desain
/// §5, D2).
///
/// Every write tool records a [Checkpoint] (content before + after)
/// before mutating a file, and deletes move the file to the trash
/// folder instead of removing it. Undo restores the before-content —
/// but only when the file still matches the checkpoint's after-state:
/// if the user (or another tool) changed the file afterwards, undo
/// refuses instead of silently overwriting their work (desain §6).
///
/// The store is in-memory for Batch 2; persisting it to Hive (so a
/// session can resume after the app is closed) is Batch 5's TaskStore
/// work. Checkpoints are dropped when the workspace changes.
class CheckpointStore {
  /// Trash folder inside the workspace (desain D2).
  static const String trashDirName = '.codeharness-trash';

  final List<Checkpoint> _checkpoints = [];

  List<Checkpoint> get all => List.unmodifiable(_checkpoints);

  void record(Checkpoint checkpoint) {
    _checkpoints.add(checkpoint);
  }

  /// Removes a checkpoint without undoing it (used when the write that
  /// recorded it failed, so no stale checkpoint survives).
  void remove(String checkpointId) {
    _checkpoints.removeWhere((cp) => cp.id == checkpointId);
  }

  List<Checkpoint> checkpointsForTask(String taskId) =>
      _checkpoints.where((cp) => cp.taskId == taskId).toList();

  List<Checkpoint> checkpointsForStep(String taskId, String stepId) =>
      _checkpoints
          .where((cp) => cp.taskId == taskId && cp.stepId == stepId)
          .toList();

  Checkpoint? byId(String checkpointId) {
    for (final cp in _checkpoints) {
      if (cp.id == checkpointId) return cp;
    }
    return null;
  }

  /// Workspace-relative trash path for a file deleted by [taskId].
  /// The file's relative path is preserved below the task folder.
  static String trashPathFor(String taskId, String relativePath) =>
      p.join(trashDirName, taskId, relativePath);

  /// Permanently deletes the trashed files of [taskId]. Called when
  /// the task finishes (desain D2) — after this, a delete checkpoint of
  /// that task can no longer be undone.
  Future<void> purgeTrashForTask(String taskId, String workspaceRoot) async {
    final trashDir = Directory(p.join(workspaceRoot, trashDirName, taskId));
    if (await trashDir.exists()) {
      await trashDir.delete(recursive: true);
    }
  }

  /// Undoes one checkpoint. Already-undone checkpoints succeed as a
  /// no-op (undo is idempotent).
  Future<UndoResult> undoCheckpoint(
    String checkpointId,
    String workspaceRoot,
  ) async {
    final checkpoint = byId(checkpointId);
    if (checkpoint == null) {
      return const UndoResult(ok: false, error: 'Change not found.');
    }
    return undoCheckpoints([checkpoint], workspaceRoot);
  }

  /// Undoes every checkpoint of one step, newest first.
  Future<UndoResult> undoStep(
    String taskId,
    String stepId,
    String workspaceRoot,
  ) async {
    return undoCheckpoints(
      checkpointsForStep(taskId, stepId),
      workspaceRoot,
    );
  }

  /// Undoes every checkpoint of a task, newest first.
  Future<UndoResult> undoTask(String taskId, String workspaceRoot) async {
    return undoCheckpoints(checkpointsForTask(taskId), workspaceRoot);
  }

  /// Undoes [checkpoints] newest first. All checkpoints are validated
  /// before anything is changed, so a refusal leaves every file
  /// untouched.
  Future<UndoResult> undoCheckpoints(
    List<Checkpoint> checkpoints,
    String workspaceRoot,
  ) async {
    final targets = checkpoints
        .where((cp) => !cp.undone)
        .toList()
        .reversed
        .toList();
    if (targets.isEmpty) {
      return const UndoResult(ok: true, undoneCount: 0);
    }

    // Phase 1 — validate everything first (desain §6 hash check).
    final problems = <String>[];
    for (final cp in targets) {
      final problem = await _validateUndo(cp, workspaceRoot);
      if (problem != null) problems.add(problem);
    }
    if (problems.isNotEmpty) {
      return UndoResult(
        ok: false,
        error:
            'Undo refused — the file changed after the agent wrote it:\n${problems.join('\n')}',
      );
    }

    // Phase 2 — apply, newest first.
    final undonePaths = <String>[];
    var applied = 0;
    for (final cp in targets) {
      try {
        await _applyUndo(cp, workspaceRoot);
        cp.undone = true;
        applied++;
        undonePaths.add(cp.path);
      } catch (error) {
        return UndoResult(
          ok: false,
          error:
              'Undo stopped after restoring $applied file(s): $error. '
              'The remaining changes were left as-is.',
          undoneCount: applied,
          undonePaths: undonePaths,
        );
      }
    }
    return UndoResult(
      ok: true,
      undoneCount: applied,
      undonePaths: undonePaths,
    );
  }

  /// Returns a refusal message, or null when this checkpoint can be
  /// undone (or is already in its before-state).
  Future<String?> _validateUndo(
    Checkpoint cp,
    String workspaceRoot,
  ) async {
    final absolutePath = await _safeAbsolutePath(workspaceRoot, cp.path);
    if (absolutePath == null) return '${cp.path}: unsafe path.';
    final file = File(absolutePath);

    if (cp.isDelete) {
      if (await file.exists()) {
        // The file is back at its old location: only accept it when it
        // is exactly what the delete removed.
        final current = await _readTextIfPossible(file);
        if (cp.before != null && current == cp.before) return null;
        return '${cp.path}: a different file now exists there — '
            'restore it manually or delete it first.';
      }
      if (cp.trashPath == null) {
        return '${cp.path}: no trash copy was recorded.';
      }
      final trashFile = File(p.join(workspaceRoot, cp.trashPath!));
      if (!await trashFile.exists()) {
        return '${cp.path}: the trash copy is gone (it was permanently '
            'deleted when the task finished).';
      }
      if (cp.before != null) {
        final trashContent = await _readTextIfPossible(trashFile);
        if (trashContent != cp.before) {
          return '${cp.path}: the trash copy changed — refusing to '
              'restore an unexpected version.';
        }
      }
      return null;
    }

    // Write checkpoint.
    if (!await file.exists()) {
      if (cp.before == null) return null; // created file already gone
      return '${cp.path}: the file was deleted after the change.';
    }
    final current = await _readTextIfPossible(file);
    if (current == null) {
      return '${cp.path}: the file is no longer readable as text.';
    }
    if (current == cp.after || current == cp.before) return null;
    return '${cp.path}: changed by hand after the agent wrote it '
        '(current content does not match the recorded version).';
  }

  Future<void> _applyUndo(Checkpoint cp, String workspaceRoot) async {
    final absolutePath = await _safeAbsolutePath(workspaceRoot, cp.path);
    if (absolutePath == null) {
      throw FileSystemException('Unsafe path', cp.path);
    }
    final file = File(absolutePath);

    if (cp.isDelete) {
      if (await file.exists()) return; // already restored (validated)
      final trashFile = File(p.join(workspaceRoot, cp.trashPath!));
      await Directory(p.dirname(absolutePath)).create(recursive: true);
      await trashFile.rename(absolutePath);
      return;
    }

    if (cp.before == null) {
      // The file was created by the agent: undo removes it.
      if (await file.exists()) await file.delete();
      return;
    }
    await WorkspaceService.writeFile(absolutePath, cp.before!);
  }

  /// Reads a file as text, or null when it is binary / unreadable.
  /// Never throws: callers turn null into a refusal message.
  Future<String?> _readTextIfPossible(File file) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      if (stat.size > WorkspaceService.maxEditableBytes) return null;
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) return null;
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  /// Resolves a checkpoint path inside the workspace. Returns null
  /// when the path is no longer safe (should not happen for paths the
  /// write tools validated, but undo must not trust stored data).
  Future<String?> _safeAbsolutePath(
    String workspaceRoot,
    String relativePath,
  ) async {
    try {
      return await WorkspaceService.resolveSafePath(
        workspaceRoot,
        relativePath,
      );
    } catch (_) {
      return null;
    }
  }

  /// Drops all checkpoints of one task (workspace changed / task
  /// discarded). Trash files are left alone — they are only removed
  /// by [purgeTrashForTask].
  void clearTask(String taskId) {
    _checkpoints.removeWhere((cp) => cp.taskId == taskId);
  }

  void clear() {
    _checkpoints.clear();
  }
}

import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../controllers/review_controller.dart';
import '../core/ui.dart';
import '../models/file_node.dart';
import '../services/new_file_service.dart';
import '../services/workspace_service.dart';
import '../utils/editor_history.dart';
import '../utils/find_replace.dart';
import 'app_controller.dart';

class AppliedPatchRecord {
  final String workspaceRoot;
  final List<PatchFile> files;
  final DateTime appliedAt;

  const AppliedPatchRecord({
    required this.workspaceRoot,
    required this.files,
    required this.appliedAt,
  });
}

class ProjectController extends GetxController {
  final AppController _appController;

  ProjectController(this._appController);

  final RxString workspacePath = ''.obs;
  final RxList<FileNode> fileTree = <FileNode>[].obs;
  final Rx<FileNode?> openFile = Rx(null);
  final RxString editorContent = ''.obs;
  final RxString savedContent = ''.obs;
  final RxBool isLoadingTree = false.obs;
  final RxBool isLoadingFile = false.obs;
  final RxString errorMessage = ''.obs;

  // Editor history (undo / redo)
  final EditorHistory _editorHistory = EditorHistory();
  final RxBool canUndo = false.obs;
  final RxBool canRedo = false.obs;

  // Find and replace in editor
  final RxBool isFindBarVisible = false.obs;
  final RxString findQuery = ''.obs;
  final RxString replaceQuery = ''.obs;
  final RxInt findMatchStart = (-1).obs;
  final RxInt findMatchEnd = (-1).obs;
  final RxInt findTotalMatches = 0.obs;
  final RxInt currentMatchIndex = 0.obs;
  final RxInt targetEditorLine = 0.obs;

  // Rollback state for most recently applied patch
  final Rx<AppliedPatchRecord?> lastAppliedPatch = Rx<AppliedPatchRecord?>(
    null,
  );

  bool get hasUnsavedChanges => editorContent.value != savedContent.value;
  bool get hasWorkspace => workspacePath.value.isNotEmpty;
  bool get canRollbackPatch =>
      lastAppliedPatch.value != null &&
      lastAppliedPatch.value!.files.isNotEmpty &&
      p.equals(lastAppliedPatch.value!.workspaceRoot, workspacePath.value);

  @override
  void onInit() {
    super.onInit();
    final last = _appController.lastWorkspacePath;
    if (last != null && Directory(last).existsSync()) openWorkspace(last);
  }

  Future<void> openWorkspace(String path) async {
    final canonical = await Directory(path).resolveSymbolicLinks();
    if (workspacePath.value == canonical) {
      await refreshTree();
      return;
    }
    if (!await _confirmUnsavedChanges()) return;

    // Workspace change clears patch rollback state and resets editor
    lastAppliedPatch.value = null;
    workspacePath.value = canonical;
    openFile.value = null;
    editorContent.value = '';
    savedContent.value = '';
    _editorHistory.init('');
    _syncUndoRedo();
    clearFind();
    isFindBarVisible.value = false;

    await _appController.setLastWorkspace(canonical);
    await refreshTree();
  }

  Future<void> refreshTree() async {
    if (workspacePath.value.isEmpty) return;
    isLoadingTree.value = true;
    errorMessage.value = '';
    try {
      fileTree.value = WorkspaceService().buildTree(workspacePath.value);
    } catch (error) {
      errorMessage.value = 'Could not read this folder: $error';
    } finally {
      isLoadingTree.value = false;
    }
  }

  Future<void> openFileNode(FileNode node, {int? lineNumber}) async {
    if (node.isDirectory) {
      node.isExpanded = !node.isExpanded;
      fileTree.refresh();
      return;
    }
    if (openFile.value?.path == node.path) {
      if (lineNumber != null) targetEditorLine.value = lineNumber;
      return;
    }
    if (!await _confirmUnsavedChanges()) return;

    isLoadingFile.value = true;
    try {
      final content = await WorkspaceService.readFile(node.path);
      openFile.value = node;
      editorContent.value = content;
      savedContent.value = content;
      _editorHistory.init(content);
      _syncUndoRedo();
      clearFind();
      if (lineNumber != null) targetEditorLine.value = lineNumber;
      errorMessage.value = '';
    } catch (error) {
      errorMessage.value = 'Could not open this file: $error';
      if (Get.overlayContext != null) {
        Get.snackbar('Could not open file', errorMessage.value);
      }
    } finally {
      isLoadingFile.value = false;
    }
  }

  Future<void> openFileByPath(String absolutePath, {int? lineNumber}) async {
    String canonical;
    try {
      canonical = await File(absolutePath).resolveSymbolicLinks();
    } catch (_) {
      canonical = absolutePath;
    }

    FileNode? targetNode;
    FileNode? findIn(List<FileNode> nodes) {
      for (final n in nodes) {
        if (p.equals(n.path, canonical)) return n;
        final child = findIn(n.children);
        if (child != null) return child;
      }
      return null;
    }

    targetNode = findIn(fileTree);
    targetNode ??= FileNode(
      name: p.basename(canonical),
      path: canonical,
      isDirectory: false,
      depth: 0,
    );

    await openFileNode(targetNode, lineNumber: lineNumber);
  }

  Future<void> createNewFile(String relativePath) async {
    if (workspacePath.value.isEmpty) {
      throw const FileSystemException('No project folder is open.');
    }
    final createdPath = await NewFileService.createFile(
      workspacePath.value,
      relativePath,
    );
    await refreshTree();
    await openFileByPath(createdPath);
  }

  Future<void> saveCurrentFile() async {
    final file = openFile.value;
    if (file == null || !hasUnsavedChanges) return;
    try {
      await WorkspaceService.writeFile(file.path, editorContent.value);
      savedContent.value = editorContent.value;
      errorMessage.value = '';
      await refreshTree();
      if (Get.overlayContext != null) {
        Get.snackbar('Saved', file.name, snackPosition: SnackPosition.BOTTOM);
      }
    } catch (error) {
      errorMessage.value = 'Could not save this file: $error';
      if (Get.overlayContext != null) {
        Get.snackbar('Save error', errorMessage.value);
      }
    }
  }

  void updateEditorContent(String content) {
    if (editorContent.value != content) {
      editorContent.value = content;
      _editorHistory.push(content);
      _syncUndoRedo();
    }
  }

  void undo() {
    final prev = _editorHistory.undo();
    if (prev != null) {
      editorContent.value = prev;
      _syncUndoRedo();
      if (findQuery.value.isNotEmpty) {
        updateFindQuery(findQuery.value);
      }
    }
  }

  void redo() {
    final next = _editorHistory.redo();
    if (next != null) {
      editorContent.value = next;
      _syncUndoRedo();
      if (findQuery.value.isNotEmpty) {
        updateFindQuery(findQuery.value);
      }
    }
  }

  void _syncUndoRedo() {
    canUndo.value = _editorHistory.canUndo;
    canRedo.value = _editorHistory.canRedo;
  }

  // ── Find / Replace actions ──

  void toggleFindBar() {
    isFindBarVisible.value = !isFindBarVisible.value;
    if (!isFindBarVisible.value) {
      clearFind();
    }
  }

  void updateFindQuery(String query, {int fromOffset = 0}) {
    findQuery.value = query;
    if (query.isEmpty) {
      clearFind();
      return;
    }
    final result = FindReplace.findNext(editorContent.value, query, fromOffset);
    if (result != null) {
      findMatchStart.value = result.matchStart;
      findMatchEnd.value = result.matchEnd;
      findTotalMatches.value = result.totalMatches;
      _updateCurrentMatchIndex(result.matchStart);
    } else {
      clearFind();
    }
  }

  void findNextMatch() {
    if (findQuery.value.isEmpty) return;
    final nextOffset = findMatchEnd.value >= 0 ? findMatchEnd.value : 0;
    final result = FindReplace.findNext(
      editorContent.value,
      findQuery.value,
      nextOffset,
    );
    if (result != null) {
      findMatchStart.value = result.matchStart;
      findMatchEnd.value = result.matchEnd;
      findTotalMatches.value = result.totalMatches;
      _updateCurrentMatchIndex(result.matchStart);
    }
  }

  void replaceCurrentMatch() {
    if (findQuery.value.isEmpty || findMatchStart.value < 0) return;
    final res = FindReplace.replaceCurrent(
      editorContent.value,
      findQuery.value,
      replaceQuery.value,
      findMatchStart.value,
      findMatchEnd.value,
    );
    if (res != null) {
      updateEditorContent(res.text);
      updateFindQuery(findQuery.value, fromOffset: res.matchEnd);
    }
  }

  void replaceAllMatches() {
    if (findQuery.value.isEmpty) return;
    final res = FindReplace.replaceAll(
      editorContent.value,
      findQuery.value,
      replaceQuery.value,
    );
    updateEditorContent(res.text);
    clearFind();
  }

  void clearFind() {
    findMatchStart.value = -1;
    findMatchEnd.value = -1;
    findTotalMatches.value = 0;
    currentMatchIndex.value = 0;
  }

  void _updateCurrentMatchIndex(int matchStart) {
    if (findQuery.value.isEmpty) {
      currentMatchIndex.value = 0;
      return;
    }
    final pattern = RegExp(
      RegExp.escape(findQuery.value),
      caseSensitive: false,
    );
    final all = pattern.allMatches(editorContent.value).toList();
    final idx = all.indexWhere((m) => m.start == matchStart);
    currentMatchIndex.value = idx >= 0 ? idx + 1 : 1;
  }

  /// Re-reads the open file from disk (used after an agent write tool
  /// changed it). Skipped when the user has unsaved edits, so their
  /// in-progress typing is never overwritten.
  Future<void> refreshOpenFile() async {
    final file = openFile.value;
    if (file == null || hasUnsavedChanges) return;
    try {
      final content = await WorkspaceService.readFile(file.path);
      editorContent.value = content;
      savedContent.value = content;
      _editorHistory.init(content);
      _syncUndoRedo();
      errorMessage.value = '';
    } catch (error) {
      errorMessage.value = 'Could not reload this file: $error';
    }
  }

  Future<void> closeFile() async {
    if (!await _confirmUnsavedChanges()) return;
    openFile.value = null;
    editorContent.value = '';
    savedContent.value = '';
    _editorHistory.init('');
    _syncUndoRedo();
    clearFind();
    isFindBarVisible.value = false;
  }

  String get treeText => WorkspaceService.treeText(fileTree);

  String get currentFileContext {
    final content = editorContent.value;
    if (content.length > 24000) return content.substring(0, 24000);
    return content;
  }

  String? get currentFileName => openFile.value?.name;

  Future<void> applyPatch(List<PatchFile> changes) async {
    final root = workspacePath.value;
    if (root.isEmpty) {
      throw const FileSystemException('No project folder is open.');
    }

    // Only apply files with actual changes (where after != before).
    // Files where all hunks were unselected stay unchanged.
    final effectiveChanges = changes.where((c) => c.before != c.after).toList();
    if (effectiveChanges.isEmpty) return;

    final validated = <({PatchFile change, String absolutePath})>[];
    for (final change in effectiveChanges) {
      final absolutePath = await WorkspaceService.resolveSafePath(
        root,
        change.path,
      );
      final exists = await File(absolutePath).exists();
      if (exists != change.existedAtPreview) {
        throw FileSystemException(
          '${change.path} changed after the preview. Create a fresh proposal.',
        );
      }
      if (exists) {
        final current = await WorkspaceService.readFile(absolutePath);
        if (current != change.before) {
          throw FileSystemException(
            '${change.path} changed after the preview. No patch was applied.',
          );
        }
      } else if (change.before.isNotEmpty) {
        throw FileSystemException(
          '${change.path} was missing when the patch was reviewed.',
        );
      }
      validated.add((change: change, absolutePath: absolutePath));
    }

    // Re-check all targets immediately before writing
    for (final item in validated) {
      final currentExists = await File(item.absolutePath).exists();
      if (currentExists != item.change.existedAtPreview) {
        throw FileSystemException(
          '${item.change.path} changed after the preview. No patch was applied.',
        );
      }
      if (currentExists &&
          await WorkspaceService.readFile(item.absolutePath) !=
              item.change.before) {
        throw FileSystemException(
          '${item.change.path} changed after the preview. No patch was applied.',
        );
      }
    }

    final applyProgress = <({String path, String before, bool existed})>[];
    try {
      for (final item in validated) {
        final change = item.change;
        final path = item.absolutePath;
        applyProgress.add((
          path: path,
          before: change.before,
          existed: change.existedAtPreview,
        ));
        if (change.existedAtPreview) {
          await WorkspaceService.writeFile(path, change.after);
        } else {
          await Directory(p.dirname(path)).create(recursive: true);
          await File(path).create(exclusive: true);
          await File(path).writeAsString(change.after);
        }
      }
    } catch (error) {
      for (final attempted in applyProgress.reversed) {
        try {
          if (attempted.existed) {
            await WorkspaceService.writeFile(attempted.path, attempted.before);
          } else if (await File(attempted.path).exists()) {
            await File(attempted.path).delete();
          }
        } catch (_) {}
      }
      throw FileSystemException(
        'Patch apply failed; attempted to restore the original files: $error',
      );
    }

    // Store rollback record
    lastAppliedPatch.value = AppliedPatchRecord(
      workspaceRoot: root,
      files: List.from(effectiveChanges),
      appliedAt: DateTime.now(),
    );

    final selectedPath = openFile.value?.path;
    for (final item in validated) {
      if (selectedPath != null && p.equals(selectedPath, item.absolutePath)) {
        editorContent.value = item.change.after;
        savedContent.value = item.change.after;
        _editorHistory.init(item.change.after);
        _syncUndoRedo();
      }
    }
    await refreshTree();
  }

  Future<void> rollbackLastPatch() async {
    final record = lastAppliedPatch.value;
    if (record == null || !canRollbackPatch) {
      throw const FileSystemException('No patch available to undo.');
    }

    final root = workspacePath.value;
    final changes = record.files;

    // 1. Safely re-resolve every target and verify against the patch after-state
    final validated = <({PatchFile change, String absolutePath})>[];
    for (final change in changes) {
      final absolutePath = await WorkspaceService.resolveSafePath(
        root,
        change.path,
      );
      final exists = await File(absolutePath).exists();
      if (!exists) {
        throw FileSystemException(
          '${change.path} is missing. Cannot rollback patch.',
        );
      }
      final currentContent = await WorkspaceService.readFile(absolutePath);
      if (currentContent != change.after) {
        throw FileSystemException(
          '${change.path} has changed since the patch was applied. Rollback rejected.',
        );
      }
      validated.add((change: change, absolutePath: absolutePath));
    }

    // 2. Validate all before mutation, and track mutations for rollback on error
    final completedMutations =
        <({String path, String? originalContent, bool wasCreated})>[];
    try {
      for (final item in validated) {
        final change = item.change;
        final path = item.absolutePath;
        completedMutations.add((
          path: path,
          originalContent: change.after,
          wasCreated: !change.existedAtPreview,
        ));
        if (!change.existedAtPreview) {
          // File was newly created by this patch -> delete it
          await File(path).delete();
        } else {
          // Revert existing file to before content
          await WorkspaceService.writeFile(path, change.before);
        }
      }
    } catch (e) {
      // Attempt rollback of the failed mutation
      for (final mut in completedMutations.reversed) {
        try {
          if (mut.originalContent != null) {
            await WorkspaceService.writeFile(mut.path, mut.originalContent!);
          }
        } catch (_) {}
      }
      throw FileSystemException('Failed while rolling back patch: $e');
    }

    // 3. Update editor content if open
    final selectedPath = openFile.value?.path;
    for (final item in validated) {
      if (selectedPath != null && p.equals(selectedPath, item.absolutePath)) {
        if (!item.change.existedAtPreview) {
          openFile.value = null;
          editorContent.value = '';
          savedContent.value = '';
          _editorHistory.init('');
          _syncUndoRedo();
        } else {
          editorContent.value = item.change.before;
          savedContent.value = item.change.before;
          _editorHistory.init(item.change.before);
          _syncUndoRedo();
        }
      }
    }

    // Clear rollback state on undo
    lastAppliedPatch.value = null;
    await refreshTree();
  }

  Future<bool> _confirmUnsavedChanges() async {
    if (!hasUnsavedChanges) return true;
    final ctx = Get.context;
    if (ctx == null) {
      // Fail closed rather than silently discarding edits when no sheet can be shown.
      return false;
    }
    final action = await showUnsavedChangesSheet(ctx);
    if (action == 'discard') return true;
    if (action != 'save') return false;
    await saveCurrentFile();
    return !hasUnsavedChanges;
  }
}

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/project_controller.dart';
import '../../core/ui.dart';
import '../../models/file_node.dart';
import '../../services/search_service.dart';
import 'editor_view.dart';

class ProjectView extends StatelessWidget {
  const ProjectView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final ctrl = Get.find<ProjectController>();

    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'Project',
        actions: [
          Obx(() {
            if (!ctrl.hasWorkspace) return const SizedBox.shrink();
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBarIcon(
                  icon: Icons.search_rounded,
                  tooltip: 'Search project',
                  onPressed: () => _openSearch(context, ctrl),
                ),
                AppBarIcon(
                  icon: Icons.note_add_outlined,
                  tooltip: 'New file',
                  onPressed: () => _openNewFileSheet(context, ctrl),
                ),
                AppBarIcon(
                  icon: Icons.refresh_rounded,
                  tooltip: 'Refresh tree',
                  onPressed: ctrl.refreshTree,
                ),
              ],
            );
          }),
          AppBarIcon(
            icon: Icons.folder_open_rounded,
            tooltip: 'Open folder',
            onPressed: () => _pickFolder(context, ctrl),
          ),
        ],
      ),
      body: Obx(() {
        if (!ctrl.hasWorkspace) {
          return _EmptyState(onOpenFolder: () => _pickFolder(context, ctrl));
        }
        if (ctrl.isLoadingTree.value) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          children: [
            _WorkspaceHeader(ctrl: ctrl),
            Expanded(
              child: ctrl.openFile.value != null
                  ? _SplitView(ctrl: ctrl)
                  : _TreePanel(ctrl: ctrl, t: t),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _pickFolder(BuildContext context, ProjectController ctrl) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open project folder',
    );
    if (result != null) {
      await ctrl.openWorkspace(result);
    }
  }

  void _openSearch(BuildContext context, ProjectController ctrl) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ProjectSearchSheet(ctrl: ctrl),
    );
  }

  void _openNewFileSheet(BuildContext context, ProjectController ctrl) {
    showAppSheet<void>(
      context,
      title: 'New file',
      subtitle: 'Enter a workspace-relative path (e.g. lib/helpers/utils.dart)',
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      builder: (ctx, scrollCtrl) =>
          _NewFileSheet(ctrl: ctrl, scrollController: scrollCtrl),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onOpenFolder;
  const _EmptyState({required this.onOpenFolder});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_rounded, size: 56, color: t.faint),
            const SizedBox(height: 20),
            Text('No project open', style: t.title),
            const SizedBox(height: 8),
            Text(
              'Open a folder to explore its files and get AI assistance.',
              style: t.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            PrimaryButton(label: 'Open folder', onPressed: onOpenFolder),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  final ProjectController ctrl;
  const _WorkspaceHeader({required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Obx(() {
      final name = ctrl.workspacePath.value.split('/').last;
      final canUndoPatch = ctrl.canRollbackPatch;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(bottom: BorderSide(color: t.hairline)),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_rounded, size: 18, color: t.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: t.bodyStrong,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (canUndoPatch) ...[
              GestureDetector(
                onTap: () => _confirmRollback(context, ctrl),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: t.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: t.orange.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.undo_rounded, size: 14, color: t.orange),
                      const SizedBox(width: 4),
                      Text(
                        'Undo patch',
                        style: t.small.copyWith(
                          color: t.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (ctrl.openFile.value != null)
              IconButton(
                tooltip: 'Close file',
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close_rounded, size: 18, color: t.muted),
                onPressed: ctrl.closeFile,
              ),
          ],
        ),
      );
    });
  }

  Future<void> _confirmRollback(
    BuildContext context,
    ProjectController ctrl,
  ) async {
    final ok = await confirmSheet(
      context,
      title: 'Rollback AI patch?',
      message:
          'This will safely restore all files modified by the last applied patch and remove any files created by it.',
      confirmLabel: 'Rollback',
      destructive: true,
    );
    if (ok) {
      try {
        await ctrl.rollbackLastPatch();
        showToast(
          'Patch reverted',
          'Previous code state restored',
          tone: ToastTone.success,
        );
      } catch (e) {
        showToast('Could not rollback', e.toString(), tone: ToastTone.error);
      }
    }
  }
}

class _SplitView extends StatelessWidget {
  final ProjectController ctrl;
  const _SplitView({required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(
      children: [
        SizedBox(
          height: 180,
          child: _TreePanel(ctrl: ctrl, t: t),
        ),
        Divider(height: 1, color: t.hairline),
        const Expanded(child: EditorView()),
      ],
    );
  }
}

class _TreePanel extends StatelessWidget {
  final ProjectController ctrl;
  final AppTokens t;
  const _TreePanel({required this.ctrl, required this.t});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final flatList = _flattenTree(ctrl.fileTree);
      if (flatList.isEmpty) {
        return Center(child: Text('No files found', style: t.caption));
      }
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: flatList.length,
        itemBuilder: (context, index) {
          final node = flatList[index];
          return _FileRow(node: node, ctrl: ctrl, t: t);
        },
      );
    });
  }

  List<FileNode> _flattenTree(List<FileNode> nodes) {
    final result = <FileNode>[];
    for (final node in nodes) {
      result.add(node);
      if (node.isDirectory && node.isExpanded) {
        result.addAll(_flattenTree(node.children));
      }
    }
    return result;
  }
}

class _FileRow extends StatelessWidget {
  final FileNode node;
  final ProjectController ctrl;
  final AppTokens t;

  const _FileRow({required this.node, required this.ctrl, required this.t});

  @override
  Widget build(BuildContext context) {
    final isOpen = ctrl.openFile.value?.path == node.path;
    return InkWell(
      onTap: () => ctrl.openFileNode(node),
      child: Container(
        color: isOpen ? t.accent.withValues(alpha: 0.08) : null,
        padding: EdgeInsets.only(
          left: 16.0 + node.depth * 16.0,
          right: 16,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            Icon(
              node.isDirectory
                  ? (node.isExpanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded)
                  : _fileIcon(node.name),
              size: 18,
              color: node.isDirectory ? t.accent : t.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                node.name,
                style: t.body.copyWith(
                  fontSize: 13.5,
                  color: isOpen ? t.accent : null,
                  fontWeight: isOpen ? FontWeight.w600 : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'dart' => Icons.code_rounded,
      'md' || 'txt' => Icons.description_outlined,
      'yaml' || 'yml' || 'json' || 'toml' => Icons.settings_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

// ── Project Search Modal Sheet ──────────────────────────────────────────

class _ProjectSearchSheet extends StatefulWidget {
  final ProjectController ctrl;
  const _ProjectSearchSheet({required this.ctrl});

  @override
  State<_ProjectSearchSheet> createState() => _ProjectSearchSheetState();
}

class _ProjectSearchSheetState extends State<_ProjectSearchSheet> {
  final _searchCtrl = TextEditingController();
  final _searchService = SearchService();
  List<SearchMatch> _results = [];
  bool _searching = false;

  Future<void> _performSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final matches = await _searchService.search(
        widget.ctrl.workspacePath.value,
        q,
      );
      if (mounted) setState(() => _results = matches);
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: t.sheetHandle,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    style: t.body.copyWith(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search files and paths…',
                      hintStyle: t.caption,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              constraints: const BoxConstraints(
                                minWidth: 44,
                                minHeight: 44,
                              ),
                              onPressed: () {
                                _searchCtrl.clear();
                                _performSearch('');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: t.fill,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) => _performSearch(val),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Close',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          if (_searching)
            const LinearProgressIndicator(minHeight: 2)
          else
            Divider(height: 0.5, color: t.hairline),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _searchCtrl.text.isEmpty
                      ? 'Type to search across workspace'
                      : '${_results.length} results (max 100)',
                  style: t.small,
                ),
                Text('512 KB/file limit', style: t.small),
              ],
            ),
          ),
          Expanded(
            child: _results.isEmpty && !_searching
                ? Center(
                    child: Text(
                      _searchCtrl.text.isEmpty
                          ? 'Search project'
                          : 'No matches found',
                      style: t.caption,
                    ),
                  )
                : ListView.builder(
                    controller: scrollCtrl,
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final match = _results[i];
                      return InkWell(
                        onTap: () async {
                          Navigator.of(context).pop();
                          await widget.ctrl.openFileByPath(
                            match.path,
                            lineNumber: match.lineNumber > 0
                                ? match.lineNumber
                                : null,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: t.hairline),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    match.isPathMatch
                                        ? Icons.folder_open_rounded
                                        : Icons.text_snippet_outlined,
                                    size: 14,
                                    color: match.isPathMatch
                                        ? t.accent
                                        : t.muted,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      match.relativePath,
                                      style: t.bodyStrong.copyWith(
                                        fontSize: 13,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (match.lineNumber > 0)
                                    AppTag(
                                      'L${match.lineNumber}',
                                      color: t.muted,
                                    ),
                                ],
                              ),
                              if (!match.isPathMatch) ...[
                                const SizedBox(height: 4),
                                Text(
                                  match.linePreview,
                                  style: t.mono.copyWith(fontSize: 12),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Create New File Dialog ──────────────────────────────────────────────

class _NewFileSheet extends StatefulWidget {
  final ProjectController ctrl;
  final ScrollController scrollController;
  const _NewFileSheet({required this.ctrl, required this.scrollController});

  @override
  State<_NewFileSheet> createState() => _NewFileSheetState();
}

class _NewFileSheetState extends State<_NewFileSheet> {
  final _pathController = TextEditingController();
  String? _error;
  bool _creating = false;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final relPath = _pathController.text.trim();
    if (relPath.isEmpty) {
      setState(() => _error = 'Path cannot be empty.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      await widget.ctrl.createNewFile(relPath);
      if (mounted) Navigator.of(context).pop();
      showToast('File created', relPath, tone: ToastTone.success);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('FileSystemException: ', '');
          _creating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return SingleChildScrollView(
      controller: widget.scrollController,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _pathController,
            autofocus: true,
            style: t.body.copyWith(fontSize: 14),
            decoration: appInputDecoration(
              context,
              hint: 'path/to/file.dart',
            ).copyWith(errorText: _error),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 8),
          Text(
            'Directories will be created automatically. Symlink escapes and hidden files are rejected.',
            style: t.small,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TonalButton.neutral(
                  context,
                  label: 'Cancel',
                  onTap: () {
                    if (!_creating) Navigator.of(context).pop();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  label: 'Create',
                  busy: _creating,
                  onPressed: _creating ? null : _create,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

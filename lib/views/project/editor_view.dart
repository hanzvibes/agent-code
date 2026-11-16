import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../../controllers/app_controller.dart';
import '../../controllers/assistant_controller.dart';
import '../../controllers/project_controller.dart';
import '../../core/ui.dart';
import '../../utils/syntax_highlighter.dart';

class EditorView extends StatefulWidget {
  const EditorView({super.key});

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  late final SyntaxTextEditingController _textController;
  late final TextEditingController _findController;
  late final TextEditingController _replaceController;
  late final ProjectController _ctrl;
  final RxBool _hasSelection = false.obs;

  @override
  void initState() {
    super.initState();
    _ctrl = Get.find<ProjectController>();
    final initialPath = _ctrl.openFile.value?.path;
    _textController = SyntaxTextEditingController(
      text: _ctrl.editorContent.value,
      language: detectCodeLanguage(initialPath),
    );
    _findController = TextEditingController(text: _ctrl.findQuery.value);
    _replaceController = TextEditingController(text: _ctrl.replaceQuery.value);

    _textController.addListener(_checkSelection);

    _ctrl.openFile.listen((file) {
      if (mounted) {
        _textController.language = detectCodeLanguage(file?.path);
      }
    });

    _ctrl.editorContent.listen((val) {
      if (_textController.text != val) {
        final sel = _textController.selection;
        _textController.text = val;
        if (sel.start <= val.length && sel.end <= val.length) {
          _textController.selection = sel;
        }
      }
    });

    _ctrl.findMatchStart.listen((start) {
      final end = _ctrl.findMatchEnd.value;
      if (start >= 0 && end <= _textController.text.length) {
        _textController.selection = TextSelection(
          baseOffset: start,
          extentOffset: end,
        );
      }
    });

    _ctrl.targetEditorLine.listen((line) {
      if (line > 0) {
        final lines = _textController.text.split('\n');
        var offset = 0;
        final targetIdx = (line - 1).clamp(0, lines.length - 1);
        for (var i = 0; i < targetIdx; i++) {
          offset += lines[i].length + 1;
        }
        if (offset <= _textController.text.length) {
          _textController.selection = TextSelection.collapsed(offset: offset);
        }
        _ctrl.targetEditorLine.value = 0;
      }
    });
  }

  void _checkSelection() {
    final sel = _textController.selection;
    final has =
        sel.isValid &&
        !sel.isCollapsed &&
        sel.textInside(_textController.text).trim().isNotEmpty;
    if (_hasSelection.value != has) {
      _hasSelection.value = has;
    }
  }

  void _openSelectionActionSheet() {
    final assistantCtrl = Get.find<AssistantController>();
    if (assistantCtrl.isLoading.value) {
      showToast(
        'Assistant busy',
        'An assistant request is already active. Please wait or cancel it.',
        tone: ToastTone.warning,
      );
      return;
    }

    final rawSelected = _textController.selection.textInside(
      _textController.text,
    );
    if (rawSelected.trim().isEmpty) return;

    final isTruncated = rawSelected.length > 8000;
    final cappedSelected = isTruncated
        ? rawSelected.substring(0, 8000)
        : rawSelected;
    final file = _ctrl.openFile.value;
    if (file == null) return;

    final wsRoot = _ctrl.workspacePath.value;
    final relPath = wsRoot.isNotEmpty
        ? p.relative(file.path, from: wsRoot)
        : file.name;
    final languageName = _textController.language.name;

    showAppSheet<void>(
      context,
      title: 'AI code actions',
      subtitle: '$relPath ($languageName)',
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (ctx, scrollCtrl) => _SelectionActionSheet(
        scrollController: scrollCtrl,
        relativePath: relPath,
        language: languageName,
        selectedText: cappedSelected,
        isTruncated: isTruncated,
        originalLength: rawSelected.length,
        onSelectAction: (actionKey) async {
          Navigator.of(ctx).pop();
          Get.find<AppController>().selectTab(
            1,
          ); // Show live progress immediately.
          await assistantCtrl.sendSelectionAction(
            actionType: actionKey,
            relativePath: relPath,
            language: languageName,
            selectedText: cappedSelected,
            isTruncated: isTruncated,
            originalLength: rawSelected.length,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _textController.removeListener(_checkSelection);
    _textController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Obx(() {
      final file = _ctrl.openFile.value;
      if (file == null) return const SizedBox.shrink();

      final unsaved = _ctrl.hasUnsavedChanges;

      return Column(
        children: [
          // Editor toolbar header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(bottom: BorderSide(color: t.hairline)),
            ),
            child: Row(
              children: [
                Icon(Icons.code, size: 16, color: t.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    file.name,
                    style: t.caption.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (unsaved) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: t.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('Unsaved', style: t.small.copyWith(color: t.orange)),
                  const SizedBox(width: 6),
                ] else ...[
                  Icon(Icons.check_circle, size: 14, color: t.green),
                  const SizedBox(width: 4),
                  Text('Saved', style: t.small.copyWith(color: t.green)),
                  const SizedBox(width: 6),
                ],
                // AI actions on selected code (visible/enabled only when selection exists)
                Obx(() {
                  if (!_hasSelection.value) return const SizedBox.shrink();
                  return IconButton(
                    tooltip: 'AI actions on selected code',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    padding: const EdgeInsets.all(8),
                    icon: Icon(Icons.auto_awesome, size: 18, color: t.accent),
                    onPressed: _openSelectionActionSheet,
                  );
                }),
                // Undo button
                IconButton(
                  tooltip: 'Undo',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: const EdgeInsets.all(8),
                  icon: Icon(
                    Icons.undo_rounded,
                    size: 18,
                    color: _ctrl.canUndo.value ? t.text : t.faint,
                  ),
                  onPressed: _ctrl.canUndo.value ? _ctrl.undo : null,
                ),
                // Redo button
                IconButton(
                  tooltip: 'Redo',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: const EdgeInsets.all(8),
                  icon: Icon(
                    Icons.redo_rounded,
                    size: 18,
                    color: _ctrl.canRedo.value ? t.text : t.faint,
                  ),
                  onPressed: _ctrl.canRedo.value ? _ctrl.redo : null,
                ),
                // Find/replace toggle
                IconButton(
                  tooltip: 'Find & replace',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: const EdgeInsets.all(8),
                  icon: Icon(
                    Icons.find_replace_rounded,
                    size: 18,
                    color: _ctrl.isFindBarVisible.value ? t.accent : t.muted,
                  ),
                  onPressed: _ctrl.toggleFindBar,
                ),
                const SizedBox(width: 4),
                // Save button
                GestureDetector(
                  onTap: _ctrl.saveCurrentFile,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: unsaved ? t.primaryFill : t.fill,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Save',
                      style: t.small.copyWith(
                        color: unsaved ? t.onPrimary : t.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Collapsible Find & Replace Bar
          if (_ctrl.isFindBarVisible.value)
            _FindReplacePanel(
              ctrl: _ctrl,
              t: t,
              findController: _findController,
              replaceController: _replaceController,
            ),
          // Editor Text Field
          Expanded(
            child: Container(
              color: t.bg,
              child: TextField(
                controller: _textController,
                maxLines: null,
                expands: true,
                style: t.mono,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.all(16),
                  filled: true,
                  fillColor: t.bg,
                ),
                onChanged: _ctrl.updateEditorContent,
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _SelectionActionSheet extends StatelessWidget {
  final ScrollController scrollController;
  final String relativePath;
  final String language;
  final String selectedText;
  final bool isTruncated;
  final int originalLength;
  final void Function(String actionKey) onSelectAction;

  const _SelectionActionSheet({
    required this.scrollController,
    required this.relativePath,
    required this.language,
    required this.selectedText,
    required this.isTruncated,
    required this.originalLength,
    required this.onSelectAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return SingleChildScrollView(
      controller: scrollController,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isTruncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: AppNotice(
                'Selected code is capped at 8,000 characters (truncated from $originalLength characters).',
                icon: Icons.warning_amber_rounded,
                color: t.orange,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 14, color: t.muted),
                  const SizedBox(width: 6),
                  Text('$originalLength characters selected', style: t.small),
                ],
              ),
            ),
          _ActionCard(
            title: 'Explain',
            description: 'Understand what this code does and how it functions.',
            icon: Icons.lightbulb_outline_rounded,
            onTap: () => onSelectAction('explain'),
            t: t,
          ),
          const SizedBox(height: 8),
          _ActionCard(
            title: 'Find/fix bug',
            description: 'Detect bugs, potential errors, and propose fixes.',
            icon: Icons.bug_report_outlined,
            onTap: () => onSelectAction('bug'),
            t: t,
          ),
          const SizedBox(height: 8),
          _ActionCard(
            title: 'Refactor',
            description:
                'Improve readability, clean up design, and enhance structure.',
            icon: Icons.auto_fix_high_rounded,
            onTap: () => onSelectAction('refactor'),
            t: t,
          ),
          const SizedBox(height: 8),
          _ActionCard(
            title: 'Suggest tests',
            description:
                'Generate unit or integration tests for this code snippet.',
            icon: Icons.checklist_rounded,
            onTap: () => onSelectAction('tests'),
            t: t,
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback onTap;
  final AppTokens t;

  const _ActionCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 20, color: t.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.bodyStrong.copyWith(fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(description, style: t.small),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: t.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _FindReplacePanel extends StatelessWidget {
  final ProjectController ctrl;
  final AppTokens t;
  final TextEditingController findController;
  final TextEditingController replaceController;

  const _FindReplacePanel({
    required this.ctrl,
    required this.t,
    required this.findController,
    required this.replaceController,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Find input row
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: TextField(
                    controller: findController,
                    style: t.body.copyWith(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Find in file…',
                      hintStyle: t.caption,
                      prefixIcon: const Icon(Icons.search, size: 16),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                      filled: true,
                      fillColor: t.fill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (q) => ctrl.updateFindQuery(q),
                    onSubmitted: (_) => ctrl.findNextMatch(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Obx(() {
                final total = ctrl.findTotalMatches.value;
                final current = ctrl.currentMatchIndex.value;
                final text = ctrl.findQuery.value.isEmpty
                    ? ''
                    : total == 0
                    ? '0/0'
                    : '$current/$total';
                return Text(
                  text,
                  style: t.small.copyWith(
                    fontWeight: FontWeight.w600,
                    color: total > 0 ? t.text : t.muted,
                  ),
                );
              }),
              IconButton(
                tooltip: 'Next match',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.arrow_downward, size: 18),
                onPressed: ctrl.findNextMatch,
              ),
              IconButton(
                tooltip: 'Close search',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close, size: 18),
                onPressed: ctrl.toggleFindBar,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Replace input row
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: TextField(
                    controller: replaceController,
                    style: t.body.copyWith(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Replace with…',
                      hintStyle: t.caption,
                      prefixIcon: const Icon(Icons.find_replace, size: 16),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                      filled: true,
                      fillColor: t.fill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (r) => ctrl.replaceQuery.value = r,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: ctrl.replaceCurrentMatch,
                child: const Text('Replace'),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(70, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: ctrl.replaceAllMatches,
                child: const Text('All'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

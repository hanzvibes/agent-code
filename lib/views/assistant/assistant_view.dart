import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../../controllers/app_controller.dart';
import '../../controllers/assistant_controller.dart';
import '../../controllers/project_controller.dart';
import '../../controllers/review_controller.dart';
import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../models/agent_task.dart';
import '../../services/android_native_action_service.dart';
import '../../services/permission_service.dart';
import '../../models/chat_message.dart';
import '../../models/file_node.dart';
import '../../services/workspace_service.dart';
import '../../utils/unified_patch.dart';
import '../../widgets/markdown_message_view.dart';
import '../review/change_history_view.dart';
import '../review/review_view.dart';
import '../settings/provider_form_view.dart';
import 'activity_timeline.dart';
import 'task_panel.dart';
import 'terminal.dart';

class AssistantView extends StatefulWidget {
  const AssistantView({super.key});

  @override
  State<AssistantView> createState() => _AssistantViewState();
}

class _AssistantViewState extends State<AssistantView> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    if (Get.isRegistered<AssistantController>()) {
      Get.find<AssistantController>().onAndroidActionApproval = null;
    }
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send(AssistantController ctrl) async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    await ctrl.sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<AssistantController>();
    ctrl.onAndroidActionApproval = (request) =>
        _confirmAndroidAction(context, request);
    ctrl.onPermissionApproval = (request) =>
        _confirmPermission(context, request);
    final projCtrl = Get.find<ProjectController>();

    // Claude Code terminal look (Opsi A): the whole screen is forced
    // dark so the AppTokens-based children (markdown, sheets) render
    // dark on the warm terminal background, in light mode too.
    return Theme(
      data: buildTheme(isDark: true),
      child: Scaffold(
        backgroundColor: TerminalTokens.bg,
        body: SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              _TerminalScreenBar(
                ctrl: ctrl,
                onOpenSettings: () => _openSettingsSheet(context, ctrl),
              ),
              Expanded(
                child: Obx(() {
                  if (!ctrl.hasProfile) return const _NoProfileState();
                  // Rebuild when the change history changes (write tool / undo).
                  ctrl.changeHistoryRevision.value;
                  return Column(
                    children: [
                      _ContextBanner(projCtrl: projCtrl, ctrl: ctrl),
                      if (ctrl.activeTask.value != null)
                        TaskPanel(
                          task: ctrl.activeTask.value!,
                          isRunning: ctrl.isLoading.value,
                          onStop: ctrl.stopAgent,
                          changeCount: ctrl.activeTaskCheckpoints.length,
                          onViewChanges: () =>
                              _openChangeHistory(context, ctrl),
                          mode: ctrl.agentMode.value,
                          onModeChanged: (mode) => ctrl.setAgentMode(mode),
                          toolCalls: ctrl.toolCallRecords,
                          onResume: ctrl.resumeTask,
                        ),
                      Expanded(
                        child: ctrl.isRestoringSession.value
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: TerminalTokens.accent,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'Loading saved conversation…',
                                      style: TerminalTokens.caption,
                                    ),
                                  ],
                                ),
                              )
                            : ctrl.messages.isEmpty && !ctrl.isLoading.value
                            ? _EmptyAssistant(ctrl: ctrl)
                            : ListView.builder(
                                controller: _scrollController,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 16,
                                ),
                                itemCount:
                                    ctrl.messages.length +
                                    (ctrl.isLoading.value &&
                                            ctrl.streamingText.value.isNotEmpty
                                        ? 1
                                        : 0),
                                itemBuilder: (ctx, i) {
                                  if (i < ctrl.messages.length) {
                                    final msg = ctrl.messages[i];
                                    final isLatestAssistant =
                                        msg.role == 'assistant' &&
                                        i == ctrl.messages.length - 1;
                                    return _TerminalMessage(
                                      message: msg,
                                      isLatestAssistant: isLatestAssistant,
                                      canRegenerate:
                                          ctrl.canRegenerate &&
                                          isLatestAssistant,
                                      onRegenerate: ctrl.regenerate,
                                    );
                                  } else {
                                    // Streaming response in progress
                                    return _StreamingLine(
                                      text: ctrl.streamingText.value,
                                    );
                                  }
                                },
                              ),
                      ),
                      // Activity timeline (Batch 5 — desain D9): one
                      // terminal line per tool call, below the messages.
                      ActivityTimeline(
                        records: ctrl.toolCallRecords,
                        isRunning: ctrl.isLoading.value,
                      ),
                      if (ctrl.statusMessage.value.isNotEmpty)
                        _StatusLine(
                          status: ctrl.statusMessage.value,
                          onCancel: ctrl.cancelRequest,
                        ),
                      if (ctrl.diffOnlyNotice.value.isNotEmpty)
                        _InfoLine(
                          notice: ctrl.diffOnlyNotice.value,
                          onDismiss: ctrl.clearDiffOnlyNotice,
                        ),
                      if (ctrl.lastError.value.isNotEmpty)
                        _ErrorLine(
                          error: ctrl.lastError.value,
                          canRetry: ctrl.canRetry,
                          onRetry: ctrl.retry,
                        ),
                      if (ctrl.pendingPatch.value.isNotEmpty)
                        _PatchLine(ctrl: ctrl, projCtrl: projCtrl),
                      if (projCtrl.canRollbackPatch)
                        _RollbackLine(projCtrl: projCtrl),
                      TerminalStatusLine(
                        profileName: Get.find<AppController>()
                            .activeProfile
                            .value
                            ?.name,
                        task: ctrl.activeTask.value,
                      ),
                      TerminalPromptBar(
                        controller: _textController,
                        isLoading: ctrl.isLoading.value,
                        isRestoringSession: ctrl.isRestoringSession.value,
                        onSend: () => _send(ctrl),
                        onCancel: ctrl.cancelRequest,
                      ),
                    ],
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmAndroidAction(
    BuildContext context,
    AndroidActionRequest request,
  ) async {
    if (!context.mounted) return false;
    final actionLabel = switch (request.action) {
      'open_link' => 'Open link',
      'share_text' => 'Open share sheet',
      _ => 'Copy text',
    };
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: TerminalTokens.sheetBg,
          builder: (sheetContext) {
            final t = AppTokens.of(sheetContext);
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: TerminalTokens.faint,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(request.title, style: t.title),
                  const SizedBox(height: 6),
                  Text(request.description, style: t.caption),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: TerminalTokens.hairline),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 180),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          request.preview,
                          style: TerminalTokens.monoSmall.copyWith(
                            color: TerminalTokens.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TerminalPrimaryButton(
                    label: actionLabel,
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
          },
        ) ==
        true;
  }

  /// Approval sheet for a tool call that needs it (Batch 4 — desain
  /// D6). Follows the `_confirmAndroidAction` pattern (bottom sheet
  /// with the exact thing that will run), plus the "always allow this
  /// command in this workspace" choice. While this sheet is open the
  /// agent loop is paused waiting for the answer.
  Future<PermissionApproval> _confirmPermission(
    BuildContext context,
    PermissionApprovalRequest request,
  ) async {
    if (!context.mounted) return PermissionApproval.deny;
    final choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: TerminalTokens.sheetBg,
      builder: (sheetContext) {
        final t = AppTokens.of(sheetContext);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: TerminalTokens.faint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(request.title, style: t.title),
              const SizedBox(height: 6),
              Text(request.description, style: t.caption),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: TerminalTokens.hairline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      request.preview,
                      style: TerminalTokens.monoSmall.copyWith(
                        color: TerminalTokens.text,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TerminalPrimaryButton(
                label: 'Allow once',
                onPressed: () => Navigator.of(sheetContext).pop('once'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(sheetContext).pop('always'),
                child: const Text('Always allow in this workspace'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop('deny'),
                child: const Text('Deny'),
              ),
            ],
          ),
        );
      },
    );
    return switch (choice) {
      'once' => PermissionApproval.allowOnce,
      'always' => PermissionApproval.allowAlways,
      _ => PermissionApproval.deny,
    };
  }

  void _openSettingsSheet(BuildContext context, AssistantController ctrl) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SessionSettingsSheet(ctrl: ctrl),
    );
  }

  /// Opens the change history for the active task (Batch 2): the list
  /// of agent changes per step with diffs and undo buttons. Review is
  /// no longer a gate — this is history + undo, not an approval step.
  Future<void> _openChangeHistory(
    BuildContext context,
    AssistantController ctrl,
  ) async {
    if (ctrl.activeTask.value == null) return;
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ChangeHistoryView(ctrl: ctrl)));
  }
}

// ── Slim terminal screen bar ───────────────────────────────────────────

/// Replaces the old Material app bar: a 48px flat strip with the mono
/// 'Assistant' title and the two screen actions (generation settings,
/// clear conversation). No elevation, no surface — just a hairline.
class _TerminalScreenBar extends StatelessWidget {
  final AssistantController ctrl;
  final VoidCallback onOpenSettings;

  const _TerminalScreenBar({required this.ctrl, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 16, right: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TerminalTokens.hairline)),
      ),
      child: Row(
        children: [
          Text('Assistant', style: TerminalTokens.titleMono),
          const Spacer(),
          IconButton(
            icon: const Icon(
              Icons.tune_rounded,
              size: 22,
              color: TerminalTokens.muted,
            ),
            tooltip: 'Generation & tools',
            onPressed: onOpenSettings,
          ),
          Obx(
            () => ctrl.messages.isNotEmpty
                ? IconButton(
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 22,
                      color: TerminalTokens.muted,
                    ),
                    tooltip: 'Clear conversation',
                    onPressed: () async {
                      final ok = await confirmSheet(
                        context,
                        title: 'Clear conversation?',
                        message:
                            'This will delete the stored chat session for this workspace.',
                        confirmLabel: 'Clear',
                        destructive: true,
                      );
                      if (ok) await ctrl.clearConversation();
                    },
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ── No-profile empty state ───────────────────────────────────────────────

class _NoProfileState extends StatelessWidget {
  const _NoProfileState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: TerminalTokens.faint,
            ),
            const SizedBox(height: 20),
            Text('No provider configured', style: TerminalTokens.titleMono),
            const SizedBox(height: 8),
            Text(
              'Add a provider profile in Settings to use the AI assistant.',
              style: TerminalTokens.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TerminalPrimaryButton(
              label: 'Add an AI provider',
              icon: Icons.add_rounded,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      ProviderFormView(ctrl: Get.find<AppController>()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Context banner ───────────────────────────────────────────────────────

class _ContextBanner extends StatelessWidget {
  final ProjectController projCtrl;
  final AssistantController ctrl;
  const _ContextBanner({required this.projCtrl, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final total = ctrl.contextFileCount;
      final extra = ctrl.selectedExtraContextCount;
      final snapshot = ctrl.lastSnapshot.value;
      final modeLabel = ctrl.agentMode.value.label;
      final lastRequestWasTruncated =
          snapshot != null &&
          p.equals(snapshot.workspaceRoot, projCtrl.workspacePath.value) &&
          snapshot.files.any((file) => file.truncated);

      String bannerText;
      if (!projCtrl.hasWorkspace) {
        bannerText =
            'Prompt and chat are sent directly to the selected provider.';
      } else if (total > 0) {
        final included = projCtrl.openFile.value == null
            ? '$extra selected'
            : 'open + $extra selected';
        bannerText =
            'Project tree + $total context file${total == 1 ? '' : 's'} ($included) sent directly to provider. Mode $modeLabel. Context leaves device.';
      } else {
        bannerText =
            'Project tree and chat go to provider. Mode $modeLabel. Choose files to include source code. Context leaves device.';
      }
      if (lastRequestWasTruncated) {
        bannerText +=
            ' Last request truncated one or more files to fit budget.';
      }
      if (ctrl.hasAgentsInstructions) {
        bannerText +=
            ' AGENTS.md guidance (${ctrl.lastAgentsInstructions.value!.uiLabel}) sent.';
      }

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: TerminalTokens.hairline)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              size: 14,
              color: TerminalTokens.faint,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(bannerText, style: TerminalTokens.small)),
            if (ctrl.hasAgentsInstructions) ...[
              const SizedBox(width: 8),
              Text(
                ctrl.lastAgentsInstructions.value!.uiLabel,
                style: TerminalTokens.monoSmall.copyWith(
                  color: TerminalTokens.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (projCtrl.hasWorkspace)
              IconButton(
                icon: const Icon(
                  Icons.file_copy_outlined,
                  size: 18,
                  color: TerminalTokens.accent,
                ),
                tooltip: 'Choose context files',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: ctrl.isLoading.value
                    ? null
                    : () => _showContextPicker(context),
              ),
          ],
        ),
      );
    });
  }

  void _showContextPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ContextPickerSheet(projCtrl: projCtrl, ctrl: ctrl),
    );
  }
}

// ── Context file picker sheet ────────────────────────────────────────────

class _ContextPickerSheet extends StatelessWidget {
  final ProjectController projCtrl;
  final AssistantController ctrl;
  const _ContextPickerSheet({required this.projCtrl, required this.ctrl});

  List<FileNode> _flatFiles(List<FileNode> nodes) {
    final result = <FileNode>[];
    for (final node in nodes) {
      if (!node.isDirectory) result.add(node);
      if (node.isDirectory) result.addAll(_flatFiles(node.children));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final allFiles = _flatFiles(projCtrl.fileTree);
    final openPath = projCtrl.openFile.value?.path;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Context files', style: t.title),
                      const SizedBox(height: 2),
                      Text(
                        'Up to 8 files total. The open file is always included.',
                        style: t.caption,
                      ),
                    ],
                  ),
                ),
                Obx(() {
                  final count = ctrl.contextFileCount;
                  return AppTag('$count / 8');
                }),
              ],
            ),
          ),
          Divider(height: 0.5, color: t.hairline),
          Expanded(
            child: ListView.builder(
              controller: scrollCtrl,
              itemCount: allFiles.length,
              itemBuilder: (_, i) {
                final node = allFiles[i];
                final isOpen = node.path == openPath;
                final relativePath = p.relative(
                  node.path,
                  from: projCtrl.workspacePath.value,
                );
                return Obx(() {
                  final isSelected = ctrl.selectedContextPaths.contains(
                    node.path,
                  );
                  final canAdd = ctrl.canAddContextFile(node.path);
                  final snapshot = ctrl.lastSnapshot.value;
                  final wasTruncated =
                      snapshot != null &&
                      p.equals(
                        snapshot.workspaceRoot,
                        projCtrl.workspacePath.value,
                      ) &&
                      snapshot.forAbsolutePath(node.path)?.truncated == true;
                  return _ContextFileRow(
                    node: node,
                    relativePath: relativePath,
                    isOpen: isOpen,
                    isSelected: isSelected || isOpen,
                    truncated: wasTruncated,
                    dimmed: !isOpen && !isSelected && !canAdd,
                    onTap:
                        isOpen ||
                            ctrl.isLoading.value ||
                            (!isSelected && !canAdd)
                        ? null
                        : () => ctrl.toggleContextFile(node.path),
                  );
                });
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Obx(
                      () => OutlinedButton(
                        onPressed:
                            ctrl.isLoading.value ||
                                ctrl.selectedContextPaths.isEmpty
                            ? null
                            : ctrl.clearContextSelection,
                        child: const Text('Clear selection'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextFileRow extends StatelessWidget {
  final FileNode node;
  final String relativePath;
  final bool isOpen;
  final bool isSelected;
  final bool truncated;
  final bool dimmed;
  final VoidCallback? onTap;

  const _ContextFileRow({
    required this.node,
    required this.relativePath,
    required this.isOpen,
    required this.isSelected,
    required this.truncated,
    required this.dimmed,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 20,
              color: isSelected
                  ? t.accent
                  : dimmed
                  ? t.faint
                  : t.muted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                relativePath,
                style: t.body.copyWith(
                  color: dimmed ? t.faint : null,
                  fontWeight: isOpen ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (isOpen) AppTag('open', color: t.accent),
            if (truncated) ...[
              if (isOpen) const SizedBox(width: 4),
              AppTag('truncated', color: t.muted),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Empty / quick-prompt state ───────────────────────────────────────────

class _EmptyAssistant extends StatelessWidget {
  final AssistantController ctrl;
  const _EmptyAssistant({required this.ctrl});

  static const _chips = [
    (
      Icons.description_outlined,
      'Explain this file',
      'Explain the source code currently included in my context, its purpose, and any notable patterns or concerns.',
    ),
    (
      Icons.bug_report_outlined,
      'Find a likely bug',
      'Review the source files currently included in my context and identify the most likely bug or issue. Explain what it is and why it matters.',
    ),
    (
      Icons.science_outlined,
      'Suggest tests',
      'Suggest specific unit tests for the source files currently included in my context. Describe what each test should cover and why.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '>',
              style: TerminalTokens.mono.copyWith(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: TerminalTokens.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Ask anything about your project',
              style: TerminalTokens.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final (icon, label, prompt) in _chips)
                  _QuickPromptChip(
                    icon: icon,
                    label: label,
                    onTap: () => ctrl.sendMessage(prompt),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickPromptChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _QuickPromptChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: TerminalTokens.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: TerminalTokens.muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TerminalTokens.mono.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Terminal message row ───────────────────────────────────────────────

/// Claude Code style: no bubble, no avatar — the user's turn is plain
/// text prefixed with a coral `>`, the assistant's turn is plain
/// markdown text. Copy / Regenerate stay as small muted text actions
/// under the latest assistant turn.
class _TerminalMessage extends StatelessWidget {
  final ChatMessage message;
  final bool isLatestAssistant;
  final bool canRegenerate;
  final VoidCallback? onRegenerate;

  const _TerminalMessage({
    required this.message,
    this.isLatestAssistant = false,
    this.canRegenerate = false,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: GestureDetector(
          onLongPress: () {
            Clipboard.setData(ClipboardData(text: message.content));
            showToast(
              'Copied',
              'Message copied to clipboard',
              tone: ToastTone.success,
            );
          },
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '>',
                style: TerminalTokens.mono.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: TerminalTokens.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(message.content, style: TerminalTokens.body),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownMessageView(content: message.content, t: AppTokens.of(context)),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: 'Copy entire response',
                button: true,
                child: TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    showToast(
                      'Copied',
                      'Full response copied to clipboard',
                      tone: ToastTone.success,
                    );
                  },
                  child: Text(
                    'copy',
                    style: TerminalTokens.monoSmall,
                  ),
                ),
              ),
              if (canRegenerate) ...[
                const SizedBox(width: 4),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: onRegenerate,
                  child: Text(
                    'regenerate',
                    style: TerminalTokens.monoSmall.copyWith(
                      color: TerminalTokens.accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ── Live streaming line ──────────────────────────────────────────────────

/// Streaming response: plain markdown text with a blinking block
/// cursor, Claude Code style. No bubble, no avatar.
class _StreamingLine extends StatelessWidget {
  final String text;

  const _StreamingLine({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownMessageView(content: text, t: AppTokens.of(context)),
          const SizedBox(height: 2),
          const _BlinkingCursor(),
        ],
      ),
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor();

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 530),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 16,
        color: TerminalTokens.accent,
      ),
    );
  }
}

// ── Live status line ───────────────────────────────────────────────────

/// Terminal version of the old status banner: a flat line with a
/// coral left border, a spinner, the status text and a stop action.
class _StatusLine extends StatelessWidget {
  final String status;
  final VoidCallback onCancel;

  const _StatusLine({required this.status, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: TerminalTokens.accent, width: 3),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: TerminalTokens.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              style: TerminalTokens.caption.copyWith(
                color: TerminalTokens.text,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Cancel',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: const EdgeInsets.all(8),
            icon: const Icon(
              Icons.stop_rounded,
              size: 20,
              color: TerminalTokens.red,
            ),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

// ── Info line (diff-only fallback) ─────────────────────────────────────

/// Explains why a task ran without tools (Batch 6 — desain D10): the
/// gateway does not support tool calling, so the agent fell back to
/// diff proposals. Dismissable; it clears when the next task starts.
class _InfoLine extends StatelessWidget {
  final String notice;
  final VoidCallback onDismiss;

  const _InfoLine({required this.notice, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: TerminalTokens.accent, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: TerminalTokens.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              style: TerminalTokens.caption.copyWith(
                color: TerminalTokens.text,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: const EdgeInsets.all(8),
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: TerminalTokens.muted,
            ),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

// ── Error line with Retry action ─────────────────────────────────────────

class _ErrorLine extends StatelessWidget {
  final String error;
  final bool canRetry;
  final VoidCallback onRetry;

  const _ErrorLine({
    required this.error,
    required this.canRetry,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: TerminalTokens.red, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: TerminalTokens.red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TerminalTokens.caption.copyWith(
                color: TerminalTokens.red,
              ),
            ),
          ),
          if (canRetry) ...[
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: TerminalTokens.red,
                side: BorderSide(
                  color: TerminalTokens.red.withValues(alpha: 0.5),
                ),
                minimumSize: const Size(60, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Patch line ───────────────────────────────────────────────────────────

class _PatchLine extends StatelessWidget {
  final AssistantController ctrl;
  final ProjectController projCtrl;

  const _PatchLine({required this.ctrl, required this.projCtrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: TerminalTokens.accent, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.difference_outlined,
            size: 18,
            color: TerminalTokens.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Proposed code changes available',
              style: TerminalTokens.caption,
            ),
          ),
          GestureDetector(
            onTap: () => _openReview(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: TerminalTokens.accent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Review',
                style: TerminalTokens.small.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openReview(BuildContext context) async {
    if (!projCtrl.hasWorkspace) {
      Get.snackbar(
        'No project open',
        'Open a project before reviewing a patch.',
      );
      return;
    }
    if (projCtrl.hasUnsavedChanges) {
      Get.snackbar(
        'Save your file first',
        'Save the open file, then ask the assistant again so the patch matches the on-disk version.',
      );
      return;
    }

    final snapshot = ctrl.lastSnapshot.value;
    if (snapshot == null) {
      Get.snackbar(
        'No context snapshot',
        'Send a message first to generate a patch.',
      );
      return;
    }
    if (!p.equals(snapshot.workspaceRoot, projCtrl.workspacePath.value)) {
      Get.snackbar(
        'Workspace changed',
        'Open the same project folder and ask again.',
      );
      return;
    }

    final patch = ctrl.pendingPatch.value;
    final fileContents = <String, String>{};
    final existedAtPreview = <String, bool>{};

    try {
      final paths = UnifiedPatchParser.outputPaths(patch);
      if (paths.isEmpty) {
        throw const UnifiedPatchException(
          'No supported file changes were found.',
        );
      }
      for (final relativePath in paths) {
        final absolutePath = await WorkspaceService.resolveSafePath(
          projCtrl.workspacePath.value,
          relativePath,
        );
        final exists = await File(absolutePath).exists();
        final snapshotFile = snapshot.forAbsolutePath(absolutePath);
        if (snapshotFile != null) {
          if (!exists) {
            throw FileSystemException(
              '$relativePath was removed after the request was sent. Ask again.',
            );
          }
          final current = await WorkspaceService.readFile(absolutePath);
          if (current != snapshotFile.baseline) {
            throw FileSystemException(
              '$relativePath changed after the request was sent. Ask again.',
            );
          }
          fileContents[relativePath] = snapshotFile.baseline;
        } else if (exists) {
          throw const UnifiedPatchException(
            'The patch targets an existing file that was not in the sent context. Select that file in context and ask again.',
          );
        } else {
          fileContents[relativePath] = '';
        }
        existedAtPreview[relativePath] = exists;
      }
    } catch (error) {
      Get.snackbar('Could not review patch', error.toString());
      return;
    }

    final reviewCtrl = ReviewController();
    reviewCtrl.loadPatch(
      patch,
      fileContents,
      existedAtPreview: existedAtPreview,
    );
    if (reviewCtrl.parseError.value.isNotEmpty) {
      Get.snackbar('Could not review patch', reviewCtrl.parseError.value);
      return;
    }

    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => ReviewView(
          ctrl: reviewCtrl,
          onApply: () async {
            try {
              await projCtrl.applyPatch(reviewCtrl.patchFiles);
              ctrl.clearPendingPatch();
              navigator.pop(true);
              showToast(
                'Patch applied',
                'Changes written to disk',
                tone: ToastTone.success,
              );
            } catch (error) {
              Get.snackbar('Patch not applied', error.toString());
            }
          },
          onDiscard: () {
            ctrl.clearPendingPatch();
            Navigator.of(context).pop(false);
          },
        ),
      ),
    );
  }
}

// ── Rollback line ──────────────────────────────────────────────────────

class _RollbackLine extends StatelessWidget {
  final ProjectController projCtrl;

  const _RollbackLine({required this.projCtrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: TerminalTokens.orange, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.history_rounded,
            size: 18,
            color: TerminalTokens.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI patch recently applied',
              style: TerminalTokens.caption,
            ),
          ),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: TerminalTokens.orange,
              side: BorderSide(
                color: TerminalTokens.orange.withValues(alpha: 0.5),
              ),
              minimumSize: const Size(60, 36),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: const Text('Undo patch'),
            onPressed: () async {
              final ok = await confirmSheet(
                context,
                title: 'Undo applied patch?',
                message:
                    'Reverts all modified files and deletes newly created files from the last patch.',
                confirmLabel: 'Undo patch',
                destructive: true,
              );
              if (ok) {
                try {
                  await projCtrl.rollbackLastPatch();
                  showToast(
                    'Patch reverted',
                    'Previous code state restored',
                    tone: ToastTone.success,
                  );
                } catch (e) {
                  showToast(
                    'Could not rollback',
                    e.toString(),
                    tone: ToastTone.error,
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

// ── Session settings & tools bottom sheet ────────────────────────────────

class _SessionSettingsSheet extends StatefulWidget {
  final AssistantController ctrl;
  const _SessionSettingsSheet({required this.ctrl});

  @override
  State<_SessionSettingsSheet> createState() => _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends State<_SessionSettingsSheet> {
  late double? _temp;
  late int? _maxTokens;
  late AgentMode _mode;

  @override
  void initState() {
    super.initState();
    _temp = widget.ctrl.sessionTemperature.value;
    _maxTokens = widget.ctrl.sessionMaxTokens.value;
    _mode = widget.ctrl.agentMode.value;
  }


  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => ListView(
        controller: scrollCtrl,
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: t.sheetHandle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Generation & Agent Mode', style: t.title),
          const SizedBox(height: 4),
          Text(
            'Per-workspace configuration. The mode is saved for this workspace and kept when you switch projects.',
            style: t.caption,
          ),
          const SizedBox(height: 20),
          SectionHeader('Sampling Temperature (0.0 – 2.0)'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Temperature', style: t.bodyStrong),
                    Text(
                      _temp == null
                          ? 'Default (model choice)'
                          : _temp!.toStringAsFixed(2),
                      style: t.caption.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                Slider(
                  value: _temp ?? 0.7,
                  min: 0.0,
                  max: 2.0,
                  divisions: 20,
                  label: (_temp ?? 0.7).toStringAsFixed(2),
                  onChanged: (v) {
                    setState(() => _temp = v);
                    widget.ctrl.setSessionTemperature(v);
                  },
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () {
                      setState(() => _temp = null);
                      widget.ctrl.setSessionTemperature(null);
                    },
                    child: const Text('Reset to default'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionHeader('Max Completion Tokens (256 – 8192)'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Max tokens', style: t.bodyStrong),
                    Text(
                      _maxTokens == null
                          ? 'Default (unbounded)'
                          : '$_maxTokens tokens',
                      style: t.caption.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                Slider(
                  value: (_maxTokens ?? 2048).toDouble(),
                  min: 256,
                  max: 8192,
                  divisions: 31,
                  label: (_maxTokens ?? 2048).toString(),
                  onChanged: (v) {
                    final val = v.round();
                    setState(() => _maxTokens = val);
                    widget.ctrl.setSessionMaxTokens(val);
                  },
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () {
                      setState(() => _maxTokens = null);
                      widget.ctrl.setSessionMaxTokens(null);
                    },
                    child: const Text('Reset to default'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AppNotice(
            'Compatibility hint: Certain reasoning models (e.g. o1, o3-mini) or custom gateways reject custom temperature or token limits. Leave unset to use provider defaults.',
            icon: Icons.lightbulb_outline_rounded,
          ),
          const SizedBox(height: 20),
          SectionHeader('Agent Mode'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<AgentMode>(
                  segments: const [
                    ButtonSegment(value: AgentMode.plan, label: Text('Plan')),
                    ButtonSegment(value: AgentMode.agent, label: Text('Agent')),
                    ButtonSegment(value: AgentMode.auto, label: Text('Auto')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) {
                    final next = selection.single;
                    setState(() => _mode = next);
                    widget.ctrl.setAgentMode(next);
                  },
                  showSelectedIcon: false,
                ),
                const SizedBox(height: 10),
                Text(TaskPanel.modeHint(_mode), style: t.small),
                const SizedBox(height: 10),
                Text(
                  'Commands the agent runs are checked first: destructive, network-out, install, and blocked-list commands ask for your approval in Agent mode. The blocked list (rm -rf, mkfs, dd, format, writes outside the project, curl | sh, credentials in commands) never runs automatically in any mode.',
                  style: t.small,
                ),
                const Divider(height: 20),
                Text(
                  'Android actions (copy/share/open link) always show an in-app approval with the exact payload first, in every mode.',
                  style: t.small,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const SizedBox(height: 16),
          Text(
            'Each task has 25 rounds and 60 tool calls. The mode applies to the next step, including a task that is already running.',
            style: t.small,
          ),
          const SizedBox(height: 24),
          PrimaryButton(
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

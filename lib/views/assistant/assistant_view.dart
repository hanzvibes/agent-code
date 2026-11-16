import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../../controllers/app_controller.dart';
import '../../controllers/assistant_controller.dart';
import '../../controllers/project_controller.dart';
import '../../controllers/review_controller.dart';
import '../../core/ui.dart';
import '../../models/chat_message.dart';
import '../../models/file_node.dart';
import '../../services/workspace_service.dart';
import '../../utils/unified_patch.dart';
import '../../widgets/markdown_message_view.dart';
import '../review/review_view.dart';
import '../settings/provider_form_view.dart';

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
    final t = AppTokens.of(context);
    final ctrl = Get.find<AssistantController>();
    final projCtrl = Get.find<ProjectController>();

    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'Assistant',
        actions: [
          IconButton(
            icon: Icon(Icons.tune_rounded, size: 22, color: t.text),
            tooltip: 'Generation & tools',
            onPressed: () => _openSettingsSheet(context, ctrl),
          ),
          Obx(
            () => ctrl.messages.isNotEmpty
                ? IconButton(
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      size: 22,
                      color: t.text,
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
      body: Obx(() {
        if (!ctrl.hasProfile) return const _NoProfileState();
        return Column(
          children: [
            _ContextBanner(projCtrl: projCtrl, ctrl: ctrl),
            Expanded(
              child: ctrl.isRestoringSession.value
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(height: 12),
                          Text('Loading saved conversation…', style: t.caption),
                        ],
                      ),
                    )
                  : ctrl.messages.isEmpty && !ctrl.isLoading.value
                  ? _EmptyAssistant(t: t, ctrl: ctrl)
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
                          return _MessageBubble(
                            message: msg,
                            t: t,
                            isLatestAssistant: isLatestAssistant,
                            canRegenerate:
                                ctrl.canRegenerate && isLatestAssistant,
                            onRegenerate: ctrl.regenerate,
                          );
                        } else {
                          // Streaming response in progress
                          return _StreamingBubble(
                            text: ctrl.streamingText.value,
                            t: t,
                          );
                        }
                      },
                    ),
            ),
            if (ctrl.statusMessage.value.isNotEmpty)
              _StatusBanner(
                status: ctrl.statusMessage.value,
                t: t,
                onCancel: ctrl.cancelRequest,
              ),
            if (ctrl.lastError.value.isNotEmpty)
              _ErrorBanner(
                error: ctrl.lastError.value,
                t: t,
                canRetry: ctrl.canRetry,
                onRetry: ctrl.retry,
              ),
            if (ctrl.pendingPatch.value.isNotEmpty)
              _PatchBanner(ctrl: ctrl, projCtrl: projCtrl, t: t),
            if (projCtrl.canRollbackPatch)
              _RollbackBanner(projCtrl: projCtrl, t: t),
            _InputBar(
              controller: _textController,
              isLoading: ctrl.isLoading.value,
              isRestoringSession: ctrl.isRestoringSession.value,
              onSend: () => _send(ctrl),
              onCancel: ctrl.cancelRequest,
              t: t,
            ),
          ],
        );
      }),
    );
  }

  void _openSettingsSheet(BuildContext context, AssistantController ctrl) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SessionSettingsSheet(ctrl: ctrl),
    );
  }
}

// ── No-profile empty state ───────────────────────────────────────────────

class _NoProfileState extends StatelessWidget {
  const _NoProfileState();

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 56, color: t.faint),
            const SizedBox(height: 20),
            Text('No provider configured', style: t.title),
            const SizedBox(height: 8),
            Text(
              'Add a provider profile in Settings to use the AI assistant.',
              style: t.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            PrimaryButton(
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
    final t = AppTokens.of(context);
    return Obx(() {
      final total = ctrl.contextFileCount;
      final extra = ctrl.selectedExtraContextCount;
      final snapshot = ctrl.lastSnapshot.value;
      final toolsOn = ctrl.enableTools.value;
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
            'Project tree + $total context file${total == 1 ? '' : 's'} ($included) sent directly to provider.${toolsOn ? ' Tools ON.' : ''} Context leaves device.';
      } else {
        bannerText =
            'Project tree and chat go to provider.${toolsOn ? ' Tools ON.' : ''} Choose files to include source code. Context leaves device.';
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
        color: t.surface,
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 14, color: t.muted),
            const SizedBox(width: 8),
            Expanded(child: Text(bannerText, style: t.small)),
            if (ctrl.hasAgentsInstructions) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.accent.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shield_outlined, size: 12, color: t.accent),
                    const SizedBox(width: 4),
                    Text(
                      ctrl.lastAgentsInstructions.value!.uiLabel,
                      style: t.small.copyWith(
                        color: t.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (projCtrl.hasWorkspace)
              IconButton(
                icon: Icon(Icons.file_copy_outlined, size: 18, color: t.accent),
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
  final AppTokens t;
  final AssistantController ctrl;
  const _EmptyAssistant({required this.t, required this.ctrl});

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
            Icon(Icons.chat_bubble_outline_rounded, size: 48, color: t.faint),
            const SizedBox(height: 16),
            Text(
              'Ask anything about your project',
              style: t.caption,
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
                    t: t,
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
  final AppTokens t;

  const _QuickPromptChip({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: t.muted),
            const SizedBox(width: 6),
            Text(
              label,
              style: t.caption.copyWith(
                color: t.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Message bubble ───────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final AppTokens t;
  final bool isLatestAssistant;
  final bool canRegenerate;
  final VoidCallback? onRegenerate;

  const _MessageBubble({
    required this.message,
    required this.t,
    this.isLatestAssistant = false,
    this.canRegenerate = false,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.smart_toy_outlined, size: 18, color: t.accent),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    showToast(
                      'Copied',
                      'Message copied to clipboard',
                      tone: ToastTone.success,
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isUser ? t.accent : t.surface,
                      borderRadius: BorderRadius.circular(16).copyWith(
                        bottomRight: isUser ? const Radius.circular(4) : null,
                        bottomLeft: isUser ? null : const Radius.circular(4),
                      ),
                      border: isUser ? null : Border.all(color: t.hairline),
                    ),
                    child: isUser
                        ? Text(
                            message.content,
                            style: t.body.copyWith(
                              color: Colors.white,
                              fontSize: 14.5,
                              height: 1.35,
                            ),
                          )
                        : MarkdownMessageView(content: message.content, t: t),
                  ),
                ),
                if (!isUser) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Explicit one-tap copy button for full assistant response
                      Semantics(
                        label: 'Copy entire response',
                        button: true,
                        child: IconButton(
                          tooltip: 'Copy entire response',
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          icon: Icon(
                            Icons.copy_all_rounded,
                            size: 16,
                            color: t.muted,
                          ),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: message.content),
                            );
                            showToast(
                              'Copied',
                              'Full response copied to clipboard',
                              tone: ToastTone.success,
                            );
                          },
                        ),
                      ),
                      if (canRegenerate) ...[
                        const SizedBox(width: 4),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(44, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.refresh_rounded, size: 14),
                          label: const Text('Regenerate'),
                          onPressed: onRegenerate,
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }
}

// ── Live Streaming Bubble ───────────────────────────────────────────────

class _StreamingBubble extends StatelessWidget {
  final String text;
  final AppTokens t;

  const _StreamingBubble({required this.text, required this.t});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.smart_toy_outlined, size: 18, color: t.accent),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: t.surface,
                borderRadius: BorderRadius.circular(
                  16,
                ).copyWith(bottomLeft: const Radius.circular(4)),
                border: Border.all(color: t.hairline),
              ),
              child: MarkdownMessageView(content: text, t: t),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Live Status Banner ───────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final String status;
  final AppTokens t;
  final VoidCallback onCancel;

  const _StatusBanner({
    required this.status,
    required this.t,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              style: t.caption.copyWith(color: t.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Cancel',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: const EdgeInsets.all(8),
            icon: Icon(Icons.stop_rounded, size: 20, color: t.red),
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

// ── Error banner with Retry action ───────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String error;
  final AppTokens t;
  final bool canRetry;
  final VoidCallback onRetry;

  const _ErrorBanner({
    required this.error,
    required this.t,
    required this.canRetry,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: t.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(error, style: t.caption.copyWith(color: t.red)),
          ),
          if (canRetry) ...[
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: t.red,
                side: BorderSide(color: t.red.withValues(alpha: 0.5)),
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

// ── Patch banner ─────────────────────────────────────────────────────────

class _PatchBanner extends StatelessWidget {
  final AssistantController ctrl;
  final ProjectController projCtrl;
  final AppTokens t;

  const _PatchBanner({
    required this.ctrl,
    required this.projCtrl,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.difference_outlined, size: 18, color: t.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Proposed code changes available', style: t.caption),
          ),
          GestureDetector(
            onTap: () => _openReview(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: t.accent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Review',
                style: t.small.copyWith(
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

// ── Rollback banner ──────────────────────────────────────────────────────

class _RollbackBanner extends StatelessWidget {
  final ProjectController projCtrl;
  final AppTokens t;

  const _RollbackBanner({required this.projCtrl, required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.orange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 18, color: t.orange),
          const SizedBox(width: 8),
          Expanded(child: Text('AI patch recently applied', style: t.caption)),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: t.orange,
              side: BorderSide(color: t.orange.withValues(alpha: 0.5)),
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
  late bool _tools;

  @override
  void initState() {
    super.initState();
    _temp = widget.ctrl.sessionTemperature.value;
    _maxTokens = widget.ctrl.sessionMaxTokens.value;
    _tools = widget.ctrl.enableTools.value;
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
          Text('Generation & Workspace Tools', style: t.title),
          const SizedBox(height: 4),
          Text(
            'Per-session configuration. These options are kept in memory and passed directly to your selected provider gateway.',
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
          SectionHeader('Workspace Tools (Agent)'),
          AppCard(
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Enable workspace tools', style: t.bodyStrong),
                  subtitle: Text(
                    'Allows the model to call read-only tools to inspect files and search code.',
                    style: t.caption,
                  ),
                  value: _tools,
                  onChanged: (on) {
                    setState(() => _tools = on);
                    widget.ctrl.enableTools.value = on;
                  },
                ),
                if (_tools) ...[
                  Divider(height: 1, color: t.hairline),
                  const SizedBox(height: 8),
                  Text(
                    'Privacy & safety disclosure: Enabling workspace tools allows your configured provider to request read-only directory listings, file contents (up to 512 KB, 16 KB preview), and project search results during conversations. Tools never modify files, run tests, or execute commands. Max 3 tool rounds and 6 calls per user turn.',
                    style: t.small,
                  ),
                ],
              ],
            ),
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

// ── Input bar ────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isRestoringSession;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final AppTokens t;

  const _InputBar({
    required this.controller,
    required this.isLoading,
    required this.isRestoringSession,
    required this.onSend,
    required this.onCancel,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.hairline)),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !isRestoringSession,
                maxLines: 4,
                minLines: 1,
                style: t.body.copyWith(fontSize: 14),
                decoration: InputDecoration(
                  hintText: isRestoringSession
                      ? 'Loading saved conversation…'
                      : 'Ask about your code…',
                  hintStyle: t.caption,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                ),
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            if (isLoading)
              GestureDetector(
                onTap: onCancel,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: t.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.red.withValues(alpha: 0.3)),
                  ),
                  child: Icon(Icons.stop_rounded, color: t.red, size: 24),
                ),
              )
            else
              GestureDetector(
                onTap: isRestoringSession ? null : onSend,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: isRestoringSession ? t.fill : t.accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: isRestoringSession
                      ? Padding(
                          padding: const EdgeInsets.all(15),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: t.muted,
                          ),
                        )
                      : const Icon(
                          Icons.send_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../models/agent_task.dart';
import '../../models/tool_call_record.dart';

/// Active-task card shown above the message list (Batch 1, desain D9;
/// Batch 5: todo checklist + resume).
///
/// Follows the visual pattern of `_RuntimeOutputCard` / `_StatusBanner`:
/// surface card, hairline border, small text. Shows the task title,
/// current mode, todo progress (x/y) and the budget used; the Stop
/// button cancels the running loop (not just the UI).
///
/// Batch 5: each todo step is a checklist row that expands to show
/// the tool calls made for that step, and a paused task shows a
/// Lanjutkan button that continues the loop from the round it
/// stopped at instead of restarting.
class TaskPanel extends StatefulWidget {
  final AgentTask task;
  final bool isRunning;
  final VoidCallback onStop;

  /// Number of recorded agent changes for this task (Batch 2). When
  /// greater than zero, a button opens the change history with undo.
  final int changeCount;
  final VoidCallback? onViewChanges;

  /// Live mode (Batch 4): may differ from [task].mode when the user
  /// switches mid-task — the switch applies to the next step. Null
  /// means "show the task's mode".
  final AgentMode? mode;

  /// Called when the user picks another mode. When null, the mode is
  /// shown as a tag only (no switcher).
  final ValueChanged<AgentMode>? onModeChanged;

  /// Tool-call records of this task (Batch 5). Each todo step expands
  /// to show the records linked to it.
  final List<ToolCallRecord> toolCalls;

  /// Called when the user presses Lanjutkan on a paused task
  /// (Batch 5). When null, no resume button is shown.
  final VoidCallback? onResume;

  const TaskPanel({
    super.key,
    required this.task,
    required this.isRunning,
    required this.onStop,
    this.changeCount = 0,
    this.onViewChanges,
    this.mode,
    this.onModeChanged,
    this.toolCalls = const [],
    this.onResume,
  });

  static String statusLabel(TaskStatus status) => switch (status) {
    TaskStatus.active => 'Berjalan',
    TaskStatus.paused => 'Dijeda — bisa dilanjutkan',
    TaskStatus.done => 'Selesai',
    TaskStatus.failed => 'Gagal',
    TaskStatus.needsHelp => 'Butuh bantuan',
    TaskStatus.cancelled => 'Dibatalkan',
  };

  /// One-line explanation of what the mode allows (Batch 4, D6).
  static String modeHint(AgentMode mode) => switch (mode) {
    AgentMode.plan =>
      'Plan — hanya baca. Agent membuat rencana; tidak ada file diubah atau perintah dijalankan.',
    AgentMode.agent =>
      'Agent — baca, tulis, dan perintah aman jalan otomatis; yang berisiko minta persetujuan dulu.',
    AgentMode.auto =>
      'Auto — semua jalan otomatis kecuali daftar larang. Hanya untuk workspace tepercaya.',
  };

  /// True when the task stopped in a state Lanjutkan can continue
  /// from (Batch 5 — desain D8).
  static bool canResume(TaskStatus status) =>
      status == TaskStatus.paused ||
      status == TaskStatus.needsHelp ||
      status == TaskStatus.cancelled;

  @override
  State<TaskPanel> createState() => _TaskPanelState();
}

class _TaskPanelState extends State<TaskPanel> {
  /// Todo step currently expanded to show its tool calls, if any.
  String? _expandedStepId;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final task = widget.task;
    final done = task.doneTodoCount;
    final total = task.totalTodoCount;
    final progress = total == 0 ? 0.0 : done / total;
    final effectiveMode = widget.mode ?? task.mode;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.assignment_turned_in_outlined,
                size: 16,
                color: t.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.title,
                  style: t.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (widget.onModeChanged == null)
                AppTag(effectiveMode.label, color: t.accent),
              if (widget.isRunning) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: t.red,
                    side: BorderSide(color: t.red.withValues(alpha: 0.5)),
                    minimumSize: const Size(44, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 16),
                  label: const Text('Stop'),
                  onPressed: widget.onStop,
                ),
              ],
            ],
          ),
          if (widget.onModeChanged != null) ...[
            const SizedBox(height: 10),
            SegmentedButton<AgentMode>(
              segments: const [
                ButtonSegment(value: AgentMode.plan, label: Text('Plan')),
                ButtonSegment(value: AgentMode.agent, label: Text('Agent')),
                ButtonSegment(value: AgentMode.auto, label: Text('Auto')),
              ],
              selected: {effectiveMode},
              onSelectionChanged: (selection) =>
                  widget.onModeChanged!(selection.single),
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              TaskPanel.modeHint(effectiveMode),
              style: t.small.copyWith(color: t.muted),
            ),
          ],
          const SizedBox(height: 8),
          if (total > 0) ...[
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                      backgroundColor: t.fill,
                      valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('$done/$total langkah', style: t.small),
              ],
            ),
            const SizedBox(height: 6),
            // Todo checklist (Batch 5 — desain D9): each step expands
            // to show the tool calls linked to it.
            for (final step in task.todos)
              _TodoRow(
                step: step,
                calls: _callsForStep(step),
                expanded: _expandedStepId == step.id,
                onTap: () => setState(() {
                  _expandedStepId = _expandedStepId == step.id ? null : step.id;
                }),
                t: t,
              ),
            const SizedBox(height: 2),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  'Ronde ${task.roundsUsed}/${task.maxRounds} • '
                  'Tool ${task.toolCallsUsed}/${task.maxToolCalls}',
                  style: t.small.copyWith(color: t.muted),
                ),
              ),
              if (task.budgetWarningReached)
                Text(
                  'Anggaran hampir habis',
                  style: t.small.copyWith(
                    color: t.orange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          if (widget.changeCount > 0) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(44, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.history_rounded, size: 16),
                label: Text(
                  widget.changeCount == 1
                      ? '1 change'
                      : '${widget.changeCount} changes',
                ),
                onPressed: widget.onViewChanges,
              ),
            ),
          ],
          if (!widget.isRunning) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    TaskPanel.statusLabel(task.status),
                    style: t.small.copyWith(
                      color: task.status == TaskStatus.done
                          ? t.green
                          : task.status == TaskStatus.needsHelp ||
                                task.status == TaskStatus.failed
                          ? t.red
                          : t.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (TaskPanel.canResume(task.status) && widget.onResume != null)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(44, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Lanjutkan'),
                    onPressed: widget.onResume,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<ToolCallRecord> _callsForStep(TaskStep step) {
    final ids = step.toolCallIds.toSet();
    return widget.toolCalls
        .where((record) => ids.contains(record.id) || record.stepId == step.id)
        .toList();
  }
}

class _TodoRow extends StatelessWidget {
  final TaskStep step;
  final List<ToolCallRecord> calls;
  final bool expanded;
  final VoidCallback onTap;
  final AppTokens t;

  const _TodoRow({
    required this.step,
    required this.calls,
    required this.expanded,
    required this.onTap,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (step.status) {
      TaskStepStatus.done => t.green,
      TaskStepStatus.active => t.accent,
      TaskStepStatus.failed => t.red,
      TaskStepStatus.skipped => t.muted,
      TaskStepStatus.pending => t.muted,
    };
    final statusIcon = switch (step.status) {
      TaskStepStatus.done => Icons.check_circle_rounded,
      TaskStepStatus.active => Icons.radio_button_checked_rounded,
      TaskStepStatus.failed => Icons.error_outline_rounded,
      TaskStepStatus.skipped => Icons.skip_next_rounded,
      TaskStepStatus.pending => Icons.radio_button_unchecked_rounded,
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(statusIcon, size: 16, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    step.title,
                    style: t.small.copyWith(
                      color: step.status == TaskStepStatus.done
                          ? t.muted
                          : t.text,
                      decoration: step.status == TaskStepStatus.done
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (calls.isNotEmpty) ...[
                  Text(
                    '${calls.length} call${calls.length == 1 ? '' : 's'}',
                    style: t.small.copyWith(color: t.faint),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: t.muted,
                  ),
                ],
              ],
            ),
            if (expanded && calls.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final call in calls)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            Icon(
                              call.status == ToolCallStatus.ok
                                  ? Icons.check_circle_outline_rounded
                                  : call.status == ToolCallStatus.running
                                  ? Icons.autorenew_rounded
                                  : Icons.error_outline_rounded,
                              size: 13,
                              color: call.status == ToolCallStatus.ok
                                  ? t.green
                                  : call.status == ToolCallStatus.running
                                  ? t.accent
                                  : t.red,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${call.toolName} — ${call.status.label}',
                                style: t.small.copyWith(
                                  fontFamily: 'monospace',
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

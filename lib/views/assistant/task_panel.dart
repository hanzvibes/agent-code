import 'package:flutter/material.dart';

import '../../models/agent_task.dart';
import '../../models/tool_call_record.dart';
import 'terminal.dart';

/// Active-task header in the Claude Code terminal look (Opsi A — full
/// terminal). The old surface card is gone: a flat section with the
/// task title in coral mono, a compact Plan/Agent/Auto switch, the
/// todo checklist as terminal circles (○/◐/●), and per-step tool
/// calls as mono rows. Behaviour is unchanged: Stop cancels the
/// running loop, a paused task can resume, steps expand to show their
/// calls, and the changes button opens the change history.
///
/// The budget line (rounds/tools) no longer lives here — it moved to
/// [TerminalStatusLine] above the prompt.
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
    final task = widget.task;
    final done = task.doneTodoCount;
    final total = task.totalTodoCount;
    final effectiveMode = widget.mode ?? task.mode;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: TerminalTokens.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: TerminalTokens.titleMono.copyWith(
                    color: TerminalTokens.accent,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (widget.onModeChanged == null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    effectiveMode.label,
                    style: TerminalTokens.monoSmall.copyWith(
                      color: TerminalTokens.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (widget.isRunning) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TerminalTokens.red,
                    side: BorderSide(
                      color: TerminalTokens.red.withValues(alpha: 0.5),
                    ),
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
            const SizedBox(height: 8),
            _ModeSwitch(
              mode: effectiveMode,
              onChanged: widget.onModeChanged!,
            ),
            const SizedBox(height: 6),
            Text(TaskPanel.modeHint(effectiveMode), style: TerminalTokens.small),
          ],
          if (total > 0) ...[
            const SizedBox(height: 8),
            Text(
              '$done/$total langkah',
              style: TerminalTokens.monoFaint,
            ),
            const SizedBox(height: 4),
            // Todo checklist (Batch 5 — desain D9): each step expands
            // to show the tool calls linked to it.
            for (final step in task.todos)
              _TodoRow(
                step: step,
                calls: _callsForStep(step),
                expanded: _expandedStepId == step.id,
                onTap: () => setState(() {
                  _expandedStepId = _expandedStepId == step.id
                      ? null
                      : step.id;
                }),
              ),
          ],
          if (widget.changeCount > 0) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: TerminalTokens.accent,
                  minimumSize: const Size(44, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
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
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    TaskPanel.statusLabel(task.status),
                    style: TerminalTokens.small.copyWith(
                      color: task.status == TaskStatus.done
                          ? TerminalTokens.green
                          : task.status == TaskStatus.needsHelp ||
                                task.status == TaskStatus.failed
                          ? TerminalTokens.red
                          : TerminalTokens.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (TaskPanel.canResume(task.status) && widget.onResume != null)
                  TerminalPrimaryButton(
                    label: 'Lanjutkan',
                    icon: Icons.play_arrow_rounded,
                    onPressed: widget.onResume,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
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

/// Compact terminal mode switch: `Plan / Agent / Auto` as tappable
/// mono labels, the active one in coral. Replaces the old
/// SegmentedButton; the callback contract is the same.
class _ModeSwitch extends StatelessWidget {
  final AgentMode mode;
  final ValueChanged<AgentMode> onChanged;

  const _ModeSwitch({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const modes = [AgentMode.plan, AgentMode.agent, AgentMode.auto];
    return Row(
      children: [
        for (var i = 0; i < modes.length; i++) ...[
          if (i > 0)
            const Text(
              ' / ',
              style: TextStyle(color: TerminalTokens.faint, fontSize: 13),
            ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(modes[i]),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                modes[i].label,
                style: TerminalTokens.mono.copyWith(
                  color: modes[i] == mode
                      ? TerminalTokens.accent
                      : TerminalTokens.muted,
                  fontWeight: modes[i] == mode
                      ? FontWeight.w700
                      : FontWeight.w400,
                  decoration: modes[i] == mode
                      ? TextDecoration.underline
                      : null,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TodoRow extends StatelessWidget {
  final TaskStep step;
  final List<ToolCallRecord> calls;
  final bool expanded;
  final VoidCallback onTap;

  const _TodoRow({
    required this.step,
    required this.calls,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (step.status) {
      TaskStepStatus.done => TerminalTokens.green,
      TaskStepStatus.active => TerminalTokens.accent,
      TaskStepStatus.failed => TerminalTokens.red,
      TaskStepStatus.skipped => TerminalTokens.muted,
      TaskStepStatus.pending => TerminalTokens.muted,
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
                    style: TerminalTokens.mono.copyWith(
                      color: step.status == TaskStepStatus.done
                          ? TerminalTokens.muted
                          : TerminalTokens.text,
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
                    style: TerminalTokens.monoFaint,
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: TerminalTokens.muted,
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
                              color: terminalStatusColor(call.status),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${call.toolName} — ${call.status.label}',
                                style: TerminalTokens.monoSmall,
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

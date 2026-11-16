import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../models/agent_task.dart';

/// Active-task card shown above the message list (Batch 1, desain D9).
///
/// Follows the visual pattern of `_RuntimeOutputCard` / `_StatusBanner`:
/// surface card, hairline border, small text. Shows the task title,
/// current mode, todo progress (x/y) and the budget used; the Stop
/// button cancels the running loop (not just the UI).
class TaskPanel extends StatelessWidget {
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

  const TaskPanel({
    super.key,
    required this.task,
    required this.isRunning,
    required this.onStop,
    this.changeCount = 0,
    this.onViewChanges,
    this.mode,
    this.onModeChanged,
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

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final done = task.doneTodoCount;
    final total = task.totalTodoCount;
    final progress = total == 0 ? 0.0 : done / total;
    final effectiveMode = mode ?? task.mode;

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
              if (onModeChanged == null)
                AppTag(effectiveMode.label, color: t.accent),
              if (isRunning) ...[
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
                  onPressed: onStop,
                ),
              ],
            ],
          ),
          if (onModeChanged != null) ...[
            const SizedBox(height: 10),
            SegmentedButton<AgentMode>(
              segments: const [
                ButtonSegment(value: AgentMode.plan, label: Text('Plan')),
                ButtonSegment(value: AgentMode.agent, label: Text('Agent')),
                ButtonSegment(value: AgentMode.auto, label: Text('Auto')),
              ],
              selected: {effectiveMode},
              onSelectionChanged: (selection) =>
                  onModeChanged!(selection.single),
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              modeHint(effectiveMode),
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
          if (changeCount > 0) ...[
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
                  changeCount == 1 ? '1 change' : '$changeCount changes',
                ),
                onPressed: onViewChanges,
              ),
            ),
          ],
          if (!isRunning) ...[
            const SizedBox(height: 4),
            Text(
              statusLabel(task.status),
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
          ],
        ],
      ),
    );
  }
}

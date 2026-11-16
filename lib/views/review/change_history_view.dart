import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/assistant_controller.dart';
import '../../controllers/review_controller.dart';
import '../../core/ui.dart';
import '../../models/checkpoint.dart';

/// Change history for the active agent task (Batch 2 — desain D2/D9).
///
/// Review is no longer a gate that stops the agent on every edit: the
/// agent's writes apply directly, and this screen lists what changed
/// per todo step — with the diff (built through [ReviewController], so
/// the existing unified-diff parser and rendering are reused) — and
/// Undo buttons per change, per step, and for the whole task.
class ChangeHistoryView extends StatelessWidget {
  final AssistantController ctrl;

  const ChangeHistoryView({super.key, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'Change history',
        showBack: true,
      ),
      body: Obx(() {
        // Rebuild when the history changes (write tool / undo).
        ctrl.changeHistoryRevision.value;
        final task = ctrl.activeTask.value;
        final checkpoints = ctrl.activeTaskCheckpoints;
        if (task == null || checkpoints.isEmpty) {
          return Center(child: Text('No changes yet.', style: t.caption));
        }

        final reviewCtrl = ReviewController();
        reviewCtrl.loadCheckpoints(checkpoints);
        final patchFiles = reviewCtrl.patchFiles;
        final groups = _groupByStep(checkpoints);
        final anyUndoable = checkpoints.any((cp) => !cp.undone);

        return Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(bottom: BorderSide(color: t.hairline)),
              ),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: 16, color: t.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${checkpoints.length} change${checkpoints.length == 1 ? '' : 's'} in this task',
                      style: t.bodyStrong.copyWith(fontSize: 13),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: anyUndoable
                        ? () => _confirmUndoAll(context)
                        : null,
                    child: const Text('Undo all'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: groups.length,
                itemBuilder: (ctx, groupIndex) {
                  final group = groups[groupIndex];
                  return _StepGroup(
                    ctrl: ctrl,
                    stepTitle: ctrl.stepTitleFor(group.stepId),
                    checkpoints: group.checkpoints,
                    patchFiles: [
                      for (final index in group.indices) patchFiles[index],
                    ],
                    t: t,
                    onUndoCheckpoint: (cp) => _undoOne(context, cp),
                    onUndoStep: () => _confirmUndoStep(context, group.stepId),
                  );
                },
              ),
            ),
          ],
        );
      }),
    );
  }

  /// Groups checkpoints by step, keeping first-seen step order.
  static List<_StepGroupData> _groupByStep(List<Checkpoint> checkpoints) {
    final groups = <_StepGroupData>[];
    final byStep = <String, _StepGroupData>{};
    for (var i = 0; i < checkpoints.length; i++) {
      final cp = checkpoints[i];
      var group = byStep[cp.stepId];
      if (group == null) {
        group = _StepGroupData(stepId: cp.stepId);
        byStep[cp.stepId] = group;
        groups.add(group);
      }
      group.indices.add(i);
      group.checkpoints.add(cp);
    }
    return groups;
  }

  Future<void> _undoOne(BuildContext context, Checkpoint cp) async {
    final error = await ctrl.undoCheckpoint(cp);
    if (error == null) {
      showToast('Change undone', cp.path, tone: ToastTone.success);
    } else {
      showToast('Could not undo', error, tone: ToastTone.error);
    }
  }

  Future<void> _confirmUndoStep(BuildContext context, String stepId) async {
    final ok = await confirmSheet(
      context,
      title: 'Undo this step?',
      message:
          'Restores every file this step changed to how it was before the step ran. Files you changed by hand afterwards are left alone.',
      confirmLabel: 'Undo step',
      destructive: true,
    );
    if (!ok) return;
    final error = await ctrl.undoStep(stepId);
    if (error == null) {
      showToast('Step undone', '', tone: ToastTone.success);
    } else {
      showToast('Could not undo step', error, tone: ToastTone.error);
    }
  }

  Future<void> _confirmUndoAll(BuildContext context) async {
    final ok = await confirmSheet(
      context,
      title: 'Undo all changes in this task?',
      message:
          'Restores every file the agent changed in this task to how it was before the task ran. Files you changed by hand afterwards are left alone.',
      confirmLabel: 'Undo all',
      destructive: true,
    );
    if (!ok) return;
    final error = await ctrl.undoWholeTask();
    if (error == null) {
      showToast('All changes undone', '', tone: ToastTone.success);
    } else {
      showToast('Could not undo all', error, tone: ToastTone.error);
    }
  }
}

class _StepGroupData {
  final String stepId;
  final List<int> indices = [];
  final List<Checkpoint> checkpoints = [];

  _StepGroupData({required this.stepId});
}

class _StepGroup extends StatelessWidget {
  final AssistantController ctrl;
  final String stepTitle;
  final List<Checkpoint> checkpoints;
  final List<PatchFile> patchFiles;
  final AppTokens t;
  final void Function(Checkpoint cp) onUndoCheckpoint;
  final VoidCallback onUndoStep;

  const _StepGroup({
    required this.ctrl,
    required this.stepTitle,
    required this.checkpoints,
    required this.patchFiles,
    required this.t,
    required this.onUndoCheckpoint,
    required this.onUndoStep,
  });

  @override
  Widget build(BuildContext context) {
    final anyUndoable = checkpoints.any((cp) => !cp.undone);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                stepTitle,
                style: t.bodyStrong.copyWith(fontSize: 13),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 36),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: anyUndoable ? onUndoStep : null,
              child: const Text('Undo step'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...List.generate(checkpoints.length, (i) {
          final cp = checkpoints[i];
          return _ChangeCard(
            checkpoint: cp,
            patchFile: patchFiles[i],
            t: t,
            onUndo: () => onUndoCheckpoint(cp),
          );
        }),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _ChangeCard extends StatelessWidget {
  final Checkpoint checkpoint;
  final PatchFile patchFile;
  final AppTokens t;
  final VoidCallback onUndo;

  const _ChangeCard({
    required this.checkpoint,
    required this.patchFile,
    required this.t,
    required this.onUndo,
  });

  String get _kindLabel {
    if (checkpoint.isDelete) return 'Deleted';
    if (checkpoint.isCreate) return 'Created';
    return 'Edited';
  }

  @override
  Widget build(BuildContext context) {
    final cp = checkpoint;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.hairline)),
            ),
            child: Row(
              children: [
                Icon(
                  cp.isDelete
                      ? Icons.delete_outline_rounded
                      : cp.isCreate
                      ? Icons.note_add_outlined
                      : Icons.edit_outlined,
                  size: 16,
                  color: t.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cp.path,
                    style: t.bodyStrong.copyWith(fontSize: 14),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: cp.undone ? t.fill : t.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    cp.undone ? 'Undone' : _kindLabel,
                    style: t.small.copyWith(
                      color: cp.undone ? t.muted : t.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: cp.undone ? null : onUndo,
                  child: const Text('Undo'),
                ),
              ],
            ),
          ),
          if (cp.isDelete)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Text(
                'Moved to trash — undo restores it. It is permanently deleted when the task finishes.',
                style: t.small.copyWith(color: t.muted),
              ),
            ),
          if (patchFile.hunks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('No visible changes', style: t.caption),
            )
          else
            ...patchFile.hunks.map(
              (hunk) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    color: t.fill,
                    child: Text(
                      hunk.header,
                      style: t.mono.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: t.muted,
                      ),
                    ),
                  ),
                  Container(
                    color: t.bg,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: hunk.lines.map((line) {
                          if (line.isEmpty) return const SizedBox.shrink();
                          final prefix = line[0];
                          final text = line.substring(1);
                          final Color? bg = prefix == '-'
                              ? t.red.withValues(alpha: 0.12)
                              : prefix == '+'
                              ? t.green.withValues(alpha: 0.12)
                              : null;
                          return Container(
                            color: bg,
                            padding: const EdgeInsets.symmetric(
                              vertical: 1,
                              horizontal: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 20,
                                  child: Text(
                                    prefix,
                                    style: t.mono.copyWith(
                                      color: prefix == '-'
                                          ? t.red
                                          : prefix == '+'
                                          ? t.green
                                          : t.faint,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(text, style: t.mono),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

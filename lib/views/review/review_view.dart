import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/review_controller.dart';
import '../../core/ui.dart';
import '../../utils/unified_patch.dart';

class ReviewView extends StatelessWidget {
  final ReviewController ctrl;
  final VoidCallback onApply;
  final VoidCallback onDiscard;

  const ReviewView({
    super.key,
    required this.ctrl,
    required this.onApply,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'Review changes',
        showBack: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          onPressed: onDiscard,
        ),
      ),
      body: Obx(() {
        if (ctrl.parseError.value.isNotEmpty) {
          return _ErrorPanel(
            error: ctrl.parseError.value,
            t: t,
            onDiscard: onDiscard,
          );
        }

        if (ctrl.patchFiles.isEmpty) {
          return Center(child: Text('No changes found.', style: t.caption));
        }

        return Column(
          children: [
            // Per-hunk selection controls bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(bottom: BorderSide(color: t.hairline)),
              ),
              child: Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 16, color: t.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${ctrl.selectedHunksCount} of ${ctrl.totalHunks} hunks selected',
                      style: t.bodyStrong.copyWith(fontSize: 13),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: ctrl.selectedHunksCount == ctrl.totalHunks
                        ? null
                        : () => ctrl.selectAllHunks(true),
                    child: const Text('Select all'),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: ctrl.selectedHunksCount == 0
                        ? null
                        : () => ctrl.selectAllHunks(false),
                    child: const Text('None'),
                  ),
                ],
              ),
            ),
            // Files and hunks list
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: ctrl.patchFiles.length,
                itemBuilder: (ctx, fileIdx) => _FileDiffCard(
                  ctrl: ctrl,
                  fileIndex: fileIdx,
                  patchFile: ctrl.patchFiles[fileIdx],
                  t: t,
                ),
              ),
            ),
            // Action bar at bottom
            _ActionBar(
              onApply: onApply,
              onDiscard: onDiscard,
              canApply: ctrl.hasSelectedHunks,
              t: t,
            ),
          ],
        );
      }),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  final String error;
  final AppTokens t;
  final VoidCallback onDiscard;
  const _ErrorPanel({
    required this.error,
    required this.t,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.red.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.error_outline, color: t.red, size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Could not apply patch',
                        style: t.bodyStrong.copyWith(color: t.red),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(error, style: t.caption),
                  const SizedBox(height: 8),
                  Text(
                    'The response will be shown as plain text. No files were modified.',
                    style: t.small,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(label: 'Dismiss', onPressed: onDiscard),
          ],
        ),
      ),
    );
  }
}

class _FileDiffCard extends StatelessWidget {
  final ReviewController ctrl;
  final int fileIndex;
  final PatchFile patchFile;
  final AppTokens t;

  const _FileDiffCard({
    required this.ctrl,
    required this.fileIndex,
    required this.patchFile,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final selectedCount = patchFile.hunks.where((h) => h.isSelected).length;
    final totalCount = patchFile.hunks.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.hairline)),
            ),
            child: Row(
              children: [
                Icon(Icons.difference_outlined, size: 16, color: t.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    patchFile.path,
                    style: t.bodyStrong.copyWith(fontSize: 14),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: selectedCount > 0
                        ? t.accent.withValues(alpha: 0.12)
                        : t.fill,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$selectedCount/$totalCount hunks',
                    style: t.small.copyWith(
                      color: selectedCount > 0 ? t.accent : t.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Hunks list
          if (patchFile.hunks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('No hunks available', style: t.caption),
            )
          else
            ...List.generate(patchFile.hunks.length, (hunkIdx) {
              final hunk = patchFile.hunks[hunkIdx];
              return _HunkItem(
                ctrl: ctrl,
                fileIndex: fileIndex,
                hunkIndex: hunkIdx,
                hunk: hunk,
                isLast: hunkIdx == patchFile.hunks.length - 1,
                t: t,
              );
            }),
        ],
      ),
    );
  }
}

class _HunkItem extends StatelessWidget {
  final ReviewController ctrl;
  final int fileIndex;
  final int hunkIndex;
  final PatchHunk hunk;
  final bool isLast;
  final AppTokens t;

  const _HunkItem({
    required this.ctrl,
    required this.fileIndex,
    required this.hunkIndex,
    required this.hunk,
    required this.isLast,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: t.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hunk header with checkbox
          InkWell(
            onTap: () => ctrl.toggleHunk(fileIndex, hunkIndex),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: hunk.isSelected ? t.fill : t.bg.withValues(alpha: 0.5),
              child: Row(
                children: [
                  Checkbox(
                    value: hunk.isSelected,
                    activeColor: t.accent,
                    onChanged: (_) => ctrl.toggleHunk(fileIndex, hunkIndex),
                  ),
                  Expanded(
                    child: Text(
                      hunk.header,
                      style: t.mono.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: hunk.isSelected ? t.text : t.muted,
                      ),
                    ),
                  ),
                  Text(
                    hunk.isSelected ? 'Included' : 'Excluded',
                    style: t.small.copyWith(
                      color: hunk.isSelected ? t.green : t.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // Hunk diff lines
          Container(
            color: hunk.isSelected ? t.bg : t.surfacePressed,
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
                  return _DiffLine(prefix: prefix, text: text, color: bg, t: t);
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  final String prefix;
  final String text;
  final Color? color;
  final AppTokens t;
  const _DiffLine({
    required this.prefix,
    required this.text,
    required this.color,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 8),
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
  }
}

class _ActionBar extends StatelessWidget {
  final VoidCallback onApply;
  final VoidCallback onDiscard;
  final bool canApply;
  final AppTokens t;

  const _ActionBar({
    required this.onApply,
    required this.onDiscard,
    required this.canApply,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: t.bg,
        border: Border(top: BorderSide(color: t.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: onDiscard,
                child: const Text('Discard'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryButton(
                label: 'Apply changes',
                onPressed: canApply ? onApply : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

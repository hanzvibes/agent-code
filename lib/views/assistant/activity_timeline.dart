import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../models/tool_call_record.dart';

/// Activity timeline (Batch 5 — desain D9): one card per tool call,
/// replacing the single runtime-output card.
///
/// Follows the visual pattern of `_RuntimeOutputCard` / `_StatusBanner`:
/// surface card, hairline border, small text. Each card shows the
/// tool name, its status (running / done / failed / denied /
/// cancelled), a one-line summary, and expands to show the arguments
/// plus the (smart-trimmed) output.
class ActivityTimeline extends StatelessWidget {
  final List<ToolCallRecord> records;
  final bool isRunning;

  const ActivityTimeline({
    super.key,
    required this.records,
    required this.isRunning,
  });

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return const SizedBox.shrink();
    final t = AppTokens.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(10),
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
              Icon(Icons.timeline_rounded, size: 16, color: t.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Activity',
                  style: t.small.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${records.length} call${records.length == 1 ? '' : 's'}',
                style: t.small.copyWith(color: t.muted),
              ),
              if (isRunning) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.7),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: records.length,
              itemBuilder: (_, index) =>
                  _ToolCallCard(record: records[index], t: t),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  final ToolCallRecord record;
  final AppTokens t;

  const _ToolCallCard({required this.record, required this.t});

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final t = widget.t;
    final statusColor = _statusColor(record.status, t);
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: t.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (record.status == ToolCallStatus.running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _statusIcon(record.status),
                    size: 16,
                    color: statusColor,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.toolName,
                    style: t.small.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                AppTag(record.backend, color: t.muted),
                const SizedBox(width: 6),
                Text(
                  record.status.label,
                  style: t.small.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: t.muted,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              record.resultSummary.isEmpty
                  ? 'No summary yet.'
                  : record.resultSummary,
              style: t.small.copyWith(color: t.muted),
              maxLines: _expanded ? null : 2,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (!_expanded && record.durationMs > 0)
              Text(
                '${record.durationMs} ms',
                style: t.small.copyWith(color: t.faint),
              ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              Text(
                'Arguments',
                style: t.small.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              SelectableText(
                _prettyJson(record.arguments),
                style: t.small.copyWith(fontFamily: 'monospace'),
              ),
              if (record.resultFull != null &&
                  record.resultFull!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Output',
                  style: t.small.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  _smartTrim(record.resultFull!),
                  style: t.small.copyWith(fontFamily: 'monospace'),
                ),
              ],
              if (record.durationMs > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${record.durationMs} ms • ${_timeLabel(record.at)}',
                  style: t.small.copyWith(color: t.faint),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  static Color _statusColor(ToolCallStatus status, AppTokens t) =>
      switch (status) {
        ToolCallStatus.running => t.accent,
        ToolCallStatus.ok => t.green,
        ToolCallStatus.error => t.red,
        ToolCallStatus.denied => t.orange,
        ToolCallStatus.cancelled => t.muted,
      };

  static IconData _statusIcon(ToolCallStatus status) => switch (status) {
    ToolCallStatus.running => Icons.autorenew_rounded,
    ToolCallStatus.ok => Icons.check_circle_outline_rounded,
    ToolCallStatus.error => Icons.error_outline_rounded,
    ToolCallStatus.denied => Icons.block_rounded,
    ToolCallStatus.cancelled => Icons.cancel_outlined,
  };

  static String _prettyJson(Map<String, dynamic> arguments) {
    try {
      return const JsonEncoder.withIndent('  ').convert(arguments);
    } catch (_) {
      return arguments.toString();
    }
  }

  /// Smart-trim of a full result (desain D1, same idea as the
  /// engine's prompt trim): short outputs pass through; long ones
  /// keep the head and the tail instead of the first 16 KB.
  static String _smartTrim(String output) {
    const maxChars = 4000;
    if (output.length <= maxChars) return output;
    const headChars = 1200;
    const tailChars = 2400;
    return '${output.substring(0, headChars)}\n'
        '…[trimmed ${output.length - headChars - tailChars} characters]…\n'
        '${output.substring(output.length - tailChars)}';
  }

  static String _timeLabel(DateTime at) {
    final hour = at.hour.toString().padLeft(2, '0');
    final minute = at.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

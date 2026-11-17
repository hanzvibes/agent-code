import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/tool_call_record.dart';
import 'terminal.dart';

/// Activity timeline (Batch 5 — desain D9) in the Claude Code terminal
/// look (Opsi A — full terminal): no card, no "Activity" header —
/// each tool call is one flat mono line with a status dot (spinner
/// while running, green check when done), and tapping expands it to
/// show the arguments plus the (smart-trimmed) output, each output
/// line prefixed with `⎿` like Claude Code.
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
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: records.length,
          itemBuilder: (_, index) =>
              _TerminalToolRow(record: records[index]),
        ),
      ),
    );
  }
}

class _TerminalToolRow extends StatefulWidget {
  final ToolCallRecord record;

  const _TerminalToolRow({required this.record});

  @override
  State<_TerminalToolRow> createState() => _TerminalToolRowState();
}

class _TerminalToolRowState extends State<_TerminalToolRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final statusColor = terminalStatusColor(record.status);
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: record.status == ToolCallStatus.running
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: TerminalTokens.accent,
                          ),
                        )
                      : Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 3),
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                Text(
                  record.toolName,
                  style: TerminalTokens.mono.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  ' — ',
                  style: TerminalTokens.mono.copyWith(
                    color: TerminalTokens.muted,
                  ),
                ),
                Expanded(
                  child: Text(
                    record.resultSummary.isEmpty
                        ? 'No summary yet.'
                        : record.resultSummary,
                    style: TerminalTokens.mono.copyWith(
                      color: TerminalTokens.muted,
                    ),
                    maxLines: _expanded ? null : 2,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  record.status.label,
                  style: TerminalTokens.monoSmall.copyWith(
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: TerminalTokens.muted,
                ),
              ],
            ),
            if (!_expanded && record.durationMs > 0)
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Text(
                  '${record.durationMs} ms',
                  style: TerminalTokens.monoFaint,
                ),
              ),
            if (_expanded) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Arguments',
                      style: TerminalTokens.monoSmall.copyWith(
                        fontWeight: FontWeight.w600,
                        color: TerminalTokens.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      _prettyJson(record.arguments),
                      style: TerminalTokens.monoSmall,
                    ),
                    if (record.resultFull != null &&
                        record.resultFull!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Output',
                        style: TerminalTokens.monoSmall.copyWith(
                          fontWeight: FontWeight.w600,
                          color: TerminalTokens.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        _prefixOutput(_smartTrim(record.resultFull!)),
                        style: TerminalTokens.monoSmall,
                      ),
                    ],
                    if (record.durationMs > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${record.durationMs} ms • ${_timeLabel(record.at)}',
                        style: TerminalTokens.monoFaint,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _prettyJson(Map<String, dynamic> arguments) {
    try {
      return const JsonEncoder.withIndent('  ').convert(arguments);
    } catch (_) {
      return arguments.toString();
    }
  }

  /// Claude Code prefixes each output line with `⎿`.
  static String _prefixOutput(String output) =>
      output.split('\n').map((line) => '⎿ $line').join('\n');

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

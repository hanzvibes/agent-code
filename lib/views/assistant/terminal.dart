import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/agent_task.dart';
import '../../models/tool_call_record.dart';

/// Claude Code terminal palette for the Assistant screen (Opsi A — full
/// terminal). Unlike [AppTokens], this palette is NOT brightness-driven:
/// the chat screen is always a dark warm terminal, in light mode too,
/// so the assistant text, tool lines and code stay readable on the
/// same background. Every foreground colour meets >= 4.5:1 against
/// [bg] (see test/chat_terminal_test.dart).
class TerminalTokens {
  static const Color bg = Color(0xFF1B1A17);
  static const Color sheetBg = Color(0xFF232220);
  static const Color text = Color(0xFFEDEAE3);
  static const Color muted = Color(0xFFA39E93);
  static const Color faint = Color(0xFF8A857A);

  /// Claude coral — the one accent colour of the terminal look.
  static const Color accent = Color(0xFFD97757);
  static const Color green = Color(0xFF4ADE80);
  static const Color red = Color(0xFFF87171);
  static const Color orange = Color(0xFFE8A33D);
  static const Color hairline = Color(0x14FFFFFF);

  static TextStyle get titleMono => GoogleFonts.firaCode(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: text,
  );
  static TextStyle get body => GoogleFonts.inter(
    fontSize: 15,
    height: 1.4,
    letterSpacing: -0.15,
    color: text,
  );
  static TextStyle get caption => GoogleFonts.inter(
    fontSize: 13,
    height: 1.35,
    color: muted,
  );
  static TextStyle get small => GoogleFonts.inter(fontSize: 12, color: muted);
  static TextStyle get mono => GoogleFonts.firaCode(
    fontSize: 13,
    color: text,
  );
  static TextStyle get monoSmall => GoogleFonts.firaCode(
    fontSize: 12,
    color: muted,
  );
  static TextStyle get monoFaint => GoogleFonts.firaCode(
    fontSize: 12,
    color: faint,
  );
}

/// Status colour for a tool call in the terminal look: running is the
/// coral accent, ok is green, error red, denied amber, cancelled muted.
Color terminalStatusColor(ToolCallStatus status) => switch (status) {
  ToolCallStatus.running => TerminalTokens.accent,
  ToolCallStatus.ok => TerminalTokens.green,
  ToolCallStatus.error => TerminalTokens.red,
  ToolCallStatus.denied => TerminalTokens.orange,
  ToolCallStatus.cancelled => TerminalTokens.muted,
};

/// Thin status line above the prompt, Claude Code style:
/// `[profile] • Ronde x/25 • Tool y/60`, with an amber budget warning
/// when the active task has used 80% of its budget. With no active
/// task it shows just the profile name; with no profile, 'No provider'.
class TerminalStatusLine extends StatelessWidget {
  final String? profileName;
  final AgentTask? task;

  const TerminalStatusLine({super.key, this.profileName, this.task});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      profileName ?? 'No provider',
      if (task != null)
        'Ronde ${task!.roundsUsed}/${task!.maxRounds} • '
        'Tool ${task!.toolCallsUsed}/${task!.maxToolCalls}',
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' • '),
              style: TerminalTokens.monoFaint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (task != null && task!.budgetWarningReached)
            Text(
              'Anggaran hampir habis',
              style: TerminalTokens.monoSmall.copyWith(
                color: TerminalTokens.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// Terminal prompt bar: a coral `>` prompt, a borderless mono text
/// field, and a send/stop icon button. Replaces the old card-style
/// composer; the callbacks and restoring behaviour are unchanged.
class TerminalPromptBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isRestoringSession;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  const TerminalPromptBar({
    super.key,
    required this.controller,
    required this.isLoading,
    required this.isRestoringSession,
    required this.onSend,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: TerminalTokens.bg,
        border: Border(top: BorderSide(color: TerminalTokens.hairline)),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '>',
                style: GoogleFonts.firaCode(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: TerminalTokens.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !isRestoringSession,
                maxLines: 4,
                minLines: 1,
                style: GoogleFonts.firaCode(
                  fontSize: 14,
                  color: TerminalTokens.text,
                ),
                cursorColor: TerminalTokens.accent,
                decoration: InputDecoration(
                  hintText: isRestoringSession
                      ? 'Loading saved conversation…'
                      : 'Ask about your code…',
                  hintStyle: GoogleFonts.firaCode(
                    fontSize: 14,
                    color: TerminalTokens.faint,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 4),
            if (isLoading)
              IconButton(
                tooltip: 'Stop',
                onPressed: onCancel,
                icon: const Icon(
                  Icons.stop_rounded,
                  color: TerminalTokens.red,
                  size: 24,
                ),
              )
            else
              IconButton(
                tooltip: 'Send',
                onPressed: isRestoringSession ? null : onSend,
                icon: Icon(
                  Icons.arrow_upward_rounded,
                  color: isRestoringSession
                      ? TerminalTokens.faint
                      : TerminalTokens.accent,
                  size: 24,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Coral filled button for the terminal look — used by the approval
/// sheets, where the shared [PrimaryButton] would render blue.
class TerminalPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  const TerminalPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: enabled
          ? TerminalTokens.accent
          : TerminalTokens.accent.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: Colors.white),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

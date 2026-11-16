import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;

import '../models/agent_task.dart';
import 'project_scaffolder.dart';

/// What a permission check decided (Batch 4 — desain D6).
enum PermissionDecision {
  /// Run it now, no questions asked.
  allowed,

  /// Ask the user first (dialog); the user may allow once, allow
  /// always for this workspace, or deny.
  needsApproval,

  /// Never run it in this mode. No dialog is shown.
  denied,
}

/// Answer from the approval dialog (Batch 4 — desain D6, pola
/// `android_action` + "selalu izinkan perintah ini di workspace ini").
enum PermissionApproval {
  /// Run this one call, then ask again next time.
  allowOnce,

  /// Run this call and remember the command as always allowed in
  /// this workspace (stored per workspace, see [WorkspacePermissions]).
  allowAlways,

  /// Do not run it. The denial is reported back to the model as a
  /// failed tool result.
  deny,
}

/// What the approval dialog shows for one action.
class PermissionApprovalRequest {
  final String title;
  final String description;

  /// The exact thing that will run (command text, file path, ...).
  final String preview;

  const PermissionApprovalRequest({
    required this.title,
    required this.description,
    required this.preview,
  });
}

/// Result of one permission check.
class PermissionCheck {
  final PermissionDecision decision;

  /// Human-readable reason, shown to the user and fed back to the
  /// model when the call is refused or needs approval.
  final String reason;

  /// Dialog content when [decision] is [PermissionDecision.needsApproval].
  /// Null for `android_action`: that tool shows its own existing
  /// approval sheet for the exact payload.
  final PermissionApprovalRequest? approvalRequest;

  const PermissionCheck({
    required this.decision,
    required this.reason,
    this.approvalRequest,
  });

  bool get isAllowed => decision == PermissionDecision.allowed;
  bool get needsApproval => decision == PermissionDecision.needsApproval;
  bool get isDenied => decision == PermissionDecision.denied;
}

/// Mode + standing approvals saved for one workspace (Batch 4 —
/// desain D6: "Izin tersimpan per workspace (Hive, di TaskStore)").
/// TaskStore (Batch 5) does not exist yet, so this lives in its own
/// Hive box (`agent_permissions`, one JSON value per workspace path —
/// the same pattern [ChatRepository] uses for chat sessions) instead
/// of depending on it.
class WorkspacePermissions {
  /// Mode the user picked for this workspace. New workspaces default
  /// to [AgentMode.agent] (keputusan Rehan 2026-11-16).
  final AgentMode mode;

  /// Normalized commands the user marked "always allow in this
  /// workspace". A standing permission overrides the pattern checks
  /// (including the hard-deny list): it is an explicit user decision
  /// for that exact command in this workspace.
  final List<String> alwaysAllowedCommands;

  const WorkspacePermissions({
    this.mode = AgentMode.agent,
    this.alwaysAllowedCommands = const [],
  });

  factory WorkspacePermissions.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'];
    final mode = modeName is String
        ? AgentMode.values.firstWhere(
            (candidate) => candidate.name == modeName,
            orElse: () => AgentMode.agent,
          )
        : AgentMode.agent;
    final commands = json['alwaysAllowedCommands'];
    return WorkspacePermissions(
      mode: mode,
      alwaysAllowedCommands: commands is List
          ? commands.whereType<String>().toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'alwaysAllowedCommands': alwaysAllowedCommands,
  };

  /// True when [command] (normalized) is on the always-allow list.
  bool allowsCommand(String command) => alwaysAllowedCommands.contains(
    PermissionService.normalizeCommand(command),
  );

  WorkspacePermissions withMode(AgentMode newMode) => WorkspacePermissions(
    mode: newMode,
    alwaysAllowedCommands: alwaysAllowedCommands,
  );

  WorkspacePermissions allowingCommand(String command) {
    final normalized = PermissionService.normalizeCommand(command);
    if (normalized.isEmpty || alwaysAllowedCommands.contains(normalized)) {
      return this;
    }
    return WorkspacePermissions(
      mode: mode,
      alwaysAllowedCommands: [...alwaysAllowedCommands, normalized],
    );
  }
}

/// Mode + permission rules for agent tool calls (Batch 4 — desain D6).
///
/// Rules (see the D6 table):
/// * **Plan** — read-only: list/read/search/probe/detect run; every
///   write tool and every command is denied (the user approves the
///   plan by switching mode, not per call). `android_action` still
///   asks for approval per call.
/// * **Agent** (default) — reads, writes and read/test/build commands
///   run automatically; destructive, network-out, install and other
///   dangerous commands ask for approval first.
/// * **Auto** (trusted workspaces only) — everything runs automatically
///   except the hard-deny list, which still asks for approval.
/// * **Hard-deny list** (never automatic, any mode): `rm -rf`, `mkfs`,
///   `dd`, `format`, writes outside the workspace, `curl|sh`,
///   credentials in the command.
///
/// The checks are simple regex/word heuristics over the command text,
/// not a sandbox: a command still runs with the app's permissions,
/// and a cleverly disguised command can slip past them. The design
/// says this honestly (D6) and this service does not pretend
/// otherwise. A standing per-workspace permission ("always allow this
/// command") overrides the pattern checks for that exact command.
class PermissionService {
  static const String boxName = 'agent_permissions';

  final Box? _overrideBox;

  /// In-memory cache of loaded workspace permissions, keyed by
  /// workspace path, so repeated checks do not re-read Hive.
  final Map<String, WorkspacePermissions> _cache = {};

  PermissionService({Box? box}) : _overrideBox = box;

  static Future<void> openBox() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  /// Null when Hive is not available (unit tests without an open box,
  /// or a box that failed to open): persistence becomes a no-op and
  /// callers get the defaults instead of an exception.
  Box? get _box {
    try {
      if (_overrideBox != null) return _overrideBox;
      if (!Hive.isBoxOpen(boxName)) return null;
      return Hive.box(boxName);
    } catch (_) {
      return null;
    }
  }

  /// Permissions saved for [workspacePath] (default: Agent mode, no
  /// standing permissions). Empty path returns the defaults.
  Future<WorkspacePermissions> permissionsFor(String workspacePath) async {
    if (workspacePath.isEmpty) return const WorkspacePermissions();
    final cached = _cache[workspacePath];
    if (cached != null) return cached;
    final box = _box;
    var stored = const WorkspacePermissions();
    if (box != null) {
      try {
        final raw = box.get(workspacePath);
        if (raw is String) {
          final parsed = jsonDecode(raw);
          if (parsed is Map<String, dynamic>) {
            stored = WorkspacePermissions.fromJson(parsed);
          }
        }
      } catch (_) {
        stored = const WorkspacePermissions();
      }
    }
    _cache[workspacePath] = stored;
    return stored;
  }

  Future<void> savePermissions(
    String workspacePath,
    WorkspacePermissions permissions,
  ) async {
    if (workspacePath.isEmpty) return;
    _cache[workspacePath] = permissions;
    final box = _box;
    if (box == null) return;
    try {
      await box.put(workspacePath, jsonEncode(permissions.toJson()));
    } catch (_) {
      // Persistence failure must not block using the assistant; the
      // in-memory cache still holds the choice for this session.
    }
  }

  Future<void> setMode(String workspacePath, AgentMode mode) async {
    final current = await permissionsFor(workspacePath);
    await savePermissions(workspacePath, current.withMode(mode));
  }

  Future<void> allowCommandAlways(String workspacePath, String command) async {
    final current = await permissionsFor(workspacePath);
    await savePermissions(workspacePath, current.allowingCommand(command));
  }

  // ── Tool-call checks ──────────────────────────────────────────────

  /// Read-only workspace tools (allowed in every mode).
  static const Set<String> readToolNames = {
    'list_project_files',
    'read_project_file',
    'search_project',
    'detect_project',
    'probe_toolchain',
  };

  /// Checks one tool call before it runs. [args] is the decoded
  /// arguments map (empty when the call had none/invalid JSON).
  /// [permissions] supplies the standing always-allow list for the
  /// workspace (null = none).
  PermissionCheck checkToolCall({
    required AgentMode mode,
    required String toolName,
    Map<String, dynamic> args = const {},
    required String workspaceRoot,
    WorkspacePermissions? permissions,
  }) {
    if (readToolNames.contains(toolName)) {
      return const PermissionCheck(
        decision: PermissionDecision.allowed,
        reason: 'Read-only tool.',
      );
    }
    if (toolName == 'android_action') {
      // Always asks for approval of the exact payload, in every mode
      // (desain D6: Android actions stay always-approve). The dialog
      // is the existing android_action sheet, so no
      // [PermissionApprovalRequest] is attached here.
      return const PermissionCheck(
        decision: PermissionDecision.needsApproval,
        reason:
            'Android actions always need your approval before the phone opens anything.',
      );
    }
    if (toolName == 'run_project_command') {
      final command = args['command'];
      if (command is! String || command.trim().isEmpty) {
        return const PermissionCheck(
          decision: PermissionDecision.denied,
          reason: 'Missing or invalid "command" argument.',
        );
      }
      return checkCommand(
        mode: mode,
        command: command,
        workspaceRoot: workspaceRoot,
        workingDirectory: args['working_directory'] is String
            ? args['working_directory'] as String
            : null,
        permissions: permissions,
      );
    }
    if (toolName == 'scaffold_project') {
      // General harness (D11): scaffolding creates a sub-project
      // and may run install commands, so it is checked like a
      // command — Plan mode denies it, Agent asks for installs,
      // Auto runs them (except the hard-deny list).
      final stackRaw = args['stack'];
      final stack = stackRaw is String
          ? ScaffoldStack.parse(stackRaw)
          : null;
      if (stack == null) {
        return const PermissionCheck(
          decision: PermissionDecision.denied,
          reason: 'Unknown stack (node, python or generic).',
        );
      }
      final pathRaw = args['path'];
      if (pathRaw is! String ||
          !ScaffoldPlan.isSafeRelativePath(pathRaw)) {
        return const PermissionCheck(
          decision: PermissionDecision.denied,
          reason:
              'Scaffold path must be a safe workspace-relative folder '
              '(no leading slash, no dot or parent segments).',
        );
      }
      final packages = <String>[];
      if (args['packages'] is List) {
        for (final item in (args['packages'] as List)) {
          if (item is! String ||
              !ScaffoldPlan.isSafePackageName(item.trim())) {
            return PermissionCheck(
              decision: PermissionDecision.denied,
              reason: 'Unsafe package name: "$item".',
            );
          }
          packages.add(item.trim());
        }
      }
      if (mode == AgentMode.plan) {
        return const PermissionCheck(
          decision: PermissionDecision.denied,
          reason:
              'Plan mode is read-only: scaffolding creates files and '
              'runs commands. Switch to Agent mode to scaffold.',
        );
      }
      PermissionCheck? needsApproval;
      for (final command in ScaffoldPlan.initCommands(stack, packages)) {
        final check = checkCommand(
          mode: mode,
          command: command,
          workspaceRoot: workspaceRoot,
          workingDirectory: pathRaw,
          permissions: permissions,
        );
        if (check.decision == PermissionDecision.denied) return check;
        needsApproval ??= check.decision == PermissionDecision.needsApproval
            ? check
            : null;
      }
      return needsApproval ??
          const PermissionCheck(
            decision: PermissionDecision.allowed,
            reason: 'Scaffold in Agent/Auto mode.',
          );
    }
    if (toolName == 'write_file' ||
        toolName == 'edit_file' ||
        toolName == 'create_file' ||
        toolName == 'delete_file') {
      if (mode == AgentMode.plan) {
        return const PermissionCheck(
          decision: PermissionDecision.denied,
          reason:
              'Plan mode is read-only: file changes are not applied. '
              'Switch to Agent mode to let the agent change files, or '
              'ask for a plan instead of an edit.',
        );
      }
      return const PermissionCheck(
        decision: PermissionDecision.allowed,
        reason: 'File write in Agent/Auto mode.',
      );
    }
    return PermissionCheck(
      decision: PermissionDecision.denied,
      reason:
          'Tool "$toolName" is not permitted: it is not a known workspace tool.',
    );
  }

  // ── Command checks ────────────────────────────────────────────────

  /// Collapses whitespace so "always allow" compares commands by
  /// their text, ignoring extra spaces and line breaks.
  static String normalizeCommand(String command) =>
      command.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Checks one shell command before it runs. [workingDirectory] is
  /// the project-relative working directory the command runs in
  /// (null/empty = workspace root).
  PermissionCheck checkCommand({
    required AgentMode mode,
    required String command,
    required String workspaceRoot,
    String? workingDirectory,
    WorkspacePermissions? permissions,
  }) {
    final normalized = normalizeCommand(command);
    if (normalized.isEmpty) {
      return const PermissionCheck(
        decision: PermissionDecision.denied,
        reason: 'Command cannot be empty.',
      );
    }
    // An explicit standing permission for this exact command in this
    // workspace wins over every pattern below.
    if (permissions != null && permissions.allowsCommand(normalized)) {
      return const PermissionCheck(
        decision: PermissionDecision.allowed,
        reason: 'Always allowed in this workspace.',
      );
    }
    final cwd = _resolveCwd(workspaceRoot, workingDirectory);
    final hardReason = hardDenyReason(normalized, workspaceRoot, cwd);
    if (hardReason != null) {
      if (mode == AgentMode.plan) {
        return PermissionCheck(
          decision: PermissionDecision.denied,
          reason: 'Plan mode is read-only: commands never run. $hardReason',
        );
      }
      return PermissionCheck(
        decision: PermissionDecision.needsApproval,
        reason:
            'This command matches the blocked list and never runs automatically: $hardReason',
        approvalRequest: PermissionApprovalRequest(
          title: 'Allow this blocked command?',
          description:
              'This command matches the blocked list ($hardReason). '
              'It never runs automatically in any mode — only run it if '
              'you understand exactly what it does.',
          preview: normalized,
        ),
      );
    }
    if (mode == AgentMode.plan) {
      return const PermissionCheck(
        decision: PermissionDecision.denied,
        reason:
            'Plan mode is read-only: commands never run. Switch to Agent '
            'mode to let the agent run commands, or ask for a plan.',
      );
    }
    final dangerousReason = _dangerousReason(normalized);
    if (dangerousReason != null) {
      if (mode == AgentMode.agent) {
        return PermissionCheck(
          decision: PermissionDecision.needsApproval,
          reason: dangerousReason,
          approvalRequest: PermissionApprovalRequest(
            title: 'Allow this command?',
            description: dangerousReason,
            preview: normalized,
          ),
        );
      }
      // Auto mode: dangerous (but not hard-deny) commands run.
      return const PermissionCheck(
        decision: PermissionDecision.allowed,
        reason: 'Auto mode: dangerous commands run automatically.',
      );
    }
    return const PermissionCheck(
      decision: PermissionDecision.allowed,
      reason: 'Safe command.',
    );
  }

  /// Absolute working directory for [workingDirectory]
  /// (project-relative, empty = root). Falls back to the root when the
  /// relative path cannot be resolved safely.
  static String _resolveCwd(String workspaceRoot, String? workingDirectory) {
    final relative = (workingDirectory ?? '').trim();
    if (relative.isEmpty || relative == '.') return workspaceRoot;
    final normalized = relative.replaceAll('\\', '/');
    if (normalized.startsWith('/') || normalized.contains('..')) {
      return workspaceRoot;
    }
    if (workspaceRoot.isEmpty) return '';
    return p.normalize(p.join(workspaceRoot, normalized));
  }

  // ── Hard-deny list (never automatic, any mode) ────────────────────

  /// Reason the command matches the hard-deny list (desain D6), or
  /// null when it does not. Pure and static so tests can call it
  /// without a service instance.
  static String? hardDenyReason(
    String command,
    String workspaceRoot,
    String cwd,
  ) {
    final normalized = normalizeCommand(command);
    // Pipe-to-shell downloads: curl/wget straight into a shell.
    if (_pipeToShell.hasMatch(normalized)) {
      return 'downloading a script and piping it straight into a shell '
          '(curl/wget | sh)';
    }
    // Credentials baked into the command line.
    if (_credentialPattern.hasMatch(normalized)) {
      return 'the command contains a credential (token, password, '
          'API key, or authorization header)';
    }
    for (final segment in _splitSegments(normalized)) {
      final body = _stripLeadingSudo(segment);
      final firstWord = _firstWord(body);
      if (firstWord == null) continue;
      if (firstWord == 'rm') {
        final flags = _flagLetters(body);
        if (flags.contains('r') && flags.contains('f')) {
          return 'rm with recursive + force flags (rm -rf)';
        }
        if (flags.contains('R') && flags.contains('f')) {
          return 'rm with recursive + force flags (rm -rf)';
        }
      }
      if (firstWord.startsWith('mkfs')) {
        return 'filesystem creation (mkfs)';
      }
      if (firstWord == 'dd') {
        return 'raw disk copy (dd)';
      }
      if (firstWord == 'format') {
        return 'disk format (format)';
      }
      final outside = _writesOutsideWorkspace(body, workspaceRoot, cwd);
      if (outside != null) return outside;
    }
    return null;
  }

  /// Reason the command is dangerous (asks for approval in Agent
  /// mode, runs in Auto mode), or null when it looks safe.
  static String? _dangerousReason(String command) {
    for (final segment in _splitSegments(command)) {
      final body = _stripLeadingSudo(segment);
      final firstWord = _firstWord(body);
      if (firstWord == null) continue;
      if (body != segment.trimLeft()) {
        // `sudo ...`: the real command underneath was already judged
        // above, but running anything as superuser still needs
        // approval in Agent mode.
        return 'running as superuser (sudo) needs approval in Agent mode';
      }
      if (_installPattern.hasMatch(body)) {
        return 'package installation needs approval in Agent mode '
            '(npm/pip/apt/pkg/brew/gem/cargo/go/composer install)';
      }
      if (_networkOutPattern.hasMatch(body)) {
        return 'sending data out (POST/upload/scp/ssh) needs approval '
            'in Agent mode';
      }
      if (firstWord == 'rm') {
        final flags = _flagLetters(body);
        if (flags.contains('r') || flags.contains('R')) {
          return 'recursive delete (rm -r) needs approval in Agent mode';
        }
      }
      if (firstWord == 'chmod' && RegExp(r'\b777\b').hasMatch(body)) {
        return 'chmod 777 needs approval in Agent mode';
      }
      if (firstWord == 'chown') {
        return 'changing file ownership (chown) needs approval in Agent mode';
      }
      if (firstWord == 'kill' ||
          firstWord == 'reboot' ||
          firstWord == 'shutdown' ||
          firstWord == 'poweroff' ||
          firstWord == 'halt') {
        return 'stopping processes or the device ($firstWord) needs '
            'approval in Agent mode';
      }
      if (firstWord == 'git') {
        if (RegExp(r'\bclean\b[^|;&]*-[a-z]*f').hasMatch(body)) {
          return 'git clean -f deletes untracked files and needs '
              'approval in Agent mode';
        }
        if (RegExp(r'\breset\b[^|;&]*--hard\b').hasMatch(body)) {
          return 'git reset --hard discards changes and needs approval '
              'in Agent mode';
        }
      }
      if (RegExp(r'\bfind\b[^|;&]*-delete\b').hasMatch(body) ||
          RegExp(r'\bfind\b[^|;&]*-exec\b[^|;&]*\brm\b').hasMatch(body)) {
        return 'mass delete via find needs approval in Agent mode';
      }
      if (firstWord == 'eval') {
        return 'eval runs arbitrary text as code and needs approval in '
            'Agent mode';
      }
      if (RegExp(r'\|\s*(sh|bash|zsh|dash)\b').hasMatch(body)) {
        return 'piping output into a shell needs approval in Agent mode';
      }
    }
    return null;
  }

  /// `curl <url> | sh` (and wget variants): the classic
  /// download-and-execute. The generic pipe-to-shell case (without a
  /// downloader) is only "dangerous", not hard-deny.
  static final RegExp _pipeToShell = RegExp(
    r'\b(curl|wget)\b[^|;&]*\|\s*(sh|bash|zsh|dash)\b',
  );

  /// Secrets on the command line: named secret flags, Authorization
  /// headers, and well-known token shapes.
  static final RegExp _credentialPattern = RegExp(
    r'(\b(api[_-]?key|apikey|password|passwd|secret|token|auth)\s*=\s*\S+'
    r'|Authorization\s*:\s*\S+'
    r'|\b(ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+)\b)',
    caseSensitive: false,
  );

  static final RegExp _installPattern = RegExp(
    r'\b((npm|npx)\s+(install|i|ci)\b'
    r'|yarn\s+add\b'
    r'|pnpm\s+(add|install)\b'
    r'|pip3?\s+install\b'
    r'|apt(-get)?\s+install\b'
    r'|pkg\s+install\b'
    r'|brew\s+install\b'
    r'|gem\s+install\b'
    r'|cargo\s+install\b'
    r'|go\s+install\b'
    r'|composer\s+(require|install)\b)',
  );

  static final RegExp _networkOutPattern = RegExp(
    r'\b(curl\b[^|;&]*(-d\b|--data|--data-raw|--data-binary|--form|-F\b|-T\b|--upload-file|-X\s+(POST|PUT|PATCH|DELETE))'
    r'|wget\b[^|;&]*--post-(data|file)\b'
    r'|scp\b'
    r'|sftp\b'
    r'|rsync\b[^|;&]*:'
    r'|ssh\b'
    r'|nc\b)',
  );

  /// Splits a command on shell separators so each pipeline stage is
  /// judged on its own (`rm -rf x; echo done` must still be caught).
  /// A heuristic split — quoted separators are not handled, which is
  /// fine for a pre-execution warning, not a sandbox.
  static List<String> _splitSegments(String command) {
    return command
        .split(RegExp(r'\s*(?:&&|\|\||[|;])\s*'))
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
  }

  /// Drops leading `sudo` (possibly repeated) so the real command
  /// underneath is judged (`sudo rm -rf` is still `rm -rf`).
  static String _stripLeadingSudo(String segment) {
    var rest = segment;
    while (true) {
      final match = RegExp(r'^sudo\s+').firstMatch(rest);
      if (match == null) return rest;
      rest = rest.substring(match.end);
    }
  }

  /// First whitespace-delimited word of a segment, or null.
  static String? _firstWord(String segment) {
    final match = RegExp(
      r'''^["']?([^\s"'&|;]+)''',
    ).firstMatch(segment.trimLeft());
    return match?.group(1);
  }

  /// Combined flag letters of the segment's dash-flags
  /// (`-rf` → {r, f}, `--recursive` → {recursive}).
  static Set<String> _flagLetters(String segment) {
    final letters = <String>{};
    for (final match in RegExp(r'(?:^|\s)-([A-Za-z]+)').allMatches(segment)) {
      letters.addAll(match.group(1)!.split(''));
    }
    for (final match in RegExp(r'--([a-z-]+)').allMatches(segment)) {
      letters.add(match.group(1)!);
    }
    return letters;
  }

  /// Detects writes that land outside the workspace: shell
  /// redirections (`> /abs/path`, `>> ../escape`) and copy/move/tee
  /// destinations. Returns a reason, or null when every detected
  /// write stays inside. `/dev/null` is always fine.
  static String? _writesOutsideWorkspace(
    String segment,
    String workspaceRoot,
    String cwd,
  ) {
    // Redirections: > target / >> target.
    for (final match in RegExp(
      ">>?\\s*(\"[^\"]+\"|'[^']+'|\\S+)",
    ).allMatches(segment)) {
      final target = _unquote(match.group(1)!);
      if (target == '/dev/null') continue;
      if (_isOutsideWorkspace(target, workspaceRoot, cwd)) {
        return 'the command writes outside the workspace ($target)';
      }
    }
    final firstWord = _firstWord(segment);
    if (firstWord == 'cp' || firstWord == 'mv') {
      final args = _shellWords(
        segment,
      ).skip(1).where((word) => !word.startsWith('-')).toList();
      if (args.isNotEmpty) {
        final destination = args.last;
        if (_isOutsideWorkspace(destination, workspaceRoot, cwd)) {
          return 'the command copies/moves a file outside the workspace ($destination)';
        }
      }
    }
    if (firstWord == 'tee') {
      for (final word in _shellWords(segment).skip(1)) {
        if (word.startsWith('-')) continue;
        if (_isOutsideWorkspace(word, workspaceRoot, cwd)) {
          return 'the command writes outside the workspace ($word)';
        }
      }
    }
    return null;
  }

  static String _unquote(String word) {
    if (word.length >= 2 &&
        ((word.startsWith('"') && word.endsWith('"')) ||
            (word.startsWith("'") && word.endsWith("'")))) {
      return word.substring(1, word.length - 1);
    }
    return word;
  }

  /// Splits a segment on whitespace, honouring simple single/double
  /// quotes (good enough for flag/destination parsing).
  static List<String> _shellWords(String segment) {
    final words = <String>[];
    final buffer = StringBuffer();
    String? quote;
    var hasWord = false;
    for (var i = 0; i < segment.length; i++) {
      final char = segment[i];
      if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          buffer.write(char);
        }
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
        hasWord = true;
        continue;
      }
      if (char == ' ' || char == '\t') {
        if (hasWord) {
          words.add(buffer.toString());
          buffer.clear();
          hasWord = false;
        }
        continue;
      }
      buffer.write(char);
      hasWord = true;
    }
    if (hasWord) words.add(buffer.toString());
    return words;
  }

  /// True when [target] resolves outside [workspaceRoot]. Absolute
  /// targets are checked against the root directly; relative targets
  /// resolve against [cwd]. An empty root means "no workspace": any
  /// absolute target counts as outside.
  static bool _isOutsideWorkspace(
    String target,
    String workspaceRoot,
    String cwd,
  ) {
    if (target.isEmpty) return false;
    if (p.isAbsolute(target)) {
      if (workspaceRoot.isEmpty) return true;
      final normalizedRoot = p.normalize(workspaceRoot);
      final normalizedTarget = p.normalize(target);
      return normalizedTarget != normalizedRoot &&
          !p.isWithin(normalizedRoot, normalizedTarget);
    }
    // Relative target: resolve against the working directory.
    if (workspaceRoot.isEmpty || cwd.isEmpty) return false;
    final resolved = p.normalize(p.join(cwd, target));
    final normalizedRoot = p.normalize(workspaceRoot);
    return resolved != normalizedRoot && !p.isWithin(normalizedRoot, resolved);
  }
}

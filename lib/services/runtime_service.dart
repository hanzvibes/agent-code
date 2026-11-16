import 'dart:async';

import 'termux_runtime_service.dart';

/// Result of one command run through [RuntimeService].
///
/// Carries the backend that actually ran the command (`bundled`,
/// `termux`, or `none` when no backend could run it), so the timeline
/// and the model can tell where a command executed.
class CommandResult {
  final String stdout;
  final String stderr;
  final int exitCode;

  /// Human-readable failure reason (Termux error, timeout, backend
  /// unavailable). Null on success.
  final String? error;
  final String backend;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  const CommandResult({
    this.stdout = '',
    this.stderr = '',
    required this.exitCode,
    this.error,
    required this.backend,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
  });

  /// Exit code 0 and no error.
  bool get ok => exitCode == 0 && (error == null || error!.isEmpty);

  Map<String, dynamic> toJson() => {
    'backend': backend,
    'exit_code': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'stdout_truncated': stdoutTruncated,
    'stderr_truncated': stderrTruncated,
    if (error != null && error!.isNotEmpty) 'error': error,
  };
}

/// What [RuntimeService.probeTool] reports for one tool (desain D4):
/// whether it exists, which version it reports, and on which backend.
class ToolProbe {
  final String tool;
  final bool available;

  /// First line of `<tool> --version`, or null when unavailable.
  final String? version;

  /// Backend that has the tool (`bundled` / `termux`), or `none`.
  final String backend;

  const ToolProbe({
    required this.tool,
    required this.available,
    this.version,
    required this.backend,
  });

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'available': available,
    'version': version,
    'backend': backend,
  };
}

/// One command-execution backend (Batch 3 — desain D5).
///
/// The interface Tier 2 implements against: the bundled backend runs
/// tools shipped inside the APK (see `BundledRuntimeBackend`, still a
/// stub in this batch), the Termux backend shells out to the Termux
/// app. Backends must enforce the shared limits — command 1–120 s,
/// 32 KB, output 16 KB per stream — so callers can rely on them no
/// matter which backend runs.
///
/// NOTE (interface decision, see PR body): `run` takes both
/// [workspaceRoot] and [cwd]. The Termux backend needs the project
/// root for its shared-storage rule; the bundled backend ignores it
/// and only uses [cwd]. Callers always pass the workspace root and
/// the absolute working directory inside it.
abstract interface class RuntimeBackend {
  /// Stable id recorded in [CommandResult.backend]: `bundled`,
  /// `termux`, …
  String get name;

  /// Runs [command] with [cwd] as the working directory.
  /// [timeoutSeconds] is clamped to 1–120. [env] adds or overrides
  /// environment variables for the child process (backend-specific:
  /// the bundled backend applies its own HOME/PATH first).
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    required String cwd,
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  });

  /// True when the backend can run [name] (a tool binary, not a shell
  /// builtin). Used for backend selection and probing. The Termux
  /// backend runs `command -v` in [workspaceRoot]/[cwd], so callers
  /// probing a real workspace must pass them; the bundled backend
  /// ignores them.
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  });

  /// Cancels the backend's active command, if any. Backends without
  /// a cancellable command do nothing.
  Future<void> cancelActiveCommand();
}

/// Termux backend: wraps the existing [TermuxRuntimeAdapter]
/// (MethodChannel to the Termux app). The first backend; it stays the
/// fallback for every tool the bundle does not have.
class TermuxRuntimeBackend implements RuntimeBackend {
  final TermuxRuntimeAdapter _adapter;

  TermuxRuntimeBackend([TermuxRuntimeAdapter? adapter])
    : _adapter = adapter ?? TermuxRuntimeService();

  @override
  String get name => 'termux';

  @override
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    required String cwd,
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    // env is accepted for interface compatibility; Termux runs the
    // command through `bash -lc` with the device environment, so
    // per-command variables are folded into the command itself by
    // the caller when needed.
    try {
      final result = await _adapter.execute(
        command: command,
        workspaceRoot: workspaceRoot,
        workingDirectory: cwd,
        timeoutSeconds: timeoutSeconds,
        onOutput: onOutput,
      );
      return CommandResult(
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
        error: result.error,
        backend: name,
        stdoutTruncated: result.stdoutTruncated,
        stderrTruncated: result.stderrTruncated,
      );
    } catch (error) {
      return CommandResult(
        exitCode: 125,
        error: 'Termux command failed: $error',
        backend: name,
      );
    }
  }

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async {
    if (!_isSafeToolName(name)) return false;
    try {
      // `command -v` is a bash builtin: exit 0 when the tool is on
      // PATH, 1 when it is not. A short timeout keeps probing cheap.
      // The native side requires a real workspace context, so
      // callers probing a workspace pass it through.
      final result = await _adapter.execute(
        command: 'command -v $name',
        workspaceRoot: workspaceRoot,
        workingDirectory: cwd.isEmpty ? workspaceRoot : cwd,
        timeoutSeconds: 10,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> cancelActiveCommand() => _adapter.cancelActiveCommand();

  static bool _isSafeToolName(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$').hasMatch(name);
}

/// Bundled backend — STUB (Batch 3 — desain D5).
///
/// The full implementation (tools staged as `jniLibs/lib*.so`,
/// symlinked to `files/engine/tools/bin`, run via `Process`) lands
/// with the Tier 2 track, which runs in parallel with Batch 3–4.
/// Until then every call reports "not available yet" with a clear
/// message instead of failing silently or pretending to run, and
/// [RuntimeService] routes everything to Termux.
class BundledRuntimeBackend implements RuntimeBackend {
  static const String notAvailableMessage =
      'Bundled runtime is not available yet: the Tier 2 bundled '
      'toolchain has not been installed in this build, so the command '
      'was not run. Use the Termux backend instead (it needs the '
      'Termux app and a project under shared storage).';

  @override
  String get name => 'bundled';

  @override
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    required String cwd,
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  }) async => const CommandResult(
    exitCode: 127,
    error: notAvailableMessage,
    backend: 'bundled',
  );

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async => false;

  @override
  Future<void> cancelActiveCommand() async {}
}

/// Single entry point for ALL command execution (Batch 3 — desain D5).
///
/// `run_project_command` and the verifier go through here, never
/// straight to [TermuxRuntimeService]. The service picks a backend per
/// command from the tool the command needs, and records the choice in
/// [CommandResult.backend].
///
/// Selection rule: the bundled backend first when it has the tool,
/// otherwise Termux. Termux is always the fallback — it runs a real
/// shell, so builtins, compound commands and tools installed
/// mid-session still work there, and a missing tool fails with the
/// shell's own "command not found" instead of a synthetic error.
/// The chosen backend per tool is cached for the service lifetime;
/// call [invalidateToolCache] when a backend gains tools (Tier 2
/// staging does this after linking a new tool).
class RuntimeService {
  /// Shared limits (desain §2 / D5): commands 1–120 s, 32 KB,
  /// output 16 KB per stream. The Termux backend enforces them today;
  /// the bundled backend must enforce the same when it lands.
  static const int maxCommandChars = TermuxRuntimeService.maxCommandChars;
  static const int maxOutputCharsPerStream =
      TermuxRuntimeService.maxOutputCharsPerStream;
  static const int minTimeoutSeconds = TermuxRuntimeService.minTimeoutSeconds;
  static const int maxTimeoutSeconds = TermuxRuntimeService.maxTimeoutSeconds;

  static const String noBackendName = 'none';

  final RuntimeBackend _bundled;
  final RuntimeBackend _termux;

  /// Backend chosen per tool name (see selection rule above).
  final Map<String, String> _toolBackendCache = {};

  RuntimeBackend? _activeBackend;

  RuntimeService({RuntimeBackend? bundled, RuntimeBackend? termux})
    : _bundled = bundled ?? BundledRuntimeBackend(),
       _termux = termux ?? TermuxRuntimeBackend();

  String get bundledBackendName => _bundled.name;
  String get termuxBackendName => _termux.name;

  /// Which backend would run a command needing [tool], honouring the
  /// cache. Does not run anything.
  Future<String> selectBackendForTool(String tool) async {
    final cached = _toolBackendCache[tool];
    if (cached != null) return cached;
    final name = await _bundled.hasTool(tool)
        ? _bundled.name
        : _termux.name;
    _toolBackendCache[tool] = name;
    return name;
  }

  /// True when any backend has [name]. The workspace context is
  /// passed through to the Termux backend (see [RuntimeBackend]).
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async =>
      await _bundled.hasTool(name) ||
      await _termux.hasTool(
        name,
        workspaceRoot: workspaceRoot,
        cwd: cwd,
      );

  /// Probes one tool: which backend has it and what `<tool> --version`
  /// reports. The version is the first non-empty output line.
  /// [workspaceRoot]/[cwd] give the Termux backend its workspace
  /// context (the native side rejects blank roots).
  Future<ToolProbe> probeTool(
    String tool, {
    String workspaceRoot = '',
    String cwd = '',
  }) async {
    if (!TermuxRuntimeBackend._isSafeToolName(tool)) {
      return ToolProbe(tool: tool, available: false, backend: noBackendName);
    }
    final backend = await selectBackendForTool(tool);
    final runner = backend == _bundled.name ? _bundled : _termux;
    // A tool the selected backend cannot actually run (Termux
    // fallback for a missing tool) reports unavailable below.
    if (backend == _termux.name &&
        !await _termux.hasTool(
          tool,
          workspaceRoot: workspaceRoot,
          cwd: cwd,
        )) {
      _toolBackendCache[tool] = noBackendName;
      return ToolProbe(tool: tool, available: false, backend: noBackendName);
    }
    final result = await runner.run(
      command: '$tool --version',
      workspaceRoot: workspaceRoot,
      cwd: cwd.isEmpty ? workspaceRoot : cwd,
      timeoutSeconds: 10,
    );
    final version = _firstVersionLine(result);
    if (!result.ok || version == null) {
      _toolBackendCache[tool] = noBackendName;
      return ToolProbe(tool: tool, available: false, backend: noBackendName);
    }
    _toolBackendCache[tool] = backend;
    return ToolProbe(
      tool: tool,
      available: true,
      version: version,
      backend: backend,
    );
  }

  /// Probes each tool in order (sequential: each probe is a runtime
  /// round trip). Returns one [ToolProbe] per requested tool.
  Future<List<ToolProbe>> probeTools(
    List<String> tools, {
    String workspaceRoot = '',
    String cwd = '',
  }) async {
    final results = <ToolProbe>[];
    for (final tool in tools) {
      results.add(
        await probeTool(tool, workspaceRoot: workspaceRoot, cwd: cwd),
      );
    }
    return results;
  }

  /// Runs [command] in [workingDirectory] (absolute, inside
  /// [workspaceRoot]) on the backend that has the tool the command
  /// needs. The chosen backend is recorded in the result.
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    String workingDirectory = '',
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return const CommandResult(
        exitCode: 125,
        error: 'Command cannot be empty.',
        backend: noBackendName,
      );
    }
    if (trimmed.length > maxCommandChars) {
      return const CommandResult(
        exitCode: 125,
        error: 'Command is too long (maximum 32,000 characters).',
        backend: noBackendName,
      );
    }
    final timeout = timeoutSeconds
        .clamp(minTimeoutSeconds, maxTimeoutSeconds)
        .toInt();
    final cwd = workingDirectory.isEmpty ? workspaceRoot : workingDirectory;
    final backendName = await selectBackendForTool(_firstWord(trimmed));
    final backend = backendName == _bundled.name ? _bundled : _termux;
    _activeBackend = backend;
    try {
      return await backend.run(
        command: trimmed,
        workspaceRoot: workspaceRoot,
        cwd: cwd,
        timeoutSeconds: timeout,
        env: env,
        onOutput: onOutput,
      );
    } finally {
      _activeBackend = null;
    }
  }

  /// Cancels the active command on the backend that is running it.
  Future<void> cancelActiveCommand() async {
    final backend = _activeBackend;
    if (backend != null) {
      await backend.cancelActiveCommand();
    } else {
      await _termux.cancelActiveCommand();
    }
  }

  /// Forget cached backend choices — all of them, or one [tool].
  /// Tier 2 calls this after staging a new bundled tool so the next
  /// command re-selects instead of sticking to the old backend.
  void invalidateToolCache([String? tool]) {
    if (tool == null) {
      _toolBackendCache.clear();
    } else {
      _toolBackendCache.remove(tool);
    }
  }

  /// First word of a shell command (the tool it needs), ignoring
  /// leading whitespace and a single level of quoting.
  static String _firstWord(String command) {
    final trimmed = command.trimLeft();
    final match = RegExp(r'''^["']?([^\s"'&|;]+)''').firstMatch(trimmed);
    return match?.group(1) ?? '';
  }

  /// First non-empty line of a `--version` run, capped so a chatty
  /// tool cannot flood the probe result.
  static String? _firstVersionLine(CommandResult result) {
    final combined = '${result.stdout}\n${result.stderr}';
    for (final line in combined.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed.length > 200
            ? '${trimmed.substring(0, 200)}…'
            : trimmed;
      }
    }
    return null;
  }
}

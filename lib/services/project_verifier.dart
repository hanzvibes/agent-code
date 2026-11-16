import 'project_detector.dart';
import 'runtime_service.dart';

/// One verify command run (desain D4).
class VerifyAttempt {
  final String command;
  final String backend;
  final int exitCode;

  /// Combined stdout + stderr, as returned by the runtime (already
  /// capped at 16 KB per stream). The engine summarises this before
  /// it enters the prompt.
  final String output;
  final String? error;

  const VerifyAttempt({
    required this.command,
    required this.backend,
    required this.exitCode,
    this.output = '',
    this.error,
  });

  bool get passed => exitCode == 0 && (error == null || error!.isEmpty);
}

/// Outcome of one verify pass (desain D4).
class VerifyOutcome {
  /// True when the project kind has no verify commands at all
  /// (Flutter/Android, generic) or no files changed, so nothing ran.
  final bool skipped;

  /// True when skipped or every command passed.
  final bool passed;

  /// Commands that ran, in order (stops at the first failure).
  final List<VerifyAttempt> attempts;

  /// The failing attempt, when [passed] is false.
  VerifyAttempt? get failedAttempt {
    for (final attempt in attempts) {
      if (!attempt.passed) return attempt;
    }
    return null;
  }

  /// Combined output of the failing command (empty when passed).
  /// The engine trims this into the error summary for the model.
  String get errorOutput {
    final failed = failedAttempt;
    if (failed == null) return '';
    final parts = <String>[];
    if (failed.error != null && failed.error!.isNotEmpty) {
      parts.add(failed.error!);
    }
    if (failed.output.isNotEmpty) parts.add(failed.output);
    return parts.join('\n');
  }

  const VerifyOutcome({
    required this.skipped,
    required this.passed,
    this.attempts = const [],
  });
}

/// Runs the standard verify commands for a project kind (desain D4).
///
/// One pass only: commands run in order and stop at the first
/// failure. Retrying after a fix — and stopping the task after too
/// many failures — is the engine's job ([AgentEngine] counts verify
/// attempts and feeds the error summary back to the model), because
/// only the engine can ask the model to fix the code between passes.
///
/// Verify never runs for the wrong kind: the caller passes the
/// detected [ProjectType] (from [ProjectDetector.detect], not a
/// model guess), and kinds without commands return a skipped
/// outcome without touching the runtime.
class ProjectVerifier {
  final RuntimeService _runtime;

  ProjectVerifier({RuntimeService? runtime})
    : _runtime = runtime ?? RuntimeService();

  /// Runs the verify commands for [projectType] in [workspaceRoot].
  ///
  /// [changedFiles] are workspace-relative paths the agent changed
  /// (used for `py_compile` / `php -l` targeting). When no files
  /// changed there is nothing to verify and the outcome is skipped.
  Future<VerifyOutcome> verify({
    required String workspaceRoot,
    required ProjectType projectType,
    List<String> changedFiles = const [],
    int timeoutSeconds = 120,
  }) async {
    if (changedFiles.isEmpty) {
      return const VerifyOutcome(skipped: true, passed: true);
    }
    final commands = await ProjectDetector.verifyCommands(
      workspaceRoot,
      projectType,
      changedFiles: changedFiles,
    );
    if (commands.isEmpty) {
      return const VerifyOutcome(skipped: true, passed: true);
    }
    final attempts = <VerifyAttempt>[];
    for (final command in commands) {
      final result = await _runtime.run(
        command: command,
        workspaceRoot: workspaceRoot,
        timeoutSeconds: timeoutSeconds,
      );
      final attempt = VerifyAttempt(
        command: command,
        backend: result.backend,
        exitCode: result.exitCode,
        output: [
          result.stdout,
          result.stderr,
        ].where((part) => part.isNotEmpty).join('\n'),
        error: result.error,
      );
      attempts.add(attempt);
      if (!attempt.passed) {
        return VerifyOutcome(skipped: false, passed: false, attempts: attempts);
      }
    }
    return VerifyOutcome(skipped: false, passed: true, attempts: attempts);
  }
}

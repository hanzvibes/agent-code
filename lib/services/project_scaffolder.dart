import 'dart:io';

import 'package:path/path.dart' as p;

import 'project_detector.dart';
import 'runtime_service.dart';

/// Stacks `scaffold_project` can create (general harness, D11).
///
/// Only stacks whose init runs on the bundled runtime: Node via
/// `npm init -y`, Python via a minimal `pyproject.toml` written
/// directly (no venv — slow and heavy on device), and generic
/// (empty folder). Flutter is deliberately absent: `flutter create`
/// is not a bundled tool.
enum ScaffoldStack {
  node,
  python,
  generic;

  /// Parses a user/model-supplied stack name (case-insensitive).
  static ScaffoldStack? parse(String value) {
    switch (value.trim().toLowerCase()) {
      case 'node':
      case 'nodejs':
      case 'javascript':
      case 'typescript':
      case 'js':
      case 'ts':
        return ScaffoldStack.node;
      case 'python':
      case 'py':
        return ScaffoldStack.python;
      case 'generic':
      case 'empty':
        return ScaffoldStack.generic;
      default:
        return null;
    }
  }

  String get label => switch (this) {
    ScaffoldStack.node => 'Node',
    ScaffoldStack.python => 'Python',
    ScaffoldStack.generic => 'Generic',
  };
}

/// Failure to scaffold (bad path, existing directory, init command
/// failed, ...). The message is user-facing: it names the blocker.
class ScaffoldException implements Exception {
  final String message;
  const ScaffoldException(this.message);

  @override
  String toString() => message;
}

/// Result of a successful scaffold: the new sub-project, detected.
class ScaffoldResult {
  /// Workspace-relative path of the new project (e.g. `remotion-app`).
  final String relativePath;

  /// Detection info of the new project (type + markers).
  final ProjectInfo info;

  /// Init commands that ran (empty when the stack needs none).
  final List<String> commandsRun;

  const ScaffoldResult({
    required this.relativePath,
    required this.info,
    this.commandsRun = const [],
  });

  Map<String, dynamic> toJson() => {
    'path': relativePath,
    'type': info.type.id,
    'label': info.type.label,
    'markers': info.markers,
    'commands_run': commandsRun,
  };
}

/// Shell commands a scaffold runs, per stack (pure — shared by the
/// scaffolder and the permission check, so both agree on what runs).
class ScaffoldPlan {
  /// Init commands for [stack] with [packages] installed afterwards.
  /// Empty when the stack needs no shell command at all.
  static List<String> initCommands(
    ScaffoldStack stack,
    List<String> packages,
  ) {
    switch (stack) {
      case ScaffoldStack.node:
        final commands = <String>['npm init -y'];
        if (packages.isNotEmpty) {
          commands.add('npm install ${packages.join(' ')}');
        }
        return commands;
      case ScaffoldStack.python:
        if (packages.isEmpty) return const [];
        return ['pip install ${packages.join(' ')}'];
      case ScaffoldStack.generic:
        return const [];
    }
  }

  /// True when [name] is a safe package name for `npm install` /
  /// `pip install` (letters, digits, `._@/-`, no whitespace or shell
  /// metacharacters, no `..`).
  static bool isSafePackageName(String name) {
    if (name.isEmpty || name.contains('..')) return false;
    // Allows scoped npm names (@remotion/cli): an optional leading
    // '@', then an alphanumeric start, then letters/digits and
    // . _ @ / - (no shell metacharacters, no parent segments).
    return RegExp(r'^@?[A-Za-z0-9][A-Za-z0-9._@/-]*$').hasMatch(name);
  }

  /// True when [relativePath] is a safe workspace-relative subfolder:
  /// non-empty, no leading `/`, no drive letter, segments are plain
  /// names (no empty, `.` or `..` parts).
  static bool isSafeRelativePath(String relativePath) {
    final trimmed = relativePath.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(trimmed)) return false;
    final segments = trimmed.replaceAll('\\', '/').split('/');
    return segments.every(
      (part) => part.isNotEmpty && part != '.' && part != '..',
    );
  }
}

/// Creates a new sub-project inside the workspace (general harness,
/// D11) and detects it, so the agent can keep working there.
///
/// The scaffold never pretends success: when an init command fails
/// (tool unavailable, timeout, non-zero exit) the error names the
/// command and its output, and the half-created folder is left in
/// place for inspection instead of being silently removed.
class ProjectScaffolder {
  final RuntimeService _runtime;

  ProjectScaffolder({RuntimeService? runtimeService})
    : _runtime = runtimeService ?? RuntimeService();

  /// Scaffolds [stack] into [relativePath] under [workspaceRoot].
  Future<ScaffoldResult> scaffold({
    required String workspaceRoot,
    required String relativePath,
    required ScaffoldStack stack,
    List<String> packages = const [],
  }) async {
    final path = relativePath.trim();
    if (!ScaffoldPlan.isSafeRelativePath(path)) {
      throw const ScaffoldException(
        'Path must be a workspace-relative folder without dot or '
        'parent segments.',
      );
    }
    for (final package in packages) {
      if (!ScaffoldPlan.isSafePackageName(package)) {
        throw ScaffoldException(
          'Unsafe package name: "$package".',
        );
      }
    }
    final root = await Directory(workspaceRoot).resolveSymbolicLinks();
    final target = p.normalize(p.join(root, path));
    if (target != root && !p.isWithin(root, target)) {
      throw const ScaffoldException(
        'Scaffold path is outside the workspace.',
      );
    }
    final directory = Directory(target);
    if (await directory.exists()) {
      throw ScaffoldException(
        'Folder "$path" already exists — pick another name or work '
        'in the existing project there.',
      );
    }
    try {
      await directory.create(recursive: true);
    } catch (error) {
      throw ScaffoldException('Could not create folder "$path": $error');
    }
    if (stack == ScaffoldStack.python) {
      await _writeMinimalPyproject(target, p.basename(path));
    }
    final commandsRun = <String>[];
    for (final command in ScaffoldPlan.initCommands(stack, packages)) {
      final result = await _runtime.run(
        command: command,
        workspaceRoot: root,
        workingDirectory: target,
        timeoutSeconds: 120,
      );
      commandsRun.add(command);
      if (!result.ok) {
        final detail = [
          if (result.error != null && result.error!.isNotEmpty)
            result.error!,
          if (result.stdout.isNotEmpty) result.stdout,
          if (result.stderr.isNotEmpty) result.stderr,
        ].join('\n');
        throw ScaffoldException(
          'Scaffold command failed ($command, exit ${result.exitCode})'
          '${detail.isEmpty ? '' : ':\n$detail'}\n'
          'The folder "$path" was created; fix the problem and run '
          'the command again inside it, or delete the folder.',
        );
      }
    }
    final info = await ProjectDetector.detectAt(workspaceRoot, path);
    return ScaffoldResult(
      relativePath: path,
      info: info,
      commandsRun: commandsRun,
    );
  }

  /// Minimal `pyproject.toml` so the folder detects as Python.
  Future<void> _writeMinimalPyproject(
    String directory,
    String folderName,
  ) async {
    final name = folderName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final safeName = name.isEmpty ? 'project' : name;
    final content =
        '[project]\n'
        'name = "$safeName"\n'
        'version = "0.1.0"\n'
        'requires-python = ">=3.10"\n';
    await File(p.join(directory, 'pyproject.toml')).writeAsString(content);
  }
}

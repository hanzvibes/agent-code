import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Project kinds the agent can recognise from root marker files
/// (Batch 3 — desain D4).
///
/// The type drives two things: which tools [probe_toolchain] checks,
/// and which verify commands run after edits. Flutter/Android and
/// generic projects have **no** verify commands in the app — the app
/// is not for testing or building APKs (koreksi Rehan 2026-11-16);
/// checking happens outside the app (CI / VM / user).
enum ProjectType {
  flutter,
  node,
  python,
  gradle,
  go,
  rust,
  php,
  generic;

  /// Stable id used in tool JSON output.
  String get id => name;

  /// Human-readable label for UI / status messages.
  String get label => switch (this) {
    ProjectType.flutter => 'Flutter/Dart',
    ProjectType.node => 'Node',
    ProjectType.python => 'Python',
    ProjectType.gradle => 'Gradle/Android',
    ProjectType.go => 'Go',
    ProjectType.rust => 'Rust',
    ProjectType.php => 'PHP',
    ProjectType.generic => 'Generic',
  };
}

/// What [ProjectDetector.detect] found at a workspace root.
class ProjectInfo {
  /// Detected kind (generic when no marker file exists).
  final ProjectType type;

  /// Marker file names that were present at the root, in detection
  /// order (e.g. `['pubspec.yaml']`).
  final List<String> markers;

  const ProjectInfo({required this.type, this.markers = const []});

  Map<String, dynamic> toJson() => {
    'type': type.id,
    'label': type.label,
    'markers': markers,
  };
}

/// Detects a project kind from marker files at the workspace root and
/// builds the standard verify commands for that kind (desain D4).
///
/// Detection only looks at the root — a Flutter project's
/// `android/build.gradle` does not make it a Gradle project.
class ProjectDetector {
  /// Markers checked in priority order. The first kind with a present
  /// marker wins, so a project with both `pubspec.yaml` and
  /// `package.json` is Flutter, not Node.
  static const Map<ProjectType, List<String>> _markers = {
    ProjectType.flutter: ['pubspec.yaml'],
    ProjectType.node: ['package.json'],
    ProjectType.python: ['pyproject.toml', 'requirements.txt'],
    ProjectType.gradle: [
      'build.gradle',
      'build.gradle.kts',
      'settings.gradle',
      'settings.gradle.kts',
    ],
    ProjectType.go: ['go.mod'],
    ProjectType.rust: ['Cargo.toml'],
    ProjectType.php: ['composer.json'],
  };

  /// Tools worth probing for each kind, plus the common ones every
  /// project gets (`git`, `rg`). Used by `probe_toolchain` when the
  /// model does not name tools explicitly.
  static const Map<ProjectType, List<String>> probeToolsForType = {
    ProjectType.flutter: ['flutter', 'dart'],
    ProjectType.node: ['node', 'npm'],
    ProjectType.python: ['python3', 'pip', 'pytest'],
    ProjectType.gradle: ['java', 'gradle'],
    ProjectType.go: ['go'],
    ProjectType.rust: ['cargo', 'rustc'],
    ProjectType.php: ['php', 'composer'],
    ProjectType.generic: [],
  };

  static const List<String> commonProbeTools = ['git', 'rg'];

  /// Default probe list for a project kind: common tools first, then
  /// the kind-specific ones.
  static List<String> defaultProbeTools(ProjectType type) => [
    ...commonProbeTools,
    ...?probeToolsForType[type],
  ];

  /// Detects the project kind from marker files at [workspaceRoot].
  static Future<ProjectInfo> detect(String workspaceRoot) async {
    for (final entry in _markers.entries) {
      final found = <String>[];
      for (final marker in entry.value) {
        if (await File(p.join(workspaceRoot, marker)).exists()) {
          found.add(marker);
        }
      }
      if (found.isNotEmpty) {
        return ProjectInfo(type: entry.key, markers: found);
      }
    }
    return const ProjectInfo(type: ProjectType.generic);
  }

  /// Standard verify commands for a project kind (desain D4).
  ///
  /// Only the project's own check commands — never an APK build or
  /// test. Returns an empty list when the kind has no automatic
  /// verify (Flutter/Android, generic) or when its tools are not in
  /// the bundled runtime (Go, Rust, PHP — their `go`/`cargo`/
  /// `composer`/`php` binaries are not bundled, so verification is
  /// skipped rather than failing every run).
  ///
  /// - Node: `npm test` when the `test` script exists, then
  ///   `npm run build` when the `build` script exists.
  /// - Python: `python3 -m pytest` when the project has tests, then
  ///   `python3 -m py_compile` for each changed `.py` file
  ///   (`pytest`/`python` are not bundled tools — only `python3`).
  static Future<List<String>> verifyCommands(
    String workspaceRoot,
    ProjectType type, {
    List<String> changedFiles = const [],
  }) async {
    switch (type) {
      case ProjectType.flutter:
      case ProjectType.gradle:
      case ProjectType.generic:
        // No verify inside the app for Flutter/Android (not an APK
        // test/build tool) and nothing to run for generic projects.
        return [];
      case ProjectType.node:
        final scripts = await _readScripts(
          workspaceRoot,
          'package.json',
        );
        final commands = <String>[];
        if (scripts.contains('test')) commands.add('npm test');
        if (scripts.contains('build')) commands.add('npm run build');
        return commands;
      case ProjectType.python:
        final commands = <String>[];
        if (await _hasPythonTests(workspaceRoot)) {
          commands.add('python3 -m pytest');
        }
        final changedPy = changedFiles
            .where((file) => file.endsWith('.py'))
            .toList();
        if (changedPy.isNotEmpty) {
          commands.add('python3 -m py_compile ${changedPy.join(' ')}');
        }
        return commands;
      case ProjectType.go:
      case ProjectType.rust:
      case ProjectType.php:
        // No verify: `go`, `cargo`, `composer` and `php` are not in
        // the bundled runtime. Skipped like Flutter/generic instead
        // of failing every run with "tool not available".
        return [];
    }
  }

  /// `scripts` keys from a JSON manifest (`package.json`,
  /// `composer.json`). Empty when the file is missing or unparseable —
  /// the caller then simply offers no script-based verify command.
  static Future<Set<String>> _readScripts(
    String workspaceRoot,
    String fileName,
  ) async {
    try {
      final raw = await File(p.join(workspaceRoot, fileName)).readAsString();
      final parsed = jsonDecode(raw);
      if (parsed is! Map || parsed['scripts'] is! Map) return {};
      return (parsed['scripts'] as Map).keys
          .map((key) => key.toString())
          .toSet();
    } catch (_) {
      return {};
    }
  }

  /// True when the project looks like it has Python tests: a `tests`
  /// directory, a `test_*.py` / `*_test.py` file at the root, or a
  /// pytest config file.
  static Future<bool> _hasPythonTests(String workspaceRoot) async {
    const configNames = ['pytest.ini', 'tox.ini', 'setup.cfg'];
    for (final name in configNames) {
      if (await File(p.join(workspaceRoot, name)).exists()) return true;
    }
    if (await Directory(p.join(workspaceRoot, 'tests')).exists()) {
      return true;
    }
    try {
      final entries = await Directory(
        workspaceRoot,
      ).list(followLinks: false).toList();
      for (final entry in entries) {
        if (entry is! File) continue;
        final base = p.basename(entry.path);
        if (base.startsWith('test_') && base.endsWith('.py')) return true;
        if (base.endsWith('_test.py')) return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}

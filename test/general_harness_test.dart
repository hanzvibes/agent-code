// General harness (D11, Opsi C): a general coding agent, not
// Flutter-only. Project kind is a hint, never a refusal reason;
// the agent can scaffold sub-projects of another stack, detect
// many projects in one workspace, and verify each project by its
// own kind.
import 'dart:convert';
import 'dart:io';

import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/services/permission_service.dart';
import 'package:code_harness/services/project_detector.dart';
import 'package:code_harness/services/project_scaffolder.dart';
import 'package:code_harness/services/project_verifier.dart';
import 'package:code_harness/services/runtime_service.dart';
import 'package:code_harness/services/tool_registry.dart';
import 'package:code_harness/services/workspace_tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Backend that behaves like a real runtime for the commands the
/// general-harness flow needs: `npm init -y` really creates a
/// package.json (with test+build scripts) in the cwd, other commands
/// answer from [runResults], and `--version` answers from [tools].
class SimulatingBackend implements RuntimeBackend {
  @override
  final String name = 'bundled';
  final Set<String> tools;
  final Map<String, CommandResult> runResults;
  final List<String> ranCommands = [];
  final List<String> ranCwds = [];

  SimulatingBackend({
    this.tools = const {},
    this.runResults = const {},
  });

  @override
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    required String cwd,
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    ranCommands.add(command);
    ranCwds.add(cwd);
    if (command == 'npm init -y') {
      await File(p.join(cwd, 'package.json')).writeAsString(
        jsonEncode({
          'name': p.basename(cwd),
          'scripts': {'test': 'node --test', 'build': 'node build.js'},
        }),
      );
      return const CommandResult(
        stdout: 'Wrote package.json',
        exitCode: 0,
        backend: 'bundled',
      );
    }
    final scripted = runResults[command];
    if (scripted != null) return scripted;
    if (command.endsWith(' --version')) {
      final tool = command.substring(0, command.length - ' --version'.length);
      if (tools.contains(tool)) {
        return CommandResult(
          stdout: '$tool 1.0.0',
          exitCode: 0,
          backend: 'bundled',
        );
      }
    }
    return CommandResult(
      exitCode: 127,
      error: '$command: not found',
      backend: 'bundled',
    );
  }

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async =>
      tools.contains(name);

  @override
  Future<void> cancelActiveCommand() async {}
}

const _ok = CommandResult(stdout: 'ok', exitCode: 0, backend: 'bundled');

Future<Directory> _tempWorkspace(Map<String, String> files) async {
  final dir = await Directory.systemTemp.createTemp('general_harness_');
  for (final entry in files.entries) {
    final file = File(p.join(dir.path, entry.key));
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  return dir;
}

WorkspaceToolService _tools(RuntimeBackend backend) =>
    WorkspaceToolService(
      runtimeService: RuntimeService(bundled: backend),
    );

/// Calls one tool on [service] and returns its result. Defaults to
/// Agent mode; pass [mode] for Auto (installs run without asking).
Future<ToolExecutionResult> _call(
  WorkspaceToolService service,
  String name,
  Map<String, dynamic> args,
  String workspaceRoot, {
  AgentMode mode = AgentMode.agent,
}) =>
    service.execute(
      workspaceRoot: workspaceRoot,
      call: ToolCallInfo(id: 't1', name: name, arguments: jsonEncode(args)),
      mode: mode,
    );

void main() {
  group('detectAll (multi-project)', () {
    test('finds root + sub-projects, skips ignored dirs, sorts', () async {
      final dir = await _tempWorkspace({
        'pubspec.yaml': 'name: app\n',
        'remotion-app/package.json': '{"name":"remotion-app"}',
        'api/pyproject.toml': '[project]\nname = "api"\n',
        'node_modules/pkg/package.json': '{}',
        '.git/config': '',
        'build/output.txt': 'x',
      });
      final projects = await ProjectDetector.detectAll(dir.path);
      expect(
        projects.map((project) => project.relativePath).toList(),
        ['.', 'api', 'remotion-app'],
      );
      expect(
        projects.map((project) => project.type).toList(),
        [ProjectType.flutter, ProjectType.python, ProjectType.node],
      );
      await dir.delete(recursive: true);
    });

    test('root without markers is still first (generic)', () async {
      final dir = await _tempWorkspace({
        'web/package.json': '{}',
      });
      final projects = await ProjectDetector.detectAll(dir.path);
      expect(
        projects.map((project) => project.relativePath).toList(),
        ['.', 'web'],
      );
      expect(projects.first.type, ProjectType.generic);
      await dir.delete(recursive: true);
    });
  });

  group('detect_project (multi-project)', () {
    test('returns the projects list for the whole workspace', () async {
      final dir = await _tempWorkspace({
        'pubspec.yaml': 'name: app\n',
        'remotion-app/package.json': '{}',
      });
      final service = _tools(SimulatingBackend());
      final result = await _call(service, 'detect_project', {}, dir.path);
      expect(result.isError, isFalse);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['type'], 'flutter');
      expect(decoded['path'], '.');
      final projects = decoded['projects'] as List;
      expect(projects.length, 2);
      expect(
        projects.map((entry) => (entry as Map)['path']).toList(),
        ['.', 'remotion-app'],
      );
      expect(
        projects.map((entry) => (entry as Map)['type']).toList(),
        ['flutter', 'node'],
      );
      await dir.delete(recursive: true);
    });

    test('path arg detects one sub-project', () async {
      final dir = await _tempWorkspace({
        'pubspec.yaml': 'name: app\n',
        'remotion-app/package.json': '{}',
      });
      final service = _tools(SimulatingBackend());
      final result = await _call(
        service,
        'detect_project',
        {'path': 'remotion-app'},
        dir.path,
      );
      expect(result.isError, isFalse);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['type'], 'node');
      expect(decoded['path'], 'remotion-app');
      expect(decoded.containsKey('projects'), isFalse);
      await dir.delete(recursive: true);
    });

    test('path arg rejects an unsafe path', () async {
      final dir = await _tempWorkspace({'pubspec.yaml': 'name: app\n'});
      final service = _tools(SimulatingBackend());
      final result = await _call(
        service,
        'detect_project',
        {'path': '../outside'},
        dir.path,
      );
      expect(result.isError, isTrue);
      expect(result.output, contains('not a folder inside the workspace'));
      await dir.delete(recursive: true);
    });
  });

  group('probe_toolchain (sub-project)', () {
    test('path arg probes inside the sub-project', () async {
      final dir = await _tempWorkspace({
        'pubspec.yaml': 'name: app\n',
        'remotion-app/package.json': '{}',
      });
      final service = _tools(SimulatingBackend(tools: {'node', 'npm'}));
      final result = await _call(
        service,
        'probe_toolchain',
        {
          'tools': ['node'],
          'path': 'remotion-app',
        },
        dir.path,
      );
      expect(result.isError, isFalse);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['path'], 'remotion-app');
      final tools = decoded['tools'] as List;
      expect((tools.first as Map)['tool'], 'node');
      expect((tools.first as Map)['available'], isTrue);
      expect((tools.first as Map)['backend'], 'bundled');
      await dir.delete(recursive: true);
    });
  });

  group('scaffold_project', () {
    test('node scaffold runs npm init + install, then is detectable',
        () async {
      final dir = await _tempWorkspace({'pubspec.yaml': 'name: app\n'});
      final backend = SimulatingBackend(
        tools: {'npm'},
        runResults: {'npm install remotion @remotion/cli': _ok},
      );
      final service = _tools(backend);
      final result = await _call(
        service,
        'scaffold_project',
        {
          'stack': 'node',
          'path': 'remotion-app',
          'packages': ['remotion', '@remotion/cli'],
        },
        dir.path,
        mode: AgentMode.auto,
      );
      expect(result.isError, isFalse, reason: result.output);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['path'], 'remotion-app');
      expect(decoded['type'], 'node');
      expect(decoded['markers'], contains('package.json'));
      expect(
        backend.ranCommands,
        ['npm init -y', 'npm install remotion @remotion/cli'],
      );
      expect(
        backend.ranCwds,
        everyElement(p.join(dir.path, 'remotion-app')),
      );
      // The new sub-project is now part of the workspace.
      final projects = await ProjectDetector.detectAll(dir.path);
      expect(
        projects.map((project) => project.relativePath).toList(),
        ['.', 'remotion-app'],
      );
      await dir.delete(recursive: true);
    });

    test('python scaffold writes pyproject.toml, runs no command',
        () async {
      final dir = await _tempWorkspace({});
      final backend = SimulatingBackend();
      final service = _tools(backend);
      final result = await _call(
        service,
        'scaffold_project',
        {'stack': 'python', 'path': 'api'},
        dir.path,
      );
      expect(result.isError, isFalse, reason: result.output);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['type'], 'python');
      expect(backend.ranCommands, isEmpty);
      final pyproject = File(p.join(dir.path, 'api', 'pyproject.toml'));
      expect(await pyproject.exists(), isTrue);
      expect(await pyproject.readAsString(), contains('[project]'));
      await dir.delete(recursive: true);
    });

    test('generic scaffold only makes the folder', () async {
      final dir = await _tempWorkspace({});
      final service = _tools(SimulatingBackend());
      final result = await _call(
        service,
        'scaffold_project',
        {'stack': 'generic', 'path': 'notes'},
        dir.path,
      );
      expect(result.isError, isFalse, reason: result.output);
      final decoded = jsonDecode(result.output) as Map<String, dynamic>;
      expect(decoded['type'], 'generic');
      expect(
        await Directory(p.join(dir.path, 'notes')).exists(),
        isTrue,
      );
      await dir.delete(recursive: true);
    });

    test('errors: existing folder, unknown stack, unsafe path/package',
        () async {
      final dir = await _tempWorkspace({'existing/keep.txt': 'x'});
      final service = _tools(SimulatingBackend());
      final existing = await _call(
        service,
        'scaffold_project',
        {'stack': 'node', 'path': 'existing'},
        dir.path,
      );
      expect(existing.isError, isTrue);
      expect(existing.output, contains('already exists'));
      final badStack = await _call(
        service,
        'scaffold_project',
        {'stack': 'rust', 'path': 'new-app'},
        dir.path,
      );
      expect(badStack.isError, isTrue);
      expect(badStack.output, contains('Unknown stack'));
      final badPath = await _call(
        service,
        'scaffold_project',
        {'stack': 'node', 'path': '../escape'},
        dir.path,
      );
      expect(badPath.isError, isTrue);
      expect(badPath.output, contains('safe'));
      final badPackage = await _call(
        service,
        'scaffold_project',
        {
          'stack': 'node',
          'path': 'new-app',
          'packages': ['pkg; rm -rf /'],
        },
        dir.path,
      );
      expect(badPackage.isError, isTrue);
      expect(badPackage.output, contains('Unsafe package'));
      await dir.delete(recursive: true);
    });

    test('scaffold plan is pure: init commands by stack', () {
      expect(
        ScaffoldPlan.initCommands(ScaffoldStack.node, ['remotion']),
        ['npm init -y', 'npm install remotion'],
      );
      expect(
        ScaffoldPlan.initCommands(ScaffoldStack.python, []),
        isEmpty,
      );
      expect(
        ScaffoldPlan.initCommands(ScaffoldStack.python, ['requests']),
        ['pip install requests'],
      );
      expect(
        ScaffoldPlan.initCommands(ScaffoldStack.generic, []),
        isEmpty,
      );
    });
  });

  group('Remotion end-to-end (fake runtime)', () {
    test('Flutter workspace + install Remotion -> node sub-project + '
        'per-project verify', () async {
      final dir = await _tempWorkspace({'pubspec.yaml': 'name: app\n'});
      final backend = SimulatingBackend(
        tools: {'npm'},
        runResults: {
          'npm install remotion @remotion/cli': _ok,
          'npm test': _ok,
          'npm run build': _ok,
        },
      );
      final service = _tools(backend);

      // 1. The agent scaffolds a Node sub-project for Remotion
      //    instead of refusing the task.
      final scaffold = await _call(
        service,
        'scaffold_project',
        {
          'stack': 'node',
          'path': 'remotion-app',
          'packages': ['remotion', '@remotion/cli'],
        },
        dir.path,
        mode: AgentMode.auto,
      );
      expect(scaffold.isError, isFalse, reason: scaffold.output);

      // 2. The agent writes the Remotion entry file there.
      final entry = File(p.join(dir.path, 'remotion-app', 'src', 'Root.tsx'));
      await entry.parent.create(recursive: true);
      await entry.writeAsString('export const Root = () => null;\n');

      // 3. Verify runs per project: the node sub-project's own
      //    commands, in the sub-project directory — the Flutter
      //    root has no verify commands and is skipped.
      final verifier = ProjectVerifier(
        runtime: RuntimeService(bundled: backend),
      );
      final outcome = await verifier.verifyAll(
        workspaceRoot: dir.path,
        changedFiles: ['remotion-app/src/Root.tsx'],
      );
      expect(outcome.passed, isTrue);
      expect(
        outcome.attempts.map((attempt) => attempt.command).toList(),
        ['npm test', 'npm run build'],
      );
      expect(
        backend.ranCwds.where((cwd) => cwd.endsWith('remotion-app')),
        hasLength(4), // init + install + test + build
      );
      await dir.delete(recursive: true);
    });
  });

  group('verifyAll (per-project verify)', () {
    test('groups changed files per project, runs each kind in its '
        'own directory', () async {
      final dir = await _tempWorkspace({
        'pubspec.yaml': 'name: app\n',
        'web-app/package.json': jsonEncode({
          'scripts': {'test': 'node --test', 'build': 'node build.js'},
        }),
        'api/pyproject.toml': '[project]\nname = "api"\n',
        'api/tests/test_api.py': 'def test_x():\n    pass\n',
      });
      final backend = SimulatingBackend(
        tools: {'npm', 'python3'},
        runResults: {
          'npm test': _ok,
          'npm run build': _ok,
          'python3 -m pytest': _ok,
          'python3 -m py_compile test_api.py': _ok,
        },
      );
      final verifier = ProjectVerifier(
        runtime: RuntimeService(bundled: backend),
      );
      final outcome = await verifier.verifyAll(
        workspaceRoot: dir.path,
        changedFiles: [
          'lib/main.dart',
          'web-app/src/index.ts',
          'api/test_api.py',
        ],
      );
      expect(outcome.passed, isTrue);
      expect(
        outcome.attempts.map((attempt) => attempt.command).toSet(),
        {
          'npm test',
          'npm run build',
          'python3 -m pytest',
          'python3 -m py_compile test_api.py',
        },
      );
      // Each command ran in its own project's directory.
      for (var i = 0; i < backend.ranCommands.length; i++) {
        final command = backend.ranCommands[i];
        final cwd = backend.ranCwds[i];
        if (command.startsWith('npm')) {
          expect(cwd, p.join(dir.path, 'web-app'));
        } else {
          expect(cwd, p.join(dir.path, 'api'));
        }
      }
      await dir.delete(recursive: true);
    });

    test('fails fast at the first red project', () async {
      final dir = await _tempWorkspace({
        'web-app/package.json': jsonEncode({
          'scripts': {'test': 'node --test', 'build': 'node build.js'},
        }),
      });
      final backend = SimulatingBackend(
        tools: {'npm'},
        runResults: {
          'npm test': const CommandResult(
            stdout: 'failing',
            exitCode: 1,
            backend: 'bundled',
          ),
          'npm run build': _ok,
        },
      );
      final verifier = ProjectVerifier(
        runtime: RuntimeService(bundled: backend),
      );
      final outcome = await verifier.verifyAll(
        workspaceRoot: dir.path,
        changedFiles: ['web-app/src/index.ts'],
      );
      expect(outcome.passed, isFalse);
      expect(outcome.attempts, hasLength(1));
      expect(backend.ranCommands, ['npm test']);
      await dir.delete(recursive: true);
    });

    test('single-project workspace behaves as before (root only)',
        () async {
      final dir = await _tempWorkspace({
        'package.json': jsonEncode({
          'scripts': {'test': 'node --test'},
        }),
      });
      final backend = SimulatingBackend(
        tools: {'npm'},
        runResults: {'npm test': _ok},
      );
      final verifier = ProjectVerifier(
        runtime: RuntimeService(bundled: backend),
      );
      final outcome = await verifier.verifyAll(
        workspaceRoot: dir.path,
        changedFiles: ['src/index.ts'],
      );
      expect(outcome.passed, isTrue);
      expect(
        outcome.attempts.map((attempt) => attempt.command).toList(),
        ['npm test'],
      );
      expect(backend.ranCwds, [dir.path]);
      await dir.delete(recursive: true);
    });
  });

  group('scaffold_project permissions', () {
    test('Plan mode denies, Agent asks for installs, Auto allows',
        () async {
      const args = {
        'stack': 'node',
        'path': 'remotion-app',
        'packages': ['remotion'],
      };
      final service = PermissionService();
      final plan = service.checkToolCall(
        mode: AgentMode.plan,
        toolName: 'scaffold_project',
        args: args,
        workspaceRoot: '/ws',
      );
      expect(plan.decision, PermissionDecision.denied);
      final agent = service.checkToolCall(
        mode: AgentMode.agent,
        toolName: 'scaffold_project',
        args: args,
        workspaceRoot: '/ws',
      );
      expect(agent.decision, PermissionDecision.needsApproval);
      expect(agent.reason, contains('installation'));
      final auto = service.checkToolCall(
        mode: AgentMode.auto,
        toolName: 'scaffold_project',
        args: args,
        workspaceRoot: '/ws',
      );
      expect(auto.decision, PermissionDecision.allowed);
    });

    test('mkdir-only scaffold is allowed in Agent mode', () {
      final check = PermissionService().checkToolCall(
        mode: AgentMode.agent,
        toolName: 'scaffold_project',
        args: const {'stack': 'generic', 'path': 'notes'},
        workspaceRoot: '/ws',
      );
      expect(check.decision, PermissionDecision.allowed);
    });
  });

  group('cross-stack prompt (general agent)', () {
    test('tool descriptions pin the rule: kind is a hint, never a '
        'refusal reason', () {
      final detect = ToolRegistry.detectionToolDefinitions.firstWhere(
        (def) => (def['function'] as Map)['name'] == 'detect_project',
      );
      expect(
        (detect['function'] as Map)['description'],
        contains('never a reason to refuse'),
      );
      final scaffold = ToolRegistry.scaffoldToolDefinitions.single;
      expect(
        (scaffold['function'] as Map)['description'],
        contains('different stack'),
      );
    });

    test('system prompt source carries the general-agent rule', () async {
      final source = await File(
        'lib/controllers/assistant_controller.dart',
      ).readAsString();
      expect(
        source,
        contains('general coding agent (like Codex, Claude Code, or Cursor)'),
      );
      expect(
        source,
        contains('never refuse the task for that reason'),
      );
      expect(source, contains('scaffold_project'));
    });
  });
}

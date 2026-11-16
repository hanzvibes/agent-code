import 'dart:convert';
import 'dart:io';

import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/services/agent_engine.dart';
import 'package:code_harness/services/llm_service.dart';
import 'package:code_harness/services/project_detector.dart';
import 'package:code_harness/services/project_verifier.dart';
import 'package:code_harness/services/runtime_service.dart';
import 'package:code_harness/services/termux_runtime_service.dart';
import 'package:code_harness/services/workspace_tool_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _profile = ProviderProfile(
  id: 'p1',
  name: 'Test Gateway',
  baseUrl: 'https://example.com/v1',
  modelId: 'test-model',
);

/// A backend with scripted answers, for RuntimeService / verifier
/// tests. [tools] maps a tool name to the `--version` output it
/// reports; [runResults] maps an exact command to its result.
class FakeBackend implements RuntimeBackend {
  @override
  final String name;
  final Map<String, String> tools;
  final Map<String, CommandResult> runResults;
  final List<String> ranCommands = [];
  int hasToolCalls = 0;

  FakeBackend({
    required this.name,
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
    final scripted = runResults[command];
    if (scripted != null) return scripted;
    if (command.endsWith(' --version')) {
      final tool = command.substring(0, command.length - ' --version'.length);
      final version = tools[tool];
      if (version != null) {
        return CommandResult(
          stdout: version,
          exitCode: 0,
          backend: name,
        );
      }
    }
    return CommandResult(
      exitCode: 127,
      error: '$command: not found',
      backend: name,
    );
  }

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async {
    hasToolCalls++;
    return tools.containsKey(name);
  }

  @override
  Future<void> cancelActiveCommand() async {}
}

/// Termux adapter fake that answers `command -v` and `--version`
/// from a tool table, for the TermuxRuntimeBackend tests.
class FakeTermuxAdapter implements TermuxRuntimeAdapter {
  final Map<String, String> tools;
  final List<String> commands = [];

  FakeTermuxAdapter(this.tools);

  @override
  Future<TermuxRuntimeStatus> getStatus() async =>
      const TermuxRuntimeStatus(installed: true, permissionGranted: true);

  @override
  Future<void> openTermux() async {}

  @override
  Future<void> openAppPermissionSettings() async {}

  @override
  Future<TermuxCommandResult> execute({
    required String command,
    required String workspaceRoot,
    required String workingDirectory,
    required int timeoutSeconds,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    commands.add(command);
    if (command.startsWith('command -v ')) {
      final tool = command.substring('command -v '.length).trim();
      return TermuxCommandResult(
        stdout: tools.containsKey(tool) ? '/data/data/com.termux/files/usr/bin/$tool\n' : '',
        exitCode: tools.containsKey(tool) ? 0 : 1,
      );
    }
    if (command.endsWith(' --version')) {
      final tool = command.substring(0, command.length - ' --version'.length);
      final version = tools[tool];
      if (version != null) {
        return TermuxCommandResult(stdout: version, exitCode: 0);
      }
      return const TermuxCommandResult(
        stdout: '',
        stderr: 'not found',
        exitCode: 127,
      );
    }
    return TermuxCommandResult(stdout: 'ok\n', exitCode: 0);
  }

  @override
  Future<void> cancelActiveCommand() async {}
}

/// Scripted LLM: each request pops the next scripted response.
class ScriptedLlmService extends LlmService {
  final List<LlmStreamResponse> script;
  int requestCount = 0;

  ScriptedLlmService(this.script);

  @override
  Future<LlmStreamResponse> streamRequest({
    required ProviderProfile profile,
    required String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,
    void Function(int index, String id, String name)? onToolCallName,
  }) async {
    requestCount++;
    if (script.isEmpty) {
      return const LlmStreamResponse(text: 'default answer');
    }
    return script.removeAt(0);
  }
}

ToolCallInfo _toolCall(String id, String name, [String arguments = '{}']) =>
    ToolCallInfo(id: id, name: name, arguments: arguments);

LlmStreamResponse _finishCall(String id) => LlmStreamResponse(
  toolCalls: [
    _toolCall(id, 'finish_task', jsonEncode({'summary': 'Done.'})),
  ],
);

Future<Directory> _tempProject(Map<String, String> files) async {
  final dir = await Directory.systemTemp.createTemp('batch3_test_');
  for (final entry in files.entries) {
    final file = File('${dir.path}/${entry.key}');
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
  }
  return dir;
}

void main() {
  group('ProjectDetector.detect', () {
    test('returns the right type for every marker', () async {
      final cases = <Map<String, String>, ProjectType>{
        {'pubspec.yaml': 'name: x\n'}: ProjectType.flutter,
        {'package.json': '{}'}: ProjectType.node,
        {'requirements.txt': 'requests\n'}: ProjectType.python,
        {'pyproject.toml': '[tool.pytest]\n'}: ProjectType.python,
        {'build.gradle': ''}: ProjectType.gradle,
        {'settings.gradle.kts': ''}: ProjectType.gradle,
        {'go.mod': 'module x\n'}: ProjectType.go,
        {'Cargo.toml': '[package]\n'}: ProjectType.rust,
        {'composer.json': '{}'}: ProjectType.php,
      };
      for (final entry in cases.entries) {
        final dir = await _tempProject(entry.key);
        try {
          final info = await ProjectDetector.detect(dir.path);
          expect(
            info.type,
            entry.value,
            reason: 'markers ${entry.key.keys} should be ${entry.value}',
          );
          expect(info.markers, isNotEmpty);
        } finally {
          await dir.delete(recursive: true);
        }
      }
    });

    test('returns generic when no marker exists', () async {
      final dir = await _tempProject({'README.md': '# hi\n'});
      try {
        final info = await ProjectDetector.detect(dir.path);
        expect(info.type, ProjectType.generic);
        expect(info.markers, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('root markers win over nested ones, pubspec beats package.json',
        () async {
      final dir = await _tempProject({
        'pubspec.yaml': 'name: x\n',
        'package.json': '{}',
        'android/build.gradle': '',
      });
      try {
        final info = await ProjectDetector.detect(dir.path);
        expect(info.type, ProjectType.flutter);
        expect(info.markers, ['pubspec.yaml']);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('ProjectDetector.verifyCommands', () {
    test('node runs npm test and npm run build only when the scripts exist',
        () async {
      final withBoth = await _tempProject({
        'package.json': jsonEncode({
          'scripts': {'test': 'jest', 'build': 'tsc'},
        }),
      });
      final withNeither = await _tempProject({
        'package.json': jsonEncode({'scripts': {}}),
      });
      try {
        expect(
          await ProjectDetector.verifyCommands(
            withBoth.path,
            ProjectType.node,
          ),
          ['npm test', 'npm run build'],
        );
        expect(
          await ProjectDetector.verifyCommands(
            withNeither.path,
            ProjectType.node,
          ),
          isEmpty,
        );
      } finally {
        await withBoth.delete(recursive: true);
        await withNeither.delete(recursive: true);
      }
    });

    test('python runs pytest when tests exist and py_compile on changed files',
        () async {
      final dir = await _tempProject({
        'requirements.txt': 'pytest\n',
        'tests/test_main.py': 'def test_x(): pass\n',
        'main.py': 'x = 1\n',
      });
      try {
        expect(
          await ProjectDetector.verifyCommands(
            dir.path,
            ProjectType.python,
            changedFiles: ['main.py', 'README.md'],
          ),
          ['pytest', 'python -m py_compile main.py'],
        );
        // No changed .py files: only pytest.
        expect(
          await ProjectDetector.verifyCommands(
            dir.path,
            ProjectType.python,
            changedFiles: ['README.md'],
          ),
          ['pytest'],
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('go, rust and php return their standard commands', () async {
      final dir = await _tempProject({});
      try {
        expect(
          await ProjectDetector.verifyCommands(dir.path, ProjectType.go),
          ['go test ./...'],
        );
        expect(
          await ProjectDetector.verifyCommands(dir.path, ProjectType.rust),
          ['cargo test'],
        );
        // PHP without a test script and no changed .php files: none.
        expect(
          await ProjectDetector.verifyCommands(dir.path, ProjectType.php),
          isEmpty,
        );
        expect(
          await ProjectDetector.verifyCommands(
            dir.path,
            ProjectType.php,
            changedFiles: ['src/Api.php'],
          ),
          ['php -l src/Api.php'],
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('php prefers composer test when the script exists', () async {
      final dir = await _tempProject({
        'composer.json': jsonEncode({
          'scripts': {'test': 'phpunit'},
        }),
      });
      try {
        expect(
          await ProjectDetector.verifyCommands(
            dir.path,
            ProjectType.php,
            changedFiles: ['src/Api.php'],
          ),
          ['composer test'],
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('flutter, gradle and generic never have verify commands', () async {
      final dir = await _tempProject({'pubspec.yaml': 'name: x\n'});
      try {
        for (final type in [
          ProjectType.flutter,
          ProjectType.gradle,
          ProjectType.generic,
        ]) {
          expect(
            await ProjectDetector.verifyCommands(
              dir.path,
              type,
              changedFiles: ['lib/main.dart'],
            ),
            isEmpty,
            reason: '$type must not verify inside the app',
          );
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('RuntimeService', () {
    test('bundled stub reports not available clearly', () async {
      final stub = BundledRuntimeBackend();
      expect(stub.name, 'bundled');
      expect(await stub.hasTool('node'), isFalse);
      final result = await stub.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        cwd: '/tmp',
      );
      expect(result.backend, 'bundled');
      expect(result.ok, isFalse);
      expect(result.exitCode, 127);
      expect(result.error, contains('not available yet'));
      expect(result.error, contains('Termux'));
    });

    test('selects the bundled backend when it has the tool', () async {
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'node': 'v22.0.0\n'},
      );
      final termux = FakeBackend(name: 'termux');
      final runtime = RuntimeService(bundled: bundled, termux: termux);
      final result = await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(result.backend, 'bundled');
      expect(result.stdout, 'v22.0.0\n');
      expect(termux.ranCommands, isEmpty);
    });

    test('falls back to termux and records it in the result', () async {
      final bundled = FakeBackend(name: 'bundled');
      final termux = FakeBackend(
        name: 'termux',
        tools: {'node': 'v20.0.0\n'},
      );
      final runtime = RuntimeService(bundled: bundled, termux: termux);
      final result = await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(result.backend, 'termux');
      expect(result.stdout, 'v20.0.0\n');
      expect(bundled.ranCommands, isEmpty);
    });

    test('rejects empty and oversized commands without touching a backend',
        () async {
      final bundled = FakeBackend(name: 'bundled');
      final termux = FakeBackend(name: 'termux');
      final runtime = RuntimeService(bundled: bundled, termux: termux);
      final empty = await runtime.run(
        command: '   ',
        workspaceRoot: '/tmp',
        );
      expect(empty.ok, isFalse);
      expect(empty.backend, RuntimeService.noBackendName);
      final huge = await runtime.run(
        command: 'x' * 32001,
        workspaceRoot: '/tmp',
        );
      expect(huge.ok, isFalse);
      expect(bundled.ranCommands, isEmpty);
      expect(termux.ranCommands, isEmpty);
    });

    test('probe reports available/version/backend, and missing tools',
        () async {
      final runtime = RuntimeService(
        bundled: FakeBackend(name: 'bundled'),
        termux: FakeBackend(
          name: 'termux',
          tools: {'git': 'git version 2.43.0\n', 'node': 'v20.0.0\n'},
        ),
      );
      final probes = await runtime.probeTools(
        ['git', 'node', 'cargo'],
        workspaceRoot: '/tmp',
      );
      expect(probes, hasLength(3));
      expect(probes[0].tool, 'git');
      expect(probes[0].available, isTrue);
      expect(probes[0].version, 'git version 2.43.0');
      expect(probes[0].backend, 'termux');
      expect(probes[1].available, isTrue);
      expect(probes[2].available, isFalse);
      expect(probes[2].version, isNull);
      expect(probes[2].backend, RuntimeService.noBackendName);
    });

    test('probe rejects unsafe tool names without running anything',
        () async {
      final termux = FakeBackend(name: 'termux');
      final runtime = RuntimeService(
        bundled: FakeBackend(name: 'bundled'),
        termux: termux,
      );
      final probe = await runtime.probeTool(
        'node; rm -rf /',
        workspaceRoot: '/tmp',
      );
      expect(probe.available, isFalse);
      expect(termux.ranCommands, isEmpty);
    });

    test('invalidateToolCache makes the next run re-select', () async {
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'node': 'v22.0.0\n'},
      );
      final termux = FakeBackend(name: 'termux');
      final runtime = RuntimeService(bundled: bundled, termux: termux);
      await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(bundled.hasToolCalls, 1);
      await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(bundled.hasToolCalls, 1, reason: 'cached');
      runtime.invalidateToolCache('node');
      await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(bundled.hasToolCalls, 2);
    });
  });

  group('TermuxRuntimeBackend', () {
    test('hasTool uses command -v and run records the termux backend',
        () async {
      final adapter = FakeTermuxAdapter({'git': 'git version 2.43.0\n'});
      final backend = TermuxRuntimeBackend(adapter);
      expect(await backend.hasTool('git'), isTrue);
      expect(await backend.hasTool('cargo'), isFalse);
      final result = await backend.run(
        command: 'git --version',
        workspaceRoot: '/tmp',
        cwd: '/tmp',
      );
      expect(result.backend, 'termux');
      expect(result.stdout, 'git version 2.43.0\n');
      expect(result.ok, isTrue);
    });
  });

  group('ProjectVerifier', () {
    test('runs commands in order and stops at the first failure', () async {
      final runtime = RuntimeService(
        bundled: FakeBackend(name: 'bundled'),
        termux: FakeBackend(
          name: 'termux',
          runResults: {
            'npm test': const CommandResult(
              stdout: 'FAIL tests\n',
              exitCode: 1,
              backend: 'termux',
            ),
            'npm run build': const CommandResult(
              stdout: 'built\n',
              exitCode: 0,
              backend: 'termux',
            ),
          },
        ),
      );
      final verifier = ProjectVerifier(runtime: runtime);
      final dir = await _tempProject({
        'package.json': jsonEncode({
          'scripts': {'test': 'jest', 'build': 'tsc'},
        }),
      });
      try {
        final outcome = await verifier.verify(
          workspaceRoot: dir.path,
          projectType: ProjectType.node,
          changedFiles: ['src/a.js'],
        );
        expect(outcome.passed, isFalse);
        expect(outcome.skipped, isFalse);
        expect(outcome.attempts, hasLength(1));
        expect(outcome.attempts.single.command, 'npm test');
        expect(outcome.attempts.single.backend, 'termux');
        expect(outcome.errorOutput, contains('FAIL tests'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('passes when all commands pass', () async {
      final runtime = RuntimeService(
        bundled: FakeBackend(name: 'bundled'),
        termux: FakeBackend(
          name: 'termux',
          runResults: {
            'go test ./...': const CommandResult(
              stdout: 'ok\n',
              exitCode: 0,
              backend: 'termux',
            ),
          },
        ),
      );
      final verifier = ProjectVerifier(runtime: runtime);
      final outcome = await verifier.verify(
        workspaceRoot: '/tmp',
        projectType: ProjectType.go,
        changedFiles: ['main.go'],
      );
      expect(outcome.passed, isTrue);
      expect(outcome.skipped, isFalse);
      expect(outcome.attempts, hasLength(1));
    });

    test('skips without running anything for flutter and generic',
        () async {
      final termux = FakeBackend(name: 'termux');
      final verifier = ProjectVerifier(
        runtime: RuntimeService(
          bundled: FakeBackend(name: 'bundled'),
          termux: termux,
        ),
      );
      for (final type in [ProjectType.flutter, ProjectType.generic]) {
        final outcome = await verifier.verify(
          workspaceRoot: '/tmp',
          projectType: type,
          changedFiles: ['lib/main.dart'],
        );
        expect(outcome.skipped, isTrue);
        expect(outcome.passed, isTrue);
      }
      expect(termux.ranCommands, isEmpty);
    });

    test('skips when no files changed', () async {
      final termux = FakeBackend(name: 'termux');
      final verifier = ProjectVerifier(
        runtime: RuntimeService(
          bundled: FakeBackend(name: 'bundled'),
          termux: termux,
        ),
      );
      final outcome = await verifier.verify(
        workspaceRoot: '/tmp',
        projectType: ProjectType.go,
      );
      expect(outcome.skipped, isTrue);
      expect(termux.ranCommands, isEmpty);
    });
  });

  group('WorkspaceToolService detection tools', () {
    test('detect_project returns the type and markers', () async {
      final dir = await _tempProject({'package.json': '{}'});
      try {
        final service = WorkspaceToolService();
        final result = await service.execute(
          workspaceRoot: dir.path,
          call: const ToolCallInfo(
            id: 'd1',
            name: 'detect_project',
            arguments: '{}',
          ),
        );
        final decoded = jsonDecode(result.output) as Map<String, dynamic>;
        expect(decoded['type'], 'node');
        expect(decoded['markers'], ['package.json']);
        expect(result.isError, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('probe_toolchain runs without a runtime opt-in (read-only)',
        () async {
      final dir = await _tempProject({'package.json': '{}'});
      try {
        final service = WorkspaceToolService(
          runtimeService: RuntimeService(
            bundled: FakeBackend(name: 'bundled'),
            termux: FakeBackend(name: 'termux'),
          ),
        );
        final result = await service.execute(
          workspaceRoot: dir.path,
          call: const ToolCallInfo(
            id: 'p0',
            name: 'probe_toolchain',
            arguments: '{}',
          ),
        );
        // Probing is read-only (Batch 4 — desain D6): it runs in every
        // mode, including Plan, with no runtime opt-in.
        expect(result.isError, isFalse);
        final decoded = jsonDecode(result.output) as Map<String, dynamic>;
        expect(decoded['project_type'], 'node');
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('probe_toolchain probes the kind tools and reports the backend',
        () async {
      final dir = await _tempProject({'package.json': '{}'});
      final termux = FakeBackend(
        name: 'termux',
        tools: {'git': 'git version 2.43.0\n', 'node': 'v20.0.0\n'},
      );
      try {
        final service = WorkspaceToolService(
          runtimeService: RuntimeService(
            bundled: FakeBackend(name: 'bundled'),
            termux: termux,
          ),
        );
        final result = await service.execute(
          workspaceRoot: dir.path,
          call: const ToolCallInfo(
            id: 'p1',
            name: 'probe_toolchain',
            arguments: '{}',
          ),
        );
        expect(result.isError, isFalse);
        final decoded = jsonDecode(result.output) as Map<String, dynamic>;
        expect(decoded['project_type'], 'node');
        final tools = decoded['tools'] as List;
        final byName = {
          for (final entry in tools)
            (entry as Map<String, dynamic>)['tool'] as String: entry,
        };
        // Default Node probe list: git, rg, node, npm.
        expect(byName.keys, containsAll(['git', 'rg', 'node', 'npm']));
        expect(byName['git']!['available'], isTrue);
        expect(byName['git']!['version'], 'git version 2.43.0');
        expect(byName['git']!['backend'], 'termux');
        expect(byName['rg']!['available'], isFalse);
        expect(byName['node']!['available'], isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('run_project_command still refuses non-shared-storage workspaces',
        () async {
      final dir = await _tempProject({'package.json': '{}'});
      final termux = FakeBackend(
        name: 'termux',
        tools: {'echo': 'echo\n'},
      );
      try {
        final service = WorkspaceToolService(
          runtimeService: RuntimeService(
            bundled: FakeBackend(name: 'bundled'),
            termux: termux,
          ),
        );
        final result = await service.execute(
          workspaceRoot: dir.path,
          call: const ToolCallInfo(
            id: 'r1',
            name: 'run_project_command',
            arguments: '{"command": "echo hi"}',
          ),
        );
        // Termux can only see shared storage: the tool refuses before
        // the runtime is touched (no /storage/emulated/0 in tests).
        expect(result.isError, isTrue);
        expect(result.output, contains('shared storage'));
        expect(termux.ranCommands, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('AgentEngine verify gate', () {
    Future<AgentRunResult> runEngine({
      required ScriptedLlmService llm,
      required ProjectVerifier verifier,
      required Directory workspace,
      Future<ToolExecutionResult> Function(ToolCallInfo call)? executeTool,
    }) async {
      final engine = AgentEngine(
        llmService: llm,
        executeTool:
            executeTool ??
            (call) async => ToolExecutionResult(
              callId: call.id,
              toolName: call.name,
              output: '{"ok": true}',
              summary: 'ok',
            ),
        delay: (_) async {},
        verifier: verifier,
      );
      return engine.run(
        task: AgentTask(title: 't'),
        profile: _profile,
        apiKey: 'k',
        messages: [
          {'role': 'user', 'content': 'Do the thing'},
        ],
        tools: const [
          {
            'type': 'function',
            'function': {'name': 'write_file'},
          },
          {
            'type': 'function',
            'function': {'name': 'finish_task'},
          },
        ],
        cancelToken: CancelToken(),
        workspaceRoot: workspace.path,
      );
    }

    ProjectVerifier failingVerifier() => ProjectVerifier(
      runtime: RuntimeService(
        bundled: FakeBackend(name: 'bundled'),
        termux: FakeBackend(
          name: 'termux',
          runResults: {
            'pytest': const CommandResult(
              stdout: 'FAILED test_main.py::test_x\nAssertionError\n',
              exitCode: 1,
              backend: 'termux',
            ),
          },
        ),
      ),
    );

    test('green verify lets finish_task complete the task', () async {
      final dir = await _tempProject({
        'requirements.txt': 'pytest\n',
        'tests/test_main.py': 'def test_x(): pass\n',
      });
      try {
        final verifier = ProjectVerifier(
          runtime: RuntimeService(
            bundled: FakeBackend(name: 'bundled'),
            termux: FakeBackend(
              name: 'termux',
              runResults: {
                'pytest': const CommandResult(
                  stdout: '1 passed\n',
                  exitCode: 0,
                  backend: 'termux',
                ),
                'python -m py_compile main.py': const CommandResult(
                  stdout: '',
                  exitCode: 0,
                  backend: 'termux',
                ),
              },
            ),
          ),
        );
        final llm = ScriptedLlmService([
          LlmStreamResponse(
            toolCalls: [
              _toolCall(
                'c1',
                'write_file',
                jsonEncode({'path': 'main.py', 'content': 'x = 1\n'}),
              ),
            ],
          ),
          _finishCall('c2'),
        ]);
        var writeCalls = 0;
        final result = await runEngine(
          llm: llm,
          verifier: verifier,
          workspace: dir,
          executeTool: (call) async {
            if (call.name == 'write_file') {
              writeCalls++;
              return ToolExecutionResult(
                callId: call.id,
                toolName: call.name,
                output: '{"ok": true, "path": "main.py"}',
                summary: 'Wrote main.py',
              );
            }
            return ToolExecutionResult(
              callId: call.id,
              toolName: call.name,
              output: '{"ok": true}',
              summary: 'ok',
            );
          },
        );
        expect(writeCalls, 1);
        expect(result.stopReason, AgentStopReason.finished);
        expect(result.task.status, TaskStatus.done);
        expect(llm.requestCount, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('red verify retries the model, then needs-help after 3 attempts',
        () async {
      final dir = await _tempProject({
        'requirements.txt': 'pytest\n',
        'tests/test_main.py': 'def test_x(): pass\n',
      });
      try {
        final llm = ScriptedLlmService([
          LlmStreamResponse(
            toolCalls: [
              _toolCall(
                'c1',
                'write_file',
                jsonEncode({'path': 'main.py', 'content': 'x = 1\n'}),
              ),
            ],
          ),
          _finishCall('c2'),
          _finishCall('c3'),
          _finishCall('c4'),
        ]);
        final result = await runEngine(
          llm: llm,
          verifier: failingVerifier(),
          workspace: dir,
          executeTool: (call) async => ToolExecutionResult(
            callId: call.id,
            toolName: call.name,
            output: '{"ok": true, "path": "main.py"}',
            summary: 'Wrote main.py',
          ),
        );
        expect(result.stopReason, AgentStopReason.verificationFailed);
        expect(result.task.status, TaskStatus.needsHelp);
        expect(result.detail, contains('3 times'));
        expect(result.detail, contains('AssertionError'));
        // 1 write round + 3 finish attempts.
        expect(llm.requestCount, 4);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('verify never runs for a flutter project', () async {
      final dir = await _tempProject({'pubspec.yaml': 'name: x\n'});
      try {
        final termux = FakeBackend(name: 'termux');
        final verifier = ProjectVerifier(
          runtime: RuntimeService(
            bundled: FakeBackend(name: 'bundled'),
            termux: termux,
          ),
        );
        final llm = ScriptedLlmService([
          LlmStreamResponse(
            toolCalls: [
              _toolCall(
                'c1',
                'write_file',
                jsonEncode({'path': 'lib/a.dart', 'content': 'void f() {}\n'}),
              ),
            ],
          ),
          _finishCall('c2'),
        ]);
        final result = await runEngine(
          llm: llm,
          verifier: verifier,
          workspace: dir,
          executeTool: (call) async => ToolExecutionResult(
            callId: call.id,
            toolName: call.name,
            output: '{"ok": true, "path": "lib/a.dart"}',
            summary: 'Wrote lib/a.dart',
          ),
        );
        expect(result.stopReason, AgentStopReason.finished);
        expect(termux.ranCommands, isEmpty);
        expect(llm.requestCount, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('verify is skipped when the model changed no files', () async {
      final dir = await _tempProject({
        'requirements.txt': 'pytest\n',
        'tests/test_main.py': 'def test_x(): pass\n',
      });
      try {
        final termux = FakeBackend(name: 'termux');
        final verifier = ProjectVerifier(
          runtime: RuntimeService(
            bundled: FakeBackend(name: 'bundled'),
            termux: termux,
          ),
        );
        final llm = ScriptedLlmService([_finishCall('c1')]);
        final result = await runEngine(
          llm: llm,
          verifier: verifier,
          workspace: dir,
        );
        expect(result.stopReason, AgentStopReason.finished);
        expect(termux.ranCommands, isEmpty);
        expect(llm.requestCount, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

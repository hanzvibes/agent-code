import 'dart:convert';
import 'dart:io';

import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/services/agent_engine.dart';
import 'package:code_harness/services/llm_service.dart';
import 'package:code_harness/services/project_detector.dart';
import 'package:code_harness/services/project_verifier.dart';
import 'package:code_harness/services/runtime_service.dart';
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
      expect(result.error, isNot(contains('Termux')));
    });

    test('selects the bundled backend when it has the tool', () async {
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'node': 'v22.0.0\n'},
      );
      final runtime = RuntimeService(bundled: bundled);
      final result = await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(result.backend, 'bundled');
      expect(result.stdout, 'v22.0.0\n');
    });

    test('refuses a tool the bundle does not have without running anything',
        () async {
      final bundled = FakeBackend(name: 'bundled');
      final runtime = RuntimeService(bundled: bundled);
      final result = await runtime.run(
        command: 'node --version',
        workspaceRoot: '/tmp',
        );
      expect(result.backend, RuntimeService.noBackendName);
      expect(result.exitCode, 127);
      expect(result.ok, isFalse);
      expect(result.error, contains('Tool "node" is not available'));
      expect(result.error, contains('probe_toolchain'));
      expect(bundled.ranCommands, isEmpty);
    });

    test('compound command selects on the first real tool', () async {
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'npm': 'npm 10.0.0\n'},
        runResults: {
          'cd x && npm install': const CommandResult(
            stdout: 'installed\n',
            exitCode: 0,
            backend: 'bundled',
          ),
        },
      );
      final runtime = RuntimeService(bundled: bundled);
      // `cd` is a builtin: the selector looks past it to `npm`.
      final result = await runtime.run(
        command: 'cd x && npm install',
        workspaceRoot: '/tmp',
        );
      expect(result.backend, 'bundled');
      expect(result.stdout, 'installed\n');
      expect(bundled.ranCommands, ['cd x && npm install']);
      // Env assignments are skipped the same way: the command still
      // reaches the bundled backend (the fake answers `--version`
      // only for a bare tool name, so assert routing, not output).
      final prefixed = await runtime.run(
        command: 'FOO=bar npm --version',
        workspaceRoot: '/tmp',
        );
      expect(prefixed.backend, 'bundled');
      expect(bundled.ranCommands, contains('FOO=bar npm --version'));
    });

    test('builtin-only commands run through the bundled shell', () async {
      final bundled = FakeBackend(name: 'bundled');
      final runtime = RuntimeService(bundled: bundled);
      final result = await runtime.run(
        command: 'echo hi',
        workspaceRoot: '/tmp',
        );
      // `echo` names no tool, so there is nothing to refuse: the
      // command reaches the bundled backend, which runs it in bash.
      expect(result.backend, 'bundled');
      expect(bundled.ranCommands, ['echo hi']);
    });

    test('missing tool fails with exit 127 and names the tool', () async {
      final bundled = FakeBackend(name: 'bundled');
      final runtime = RuntimeService(bundled: bundled);
      final result = await runtime.run(
        command: 'make build',
        workspaceRoot: '/tmp',
        );
      expect(result.backend, RuntimeService.noBackendName);
      expect(result.exitCode, 127);
      expect(result.ok, isFalse);
      expect(result.error, contains('Tool "make" is not available'));
      expect(
        result.error,
        contains(
          'Bundled tools: git, rg, node, npm, npx, python3, pip, jq, '
          'curl, xz, tar, ffmpeg, ffprobe, bash',
        ),
      );
      expect(result.error, contains('probe_toolchain'));
      expect(bundled.ranCommands, isEmpty);
    });

    test('no Termux backend remains: selection is bundled or none',
        () async {
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'git': 'git version 2.43.0\n', 'node': 'v20.0.0\n'},
      );
      final runtime = RuntimeService(bundled: bundled);
      expect(runtime.bundledBackendName, 'bundled');
      for (final tool in ['git', 'node', 'flutter', 'make', 'cargo']) {
        final selected = await runtime.selectBackendForTool(tool);
        expect(
          selected,
          anyOf('bundled', RuntimeService.noBackendName),
          reason: '$tool must never select termux',
        );
        expect(selected, isNot('termux'));
      }
      expect(await runtime.selectBackendForTool('git'), 'bundled');
      expect(
        await runtime.selectBackendForTool('flutter'),
        RuntimeService.noBackendName,
      );
    });

    test('rejects empty and oversized commands without touching a backend',
        () async {
      final bundled = FakeBackend(name: 'bundled');
      final runtime = RuntimeService(bundled: bundled);
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
    });

    test('probe reports available/version/backend, and missing tools',
        () async {
      final runtime = RuntimeService(
        bundled: FakeBackend(
          name: 'bundled',
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
      expect(probes[0].backend, 'bundled');
      expect(probes[1].available, isTrue);
      expect(probes[2].available, isFalse);
      expect(probes[2].version, isNull);
      expect(probes[2].backend, RuntimeService.noBackendName);
    });

    test('probe rejects unsafe tool names without running anything',
        () async {
      final bundled = FakeBackend(name: 'bundled');
      final runtime = RuntimeService(bundled: bundled);
      final probe = await runtime.probeTool(
        'node; rm -rf /',
        workspaceRoot: '/tmp',
      );
      expect(probe.available, isFalse);
      expect(bundled.ranCommands, isEmpty);
    });

    test('invalidateToolCache makes the next run re-select', () async {
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'node': 'v22.0.0\n'},
      );
      final runtime = RuntimeService(bundled: bundled);
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

  group('ProjectVerifier', () {
    test('runs commands in order and stops at the first failure', () async {
      final runtime = RuntimeService(
        bundled: FakeBackend(
          name: 'bundled',
          tools: {'npm': 'npm 10.0.0\n'},
          runResults: {
            'npm test': const CommandResult(
              stdout: 'FAIL tests\n',
              exitCode: 1,
              backend: 'bundled',
            ),
            'npm run build': const CommandResult(
              stdout: 'built\n',
              exitCode: 0,
              backend: 'bundled',
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
        expect(outcome.attempts.single.backend, 'bundled');
        expect(outcome.errorOutput, contains('FAIL tests'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('passes when all commands pass', () async {
      final runtime = RuntimeService(
        bundled: FakeBackend(
          name: 'bundled',
          tools: {'go': 'go version go1.22.0\n'},
          runResults: {
            'go test ./...': const CommandResult(
              stdout: 'ok\n',
              exitCode: 0,
              backend: 'bundled',
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
      final bundled = FakeBackend(name: 'bundled');
      final verifier = ProjectVerifier(
        runtime: RuntimeService(bundled: bundled),
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
      expect(bundled.ranCommands, isEmpty);
    });

    test('skips when no files changed', () async {
      final bundled = FakeBackend(name: 'bundled');
      final verifier = ProjectVerifier(
        runtime: RuntimeService(bundled: bundled),
      );
      final outcome = await verifier.verify(
        workspaceRoot: '/tmp',
        projectType: ProjectType.go,
      );
      expect(outcome.skipped, isTrue);
      expect(bundled.ranCommands, isEmpty);
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
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'git': 'git version 2.43.0\n', 'node': 'v20.0.0\n'},
      );
      try {
        final service = WorkspaceToolService(
          runtimeService: RuntimeService(bundled: bundled),
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
        expect(byName['git']!['backend'], 'bundled');
        expect(byName['rg']!['available'], isFalse);
        expect(byName['node']!['available'], isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('run_project_command runs in an app-private workspace via bundled',
        () async {
      final dir = await _tempProject({'package.json': '{}'});
      final bundled = FakeBackend(
        name: 'bundled',
        tools: {'git': 'git version 2.43.0\n'},
        runResults: {
          'git status': const CommandResult(
            stdout: 'On branch main\n',
            exitCode: 0,
            backend: 'bundled',
          ),
        },
      );
      try {
        final service = WorkspaceToolService(
          runtimeService: RuntimeService(bundled: bundled),
        );
        final result = await service.execute(
          workspaceRoot: dir.path,
          call: const ToolCallInfo(
            id: 'r1',
            name: 'run_project_command',
            arguments: '{"command": "git status"}',
          ),
        );
        // No shared-storage gate any more: the app-private temp dir
        // is a valid workspace and the command runs via bundled.
        expect(result.isError, isFalse);
        expect(result.output, contains('"backend":"bundled"'));
        expect(result.output, contains('On branch main'));
        expect(bundled.ranCommands, ['git status']);
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
        bundled: FakeBackend(
          name: 'bundled',
          tools: {'pytest': 'pytest 8.0.0\n'},
          runResults: {
            'pytest': const CommandResult(
              stdout: 'FAILED test_main.py::test_x\nAssertionError\n',
              exitCode: 1,
              backend: 'bundled',
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
            bundled: FakeBackend(
              name: 'bundled',
              tools: {'pytest': 'pytest 8.0.0\n', 'python': 'Python 3.14\n'},
              runResults: {
                'pytest': const CommandResult(
                  stdout: '1 passed\n',
                  exitCode: 0,
                  backend: 'bundled',
                ),
                'python -m py_compile main.py': const CommandResult(
                  stdout: '',
                  exitCode: 0,
                  backend: 'bundled',
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
        final bundled = FakeBackend(name: 'bundled');
        final verifier = ProjectVerifier(
          runtime: RuntimeService(bundled: bundled),
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
        expect(bundled.ranCommands, isEmpty);
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
        final bundled = FakeBackend(name: 'bundled');
        final verifier = ProjectVerifier(
          runtime: RuntimeService(bundled: bundled),
        );
        final llm = ScriptedLlmService([_finishCall('c1')]);
        final result = await runEngine(
          llm: llm,
          verifier: verifier,
          workspace: dir,
        );
        expect(result.stopReason, AgentStopReason.finished);
        expect(bundled.ranCommands, isEmpty);
        expect(llm.requestCount, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

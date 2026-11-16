import 'dart:io';

import 'package:code_harness/services/runtime_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Paths provider fake: returns fixed temp directories.
class FakePathsProvider implements BundledRuntimePathsProvider {
  final BundledRuntimePaths paths;
  int fetchCalls = 0;

  FakePathsProvider(this.paths);

  @override
  Future<BundledRuntimePaths?> fetch() async {
    fetchCalls++;
    return paths;
  }
}

/// Process runner fake: records every call, returns a scripted result.
class FakeProcessRunner implements BundledProcessRunner {
  final List<Map<String, Object?>> calls = [];
  BundledProcessResult resultToReturn = const BundledProcessResult(
    stdout: 'ok\n',
    exitCode: 0,
  );
  int cancelCalls = 0;

  @override
  Future<BundledProcessResult> run({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required Duration timeout,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    calls.add({
      'executable': executable,
      'arguments': arguments,
      'workingDirectory': workingDirectory,
      'environment': environment,
      'timeout': timeout,
    });
    if (onOutput != null && resultToReturn.stdout.isNotEmpty) {
      onOutput('stdout', resultToReturn.stdout);
    }
    if (onOutput != null && resultToReturn.stderr.isNotEmpty) {
      onOutput('stderr', resultToReturn.stderr);
    }
    return resultToReturn;
  }

  @override
  void cancel() {
    cancelCalls++;
  }
}

/// Asset extractor fake: pretends to copy files, answers the
/// git-core links list from a scripted string.
class FakeAssetExtractor implements BundledAssetExtractor {
  int extractCalls = 0;
  final List<String> extractedDirs = [];
  String gitCoreLinks;

  FakeAssetExtractor({this.gitCoreLinks = 'git\ngit-add\ngit-remote-https\n'});

  @override
  Future<int> extractAssets(String engineDir) async {
    extractCalls++;
    extractedDirs.add(engineDir);
    return 3;
  }

  @override
  Future<String> readTextAsset(String assetPath) async {
    if (assetPath == 'assets/git-core-links.txt') return gitCoreLinks;
    throw StateError('unexpected asset $assetPath');
  }
}

/// Minimal second backend, for the RuntimeService selection tests.
class FakeTermuxBackend implements RuntimeBackend {
  @override
  final String name = 'termux';
  final Set<String> tools;
  final List<String> ranCommands = [];

  FakeTermuxBackend({this.tools = const {}});

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
    return CommandResult(
      stdout: 'termux: $command\n',
      exitCode: 0,
      backend: name,
    );
  }

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async => tools.contains(name);

  @override
  Future<void> cancelActiveCommand() async {}
}

class _Harness {
  final Directory root;
  final Directory nativeLib;
  final Directory filesDir;
  final Directory cacheDir;
  final FakePathsProvider paths;
  final FakeProcessRunner runner;
  final FakeAssetExtractor extractor;
  final BundledRuntimeBackend backend;

  _Harness._({
    required this.root,
    required this.nativeLib,
    required this.filesDir,
    required this.cacheDir,
    required this.paths,
    required this.runner,
    required this.extractor,
    required this.backend,
  });

  String get engineDir => '${filesDir.path}/engine';

  Future<void> dispose() => root.delete(recursive: true);
}

Future<_Harness> _makeHarness({
  bool withLibs = true,
  List<String> libs = const [],
  String shellExecutable = '/bin/sh',
}) async {
  final root = await Directory.systemTemp.createTemp('tier2_test_');
  final nativeLib = Directory('${root.path}/lib');
  final filesDir = Directory('${root.path}/files');
  final cacheDir = Directory('${root.path}/cache');
  await nativeLib.create(recursive: true);
  await filesDir.create(recursive: true);
  await cacheDir.create(recursive: true);
  final staged = libs.isEmpty
      ? BundledRuntimeBackend.bundledTools.values.toSet().toList()
      : libs;
  if (withLibs) {
    for (final lib in staged) {
      await File('${nativeLib.path}/$lib').writeAsString('');
    }
    // git-core helpers are staged too.
    for (final lib in [
      'libgit-remote-http.so',
      'libgit-http-fetch.so',
      'libgit-http-push.so',
      'libgit-daemon.so',
      'libgit-http-backend.so',
      'libgit-imap-send.so',
      'libgit-sh-i18n--envsubst.so',
    ]) {
      await File('${nativeLib.path}/$lib').writeAsString('');
    }
  }
  final paths = FakePathsProvider(
    BundledRuntimePaths(
      nativeLibraryDir: nativeLib.path,
      filesDir: filesDir.path,
      cacheDir: cacheDir.path,
    ),
  );
  final runner = FakeProcessRunner();
  final extractor = FakeAssetExtractor();
  final backend = BundledRuntimeBackend(
    pathsProvider: paths,
    processRunner: runner,
    assetExtractor: extractor,
    shellExecutable: shellExecutable,
  );
  return _Harness._(
    root: root,
    nativeLib: nativeLib,
    filesDir: filesDir,
    cacheDir: cacheDir,
    paths: paths,
    runner: runner,
    extractor: extractor,
    backend: backend,
  );
}

void main() {
  group('BundledRuntimeBackend.buildEnvironment', () {
    test('builds the opencode-style environment', () {
      final env = BundledRuntimeBackend.buildEnvironment(
        nativeLibraryDir: '/lib',
        engineDir: '/files/engine',
        tmpDir: '/cache/engine-tmp',
      );
      expect(env['HOME'], '/files/engine/home');
      expect(env['TMPDIR'], '/cache/engine-tmp');
      expect(env['XDG_DATA_HOME'], '/files/engine/home/.local/share');
      expect(env['XDG_CACHE_HOME'], '/files/engine/home/.cache');
      expect(env['XDG_CONFIG_HOME'], '/files/engine/home/.config');
      expect(
        env['PATH'],
        '/files/engine/tools/bin:/system/bin:/system/xbin:/vendor/bin',
      );
      expect(env['LANG'], 'C.UTF-8');
      expect(env['SHELL'], '/system/bin/sh');
      expect(env['SSL_CERT_FILE'], '/files/engine/node/etc/tls/cert.pem');
      expect(env['PYTHONHOME'], '/files/engine/python');
      expect(env['LD_LIBRARY_PATH'], '/lib');
      expect(env['GIT_EXEC_PATH'], '/files/engine/git-core');
      expect(env['GIT_TEMPLATE_DIR'], '/files/engine/git-templates');
      expect(env['GIT_CONFIG_NOSYSTEM'], '1');
    });
  });

  group('BundledRuntimeBackend.shellPreamble', () {
    test('defines npm, npx and pip as shell functions', () {
      final preamble = BundledRuntimeBackend.shellPreamble(
        '/files/engine',
      );
      expect(
        preamble,
        contains(
          "npm() { node '/files/engine/node/lib/node_modules/npm/bin/npm-cli.js'",
        ),
      );
      expect(
        preamble,
        contains(
          "npx() { node '/files/engine/node/lib/node_modules/npm/bin/npx-cli.js'",
        ),
      );
      expect(preamble, contains("pip() { python3 -m pip"));
    });
  });

  group('BundledRuntimeBackend.bundledTools', () {
    test('covers all eleven Tier 2 tools plus npm/npx/pip', () {
      final tools = BundledRuntimeBackend.bundledTools;
      expect(
        tools.keys,
        containsAll([
          'git',
          'rg',
          'node',
          'npm',
          'npx',
          'python3',
          'pip',
          'jq',
          'curl',
          'xz',
          'tar',
          'ffmpeg',
          'ffprobe',
        ]),
      );
      expect(tools['git'], 'libgit.so');
      expect(tools['jq'], 'libjq-cli.so');
      expect(tools['curl'], 'libcurl-cli.so');
      expect(tools['npm'], 'libnode.so');
      expect(tools['pip'], 'libpython3.so');
    });
  });

  group('BundledRuntimeBackend setup', () {
    test('links tools, git-core helpers and writes .gitconfig', () async {
      final h = await _makeHarness();
      try {
        expect(await h.backend.hasTool('git'), isTrue);
        // Tools are symlinks into nativeLibraryDir.
        expect(
          await Link('${h.engineDir}/tools/bin/git').target(),
          '${h.nativeLib.path}/libgit.so',
        );
        expect(
          await Link('${h.engineDir}/tools/bin/node').target(),
          '${h.nativeLib.path}/libnode.so',
        );
        expect(
          await Link('${h.engineDir}/tools/bin/git-remote-http').target(),
          '${h.nativeLib.path}/libgit-remote-http.so',
        );
        // npm/npx/pip are shell functions, not symlinks.
        expect(
          await File('${h.engineDir}/tools/bin/npm').exists(),
          isFalse,
        );
        // git-core multicall links point at tools/bin/git…
        expect(
          await Link('${h.engineDir}/git-core/git').target(),
          '${h.engineDir}/tools/bin/git',
        );
        expect(
          await Link('${h.engineDir}/git-core/git-add').target(),
          '${h.engineDir}/tools/bin/git',
        );
        // …except the remote helpers, which point at git-remote-http.
        expect(
          await Link('${h.engineDir}/git-core/git-remote-https').target(),
          '${h.engineDir}/tools/bin/git-remote-http',
        );
        // Assets were extracted once, and the marker was written.
        expect(h.extractor.extractCalls, 1);
        expect(h.extractor.extractedDirs.single, h.engineDir);
        expect(
          await File('${h.engineDir}/.tier2-assets-version').readAsString(),
          BundledRuntimeBackend.assetsVersion,
        );
        // .gitconfig carries the two bundled-runtime settings.
        final gitconfig = await File(
          '${h.engineDir}/home/.gitconfig',
        ).readAsString();
        expect(gitconfig, contains('fileMode = false'));
        expect(gitconfig, contains('directory = *'));
      } finally {
        await h.dispose();
      }
    });

    test('setup is idempotent and repairs stale links', () async {
      final h = await _makeHarness();
      try {
        final binDir = Directory('${h.engineDir}/tools/bin');
        await binDir.create(recursive: true);
        // A stale symlink and a regular file where links belong.
        await Link(
          '${binDir.path}/git',
        ).create('/nowhere/libgit.so');
        await File('${binDir.path}/rg').writeAsString('not a link');
        expect(await h.backend.hasTool('git'), isTrue);
        expect(await h.backend.hasTool('rg'), isTrue);
        expect(
          await Link('${binDir.path}/git').target(),
          '${h.nativeLib.path}/libgit.so',
        );
        expect(
          await Link('${binDir.path}/rg').target(),
          '${h.nativeLib.path}/librg.so',
        );
        // Second setup: no re-extraction, no .gitconfig rewrite.
        final extractorCalls = h.extractor.extractCalls;
        final gitconfig = File('${h.engineDir}/home/.gitconfig');
        await gitconfig.writeAsString('[user]\n\tname = Keeper\n');
        expect(await h.backend.hasTool('node'), isTrue);
        expect(h.extractor.extractCalls, extractorCalls);
        expect(await gitconfig.readAsString(), contains('Keeper'));
        expect(h.paths.fetchCalls, 1, reason: 'setup is cached');
      } finally {
        await h.dispose();
      }
    });

    test('reports unavailable when the bundle is not staged', () async {
      final h = await _makeHarness(withLibs: false);
      try {
        expect(await h.backend.hasTool('git'), isFalse);
        expect(await h.backend.hasTool('node'), isFalse);
        final result = await h.backend.run(
          command: 'git --version',
          workspaceRoot: '/tmp',
          cwd: '/tmp',
        );
        expect(result.backend, 'bundled');
        expect(result.ok, isFalse);
        expect(result.exitCode, 127);
        expect(
          result.error,
          contains(BundledRuntimeBackend.notAvailableMessage),
        );
        expect(h.runner.calls, isEmpty);
        expect(h.extractor.extractCalls, 0);
      } finally {
        await h.dispose();
      }
    });

    test('hasTool is false for tools outside the bundle', () async {
      final h = await _makeHarness();
      try {
        for (final tool in ['flutter', 'cargo', 'gradle', 'ls', 'sh']) {
          expect(
            await h.backend.hasTool(tool),
            isFalse,
            reason: '$tool is not bundled',
          );
        }
        expect(await h.backend.hasTool('git; rm -rf /'), isFalse);
      } finally {
        await h.dispose();
      }
    });
  });

  group('BundledRuntimeBackend.run', () {
    test('runs through sh with the preamble, env and cwd', () async {
      final h = await _makeHarness();
      try {
        final seen = <String>[];
        final result = await h.backend.run(
          command: 'npm test',
          workspaceRoot: '/tmp',
          cwd: '/tmp/work',
          timeoutSeconds: 30,
          env: {'FOO': 'bar'},
          onOutput: (channel, chunk) => seen.add('$channel:$chunk'),
        );
        expect(result.backend, 'bundled');
        expect(result.ok, isTrue);
        expect(result.stdout, 'ok\n');
        expect(seen, ['stdout:ok\n']);
        expect(h.runner.calls, hasLength(1));
        final call = h.runner.calls.single;
        expect(call['executable'], '/bin/sh');
        final args = call['arguments'] as List<String>;
        expect(args.first, '-c');
        expect(
          args[1],
          startsWith(
            BundledRuntimeBackend.shellPreamble(h.engineDir),
          ),
        );
        expect(args[1], endsWith('npm test'));
        expect(call['workingDirectory'], '/tmp/work');
        expect(call['timeout'], const Duration(seconds: 30));
        final env = call['environment'] as Map<String, String>;
        expect(env['PATH'], startsWith('${h.engineDir}/tools/bin:'));
        expect(env['GIT_EXEC_PATH'], '${h.engineDir}/git-core');
        expect(env['FOO'], 'bar');
      } finally {
        await h.dispose();
      }
    });

    test('clamps the timeout to 1-120 seconds', () async {
      final h = await _makeHarness();
      try {
        await h.backend.run(
          command: 'git status',
          workspaceRoot: '/tmp',
          cwd: '/tmp',
          timeoutSeconds: 500,
        );
        await h.backend.run(
          command: 'git status',
          workspaceRoot: '/tmp',
          cwd: '/tmp',
          timeoutSeconds: 0,
        );
        expect(h.runner.calls, hasLength(2));
        expect(
          h.runner.calls[0]['timeout'],
          const Duration(seconds: 120),
        );
        expect(
          h.runner.calls[1]['timeout'],
          const Duration(seconds: 1),
        );
      } finally {
        await h.dispose();
      }
    });

    test('reports a runner timeout as exit 124', () async {
      final h = await _makeHarness();
      try {
        h.runner.resultToReturn = const BundledProcessResult(
          stdout: '',
          stderr: '',
          exitCode: -15,
          timedOut: true,
        );
        final result = await h.backend.run(
          command: 'git status',
          workspaceRoot: '/tmp',
          cwd: '/tmp',
        );
        expect(result.exitCode, 124);
        expect(result.ok, isFalse);
        expect(result.error, contains('timed out'));
      } finally {
        await h.dispose();
      }
    });

    test('propagates truncation flags from the runner', () async {
      final h = await _makeHarness();
      try {
        h.runner.resultToReturn = const BundledProcessResult(
          stdout: 'x',
          exitCode: 0,
          stdoutTruncated: true,
        );
        final result = await h.backend.run(
          command: 'git status',
          workspaceRoot: '/tmp',
          cwd: '/tmp',
        );
        expect(result.stdoutTruncated, isTrue);
        expect(result.stderrTruncated, isFalse);
      } finally {
        await h.dispose();
      }
    });

    test('rejects oversized commands without running anything', () async {
      final h = await _makeHarness();
      try {
        final result = await h.backend.run(
          command: 'x' * 32001,
          workspaceRoot: '/tmp',
          cwd: '/tmp',
        );
        expect(result.exitCode, 125);
        expect(result.ok, isFalse);
        expect(h.runner.calls, isEmpty);
      } finally {
        await h.dispose();
      }
    });

    test('cancelActiveCommand reaches the runner', () async {
      final h = await _makeHarness();
      try {
        await h.backend.cancelActiveCommand();
        expect(h.runner.cancelCalls, 1);
      } finally {
        await h.dispose();
      }
    });
  });

  group('RuntimeService with the real bundled backend', () {
    test('selects bundled for a bundled tool, termux otherwise',
        () async {
      final h = await _makeHarness();
      try {
        final runtime = RuntimeService(
          bundled: h.backend,
          termux: FakeTermuxBackend(tools: {'flutter'}),
        );
        final git = await runtime.run(
          command: 'git --version',
          workspaceRoot: '/tmp',
          workingDirectory: '/tmp',
        );
        expect(git.backend, 'bundled');
        expect(git.stdout, 'ok\n');
        final probe = await runtime.probeTool(
          'node',
          workspaceRoot: '/tmp',
          cwd: '/tmp',
        );
        expect(probe.available, isTrue);
        expect(probe.backend, 'bundled');
        expect(probe.version, 'ok');
      } finally {
        await h.dispose();
      }
    });

    test('invalidateToolCache re-selects after a tool is staged',
        () async {
      // ffmpeg is NOT staged yet: selection falls to termux.
      final h = await _makeHarness(
        libs: BundledRuntimeBackend.bundledTools.values.toSet().toList()
          ..remove('libffmpeg.so'),
      );
      try {
        final termux = FakeTermuxBackend(tools: {'ffmpeg'});
        final runtime = RuntimeService(bundled: h.backend, termux: termux);
        expect(
          await runtime.selectBackendForTool('ffmpeg'),
          'termux',
        );
        // Stage ffmpeg, then invalidate: the next selection is bundled.
        await File('${h.nativeLib.path}/libffmpeg.so').writeAsString('');
        runtime.invalidateToolCache('ffmpeg');
        expect(
          await runtime.selectBackendForTool('ffmpeg'),
          'bundled',
        );
      } finally {
        await h.dispose();
      }
    });
  });

  group('BundledProcessRunner (real, host shell)', () {
    test('runs a command through the real Process implementation',
        () async {
      final h = await _makeHarness();
      try {
        final real = BundledRuntimeBackend(
          pathsProvider: h.paths,
          processRunner: ProcessBundledProcessRunner(),
          assetExtractor: h.extractor,
          shellExecutable: '/bin/sh',
        );
        final result = await real.run(
          command: 'echo hello-bundled',
          workspaceRoot: '/tmp',
          cwd: h.root.path,
        );
        expect(result.backend, 'bundled');
        expect(result.ok, isTrue);
        expect(result.stdout, 'hello-bundled\n');
        expect(result.exitCode, 0);
      } finally {
        await h.dispose();
      }
    });

    test('truncates output at 16 KB per stream', () async {
      final h = await _makeHarness();
      try {
        final real = BundledRuntimeBackend(
          pathsProvider: h.paths,
          processRunner: ProcessBundledProcessRunner(),
          assetExtractor: h.extractor,
          shellExecutable: '/bin/sh',
        );
        final result = await real.run(
          // Deterministic 20 KB producer that exits on its own
          // (an infinite producer such as `yes` depends on SIGPIPE
          // timing and stalls the stream drain under load).
          // Host PATH: the bundled env points at Android's /system/bin,
          // which does not exist on the VM running this test.
          command: "head -c 20000 /dev/zero | tr '\\0' 'x'",
          workspaceRoot: '/tmp',
          cwd: h.root.path,
          env: const {'PATH': '/usr/bin:/bin'},
        );
        expect(result.ok, isTrue);
        expect(result.stdout.length, RuntimeService.maxOutputCharsPerStream);
        expect(result.stdoutTruncated, isTrue);
        expect(result.stderrTruncated, isFalse);
      } finally {
        await h.dispose();
      }
    });

    test('reports a timeout as exit 124', () async {
      final h = await _makeHarness();
      try {
        final real = BundledRuntimeBackend(
          pathsProvider: h.paths,
          processRunner: ProcessBundledProcessRunner(),
          assetExtractor: h.extractor,
          shellExecutable: '/bin/sh',
        );
        final result = await real.run(
          command: 'sleep 30',
          workspaceRoot: '/tmp',
          cwd: h.root.path,
          timeoutSeconds: 1,
          // Host PATH (see the truncation test): the bundled env
          // points at Android's /system/bin, so `sleep` would be
          // "not found" on the VM without this override.
          env: const {'PATH': '/usr/bin:/bin'},
        );
        expect(result.exitCode, 124);
        expect(result.ok, isFalse);
        expect(result.error, contains('timed out'));
      } finally {
        await h.dispose();
      }
    });

    test('propagates a non-zero exit code and stderr', () async {
      final h = await _makeHarness();
      try {
        final real = BundledRuntimeBackend(
          pathsProvider: h.paths,
          processRunner: ProcessBundledProcessRunner(),
          assetExtractor: h.extractor,
          shellExecutable: '/bin/sh',
        );
        final result = await real.run(
          command: 'echo oops >&2; exit 3',
          workspaceRoot: '/tmp',
          cwd: h.root.path,
        );
        expect(result.exitCode, 3);
        expect(result.ok, isFalse);
        expect(result.stderr, contains('oops'));
      } finally {
        await h.dispose();
      }
    });
  });
}

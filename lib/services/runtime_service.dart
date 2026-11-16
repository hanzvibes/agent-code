import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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

/// Paths the Android side reports for the bundled runtime.
///
/// `nativeLibraryDir` is the only location Android 10+ lets the app
/// execute from; the bundled `.so` files live there after install.
/// `filesDir` / `cacheDir` are the app-private directories the runtime
/// layout (`engine/...`) is built under.
class BundledRuntimePaths {
  final String nativeLibraryDir;
  final String filesDir;
  final String cacheDir;

  const BundledRuntimePaths({
    required this.nativeLibraryDir,
    required this.filesDir,
    required this.cacheDir,
  });
}

/// Source of [BundledRuntimePaths]. The default implementation asks the
/// Android side over a MethodChannel; tests inject fixed paths.
abstract interface class BundledRuntimePathsProvider {
  Future<BundledRuntimePaths?> fetch();
}

class _MethodChannelBundledRuntimePathsProvider
    implements BundledRuntimePathsProvider {
  const _MethodChannelBundledRuntimePathsProvider();

  static const MethodChannel _channel = MethodChannel(
    'dev.codeharness/bundled_runtime',
  );

  @override
  Future<BundledRuntimePaths?> fetch() async {
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'getRuntimePaths',
      );
      final nativeLibraryDir = response?['nativeLibraryDir'] as String?;
      final filesDir = response?['filesDir'] as String?;
      final cacheDir = response?['cacheDir'] as String?;
      if (nativeLibraryDir == null || filesDir == null || cacheDir == null) {
        return null;
      }
      return BundledRuntimePaths(
        nativeLibraryDir: nativeLibraryDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );
    } on PlatformException {
      // No handler (old build, plain unit test): no bundled runtime.
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Result of one process run through a [BundledProcessRunner].
class BundledProcessResult {
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  const BundledProcessResult({
    this.stdout = '',
    this.stderr = '',
    required this.exitCode,
    this.timedOut = false,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
  });
}

/// Runs one child process for the bundled backend. The default
/// implementation uses `dart:io` [Process]; tests inject a fake so no
/// real process is ever started.
abstract interface class BundledProcessRunner {
  Future<BundledProcessResult> run({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required Duration timeout,
    void Function(String channel, String chunk)? onOutput,
  });

  /// Terminates the active process, if any. A cancel that arrives
  /// before the process starts kills it as soon as it does.
  void cancel();
}

/// Default [BundledProcessRunner]: runs the child with `dart:io`
/// [Process] and enforces the shared output/timeout limits.
class ProcessBundledProcessRunner implements BundledProcessRunner {
  Process? _active;
  bool _cancelRequested = false;

  @override
  Future<BundledProcessResult> run({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
    required Duration timeout,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    _active = process;
    if (_cancelRequested) {
      _cancelRequested = false;
      process.kill(ProcessSignal.sigterm);
    }
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    var stdoutTruncated = false;
    var stderrTruncated = false;

    void append(String channel, String chunk) {
      final buffer = channel == 'stderr' ? stderrBuffer : stdoutBuffer;
      final remaining =
          RuntimeService.maxOutputCharsPerStream - buffer.length;
      if (remaining > 0) {
        buffer.write(
          chunk.substring(0, chunk.length.clamp(0, remaining).toInt()),
        );
      }
      if (chunk.length > remaining) {
        if (channel == 'stderr') {
          stderrTruncated = true;
        } else {
          stdoutTruncated = true;
        }
      }
      onOutput?.call(channel, chunk);
    }

    // Malformed bytes become U+FFFD instead of failing the whole run:
    // tool output is not guaranteed to be valid UTF-8.
    const decoder = Utf8Decoder(allowMalformed: true);
    final stdoutSub = process.stdout
        .transform(decoder)
        .listen((chunk) => append('stdout', chunk));
    final stderrSub = process.stderr
        .transform(decoder)
        .listen((chunk) => append('stderr', chunk));
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      Timer(const Duration(seconds: 2), () {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {
          // Already gone.
        }
      });
    });
    try {
      final exitCode = await process.exitCode;
      // The exit-code future can complete before the last output
      // chunks are delivered; wait for both streams to close. The
      // guard is generous on purpose: under load the event loop can
      // be slow to deliver the final chunks, and a stuck pipe (a
      // child that outlives the shell holding stdout open) must not
      // hang the backend forever.
      await Future.wait([
        stdoutSub.asFuture().timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        ),
        stderrSub.asFuture().timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        ),
      ]);
      return BundledProcessResult(
        stdout: stdoutBuffer.toString(),
        stderr: stderrBuffer.toString(),
        exitCode: timedOut ? 124 : exitCode,
        timedOut: timedOut,
        stdoutTruncated: stdoutTruncated,
        stderrTruncated: stderrTruncated,
      );
    } finally {
      timer.cancel();
      await stdoutSub.cancel();
      await stderrSub.cancel();
      if (_active == process) _active = null;
    }
  }

  @override
  void cancel() {
    final process = _active;
    if (process == null) {
      _cancelRequested = true;
      return;
    }
    process.kill(ProcessSignal.sigterm);
  }
}

/// Copies the bundled Tier 2 assets (node tree, python stdlib,
/// git templates) into the runtime layout. The default implementation
/// reads them from the Flutter asset bundle; tests inject a fake.
abstract interface class BundledAssetExtractor {
  /// Copies every file listed in the bundled `assets/tier2-manifest.txt`
  /// into [engineDir] (`node/` → `engineDir/node`, …).
  /// Returns the number of files copied.
  Future<int> extractAssets(String engineDir);

  /// Reads one bundled text asset by its Flutter asset path
  /// (for example `assets/git-core-links.txt`).
  Future<String> readTextAsset(String assetPath);
}

class _RootBundleAssetExtractor implements BundledAssetExtractor {
  const _RootBundleAssetExtractor();

  static const String _manifestAsset = 'assets/tier2-manifest.txt';

  @override
  Future<int> extractAssets(String engineDir) async {
    final manifest = await rootBundle.loadString(_manifestAsset);
    var count = 0;
    for (final line in manifest.split('\n')) {
      final relative = line.trim();
      if (relative.isEmpty) continue;
      final data = await rootBundle.load('assets/$relative');
      final target = File('$engineDir/$relative');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      count++;
    }
    return count;
  }

  @override
  Future<String> readTextAsset(String assetPath) =>
      rootBundle.loadString(assetPath);
}

/// Bundled backend (Tier 2 — desain D5): tools shipped inside the APK
/// as `jniLibs/lib*.so`, run from `nativeLibraryDir`.
///
/// Layout (opencode-android recipe, proven there in Kotlin;
/// the Dart `Process` call itself is still to be proven on a device —
/// see the PR body):
///
/// ```
/// filesDir/engine/
///   home/                 HOME (.gitconfig lives here)
///   node/                 assets/node (npm tree + CA bundle)
///   python/               assets/python (stdlib + pip)
///   git-templates/        assets/git-templates (for `git init`)
///   tools/bin/            symlinks to nativeLibraryDir/lib*.so (PATH)
///   git-core/             symlinks recreated from git-core-links.txt
/// cacheDir/engine-tmp/    TMPDIR
/// ```
///
/// Symlinks are load-bearing: since Android 10 only `nativeLibraryDir`
/// may be executed, and a copy/hard link into `filesDir` fails with
/// EACCES under SELinux while a symlink keeps the target's label.
/// Setup is idempotent — links that already point at the right target
/// are left alone — and runs once per backend instance.
///
/// Tools without their own binary (`npm`, `npx`, `pip`) are shell
/// functions defined in the command preamble (see [shellPreamble]):
/// `npm` → `node …/npm-cli.js`, `pip` → `python3 -m pip`.
class BundledRuntimeBackend implements RuntimeBackend {
  static const String notAvailableMessage =
      'Bundled runtime is not available yet: the Tier 2 bundled '
      'toolchain has not been installed in this build, so the command '
      'was not run. Use the Termux backend instead (it needs the '
      'Termux app and a project under shared storage).';

  /// Bumped when the staged assets change; a mismatch re-extracts them.
  static const String assetsVersion = 'tier2-v1';

  /// Tool name → staged library in `nativeLibraryDir`.
  ///
  /// `npm`/`npx` share `libnode.so` and `pip` shares `libpython3.so`:
  /// they have no binary of their own and are provided as shell
  /// functions (see [shellPreamble]), but [hasTool] still answers
  /// true for them when the underlying binary is staged.
  static const Map<String, String> bundledTools = {
    'git': 'libgit.so',
    'rg': 'librg.so',
    'node': 'libnode.so',
    'npm': 'libnode.so',
    'npx': 'libnode.so',
    'python3': 'libpython3.so',
    'pip': 'libpython3.so',
    'jq': 'libjq-cli.so',
    'curl': 'libcurl-cli.so',
    'xz': 'libxz.so',
    'tar': 'libtar.so',
    'ffmpeg': 'libffmpeg.so',
    'ffprobe': 'libffprobe.so',
  };

  /// Tools that are only a shell function, not a symlink in `tools/bin`.
  static const Set<String> _functionTools = {'npm', 'npx', 'pip'};

  /// git-core helper binaries staged as `libgit-<name>.so`
  /// (coordinator decision, desain D5): without them and
  /// `GIT_EXEC_PATH`, `git clone`/`fetch`/`push` over HTTPS cannot
  /// find `git-remote-https`.
  static const Map<String, String> _gitHelpers = {
    'git-remote-http': 'libgit-remote-http.so',
    'git-http-fetch': 'libgit-http-fetch.so',
    'git-http-push': 'libgit-http-push.so',
    'git-daemon': 'libgit-daemon.so',
    'git-http-backend': 'libgit-http-backend.so',
    'git-imap-send': 'libgit-imap-send.so',
    'git-sh-i18n--envsubst': 'libgit-sh-i18n--envsubst.so',
  };

  /// git-remote helpers are symlinks to `git-remote-http` in the
  /// Termux package; the runtime recreates them that way.
  static const Set<String> _gitRemoteHelpers = {
    'git-remote-https',
    'git-remote-ftp',
    'git-remote-ftps',
  };

  /// `.gitconfig` written to the engine HOME on first setup (only when
  /// the file does not exist yet, so a user-set identity is kept).
  /// `fileMode=false`: the app-private storage ignores chmod;
  /// `safe.directory=*`: workspaces live outside the usual trust roots.
  static const String bundledGitConfig =
      '# Written by Code Harness (Tier 2 bundled runtime).\n'
      '[core]\n'
      '\tfileMode = false\n'
      '[safe]\n'
      '\tdirectory = *\n';

  final BundledRuntimePathsProvider _pathsProvider;
  final BundledProcessRunner _runner;
  final BundledAssetExtractor _assetExtractor;
  final String _shellExecutable;

  Future<_BundledSetup?>? _setupFuture;

  BundledRuntimeBackend({
    BundledRuntimePathsProvider? pathsProvider,
    BundledProcessRunner? processRunner,
    BundledAssetExtractor? assetExtractor,
    String shellExecutable = '/system/bin/sh',
  }) : _pathsProvider =
           pathsProvider ?? const _MethodChannelBundledRuntimePathsProvider(),
       _runner = processRunner ?? ProcessBundledProcessRunner(),
       _assetExtractor =
           assetExtractor ?? const _RootBundleAssetExtractor(),
       _shellExecutable = shellExecutable;

  @override
  String get name => 'bundled';

  /// Child-process environment for the bundled runtime (pure, so
  /// tests can assert it without any setup).
  ///
  /// Mirrors opencode-android's `EngineEnvironment.variables()`, plus
  /// `GIT_EXEC_PATH` / `GIT_TEMPLATE_DIR` (the git-core decision) and
  /// `GIT_CONFIG_NOSYSTEM` (there is no usable system gitconfig on
  /// the device).
  static Map<String, String> buildEnvironment({
    required String nativeLibraryDir,
    required String engineDir,
    required String tmpDir,
  }) {
    final home = '$engineDir/home';
    return {
      'HOME': home,
      'TMPDIR': tmpDir,
      'XDG_DATA_HOME': '$home/.local/share',
      'XDG_CACHE_HOME': '$home/.cache',
      'XDG_CONFIG_HOME': '$home/.config',
      'PATH': '$engineDir/tools/bin:/system/bin:/system/xbin:/vendor/bin',
      'LANG': 'C.UTF-8',
      'SHELL': '/system/bin/sh',
      'SSL_CERT_FILE': '$engineDir/node/etc/tls/cert.pem',
      'PYTHONHOME': '$engineDir/python',
      'LD_LIBRARY_PATH': nativeLibraryDir,
      'GIT_EXEC_PATH': '$engineDir/git-core',
      'GIT_TEMPLATE_DIR': '$engineDir/git-templates',
      'GIT_CONFIG_NOSYSTEM': '1',
    };
  }

  /// Shell-function preamble prepended to every command run through
  /// `/system/bin/sh -c` (not shown to the user: the recorded command
  /// stays as typed). Provides `npm`/`npx`/`pip`, which have no binary
  /// of their own — the `bin/npm` wrapper ships a dead Termux shebang.
  static String shellPreamble(String engineDir) {
    final npmCli =
        '$engineDir/node/lib/node_modules/npm/bin/npm-cli.js';
    final npxCli =
        '$engineDir/node/lib/node_modules/npm/bin/npx-cli.js';
    return "npm() { node '$npmCli' \"\$@\"; }\n"
        "npx() { node '$npxCli' \"\$@\"; }\n"
        "pip() { python3 -m pip \"\$@\"; }\n";
  }

  @override
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    required String cwd,
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    // workspaceRoot is ignored: the bundled backend only uses cwd
    // (see the interface note on RuntimeBackend.run).
    final trimmed = command.trim();
    if (trimmed.length > RuntimeService.maxCommandChars) {
      return const CommandResult(
        exitCode: 125,
        error: 'Command is too long (maximum 32,000 characters).',
        backend: 'bundled',
      );
    }
    final setup = await _ensureSetup();
    if (setup == null) {
      return const CommandResult(
        exitCode: 127,
        error: notAvailableMessage,
        backend: 'bundled',
      );
    }
    final timeout = timeoutSeconds
        .clamp(
          RuntimeService.minTimeoutSeconds,
          RuntimeService.maxTimeoutSeconds,
        )
        .toInt();
    final environment = buildEnvironment(
      nativeLibraryDir: setup.nativeLibraryDir,
      engineDir: setup.engineDir,
      tmpDir: setup.tmpDir,
    );
    if (env != null) environment.addAll(env);
    final result = await _runner.run(
      executable: _shellExecutable,
      arguments: ['-c', '${shellPreamble(setup.engineDir)}$trimmed'],
      workingDirectory: cwd,
      environment: environment,
      timeout: Duration(seconds: timeout),
      onOutput: onOutput,
    );
    return CommandResult(
      stdout: result.stdout,
      stderr: result.stderr,
      // A runner reports a timeout with the raw signal exit code
      // (for example -15); the backend normalises it to 124, the
      // same code `timeout(1)` uses.
      exitCode: result.timedOut ? 124 : result.exitCode,
      error: result.timedOut
          ? 'Command timed out after $timeout seconds.'
          : null,
      backend: name,
      stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated,
    );
  }

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async {
    if (!TermuxRuntimeBackend._isSafeToolName(name)) return false;
    final lib = bundledTools[name];
    if (lib == null) return false;
    final setup = await _ensureSetup();
    if (setup == null) return false;
    return File('${setup.nativeLibraryDir}/$lib').existsSync();
  }

  @override
  Future<void> cancelActiveCommand() async {
    _runner.cancel();
  }

  /// Runs the one-time setup (or returns the cached result, including
  /// a cached "unavailable"). Null means this build has no Tier 2
  /// bundle — every call then reports [notAvailableMessage].
  Future<_BundledSetup?> _ensureSetup() =>
      _setupFuture ??= _doSetup();

  Future<_BundledSetup?> _doSetup() async {
    final BundledRuntimePaths? paths;
    try {
      paths = await _pathsProvider.fetch();
    } catch (_) {
      return null;
    }
    if (paths == null) return null;
    // Availability probe: the marker library of the Tier 2 bundle.
    // A build without jniLibs (for example armeabi-v7a) has no
    // bundled runtime at all.
    if (!File('${paths.nativeLibraryDir}/libgit.so').existsSync()) {
      return null;
    }
    final engineDir = '${paths.filesDir}/engine';
    final tmpDir = '${paths.cacheDir}/engine-tmp';
    try {
      await Directory('$engineDir/tools/bin').create(recursive: true);
      await Directory('$engineDir/git-core').create(recursive: true);
      await Directory(tmpDir).create(recursive: true);
      await _extractAssetsIfNeeded(engineDir);
      await _linkTools(paths.nativeLibraryDir, engineDir);
      await _linkGitCore(engineDir);
      await _writeGitConfig('$engineDir/home');
    } catch (_) {
      return null;
    }
    return _BundledSetup(
      nativeLibraryDir: paths.nativeLibraryDir,
      engineDir: engineDir,
      tmpDir: tmpDir,
    );
  }

  Future<void> _extractAssetsIfNeeded(String engineDir) async {
    final marker = File('$engineDir/.tier2-assets-version');
    try {
      if (await marker.exists() &&
          await marker.readAsString() == assetsVersion) {
        return;
      }
    } catch (_) {
      // Missing or unreadable marker: extract below.
    }
    final count = await _assetExtractor.extractAssets(engineDir);
    if (count <= 0) {
      throw StateError('Tier 2 asset extraction copied no files.');
    }
    await marker.writeAsString(assetsVersion);
  }

  Future<void> _linkTools(String nativeLibraryDir, String engineDir) async {
    final binDir = '$engineDir/tools/bin';
    final links = <String, String>{};
    for (final entry in bundledTools.entries) {
      if (_functionTools.contains(entry.key)) continue;
      links[entry.key] = entry.value;
    }
    links.addAll(_gitHelpers);
    for (final entry in links.entries) {
      await _ensureSymlink(
        '$binDir/${entry.key}',
        '$nativeLibraryDir/${entry.value}',
      );
    }
  }

  Future<void> _linkGitCore(String engineDir) async {
    final gitCoreDir = '$engineDir/git-core';
    final binDir = '$engineDir/tools/bin';
    final linksText = await _assetExtractor.readTextAsset(
      'assets/git-core-links.txt',
    );
    for (final line in linksText.split('\n')) {
      final name = line.trim();
      if (name.isEmpty) continue;
      final target = _gitRemoteHelpers.contains(name)
          ? '$binDir/git-remote-http'
          : '$binDir/git';
      await _ensureSymlink('$gitCoreDir/$name', target);
    }
  }

  Future<void> _writeGitConfig(String homeDir) async {
    final config = File('$homeDir/.gitconfig');
    await config.parent.create(recursive: true);
    if (await config.exists()) return;
    await config.writeAsString(bundledGitConfig);
  }

  /// Creates (or repairs) a symlink, leaving it alone when it already
  /// points at [target]. A stale link is replaced; a regular file (or
  /// anything else) sitting where the link belongs is removed first —
  /// `Link.delete()` refuses non-links (EINVAL), so the removal falls
  /// back to `File.delete()` for that case.
  static Future<void> _ensureSymlink(
    String linkPath,
    String target,
  ) async {
    final link = Link(linkPath);
    try {
      if (await link.target() == target) return;
    } on FileSystemException {
      // No link yet, or not a link at all: (re)create it below.
    }
    await link.parent.create(recursive: true);
    try {
      await link.delete();
    } on FileSystemException {
      try {
        await File(linkPath).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
    await link.create(target);
  }
}

/// The resolved, ready-to-use bundled runtime layout.
class _BundledSetup {
  final String nativeLibraryDir;
  final String engineDir;
  final String tmpDir;

  const _BundledSetup({
    required this.nativeLibraryDir,
    required this.engineDir,
    required this.tmpDir,
  });
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

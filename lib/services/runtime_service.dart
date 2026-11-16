import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Result of one command run through [RuntimeService].
///
/// Carries the backend that actually ran the command (`bundled`,
/// or `none` when no backend could run it), so the timeline
/// and the model can tell where a command executed.
class CommandResult {
  final String stdout;
  final String stderr;
  final int exitCode;

  /// Human-readable failure reason (timeout, backend
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

  /// Backend that has the tool (`bundled`), or `none`.
  final String backend;

  /// Why a bundled tool is unavailable (for example the bundled
  /// runtime failed to set up on this device). Null when the tool
  /// simply is not in the bundle, or when the probe succeeded.
  final String? detail;

  const ToolProbe({
    required this.tool,
    required this.available,
    this.version,
    required this.backend,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
    'tool': tool,
    'available': available,
    'version': version,
    'backend': backend,
    if (detail != null) 'detail': detail,
  };
}

/// One command-execution backend (Batch 3 — desain D5).
///
/// The interface Tier 2 implements against: the bundled backend runs
/// tools shipped inside the APK (see `BundledRuntimeBackend`). It is
/// the only backend — there is no fallback. Backends must enforce the
/// shared limits — command 1–120 s, 32 KB, output 16 KB per stream —
/// so callers can rely on them.
///
/// NOTE (interface decision, see PR body): `run` takes both
/// [workspaceRoot] and [cwd]. The bundled backend ignores the root
/// and only uses [cwd]. Callers always pass the workspace root and
/// the absolute working directory inside it.
abstract interface class RuntimeBackend {
  /// Stable id recorded in [CommandResult.backend]: `bundled`, …
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
  /// builtin). Used for backend selection and probing.
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  });

  /// Cancels the backend's active command, if any. Backends without
  /// a cancellable command do nothing.
  Future<void> cancelActiveCommand();
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
      'was not run.';

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
    // Option B: the staged bash is the bundled runtime's default
    // shell (see [run]); it also makes `bash <script>` runnable.
    'bash': 'libbash.so',
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
  /// upstream package; the runtime recreates them that way.
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

  /// Shell the backend was built with. The default is the device
  /// shell; [run] replaces it with the staged bash symlink whenever
  /// the default is in use. Tests inject their own shell here.
  static const String _defaultShellExecutable = '/system/bin/sh';
  final String _shellExecutable;

  Future<_BundledSetup?>? _setupFuture;

  /// Why the last setup failed, or null when setup succeeded (or
  /// never ran). Read after [hasTool]/[run] so the cached setup has
  /// run: a null setup leaves every tool unavailable with no other
  /// trace, so the reason is what makes a tablet failure
  /// diagnosable (for example the marker library missing from
  /// nativeLibraryDir because the APK was built without extracted
  /// native libraries).
  String? _setupFailureReason;

  /// Why the bundled runtime is unavailable, or null when it is
  /// ready. See [_setupFailureReason].
  String? get setupFailureReason => _setupFailureReason;

  BundledRuntimeBackend({
    BundledRuntimePathsProvider? pathsProvider,
    BundledProcessRunner? processRunner,
    BundledAssetExtractor? assetExtractor,
    String shellExecutable = _defaultShellExecutable,
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
      'SHELL': '$engineDir/tools/bin/bash',
      'SSL_CERT_FILE': '$engineDir/node/etc/tls/cert.pem',
      'PYTHONHOME': '$engineDir/python',
      'LD_LIBRARY_PATH': nativeLibraryDir,
      'GIT_EXEC_PATH': '$engineDir/git-core',
      'GIT_TEMPLATE_DIR': '$engineDir/git-templates',
      'GIT_CONFIG_NOSYSTEM': '1',
    };
  }

  /// Shell-function preamble prepended to every command run through
  /// the bundled bash (`tools/bin/bash -c`; `/system/bin/sh` only as
  /// a fallback when the bash link is missing — see [run]). It is not
  /// shown to the user: the recorded command stays as typed.
  /// Provides `npm`/`npx`/`pip`, which have no binary of their own —
  /// the `bin/npm` wrapper ships a shebang pointing outside the
  /// bundle, so it cannot run directly.
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
      return CommandResult(
        exitCode: 127,
        error: _setupFailureReason == null
            ? notAvailableMessage
            : '$notAvailableMessage $_setupFailureReason',
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
    // Bash is the bundled shell (Option B): run through the staged
    // `tools/bin/bash` symlink. A test-injected shell still wins, and
    // a missing symlink falls back to the device shell.
    final shell = _shellExecutable == _defaultShellExecutable
        ? (File('${setup.engineDir}/tools/bin/bash').existsSync()
              ? '${setup.engineDir}/tools/bin/bash'
              : _defaultShellExecutable)
        : _shellExecutable;
    final result = await _runner.run(
      executable: shell,
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
    if (!RuntimeService.isSafeToolName(name)) return false;
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
      _setupFailureReason =
          'Could not read the bundled runtime paths from the '
          'Android side.';
      return null;
    }
    if (paths == null) {
      _setupFailureReason =
          'The Android side reported no bundled runtime paths.';
      return null;
    }
    // Availability probe: the marker library of the Tier 2 bundle.
    // A build without jniLibs (for example armeabi-v7a) has no
    // bundled runtime at all.
    if (!File('${paths.nativeLibraryDir}/libgit.so').existsSync()) {
      _setupFailureReason =
          'libgit.so is missing from nativeLibraryDir '
          '(${paths.nativeLibraryDir}): the APK was built without '
          'extracted native libraries (android:extractNativeLibs '
          'must be true) so the bundled tools were never extracted '
          'to the device.';
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
    } catch (e) {
      _setupFailureReason =
          'Bundled runtime setup failed while staging the tools ($e).';
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
/// straight to a backend. The service picks the bundled backend when
/// it can run the command's tool, and records the choice in
/// [CommandResult.backend]. There is no fallback backend: a command
/// whose tool is not bundled fails with exit 127 and a message
/// naming the missing tool (see [missingToolMessage]) instead of
/// running anywhere.
///
/// Selection rule: the first real command word of the command (see
/// [_firstRealCommandWord] — shell builtins and `FOO=bar` prefixes
/// are skipped, so `cd x && npm install` selects on `npm`). A
/// bundled tool, or a common system applet that resolves via the
/// bundled PATH, runs through the bundled shell; anything else is
/// refused before it runs. Compound commands whose LATER tool is
/// missing (for example `npm install && make build`) are NOT caught
/// here — they fail inside bash with "command not found".
/// The chosen backend per tool is cached for the service lifetime;
/// call [invalidateToolCache] when a backend gains tools (Tier 2
/// staging does this after linking a new tool).
class RuntimeService {
  /// Shared limits (desain §2 / D5): commands 1–120 s, 32 KB,
  /// output 16 KB per stream. The bundled backend enforces them.
  static const int maxCommandChars = 32000;
  static const int maxOutputCharsPerStream = 16000;
  static const int minTimeoutSeconds = 1;
  static const int maxTimeoutSeconds = 120;

  static const String noBackendName = 'none';

  /// True when [name] is a safe bare tool name (no path, no shell
  /// metacharacters). Guards [probeTool] and backend `hasTool`
  /// against injection through the tool name.
  static bool isSafeToolName(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$').hasMatch(name);

  /// Message returned (exit 127, backend `none`) when a command
  /// needs a tool the bundled runtime does not have. Nothing is run.
  static String missingToolMessage(String tool) =>
      'Tool "$tool" is not available in the bundled runtime: the '
      'command was not run. Bundled tools: '
      '${BundledRuntimeBackend.bundledTools.keys.join(', ')}. '
      'Run probe_toolchain to see what is available.';

  /// Shell keywords/builtins that name no external tool: the
  /// selector skips them (and their arguments) and looks at the next
  /// command segment instead. Bash itself runs these.
  static const Set<String> _skippedBuiltins = {
    // Required by the design: prefixes and builtins an agent
    // command commonly starts with (`cd x && npm install`).
    'cd',
    'export',
    'unset',
    'source',
    '.',
    'test',
    '[',
    'true',
    'false',
    'set',
    'eval',
    'exec',
    'echo',
    // Other bash builtins/keywords: they name no external tool
    // either, so a command made only of them still runs in bash
    // (for example `echo oops >&2; exit 3`, `if …; then npm test`).
    'exit',
    'return',
    'shift',
    'break',
    'continue',
    'trap',
    'alias',
    'unalias',
    'readonly',
    'local',
    'declare',
    'typeset',
    'pushd',
    'popd',
    'dirs',
    'jobs',
    'wait',
    'kill',
    'disown',
    'umask',
    'ulimit',
    'history',
    'command',
    'builtin',
    'type',
    'hash',
    'help',
    'logout',
    'suspend',
    'bg',
    'fg',
    'getopts',
    'let',
    'read',
    'printf',
    'time',
    'if',
    'then',
    'else',
    'elif',
    'fi',
    'for',
    'while',
    'until',
    'do',
    'done',
    'case',
    'esac',
    'function',
    'select',
    'in',
    '{',
    '}',
    '!',
    '[[',
    ']]',
  };

  /// Common system applets that are not staged tools but resolve via
  /// the bundled PATH (`/system/bin`, `/system/xbin`, `/vendor/bin`),
  /// so they run through the bundled shell like bundled tools do.
  static const Set<String> _systemApplets = {
    'ls',
    'cat',
    'cp',
    'mv',
    'mkdir',
    'rm',
    'pwd',
    'grep',
    'sed',
    'awk',
    'head',
    'tail',
    'wc',
    'sort',
    'find',
    'chmod',
    'env',
    'sleep',
    'date',
    'uname',
    'ps',
    'df',
    'du',
  };

  final RuntimeBackend _bundled;

  /// Backend chosen per tool name (see selection rule above).
  final Map<String, String> _toolBackendCache = {};

  RuntimeBackend? _activeBackend;

  RuntimeService({RuntimeBackend? bundled})
    : _bundled = bundled ?? BundledRuntimeBackend();

  String get bundledBackendName => _bundled.name;

  /// Which backend would run a command needing [tool], honouring the
  /// cache. Does not run anything. Only `bundled` or `none`: a tool
  /// the bundle does not have has no backend.
  Future<String> selectBackendForTool(String tool) async {
    final cached = _toolBackendCache[tool];
    if (cached != null) return cached;
    final name = await _bundled.hasTool(tool)
        ? _bundled.name
        : noBackendName;
    _toolBackendCache[tool] = name;
    return name;
  }

  /// True when the bundled backend has [name]. The workspace context
  /// is accepted for API stability and ignored.
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async =>
      _bundled.hasTool(name, workspaceRoot: workspaceRoot, cwd: cwd);

  /// Why the bundled backend is unavailable, or null when it is
  /// ready (or the backend is not the bundled one). Triggers the
  /// cached one-time setup first, so the reason is recorded by the
  /// time it is read. This is what lets [probeTool] and [run] say
  /// WHY a bundled tool is unavailable instead of only that it is.
  Future<String?> bundledSetupFailureReason() async {
    await _bundled.hasTool('git');
    final backend = _bundled;
    return backend is BundledRuntimeBackend
        ? backend.setupFailureReason
        : null;
  }

  /// Probes one tool: whether the bundle has it and what
  /// `<tool> --version` reports. The version is the first non-empty
  /// output line. A tool the bundle does not have reports
  /// `available: false, backend: 'none'`.
  Future<ToolProbe> probeTool(
    String tool, {
    String workspaceRoot = '',
    String cwd = '',
  }) async {
    if (!isSafeToolName(tool)) {
      return ToolProbe(tool: tool, available: false, backend: noBackendName);
    }
    final backend = await selectBackendForTool(tool);
    if (backend == noBackendName) {
      // A bundled tool with no backend means the setup failed, not
      // that the tool is missing from the bundle: say why, so the
      // failure is diagnosable from the device. A tool the bundle
      // never had keeps detail null.
      final detail = BundledRuntimeBackend.bundledTools.containsKey(tool)
          ? await bundledSetupFailureReason()
          : null;
      return ToolProbe(
        tool: tool,
        available: false,
        backend: noBackendName,
        detail: detail,
      );
    }
    final result = await _bundled.run(
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
  /// [workspaceRoot]) on the bundled backend. The chosen backend is
  /// recorded in the result. A command whose tool is not bundled (and
  /// not a system applet) is refused before it runs: exit 127,
  /// backend `none`, error naming the missing tool.
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
    final tool = _firstRealCommandWord(trimmed);
    if (tool.isNotEmpty && !_systemApplets.contains(tool)) {
      final backendName = await selectBackendForTool(tool);
      if (backendName == noBackendName) {
        // Same distinction as [probeTool]: a bundled tool refused
        // here means the setup failed — name the reason in the
        // error instead of only naming the missing tool.
        final reason = BundledRuntimeBackend.bundledTools.containsKey(tool)
            ? await bundledSetupFailureReason()
            : null;
        return CommandResult(
          exitCode: 127,
          error: reason == null
              ? missingToolMessage(tool)
              : '${missingToolMessage(tool)} $reason',
          backend: noBackendName,
        );
      }
    }
    _activeBackend = _bundled;
    try {
      return await _bundled.run(
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

  /// Cancels the active command on the bundled backend, if any.
  Future<void> cancelActiveCommand() async {
    final backend = _activeBackend;
    if (backend != null) {
      await backend.cancelActiveCommand();
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

  /// First word of [command] that names an external tool, skipping
  /// shell operators, leading `FOO=bar` env assignments, and shell
  /// builtins/keywords (with their arguments — a builtin segment
  /// names no tool). Returns '' when the command is builtins and
  /// assignments only (`echo hi`, `cd sub`), which bash runs itself.
  ///
  /// Examples: `cd x && npm install` → `npm`; `FOO=bar make build`
  /// → `make`; `export FOO=bar; git status` → `git`.
  static String _firstRealCommandWord(String command) {
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;
    void flush() {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    }

    for (var i = 0; i < command.length; i++) {
      final ch = command[i];
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        continue;
      }
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        flush();
        continue;
      }
      if (ch == '&' ||
          ch == '|' ||
          ch == ';' ||
          ch == '(' ||
          ch == ')' ||
          ch == '<' ||
          ch == '>') {
        flush();
        if ((ch == '&' || ch == '|' || ch == '>') &&
            i + 1 < command.length &&
            command[i + 1] == ch) {
          tokens.add('$ch$ch');
          i++;
        } else if ((ch == '>' || ch == '<') &&
            i + 1 < command.length &&
            command[i + 1] == '&') {
          // `>&2` / `<&0`: one redirection token, so the `&` is not
          // mistaken for the background operator.
          tokens.add('$ch&');
          i++;
        } else {
          tokens.add(ch);
        }
        continue;
      }
      buf.write(ch);
    }
    flush();

    const operators = {'&&', '||', ';', '|', '&', '(', ')'};
    const redirections = {'>', '>>', '<', '<<', '>&', '<&'};
    var atCommandStart = true;
    for (final token in tokens) {
      if (operators.contains(token)) {
        atCommandStart = true;
        continue;
      }
      if (redirections.contains(token)) {
        // A redirection target is an argument, not a command.
        atCommandStart = false;
        continue;
      }
      if (!atCommandStart) continue;
      if (_isEnvAssignment(token)) continue;
      if (_skippedBuiltins.contains(token)) {
        // The rest of this segment is the builtin's arguments.
        atCommandStart = false;
        continue;
      }
      return token;
    }
    return '';
  }

  static bool _isEnvAssignment(String token) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(token);

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

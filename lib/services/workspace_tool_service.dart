import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../models/agent_task.dart';
import '../models/checkpoint.dart';
import 'android_native_action_service.dart';
import 'checkpoint_store.dart';
import 'permission_service.dart';
import 'project_detector.dart';
import 'project_scaffolder.dart';
import 'runtime_service.dart';
import 'search_service.dart';
import 'tool_registry.dart';
import 'workspace_service.dart';

class ToolCallInfo {
  final String id;
  final String name;
  final String arguments;

  const ToolCallInfo({
    required this.id,
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toApiMap() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

class ToolExecutionResult {
  final String callId;
  final String toolName;
  final String output;
  final String summary;

  /// True when the tool refused or failed (Batch 1: AgentEngine uses
  /// this to detect the same error repeating).
  final bool isError;

  const ToolExecutionResult({
    required this.callId,
    required this.toolName,
    required this.output,
    required this.summary,
    this.isError = false,
  });

  Map<String, dynamic> toApiMap() => {
    'role': 'tool',
    'tool_call_id': callId,
    'content': output,
  };
}

class WorkspaceToolService {
  final SearchService _searchService;

  /// Single entry point for all command execution (Batch 3 — desain
  /// D5). Pass a [RuntimeService] directly to control the backend;
  /// the default runs commands through the bundled runtime.
  final RuntimeService _runtime;
  final AndroidNativeActionAdapter _androidActions;

  WorkspaceToolService({
    SearchService? searchService,
    RuntimeService? runtimeService,
    AndroidNativeActionAdapter? androidActions,
  }) : _searchService = searchService ?? SearchService(),
       _runtime = runtimeService ?? RuntimeService(),
       _androidActions = androidActions ?? AndroidNativeActionService();

  /// Read-only workspace tools. The full set (read + write) lives in
  /// [ToolRegistry]; this alias stays so existing callers keep working.
  static const List<Map<String, dynamic>> toolDefinitions =
      ToolRegistry.readToolDefinitions;

  static const List<Map<String, dynamic>> runtimeToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'run_project_command',
        'description':
            'Runs one shell command through the bundled runtime in the open project or a project-relative subfolder (the runtime picks the backend and records it in the result). For a concrete user request to build, test, or run something, execute the task instead of giving a tutorial: inspect the environment, then run and verify the task. Only the pre-installed bundled tools are available (git, Node/npm, Python, rg, jq, curl, xz, tar, ffmpeg, bash, and common system applets such as ls/grep/sed); there is no package manager and no way to install a missing tool, so do not promise installs — if a tool is missing, say so and suggest an alternative that uses the bundled tools. Use the existing project package manager (npm/pip) only to install requested project dependencies, not runtimes. Routine installs explicitly requested by the user do not need another confirmation. Commands can change files and access device files/network. Ask before destructive/high-impact actions or sending private data off-device. Return actual output and exit status; do not claim work that was not run. Commands are bounded to 1–120 seconds, 32 KB, and 16 KB output per stream. When the requested task belongs to a different stack than the open project, do not refuse it: work in the matching sub-project via working_directory, or scaffold it first with scaffold_project, then continue there.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'Shell command to run in the bundled runtime.',
            },
            'working_directory': {
              'type': 'string',
              'description':
                  'Optional project-relative working directory. Defaults to the project root.',
            },
            'timeout_seconds': {
              'type': 'integer',
              'description':
                  'Maximum runtime from 1 to 120 seconds (default 30).',
            },
          },
          'required': ['command'],
          'additionalProperties': false,
        },
      },
    },
  ];

  static const List<Map<String, dynamic>> androidActionToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'android_action',
        'description':
            'Android actions: one small group for phone-native copy/share and opening a web link. Use only when the user asks for that phone action. Copy, share, and opening a link always require the user to approve the exact content or destination in the app before Android is opened. Never use this to send project or private content unless the user asked.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['copy_text', 'share_text', 'open_link'],
            },
            'text': {
              'type': 'string',
              'description':
                  'Text to copy or share (maximum 8,000 characters).',
            },
            'title': {
              'type': 'string',
              'description':
                  'Short optional title for the Android share sheet.',
            },
            'url': {
              'type': 'string',
              'description': 'HTTP or HTTPS link to open in Android.',
            },
          },
          'required': ['action'],
          'additionalProperties': false,
        },
      },
    },
  ];

  static const _skip = {
    '.git',
    'build',
    '.dart_tool',
    'node_modules',
    '.gradle',
    '.idea',
    '__pycache__',
    '.venv',
    'venv',
    '.DS_Store',
  };

  static const int maxPerFileSizeBytes = 512 * 1024;
  static const int maxOutputChars = 16384;
  static const int maxFileList = 200;

  /// Executes one tool call.
  ///
  /// Write tools (`write_file`, `edit_file`, `create_file`,
  /// `delete_file`) require [checkpointStore] and [taskId]: every agent
  /// write is checkpointed before it touches the disk, so it can be
  /// undone later (Batch 2 — desain D2). Without them the write is
  /// refused instead of running unrecorded. [stepId] is the active
  /// todo step the change belongs to (`'unplanned'` when unknown).
  ///
  /// Permission gate (Batch 4 — desain D6): when [permissionService]
  /// is given, every call is checked against [mode] first. A denied
  /// call returns a clear error for the model; a call that needs
  /// approval pauses for [requestPermissionApproval] (the loop waits
  /// for the user's answer) — except `android_action`, which shows
  /// its own existing approval sheet via [confirmAndroidAction].
  /// [permissions] supplies the workspace's standing always-allow
  /// list; when [permissionService] is null a fresh service with no
  /// stored permissions is used, so the pattern rules still apply.
  Future<ToolExecutionResult> execute({
    required String workspaceRoot,
    required ToolCallInfo call,
    AgentMode mode = AgentMode.agent,
    PermissionService? permissionService,
    WorkspacePermissions? permissions,
    Future<PermissionApproval> Function(PermissionApprovalRequest request)?
    requestPermissionApproval,
    CheckpointStore? checkpointStore,
    String? taskId,
    String? stepId,
    void Function(String channel, String chunk)? onRuntimeOutput,
    Future<bool> Function(AndroidActionRequest request)? confirmAndroidAction,
  }) async {
    final name = call.name;
    final callId = call.id;

    if (workspaceRoot.isEmpty && name != 'android_action') {
      return ToolExecutionResult(
        callId: callId,
        toolName: name,
        output: jsonEncode({'error': 'No workspace is currently open.'}),
        summary: 'No workspace open',
        isError: true,
      );
    }

    final permission = permissionService ?? PermissionService();
    final check = permission.checkToolCall(
      mode: mode,
      toolName: name,
      args: _decodeArgs(call) ?? const {},
      workspaceRoot: workspaceRoot,
      permissions: permissions,
    );
    if (check.isDenied) {
      return _toolError(
        call,
        check.reason,
        'Blocked by permission rules ($name)',
      );
    }
    if (check.needsApproval && name != 'android_action') {
      // The loop pauses here until the user answers; a denial is
      // reported back to the model as a refused tool result.
      final request = check.approvalRequest;
      if (request == null || requestPermissionApproval == null) {
        return _toolError(
          call,
          'This action needs your approval, but no approval prompt is available: ${check.reason}',
          'Approval unavailable ($name)',
        );
      }
      final approval = await requestPermissionApproval(request);
      if (approval == PermissionApproval.deny) {
        return _toolError(
          call,
          'You declined this action: ${check.reason}',
          'Declined by user ($name)',
        );
      }
      if (approval == PermissionApproval.allowAlways) {
        final command = _commandFromArgs(call);
        if (command != null) {
          try {
            await permission.allowCommandAlways(workspaceRoot, command);
          } catch (_) {
            // A failed persist must not block the approved run; the
            // approval still counts for this one call.
          }
        }
      }
    }

    switch (name) {
      case 'list_project_files':
        return _executeListFiles(workspaceRoot, callId);
      case 'read_project_file':
        return _executeReadFile(workspaceRoot, callId, call.arguments);
      case 'search_project':
        return _executeSearch(workspaceRoot, callId, call.arguments);
      case 'write_file':
        return _executeWriteFile(
          workspaceRoot,
          call,
          checkpointStore: checkpointStore,
          taskId: taskId,
          stepId: stepId,
        );
      case 'edit_file':
        return _executeEditFile(
          workspaceRoot,
          call,
          checkpointStore: checkpointStore,
          taskId: taskId,
          stepId: stepId,
        );
      case 'create_file':
        return _executeCreateFile(
          workspaceRoot,
          call,
          checkpointStore: checkpointStore,
          taskId: taskId,
          stepId: stepId,
        );
      case 'delete_file':
        return _executeDeleteFile(
          workspaceRoot,
          call,
          checkpointStore: checkpointStore,
          taskId: taskId,
          stepId: stepId,
        );
      case 'detect_project':
        return _executeDetectProject(workspaceRoot, call);
      case 'probe_toolchain':
        // Read-only (Batch 4 — desain D6): probing runs in every
        // mode, no runtime opt-in needed.
        return _executeProbeToolchain(workspaceRoot, call);
      case 'scaffold_project':
        // Write-class (general harness, D11): creates a sub-project
        // and may run install commands — permission-checked above
        // like run_project_command.
        return _executeScaffoldProject(workspaceRoot, call);
      case 'run_project_command':
        // Permission-checked above (Batch 4): Plan denies it, Agent
        // asks for dangerous commands, Auto runs them.
        return _executeRuntimeCommand(
          workspaceRoot,
          call,
          onRuntimeOutput: onRuntimeOutput,
        );
      case 'android_action':
        // Permission-checked above (always needs approval); the exact
        // payload is confirmed through the existing approval sheet.
        return _executeAndroidAction(
          call,
          confirmAndroidAction: confirmAndroidAction,
        );
      default:
        return ToolExecutionResult(
          callId: callId,
          toolName: name,
          output: jsonEncode({
            'error':
                'Tool "$name" is not permitted. Available workspace tools: '
                'list_project_files, read_project_file, search_project, '
                'write_file, edit_file, create_file, delete_file, '
                'detect_project, probe_toolchain, run_project_command, '
                'scaffold_project, android_action.',
          }),
          summary: 'Blocked unauthorized tool "$name"',
          isError: true,
        );
    }
  }

  void cancelActiveCommand() {
    _runtime.cancelActiveCommand();
  }

  ToolExecutionResult _toolError(
    ToolCallInfo call,
    String error,
    String summary,
  ) => ToolExecutionResult(
    callId: call.id,
    toolName: call.name,
    output: jsonEncode({'error': error}),
    summary: summary,
    isError: true,
  );

  Future<ToolExecutionResult> _executeRuntimeCommand(
    String workspaceRoot,
    ToolCallInfo call, {
    void Function(String channel, String chunk)? onRuntimeOutput,
  }) async {
    try {
      final args = jsonDecode(call.arguments);
      if (args is! Map || args['command'] is! String) {
        return _toolError(
          call,
          'Missing or invalid "command".',
          'Invalid command request',
        );
      }
      final command = (args['command'] as String).trim();
      if (command.isEmpty) {
        return _toolError(call, 'Command cannot be empty.', 'Empty command');
      }
      if (command.length > RuntimeService.maxCommandChars) {
        return _toolError(
          call,
          'Command exceeds 32,000 characters.',
          'Command too long',
        );
      }
      final root = await Directory(workspaceRoot).resolveSymbolicLinks();
      final rawCwd = (args['working_directory'] as String? ?? '').trim();
      final cwdSegments = rawCwd.isEmpty || rawCwd == '.'
          ? <String>[]
          : rawCwd.replaceAll('\\', '/').split('/');
      if (rawCwd.startsWith('/') ||
          RegExp(r'^[A-Za-z]:').hasMatch(rawCwd) ||
          cwdSegments.any(
            (part) => part.isEmpty || part == '.' || part == '..',
          )) {
        return _toolError(
          call,
          'working_directory must be a project-relative folder without dot or parent segments.',
          'Blocked unsafe working directory',
        );
      }
      final candidate = p.normalize(p.joinAll([root, ...cwdSegments]));
      if (candidate != root && !p.isWithin(root, candidate)) {
        return _toolError(
          call,
          'Working directory is outside the project.',
          'Blocked working directory',
        );
      }
      final directory = Directory(candidate);
      if (!await directory.exists()) {
        return _toolError(
          call,
          'Working directory does not exist: $rawCwd',
          'Working directory not found',
        );
      }
      final canonicalCwd = await directory.resolveSymbolicLinks();
      if (canonicalCwd != root && !p.isWithin(root, canonicalCwd)) {
        return _toolError(
          call,
          'Working directory resolves outside the project.',
          'Blocked symlink working directory',
        );
      }
      final requestedTimeout = args['timeout_seconds'] is num
          ? (args['timeout_seconds'] as num).toInt()
          : 30;
      final timeout = requestedTimeout
          .clamp(
            RuntimeService.minTimeoutSeconds,
            RuntimeService.maxTimeoutSeconds,
          )
          .toInt();
      final result = await _runtime.run(
        command: command,
        workspaceRoot: root,
        workingDirectory: canonicalCwd,
        timeoutSeconds: timeout,
        onOutput: onRuntimeOutput,
      );
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode(result.toJson()),
        summary: result.error == null
            ? 'Command finished (exit ${result.exitCode}) via ${result.backend}'
            : 'Command error via ${result.backend}: ${result.error}',
      );
    } catch (error) {
      return _toolError(
        call,
        'Runtime command failed: $error',
        'Runtime command failed',
      );
    }
  }

  /// Resolves a workspace-relative subfolder to its canonical
  /// absolute path, or null when it is unsafe, outside the workspace,
  /// or does not exist. '' / '.' means the workspace root itself.
  Future<String?> _resolveSubPath(
    String workspaceRoot,
    String relativePath,
  ) async {
    final raw = relativePath.trim();
    final root = await Directory(workspaceRoot).resolveSymbolicLinks();
    if (raw.isEmpty || raw == '.') return root;
    if (!ScaffoldPlan.isSafeRelativePath(raw)) return null;
    final candidate = p.normalize(
      p.join(root, raw.replaceAll('\\', '/')),
    );
    if (candidate != root && !p.isWithin(root, candidate)) return null;
    if (!await Directory(candidate).exists()) return null;
    final canonical = await Directory(candidate).resolveSymbolicLinks();
    if (canonical != root && !p.isWithin(root, canonical)) return null;
    return canonical;
  }

  /// Detects the project kind from root marker files (Batch 3 —
  /// desain D4). Pure file-system work, no runtime needed.
  ///
  /// General harness (D11): without a `path` argument the result
  /// also lists every project in the workspace (`projects`: root +
  /// subfolders); with `path` it detects that one sub-project.
  Future<ToolExecutionResult> _executeDetectProject(
    String workspaceRoot,
    ToolCallInfo call,
  ) async {
    final args = _decodeArgs(call);
    final rawPath = args?['path'] is String
        ? (args!['path'] as String).trim()
        : '';
    if (rawPath.isNotEmpty && rawPath != '.') {
      final dir = await _resolveSubPath(workspaceRoot, rawPath);
      if (dir == null) {
        return _toolError(
          call,
          'Path "$rawPath" is not a folder inside the workspace.',
          'Invalid project path',
        );
      }
      final root = await Directory(workspaceRoot).resolveSymbolicLinks();
      final rel = p
          .relative(dir, from: root)
          .replaceAll('\\', '/');
      final info = await ProjectDetector.detectAt(workspaceRoot, rel);
      return ToolExecutionResult(
        callId: call.id,
        toolName: 'detect_project',
        output: jsonEncode(info.toJson()),
        summary: 'Detected ${info.type.label} project at $rel',
      );
    }
    final rootInfo = await ProjectDetector.detect(workspaceRoot);
    final projects = await ProjectDetector.detectAll(workspaceRoot);
    return ToolExecutionResult(
      callId: call.id,
      toolName: 'detect_project',
      output: jsonEncode({
        ...rootInfo.toJson(),
        'projects': projects.map((project) => project.toJson()).toList(),
      }),
      summary: projects.length == 1
          ? 'Detected ${rootInfo.type.label} project'
          : 'Detected ${projects.length} projects '
                '(${projects.map((project) => project.type.label).join(', ')})',
    );
  }

  /// Probes the toolchain on the runtime (Batch 3 — desain D4):
  /// `<tool> --version` for the tools relevant to the detected
  /// project kind (or the tools the model named), via [RuntimeService].
  ///
  /// General harness (D11): an optional `path` argument probes in
  /// that sub-project instead of the workspace root.
  Future<ToolExecutionResult> _executeProbeToolchain(
    String workspaceRoot,
    ToolCallInfo call,
  ) async {
    final args = _decodeArgs(call);
    List<String>? requested;
    if (args != null && args['tools'] is List) {
      requested = (args['tools'] as List)
          .whereType<String>()
          .map((tool) => tool.trim())
          .where((tool) => tool.isNotEmpty)
          .toList();
    }
    var probeRoot = workspaceRoot;
    var probeRel = '.';
    final rawPath = args?['path'] is String
        ? (args!['path'] as String).trim()
        : '';
    if (rawPath.isNotEmpty && rawPath != '.') {
      final dir = await _resolveSubPath(workspaceRoot, rawPath);
      if (dir == null) {
        return _toolError(
          call,
          'Path "$rawPath" is not a folder inside the workspace.',
          'Invalid project path',
        );
      }
      probeRoot = dir;
      probeRel = rawPath.replaceAll('\\', '/');
    }
    final info = await ProjectDetector.detect(probeRoot);
    final tools = requested == null || requested.isEmpty
        ? ProjectDetector.defaultProbeTools(info.type)
        : requested;
    final probes = await _runtime.probeTools(
      tools,
      workspaceRoot: probeRoot,
    );
    final availableCount = probes.where((probe) => probe.available).length;
    return ToolExecutionResult(
      callId: call.id,
      toolName: call.name,
      output: jsonEncode({
        'project_type': info.type.id,
        'path': probeRel,
        'tools': probes.map((probe) => probe.toJson()).toList(),
      }),
      summary:
          'Probed ${probes.length} tools ($availableCount available) for ${info.type.label}'
          '${probeRel == '.' ? '' : ' at $probeRel'}',
    );
  }

  /// Scaffolds a new sub-project for the requested stack (general
  /// harness, D11). The scaffolder reports its own failures; this
  /// wrapper only maps them onto tool errors.
  Future<ToolExecutionResult> _executeScaffoldProject(
    String workspaceRoot,
    ToolCallInfo call,
  ) async {
    final args = _decodeArgs(call);
    final stackRaw = args?['stack'];
    if (stackRaw is! String || stackRaw.trim().isEmpty) {
      return _toolError(
        call,
        'Missing or invalid "stack" (node, python or generic).',
        'Invalid scaffold request',
      );
    }
    final stack = ScaffoldStack.parse(stackRaw);
    if (stack == null) {
      return _toolError(
        call,
        'Unknown stack "$stackRaw" (node, python or generic).',
        'Unknown stack',
      );
    }
    final pathRaw = args?['path'];
    if (pathRaw is! String || pathRaw.trim().isEmpty) {
      return _toolError(
        call,
        'Missing or invalid "path" (workspace-relative subfolder).',
        'Invalid scaffold request',
      );
    }
    final packages = <String>[];
    if (args?['packages'] is List) {
      for (final item in (args!['packages'] as List)) {
        if (item is String && item.trim().isNotEmpty) {
          packages.add(item.trim());
        }
      }
    }
    try {
      final result = await ProjectScaffolder(
        runtimeService: _runtime,
      ).scaffold(
        workspaceRoot: workspaceRoot,
        relativePath: pathRaw.trim(),
        stack: stack,
        packages: packages,
      );
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode(result.toJson()),
        summary:
            'Scaffolded ${stack.label} project at ${result.relativePath} '
            '(${result.info.type.label})',
      );
    } on ScaffoldException catch (error) {
      return _toolError(call, error.message, 'Scaffold failed');
    } catch (error) {
      return _toolError(call, 'Scaffold failed: $error', 'Scaffold failed');
    }
  }

  Future<ToolExecutionResult> _executeAndroidAction(
    ToolCallInfo call, {
    Future<bool> Function(AndroidActionRequest request)? confirmAndroidAction,
  }) async {
    try {
      final args = jsonDecode(call.arguments);
      if (args is! Map || args['action'] is! String) {
        return _toolError(
          call,
          'Missing or invalid Android action.',
          'Invalid Android action',
        );
      }
      final action = (args['action'] as String).trim();
      final text = args['text'] is String ? args['text'] as String : '';
      final title = args['title'] is String
          ? (args['title'] as String).trim()
          : '';
      final url = args['url'] is String ? (args['url'] as String).trim() : '';
      late final AndroidActionRequest request;
      switch (action) {
        case 'copy_text':
          if (text.trim().isEmpty ||
              text.length > AndroidNativeActionService.maxTextChars) {
            return _toolError(
              call,
              'Copy text must contain 1–8,000 characters.',
              'Invalid copy text',
            );
          }
          request = AndroidActionRequest(
            action: action,
            title: 'Copy text to the phone clipboard?',
            description:
                'The text will be placed on the Android clipboard, where other apps may be able to read it.',
            preview: text,
          );
        case 'share_text':
          if (text.trim().isEmpty ||
              text.length > AndroidNativeActionService.maxTextChars) {
            return _toolError(
              call,
              'Shared text must contain 1–8,000 characters.',
              'Invalid share text',
            );
          }
          request = AndroidActionRequest(
            action: action,
            title: 'Share this text from Android?',
            description:
                'Android will open the system share sheet. You choose the destination app.',
            preview: text,
          );
        case 'open_link':
          final uri = Uri.tryParse(url);
          if (uri == null ||
              !{'http', 'https'}.contains(uri.scheme.toLowerCase()) ||
              uri.host.isEmpty) {
            return _toolError(
              call,
              'Only valid HTTP or HTTPS links can be opened.',
              'Invalid link',
            );
          }
          request = AndroidActionRequest(
            action: action,
            title: 'Open this link outside the app?',
            description:
                'Android will open the link in a browser or the app registered for it.',
            preview: uri.toString(),
          );
        default:
          return _toolError(
            call,
            'Unsupported Android action "$action".',
            'Unsupported Android action',
          );
      }
      if (confirmAndroidAction == null ||
          !await confirmAndroidAction(request)) {
        return _toolError(
          call,
          'The user declined or dismissed this Android action.',
          'Android action not approved',
        );
      }
      switch (action) {
        case 'copy_text':
          await _androidActions.copyText(text);
          break;
        case 'share_text':
          await _androidActions.shareText(
            title: title.isEmpty ? 'Shared from Code Harness' : title,
            text: text,
          );
          break;
        case 'open_link':
          await _androidActions.openLink(url);
          break;
      }
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode({'ok': true, 'action': action}),
        summary: 'Android action approved and completed: $action',
      );
    } catch (error) {
      return _toolError(
        call,
        'Android action failed: $error',
        'Android action failed',
      );
    }
  }

  Future<ToolExecutionResult> _executeListFiles(
    String workspaceRoot,
    String callId,
  ) async {
    try {
      final rootDir = Directory(workspaceRoot);
      final canonicalRoot = await rootDir.resolveSymbolicLinks();
      final fileList = <String>[];

      void collect(Directory dir) {
        if (fileList.length >= maxFileList) return;
        List<FileSystemEntity> entries;
        try {
          entries = dir.listSync(followLinks: false)
            ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
        } catch (_) {
          return;
        }

        for (final entry in entries) {
          if (fileList.length >= maxFileList) break;
          final base = p.basename(entry.path);
          if (base.startsWith('.') || _skip.contains(base)) continue;
          if (entry is Directory) {
            collect(entry);
          } else if (entry is File) {
            fileList.add(p.relative(entry.path, from: canonicalRoot));
          }
        }
      }

      collect(Directory(canonicalRoot));
      return ToolExecutionResult(
        callId: callId,
        toolName: 'list_project_files',
        output: jsonEncode({
          'files': fileList,
          'total': fileList.length,
          'capped': fileList.length >= maxFileList,
        }),
        summary: 'Listed ${fileList.length} workspace files',
      );
    } catch (e) {
      return ToolExecutionResult(
        callId: callId,
        toolName: 'list_project_files',
        output: jsonEncode({'error': 'Failed to list project files: $e'}),
        summary: 'Error listing files',
      );
    }
  }

  Future<ToolExecutionResult> _executeReadFile(
    String workspaceRoot,
    String callId,
    String rawArgs,
  ) async {
    String? relPath;
    try {
      final parsed = jsonDecode(rawArgs);
      if (parsed is Map && parsed['path'] is String) {
        relPath = (parsed['path'] as String).trim();
      }
    } catch (_) {}

    if (relPath == null || relPath.isEmpty) {
      return ToolExecutionResult(
        callId: callId,
        toolName: 'read_project_file',
        output: jsonEncode({'error': 'Missing or invalid "path" parameter.'}),
        summary: 'Invalid read request',
      );
    }

    final pathSegments = relPath.replaceAll('\\', '/').split('/');
    if (pathSegments.any(
      (segment) =>
          segment.isEmpty || segment.startsWith('.') || _skip.contains(segment),
    )) {
      return ToolExecutionResult(
        callId: callId,
        toolName: 'read_project_file',
        output: jsonEncode({
          'error': 'Hidden or ignored paths are not available.',
        }),
        summary: 'Blocked hidden or ignored path',
      );
    }

    try {
      final absolutePath = await WorkspaceService.resolveSafePath(
        workspaceRoot,
        relPath,
      );
      final file = File(absolutePath);
      final stat = await file.stat();

      if (stat.type != FileSystemEntityType.file) {
        return ToolExecutionResult(
          callId: callId,
          toolName: 'read_project_file',
          output: jsonEncode({'error': 'File not found: $relPath'}),
          summary: 'File not found ($relPath)',
        );
      }

      if (stat.size > maxPerFileSizeBytes) {
        return ToolExecutionResult(
          callId: callId,
          toolName: 'read_project_file',
          output: jsonEncode({
            'error':
                'File exceeds maximum 512 KB limit ($relPath: ${stat.size} bytes).',
          }),
          summary: 'File exceeds 512 KB limit ($relPath)',
        );
      }

      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) {
        return ToolExecutionResult(
          callId: callId,
          toolName: 'read_project_file',
          output: jsonEncode({'error': 'Binary file cannot be read: $relPath'}),
          summary: 'Skipped binary file ($relPath)',
        );
      }

      String content;
      try {
        content = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        return ToolExecutionResult(
          callId: callId,
          toolName: 'read_project_file',
          output: jsonEncode({'error': 'File is not valid UTF-8: $relPath'}),
          summary: 'Non-UTF8 file ($relPath)',
        );
      }

      bool truncated = false;
      String outputContent = content;
      if (content.length > maxOutputChars) {
        truncated = true;
        outputContent =
            '${content.substring(0, maxOutputChars)}\n\n[Content truncated to 16 KB; full size: ${content.length} characters]';
      }

      final summary = truncated
          ? 'Read $relPath (limited to 16 KB)'
          : 'Read $relPath';

      return ToolExecutionResult(
        callId: callId,
        toolName: 'read_project_file',
        output: outputContent,
        summary: summary,
      );
    } catch (e) {
      return ToolExecutionResult(
        callId: callId,
        toolName: 'read_project_file',
        output: jsonEncode({'error': 'Failed to read $relPath: $e'}),
        summary: 'Error reading $relPath',
      );
    }
  }

  Future<ToolExecutionResult> _executeSearch(
    String workspaceRoot,
    String callId,
    String rawArgs,
  ) async {
    String? query;
    try {
      final parsed = jsonDecode(rawArgs);
      if (parsed is Map && parsed['query'] is String) {
        query = (parsed['query'] as String).trim();
      }
    } catch (_) {}

    if (query == null || query.isEmpty) {
      return ToolExecutionResult(
        callId: callId,
        toolName: 'search_project',
        output: jsonEncode({'error': 'Missing or empty "query" parameter.'}),
        summary: 'Invalid search query',
      );
    }

    try {
      final matches = await _searchService.search(workspaceRoot, query);
      final formatted = matches
          .take(50)
          .map(
            (m) => {
              'path': m.relativePath,
              'line': m.lineNumber,
              'preview': m.linePreview,
              'isPathMatch': m.isPathMatch,
            },
          )
          .toList();

      final summary =
          'Searched project for "$query" (${matches.length} matches)';

      return ToolExecutionResult(
        callId: callId,
        toolName: 'search_project',
        output: jsonEncode({
          'query': query,
          'totalMatches': matches.length,
          'matches': formatted,
        }),
        summary: summary,
      );
    } catch (e) {
      return ToolExecutionResult(
        callId: callId,
        toolName: 'search_project',
        output: jsonEncode({'error': 'Search failed: $e'}),
        summary: 'Search error for "$query"',
      );
    }
  }

  // ── Write tools (Batch 2 — desain D2) ──────────────────────────────
  //
  // Every write goes through [WorkspaceService.resolveSafePath]
  // (rejects `..`, absolute paths, symlink escapes) and
  // [WorkspaceService.writeFile] (512 KB cap), and records a
  // [Checkpoint] BEFORE the disk changes, so the change can be undone.

  /// Resolves a write-tool path, or returns an error result when the
  /// path is unsafe. Also refuses paths inside the trash folder: the
  /// trash is managed by [CheckpointStore] only, never by the agent.
  Future<({String absolutePath, String relativePath})?> _resolveWritePath(
    String workspaceRoot,
    String? relativePath,
  ) async {
    if (relativePath == null || relativePath.isEmpty) {
      return null;
    }
    final normalized = relativePath.replaceAll('\\', '/');
    final firstSegment = normalized.split('/').first;
    if (firstSegment == CheckpointStore.trashDirName) {
      return null;
    }
    try {
      final absolutePath = await WorkspaceService.resolveSafePath(
        workspaceRoot,
        relativePath,
      );
      return (absolutePath: absolutePath, relativePath: normalized);
    } catch (error) {
      return null;
    }
  }

  ToolExecutionResult _writePathError(
    ToolCallInfo call,
    String? relativePath,
    String fallback,
  ) {
    final message = relativePath == null || relativePath.isEmpty
        ? 'Missing or invalid "path" parameter.'
        : relativePath.replaceAll('\\', '/').split('/').first ==
              CheckpointStore.trashDirName
        ? 'Writing inside the ${CheckpointStore.trashDirName} folder is not allowed.'
        : 'Unsafe path "$relativePath": $fallback';
    return _toolError(call, message, 'Blocked unsafe path');
  }

  /// Reads the current text of an existing file, or null when it does
  /// not exist. Returns a [_toolError] result (via [onError]) when the
  /// existing file cannot be safely read as text.
  Future<({String? before, ToolExecutionResult? error})> _readExistingText(
    ToolCallInfo call,
    String absolutePath,
    String relativePath,
  ) async {
    final file = File(absolutePath);
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return (before: null, error: null);
    }
    if (stat.type != FileSystemEntityType.file) {
      return (
        before: null,
        error: _toolError(
          call,
          '"$relativePath" is not a file.',
          'Not a file ($relativePath)',
        ),
      );
    }
    if (stat.size > maxPerFileSizeBytes) {
      return (
        before: null,
        error: _toolError(
          call,
          'File exceeds maximum 512 KB limit ($relativePath: ${stat.size} bytes).',
          'File exceeds 512 KB limit ($relativePath)',
        ),
      );
    }
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) {
      return (
        before: null,
        error: _toolError(
          call,
          'Binary file cannot be edited: $relativePath',
          'Skipped binary file ($relativePath)',
        ),
      );
    }
    try {
      return (before: utf8.decode(bytes), error: null);
    } on FormatException {
      return (
        before: null,
        error: _toolError(
          call,
          'File is not valid UTF-8: $relativePath',
          'Non-UTF8 file ($relativePath)',
        ),
      );
    }
  }

  /// Validates agent-supplied text content (desain §6: binary writes
  /// are rejected, 512 KB cap kept). Returns an error message, or null
  /// when the content is acceptable.
  String? _validateTextContent(String content, String relativePath) {
    if (content.contains('\u0000')) {
      return 'Binary content cannot be written: $relativePath';
    }
    if (utf8.encode(content).length > maxPerFileSizeBytes) {
      return 'Content exceeds maximum 512 KB limit ($relativePath).';
    }
    return null;
  }

  /// Write tools refuse to run unrecorded: without a checkpoint store
  /// and a task id there is nothing to undo them with.
  ToolExecutionResult? _requireCheckpointContext(
    ToolCallInfo call,
    CheckpointStore? checkpointStore,
    String? taskId,
  ) {
    if (checkpointStore == null || taskId == null || taskId.isEmpty) {
      return _toolError(
        call,
        'Write tools need an active task with checkpoint tracking.',
        'Write refused (no active task)',
      );
    }
    return null;
  }

  Map<String, dynamic>? _decodeArgs(ToolCallInfo call) {
    try {
      final parsed = jsonDecode(call.arguments);
      if (parsed is Map<String, dynamic>) return parsed;
      if (parsed is Map) {
        return parsed.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  /// The `command` argument of a `run_project_command` call, or null
  /// for other tools. Used to store a standing "always allow" choice
  /// for exactly this command.
  String? _commandFromArgs(ToolCallInfo call) {
    if (call.name != 'run_project_command') return null;
    final args = _decodeArgs(call);
    final command = args?['command'];
    if (command is! String || command.trim().isEmpty) return null;
    return command;
  }

  String? _stringArg(Map<String, dynamic> args, String name) {
    final value = args[name];
    if (value is! String) return null;
    final trimmed = name == 'path' ? value.trim() : value;
    return trimmed;
  }

  Future<ToolExecutionResult> _executeWriteFile(
    String workspaceRoot,
    ToolCallInfo call, {
    CheckpointStore? checkpointStore,
    String? taskId,
    String? stepId,
  }) async {
    final contextError = _requireCheckpointContext(
      call,
      checkpointStore,
      taskId,
    );
    if (contextError != null) return contextError;
    final args = _decodeArgs(call);
    final relativePath = args == null ? null : _stringArg(args, 'path');
    final content = args == null ? null : _stringArg(args, 'content');
    if (content == null) {
      return _toolError(
        call,
        'Missing or invalid "content" parameter.',
        'Invalid write request',
      );
    }
    final resolved = await _resolveWritePath(workspaceRoot, relativePath);
    if (resolved == null) {
      return _writePathError(
        call,
        relativePath,
        'use a workspace-relative path without ".." or a leading "/".',
      );
    }
    final contentError = _validateTextContent(content, resolved.relativePath);
    if (contentError != null) {
      return _toolError(call, contentError, 'Invalid content');
    }
    try {
      final (before: before, error: readError) = await _readExistingText(
        call,
        resolved.absolutePath,
        resolved.relativePath,
      );
      if (readError != null) return readError;
      if (before == content) {
        return ToolExecutionResult(
          callId: call.id,
          toolName: call.name,
          output: jsonEncode({
            'ok': true,
            'path': resolved.relativePath,
            'unchanged': true,
          }),
          summary: 'No change needed for ${resolved.relativePath}',
        );
      }
      final checkpoint = Checkpoint(
        taskId: taskId!,
        stepId: stepId ?? 'unplanned',
        path: resolved.relativePath,
        before: before,
        after: content,
        kind: CheckpointKind.write,
      );
      checkpointStore!.record(checkpoint);
      try {
        await WorkspaceService.writeFile(resolved.absolutePath, content);
      } catch (error) {
        checkpointStore.remove(checkpoint.id);
        rethrow;
      }
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode({
          'ok': true,
          'path': resolved.relativePath,
          'created': before == null,
        }),
        summary: before == null
            ? 'Created ${resolved.relativePath}'
            : 'Wrote ${resolved.relativePath}',
      );
    } catch (error) {
      return _toolError(
        call,
        'Failed to write ${relativePath ?? ''}: $error',
        'Write failed',
      );
    }
  }

  Future<ToolExecutionResult> _executeEditFile(
    String workspaceRoot,
    ToolCallInfo call, {
    CheckpointStore? checkpointStore,
    String? taskId,
    String? stepId,
  }) async {
    final contextError = _requireCheckpointContext(
      call,
      checkpointStore,
      taskId,
    );
    if (contextError != null) return contextError;
    final args = _decodeArgs(call);
    final relativePath = args == null ? null : _stringArg(args, 'path');
    final oldText = args == null ? null : _stringArg(args, 'oldText');
    final newText = args == null ? null : _stringArg(args, 'newText');
    if (oldText == null || oldText.isEmpty || newText == null) {
      return _toolError(
        call,
        'Missing or invalid "oldText"/"newText" parameters.',
        'Invalid edit request',
      );
    }
    if (oldText == newText) {
      return _toolError(
        call,
        'oldText and newText are identical — nothing to change.',
        'No-op edit',
      );
    }
    final resolved = await _resolveWritePath(workspaceRoot, relativePath);
    if (resolved == null) {
      return _writePathError(
        call,
        relativePath,
        'use a workspace-relative path without ".." or a leading "/".',
      );
    }
    final contentError = _validateTextContent(newText, resolved.relativePath);
    if (contentError != null) {
      return _toolError(call, contentError, 'Invalid content');
    }
    try {
      final (before: before, error: readError) = await _readExistingText(
        call,
        resolved.absolutePath,
        resolved.relativePath,
      );
      if (readError != null) return readError;
      if (before == null) {
        return _toolError(
          call,
          'File not found: ${resolved.relativePath}. Use create_file to create it.',
          'File not found (${resolved.relativePath})',
        );
      }
      final matches = _countOccurrences(before, oldText);
      if (matches == 0) {
        return _toolError(
          call,
          'No occurrence of the given text was found in ${resolved.relativePath}. '
              'Read the file again and copy the exact text, including indentation.',
          'Text not found in ${resolved.relativePath}',
        );
      }
      if (matches > 1) {
        return _toolError(
          call,
          'The given text matches $matches times in ${resolved.relativePath}. '
              'Include more surrounding context so it matches exactly once — '
              'never guess which occurrence to change.',
          'Ambiguous edit in ${resolved.relativePath}',
        );
      }
      final after = before.replaceFirst(oldText, newText);
      final sizeError = _validateTextContent(after, resolved.relativePath);
      if (sizeError != null) {
        return _toolError(call, sizeError, 'Invalid content');
      }
      final checkpoint = Checkpoint(
        taskId: taskId!,
        stepId: stepId ?? 'unplanned',
        path: resolved.relativePath,
        before: before,
        after: after,
        kind: CheckpointKind.write,
      );
      checkpointStore!.record(checkpoint);
      try {
        await WorkspaceService.writeFile(resolved.absolutePath, after);
      } catch (error) {
        checkpointStore.remove(checkpoint.id);
        rethrow;
      }
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode({'ok': true, 'path': resolved.relativePath}),
        summary: 'Edited ${resolved.relativePath}',
      );
    } catch (error) {
      return _toolError(
        call,
        'Failed to edit ${relativePath ?? ''}: $error',
        'Edit failed',
      );
    }
  }

  Future<ToolExecutionResult> _executeCreateFile(
    String workspaceRoot,
    ToolCallInfo call, {
    CheckpointStore? checkpointStore,
    String? taskId,
    String? stepId,
  }) async {
    final contextError = _requireCheckpointContext(
      call,
      checkpointStore,
      taskId,
    );
    if (contextError != null) return contextError;
    final args = _decodeArgs(call);
    final relativePath = args == null ? null : _stringArg(args, 'path');
    final content = args == null ? null : _stringArg(args, 'content');
    if (content == null) {
      return _toolError(
        call,
        'Missing or invalid "content" parameter.',
        'Invalid create request',
      );
    }
    final resolved = await _resolveWritePath(workspaceRoot, relativePath);
    if (resolved == null) {
      return _writePathError(
        call,
        relativePath,
        'use a workspace-relative path without ".." or a leading "/".',
      );
    }
    final contentError = _validateTextContent(content, resolved.relativePath);
    if (contentError != null) {
      return _toolError(call, contentError, 'Invalid content');
    }
    try {
      final (before: before, error: readError) = await _readExistingText(
        call,
        resolved.absolutePath,
        resolved.relativePath,
      );
      if (readError != null) return readError;
      if (before != null) {
        return _toolError(
          call,
          'File already exists: ${resolved.relativePath}. '
              'Use edit_file or write_file to change it.',
          'File already exists (${resolved.relativePath})',
        );
      }
      final checkpoint = Checkpoint(
        taskId: taskId!,
        stepId: stepId ?? 'unplanned',
        path: resolved.relativePath,
        before: null,
        after: content,
        kind: CheckpointKind.write,
      );
      checkpointStore!.record(checkpoint);
      try {
        await WorkspaceService.writeFile(resolved.absolutePath, content);
      } catch (error) {
        checkpointStore.remove(checkpoint.id);
        rethrow;
      }
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode({'ok': true, 'path': resolved.relativePath}),
        summary: 'Created ${resolved.relativePath}',
      );
    } catch (error) {
      return _toolError(
        call,
        'Failed to create ${relativePath ?? ''}: $error',
        'Create failed',
      );
    }
  }

  Future<ToolExecutionResult> _executeDeleteFile(
    String workspaceRoot,
    ToolCallInfo call, {
    CheckpointStore? checkpointStore,
    String? taskId,
    String? stepId,
  }) async {
    final contextError = _requireCheckpointContext(
      call,
      checkpointStore,
      taskId,
    );
    if (contextError != null) return contextError;
    final args = _decodeArgs(call);
    final relativePath = args == null ? null : _stringArg(args, 'path');
    final resolved = await _resolveWritePath(workspaceRoot, relativePath);
    if (resolved == null) {
      return _writePathError(
        call,
        relativePath,
        'use a workspace-relative path without ".." or a leading "/".',
      );
    }
    try {
      final (
        exists: exists,
        before: before,
        error: readError,
      ) = await _readDeleteBefore(
        call,
        resolved.absolutePath,
        resolved.relativePath,
      );
      if (readError != null) return readError;
      if (!exists) {
        return _toolError(
          call,
          'File not found: ${resolved.relativePath}.',
          'File not found (${resolved.relativePath})',
        );
      }
      // Binary / oversized files can still be deleted: the trash copy
      // holds the bytes, so undo does not need a text snapshot.
      final trashRelativePath = CheckpointStore.trashPathFor(
        taskId!,
        resolved.relativePath,
      );
      final trashAbsolutePath = p.join(workspaceRoot, trashRelativePath);
      if (await File(trashAbsolutePath).exists()) {
        return _toolError(
          call,
          'A trashed copy of ${resolved.relativePath} already exists for this task.',
          'Trash conflict for ${resolved.relativePath}',
        );
      }
      final checkpoint = Checkpoint(
        taskId: taskId,
        stepId: stepId ?? 'unplanned',
        path: resolved.relativePath,
        before: before,
        after: null,
        trashPath: trashRelativePath,
        kind: CheckpointKind.delete,
      );
      checkpointStore!.record(checkpoint);
      try {
        await Directory(p.dirname(trashAbsolutePath)).create(recursive: true);
        await File(resolved.absolutePath).rename(trashAbsolutePath);
      } catch (error) {
        checkpointStore.remove(checkpoint.id);
        rethrow;
      }
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: jsonEncode({
          'ok': true,
          'path': resolved.relativePath,
          'trashPath': trashRelativePath,
        }),
        summary:
            'Moved ${resolved.relativePath} to trash (restorable until the task finishes)',
      );
    } catch (error) {
      return _toolError(
        call,
        'Failed to delete ${relativePath ?? ''}: $error',
        'Delete failed',
      );
    }
  }

  /// Reads the text snapshot for a delete. [exists] is false when the
  /// file is gone; [before] is null when the file exists but has no
  /// usable text snapshot (binary, oversized, or invalid UTF-8). Only
  /// a directory target is an error - anything else can be trashed and
  /// restored from the trash copy.
  Future<({bool exists, String? before, ToolExecutionResult? error})>
  _readDeleteBefore(
    ToolCallInfo call,
    String absolutePath,
    String relativePath,
  ) async {
    final file = File(absolutePath);
    final stat = await file.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return (exists: false, before: null, error: null);
    }
    if (stat.type != FileSystemEntityType.file) {
      return (
        exists: true,
        before: null,
        error: _toolError(
          call,
          '"$relativePath" is not a file.',
          'Not a file ($relativePath)',
        ),
      );
    }
    if (stat.size > maxPerFileSizeBytes) {
      return (exists: true, before: null, error: null);
    }
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) return (exists: true, before: null, error: null);
    try {
      return (exists: true, before: utf8.decode(bytes), error: null);
    } on FormatException {
      return (exists: true, before: null, error: null);
    }
  }

  /// Counts non-overlapping exact occurrences of [needle] in
  /// [haystack] (D2: edit_file needs exactly one).
  static int _countOccurrences(String haystack, String needle) {
    var count = 0;
    var start = 0;
    while (true) {
      final index = haystack.indexOf(needle, start);
      if (index < 0) return count;
      count++;
      start = index + needle.length;
    }
  }
}

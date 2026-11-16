import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'android_native_action_service.dart';
import 'search_service.dart';
import 'termux_runtime_service.dart';
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

  const ToolExecutionResult({
    required this.callId,
    required this.toolName,
    required this.output,
    required this.summary,
  });

  Map<String, dynamic> toApiMap() => {
    'role': 'tool',
    'tool_call_id': callId,
    'name': toolName,
    'content': output,
  };
}

class WorkspaceToolService {
  final SearchService _searchService;
  final TermuxRuntimeAdapter _termuxRuntime;
  final AndroidNativeActionAdapter _androidActions;

  WorkspaceToolService({
    SearchService? searchService,
    TermuxRuntimeAdapter? termuxRuntime,
    AndroidNativeActionAdapter? androidActions,
  }) : _searchService = searchService ?? SearchService(),
       _termuxRuntime = termuxRuntime ?? TermuxRuntimeService(),
       _androidActions = androidActions ?? AndroidNativeActionService();

  static const List<Map<String, dynamic>> toolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'list_project_files',
        'description':
            'Lists relative file paths in the workspace (skipping ignored folders).',
        'parameters': {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'read_project_file',
        'description':
            'Reads a workspace-relative file, capped to 512 KB and truncated to 16 KB.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Workspace-relative path to read.',
            },
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'search_project',
        'description':
            'Searches for text in workspace files and file paths, returning line numbers and previews.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'Search string to find in workspace.',
            },
          },
          'required': ['query'],
          'additionalProperties': false,
        },
      },
    },
  ];

  static const List<Map<String, dynamic>> termuxToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'run_project_command',
        'description':
            'Runtime tools: runs one shell command through the user-enabled Termux environment in the open project or a project-relative subfolder. Use for builds, tests, Git, Node/npm, Python, or network-enabled development tasks. The command can change files and access Termux-visible device files/network; use only when needed, inspect the result, and report its exit code. Do not use this as a substitute for a reviewable code diff when proposing source edits.',
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': 'Shell command to run in Termux.',
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

  Future<ToolExecutionResult> execute({
    required String workspaceRoot,
    required ToolCallInfo call,
    bool allowTermuxExecution = false,
    bool allowAndroidActions = false,
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
      );
    }

    switch (name) {
      case 'list_project_files':
        return _executeListFiles(workspaceRoot, callId);
      case 'read_project_file':
        return _executeReadFile(workspaceRoot, callId, call.arguments);
      case 'search_project':
        return _executeSearch(workspaceRoot, callId, call.arguments);
      case 'run_project_command':
        if (!allowTermuxExecution) {
          return _toolError(
            call,
            'Termux execution is not enabled for this session.',
            'Blocked Termux command (not enabled)',
          );
        }
        return _executeTermuxCommand(
          workspaceRoot,
          call,
          onRuntimeOutput: onRuntimeOutput,
        );
      case 'android_action':
        if (!allowAndroidActions) {
          return _toolError(
            call,
            'Android actions are not enabled for this session.',
            'Blocked Android action (not enabled)',
          );
        }
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
                'Tool "$name" is not permitted. Only read-only workspace tools are allowed.',
          }),
          summary: 'Blocked unauthorized tool "$name"',
        );
    }
  }

  void cancelActiveCommand() {
    _termuxRuntime.cancelActiveCommand();
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
  );

  Future<ToolExecutionResult> _executeTermuxCommand(
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
      if (command.length > TermuxRuntimeService.maxCommandChars) {
        return _toolError(
          call,
          'Command exceeds 32,000 characters.',
          'Command too long',
        );
      }
      final root = await Directory(workspaceRoot).resolveSymbolicLinks();
      if (!isTermuxSharedStoragePath(root)) {
        return _toolError(
          call,
          'Termux can only work with a project under shared storage (for example /storage/emulated/0). Reopen or move this project there, then run termux-setup-storage in Termux.',
          'Workspace is not in Termux-visible shared storage',
        );
      }
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
            TermuxRuntimeService.minTimeoutSeconds,
            TermuxRuntimeService.maxTimeoutSeconds,
          )
          .toInt();
      final result = await _termuxRuntime.execute(
        command: command,
        workspaceRoot: root,
        workingDirectory: canonicalCwd,
        timeoutSeconds: timeout,
        onOutput: onRuntimeOutput,
      );
      return ToolExecutionResult(
        callId: call.id,
        toolName: call.name,
        output: TermuxRuntimeService.formatOutputForTool(result),
        summary: result.error == null
            ? 'Termux command finished (exit ${result.exitCode})'
            : 'Termux command error: ${result.error}',
      );
    } catch (error) {
      return _toolError(
        call,
        'Termux command failed: $error',
        'Termux command failed',
      );
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
}

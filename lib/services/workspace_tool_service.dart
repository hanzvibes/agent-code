import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'search_service.dart';
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

  WorkspaceToolService({SearchService? searchService})
    : _searchService = searchService ?? SearchService();

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
  }) async {
    final name = call.name;
    final callId = call.id;

    if (workspaceRoot.isEmpty) {
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

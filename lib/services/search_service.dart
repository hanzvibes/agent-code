import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class SearchMatch {
  final String path;
  final String relativePath;
  final int lineNumber;
  final String linePreview;
  final bool isPathMatch;

  const SearchMatch({
    required this.path,
    required this.relativePath,
    required this.lineNumber,
    required this.linePreview,
    required this.isPathMatch,
  });
}

class SearchService {
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
  static const int maxTotalSizeBytes = 5 * 1024 * 1024;
  static const int maxResults = 100;

  Future<List<SearchMatch>> search(String workspaceRoot, String query) async {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return [];

    final root = await Directory(workspaceRoot).resolveSymbolicLinks();
    final results = <SearchMatch>[];
    final bytesScanned = [0];
    await _searchDir(
      Directory(root),
      root,
      normalizedQuery,
      results,
      bytesScanned,
    );
    return results;
  }

  Future<void> _searchDir(
    Directory dir,
    String root,
    String lowerQuery,
    List<SearchMatch> results,
    List<int> bytesScanned,
  ) async {
    if (results.length >= maxResults) return;

    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false)
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    } catch (_) {
      return;
    }

    for (final entity in entries) {
      if (results.length >= maxResults) break;
      final name = p.basename(entity.path);
      if (name.startsWith('.') || _skip.contains(name)) continue;
      if (entity is Directory) {
        await _searchDir(entity, root, lowerQuery, results, bytesScanned);
      } else if (entity is File) {
        await _searchFile(entity, root, lowerQuery, results, bytesScanned);
      }
    }
  }

  Future<void> _searchFile(
    File file,
    String root,
    String lowerQuery,
    List<SearchMatch> results,
    List<int> bytesScanned,
  ) async {
    if (results.length >= maxResults) return;

    FileStat stat;
    try {
      stat = await file.stat();
    } catch (_) {
      return;
    }
    final relativePath = p.relative(file.path, from: root);
    if (relativePath.toLowerCase().contains(lowerQuery)) {
      results.add(
        SearchMatch(
          path: file.path,
          relativePath: relativePath,
          lineNumber: 0,
          linePreview: relativePath,
          isPathMatch: true,
        ),
      );
      if (results.length >= maxResults) return;
    }

    if (stat.size > maxPerFileSizeBytes ||
        bytesScanned[0] >= maxTotalSizeBytes ||
        stat.size > maxTotalSizeBytes - bytesScanned[0]) {
      return;
    }

    List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return;
    }
    if (bytes.length > maxTotalSizeBytes - bytesScanned[0]) return;
    bytesScanned[0] += bytes.length;
    if (bytes.contains(0)) return;

    String content;
    try {
      content = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return;
    }

    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (results.length >= maxResults) break;
      if (lines[i].toLowerCase().contains(lowerQuery)) {
        final preview = lines[i].trim();
        results.add(
          SearchMatch(
            path: file.path,
            relativePath: relativePath,
            lineNumber: i + 1,
            linePreview: preview.length > 120
                ? preview.substring(0, 120)
                : preview,
            isPathMatch: false,
          ),
        );
      }
    }
  }
}

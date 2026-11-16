import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/file_node.dart';

class WorkspaceService {
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
  static const _maxDepth = 5;
  static const _maxNodes = 600;
  static const maxEditableBytes = 512 * 1024;

  int _nodeCount = 0;

  List<FileNode> buildTree(String rootPath) {
    _nodeCount = 0;
    final dir = Directory(rootPath);
    if (!dir.existsSync()) return [];
    return _listDir(dir, 0);
  }

  List<FileNode> _listDir(Directory dir, int depth) {
    if (depth >= _maxDepth || _nodeCount >= _maxNodes) return [];
    final entries = <FileNode>[];
    try {
      final list = dir.listSync(followLinks: false)
        ..sort((a, b) {
          final aIsDir = a is Directory ? 0 : 1;
          final bIsDir = b is Directory ? 0 : 1;
          if (aIsDir != bIsDir) return aIsDir - bIsDir;
          return p
              .basename(a.path)
              .toLowerCase()
              .compareTo(p.basename(b.path).toLowerCase());
        });
      for (final entity in list) {
        if (_nodeCount >= _maxNodes) break;
        final name = p.basename(entity.path);
        if (name.startsWith('.') || _skip.contains(name)) continue;
        if (entity is Directory) {
          final node = FileNode(
            name: name,
            path: entity.path,
            isDirectory: true,
            depth: depth,
          );
          _nodeCount++;
          node.children = _listDir(entity, depth + 1);
          entries.add(node);
        } else if (entity is File) {
          _nodeCount++;
          entries.add(
            FileNode(
              name: name,
              path: entity.path,
              isDirectory: false,
              depth: depth,
            ),
          );
        }
      }
    } catch (_) {
      // An unreadable subdirectory should not prevent browsing the rest.
    }
    return entries;
  }

  static Future<String> resolveSafePath(
    String root,
    String relativePath,
  ) async {
    final normalized = relativePath.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        segments.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FileSystemException('Patch contains an unsafe project path.');
    }

    final rootCanonical = await Directory(root).resolveSymbolicLinks();
    final candidate = p.normalize(p.joinAll([rootCanonical, ...segments]));
    if (candidate == rootCanonical || !p.isWithin(rootCanonical, candidate)) {
      throw const FileSystemException('Patch target is outside the project.');
    }

    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      throw const FileSystemException('Patch target is a directory.');
    }
    if (type != FileSystemEntityType.notFound) {
      final canonical = await File(candidate).resolveSymbolicLinks();
      if (!p.isWithin(rootCanonical, canonical)) {
        throw const FileSystemException(
          'Patch target resolves outside the project folder.',
        );
      }
      if ((await File(canonical).stat()).type ==
          FileSystemEntityType.directory) {
        throw const FileSystemException('Patch target is a directory.');
      }
    } else {
      var parent = Directory(p.dirname(candidate));
      while (!await parent.exists() &&
          parent.path != rootCanonical &&
          p.isWithin(rootCanonical, parent.path)) {
        final next = parent.parent;
        if (next.path == parent.path) break;
        parent = next;
      }
      if (!await parent.exists()) {
        throw const FileSystemException('Patch parent folder is unavailable.');
      }
      final canonicalParent = await parent.resolveSymbolicLinks();
      if (canonicalParent != rootCanonical &&
          !p.isWithin(rootCanonical, canonicalParent)) {
        throw const FileSystemException(
          'Patch parent resolves outside the project folder.',
        );
      }
    }
    return candidate;
  }

  /// Read a file for context inclusion. Applies the same 512 KB guard as
  /// [readFile]. Returns the content and a [truncated] flag when the content
  /// was capped at [cap] characters.
  ///
  /// Callers are responsible for path-safety checks (via [resolveSafePath])
  /// before calling this method.
  static Future<({String content, bool truncated})> readFileForContext(
    String path, {
    int cap = 24000,
  }) async {
    final raw = await readFile(path); // enforces 512 KB
    if (raw.length > cap) {
      return (content: raw.substring(0, cap), truncated: true);
    }
    return (content: raw, truncated: false);
  }

  static Future<String> readFile(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const FileSystemException('This is not a regular file.');
    }
    if (stat.size > maxEditableBytes) {
      throw FileSystemException(
        'File too large (${stat.size ~/ 1024} KB). Max 512 KB.',
        path,
      );
    }
    return file.readAsString();
  }

  static Future<void> writeFile(String path, String content) async {
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsString(content);
  }

  static String treeText(List<FileNode> nodes, {int maxLines = 150}) {
    final buf = StringBuffer();
    _appendTree(buf, nodes, 0, maxLines);
    return buf.toString();
  }

  static int _appendTree(
    StringBuffer buf,
    List<FileNode> nodes,
    int indent,
    int maxLines,
  ) {
    var written = 0;
    for (final node in nodes) {
      if (written >= maxLines) break;
      buf.write('  ' * indent);
      buf.writeln(
        node.isDirectory ? '[dir] ${node.name}/' : '[file] ${node.name}',
      );
      written++;
      if (node.isDirectory && node.children.isNotEmpty) {
        written += _appendTree(
          buf,
          node.children,
          indent + 1,
          maxLines - written,
        );
      }
    }
    return written;
  }

  static Future<void> createSampleWorkspace(String basePath) async {
    final root = Directory(basePath);
    if (!root.existsSync()) root.createSync(recursive: true);

    await File('$basePath/README.md').writeAsString(
      '# Sample Project\n\nWelcome to Code Harness! This is a demo workspace.\n\n## Files\n- `lib/main.dart` — entry point\n- `lib/models/user.dart` — data model\n- `pubspec.yaml` — project config\n',
    );
    await Directory('$basePath/lib/models').create(recursive: true);
    await File('$basePath/lib/main.dart').writeAsString(
      "void main() {\n  print('Hello from the sample project!');\n}\n",
    );
    await File('$basePath/lib/models/user.dart').writeAsString(r'''class User {
  final String id;
  final String name;
  final String email;

  const User({
    required this.id,
    required this.name,
    required this.email,
  });

  @override
  String toString() => 'User(id: $id, name: $name, email: $email)';
}
''');
    await File('$basePath/pubspec.yaml').writeAsString(
      'name: sample_project\ndescription: A sample demo project for Code Harness.\nversion: 1.0.0\n\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n',
    );
  }
}

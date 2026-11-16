import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace_service.dart';

class NewFileService {
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

  static Future<String> validate(
    String workspaceRoot,
    String relativePath,
  ) async {
    final normalized = relativePath.replaceAll('\\', '/').trim();
    if (normalized.isEmpty) {
      throw const FileSystemException('Path cannot be empty.');
    }
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw const FileSystemException('Absolute paths are not allowed.');
    }
    if (normalized.endsWith('/')) {
      throw const FileSystemException('Path must not end with a slash.');
    }

    final segments = normalized.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw const FileSystemException('Path contains invalid segments.');
      }
      if (segment.startsWith('.')) {
        throw FileSystemException('Hidden segment not allowed: $segment');
      }
      if (_skip.contains(segment)) {
        throw FileSystemException('Ignored directory not allowed: $segment');
      }
    }

    // This checks the canonical workspace and all existing parent symlinks.
    final absolutePath = await WorkspaceService.resolveSafePath(
      workspaceRoot,
      normalized,
    );
    final type = await FileSystemEntity.type(absolutePath, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'File or directory already exists: $relativePath',
      );
    }
    return absolutePath;
  }

  static Future<String> createFile(
    String workspaceRoot,
    String relativePath,
  ) async {
    final absolutePath = await validate(workspaceRoot, relativePath);
    await Directory(p.dirname(absolutePath)).create(recursive: true);
    // Revalidate after creating parents and use exclusive creation to avoid
    // overwriting a target that appeared between validation and creation.
    final checkedPath = await validate(workspaceRoot, relativePath);
    if (checkedPath != absolutePath) {
      throw const FileSystemException(
        'Workspace path changed during creation.',
      );
    }
    await File(checkedPath).create(exclusive: true);
    return checkedPath;
  }
}

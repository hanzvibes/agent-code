import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:code_harness/services/workspace_service.dart';

void main() {
  late Directory temp;
  late Directory root;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('code_harness_test_');
    root = Directory(p.join(temp.path, 'project'));
    await root.create();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('resolves a safe relative file path inside the workspace', () async {
    final target = await WorkspaceService.resolveSafePath(
      root.path,
      'lib/main.dart',
    );
    expect(target, p.join(root.path, 'lib', 'main.dart'));
  });

  test('rejects traversal and absolute paths', () async {
    await expectLater(
      WorkspaceService.resolveSafePath(root.path, '../outside.dart'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      WorkspaceService.resolveSafePath(root.path, '/tmp/outside.dart'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('rejects a symlink that escapes the workspace', () async {
    final outside = Directory(p.join(temp.path, 'outside'));
    await outside.create();
    await Link(p.join(root.path, 'escape')).create(outside.path);

    await expectLater(
      WorkspaceService.resolveSafePath(root.path, 'escape/new.dart'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('does not traverse ignored or hidden directories', () async {
    await Directory(p.join(root.path, '.git')).create();
    await File(p.join(root.path, '.git', 'config')).writeAsString('secret');
    await Directory(p.join(root.path, 'build')).create();
    await File(p.join(root.path, 'build', 'cache')).writeAsString('cache');
    await File(p.join(root.path, 'main.dart')).writeAsString('void main() {}');

    final tree = WorkspaceService().buildTree(root.path);
    expect(tree.map((node) => node.name), ['main.dart']);
  });

  test('rejects files larger than the editor limit', () async {
    final file = File(p.join(root.path, 'large.txt'));
    await file.writeAsString('x' * (WorkspaceService.maxEditableBytes + 1));

    await expectLater(
      WorkspaceService.readFile(file.path),
      throwsA(isA<FileSystemException>()),
    );
  });
}

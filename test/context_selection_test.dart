import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:code_harness/models/context_snapshot.dart';
import 'package:code_harness/services/assistant_context_builder.dart';
import 'package:code_harness/services/workspace_service.dart';

void main() {
  late Directory temp;
  late Directory root;
  late AssistantContextBuilder builder;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('code_harness_ctx_test_');
    root = Directory(p.join(temp.path, 'project'));
    await root.create();
    builder = AssistantContextBuilder();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<File> writeFile(String relativePath, String content) async {
    final file = File(p.join(root.path, relativePath));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  test(
    'keeps the open editor buffer as the baseline and sends it first',
    () async {
      final open = await writeFile('lib/main.dart', 'saved source');
      final extra = await writeFile('lib/helper.dart', 'helper source');

      final result = await builder.build(
        workspaceRoot: root.path,
        openFilePath: open.path,
        openFileContent: 'unsaved editor buffer',
        selectedAbsolutePaths: [extra.path],
      );

      expect(result.snapshot.files.map((file) => file.relativePath), [
        'lib/main.dart',
        'lib/helper.dart',
      ]);
      expect(result.snapshot.files.first.baseline, 'unsaved editor buffer');
      expect(result.promptContents['lib/main.dart'], 'unsaved editor buffer');
      expect(result.snapshot.openFilePath, open.path);
    },
  );

  test(
    'shares the 48k budget across eight selected files without starving any',
    () async {
      final files = <File>[];
      for (var i = 0; i < AssistantContextBuilder.maxContextFiles; i++) {
        files.add(await writeFile('src/file_$i.dart', 'x' * 10000));
      }

      final result = await builder.build(
        workspaceRoot: root.path,
        selectedAbsolutePaths: files.map((file) => file.path),
      );
      final lengths = result.promptContents.values.map(
        (content) => content.length,
      );

      expect(result.snapshot.files, hasLength(8));
      expect(result.promptContents, hasLength(8));
      expect(lengths.every((length) => length > 0), isTrue);
      expect(lengths.fold<int>(0, (sum, length) => sum + length), 48000);
      expect(lengths.every((length) => length <= 24000), isTrue);
      expect(result.snapshot.files.every((file) => file.truncated), isTrue);
    },
  );

  test(
    'keeps the open file first and distributes the remaining budget across extras',
    () async {
      final open = await writeFile('lib/main.dart', 'disk version');
      final extras = <File>[];
      for (var i = 0; i < 7; i++) {
        extras.add(await writeFile('lib/part_$i.dart', 'y' * 20000));
      }

      final result = await builder.build(
        workspaceRoot: root.path,
        openFilePath: open.path,
        openFileContent: 'o' * 30000,
        selectedAbsolutePaths: extras.map((file) => file.path),
      );
      final lengths = result.promptContents.values.map(
        (content) => content.length,
      );

      expect(result.snapshot.files, hasLength(8));
      expect(result.snapshot.files.first.relativePath, 'lib/main.dart');
      expect(result.promptContents.values.first.length, 24000);
      expect(lengths.skip(1).every((length) => length > 0), isTrue);
      expect(lengths.fold<int>(0, (sum, length) => sum + length), 48000);
      expect(result.snapshot.files.first.baseline, 'o' * 30000);
      expect(result.snapshot.files.first.truncated, isTrue);
    },
  );

  test(
    'redistributes unused characters from a short file to later files',
    () async {
      final first = await writeFile('lib/a.dart', 'tiny');
      final second = await writeFile('lib/b.dart', 'z' * 30000);

      final result = await builder.build(
        workspaceRoot: root.path,
        openFilePath: (await writeFile('lib/main.dart', 'm' * 24000)).path,
        openFileContent: 'm' * 24000,
        selectedAbsolutePaths: [first.path, second.path],
      );

      expect(result.promptContents['lib/a.dart'], 'tiny');
      expect(result.promptContents['lib/b.dart']!.length, 23996);
      expect(
        result.promptContents.values.fold<int>(
          0,
          (sum, content) => sum + content.length,
        ),
        48000,
      );
    },
  );

  test(
    'deduplicates the open file if it is also selected as extra context',
    () async {
      final open = await writeFile('main.dart', 'code');
      final result = await builder.build(
        workspaceRoot: root.path,
        openFilePath: open.path,
        openFileContent: 'code',
        selectedAbsolutePaths: [open.path],
      );

      expect(result.snapshot.files, hasLength(1));
      expect(result.promptContents.keys, ['main.dart']);
    },
  );

  test(
    'rejects more than eight total files instead of silently dropping selection',
    () async {
      final files = <File>[];
      for (var i = 0; i < 9; i++) {
        files.add(await writeFile('file_$i.dart', 'x'));
      }

      await expectLater(
        builder.build(
          workspaceRoot: root.path,
          selectedAbsolutePaths: files.map((file) => file.path),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'rejects traversal and symlink escapes in selected context paths',
    () async {
      final outside = Directory(p.join(temp.path, 'outside'));
      await outside.create();
      final secret = File(p.join(outside.path, 'secret.dart'));
      await secret.writeAsString('private');
      await Link(p.join(root.path, 'escape')).create(outside.path);

      await expectLater(
        builder.build(
          workspaceRoot: root.path,
          selectedAbsolutePaths: [
            p.join(root.path, '..', 'outside', 'secret.dart'),
          ],
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        builder.build(
          workspaceRoot: root.path,
          selectedAbsolutePaths: [p.join(root.path, 'escape', 'secret.dart')],
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('rejects an open file outside the selected workspace', () async {
    final outside = await writeFile('../outside.dart', 'not inside');
    await expectLater(
      builder.build(
        workspaceRoot: root.path,
        openFilePath: outside.path,
        openFileContent: 'secret',
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'exposes the full baseline when the prompt content is truncated',
    () async {
      final file = await writeFile('large.txt', 'a' * 30000);
      final result = await builder.build(
        workspaceRoot: root.path,
        openFilePath: file.path,
        openFileContent: 'a' * 30000,
      );
      final snapshotFile = result.snapshot.forAbsolutePath(file.path)!;

      expect(result.promptContents['large.txt'], hasLength(24000));
      expect(snapshotFile.baseline, hasLength(30000));
      expect(snapshotFile.truncated, isTrue);
    },
  );

  test('returns an empty immutable context when no project is open', () async {
    final result = await builder.build(workspaceRoot: '');

    expect(result.snapshot.files, isEmpty);
    expect(result.promptContents, isEmpty);
    expect(
      () => result.snapshot.files.add(
        const ContextFile(
          relativePath: 'x.dart',
          absolutePath: '/project/x.dart',
          baseline: '',
          truncated: false,
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'readFileForContext preserves its per-file cap and 512 KB guard',
    () async {
      final file = await writeFile('sample.txt', 'a' * 200);
      final bounded = await WorkspaceService.readFileForContext(
        file.path,
        cap: 100,
      );
      expect(bounded.content, hasLength(100));
      expect(bounded.truncated, isTrue);

      final huge = await writeFile(
        'huge.txt',
        'x' * (WorkspaceService.maxEditableBytes + 1),
      );
      await expectLater(
        WorkspaceService.readFileForContext(huge.path, cap: 24000),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}

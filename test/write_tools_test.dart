import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/services/checkpoint_store.dart';
import 'package:code_harness/services/workspace_tool_service.dart';

void main() {
  late Directory tempDir;
  late Directory outsideDir;
  late WorkspaceToolService toolService;
  late CheckpointStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('write_tools_test_');
    outsideDir = await Directory.systemTemp.createTemp('write_tools_out_');
    toolService = WorkspaceToolService();
    store = CheckpointStore();
    File('${tempDir.path}/notes.txt').writeAsStringSync(
      'alpha\nbeta\nalpha\n',
    );
    File('${outsideDir.path}/secret.txt').writeAsStringSync('secret\n');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    if (outsideDir.existsSync()) await outsideDir.delete(recursive: true);
  });

  Future<ToolExecutionResult> run(
    String name,
    Map<String, dynamic> args, {
    CheckpointStore? checkpointStore,
    String? taskId,
  }) => toolService.execute(
    workspaceRoot: tempDir.path,
    call: ToolCallInfo(id: 'c1', name: name, arguments: jsonEncode(args)),
    checkpointStore: checkpointStore ?? store,
    taskId: taskId ?? 'task1',
    stepId: 'step1',
  );

  group('write_file', () {
    test('creates a new file and records a checkpoint', () async {
      final result = await run('write_file', {
        'path': 'new.txt',
        'content': 'hello\n',
      });

      expect(result.isError, isFalse);
      expect(await File('${tempDir.path}/new.txt').readAsString(), 'hello\n');
      final checkpoints = store.checkpointsForTask('task1');
      expect(checkpoints, hasLength(1));
      expect(checkpoints.first.path, 'new.txt');
      expect(checkpoints.first.before, isNull);
      expect(checkpoints.first.after, 'hello\n');
      expect(checkpoints.first.isCreate, isTrue);
    });

    test('overwrites an existing file and records before/after', () async {
      final result = await run('write_file', {
        'path': 'notes.txt',
        'content': 'replaced\n',
      });

      expect(result.isError, isFalse);
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'replaced\n',
      );
      final cp = store.checkpointsForTask('task1').first;
      expect(cp.before, 'alpha\nbeta\nalpha\n');
      expect(cp.after, 'replaced\n');
    });

    test('identical content is a no-op without a checkpoint', () async {
      final result = await run('write_file', {
        'path': 'notes.txt',
        'content': 'alpha\nbeta\nalpha\n',
      });

      expect(result.isError, isFalse);
      expect(result.output, contains('unchanged'));
      expect(store.checkpointsForTask('task1'), isEmpty);
    });

    test('rejects binary content', () async {
      final result = await run('write_file', {
        'path': 'bin.txt',
        'content': 'a\u0000b',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('Binary content'));
      expect(await File('${tempDir.path}/bin.txt').exists(), isFalse);
    });

    test('rejects content over 512 KB', () async {
      final result = await run('write_file', {
        'path': 'big.txt',
        'content': 'x' * (512 * 1024 + 1),
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('512 KB'));
    });

    test('creates missing parent folders', () async {
      final result = await run('write_file', {
        'path': 'deep/nested/file.txt',
        'content': 'deep\n',
      });

      expect(result.isError, isFalse);
      expect(
        await File('${tempDir.path}/deep/nested/file.txt').readAsString(),
        'deep\n',
      );
    });
  });

  group('edit_file', () {
    test('replaces the single match', () async {
      final result = await run('edit_file', {
        'path': 'notes.txt',
        'oldText': 'beta',
        'newText': 'BETA',
      });

      expect(result.isError, isFalse);
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'alpha\nBETA\nalpha\n',
      );
      final cp = store.checkpointsForTask('task1').first;
      expect(cp.before, 'alpha\nbeta\nalpha\n');
      expect(cp.after, 'alpha\nBETA\nalpha\n');
    });

    test('refuses when oldText matches zero times', () async {
      final result = await run('edit_file', {
        'path': 'notes.txt',
        'oldText': 'gamma',
        'newText': 'GAMMA',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('No occurrence'));
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'alpha\nbeta\nalpha\n',
      );
      expect(store.checkpointsForTask('task1'), isEmpty);
    });

    test('refuses when oldText matches more than once', () async {
      final result = await run('edit_file', {
        'path': 'notes.txt',
        'oldText': 'alpha',
        'newText': 'ALPHA',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('matches 2 times'));
      expect(result.output, contains('exactly once'));
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'alpha\nbeta\nalpha\n',
      );
      expect(store.checkpointsForTask('task1'), isEmpty);
    });

    test('refuses to edit a missing file', () async {
      final result = await run('edit_file', {
        'path': 'missing.txt',
        'oldText': 'a',
        'newText': 'b',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('File not found'));
    });

    test('refuses a no-op edit', () async {
      final result = await run('edit_file', {
        'path': 'notes.txt',
        'oldText': 'beta',
        'newText': 'beta',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('identical'));
    });
  });

  group('create_file', () {
    test('creates a missing file', () async {
      final result = await run('create_file', {
        'path': 'fresh.txt',
        'content': 'new\n',
      });

      expect(result.isError, isFalse);
      expect(await File('${tempDir.path}/fresh.txt').readAsString(), 'new\n');
    });

    test('fails when the file already exists', () async {
      final result = await run('create_file', {
        'path': 'notes.txt',
        'content': 'nope\n',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('already exists'));
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'alpha\nbeta\nalpha\n',
      );
    });
  });

  group('delete_file', () {
    test('moves the file to trash and records a delete checkpoint',
        () async {
      final result = await run('delete_file', {'path': 'notes.txt'});

      expect(result.isError, isFalse);
      expect(await File('${tempDir.path}/notes.txt').exists(), isFalse);
      final trashPath =
          '${tempDir.path}/${CheckpointStore.trashPathFor('task1', 'notes.txt')}';
      expect(await File(trashPath).readAsString(), 'alpha\nbeta\nalpha\n');
      final cp = store.checkpointsForTask('task1').first;
      expect(cp.isDelete, isTrue);
      expect(cp.before, 'alpha\nbeta\nalpha\n');
      expect(cp.after, isNull);
    });

    test('delete then undo restores the file', () async {
      await run('delete_file', {'path': 'notes.txt'});

      final undo = await store.undoTask('task1', tempDir.path);

      expect(undo.ok, isTrue);
      expect(
        await File('${tempDir.path}/notes.txt').readAsString(),
        'alpha\nbeta\nalpha\n',
      );
    });

    test('fails when the file does not exist', () async {
      final result = await run('delete_file', {'path': 'nope.txt'});

      expect(result.isError, isTrue);
      expect(result.output, contains('File not found'));
    });
  });

  group('path safety (all write tools)', () {
    const unsafePaths = [
      '../escape.txt',
      'sub/../../escape.txt',
      '/etc/passwd',
      'C:\\Windows\\secret.txt',
    ];

    for (final tool in [
      'write_file',
      'edit_file',
      'create_file',
      'delete_file',
    ]) {
      for (final unsafe in unsafePaths) {
        test('$tool rejects "$unsafe"', () async {
          final args = <String, dynamic>{'path': unsafe};
          if (tool != 'delete_file') args['content'] = 'x\n';
          if (tool == 'edit_file') {
            args['oldText'] = 'a';
            args['newText'] = 'b';
          }
          final result = await run(tool, args);

          expect(result.isError, isTrue);
          expect(result.output, contains('Unsafe path'));
        });
      }
    }

    test('write tools reject paths inside the trash folder', () async {
      final result = await run('write_file', {
        'path': '.codeharness-trash/task1/notes.txt',
        'content': 'sneaky\n',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('trash'));
    });

    test('symlink escape is rejected', () async {
      Link(
        '${tempDir.path}/link.txt',
      ).createSync('${outsideDir.path}/secret.txt');

      final result = await run('write_file', {
        'path': 'link.txt',
        'content': 'pwned\n',
      });

      expect(result.isError, isTrue);
      expect(await File('${outsideDir.path}/secret.txt').readAsString(), 'secret\n');
    });

    test('symlink escape is rejected for edit and delete too', () async {
      Link(
        '${tempDir.path}/link.txt',
      ).createSync('${outsideDir.path}/secret.txt');

      final edit = await run('edit_file', {
        'path': 'link.txt',
        'oldText': 'secret',
        'newText': 'pwned',
      });
      expect(edit.isError, isTrue);

      final delete = await run('delete_file', {'path': 'link.txt'});
      expect(delete.isError, isTrue);
      expect(await File('${outsideDir.path}/secret.txt').exists(), isTrue);
    });
  });

  group('checkpoint context', () {
    test('write tools refuse to run without a checkpoint store', () async {
      final result = await toolService.execute(
        workspaceRoot: tempDir.path,
        call: const ToolCallInfo(
          id: 'c1',
          name: 'write_file',
          arguments: '{"path": "x.txt", "content": "x"}',
        ),
        taskId: 'task1',
      );

      expect(result.isError, isTrue);
      expect(result.output, contains('checkpoint tracking'));
      expect(await File('${tempDir.path}/x.txt').exists(), isFalse);
    });

    test('write tools refuse to run without a task id', () async {
      final result = await toolService.execute(
        workspaceRoot: tempDir.path,
        call: const ToolCallInfo(
          id: 'c1',
          name: 'write_file',
          arguments: '{"path": "x.txt", "content": "x"}',
        ),
        checkpointStore: store,
      );

      expect(result.isError, isTrue);
      expect(await File('${tempDir.path}/x.txt').exists(), isFalse);
    });
  });
}

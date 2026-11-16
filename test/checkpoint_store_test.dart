import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/models/checkpoint.dart';
import 'package:code_harness/services/checkpoint_store.dart';

void main() {
  late Directory tempDir;
  late CheckpointStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('checkpoint_test_');
    store = CheckpointStore();
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Checkpoint writeCheckpoint({
    String taskId = 't1',
    String stepId = 's1',
    String path = 'a.txt',
    String? before,
    String? after,
  }) => Checkpoint(
    taskId: taskId,
    stepId: stepId,
    path: path,
    before: before,
    after: after,
    kind: CheckpointKind.write,
  );

  Future<void> writeTestFile(String relativePath, String content) async {
    final file = File('${tempDir.path}/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('undo of one edit restores the before content', () async {
    await writeTestFile('a.txt', 'after\n');
    final cp = writeCheckpoint(before: 'before\n', after: 'after\n');
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isTrue);
    expect(result.undoneCount, 1);
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'before\n');
    expect(cp.undone, isTrue);
  });

  test('undo is idempotent: a second undo is a no-op success', () async {
    await writeTestFile('a.txt', 'after\n');
    final cp = writeCheckpoint(before: 'before\n', after: 'after\n');
    store.record(cp);
    await store.undoCheckpoint(cp.id, tempDir.path);

    final second = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(second.ok, isTrue);
    expect(second.undoneCount, 0);
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'before\n');
  });

  test('undo of a create deletes the file', () async {
    await writeTestFile('new.txt', 'fresh\n');
    final cp = writeCheckpoint(
      path: 'new.txt',
      before: null,
      after: 'fresh\n',
    );
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isTrue);
    expect(await File('${tempDir.path}/new.txt').exists(), isFalse);
  });

  test('undo of a create succeeds when the file is already gone', () async {
    final cp = writeCheckpoint(
      path: 'new.txt',
      before: null,
      after: 'fresh\n',
    );
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isTrue);
    expect(result.undoneCount, 1);
  });

  test('undo is refused when the file changed by hand afterwards', () async {
    await writeTestFile('a.txt', 'hand-edited\n');
    final cp = writeCheckpoint(before: 'before\n', after: 'after\n');
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isFalse);
    expect(result.error, contains('changed by hand'));
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'hand-edited\n');
    expect(cp.undone, isFalse);
  });

  test('undo is refused when the file was deleted afterwards', () async {
    final cp = writeCheckpoint(before: 'before\n', after: 'after\n');
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isFalse);
    expect(result.error, contains('was deleted'));
  });

  test('undo of a whole task restores every file, newest first', () async {
    await writeTestFile('a.txt', 'a2\n');
    await writeTestFile('b.txt', 'b2\n');
    final cp1 = writeCheckpoint(path: 'a.txt', before: 'a1\n', after: 'a2\n');
    final cp2 = writeCheckpoint(path: 'b.txt', before: 'b1\n', after: 'b2\n');
    store.record(cp1);
    store.record(cp2);

    final result = await store.undoTask('t1', tempDir.path);

    expect(result.ok, isTrue);
    expect(result.undoneCount, 2);
    expect(result.undonePaths, ['b.txt', 'a.txt']);
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'a1\n');
    expect(await File('${tempDir.path}/b.txt').readAsString(), 'b1\n');
  });

  test('undo of a step only touches that step', () async {
    await writeTestFile('a.txt', 'a2\n');
    await writeTestFile('b.txt', 'b2\n');
    store.record(
      writeCheckpoint(
        stepId: 's1',
        path: 'a.txt',
        before: 'a1\n',
        after: 'a2\n',
      ),
    );
    store.record(
      writeCheckpoint(
        stepId: 's2',
        path: 'b.txt',
        before: 'b1\n',
        after: 'b2\n',
      ),
    );

    final result = await store.undoStep('t1', 's1', tempDir.path);

    expect(result.ok, isTrue);
    expect(result.undoneCount, 1);
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'a1\n');
    expect(await File('${tempDir.path}/b.txt').readAsString(), 'b2\n');
  });

  test('a refused checkpoint blocks the whole task undo (nothing changes)',
      () async {
    await writeTestFile('a.txt', 'a2\n');
    await writeTestFile('b.txt', 'hand-edited\n');
    store.record(writeCheckpoint(path: 'a.txt', before: 'a1\n', after: 'a2\n'));
    store.record(
      writeCheckpoint(path: 'b.txt', before: 'b1\n', after: 'b2\n'),
    );

    final result = await store.undoTask('t1', tempDir.path);

    expect(result.ok, isFalse);
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'a2\n');
    expect(await File('${tempDir.path}/b.txt').readAsString(), 'hand-edited\n');
  });

  test('delete checkpoint restores the file from trash', () async {
    final trashPath = CheckpointStore.trashPathFor('t1', 'gone.txt');
    await writeTestFile(trashPath, 'precious\n');
    final cp = Checkpoint(
      taskId: 't1',
      stepId: 's1',
      path: 'gone.txt',
      before: 'precious\n',
      after: null,
      trashPath: trashPath,
      kind: CheckpointKind.delete,
    );
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isTrue);
    expect(await File('${tempDir.path}/gone.txt').readAsString(), 'precious\n');
    expect(await File('${tempDir.path}/$trashPath').exists(), isFalse);
  });

  test('delete undo is refused when a different file took its place',
      () async {
    final trashPath = CheckpointStore.trashPathFor('t1', 'gone.txt');
    await writeTestFile(trashPath, 'precious\n');
    await writeTestFile('gone.txt', 'something else\n');
    final cp = Checkpoint(
      taskId: 't1',
      stepId: 's1',
      path: 'gone.txt',
      before: 'precious\n',
      after: null,
      trashPath: trashPath,
      kind: CheckpointKind.delete,
    );
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isFalse);
    expect(result.error, contains('different file'));
    expect(
      await File('${tempDir.path}/gone.txt').readAsString(),
      'something else\n',
    );
  });

  test('delete undo fails after the trash was purged', () async {
    final trashPath = CheckpointStore.trashPathFor('t1', 'gone.txt');
    await writeTestFile(trashPath, 'precious\n');
    final cp = Checkpoint(
      taskId: 't1',
      stepId: 's1',
      path: 'gone.txt',
      before: 'precious\n',
      after: null,
      trashPath: trashPath,
      kind: CheckpointKind.delete,
    );
    store.record(cp);
    await store.purgeTrashForTask('t1', tempDir.path);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isFalse);
    expect(result.error, contains('trash copy is gone'));
  });

  test('purgeTrashForTask only removes that task trash folder', () async {
    await writeTestFile(
      CheckpointStore.trashPathFor('t1', 'a.txt'),
      'a\n',
    );
    await writeTestFile(
      CheckpointStore.trashPathFor('t2', 'b.txt'),
      'b\n',
    );

    await store.purgeTrashForTask('t1', tempDir.path);

    expect(
      await Directory(
        '${tempDir.path}/${CheckpointStore.trashDirName}/t1',
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        '${tempDir.path}/${CheckpointStore.trashPathFor('t2', 'b.txt')}',
      ).exists(),
      isTrue,
    );
  });

  test('non-ASCII content compares correctly on undo', () async {
    await writeTestFile('a.txt', 'héllo wörld — ünïcode\n');
    final cp = writeCheckpoint(
      before: 'before\n',
      after: 'héllo wörld — ünïcode\n',
    );
    store.record(cp);

    final result = await store.undoCheckpoint(cp.id, tempDir.path);

    expect(result.ok, isTrue);
    expect(await File('${tempDir.path}/a.txt').readAsString(), 'before\n');
  });
}

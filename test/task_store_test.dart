import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/checkpoint.dart';
import 'package:code_harness/models/tool_call_record.dart';
import 'package:code_harness/services/task_store.dart';

void main() {
  late Directory tempDir;
  late Box testBox;
  late TaskStore store;

  const workspace = '/workspace/project-a';

  AgentTask task({
    String id = 'task_1',
    String title = 'Add tests',
    TaskStatus status = TaskStatus.paused,
    int roundsUsed = 3,
    int toolCallsUsed = 7,
  }) {
    return AgentTask(
      id: id,
      title: title,
      status: status,
      todos: [
        TaskStep(id: 's1', title: 'Read the file', status: TaskStepStatus.done),
        TaskStep(
          id: 's2',
          title: 'Edit the file',
          status: TaskStepStatus.active,
        ),
      ],
      roundsUsed: roundsUsed,
      toolCallsUsed: toolCallsUsed,
      summary: 'Read the file, started the edit.',
    );
  }

  ToolCallRecord record({
    String id = 'tc_1',
    String toolName = 'read_project_file',
    ToolCallStatus status = ToolCallStatus.ok,
  }) {
    return ToolCallRecord(
      id: id,
      taskId: 'task_1',
      stepId: 's1',
      toolName: toolName,
      arguments: {'path': 'lib/main.dart'},
      resultSummary: 'Read 12 lines',
      resultFull: 'line1\nline2',
      backend: 'bundled',
      status: status,
      durationMs: 42,
    );
  }

  Checkpoint checkpoint({String id = 'cp_1', String path = 'lib/main.dart'}) {
    return Checkpoint(
      id: id,
      taskId: 'task_1',
      stepId: 's1',
      path: path,
      before: 'old content',
      after: 'new content',
      kind: CheckpointKind.write,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('task_store_test_');
    Hive.init(tempDir.path);
    testBox = await Hive.openBox('test_agent_tasks');
    store = TaskStore(box: testBox);
  });

  tearDown(() async {
    await testBox.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'saves and loads a task with todos, tool calls and checkpoints',
    () async {
      final saved = task();
      await store.saveTask(
        workspace,
        saved,
        toolCalls: [record()],
        checkpoints: [checkpoint()],
      );

      final loaded = await store.loadTasks(workspace);
      expect(loaded.length, 1);
      final snapshot = loaded.first;
      expect(snapshot.task.id, 'task_1');
      expect(snapshot.task.title, 'Add tests');
      expect(snapshot.task.status, TaskStatus.paused);
      expect(snapshot.task.roundsUsed, 3);
      expect(snapshot.task.toolCallsUsed, 7);
      expect(snapshot.task.summary, 'Read the file, started the edit.');
      expect(snapshot.task.todos.length, 2);
      expect(snapshot.task.todos[0].title, 'Read the file');
      expect(snapshot.task.todos[0].status, TaskStepStatus.done);
      expect(snapshot.task.todos[1].status, TaskStepStatus.active);

      expect(snapshot.toolCalls.length, 1);
      final loadedRecord = snapshot.toolCalls.first;
      expect(loadedRecord.toolName, 'read_project_file');
      expect(loadedRecord.arguments['path'], 'lib/main.dart');
      expect(loadedRecord.resultSummary, 'Read 12 lines');
      expect(loadedRecord.resultFull, 'line1\nline2');
      expect(loadedRecord.backend, 'bundled');
      expect(loadedRecord.status, ToolCallStatus.ok);
      expect(loadedRecord.durationMs, 42);

      expect(snapshot.checkpoints.length, 1);
      final loadedCheckpoint = snapshot.checkpoints.first;
      expect(loadedCheckpoint.path, 'lib/main.dart');
      expect(loadedCheckpoint.before, 'old content');
      expect(loadedCheckpoint.after, 'new content');
      expect(loadedCheckpoint.undone, isFalse);
    },
  );

  test('saving the same task replaces it instead of duplicating', () async {
    await store.saveTask(workspace, task(), toolCalls: [record()]);
    final updated = task(roundsUsed: 5, toolCallsUsed: 9);
    await store.saveTask(workspace, updated, toolCalls: [record()]);

    final loaded = await store.loadTasks(workspace);
    expect(loaded.length, 1);
    expect(loaded.first.task.roundsUsed, 5);
    expect(loaded.first.task.toolCallsUsed, 9);
  });

  test('newest task comes first and old tasks are capped', () async {
    for (var i = 0; i < TaskStore.maxTasksPerWorkspace + 2; i++) {
      await store.saveTask(workspace, task(id: 'task_$i', title: 'Task $i'));
    }

    final loaded = await store.loadTasks(workspace);
    expect(loaded.length, TaskStore.maxTasksPerWorkspace);
    expect(loaded.first.task.id, 'task_11');
    expect(loaded.map((s) => s.task.id), isNot(contains('task_0')));
  });

  test(
    'loadResumableTask returns the newest paused/needsHelp/cancelled task',
    () async {
      await store.saveTask(
        workspace,
        task(id: 't_done', status: TaskStatus.done),
      );
      await store.saveTask(
        workspace,
        task(id: 't_paused', status: TaskStatus.paused),
      );
      await store.saveTask(
        workspace,
        task(id: 't_failed', status: TaskStatus.failed),
      );

      final resumable = await store.loadResumableTask(workspace);
      expect(resumable, isNotNull);
      expect(resumable!.task.id, 't_paused');
    },
  );

  test('loadResumableTask returns null when nothing can resume', () async {
    await store.saveTask(workspace, task(status: TaskStatus.done));
    expect(await store.loadResumableTask(workspace), isNull);
    expect(await store.loadResumableTask('/workspace/empty'), isNull);
  });

  test('deleteTask removes only that task', () async {
    await store.saveTask(workspace, task(id: 't1'));
    await store.saveTask(workspace, task(id: 't2'));

    await store.deleteTask(workspace, 't1');
    final loaded = await store.loadTasks(workspace);
    expect(loaded.map((s) => s.task.id), ['t2']);

    await store.deleteTask(workspace, 't2');
    expect(await store.loadTasks(workspace), isEmpty);
  });

  test('deleteAll clears the workspace entry', () async {
    await store.saveTask(workspace, task());
    await store.deleteAll(workspace);
    expect(await store.loadTasks(workspace), isEmpty);
  });

  test('malformed stored data loads as empty instead of throwing', () async {
    await testBox.put(workspace, 'not-json{{{');
    expect(await store.loadTasks(workspace), isEmpty);
    expect(await store.loadResumableTask(workspace), isNull);
  });

  test('empty workspace path is a no-op', () async {
    await store.saveTask('', task());
    expect(await store.loadTasks(''), isEmpty);
  });

  test('oversized full results are trimmed when persisted', () async {
    final big = record()..resultFull = 'x' * 50000;
    await store.saveTask(workspace, task(), toolCalls: [big]);

    final loaded = await store.loadTasks(workspace);
    final full = loaded.first.toolCalls.first.resultFull!;
    expect(full.length, lessThan(50000));
    expect(full, contains('[trimmed for storage]'));
    // The summary is never trimmed.
    expect(loaded.first.toolCalls.first.resultSummary, 'Read 12 lines');
  });

  test('tool call records round-trip through JSON', () {
    final original = record(status: ToolCallStatus.denied);
    final restored = ToolCallRecord.fromJson(original.toJson());
    expect(restored.id, original.id);
    expect(restored.taskId, original.taskId);
    expect(restored.stepId, original.stepId);
    expect(restored.toolName, original.toolName);
    expect(restored.status, ToolCallStatus.denied);
    expect(restored.backend, 'bundled');
  });

  test('checkpoints round-trip through JSON including undone', () {
    final original = checkpoint()..undone = true;
    final restored = Checkpoint.fromJson(original.toJson());
    expect(restored.id, original.id);
    expect(restored.before, 'old content');
    expect(restored.after, 'new content');
    expect(restored.undone, isTrue);
  });

  test('tasks round-trip through JSON including todo tool-call links', () {
    final original = task();
    original.todos.first.toolCallIds.add('tc_1');
    final restored = AgentTask.fromJson(original.toJson());
    expect(restored.todos.first.toolCallIds, ['tc_1']);
    expect(restored.mode, AgentMode.agent);
  });
}

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

import '../models/agent_task.dart';
import '../models/checkpoint.dart';
import '../models/tool_call_record.dart';

/// One persisted task: the task itself plus its tool-call history and
/// its checkpoints (Batch 5 — desain D8).
class TaskSnapshot {
  final AgentTask task;
  final List<ToolCallRecord> toolCalls;
  final List<Checkpoint> checkpoints;

  const TaskSnapshot({
    required this.task,
    this.toolCalls = const [],
    this.checkpoints = const [],
  });
}

/// Hive-backed store of agent tasks (Batch 5 — desain D8).
///
/// One entry per workspace path: the workspace's tasks, newest first,
/// each with its todo list, tool-call records (summary + full result),
/// checkpoint index, and compaction summary (kept on the task).
/// A task that stopped mid-work (`paused`, `needsHelp`, `cancelled`)
/// can be resumed after the app was closed — the controller restores
/// the latest resumable task when the workspace opens again.
///
/// Follows the [ChatRepository] pattern: JSON strings in one Hive box,
/// an optional override box for tests, and a null box degrades to a
/// no-op instead of throwing.
class TaskStore {
  static const String boxName = 'agent_tasks';

  /// At most this many tasks are kept per workspace.
  static const int maxTasksPerWorkspace = 10;

  /// At most this many tool-call records are kept per task.
  static const int maxToolCallsPerTask = 200;

  /// Full tool results longer than this are trimmed before they are
  /// persisted (the summary is always kept whole).
  static const int maxResultFullChars = 16384;

  final Box? _overrideBox;

  TaskStore({Box? box}) : _overrideBox = box;

  static Future<void> openBox() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box? get _box {
    try {
      if (_overrideBox != null) return _overrideBox;
      if (!Hive.isBoxOpen(boxName)) return null;
      return Hive.box(boxName);
    } catch (_) {
      return null;
    }
  }

  /// Saves (or replaces) [task] for [workspacePath], with its tool
  /// calls and checkpoints. Newest task first in the stored list.
  Future<void> saveTask(
    String workspacePath,
    AgentTask task, {
    List<ToolCallRecord> toolCalls = const [],
    List<Checkpoint> checkpoints = const [],
  }) async {
    if (workspacePath.isEmpty) return;
    final box = _box;
    if (box == null) return;
    final tasks = await loadTasks(workspacePath);
    final keptCalls = toolCalls.length > maxToolCallsPerTask
        ? toolCalls.sublist(toolCalls.length - maxToolCallsPerTask)
        : toolCalls;
    final snapshot = TaskSnapshot(
      task: task,
      toolCalls: keptCalls,
      checkpoints: checkpoints,
    );
    final updated = <TaskSnapshot>[
      snapshot,
      for (final existing in tasks)
        if (existing.task.id != task.id) existing,
    ];
    final trimmed = updated.length > maxTasksPerWorkspace
        ? updated.sublist(0, maxTasksPerWorkspace)
        : updated;
    await box.put(workspacePath, jsonEncode(trimmed.map(_encode).toList()));
  }

  /// All persisted tasks for [workspacePath], newest first. Empty
  /// when nothing was saved or the stored data is malformed.
  Future<List<TaskSnapshot>> loadTasks(String workspacePath) async {
    if (workspacePath.isEmpty) return [];
    final box = _box;
    if (box == null) return [];
    final raw = box.get(workspacePath);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw as String) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((entry) => _decode(entry.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// The newest task that can be continued (`paused`, `needsHelp`,
  /// or `cancelled`), or null when there is none.
  Future<TaskSnapshot?> loadResumableTask(String workspacePath) async {
    final tasks = await loadTasks(workspacePath);
    for (final snapshot in tasks) {
      switch (snapshot.task.status) {
        case TaskStatus.paused:
        case TaskStatus.needsHelp:
        case TaskStatus.cancelled:
          return snapshot;
        case TaskStatus.active:
        case TaskStatus.done:
        case TaskStatus.failed:
          continue;
      }
    }
    return null;
  }

  /// Deletes one task from [workspacePath]. No-op when it is absent.
  Future<void> deleteTask(String workspacePath, String taskId) async {
    if (workspacePath.isEmpty) return;
    final box = _box;
    if (box == null) return;
    final tasks = await loadTasks(workspacePath);
    final kept = tasks.where((s) => s.task.id != taskId).toList();
    if (kept.length == tasks.length) return;
    if (kept.isEmpty) {
      await box.delete(workspacePath);
    } else {
      await box.put(workspacePath, jsonEncode(kept.map(_encode).toList()));
    }
  }

  /// Deletes every persisted task for [workspacePath].
  Future<void> deleteAll(String workspacePath) async {
    if (workspacePath.isEmpty) return;
    final box = _box;
    if (box == null) return;
    await box.delete(workspacePath);
  }

  static Map<String, dynamic> _encode(TaskSnapshot snapshot) {
    return {
      'task': snapshot.task.toJson(),
      'toolCalls': snapshot.toolCalls.map((record) {
        final json = record.toJson();
        final full = json['resultFull'] as String?;
        if (full != null && full.length > maxResultFullChars) {
          json['resultFull'] =
              '${full.substring(0, maxResultFullChars)}\n…[trimmed for storage]';
        }
        return json;
      }).toList(),
      'checkpoints': snapshot.checkpoints
          .map((checkpoint) => checkpoint.toJson())
          .toList(),
    };
  }

  static TaskSnapshot _decode(Map<String, dynamic> json) {
    return TaskSnapshot(
      task: AgentTask.fromJson(
        (json['task'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      toolCalls:
          (json['toolCalls'] as List?)
              ?.whereType<Map>()
              .map(
                (entry) =>
                    ToolCallRecord.fromJson(entry.cast<String, dynamic>()),
              )
              .toList() ??
          const [],
      checkpoints:
          (json['checkpoints'] as List?)
              ?.whereType<Map>()
              .map(
                (entry) => Checkpoint.fromJson(entry.cast<String, dynamic>()),
              )
              .toList() ??
          const [],
    );
  }
}

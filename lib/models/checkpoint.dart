/// A checkpoint of one agent file change (Batch 2 — desain §5, D2).
///
/// Every write tool records a [Checkpoint] with the file content before
/// and after the change, so the change can be undone later — per step
/// or for the whole task — without touching files the user changed
/// manually afterwards (see [CheckpointStore]).
enum CheckpointKind {
  /// File content was written, edited, or created ([before] is null
  /// when the file did not exist yet).
  write,

  /// File was moved to the trash folder ([after] is null and
  /// [trashPath] points at the trashed copy).
  delete,
}

class Checkpoint {
  static int _sequence = 0;

  /// Unique id, generated when not given.
  final String id;

  /// Task that made the change.
  final String taskId;

  /// Todo step that was active when the change was made, or
  /// `'unplanned'` when the task had no active step.
  final String stepId;

  /// Workspace-relative path of the changed file.
  final String path;

  /// Content before the change. Null when the file did not exist yet
  /// (created by this change), or when the previous content was binary
  /// and only the trash copy can restore it (delete kind).
  final String? before;

  /// Content after the change. Null for deletes (the file is gone from
  /// its original location; see [trashPath]).
  final String? after;

  /// Workspace-relative path of the trashed copy, only for deletes.
  final String? trashPath;

  final CheckpointKind kind;
  final DateTime at;

  /// True once this checkpoint has been undone.
  bool undone;

  Checkpoint({
    String? id,
    required this.taskId,
    required this.stepId,
    required this.path,
    required this.before,
    required this.after,
    this.trashPath,
    required this.kind,
    DateTime? at,
    this.undone = false,
  }) : id = id ?? 'cp_${DateTime.now().millisecondsSinceEpoch}_${_sequence++}',
       at = at ?? DateTime.now();

  /// A delete moves the file away, so the "after" state is "no file".
  bool get isDelete => kind == CheckpointKind.delete;

  /// A write whose file did not exist before.
  bool get isCreate => kind == CheckpointKind.write && before == null;

  /// JSON form for [TaskStore] persistence (Batch 5 — desain D8).
  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'stepId': stepId,
    'path': path,
    'before': before,
    'after': after,
    'trashPath': trashPath,
    'kind': kind.name,
    'atMs': at.millisecondsSinceEpoch,
    'undone': undone,
  };

  factory Checkpoint.fromJson(Map<String, dynamic> json) {
    return Checkpoint(
      id: json['id'] as String?,
      taskId: json['taskId'] as String? ?? '',
      stepId: json['stepId'] as String? ?? 'unplanned',
      path: json['path'] as String? ?? '',
      before: json['before'] as String?,
      after: json['after'] as String?,
      trashPath: json['trashPath'] as String?,
      kind: CheckpointKind.values.firstWhere(
        (value) => value.name == json['kind'],
        orElse: () => CheckpointKind.write,
      ),
      at: json['atMs'] is num
          ? DateTime.fromMillisecondsSinceEpoch((json['atMs'] as num).toInt())
          : null,
      undone: json['undone'] as bool? ?? false,
    );
  }
}

/// One recorded tool call (Batch 5 — desain §5, D9).
///
/// Every workspace tool call the agent makes is recorded here: the
/// arguments that were sent, a one-line summary (what enters the
/// prompt / timeline), and the full result (kept in the [TaskStore]
/// only, never in the prompt). The timeline UI renders one card per
/// record; a todo step links to its records through
/// [TaskStep.toolCallIds].
enum ToolCallStatus {
  /// Still executing (live in the timeline).
  running,

  /// Finished without an error.
  ok,

  /// Finished with an error.
  error,

  /// Refused by the permission rules or declined by the user.
  denied,

  /// Cancelled while running (user pressed Stop).
  cancelled,
}

extension ToolCallStatusLabel on ToolCallStatus {
  String get label => switch (this) {
    ToolCallStatus.running => 'Berjalan',
    ToolCallStatus.ok => 'Selesai',
    ToolCallStatus.error => 'Gagal',
    ToolCallStatus.denied => 'Ditolak',
    ToolCallStatus.cancelled => 'Dibatalkan',
  };
}

class ToolCallRecord {
  final String id;
  final String taskId;

  /// Todo step the call belongs to (`'unplanned'` when the task had
  /// no active step). Used to show a step's calls in the TaskPanel.
  final String stepId;
  final String toolName;

  /// Decoded arguments map (or `{'raw': ...}` when the raw JSON did
  /// not parse to a map).
  final Map<String, dynamic> arguments;

  /// One-line summary — what the timeline shows and what enters the
  /// prompt on a later round.
  String resultSummary;

  /// Full result, only in the store (capped when persisted).
  String? resultFull;

  /// Backend that ran the call (`bundled` / `termux` / `none`). Tools
  /// that run inside the app report `bundled`.
  String backend;

  ToolCallStatus status;
  int durationMs;
  final DateTime at;

  ToolCallRecord({
    String? id,
    required this.taskId,
    required this.stepId,
    required this.toolName,
    Map<String, dynamic>? arguments,
    this.resultSummary = '',
    this.resultFull,
    this.backend = 'bundled',
    this.status = ToolCallStatus.running,
    this.durationMs = 0,
    DateTime? at,
  }) : id = id ?? 'tc_${DateTime.now().millisecondsSinceEpoch}',
       arguments = arguments ?? const {},
       at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'stepId': stepId,
    'toolName': toolName,
    'arguments': arguments,
    'resultSummary': resultSummary,
    'resultFull': resultFull,
    'backend': backend,
    'status': status.name,
    'durationMs': durationMs,
    'atMs': at.millisecondsSinceEpoch,
  };

  factory ToolCallRecord.fromJson(Map<String, dynamic> json) {
    return ToolCallRecord(
      id: json['id'] as String?,
      taskId: json['taskId'] as String? ?? '',
      stepId: json['stepId'] as String? ?? 'unplanned',
      toolName: json['toolName'] as String? ?? '',
      arguments:
          (json['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
      resultSummary: json['resultSummary'] as String? ?? '',
      resultFull: json['resultFull'] as String?,
      backend: json['backend'] as String? ?? 'bundled',
      status: ToolCallStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => ToolCallStatus.ok,
      ),
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      at: json['atMs'] is num
          ? DateTime.fromMillisecondsSinceEpoch((json['atMs'] as num).toInt())
          : null,
    );
  }
}

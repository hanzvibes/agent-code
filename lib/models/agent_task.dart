/// Agent task model (Batch 1 — desain §5, D1/D3).
///
/// One [AgentTask] is a single user request worked on by [AgentEngine]:
/// the model plans first (a todo list of [TaskStep]s), then works through
/// the steps one at a time until a stop condition is reached.
enum TaskStatus {
  /// Work is in progress.
  active,

  /// Stopped because the budget ran out or the network failed; resumable.
  paused,

  /// Finished (model called `finish_task` or answered without tool calls).
  done,

  /// Stopped by an unexpected failure.
  failed,

  /// Stopped because the agent needs the user (for example the same
  /// tool error repeated three times).
  needsHelp,

  /// Stopped by the user.
  cancelled,
}

enum TaskStepStatus { pending, active, done, failed, skipped }

/// How freely the agent may act. Full mode handling lands in Batch 4;
/// Batch 1 only carries the chosen mode on the task. Default is [agent].
enum AgentMode { plan, agent, auto }

extension AgentModeLabel on AgentMode {
  String get label => switch (this) {
    AgentMode.plan => 'Plan',
    AgentMode.agent => 'Agent',
    AgentMode.auto => 'Auto',
  };
}

class TaskStep {
  final String id;
  final String title;
  TaskStepStatus status;
  String? detail;

  /// Ids of the [ToolCallRecord]s made while this step was active
  /// (Batch 5 — desain §5). The TaskPanel expands a step to show
  /// these calls.
  final List<String> toolCallIds;

  TaskStep({
    required this.id,
    required this.title,
    this.status = TaskStepStatus.pending,
    this.detail,
    List<String>? toolCallIds,
  }) : toolCallIds = toolCallIds ?? <String>[];

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'status': status.name,
    'detail': detail,
    'toolCallIds': toolCallIds,
  };

  factory TaskStep.fromJson(Map<String, dynamic> json) {
    return TaskStep(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      status: TaskStepStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => TaskStepStatus.pending,
      ),
      detail: json['detail'] as String?,
      toolCallIds:
          (json['toolCallIds'] as List?)?.whereType<String>().toList() ??
          const [],
    );
  }
}

class AgentTask {
  /// Default budget (desain D1/D7, keputusan Rehan 2026-11-16).
  static const int defaultMaxRounds = 25;
  static const int defaultMaxToolCalls = 60;

  /// Fraction of the budget at which the UI warns the user (D7).
  static const double budgetWarningFraction = 0.8;

  final String id;
  final String title;
  final AgentMode mode;
  TaskStatus status;
  final List<TaskStep> todos;
  final int maxRounds;
  final int maxToolCalls;
  int roundsUsed;
  int toolCallsUsed;

  /// Short result summary (from `finish_task`, or the last compaction).
  String? summary;
  final DateTime createdAt;
  DateTime updatedAt;

  AgentTask({
    String? id,
    required this.title,
    this.mode = AgentMode.agent,
    this.status = TaskStatus.active,
    List<TaskStep>? todos,
    this.maxRounds = defaultMaxRounds,
    this.maxToolCalls = defaultMaxToolCalls,
    this.roundsUsed = 0,
    this.toolCallsUsed = 0,
    this.summary,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? 'task_${DateTime.now().millisecondsSinceEpoch}',
       todos = todos ?? <TaskStep>[],
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// How much of the budget is used, as the larger of the two fractions.
  double get budgetFraction {
    final rounds = maxRounds <= 0 ? 0.0 : roundsUsed / maxRounds;
    final calls = maxToolCalls <= 0 ? 0.0 : toolCallsUsed / maxToolCalls;
    return rounds > calls ? rounds : calls;
  }

  bool get budgetWarningReached => budgetFraction >= budgetWarningFraction;

  int get totalTodoCount => todos.length;

  int get doneTodoCount =>
      todos.where((step) => step.status == TaskStepStatus.done).length;

  /// Replaces the todo list with a fresh plan from the model.
  void replaceTodos(List<TaskStep> steps) {
    todos
      ..clear()
      ..addAll(steps);
    touch();
  }

  /// Marks every still-open step as skipped (used when the task ends
  /// before the plan is fully done).
  void skipOpenTodos() {
    for (final step in todos) {
      if (step.status == TaskStepStatus.pending ||
          step.status == TaskStepStatus.active) {
        step.status = TaskStepStatus.skipped;
      }
    }
    touch();
  }

  void touch() {
    updatedAt = DateTime.now();
  }

  /// JSON form for [TaskStore] persistence (Batch 5 — desain D8).
  /// Round/tool budgets are saved so a resumed task continues from
  /// the round it stopped at instead of restarting.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'mode': mode.name,
    'status': status.name,
    'todos': todos.map((step) => step.toJson()).toList(),
    'maxRounds': maxRounds,
    'maxToolCalls': maxToolCalls,
    'roundsUsed': roundsUsed,
    'toolCallsUsed': toolCallsUsed,
    'summary': summary,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
    'updatedAtMs': updatedAt.millisecondsSinceEpoch,
  };

  factory AgentTask.fromJson(Map<String, dynamic> json) {
    return AgentTask(
      id: json['id'] as String?,
      title: json['title'] as String? ?? '',
      mode: AgentMode.values.firstWhere(
        (value) => value.name == json['mode'],
        orElse: () => AgentMode.agent,
      ),
      status: TaskStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => TaskStatus.paused,
      ),
      todos:
          (json['todos'] as List?)
              ?.whereType<Map>()
              .map((entry) => TaskStep.fromJson(entry.cast<String, dynamic>()))
              .toList() ??
          const [],
      maxRounds: (json['maxRounds'] as num?)?.toInt() ?? defaultMaxRounds,
      maxToolCalls:
          (json['maxToolCalls'] as num?)?.toInt() ?? defaultMaxToolCalls,
      roundsUsed: (json['roundsUsed'] as num?)?.toInt() ?? 0,
      toolCallsUsed: (json['toolCallsUsed'] as num?)?.toInt() ?? 0,
      summary: json['summary'] as String?,
      createdAt: json['createdAtMs'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['createdAtMs'] as num).toInt(),
            )
          : null,
      updatedAt: json['updatedAtMs'] is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['updatedAtMs'] as num).toInt(),
            )
          : null,
    );
  }
}

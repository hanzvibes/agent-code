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

  TaskStep({
    required this.id,
    required this.title,
    this.status = TaskStepStatus.pending,
    this.detail,
  });
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
}

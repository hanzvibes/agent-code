import 'dart:convert';

import '../models/agent_task.dart';
import '../models/provider_profile.dart';
import 'llm_service.dart';
import 'workspace_tool_service.dart';

/// Why an agent run stopped (desain D1).
enum AgentStopReason {
  /// Model answered without tool calls, or called `finish_task`.
  finished,

  /// The user pressed Stop.
  cancelled,

  /// The same tool error happened three times in a row.
  repeatedError,

  /// The round or tool-call budget ran out.
  budgetExhausted,

  /// Gateway network/timeout failure even after retries.
  networkPaused,

  /// Any other failure.
  failed,
}

class AgentRunResult {
  final AgentTask task;
  final AgentStopReason stopReason;

  /// Final answer text (or the `finish_task` summary). Empty when the
  /// run stopped before producing an answer.
  final String finalText;

  /// User-facing explanation for non-finished stops.
  final String? detail;

  const AgentRunResult({
    required this.task,
    required this.stopReason,
    this.finalText = '',
    this.detail,
  });
}

/// The agent loop (desain D1, D3, D7): runs an [AgentTask] until one of
/// the stop conditions is met.
///
/// The engine owns the LLM round loop only. It does not know about the
/// workspace or the UI: workspace tools run through the injected
/// [executeTool] callback, and progress is reported through callbacks so
/// the controller can update the UI.
class AgentEngine {
  static const String finishTaskToolName = 'finish_task';
  static const String updateTodoToolName = 'update_todo';

  /// Same error this many times in a row stops the task (D1).
  static const int maxSameErrors = 3;

  /// Network/timeout retries before the task pauses (D1).
  static const int maxNetworkRetries = 2;

  /// Tool results longer than this are summarised before entering the
  /// prompt (D1: error lines + last lines, never the raw head).
  static const int maxToolOutputChars = 4000;
  static const int toolOutputTailLines = 30;

  /// Tools the engine itself answers; they never reach [executeTool].
  static const List<Map<String, dynamic>> agentToolDefinitions = [
    {
      'type': 'function',
      'function': {
        'name': 'finish_task',
        'description':
            'Ends the task with a short summary of what was done and the outcome. Call this when the user request is complete, or when it cannot be completed and you have explained why.',
        'parameters': {
          'type': 'object',
          'properties': {
            'summary': {
              'type': 'string',
              'description': 'Short summary of the work done and the result.',
            },
          },
          'required': ['summary'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'update_todo',
        'description':
            'Replaces the task todo list with the current plan. Call this first with the plan, then again whenever a step finishes or the plan changes. Statuses: pending, active, done, failed, skipped.',
        'parameters': {
          'type': 'object',
          'properties': {
            'steps': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'title': {'type': 'string'},
                  'status': {
                    'type': 'string',
                    'enum': ['pending', 'active', 'done', 'failed', 'skipped'],
                  },
                },
                'required': ['title'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['steps'],
          'additionalProperties': false,
        },
      },
    },
  ];

  final LlmService _llmService;
  final Future<ToolExecutionResult> Function(ToolCallInfo call) _executeTool;
  final Future<void> Function(Duration duration) _delay;

  bool _stopRequested = false;

  AgentEngine({
    required LlmService llmService,
    required Future<ToolExecutionResult> Function(ToolCallInfo call)
    executeTool,
    Future<void> Function(Duration duration)? delay,
  }) : _llmService = llmService,
       _executeTool = executeTool,
       _delay = delay ?? Future.delayed;

  /// Asks the loop to stop at the next check. The in-flight LLM request
  /// is cancelled through [cancelToken]; this flag covers the gaps
  /// between requests and tool executions.
  void requestStop() {
    _stopRequested = true;
  }

  Future<AgentRunResult> run({
    required AgentTask task,
    required ProviderProfile profile,
    required String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required CancelToken cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,
    void Function(String status)? onStatus,
    void Function(ToolCallInfo call)? onToolStarted,
    void Function(ToolExecutionResult result)? onToolFinished,
    void Function(AgentTask task)? onTaskChanged,
    void Function(double usedFraction)? onBudgetWarning,
  }) async {
    _stopRequested = false;
    final transientMessages = List<Map<String, dynamic>>.from(messages);
    final activeTools = tools == null || tools.isEmpty ? null : tools;
    var budgetWarned = false;
    var lastErrorSignature = '';
    var lastErrorCount = 0;

    void checkBudgetWarning() {
      if (!budgetWarned && task.budgetWarningReached) {
        budgetWarned = true;
        onBudgetWarning?.call(task.budgetFraction);
      }
    }

    AgentRunResult cancelled() {
      task.status = TaskStatus.cancelled;
      task.touch();
      onTaskChanged?.call(task);
      return AgentRunResult(task: task, stopReason: AgentStopReason.cancelled);
    }

    while (true) {
      if (_stopRequested || cancelToken.isCancelled) return cancelled();

      if (task.roundsUsed >= task.maxRounds ||
          task.toolCallsUsed >= task.maxToolCalls) {
        task.status = TaskStatus.paused;
        task.touch();
        onTaskChanged?.call(task);
        return AgentRunResult(
          task: task,
          stopReason: AgentStopReason.budgetExhausted,
          detail:
              'Task budget reached (${task.roundsUsed}/${task.maxRounds} rounds, '
              '${task.toolCallsUsed}/${task.maxToolCalls} tool calls).',
        );
      }

      task.roundsUsed++;
      task.touch();
      onTaskChanged?.call(task);
      checkBudgetWarning();
      onStatus?.call('Working… round ${task.roundsUsed}/${task.maxRounds}');

      late final LlmStreamResponse response;
      try {
        response = await _streamWithRetry(
          profile: profile,
          apiKey: apiKey,
          messages: transientMessages,
          tools: activeTools,
          cancelToken: cancelToken,
          temperature: temperature,
          maxTokens: maxTokens,
          onDelta: onDelta,
        );
      } on LlmServiceException catch (error) {
        if (_stopRequested || cancelToken.isCancelled) return cancelled();
        if (_isRetryable(error)) {
          task.status = TaskStatus.paused;
          task.touch();
          onTaskChanged?.call(task);
          return AgentRunResult(
            task: task,
            stopReason: AgentStopReason.networkPaused,
            detail:
                'Could not reach ${profile.name} after $maxNetworkRetries retries. '
                'The task is paused and can be continued.',
          );
        }
        task.status = TaskStatus.failed;
        task.touch();
        onTaskChanged?.call(task);
        return AgentRunResult(
          task: task,
          stopReason: AgentStopReason.failed,
          detail: error.message,
        );
      } catch (error) {
        if (_stopRequested || cancelToken.isCancelled) return cancelled();
        task.status = TaskStatus.failed;
        task.touch();
        onTaskChanged?.call(task);
        return AgentRunResult(
          task: task,
          stopReason: AgentStopReason.failed,
          detail: error.toString(),
        );
      }

      if (_stopRequested || cancelToken.isCancelled) return cancelled();

      if (!response.hasToolCalls || activeTools == null) {
        task.status = TaskStatus.done;
        task.touch();
        onTaskChanged?.call(task);
        return AgentRunResult(
          task: task,
          stopReason: AgentStopReason.finished,
          finalText: response.text,
        );
      }

      transientMessages.add({
        'role': 'assistant',
        'content': response.text,
        'tool_calls': response.toolCalls
            .map((call) => call.toApiMap())
            .toList(),
      });

      for (final call in response.toolCalls) {
        if (_stopRequested || cancelToken.isCancelled) return cancelled();

        if (call.name == finishTaskToolName) {
          final summary = _parseFinishSummary(call.arguments);
          task.summary = summary;
          task.skipOpenTodos();
          task.status = TaskStatus.done;
          task.touch();
          onTaskChanged?.call(task);
          return AgentRunResult(
            task: task,
            stopReason: AgentStopReason.finished,
            finalText: summary,
          );
        }

        if (call.name == updateTodoToolName) {
          final steps = _parseTodoSteps(call.arguments);
          if (steps != null) {
            task.replaceTodos(steps);
            onTaskChanged?.call(task);
          }
          transientMessages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'name': call.name,
            'content': jsonEncode({'ok': true, 'steps': task.totalTodoCount}),
          });
          continue;
        }

        if (task.toolCallsUsed >= task.maxToolCalls) {
          transientMessages.add({
            'role': 'tool',
            'tool_call_id': call.id,
            'name': call.name,
            'content': jsonEncode({
              'error':
                  'Exceeded maximum allowed tool calls (${task.maxToolCalls}) per task.',
            }),
          });
          continue;
        }

        task.toolCallsUsed++;
        onTaskChanged?.call(task);
        checkBudgetWarning();
        onToolStarted?.call(call);

        final result = await _executeTool(call);
        onToolFinished?.call(result);

        if (result.isError) {
          final signature = '${result.toolName}:${result.output}';
          if (signature == lastErrorSignature) {
            lastErrorCount++;
          } else {
            lastErrorSignature = signature;
            lastErrorCount = 1;
          }
          if (lastErrorCount >= maxSameErrors) {
            task.status = TaskStatus.needsHelp;
            task.touch();
            onTaskChanged?.call(task);
            return AgentRunResult(
              task: task,
              stopReason: AgentStopReason.repeatedError,
              detail:
                  'The same error happened $maxSameErrors times running ${result.toolName}. The task needs your help.',
            );
          }
        } else {
          lastErrorSignature = '';
          lastErrorCount = 0;
        }

        transientMessages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'name': call.name,
          'content': summarizeToolOutput(result.output),
        });

        if (_stopRequested || cancelToken.isCancelled) return cancelled();
      }
      // Next round with the tool outputs.
    }
  }

  Future<LlmStreamResponse> _streamWithRetry({
    required ProviderProfile profile,
    required String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    required CancelToken cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await _llmService.streamRequest(
          profile: profile,
          apiKey: apiKey,
          messages: messages,
          tools: tools,
          cancelToken: cancelToken,
          temperature: temperature,
          maxTokens: maxTokens,
          onDelta: onDelta,
        );
      } on LlmServiceException catch (error) {
        if (cancelToken.isCancelled || _stopRequested) rethrow;
        if (!_isRetryable(error) || attempt >= maxNetworkRetries) rethrow;
        attempt++;
        await _delay(Duration(seconds: attempt));
      }
    }
  }

  static bool _isRetryable(LlmServiceException error) {
    final message = error.message.toLowerCase();
    return message.contains('timed out') || message.contains('network error');
  }

  static String _parseFinishSummary(String rawArguments) {
    try {
      final parsed = jsonDecode(rawArguments);
      if (parsed is Map && parsed['summary'] is String) {
        final summary = (parsed['summary'] as String).trim();
        if (summary.isNotEmpty) return summary;
      }
    } catch (_) {}
    return 'Task finished.';
  }

  static List<TaskStep>? _parseTodoSteps(String rawArguments) {
    try {
      final parsed = jsonDecode(rawArguments);
      if (parsed is! Map || parsed['steps'] is! List) return null;
      final steps = <TaskStep>[];
      final stamp = DateTime.now().millisecondsSinceEpoch;
      var index = 0;
      for (final entry in parsed['steps'] as List) {
        if (entry is! Map || entry['title'] is! String) continue;
        final title = (entry['title'] as String).trim();
        if (title.isEmpty) continue;
        steps.add(
          TaskStep(
            id: 'todo_${stamp}_$index',
            title: title,
            status: _parseStepStatus(entry['status']),
          ),
        );
        index++;
      }
      return steps;
    } catch (_) {
      return null;
    }
  }

  static TaskStepStatus _parseStepStatus(Object? raw) {
    if (raw is! String) return TaskStepStatus.pending;
    return switch (raw.toLowerCase()) {
      'active' => TaskStepStatus.active,
      'done' => TaskStepStatus.done,
      'failed' => TaskStepStatus.failed,
      'skipped' => TaskStepStatus.skipped,
      _ => TaskStepStatus.pending,
    };
  }

  /// Smart-trim of a tool result before it enters the prompt (D1):
  /// short outputs pass through unchanged; long ones keep the error
  /// lines plus the last [toolOutputTailLines] lines instead of the
  /// first 16 KB.
  static String summarizeToolOutput(String output) {
    if (output.length <= maxToolOutputChars) return output;
    final lines = output.split('\n');
    final errorPattern = RegExp(
      r'error|fail|exception|traceback',
      caseSensitive: false,
    );
    final errorLines = lines
        .where((line) => errorPattern.hasMatch(line))
        .take(20)
        .toList();
    final tail = lines.length > toolOutputTailLines
        ? lines.sublist(lines.length - toolOutputTailLines)
        : lines;
    final buffer = StringBuffer()
      ..writeln(
        '[Output trimmed from ${output.length} characters: showing error lines and the last $toolOutputTailLines lines.]',
      );
    if (errorLines.isNotEmpty) {
      buffer.writeln('--- Error lines ---');
      for (final line in errorLines) {
        buffer.writeln(line);
      }
    }
    buffer.writeln('--- Last $toolOutputTailLines lines ---');
    for (final line in tail) {
      buffer.writeln(line);
    }
    return buffer.toString();
  }
}

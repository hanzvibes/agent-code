import 'dart:convert';

import '../models/agent_task.dart';
import '../models/provider_profile.dart';
import 'llm_service.dart';
import 'project_detector.dart';
import 'project_verifier.dart';
import 'tool_registry.dart';
import 'workspace_tool_service.dart';

/// Why an agent run stopped (desain D1).
enum AgentStopReason {
  /// Model answered without tool calls, or called `finish_task`.
  finished,

  /// The user pressed Stop.
  cancelled,

  /// The same tool error happened three times in a row.
  repeatedError,

  /// Verification stayed red after the maximum verify attempts.
  verificationFailed,

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

  /// Verify attempts before the task stops with needs-help (Batch 3
  /// — desain D4: max 3 percobaan per langkah). Counted per task, at
  /// the finish gate (see [_verificationGate]).
  static const int maxVerifyAttempts = 3;

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

  /// Runs the standard verify commands before the task may finish
  /// (Batch 3 — desain D4). Null means no verification (the caller —
  /// usually the controller — wires the real verifier). Test-only
  /// runs pass a verifier backed by a fake runtime.
  final ProjectVerifier? _verifier;

  bool _stopRequested = false;

  /// Verify attempts used by the current run (reset per [run]).
  int _verifyAttempts = 0;

  AgentEngine({
    required LlmService llmService,
    required Future<ToolExecutionResult> Function(ToolCallInfo call)
    executeTool,
    Future<void> Function(Duration duration)? delay,
    ProjectVerifier? verifier,
  }) : _llmService = llmService,
       _executeTool = executeTool,
       _delay = delay ?? Future.delayed,
       _verifier = verifier;

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
    /// Workspace root for the verify gate (Batch 3 — desain D4).
    /// Null/empty means no verification runs.
    String? workspaceRoot,
  }) async {
    _stopRequested = false;
    _verifyAttempts = 0;
    final transientMessages = List<Map<String, dynamic>>.from(messages);
    final activeTools = tools == null || tools.isEmpty ? null : tools;
    var budgetWarned = false;
    var lastErrorSignature = '';
    var lastErrorCount = 0;
    // Workspace-relative paths the agent changed this run (from
    // successful write-tool results). The verify gate only runs when
    // this is non-empty.
    final changedFiles = <String>{};

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

    taskLoop:
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
        // The model is done — but the verify gate runs first when
        // the task changed files (Batch 3 — desain D4).
        final gate = await _verificationGate(
          task: task,
          workspaceRoot: workspaceRoot,
          changedFiles: changedFiles,
          onStatus: onStatus,
          onTaskChanged: onTaskChanged,
        );
        if (gate.stopResult != null) return gate.stopResult!;
        if (!gate.shouldFinish) {
          transientMessages.add({
            'role': 'user',
            'content':
                'Verification failed (attempt $_verifyAttempts/$maxVerifyAttempts):\n${gate.errorSummary}\nFix the errors above, then answer again when the checks pass.',
          });
          continue taskLoop;
        }
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
          // The model says it is done — the verify gate runs first
          // when the task changed files (Batch 3 — desain D4). A red
          // verify sends the error back as this call's tool result
          // so the model can fix it and finish again.
          final gate = await _verificationGate(
            task: task,
            workspaceRoot: workspaceRoot,
            changedFiles: changedFiles,
            onStatus: onStatus,
            onTaskChanged: onTaskChanged,
          );
          if (gate.stopResult != null) return gate.stopResult!;
          if (!gate.shouldFinish) {
            transientMessages.add({
              'role': 'tool',
              'tool_call_id': call.id,
              'name': call.name,
              'content': jsonEncode({
                'verification': 'failed',
                'attempt': '$_verifyAttempts/$maxVerifyAttempts',
                'error': gate.errorSummary,
                'hint':
                    'Fix the errors above, then call finish_task again when the checks pass.',
              }),
            });
            continue taskLoop;
          }
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

        if (ToolRegistry.isWriteTool(call.name) && !result.isError) {
          final changed = _changedPathFrom(result.output);
          if (changed != null) changedFiles.add(changed);
        }

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

  /// Verify gate (Batch 3 — desain D4): before the task may finish,
  /// run the standard verify commands for the detected project kind.
  ///
  /// Returns `shouldFinish: true` when the task may finish (no
  /// verifier, no workspace, no files changed, or verify green /
  /// skipped for this kind). On a red verify, counts the attempt:
  /// - attempts left: `shouldFinish: false` with the trimmed error
  ///   summary — the caller feeds it back to the model so it can fix
  ///   the code and finish again;
  /// - attempts exhausted ([maxVerifyAttempts]): marks the task
  ///   `needsHelp` and returns the stop result.
  ///
  /// Verify never runs for the wrong kind: the kind comes from
  /// [ProjectDetector.detect] on the workspace (not a model guess),
  /// and kinds without commands (Flutter/Android, generic) skip.
  Future<
    ({
      bool shouldFinish,
      AgentRunResult? stopResult,
      String? errorSummary,
    })
  >
  _verificationGate({
    required AgentTask task,
    required String? workspaceRoot,
    required Set<String> changedFiles,
    void Function(String status)? onStatus,
    void Function(AgentTask task)? onTaskChanged,
  }) async {
    const proceed = (
      shouldFinish: true,
      stopResult: null,
      errorSummary: null,
    );
    final verifier = _verifier;
    final root = workspaceRoot;
    if (verifier == null ||
        root == null ||
        root.isEmpty ||
        changedFiles.isEmpty) {
      return proceed;
    }
    final info = await ProjectDetector.detect(root);
    onStatus?.call('Verifying (${info.type.label})…');
    final outcome = await verifier.verify(
      workspaceRoot: root,
      projectType: info.type,
      changedFiles: changedFiles.toList(),
    );
    if (outcome.passed) return proceed;
    _verifyAttempts++;
    final summary = summarizeToolOutput(outcome.errorOutput);
    if (_verifyAttempts >= maxVerifyAttempts) {
      task.status = TaskStatus.needsHelp;
      task.touch();
      onTaskChanged?.call(task);
      return (
        shouldFinish: false,
        stopResult: AgentRunResult(
          task: task,
          stopReason: AgentStopReason.verificationFailed,
          detail:
              'Verification failed $maxVerifyAttempts times (${info.type.label} project) and the task needs your help. Last error:\n$summary',
        ),
        errorSummary: null,
      );
    }
    onStatus?.call(
      'Verification failed — fixing… (attempt $_verifyAttempts/$maxVerifyAttempts)',
    );
    return (
      shouldFinish: false,
      stopResult: null,
      errorSummary: summary,
    );
  }

  /// Workspace-relative path from a successful write-tool result
  /// (`{"ok": true, "path": ...}`), or null when the output is not
  /// a write result.
  static String? _changedPathFrom(String output) {
    try {
      final parsed = jsonDecode(output);
      if (parsed is Map && parsed['path'] is String) {
        return parsed['path'] as String;
      }
    } catch (_) {}
    return null;
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

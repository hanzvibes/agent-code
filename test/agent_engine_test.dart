import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/services/agent_engine.dart';
import 'package:code_harness/services/llm_service.dart';
import 'package:code_harness/services/workspace_tool_service.dart';

final _profile = ProviderProfile(
  id: 'p1',
  name: 'Test Gateway',
  baseUrl: 'https://example.com/v1',
  modelId: 'test-model',
);

ToolCallInfo _toolCall(String id, String name, [String arguments = '{}']) =>
    ToolCallInfo(id: id, name: name, arguments: arguments);

ToolExecutionResult _okResult(
  ToolCallInfo call, [
  String output = '{"ok": true}',
]) => ToolExecutionResult(
  callId: call.id,
  toolName: call.name,
  output: output,
  summary: 'ok',
);

ToolExecutionResult _errorResult(
  ToolCallInfo call, [
  String output = '{"error": "boom"}',
]) => ToolExecutionResult(
  callId: call.id,
  toolName: call.name,
  output: output,
  summary: 'boom',
  isError: true,
);

/// Scripted LLM: each request pops the next scripted item (a response
/// to return or an exception to throw); defaults to a plain answer.
class ScriptedLlmService extends LlmService {
  final List<Object> script;
  int requestCount = 0;
  List<Map<String, dynamic>> lastMessages = [];
  List<Map<String, dynamic>>? lastTools;
  Completer<void>? gate;

  ScriptedLlmService(this.script);

  @override
  Future<LlmStreamResponse> streamRequest({
    required ProviderProfile profile,
    required String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,
    void Function(int index, String id, String name)? onToolCallName,
  }) async {
    requestCount++;
    lastMessages = List.from(messages);
    lastTools = tools == null ? null : List.from(tools);
    if (gate != null) await gate!.future;
    if (script.isEmpty) {
      onDelta?.call('default answer');
      return const LlmStreamResponse(text: 'default answer');
    }
    final next = script.removeAt(0);
    if (next is Exception) throw next;
    final response = next as LlmStreamResponse;
    if (response.text.isNotEmpty) onDelta?.call(response.text);
    return response;
  }
}

AgentEngine _engine({
  required ScriptedLlmService llm,
  Future<ToolExecutionResult> Function(ToolCallInfo call)? executeTool,
}) => AgentEngine(
  llmService: llm,
  executeTool: executeTool ?? (call) async => _okResult(call),
  // No real waiting for retry backoff in tests.
  delay: (_) async {},
);

Future<AgentRunResult> _run(
  AgentEngine engine,
  AgentTask task,
  ScriptedLlmService llm, {
  List<Map<String, dynamic>>? tools,
  CancelToken? cancelToken,
  void Function(double usedFraction)? onBudgetWarning,
}) => engine.run(
  task: task,
  profile: _profile,
  apiKey: 'key',
  messages: [
    {'role': 'user', 'content': 'Do the thing'},
  ],
  tools: tools,
  cancelToken: cancelToken ?? CancelToken(),
  onBudgetWarning: onBudgetWarning,
);

final _workspaceTools = [
  {
    'type': 'function',
    'function': {'name': 'list_project_files'},
  },
];

void main() {
  group('AgentEngine stop conditions', () {
    test('finishes when the model answers without tool calls', () async {
      final llm = ScriptedLlmService([
        const LlmStreamResponse(text: 'All done.'),
      ]);
      final task = AgentTask(title: 't');
      final result = await _run(_engine(llm: llm), task, llm);

      expect(result.stopReason, AgentStopReason.finished);
      expect(result.finalText, 'All done.');
      expect(task.status, TaskStatus.done);
      expect(task.roundsUsed, 1);
      expect(llm.requestCount, 1);
    });

    test('finishes when the model calls finish_task', () async {
      var executed = 0;
      final llm = ScriptedLlmService([
        LlmStreamResponse(
          toolCalls: [
            _toolCall(
              'c1',
              'finish_task',
              jsonEncode({'summary': 'Added the tests.'}),
            ),
          ],
        ),
      ]);
      final task = AgentTask(
        title: 't',
        todos: [
          TaskStep(id: 's1', title: 'step', status: TaskStepStatus.active),
        ],
      );
      final result = await _run(
        _engine(
          llm: llm,
          executeTool: (call) async {
            executed++;
            return _okResult(call);
          },
        ),
        task,
        llm,
        tools: [..._workspaceTools, ...AgentEngine.agentToolDefinitions],
      );

      expect(result.stopReason, AgentStopReason.finished);
      expect(result.finalText, 'Added the tests.');
      expect(task.status, TaskStatus.done);
      expect(task.summary, 'Added the tests.');
      // finish_task is engine-owned: never sent to the workspace executor.
      expect(executed, 0);
      // Open todos are skipped when the task ends early.
      expect(task.todos.first.status, TaskStepStatus.skipped);
    });

    test('stops after the same tool error three times', () async {
      var executed = 0;
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c2', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c3', 'list_project_files')]),
        // Must never be reached.
        const LlmStreamResponse(text: 'should not happen'),
      ]);
      final task = AgentTask(title: 't');
      final result = await _run(
        _engine(
          llm: llm,
          executeTool: (call) async {
            executed++;
            return _errorResult(call);
          },
        ),
        task,
        llm,
        tools: _workspaceTools,
      );

      expect(result.stopReason, AgentStopReason.repeatedError);
      expect(task.status, TaskStatus.needsHelp);
      expect(result.detail, contains('needs your help'));
      expect(executed, 3);
      expect(llm.requestCount, 3);
    });

    test('different errors do not trip the repeat guard', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c2', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c3', 'list_project_files')]),
        const LlmStreamResponse(text: 'Recovered.'),
      ]);
      final errors = [
        '{"error": "first"}',
        '{"error": "second"}',
        '{"error": "third"}',
      ];
      var index = 0;
      final task = AgentTask(title: 't');
      final result = await _run(
        _engine(
          llm: llm,
          executeTool: (call) async => _errorResult(call, errors[index++]),
        ),
        task,
        llm,
        tools: _workspaceTools,
      );

      expect(result.stopReason, AgentStopReason.finished);
      expect(task.status, TaskStatus.done);
      expect(llm.requestCount, 4);
    });

    test('stops when the round budget runs out', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c2', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c3', 'list_project_files')]),
      ]);
      final task = AgentTask(title: 't', maxRounds: 2);
      final result = await _run(
        _engine(llm: llm),
        task,
        llm,
        tools: _workspaceTools,
      );

      expect(result.stopReason, AgentStopReason.budgetExhausted);
      expect(task.status, TaskStatus.paused);
      expect(task.roundsUsed, 2);
      expect(llm.requestCount, 2);
    });

    test('stops when the tool-call budget runs out', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(
          toolCalls: [
            _toolCall('c1', 'list_project_files'),
            _toolCall('c2', 'list_project_files'),
            _toolCall('c3', 'list_project_files'),
          ],
        ),
        const LlmStreamResponse(text: 'should not happen'),
      ]);
      final task = AgentTask(title: 't', maxToolCalls: 2);
      final result = await _run(
        _engine(llm: llm),
        task,
        llm,
        tools: _workspaceTools,
      );

      expect(result.stopReason, AgentStopReason.budgetExhausted);
      expect(task.status, TaskStatus.paused);
      expect(task.toolCallsUsed, 2);
      expect(llm.requestCount, 1);
    });
  });

  group('AgentEngine cancellation', () {
    test('requestStop cancels a run stuck in the LLM request', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
      ]);
      llm.gate = Completer<void>();
      var executed = 0;
      final engine = _engine(
        llm: llm,
        executeTool: (call) async {
          executed++;
          return _okResult(call);
        },
      );
      final task = AgentTask(title: 't');
      final pending = _run(engine, task, llm, tools: _workspaceTools);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      engine.requestStop();
      llm.gate!.complete();
      final result = await pending;

      expect(result.stopReason, AgentStopReason.cancelled);
      expect(task.status, TaskStatus.cancelled);
      expect(executed, 0);
    });

    test('cancelled CancelToken stops the run after the response', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
      ]);
      final token = CancelToken()..cancel();
      final task = AgentTask(title: 't');
      final result = await _run(
        _engine(llm: llm),
        task,
        llm,
        tools: _workspaceTools,
        cancelToken: token,
      );

      expect(result.stopReason, AgentStopReason.cancelled);
      expect(task.status, TaskStatus.cancelled);
      expect(llm.requestCount, 0);
    });
  });

  group('AgentEngine network retries', () {
    test('retries network errors twice, then pauses the task', () async {
      final llm = ScriptedLlmService([
        const LlmServiceException('Network error from Test Gateway: boom'),
        const LlmServiceException('Network error from Test Gateway: boom'),
        const LlmServiceException('Network error from Test Gateway: boom'),
      ]);
      final task = AgentTask(title: 't');
      final result = await _run(_engine(llm: llm), task, llm);

      expect(llm.requestCount, 3);
      expect(result.stopReason, AgentStopReason.networkPaused);
      expect(task.status, TaskStatus.paused);
      expect(result.detail, contains('paused'));
    });

    test('recovers when a retry succeeds', () async {
      final llm = ScriptedLlmService([
        const LlmServiceException('Request to Test Gateway timed out.'),
        const LlmStreamResponse(text: 'Recovered after retry.'),
      ]);
      final task = AgentTask(title: 't');
      final result = await _run(_engine(llm: llm), task, llm);

      expect(llm.requestCount, 2);
      expect(result.stopReason, AgentStopReason.finished);
      expect(result.finalText, 'Recovered after retry.');
      expect(task.status, TaskStatus.done);
    });

    test('non-network errors fail immediately without retry', () async {
      final llm = ScriptedLlmService([
        const LlmServiceException('Request to Test Gateway failed (HTTP 401).'),
      ]);
      final task = AgentTask(title: 't');
      final result = await _run(_engine(llm: llm), task, llm);

      expect(llm.requestCount, 1);
      expect(result.stopReason, AgentStopReason.failed);
      expect(task.status, TaskStatus.failed);
      expect(result.detail, contains('401'));
    });
  });

  group('AgentEngine todos and budget warning', () {
    test('update_todo replaces the todo list and tracks progress', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(
          toolCalls: [
            _toolCall(
              'c1',
              'update_todo',
              jsonEncode({
                'steps': [
                  {'title': 'Read the file', 'status': 'done'},
                  {'title': 'Edit the file', 'status': 'active'},
                  {'title': 'Verify', 'status': 'pending'},
                ],
              }),
            ),
          ],
        ),
        const LlmStreamResponse(text: 'Working on it.'),
      ]);
      final task = AgentTask(title: 't');
      final seen = <int>[];
      final engine = _engine(llm: llm);
      final result = await engine.run(
        task: task,
        profile: _profile,
        apiKey: 'key',
        messages: [
          {'role': 'user', 'content': 'Do the thing'},
        ],
        tools: [..._workspaceTools, ...AgentEngine.agentToolDefinitions],
        cancelToken: CancelToken(),
        onTaskChanged: (changed) => seen.add(changed.doneTodoCount),
      );

      expect(result.stopReason, AgentStopReason.finished);
      expect(task.totalTodoCount, 3);
      expect(task.doneTodoCount, 1);
      expect(task.todos[1].status, TaskStepStatus.active);
      expect(seen, contains(1));
    });

    test('warns when 80 percent of the budget is used', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c2', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c3', 'list_project_files')]),
        LlmStreamResponse(toolCalls: [_toolCall('c4', 'list_project_files')]),
        const LlmStreamResponse(text: 'Done.'),
      ]);
      final task = AgentTask(title: 't', maxRounds: 5);
      final warnings = <double>[];
      final result = await _run(
        _engine(llm: llm),
        task,
        llm,
        tools: _workspaceTools,
        onBudgetWarning: warnings.add,
      );

      expect(result.stopReason, AgentStopReason.finished);
      expect(warnings, [0.8]);
      expect(task.budgetWarningReached, isTrue);
    });
  });

  group('AgentEngine.summarizeToolOutput', () {
    test('short output passes through unchanged', () {
      const output = 'line one\nline two';
      expect(AgentEngine.summarizeToolOutput(output), output);
    });

    test('long output keeps error lines and the last 30 lines', () {
      final lines = List<String>.generate(
        200,
        (i) => i == 5
            ? 'Error: something broke early'
            : 'filler line $i with padding text to grow the output size',
      );
      final output = lines.join('\n');
      expect(output.length, greaterThan(AgentEngine.maxToolOutputChars));
      final summary = AgentEngine.summarizeToolOutput(output);

      expect(summary.length, lessThan(output.length));
      expect(summary, contains('Error: something broke early'));
      expect(summary, contains('filler line 199'));
      expect(summary, contains('filler line 170'));
      expect(summary, isNot(contains('filler line 100')));
      expect(summary, contains('trimmed from'));
    });

    test('summarised output is what the next LLM request sees', () async {
      final lines = List<String>.generate(
        200,
        (i) => i == 5
            ? 'Error: boom'
            : 'filler line $i with padding text to grow the output size',
      );
      final longOutput = lines.join('\n');
      final llm = ScriptedLlmService([
        LlmStreamResponse(toolCalls: [_toolCall('c1', 'list_project_files')]),
        const LlmStreamResponse(text: 'Done.'),
      ]);
      final task = AgentTask(title: 't');
      await _run(
        _engine(
          llm: llm,
          executeTool: (call) async => _okResult(call, longOutput),
        ),
        task,
        llm,
        tools: _workspaceTools,
      );

      final toolMessage = llm.lastMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      final content = toolMessage['content'] as String;
      expect(content.length, lessThan(longOutput.length));
      expect(content, contains('Error: boom'));
      expect(content, contains('filler line 199'));
    });
  });

  group('AgentEngine tool-call history (HTTP 400 fallback)', () {
    test('follow-up request carries a spec-shaped tool exchange', () async {
      final llm = ScriptedLlmService([
        LlmStreamResponse(
          toolCalls: [_toolCall('call_9', 'list_project_files')],
        ),
        const LlmStreamResponse(text: 'Done.'),
      ]);
      final task = AgentTask(title: 't');
      final result = await _run(
        _engine(llm: llm),
        task,
        llm,
        tools: _workspaceTools,
      );

      expect(result.stopReason, AgentStopReason.finished);
      expect(llm.requestCount, 2);
      final assistantMessage = llm.lastMessages.firstWhere(
        (m) => m['role'] == 'assistant',
      );
      final toolCalls = assistantMessage['tool_calls'] as List;
      expect(toolCalls.single['id'], 'call_9');
      expect(toolCalls.single['type'], 'function');
      final toolMessage = llm.lastMessages.firstWhere(
        (m) => m['role'] == 'tool',
      );
      expect(toolMessage['tool_call_id'], 'call_9');
      // Tool messages carry only role + tool_call_id + content (the
      // OpenAI shape): an extra `name` field is rejected by strict
      // gateways with HTTP 400.
      expect(toolMessage.containsKey('name'), isFalse);
    });

    test(
      'falls back to diff-only when the provider rejects a follow-up after a tool call',
      () async {
        final llm = ScriptedLlmService([
          LlmStreamResponse(
            toolCalls: [_toolCall('call_9', 'list_project_files')],
          ),
          const LlmServiceException(
            'Request to Test Gateway failed (HTTP 400).',
          ),
          const LlmStreamResponse(text: 'Here is the diff.'),
        ]);
        final task = AgentTask(title: 't');
        final result = await _run(
          _engine(llm: llm),
          task,
          llm,
          tools: _workspaceTools,
        );

        expect(result.stopReason, AgentStopReason.finished);
        expect(result.finalText, 'Here is the diff.');
        expect(result.diffOnlyFallback, isTrue);
        expect(task.status, TaskStatus.done);
        expect(llm.requestCount, 3);
        // The retry request carries no tools and no tool-call history.
        expect(llm.lastTools, isNull);
        expect(
          llm.lastMessages.any(
            (m) =>
                m['role'] == 'assistant' &&
                m['tool_calls'] is List &&
                (m['tool_calls'] as List).isNotEmpty,
          ),
          isFalse,
        );
        expect(
          llm.lastMessages.any(
            (m) =>
                m['role'] == 'user' &&
                (m['content'] as String).contains(
                  'rejected the request containing',
                ),
          ),
          isTrue,
        );
      },
    );

    test(
      'still fails the task when the first request is rejected with HTTP 400',
      () async {
        final llm = ScriptedLlmService([
          const LlmServiceException(
            'Request to Test Gateway failed (HTTP 400).',
          ),
        ]);
        final task = AgentTask(title: 't');
        final result = await _run(
          _engine(llm: llm),
          task,
          llm,
          tools: _workspaceTools,
        );

        expect(result.stopReason, AgentStopReason.failed);
        expect(result.diffOnlyFallback, isFalse);
        expect(result.detail, contains('HTTP 400'));
        expect(task.status, TaskStatus.failed);
        expect(llm.requestCount, 1);
      },
    );
  });
}

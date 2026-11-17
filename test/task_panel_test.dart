import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/core/theme.dart';
import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/tool_call_record.dart';
import 'package:code_harness/views/assistant/task_panel.dart';

Future<void> _pumpPanel(
  WidgetTester tester,
  AgentTask task, {
  bool isRunning = true,
  VoidCallback? onStop,
  int changeCount = 0,
  VoidCallback? onViewChanges,
  AgentMode? mode,
  ValueChanged<AgentMode>? onModeChanged,
  List<ToolCallRecord> toolCalls = const [],
  VoidCallback? onResume,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(isDark: false),
      home: Scaffold(
        body: TaskPanel(
          task: task,
          isRunning: isRunning,
          onStop: onStop ?? () {},
          changeCount: changeCount,
          onViewChanges: onViewChanges,
          mode: mode,
          onModeChanged: onModeChanged,
          toolCalls: toolCalls,
          onResume: onResume,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows title, mode and todo progress', (tester) async {
    final task = AgentTask(
      title: 'Add the login screen',
      mode: AgentMode.agent,
      todos: [
        TaskStep(id: 's1', title: 'one', status: TaskStepStatus.done),
        TaskStep(id: 's2', title: 'two', status: TaskStepStatus.active),
        TaskStep(id: 's3', title: 'three'),
      ],
      roundsUsed: 2,
      toolCallsUsed: 5,
    );

    await _pumpPanel(tester, task);

    expect(find.text('Add the login screen'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('1/3 langkah'), findsOneWidget);
    // The budget line (rounds/tools) moved to TerminalStatusLine
    // above the prompt — see test/chat_terminal_test.dart.
    expect(find.text('Ronde 2/25 • Tool 5/60'), findsNothing);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('Stop button calls onStop', (tester) async {
    var stopped = false;
    final task = AgentTask(title: 'Long task');

    await _pumpPanel(tester, task, onStop: () => stopped = true);
    await tester.tap(find.text('Stop'));
    await tester.pump();

    expect(stopped, isTrue);
  });

  testWidgets('finished task hides Stop and shows the status', (tester) async {
    final task = AgentTask(
      title: 'Done task',
      status: TaskStatus.done,
      todos: [TaskStep(id: 's1', title: 'one', status: TaskStepStatus.done)],
      roundsUsed: 1,
    );

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.text('Stop'), findsNothing);
    expect(find.text('Selesai'), findsOneWidget);
    expect(find.text('1/1 langkah'), findsOneWidget);
  });

  // The 80% budget warning moved with the budget line to
  // TerminalStatusLine — see test/chat_terminal_test.dart.
  testWidgets('paused task shows the resumable status', (tester) async {
    final task = AgentTask(title: 'Paused task', status: TaskStatus.paused);

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.text('Dijeda — bisa dilanjutkan'), findsOneWidget);
  });

  testWidgets('shows changes button when the task recorded changes', (
    tester,
  ) async {
    var opened = false;
    final task = AgentTask(title: 'Task with changes');

    await _pumpPanel(
      tester,
      task,
      isRunning: false,
      changeCount: 2,
      onViewChanges: () => opened = true,
    );

    expect(find.text('2 changes'), findsOneWidget);
    await tester.tap(find.text('2 changes'));
    await tester.pump();
    expect(opened, isTrue);
  });

  testWidgets('hides changes button when there are no changes', (tester) async {
    final task = AgentTask(title: 'Plain task');

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.textContaining('change'), findsNothing);
  });

  testWidgets('mode switcher shows all modes and reports the pick', (
    tester,
  ) async {
    AgentMode? picked;
    final task = AgentTask(title: 'Task with switcher', mode: AgentMode.agent);

    await _pumpPanel(
      tester,
      task,
      isRunning: false,
      onModeChanged: (mode) => picked = mode,
    );

    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    await tester.tap(find.text('Auto'));
    await tester.pump();

    expect(picked, AgentMode.auto);
  });

  testWidgets('mode switcher shows the live mode, not the task mode', (
    tester,
  ) async {
    final task = AgentTask(
      title: 'Task started in Agent',
      mode: AgentMode.agent,
    );

    await _pumpPanel(
      tester,
      task,
      isRunning: false,
      mode: AgentMode.plan,
      onModeChanged: (_) {},
    );

    // The Plan hint is shown; the tag is replaced by the switcher.
    expect(find.textContaining('Plan — hanya baca'), findsOneWidget);
  });

  testWidgets('without a switcher the mode is shown as a tag', (tester) async {
    final task = AgentTask(
      title: 'Task without switcher',
      mode: AgentMode.auto,
    );

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Plan'), findsNothing);
  });

  testWidgets('paused task shows Lanjutkan and calls onResume', (tester) async {
    var resumed = false;
    final task = AgentTask(title: 'Paused task', status: TaskStatus.paused);

    await _pumpPanel(
      tester,
      task,
      isRunning: false,
      onResume: () => resumed = true,
    );

    expect(find.text('Lanjutkan'), findsOneWidget);
    await tester.tap(find.text('Lanjutkan'));
    await tester.pump();
    expect(resumed, isTrue);
  });

  testWidgets('running or finished tasks hide Lanjutkan', (tester) async {
    final running = AgentTask(title: 'Running task');
    await _pumpPanel(tester, running, isRunning: true, onResume: () {});
    expect(find.text('Lanjutkan'), findsNothing);

    final done = AgentTask(title: 'Done task', status: TaskStatus.done);
    await _pumpPanel(tester, done, isRunning: false, onResume: () {});
    expect(find.text('Lanjutkan'), findsNothing);
  });

  testWidgets('todo step expands to show its linked tool calls', (
    tester,
  ) async {
    final step = TaskStep(
      id: 's1',
      title: 'Read the file',
      status: TaskStepStatus.done,
      toolCallIds: ['tc_1'],
    );
    final task = AgentTask(
      title: 'Task with steps',
      todos: [step],
      status: TaskStatus.paused,
    );
    final calls = [
      ToolCallRecord(
        id: 'tc_1',
        taskId: task.id,
        stepId: 's1',
        toolName: 'read_project_file',
        arguments: {'path': 'lib/main.dart'},
        resultSummary: 'Read 12 lines',
        status: ToolCallStatus.ok,
      ),
    ];

    await _pumpPanel(tester, task, isRunning: false, toolCalls: calls);

    expect(find.text('Read the file'), findsOneWidget);
    expect(find.text('1 call'), findsOneWidget);
    expect(find.textContaining('read_project_file'), findsNothing);

    await tester.tap(find.text('Read the file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('read_project_file'), findsOneWidget);
    expect(find.textContaining('Selesai'), findsOneWidget);
  });

  testWidgets('todo step without calls has no expand affordance', (
    tester,
  ) async {
    final task = AgentTask(
      title: 'Task with plain steps',
      todos: [TaskStep(id: 's1', title: 'Plan only')],
      status: TaskStatus.paused,
    );

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.text('Plan only'), findsOneWidget);
    expect(find.textContaining('call'), findsNothing);
  });
}

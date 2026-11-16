import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/core/theme.dart';
import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/views/assistant/task_panel.dart';

Future<void> _pumpPanel(
  WidgetTester tester,
  AgentTask task, {
  bool isRunning = true,
  VoidCallback? onStop,
  int changeCount = 0,
  VoidCallback? onViewChanges,
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
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows title, mode, todo progress and budget', (tester) async {
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
    expect(find.text('Ronde 2/25 • Tool 5/60'), findsOneWidget);
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

  testWidgets('warns when the budget is 80 percent used', (tester) async {
    final task = AgentTask(
      title: 'Almost out of budget',
      roundsUsed: 20,
      toolCallsUsed: 10,
    );

    await _pumpPanel(tester, task);

    expect(find.text('Anggaran hampir habis'), findsOneWidget);
  });

  testWidgets('paused task shows the resumable status', (tester) async {
    final task = AgentTask(title: 'Paused task', status: TaskStatus.paused);

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.text('Dijeda — bisa dilanjutkan'), findsOneWidget);
  });

  testWidgets('shows changes button when the task recorded changes',
      (tester) async {
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

  testWidgets('hides changes button when there are no changes',
      (tester) async {
    final task = AgentTask(title: 'Plain task');

    await _pumpPanel(tester, task, isRunning: false);

    expect(find.textContaining('change'), findsNothing);
  });
}

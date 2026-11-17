import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/core/contrast.dart';
import 'package:code_harness/core/theme.dart';
import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/tool_call_record.dart';
import 'package:code_harness/views/assistant/activity_timeline.dart';
import 'package:code_harness/views/assistant/task_panel.dart';
import 'package:code_harness/views/assistant/terminal.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(theme: buildTheme(isDark: false), home: Scaffold(body: child)),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TerminalTokens contrast (>= 4.5:1 on the terminal background)', () {
    test('every foreground colour is readable on the terminal bg', () {
      final tokens = {
        'text': TerminalTokens.text,
        'muted': TerminalTokens.muted,
        'faint': TerminalTokens.faint,
        'accent': TerminalTokens.accent,
        'green': TerminalTokens.green,
        'red': TerminalTokens.red,
        'orange': TerminalTokens.orange,
      };
      for (final entry in tokens.entries) {
        final ratio = ContrastUtils.contrastRatio(
          entry.value,
          TerminalTokens.bg,
        );
        expect(
          ratio >= 4.5,
          isTrue,
          reason:
              'Terminal token "${entry.key}" (${entry.value}) has ratio $ratio < 4.5:1 against the terminal background',
        );
      }
    });
  });

  group('TerminalStatusLine', () {
    testWidgets('shows the profile and the task budget', (tester) async {
      final task = AgentTask(
        title: 'Install Remotion',
        roundsUsed: 2,
        toolCallsUsed: 3,
      );
      await _pump(
        tester,
        const TerminalStatusLine(profileName: 'Smart', task: null),
      );
      // Swap in the task: the line must show both parts.
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(isDark: false),
          home: Scaffold(
            body: TerminalStatusLine(profileName: 'Smart', task: task),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Smart'), findsOneWidget);
      expect(find.textContaining('Ronde 2/25 • Tool 3/60'), findsOneWidget);
      expect(find.text('Anggaran hampir habis'), findsNothing);
    });

    testWidgets('warns when the budget is 80 percent used', (tester) async {
      final task = AgentTask(
        title: 'Almost out of budget',
        roundsUsed: 20,
        toolCallsUsed: 10,
      );
      await _pump(
        tester,
        TerminalStatusLine(profileName: 'Smart', task: task),
      );

      expect(find.text('Anggaran hampir habis'), findsOneWidget);
    });

    testWidgets('shows No provider when there is no profile', (
      tester,
    ) async {
      await _pump(tester, const TerminalStatusLine());

      expect(find.textContaining('No provider'), findsOneWidget);
      expect(find.textContaining('Ronde'), findsNothing);
    });
  });

  group('TerminalPromptBar', () {
    testWidgets('shows a coral > prompt and sends on tap', (tester) async {
      var sent = false;
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await _pump(
        tester,
        TerminalPromptBar(
          controller: controller,
          isLoading: false,
          isRestoringSession: false,
          onSend: () => sent = true,
          onCancel: () {},
        ),
      );

      expect(find.text('>'), findsOneWidget);
      final prompt = tester.widget<Text>(find.text('>'));
      expect(prompt.style?.color, TerminalTokens.accent);
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();
      expect(sent, isTrue);
    });

    testWidgets('loading shows Stop and cancels on tap', (tester) async {
      var cancelled = false;
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await _pump(
        tester,
        TerminalPromptBar(
          controller: controller,
          isLoading: true,
          isRestoringSession: false,
          onSend: () {},
          onCancel: () => cancelled = true,
        ),
      );

      expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
      await tester.tap(find.byIcon(Icons.stop_rounded));
      await tester.pump();
      expect(cancelled, isTrue);
    });

    testWidgets('send is disabled while the session restores', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await _pump(
        tester,
        TerminalPromptBar(
          controller: controller,
          isLoading: false,
          isRestoringSession: true,
          onSend: () {},
          onCancel: () {},
        ),
      );

      final send = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.arrow_upward_rounded),
          matching: find.byType(IconButton),
        ),
      );
      expect(send.onPressed, isNull);
    });
  });

  group('Terminal tool row (ActivityTimeline)', () {
    ToolCallRecord record({
      ToolCallStatus status = ToolCallStatus.ok,
      String? full,
    }) {
      return ToolCallRecord(
        id: 'tc_1',
        taskId: 'task_1',
        stepId: 's1',
        toolName: 'list_project_files',
        arguments: {'path': 'lib/main.dart'},
        resultSummary: 'Listed 4 workspace files',
        resultFull: full,
        backend: 'bundled',
        status: status,
        durationMs: 18,
      );
    }

    testWidgets('running shows Berjalan, no Activity header', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(isDark: false),
          home: Scaffold(
            body: ActivityTimeline(
              records: [
                record(status: ToolCallStatus.running),
              ],
              isRunning: true,
            ),
          ),
        ),
      );
      // Plain pump, not pumpAndSettle: the running spinner animates.
      await tester.pump();

      expect(find.text('list_project_files'), findsOneWidget);
      expect(find.text('Berjalan'), findsOneWidget);
      expect(find.text('Activity'), findsNothing);
    });

    testWidgets('tapping expands output with the ⎿ prefix', (tester) async {
      await _pump(
        tester,
        ActivityTimeline(
          records: [record(full: 'line1\nline2')],
          isRunning: false,
        ),
      );

      expect(find.textContaining('line1'), findsNothing);

      await tester.tap(find.text('list_project_files'));
      await tester.pumpAndSettle();

      expect(find.text('Arguments'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
      expect(find.textContaining('⎿ line1'), findsOneWidget);
      expect(find.textContaining('⎿ line2'), findsOneWidget);
      expect(find.textContaining('18 ms'), findsOneWidget);
    });
  });

  group('TaskPanel terminal details', () {
    testWidgets('title is coral and a done step is struck through', (
      tester,
    ) async {
      final task = AgentTask(
        title: 'Add the login screen',
        mode: AgentMode.agent,
        todos: [
          TaskStep(id: 's1', title: 'one', status: TaskStepStatus.done),
          TaskStep(id: 's2', title: 'two', status: TaskStepStatus.active),
        ],
      );
      await _pump(
        tester,
        TaskPanel(task: task, isRunning: true, onStop: () {}),
      );

      expect(
        tester.widget<Text>(find.text('Add the login screen')).style?.color,
        TerminalTokens.accent,
      );
      expect(
        tester.widget<Text>(find.text('one')).style?.decoration,
        TextDecoration.lineThrough,
      );
      expect(
        tester.widget<Text>(find.text('two')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
    });

    testWidgets('the active mode label is coral', (tester) async {
      final task = AgentTask(title: 'Task with switcher', mode: AgentMode.agent);
      await _pump(
        tester,
        TaskPanel(
          task: task,
          isRunning: false,
          onStop: () {},
          onModeChanged: (_) {},
        ),
      );

      expect(
        tester.widget<Text>(find.text('Agent')).style?.color,
        TerminalTokens.accent,
      );
      expect(
        tester.widget<Text>(find.text('Plan')).style?.color,
        TerminalTokens.muted,
      );
    });
  });
}

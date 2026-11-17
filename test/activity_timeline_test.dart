import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/core/theme.dart';
import 'package:code_harness/models/tool_call_record.dart';
import 'package:code_harness/views/assistant/activity_timeline.dart';

Future<void> _pumpTimeline(
  WidgetTester tester,
  List<ToolCallRecord> records, {
  bool isRunning = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(isDark: false),
      home: Scaffold(
        body: ActivityTimeline(records: records, isRunning: isRunning),
      ),
    ),
  );
  // Plain pump, not pumpAndSettle: a running record shows a
  // CircularProgressIndicator that animates forever.
  await tester.pump();
}

ToolCallRecord _record({
  String id = 'tc_1',
  String toolName = 'read_project_file',
  ToolCallStatus status = ToolCallStatus.ok,
  String summary = 'Read 12 lines',
  String? full,
  Map<String, dynamic>? arguments,
}) {
  return ToolCallRecord(
    id: id,
    taskId: 'task_1',
    stepId: 's1',
    toolName: toolName,
    arguments: arguments ?? {'path': 'lib/main.dart'},
    resultSummary: summary,
    resultFull: full,
    backend: 'bundled',
    status: status,
    durationMs: 120,
  );
}

void main() {
  testWidgets('shows each tool call with its name, status and summary', (
    tester,
  ) async {
    await _pumpTimeline(tester, [
      _record(),
      _record(
        id: 'tc_2',
        toolName: 'write_file',
        status: ToolCallStatus.error,
        summary: 'Write failed: path is outside the project',
      ),
    ]);

    expect(find.text('read_project_file'), findsOneWidget);
    expect(find.text('write_file'), findsOneWidget);
    expect(find.text('Selesai'), findsOneWidget);
    expect(find.text('Gagal'), findsOneWidget);
    expect(find.text('Read 12 lines'), findsOneWidget);
    expect(
      find.text('Write failed: path is outside the project'),
      findsOneWidget,
    );
    // Terminal look: no "Activity" header and no call count.
    expect(find.text('Activity'), findsNothing);
  });

  testWidgets('shows a running call as Berjalan', (tester) async {
    await _pumpTimeline(tester, [
      _record(
        toolName: 'run_project_command',
        status: ToolCallStatus.running,
        summary: 'Running run_project_command…',
        arguments: {'command': 'npm test'},
      ),
    ], isRunning: true);

    expect(find.text('run_project_command'), findsOneWidget);
    expect(find.text('Berjalan'), findsOneWidget);
    // Terminal look: no "Activity" header and no call count.
    expect(find.text('Activity'), findsNothing);
  });

  testWidgets('denied and cancelled statuses have their own labels', (
    tester,
  ) async {
    await _pumpTimeline(tester, [
      _record(
        id: 'tc_1',
        toolName: 'run_project_command',
        status: ToolCallStatus.denied,
        summary: 'Declined by user',
      ),
      _record(
        id: 'tc_2',
        toolName: 'read_project_file',
        status: ToolCallStatus.cancelled,
        summary: 'Cancelled',
      ),
    ]);

    expect(find.text('Ditolak'), findsOneWidget);
    expect(find.text('Dibatalkan'), findsOneWidget);
  });

  testWidgets('tapping a card expands arguments and output', (tester) async {
    await _pumpTimeline(tester, [_record(full: 'line1\nline2\nline3')]);

    expect(find.textContaining('lib/main.dart'), findsNothing);
    expect(find.textContaining('line1'), findsNothing);

    await tester.tap(find.text('read_project_file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('lib/main.dart'), findsWidgets);
    expect(find.textContaining('line1'), findsOneWidget);
    expect(find.text('Arguments'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.textContaining('120 ms'), findsOneWidget);
  });

  testWidgets('long output is smart-trimmed when expanded', (tester) async {
    final longOutput = List.generate(500, (i) => 'output line $i').join('\n');
    await _pumpTimeline(tester, [_record(full: longOutput)]);

    await tester.tap(find.text('read_project_file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('[trimmed'), findsOneWidget);
    // Head and tail survive the trim.
    expect(find.textContaining('output line 0'), findsOneWidget);
    expect(find.textContaining('output line 499'), findsOneWidget);
  });

  testWidgets('renders nothing when there are no records', (tester) async {
    await _pumpTimeline(tester, []);
    expect(find.text('Activity'), findsNothing);
  });
}

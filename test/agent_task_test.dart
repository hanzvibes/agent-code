import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/models/agent_task.dart';

void main() {
  group('AgentTask defaults', () {
    test('defaults to Agent mode with the 25 round / 60 call budget', () {
      final task = AgentTask(title: 'Add tests');
      expect(task.mode, AgentMode.agent);
      expect(task.status, TaskStatus.active);
      expect(task.maxRounds, 25);
      expect(task.maxToolCalls, 60);
      expect(task.roundsUsed, 0);
      expect(task.toolCallsUsed, 0);
      expect(task.todos, isEmpty);
      expect(task.budgetFraction, 0.0);
      expect(task.budgetWarningReached, isFalse);
    });

    test('title and mode can be overridden', () {
      final task = AgentTask(title: 'Plan only', mode: AgentMode.plan);
      expect(task.mode, AgentMode.plan);
      expect(task.mode.label, 'Plan');
      expect(AgentMode.agent.label, 'Agent');
      expect(AgentMode.auto.label, 'Auto');
    });
  });

  group('AgentTask budget', () {
    test('budget fraction is the larger of rounds and tool calls', () {
      final task = AgentTask(title: 't', maxRounds: 10, maxToolCalls: 100);
      task.roundsUsed = 5;
      task.toolCallsUsed = 10;
      expect(task.budgetFraction, 0.5);
      task.toolCallsUsed = 90;
      expect(task.budgetFraction, 0.9);
    });

    test('budget warning triggers at 80 percent', () {
      final task = AgentTask(title: 't', maxRounds: 25, maxToolCalls: 60);
      task.roundsUsed = 19;
      expect(task.budgetWarningReached, isFalse);
      task.roundsUsed = 20;
      expect(task.budgetWarningReached, isTrue);
      task.roundsUsed = 0;
      task.toolCallsUsed = 48;
      expect(task.budgetWarningReached, isTrue);
    });
  });

  group('AgentTask todos', () {
    TaskStep step(
      String title, [
      TaskStepStatus status = TaskStepStatus.pending,
    ]) => TaskStep(id: title, title: title, status: status);

    test('counts done steps over total steps', () {
      final task = AgentTask(
        title: 't',
        todos: [
          step('one', TaskStepStatus.done),
          step('two', TaskStepStatus.active),
          step('three'),
        ],
      );
      expect(task.totalTodoCount, 3);
      expect(task.doneTodoCount, 1);
    });

    test('replaceTodos swaps the plan', () {
      final task = AgentTask(title: 't', todos: [step('old')]);
      task.replaceTodos([step('new one'), step('new two')]);
      expect(task.totalTodoCount, 2);
      expect(task.todos.first.title, 'new one');
    });

    test('skipOpenTodos leaves finished and failed steps alone', () {
      final task = AgentTask(
        title: 't',
        todos: [
          step('done', TaskStepStatus.done),
          step('failed', TaskStepStatus.failed),
          step('active', TaskStepStatus.active),
          step('pending'),
        ],
      );
      task.skipOpenTodos();
      expect(task.todos[0].status, TaskStepStatus.done);
      expect(task.todos[1].status, TaskStepStatus.failed);
      expect(task.todos[2].status, TaskStepStatus.skipped);
      expect(task.todos[3].status, TaskStepStatus.skipped);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:code_harness/utils/editor_history.dart';

void main() {
  late EditorHistory history;

  setUp(() {
    history = EditorHistory();
  });

  test('initial state has empty history and returns current', () {
    history.init('initial');
    expect(history.current, 'initial');
    expect(history.canUndo, isFalse);
    expect(history.canRedo, isFalse);
    expect(history.undo(), isNull);
    expect(history.redo(), isNull);
  });

  test('pushing identical text does not add duplicate history steps', () {
    history.init('v1');
    history.push('v1');
    expect(history.canUndo, isFalse);
    expect(history.current, 'v1');
  });

  test('push, undo, and redo workflow', () {
    history.init('v1');
    history.push('v2');
    history.push('v3');

    expect(history.current, 'v3');
    expect(history.canUndo, isTrue);
    expect(history.canRedo, isFalse);

    // Undo to v2
    expect(history.undo(), 'v2');
    expect(history.current, 'v2');
    expect(history.canUndo, isTrue);
    expect(history.canRedo, isTrue);

    // Undo to v1
    expect(history.undo(), 'v1');
    expect(history.current, 'v1');
    expect(history.canUndo, isFalse);
    expect(history.canRedo, isTrue);

    // Cannot undo past initial
    expect(history.undo(), isNull);

    // Redo to v2
    expect(history.redo(), 'v2');
    expect(history.current, 'v2');
    expect(history.canUndo, isTrue);
    expect(history.canRedo, isTrue);

    // Redo to v3
    expect(history.redo(), 'v3');
    expect(history.current, 'v3');
    expect(history.canUndo, isTrue);
    expect(history.canRedo, isFalse);

    // Cannot redo past latest
    expect(history.redo(), isNull);
  });

  test('push clears future redo stack', () {
    history.init('v1');
    history.push('v2');
    history.undo(); // back to v1, future contains v2
    expect(history.canRedo, isTrue);

    history.push('v3'); // diverged branch
    expect(history.current, 'v3');
    expect(history.canRedo, isFalse);
    expect(history.redo(), isNull);

    expect(history.undo(), 'v1');
  });

  test('bounds past stack to maxSteps (100)', () {
    history.init('step_0');
    for (int i = 1; i <= 120; i++) {
      history.push('step_$i');
    }

    expect(history.current, 'step_120');

    // Should be able to undo exactly 100 times
    int undoCount = 0;
    while (history.undo() != null) {
      undoCount++;
    }
    expect(undoCount, EditorHistory.maxSteps);
    // Earliest retained step after 120 pushes with cap 100 is step_20
    expect(history.current, 'step_20');
    expect(history.undo(), isNull);
  });
}

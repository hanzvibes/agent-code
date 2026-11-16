import 'package:flutter_test/flutter_test.dart';

import 'package:code_harness/utils/find_replace.dart';

void main() {
  group('FindReplace.findNext', () {
    test('returns null when query is empty or not found', () {
      expect(FindReplace.findNext('Hello world', '', 0), isNull);
      expect(FindReplace.findNext('Hello world', 'xyz', 0), isNull);
    });

    test('finds match case-insensitively with total match count', () {
      const text = 'Alpha beta ALPHA gamma alpha';
      final result = FindReplace.findNext(text, 'alpha', 0);
      expect(result, isNotNull);
      expect(result!.matchStart, 0);
      expect(result.matchEnd, 5);
      expect(result.totalMatches, 3);
    });

    test('advances to next match from offset', () {
      const text = 'Alpha beta ALPHA gamma alpha';
      final result = FindReplace.findNext(text, 'alpha', 6);
      expect(result, isNotNull);
      expect(result!.matchStart, 11);
      expect(result.matchEnd, 16);
      expect(result.totalMatches, 3);
    });

    test('wraps around to beginning when no matches past offset', () {
      const text = 'Alpha beta ALPHA gamma alpha';
      // Past the last match (which starts at 23)
      final result = FindReplace.findNext(text, 'alpha', 25);
      expect(result, isNotNull);
      expect(result!.matchStart, 0);
      expect(result.matchEnd, 5);
      expect(result.totalMatches, 3);
    });
  });

  group('FindReplace.replaceCurrent', () {
    test('returns null for empty query or invalid bounds', () {
      expect(
        FindReplace.replaceCurrent('Hello world', '', 'new', 0, 5),
        isNull,
      );
      expect(
        FindReplace.replaceCurrent('Hello world', 'world', 'earth', -1, 5),
        isNull,
      );
      expect(
        FindReplace.replaceCurrent('Hello world', 'world', 'earth', 6, 20),
        isNull,
      );
      expect(
        FindReplace.replaceCurrent('Hello world', 'world', 'earth', 5, 5),
        isNull,
      );
      expect(
        FindReplace.replaceCurrent('Hello world', 'world', 'earth', 7, 5),
        isNull,
      );
    });

    test(
      'replaces specified span and returns new text with updated matchEnd and count',
      () {
        const text = 'foo bar foo baz';
        // Replace first 'foo'
        final result = FindReplace.replaceCurrent(
          text,
          'foo',
          'QUX_LONG',
          0,
          3,
        );
        expect(result, isNotNull);
        expect(result!.text, 'QUX_LONG bar foo baz');
        expect(result.matchStart, 0);
        expect(result.matchEnd, 8); // 0 + 'QUX_LONG'.length
        expect(result.totalMatches, 1); // only 1 'foo' left
      },
    );
  });

  group('FindReplace.replaceAll', () {
    test('returns unchanged text when query is empty', () {
      const text = 'Hello world';
      final result = FindReplace.replaceAll(text, '', 'new');
      expect(result.text, text);
      expect(result.matchStart, -1);
      expect(result.matchEnd, -1);
      expect(result.totalMatches, 0);
    });

    test(
      'replaces all occurrences case-insensitively and escapes regex characters',
      () {
        const text = 'Item (test.val) and (TEST.VAL) end.';
        final result = FindReplace.replaceAll(text, '(test.val)', '[REPLACED]');
        expect(result.text, 'Item [REPLACED] and [REPLACED] end.');
        expect(result.matchStart, -1);
        expect(result.matchEnd, -1);
        expect(result.totalMatches, 0);
      },
    );
  });
}

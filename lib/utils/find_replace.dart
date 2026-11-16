class FindReplaceResult {
  final String text;
  final int matchStart;
  final int matchEnd;
  final int totalMatches;

  const FindReplaceResult({
    required this.text,
    required this.matchStart,
    required this.matchEnd,
    required this.totalMatches,
  });
}

class FindReplace {
  static RegExp _pattern(String query, {bool caseSensitive = false}) =>
      RegExp(RegExp.escape(query), caseSensitive: caseSensitive);

  static int countMatches(
    String text,
    String query, {
    bool caseSensitive = false,
  }) {
    if (query.isEmpty) return 0;
    return _pattern(
      query,
      caseSensitive: caseSensitive,
    ).allMatches(text).length;
  }

  static FindReplaceResult? findNext(
    String text,
    String query,
    int fromOffset, {
    bool caseSensitive = false,
  }) {
    if (query.isEmpty) return null;
    final matches = _pattern(
      query,
      caseSensitive: caseSensitive,
    ).allMatches(text);
    if (matches.isEmpty) return null;

    final safeOffset = fromOffset.clamp(0, text.length);
    RegExpMatch? selected;
    for (final match in matches) {
      if (match.start >= safeOffset) {
        selected = match;
        break;
      }
    }
    selected ??= matches.first;
    return FindReplaceResult(
      text: text,
      matchStart: selected.start,
      matchEnd: selected.end,
      totalMatches: matches.length,
    );
  }

  static FindReplaceResult? replaceCurrent(
    String text,
    String query,
    String replacement,
    int matchStart,
    int matchEnd, {
    bool caseSensitive = false,
  }) {
    if (query.isEmpty || matchStart < 0 || matchEnd > text.length) return null;
    final match = _pattern(
      query,
      caseSensitive: caseSensitive,
    ).allMatches(text).where((m) => m.start == matchStart && m.end == matchEnd);
    if (match.isEmpty) return null;

    final newText = text.replaceRange(matchStart, matchEnd, replacement);
    final newEnd = matchStart + replacement.length;
    return FindReplaceResult(
      text: newText,
      matchStart: matchStart,
      matchEnd: newEnd,
      totalMatches: countMatches(newText, query, caseSensitive: caseSensitive),
    );
  }

  static FindReplaceResult replaceAll(
    String text,
    String query,
    String replacement, {
    bool caseSensitive = false,
  }) {
    if (query.isEmpty) {
      return FindReplaceResult(
        text: text,
        matchStart: -1,
        matchEnd: -1,
        totalMatches: 0,
      );
    }
    final pattern = _pattern(query, caseSensitive: caseSensitive);
    final newText = text.replaceAllMapped(pattern, (_) => replacement);
    return FindReplaceResult(
      text: newText,
      matchStart: -1,
      matchEnd: -1,
      totalMatches: countMatches(newText, query, caseSensitive: caseSensitive),
    );
  }
}

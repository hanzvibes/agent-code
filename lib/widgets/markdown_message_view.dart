import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ui.dart';

sealed class _MarkdownBlock {}

class _CodeBlock extends _MarkdownBlock {
  final String language;
  final String code;
  _CodeBlock({required this.language, required this.code});
}

class _HeadingBlock extends _MarkdownBlock {
  final int level;
  final String text;
  _HeadingBlock({required this.level, required this.text});
}

class _ListItemBlock extends _MarkdownBlock {
  final bool isOrdered;
  final String indexText;
  final String text;
  _ListItemBlock({
    required this.isOrdered,
    required this.indexText,
    required this.text,
  });
}

class _ParagraphBlock extends _MarkdownBlock {
  final String text;
  _ParagraphBlock({required this.text});
}

class MarkdownMessageView extends StatelessWidget {
  final String content;
  final AppTokens t;

  const MarkdownMessageView({
    super.key,
    required this.content,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _renderBlock(context, blocks[i]),
        ],
      ],
    );
  }

  Widget _renderBlock(BuildContext context, _MarkdownBlock block) {
    return switch (block) {
      _CodeBlock b => _renderCodeBlock(context, b),
      _HeadingBlock b => _renderHeading(b),
      _ListItemBlock b => _renderListItem(b),
      _ParagraphBlock b => _renderParagraph(b),
    };
  }

  Widget _renderHeading(_HeadingBlock block) {
    final (double size, FontWeight weight) = switch (block.level) {
      1 => (18.0, FontWeight.w700),
      2 => (16.0, FontWeight.w600),
      _ => (15.0, FontWeight.w600),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        block.text,
        style: t.title.copyWith(fontSize: size, fontWeight: weight),
      ),
    );
  }

  Widget _renderListItem(_ListItemBlock block) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: block.isOrdered ? 24 : 16,
            child: Text(
              block.isOrdered ? block.indexText : '•',
              style: t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: t.accent,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: _parseInline(block.text)),
              style: t.body.copyWith(fontSize: 14, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _renderParagraph(_ParagraphBlock block) {
    return Text.rich(
      TextSpan(children: _parseInline(block.text)),
      style: t.body.copyWith(fontSize: 14, height: 1.4),
    );
  }

  Widget _renderCodeBlock(BuildContext context, _CodeBlock block) {
    final lang = block.language.isNotEmpty ? block.language : 'code';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF161618) : const Color(0xFFEBECEF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with language tag and explicit copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: t.fill,
              border: Border(bottom: BorderSide(color: t.hairline)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  lang,
                  style: t.small.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                Semantics(
                  label: 'Copy code block',
                  button: true,
                  child: IconButton(
                    tooltip: 'Copy code block',
                    icon: Icon(Icons.copy_rounded, size: 16, color: t.muted),
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    padding: const EdgeInsets.all(8),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: block.code));
                      showToast(
                        'Copied',
                        'Code block copied to clipboard',
                        tone: ToastTone.success,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // Code content
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              block.code,
              style: t.mono.copyWith(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  List<_MarkdownBlock> _parseBlocks(String input) {
    final blocks = <_MarkdownBlock>[];
    final lines = input.split('\n');
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();

      // Fenced code block (``` or ````)
      if (trimmed.startsWith('```')) {
        final fence = trimmed.startsWith('````') ? '````' : '```';
        final lang = trimmed.substring(fence.length).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length) {
          if (lines[i].trim().startsWith(fence)) {
            i++;
            break;
          }
          codeLines.add(lines[i]);
          i++;
        }
        blocks.add(_CodeBlock(language: lang, code: codeLines.join('\n')));
        continue;
      }

      // Headings
      if (trimmed.startsWith('#')) {
        var level = 0;
        while (level < trimmed.length && trimmed[level] == '#') {
          level++;
        }
        if (level > 0 &&
            level <= 3 &&
            level < trimmed.length &&
            trimmed[level] == ' ') {
          blocks.add(
            _HeadingBlock(
              level: level,
              text: trimmed.substring(level + 1).trim(),
            ),
          );
          i++;
          continue;
        }
      }

      // Ordered list (e.g. "1. ")
      final orderedMatch = RegExp(r'^(\d+[\.\)])\s+(.*)$').firstMatch(trimmed);
      if (orderedMatch != null) {
        blocks.add(
          _ListItemBlock(
            isOrdered: true,
            indexText: orderedMatch.group(1)!,
            text: orderedMatch.group(2)!,
          ),
        );
        i++;
        continue;
      }

      // Unordered list (e.g. "- " or "* ")
      if ((trimmed.startsWith('- ') || trimmed.startsWith('* ')) &&
          trimmed.length > 2) {
        blocks.add(
          _ListItemBlock(
            isOrdered: false,
            indexText: '•',
            text: trimmed.substring(2).trim(),
          ),
        );
        i++;
        continue;
      }

      // Empty line
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // Normal paragraph (group consecutive non-empty lines that aren't other blocks)
      final paraLines = <String>[line];
      i++;
      while (i < lines.length) {
        final nextTrim = lines[i].trim();
        if (nextTrim.isEmpty ||
            nextTrim.startsWith('```') ||
            nextTrim.startsWith('#') ||
            nextTrim.startsWith('- ') ||
            nextTrim.startsWith('* ') ||
            RegExp(r'^\d+[\.\)]\s+').hasMatch(nextTrim)) {
          break;
        }
        paraLines.add(lines[i]);
        i++;
      }
      blocks.add(_ParagraphBlock(text: paraLines.join('\n')));
    }

    return blocks;
  }

  List<InlineSpan> _parseInline(String text) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(`[^`]+`|\*\*[^\*]+\*\*|\*[^\*]+\*)');
    int lastEnd = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final matchedStr = match.group(0)!;
      if (matchedStr.startsWith('`') &&
          matchedStr.endsWith('`') &&
          matchedStr.length >= 2) {
        // Inline code
        final codeText = matchedStr.substring(1, matchedStr.length - 1);
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: t.fill,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: t.hairline),
              ),
              child: Text(
                codeText,
                style: t.mono.copyWith(fontSize: 12, color: t.accent),
              ),
            ),
          ),
        );
      } else if (matchedStr.startsWith('**') &&
          matchedStr.endsWith('**') &&
          matchedStr.length >= 4) {
        // Bold
        spans.add(
          TextSpan(
            text: matchedStr.substring(2, matchedStr.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (matchedStr.startsWith('*') &&
          matchedStr.endsWith('*') &&
          matchedStr.length >= 2) {
        // Italic
        spans.add(
          TextSpan(
            text: matchedStr.substring(1, matchedStr.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    return spans;
  }
}

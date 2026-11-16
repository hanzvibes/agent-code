import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Supported languages for syntax highlighting.
enum CodeLanguage {
  dart,
  kotlinJava,
  javascriptTypescript,
  python,
  jsonYaml,
  plainText,
}

/// Detects the language based on file extension.
CodeLanguage detectCodeLanguage(String? filePath) {
  if (filePath == null || filePath.isEmpty) return CodeLanguage.plainText;
  final ext = p.extension(filePath).toLowerCase();

  switch (ext) {
    case '.dart':
      return CodeLanguage.dart;
    case '.kt':
    case '.kts':
    case '.java':
      return CodeLanguage.kotlinJava;
    case '.js':
    case '.jsx':
    case '.ts':
    case '.tsx':
    case '.mjs':
    case '.cjs':
      return CodeLanguage.javascriptTypescript;
    case '.py':
    case '.pyw':
      return CodeLanguage.python;
    case '.json':
    case '.yaml':
    case '.yml':
      return CodeLanguage.jsonYaml;
    default:
      return CodeLanguage.plainText;
  }
}

/// Token types for syntax highlighting.
enum SyntaxTokenType { keyword, string, comment, number, identifier, plain }

/// High-contrast syntax color palette for light and dark themes.
/// All colors are measured against the respective background (white or black)
/// to ensure a contrast ratio of at least 4.5:1.
class SyntaxPalette {
  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;
  final Color identifier;
  final Color plain;

  const SyntaxPalette({
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.identifier,
    required this.plain,
  });

  /// Palette for light theme (background: #FFFFFF).
  /// Every color has WCAG contrast >= 4.5:1 against white:
  /// - keyword (#5B21B6): ~8.97:1
  /// - string (#166534): ~6.64:1
  /// - comment (#4B5563): ~7.56:1
  /// - number (#9A3412): ~6.95:1
  /// - identifier (#0369A1): ~6.00:1
  /// - plain (#0F0F10): ~20.0:1
  static const light = SyntaxPalette(
    keyword: Color(0xFF5B21B6),
    string: Color(0xFF166534),
    comment: Color(0xFF4B5563),
    number: Color(0xFF9A3412),
    identifier: Color(0xFF0369A1),
    plain: Color(0xFF0F0F10),
  );

  /// Palette for dark theme (background: #000000).
  /// Every color has WCAG contrast >= 4.5:1 against black:
  /// - keyword (#C084FC): ~7.98:1
  /// - string (#86EFAC): ~14.96:1
  /// - comment (#94A3B8): ~8.10:1
  /// - number (#FDBA74): ~12.68:1
  /// - identifier (#7DD3FC): ~13.20:1
  /// - plain (#F9FAFB): ~20.2:1
  static const dark = SyntaxPalette(
    keyword: Color(0xFFC084FC),
    string: Color(0xFF86EFAC),
    comment: Color(0xFF94A3B8),
    number: Color(0xFFFDBA74),
    identifier: Color(0xFF7DD3FC),
    plain: Color(0xFFF9FAFB),
  );

  static SyntaxPalette of(bool isDark) => isDark ? dark : light;

  Color colorFor(SyntaxTokenType type) {
    switch (type) {
      case SyntaxTokenType.keyword:
        return keyword;
      case SyntaxTokenType.string:
        return string;
      case SyntaxTokenType.comment:
        return comment;
      case SyntaxTokenType.number:
        return number;
      case SyntaxTokenType.identifier:
        return identifier;
      case SyntaxTokenType.plain:
        return plain;
    }
  }
}

/// Tokenizer and syntax highlighter with bounded rendering and caching.
class SyntaxHighlighter {
  static const int maxHighlightChars = 50000;

  static const Set<String> _dartKeywords = {
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'of',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'while',
    'with',
    'yield',
  };

  static const Set<String> _kotlinJavaKeywords = {
    'abstract',
    'actual',
    'annotation',
    'as',
    'assert',
    'break',
    'byte',
    'case',
    'catch',
    'char',
    'class',
    'companion',
    'const',
    'constructor',
    'continue',
    'data',
    'default',
    'do',
    'double',
    'else',
    'enum',
    'expect',
    'extends',
    'external',
    'false',
    'final',
    'finally',
    'float',
    'for',
    'fun',
    'goto',
    'if',
    'implements',
    'import',
    'in',
    'infix',
    'init',
    'inline',
    'instanceof',
    'int',
    'interface',
    'internal',
    'is',
    'lateinit',
    'long',
    'native',
    'new',
    'noinline',
    'null',
    'object',
    'open',
    'operator',
    'out',
    'override',
    'package',
    'private',
    'protected',
    'public',
    'reified',
    'return',
    'sealed',
    'short',
    'static',
    'strictfp',
    'super',
    'suspend',
    'switch',
    'synchronized',
    'tailrec',
    'this',
    'throw',
    'throws',
    'transient',
    'true',
    'try',
    'typealias',
    'val',
    'var',
    'vararg',
    'void',
    'volatile',
    'when',
    'while',
  };

  static const Set<String> _jsTsKeywords = {
    'abstract',
    'any',
    'as',
    'async',
    'await',
    'boolean',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'constructor',
    'continue',
    'debugger',
    'declare',
    'default',
    'delete',
    'do',
    'else',
    'enum',
    'export',
    'extends',
    'false',
    'finally',
    'for',
    'from',
    'function',
    'get',
    'if',
    'implements',
    'import',
    'in',
    'instanceof',
    'interface',
    'is',
    'keyof',
    'let',
    'module',
    'namespace',
    'never',
    'new',
    'null',
    'number',
    'of',
    'package',
    'private',
    'protected',
    'public',
    'readonly',
    'require',
    'return',
    'set',
    'static',
    'string',
    'super',
    'switch',
    'symbol',
    'this',
    'throw',
    'true',
    'try',
    'type',
    'typeof',
    'undefined',
    'unknown',
    'var',
    'void',
    'while',
    'with',
    'yield',
  };

  static const Set<String> _pythonKeywords = {
    'and',
    'as',
    'assert',
    'async',
    'await',
    'break',
    'class',
    'continue',
    'def',
    'del',
    'elif',
    'else',
    'except',
    'False',
    'finally',
    'for',
    'from',
    'global',
    'if',
    'import',
    'in',
    'is',
    'lambda',
    'None',
    'nonlocal',
    'not',
    'or',
    'pass',
    'raise',
    'return',
    'True',
    'try',
    'while',
    'with',
    'yield',
  };

  static const Set<String> _jsonYamlKeywords = {
    'true',
    'false',
    'null',
    'yes',
    'no',
    'on',
    'off',
  };

  static const Set<String> _commonBuiltinTypes = {
    'int',
    'double',
    'num',
    'bool',
    'String',
    'List',
    'Map',
    'Set',
    'Future',
    'Stream',
    'void',
    'dynamic',
    'Object',
    'Function',
    'boolean',
    'number',
    'string',
    'any',
    'Float',
    'Double',
    'Long',
    'Integer',
  };

  static Set<String> _keywordsFor(CodeLanguage lang) {
    switch (lang) {
      case CodeLanguage.dart:
        return _dartKeywords;
      case CodeLanguage.kotlinJava:
        return _kotlinJavaKeywords;
      case CodeLanguage.javascriptTypescript:
        return _jsTsKeywords;
      case CodeLanguage.python:
        return _pythonKeywords;
      case CodeLanguage.jsonYaml:
        return _jsonYamlKeywords;
      case CodeLanguage.plainText:
        return const {};
    }
  }

  // Regex patterns:
  // Comments: //..., /*...*/, #...
  // Strings: """...""", '''...''', "...", '...', `...`
  // Numbers: 0x..., digits
  // Words: identifiers/keywords
  // Annotations: @...
  static final RegExp _cStyleTokenRegex = RegExp(
    r'(//[^\n]*|/\*[\s\S]*?\*/)' // comments (group 1)
    r'|("""[\s\S]*?"""|'
    r"'''[\s\S]*?'''|"
    r'"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|`"
    r'(?:\\.|[^`\\])*`)' // strings (group 2)
    r'|(\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?\b)' // numbers (group 3)
    r'|(@[a-zA-Z_]\w*)' // annotations (group 4)
    r'|(\b[a-zA-Z_]\w*\b)', // words (group 5)
  );

  static final RegExp _pythonTokenRegex = RegExp(
    r'(#[^\n]*)' // comment (group 1)
    r'|("""[\s\S]*?"""|'
    r"'''[\s\S]*?'''|"
    r'"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*')" // strings (group 2)
    r'|(\b0x[0-9a-fA-F]+\b|\b\d+(?:\.\d+)?\b)' // numbers (group 3)
    r'|(@[a-zA-Z_]\w*)' // decorators (group 4)
    r'|(\b[a-zA-Z_]\w*\b)', // words (group 5)
  );

  static final RegExp _yamlJsonTokenRegex = RegExp(
    r'(#[^\n]*)' // comment (group 1)
    r'|("(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*')" // strings (group 2)
    r'|(\b\d+(?:\.\d+)?\b)' // numbers (group 3)
    r'|(\b[a-zA-Z_][a-zA-Z0-9_\-]*\b)', // words (group 4)
  );

  /// Highlights [text] for [language] and returns a list of [TextSpan]s.
  /// If [language] is plainText, returns a single uncolored TextSpan.
  /// If [text] exceeds [maxHighlightChars], the remainder is appended as plain text.
  static List<TextSpan> highlight({
    required String text,
    required CodeLanguage language,
    required bool isDark,
    TextStyle? defaultStyle,
  }) {
    if (text.isEmpty) {
      return [TextSpan(text: '', style: defaultStyle)];
    }

    if (language == CodeLanguage.plainText) {
      return [TextSpan(text: text, style: defaultStyle)];
    }

    final palette = SyntaxPalette.of(isDark);
    final keywords = _keywordsFor(language);

    // Bound parsing for large files
    final String highlightableText;
    final String? overflowText;
    if (text.length > maxHighlightChars) {
      highlightableText = text.substring(0, maxHighlightChars);
      overflowText = text.substring(maxHighlightChars);
    } else {
      highlightableText = text;
      overflowText = null;
    }

    final RegExp regex;
    switch (language) {
      case CodeLanguage.python:
        regex = _pythonTokenRegex;
        break;
      case CodeLanguage.jsonYaml:
        regex = _yamlJsonTokenRegex;
        break;
      default:
        regex = _cStyleTokenRegex;
        break;
    }

    final spans = <TextSpan>[];
    int lastEnd = 0;

    final matches = regex.allMatches(highlightableText);
    for (final match in matches) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: highlightableText.substring(lastEnd, match.start),
            style: defaultStyle,
          ),
        );
      }

      final matchedText = match.group(0)!;
      final SyntaxTokenType tokenType;

      if (match.group(1) != null) {
        tokenType = SyntaxTokenType.comment;
      } else if (match.group(2) != null) {
        tokenType = SyntaxTokenType.string;
      } else if (match.group(3) != null) {
        tokenType = SyntaxTokenType.number;
      } else if (language != CodeLanguage.jsonYaml &&
          match.group(4) != null &&
          match.group(4)!.startsWith('@')) {
        tokenType = SyntaxTokenType.identifier;
      } else {
        // Word token
        if (keywords.contains(matchedText)) {
          tokenType = SyntaxTokenType.keyword;
        } else if (_isIdentifierOrType(matchedText)) {
          tokenType = SyntaxTokenType.identifier;
        } else {
          tokenType = SyntaxTokenType.plain;
        }
      }

      if (tokenType == SyntaxTokenType.plain) {
        spans.add(TextSpan(text: matchedText, style: defaultStyle));
      } else {
        spans.add(
          TextSpan(
            text: matchedText,
            style: (defaultStyle ?? const TextStyle()).copyWith(
              color: palette.colorFor(tokenType),
              fontWeight: tokenType == SyntaxTokenType.keyword
                  ? FontWeight.w600
                  : null,
            ),
          ),
        );
      }

      lastEnd = match.end;
    }

    if (lastEnd < highlightableText.length) {
      spans.add(
        TextSpan(
          text: highlightableText.substring(lastEnd),
          style: defaultStyle,
        ),
      );
    }

    if (overflowText != null && overflowText.isNotEmpty) {
      spans.add(TextSpan(text: overflowText, style: defaultStyle));
    }

    return spans;
  }

  static bool _isIdentifierOrType(String word) {
    if (_commonBuiltinTypes.contains(word)) return true;
    // PascalCase / Types / Classes starting with uppercase letter
    if (word.isNotEmpty &&
        word.codeUnitAt(0) >= 65 &&
        word.codeUnitAt(0) <= 90) {
      return true;
    }
    return false;
  }
}

/// A specialized [TextEditingController] that highlights syntax in real time
/// using [buildTextSpan] without breaking text editing, IME composing,
/// selection, clipboard, or undo/redo.
class SyntaxTextEditingController extends TextEditingController {
  CodeLanguage _language;
  String _cachedText = '';
  bool _cachedIsDark = false;
  CodeLanguage _cachedLanguage = CodeLanguage.plainText;
  TextStyle? _cachedStyle;
  List<TextSpan>? _cachedSpans;

  SyntaxTextEditingController({
    super.text,
    CodeLanguage language = CodeLanguage.plainText,
  }) : _language = language;

  CodeLanguage get language => _language;
  set language(CodeLanguage value) {
    if (_language != value) {
      _language = value;
      _cachedSpans = null;
      notifyListeners();
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Cache check to avoid reparsing when only cursor or selection moves
    if (_cachedSpans != null &&
        _cachedText == text &&
        _cachedIsDark == isDark &&
        _cachedLanguage == _language &&
        _cachedStyle == style &&
        (!withComposing || !value.isComposingRangeValid)) {
      return TextSpan(style: style, children: _cachedSpans);
    }

    final spans = SyntaxHighlighter.highlight(
      text: text,
      language: _language,
      isDark: isDark,
      defaultStyle: style,
    );

    // If there is an active IME composing range, respect the underline decoration
    if (withComposing && value.isComposingRangeValid) {
      // Return spans with composing style handled
      final composingStyle = (style ?? const TextStyle()).merge(
        const TextStyle(decoration: TextDecoration.underline),
      );
      return TextSpan(
        style: style,
        children: [
          TextSpan(text: value.composing.textBefore(text)),
          TextSpan(
            style: composingStyle,
            text: value.composing.textInside(text),
          ),
          TextSpan(text: value.composing.textAfter(text)),
        ],
      );
    }

    _cachedText = text;
    _cachedIsDark = isDark;
    _cachedLanguage = _language;
    _cachedStyle = style;
    _cachedSpans = spans;

    return TextSpan(style: style, children: spans);
  }
}

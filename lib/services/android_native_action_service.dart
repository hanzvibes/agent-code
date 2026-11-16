import 'package:flutter/services.dart';

class AndroidActionRequest {
  final String action;
  final String title;
  final String description;
  final String preview;

  const AndroidActionRequest({
    required this.action,
    required this.title,
    required this.description,
    required this.preview,
  });
}

abstract interface class AndroidNativeActionAdapter {
  Future<void> openLink(String url);
  Future<void> shareText({required String title, required String text});
  Future<void> copyText(String text);
}

class AndroidNativeActionService implements AndroidNativeActionAdapter {
  static const MethodChannel _channel = MethodChannel(
    'dev.codeharness/android_actions',
  );
  static const int maxTextChars = 8000;
  static const int maxTitleChars = 100;

  @override
  Future<void> openLink(String url) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        !{'http', 'https'}.contains(parsed.scheme.toLowerCase()) ||
        parsed.host.isEmpty) {
      throw const FormatException(
        'Only valid http:// and https:// links can be opened.',
      );
    }
    await _channel.invokeMethod<void>('openAndroidLink', {
      'url': parsed.toString(),
    });
  }

  @override
  Future<void> shareText({required String title, required String text}) async {
    if (text.trim().isEmpty || text.length > maxTextChars) {
      throw const FormatException(
        'Shared text must contain 1–8,000 characters.',
      );
    }
    final safeTitle = title.trim().isEmpty ? 'Shared from Code Harness' : title;
    await _channel.invokeMethod<void>('shareAndroidText', {
      'title': safeTitle.substring(
        0,
        safeTitle.length.clamp(0, maxTitleChars).toInt(),
      ),
      'text': text,
    });
  }

  @override
  Future<void> copyText(String text) async {
    if (text.trim().isEmpty || text.length > maxTextChars) {
      throw const FormatException(
        'Copied text must contain 1–8,000 characters.',
      );
    }
    await _channel.invokeMethod<void>('copyAndroidText', {'text': text});
  }
}

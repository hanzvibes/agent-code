import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class TermuxRuntimeStatus {
  final bool installed;
  final bool permissionGranted;

  const TermuxRuntimeStatus({
    required this.installed,
    required this.permissionGranted,
  });

  bool get ready => installed && permissionGranted;
}

class TermuxCommandResult {
  final String stdout;
  final String stderr;
  final int exitCode;
  final String? error;
  final bool stdoutTruncated;
  final bool stderrTruncated;

  const TermuxCommandResult({
    this.stdout = '',
    this.stderr = '',
    required this.exitCode,
    this.error,
    this.stdoutTruncated = false,
    this.stderrTruncated = false,
  });

  Map<String, dynamic> toJson() => {
    'exit_code': exitCode,
    'stdout': stdout,
    'stderr': stderr,
    'stdout_truncated': stdoutTruncated,
    'stderr_truncated': stderrTruncated,
    if (error != null && error!.isNotEmpty) 'error': error,
  };
}

abstract interface class TermuxRuntimeAdapter {
  Future<TermuxRuntimeStatus> getStatus();
  Future<void> openTermux();
  Future<void> openAppPermissionSettings();
  Future<TermuxCommandResult> execute({
    required String command,
    required String workspaceRoot,
    required String workingDirectory,
    required int timeoutSeconds,
    void Function(String channel, String chunk)? onOutput,
  });
  Future<void> cancelActiveCommand();
}

class _PendingCommand {
  final StringBuffer stdout = StringBuffer();
  final StringBuffer stderr = StringBuffer();
  final void Function(String channel, String chunk)? onOutput;
  final Completer<TermuxCommandResult> completer =
      Completer<TermuxCommandResult>();
  bool stdoutTruncated = false;
  bool stderrTruncated = false;
  int? exitCode;
  String? error;

  _PendingCommand(this.onOutput);
}

/// Termux RUN_COMMAND bridge. The Android platform layer relays output on a
/// loopback socket while the process runs and reports the final Termux status.
class TermuxRuntimeService implements TermuxRuntimeAdapter {
  static const int maxCommandChars = 32000;
  static const int maxOutputCharsPerStream = 16000;
  static const int minTimeoutSeconds = 1;
  static const int maxTimeoutSeconds = 120;
  static const MethodChannel _methodChannel = MethodChannel(
    'dev.codeharness/termux',
  );
  static const EventChannel _eventChannel = EventChannel(
    'dev.codeharness/termux_events',
  );

  static StreamSubscription<dynamic>? _subscription;
  static final Map<String, _PendingCommand> _pending = {};
  static final Map<String, List<Map<String, dynamic>>> _earlyEvents = {};
  String? _activeRequestId;
  bool _cancelRequestedDuringStart = false;

  @override
  Future<TermuxRuntimeStatus> getStatus() async {
    final response = await _methodChannel.invokeMapMethod<String, dynamic>(
      'getTermuxStatus',
    );
    return TermuxRuntimeStatus(
      installed: response?['installed'] == true,
      permissionGranted: response?['permissionGranted'] == true,
    );
  }

  @override
  Future<void> openTermux() => _methodChannel.invokeMethod<void>('openTermux');

  @override
  Future<void> openAppPermissionSettings() =>
      _methodChannel.invokeMethod<void>('openAppPermissionSettings');

  @override
  Future<TermuxCommandResult> execute({
    required String command,
    required String workspaceRoot,
    required String workingDirectory,
    required int timeoutSeconds,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    _cancelRequestedDuringStart = false;
    _activeRequestId = null;
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Command cannot be empty.');
    }
    if (trimmed.length > maxCommandChars) {
      throw const FormatException(
        'Command is too long (maximum 32,000 characters).',
      );
    }
    final timeout = timeoutSeconds
        .clamp(minTimeoutSeconds, maxTimeoutSeconds)
        .toInt();
    await _ensureListening();
    final requestId = await _methodChannel
        .invokeMethod<String>('startTermuxCommand', {
          'command': trimmed,
          'workspaceRoot': workspaceRoot,
          'workingDirectory': workingDirectory,
          'timeoutSeconds': timeout,
        });
    if (requestId == null || requestId.isEmpty) {
      throw PlatformException(
        code: 'termux_no_request_id',
        message: 'Termux did not accept the command request.',
      );
    }
    final pending = _PendingCommand(onOutput);
    _pending[requestId] = pending;
    _activeRequestId = requestId;
    if (_cancelRequestedDuringStart) {
      await cancelActiveCommand();
    }
    final early = _earlyEvents.remove(requestId) ?? const [];
    for (final event in early) {
      _handleEvent(event);
    }
    try {
      return await pending.completer.future.timeout(
        Duration(seconds: timeout + 35),
        onTimeout: () => throw TimeoutException(
          'No final result was received from Termux. The command may still be '
          'running until its Termux timeout expires.',
        ),
      );
    } finally {
      _pending.remove(requestId);
      if (_activeRequestId == requestId) _activeRequestId = null;
      _cancelRequestedDuringStart = false;
    }
  }

  @override
  Future<void> cancelActiveCommand() async {
    final requestId = _activeRequestId;
    if (requestId == null) {
      _cancelRequestedDuringStart = true;
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('cancelTermuxCommand', {
        'requestId': requestId,
      });
    } on PlatformException {
      // The command still has a strict Termux-side timeout if cancellation
      // cannot be delivered.
    }
  }

  static Future<void> _ensureListening() async {
    if (_subscription != null) return;
    _subscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is Map) {
          _handleEvent(Map<String, dynamic>.from(event));
        }
      },
      onError: (Object error) {
        final wrapped = error is PlatformException
            ? error
            : PlatformException(code: 'termux_event_stream', message: '$error');
        for (final entry in _pending.values) {
          if (!entry.completer.isCompleted) {
            entry.completer.completeError(wrapped);
          }
        }
      },
    );
  }

  static void _handleEvent(Map<String, dynamic> event) {
    final requestId = event['requestId']?.toString();
    if (requestId == null || requestId.isEmpty) return;
    final pending = _pending[requestId];
    if (pending == null) {
      final early = _earlyEvents.putIfAbsent(requestId, () => []);
      if (early.length >= 512) early.removeAt(0);
      early.add(event);
      return;
    }
    final type = event['type']?.toString();
    if (type == 'output') {
      final channel = event['channel']?.toString() ?? 'stdout';
      final chunk = event['chunk']?.toString() ?? '';
      final target = channel == 'stderr' ? pending.stderr : pending.stdout;
      final already = target.length;
      final remaining = maxOutputCharsPerStream - already;
      if (remaining > 0) {
        target.write(
          chunk.substring(0, chunk.length.clamp(0, remaining).toInt()),
        );
      }
      if (chunk.length > remaining) {
        if (channel == 'stderr') {
          pending.stderrTruncated = true;
        } else {
          pending.stdoutTruncated = true;
        }
      }
      pending.onOutput?.call(channel, chunk);
      return;
    }
    if (type == 'complete') {
      pending.exitCode = (event['exitCode'] as num?)?.toInt() ?? 125;
      final error = event['error']?.toString();
      if (error != null && error.isNotEmpty) pending.error = error;
      pending.stdoutTruncated |= event['stdoutTruncated'] == true;
      pending.stderrTruncated |= event['stderrTruncated'] == true;
      if (!pending.completer.isCompleted) {
        pending.completer.complete(
          TermuxCommandResult(
            stdout: pending.stdout.toString(),
            stderr: pending.stderr.toString(),
            exitCode: pending.exitCode!,
            error: pending.error,
            stdoutTruncated: pending.stdoutTruncated,
            stderrTruncated: pending.stderrTruncated,
          ),
        );
      }
    }
  }

  static String formatOutputForTool(TermuxCommandResult result) =>
      jsonEncode(result.toJson());
}

bool isTermuxSharedStoragePath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized == '/sdcard' ||
      normalized.startsWith('/sdcard/') ||
      normalized == '/storage/emulated/0' ||
      normalized.startsWith('/storage/emulated/0/') ||
      normalized == '/storage/self/primary' ||
      normalized.startsWith('/storage/self/primary/') ||
      RegExp(r'^/storage/[0-9A-Fa-f-]{8,}/').hasMatch(normalized);
}

import 'package:flutter/services.dart';

/// Foreground service that keeps the agent loop alive while the app
/// is in the background (Batch 5 — desain D8, keputusan Rehan
/// 2026-11-16: agent tetap jalan di background).
///
/// Dart side of the `dev.codeharness/agent_foreground` channel; the
/// native side (MainActivity + AgentForegroundService) shows a
/// persistent notification (`Agent sedang mengerjakan <judul tugas>`)
/// while the agent runs. Android requires that notification for the
/// whole time the service runs.
///
/// Calls are best-effort: on a platform without the native service
/// (tests, desktop) the missing-plugin error is swallowed and the
/// agent loop simply runs without a foreground service.
class AgentForegroundService {
  static const MethodChannel _defaultChannel = MethodChannel(
    'dev.codeharness/agent_foreground',
  );

  final MethodChannel _channel;

  AgentForegroundService({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  /// Starts the foreground service with a notification naming the
  /// task. Safe to call when it is already running (the native side
  /// just updates the notification text).
  Future<void> start(String taskTitle) async {
    try {
      await _channel.invokeMethod('start', {'title': taskTitle});
    } catch (_) {
      // No native service (tests / non-Android): run without it.
    }
  }

  /// Stops the foreground service and removes its notification.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // Already stopped, or no native service: nothing to do.
    }
  }
}

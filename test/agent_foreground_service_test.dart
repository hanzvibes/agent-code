import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/services/agent_foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.codeharness/agent_foreground');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start sends the task title to the native service', () async {
    final service = AgentForegroundService();
    await service.start('Fix the login bug');

    expect(calls.length, 1);
    expect(calls.first.method, 'start');
    expect(calls.first.arguments, {'title': 'Fix the login bug'});
  });

  test('stop tells the native service to stop', () async {
    final service = AgentForegroundService();
    await service.start('Fix the login bug');
    await service.stop();

    expect(calls.length, 2);
    expect(calls.last.method, 'stop');
  });

  test('missing native service is swallowed, not thrown', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final service = AgentForegroundService();
    await service.start('Fix the login bug');
    await service.stop();
    // No throw: the agent loop runs without a foreground service.
  });
}

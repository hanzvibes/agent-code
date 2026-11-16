import 'dart:convert';
import 'dart:io';

import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/services/android_native_action_service.dart';
import 'package:code_harness/services/runtime_service.dart';
import 'package:code_harness/services/workspace_tool_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAndroidActions implements AndroidNativeActionAdapter {
  String? copied;
  String? shared;
  String? opened;

  @override
  Future<void> copyText(String text) async => copied = text;

  @override
  Future<void> openLink(String url) async => opened = url;

  @override
  Future<void> shareText({required String title, required String text}) async {
    shared = '$title\n$text';
  }
}

/// Bundled-backend fake: answers `hasTool` from a tool table and
/// returns a scripted result for every run.
class _FakeBundledBackend implements RuntimeBackend {
  int calls = 0;

  @override
  String get name => 'bundled';

  @override
  Future<bool> hasTool(
    String name, {
    String workspaceRoot = '',
    String cwd = '',
  }) async => name == 'git';

  @override
  Future<CommandResult> run({
    required String command,
    required String workspaceRoot,
    required String cwd,
    int timeoutSeconds = 30,
    Map<String, String>? env,
    void Function(String channel, String chunk)? onOutput,
  }) async {
    calls++;
    onOutput?.call('stdout', 'ok\n');
    return const CommandResult(
      stdout: 'ok\n',
      stderr: 'warning\n',
      exitCode: 7,
      backend: 'bundled',
    );
  }

  @override
  Future<void> cancelActiveCommand() async {}
}

void main() {
  group('bounded tool discovery', () {
    test('exposes one tool for each optional runtime/action group', () {
      expect(WorkspaceToolService.runtimeToolDefinitions, hasLength(1));
      expect(WorkspaceToolService.androidActionToolDefinitions, hasLength(1));
      expect(
        WorkspaceToolService.runtimeToolDefinitions.single['function']['name'],
        'run_project_command',
      );
      expect(
        WorkspaceToolService
            .androidActionToolDefinitions
            .single['function']['name'],
        'android_action',
      );
    });
  });

  group('Runtime command tool', () {
    late Directory tempDir;
    late _FakeBundledBackend bundled;
    late WorkspaceToolService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('runtime_tool_test_');
      bundled = _FakeBundledBackend();
      service = WorkspaceToolService(
        runtimeService: RuntimeService(bundled: bundled),
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('Plan mode denies commands before contacting the runtime', () async {
      final result = await service.execute(
        workspaceRoot: tempDir.path,
        mode: AgentMode.plan,
        call: const ToolCallInfo(
          id: 'runtime-plan',
          name: 'run_project_command',
          arguments: '{"command":"git status"}',
        ),
      );

      expect(result.output, contains('Plan mode is read-only'));
      expect(bundled.calls, 0);
    });

    test('runs in an app-private workspace via the bundled backend',
        () async {
      final result = await service.execute(
        workspaceRoot: tempDir.path,
        mode: AgentMode.agent,
        call: const ToolCallInfo(
          id: 'private-root',
          name: 'run_project_command',
          arguments: '{"command":"git status"}',
        ),
      );

      // No shared-storage gate any more: the app-private temp dir is
      // a valid workspace and the command runs via bundled.
      expect(result.isError, isFalse);
      expect(result.output, contains('"backend":"bundled"'));
      expect(result.output, contains('ok'));
      expect(bundled.calls, 1);
    });

    test('serializes stdout, stderr, and exit code for the model', () {
      final serialized = jsonEncode(
        const CommandResult(
          stdout: 'build output',
          stderr: 'warning',
          exitCode: 7,
          backend: 'bundled',
        ).toJson(),
      );
      final result = jsonDecode(serialized) as Map<String, dynamic>;
      expect(result['stdout'], 'build output');
      expect(result['stderr'], 'warning');
      expect(result['exit_code'], 7);
    });
  });

  group('Android native actions', () {
    late _FakeAndroidActions actions;
    late WorkspaceToolService service;

    setUp(() {
      actions = _FakeAndroidActions();
      service = WorkspaceToolService(androidActions: actions);
    });

    test('android_action always needs approval, in every mode', () async {
      // No approval callback: even in Auto mode the action is refused
      // before Android is touched.
      final result = await service.execute(
        workspaceRoot: '',
        mode: AgentMode.auto,
        call: const ToolCallInfo(
          id: 'android-no-confirm',
          name: 'android_action',
          arguments: '{"action":"copy_text","text":"hello"}',
        ),
      );

      expect(result.isError, isTrue);
      expect(result.output, contains('declined'));
      expect(actions.copied, isNull);
    });

    test(
      'shows the exact payload and does not copy when approval is declined',
      () async {
        AndroidActionRequest? shown;
        final result = await service.execute(
          workspaceRoot: '',
          call: const ToolCallInfo(
            id: 'copy-denied',
            name: 'android_action',
            arguments: '{"action":"copy_text","text":"exact secret text"}',
          ),
          confirmAndroidAction: (request) async {
            shown = request;
            return false;
          },
        );

        expect(shown?.preview, 'exact secret text');
        expect(result.output, contains('declined'));
        expect(actions.copied, isNull);
      },
    );

    test('runs Android share only after approving the exact content', () async {
      AndroidActionRequest? shown;
      final result = await service.execute(
        workspaceRoot: '',
        call: const ToolCallInfo(
          id: 'share-ok',
          name: 'android_action',
          arguments:
              '{"action":"share_text","title":"Note","text":"Hello from the app"}',
        ),
        confirmAndroidAction: (request) async {
          shown = request;
          return true;
        },
      );

      expect(shown?.preview, 'Hello from the app');
      expect(actions.shared, 'Note\nHello from the app');
      expect(result.output, contains('"ok":true'));
    });

    test(
      'rejects unsafe link schemes before approval or Android intent',
      () async {
        var approvalAsked = false;
        final result = await service.execute(
          workspaceRoot: '',
          call: const ToolCallInfo(
            id: 'unsafe-link',
            name: 'android_action',
            arguments: '{"action":"open_link","url":"javascript:alert(1)"}',
          ),
          confirmAndroidAction: (_) async {
            approvalAsked = true;
            return true;
          },
        );

        expect(result.output, contains('HTTP or HTTPS'));
        expect(approvalAsked, isFalse);
        expect(actions.opened, isNull);
      },
    );
  });
}

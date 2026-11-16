import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/controllers/app_controller.dart';
import 'package:code_harness/controllers/assistant_controller.dart';
import 'package:code_harness/controllers/project_controller.dart';
import 'package:code_harness/models/agent_task.dart';
import 'package:code_harness/models/app_prefs.dart';
import 'package:code_harness/models/chat_message.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/repositories/chat_repository.dart';
import 'package:code_harness/repositories/prefs_repository.dart';
import 'package:code_harness/repositories/profile_repository.dart';
import 'package:code_harness/services/llm_service.dart';
import 'package:code_harness/services/workspace_tool_service.dart';

class FakePrefsRepo extends PrefsRepository {
  final AppPrefs _prefs = AppPrefs();
  @override
  AppPrefs get prefs => _prefs;
  @override
  Future<void> save(AppPrefs prefs) async {}
}

class FakeProfileRepo extends ProfileRepository {
  final List<ProviderProfile> profiles = [];
  @override
  List<ProviderProfile> getAll() => profiles;
  @override
  ProviderProfile? getById(String id) {
    try {
      return profiles.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getApiKey(String id) async => 'fake-key';
}

class FakeChatRepo extends ChatRepository {
  final Map<String, List<ChatMessage>> storage = {};
  @override
  Future<List<ChatMessage>> load(String workspacePath) async =>
      List.from(storage[workspacePath] ?? []);
  @override
  Future<void> save(String workspacePath, List<ChatMessage> messages) async {
    storage[workspacePath] = messages
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList();
  }

  @override
  Future<void> delete(String workspacePath) async {
    storage.remove(workspacePath);
  }
}

class FakeLlmService extends LlmService {
  final List<LlmStreamResponse> scriptResponses = [];
  int requestCount = 0;
  List<Map<String, dynamic>> lastMessages = [];
  List<Map<String, dynamic>> lastTools = [];
  Completer<void>? gate;

  @override
  Future<LlmStreamResponse> streamRequest({
    required ProviderProfile profile,
    required String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,
  }) async {
    requestCount++;
    lastMessages = List.from(messages);
    lastTools = List.from(tools ?? []);
    if (gate != null) await gate!.future;
    if (scriptResponses.isNotEmpty) {
      final resp = scriptResponses.removeAt(0);
      if (resp.text.isNotEmpty) onDelta?.call(resp.text);
      return resp;
    }
    onDelta?.call('Default response');
    return const LlmStreamResponse(text: 'Default response');
  }
}

void main() {
  late Directory tempDir;
  late AppController appController;
  late ProjectController projectController;
  late FakeProfileRepo profileRepo;
  late FakeChatRepo chatRepo;
  late FakeLlmService llmService;
  late AssistantController assistantController;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('assistant_agent_test_');
    profileRepo = FakeProfileRepo();
    profileRepo.profiles.add(
      ProviderProfile(
        id: 'p1',
        name: 'Test Profile',
        baseUrl: 'https://api.example.com',
        modelId: 'test-model',
      ),
    );
    chatRepo = FakeChatRepo();
    llmService = FakeLlmService();

    final prefsRepo = FakePrefsRepo();
    prefsRepo.prefs.activeProfileId = 'p1';

    appController = AppController(
      prefsRepo: prefsRepo,
      profileRepo: profileRepo,
    );
    appController.onInit();

    projectController = ProjectController(appController);
    await projectController.openWorkspace(tempDir.path);

    assistantController = AssistantController(
      appController: appController,
      projectController: projectController,
      profileRepo: profileRepo,
      chatRepo: chatRepo,
      llmService: llmService,
    );
    assistantController.onInit();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    assistantController.onClose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
    Get.reset();
  });

  test('sendMessage creates an Agent-mode task that finishes', () async {
    await assistantController.sendMessage('Explain this project');

    final task = assistantController.activeTask.value;
    expect(task, isNotNull);
    expect(task!.title, 'Explain this project');
    expect(task.mode, AgentMode.agent);
    expect(task.status, TaskStatus.done);
    expect(assistantController.messages.last.content, 'Default response');
  });

  test('system prompt tells the model to plan first', () async {
    await assistantController.sendMessage('Do something');

    final systemMessage = llmService.lastMessages.firstWhere(
      (message) => message['role'] == 'system',
    );
    final systemPrompt = systemMessage['content'] as String;
    expect(systemPrompt, contains('plan first'));
    expect(systemPrompt, contains('never guess'));
    expect(systemPrompt, contains('read the relevant file first'));
  });

  test('update_todo and finish_task flow through the controller', () async {
    llmService.scriptResponses.addAll([
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c1',
            name: 'update_todo',
            arguments: jsonEncode({
              'steps': [
                {'title': 'Read the file', 'status': 'done'},
                {'title': 'Edit the file', 'status': 'active'},
              ],
            }),
          ),
        ],
      ),
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c2',
            name: 'finish_task',
            arguments: jsonEncode({'summary': 'Edited the file.'}),
          ),
        ],
      ),
    ]);

    await assistantController.sendMessage('Fix the bug');

    final task = assistantController.activeTask.value;
    expect(task, isNotNull);
    expect(task!.status, TaskStatus.done);
    expect(task.totalTodoCount, 2);
    expect(task.doneTodoCount, 1);
    expect(task.summary, 'Edited the file.');
    expect(assistantController.messages.last.content, 'Edited the file.');
    expect(
      llmService.lastTools.map((tool) => tool['function']['name']),
      containsAll(['update_todo', 'finish_task']),
    );
  });

  test('same tool error three times pauses with needs-help', () async {
    // 'nope' is not a permitted tool, so the real executor returns the
    // same error every time.
    llmService.scriptResponses.addAll([
      const LlmStreamResponse(
        toolCalls: [ToolCallInfo(id: 'c1', name: 'nope', arguments: '{}')],
      ),
      const LlmStreamResponse(
        toolCalls: [ToolCallInfo(id: 'c2', name: 'nope', arguments: '{}')],
      ),
      const LlmStreamResponse(
        toolCalls: [ToolCallInfo(id: 'c3', name: 'nope', arguments: '{}')],
      ),
    ]);

    await assistantController.sendMessage('Do the forbidden thing');

    final task = assistantController.activeTask.value;
    expect(task!.status, TaskStatus.needsHelp);
    expect(assistantController.lastError.value, contains('needs your help'));
    // No assistant answer was produced, so the user message stays last
    // and retryable.
    expect(assistantController.messages.last.role, 'user');
    expect(assistantController.canRetry, isTrue);
  });

  test('write tools run through the engine and record checkpoints', () async {
    File('${tempDir.path}/notes.txt').writeAsStringSync('alpha\nbeta\n');
    File('${tempDir.path}/old.txt').writeAsStringSync('stale\n');
    llmService.scriptResponses.addAll([
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c1',
            name: 'update_todo',
            arguments: jsonEncode({
              'steps': [
                {'title': 'Edit the file', 'status': 'active'},
              ],
            }),
          ),
        ],
      ),
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c2',
            name: 'write_file',
            arguments: jsonEncode({
              'path': 'notes.txt',
              'content': 'alpha\nBETA\n',
            }),
          ),
        ],
      ),
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c3',
            name: 'delete_file',
            arguments: jsonEncode({'path': 'old.txt'}),
          ),
        ],
      ),
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c4',
            name: 'finish_task',
            arguments: jsonEncode({'summary': 'Edited and cleaned up.'}),
          ),
        ],
      ),
    ]);

    await assistantController.sendMessage('Fix the notes file');

    final task = assistantController.activeTask.value;
    expect(task, isNotNull);
    expect(task!.status, TaskStatus.done);
    expect(
      await File('${tempDir.path}/notes.txt').readAsString(),
      'alpha\nBETA\n',
    );
    expect(await File('${tempDir.path}/old.txt').exists(), isFalse);

    // Both writes were checkpointed under this task.
    final checkpoints = assistantController.activeTaskCheckpoints;
    expect(checkpoints, hasLength(2));
    expect(checkpoints.map((cp) => cp.path), ['notes.txt', 'old.txt']);
    expect(checkpoints.first.before, 'alpha\nbeta\n');
    expect(checkpoints.first.after, 'alpha\nBETA\n');
    expect(checkpoints.last.isDelete, isTrue);

    // The model was offered the write tools.
    expect(
      llmService.lastTools.map((tool) => tool['function']['name']),
      containsAll(['write_file', 'edit_file', 'create_file', 'delete_file']),
    );

    // The task finished, so the trash was permanently purged (D2).
    final trashDir = Directory('${tempDir.path}/.codeharness-trash/${task.id}');
    expect(await trashDir.exists(), isFalse);
  });

  test('system prompt mentions write tools and undo when enabled', () async {
    await assistantController.sendMessage('Do something');

    final systemMessage = llmService.lastMessages.firstWhere(
      (message) => message['role'] == 'system',
    );
    final systemPrompt = systemMessage['content'] as String;
    expect(systemPrompt, contains('write_file'));
    expect(systemPrompt, contains('undo'));
  });

  test('stopAgent cancels the in-flight run', () async {
    llmService.gate = Completer<void>();
    llmService.scriptResponses.add(
      const LlmStreamResponse(text: 'never arrives'),
    );

    final run = assistantController.sendMessage('Long task');
    // Wait until the generation is actually in flight.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!assistantController.isLoading.value) {
      if (DateTime.now().isAfter(deadline)) {
        fail('generation did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    assistantController.stopAgent();
    llmService.gate!.complete();
    await run;

    final task = assistantController.activeTask.value;
    expect(task, isNotNull);
    expect(task!.status, TaskStatus.cancelled);
    expect(assistantController.isLoading.value, isFalse);
    // The cancelled run adds no assistant message.
    expect(assistantController.messages.length, 1);
    expect(assistantController.messages.first.role, 'user');
  });

  test(
    'Plan mode offers only read tools; Agent mode offers write tools',
    () async {
      await assistantController.setAgentMode(AgentMode.plan);
      await assistantController.sendMessage('Inspect this project');

      final planTools = llmService.lastTools
          .map((tool) => tool['function']['name'] as String)
          .toSet();
      expect(planTools, contains('list_project_files'));
      expect(planTools, contains('detect_project'));
      expect(planTools, contains('update_todo'));
      expect(planTools, isNot(contains('write_file')));
      expect(planTools, isNot(contains('run_project_command')));

      await assistantController.setAgentMode(AgentMode.agent);
      await assistantController.sendMessage('Fix it');

      final agentTools = llmService.lastTools
          .map((tool) => tool['function']['name'] as String)
          .toSet();
      expect(agentTools, contains('write_file'));
      expect(agentTools, contains('edit_file'));
      expect(agentTools, contains('run_project_command'));
      expect(agentTools, contains('probe_toolchain'));
    },
  );

  test('mode is saved per workspace and restored on switch', () async {
    final firstPath = projectController.workspacePath.value;
    await assistantController.setAgentMode(AgentMode.plan);
    expect(assistantController.agentMode.value, AgentMode.plan);

    final secondDir = await Directory.systemTemp.createTemp(
      'assistant_agent_test_ws2_',
    );
    try {
      await projectController.openWorkspace(secondDir.path);
      await _waitForMode(assistantController, AgentMode.agent);
      expect(assistantController.agentMode.value, AgentMode.agent);

      await projectController.openWorkspace(firstPath);
      await _waitForMode(assistantController, AgentMode.plan);
      expect(assistantController.agentMode.value, AgentMode.plan);
    } finally {
      if (secondDir.existsSync()) {
        await secondDir.delete(recursive: true);
      }
    }
  });
}

/// Waits until the controller reports [mode] (workspace switches load
/// the saved mode asynchronously), failing after 5 seconds.
Future<void> _waitForMode(
  AssistantController controller,
  AgentMode mode,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (controller.agentMode.value != mode) {
    if (DateTime.now().isAfter(deadline)) {
      fail('mode did not become $mode');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

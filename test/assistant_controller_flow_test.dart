import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/controllers/app_controller.dart';
import 'package:code_harness/controllers/assistant_controller.dart';
import 'package:code_harness/controllers/project_controller.dart';
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
  final Map<String, Completer<void>> loadGates = {};
  @override
  Future<List<ChatMessage>> load(String workspacePath) async {
    final gate = loadGates[workspacePath];
    if (gate != null) await gate.future;
    return List.from(storage[workspacePath] ?? []);
  }

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
  double? lastTemperature;
  int? lastMaxTokens;

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
    lastTemperature = temperature;
    lastMaxTokens = maxTokens;

    if (scriptResponses.isNotEmpty) {
      final resp = scriptResponses.removeAt(0);
      if (resp.text.isNotEmpty) {
        onDelta?.call(resp.text);
      }
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
    tempDir = await Directory.systemTemp.createTemp('assistant_ctrl_test_');
    profileRepo = FakeProfileRepo();
    final p = ProviderProfile(
      id: 'p1',
      name: 'Test Profile',
      baseUrl: 'https://api.example.com',
      modelId: 'test-model',
    );
    profileRepo.profiles.add(p);

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

  test('sends message and saves session to ChatRepository', () async {
    await assistantController.sendMessage('Hello assistant');

    expect(assistantController.messages.length, 2);
    expect(assistantController.messages[0].role, 'user');
    expect(assistantController.messages[0].content, 'Hello assistant');
    expect(assistantController.messages[1].role, 'assistant');
    expect(assistantController.messages[1].content, 'Default response');

    // Verify saved in repository
    final saved = await chatRepo.load(tempDir.path);
    expect(saved.length, 2);
    expect(saved[0].content, 'Hello assistant');
  });

  test(
    'late workspace restore cannot load an old session into the new project',
    () async {
      assistantController.onClose();
      final delayedRepo = FakeChatRepo();
      delayedRepo.storage[tempDir.path] = [
        ChatMessage(
          role: 'user',
          content: 'old project',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          role: 'assistant',
          content: 'old reply',
          timestamp: DateTime.now(),
        ),
      ];
      final gate = Completer<void>();
      delayedRepo.loadGates[tempDir.path] = gate;

      final nextDir = await Directory.systemTemp.createTemp('next_ws_');
      delayedRepo.storage[nextDir.path] = [
        ChatMessage(
          role: 'user',
          content: 'new project',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          role: 'assistant',
          content: 'new reply',
          timestamp: DateTime.now(),
        ),
      ];
      final nextController = AssistantController(
        appController: appController,
        projectController: projectController,
        profileRepo: profileRepo,
        chatRepo: delayedRepo,
        llmService: llmService,
      );
      assistantController = nextController;
      nextController.onInit();
      await Future<void>.delayed(Duration.zero);

      await projectController.openWorkspace(nextDir.path);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(nextController.messages.length, 2);
      expect(nextController.messages.first.content, 'new project');
      expect(nextController.messages.last.content, 'new reply');
      await nextDir.delete(recursive: true);
    },
  );

  test(
    'retry resends last user message without duplicate user entry',
    () async {
      // Simulate failed first request where user message was added
      assistantController.messages.add(
        ChatMessage(
          role: 'user',
          content: 'Initial query',
          timestamp: DateTime.now(),
        ),
      );

      expect(assistantController.canRetry, isTrue);
      expect(assistantController.canRegenerate, isFalse);

      await assistantController.retry();

      expect(assistantController.messages.length, 2);
      expect(assistantController.messages[0].content, 'Initial query');
      expect(assistantController.messages[1].role, 'assistant');
      expect(assistantController.messages[1].content, 'Default response');
    },
  );

  test(
    'regenerate replaces last assistant answer without duplicate user message',
    () async {
      assistantController.messages.addAll([
        ChatMessage(
          role: 'user',
          content: 'What is 2+2?',
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          role: 'assistant',
          content: 'It is 5',
          timestamp: DateTime.now(),
        ),
      ]);

      expect(assistantController.canRegenerate, isTrue);

      llmService.scriptResponses.add(const LlmStreamResponse(text: 'It is 4'));

      await assistantController.regenerate();

      expect(assistantController.messages.length, 2);
      expect(assistantController.messages[0].role, 'user');
      expect(assistantController.messages[0].content, 'What is 2+2?');
      expect(assistantController.messages[1].role, 'assistant');
      expect(assistantController.messages[1].content, 'It is 4');
    },
  );

  test('generation controls clamp and pass parameters to LLM', () async {
    assistantController.setSessionTemperature(1.5);
    assistantController.setSessionMaxTokens(2048);

    await assistantController.sendMessage('Test generation params');

    expect(llmService.lastTemperature, 1.5);
    expect(llmService.lastMaxTokens, 2048);

    assistantController.resetSessionGenerationControls();
    expect(assistantController.sessionTemperature.value, isNull);
    expect(assistantController.sessionMaxTokens.value, isNull);
  });

  test(
    'multi-turn tool execution caps rounds at 3 and does not save tool messages to chat history',
    () async {
      assistantController.enableTools.value = true;

      // Script 2 tool rounds then final response
      llmService.scriptResponses.addAll([
        const LlmStreamResponse(
          toolCalls: [
            ToolCallInfo(id: 'c1', name: 'list_project_files', arguments: '{}'),
          ],
        ),
        const LlmStreamResponse(
          toolCalls: [
            ToolCallInfo(id: 'c2', name: 'list_project_files', arguments: '{}'),
          ],
        ),
        const LlmStreamResponse(text: 'Final answer after tools'),
      ]);

      await assistantController.sendMessage('Inspect the project');

      expect(llmService.requestCount, 3);
      expect(assistantController.messages.length, 2);
      expect(
        assistantController.messages.last.content,
        'Final answer after tools',
      );

      // Stored chat session must NOT contain any tool messages
      final saved = await chatRepo.load(tempDir.path);
      expect(
        saved.every((m) => m.role == 'user' || m.role == 'assistant'),
        isTrue,
      );
      expect(saved.length, 2);
    },
  );

  test('Termux-enabled install requests are execution-first', () async {
    assistantController.enableTermuxRuntime.value = true;

    await assistantController.sendMessage('Install Remotion in this project');

    expect(
      llmService.lastTools.map((tool) => tool['function']['name']),
      contains('run_project_command'),
    );
    final systemMessage = llmService.lastMessages.firstWhere(
      (message) => message['role'] == 'system',
    );
    final systemPrompt = systemMessage['content'] as String;
    expect(systemPrompt, contains('do not substitute a tutorial'));
    expect(systemPrompt, contains('Node.js for Remotion/npm tasks'));
    expect(
      systemPrompt,
      contains('routine toolchain and project-package installation'),
    );
    expect(systemPrompt, contains('bounded to 120 seconds'));
  });
}

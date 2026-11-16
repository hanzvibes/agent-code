import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
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
import 'package:code_harness/services/task_store.dart';
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
  Completer<void>? gate;

  /// When > 0, only requests after this number wait on [gate].
  int gateFromRequest = 0;

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
    void Function(int index, String id, String name)? onToolCallName,
  }) async {
    requestCount++;
    lastMessages = List.from(messages);
    if (gate != null && requestCount > gateFromRequest) {
      await gate!.future;
    }
    if (scriptResponses.isNotEmpty) {
      final resp = scriptResponses.removeAt(0);
      if (resp.text.isNotEmpty) onDelta?.call(resp.text);
      return resp;
    }
    onDelta?.call('Default response');
    return const LlmStreamResponse(text: 'Default response');
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tempDir;
  late Box testBox;
  late TaskStore taskStore;
  late AppController appController;
  late ProjectController projectController;
  late FakeProfileRepo profileRepo;
  late FakeChatRepo chatRepo;
  late FakeLlmService llmService;

  Future<AssistantController> buildController() async {
    final controller = AssistantController(
      appController: appController,
      projectController: projectController,
      profileRepo: profileRepo,
      chatRepo: chatRepo,
      llmService: llmService,
      taskStore: taskStore,
    );
    controller.onInit();
    // Wait for the session (chat + persisted task) restore: sending
    // a message while it runs is ignored by the controller.
    await _waitFor(() => !controller.isRestoringSession.value);
    return controller;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('assistant_resume_test_');
    Hive.init(tempDir.path);
    testBox = await Hive.openBox('test_agent_tasks_resume');
    taskStore = TaskStore(box: testBox);

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
  });

  tearDown(() async {
    await testBox.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
    Get.reset();
  });

  test(
    'Stop cancels the in-flight stream and resume continues the task',
    () async {
      // Round 1: one read tool call, executed and recorded.
      // Round 2: gated — Stop is pressed while the model streams.
      llmService.scriptResponses.addAll([
        LlmStreamResponse(
          toolCalls: [
            ToolCallInfo(id: 'c1', name: 'list_project_files', arguments: '{}'),
          ],
        ),
        const LlmStreamResponse(text: 'Still working…'),
      ]);
      llmService.gateFromRequest = 1;
      llmService.gate = Completer<void>();

      final controller = await buildController();
      addTearDown(controller.onClose);

      final sendFuture = controller.sendMessage('List the files');
      await _waitFor(() => llmService.requestCount >= 2);
      controller.stopAgent();
      llmService.gate!.complete();
      await sendFuture;

      final task = controller.activeTask.value!;
      expect(task.status, TaskStatus.cancelled);
      expect(task.roundsUsed, 2);
      expect(task.toolCallsUsed, 1);
      expect(controller.toolCallRecords.length, 1);
      expect(controller.toolCallRecords.first.toolName, 'list_project_files');
      expect(controller.isLoading.value, isFalse);

      // The cancelled task was persisted with its tool-call record.
      final persisted = await taskStore.loadTasks(tempDir.path);
      expect(persisted.length, 1);
      expect(persisted.first.task.status, TaskStatus.cancelled);
      expect(persisted.first.task.roundsUsed, 2);
      expect(persisted.first.toolCalls.length, 1);

      // Resume: the model answers without tool calls, the task finishes
      // from round 3 instead of restarting at round 1.
      llmService.scriptResponses.add(
        const LlmStreamResponse(text: 'Done after resume.'),
      );
      await controller.resumeTask();

      expect(task.status, TaskStatus.done);
      expect(task.roundsUsed, 3);
      expect(task.toolCallsUsed, 1);
      expect(controller.toolCallRecords.length, 1);
      final resumeNote = llmService.lastMessages.last;
      expect(resumeNote['role'], 'user');
      expect(resumeNote['content'] as String, contains('Resumed task'));
      expect(resumeNote['content'] as String, contains('round 2/25'));
    },
  );

  test('a paused task is restored when the workspace reopens', () async {
    llmService.scriptResponses.addAll([
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(id: 'c1', name: 'list_project_files', arguments: '{}'),
        ],
      ),
      const LlmStreamResponse(text: 'Still working…'),
    ]);
    llmService.gateFromRequest = 1;
    llmService.gate = Completer<void>();

    final first = await buildController();
    final sendFuture = first.sendMessage('List the files');
    await _waitFor(() => llmService.requestCount >= 2);
    first.stopAgent();
    llmService.gate!.complete();
    await sendFuture;
    final taskId = first.activeTask.value!.id;
    first.onClose();

    // A fresh controller — as if the app was closed and reopened —
    // restores the cancelled task with its timeline records.
    final second = await buildController();
    addTearDown(second.onClose);
    await _waitFor(() => second.activeTask.value != null);

    final restored = second.activeTask.value!;
    expect(restored.id, taskId);
    expect(restored.status, TaskStatus.cancelled);
    expect(restored.roundsUsed, 2);
    expect(second.toolCallRecords.length, 1);
    expect(second.toolCallRecords.first.toolName, 'list_project_files');

    // And it can be resumed from the restored state.
    llmService.scriptResponses.add(
      const LlmStreamResponse(text: 'Finished after reopen.'),
    );
    await second.resumeTask();
    expect(restored.status, TaskStatus.done);
    expect(restored.roundsUsed, 3);
  });

  test('checkpoint survives persistence and undo restores the file', () async {
    final file = File('${tempDir.path}/notes.txt');
    await file.writeAsString('old content');
    llmService.scriptResponses.addAll([
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c1',
            name: 'write_file',
            arguments: jsonEncode({
              'path': 'notes.txt',
              'content': 'new content',
            }),
          ),
        ],
      ),
      LlmStreamResponse(
        toolCalls: [
          ToolCallInfo(
            id: 'c2',
            name: 'finish_task',
            arguments: jsonEncode({'summary': 'Wrote the note.'}),
          ),
        ],
      ),
    ]);

    final controller = await buildController();
    addTearDown(controller.onClose);
    await controller.sendMessage('Update the note');

    expect(await file.readAsString(), 'new content');
    expect(controller.activeTask.value!.status, TaskStatus.done);
    expect(controller.toolCallRecords.length, 1);
    expect(controller.toolCallRecords.first.toolName, 'write_file');

    // The checkpoint is in the store, and a fresh store built from
    // the persisted snapshot can undo it after an app restart.
    final persisted = await taskStore.loadTasks(tempDir.path);
    expect(persisted.length, 1);
    expect(persisted.first.checkpoints.length, 1);
    final storedCheckpoint = persisted.first.checkpoints.first;
    expect(storedCheckpoint.before, 'old content');
    expect(storedCheckpoint.after, 'new content');

    final freshStore = controller.checkpointStore;
    freshStore.clear();
    freshStore.loadAll(persisted.first.checkpoints);
    final error = await controller.undoCheckpoint(storedCheckpoint);
    expect(error, isNull);
    expect(await file.readAsString(), 'old content');
  });

  test('resumeTask is a no-op for a finished task', () async {
    final controller = await buildController();
    addTearDown(controller.onClose);
    await controller.sendMessage('Say hello');
    expect(controller.activeTask.value!.status, TaskStatus.done);
    final requestsBefore = llmService.requestCount;
    await controller.resumeTask();
    expect(llmService.requestCount, requestsBefore);
  });
}

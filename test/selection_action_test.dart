import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/controllers/app_controller.dart';
import 'package:code_harness/controllers/assistant_controller.dart';
import 'package:code_harness/controllers/project_controller.dart';
import 'package:code_harness/models/app_prefs.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/repositories/prefs_repository.dart';
import 'package:code_harness/repositories/profile_repository.dart';
import 'package:code_harness/services/llm_service.dart';

class _FakePrefsRepo extends PrefsRepository {
  final AppPrefs _prefs = AppPrefs();
  @override
  AppPrefs get prefs => _prefs;
  @override
  Future<void> save(AppPrefs prefs) async {}
}

class _FakeProfileRepo extends ProfileRepository {
  final List<ProviderProfile> _profiles = [];
  @override
  List<ProviderProfile> getAll() => _profiles;
  @override
  ProviderProfile? getById(String id) =>
      _profiles.isEmpty ? null : _profiles.firstWhere((p) => p.id == id);
  @override
  Future<String?> getApiKey(String id) async => null;
}

class _FakeLlmService extends LlmService {
  @override
  Future<LlmStreamResponse> streamRequest({
    required ProviderProfile profile,
    String? apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    CancelToken? cancelToken,
    double? temperature,
    int? maxTokens,
    void Function(String delta)? onDelta,
  }) async {
    return const LlmStreamResponse(text: 'Analysis response');
  }
}

void main() {
  late Directory tempDir;
  late AppController appCtrl;
  late ProjectController projectCtrl;
  late AssistantController assistantCtrl;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('selection_action_test_');
    final prefsRepo = _FakePrefsRepo();
    final profileRepo = _FakeProfileRepo();

    final testProfile = ProviderProfile(
      id: 'test-profile',
      name: 'Test Profile',
      baseUrl: 'http://localhost',
      modelId: 'test-model',
    );
    profileRepo._profiles.add(testProfile);
    prefsRepo.prefs.activeProfileId = testProfile.id;

    appCtrl = AppController(prefsRepo: prefsRepo, profileRepo: profileRepo);
    Get.put<AppController>(appCtrl);

    projectCtrl = ProjectController(appCtrl);
    await projectCtrl.openWorkspace(tempDir.path);
    Get.put<ProjectController>(projectCtrl);

    assistantCtrl = AssistantController(
      appController: appCtrl,
      projectController: projectCtrl,
      profileRepo: profileRepo,
      llmService: _FakeLlmService(),
    );
    Get.put<AssistantController>(assistantCtrl);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
    Get.reset();
  });

  group('AI actions on selected code', () {
    test(
      'formats action message with untrusted code, relative path, and language',
      () async {
        await assistantCtrl.sendSelectionAction(
          actionType: 'explain',
          relativePath: 'lib/main.dart',
          language: 'dart',
          selectedText: 'void main() => runApp(MyApp());',
          isTruncated: false,
          originalLength: 30,
        );

        expect(assistantCtrl.messages.isNotEmpty, isTrue);
        final userMessage = assistantCtrl.messages.first;
        expect(userMessage.role, 'user');
        expect(
          userMessage.content,
          contains('Explain the following untrusted code snippet'),
        );
        expect(userMessage.content, contains('lib/main.dart'));
        expect(userMessage.content, contains('```dart'));
        expect(
          userMessage.content,
          contains('void main() => runApp(MyApp());'),
        );
        expect(
          userMessage.content,
          isNot(contains('[Notice: Selected snippet was capped')),
        );
      },
    );

    test('caps at 8,000 characters with visible notice when truncated', () async {
      final largeCode = 'x' * 8000;
      await assistantCtrl.sendSelectionAction(
        actionType: 'refactor',
        relativePath: 'lib/large.dart',
        language: 'dart',
        selectedText: largeCode,
        isTruncated: true,
        originalLength: 12000,
      );

      final userMessage = assistantCtrl.messages.first;
      expect(userMessage.role, 'user');
      expect(
        userMessage.content,
        contains('Refactor the following untrusted code snippet'),
      );
      expect(
        userMessage.content,
        contains(
          '[Notice: Selected snippet was capped at 8,000 characters (truncated from 12000 characters).]',
        ),
      );
    });

    test(
      'supports all four action choices: explain, bug, refactor, tests',
      () async {
        const actions = ['explain', 'bug', 'refactor', 'tests'];
        final expectedPrompts = [
          'Explain the following untrusted code snippet',
          'Find and fix any bugs in the following untrusted code snippet',
          'Refactor the following untrusted code snippet to improve quality, structure, and maintainability',
          'Suggest tests for the following untrusted code snippet',
        ];

        for (var i = 0; i < actions.length; i++) {
          assistantCtrl.messages.clear();
          await assistantCtrl.sendSelectionAction(
            actionType: actions[i],
            relativePath: 'test.dart',
            language: 'dart',
            selectedText: 'int x = 1;',
            isTruncated: false,
            originalLength: 10,
          );

          final userMsg = assistantCtrl.messages.first;
          expect(userMsg.content, contains(expectedPrompts[i]));
        }
      },
    );

    test(
      'disables/rejects action while assistant request is already active',
      () async {
        assistantCtrl.isLoading.value = true;

        await assistantCtrl.sendSelectionAction(
          actionType: 'explain',
          relativePath: 'lib/main.dart',
          language: 'dart',
          selectedText: 'int x = 1;',
          isTruncated: false,
          originalLength: 10,
        );

        // No message should be added while loading
        expect(assistantCtrl.messages.isEmpty, isTrue);
        expect(assistantCtrl.lastError.value, contains('already active'));
      },
    );

    test(
      'tab switching: selectTab switches active tab to Assistant (index 1)',
      () {
        expect(appCtrl.selectedTab.value, 0); // initial: Project tab
        appCtrl.selectTab(1);
        expect(appCtrl.selectedTab.value, 1); // Assistant tab
      },
    );

    test('action itself never writes files to disk', () async {
      final testFile = File('${tempDir.path}/code.dart');
      await testFile.writeAsString('original file content');

      await assistantCtrl.sendSelectionAction(
        actionType: 'refactor',
        relativePath: 'code.dart',
        language: 'dart',
        selectedText: 'original file content',
        isTruncated: false,
        originalLength: 21,
      );

      // Disk content must remain unchanged
      final diskContent = await testFile.readAsString();
      expect(diskContent, 'original file content');
    });
  });
}

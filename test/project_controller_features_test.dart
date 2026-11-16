import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/controllers/app_controller.dart';
import 'package:code_harness/controllers/project_controller.dart';
import 'package:code_harness/models/app_prefs.dart';
import 'package:code_harness/models/provider_profile.dart';
import 'package:code_harness/repositories/prefs_repository.dart';
import 'package:code_harness/repositories/profile_repository.dart';

class FakePrefsRepo extends PrefsRepository {
  final AppPrefs _prefs = AppPrefs();
  @override
  AppPrefs get prefs => _prefs;
  @override
  Future<void> save(AppPrefs prefs) async {}
}

class FakeProfileRepo extends ProfileRepository {
  @override
  List<ProviderProfile> getAll() => [];
}

void main() {
  late Directory tempDir;
  late ProjectController projectController;
  late AppController appController;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proj_features_test_');
    appController = AppController(
      prefsRepo: FakePrefsRepo(),
      profileRepo: FakeProfileRepo(),
    );
    appController.onInit();
    projectController = ProjectController(appController);
    await projectController.openWorkspace(tempDir.path);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
    Get.reset();
  });

  test(
    'editor undo and redo updates content and dirty state without disk writes',
    () async {
      final file = File('${tempDir.path}/code.dart');
      await file.writeAsString('initial');

      await projectController.openFileByPath(file.path);
      expect(projectController.hasUnsavedChanges, isFalse);
      expect(projectController.canUndo.value, isFalse);

      // Edit 1
      projectController.updateEditorContent('step 1');
      expect(projectController.hasUnsavedChanges, isTrue);
      expect(projectController.canUndo.value, isTrue);

      // Edit 2
      projectController.updateEditorContent('step 2');
      expect(projectController.editorContent.value, 'step 2');

      // Undo -> step 1
      projectController.undo();
      expect(projectController.editorContent.value, 'step 1');
      expect(projectController.canRedo.value, isTrue);
      // Disk content is still untouched
      expect(await file.readAsString(), 'initial');

      // Undo -> initial
      projectController.undo();
      expect(projectController.editorContent.value, 'initial');
      expect(projectController.hasUnsavedChanges, isFalse);

      // Redo -> step 1
      projectController.redo();
      expect(projectController.editorContent.value, 'step 1');
      expect(projectController.hasUnsavedChanges, isTrue);

      // Save writes to disk
      await projectController.saveCurrentFile();
      expect(await file.readAsString(), 'step 1');
      expect(projectController.hasUnsavedChanges, isFalse);
    },
  );

  test('file switch resets undo/redo history', () async {
    final file1 = File('${tempDir.path}/one.dart')..writeAsStringSync('one');
    final file2 = File('${tempDir.path}/two.dart')..writeAsStringSync('two');

    await projectController.openFileByPath(file1.path);
    projectController.updateEditorContent('one edited');
    expect(projectController.canUndo.value, isTrue);

    // Switch file (discarding changes in memory for switch)
    projectController.savedContent.value =
        'one edited'; // simulate saved so switch proceeds without dialog
    await projectController.openFileByPath(file2.path);

    expect(projectController.editorContent.value, 'two');
    expect(projectController.canUndo.value, isFalse);
    expect(projectController.canRedo.value, isFalse);
  });

  test(
    'find and replace in editor manages matches, replaces current and all',
    () async {
      final file = File('${tempDir.path}/search.dart');
      await file.writeAsString('apple banana apple cherry apple');

      await projectController.openFileByPath(file.path);

      // Find query
      projectController.updateFindQuery('apple');
      expect(projectController.findTotalMatches.value, 3);
      expect(projectController.currentMatchIndex.value, 1);
      expect(projectController.findMatchStart.value, 0);
      expect(projectController.findMatchEnd.value, 5);

      // Find next wraps to second match
      projectController.findNextMatch();
      expect(projectController.currentMatchIndex.value, 2);
      expect(projectController.findMatchStart.value, 13);

      // Replace current match
      projectController.replaceQuery.value = 'orange';
      projectController.replaceCurrentMatch();
      expect(
        projectController.editorContent.value,
        'apple banana orange cherry apple',
      );
      expect(projectController.hasUnsavedChanges, isTrue);

      // Replace all
      projectController.replaceQuery.value = 'grape';
      projectController.updateFindQuery('apple');
      expect(projectController.findTotalMatches.value, 2);
      projectController.replaceAllMatches();
      expect(
        projectController.editorContent.value,
        'grape banana orange cherry grape',
      );

      // File on disk remains untouched until save
      expect(await file.readAsString(), 'apple banana apple cherry apple');
    },
  );

  test(
    'createNewFile creates relative file, refreshes tree, and opens it',
    () async {
      await projectController.createNewFile('src/helpers/utils.dart');

      expect(
        File('${tempDir.path}/src/helpers/utils.dart').existsSync(),
        isTrue,
      );
      expect(projectController.openFile.value?.name, 'utils.dart');
      expect(projectController.editorContent.value, '');
    },
  );
}

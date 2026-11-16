import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:code_harness/controllers/app_controller.dart';
import 'package:code_harness/controllers/project_controller.dart';
import 'package:code_harness/controllers/review_controller.dart';
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
    tempDir = await Directory.systemTemp.createTemp('rollback_test_');
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
    'applies patch and rolls back pre-existing and newly created files',
    () async {
      final existingFile = File('${tempDir.path}/hello.txt');
      await existingFile.writeAsString('initial content');

      final changes = [
        const PatchFile(
          path: 'hello.txt',
          before: 'initial content',
          after: 'modified content',
          existedAtPreview: true,
        ),
        const PatchFile(
          path: 'new_feature.txt',
          before: '',
          after: 'created by patch',
          existedAtPreview: false,
        ),
      ];

      await projectController.applyPatch(changes);
      expect(projectController.canRollbackPatch, isTrue);

      final newFile = File('${tempDir.path}/new_feature.txt');
      expect(await existingFile.readAsString(), 'modified content');
      expect(await newFile.exists(), isTrue);
      expect(await newFile.readAsString(), 'created by patch');

      // Rollback
      await projectController.rollbackLastPatch();

      // Verify existing file restored
      expect(await existingFile.readAsString(), 'initial content');
      // Verify created file removed
      expect(await newFile.exists(), isFalse);
      // Verify rollback state cleared
      expect(projectController.canRollbackPatch, isFalse);
    },
  );

  test(
    'rejects rollback if a target file was modified after patch application',
    () async {
      final existingFile = File('${tempDir.path}/file.txt');
      await existingFile.writeAsString('before text');

      final changes = [
        const PatchFile(
          path: 'file.txt',
          before: 'before text',
          after: 'after text',
          existedAtPreview: true,
        ),
      ];

      await projectController.applyPatch(changes);
      expect(projectController.canRollbackPatch, isTrue);

      // Modify the file outside the patch
      await existingFile.writeAsString('tampered content');

      expect(
        () => projectController.rollbackLastPatch(),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('changed since the patch was applied'),
          ),
        ),
      );
    },
  );

  test(
    'rollback restores an existing file whose original content was empty',
    () async {
      final emptyFile = File('${tempDir.path}/empty.txt');
      await emptyFile.create();
      await projectController.applyPatch([
        const PatchFile(
          path: 'empty.txt',
          before: '',
          after: 'temporary content',
          existedAtPreview: true,
        ),
      ]);

      await projectController.rollbackLastPatch();

      expect(await emptyFile.exists(), isTrue);
      expect(await emptyFile.readAsString(), isEmpty);
    },
  );

  test('switching workspace clears rollback state', () async {
    final existingFile = File('${tempDir.path}/file.txt');
    await existingFile.writeAsString('before text');

    final changes = [
      const PatchFile(
        path: 'file.txt',
        before: 'before text',
        after: 'after text',
        existedAtPreview: true,
      ),
    ];

    await projectController.applyPatch(changes);
    expect(projectController.canRollbackPatch, isTrue);

    final otherDir = await Directory.systemTemp.createTemp('other_ws_');
    try {
      await projectController.openWorkspace(otherDir.path);
      expect(projectController.canRollbackPatch, isFalse);
    } finally {
      if (otherDir.existsSync()) await otherDir.delete(recursive: true);
    }
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/services/agents_instructions_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agents_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('AgentsInstructionsService', () {
    test('no-file case loads only root AGENTS.md', () async {
      final rootAgents = File('${tempDir.path}/AGENTS.md');
      await rootAgents.writeAsString('Root project instructions');

      // Subdirectory AGENTS.md should NOT be loaded when no file is open
      final subDir = Directory('${tempDir.path}/lib')..createSync();
      final subAgents = File('${subDir.path}/AGENTS.md');
      await subAgents.writeAsString('Lib instructions');

      final result = await AgentsInstructionsService.load(
        workspaceRoot: tempDir.path,
        openFilePath: null,
      );

      expect(result.files.length, 1);
      expect(result.files.first.relativePath, 'AGENTS.md');
      expect(result.files.first.content, 'Root project instructions');
      expect(result.files.first.truncated, isFalse);
      expect(
        result.toSystemPromptSection(),
        contains('--- PROJECT INSTRUCTIONS (AGENTS.md) ---'),
      );
      expect(result.toSystemPromptSection(), contains('[Source: AGENTS.md]'));
      expect(
        result.toSystemPromptSection(),
        contains('Root project instructions'),
      );
      expect(
        result.toSystemPromptSection(),
        isNot(contains('Lib instructions')),
      );
    });

    test(
      'ancestor ordering loads root down to open file directory in order',
      () async {
        final rootAgents = File('${tempDir.path}/AGENTS.md');
        await rootAgents.writeAsString('Level 0: Root');

        final libDir = Directory('${tempDir.path}/lib')..createSync();
        final libAgents = File('${libDir.path}/AGENTS.md');
        await libAgents.writeAsString('Level 1: Lib');

        final srcDir = Directory('${libDir.path}/src')..createSync();
        final srcAgents = File('${srcDir.path}/AGENTS.md');
        await srcAgents.writeAsString('Level 2: Src');

        // An unrelated directory AGENTS.md that should NOT be loaded
        final testDir = Directory('${tempDir.path}/test')..createSync();
        final testAgents = File('${testDir.path}/AGENTS.md');
        await testAgents.writeAsString(
          'Test instructions (should not be loaded)',
        );

        final targetFile = File('${srcDir.path}/app.dart')
          ..writeAsStringSync('void main() {}');

        final result = await AgentsInstructionsService.load(
          workspaceRoot: tempDir.path,
          openFilePath: targetFile.path,
        );

        expect(result.files.length, 3);
        expect(result.files[0].relativePath, 'AGENTS.md');
        expect(result.files[0].content, 'Level 0: Root');

        expect(result.files[1].relativePath, 'lib/AGENTS.md');
        expect(result.files[1].content, 'Level 1: Lib');

        expect(result.files[2].relativePath, 'lib/src/AGENTS.md');
        expect(result.files[2].content, 'Level 2: Src');

        final prompt = result.toSystemPromptSection();
        expect(prompt, contains('Level 0: Root'));
        expect(prompt, contains('Level 1: Lib'));
        expect(prompt, contains('Level 2: Src'));
        expect(prompt, isNot(contains('Test instructions')));

        // Verify order in prompt
        final idx0 = prompt.indexOf('Level 0: Root');
        final idx1 = prompt.indexOf('Level 1: Lib');
        final idx2 = prompt.indexOf('Level 2: Src');
        expect(idx0 < idx1 && idx1 < idx2, isTrue);
      },
    );

    test('caps total AGENTS.md content at 16 KB', () async {
      // Create a root file with 10 KB
      final largeContent = 'A' * (10 * 1024);
      final rootAgents = File('${tempDir.path}/AGENTS.md');
      await rootAgents.writeAsString(largeContent);

      // Create a sub AGENTS.md with 10 KB (exceeding 16 KB total)
      final libDir = Directory('${tempDir.path}/lib')..createSync();
      final libAgents = File('${libDir.path}/AGENTS.md');
      await libAgents.writeAsString('B' * (10 * 1024));

      final targetFile = File('${libDir.path}/app.dart')
        ..writeAsStringSync('void main() {}');

      final result = await AgentsInstructionsService.load(
        workspaceRoot: tempDir.path,
        openFilePath: targetFile.path,
      );

      expect(result.files.length, 2);
      expect(result.files[0].truncated, isFalse);
      expect(result.files[0].content.length, 10 * 1024);

      // Second file should be truncated to the remaining budget: 16*1024 - 10*1024 = 6*1024
      expect(result.files[1].truncated, isTrue);
      expect(result.files[1].content.length, 6 * 1024);
      expect(result.totalBytes, 16 * 1024);
    });

    test('missing AGENTS.md files are skipped safely', () async {
      // Only lib/AGENTS.md exists, no root AGENTS.md
      final libDir = Directory('${tempDir.path}/lib')..createSync();
      final libAgents = File('${libDir.path}/AGENTS.md');
      await libAgents.writeAsString('Lib instructions only');

      final targetFile = File('${libDir.path}/app.dart')
        ..writeAsStringSync('void main() {}');

      final result = await AgentsInstructionsService.load(
        workspaceRoot: tempDir.path,
        openFilePath: targetFile.path,
      );

      expect(result.files.length, 1);
      expect(result.files.first.relativePath, 'lib/AGENTS.md');
      expect(result.files.first.content, 'Lib instructions only');
    });

    test('rejects symlink escapes and path traversal', () async {
      // 1. Path traversal candidate
      expect(
        () => AgentsInstructionsService.resolveSafePath(
          tempDir.path,
          '../escaped/AGENTS.md',
        ),
        throwsA(isA<FileSystemException>()),
      );

      // 2. Symlink escape outside workspace
      final outsideDir = await Directory.systemTemp.createTemp('outside_');
      try {
        final outsideAgents = File('${outsideDir.path}/SECRET_AGENTS.md');
        await outsideAgents.writeAsString('outside content');

        final symlink = Link('${tempDir.path}/AGENTS.md');
        await symlink.create(outsideAgents.path);

        // Resolving through resolveSafePath must throw FileSystemException
        expect(
          () => AgentsInstructionsService.resolveSafePath(
            tempDir.path,
            'AGENTS.md',
          ),
          throwsA(isA<FileSystemException>()),
        );

        // Load skips or rejects symlink escapes
        final result = await AgentsInstructionsService.load(
          workspaceRoot: tempDir.path,
          openFilePath: null,
        );
        expect(result.files, isEmpty);
      } finally {
        if (outsideDir.existsSync()) {
          await outsideDir.delete(recursive: true);
        }
      }
    });
  });
}

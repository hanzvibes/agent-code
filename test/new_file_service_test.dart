import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:code_harness/services/new_file_service.dart';

void main() {
  late Directory temp;
  late Directory root;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('new_file_service_test_');
    root = Directory(p.join(temp.path, 'project'));
    await root.create();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'creates file successfully including nested parent directories',
    () async {
      final createdPath = await NewFileService.createFile(
        root.path,
        'nested/sub/new_file.dart',
      );
      expect(
        createdPath,
        p.join(
          await root.resolveSymbolicLinks(),
          'nested',
          'sub',
          'new_file.dart',
        ),
      );
      expect(await File(createdPath).exists(), isTrue);
    },
  );

  test('throws FileSystemException when file already exists', () async {
    await NewFileService.createFile(root.path, 'existing.txt');
    await expectLater(
      NewFileService.createFile(root.path, 'existing.txt'),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('already exists'),
        ),
      ),
    );
  });

  test('throws FileSystemException on directory traversal', () async {
    await expectLater(
      NewFileService.validate(root.path, '../outside.txt'),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      NewFileService.validate(root.path, 'sub/../../outside.txt'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'rejects creation through a parent symlink that escapes the workspace',
    () async {
      final outside = Directory(p.join(temp.path, 'outside'))..createSync();
      final link = Link(p.join(root.path, 'escape'));
      await link.create(outside.path);

      await expectLater(
        NewFileService.createFile(root.path, 'escape/secret.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(outside.path, 'secret.txt')).existsSync(), isFalse);
    },
  );

  test(
    'throws FileSystemException on hidden file or directory segments',
    () async {
      await expectLater(
        NewFileService.validate(root.path, '.hidden'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('Hidden segment not allowed'),
          ),
        ),
      );
      await expectLater(
        NewFileService.validate(root.path, 'sub/.secret/foo.txt'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('Hidden segment not allowed'),
          ),
        ),
      );
    },
  );

  test('throws FileSystemException on absolute paths', () async {
    await expectLater(
      NewFileService.validate(root.path, '/etc/passwd'),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('Absolute paths are not allowed'),
        ),
      ),
    );
    await expectLater(
      NewFileService.validate(root.path, 'C:/test.txt'),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('Absolute paths are not allowed'),
        ),
      ),
    );
  });

  test(
    'throws FileSystemException on empty path or ending with slash',
    () async {
      await expectLater(
        NewFileService.validate(root.path, ''),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('cannot be empty'),
          ),
        ),
      );
      await expectLater(
        NewFileService.validate(root.path, 'folder/'),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('must not end with a slash'),
          ),
        ),
      );
    },
  );

  test('throws FileSystemException on _skip directories', () async {
    for (final skipDir in ['node_modules', 'build', '.git', '__pycache__']) {
      await expectLater(
        NewFileService.validate(root.path, '$skipDir/file.txt'),
        throwsA(isA<FileSystemException>()),
      );
    }
  });
}

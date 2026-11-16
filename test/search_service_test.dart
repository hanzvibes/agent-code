import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:code_harness/services/search_service.dart';

void main() {
  late Directory temp;
  late Directory root;
  late SearchService searchService;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('search_service_test_');
    root = Directory(p.join(temp.path, 'project'));
    await root.create();
    searchService = SearchService();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('returns empty list when query is empty', () async {
    final results = await searchService.search(root.path, '');
    expect(results, isEmpty);
  });

  test('finds file by path match', () async {
    final file = File(p.join(root.path, 'my_special_widget.dart'));
    await file.writeAsString('// no target here');

    final results = await searchService.search(root.path, 'special');
    expect(results.length, 1);
    expect(results.first.isPathMatch, isTrue);
    expect(results.first.lineNumber, 0);
    expect(results.first.relativePath, 'my_special_widget.dart');
  });

  test('finds content match with correct line number and preview', () async {
    final file = File(p.join(root.path, 'code.txt'));
    await file.writeAsString(
      'line one\nfind this query string here\nline three',
    );

    final results = await searchService.search(root.path, 'QUERY');
    expect(results.length, 1);
    expect(results.first.isPathMatch, isFalse);
    expect(results.first.lineNumber, 2);
    expect(results.first.linePreview, 'find this query string here');
  });

  test('skips binary files with null bytes', () async {
    final binaryFile = File(p.join(root.path, 'binary.bin'));
    await binaryFile.writeAsBytes([
      65,
      66,
      0,
      67,
      102,
      105,
      110,
      100,
      109,
      101,
    ]); // contains 'findme' after 0

    final results = await searchService.search(root.path, 'findme');
    expect(results, isEmpty);
  });

  test('skips oversized files (>512KB)', () async {
    final bigFile = File(p.join(root.path, 'big.txt'));
    final padding = 'a' * (SearchService.maxPerFileSizeBytes + 10);
    await bigFile.writeAsString('$padding\nsearchtarget\n');

    final results = await searchService.search(root.path, 'searchtarget');
    expect(results, isEmpty);
  });

  test('skips hidden directories', () async {
    final hiddenDir = Directory(p.join(root.path, '.hidden'));
    await hiddenDir.create();
    final file = File(p.join(hiddenDir.path, 'secret.txt'));
    await file.writeAsString('hidden searchtarget');

    final results = await searchService.search(root.path, 'searchtarget');
    expect(results, isEmpty);
  });

  test('does not follow directory symlinks outside the workspace', () async {
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    await File(p.join(outside.path, 'secret.txt')).writeAsString('needle');
    await Link(p.join(root.path, 'linked')).create(outside.path);

    final results = await searchService.search(root.path, 'needle');
    expect(results, isEmpty);
  });

  test('skips _skip directories (e.g. node_modules, build, .git)', () async {
    final nodeModules = Directory(p.join(root.path, 'node_modules'));
    await nodeModules.create();
    final file1 = File(p.join(nodeModules.path, 'lib.js'));
    await file1.writeAsString('searchtarget in node_modules');

    final buildDir = Directory(p.join(root.path, 'build'));
    await buildDir.create();
    final file2 = File(p.join(buildDir.path, 'out.js'));
    await file2.writeAsString('searchtarget in build');

    final results = await searchService.search(root.path, 'searchtarget');
    expect(results, isEmpty);
  });

  test('caps results at 100', () async {
    final file = File(p.join(root.path, 'many.txt'));
    final buffer = StringBuffer();
    for (int i = 0; i < 150; i++) {
      buffer.writeln('needle line $i');
    }
    await file.writeAsString(buffer.toString());

    final results = await searchService.search(root.path, 'needle');
    expect(results.length, SearchService.maxResults);
  });
}

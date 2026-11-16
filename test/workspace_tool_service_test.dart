import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_harness/services/workspace_tool_service.dart';

void main() {
  late Directory tempDir;
  late WorkspaceToolService toolService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tool_service_test_');
    toolService = WorkspaceToolService();

    // Create some sample project structure
    final libDir = Directory('${tempDir.path}/lib')..createSync();
    File('${libDir.path}/main.dart').writeAsStringSync('void main() {}');
    File(
      '${libDir.path}/helper.dart',
    ).writeAsStringSync('// helper code\nString greet() => "hi";');

    // Ignored/hidden directories
    final gitDir = Directory('${tempDir.path}/.git')..createSync();
    File('${gitDir.path}/config').writeAsStringSync('git config');
    final buildDir = Directory('${tempDir.path}/build')..createSync();
    File('${buildDir.path}/output.bin').writeAsStringSync('build output');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects disallowed tools with bounded error', () async {
    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c1',
        name: 'execute_shell',
        arguments: '{"cmd": "rm -rf /"}',
      ),
    );

    expect(result.callId, 'c1');
    expect(result.toolName, 'execute_shell');
    expect(result.output, contains('not permitted'));
    expect(result.summary, contains('Blocked'));
  });

  test('list_project_files lists files and skips ignored dirs', () async {
    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c2',
        name: 'list_project_files',
        arguments: '{}',
      ),
    );

    expect(result.output, contains('lib/main.dart'));
    expect(result.output, contains('lib/helper.dart'));
    expect(result.output, isNot(contains('.git')));
    expect(result.output, isNot(contains('build')));
    expect(result.summary, contains('Listed'));
  });

  test('read_project_file reads valid workspace file', () async {
    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c3',
        name: 'read_project_file',
        arguments: '{"path": "lib/main.dart"}',
      ),
    );

    expect(result.output, 'void main() {}');
    expect(result.summary, contains('Read lib/main.dart'));
  });

  test('read_project_file truncates files larger than 16 KB', () async {
    final bigContent = 'x' * 20000;
    File('${tempDir.path}/lib/big.txt').writeAsStringSync(bigContent);

    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c4',
        name: 'read_project_file',
        arguments: '{"path": "lib/big.txt"}',
      ),
    );

    expect(result.output, contains('[Content truncated to 16 KB'));
    expect(result.summary, contains('Read lib/big.txt (limited to 16 KB)'));
  });

  test('read_project_file rejects traversal outside workspace', () async {
    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c5',
        name: 'read_project_file',
        arguments: '{"path": "../secret.txt"}',
      ),
    );

    expect(result.output, contains('error'));
    expect(result.summary, contains('Blocked'));
  });

  test('read_project_file rejects hidden and ignored paths', () async {
    for (final relativePath in ['.env', '.git/config', 'build/output.bin']) {
      final result = await toolService.execute(
        workspaceRoot: tempDir.path,
        call: ToolCallInfo(
          id: 'blocked-$relativePath',
          name: 'read_project_file',
          arguments: '{"path": "$relativePath"}',
        ),
      );
      expect(result.output, contains('Hidden or ignored paths'));
    }
  });

  test('read_project_file rejects binary files', () async {
    final binFile = File('${tempDir.path}/lib/binary.dat');
    binFile.writeAsBytesSync([0, 1, 2, 3]);

    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c6',
        name: 'read_project_file',
        arguments: '{"path": "lib/binary.dat"}',
      ),
    );

    expect(result.output, contains('Binary file cannot be read'));
    expect(result.summary, contains('Skipped binary file'));
  });

  test('search_project finds matching text', () async {
    final result = await toolService.execute(
      workspaceRoot: tempDir.path,
      call: const ToolCallInfo(
        id: 'c7',
        name: 'search_project',
        arguments: '{"query": "greet"}',
      ),
    );

    expect(result.output, contains('helper.dart'));
    expect(result.output, contains('greet()'));
    expect(result.summary, contains('Searched project for "greet"'));
  });
}

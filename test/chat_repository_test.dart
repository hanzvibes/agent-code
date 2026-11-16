import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:code_harness/models/chat_message.dart';
import 'package:code_harness/repositories/chat_repository.dart';

void main() {
  late Directory tempDir;
  late Box testBox;
  late ChatRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat_repo_test_');
    Hive.init(tempDir.path);
    testBox = await Hive.openBox('test_chat_sessions');
    repository = ChatRepository(box: testBox);
  });

  tearDown(() async {
    await testBox.close();
    await Hive.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('saves and loads user and assistant messages for a workspace', () async {
    final now = DateTime.now();
    final messages = [
      ChatMessage(role: 'user', content: 'Hello', timestamp: now),
      ChatMessage(role: 'assistant', content: 'Hi there', timestamp: now),
    ];

    await repository.save('/workspace/project-a', messages);
    final loaded = await repository.load('/workspace/project-a');

    expect(loaded.length, 2);
    expect(loaded[0].role, 'user');
    expect(loaded[0].content, 'Hello');
    expect(loaded[1].role, 'assistant');
    expect(loaded[1].content, 'Hi there');
  });

  test('never persists system or other roles', () async {
    final now = DateTime.now();
    final messages = [
      ChatMessage(role: 'system', content: 'System prompt', timestamp: now),
      ChatMessage(role: 'user', content: 'Can you help?', timestamp: now),
      ChatMessage(role: 'tool', content: '{"result": 1}', timestamp: now),
      ChatMessage(role: 'assistant', content: 'Sure!', timestamp: now),
    ];

    await repository.save('/workspace/project-a', messages);
    final loaded = await repository.load('/workspace/project-a');

    expect(loaded.length, 2);
    expect(loaded.map((m) => m.role), ['user', 'assistant']);
    expect(loaded.map((m) => m.content), ['Can you help?', 'Sure!']);
  });

  test('caps messages at 100 newest items', () async {
    final now = DateTime.now();
    final messages = List.generate(
      120,
      (i) => ChatMessage(role: 'user', content: 'Message $i', timestamp: now),
    );

    await repository.save('/workspace/project-a', messages);
    final loaded = await repository.load('/workspace/project-a');

    expect(loaded.length, 100);
    expect(loaded.first.content, 'Message 20');
    expect(loaded.last.content, 'Message 119');
  });

  test('caps total characters at 200,000 characters', () async {
    final now = DateTime.now();
    // 3 messages of 80,000 chars = 240,000 chars -> should drop first message so total <= 200,000
    final bigChunk = 'A' * 80000;
    final messages = [
      ChatMessage(role: 'user', content: 'first: $bigChunk', timestamp: now),
      ChatMessage(
        role: 'assistant',
        content: 'second: $bigChunk',
        timestamp: now,
      ),
      ChatMessage(role: 'user', content: 'third: $bigChunk', timestamp: now),
    ];

    await repository.save('/workspace/project-a', messages);
    final loaded = await repository.load('/workspace/project-a');

    expect(loaded.length, 2);
    expect(loaded[0].content.startsWith('second:'), isTrue);
    expect(loaded[1].content.startsWith('third:'), isTrue);
    final total = loaded.fold<int>(0, (sum, m) => sum + m.content.length);
    expect(total <= 200000, isTrue);
  });

  test('workspaces are isolated without cross-contamination', () async {
    final now = DateTime.now();
    await repository.save('/workspace/proj-one', [
      ChatMessage(role: 'user', content: 'One', timestamp: now),
    ]);
    await repository.save('/workspace/proj-two', [
      ChatMessage(role: 'user', content: 'Two', timestamp: now),
    ]);

    final loadOne = await repository.load('/workspace/proj-one');
    final loadTwo = await repository.load('/workspace/proj-two');

    expect(loadOne.single.content, 'One');
    expect(loadTwo.single.content, 'Two');
  });

  test('delete removes stored session', () async {
    final now = DateTime.now();
    await repository.save('/workspace/proj-one', [
      ChatMessage(role: 'user', content: 'One', timestamp: now),
    ]);

    await repository.delete('/workspace/proj-one');
    final loaded = await repository.load('/workspace/proj-one');

    expect(loaded, isEmpty);
  });
}

import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/chat_message.dart';

class ChatRepository {
  static const _boxName = 'chat_sessions';
  static const _maxMessages = 100;
  static const _maxChars = 200000;

  final Box? _overrideBox;

  ChatRepository({Box? box}) : _overrideBox = box;

  Box get _box => _overrideBox ?? Hive.box(_boxName);

  static Future<void> openBox() async {
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.openBox(_boxName);
    }
  }

  Future<List<ChatMessage>> load(String workspacePath) async {
    if (workspacePath.isEmpty) return [];
    final raw = _box.get(workspacePath);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw as String) as List<dynamic>;
      return list.map((e) {
        final m = e as Map<String, dynamic>;
        return ChatMessage(
          role: m['role'] as String,
          content: m['content'] as String,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            m['timestampMs'] as int,
          ),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String workspacePath, List<ChatMessage> messages) async {
    if (workspacePath.isEmpty) return;
    // Filter to user+assistant only, never system, tool, or context snapshots
    var filtered = messages
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList();

    // Apply bounds: newest 100 messages
    while (filtered.length > _maxMessages) {
      filtered.removeAt(0);
    }

    // Apply bounds: newest <= 200k chars
    int totalChars() => filtered.fold(0, (sum, m) => sum + m.content.length);
    while (filtered.isNotEmpty && totalChars() > _maxChars) {
      filtered.removeAt(0);
    }

    final encoded = jsonEncode(
      filtered
          .map(
            (m) => {
              'role': m.role,
              'content': m.content,
              'timestampMs': m.timestamp.millisecondsSinceEpoch,
            },
          )
          .toList(),
    );
    await _box.put(workspacePath, encoded);
  }

  Future<void> delete(String workspacePath) async {
    if (workspacePath.isEmpty) return;
    await _box.delete(workspacePath);
  }
}

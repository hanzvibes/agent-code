import 'package:hive_flutter/hive_flutter.dart';

part 'app_prefs.g.dart';

@HiveType(typeId: 1)
class AppPrefs extends HiveObject {
  @HiveField(0)
  String? activeProfileId;

  @HiveField(1)
  String? lastWorkspacePath;

  @HiveField(2)
  bool isDarkMode;

  @HiveField(3)
  bool useSystemTheme;

  /// Default per-task budget for new agent tasks (Batch 6 — desain
  /// D7). The user can change these in Settings; a task keeps the
  /// limits it started with. Defaults match the design decision
  /// (25 rounds / 60 tool calls).
  @HiveField(4)
  int defaultMaxRounds;

  @HiveField(5)
  int defaultMaxToolCalls;

  AppPrefs({
    this.activeProfileId,
    this.lastWorkspacePath,
    this.isDarkMode = false,
    this.useSystemTheme = true,
    this.defaultMaxRounds = 25,
    this.defaultMaxToolCalls = 60,
  });
}

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

  AppPrefs({
    this.activeProfileId,
    this.lastWorkspacePath,
    this.isDarkMode = false,
    this.useSystemTheme = true,
  });
}

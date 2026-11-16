import 'package:hive_flutter/hive_flutter.dart';

import '../models/app_prefs.dart';

class PrefsRepository {
  static const _boxName = 'app_prefs';
  static const _key = 'prefs';

  Box<AppPrefs> get _box => Hive.box<AppPrefs>(_boxName);

  static Future<void> openBox() async {
    await Hive.openBox<AppPrefs>(_boxName);
  }

  AppPrefs get prefs {
    return _box.get(_key) ?? AppPrefs(useSystemTheme: true, isDarkMode: false);
  }

  Future<void> save(AppPrefs p) async {
    await _box.put(_key, p);
  }
}

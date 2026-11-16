import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/app_prefs.dart';
import '../models/provider_profile.dart';
import '../repositories/prefs_repository.dart';
import '../repositories/profile_repository.dart';

class AppController extends GetxController {
  final PrefsRepository _prefsRepo;
  final ProfileRepository _profileRepo;

  AppController({
    required PrefsRepository prefsRepo,
    required ProfileRepository profileRepo,
  }) : _prefsRepo = prefsRepo,
       _profileRepo = profileRepo;

  late final Rx<AppPrefs> prefs;
  late final RxList<ProviderProfile> profiles;
  final Rx<ProviderProfile?> activeProfile = Rx(null);
  final RxInt selectedTab = 0.obs;

  void selectTab(int index) {
    selectedTab.value = index;
  }

  @override
  void onInit() {
    super.onInit();
    prefs = _prefsRepo.prefs.obs;
    profiles = _profileRepo.getAll().obs;
    _syncActiveProfile();
  }

  void _syncActiveProfile() {
    final id = prefs.value.activeProfileId;
    if (id != null) {
      activeProfile.value = _profileRepo.getById(id);
    } else {
      activeProfile.value = null;
    }
  }

  ThemeMode get themeMode {
    if (prefs.value.useSystemTheme) return ThemeMode.system;
    return prefs.value.isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final p = prefs.value;
    switch (mode) {
      case ThemeMode.system:
        p.useSystemTheme = true;
        break;
      case ThemeMode.light:
        p.useSystemTheme = false;
        p.isDarkMode = false;
        break;
      case ThemeMode.dark:
        p.useSystemTheme = false;
        p.isDarkMode = true;
        break;
    }
    await _prefsRepo.save(p);
    prefs.refresh();
    update();
  }

  Future<void> setActiveProfile(String? id) async {
    final p = prefs.value;
    p.activeProfileId = id;
    await _prefsRepo.save(p);
    prefs.refresh();
    _syncActiveProfile();
  }

  Future<void> addProfile(ProviderProfile profile) async {
    await _profileRepo.save(profile);
    profiles.value = _profileRepo.getAll();
    if (profiles.length == 1) await setActiveProfile(profile.id);
  }

  Future<void> updateProfile(ProviderProfile profile) async {
    await _profileRepo.save(profile);
    profiles.value = _profileRepo.getAll();
    _syncActiveProfile();
  }

  Future<void> deleteProfile(String id) async {
    await _profileRepo.delete(id);
    profiles.value = _profileRepo.getAll();
    if (prefs.value.activeProfileId == id) {
      await setActiveProfile(profiles.isNotEmpty ? profiles.first.id : null);
    }
    _syncActiveProfile();
  }

  Future<void> setLastWorkspace(String? path) async {
    final p = prefs.value;
    p.lastWorkspacePath = path;
    await _prefsRepo.save(p);
    prefs.refresh();
  }

  String? get lastWorkspacePath => prefs.value.lastWorkspacePath;
}

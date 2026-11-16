import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/provider_profile.dart';

class ProfileRepository {
  static const _boxName = 'profiles';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Box<ProviderProfile> get _box => Hive.box<ProviderProfile>(_boxName);

  static Future<void> openBox() async {
    await Hive.openBox<ProviderProfile>(_boxName);
  }

  List<ProviderProfile> getAll() => _box.values.toList();

  ProviderProfile? getById(String id) {
    try {
      return _box.values.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ProviderProfile profile) async {
    await _box.put(profile.id, profile);
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    await _secureStorage.delete(key: _apiKeyStorageKey(id));
  }

  Future<void> saveApiKey(String profileId, String key) async {
    await _secureStorage.write(key: _apiKeyStorageKey(profileId), value: key);
  }

  Future<String?> getApiKey(String profileId) async {
    return _secureStorage.read(key: _apiKeyStorageKey(profileId));
  }

  Future<void> deleteApiKey(String profileId) async {
    await _secureStorage.delete(key: _apiKeyStorageKey(profileId));
  }

  String _apiKeyStorageKey(String profileId) => 'api_key_$profileId';
}

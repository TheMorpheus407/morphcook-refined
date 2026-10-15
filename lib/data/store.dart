import 'dart:convert';
import 'dart:typed_data';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/profile.dart';

/// Persistence boundary: shared_preferences for the profile + small flags,
/// Hive for collections. Swappable for an in-memory store in tests.
abstract class PersistenceStore {
  Future<void> open();

  Profile? loadProfile();
  Future<void> saveProfile(Profile profile);
  bool get onboardingComplete;
  Future<void> setOnboardingComplete(bool value);

  /// Collections are stored as JSON strings under a key.
  String? getCollection(String key);
  Future<void> putCollection(String key, String jsonText);
  Future<void> removeCollection(String key);
  Future<void> putCollections(Map<String, String> collections);
  Map<String, Uint8List> loadRecipeImageBytes();
  Future<void> putRecipeImageBytes(String recipeId, Uint8List bytes);
  Future<void> putRecipeImageBytesBatch(Map<String, Uint8List> images);
  Future<void> removeRecipeImageBytes(String recipeId);
  Future<void> removeRecipeImageBytesBatch(Iterable<String> recipeIds);
  Future<void> clearRecipeImageBytes();
  Future<void> clearAll();
}

class HiveStore implements PersistenceStore {
  late SharedPreferences _prefs;
  late Box<String> _box;
  late Box<Uint8List> _imageBox;

  @override
  Future<void> open() async {
    _prefs = await SharedPreferences.getInstance();
    await Hive.initFlutter();
    _box = await Hive.openBox<String>('morphcook');
    _imageBox = await Hive.openBox<Uint8List>('morphcook_recipe_images');
  }

  @override
  Profile? loadProfile() {
    final raw = _prefs.getString('profile');
    if (raw == null) return null;
    try {
      return Profile.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveProfile(Profile profile) async {
    if (!await _prefs.setString('profile', json.encode(profile.toJson()))) {
      throw StateError('Failed to save profile');
    }
  }

  @override
  bool get onboardingComplete => _prefs.getBool('onboarding_complete') ?? false;

  @override
  Future<void> setOnboardingComplete(bool value) async {
    if (!await _prefs.setBool('onboarding_complete', value)) {
      throw StateError('Failed to save onboarding status');
    }
  }

  @override
  String? getCollection(String key) => _box.get(key);

  @override
  Future<void> putCollection(String key, String jsonText) async {
    await _box.put(key, jsonText);
  }

  @override
  Future<void> removeCollection(String key) => _box.delete(key);

  @override
  Future<void> putCollections(Map<String, String> collections) =>
      _box.putAll(collections);

  @override
  Map<String, Uint8List> loadRecipeImageBytes() => {
    for (final key in _imageBox.keys.whereType<String>())
      if (_imageBox.get(key) case final bytes?) key: Uint8List.fromList(bytes),
  };

  @override
  Future<void> putRecipeImageBytes(String recipeId, Uint8List bytes) async {
    await _imageBox.put(recipeId, Uint8List.fromList(bytes));
  }

  @override
  Future<void> putRecipeImageBytesBatch(Map<String, Uint8List> images) =>
      _imageBox.putAll({
        for (final entry in images.entries)
          entry.key: Uint8List.fromList(entry.value),
      });

  @override
  Future<void> removeRecipeImageBytes(String recipeId) async {
    await _imageBox.delete(recipeId);
  }

  @override
  Future<void> removeRecipeImageBytesBatch(Iterable<String> recipeIds) =>
      _imageBox.deleteAll(recipeIds);

  @override
  Future<void> clearRecipeImageBytes() => _imageBox.clear();

  @override
  Future<void> clearAll() async {
    final previous = {for (final key in _prefs.getKeys()) key: _prefs.get(key)};
    try {
      if (!await _prefs.clear()) {
        throw StateError('Failed to clear preferences');
      }
    } catch (_) {
      // A failed clear can already have changed both the Dart and native maps.
      // Restore each value independently; recovery must preserve the clear error.
      for (final entry in previous.entries) {
        try {
          await switch (entry.value) {
            final bool value => _prefs.setBool(entry.key, value),
            final int value => _prefs.setInt(entry.key, value),
            final double value => _prefs.setDouble(entry.key, value),
            final String value => _prefs.setString(entry.key, value),
            final List value => _prefs.setStringList(
              entry.key,
              value.cast<String>(),
            ),
            _ => throw StateError('Unsupported preference value'),
          };
        } catch (_) {}
      }
      rethrow;
    }
    await _box.clear();
    await _imageBox.clear();
  }
}

/// In-memory store for tests and previews.
class MemoryStore implements PersistenceStore {
  Profile? _profile;
  bool _onboarded = false;
  final Map<String, String> _collections = {};
  final Map<String, Uint8List> _recipeImages = {};

  @override
  Future<void> open() async {}

  @override
  Profile? loadProfile() => _profile;

  @override
  Future<void> saveProfile(Profile profile) async => _profile = profile;

  @override
  bool get onboardingComplete => _onboarded;

  @override
  Future<void> setOnboardingComplete(bool value) async => _onboarded = value;

  @override
  String? getCollection(String key) => _collections[key];

  @override
  Future<void> putCollection(String key, String jsonText) async {
    _collections[key] = jsonText;
  }

  @override
  Future<void> removeCollection(String key) async {
    _collections.remove(key);
  }

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    _collections.addAll(collections);
  }

  @override
  Map<String, Uint8List> loadRecipeImageBytes() => {
    for (final entry in _recipeImages.entries)
      entry.key: Uint8List.fromList(entry.value),
  };

  @override
  Future<void> putRecipeImageBytes(String recipeId, Uint8List bytes) async {
    _recipeImages[recipeId] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> putRecipeImageBytesBatch(Map<String, Uint8List> images) async {
    for (final entry in images.entries) {
      _recipeImages[entry.key] = Uint8List.fromList(entry.value);
    }
  }

  @override
  Future<void> removeRecipeImageBytes(String recipeId) async {
    _recipeImages.remove(recipeId);
  }

  @override
  Future<void> removeRecipeImageBytesBatch(Iterable<String> recipeIds) async {
    _recipeImages.removeWhere((key, _) => recipeIds.contains(key));
  }

  @override
  Future<void> clearRecipeImageBytes() async => _recipeImages.clear();

  @override
  Future<void> clearAll() async {
    _profile = null;
    _onboarded = false;
    _collections.clear();
    _recipeImages.clear();
  }
}

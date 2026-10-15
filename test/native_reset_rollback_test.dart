import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/models/profile.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'helpers.dart';

class _TestPath extends PathProviderPlatform {
  _TestPath(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  Future<void> Function()? afterClear;

  @override
  Future<bool> clear() async {
    final result = await super.clear();
    final callback = afterClear;
    afterClear = null;
    await callback?.call();
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failingBox in ['morphcook', 'morphcook_recipe_images']) {
    for (final timing in ['before reset', 'after preference clear']) {
      test('failed native reset: $failingBox closed $timing', () async {
        final directory = await Directory.systemTemp.createTemp(
          'morphcook-reset-',
        );
        final oldPath = PathProviderPlatform.instance;
        final oldPreferences = SharedPreferencesStorePlatform.instance;
        PathProviderPlatform.instance = _TestPath(directory.path);
        SharedPreferences.setMockInitialValues({});
        final preferences = _Preferences();
        SharedPreferencesStorePlatform.instance = preferences;
        final store = HiveStore();
        final state = AppState(store: store, corpus: await loadRealCorpus());
        addTearDown(() async {
          state.dispose();
          await Hive.close();
          PathProviderPlatform.instance = oldPath;
          SharedPreferences.setMockInitialValues({});
          SharedPreferencesStorePlatform.instance = oldPreferences;
          await directory.delete(recursive: true);
        });
        await state.load();
        const profile = Profile(name: 'Before', avoidFlags: {'dairy'});
        await state.completeOnboarding(profile);
        final recipe = PersonalRecipe.create(
          title: 'Family recipe',
          timeMinutes: 10,
          servings: 1,
          ingredients: [
            PersonalRecipeIngredient(name: 'rice', qty: 100, unit: 'g'),
          ],
          steps: [PersonalRecipeStep(text: 'Cook it.')],
        );
        await state.savePersonalRecipe(recipe);
        await state.setRecipeImage(recipe.id, testPngBytes());
        await state.toggleSaved('doener-vegan');
        await store.putCollection('future_collection', '{"keep":"raw data"}');
        final before = state.buildBackup().toJson(DateTime.utc(2026));
        final native = await preferences.getAll();
        final collections = Hive.box<String>('morphcook').toMap();
        final photos = store.loadRecipeImageBytes();
        var notifications = 0;
        state.addListener(() => notifications++);
        Future<void> closeBox() => failingBox == 'morphcook'
            ? Hive.box<String>(failingBox).close()
            : Hive.box<Uint8List>(failingBox).close();
        if (timing == 'before reset') {
          await closeBox();
        } else {
          // All snapshots remain readable; fail the actual clear after prefs
          // have been erased, rather than only testing a preflight failure.
          preferences.afterClear = closeBox;
        }
        await expectLater(state.resetEverything(), throwsA(isA<HiveError>()));
        expect(notifications, 0);
        expect(state.onboarded, isTrue);
        expect(state.buildBackup().toJson(DateTime.utc(2026)), before);
        expect(await preferences.getAll(), native);

        // Drop the Dart preference cache and reopen the real Hive boxes.
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesStorePlatform.instance = preferences;
        final reloaded = AppState(store: HiveStore(), corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.onboarded, isTrue);
        expect(reloaded.buildBackup().toJson(DateTime.utc(2026)), before);
        expect(Hive.box<String>('morphcook').toMap(), collections);
        expect(reloaded.store.loadRecipeImageBytes(), photos);

        await reloaded.resetEverything();
        expect(reloaded.onboarded, isFalse);
        expect(reloaded.personalRecipes, isEmpty);
        expect(await preferences.getAll(), isEmpty);
        expect(Hive.box<String>('morphcook').isEmpty, isTrue);
        expect(reloaded.store.loadRecipeImageBytes(), isEmpty);
      });
    }
  }
}

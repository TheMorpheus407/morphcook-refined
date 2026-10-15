import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';

import 'helpers.dart';

class _RecoveryFailureStore extends MemoryStore {
  bool armed = false;
  bool recovering = false;
  String? failedRecovery;
  final recovered = <String>[];
  final importError = StateError('onboarding confirmation failed');

  void _recover(String operation) {
    if (!recovering) return;
    recovered.add(operation);
    if (failedRecovery == operation) throw StateError('failed $operation');
  }

  @override
  Future<void> setOnboardingComplete(bool value) async {
    if (armed) {
      armed = false;
      recovering = true;
      // The native write may succeed before its confirmation fails.
      await super.setOnboardingComplete(value);
      throw importError;
    }
    _recover('onboarding');
    await super.setOnboardingComplete(value);
  }

  @override
  Future<void> putRecipeImageBytesBatch(Map<String, Uint8List> images) async {
    _recover('images');
    await super.putRecipeImageBytesBatch(images);
  }

  @override
  Future<void> removeRecipeImageBytesBatch(Iterable<String> ids) async {
    _recover('cleanup');
    await super.removeRecipeImageBytesBatch(ids);
  }

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    _recover('collections');
    await super.putCollections(collections);
  }

  @override
  Future<void> saveProfile(Profile profile) async {
    _recover('profile');
    await super.saveProfile(profile);
  }
}

void main() {
  for (final failed in ['images', 'cleanup', 'collections', 'profile']) {
    test('backup recovery continues after failed $failed rollback', () async {
      final store = _RecoveryFailureStore();
      final state = AppState(store: store, corpus: await loadRealCorpus());
      addTearDown(state.dispose);
      await state.load();
      const original = Profile(name: 'Before', avoidFlags: {'dairy'});
      await state.updateProfile(original);
      await state.toggleSaved('doener-vegan');
      await state.setRecipeImage('doener-vegan', testPngBytes());
      final before = state.buildBackup().toJson(DateTime.utc(2026));
      final incoming = BackupData(
        profile: const Profile(name: 'Incoming'),
        saved: const [],
        mealPlan: const {},
        history: const [],
        recipeImages: [
          RecipeImage(
            recipeId: 'pad-thai-vegan',
            bytes: testPngBytes(),
            updatedAt: DateTime.utc(2026),
          ),
        ],
      );
      store.failedRecovery = failed;
      store.armed = true;
      await expectLater(
        state.applyBackup(incoming, merge: false),
        throwsA(same(store.importError)),
      );
      expect(store.recovered, [
        'images',
        'cleanup',
        'collections',
        'profile',
        'onboarding',
      ]);
      expect(state.buildBackup().toJson(DateTime.utc(2026)), before);
      expect(state.onboarded, isFalse);
      final reloaded = AppState(store: store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.onboarded, isFalse);
      if (failed != 'profile') {
        expect(reloaded.profile.toJson(), original.toJson());
      }
      if (failed != 'collections') {
        expect(reloaded.isSaved('doener-vegan'), isTrue);
        expect(reloaded.recipeImageFor('doener-vegan'), isNotNull);
      }
      if (failed != 'cleanup') {
        expect(
          store.loadRecipeImageBytes().containsKey('pad-thai-vegan'),
          isFalse,
        );
      }

      // Recovery failure must not poison the mutation queue or a later retry.
      store.recovering = false;
      store.failedRecovery = null;
      await state.applyBackup(incoming, merge: false);
      expect(state.profile.name, 'Incoming');
      expect(state.saved, isEmpty);
      expect(state.onboarded, isTrue);
      expect(state.recipeImageFor('pad-thai-vegan'), isNotNull);
    });
  }
}

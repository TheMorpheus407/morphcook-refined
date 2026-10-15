import 'dart:convert';
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
  int? imageWritesBeforeFailure;
  int? cleanupDeletesBeforeFailure;
  bool failImageRead = false;
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
    if (imageWritesBeforeFailure case final count? when recovering) {
      recovered.add('images');
      for (final entry in images.entries.take(count)) {
        await super.putRecipeImageBytes(entry.key, entry.value);
      }
      throw StateError('image rollback confirmation failed');
    }
    _recover('images');
    await super.putRecipeImageBytesBatch(images);
  }

  @override
  Future<void> removeRecipeImageBytesBatch(Iterable<String> ids) async {
    if (cleanupDeletesBeforeFailure case final count? when recovering) {
      recovered.add('cleanup');
      await super.removeRecipeImageBytesBatch(ids.take(count));
      throw StateError('cleanup rollback confirmation failed');
    }
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

  @override
  Map<String, Uint8List> loadRecipeImageBytes() {
    if (recovering && failImageRead) {
      throw StateError('image store unavailable');
    }
    return super.loadRecipeImageBytes();
  }
}

RecipeImageCredit _credit(String author) => RecipeImageCredit.tryCreate(
  title: '$author photo',
  author: author,
  license: 'CC BY 4.0',
  provider: 'Wikimedia Commons',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:$author.png',
)!;

void _expectPhoto(AppState state, RecipeImage expected) {
  final actual = state.recipeImageFor(expected.recipeId)!;
  expect(actual.bytes, orderedEquals(expected.bytes));
  expect(actual.credit, expected.credit);
  expect(actual.updatedAt, expected.updatedAt);
  expect(
    state
        .buildBackup()
        .recipeImages
        .singleWhere((image) => image.recipeId == expected.recipeId)
        .toBackupJson(),
    expected.toBackupJson(),
  );
}

void main() {
  for (final merge in [false, true]) {
    for (final legacy in [false, true]) {
      for (final count in [0, 1, 2]) {
        test('photo rollback preserves matching credits: merge=$merge '
            'legacy=$legacy restored=$count', () async {
          final store = _RecoveryFailureStore();
          final state = AppState(store: store, corpus: await loadRealCorpus());
          addTearDown(state.dispose);
          await state.load();
          const original = Profile(name: 'Before', avoidFlags: {'dairy'});
          await state.updateProfile(original);
          await state.toggleSaved('doener-vegan');
          for (final id in ['doener-vegan', 'pad-thai-vegan']) {
            await state.setRecipeImage(
              id,
              testPngBytes(),
              updatedAt: DateTime.utc(2025),
              credit: _credit('Old'),
            );
          }
          final oldPhotos = state.recipeImages;
          if (legacy) {
            await store.putCollections({
              'recipe_image_metadata': jsonEncode([
                for (final image in oldPhotos)
                  image.metadata.toJson()..remove('credit_bytes_digest'),
              ]),
            });
          }
          final before = state.buildBackup().toJson(DateTime.utc(2026));
          final incoming = BackupData(
            profile: const Profile(name: 'Incoming'),
            saved: const [],
            mealPlan: const {},
            history: const [],
            recipeImages: [
              for (final image in oldPhotos)
                RecipeImage(
                  recipeId: image.recipeId,
                  bytes: [...testPngBytes(), 0],
                  updatedAt: DateTime.utc(2026),
                  credit: _credit('New'),
                ),
            ],
          );
          store.imageWritesBeforeFailure = count;
          store.armed = true;
          await expectLater(
            state.applyBackup(incoming, merge: merge),
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
          final reloaded = AppState(store: store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          expect(reloaded.profile.toJson(), original.toJson());
          expect(reloaded.isSaved('doener-vegan'), isTrue);
          expect(reloaded.onboarded, isFalse);
          for (var i = 0; i < oldPhotos.length; i++) {
            _expectPhoto(
              reloaded,
              i < count ? oldPhotos[i] : incoming.recipeImages[i],
            );
          }
          store.recovering = false;
          store.imageWritesBeforeFailure = null;
          await state.applyBackup(incoming, merge: merge);
          for (final image in incoming.recipeImages) {
            _expectPhoto(state, image);
          }
        });
      }
    }
    for (final deleted in [0, 1]) {
      test('failed photo cleanup retains surviving credits: merge=$merge '
          'deleted=$deleted', () async {
        final store = _RecoveryFailureStore();
        final state = AppState(store: store, corpus: await loadRealCorpus());
        addTearDown(state.dispose);
        await state.load();
        await state.toggleSaved('doener-vegan');
        final incoming = BackupData(
          profile: const Profile(name: 'Incoming'),
          saved: const [],
          mealPlan: const {},
          history: const [],
          recipeImages: [
            for (final id in ['doener-vegan', 'pad-thai-vegan'])
              RecipeImage(
                recipeId: id,
                bytes: testPngBytes(),
                updatedAt: DateTime.utc(2026),
                credit: _credit('New'),
              ),
          ],
        );
        final before = state.buildBackup().toJson(DateTime.utc(2026));
        store.cleanupDeletesBeforeFailure = deleted;
        store.armed = true;
        await expectLater(
          state.applyBackup(incoming, merge: merge),
          throwsA(same(store.importError)),
        );
        expect(state.buildBackup().toJson(DateTime.utc(2026)), before);
        final reloaded = AppState(store: store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.isSaved('doener-vegan'), isTrue);
        expect(reloaded.profile.name, isEmpty);
        expect(reloaded.onboarded, isFalse);
        expect(reloaded.recipeImages.length, 2 - deleted);
        for (final image in incoming.recipeImages.skip(deleted)) {
          _expectPhoto(reloaded, image);
        }
      });
    }
  }

  test('unavailable photo reads do not block independent recovery', () async {
    final store = _RecoveryFailureStore();
    final state = AppState(store: store, corpus: await loadRealCorpus());
    addTearDown(state.dispose);
    await state.load();
    const original = Profile(name: 'Before', avoidFlags: {'dairy'});
    await state.updateProfile(original);
    await state.toggleSaved('doener-vegan');
    await state.setRecipeImage(
      'doener-vegan',
      testPngBytes(),
      credit: _credit('Old'),
    );
    final incomingPhoto = RecipeImage(
      recipeId: 'doener-vegan',
      bytes: [...testPngBytes(), 0],
      updatedAt: DateTime.utc(2026),
      credit: _credit('New'),
    );
    store.failedRecovery = 'images';
    store.failImageRead = true;
    store.armed = true;
    await expectLater(
      state.applyBackup(
        BackupData(
          profile: const Profile(name: 'Incoming'),
          saved: const [],
          mealPlan: const {},
          history: const [],
          recipeImages: [incomingPhoto],
        ),
        merge: false,
      ),
      throwsA(same(store.importError)),
    );
    store.failImageRead = false;
    final reloaded = AppState(store: store, corpus: state.corpus);
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.profile.toJson(), original.toJson());
    expect(reloaded.isSaved('doener-vegan'), isTrue);
    expect(reloaded.onboarded, isFalse);
    _expectPhoto(reloaded, incomingPhoto);
  });

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

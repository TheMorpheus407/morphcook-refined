import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';
import 'package:morphcook/models/recipe_share.dart';

import 'helpers.dart';

class PausedPhotoStore extends MemoryStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool failFirst = false;

  @override
  Future<void> putRecipeImageBytes(String id, Uint8List bytes) async {
    await super.putRecipeImageBytes(id, bytes);
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
      if (failFirst) throw StateError('photo write failed');
    }
  }
}

RecipeImageCredit credit(String author) => RecipeImageCredit.tryCreate(
  title: '$author photo',
  author: author,
  license: 'CC BY 4.0',
  provider: 'Wikimedia Commons',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:$author.png',
)!;

PersonalRecipe personalRecipe(int number) => PersonalRecipe(
  id: 'personal-${number.toRadixString(16).padLeft(32, '0')}',
  title: 'Soup $number',
  timeMinutes: 10,
  servings: 1,
  ingredients: [PersonalRecipeIngredient(name: 'water', qty: 1, unit: 'l')],
  steps: [PersonalRecipeStep(text: 'Simmer.')],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  for (final fails in [false, true]) {
    test(
      'overlapping photo writes preserve later save: fails=$fails',
      () async {
        final store = PausedPhotoStore()..failFirst = fails;
        final corpus = await loadRealCorpus();
        final state = AppState(store: store, corpus: corpus);
        await state.load();
        final first = state.setRecipeImage(
          'doener-vegan',
          testPngBytes(),
          credit: credit('Ann'),
        );
        final firstResult = fails
            ? expectLater(first, throwsStateError)
            : first;
        await store.entered.future;
        final second = state.setRecipeImage(
          'doener-classic',
          testPngBytes(),
          credit: credit('Bob'),
        );
        // Let the second call reach its asynchronous writes on the old code.
        await Future<void>.delayed(Duration.zero);
        store.release.complete();
        await firstResult;
        await second;

        final recovered = AppState(store: store, corpus: corpus);
        await recovered.load();
        for (final snapshot in [state, recovered]) {
          expect(
            snapshot.recipeImageFor('doener-vegan')?.credit,
            fails ? isNull : credit('Ann'),
          );
          expect(
            snapshot.recipeImageFor('doener-classic')?.credit,
            credit('Bob'),
          );
          expect(
            snapshot.buildBackup().recipeImages.map((image) => image.recipeId),
            unorderedEquals([if (!fails) 'doener-vegan', 'doener-classic']),
          );
        }
        expect(
          store.loadRecipeImageBytes().keys,
          unorderedEquals([if (!fails) 'doener-vegan', 'doener-classic']),
        );
      },
    );
  }

  test('removal requested during a save removes its completed photo', () async {
    final store = PausedPhotoStore();
    final corpus = await loadRealCorpus();
    final state = AppState(store: store, corpus: corpus);
    await state.load();
    final saving = state.setRecipeImage('doener-vegan', testPngBytes());
    await store.entered.future;
    final removing = state.removeRecipeImage('doener-vegan');
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await saving;
    await removing;
    final recovered = AppState(store: store, corpus: corpus);
    await recovered.load();
    expect(state.recipeImages, isEmpty);
    expect(recovered.recipeImages, isEmpty);
    expect(store.loadRecipeImageBytes(), isEmpty);
  });

  for (final operation in ['import', 'merge', 'replace', 'delete', 'reset']) {
    for (final fails in [false, true]) {
      test(
        '$operation waits for a photo save and rollback: fails=$fails',
        () async {
          final store = PausedPhotoStore()..failFirst = fails;
          final corpus = await loadRealCorpus();
          final state = AppState(store: store, corpus: corpus);
          addTearDown(state.dispose);
          await state.load();
          final local = personalRecipe(1);
          final incoming = personalRecipe(2);
          await state.savePersonalRecipe(local);
          final incomingImage = RecipeImage(
            recipeId: incoming.id,
            bytes: testPngBytes(),
            updatedAt: DateTime.utc(2026),
            credit: credit('Bob'),
          );
          const incomingProfile = Profile(lang: 'de');
          final backup = BackupData(
            profile: incomingProfile,
            saved: const [],
            mealPlan: const {},
            history: const [],
            personalRecipes: [incoming],
            recipeImages: [incomingImage],
          );
          final saving = state.setRecipeImage(
            local.id,
            testPngBytes(),
            credit: credit('Ann'),
          );
          final saveResult = fails
              ? expectLater(saving, throwsStateError)
              : saving;
          await store.entered.future;
          var completed = false;
          final next = switch (operation) {
            'import' => state.importSharedRecipes(
              RecipeShareData(recipes: [incoming], images: [incomingImage]),
            ),
            'merge' => state.applyBackup(backup, merge: true),
            'replace' => state.applyBackup(backup, merge: false),
            'delete' => state.deletePersonalRecipe(local.id),
            'reset' => state.resetEverything(),
            _ => throw StateError('unknown operation'),
          };
          final nextResult = next.then((_) => completed = true);
          // Give an independent writer time to persist and publish its snapshot.
          await Future<void>.delayed(Duration.zero);
          final completedBeforeRelease = completed;
          final recipesBeforeRelease = state.personalRecipes
              .map((r) => r.id)
              .toList();
          store.release.complete();
          await saveResult;
          await nextResult;

          expect(completedBeforeRelease, isFalse);
          expect(recipesBeforeRelease, [local.id]);
          final keepsLocal = operation == 'import' || operation == 'merge';
          final addsIncoming = keepsLocal || operation == 'replace';
          final expectedImages = <String, RecipeImageCredit>{
            if (keepsLocal && !fails) local.id: credit('Ann'),
            if (addsIncoming) incoming.id: credit('Bob'),
          };
          final recovered = AppState(store: store, corpus: corpus);
          addTearDown(recovered.dispose);
          await recovered.load();
          for (final snapshot in [state, recovered]) {
            expect(
              snapshot.personalRecipes.map((r) => r.id),
              unorderedEquals([
                if (keepsLocal) local.id,
                if (addsIncoming) incoming.id,
              ]),
            );
            expect(
              snapshot.recipeImages.map((i) => i.recipeId),
              unorderedEquals(expectedImages.keys),
            );
            for (final image in snapshot.recipeImages) {
              expect(image.bytes, testPngBytes());
              expect(image.credit, expectedImages[image.recipeId]);
            }
            expect(
              snapshot.buildBackup().recipeImages.map((i) => i.toBackupJson()),
              snapshot.recipeImages.map((i) => i.toBackupJson()),
            );
            expect(
              snapshot.profile.lang,
              operation == 'merge' || operation == 'replace' ? 'de' : 'en',
            );
            expect(
              snapshot.onboarded,
              operation == 'merge' || operation == 'replace',
            );
          }
          expect(
            store.loadRecipeImageBytes().keys,
            unorderedEquals(expectedImages.keys),
          );
          for (final bytes in store.loadRecipeImageBytes().values) {
            expect(bytes, testPngBytes());
          }
        },
      );
    }
  }
}

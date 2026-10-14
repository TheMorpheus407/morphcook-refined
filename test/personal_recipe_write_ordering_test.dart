import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/logic/cook/cook_controller.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';
import 'package:morphcook/models/recipe_share.dart';

import 'helpers.dart';
import 'recipe_photo_write_ordering_test.dart' show personalRecipe, credit;

class _PausedPersonalStore extends MemoryStore {
  bool pauseNext = true;
  bool failPaused = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    if (pauseNext && collections.containsKey('personal_recipes')) {
      pauseNext = false;
      entered.complete();
      await release.future;
      if (failPaused) throw StateError('personal recipe write failed');
    }
    await super.putCollections(collections);
  }
}

class _PausedCollectionStore extends MemoryStore {
  final String key;
  final bool afterPersistence;
  final entered = Completer<void>();
  final release = Completer<void>();

  _PausedCollectionStore(this.key, {required this.afterPersistence});

  @override
  Future<void> putCollection(String key, String jsonText) async {
    if (key == this.key && !entered.isCompleted) {
      if (afterPersistence) await super.putCollection(key, jsonText);
      entered.complete();
      await release.future;
      if (afterPersistence) return;
    }
    await super.putCollection(key, jsonText);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final editing in [false, true]) {
    for (final initiallySaved in [false, true]) {
      for (final fails in [false, true]) {
        test(
          'bookmark survives personal save: edit=$editing saved=$initiallySaved failure=$fails',
          () async {
            final store = _PausedPersonalStore()..pauseNext = false;
            final state = AppState(
              store: store,
              corpus: await loadRealCorpus(),
            );
            await state.load();
            addTearDown(state.dispose);
            final local = personalRecipe(1);
            if (editing) await state.savePersonalRecipe(local);
            if (initiallySaved) await state.toggleSaved('doener-vegan');
            store
              ..pauseNext = true
              ..failPaused = fails;
            final saving = state.savePersonalRecipe(
              local.copyWith(title: 'Edited soup'),
            );
            final checkedSaving = fails
                ? expectLater(saving, throwsStateError)
                : saving;
            await store.entered.future;
            var completed = false;
            final toggling = state
                .toggleSaved('doener-vegan')
                .then((_) => completed = true);
            await Future<void>.delayed(Duration.zero);
            final finishedBeforeRelease = completed;
            store.release.complete();
            await checkedSaving;
            await toggling;
            final reloaded = AppState(store: store, corpus: state.corpus);
            await reloaded.load();
            addTearDown(reloaded.dispose);
            for (final snapshot in [state, reloaded]) {
              expect(snapshot.isSaved('doener-vegan'), !initiallySaved);
              expect(snapshot.isSaved(local.id), editing || !fails);
            }
            expect(finishedBeforeRelease, isFalse);
          },
        );
      }
    }
  }

  for (final afterPersistence in [false, true]) {
    test(
      'personal creation waits for bookmark: afterPersistence=$afterPersistence',
      () async {
        final store = _PausedCollectionStore(
          'saved',
          afterPersistence: afterPersistence,
        );
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        addTearDown(state.dispose);
        final toggling = state.toggleSaved('doener-vegan');
        await store.entered.future;
        var completed = false;
        final local = personalRecipe(1);
        final saving = state
            .savePersonalRecipe(local)
            .then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        final finishedBeforeRelease = completed;
        store.release.complete();
        await toggling;
        await saving;
        final reloaded = AppState(store: store, corpus: state.corpus);
        await reloaded.load();
        addTearDown(reloaded.dispose);
        for (final snapshot in [state, reloaded]) {
          expect(snapshot.isSaved('doener-vegan'), isTrue);
          expect(snapshot.isSaved(local.id), isTrue);
        }
        expect(finishedBeforeRelease, isFalse);
      },
    );

    test(
      'personal edit clears pending progress: afterPersistence=$afterPersistence',
      () async {
        final store = _PausedCollectionStore(
          'cook_progress',
          afterPersistence: afterPersistence,
        );
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        addTearDown(state.dispose);
        final local = personalRecipe(1);
        await state.savePersonalRecipe(local);
        final progressing = state.persistCookProgress(
          CookProgress(recipeId: local.id, stepIndex: 0, servings: 1),
        );
        await store.entered.future;
        var completed = false;
        final saving = state
            .savePersonalRecipe(local.copyWith(title: 'Edited soup'))
            .then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        final finishedBeforeRelease = completed;
        store.release.complete();
        await progressing;
        await saving;
        final reloaded = AppState(store: store, corpus: state.corpus);
        await reloaded.load();
        addTearDown(reloaded.dispose);
        for (final snapshot in [state, reloaded]) {
          expect(snapshot.personalRecipeById(local.id)?.title, 'Edited soup');
          expect(snapshot.cookProgress, isNull);
        }
        expect(finishedBeforeRelease, isFalse);
      },
    );
  }

  for (final fails in [false, true]) {
    test(
      'new cooking session survives personal edit: failure=$fails',
      () async {
        final store = _PausedPersonalStore()..pauseNext = false;
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        addTearDown(state.dispose);
        final local = personalRecipe(1);
        await state.savePersonalRecipe(local);
        await state.persistCookProgress(
          CookProgress(recipeId: local.id, stepIndex: 0, servings: 1),
        );
        store
          ..pauseNext = true
          ..failPaused = fails;
        final saving = state.savePersonalRecipe(
          local.copyWith(title: 'Edited soup'),
        );
        final checkedSaving = fails
            ? expectLater(saving, throwsStateError)
            : saving;
        await store.entered.future;
        var completed = false;
        final progressing = state
            .persistCookProgress(
              CookProgress(recipeId: 'doener-vegan', stepIndex: 1, servings: 2),
            )
            .then((_) => completed = true);
        await Future<void>.delayed(Duration.zero);
        final finishedBeforeRelease = completed;
        store.release.complete();
        await checkedSaving;
        await progressing;
        final reloaded = AppState(store: store, corpus: state.corpus);
        await reloaded.load();
        addTearDown(reloaded.dispose);
        for (final snapshot in [state, reloaded]) {
          expect(snapshot.cookProgress?.recipeId, 'doener-vegan');
          expect(snapshot.cookProgress?.stepIndex, 1);
          expect(snapshot.cookProgress?.servings, 2);
        }
        expect(finishedBeforeRelease, isFalse);
      },
    );
  }

  for (final operation in [
    'import',
    'save',
    'merge',
    'replace',
    'delete',
    'reset',
  ]) {
    for (final fails in [false, true]) {
      test(
        'personal save then $operation stays ordered: failure=$fails',
        () async {
          final store = _PausedPersonalStore()..failPaused = fails;
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          addTearDown(state.dispose);
          final local = personalRecipe(1);
          final incoming = personalRecipe(2);
          final image = RecipeImage(
            recipeId: incoming.id,
            bytes: testPngBytes(),
            updatedAt: DateTime.utc(2026),
            credit: credit('Ann'),
          );
          final backup = BackupData(
            profile: const Profile(),
            saved: const [],
            mealPlan: const {},
            history: const [],
            personalRecipes: [incoming],
            recipeImages: [image],
          );
          final saving = state.savePersonalRecipe(local);
          final checkedSaving = fails
              ? expectLater(saving, throwsStateError)
              : saving;
          addTearDown(() async {
            if (!store.release.isCompleted) store.release.complete();
            await checkedSaving;
          });
          await store.entered.future;
          var completed = false;
          final next = switch (operation) {
            'import' =>
              state
                  .importSharedRecipes(
                    RecipeShareData(recipes: [incoming], images: [image]),
                  )
                  .then((count) => expect(count, 1)),
            'save' => state.savePersonalRecipe(incoming),
            'merge' => state.applyBackup(backup, merge: true),
            'replace' => state.applyBackup(backup, merge: false),
            'delete' => state.deletePersonalRecipe(local.id),
            'reset' => state.resetEverything(),
            _ => throw StateError(operation),
          };
          final checkedNext = next.then((_) => completed = true);
          await Future<void>.delayed(Duration.zero);
          final finishedBeforeRelease = completed;
          store.release.complete();
          await checkedSaving;
          await checkedNext;
          expect(finishedBeforeRelease, isFalse);

          final keepsLocal =
              !fails && ['import', 'save', 'merge'].contains(operation);
          final addsIncoming = !['reset', 'delete'].contains(operation);
          final hasImage = ['import', 'merge', 'replace'].contains(operation);
          final reloaded = AppState(store: store, corpus: state.corpus);
          await reloaded.load();
          addTearDown(reloaded.dispose);
          for (final snapshot in [state, reloaded]) {
            expect(
              snapshot.personalRecipes.map((r) => r.id),
              unorderedEquals([
                if (keepsLocal) local.id,
                if (addsIncoming) incoming.id,
              ]),
            );
            expect(snapshot.isSaved(local.id), keepsLocal);
            expect(
              snapshot.isSaved(incoming.id),
              ['import', 'save'].contains(operation),
            );
            expect(
              snapshot.recipeImageFor(incoming.id)?.credit,
              hasImage ? credit('Ann') : isNull,
            );
            expect(
              snapshot.recipeImages.map((i) => i.recipeId),
              hasImage ? [incoming.id] : isEmpty,
            );
          }
          expect(
            store.loadRecipeImageBytes().keys,
            hasImage ? [incoming.id] : isEmpty,
          );
        },
      );
    }
  }
}

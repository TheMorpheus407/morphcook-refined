import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';

import 'helpers.dart';
import 'recipe_photo_write_ordering_test.dart' show personalRecipe;

class _PausedCollectionsStore extends MemoryStore {
  bool armed = false;
  bool failAfterWrite = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    if (armed && collections.containsKey('personal_recipes')) {
      armed = false;
      entered.complete();
      await release.future;
      await super.putCollections(collections);
      if (failAfterWrite) throw StateError('confirmation failed');
      return;
    }
    await super.putCollections(collections);
  }
}

const _backup = BackupData(
  profile: Profile(),
  saved: [],
  mealPlan: {},
  history: [],
);

Future<void> _edit(AppState state, String edit) => switch (edit) {
  'history' => state.logCooked('doener-vegan'),
  'assign' => state.assignMeal('2026-W42', 'mon', 'doener-vegan'),
  'clear meal' => state.clearMeal('2026-W42', 'mon'),
  'move meal' => state.moveMeal('2026-W42', 'mon', 'tue'),
  'shopping add' => state.addToShoppingList([(makeRecipe(), 1.0)]),
  'shopping toggle' => state.toggleShoppingItem(0),
  'shopping clear checked' => state.clearCheckedShoppingItems(),
  'shopping clear' => state.clearShoppingList(),
  'request' => state.logContentRequest('new dish'),
  _ => throw ArgumentError(edit),
};

void _expectEdit(AppState state, String edit) {
  final backup = state.buildBackup();
  switch (edit) {
    case 'history':
      expect(backup.history.map((h) => h.recipeId), ['doener-vegan']);
    case 'assign':
      expect(backup.mealPlan['2026-W42']?['mon'], 'doener-vegan');
    case 'clear meal':
      expect(backup.mealPlan, isEmpty);
    case 'move meal':
      expect(backup.mealPlan['2026-W42'], {'tue': 'doener-classic'});
    case 'shopping add':
      expect(state.shoppingList.single.ingredientId, 'garlic');
      expect(backup.shoppingHistory.single.ingredientId, 'garlic');
    case 'shopping toggle':
      expect(state.shoppingList.single.checked, isTrue);
    case 'shopping clear checked':
    case 'shopping clear':
      expect(state.shoppingList, isEmpty);
    case 'request':
      expect(backup.contentRequests, ['new dish']);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final operation in ['merge', 'delete']) {
    for (final fails in [false, true]) {
      for (final edit in [
        'history',
        'assign',
        'clear meal',
        'move meal',
        'shopping add',
        'shopping toggle',
        'shopping clear checked',
        'shopping clear',
        'request',
      ]) {
        test('$edit survives $operation (failure=$fails)', () async {
          final store = _PausedCollectionsStore()..failAfterWrite = fails;
          final state = AppState(store: store, corpus: await loadRealCorpus());
          addTearDown(state.dispose);
          await state.load();
          await state.savePersonalRecipe(personalRecipe(1));
          if (edit == 'clear meal' || edit == 'move meal') {
            await state.assignMeal('2026-W42', 'mon', 'doener-classic');
          }
          if (edit.startsWith('shopping') && edit != 'shopping add') {
            await state.addToShoppingList([(makeRecipe(), 1.0)]);
            if (edit == 'shopping clear checked') {
              await state.toggleShoppingItem(0);
            }
          }
          store.armed = true;
          final first = operation == 'merge'
              ? state.applyBackup(_backup, merge: true)
              : state.deletePersonalRecipe(personalRecipe(1).id);
          final checkedFirst = fails
              ? expectLater(first, throwsStateError)
              : first;
          addTearDown(() async {
            if (!store.release.isCompleted) store.release.complete();
            await checkedFirst;
          });
          await store.entered.future.timeout(const Duration(seconds: 5));
          final later = _edit(state, edit);
          await Future<void>.delayed(Duration.zero);
          store.release.complete();
          await checkedFirst;
          await later;
          _expectEdit(state, edit);
          final reloaded = AppState(store: store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          _expectEdit(reloaded, edit);
        });
      }
    }
  }

  for (final operation in ['delete', 'replace', 'reset']) {
    test(
      'queued history and plan ignore a recipe removed by $operation',
      () async {
        final store = _PausedCollectionsStore();
        final state = AppState(store: store, corpus: await loadRealCorpus());
        addTearDown(state.dispose);
        await state.load();
        final recipe = personalRecipe(1);
        await state.savePersonalRecipe(recipe);
        store.armed = operation != 'reset';
        final first = switch (operation) {
          'delete' => state.deletePersonalRecipe(recipe.id),
          'replace' => state.applyBackup(_backup, merge: false),
          _ => state.resetEverything(),
        };
        if (store.armed || store.entered.isCompleted) {
          await store.entered.future.timeout(const Duration(seconds: 5));
        }
        final history = state.logCooked(recipe.id);
        final plan = state.assignMeal('2026-W42', 'mon', recipe.id);
        store.release.complete();
        await Future.wait([first, history, plan]);
        final reloaded = AppState(store: store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        for (final snapshot in [state, reloaded]) {
          expect(snapshot.history, isEmpty);
          expect(snapshot.mealPlan, isEmpty);
        }
      },
    );
  }
}

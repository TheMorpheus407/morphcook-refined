import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';

import 'helpers.dart';

class _FailingStore extends MemoryStore {
  String? failKey;
  bool afterWrite = false;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> putCollection(String key, String jsonText) async {
    if (key == failKey) {
      failKey = null;
      entered?.complete();
      if (release != null) await release!.future;
      if (afterWrite) await super.putCollection(key, jsonText);
      throw StateError('collection confirmation failed');
    }
    await super.putCollection(key, jsonText);
  }
}

Map<String, Object> _snapshot(AppState state) => {
  'history': state.history.map((h) => h.toJson()).toList(),
  'meal_plan': jsonDecode(jsonEncode(state.mealPlan)),
  'shopping_list': state.shoppingList.map((s) => s.toJson()).toList(),
  'shopping_history': state.shoppingHistory.map((s) => s.toJson()).toList(),
  'content_requests': state.contentRequests,
};

Future<void> _edit(AppState state, String operation) => switch (operation) {
  'history' => state.logCooked('doener-vegan'),
  'assign' => state.assignMeal('week', 'tue', 'doener-vegan'),
  'clear meal' => state.clearMeal('week', 'mon'),
  'move meal' => state.moveMeal('week', 'mon', 'tue'),
  'shopping add' => state.addToShoppingList([(makeRecipe(), 1.0)]),
  'shopping toggle' => state.toggleShoppingItem(state.shoppingList.single),
  'clear checked' => state.clearCheckedShoppingItems(),
  'clear shopping' => state.clearShoppingList(),
  'request' => state.logContentRequest('missing dish'),
  _ => throw ArgumentError(operation),
};

void _expectSuccess(AppState state, String operation) {
  switch (operation) {
    case 'history':
      expect(state.history.length, 1);
    case 'assign':
      expect(state.mealPlan['week'], {
        'mon': 'doener-classic',
        'tue': 'doener-vegan',
      });
    case 'clear meal':
      expect(state.mealPlan, isEmpty);
    case 'move meal':
      expect(state.mealPlan['week'], {'tue': 'doener-classic'});
    case 'shopping add':
      expect(state.shoppingList.single.qty, 2);
      expect(state.shoppingHistory.length, 2);
    case 'shopping toggle':
      expect(state.shoppingList.single.checked, isTrue);
    case 'clear checked':
    case 'clear shopping':
      expect(state.shoppingList, isEmpty);
    case 'request':
      expect(state.contentRequests, ['missing dish']);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (operation, key) in [
    ('history', 'history'),
    ('assign', 'meal_plan'),
    ('clear meal', 'meal_plan'),
    ('move meal', 'meal_plan'),
    ('shopping add', 'shopping_list'),
    ('shopping add', 'shopping_history'),
    ('shopping toggle', 'shopping_list'),
    ('clear checked', 'shopping_list'),
    ('clear shopping', 'shopping_list'),
    ('request', 'content_requests'),
  ]) {
    for (final afterWrite in [false, true]) {
      test(
        '$operation: $key failure (afterWrite=$afterWrite) and retry',
        () async {
          final store = _FailingStore()..afterWrite = afterWrite;
          final state = AppState(store: store, corpus: await loadRealCorpus());
          addTearDown(state.dispose);
          await state.load();
          await state.assignMeal('week', 'mon', 'doener-classic');
          await state.addToShoppingList([(makeRecipe(), 1.0)]);
          if (operation == 'clear checked') {
            await state.toggleShoppingItem(state.shoppingList.single);
          }
          final previous = _snapshot(state);
          var notifications = 0;
          state.addListener(() => notifications++);
          store.failKey = key;
          await expectLater(_edit(state, operation), throwsStateError);
          expect(
            _snapshot(state),
            previous,
            reason: 'failed intent is unpublished',
          );
          expect(notifications, 0);
          final reloaded = AppState(store: store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          expect(
            _snapshot(reloaded),
            previous,
            reason: 'storage is rolled back',
          );
          await _edit(state, operation);
          _expectSuccess(state, operation);
          await reloaded.load();
          _expectSuccess(reloaded, operation);
          expect(_snapshot(reloaded), _snapshot(state));
        },
      );
    }
  }

  test(
    'failed meal deletion cannot leak into the next queued assignment',
    () async {
      final store = _FailingStore();
      final state = AppState(store: store, corpus: await loadRealCorpus());
      addTearDown(state.dispose);
      await state.load();
      await state.assignMeal('week', 'mon', 'doener-classic');
      store
        ..failKey = 'meal_plan'
        ..afterWrite = true
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final failed = expectLater(
        state.clearMeal('week', 'mon'),
        throwsStateError,
      );
      addTearDown(() async {
        if (!store.release!.isCompleted) store.release!.complete();
        await failed;
      });
      await store.entered!.future;
      expect(state.mealPlan['week'], {'mon': 'doener-classic'});
      final later = state.assignMeal('week', 'tue', 'doener-vegan');
      store.release!.complete();
      await failed;
      await later;
      _expectSuccess(state, 'assign');
      final reloaded = AppState(store: store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      _expectSuccess(reloaded, 'assign');
    },
  );
}

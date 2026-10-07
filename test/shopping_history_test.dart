import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/insights.dart';

import 'helpers.dart';

Future<AppState> buildState({MemoryStore? store}) async {
  final corpus = await loadRealCorpus();
  final state = AppState(store: store ?? MemoryStore(), corpus: corpus);
  await state.load();
  return state;
}

Future<AppState> reload(AppState state) async {
  final reloaded = AppState(store: state.store, corpus: state.corpus);
  await reloaded.load();
  return reloaded;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('adding recipe ingredients does not count them for insights', () async {
    final state = await buildState();
    final doener = state.corpus.loadedRecipeById('doener-vegan')!;

    await state.addToShoppingList([(doener, 1.0)]);

    expect(state.shoppingList, isNotEmpty);
    expect(state.shoppingHistory, isEmpty);
    expect(ShoppingInsights.compute(state.shoppingHistory).varietyScore, 0);
  });

  test(
    'clearing the list with nothing checked off records no history',
    () async {
      // Issue recreation: add via recipe, delete everything from the
      // shopping list without checking anything off — insights stay empty.
      final state = await buildState();
      final doener = state.corpus.loadedRecipeById('doener-vegan')!;
      await state.addToShoppingList([(doener, 1.0)]);

      await state.clearShoppingList();

      expect(state.shoppingList, isEmpty);
      expect(state.shoppingHistory, isEmpty);
      expect(ShoppingInsights.compute(state.shoppingHistory).varietyScore, 0);

      final reloaded = await reload(state);
      expect(reloaded.shoppingHistory, isEmpty);
    },
  );

  test('checked-off items enter history when cleared from the list', () async {
    final state = await buildState();
    final doener = state.corpus.loadedRecipeById('doener-vegan')!;
    await state.addToShoppingList([(doener, 1.0)]);
    final listLength = state.shoppingList.length;

    await state.toggleShoppingItem(0);
    final checkedOff = state.shoppingList[0];
    expect(checkedOff.checked, isTrue);
    await state.clearCheckedShoppingItems();

    expect(state.shoppingList, hasLength(listLength - 1));
    expect(state.shoppingList.where((item) => item.checked), isEmpty);
    expect(state.shoppingHistory, hasLength(1));
    final entry = state.shoppingHistory.single;
    expect(entry.ingredientId, checkedOff.ingredientId);
    expect(entry.qty, checkedOff.qty);
    expect(entry.unit, checkedOff.unit);
    expect(entry.hasQuantity, checkedOff.hasQuantity);
    expect(entry.aisle, checkedOff.aisle);
    expect(entry.addedAt, checkedOff.addedAt);

    final reloaded = await reload(state);
    expect(reloaded.shoppingHistory, hasLength(1));
    expect(
      reloaded.shoppingHistory.single.ingredientId,
      checkedOff.ingredientId,
    );
  });

  test('clearing the whole list counts only checked-off items', () async {
    final state = await buildState();
    final doener = state.corpus.loadedRecipeById('doener-vegan')!;
    await state.addToShoppingList([(doener, 1.0)]);

    await state.toggleShoppingItem(0);
    final checkedOff = state.shoppingList[0];
    await state.clearShoppingList();

    expect(state.shoppingList, isEmpty);
    expect(state.shoppingHistory, hasLength(1));
    expect(state.shoppingHistory.single.ingredientId, checkedOff.ingredientId);

    final reloaded = await reload(state);
    expect(reloaded.shoppingHistory, hasLength(1));
    expect(
      reloaded.shoppingHistory.single.ingredientId,
      checkedOff.ingredientId,
    );
  });

  test(
    'un-checking an item before clearing keeps it out of the history',
    () async {
      final state = await buildState();
      final doener = state.corpus.loadedRecipeById('doener-vegan')!;
      await state.addToShoppingList([(doener, 1.0)]);

      // Check an item off, then undo it — at deletion time nothing is checked.
      await state.toggleShoppingItem(0);
      await state.toggleShoppingItem(0);
      expect(state.shoppingList[0].checked, isFalse);

      await state.clearShoppingList();

      expect(state.shoppingList, isEmpty);
      expect(state.shoppingHistory, isEmpty);
      expect(ShoppingInsights.compute(state.shoppingHistory).varietyScore, 0);

      final reloaded = await reload(state);
      expect(reloaded.shoppingHistory, isEmpty);
    },
  );

  test('repeated toggles count a checked-off item only once', () async {
    final state = await buildState();
    final doener = state.corpus.loadedRecipeById('doener-vegan')!;
    await state.addToShoppingList([(doener, 1.0)]);

    // Check → uncheck → check again: the item is archived exactly once.
    await state.toggleShoppingItem(0);
    await state.toggleShoppingItem(0);
    await state.toggleShoppingItem(0);
    final checkedOff = state.shoppingList[0];
    expect(checkedOff.checked, isTrue);
    await state.clearCheckedShoppingItems();

    expect(state.shoppingHistory, hasLength(1));
    expect(state.shoppingHistory.single.ingredientId, checkedOff.ingredientId);
    expect(ShoppingInsights.compute(state.shoppingHistory).varietyScore, 1);

    final reloaded = await reload(state);
    expect(reloaded.shoppingHistory, hasLength(1));
  });

  test(
    'history accumulates across repeated check-off and clear cycles',
    () async {
      final state = await buildState();
      final doener = state.corpus.loadedRecipeById('doener-vegan')!;

      await state.addToShoppingList([(doener, 1.0)]);
      await state.toggleShoppingItem(0);
      await state.toggleShoppingItem(1);
      final firstCycle = [state.shoppingList[0], state.shoppingList[1]];
      await state.clearCheckedShoppingItems();
      expect(state.shoppingHistory, hasLength(2));

      await state.addToShoppingList([(doener, 1.0)]);
      final nextIndex = state.shoppingList.indexWhere((item) => !item.checked);
      expect(nextIndex, isNonNegative);
      await state.toggleShoppingItem(nextIndex);
      final secondCycle = state.shoppingList[nextIndex];
      await state.clearCheckedShoppingItems();

      // The second archive appends to the history instead of replacing it.
      expect(state.shoppingHistory, hasLength(3));
      final ids = [
        ...firstCycle.map((item) => item.ingredientId),
        secondCycle.ingredientId,
      ];
      expect(
        state.shoppingHistory.map((item) => item.ingredientId).toList(),
        ids,
      );
      expect(
        ShoppingInsights.compute(state.shoppingHistory).varietyScore,
        ids.toSet().length,
      );

      final reloaded = await reload(state);
      expect(reloaded.shoppingHistory, hasLength(3));
    },
  );
}

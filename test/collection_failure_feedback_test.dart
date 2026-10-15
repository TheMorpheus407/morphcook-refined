import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/collections.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/cook_mode_screen.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/screens/shopping_list_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/widgets/recipe_row.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _FailOnceStore extends MemoryStore {
  String? failKey;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<void> putCollection(String key, String jsonText) async {
    if (key == failKey) {
      failKey = null;
      entered?.complete();
      if (release != null) await release!.future;
      throw StateError('storage unavailable');
    }
    await super.putCollection(key, jsonText);
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    testWidgets('$lang navigation during a failed save stays safe', (
      tester,
    ) async {
      final store = _FailOnceStore();
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        await state.addToShoppingList([(makeRecipe(), 1.0)]);
        return state;
      }))!;
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state, const ShoppingListScreen()));
      await tester.pumpAndSettle();
      store
        ..failKey = 'shopping_list'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      addTearDown(() {
        if (!store.release!.isCompleted) store.release!.complete();
      });
      await tester.tap(find.byIcon(Icons.check_box_outline_blank));
      await tester.pump();
      expect(store.entered!.isCompleted, isTrue);
      await tester.pumpWidget(const SizedBox());
      store.release!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(state.shoppingList.single.checked, isFalse);
    });
    for (final action in ['assign', 'remove', 'move']) {
      testWidgets('$lang meal $action reports failure and retries', (
        tester,
      ) async {
        final store = _FailOnceStore();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          await state.assignMeal(
            isoWeekKey(DateTime.now()),
            'mon.dinner',
            'doener-classic',
          );
          await state.toggleSaved('doener-vegan');
          return state;
        }))!;
        addTearDown(state.dispose);
        final week = isoWeekKey(DateTime.now());
        await tester.pumpWidget(
          app(state, const Scaffold(body: MealPlanScreen())),
        );
        await tester.pumpAndSettle();
        Future<void> edit() async {
          final targets = find.byWidgetPredicate(
            (w) => w is DragTarget<MealPlanDrag>,
          );
          if (action == 'move') {
            tester
                .widget<DragTarget<MealPlanDrag>>(targets.first)
                .onAcceptWithDetails!(
              DragTargetDetails(
                data: (
                  weekKey: week,
                  slotKey: 'mon.dinner',
                  recipeId: 'doener-classic',
                ),
                offset: Offset.zero,
              ),
            );
          } else {
            await tester.tap(targets.at(action == 'remove' ? 2 : 0));
            await tester.pumpAndSettle();
            if (action == 'remove') {
              await tester.tap(find.text(S(lang)('removeFromSlot')));
            } else {
              await tester.tap(find.text(S(lang)('fromCookbook')));
              await tester.pumpAndSettle();
              await tester.tap(find.byType(RecipeRow).first);
            }
          }
          await tester.pumpAndSettle();
        }

        store.failKey = 'meal_plan';
        await edit();
        expect(tester.takeException(), isNull);
        expect(find.text(S(lang)('collectionSaveFailed')), findsOneWidget);
        expect(state.mealPlan[week], {'mon.dinner': 'doener-classic'});
        ScaffoldMessenger.of(
          tester.element(find.byType(MealPlanScreen)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        await edit();
        final expected = switch (action) {
          'remove' => <String, String>{},
          'move' => {'mon.breakfast': 'doener-classic'},
          _ => {
            'mon.dinner': 'doener-classic',
            'mon.breakfast': 'doener-vegan',
          },
        };
        expect(state.mealPlan[week] ?? {}, expected);
        final reloaded = AppState(store: store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.mealPlan, state.mealPlan);
        await tester.pumpWidget(const SizedBox());
      });
    }
    for (final action in [
      'toggle',
      'clear checked',
      'clear all',
      'export week',
      'dish add',
      'cook',
    ]) {
      testWidgets('$lang $action reports storage failure and allows retry', (
        tester,
      ) async {
        final store = _FailOnceStore();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          await state.addToShoppingList([(makeRecipe(), 1.0)]);
          if (action == 'clear checked') {
            await state.toggleShoppingItem(state.shoppingList.single);
          }
          await state.assignMeal(
            isoWeekKey(DateTime.now()),
            'mon.dinner',
            'doener-classic',
          );
          return state;
        }))!;
        addTearDown(state.dispose);
        final s = S(lang);
        Widget screen;
        switch (action) {
          case 'export week':
            screen = const Scaffold(body: MealPlanScreen());
          case 'dish add':
            screen = const DishDetailScreen(dishId: 'doener');
          case 'cook':
            screen = CookModeScreen(recipe: makeRecipe(id: 'doener-classic'));
          default:
            screen = const ShoppingListScreen();
        }
        await tester.pumpWidget(app(state, screen));
        await tester.pumpAndSettle();
        Finder control;
        switch (action) {
          case 'toggle':
            control = find.text(
              state.corpus.dictionary.byId('garlic')!.name.of(lang),
            );
          case 'clear checked':
            control = find.byTooltip(s('clearChecked'));
          case 'clear all':
            control = find.byTooltip(s('clearAll'));
          case 'export week':
            control = find.text(s('exportWeekToList'));
          case 'dish add':
            control = find.text(s('addToList'));
            await tester.scrollUntilVisible(control, 300);
            await tester.pumpAndSettle();
          case 'cook':
            await tester.tap(find.byType(FilledButton));
            await tester.pumpAndSettle();
            // Completion has not been saved until its final button succeeds.
            expect(state.history, isEmpty);
            expect(
              find.text(
                lang == 'en'
                    ? 'logged to your history.'
                    : 'in deiner Historie vermerkt.',
              ),
              findsNothing,
            );
            control = find.byType(FilledButton);
          default:
            throw StateError(action);
        }
        final beforeQty = state.shoppingList.single.qty;
        store.failKey = action == 'cook' ? 'history' : 'shopping_list';
        await tester.tap(control);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(s('collectionSaveFailed')), findsOneWidget);
        expect(state.shoppingList.single.qty, beforeQty);
        expect(state.shoppingList.single.checked, action == 'clear checked');
        expect(state.history, isEmpty);
        expect(find.text(s('weekExported')), findsNothing);
        expect(find.text(s('addedToList')), findsNothing);
        ScaffoldMessenger.of(tester.element(control)).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        await tester.tap(control);
        await tester.pumpAndSettle();
        switch (action) {
          case 'toggle':
            expect(state.shoppingList.single.checked, isTrue);
          case 'clear checked':
          case 'clear all':
            expect(state.shoppingList, isEmpty);
          case 'export week':
          case 'dish add':
            expect(state.shoppingHistory.length, greaterThan(1));
          case 'cook':
            expect(state.history, hasLength(1));
        }
        final reloaded = AppState(store: store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(
          reloaded.shoppingList.map((item) => item.toJson()),
          state.shoppingList.map((item) => item.toJson()),
        );
        expect(
          reloaded.history.map((item) => item.toJson()),
          state.history.map((item) => item.toJson()),
        );
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

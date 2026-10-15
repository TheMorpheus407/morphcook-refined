// Regression for morphcook-r16-p2-1: resolve shopping ingredients after queued mutations.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/main.dart';
import 'package:morphcook/models/collections.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _PausedStore extends MemoryStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool pauseImport = false;
  bool fail = false;
  @override
  Future<void> clearAll() async {
    entered.complete();
    await release.future;
    if (fail) throw StateError('reset rejected');
    await super.clearAll();
  }

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    if (pauseImport && collections.containsKey('personal_recipes')) {
      pauseImport = false;
      entered.complete();
      await release.future;
      if (fail) throw StateError('import rejected');
    }
    await super.putCollections(collections);
  }
}

PersonalRecipe _personal() => PersonalRecipe.create(
  title: 'Private family recipe',
  timeMinutes: 10,
  servings: 1,
  ingredients: [
    PersonalRecipeIngredient(
      name: 'PRIVATE OLD ingredient',
      qty: 100,
      unit: 'g',
    ),
  ],
  steps: [PersonalRecipeStep(text: 'Cook it.')],
);

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  test(
    'queued mixed batch uses confirmed recipe and preserves scaling',
    () async {
      final store = _PausedStore();
      final recipe = _personal();
      final state = AppState(store: store, corpus: await loadRealCorpus());
      await state.load();
      await state.savePersonalRecipe(recipe);
      addTearDown(state.dispose);
      addTearDown(() {
        if (!store.release.isCompleted) store.release.complete();
      });
      final bundled = (await state.recipeById('doener-vegan'))!;
      final snapshot = recipe.asRecipe();
      final replacement = recipe.copyWith(
        ingredients: [
          PersonalRecipeIngredient(
            name: 'NEW imported ingredient',
            qty: 200,
            unit: 'g',
          ),
        ],
      );
      store.pauseImport = true;
      final restore = state.applyBackup(
        BackupData(
          profile: const Profile(),
          saved: const [],
          mealPlan: const {},
          history: const [],
          personalRecipes: [replacement],
        ),
        merge: false,
      );
      await store.entered.future;
      final add = state.addToShoppingList([(snapshot, 2.0), (bundled, 1.0)]);
      expect(state.shoppingList, isEmpty);
      store.release.complete();
      await restore;
      await add;
      final reloaded = AppState(store: store, corpus: state.corpus);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      final custom = reloaded.shoppingList.where(
        (item) => item.customName != null,
      );
      expect(custom.single.customName, 'NEW imported ingredient');
      expect(custom.single.qty, 400);
      expect(reloaded.shoppingList.length, greaterThan(1));
      expect(reloaded.shoppingHistory.length, reloaded.shoppingList.length);
    },
  );
  test(
    'removed personal recipe rejects entire batch before any write',
    () async {
      final store = _PausedStore();
      final recipe = _personal();
      final state = AppState(store: store, corpus: await loadRealCorpus());
      await state.load();
      await state.savePersonalRecipe(recipe);
      addTearDown(state.dispose);
      final bundled = (await state.recipeById('doener-vegan'))!;
      final snapshot = recipe.asRecipe();
      await state.deletePersonalRecipe(recipe.id);
      await expectLater(
        state.addToShoppingList(<(Recipe, double)>[
          (bundled, 1.0),
          (snapshot, 1.0),
        ]),
        throwsA(isA<RecipeUnavailableException>()),
      );
      final reloaded = AppState(store: store, corpus: state.corpus);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.shoppingList, isEmpty);
      expect(reloaded.shoppingHistory, isEmpty);
      // Rejection must not poison the mutation queue.
      await state.addToShoppingList([(bundled, 1.0)]);
      expect(state.shoppingList, isNotEmpty);
    },
  );
  test(
    'personal shopping requires stored contents but not a bookmark',
    () async {
      final state = AppState(
        store: MemoryStore(),
        corpus: await loadRealCorpus(),
      );
      await state.load();
      addTearDown(state.dispose);
      final recipe = _personal();
      await expectLater(
        state.addToShoppingList([(recipe.asRecipe(), 1.0)]),
        throwsA(isA<RecipeUnavailableException>()),
      );
      expect(state.shoppingList, isEmpty);
      expect(state.shoppingHistory, isEmpty);
      await state.savePersonalRecipe(recipe);
      await state.toggleSaved(recipe.id);
      expect(state.isSaved(recipe.id), isFalse);
      await state.addToShoppingList([(recipe.asRecipe(), 1.0)]);
      expect(state.shoppingList.single.customName, 'PRIVATE OLD ingredient');
      expect(state.shoppingHistory.single.qty, 100);
    },
  );
  for (final lang in ['en', 'de']) {
    for (final fails in [false, true]) {
      testWidgets('$lang actual reset UI then shopping add fails=$fails', (
        tester,
      ) async {
        final store = _PausedStore()..fail = fails;
        final recipe = _personal();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          await state.savePersonalRecipe(recipe);
          return state;
        }))!;
        addTearDown(state.dispose);
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
        });
        final s = S(lang);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(value: state, child: const ThemedApp()),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(s('resetApp')),
          400,
          scrollable: find
              .descendant(
                of: find.byType(SettingsScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.text(s('resetApp')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, s('erase')));
        await tester.pumpAndSettle();
        expect(store.entered.isCompleted, isTrue);
        await tester.tap(find.byIcon(Icons.bookmark_border).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(recipe.title).first);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text(s('addToList')), 300);
        await tester.pumpAndSettle();
        await tester.tap(find.text(s('addToList')));
        await tester.pump();
        expect(state.shoppingList, isEmpty, reason: 'add waits behind reset');
        store.release.complete();
        await tester.pumpAndSettle();
        final reloaded = (await tester.runAsync(() async {
          final reloaded = AppState(store: store, corpus: state.corpus);
          await reloaded.load();
          return reloaded;
        }))!;
        addTearDown(reloaded.dispose);
        expect(reloaded.onboarded, fails);
        expect(reloaded.personalRecipes, hasLength(fails ? 1 : 0));
        expect(
          reloaded.shoppingList,
          fails ? hasLength(1) : isEmpty,
          reason:
              'confirmed erasure must not resurrect the deleted personal recipe ingredients',
        );
        expect(reloaded.shoppingHistory, fails ? hasLength(1) : isEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    }
    for (final entrypoint in ['detail', 'planner']) {
      testWidgets(
        '$lang $entrypoint reports a removed recipe without storage advice',
        (tester) async {
          final store = _PausedStore();
          final recipe = _personal();
          final state = (await tester.runAsync(() async {
            final state = AppState(
              store: store,
              corpus: await loadRealCorpus(),
            );
            await state.load();
            await state.completeOnboarding(Profile(lang: lang));
            await state.savePersonalRecipe(recipe);
            await state.assignMeal(
              isoWeekKey(DateTime.now()),
              'mon.dinner',
              recipe.id,
            );
            return state;
          }))!;
          addTearDown(state.dispose);
          addTearDown(() {
            if (!store.release.isCompleted) store.release.complete();
          });
          await tester.pumpWidget(
            app(
              state,
              entrypoint == 'detail'
                  ? DishDetailScreen(dishId: recipe.dishId)
                  : const Scaffold(body: MealPlanScreen()),
            ),
          );
          await tester.pumpAndSettle();
          store.pauseImport = true;
          final restore = state.applyBackup(
            BackupData(
              profile: Profile(lang: lang),
              saved: const [],
              mealPlan: const {},
              history: const [],
            ),
            merge: false,
          );
          await tester.pump();
          expect(store.entered.isCompleted, isTrue);
          final s = S(lang);
          final control = find.text(
            s(entrypoint == 'detail' ? 'addToList' : 'exportWeekToList'),
          );
          if (entrypoint == 'detail') {
            await tester.scrollUntilVisible(control, 300);
            await tester.pumpAndSettle();
          }
          await tester.tap(control);
          await tester.pump();
          store.release.complete();
          await restore;
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(s('recipeUnavailable')),
            ),
            findsOneWidget,
          );
          expect(find.text(s('collectionSaveFailed')), findsNothing);
          expect(find.text(s('addedToList')), findsNothing);
          expect(find.text(s('weekExported')), findsNothing);
          expect(state.shoppingList, isEmpty);
          expect(state.shoppingHistory, isEmpty);
          final reloaded = AppState(store: store, corpus: state.corpus);
          await reloaded.load();
          addTearDown(reloaded.dispose);
          expect(reloaded.shoppingList, isEmpty);
          expect(reloaded.shoppingHistory, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    testWidgets('$lang shopping uses confirmed imported recipe', (
      tester,
    ) async {
      final store = _PausedStore();
      final recipe = _personal();
      final replacement = recipe.copyWith(
        ingredients: [
          PersonalRecipeIngredient(
            name: 'NEW imported ingredient',
            qty: 200,
            unit: 'g',
          ),
        ],
      );
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        await state.savePersonalRecipe(recipe);
        return state;
      }))!;
      addTearDown(state.dispose);
      addTearDown(() {
        if (!store.release.isCompleted) store.release.complete();
      });
      await tester.pumpWidget(
        app(state, DishDetailScreen(dishId: recipe.dishId)),
      );
      await tester.pumpAndSettle();
      store.pauseImport = true;
      final restore = state.applyBackup(
        BackupData(
          profile: Profile(lang: lang),
          saved: [],
          mealPlan: {},
          history: [],
          personalRecipes: [replacement],
        ),
        merge: false,
      );
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);
      await tester.scrollUntilVisible(find.text(S(lang)('addToList')), 300);
      await tester.pumpAndSettle();
      await tester.tap(find.text(S(lang)('addToList')));
      await tester.pump();
      store.release.complete();
      await restore;
      await tester.pumpAndSettle();
      expect(
        state.personalRecipes.single.ingredients.single.name,
        'NEW imported ingredient',
      );
      expect(state.shoppingList.single.customName, 'NEW imported ingredient');
      expect(state.shoppingList.single.qty, 200);
      final reloaded = AppState(store: store, corpus: state.corpus);
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(
        reloaded.shoppingList.single.customName,
        'NEW imported ingredient',
      );
      expect(reloaded.shoppingList.single.qty, 200);
      expect(
        reloaded.shoppingHistory.single.customName,
        'NEW imported ingredient',
      );
      expect(reloaded.shoppingHistory.single.qty, 200);
      expect(find.text(S(lang)('addedToList')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

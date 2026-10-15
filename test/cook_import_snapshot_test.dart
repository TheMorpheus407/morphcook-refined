import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/strings.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _DelayedBackupStore extends MemoryStore {
  bool armed = false;
  bool fail = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    if (armed) {
      armed = false;
      entered.complete();
      await release.future;
      if (fail) throw StateError('import rejected');
    }
    await super.putCollections(collections);
  }
}

PersonalRecipe _personal({required bool updated}) => PersonalRecipe(
  id: 'personal-0123456789abcdef0123456789abcdef',
  title: updated ? 'New title' : 'Old title',
  timeMinutes: 1,
  servings: updated ? 4 : 2,
  ingredients: [
    PersonalRecipeIngredient(
      name: updated ? 'New water' : 'Old water',
      qty: updated ? 200 : 100,
      unit: 'ml',
    ),
  ],
  steps: [
    PersonalRecipeStep(
      text: updated ? 'NEW imported instructions' : 'OLD instructions',
      timerMinutes: updated ? 1 : null,
    ),
  ],
  createdAt: DateTime.utc(2025),
  updatedAt: DateTime.utc(updated ? 2026 : 2025),
);

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final fails in [false, true]) {
      testWidgets(
        '$lang cooking uses confirmed import snapshot: fails=$fails',
        (tester) async {
          final store = _DelayedBackupStore()..fail = fails;
          final oldRecipe = _personal(updated: false);
          final newRecipe = _personal(updated: true);
          final state = (await tester.runAsync(() async {
            final state = AppState(
              store: store,
              corpus: await loadRealCorpus(),
            );
            await state.load();
            await state.completeOnboarding(Profile(lang: lang));
            await state.savePersonalRecipe(oldRecipe);
            return state;
          }))!;
          addTearDown(state.dispose);
          addTearDown(() {
            if (!store.release.isCompleted) store.release.complete();
          });
          store.armed = true;
          final restore = state.applyBackup(
            BackupData(
              profile: Profile(lang: lang),
              saved: const [],
              mealPlan: const {},
              history: const [],
              personalRecipes: [newRecipe],
            ),
            merge: false,
          );
          final restored = fails
              ? expectLater(restore, throwsStateError)
              : restore;
          await store.entered.future;
          await tester.pumpWidget(
            app(state, DishDetailScreen(dishId: oldRecipe.dishId)),
          );
          await tester.pumpAndSettle();
          final start = find.text(S(lang)('startCooking'));
          await tester.scrollUntilVisible(start, 400);
          await tester.pumpAndSettle();
          await tester.tap(start);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.byIcon(Icons.add), findsNothing);
          store.release.complete();
          await restored;
          await tester.pumpAndSettle();
          final expected = fails ? oldRecipe : newRecipe;
          final other = fails ? newRecipe : oldRecipe;
          expect(
            state.personalRecipes.single.steps.single.text,
            expected.steps.single.text,
          );
          expect(find.text(expected.steps.single.text), findsOneWidget);
          expect(find.text(other.steps.single.text), findsNothing);
          expect(find.text(expected.title), findsOneWidget);
          expect(find.text('${expected.servings}'), findsOneWidget);
          expect(find.text('01:00'), fails ? findsNothing : findsOneWidget);
          await tester.tap(find.byIcon(Icons.add));
          await tester.pumpAndSettle();
          expect(state.cookProgress?.recipeId, expected.id);
          expect(state.cookProgress?.servings, expected.servings + 1);
          expect(state.cookProgress?.remainingTimerSeconds, fails ? null : 60);
          await tester.tap(find.byTooltip(S(lang)('ingredients')));
          await tester.pumpAndSettle();
          expect(find.text(expected.ingredients.single.name), findsOneWidget);
          expect(find.text(other.ingredients.single.name), findsNothing);
          expect(find.text(fails ? '150 ml' : '250 ml'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

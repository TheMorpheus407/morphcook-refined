import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final rollover in [false, true]) {
      testWidgets('$lang remove keeps selected week (rollover=$rollover)', (
        tester,
      ) async {
        const slot = 'mon.breakfast';
        const recipe = 'doener-classic';
        final state = (await tester.runAsync(() async {
          final state = AppState(
            store: MemoryStore(),
            corpus: await loadRealCorpus(),
          );
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          await state.assignMeal('2026-W42', slot, recipe);
          await state.assignMeal('2026-W43', slot, recipe);
          return state;
        }))!;
        addTearDown(state.dispose);
        var now = DateTime(2026, 10, 18, 23, 59, 50);
        await tester.pumpWidget(
          app(state, Scaffold(body: MealPlanScreen(now: () => now))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(DragTarget<MealPlanDrag>).first);
        await tester.pumpAndSettle();
        now = rollover
            ? DateTime(2026, 10, 19, 0, 0, 10)
            : DateTime(2026, 10, 18, 23, 59, 55);
        await tester.tap(find.text(S(lang)('removeFromSlot')));
        await tester.pumpAndSettle();
        final reloaded = AppState(store: state.store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        for (final snapshot in [state, reloaded]) {
          expect(
            snapshot.mealPlan,
            {
              '2026-W43': {slot: recipe},
            },
            reason:
                'Remove must target selected W42 and preserve unselected W43',
          );
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

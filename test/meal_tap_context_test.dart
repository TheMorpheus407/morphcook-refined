import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/widgets/recipe_row.dart';
import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final interaction in [
      'fast scroll',
      'secondary click',
      'restore empty',
    ]) {
      for (final action in ['remove', 'cookbook']) {
        testWidgets('$lang $interaction cannot redirect later $action', (
          tester,
        ) async {
          const slot = 'mon.breakfast';
          const recipe = 'doener-classic';
          const picked = 'doener-vegan';
          final state = (await tester.runAsync(() async {
            final state = AppState(
              store: MemoryStore(),
              corpus: await loadRealCorpus(),
            );
            await state.load();
            await state.completeOnboarding(Profile(lang: lang));
            await state.assignMeal('2026-W42', slot, recipe);
            await state.assignMeal('2026-W43', slot, recipe);
            await state.toggleSaved(picked);
            return state;
          }))!;
          addTearDown(state.dispose);
          await tester.pumpWidget(
            app(
              state,
              Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 10, 15))),
            ),
          );
          await tester.pumpAndSettle();
          final cell = find.byType(DragTarget<MealPlanDrag>).first;
          final pointer = await tester.startGesture(
            tester.getCenter(cell),
            kind: interaction == 'secondary click'
                ? PointerDeviceKind.mouse
                : PointerDeviceKind.touch,
            buttons: interaction == 'secondary click'
                ? kSecondaryMouseButton
                : kPrimaryButton,
          );
          if (interaction == 'fast scroll') {
            // Reject before the tap-down deadline, without a PointerCancelEvent.
            await pointer.moveBy(const Offset(0, -60));
          } else if (interaction == 'restore empty') {
            await state.applyBackup(
              BackupData(
                profile: Profile(lang: lang),
                saved: state.saved,
                history: const [],
                mealPlan: {
                  '2026-W43': {slot: recipe},
                },
              ),
              merge: false,
            );
            await tester.pump(const Duration(milliseconds: 16));
          }
          await pointer.up();
          await tester.pumpAndSettle();
          expect(find.text(S(lang)('pickRecipe')), findsNothing);
          await tester.tap(find.byIcon(Icons.chevron_right));
          await tester.pumpAndSettle();
          await tester.tap(cell);
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(
              S(lang)(action == 'remove' ? 'removeFromSlot' : 'fromCookbook'),
            ),
          );
          await tester.pumpAndSettle();
          if (action == 'cookbook') {
            await tester.tap(find.byType(RecipeRow));
            await tester.pumpAndSettle();
          }
          final reloaded = AppState(store: state.store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          for (final snapshot in [state, reloaded]) {
            expect(
              snapshot.mealPlan,
              {
                if (interaction != 'restore empty') '2026-W42': {slot: recipe},
                if (action == 'cookbook') '2026-W43': {slot: picked},
              },
              reason:
                  'The next action belongs to the freshly selected W43 slot',
            );
          }
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  for (final lang in ['en', 'de']) {
    testWidgets('$lang accessibility tap opens the current slot menu', (
      tester,
    ) async {
      final state = (await tester.runAsync(() async {
        final state = AppState(
          store: MemoryStore(),
          corpus: await loadRealCorpus(),
        );
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        return state;
      }))!;
      addTearDown(state.dispose);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        app(
          state,
          Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 10, 15))),
        ),
      );
      await tester.pumpAndSettle();
      final cell = find.byType(DragTarget<MealPlanDrag>).first;
      final node = tester.getSemantics(
        find
            .descendant(
              of: cell,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.onTap != null,
              ),
            )
            .first,
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.text(S(lang)('pickRecipe')), findsOneWidget);
      expect(find.text(S(lang)('removeFromSlot')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    });
  }
  for (final lang in ['en', 'de']) {
    testWidgets('$lang another pointer cannot replace an active tap snapshot', (
      tester,
    ) async {
      const slot = 'mon.breakfast';
      final state = (await tester.runAsync(() async {
        final state = AppState(
          store: MemoryStore(),
          corpus: await loadRealCorpus(),
        );
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        await state.assignMeal('2026-W42', slot, 'doener-classic');
        return state;
      }))!;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        app(
          state,
          Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 10, 15))),
        ),
      );
      await tester.pumpAndSettle();
      final cell = find.byType(DragTarget<MealPlanDrag>).first;
      final first = await tester.startGesture(
        tester.getCenter(cell),
        pointer: 1,
      );
      await state.assignMeal('2026-W42', slot, 'doener-vegan');
      await tester.pump(const Duration(milliseconds: 16));
      final second = await tester.startGesture(
        tester.getCenter(cell),
        pointer: 2,
      );
      await second.up();
      await first.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text(S(lang)('removeFromSlot')));
      await tester.pumpAndSettle();
      final reloaded = AppState(store: state.store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      for (final snapshot in [state, reloaded]) {
        expect(snapshot.mealPlan, {
          '2026-W42': {slot: 'doener-vegan'},
        });
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}

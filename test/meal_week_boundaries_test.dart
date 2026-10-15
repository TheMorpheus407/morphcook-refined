import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/collections.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/strings.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

Future<AppState> stateForTest({String lang = 'en'}) async {
  final state = AppState(store: MemoryStore(), corpus: await loadRealCorpus());
  await state.load();
  await state.completeOnboarding(Profile(lang: lang));
  await state.assignMeal('2026-W42', 'mon.breakfast', 'doener-classic');
  await state.assignMeal('2026-W43', 'mon.breakfast', 'doener-vegan');
  return state;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  // Also run with TZ=Asia/Jerusalem: spring DST begins on Friday, inside
  // the calendar week, so subtracting 24-hour durations crosses the change.
  test('weekStart returns calendar Monday midnight across DST', () {
    for (final monday in [DateTime(2026, 3, 23), DateTime(2026, 10, 19)]) {
      for (var day = 0; day < 7; day++) {
        expect(
          weekStart(DateTime(monday.year, monday.month, monday.day + day, 12)),
          monday,
        );
      }
    }
  });

  for (final lang in ['en', 'de']) {
    testWidgets('$lang current week after a weekday DST change exports W13', (
      tester,
    ) async {
      final state = (await tester.runAsync(() async {
        final state = await stateForTest(lang: lang);
        await state.assignMeal('2026-W12', 'mon.breakfast', 'doener-vegan');
        await state.assignMeal('2026-W13', 'mon.breakfast', 'doener-classic');
        return state;
      }))!;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        app(
          state,
          Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 3, 29, 12))),
        ),
      );
      await tester.pumpAndSettle();
      // Check persisted ingredients before the date labels so the regression
      // demonstrates exporting the wrong plan, beyond its misleading header.
      await tester.tap(find.text(S(lang)('exportWeekToList')));
      await tester.pumpAndSettle();
      final expected = AppState(store: MemoryStore(), corpus: state.corpus);
      addTearDown(expected.dispose);
      await expected.load();
      await expected.addToShoppingList([
        (state.loadedRecipeById('doener-classic')!, 1.0),
      ]);
      final reloaded = AppState(store: state.store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      final expectedLines = expected.shoppingList
          .map((item) => item.toJson()..remove('added_at'))
          .toList();
      for (final snapshot in [state, reloaded]) {
        expect(
          snapshot.shoppingList
              .map((item) => item.toJson()..remove('added_at'))
              .toList(),
          expectedLines,
        );
        expect(snapshot.mealPlan, state.mealPlan);
      }
      expect(find.textContaining('2026-W13'), findsOneWidget);
      expect(find.text('${S(lang)('mon')} 23.3.'), findsOneWidget);
      expect(find.text('${S(lang)('tue')} 24.3.'), findsOneWidget);
    });
  }
  for (final rollover in [false, true]) {
    testWidgets('drag stays in displayed week; rollover=$rollover', (
      tester,
    ) async {
      final state = (await tester.runAsync(stateForTest))!;
      addTearDown(state.dispose);
      var now = DateTime(2026, 10, 18, 23, 59, 50);
      await tester.pumpWidget(
        app(state, Scaffold(body: MealPlanScreen(now: () => now))),
      );
      await tester.pumpAndSettle();
      final source = find.byType(LongPressDraggable<MealPlanDrag>).first;
      final destination = find.byType(DragTarget<MealPlanDrag>).at(1);
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 650));
      await gesture.moveTo(tester.getCenter(destination));
      await tester.pump();
      if (rollover) now = DateTime(2026, 10, 19, 0, 0, 10);
      // The visible grid and drag are still W42; no provider update was needed.
      expect(find.textContaining('2026-W42'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      final reloaded = AppState(store: state.store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      final expected = {
        '2026-W42': {'mon.lunch': 'doener-classic'},
        '2026-W43': {'mon.breakfast': 'doener-vegan'},
      };
      expect([state.mealPlan, reloaded.mealPlan], [expected, expected]);
    });

    testWidgets('export stays in displayed week; rollover=$rollover', (
      tester,
    ) async {
      final state = (await tester.runAsync(stateForTest))!;
      addTearDown(state.dispose);
      var now = DateTime(2026, 10, 18, 23, 59, 50);
      await tester.pumpWidget(
        app(state, Scaffold(body: MealPlanScreen(now: () => now))),
      );
      await tester.pumpAndSettle();
      if (rollover) now = DateTime(2026, 10, 19, 0, 0, 10);
      expect(find.textContaining('2026-W42'), findsOneWidget);
      await tester.tap(find.text(S('en')('exportWeekToList')));
      await tester.pumpAndSettle();
      final expected = AppState(store: MemoryStore(), corpus: state.corpus);
      addTearDown(expected.dispose);
      await expected.load();
      await expected.addToShoppingList([
        (state.loadedRecipeById('doener-classic')!, 1.0),
      ]);
      final actualLines = state.shoppingList
          .map((item) => item.toJson()..remove('added_at'))
          .toList();
      final expectedLines = expected.shoppingList
          .map((item) => item.toJson()..remove('added_at'))
          .toList();
      final reloaded = AppState(store: state.store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(
        reloaded.shoppingList
            .map((item) => item.toJson()..remove('added_at'))
            .toList(),
        actualLines,
      );
      expect(actualLines, expectedLines);
    });
  }

  // Run with TZ=Europe/Berlin to exercise the one-hour DST transitions.
  testWidgets('previous week across spring DST starts stays on Monday', (
    tester,
  ) async {
    final state = (await tester.runAsync(stateForTest))!;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      app(
        state,
        Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 3, 30))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-W13'), findsOneWidget);
    expect(find.text('mon 23.3.'), findsOneWidget);
    expect(find.text('tue 24.3.'), findsOneWidget);
  });

  testWidgets('next week across Europe Berlin DST ends advances to W44', (
    tester,
  ) async {
    final state = (await tester.runAsync(stateForTest))!;
    addTearDown(state.dispose);
    await tester.pumpWidget(
      app(
        state,
        Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 10, 19))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-W43'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.textContaining('2026-W44'), findsOneWidget);
    expect(find.text('mon 26.10.'), findsOneWidget);
    expect(find.text('tue 27.10.'), findsOneWidget);
  });
}

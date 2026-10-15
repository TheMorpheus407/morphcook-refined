import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/strings.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

Future<AppState> stateForTest() async {
  final state = AppState(store: MemoryStore(), corpus: await loadRealCorpus());
  await state.load();
  await state.completeOnboarding(const Profile(lang: 'en'));
  await state.assignMeal('2026-W42', 'mon.breakfast', 'doener-classic');
  await state.assignMeal('2026-W43', 'mon.breakfast', 'doener-vegan');
  return state;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
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

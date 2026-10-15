import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/main.dart' show RootShell;
import 'package:morphcook/models/collections.dart';
import 'package:morphcook/models/profile.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _PausedRestoreStore extends MemoryStore {
  bool pause = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> putCollections(Map<String, String> values) async {
    if (pause) {
      pause = false;
      entered.complete();
      await release.future;
    }
    await super.putCollections(values);
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final occupiedDestination in [false, true]) {
      for (final replacesSource in [false, true]) {
        for (final restoreBeforeDrop in [false, true]) {
          testWidgets(
            '$lang meal drag keeps displayed identity: occupied=$occupiedDestination replacement=$replacesSource restoreBeforeDrop=$restoreBeforeDrop',
            (tester) async {
              final store = _PausedRestoreStore();
              final state = (await tester.runAsync(() async {
                final state = AppState(
                  store: store,
                  corpus: await loadRealCorpus(),
                );
                await state.load();
                await state.completeOnboarding(Profile(lang: lang));
                return state;
              }))!;
              addTearDown(state.dispose);
              addTearDown(() {
                if (!store.release.isCompleted) store.release.complete();
              });
              final week = isoWeekKey(weekStart(DateTime.now()));
              const source = 'mon.breakfast';
              const destination = 'mon.lunch';
              const displayedRecipe = 'doener-classic';
              const replacementRecipe = 'doener-vegan';
              const destinationRecipe = 'curry-chickpea';
              await state.assignMeal(week, source, displayedRecipe);
              if (occupiedDestination) {
                await state.assignMeal(week, destination, destinationRecipe);
              }
              await tester.pumpWidget(app(state, const RootShell()));
              await tester.pumpAndSettle();
              await tester.tap(find.byIcon(Icons.tune));
              await tester.pumpAndSettle();

              store.pause = true;
              final restoring = state.applyBackup(
                BackupData(
                  profile: Profile(lang: lang),
                  saved: const [],
                  history: const [],
                  mealPlan: {
                    week: {
                      source: replacesSource
                          ? replacementRecipe
                          : displayedRecipe,
                      if (occupiedDestination) destination: destinationRecipe,
                    },
                  },
                ),
                merge: false,
              );
              await store.entered.future;
              // The owner can switch from the restoring Settings tab to Meal Plan.
              await tester.tap(find.byIcon(Icons.calendar_today_outlined));
              await tester.pumpAndSettle();
              final displayedTitle = state
                  .loadedRecipeById(displayedRecipe)!
                  .title
                  .of(lang);
              expect(find.text(displayedTitle), findsOneWidget);
              final dragged = find
                  .byWidgetPredicate((widget) => widget is LongPressDraggable)
                  .first;
              final dropTarget = find
                  .byWidgetPredicate((widget) => widget is DragTarget)
                  .at(1);
              final gesture = await tester.startGesture(
                tester.getCenter(dragged),
              );
              await tester.pump(const Duration(milliseconds: 650));
              await gesture.moveTo(tester.getCenter(dropTarget));
              await tester.pump();
              if (restoreBeforeDrop) {
                store.release.complete();
                await restoring;
                await tester.pump();
              }
              await gesture.up();
              await tester.pump();
              if (!restoreBeforeDrop) {
                expect(state.mealPlan[week]![source], displayedRecipe);
                store.release.complete();
                await restoring;
              }
              await tester.pumpAndSettle();

              final reloaded = AppState(store: store, corpus: state.corpus);
              addTearDown(reloaded.dispose);
              await reloaded.load();
              final expected = replacesSource
                  ? {
                      source: replacementRecipe,
                      if (occupiedDestination) destination: destinationRecipe,
                    }
                  : {
                      if (occupiedDestination) source: destinationRecipe,
                      destination: displayedRecipe,
                    };
              expect(state.mealPlan, {week: expected});
              expect(reloaded.mealPlan, {week: expected});
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}

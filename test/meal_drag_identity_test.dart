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
  for (final replacesSource in [false, true]) {
    for (final restoreBeforeDrop in [false, true]) {
      testWidgets(
        'meal drag keeps displayed identity: replacement=$replacesSource restoreBeforeDrop=$restoreBeforeDrop',
        (tester) async {
          final store = _PausedRestoreStore();
          final state = (await tester.runAsync(() async {
            final state = AppState(
              store: store,
              corpus: await loadRealCorpus(),
            );
            await state.load();
            await state.completeOnboarding(const Profile());
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
          await state.assignMeal(week, source, displayedRecipe);
          await tester.pumpWidget(app(state, const RootShell()));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.tune));
          await tester.pumpAndSettle();

          store.pause = true;
          final restoring = state.applyBackup(
            BackupData(
              profile: const Profile(),
              saved: const [],
              history: const [],
              mealPlan: {
                week: {
                  source: replacesSource ? replacementRecipe : displayedRecipe,
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
              .of('en');
          expect(find.text(displayedTitle.toLowerCase()), findsOneWidget);
          final dragged = find
              .byWidgetPredicate((widget) => widget is LongPressDraggable)
              .first;
          final dropTarget = find
              .byWidgetPredicate((widget) => widget is DragTarget)
              .at(1);
          final gesture = await tester.startGesture(tester.getCenter(dragged));
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
          // A stale drag must at least preserve the restored replacement's slot.
          if (replacesSource) {
            expect(state.mealPlan[week]![source], replacementRecipe);
            expect(state.mealPlan[week]![destination], isNull);
            expect(reloaded.mealPlan[week]![source], replacementRecipe);
            expect(reloaded.mealPlan[week]![destination], isNull);
          } else {
            expect(state.mealPlan[week]![source], isNull);
            expect(state.mealPlan[week]![destination], displayedRecipe);
            expect(reloaded.mealPlan[week]![destination], displayedRecipe);
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

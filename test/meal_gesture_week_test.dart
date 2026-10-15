import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/meal_plan_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class PausedRestoreStore extends MemoryStore {
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

Future<AppState> makeState({MemoryStore? store, String lang = 'en'}) async {
  final state = AppState(
    store: store ?? MemoryStore(),
    corpus: await loadRealCorpus(),
  );
  await state.load();
  await state.completeOnboarding(Profile(lang: lang));
  await state.assignMeal('2026-W42', 'mon.breakfast', 'doener-classic');
  await state.assignMeal('2026-W43', 'mon.breakfast', 'doener-vegan');
  return state;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final rollover in [false, true]) {
      for (final forward in [false, true]) {
        testWidgets(
          '$lang navigation follows displayed week rollover=$rollover forward=$forward',
          (tester) async {
            final state = (await tester.runAsync(() => makeState(lang: lang)))!;
            addTearDown(state.dispose);
            var now = DateTime(2026, 10, 18, 23, 59, 50);
            await tester.pumpWidget(
              app(state, Scaffold(body: MealPlanScreen(now: () => now))),
            );
            await tester.pumpAndSettle();
            expect(find.textContaining('2026-W42'), findsOneWidget);
            if (rollover) now = DateTime(2026, 10, 19, 0, 0, 10);
            await tester.tap(
              find.byIcon(forward ? Icons.chevron_right : Icons.chevron_left),
            );
            await tester.pumpAndSettle();
            final expected = forward ? '2026-W43' : '2026-W41';
            expect(find.textContaining(expected), findsOneWidget);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
    for (final replacement in [false, true]) {
      testWidgets(
        '$lang long-press retains pointer-down recipe replacement=$replacement',
        (tester) async {
          final store = PausedRestoreStore();
          final state = (await tester.runAsync(
            () => makeState(store: store, lang: lang),
          ))!;
          addTearDown(state.dispose);
          addTearDown(() {
            if (!store.release.isCompleted) store.release.complete();
          });
          await tester.pumpWidget(
            app(
              state,
              Scaffold(body: MealPlanScreen(now: () => DateTime(2026, 10, 15))),
            ),
          );
          await tester.pumpAndSettle();
          store.pause = true;
          final incoming = {
            '2026-W42': {
              'mon.breakfast': replacement ? 'doener-vegan' : 'doener-classic',
            },
            '2026-W43': {'mon.breakfast': 'doener-vegan'},
          };
          final restoring = state.applyBackup(
            BackupData(
              profile: Profile(lang: lang),
              saved: const [],
              history: const [],
              mealPlan: incoming,
            ),
            merge: false,
          );
          await store.entered.future;
          final gesture = await tester.startGesture(
            tester.getCenter(
              find.byType(LongPressDraggable<MealPlanDrag>).first,
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          store.release.complete();
          await restoring;
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 600));
          await gesture.moveTo(
            tester.getCenter(find.byType(DragTarget<MealPlanDrag>).at(1)),
          );
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          final reloaded = AppState(store: store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          final expected = replacement
              ? incoming
              : {
                  '2026-W42': {'mon.lunch': 'doener-classic'},
                  '2026-W43': {'mon.breakfast': 'doener-vegan'},
                };
          expect(state.mealPlan, expected);
          expect(reloaded.mealPlan, expected);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    for (final rollover in [false, true]) {
      testWidgets(
        '$lang export retains pointer-down week through restore rollover=$rollover',
        (tester) async {
          final store = PausedRestoreStore();
          final state = (await tester.runAsync(
            () => makeState(store: store, lang: lang),
          ))!;
          addTearDown(state.dispose);
          addTearDown(() {
            if (!store.release.isCompleted) store.release.complete();
          });
          var now = DateTime(2026, 10, 18, 23, 59, 50);
          await tester.pumpWidget(
            app(state, Scaffold(body: MealPlanScreen(now: () => now))),
          );
          await tester.pumpAndSettle();
          store.pause = true;
          final restoring = state.applyBackup(
            state.buildBackup(),
            merge: false,
          );
          await store.entered.future;
          final gesture = await tester.startGesture(
            tester.getCenter(find.text(S(lang)('exportWeekToList'))),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (rollover) now = DateTime(2026, 10, 19, 0, 0, 10);
          store.release.complete();
          await restoring;
          await tester.pump(const Duration(milliseconds: 16));
          await gesture.up();
          await tester.pumpAndSettle();
          final expected = AppState(store: MemoryStore(), corpus: state.corpus);
          addTearDown(expected.dispose);
          await expected.load();
          await expected.addToShoppingList([
            (state.loadedRecipeById('doener-classic')!, 1.0),
          ]);
          final reloaded = AppState(store: store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          List<Object> lines(AppState s) => s.shoppingList
              .map((i) => i.toJson()..remove('added_at'))
              .toList();
          expect(lines(reloaded), lines(state));
          expect(lines(state), lines(expected));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

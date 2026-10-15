import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/main.dart' show RootShell;
import 'package:morphcook/models/collections.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/strings.dart';
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
  for (final change in [
    'unchanged',
    'replaced',
    'removed',
    'initially empty',
  ]) {
    test(
      'direct removal captures identity before queued restore: $change',
      () async {
        final store = _PausedRestoreStore();
        final state = AppState(store: store, corpus: await loadRealCorpus());
        addTearDown(state.dispose);
        await state.load();
        const week = '2026-W42';
        const slot = 'mon.breakfast';
        const displayed = 'doener-classic';
        const replacement = 'doener-vegan';
        if (change != 'initially empty') {
          await state.assignMeal(week, slot, displayed);
        }
        store.pause = true;
        final restoring = state.applyBackup(
          BackupData(
            profile: const Profile(),
            saved: const [],
            history: const [],
            mealPlan: {
              week: {
                if (change != 'removed')
                  slot: change == 'unchanged' ? displayed : replacement,
                'tue.dinner': displayed,
              },
            },
          ),
          merge: false,
        );
        addTearDown(() async {
          if (!store.release.isCompleted) store.release.complete();
          await restoring;
        });
        await store.entered.future.timeout(const Duration(seconds: 5));
        final removing = state.clearMeal(week, slot);
        store.release.complete();
        await Future.wait([restoring, removing]);
        final reloaded = AppState(store: store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        for (final snapshot in [state, reloaded]) {
          expect(snapshot.mealPlan, {
            week: {
              if (change == 'replaced' || change == 'initially empty')
                slot: replacement,
              'tue.dinner': displayed,
            },
          });
        }
      },
    );
  }
  for (final lang in ['en', 'de']) {
    for (final replace in [false, true]) {
      for (final restoreTiming in [
        'before tap',
        'during tap rebuild',
        'before Remove',
        'after Remove',
      ]) {
        testWidgets(
          '$lang removal during restore replacement=$replace timing=$restoreTiming',
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
            const slot = 'mon.breakfast';
            const displayed = 'doener-classic';
            const replacement = 'doener-vegan';
            await state.assignMeal(week, slot, displayed);
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
                  week: {slot: replace ? replacement : displayed},
                },
              ),
              merge: false,
            );
            await store.entered.future;
            await tester.tap(find.byIcon(Icons.calendar_today_outlined));
            await tester.pumpAndSettle();
            final title = state.loadedRecipeById(displayed)!.title.of(lang);
            expect(find.text(title), findsOneWidget);
            if (restoreTiming == 'before tap' ||
                restoreTiming == 'during tap rebuild') {
              final pointer = await tester.startGesture(
                tester.getCenter(find.text(title)),
              );
              store.release.complete();
              await restoring;
              // Exercise both event orderings around the provider rebuild.
              if (restoreTiming == 'during tap rebuild') {
                await tester.pump(const Duration(milliseconds: 16));
              }
              await pointer.up();
            } else {
              await tester.tap(find.text(title));
            }
            await tester.pumpAndSettle();
            if (restoreTiming == 'before Remove') {
              store.release.complete();
              await restoring;
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text(S(lang)('removeFromSlot')));
            await tester.pumpAndSettle();
            if (restoreTiming == 'after Remove') {
              expect(state.mealPlan[week]![slot], displayed);
              store.release.complete();
              await restoring;
            }
            await tester.pumpAndSettle();
            final reloaded = AppState(store: store, corpus: state.corpus);
            addTearDown(reloaded.dispose);
            await reloaded.load();
            expect(
              [state.mealPlan[week]?[slot], reloaded.mealPlan[week]?[slot]],
              [replace ? replacement : isNull, replace ? replacement : isNull],
              reason:
                  'Removing the displayed old meal must preserve a different restored meal',
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}

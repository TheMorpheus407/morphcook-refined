import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/cook/cook_controller.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/cook_mode_screen.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/strings.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _DelayedProgressStore extends MemoryStore {
  bool armed = false;
  bool afterWrite = false;
  bool fail = false;
  bool recovering = false;
  int writes = 0;
  final recoveryEntered = Completer<void>();
  final recoveryRelease = Completer<void>();
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> putCollection(String key, String jsonText) async {
    if (key == 'cook_progress') writes++;
    if (key == 'cook_progress' && recovering) {
      recovering = false;
      recoveryEntered.complete();
      await recoveryRelease.future;
    }
    if (key == 'cook_progress' && armed) {
      armed = false;
      if (afterWrite) await super.putCollection(key, jsonText);
      entered.complete();
      await release.future;
      if (fail) {
        recovering = true;
        throw StateError('progress rejected');
      }
    }
    await super.putCollection(key, jsonText);
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final afterWrite in [false, true]) {
      for (final outcome in ['save', 'failure', 'clear', 'timer']) {
        testWidgets(
          '$lang reopen during progress $outcome afterWrite=$afterWrite',
          (tester) async {
            final store = _DelayedProgressStore()
              ..afterWrite = afterWrite
              ..fail = outcome == 'failure';
            final state = (await tester.runAsync(() async {
              final state = AppState(
                store: store,
                corpus: await loadRealCorpus(),
              );
              await state.load();
              await state.completeOnboarding(Profile(lang: lang));
              await state.persistCookProgress(
                CookProgress(
                  recipeId: 'doener-classic',
                  stepIndex: outcome == 'clear' ? 1 : 0,
                  servings: 2,
                ),
              );
              return state;
            }))!;
            addTearDown(state.dispose);
            addTearDown(() {
              if (!store.release.isCompleted) store.release.complete();
              if (!store.recoveryRelease.isCompleted) {
                store.recoveryRelease.complete();
              }
            });
            final recipe = (await tester.runAsync(
              () => state.recipeById('doener-classic'),
            ))!;
            await tester.pumpWidget(
              app(
                state,
                Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      child: const Text('open cook'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CookModeScreen(recipe: recipe),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('open cook'));
            await tester.pumpAndSettle();
            store.armed = true;
            Future<void>? clear;
            if (outcome == 'clear') {
              clear = state.persistCookProgress(null);
            } else if (outcome == 'timer') {
              clear = state.persistCookProgress(
                const CookProgress(
                  recipeId: 'doener-classic',
                  stepIndex: 1,
                  servings: 4,
                  remainingTimerSeconds: 37,
                ),
              );
            } else {
              await tester.tap(find.byType(FilledButton));
            }
            await tester.pump();
            expect(store.entered.isCompleted, isTrue);
            // Another navigation while the first write waits must also settle.
            if (outcome == 'save') {
              await tester.tap(find.byType(FilledButton));
              await tester.pump();
            }
            await tester.tap(find.byIcon(Icons.close));
            await tester.pumpAndSettle();
            await tester.tap(find.text('open cook'));
            await tester.pump();
            // Confirmed resume data remains unchanged while native storage waits.
            expect(state.cookProgress?.stepIndex, outcome == 'clear' ? 1 : 0);
            expect(find.byType(FilledButton), findsNothing);
            expect(find.byIcon(Icons.add), findsNothing);
            store.release.complete();
            if (outcome == 'failure') {
              await tester.pump();
              expect(store.recoveryEntered.isCompleted, isTrue);
              expect(find.byType(FilledButton), findsNothing);
              expect(state.cookProgress?.stepIndex, 0);
              store.recoveryRelease.complete();
            }
            await tester.pumpAndSettle();
            if (clear != null) await clear;
            final expectedStep = outcome == 'save'
                ? 2
                : outcome == 'timer'
                ? 1
                : 0;
            final expectedServings = outcome == 'timer' ? 4 : 2;
            if (outcome == 'timer') {
              expect(find.text('00:37'), findsOneWidget);
              expect(
                find.widgetWithText(TextButton, S(lang)('resume')),
                findsOneWidget,
              );
            }
            expect(find.text('${expectedStep + 1}.'), findsOneWidget);
            expect(find.text('$expectedServings'), findsOneWidget);
            await tester.tap(find.byIcon(Icons.add));
            await tester.pumpAndSettle();
            expect(state.cookProgress?.stepIndex, expectedStep);
            expect(state.cookProgress?.servings, expectedServings + 1);
            if (outcome == 'timer') {
              expect(state.cookProgress?.remainingTimerSeconds, 37);
            }
            expect(
              jsonDecode(store.getCollection('cook_progress')!),
              state.cookProgress?.toJson(),
            );
            final reloaded = (await tester.runAsync(() async {
              final reloaded = AppState(store: store, corpus: state.corpus);
              await reloaded.load();
              return reloaded;
            }))!;
            addTearDown(reloaded.dispose);
            expect(reloaded.cookProgress?.stepIndex, expectedStep);
            expect(reloaded.cookProgress?.servings, expectedServings + 1);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
    for (final clearing in [false, true]) {
      testWidgets(
        '$lang detail refreshes after confirmed progress clear=$clearing',
        (tester) async {
          final store = _DelayedProgressStore();
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
          final recipe = (await tester.runAsync(
            () => state.bestVariant('doener'),
          ))!;
          final progress = CookProgress(
            recipeId: recipe.id,
            stepIndex: 1,
            servings: 2,
          );
          if (clearing) await state.persistCookProgress(progress);
          await tester.pumpWidget(
            app(state, DishDetailScreen(dishId: recipe.dishId)),
          );
          await tester.pumpAndSettle();
          final before = S(lang)(clearing ? 'resumeCooking' : 'startCooking');
          final after = S(lang)(clearing ? 'startCooking' : 'resumeCooking');
          await tester.scrollUntilVisible(find.text(before), 400);
          await tester.pumpAndSettle();
          expect(find.text(before), findsOneWidget);
          store.armed = true;
          final saved = state.persistCookProgress(clearing ? null : progress);
          await tester.pump();
          expect(store.entered.isCompleted, isTrue);
          expect(find.text(before), findsOneWidget);
          expect(find.text(after), findsNothing);
          store.release.complete();
          await saved;
          await tester.pumpAndSettle();
          expect(find.text(after), findsOneWidget);
          expect(find.text(before), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    for (final enabled in [false, true]) {
      testWidgets('$lang queued quick-tap setting becomes $enabled', (
        tester,
      ) async {
        final store = _DelayedProgressStore();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(
            Profile(lang: lang, quickNextTapEnabled: !enabled),
          );
          return state;
        }))!;
        addTearDown(state.dispose);
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
        });
        final recipe = (await tester.runAsync(
          () => state.recipeById('doener-classic'),
        ))!;
        store.armed = true;
        final progress = state.persistCookProgress(
          const CookProgress(
            recipeId: 'doener-classic',
            stepIndex: 0,
            servings: 2,
          ),
        );
        final profile = state.editProfile(
          (p) => p.copyWith(quickNextTapEnabled: enabled),
        );
        await tester.pumpWidget(app(state, CookModeScreen(recipe: recipe)));
        expect(find.byType(FilledButton), findsNothing);
        store.release.complete();
        await tester.pumpAndSettle();
        await progress;
        await profile;
        expect(state.profile.quickNextTapEnabled, enabled);
        expect(
          find.text(S(lang)('quickTapHint')),
          enabled ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text(recipe.steps[0].text.of(lang)));
        await tester.pumpAndSettle();
        expect(find.text(enabled ? '2.' : '1.'), findsOneWidget);
        expect(state.cookProgress?.stepIndex, enabled ? 1 : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
    for (final navigation in ['close', 'back']) {
      testWidgets('$lang $navigation while waiting for resume', (tester) async {
        final store = _DelayedProgressStore();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          return state;
        }))!;
        addTearDown(state.dispose);
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
        });
        final recipe = (await tester.runAsync(
          () => state.recipeById('doener-classic'),
        ))!;
        await tester.pumpWidget(app(state, const Scaffold(body: Text('home'))));
        store.armed = true;
        final saved = state.persistCookProgress(
          const CookProgress(
            recipeId: 'doener-classic',
            stepIndex: 1,
            servings: 4,
            remainingTimerSeconds: 37,
          ),
        );
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => CookModeScreen(recipe: recipe),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .semanticsLabel,
          S(lang)('loadingCookProgress'),
        );
        expect(find.byType(FilledButton), findsNothing);
        expect(find.byIcon(Icons.add), findsNothing);
        if (navigation == 'close') {
          await tester.tap(find.byIcon(Icons.close));
        } else {
          await navigator.maybePop();
        }
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);
        store.release.complete();
        await saved;
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);
        expect(find.byType(CookModeScreen), findsNothing);
        expect(state.cookProgress?.stepIndex, 1);
        expect(state.cookProgress?.servings, 4);
        expect(store.writes, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

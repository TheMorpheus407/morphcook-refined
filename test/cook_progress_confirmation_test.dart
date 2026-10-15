import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/cook/cook_controller.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/ui/screens/cook_mode_screen.dart';
import 'package:morphcook/ui/strings.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

const _old = CookProgress(
  recipeId: 'doener-classic',
  stepIndex: 0,
  servings: 2,
);
const _next = CookProgress(
  recipeId: 'doener-classic',
  stepIndex: 1,
  servings: 3,
);

class _ProgressStore extends MemoryStore {
  bool armed = false;
  bool afterWrite = false;
  bool fail = true;
  String failureKey = 'cook_progress';
  Completer<void>? entered;
  Completer<void>? release;
  final error = StateError('progress confirmation failed');
  @override
  Future<void> putCollection(String key, String jsonText) async {
    if (key == failureKey && armed) {
      armed = false;
      if (afterWrite) await super.putCollection(key, jsonText);
      entered?.complete();
      if (release != null) await release!.future;
      if (fail) throw error;
    }
    await super.putCollection(key, jsonText);
  }
}

Future<AppState> _load(_ProgressStore store) async {
  final state = AppState(store: store, corpus: await loadRealCorpus());
  await state.load();
  return state;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final afterWrite in [false, true]) {
    for (final action in ['start', 'update', 'clear', 'empty', 'malformed']) {
      test(
        '$action progress failure afterWrite=$afterWrite keeps raw resume',
        () async {
          final store = _ProgressStore()..afterWrite = afterWrite;
          final previous = switch (action) {
            'start' => null,
            'empty' => 'null',
            'malformed' => ' { broken JSON ',
            _ => jsonEncode({..._old.toJson(), 'future_field': 'keep me'}),
          };
          if (previous != null) {
            await store.putCollection('cook_progress', previous);
          }
          final state = await _load(store);
          addTearDown(state.dispose);
          final original = state.cookProgress?.toJson();
          final next = ['clear', 'empty'].contains(action) ? null : _next;
          store.armed = true;
          await expectLater(
            state.persistCookProgress(next),
            throwsA(same(store.error)),
          );
          expect(state.cookProgress?.toJson(), original);
          expect(store.getCollection('cook_progress'), previous);
          final reloaded = await _load(store);
          addTearDown(reloaded.dispose);
          expect(reloaded.cookProgress?.toJson(), original);
          await state.persistCookProgress(next);
          expect(state.cookProgress?.toJson(), next?.toJson());
          expect(
            jsonDecode(store.getCollection('cook_progress')!),
            next?.toJson(),
          );
        },
      );
    }

    test(
      'pending progress publishes only confirmed queued values: after=$afterWrite',
      () async {
        final store = _ProgressStore()..afterWrite = afterWrite;
        final state = await _load(store);
        addTearDown(state.dispose);
        await state.persistCookProgress(_old);
        store
          ..armed = true
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!store.release!.isCompleted) store.release!.complete();
        });
        final failed = expectLater(
          state.persistCookProgress(_next),
          throwsA(same(store.error)),
        );
        await store.entered!.future;
        final queued = state.persistCookProgress(null);
        final whilePending = state.cookProgress?.toJson();
        store.release!.complete();
        await failed;
        await queued;
        expect(whilePending, _old.toJson());
        expect(state.cookProgress, isNull);
        expect(store.getCollection('cook_progress'), 'null');
        await state.persistCookProgress(_next);
        expect(state.cookProgress?.toJson(), _next.toJson());
      },
    );
  }

  for (final key in ['history', 'cook_progress']) {
    for (final afterWrite in [false, true]) {
      test(
        'completion failure restores history and progress: $key after=$afterWrite',
        () async {
          final store = _ProgressStore()..afterWrite = afterWrite;
          final state = await _load(store);
          addTearDown(state.dispose);
          await state.logCooked('doener-vegan');
          await state.persistCookProgress(_old);
          final rawHistory = store.getCollection('history');
          final rawProgress = store.getCollection('cook_progress');
          store
            ..failureKey = key
            ..armed = true;
          await expectLater(
            state.logCooked(_old.recipeId),
            throwsA(same(store.error)),
          );
          expect(state.history.map((e) => e.recipeId), ['doener-vegan']);
          expect(state.cookProgress?.toJson(), _old.toJson());
          expect(store.getCollection('history'), rawHistory);
          expect(store.getCollection('cook_progress'), rawProgress);
          final reloaded = await _load(store);
          addTearDown(reloaded.dispose);
          expect(reloaded.history.map((e) => e.recipeId), ['doener-vegan']);
          expect(reloaded.cookProgress?.toJson(), _old.toJson());
          await state.logCooked(_old.recipeId);
          expect(state.history, hasLength(2));
          expect(state.cookProgress, isNull);
          expect(store.getCollection('cook_progress'), 'null');
        },
      );
    }
  }

  for (final previousMatches in [false, true]) {
    for (final fails in [false, true]) {
      test(
        'scoped clear checks settled owner: previousMatches=$previousMatches fails=$fails',
        () async {
          final store = _ProgressStore()..afterWrite = true;
          const other = CookProgress(
            recipeId: 'doener-vegan',
            stepIndex: 1,
            servings: 4,
            remainingTimerSeconds: 37,
          );
          final previous = previousMatches ? _old : other;
          final next = previousMatches ? other : _next;
          // Preserve unknown fields and formatting if the earlier save fails.
          final raw = ' ${jsonEncode({...previous.toJson(), 'future': true})} ';
          await store.putCollection('cook_progress', raw);
          final state = await _load(store);
          addTearDown(state.dispose);
          store
            ..fail = fails
            ..armed = true
            ..entered = Completer<void>()
            ..release = Completer<void>();
          addTearDown(() {
            if (!store.release!.isCompleted) store.release!.complete();
          });
          final save = state.persistCookProgress(next);
          final settledSave = fails
              ? expectLater(save, throwsA(same(store.error)))
              : save;
          await store.entered!.future;
          var notifications = 0;
          state.addListener(() => notifications++);
          final clear = state.clearCookProgressForRecipe(_old.recipeId);
          expect(state.cookProgress?.toJson(), previous.toJson());
          expect(notifications, 0);
          store.release!.complete();
          await settledSave;
          await clear;
          final confirmed = fails ? previous : next;
          final clears = confirmed.recipeId == _old.recipeId;
          expect(
            state.cookProgress?.toJson(),
            clears ? null : confirmed.toJson(),
          );
          expect(
            store.getCollection('cook_progress'),
            clears ? 'null' : (fails ? raw : jsonEncode(next.toJson())),
          );
          expect(notifications, (fails ? 0 : 1) + (clears ? 1 : 0));
          final reloaded = await _load(store);
          addTearDown(reloaded.dispose);
          expect(reloaded.cookProgress?.toJson(), state.cookProgress?.toJson());
        },
      );
    }
  }

  test('logging another recipe keeps the active resume state', () async {
    final store = _ProgressStore();
    final state = await _load(store);
    addTearDown(state.dispose);
    await state.persistCookProgress(_old);
    final raw = store.getCollection('cook_progress');
    await state.logCooked('doener-vegan');
    expect(state.cookProgress?.toJson(), _old.toJson());
    expect(store.getCollection('cook_progress'), raw);
  });

  testWidgets(
    'finishing another recipe preserves confirmed resume through reload',
    (tester) async {
      final store = _ProgressStore();
      final state = (await tester.runAsync(() async {
        final state = await _load(store);
        await state.savePersonalRecipe(
          PersonalRecipe(
            id: 'personal-0123456789abcdef0123456789abcdef',
            title: 'One step recipe',
            timeMinutes: 1,
            servings: 2,
            ingredients: [
              PersonalRecipeIngredient(name: 'Water', qty: 1, unit: 'ml'),
            ],
            steps: [PersonalRecipeStep(text: 'Drink.')],
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
        await state.persistCookProgress(
          const CookProgress(
            recipeId: 'doener-classic',
            stepIndex: 2,
            servings: 4,
            remainingTimerSeconds: 37,
          ),
        );
        return state;
      }))!;
      addTearDown(state.dispose);
      final before = state.cookProgress!.toJson();
      final raw = store.getCollection('cook_progress');
      await tester.pumpWidget(
        app(
          state,
          CookModeScreen(recipe: state.personalRecipes.single.asRecipe()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton)); // Finish, before Done.
      await tester.pumpAndSettle();
      expect(state.history, isEmpty);
      expect(state.cookProgress?.toJson(), before);
      expect(store.getCollection('cook_progress'), raw);
      final reloaded = (await tester.runAsync(() => _load(store)))!;
      addTearDown(reloaded.dispose);
      expect(reloaded.cookProgress?.toJson(), before);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final lang in ['en', 'de']) {
    for (final action in ['servings', 'complete']) {
      testWidgets('$lang $action progress failure reports error and recovers', (
        tester,
      ) async {
        final store = _ProgressStore()..afterWrite = true;
        final state = (await tester.runAsync(() async {
          final state = await _load(store);
          await state.completeOnboarding(Profile(lang: lang));
          await state.persistCookProgress(_old);
          return state;
        }))!;
        addTearDown(state.dispose);
        Widget screen() => app(
          state,
          CookModeScreen(recipe: makeRecipe(id: 'doener-classic')),
        );
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        store.armed = true;
        await tester.tap(
          action == 'servings'
              ? find.byIcon(Icons.add)
              : find.byType(FilledButton),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(S(lang)('collectionSaveFailed')), findsOneWidget);
        expect(state.cookProgress?.toJson(), _old.toJson());
        expect(
          jsonDecode(store.getCollection('cook_progress')!),
          _old.toJson(),
        );
        if (action == 'servings') {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(screen());
          await tester.pumpAndSettle();
          expect(find.text('2'), findsOneWidget);
          await tester.tap(find.byIcon(Icons.add));
          await tester.pumpAndSettle();
          expect(state.cookProgress?.servings, 3);
        } else {
          ScaffoldMessenger.of(
            tester.element(find.byType(FilledButton)),
          ).removeCurrentSnackBar();
          await tester.pumpAndSettle();
          await tester.tap(find.byType(FilledButton));
          await tester.pumpAndSettle();
          expect(state.history, hasLength(1));
          expect(state.cookProgress, isNull);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

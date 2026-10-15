import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';

import 'helpers.dart';

class _FailingBackupStore extends MemoryStore {
  String? failure;

  @override
  Future<void> setOnboardingComplete(bool value) async {
    await super.setOnboardingComplete(value);
    if (failure == 'after onboarding write') {
      failure = null;
      throw StateError('injected import failure after onboarding');
    }
  }

  @override
  Future<void> putRecipeImageBytesBatch(Map<String, Uint8List> images) async {
    if (failure == 'before any collection write') {
      failure = null;
      throw StateError('injected import failure before collections');
    }
    await super.putRecipeImageBytesBatch(images);
  }

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    await super.putCollections(collections);
    if (failure == 'after collection write') {
      failure = null;
      throw StateError('injected import failure after collections');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final merge in [false, true]) {
    test(
      'late backup failure restores raw non-photo collections: merge=$merge',
      () async {
        const rawCollections = {
          'saved':
              '[ {"recipe_id":"doener-vegan",'
              '"saved_at":"2026-10-01T12:00:00.000","future_field":42} ]',
          'history':
              '[ {"recipe_id":"doener-vegan",'
              '"cooked_at":"2026-10-01T12:00:00.000","future_field":42} ]',
          'meal_plan': '{ "2026-W40": {"mon.dinner": 42} }',
          'shopping_list': '[ {"future_field":42}, null ]',
          'shopping_history': '[ {"future_field":42}, null ]',
          'content_requests': '[ "legacy", 42 ]',
          'personal_recipes': '[ {"future_field":42} ]',
          'expert_assessments': '[ {"future_field":42} ]',
          'cook_progress': '{ "future_field":42 }',
        };
        final store = _FailingBackupStore();
        await store.putCollections(rawCollections);
        const original = Profile(name: 'Before', lang: 'de');
        await store.saveProfile(original);
        final state = AppState(store: store, corpus: await loadRealCorpus());
        addTearDown(state.dispose);
        await state.load();
        expect(state.saved, hasLength(1));
        expect(state.history, hasLength(1));
        final before = state.buildBackup().toJson(DateTime.utc(2026));
        var notifications = 0;
        state.addListener(() => notifications++);
        const incoming = BackupData(
          profile: Profile(name: 'Incoming'),
          saved: [],
          mealPlan: {},
          history: [],
        );
        store.failure = 'after onboarding write';
        await expectLater(
          state.applyBackup(incoming, merge: merge),
          throwsStateError,
        );
        for (final entry in rawCollections.entries) {
          expect(
            store.getCollection(entry.key),
            entry.value,
            reason: entry.key,
          );
        }
        expect(notifications, 0);
        expect(state.buildBackup().toJson(DateTime.utc(2026)), before);
        expect(store.loadProfile()!.toJson(), original.toJson());
        expect(store.onboardingComplete, isFalse);
        final reloaded = AppState(store: store, corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.buildBackup().toJson(DateTime.utc(2026)), before);
        expect(reloaded.onboarded, isFalse);

        await state.applyBackup(incoming, merge: merge);
        expect(notifications, 1);
        expect(state.profile.name, 'Incoming');
        expect(store.onboardingComplete, isTrue);
        expect(state.saved, hasLength(merge ? 1 : 0));
        expect(state.history, hasLength(merge ? 1 : 0));
      },
    );

    for (final stage in [
      'before any collection write',
      'after collection write',
    ]) {
      test(
        'failed backup preserves recoverable history: merge=$merge, $stage',
        () async {
          const raw =
              '[ {"recipe_id":"doener-classic","cooked_at":"2026-10-01T12:00:00.000"},'
              '{"recipe_id":"doener-vegan","cooked_at":null,"future_field":42} ]';
          final store = _FailingBackupStore();
          await store.putCollection('history', raw);
          const requestsRaw = '[ "legacy", 42 ]';
          await store.putCollection('content_requests', requestsRaw);
          final state = AppState(store: store, corpus: await loadRealCorpus());
          addTearDown(state.dispose);
          await state.load();
          expect(
            state.history,
            isEmpty,
            reason: 'tolerant reader hides malformed collection',
          );
          expect(jsonDecode(raw), hasLength(2));
          store.failure = stage;
          await expectLater(
            state.applyBackup(
              BackupData(
                profile: const Profile(),
                saved: const [],
                mealPlan: const {},
                history: const [],
                recipeImages: [
                  RecipeImage(
                    recipeId: 'doener-vegan',
                    bytes: testPngBytes(),
                    updatedAt: DateTime.utc(2026),
                  ),
                ],
              ),
              merge: merge,
            ),
            throwsStateError,
          );
          expect(
            store.getCollection('history'),
            raw,
            reason:
                'failed import must not permanently erase the valid first record',
          );
          expect(store.getCollection('content_requests'), requestsRaw);
          for (final key in [
            'saved',
            'meal_plan',
            'shopping_list',
            'shopping_history',
            'personal_recipes',
            'expert_assessments',
            'cook_progress',
          ]) {
            expect(store.getCollection(key), isNull, reason: '$key was absent');
          }
          final reloaded = AppState(store: store, corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          expect(store.getCollection('history'), raw);
        },
      );
    }
  }
}

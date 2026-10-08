import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';

import 'helpers.dart';

const _id = 'doener-vegan';
const _otherId = 'doener-classic';
const _incomingId = 'pad-thai-vegan';

RecipeImageCredit _credit(String author) => RecipeImageCredit.tryCreate(
  title: '$author photo',
  author: author,
  license: 'CC BY 4.0',
  provider: 'Wikimedia Commons',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:$author.png',
)!;

// Pause real writes, then load another AppState at the exact restart boundary.
// Batch writes can also stop after the first entry, as Hive putAll spans keys.
class _RestoreStore extends MemoryStore {
  String? pauseAfter;
  String? failAfter;
  final reached = Completer<void>();
  final resume = Completer<void>();
  final events = <String>[];
  final cleanupBatches = <List<String>>[];

  Future<void> _after(String event) async {
    events.add(event);
    if (failAfter == event) {
      failAfter = null;
      throw StateError('failed after $event');
    }
    if (pauseAfter == event) {
      pauseAfter = null;
      reached.complete();
      await resume.future;
    }
  }

  @override
  Future<void> putCollections(Map<String, String> collections) async {
    await super.putCollections(collections);
    await _after(collections.length == 1 ? 'binding' : 'metadata');
  }

  @override
  Future<void> putRecipeImageBytesBatch(Map<String, Uint8List> images) async {
    var first = true;
    for (final entry in images.entries) {
      await super.putRecipeImageBytes(entry.key, entry.value);
      if (first) {
        first = false;
        await _after('partial bytes');
      }
    }
    await _after('bytes');
  }

  @override
  Future<void> saveProfile(Profile profile) async {
    await super.saveProfile(profile);
    await _after('profile');
  }

  @override
  Future<void> setOnboardingComplete(bool value) async {
    await super.setOnboardingComplete(value);
    await _after('onboarding');
  }

  @override
  Future<void> removeRecipeImageBytesBatch(Iterable<String> ids) async {
    final batch = ids.toList();
    cleanupBatches.add(batch);
    await super.removeRecipeImageBytesBatch(batch);
    await _after('cleanup');
  }
}

Future<AppState> _load(MemoryStore store) async {
  final state = AppState(store: store, corpus: await loadRealCorpus());
  await state.load();
  return state;
}

Future<AppState> _seed(_RestoreStore store, {required bool legacy}) async {
  final state = await _load(store);
  await state.completeOnboarding(const Profile(name: 'Local'));
  for (final id in [_id, _otherId]) {
    await state.setRecipeImage(
      id,
      testPngBytes(),
      updatedAt: DateTime.utc(2025),
      credit: _credit('Old'),
    );
  }
  if (legacy) {
    await store.putCollections({
      'recipe_image_metadata': jsonEncode([
        for (final image in state.recipeImages)
          image.metadata.toJson()..remove('credit_bytes_digest'),
      ]),
    });
  }
  store.events.clear();
  return _load(store);
}

BackupData _backup(
  AppState state, {
  required bool credited,
  List<String> ids = const [_id, _otherId],
}) => BackupData(
  profile: const Profile(name: 'Restored'),
  saved: state.saved,
  mealPlan: state.mealPlan,
  history: state.history,
  shoppingHistory: state.shoppingHistory,
  contentRequests: state.contentRequests,
  recipeImages: [
    for (final id in ids)
      RecipeImage(
        recipeId: id,
        bytes: [...testPngBytes(), 0],
        updatedAt: DateTime.utc(2026),
        credit: credited ? _credit('New') : null,
      ),
  ],
);

void _expectPhoto(
  AppState state,
  String id, {
  required bool replaced,
  required RecipeImageCredit? credit,
}) {
  final image = state.recipeImageFor(id)!;
  expect(image.bytes, orderedEquals([...testPngBytes(), if (replaced) 0]));
  expect(image.credit, credit);
  expect(
    state
        .buildBackup()
        .recipeImages
        .singleWhere((image) => image.recipeId == id)
        .credit,
    credit,
    reason: 'a recovered credit must remain truthful in the next export',
  );
}

void main() {
  for (final legacy in [false, true]) {
    test('replace cleanup deletes obsolete photo: legacy=$legacy', () async {
      final store = _RestoreStore();
      final state = await _seed(store, legacy: legacy);
      final original = state.buildBackup().toJson(DateTime.utc(2026));
      store.pauseAfter = 'cleanup';
      final restoring = state.applyBackup(
        _backup(state, credited: true, ids: [_id, _incomingId]),
        merge: false,
      );
      addTearDown(() async {
        if (!store.resume.isCompleted) store.resume.complete();
        await restoring.timeout(const Duration(seconds: 5));
      });
      await store.reached.future.timeout(const Duration(seconds: 5));
      expect(store.cleanupBatches, [
        [_otherId],
      ]);
      expect(
        store.loadRecipeImageBytes().keys,
        unorderedEquals([_id, _incomingId]),
      );
      expect(state.buildBackup().toJson(DateTime.utc(2026)), original);
      final recovered = await _load(store);
      expect(recovered.recipeImageFor(_otherId), isNull);
      for (final id in [_id, _incomingId]) {
        _expectPhoto(recovered, id, replaced: true, credit: _credit('New'));
      }
      store.resume.complete();
      await restoring;
      expect(
        state.buildBackup().toJson(DateTime.utc(2026)),
        recovered.buildBackup().toJson(DateTime.utc(2026)),
      );
    });

    test(
      'replace cleanup failure restores deleted photo: legacy=$legacy',
      () async {
        final store = _RestoreStore();
        final state = await _seed(store, legacy: legacy);
        final original = state.buildBackup().toJson(DateTime.utc(2026));
        final incoming = _backup(
          state,
          credited: true,
          ids: [_id, _incomingId],
        );
        store.failAfter = 'cleanup';
        await expectLater(
          state.applyBackup(incoming, merge: false),
          throwsStateError,
        );
        expect(store.cleanupBatches, [
          [_otherId],
          [_incomingId],
        ]);
        final restoredBytes = store.loadRecipeImageBytes();
        expect(restoredBytes.keys, unorderedEquals([_id, _otherId]));
        for (final id in [_id, _otherId]) {
          expect(restoredBytes[id], orderedEquals(testPngBytes()));
          _expectPhoto(state, id, replaced: false, credit: _credit('Old'));
        }
        expect(state.recipeImageFor(_incomingId), isNull);
        expect(state.buildBackup().toJson(DateTime.utc(2026)), original);
        final recovered = await _load(store);
        expect(recovered.recipeImageFor(_incomingId), isNull);
        expect(recovered.buildBackup().toJson(DateTime.utc(2026)), original);
        for (final id in [_id, _otherId]) {
          _expectPhoto(recovered, id, replaced: false, credit: _credit('Old'));
        }

        await state.applyBackup(incoming, merge: false);
        expect(store.cleanupBatches.last, [_otherId]);
        expect(
          store.loadRecipeImageBytes().keys,
          unorderedEquals([_id, _incomingId]),
        );
        final retried = await _load(store);
        expect(retried.recipeImageFor(_otherId), isNull);
        expect(state.recipeImageFor(_otherId), isNull);
        for (final id in [_id, _incomingId]) {
          _expectPhoto(retried, id, replaced: true, credit: _credit('New'));
          _expectPhoto(state, id, replaced: true, credit: _credit('New'));
        }
        expect(
          retried.buildBackup().toJson(DateTime.utc(2026)),
          state.buildBackup().toJson(DateTime.utc(2026)),
        );
      },
    );
  }

  for (final merge in [false, true]) {
    for (final legacy in [false, true]) {
      for (final credited in [false, true]) {
        for (final boundary in [
          'binding',
          'partial bytes',
          'bytes',
          'metadata',
          'profile',
          'onboarding',
          'cleanup',
        ]) {
          test(
            'restore restart after $boundary: merge=$merge legacy=$legacy credited=$credited',
            () async {
              final store = _RestoreStore();
              final state = await _seed(store, legacy: legacy);
              store.pauseAfter = boundary;
              final restoring = state.applyBackup(
                _backup(state, credited: credited),
                merge: merge,
              );
              addTearDown(() async {
                if (!store.resume.isCompleted) store.resume.complete();
                await restoring.timeout(const Duration(seconds: 5));
              });
              await store.reached.future.timeout(const Duration(seconds: 5));
              // In-memory state stays unpublished while a write is pending.
              _expectPhoto(state, _id, replaced: false, credit: _credit('Old'));
              final recovered = await _load(store);
              final hasMetadata = [
                'metadata',
                'profile',
                'onboarding',
                'cleanup',
              ].contains(boundary);
              for (final id in [_id, _otherId]) {
                final replaced =
                    boundary != 'binding' &&
                    (boundary != 'partial bytes' || id == _id);
                _expectPhoto(
                  recovered,
                  id,
                  replaced: replaced,
                  credit: !replaced
                      ? _credit('Old')
                      : hasMetadata && credited
                      ? _credit('New')
                      : null,
                );
              }
              store.resume.complete();
              await restoring;
              for (final id in [_id, _otherId]) {
                _expectPhoto(
                  state,
                  id,
                  replaced: true,
                  credit: credited ? _credit('New') : null,
                );
              }
              expect(
                (await _load(store)).buildBackup().toJson(DateTime.utc(2026)),
                state.buildBackup().toJson(DateTime.utc(2026)),
              );
              expect(store.events, [
                'binding',
                'partial bytes',
                'bytes',
                'metadata',
                'profile',
                'onboarding',
                'cleanup',
              ]);
            },
          );
        }
      }
    }

    for (final boundary in [
      'binding',
      'partial bytes',
      'bytes',
      'metadata',
      'profile',
      'onboarding',
      'cleanup',
    ]) {
      test(
        'restore failure after $boundary rolls back: merge=$merge',
        () async {
          final store = _RestoreStore();
          final state = await _seed(store, legacy: true);
          final original = state.buildBackup().toJson(DateTime.utc(2026));
          store.failAfter = boundary;
          await expectLater(
            state.applyBackup(_backup(state, credited: true), merge: merge),
            throwsStateError,
          );
          expect(state.buildBackup().toJson(DateTime.utc(2026)), original);
          expect(
            (await _load(store)).buildBackup().toJson(DateTime.utc(2026)),
            original,
          );
          await state.applyBackup(_backup(state, credited: true), merge: merge);
          _expectPhoto(
            await _load(store),
            _id,
            replaced: true,
            credit: _credit('New'),
          );
        },
      );
    }
  }
}

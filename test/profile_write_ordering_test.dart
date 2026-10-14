import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/models/profile.dart';

import 'helpers.dart';

class _PausedProfileStore extends MemoryStore {
  bool pauseNext = false;
  bool pauseAfterPersisting = false;
  bool failPausedWrite = false;
  final reached = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (!pauseNext) return super.saveProfile(profile);
    pauseNext = false;
    if (pauseAfterPersisting) await super.saveProfile(profile);
    reached.complete();
    await resume.future;
    if (failPausedWrite) throw StateError('profile write failed');
    if (!pauseAfterPersisting) await super.saveProfile(profile);
  }
}

const _initial = Profile(name: 'Initial');
const _first = Profile(name: 'First', maxTimeMinutes: 30);
const _latest = Profile(name: 'Latest', maxTimeMinutes: 60, lang: 'de');

BackupData _backup(Profile profile) => BackupData(
  profile: profile,
  saved: const [],
  mealPlan: const {},
  history: const [],
);

Future<AppState> _state(_PausedProfileStore store) async {
  final state = AppState(store: store, corpus: await loadRealCorpus());
  await state.load();
  await state.completeOnboarding(_initial);
  return state;
}

Future<void> _later(AppState state, String operation) => switch (operation) {
  'update' => state.updateProfile(_latest),
  'onboarding' => state.completeOnboarding(_latest),
  'reset' => state.resetEverything(),
  'merge' => state.applyBackup(_backup(_latest), merge: true),
  'replace' => state.applyBackup(_backup(_latest), merge: false),
  _ => throw ArgumentError(operation),
};

Future<void> _expectProfile(
  AppState state,
  Profile expected, {
  bool reset = false,
}) async {
  expect(state.profile.toJson(), expected.toJson());
  expect(state.onboarded, !reset);
  expect(state.store.loadProfile()?.toJson(), reset ? null : expected.toJson());
  final reloaded = AppState(store: state.store, corpus: state.corpus);
  await reloaded.load();
  expect(reloaded.profile.toJson(), expected.toJson());
  expect(reloaded.onboarded, !reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Exercise both sides of the persistence boundary. A delayed completion
  // must not republish an older profile; a delayed write must not erase newer
  // storage. Failure before persistence must also leave the queue usable.
  for (final boundary in ['before write', 'after write', 'failed write']) {
    for (final operation in [
      'update',
      'onboarding',
      'reset',
      'merge',
      'replace',
    ]) {
      test(
        'profile $boundary then $operation preserves request order',
        () async {
          final store = _PausedProfileStore();
          final state = await _state(store);
          final published = <String>[];
          state.addListener(() => published.add(state.profile.name));
          store
            ..pauseNext = true
            ..pauseAfterPersisting = boundary == 'after write'
            ..failPausedWrite = boundary == 'failed write';
          final first = state.updateProfile(_first);
          final checkedFirst = boundary == 'failed write'
              ? expectLater(first, throwsStateError)
              : first;
          addTearDown(() async {
            if (!store.resume.isCompleted) store.resume.complete();
            await checkedFirst;
          });
          await store.reached.future.timeout(const Duration(seconds: 5));
          expect(state.profile, same(_initial));
          expect(published, isEmpty);
          final later = _later(state, operation);
          // Let an unqueued operation finish before releasing the first save.
          await Future<void>.delayed(Duration.zero);
          final pendingProfile = state.profile;
          final pendingPublications = List<String>.of(published);
          store.resume.complete();
          await checkedFirst;
          await later;

          expect(pendingProfile, same(_initial));
          expect(pendingPublications, isEmpty);
          final reset = operation == 'reset';
          await _expectProfile(
            state,
            reset ? const Profile() : _latest,
            reset: reset,
          );
          expect(published, [
            if (boundary != 'failed write') _first.name,
            reset ? '' : _latest.name,
          ]);
        },
      );
    }
  }

  for (final operation in ['onboarding', 'merge', 'replace']) {
    test('$operation then profile update preserves the later edit', () async {
      final store = _PausedProfileStore();
      final state = await _state(store);
      store
        ..pauseNext = true
        ..pauseAfterPersisting = true;
      final first = operation == 'onboarding'
          ? state.completeOnboarding(_first)
          : state.applyBackup(_backup(_first), merge: operation == 'merge');
      addTearDown(() async {
        if (!store.resume.isCompleted) store.resume.complete();
        await first;
      });
      await store.reached.future.timeout(const Duration(seconds: 5));
      final later = state.updateProfile(_latest);
      await Future<void>.delayed(Duration.zero);
      final pendingProfile = state.profile;
      store.resume.complete();
      await first;
      await later;
      expect(pendingProfile, same(_initial));
      await _expectProfile(state, _latest);
    });
  }
}

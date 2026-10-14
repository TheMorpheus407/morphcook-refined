import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'helpers.dart';

class _TestPath extends PathProviderPlatform {
  _TestPath(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  String? failKey;
  String mode = '';

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == failKey) {
      failKey = null;
      if (mode == 'false') return false;
      if (mode == 'after write') await super.setValue(type, key, value);
      throw StateError('native confirmation failed');
    }
    return super.setValue(type, key, value);
  }
}

class _AfterWriteProfileStore extends MemoryStore {
  _AfterWriteProfileStore({this.pauseRollback = false});

  final bool pauseRollback;
  bool armed = false;
  bool _rollbackPending = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  final rollbackEntered = Completer<void>();
  final rollbackRelease = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (_rollbackPending && pauseRollback) {
      _rollbackPending = false;
      rollbackEntered.complete();
      await rollbackRelease.future;
    }
    await super.saveProfile(profile);
    if (armed) {
      armed = false;
      entered.complete();
      await release.future;
      _rollbackPending = true;
      throw StateError('confirmation failed after writing profile');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in ['false', 'before write', 'after write']) {
    for (final operation in [
      'profile add',
      'profile remove',
      'onboarding profile',
      'onboarding flag',
    ]) {
      test(
        '$operation reports native $mode and preserves prior state',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'morphcook-profile-',
          );
          final originalPath = PathProviderPlatform.instance;
          final originalPreferences = SharedPreferencesStorePlatform.instance;
          PathProviderPlatform.instance = _TestPath(directory.path);
          SharedPreferences.setMockInitialValues({});
          final preferences = _FailingPreferences();
          SharedPreferencesStorePlatform.instance = preferences;
          final store = HiveStore();
          final state = AppState(store: store, corpus: await loadRealCorpus());
          addTearDown(() async {
            state.dispose();
            await Hive.close();
            PathProviderPlatform.instance = originalPath;
            SharedPreferences.setMockInitialValues({});
            SharedPreferencesStorePlatform.instance = originalPreferences;
            await directory.delete(recursive: true);
          });
          await state.load();
          final original = operation == 'profile add'
              ? const Profile()
              : const Profile(avoidFlags: {'dairy'});
          final nextFlags = operation == 'profile add' ? {'dairy'} : <String>{};
          await state.updateProfile(original);
          final published = <Profile>[];
          state.addListener(() => published.add(state.profile));
          preferences
            ..mode = mode
            ..failKey = operation == 'onboarding flag'
                ? 'flutter.onboarding_complete'
                : 'flutter.profile';
          final save = operation.startsWith('profile')
              ? state.editProfile(
                  (profile) => profile.copyWith(avoidFlags: nextFlags),
                )
              : state.completeOnboarding(const Profile(name: 'New'));
          await expectLater(save, throwsStateError);
          expect(published, isEmpty);
          expect(state.profile.toJson(), original.toJson());
          expect(state.onboarded, isFalse);
          expect(
            store.loadProfile()!.toJson(),
            original.toJson(),
            reason: 'restore the real SharedPreferences cache',
          );
          expect(store.onboardingComplete, isFalse);
          final disk = await preferences.getAll();
          expect(
            jsonDecode(disk['flutter.profile']! as String),
            original.toJson(),
            reason: 'restore native data even after a write succeeded',
          );
          expect(disk['flutter.onboarding_complete'] ?? false, isFalse);

          // Drop the Dart cache to simulate a new process reading native data.
          SharedPreferences.setMockInitialValues({});
          SharedPreferencesStorePlatform.instance = preferences;
          final reloaded = AppState(store: HiveStore(), corpus: state.corpus);
          addTearDown(reloaded.dispose);
          await reloaded.load();
          expect(reloaded.profile.toJson(), original.toJson());
          expect(reloaded.onboarded, isFalse);

          // The failure must neither poison the queue nor prevent a real retry.
          if (operation.startsWith('profile')) {
            await state.editProfile(
              (profile) => profile.copyWith(avoidFlags: nextFlags),
            );
            expect(state.profile.avoidFlags, nextFlags);
            expect(store.loadProfile()!.avoidFlags, nextFlags);
          } else {
            await state.completeOnboarding(const Profile(name: 'Retry'));
            expect(state.profile.name, 'Retry');
            expect(state.onboarded, isTrue);
            expect(store.onboardingComplete, isTrue);
          }
        },
      );
    }
  }

  test(
    'after-write failure rolls back before the next queued profile edit',
    () async {
      final store = _AfterWriteProfileStore(pauseRollback: true);
      final state = AppState(store: store, corpus: await loadRealCorpus());
      addTearDown(state.dispose);
      await state.load();
      await state.updateProfile(const Profile(avoidFlags: {'dairy'}));
      store.armed = true;
      final failed = expectLater(
        state.editProfile((p) => p.copyWith(avoidFlags: {})),
        throwsStateError,
      );
      addTearDown(() async {
        if (!store.release.isCompleted) store.release.complete();
        if (!store.rollbackRelease.isCompleted) {
          store.rollbackRelease.complete();
        }
        await failed;
      });
      await store.entered.future.timeout(const Duration(seconds: 5));
      var nextEditStarted = false;
      Profile? storedBeforeNextEdit;
      final next = state.editProfile((p) {
        nextEditStarted = true;
        storedBeforeNextEdit = store.loadProfile();
        return p.copyWith(name: 'Later');
      });
      store.release.complete();
      await Future<void>.delayed(Duration.zero);
      final rollbackStarted = store.rollbackEntered.isCompleted;
      final nextEditStartedDuringRollback = nextEditStarted;
      store.rollbackRelease.complete();
      await failed;
      await next;
      expect(rollbackStarted, isTrue);
      expect(nextEditStartedDuringRollback, isFalse);
      expect(
        storedBeforeNextEdit!.toJson(),
        const Profile(avoidFlags: {'dairy'}).toJson(),
      );
      expect(state.profile.avoidFlags, {'dairy'});
      expect(state.profile.name, 'Later');
      expect(store.loadProfile()!.toJson(), state.profile.toJson());
      final reloaded = AppState(store: store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.profile.toJson(), state.profile.toJson());
    },
  );

  test(
    'an after-write failure alone preserves persisted allergy choices',
    () async {
      final store = _AfterWriteProfileStore();
      final state = AppState(store: store, corpus: await loadRealCorpus());
      addTearDown(state.dispose);
      await state.load();
      await state.updateProfile(const Profile(avoidFlags: {'dairy'}));
      store.armed = true;
      final failed = expectLater(
        state.editProfile((p) => p.copyWith(avoidFlags: {})),
        throwsStateError,
      );
      await store.entered.future.timeout(const Duration(seconds: 5));
      store.release.complete();
      await failed;
      expect(state.profile.avoidFlags, {'dairy'});
      expect(store.loadProfile()!.avoidFlags, {'dairy'});
      final reloaded = AppState(store: store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.profile.avoidFlags, {'dairy'});
    },
  );
}

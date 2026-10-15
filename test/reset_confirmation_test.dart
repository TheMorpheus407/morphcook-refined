import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _TestPath extends PathProviderPlatform {
  _TestPath(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _RejectClearPreferences extends InMemorySharedPreferencesStore {
  _RejectClearPreferences(this.mode) : super.empty();
  final String mode;
  bool reject = false;
  final error = StateError('native clear failed');
  @override
  Future<bool> clear() async {
    if (reject) {
      reject = false;
      if (mode == 'false') return false;
      throw error;
    }
    return super.clear();
  }
}

class _RejectOnceResetStore extends MemoryStore {
  bool reject = true;
  @override
  Future<void> clearAll() async {
    if (reject) {
      reject = false;
      throw StateError('reset failed');
    }
    await super.clearAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final mode in ['false', 'throw']) {
    test(
      'native clear $mode reports failure and preserves reset data',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'morphcook-reset-',
        );
        final oldPath = PathProviderPlatform.instance;
        final oldPreferences = SharedPreferencesStorePlatform.instance;
        PathProviderPlatform.instance = _TestPath(directory.path);
        SharedPreferences.setMockInitialValues({});
        final preferences = _RejectClearPreferences(mode);
        SharedPreferencesStorePlatform.instance = preferences;
        final store = HiveStore();
        final state = AppState(store: store, corpus: await loadRealCorpus());
        addTearDown(() async {
          state.dispose();
          await Hive.close();
          PathProviderPlatform.instance = oldPath;
          SharedPreferences.setMockInitialValues({});
          SharedPreferencesStorePlatform.instance = oldPreferences;
          await directory.delete(recursive: true);
        });
        await state.load();
        const profile = Profile(
          name: 'Personal name',
          imageSearchEnabled: true,
        );
        await state.completeOnboarding(profile);
        await state.toggleSaved('doener-vegan');
        await state.setRecipeImage('doener-vegan', testPngBytes());
        final before = state.buildBackup().toJson(DateTime.utc(2026));
        final rawSaved = store.getCollection('saved');
        final native = await preferences.getAll();
        var notifications = 0;
        state.addListener(() => notifications++);
        preferences.reject = true;
        await expectLater(
          state.resetEverything(),
          mode == 'throw' ? throwsA(same(preferences.error)) : throwsStateError,
        );
        expect(notifications, 0);
        expect(state.onboarded, isTrue);
        expect(state.buildBackup().toJson(DateTime.utc(2026)), before);
        expect(store.loadProfile()!.toJson(), profile.toJson());
        expect(store.onboardingComplete, isTrue);
        expect(store.getCollection('saved'), rawSaved);
        expect(store.loadRecipeImageBytes()['doener-vegan'], testPngBytes());
        expect(await preferences.getAll(), native);

        // A fresh Dart cache must see the same data, not a successful reset.
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesStorePlatform.instance = preferences;
        final reloaded = AppState(store: HiveStore(), corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await reloaded.load();
        expect(reloaded.onboarded, isTrue);
        expect(reloaded.buildBackup().toJson(DateTime.utc(2026)), before);

        await state.resetEverything();
        expect(notifications, 1);
        expect(state.onboarded, isFalse);
        expect(state.profile.name, isEmpty);
        expect(state.saved, isEmpty);
        expect(store.loadRecipeImageBytes(), isEmpty);
        expect(await preferences.getAll(), isEmpty);
      },
    );
  }

  for (final lang in ['en', 'de']) {
    testWidgets('$lang failed reset reports error and can retry', (
      tester,
    ) async {
      final store = _RejectOnceResetStore();
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(Profile(name: 'Before', lang: lang));
        await state.toggleSaved('doener-vegan');
        return state;
      }))!;
      addTearDown(state.dispose);
      final s = S(lang);
      await tester.pumpWidget(
        app(state, const Scaffold(body: SettingsScreen())),
      );
      await tester.pumpAndSettle();
      Future<void> reset() async {
        final resetButton = find.text(s('resetApp'));
        await tester.scrollUntilVisible(
          resetButton,
          500,
          scrollable: find
              .descendant(
                of: find.byType(SettingsScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(resetButton);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, s('erase')));
        await tester.pumpAndSettle();
      }

      await reset();
      expect(tester.takeException(), isNull);
      expect(find.text(s('resetFailed')), findsOneWidget);
      expect(state.onboarded, isTrue);
      expect(state.profile.name, 'Before');
      expect(state.isSaved('doener-vegan'), isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await reset();
      expect(tester.takeException(), isNull);
      expect(state.onboarded, isFalse);
      expect(state.saved, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

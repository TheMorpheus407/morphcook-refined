// Regression for morphcook-r4-p2-1; adapted from the round-4 review's
// review-2/onboarding_pending_review_test.dart in the Issue-Kosten job.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/ui/screens/onboarding_screen.dart';
import 'package:morphcook/ui/theme.dart';
import 'package:morphcook/ui/widgets/decor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'helpers.dart';

class _TestPath extends PathProviderPlatform {
  _TestPath(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _PausedPreferences extends InMemorySharedPreferencesStore {
  _PausedPreferences({required this.fail}) : super.empty();
  final bool fail;
  bool armed = true;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.onboarding_complete' && armed) {
      armed = false;
      entered.complete();
      await release.future;
      if (fail) return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  for (final selected in [false, true]) {
    for (final fail in [false, true]) {
      testWidgets('pending onboarding freezes allergy=$selected (fail=$fail)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1000, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preferences = _PausedPreferences(fail: fail);
        final originalPath = PathProviderPlatform.instance;
        final originalPreferences = SharedPreferencesStorePlatform.instance;
        late Directory directory;
        final state = (await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp(
            'morphcook-onboarding-',
          );
          PathProviderPlatform.instance = _TestPath(directory.path);
          SharedPreferences.setMockInitialValues({});
          SharedPreferencesStorePlatform.instance = preferences;
          final state = AppState(
            store: HiveStore(),
            corpus: await loadRealCorpus(),
          );
          await state.load();
          return state;
        }))!;
        addTearDown(() async {
          if (!preferences.release.isCompleted) preferences.release.complete();
          state.dispose();
          await Hive.close();
          PathProviderPlatform.instance = originalPath;
          SharedPreferences.setMockInitialValues({});
          SharedPreferencesStorePlatform.instance = originalPreferences;
          await directory.delete(recursive: true);
        });
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: MaterialApp(
              theme: morphThemeData(MorphColors.light),
              home: Builder(
                builder: (context) => context.watch<AppState>().onboarded
                    ? const Scaffold(body: Text('Finished'))
                    : const OnboardingScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('onboarding-personalize')));
        await tester.pumpAndSettle();
        final dairy = find.byWidgetPredicate(
          (w) => w is MonoChip && w.label == 'dairy',
        );
        if (selected) {
          await tester.tap(dairy);
          await tester.pump();
        }
        await tester.tap(
          find.byKey(const ValueKey('onboarding-open-personalized')),
        );
        await tester.pump();
        expect(preferences.entered.isCompleted, isTrue);
        await tester.tap(dairy);
        await tester.pump();
        final pendingSelection = tester.widget<MonoChip>(dairy).selected;
        // Release before assertions so a red regression never strands IO.
        preferences.release.complete();
        await tester.pumpAndSettle();
        expect(
          pendingSelection,
          selected,
          reason: 'choices stay fixed during save',
        );
        if (fail) {
          expect(state.onboarded, isFalse);
          expect(tester.widget<MonoChip>(dairy).selected, selected);
          // A failed save unlocks the choices and can be retried.
          await tester.tap(dairy);
          await tester.pump();
          expect(tester.widget<MonoChip>(dairy).selected, !selected);
          await tester.tap(
            find.byKey(const ValueKey('onboarding-open-personalized')),
          );
          await tester.pumpAndSettle();
        }
        expect(state.onboarded, isTrue);
        final expected = (fail ? !selected : selected) ? {'dairy'} : <String>{};
        expect(state.profile.avoidFlags, expected);
        // Discard SharedPreferences' cache and read the native store afresh.
        SharedPreferences.setMockInitialValues({});
        SharedPreferencesStorePlatform.instance = preferences;
        final reloaded = AppState(store: HiveStore(), corpus: state.corpus);
        addTearDown(reloaded.dispose);
        await tester.runAsync(reloaded.load);
        expect(reloaded.onboarded, isTrue);
        expect(reloaded.profile.avoidFlags, expected);
        expect(reloaded.profile.toJson(), state.profile.toJson());
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

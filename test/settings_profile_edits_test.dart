import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/widgets/decor.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _PausedProfileStore extends MemoryStore {
  bool pauseNext = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (pauseNext) {
      pauseNext = false;
      entered.complete();
      await release.future;
    }
    await super.saveProfile(profile);
  }
}

void main() {
  for (final nextEdit in ['other allergy', 'language', 'same allergy']) {
    testWidgets('pending allergy edit preserves $nextEdit intent', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _PausedProfileStore();
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(const Profile());
        return state;
      }))!;
      addTearDown(() {
        if (!store.release.isCompleted) store.release.complete();
        state.dispose();
      });
      await tester.pumpWidget(
        app(state, const Scaffold(body: SettingsScreen())),
      );
      await tester.pumpAndSettle();
      Finder chip(String label) =>
          find.byWidgetPredicate((w) => w is MonoChip && w.label == label);
      await tester.ensureVisible(chip('dairy'));
      store.pauseNext = true;
      await tester.tap(chip('dairy'));
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);
      expect(state.profile.avoidFlags, isEmpty);
      final second = switch (nextEdit) {
        'other allergy' => 'egg',
        'language' => 'deutsch',
        _ => 'dairy',
      };
      await tester.ensureVisible(chip(second));
      await tester.tap(chip(second));
      await tester.pump();
      store.release.complete();
      await tester.pumpAndSettle();

      final expectedFlags = switch (nextEdit) {
        'other allergy' => {'dairy', 'egg'},
        'language' => {'dairy'},
        _ => <String>{},
      };
      expect(state.profile.avoidFlags, expectedFlags);
      expect(state.profile.lang, nextEdit == 'language' ? 'de' : 'en');
      expect(store.loadProfile()!.toJson(), state.profile.toJson());
      final reloaded = AppState(store: store, corpus: state.corpus);
      await reloaded.load();
      expect(reloaded.profile.toJson(), state.profile.toJson());
      reloaded.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/widgets/decor.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _PausedProfileStore extends MemoryStore {
  bool pauseNext = false;
  bool failPausedWrite = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (pauseNext) {
      pauseNext = false;
      entered.complete();
      await release.future;
      if (failPausedWrite) throw StateError('profile write failed');
    }
    await super.saveProfile(profile);
  }
}

void main() {
  for (final nextEdit in [
    'other allergy',
    'language',
    'same allergy',
    'same attribute',
  ]) {
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
          find.byWidgetPredicate((w) => w is MonoChip && w.label == label).last;
      final firstChip = nextEdit == 'same attribute' ? 'vegan' : 'dairy';
      await tester.ensureVisible(chip(firstChip).last);
      store.pauseNext = true;
      await tester.tap(chip(firstChip).last);
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);
      expect(state.profile.avoidFlags, isEmpty);
      final second = switch (nextEdit) {
        'other allergy' => 'egg',
        'language' => 'deutsch',
        'same attribute' => 'vegan',
        _ => 'dairy',
      };
      await tester.ensureVisible(chip(second).last);
      await tester.tap(chip(second).last);
      await tester.pump();
      store.release.complete();
      await tester.pumpAndSettle();

      final expectedFlags = switch (nextEdit) {
        'other allergy' => {'dairy', 'egg'},
        'language' => {'dairy'},
        _ => <String>{},
      };
      expect(state.profile.avoidFlags, expectedFlags);
      expect(state.profile.requiredAttributes, isEmpty);
      expect(state.profile.lang, nextEdit == 'language' ? 'de' : 'en');
      expect(store.loadProfile()!.toJson(), state.profile.toJson());
      final reloaded = AppState(store: store, corpus: state.corpus);
      await reloaded.load();
      expect(reloaded.profile.toJson(), state.profile.toJson());
      reloaded.dispose();
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final lang in ['en', 'de']) {
    testWidgets('failed settings save reports $lang error and allows retry', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _PausedProfileStore();
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
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
      final original = state.profile.toJson();
      final dairy = find.byWidgetPredicate(
        (w) =>
            w is MonoChip &&
            w.label == state.corpus.ontology.nameOf('dairy', lang),
      );
      store
        ..pauseNext = true
        ..failPausedWrite = true;
      await tester.ensureVisible(dairy);
      await tester.tap(dairy);
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);
      store.release.complete();
      await tester.pumpAndSettle();
      expect(find.text(S(lang)('obSaveFailed')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(state.profile.toJson(), original);
      expect(store.loadProfile()!.toJson(), original);
      final reloaded = AppState(store: store, corpus: state.corpus);
      await reloaded.load();
      expect(reloaded.profile.toJson(), original);
      reloaded.dispose();

      await tester.tap(dairy);
      await tester.pumpAndSettle();
      expect(state.profile.avoidFlags, {'dairy'});
      expect(store.loadProfile()!.toJson(), state.profile.toJson());
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('restored profile refreshes the settings name field', (
    tester,
  ) async {
    final store = MemoryStore();
    final state = (await tester.runAsync(() async {
      final state = AppState(store: store, corpus: await loadRealCorpus());
      await state.load();
      await state.completeOnboarding(const Profile(name: 'Original'));
      return state;
    }))!;
    addTearDown(state.dispose);
    await tester.pumpWidget(app(state, const Scaffold(body: SettingsScreen())));
    await tester.pumpAndSettle();
    await state.applyBackup(
      BackupData(
        profile: const Profile(name: 'Restored'),
        saved: const [],
        mealPlan: const {},
        history: const [],
      ),
      merge: false,
    );
    await tester.pumpAndSettle();
    expect(state.profile.name, 'Restored');
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextFormField),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.controller.text, 'Restored');
    await tester.pumpWidget(const SizedBox());
  });
}

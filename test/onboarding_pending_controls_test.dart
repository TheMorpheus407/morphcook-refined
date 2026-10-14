import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/ui/screens/onboarding_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/theme.dart';
import 'package:morphcook/ui/widgets/decor.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

class _PendingStore extends MemoryStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool _armed = true;

  @override
  Future<void> setOnboardingComplete(bool value) async {
    if (value && _armed) {
      _armed = false;
      entered.complete();
      await release.future;
      throw StateError('onboarding confirmation failed');
    }
    await super.setOnboardingComplete(value);
  }
}

Future<AppState> _mount(WidgetTester tester, _PendingStore store) async {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = (await tester.runAsync(() async {
    final state = AppState(store: store, corpus: await loadRealCorpus());
    await state.load();
    return state;
  }))!;
  addTearDown(() {
    if (!store.release.isCompleted) store.release.complete();
    state.dispose();
  });
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        theme: morphThemeData(MorphColors.light),
        initialRoute: '/onboarding',
        routes: {
          '/': (_) => const Scaffold(body: Text('Previous route')),
          '/onboarding': (context) => context.watch<AppState>().onboarded
              ? const Scaffold(body: Text('Finished'))
              : const OnboardingScreen(),
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

void main() {
  for (final lang in ['en', 'de']) {
    final language = lang == 'en' ? 'english' : 'deutsch';
    final otherLanguage = lang == 'en' ? 'deutsch' : 'english';
    final otherLang = lang == 'en' ? 'de' : 'en';

    testWidgets('pending $lang welcome locks language and system back', (
      tester,
    ) async {
      final store = _PendingStore();
      final state = await _mount(tester, store);
      await tester.tap(find.text(language));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('onboarding-open')));
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);

      await tester.tap(find.text(otherLanguage));
      await tester.pump();
      expect(find.text(S(lang)('obLanguageTitle')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.text('Previous route'), findsNothing);
      expect(state.onboarded, isFalse);

      store.release.complete();
      await tester.pumpAndSettle();
      expect(find.text(S(lang)('obSaveFailed')), findsOneWidget);
      await tester.tap(find.text(otherLanguage));
      await tester.pump();
      expect(find.text(S(otherLang)('obLanguageTitle')), findsOneWidget);
      // A failed save also releases the route's system-back lock.
      expect(
        ModalRoute.of(
          tester.element(find.byType(OnboardingScreen)),
        )!.popDisposition,
        RoutePopDisposition.pop,
      );
      await tester.tap(find.byKey(const ValueKey('onboarding-open')));
      await tester.pumpAndSettle();
      expect(state.onboarded, isTrue);
      expect(state.lang, otherLang);
      expect(store.loadProfile()!.toJson(), state.profile.toJson());
      await tester.pumpWidget(const SizedBox());
    });

    for (final back in ['toolbar', 'system']) {
      testWidgets('pending $lang dietary setup locks $back back', (
        tester,
      ) async {
        final store = _PendingStore();
        final state = await _mount(tester, store);
        await tester.tap(find.text(language));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('onboarding-personalize')));
        await tester.pumpAndSettle();
        final vegan = find.byWidgetPredicate(
          (w) => w is MonoChip && w.label == 'vegan',
        );
        await tester.tap(vegan);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('onboarding-open-personalized')),
        );
        await tester.pump();
        expect(store.entered.isCompleted, isTrue);
        await tester.tap(vegan);
        await tester.pump();
        expect(tester.widget<MonoChip>(vegan).selected, isTrue);

        Future<void> goBack() async {
          if (back == 'toolbar') {
            await tester.tap(find.byKey(const ValueKey('onboarding-back')));
          } else {
            await tester.binding.handlePopRoute();
          }
          // pumpAndSettle cannot finish while the save spinner is active.
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
        }

        await goBack();
        expect(find.text(S(lang)('obDietTitle')), findsOneWidget);
        expect(find.text(S(lang)('obLanguageTitle')), findsNothing);
        store.release.complete();
        await tester.pumpAndSettle();
        expect(find.text(S(lang)('obSaveFailed')), findsOneWidget);
        await goBack();
        await tester.pumpAndSettle();
        expect(find.text(S(lang)('obLanguageTitle')), findsOneWidget);
        await tester.tap(find.text(otherLanguage));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('onboarding-personalize')));
        await tester.pumpAndSettle();
        expect(tester.widget<MonoChip>(vegan).selected, isTrue);
        await tester.tap(vegan);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('onboarding-open-personalized')),
        );
        await tester.pumpAndSettle();
        expect(state.onboarded, isTrue);
        expect(state.lang, otherLang);
        expect(state.profile.avoidFlags, isEmpty);
        expect(store.loadProfile()!.toJson(), state.profile.toJson());
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

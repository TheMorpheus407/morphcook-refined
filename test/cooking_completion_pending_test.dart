import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/cook_mode_screen.dart';
import 'package:morphcook/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

class _DelayedHistoryStore extends MemoryStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool delay = true;
  @override
  Future<void> putCollection(String key, String jsonText) async {
    if (key == 'history' && delay) {
      delay = false;
      entered.complete();
      await release.future;
    }
    await super.putCollection(key, jsonText);
  }
}

class _PopRecorder extends NavigatorObserver {
  final popped = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route.settings.name);
    super.didPop(route, previousRoute);
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final navigation in ['stay', 'back', 'cover']) {
      testWidgets('$lang pending completion: $navigation', (tester) async {
        final store = _DelayedHistoryStore();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          return state;
        }))!;
        addTearDown(state.dispose);
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
        });
        final observer = _PopRecorder();
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: MaterialApp(
              theme: morphThemeData(MorphColors.light),
              navigatorObservers: [observer],
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    child: const Text('open detail'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        settings: const RouteSettings(name: '/detail'),
                        builder: (context) => Scaffold(
                          body: TextButton(
                            child: const Text('open cook'),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                settings: const RouteSettings(name: '/cook'),
                                builder: (_) => CookModeScreen(
                                  recipe: makeRecipe(id: 'doener-classic'),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open detail'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open cook'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FilledButton));
        if (navigation == 'stay') {
          // A second real tap before the rebuild exercises the old callback.
          await tester.tap(find.byType(FilledButton));
        }
        await tester.pump();
        expect(store.entered.isCompleted, isTrue);
        expect(state.history, isEmpty);
        if (navigation == 'back') {
          // Back starts a pop while the cook route is still mounted/animating.
          Navigator.of(tester.element(find.byType(CookModeScreen))).pop();
          await tester.pump();
        } else if (navigation == 'cover') {
          Navigator.of(tester.element(find.byType(CookModeScreen))).push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/cover'),
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('close cover'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }
        store.release.complete();
        await tester.pumpAndSettle();
        if (navigation == 'cover') {
          expect(observer.popped, isEmpty);
          expect(state.history, hasLength(1));
          await tester.tap(find.text('close cover'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(FilledButton));
          await tester.pumpAndSettle();
        }
        expect(state.history.map((h) => h.recipeId), ['doener-classic']);
        expect(
          jsonDecode(store.getCollection('history')!) as List,
          hasLength(1),
        );
        expect(observer.popped, [if (navigation == 'cover') '/cover', '/cook']);
        expect(find.text('open cook'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

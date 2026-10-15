import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';
import 'recipe_photo_search_widget_test.dart'
    show FakePhotoSearch, settlePhotos;
import 'recipe_photo_write_ordering_test.dart' show PausedPhotoStore;

class _PopRecorder extends NavigatorObserver {
  final popped = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route.settings.name);
  }
}

void main() {
  for (final lang in ['en', 'de']) {
    for (final mode in ['back-50', 'back-500', 'cover', 'stay']) {
      testWidgets('photo save navigation: $mode ($lang)', (tester) async {
        final store = PausedPhotoStore();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(
            Profile(lang: lang, imageSearchEnabled: true),
          );
          return state;
        }))!;
        addTearDown(state.dispose);
        final nav = GlobalKey<NavigatorState>();
        final observer = _PopRecorder();
        final search = FakePhotoSearch();
        final useButton = find.byKey(const ValueKey('use-found-photo'));
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
        });
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: state,
            child: MaterialApp(
              theme: morphThemeData(MorphColors.light),
              navigatorKey: nav,
              navigatorObservers: [observer],
              home: const Scaffold(body: Text('root')),
            ),
          ),
        );
        unawaited(
          nav.currentState!.push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'recipe-detail'),
              builder: (_) =>
                  DishDetailScreen(dishId: 'doener', photoSearch: search),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('search-recipe-image')));
        await settlePhotos(tester);
        await tester.tap(find.byKey(const ValueKey('found-photo-0')));
        await tester.pump();
        await tester.tap(useButton);
        await tester.pump();
        expect(store.entered.isCompleted, isTrue);
        expect(tester.widget<FilledButton>(useButton).onPressed, isNull);
        expect(state.recipeImages, isEmpty);
        if (mode.startsWith('back')) {
          await tester.tap(find.byType(BackButton));
          await tester.pump();
          await tester.pump(
            Duration(milliseconds: mode == 'back-50' ? 50 : 500),
          );
          expect(observer.popped, [null]);
        } else if (mode == 'cover') {
          unawaited(
            nav.currentState!.push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: 'cover'),
                builder: (_) => const Scaffold(body: Text('cover')),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }
        store.release.complete();
        await tester.pumpAndSettle();
        expect(state.recipeImages, hasLength(1));
        if (mode == 'cover') {
          expect(observer.popped, isEmpty);
          expect(find.text('cover'), findsOneWidget);
          nav.currentState!.pop();
          await tester.pumpAndSettle();
          // Returning to a covered search leaves a usable save control.
          expect(tester.widget<FilledButton>(useButton).onPressed, isNotNull);
          await tester.tap(useButton);
          await tester.pumpAndSettle();
        }
        expect(observer.popped, [if (mode == 'cover') 'cover', null]);
        expect(find.byType(DishDetailScreen), findsOneWidget);
        final image = state.recipeImages.single;
        expect(image.bytes, orderedEquals(testPngBytes()));
        expect(image.credit, search.results.first.credit);
        expect(find.textContaining(image.credit!.label(lang)), findsOneWidget);
        if (mode == 'stay' || mode == 'cover') {
          expect(find.text(S(lang)('photoSearchSaved')), findsOneWidget);
        }
        expect(search.queries, hasLength(1));
        expect(
          search.downloads.where((name) => name == 'Doener plate'),
          hasLength(1),
        );
        final recovered = (await tester.runAsync(() async {
          final recovered = AppState(
            store: store,
            corpus: await loadRealCorpus(),
          );
          await recovered.load();
          return recovered;
        }))!;
        addTearDown(recovered.dispose);
        expect(recovered.recipeImages.single.recipeId, image.recipeId);
        expect(recovered.recipeImages.single.bytes, orderedEquals(image.bytes));
        expect(recovered.recipeImages.single.credit, image.credit);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

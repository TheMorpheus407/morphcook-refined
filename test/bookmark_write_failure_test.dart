import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/home_screen.dart';
import 'package:morphcook/ui/widgets/decor.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _FailingSavedStore extends MemoryStore {
  bool failNext = false;
  bool failAfterPersisting = false;

  @override
  Future<void> putCollection(String key, String value) async {
    if (key == 'saved' && failNext) {
      failNext = false;
      if (failAfterPersisting) await super.putCollection(key, value);
      throw StateError('saved write failed');
    }
    await super.putCollection(key, value);
  }
}

class _PausedSavedStore extends MemoryStore {
  final bool afterPersistence;
  bool pauseNext = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  _PausedSavedStore({required this.afterPersistence});

  @override
  Future<void> putCollection(String key, String value) async {
    if (key == 'saved' && pauseNext) {
      pauseNext = false;
      if (afterPersistence) await super.putCollection(key, value);
      entered.complete();
      await release.future;
      if (afterPersistence) return;
    }
    await super.putCollection(key, value);
  }
}

Future<AppState> _state(PersistenceStore store, {String lang = 'en'}) async {
  final state = AppState(store: store, corpus: await loadRealCorpus());
  await state.load();
  await state.completeOnboarding(Profile(lang: lang));
  return state;
}

List<dynamic> _persistedSaved(PersistenceStore store) =>
    jsonDecode(store.getCollection('saved') ?? '[]') as List<dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final initiallySaved in [false, true]) {
    for (final afterPersistence in [false, true]) {
      test(
        'pending bookmark stays unpublished: saved=$initiallySaved afterPersistence=$afterPersistence',
        () async {
          final store = _PausedSavedStore(afterPersistence: afterPersistence);
          final state = await _state(store);
          addTearDown(state.dispose);
          const id = 'doener-vegan';
          if (initiallySaved) await state.toggleSaved(id);
          final before = state.saved.map((s) => s.toJson()).toList();
          final observed = <List<Map<String, dynamic>>>[];
          state.addListener(
            () => observed.add(state.saved.map((s) => s.toJson()).toList()),
          );
          store.pauseNext = true;
          final toggling = state.toggleSaved(id);
          addTearDown(() async {
            if (!store.release.isCompleted) store.release.complete();
            await toggling;
          });
          await store.entered.future;
          expect(state.saved.map((s) => s.toJson()).toList(), before);
          expect(observed, isEmpty);
          // Meal-plan writes notify independently of the shared mutation queue.
          await state.assignMeal('2026-W42', 'mon-dinner', 'ramen-vegan');
          expect(observed, [before]);
          expect(state.isSaved(id), initiallySaved);
          if (!afterPersistence) expect(_persistedSaved(store), before);

          store.release.complete();
          await toggling;
          expect(state.isSaved(id), !initiallySaved);
          final after = state.saved.map((s) => s.toJson()).toList();
          expect(observed, [before, after]);
          expect(_persistedSaved(store), after);
          final reloaded = AppState(store: store, corpus: state.corpus);
          await reloaded.load();
          addTearDown(reloaded.dispose);
          expect(reloaded.isSaved(id), !initiallySaved);
        },
      );
    }

    for (final afterWrite in [false, true]) {
      test(
        'failed bookmark preserves prior data and retry: saved=$initiallySaved afterWrite=$afterWrite',
        () async {
          final store = _FailingSavedStore()..failAfterPersisting = afterWrite;
          final state = await _state(store);
          addTearDown(state.dispose);
          const id = 'doener-vegan';
          if (initiallySaved) await state.toggleSaved(id);
          final before = state.saved.map((s) => s.toJson()).toList();
          var notifications = 0;
          state.addListener(() => notifications++);
          store.failNext = true;
          await expectLater(state.toggleSaved(id), throwsStateError);
          expect(state.saved.map((s) => s.toJson()).toList(), before);
          expect(_persistedSaved(store), before);
          expect(notifications, 0);
          final reloaded = AppState(store: store, corpus: state.corpus);
          await reloaded.load();
          expect(reloaded.isSaved(id), initiallySaved);
          reloaded.dispose();
          await state.toggleSaved(id);
          expect(state.isSaved(id), !initiallySaved);
          expect(notifications, 1);
          final retried = AppState(store: store, corpus: state.corpus);
          await retried.load();
          expect(retried.isSaved(id), !initiallySaved);
          retried.dispose();
        },
      );
    }
  }

  for (final surface in ['featured', 'grid', 'detail']) {
    for (final lang in ['en', 'de']) {
      testWidgets(
        '$surface bookmark reports $lang failure and retries the intent',
        (tester) async {
          final store = _FailingSavedStore();
          final state = (await tester.runAsync(
            () => _state(store, lang: lang),
          ))!;
          addTearDown(state.dispose);
          await tester.pumpWidget(
            app(
              state,
              surface == 'detail'
                  ? const DishDetailScreen(dishId: 'doener')
                  : const Scaffold(body: HomeScreen()),
            ),
          );
          await tester.pumpAndSettle();
          Finder control;
          if (surface == 'detail') {
            control = find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.icon is Icon &&
                  [
                    Icons.bookmark,
                    Icons.bookmark_border,
                  ].contains((widget.icon as Icon).icon),
            );
          } else if (surface == 'grid') {
            final scrollable = find
                .descendant(
                  of: find.byType(HomeScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
            await tester.drag(scrollable, const Offset(0, -700));
            await tester.pumpAndSettle();
            final card = find.byKey(const ValueKey('home-dish-card-0'));
            await tester.ensureVisible(card);
            await tester.pumpAndSettle();
            control = find.descendant(
              of: card,
              matching: find.byType(BookmarkBadge),
            );
          } else {
            control = find.byType(BookmarkBadge).first;
          }
          expect(control, findsOneWidget);
          VoidCallback callback() => surface == 'detail'
              ? tester.widget<IconButton>(control).onPressed!
              : tester.widget<BookmarkBadge>(control).onTap!;
          final errors = <Object>[];
          store.failNext = true;
          // Exercise the actual installed callback, recording async failures.
          runZonedGuarded(() => callback()(), (error, _) => errors.add(error));
          await tester.pumpAndSettle();
          expect(errors, isEmpty);
          expect(state.saved, isEmpty);
          expect(_persistedSaved(store), isEmpty);
          expect(find.byType(SnackBar), findsOneWidget);
          final errorText = tester
              .widget<Text>(
                find
                    .descendant(
                      of: find.byType(SnackBar),
                      matching: find.byType(Text),
                    )
                    .first,
              )
              .data!;
          expect(errorText, contains(lang == 'de' ? 'Speicher' : 'storage'));
          // A later notification must not reveal a phantom bookmark.
          await state.updateProfile(state.profile);
          await tester.pumpAndSettle();
          if (surface != 'detail') {
            expect(tester.widget<BookmarkBadge>(control).saved, isFalse);
          } else {
            expect(
              (tester.widget<IconButton>(control).icon as Icon).icon,
              Icons.bookmark_border,
            );
          }
          callback()();
          await tester.pumpAndSettle();
          expect(state.saved, hasLength(1));
          final id = state.saved.single.recipeId;
          final reloaded = AppState(store: store, corpus: state.corpus);
          await reloaded.load();
          expect(reloaded.isSaved(id), isTrue);
          reloaded.dispose();

          // Removal uses the same callback and must preserve the saved entry
          // after failure, including an unrelated rebuild and a later retry.
          ScaffoldMessenger.of(tester.element(control)).removeCurrentSnackBar();
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          final beforeRemoval = state.saved.map((s) => s.toJson()).toList();
          store.failNext = true;
          runZonedGuarded(() => callback()(), (error, _) => errors.add(error));
          await tester.pumpAndSettle();
          expect(errors, isEmpty);
          expect(state.saved.map((s) => s.toJson()).toList(), beforeRemoval);
          expect(_persistedSaved(store), beforeRemoval);
          expect(find.text(errorText), findsOneWidget);
          await state.updateProfile(state.profile);
          await tester.pumpAndSettle();
          if (surface != 'detail') {
            expect(tester.widget<BookmarkBadge>(control).saved, isTrue);
          } else {
            expect(
              (tester.widget<IconButton>(control).icon as Icon).icon,
              Icons.bookmark,
            );
          }
          callback()();
          await tester.pumpAndSettle();
          expect(state.saved, isEmpty);
          expect(_persistedSaved(store), isEmpty);
          final removed = AppState(store: store, corpus: state.corpus);
          await removed.load();
          addTearDown(removed.dispose);
          expect(removed.isSaved(id), isFalse);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

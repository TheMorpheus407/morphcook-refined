import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/recipe_photo_search_screen.dart';

import 'helpers.dart';
import 'recipe_photo_search_widget_test.dart'
    show app, candidate, photoState, FakePhotoSearch, OrderedPhotoSearch;

class _PausedProfileStore extends MemoryStore {
  bool pauseNext = false;
  final release = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (pauseNext) {
      pauseNext = false;
      await release.future;
    }
    await super.saveProfile(profile);
  }
}

Finder get _runButton => find.byKey(const ValueKey('run-photo-search'));
Finder get _query => find.byKey(const ValueKey('photo-search-query'));

Widget _screen(AppState state, FakePhotoSearch search) => app(
  state,
  RecipePhotoSearchScreen(
    recipeId: 'doener-vegan',
    initialQuery: 'food',
    photoSearch: search,
  ),
);

void main() {
  testWidgets('an opted-out search screen dispatches no initial request', (
    tester,
  ) async {
    final state = (await tester.runAsync(photoState))!;
    final search = FakePhotoSearch();
    await tester.pumpWidget(_screen(state, search));
    await tester.pumpAndSettle();
    expect(search.queries, isEmpty);
    expect(search.downloads, isEmpty);
    expect(tester.widget<IconButton>(_runButton).onPressed, isNull);
    expect(tester.widget<TextField>(_query).enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('completed opt-out blocks new search and retained callbacks', (
    tester,
  ) async {
    final store = _PausedProfileStore();
    final state = (await tester.runAsync(() async {
      final state = AppState(store: store, corpus: await loadRealCorpus());
      await state.load();
      await state.completeOnboarding(const Profile(imageSearchEnabled: true));
      return state;
    }))!;
    final search = FakePhotoSearch()..results = [];
    store.pauseNext = true;
    final disabling = state.updateProfile(
      state.profile.copyWith(imageSearchEnabled: false),
    );
    addTearDown(() {
      if (!store.release.isCompleted) store.release.complete();
    });
    // Enter while the Settings opt-out is still persisting.
    await tester.pumpWidget(_screen(state, search));
    await tester.pumpAndSettle();
    final retainedSearch = tester.widget<IconButton>(_runButton).onPressed!;
    final retainedSubmit = tester.widget<TextField>(_query).onSubmitted!;
    await tester.enterText(_query, 'second search');
    store.release.complete();
    await disabling;
    await tester.pumpAndSettle();
    expect(store.loadProfile()!.imageSearchEnabled, isFalse);
    retainedSearch();
    retainedSubmit('second search');
    await tester.pumpAndSettle();
    expect(search.queries, ['food']);
    expect(search.downloads, isEmpty);
    expect(tester.widget<IconButton>(_runButton).onPressed, isNull);
    expect(tester.widget<TextField>(_query).enabled, isFalse);

    // Re-enabling alone does not search; a new explicit request still works.
    await state.updateProfile(state.profile.copyWith(imageSearchEnabled: true));
    await tester.pumpAndSettle();
    expect(search.queries, ['food']);
    await tester.tap(_runButton);
    await tester.pumpAndSettle();
    expect(search.queries, ['food', 'second search']);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final reenableBeforeFrame in [false, true]) {
    testWidgets(
      'late results cannot dispatch previews after opt-out: reenable=$reenableBeforeFrame',
      (tester) async {
        final state = (await tester.runAsync(() => photoState(enabled: true)))!;
        final search = OrderedPhotoSearch();
        await tester.pumpWidget(_screen(state, search));
        await tester.pump();
        expect(search.searches, hasLength(1));
        await state.updateProfile(
          state.profile.copyWith(imageSearchEnabled: false),
        );
        if (reenableBeforeFrame) {
          await state.updateProfile(
            state.profile.copyWith(imageSearchEnabled: true),
          );
        }
        search.searches.single.complete([candidate('Late photo')]);
        await tester.pumpAndSettle();
        expect(search.downloads, isEmpty);
        expect(find.byKey(const ValueKey('found-photo-0')), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      },
    );
  }
}

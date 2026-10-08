import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/import/recipe_photo_search.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe_image.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/recipe_photo_search_screen.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

const en = S('en');

RecipePhotoCandidate candidate(String name, {String? author = 'Ann'}) =>
    RecipePhotoCandidate(
      imageUrl: Uri.parse('https://thumb.wikimedia.org/$name.jpg'),
      credit: RecipeImageCredit.tryCreate(
        title: name,
        author: author,
        license: 'CC BY-SA 4.0',
        provider: recipePhotoProvider,
        sourceUrl: 'https://commons.wikimedia.org/wiki/File:$name.jpg',
      )!,
    );

class FakePhotoSearch extends RecipePhotoSearch {
  final queries = <String>[];
  final downloads = <String>[];
  List<RecipePhotoCandidate> results = [
    candidate('Doener plate'),
    candidate('broken preview', author: null),
  ];
  RecipePhotoSearchFailure? fail;

  @override
  Future<List<RecipePhotoCandidate>> search(
    String query, {
    String lang = 'en',
  }) async {
    queries.add(query);
    if (fail case final failure?) throw RecipePhotoSearchException(failure);
    return results;
  }

  @override
  Future<Uint8List> download(RecipePhotoCandidate candidate) async {
    downloads.add(candidate.credit.title);
    if (candidate.credit.title.contains('broken')) {
      throw const RecipePhotoSearchException(
        RecipePhotoSearchFailure.unsupportedImage,
      );
    }
    return testPngBytes();
  }
}

Future<AppState> photoState({bool enabled = false}) async {
  final state = AppState(store: MemoryStore(), corpus: await loadRealCorpus());
  await state.load();
  await state.completeOnboarding(
    Profile(lang: 'en', imageSearchEnabled: enabled),
  );
  return state;
}

Widget app(AppState state, Widget child) => ChangeNotifierProvider.value(
  value: state,
  child: MaterialApp(theme: morphThemeData(MorphColors.light), home: child),
);

Finder get searchButton => find.byKey(const ValueKey('search-recipe-image'));
Finder get useButton => find.byKey(const ValueKey('use-found-photo'));

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('settings switch enables photo search and persists the choice', (
    tester,
  ) async {
    final state = (await tester.runAsync(photoState))!;
    await tester.pumpWidget(app(state, const Scaffold(body: SettingsScreen())));
    await tester.pumpAndSettle();

    final label = find.text(en('imageSearch'));
    await tester.scrollUntilVisible(
      label,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(en('imageSearchHint')), findsOneWidget);
    final toggle = find.descendant(
      of: find.ancestor(of: label, matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.profile.imageSearchEnabled, isTrue);
    expect(state.store.loadProfile()?.imageSearchEnabled, isTrue);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.store.loadProfile()?.imageSearchEnabled, isFalse);
  });

  testWidgets('recipe pages offer no online search while it is off', (
    tester,
  ) async {
    final state = (await tester.runAsync(photoState))!;
    final search = FakePhotoSearch();
    await tester.pumpWidget(
      app(state, DishDetailScreen(dishId: 'doener', photoSearch: search)),
    );
    await tester.pumpAndSettle();

    expect(searchButton, findsNothing);
    expect(find.byKey(const ValueKey('set-recipe-image')), findsOneWidget);
    expect(search.queries, isEmpty);
    expect(search.downloads, isEmpty);

    // Enabling it in settings shows the action without contacting anyone.
    await state.updateProfile(state.profile.copyWith(imageSearchEnabled: true));
    await tester.pumpAndSettle();
    expect(searchButton, findsOneWidget);
    expect(search.queries, isEmpty);
  });

  testWidgets('choosing a found photo stores it with a visible credit', (
    tester,
  ) async {
    final state = (await tester.runAsync(() => photoState(enabled: true)))!;
    final search = FakePhotoSearch();
    await tester.pumpWidget(
      app(state, DishDetailScreen(dishId: 'doener', photoSearch: search)),
    );
    await tester.pumpAndSettle();

    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(find.byType(RecipePhotoSearchScreen), findsOneWidget);
    // Bundled dishes search with their English name.
    expect(search.queries, [state.dishById('doener')!.name.of('en')]);
    expect(search.downloads, ['Doener plate', 'broken preview']);
    expect(find.text(en('photoPreviewFailed')), findsOneWidget);
    expect(find.text('Ann · CC BY-SA 4.0'), findsOneWidget);

    // Nothing is chosen yet, and a failed preview cannot be chosen.
    expect(tester.widget<FilledButton>(useButton).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('found-photo-1')));
    await tester.pump();
    expect(tester.widget<FilledButton>(useButton).onPressed, isNull);
    expect(state.recipeImages, isEmpty);

    await tester.tap(find.byKey(const ValueKey('found-photo-0')));
    await tester.pump();
    expect(find.text(en('useThisPhoto')), findsOneWidget);
    expect(
      find.text('Photo: Doener plate · Ann · CC BY-SA 4.0 · Wikimedia Commons'),
      findsOneWidget,
    );
    await tester.tap(useButton);
    await tester.pumpAndSettle();

    expect(find.byType(RecipePhotoSearchScreen), findsNothing);
    expect(find.text(en('photoSearchSaved')), findsOneWidget);
    final stored = state.recipeImages.single;
    expect(stored.bytes, orderedEquals(testPngBytes()));
    expect(stored.credit, candidate('Doener plate').credit);
    // No extra request: the chosen preview is what gets stored.
    expect(search.downloads, hasLength(2));
    expect(
      find.text(
        'Photo: Doener plate · Ann · CC BY-SA 4.0 · Wikimedia Commons\n'
        '${en('onlinePhotoNote')}',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recipe-image-credit')), findsOneWidget);

    // A device photo replaces the found one and removes its credit.
    await tester.pumpWidget(
      app(
        state,
        DishDetailScreen(
          key: const ValueKey('device'),
          dishId: 'doener',
          pickImageBytes: () async => testPngBytes(),
          photoSearch: search,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('set-recipe-image')));
    await tester.pumpAndSettle();
    expect(state.recipeImages.single.credit, isNull);
    expect(find.byKey(const ValueKey('recipe-image-credit')), findsNothing);
  });

  testWidgets('search words can be refined; failures and no results explain', (
    tester,
  ) async {
    final state = (await tester.runAsync(() => photoState(enabled: true)))!;
    final search = FakePhotoSearch()..fail = RecipePhotoSearchFailure.network;
    await tester.pumpWidget(
      app(
        state,
        RecipePhotoSearchScreen(
          recipeId: 'doener-vegan',
          initialQuery: '  Döner   Kebab ',
          photoSearch: search,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(search.queries, ['Döner Kebab']);
    expect(find.text(en('photoSearchFailed')), findsOneWidget);

    search.fail = RecipePhotoSearchFailure.busy;
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await tester.pumpAndSettle();
    expect(find.text(en('photoSearchFailed')), findsNothing);
    expect(find.text(en('photoSearchBusy')), findsOneWidget);

    search
      ..fail = null
      ..results = [];
    await tester.enterText(
      find.byKey(const ValueKey('photo-search-query')),
      'kebab plate',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(search.queries.last, 'kebab plate');
    expect(find.text(en('photoSearchBusy')), findsNothing);
    expect(find.text(en('photoSearchEmpty')), findsOneWidget);

    search.results = [candidate('Kebab plate')];
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await tester.pumpAndSettle();
    expect(search.queries, hasLength(4));
    expect(find.text(en('photoSearchEmpty')), findsNothing);
    expect(find.byKey(const ValueKey('found-photo-0')), findsOneWidget);
    expect(state.recipeImages, isEmpty);
  });

  testWidgets('an empty query opens without searching', (tester) async {
    final state = (await tester.runAsync(() => photoState(enabled: true)))!;
    final search = FakePhotoSearch();
    await tester.pumpWidget(
      app(
        state,
        RecipePhotoSearchScreen(
          recipeId: 'doener-vegan',
          initialQuery: ' ',
          photoSearch: search,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await tester.pumpAndSettle();
    expect(search.queries, isEmpty);
    expect(find.text(en('photoSearchEmpty')), findsNothing);
  });

  testWidgets('a full photo store keeps the search open with a reason', (
    tester,
  ) async {
    final state = (await tester.runAsync(() async {
      final state = await photoState(enabled: true);
      final ids = <String>[];
      for (final dish in state.corpus.dishes) {
        for (final recipe in await state.variantsOf(dish)) {
          if (ids.length < maxBackupRecipeImages &&
              recipe.id != 'doener-vegan') {
            ids.add(recipe.id);
          }
        }
      }
      for (final id in ids) {
        await state.setRecipeImage(id, testPngBytes());
      }
      return state;
    }))!;
    expect(state.recipeImages, hasLength(maxBackupRecipeImages));
    await tester.pumpWidget(
      app(
        state,
        RecipePhotoSearchScreen(
          recipeId: 'doener-vegan',
          initialQuery: 'doener',
          photoSearch: FakePhotoSearch(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('found-photo-0')));
    await tester.pump();
    await tester.tap(useButton);
    await tester.pumpAndSettle();

    expect(find.byType(RecipePhotoSearchScreen), findsOneWidget);
    expect(find.text(en('recipeImageStorageFull')), findsOneWidget);
    expect(state.recipeImageFor('doener-vegan'), isNull);
    expect(tester.widget<FilledButton>(useButton).onPressed, isNotNull);
  });

  testWidgets('photo actions, credit and results fit a phone in German', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360 * 3, 690 * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() async {
      final state = await photoState(enabled: true);
      await state.updateProfile(state.profile.copyWith(lang: 'de'));
      final recipe = await state.bestVariant('doener');
      await state.setRecipeImage(
        recipe!.id,
        testPngBytes(),
        credit: RecipeImageCredit.tryCreate(
          title: 'Döner Kebab, Berlin, 2010 (01) — a long descriptive title',
          author: 'A photographer with a rather long display name',
          license: 'CC BY-SA 4.0',
          provider: recipePhotoProvider,
          sourceUrl: 'https://commons.wikimedia.org/wiki/File:Doener.jpg',
        ),
      );
      return state;
    }))!;
    final search = FakePhotoSearch();
    await tester.pumpWidget(
      app(state, DishDetailScreen(dishId: 'doener', photoSearch: search)),
    );
    await tester.pumpAndSettle();
    expect(searchButton, findsOneWidget);
    expect(find.byKey(const ValueKey('remove-recipe-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-image-credit')), findsOneWidget);

    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('found-photo-0')));
    await tester.pumpAndSettle();
    expect(find.text(const S('de')('useThisPhoto')), findsOneWidget);
  });

  test('photo search copy exists in english and german', () {
    const de = S('de');
    for (final key in [
      'onlinePhotos',
      'imageSearch',
      'imageSearchHint',
      'findRecipeImage',
      'photoSearchTitle',
      'photoSearchQuery',
      'photoSearchButton',
      'photoSearchHint',
      'photoSearchEmpty',
      'photoSearchFailed',
      'photoSearchBusy',
      'photoPreviewFailed',
      'useThisPhoto',
      'choosePhotoFirst',
      'photoSearchSaved',
      'onlinePhotoNote',
      'openPhotoSource',
    ]) {
      expect(en(key), isNot(key), reason: 'missing EN $key');
      expect(de(key), isNot(key), reason: 'missing DE $key');
      expect(de(key), isNot(en(key)), reason: 'untranslated $key');
    }
  });
}

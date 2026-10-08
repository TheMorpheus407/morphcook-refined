import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
  Uint8List? previewBytes;

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
    return previewBytes ?? testPngBytes();
  }
}

class DelayedPhotoSearch extends FakePhotoSearch {
  final pending = <RecipePhotoCandidate, Completer<Uint8List>>{};

  @override
  Future<Uint8List> download(RecipePhotoCandidate candidate) {
    final completer = pending[candidate];
    if (completer == null) return super.download(candidate);
    downloads.add(candidate.credit.title);
    return completer.future;
  }
}

Future<Uint8List> differentPngBytes() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.red, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
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

// Platform image decoding runs outside the test's fake clock. Await actual
// image streams so assertions test a displayed preview, not just its download.
Future<void> settlePhotos(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  if (images.isNotEmpty) {
    final context = tester.element(find.byType(Image).first);
    await tester.runAsync(() async {
      for (final image in images) {
        await precacheImage(image.image, context, onError: (_, _) {});
      }
    });
    await tester.pumpAndSettle();
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  for (final outcome in [
    'success',
    'download failure',
    'decoder failure',
    'same candidate',
  ]) {
    testWidgets('repeated search never reuses old preview: $outcome', (
      tester,
    ) async {
      final state = (await tester.runAsync(() => photoState(enabled: true)))!;
      final first = candidate('First photo');
      final next = outcome == 'same candidate'
          ? first
          : candidate('Next photo', author: 'Bea');
      final search = DelayedPhotoSearch()..results = [first];
      await tester.pumpWidget(
        app(state, DishDetailScreen(dishId: 'doener', photoSearch: search)),
      );
      await settlePhotos(tester);
      await tester.tap(searchButton);
      await settlePhotos(tester);
      final tile = find.byKey(const ValueKey('found-photo-0'));
      await tester.tap(tile);
      await tester.pump();
      expect(tester.widget<FilledButton>(useButton).onPressed, isNotNull);

      final pending = Completer<Uint8List>();
      search
        ..results = [next]
        ..pending[next] = pending;
      // The search resolves before the next frame: the old tile is reused
      // without an intermediate frame rendering the empty results list.
      await tester.tap(find.byKey(const ValueKey('run-photo-search')));
      await tester.pump();
      await tester.pump();
      expect(search.downloads, [first.credit.title, next.credit.title]);
      expect(
        tester.widget<InkWell>(tile).onTap,
        isNull,
        reason: 'A new result must wait for its own download and decode',
      );
      await tester.tap(tile);
      await tester.pump();
      expect(tester.widget<FilledButton>(useButton).onPressed, isNull);
      expect(state.recipeImages, isEmpty);

      if (outcome == 'download failure') {
        pending.completeError(
          const RecipePhotoSearchException(RecipePhotoSearchFailure.network),
        );
      } else if (outcome == 'decoder failure') {
        pending.complete(testPngBytes()..[24] = 3);
      } else {
        final bytes = (await tester.runAsync(differentPngBytes))!;
        expect(bytes, isNot(orderedEquals(testPngBytes())));
        pending.complete(bytes);
        await settlePhotos(tester);
        expect(tester.widget<InkWell>(tile).onTap, isNotNull);
        await tester.tap(tile);
        await tester.pump();
        await tester.tap(useButton);
        await settlePhotos(tester);
        final stored = state.recipeImages.single;
        expect(stored.bytes, orderedEquals(bytes));
        expect(stored.credit, next.credit);
        expect(search.downloads, hasLength(2));
        return;
      }
      await settlePhotos(tester);
      expect(find.text(en('photoPreviewFailed')), findsOneWidget);
      expect(tester.widget<InkWell>(tile).onTap, isNull);
      await tester.tap(tile);
      await tester.pump();
      expect(tester.widget<FilledButton>(useButton).onPressed, isNull);
      expect(state.recipeImages, isEmpty);
    });
  }

  testWidgets('decoder failures cannot replace a working photo', (
    tester,
  ) async {
    final state = (await tester.runAsync(() => photoState(enabled: true)))!;
    await state.setRecipeImage('doener-vegan', testPngBytes());
    final broken = testPngBytes()..[24] = 3; // Invalid PNG bit depth.
    // Header validation accepts this; the platform decoder cannot display it.
    RecipeImage(
      recipeId: 'doener-vegan',
      bytes: broken,
      updatedAt: DateTime.now(),
    );
    final search = FakePhotoSearch()
      ..results = [candidate('undecodable')]
      ..previewBytes = broken;
    await tester.pumpWidget(
      app(
        state,
        RecipePhotoSearchScreen(
          recipeId: 'doener-vegan',
          initialQuery: 'doener',
          photoSearch: search,
        ),
      ),
    );
    await settlePhotos(tester);
    expect(find.text(en('photoPreviewFailed')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('found-photo-0')));
    await tester.pump();
    expect(tester.widget<FilledButton>(useButton).onPressed, isNull);
    expect(
      state.recipeImageFor('doener-vegan')!.bytes,
      orderedEquals(testPngBytes()),
    );
  });

  testWidgets('search and save controls scroll with a landscape keyboard', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(690 * 3, 360 * 3)
      ..devicePixelRatio = 3
      ..viewInsets = const FakeViewPadding(bottom: 210 * 3);
    addTearDown(tester.view.reset);
    final state = (await tester.runAsync(() => photoState(enabled: true)))!;
    await state.updateProfile(state.profile.copyWith(lang: 'de'));
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
    await settlePhotos(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('run-photo-search')));
    await settlePhotos(tester);
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await settlePhotos(tester);
    await tester.scrollUntilVisible(
      useButton,
      100,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settlePhotos(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings switch enables photo search and persists the choice', (
    tester,
  ) async {
    final state = (await tester.runAsync(photoState))!;
    await tester.pumpWidget(app(state, const Scaffold(body: SettingsScreen())));
    await settlePhotos(tester);

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
    await settlePhotos(tester);
    expect(state.profile.imageSearchEnabled, isTrue);
    expect(state.store.loadProfile()?.imageSearchEnabled, isTrue);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await settlePhotos(tester);
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
    await settlePhotos(tester);

    expect(searchButton, findsNothing);
    expect(find.byKey(const ValueKey('set-recipe-image')), findsOneWidget);
    expect(search.queries, isEmpty);
    expect(search.downloads, isEmpty);

    // Enabling it in settings shows the action without contacting anyone.
    await state.updateProfile(state.profile.copyWith(imageSearchEnabled: true));
    await settlePhotos(tester);
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
    await settlePhotos(tester);

    await tester.tap(searchButton);
    await settlePhotos(tester);
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
    await settlePhotos(tester);

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

    // Disabling search retains the saved photo and credit without a request.
    await state.updateProfile(
      state.profile.copyWith(imageSearchEnabled: false),
    );
    await settlePhotos(tester);
    expect(searchButton, findsNothing);
    expect(state.recipeImages.single.credit, candidate('Doener plate').credit);
    expect(search.queries, hasLength(1));
    expect(search.downloads, hasLength(2));

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
    await settlePhotos(tester);
    await tester.tap(find.byKey(const ValueKey('set-recipe-image')));
    await settlePhotos(tester);
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
    await settlePhotos(tester);
    expect(search.queries, ['Döner Kebab']);
    expect(find.text(en('photoSearchFailed')), findsOneWidget);

    search.fail = RecipePhotoSearchFailure.busy;
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await settlePhotos(tester);
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
    await settlePhotos(tester);
    expect(search.queries.last, 'kebab plate');
    expect(find.text(en('photoSearchBusy')), findsNothing);
    expect(find.text(en('photoSearchEmpty')), findsOneWidget);

    search.results = [candidate('Kebab plate')];
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await settlePhotos(tester);
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
    await settlePhotos(tester);
    await tester.tap(find.byKey(const ValueKey('run-photo-search')));
    await settlePhotos(tester);
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
    await settlePhotos(tester);
    await tester.tap(find.byKey(const ValueKey('found-photo-0')));
    await tester.pump();
    await tester.tap(useButton);
    await settlePhotos(tester);

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
    await settlePhotos(tester);
    expect(searchButton, findsOneWidget);
    expect(find.byKey(const ValueKey('remove-recipe-image')), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-image-credit')), findsOneWidget);

    await tester.tap(searchButton);
    await settlePhotos(tester);
    await tester.tap(find.byKey(const ValueKey('found-photo-0')));
    await settlePhotos(tester);
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

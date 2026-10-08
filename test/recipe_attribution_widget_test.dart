import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/corpus.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/sharing/recipe_share.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

// Match AI authorship without requiring widget keys or naming a particular
// AI model that the corpus does not identify.
final _englishAi = RegExp(
  r'\bAI\b|artificial intelligence',
  caseSensitive: false,
);
final _germanAi = RegExp(
  r'\bKI\b|künstliche Intelligenz',
  caseSensitive: false,
);
final _anyAi = RegExp(
  r'\bAI\b|artificial intelligence|\bKI\b|künstliche Intelligenz',
  caseSensitive: false,
);

// Wait for file reads started by the detail screen on the real event loop.
// Keep non-core partitions unloaded until the screen actually requests them.
class _AttributionAssetBundle extends FileAssetBundle {
  final reads = <Future<String>>[];

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    final read = super.loadString(key, cache: cache);
    reads.add(read);
    return read;
  }
}

Future<AppState> _state(String lang) async {
  final corpus = CorpusRepository(bundle: _AttributionAssetBundle());
  await corpus.initialize();
  final state = AppState(store: MemoryStore(), corpus: corpus);
  await state.load();
  await state.completeOnboarding(Profile(lang: lang));
  return state;
}

Future<void> _openDetail(
  WidgetTester tester,
  AppState state,
  String dishId,
) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          theme: morphThemeData(MorphColors.light),
          home: DishDetailScreen(key: ValueKey(dishId), dishId: dishId),
        ),
      ),
    );
    await Future.wait((state.corpus.bundle as _AttributionAssetBundle).reads);
  });
  await tester.pumpAndSettle();
}

void main() {
  for (final lang in ['en', 'de']) {
    testWidgets('bundled recipe discloses its AI origin in $lang', (
      tester,
    ) async {
      final state = (await tester.runAsync(() => _state(lang)))!;
      addTearDown(state.dispose);
      await _openDetail(tester, state, 'doener');

      // The disclosure belongs on the recipe itself, where a cook decides
      // whether to spend ingredients and time, rather than in app credits.
      final disclosure = find.descendant(
        of: find.byType(DishDetailScreen),
        matching: find.textContaining(lang == 'de' ? _germanAi : _englishAi),
      );
      expect(
        disclosure,
        findsOneWidget,
        reason: 'A bundled recipe must identify its AI origin to the cook.',
      );
      expect(
        tester.widget<Text>(disclosure).data,
        contains('MorphCook'),
        reason: 'The origin disclosure must identify the recipe collection.',
      );
      final origin = tester.widget<Text>(disclosure).data!;
      final generation = lang == 'de'
          ? r'\b(?:generier|erstell|verfass)\w*'
          : r'\b(?:generat|creat|writ|author)\w*';
      final denial = lang == 'de'
          ? r'\b(?:nicht|nie|kein\w*|ohne)\b'
          : r'\b(?:not|never|no|without)\b';
      expect(
        origin,
        matches(RegExp(generation, caseSensitive: false)),
        reason: 'The disclosure must describe how the recipe was authored.',
      );
      expect(
        origin,
        isNot(
          matches(RegExp('$denial[^.!?]*$generation', caseSensitive: false)),
        ),
        reason: 'The disclosure must not deny AI authorship.',
      );
      expect(
        origin,
        contains(
          lang == 'de'
              ? 'Ein Nachkochen durch Menschen ist nicht bestätigt.'
              : 'Human cooking verification is not provided.',
        ),
        reason: 'The disclosure must not imply verified human cooking.',
      );
      await tester.ensureVisible(disclosure.first);
      await tester.pumpAndSettle();
      expect(disclosure.hitTestable(), findsWidgets);
    });

    testWidgets('on-demand bundled recipe discloses its origin in $lang', (
      tester,
    ) async {
      final state = (await tester.runAsync(() => _state(lang)))!;
      addTearDown(state.dispose);
      final dish = state.dishById('risotto')!;
      expect(state.corpus.isPartitionLoaded(dish.partitionId), isFalse);
      expect(
        dish.recipeIds.map(state.corpus.loadedRecipeById),
        everyElement(isNull),
      );

      await _openDetail(tester, state, dish.id);

      expect(state.corpus.isPartitionLoaded(dish.partitionId), isTrue);
      expect(find.text('bundledRecipeOrigin'), findsNothing);
      final disclosure = find.text(S(lang)('bundledRecipeOrigin'));
      expect(disclosure, findsOneWidget);
      await tester.ensureVisible(disclosure);
      await tester.pumpAndSettle();
      expect(disclosure.hitTestable(), findsOneWidget);
    });

    testWidgets('shared bundled copy discloses its original AI origin in $lang', (
      tester,
    ) async {
      final sender = (await tester.runAsync(() => _state(lang)))!;
      final recipient = (await tester.runAsync(() => _state(lang)))!;
      addTearDown(sender.dispose);
      addTearDown(recipient.dispose);
      final shared = (await tester.runAsync(
        () async => decodeRecipeShare(
          encodeRecipeShare(
            await collectRecipeShare(sender, recipeId: 'doener-vegan'),
          ),
        ),
      ))!;
      await tester.runAsync(() => recipient.importSharedRecipes(shared));
      final copy = recipient.personalRecipes.single;
      // Personal edits must not erase the original authorship or imply that
      // the current text is an unchanged, wholly AI-authored corpus recipe.
      await _openDetail(tester, recipient, copy.dishId);
      final expected = lang == 'de'
          ? 'Ursprüngliches Rezept (Herkunftsangabe des Absenders, ungeprüft): MorphCook-Sammlung · KI-generiert. Ein Nachkochen durch Menschen ist nicht bestätigt.'
          : 'Original recipe (sender-supplied origin, unverified): MorphCook collection · AI-generated. Human cooking verification is not provided.';
      final disclosure = find.text(expected);
      expect(disclosure, findsOneWidget);
      await tester.ensureVisible(disclosure);
      await tester.pumpAndSettle();
      expect(disclosure.hitTestable(), findsOneWidget);
      expect(find.text(S(lang)('bundledRecipeOrigin')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('edit-personal-recipe')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recipe-title')),
        'My adapted döner',
      );
      final save = find.byKey(const ValueKey('save-personal-recipe'));
      await tester.scrollUntilVisible(
        save,
        400,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(recipient.personalRecipes.single.title, 'My adapted döner');
      await tester.drag(find.byType(ListView), const Offset(0, 1000));
      await tester.pumpAndSettle();
      expect(disclosure, findsOneWidget);

      // Older bundled shares have the same ID but no origin metadata. Do not
      // infer provenance from that ID or from recipe text.
      final legacy = PersonalRecipe.fromJson(
        copy.toJson()..remove('bundled_origin'),
      );
      await tester.runAsync(() => recipient.savePersonalRecipe(legacy));
      await tester.pumpWidget(const SizedBox());
      await _openDetail(tester, recipient, legacy.dishId);
      expect(find.textContaining(_anyAi), findsNothing);
    });

    testWidgets('sender-supplied origin stays qualified in details in $lang', (
      tester,
    ) async {
      final recipient = (await tester.runAsync(() => _state(lang)))!;
      addTearDown(recipient.dispose);
      final arbitrary = PersonalRecipe.create(
        title: 'A sender’s carrot soup',
        sourceUrl: 'https://example.com/carrot-soup',
        sourceAuthor: 'Alex Example',
        timeMinutes: 30,
        servings: 2,
        ingredients: [
          PersonalRecipeIngredient(name: 'carrots', qty: 200, unit: 'g'),
        ],
        steps: [PersonalRecipeStep(text: 'Simmer the carrots.')],
      );
      // A valid file can claim a bundled origin for arbitrary content. The
      // importer must preserve the claim without presenting it as verified.
      final incoming = decodeRecipeShare(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'format': recipeShareFormat,
              'version': recipeShareVersion,
              'recipes': [
                {...arbitrary.toJson(), 'bundled_origin': true},
              ],
            }),
          ),
        ),
      );
      await tester.runAsync(() => recipient.importSharedRecipes(incoming));
      expect(recipient.personalRecipes.single.bundledOrigin, isTrue);

      final expected = lang == 'de'
          ? 'Ursprüngliches Rezept (Herkunftsangabe des Absenders, ungeprüft): MorphCook-Sammlung · KI-generiert. Ein Nachkochen durch Menschen ist nicht bestätigt.'
          : 'Original recipe (sender-supplied origin, unverified): MorphCook collection · AI-generated. Human cooking verification is not provided.';
      for (final edited in [false, true]) {
        if (edited) {
          await tester.runAsync(
            () => recipient.savePersonalRecipe(
              recipient.personalRecipes.single.copyWith(
                title: 'My adapted soup',
                steps: [PersonalRecipeStep(text: 'My own instructions.')],
              ),
            ),
          );
          await tester.pumpWidget(const SizedBox());
        }
        await _openDetail(tester, recipient, arbitrary.dishId);
        final disclosure = find.text(expected);
        expect(disclosure, findsOneWidget);
        await tester.ensureVisible(disclosure);
        await tester.pumpAndSettle();
        expect(disclosure.hitTestable(), findsOneWidget);
        expect(find.text(S(lang)('bundledRecipeOrigin')), findsNothing);
        expect(
          find.text('${S(lang)('sourceAuthor')}: Alex Example'),
          findsOneWidget,
        );
        expect(
          find.text(
            '${S(lang)('recipeSource')}: https://example.com/carrot-soup',
          ),
          findsOneWidget,
        );
      }

      final unclassified = PersonalRecipe.fromJson({
        ...recipient.personalRecipes.single.toJson(),
        'bundled_origin': false,
      });
      await tester.runAsync(() => recipient.savePersonalRecipe(unclassified));
      await tester.pumpWidget(const SizedBox());
      await _openDetail(tester, recipient, arbitrary.dishId);
      expect(find.textContaining(_anyAi), findsNothing);
    });
  }

  testWidgets('bundled recipe keeps its origin when switching variants', (
    tester,
  ) async {
    final state = (await tester.runAsync(() => _state('en')))!;
    addTearDown(state.dispose);
    final initial = (await tester.runAsync(() => state.bestVariant('doener')))!;
    final variants = (await tester.runAsync(
      () => state.visibleVariants('doener'),
    ))!;
    final targetDiet = variants
        .firstWhere((recipe) => recipe.variant.diet != initial.variant.diet)
        .variant
        .diet;
    final targetTitles = variants
        .where((recipe) => recipe.variant.diet == targetDiet)
        .map((recipe) => recipe.title.of('en').toLowerCase())
        .toList();

    await _openDetail(tester, state, 'doener');
    final disclosure = find.textContaining(_englishAi);
    expect(disclosure, findsOneWidget);
    final origin = tester.widget<Text>(disclosure).data!;
    expect(origin, contains('MorphCook'));
    expect(find.text(initial.title.of('en').toLowerCase()), findsOneWidget);

    final dietRow = find.textContaining('— diet');
    await tester.ensureVisible(dietRow);
    await tester.tap(dietRow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(state.corpus.ontology.nameOf(targetDiet, 'en')).first,
    );
    await tester.pumpAndSettle();
    // Return to the header after scrolling the variant controls into view.
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    await tester.pumpAndSettle();
    expect(
      targetTitles.where((title) => find.text(title).evaluate().isNotEmpty),
      isNotEmpty,
      reason: 'A different diet variant must actually be selected.',
    );
    expect(find.text(origin), findsOneWidget);
    await tester.ensureVisible(find.text(origin));
    await tester.pumpAndSettle();
    expect(find.text(origin).hitTestable(), findsOneWidget);
    // Let the existing ingredient highlight reset finish before teardown.
    await tester.pump(const Duration(seconds: 2));
  });

  for (final lang in ['en', 'de']) {
    testWidgets(
      'personal recipes retain supplied authorship without bundled AI attribution in $lang',
      (tester) async {
        final state = (await tester.runAsync(() => _state(lang)))!;
        addTearDown(state.dispose);

        for (final imported in [false, true]) {
          final recipe = PersonalRecipe.create(
            title: imported ? 'Imported carrot soup' : 'My carrot soup',
            sourceUrl: imported ? 'https://example.com/carrot-soup' : null,
            sourceAuthor: imported ? 'Alex Example' : null,
            timeMinutes: 30,
            servings: 2,
            ingredients: [
              PersonalRecipeIngredient(name: 'carrots', qty: 200, unit: 'g'),
            ],
            steps: [PersonalRecipeStep(text: 'Simmer the carrots.')],
          );
          await tester.runAsync(() => state.savePersonalRecipe(recipe));
          await _openDetail(tester, state, recipe.dishId);

          expect(find.text(recipe.title), findsWidgets);
          expect(
            find.textContaining(_anyAi),
            findsNothing,
            reason: 'Personal recipes must not inherit the bundled AI origin.',
          );
          if (imported) {
            final author = find.text(
              '${S(lang)('sourceAuthor')}: Alex Example',
            );
            final source = find.text(
              '${S(lang)('recipeSource')}: https://example.com/carrot-soup',
            );
            expect(author, findsOneWidget);
            expect(source, findsOneWidget);
            await tester.ensureVisible(author);
            await tester.pumpAndSettle();
            expect(author.hitTestable(), findsOneWidget);
          }
        }
      },
    );
  }
}

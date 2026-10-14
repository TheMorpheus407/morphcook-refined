import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/main.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/search_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/widgets/decor.dart';
import 'package:morphcook/ui/widgets/recipe_row.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

void main() {
  for (final lang in ['en', 'de']) {
    testWidgets('$lang offstage search retains filters and ignores bookmarks', (
      tester,
    ) async {
      final state = (await tester.runAsync(() async {
        final state = AppState(
          store: MemoryStore(),
          corpus: await loadRealCorpus(),
        );
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        return state;
      }))!;
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state, const RootShell()));
      await tester.pumpAndSettle();
      final s = S(lang);
      await tester.tap(find.text(s('navSearch')));
      await tester.pumpAndSettle();
      final search = find.byType(SearchScreen);
      final mountedSearch = tester.state(search);
      final input = find.descendant(
        of: search,
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'pancake');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final category = state.corpus.categories.first;
      final categoryChip = find.widgetWithText(
        MonoChip,
        category.name.of(lang),
      );
      final veganChip = find.widgetWithText(
        MonoChip,
        state.corpus.ontology.nameOf('vegan', lang),
      );
      await tester.tap(categoryChip);
      await tester.pumpAndSettle();
      await tester.tap(veganChip);
      await tester.pumpAndSettle();

      List<RecipeRow> rows() => tester
          .widgetList<RecipeRow>(
            find.descendant(of: search, matching: find.byType(RecipeRow)),
          )
          .toList();
      final originalIds = rows().map((row) => row.recipe.id).toList();
      expect(originalIds, isNotEmpty);
      expect(
        rows().every(
          (row) =>
              row.recipe.attributes.contains('vegan') &&
              state.corpus.categoryOfRecipe(row.recipe) == category.id,
        ),
        isTrue,
      );
      final results = find.descendant(
        of: search,
        matching: find.byType(ListenableBuilder),
      );
      final pager = tester.widget<ListenableBuilder>(results).listenable;
      await state.toggleSaved(originalIds.first);
      await tester.pumpAndSettle();
      expect(tester.widget<ListenableBuilder>(results).listenable, same(pager));
      expect(rows().map((row) => row.recipe.id), originalIds);

      await tester.tap(find.text(s('navSettings')));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      await state.updateProfile(state.profile.copyWith(maxTimeMinutes: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s('navSearch')));
      await tester.pumpAndSettle();
      expect(tester.state(search), same(mountedSearch));
      expect(tester.widget<TextField>(input).controller!.text, 'pancake');
      expect(rows(), isEmpty);
      expect(tester.widget<MonoChip>(categoryChip).selected, isTrue);
      expect(tester.widget<MonoChip>(veganChip).selected, isTrue);

      await state.updateProfile(state.profile.copyWith(clearMaxTime: true));
      await tester.pumpAndSettle();
      expect(rows().map((row) => row.recipe.id), originalIds);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (filter, profile) in [
    ('ingredient', const Profile(avoidIngredients: {'ladyfingers'})),
    ('allergy', const Profile(avoidFlags: {'dairy'})),
    ('attribute', const Profile(requiredAttributes: {'vegan'})),
    ('time', const Profile(maxTimeMinutes: 1)),
    ('calories', const Profile(calorieTarget: 1)),
  ]) {
    testWidgets(
      'mounted search follows $filter profile restriction and removal',
      (tester) async {
        final state = (await tester.runAsync(() async {
          final state = AppState(
            store: MemoryStore(),
            corpus: await loadRealCorpus(),
          );
          await state.load();
          return state;
        }))!;
        addTearDown(state.dispose);
        // RootShell retains its pages in an IndexedStack when switching tabs.
        await tester.pumpWidget(
          app(
            state,
            const Scaffold(
              body: IndexedStack(
                index: 0,
                children: [SearchScreen(), SizedBox()],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'cheesecake');
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        final mountedSearch = tester.state(find.byType(SearchScreen));
        final classic = (await state.recipeById('cheesecake-classic'))!;
        expect(
          tester
              .widgetList<RecipeRow>(find.byType(RecipeRow))
              .map((row) => row.recipe.id),
          contains(classic.id),
        );
        expect(state.matcher.isVisible(classic, profile), isFalse);
        await state.updateProfile(profile);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(SearchScreen)), same(mountedSearch));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'cheesecake',
        );
        final visible = tester.widgetList<RecipeRow>(find.byType(RecipeRow));
        expect(
          visible.map((row) => row.recipe.id),
          isNot(contains(classic.id)),
        );
        expect(
          visible.every(
            (row) => state.matcher.isVisible(row.recipe, state.profile),
          ),
          isTrue,
        );
        // Relaxing the profile must restore results without typing again.
        await state.updateProfile(const Profile());
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<RecipeRow>(find.byType(RecipeRow))
              .map((row) => row.recipe.id),
          contains(classic.id),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

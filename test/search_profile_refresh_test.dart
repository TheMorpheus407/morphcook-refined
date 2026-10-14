import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/search_screen.dart';
import 'package:morphcook/ui/widgets/recipe_row.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

void main() {
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

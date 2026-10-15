import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/main.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/onboarding_screen.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/widgets/decor.dart';
import 'package:provider/provider.dart';
import 'helpers.dart';

class _PausedResetStore extends MemoryStore {
  _PausedResetStore(this.fail);
  final bool fail;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> clearAll() async {
    entered.complete();
    await release.future;
    if (fail) throw StateError('simulated reset failure');
    await super.clearAll();
  }
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final fail in [false, true]) {
      testWidgets(
        '$lang reset completes before first detail frame fail=$fail',
        (tester) async {
          final store = _PausedResetStore(fail);
          final recipe = PersonalRecipe.create(
            title: 'Private recipe',
            timeMinutes: 10,
            servings: 1,
            ingredients: [
              PersonalRecipeIngredient(name: 'rice', qty: 100, unit: 'g'),
            ],
            steps: [PersonalRecipeStep(text: 'Cook rice.')],
          );
          final state = (await tester.runAsync(() async {
            final state = AppState(
              store: store,
              corpus: await loadRealCorpus(),
            );
            await state.load();
            await state.completeOnboarding(Profile(lang: lang));
            await state.savePersonalRecipe(recipe);
            return state;
          }))!;
          addTearDown(() {
            if (!store.release.isCompleted) store.release.complete();
            state.dispose();
          });
          final published = Completer<void>();
          state.addListener(() {
            if (!state.onboarded && !published.isCompleted) {
              published.complete();
            }
          });
          final s = S(lang);
          await tester.pumpWidget(
            ChangeNotifierProvider.value(
              value: state,
              child: const ThemedApp(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.tune));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(s('resetApp')),
            400,
            scrollable: find
                .descendant(
                  of: find.byType(SettingsScreen),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(find.text(s('resetApp')));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(TextButton, s('erase')));
          await tester.pumpAndSettle();
          expect(store.entered.isCompleted, isTrue);
          await tester.tap(find.byIcon(Icons.bookmark_border).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text(recipe.title).first);
          // Navigator has pushed the route, but its widget has not built yet.
          store.release.complete();
          if (!fail) await published.future;
          await tester.pumpAndSettle();
          expect(find.byType(DishDetailScreen), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (fail) {
            expect(find.text(recipe.title), findsWidgets);
            expect(find.byType(SkeletonBlock), findsNothing);
            expect(find.text(S(state.lang)('recipeUnavailable')), findsNothing);
            expect(
              find.byKey(const ValueKey('edit-personal-recipe')),
              findsOneWidget,
            );
          } else {
            expect(state.personalRecipes, isEmpty);
            expect(find.byType(SkeletonBlock), findsNothing);
            expect(
              find.text(S(state.lang)('recipeUnavailable')),
              findsOneWidget,
            );
            expect(find.text(recipe.title), findsNothing);
            expect(
              find.byKey(const ValueKey('share-detail-recipe')),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('edit-personal-recipe')),
              findsNothing,
            );
            expect(find.text(S(state.lang)('startCooking')), findsNothing);
            await tester.pump(const Duration(seconds: 5));
            expect(find.byType(SkeletonBlock), findsNothing);
            expect(
              find.text(S(state.lang)('recipeUnavailable')),
              findsOneWidget,
            );
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.byType(OnboardingScreen), findsOneWidget);
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

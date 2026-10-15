import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/main.dart';
import 'package:morphcook/models/personal_recipe.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/onboarding_screen.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _PausedResetStore extends MemoryStore {
  _PausedResetStore({required this.fail});
  final bool fail;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> clearAll() async {
    entered.complete();
    await release.future;
    if (fail) throw StateError('reset failed');
    await super.clearAll();
  }
}

PersonalRecipe _recipe() => PersonalRecipe.create(
  title: 'Grandmother human recipe',
  sourceUrl: 'https://example.org/grandmother',
  sourceAuthor: 'Grandmother',
  timeMinutes: 10,
  servings: 1,
  ingredients: [PersonalRecipeIngredient(name: 'rice', qty: 100, unit: 'g')],
  steps: [PersonalRecipeStep(text: 'Cook it.')],
);

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final lang in ['en', 'de']) {
    for (final fail in [false, true]) {
      testWidgets('$lang personal details follow confirmed reset fail=$fail', (
        tester,
      ) async {
        final store = _PausedResetStore(fail: fail);
        final recipe = _recipe();
        final state = (await tester.runAsync(() async {
          final state = AppState(store: store, corpus: await loadRealCorpus());
          await state.load();
          await state.completeOnboarding(Profile(lang: lang));
          await state.savePersonalRecipe(recipe);
          return state;
        }))!;
        addTearDown(() {
          if (!store.release.isCompleted) store.release.complete();
          state.dispose();
        });
        final s = S(lang);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(value: state, child: const ThemedApp()),
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
        await tester.pumpAndSettle();
        expect(find.byType(DishDetailScreen), findsOneWidget);
        expect(find.text(recipe.title), findsWidgets);
        expect(find.text('${s('sourceAuthor')}: Grandmother'), findsOneWidget);
        expect(find.text(s('bundledRecipeOrigin')), findsNothing);

        store.release.complete();
        await tester.pumpAndSettle();
        expect(find.text(S(state.lang)('bundledRecipeOrigin')), findsNothing);
        if (fail) {
          expect(state.personalRecipeById(recipe.id), isNotNull);
          expect(find.text(recipe.title), findsWidgets);
          expect(
            find.text('${s('sourceAuthor')}: Grandmother'),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('edit-personal-recipe')),
            findsOneWidget,
          );
        } else {
          expect(state.personalRecipes, isEmpty);
          expect(find.text(recipe.title), findsNothing);
          expect(find.text('${s('sourceAuthor')}: Grandmother'), findsNothing);
          expect(find.text(S(state.lang)('recipeUnavailable')), findsOneWidget);
          expect(
            find.byKey(const ValueKey('share-detail-recipe')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('edit-personal-recipe')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('set-recipe-image')), findsNothing);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(OnboardingScreen), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }

    for (final remove in [false, true]) {
      testWidgets(
        '$lang personal restore follows current recipe removal=$remove',
        (tester) async {
          final original = _recipe();
          final state = (await tester.runAsync(() async {
            final state = AppState(
              store: MemoryStore(),
              corpus: await loadRealCorpus(),
            );
            await state.load();
            await state.completeOnboarding(Profile(lang: lang));
            await state.savePersonalRecipe(original);
            return state;
          }))!;
          addTearDown(state.dispose);
          await tester.pumpWidget(
            app(state, DishDetailScreen(dishId: original.dishId)),
          );
          await tester.pumpAndSettle();
          expect(find.text(original.title), findsWidgets);
          final replacement = original.copyWith(
            title: 'Replacement recipe',
            sourceAuthor: 'Replacement author',
            ingredients: [
              PersonalRecipeIngredient(name: 'potatoes', qty: 200, unit: 'g'),
            ],
          );
          await state.applyBackup(
            BackupData(
              profile: Profile(lang: lang),
              saved: const [],
              history: const [],
              mealPlan: const {},
              personalRecipes: remove ? [] : [replacement],
            ),
            merge: false,
          );
          await tester.pumpAndSettle();
          expect(find.text(original.title), findsNothing);
          if (remove) {
            expect(find.text(S(lang)('recipeUnavailable')), findsOneWidget);
            expect(find.text(S(lang)('bundledRecipeOrigin')), findsNothing);
            expect(
              find.text('${S(lang)('sourceAuthor')}: Grandmother'),
              findsNothing,
            );
            expect(
              find.byKey(const ValueKey('share-detail-recipe')),
              findsNothing,
            );
            await tester.pumpWidget(const SizedBox());
            return;
          }
          expect(find.text(replacement.title), findsWidgets);
          expect(
            find.text('${S(lang)('sourceAuthor')}: Replacement author'),
            findsOneWidget,
          );
          expect(find.text(S(lang)('bundledRecipeOrigin')), findsNothing);
          await tester.scrollUntilVisible(
            find.text('potatoes'),
            250,
            scrollable: find
                .descendant(
                  of: find.byType(DishDetailScreen),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text('potatoes'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

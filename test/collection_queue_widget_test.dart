import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/ui/screens/search_screen.dart';
import 'package:morphcook/ui/screens/shopping_list_screen.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/widgets/recipe_row.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

class _PausedProfileStore extends MemoryStore {
  bool armed = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (armed) {
      armed = false;
      entered.complete();
      await release.future;
    }
    await super.saveProfile(profile);
  }
}

void main() {
  for (final lang in ['en', 'de']) {
    testWidgets('later $lang search survives queued content request', (
      tester,
    ) async {
      final store = _PausedProfileStore();
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        return state;
      }))!;
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state, const Scaffold(body: SearchScreen())));
      await tester.pumpAndSettle();
      store.armed = true;
      final first = state.updateProfile(state.profile);
      addTearDown(() {
        if (!store.release.isCompleted) store.release.complete();
      });
      await store.entered.future;
      await tester.enterText(find.byType(TextField), 'zzzzmissingdish');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(state.contentRequests, isEmpty);
      await tester.enterText(find.byType(TextField), 'lasag');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byType(RecipeRow), findsWidgets);
      store.release.complete();
      await tester.pumpAndSettle();
      await first;
      expect(state.contentRequests, ['zzzzmissingdish']);
      expect(find.byType(RecipeRow), findsWidgets);
      expect(
        tester
            .widgetList<RecipeRow>(find.byType(RecipeRow))
            .every((row) => row.recipe.dishId == 'lasagna'),
        isTrue,
      );
      expect(find.text('${S(lang)('searchEmpty')} "lasag"'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$lang shopping tap follows displayed row behind clear', (
      tester,
    ) async {
      final store = _PausedProfileStore();
      final state = (await tester.runAsync(() async {
        final state = AppState(store: store, corpus: await loadRealCorpus());
        await state.load();
        await state.completeOnboarding(Profile(lang: lang));
        await state.addToShoppingList([
          (makeRecipe(ingredientIds: ['garlic', 'onion', 'tomato']), 1.0),
        ]);
        await state.toggleShoppingItem(state.shoppingList[0]);
        return state;
      }))!;
      addTearDown(state.dispose);
      await tester.pumpWidget(app(state, const ShoppingListScreen()));
      await tester.pumpAndSettle();
      store.armed = true;
      final first = state.updateProfile(state.profile);
      addTearDown(() {
        if (!store.release.isCompleted) store.release.complete();
      });
      await store.entered.future;
      await tester.tap(find.byTooltip(S(lang)('clearChecked')));
      final onionName = state.corpus.dictionary.byId('onion')!.name.of(lang);
      await tester.tap(find.text(onionName));
      await tester.pump();
      expect(state.shoppingList, hasLength(3));
      store.release.complete();
      await tester.pumpAndSettle();
      await first;
      expect(
        state.shoppingList
            .where((row) => row.checked)
            .map((row) => row.ingredientId),
        ['onion'],
      );
      final reloaded = AppState(store: store, corpus: state.corpus);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(
        reloaded.shoppingList
            .where((row) => row.checked)
            .map((row) => row.ingredientId),
        ['onion'],
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}

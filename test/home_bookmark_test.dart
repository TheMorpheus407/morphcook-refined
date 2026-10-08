import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/corpus.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/logic/ranking.dart';
import 'package:morphcook/main.dart';
import 'package:morphcook/models/collections.dart';
import 'package:morphcook/models/dish.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/models/recipe.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/home_screen.dart';
import 'package:morphcook/ui/widgets/decor.dart';
import 'package:morphcook/ui/widgets/recipe_cover.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app, onboardedState;

// Reverse authored input order to prove ordering is defined by tier and ID.
class ReversedCorpus extends CorpusRepository {
  ReversedCorpus() : super(bundle: FileAssetBundle());

  @override
  List<Dish> get dishes => super.dishes.reversed.toList();
}

class DelayedVariantState extends AppState {
  DelayedVariantState({required super.store, required super.corpus});

  Completer<void>? pause;
  bool _paused = false;

  @override
  Future<Recipe?> bestVariant(String dishId) async {
    final recipe = await super.bestVariant(dishId);
    if (pause != null && !_paused && recipe != null) {
      _paused = true;
      await pause!.future;
    }
    return recipe;
  }
}

class ClockedAppState extends AppState {
  ClockedAppState({
    required super.store,
    required super.corpus,
    required DateTime Function() now,
  }) : _ranker = Ranker(now: now);

  final Ranker _ranker;

  @override
  Ranker get ranker => _ranker;
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  Future<Finder> firstCard(WidgetTester tester) async {
    final homeScrollable = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(homeScrollable, const Offset(0, -700));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('home-dish-card-0'));
    expect(card, findsOneWidget);
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    return card;
  }

  testWidgets('start view card bookmark saves a recipe without opening it', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
    await tester.pumpWidget(app(state, const RootShell()));
    await tester.pumpAndSettle();
    expect(state.saved, isEmpty);

    final card = await firstCard(tester);
    final bookmark = find.descendant(
      of: card,
      matching: find.byIcon(Icons.bookmark_border),
    );
    expect(
      bookmark,
      findsOneWidget,
      reason: 'start view cards expose a save-to-cookbook bookmark',
    );
    await tester.tap(bookmark);
    await tester.pumpAndSettle();

    // Saved via the existing cookbook machinery, still on the start view.
    expect(state.saved, hasLength(1));
    expect(state.isSaved(state.saved.single.recipeId), isTrue);
    expect(find.byType(DishDetailScreen), findsNothing);
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.bookmark)),
      findsOneWidget,
      reason: 'bookmark icon flips to the filled state once saved',
    );
  });

  testWidgets('tapping a saved card bookmark unsaves the recipe', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
    await tester.pumpWidget(app(state, const RootShell()));
    await tester.pumpAndSettle();

    final card = await firstCard(tester);
    await tester.tap(
      find.descendant(of: card, matching: find.byIcon(Icons.bookmark_border)),
    );
    await tester.pumpAndSettle();
    expect(state.saved, hasLength(1));

    await tester.tap(
      find.descendant(of: card, matching: find.byIcon(Icons.bookmark)),
    );
    await tester.pumpAndSettle();
    expect(state.saved, isEmpty);
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.bookmark_border)),
      findsOneWidget,
    );
    expect(find.byType(DishDetailScreen), findsNothing);
  });

  testWidgets('card bookmark reflects recipes already in the cookbook', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
    final recipeId = (await tester.runAsync(() async {
      final recipe = await state.bestVariant('doener');
      return recipe!.id;
    }))!;
    await state.toggleSaved(recipeId);

    await tester.pumpWidget(app(state, const RootShell()));
    await tester.pumpAndSettle();
    await firstCard(tester);

    // Cards build lazily with scroll position; walk the feed until the
    // saved dish's card enters the tree.
    final filledBookmark = find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byIcon(Icons.bookmark),
    );
    final homeScrollable = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    for (var i = 0; i < 20 && filledBookmark.evaluate().isEmpty; i++) {
      await tester.drag(homeScrollable, const Offset(0, -600));
      await tester.pumpAndSettle();
    }

    expect(
      filledBookmark,
      findsWidgets,
      reason: 'a recipe saved elsewhere shows as bookmarked on its card',
    );
  });

  testWidgets('featured card bookmark saves and unsaves without opening it', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
    await tester.pumpWidget(app(state, const RootShell()));
    await tester.pumpAndSettle();
    expect(state.saved, isEmpty);

    // The featured card sits at the top of the start view; its badge is the
    // first bookmark icon in tree order and lives outside the grid's
    // PolaroidCards.
    final badge = find
        .descendant(
          of: find.byType(HomeScreen),
          matching: find.byIcon(Icons.bookmark_border),
        )
        .first;
    expect(
      badge,
      findsOneWidget,
      reason: 'featured card exposes a save-to-cookbook bookmark',
    );
    expect(
      find.ancestor(of: badge, matching: find.byType(PolaroidCard)),
      findsNothing,
      reason:
          'the featured bookmark belongs to the featured card, not a grid card',
    );

    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(state.saved, hasLength(1));
    expect(state.isSaved(state.saved.single.recipeId), isTrue);
    expect(find.byType(DishDetailScreen), findsNothing);
    expect(
      find
          .descendant(
            of: find.byType(HomeScreen),
            matching: find.byIcon(Icons.bookmark),
          )
          .first,
      findsOneWidget,
      reason: 'featured bookmark icon flips to the filled state once saved',
    );

    await tester.tap(
      find
          .descendant(
            of: find.byType(HomeScreen),
            matching: find.byIcon(Icons.bookmark),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(state.saved, isEmpty);
    expect(find.byType(DishDetailScreen), findsNothing);
  });

  testWidgets('home bookmarks persist while preserving other saved variants', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
    final other = (await state.bestVariant('doener'))!;
    await state.toggleSaved(other.id);
    await tester.pumpWidget(app(state, const RootShell()));
    await tester.pumpAndSettle();
    final card = await firstCard(tester);
    final cover = tester.widget<RecipeCover>(
      find.descendant(of: card, matching: find.byType(RecipeCover)),
    );
    expect(cover.recipeId, isNot(other.id));
    final bookmark = find.descendant(
      of: card,
      matching: find.byType(BookmarkBadge),
    );
    await tester.tap(bookmark);
    await tester.pumpAndSettle();
    final reloaded = AppState(store: state.store, corpus: state.corpus);
    await reloaded.load();
    expect(
      reloaded.saved.map((r) => r.recipeId),
      unorderedEquals([other.id, cover.recipeId]),
    );
    await tester.tap(bookmark);
    await tester.pumpAndSettle();
    await reloaded.load();
    expect(reloaded.saved.single.recipeId, other.id);
  });

  testWidgets(
    'featured recommendation still updates across meal times and cooking history',
    (tester) async {
      var now = DateTime(2026, 10, 5, 10);
      final state = (await tester.runAsync(() async {
        final state = ClockedAppState(
          store: MemoryStore(),
          corpus: await loadRealCorpus(),
          now: () => now,
        );
        await state.load();
        await state.completeOnboarding(const Profile());
        return state;
      }))!;
      await tester.pumpWidget(app(state, const RootShell()));
      await tester.pumpAndSettle();
      String featuredId() => tester
          .widget<RecipeCover>(
            find
                .descendant(
                  of: find.byType(HomeScreen),
                  matching: find.byType(RecipeCover),
                )
                .first,
          )
          .recipeId;
      Future<void> openAndReturn() async {
        final dish = state.corpus.dishById(
          state.loadedRecipeById(featuredId())!.dishId,
        )!;
        await tester.tap(
          find
              .descendant(
                of: find.byType(HomeScreen),
                matching: find.text(dish.name.of('en')),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.byType(DishDetailScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      final morning = featuredId();
      now = DateTime(2026, 10, 5, 18);
      await openAndReturn();
      final evening = featuredId();
      expect(
        evening,
        isNot(morning),
        reason: 'the featured dish remains time-aware',
      );
      // An equally ranked alternative with old cooking history earns the
      // existing staleness bonus. Loading it simulates restored local history.
      final featured = state.loadedRecipeById(evening)!;
      final alternative = state.corpus.loadedRecipes.firstWhere(
        (r) =>
            r.dishId != featured.dishId &&
            state.matcher.isVisible(r, state.profile) &&
            state.ranker.totalScore(r, state.profile, []) ==
                state.ranker.totalScore(featured, state.profile, []),
      );
      await state.store.putCollection(
        'history',
        jsonEncode([
          HistoryEntry(
            recipeId: alternative.id,
            cookedAt: now.subtract(const Duration(days: 40)),
          ).toJson(),
        ]),
      );
      await state.load();
      await tester.pumpAndSettle();
      await openAndReturn();
      expect(
        featuredId(),
        alternative.id,
        reason: 'history still influences the featured recommendation',
      );
    },
  );

  for (final featured in [false, true]) {
    testWidgets(
      'profile changes refresh ${featured ? 'featured' : 'grid'} bookmarks',
      (tester) async {
        final state = (await tester.runAsync(onboardedState))!;
        await tester.pumpWidget(app(state, const RootShell()));
        await tester.pumpAndSettle();
        if (!featured) await firstCard(tester);

        // Settings updates the same AppState while Home remains mounted.
        await tester.tap(find.byIcon(Icons.tune));
        await tester.pumpAndSettle();
        await state.updateProfile(
          state.profile.copyWith(requiredAttributes: {'vegan'}),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.auto_stories_outlined));
        await tester.pumpAndSettle();
        final target = featured
            ? find.byType(HomeScreen)
            : await firstCard(tester);
        final cover = tester.widget<RecipeCover>(
          find.descendant(of: target, matching: find.byType(RecipeCover)).first,
        );
        final recipe = await state.recipeById(cover.recipeId);
        expect(recipe, isNotNull);
        expect(
          state.matcher.isVisible(recipe!, state.profile),
          isTrue,
          reason:
              'home must display and save a variant allowed by the new profile',
        );
        final expected = await state.bestVariant(recipe.dishId);
        expect(cover.recipeId, expected!.id);
        final bookmark = find
            .descendant(of: target, matching: find.byType(BookmarkBadge))
            .first;
        await tester.tap(bookmark);
        await tester.pumpAndSettle();
        expect(state.saved.single.recipeId, expected.id);
        expect(find.byType(DishDetailScreen), findsNothing);
      },
    );
  }

  testWidgets('profile with no matching variants removes both bookmark paths', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
    await tester.pumpWidget(app(state, const RootShell()));
    await tester.pumpAndSettle();
    expect(find.byType(BookmarkBadge), findsWidgets);
    await state.updateProfile(state.profile.copyWith(maxTimeMinutes: 0));
    await tester.pumpAndSettle();
    expect(find.byType(BookmarkBadge), findsNothing);
    expect(find.byType(RecipeCover), findsNothing);
  });

  testWidgets('an older in-flight load cannot overwrite a new profile', (
    tester,
  ) async {
    final state = (await tester.runAsync(() async {
      final state = DelayedVariantState(
        store: MemoryStore(),
        corpus: await loadRealCorpus(),
      );
      await state.load();
      await state.completeOnboarding(const Profile());
      return state;
    }))!;
    state.pause = Completer<void>();
    await tester.pumpWidget(app(state, const Scaffold(body: HomeScreen())));
    await tester.pumpAndSettle();
    expect(state._paused, isTrue);
    await state.updateProfile(state.profile.copyWith(maxTimeMinutes: 0));
    await tester.pumpAndSettle();
    state.pause!.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonBlock), findsNothing);
    expect(find.byType(BookmarkBadge), findsNothing);
  });

  for (final lang in ['en', 'de']) {
    testWidgets(
      'bookmarks have separate localized actions and saved state ($lang)',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final state = (await tester.runAsync(onboardedState))!;
          await state.updateProfile(state.profile.copyWith(lang: lang));
          await tester.pumpWidget(app(state, const RootShell()));
          await tester.pumpAndSettle();
          final saveLabel = lang == 'en'
              ? 'save to cookbook: '
              : 'im Kochbuch speichern: ';
          final removeLabel = lang == 'en'
              ? 'remove from cookbook: '
              : 'aus dem Kochbuch entfernen: ';
          final save = find.bySemanticsLabel(RegExp('^$saveLabel')).first;
          expect(save, findsOneWidget);
          final node = tester.getSemantics(save);
          expect(node.flagsCollection.isButton, isTrue);
          expect(node.flagsCollection.isSelected == Tristate.isTrue, isFalse);
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          node.owner!.performAction(node.id, SemanticsAction.tap);
          await tester.pumpAndSettle();
          expect(state.saved, hasLength(1));
          expect(find.byType(DishDetailScreen), findsNothing);
          final remove = find.bySemanticsLabel(RegExp('^$removeLabel')).first;
          expect(
            tester.getSemantics(remove).flagsCollection.isSelected ==
                Tristate.isTrue,
            isTrue,
          );
          final removeNode = tester.getSemantics(remove);
          removeNode.owner!.performAction(removeNode.id, SemanticsAction.tap);
          await tester.pumpAndSettle();
          expect(state.saved, isEmpty);
          expect(find.byType(DishDetailScreen), findsNothing);
          // Grid controls expose the same independent action.
          final card = await firstCard(tester);
          expect(
            find.descendant(
              of: card,
              matching: find.bySemanticsLabel(RegExp('^$saveLabel')),
            ),
            findsOneWidget,
          );
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'equal-tier category cards sort by ID even with reversed corpus input',
    (tester) async {
      final state = (await tester.runAsync(() async {
        final corpus = ReversedCorpus();
        await corpus.initialize();
        await corpus.ensureAllLoaded();
        final state = AppState(store: MemoryStore(), corpus: corpus);
        await state.load();
        await state.completeOnboarding(const Profile());
        return state;
      }))!;
      await tester.pumpWidget(app(state, const RootShell()));
      await tester.pumpAndSettle();
      final category = state.corpus.categories.first;
      await tester.tap(find.widgetWithText(MonoChip, category.name.of('en')));
      await tester.pumpAndSettle();
      final eligible = <Dish>[];
      for (final dish in state.corpus.dishes.where(
        (d) => d.category == category.id,
      )) {
        if (await state.bestVariant(dish.id) != null) eligible.add(dish);
      }
      expect(eligible.length, greaterThan(1));
      eligible.sort((a, b) {
        final tier = a.frequencyTier.compareTo(b.frequencyTier);
        return tier != 0 ? tier : a.id.compareTo(b.id);
      });
      final titles = tester
          .widgetList<PolaroidCard>(find.byType(PolaroidCard))
          .map((c) => c.title)
          .toList();
      expect(titles.length, greaterThan(1));
      expect(
        titles,
        orderedEquals(eligible.take(titles.length).map((d) => d.name.of('en'))),
      );
    },
  );

  testWidgets(
    'feed order is identical after detail return with unchanged ranking inputs',
    (tester) async {
      final state = (await tester.runAsync(() async {
        final state = ClockedAppState(
          store: MemoryStore(),
          corpus: await loadRealCorpus(),
          now: () => DateTime(2026, 10, 5, 10),
        );
        await state.load();
        await state.completeOnboarding(const Profile());
        return state;
      }))!;
      await tester.pumpWidget(app(state, const RootShell()));
      await tester.pumpAndSettle();

      final card = await firstCard(tester);
      List<String> cardTitles() => tester
          .widgetList<PolaroidCard>(find.byType(PolaroidCard))
          .map((c) => c.title)
          .toList();
      final before = cardTitles();
      expect(before, isNotEmpty);

      await tester.tap(
        find.descendant(
          of: card,
          matching: find.text(tester.widget<PolaroidCard>(card).title),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DishDetailScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      expect(
        cardTitles(),
        orderedEquals(before),
        reason:
            'returning from a recipe must not scramble the other start view cards',
      );
    },
  );
}

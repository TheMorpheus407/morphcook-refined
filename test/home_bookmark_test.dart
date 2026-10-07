import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/main.dart';
import 'package:morphcook/ui/screens/dish_detail_screen.dart';
import 'package:morphcook/ui/screens/home_screen.dart';
import 'package:morphcook/ui/widgets/decor.dart';

import 'widget_smoke_test.dart' show app, onboardedState;

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

  testWidgets('feed order is identical after returning from the detail view', (
    tester,
  ) async {
    final state = (await tester.runAsync(onboardedState))!;
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
      find.descendant(of: card, matching: find.byType(GestureDetector)),
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
  });
}

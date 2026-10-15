import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/app_state.dart';
import '../../models/collections.dart';
import '../../models/recipe.dart';
import '../collection_edit.dart';
import '../strings.dart';
import '../theme.dart';
import '../widgets/recipe_row.dart';
import 'search_screen.dart';
import 'shopping_list_screen.dart';

/// The assignment visible when a meal drag starts.
typedef MealPlanDrag = ({String weekKey, String slotKey, String recipeId});

typedef _MealSlotSelection = ({String weekKey, String? recipeId});

/// Weekly meal plan: Mon–Sun × breakfast/lunch/dinner. Tap a slot to assign
/// from cookbook/search, long-press-drag between slots, one-tap export of
/// the week to the shopping list. Weekly pagination, ±4 weeks window.
class MealPlanScreen extends StatefulWidget {
  const MealPlanScreen({super.key, this.now});

  final DateTime Function()? now;

  @override
  State<MealPlanScreen> createState() => _MealPlanScreenState();
}

class _MealPlanScreenState extends State<MealPlanScreen> {
  /// Offset from the week first displayed (clamped to ±4 — the spec's
  /// "max 4 weeks rendered" guardrail, one week rendered at a time).
  int _weekOffset = 0;
  late final DateTime _initialWeek = weekStart(
    widget.now?.call() ?? DateTime.now(),
  );

  DateTime get _weekDate {
    // Calendar days retain Monday midnight across daylight-saving changes.
    // Rebuilds and gestures keep the displayed week across midnight.
    return DateTime(
      _initialWeek.year,
      _initialWeek.month,
      _initialWeek.day + 7 * _weekOffset,
    );
  }

  @override
  Widget build(BuildContext context) {
    final morph = MorphTheme.of(context);
    final state = context.watch<AppState>();
    final s = S(state.lang);
    final weekDate = _weekDate;
    final weekKey = isoWeekKey(weekDate);
    final week = state.mealPlan[weekKey] ?? const <String, String>{};

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                Text(
                  s('mealPlan'),
                  style: morph.text.display.copyWith(fontSize: 30),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                    Icons.shopping_basket_outlined,
                    size: 20,
                    color: morph.colors.inkSoft,
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ShoppingListScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                IconButton(
                  onPressed: _weekOffset > -4
                      ? () => setState(() => _weekOffset--)
                      : null,
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      morph.cased('${s('week')} $weekKey'),
                      style: morph.text.label(),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _weekOffset < 4
                      ? () => setState(() => _weekOffset++)
                      : null,
                  icon: const Icon(Icons.chevron_right, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              children: [
                for (var d = 0; d < 7; d++)
                  _dayRow(d, weekDate, weekKey, week, state, s),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: week.isEmpty
                    ? null
                    : () => _exportWeek(weekKey, state, s),
                icon: Icon(
                  Icons.playlist_add,
                  size: 16,
                  color: morph.colors.teal,
                ),
                label: Text(
                  s('exportWeekToList'),
                  style: morph.text.label(color: morph.colors.teal),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: morph.colors.teal),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(2),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayRow(
    int dayIndex,
    DateTime weekDate,
    String weekKey,
    Map<String, String> week,
    AppState state,
    S s,
  ) {
    final morph = MorphTheme.of(context);
    final date = DateTime(
      weekDate.year,
      weekDate.month,
      weekDate.day + dayIndex,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(
            morph.cased('${s(weekDays[dayIndex])} ${date.day}.${date.month}.'),
            style: morph.text.label(),
          ),
        ),
        Row(
          children: [
            for (final slot in mealSlots) ...[
              Expanded(
                child: _slotCell(dayIndex, slot, weekKey, week, state, s),
              ),
              if (slot != mealSlots.last) const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }

  Widget _slotCell(
    int dayIndex,
    String slot,
    String weekKey,
    Map<String, String> week,
    AppState state,
    S s,
  ) {
    final morph = MorphTheme.of(context);
    final slotKey = '${weekDays[dayIndex]}.$slot';
    final recipeId = week[slotKey];
    final recipe = recipeId == null ? null : state.loadedRecipeById(recipeId);

    final cell = DragTarget<MealPlanDrag>(
      onAcceptWithDetails: (details) {
        final source = details.data;
        if (source.weekKey != weekKey) return;
        saveCollectionEdit(
          context,
          () => state.moveMeal(
            source.weekKey,
            source.slotKey,
            slotKey,
            expectedRecipeId: source.recipeId,
          ),
        );
      },
      builder: (context, candidates, _) {
        final highlighted = candidates.isNotEmpty;
        // Accessibility taps have no pointer-down and use the visible context.
        return Semantics(
          onTap: () => _assignSlot(weekKey, slotKey, recipeId, state, s),
          child: RawGestureDetector(
            excludeFromSemantics: true,
            gestures: {
              _MealSlotTapRecognizer:
                  GestureRecognizerFactoryWithHandlers<_MealSlotTapRecognizer>(
                    _MealSlotTapRecognizer.new,
                    (recognizer) {
                      recognizer.gestureSettings =
                          MediaQuery.maybeGestureSettingsOf(context);
                      recognizer.selection = () =>
                          (weekKey: weekKey, recipeId: recipeId);
                      recognizer.onTap = () {
                        final selected = recognizer.selected!;
                        _assignSlot(
                          selected.weekKey,
                          slotKey,
                          selected.recipeId,
                          state,
                          s,
                        );
                      };
                    },
                  ),
            },
            child: Container(
              height: 64,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: recipe == null ? Colors.transparent : morph.colors.card,
                border: Border.all(
                  color: highlighted
                      ? morph.colors.terracotta
                      : morph.colors.line,
                  width: highlighted ? 1.6 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s(slot), style: morph.text.label(size: 8)),
                  const Spacer(),
                  Text(
                    recipe == null
                        ? s('planEmptySlot')
                        : morph.cased(recipe.title.of(state.lang)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: recipe == null
                        ? morph.text.handAt(14, color: morph.colors.inkFaint)
                        : morph.text.mono.copyWith(fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (recipeId == null) return cell;
    // Capture before the delayed long-press recognizer starts the drag.
    return _MealDragSource(
      data: (weekKey: weekKey, slotKey: slotKey, recipeId: recipeId),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(8),
          color: morph.colors.ink,
          child: Text(
            morph.cased(recipe?.title.of(state.lang) ?? ''),
            style: morph.text.mono.copyWith(
              fontSize: 11,
              color: morph.colors.paper,
            ),
          ),
        ),
      ),
      child: cell,
    );
  }

  Future<void> _assignSlot(
    String weekKey,
    String slotKey,
    String? existing,
    AppState state,
    S s,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MorphTheme.of(context).colors.paper,
      builder: (context) {
        final morph = MorphTheme.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Text(s('pickRecipe'), style: morph.text.label()),
              ListTile(
                leading: Icon(
                  Icons.bookmark_border,
                  color: morph.colors.terracotta,
                ),
                title: Text(
                  s('fromCookbook'),
                  style: morph.text.mono.copyWith(fontSize: 13),
                ),
                onTap: () => Navigator.pop(context, 'cookbook'),
              ),
              ListTile(
                leading: Icon(Icons.search, color: morph.colors.teal),
                title: Text(
                  s('fromSearch'),
                  style: morph.text.mono.copyWith(fontSize: 13),
                ),
                onTap: () => Navigator.pop(context, 'search'),
              ),
              if (existing != null)
                ListTile(
                  leading: Icon(
                    Icons.delete_outline,
                    color: morph.colors.coral,
                  ),
                  title: Text(
                    s('removeFromSlot'),
                    style: morph.text.mono.copyWith(fontSize: 13),
                  ),
                  onTap: () => Navigator.pop(context, 'remove'),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;

    if (action == 'remove') {
      await saveCollectionEdit(
        context,
        () => state.clearMeal(weekKey, slotKey, expectedRecipeId: existing),
      );
      return;
    }

    Recipe? picked;
    if (action == 'cookbook') {
      picked = await _pickFromCookbook(state, s);
    } else {
      picked = await Navigator.of(context).push<Recipe>(
        MaterialPageRoute(
          builder: (context) => Scaffold(
            appBar: AppBar(
              title: Text(
                s('pickRecipe'),
                style: MorphTheme.of(
                  context,
                ).text.display.copyWith(fontSize: 20),
              ),
            ),
            body: const PaperBackground(child: SearchScreen(pickerMode: true)),
          ),
        ),
      );
    }
    if (picked != null) {
      if (!mounted) return;
      final recipe = picked;
      await saveCollectionEdit(
        context,
        () => state.assignMeal(weekKey, slotKey, recipe.id),
      );
    }
  }

  Future<Recipe?> _pickFromCookbook(AppState state, S s) async {
    final recipes = <Recipe>[];
    for (final saved in state.saved.reversed) {
      final r = await state.recipeById(saved.recipeId);
      if (r != null) recipes.add(r);
    }
    if (!mounted) return null;
    return showModalBottomSheet<Recipe>(
      context: context,
      backgroundColor: MorphTheme.of(context).colors.paper,
      isScrollControlled: true,
      builder: (context) {
        final morph = MorphTheme.of(context);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, controller) => recipes.isEmpty
              ? Center(
                  child: Text(
                    s('cookbookEmpty'),
                    textAlign: TextAlign.center,
                    style: morph.text.handAt(19, color: morph.colors.inkSoft),
                  ),
                )
              : ListView.builder(
                  controller: controller,
                  padding: const EdgeInsets.all(20),
                  itemCount: recipes.length,
                  itemBuilder: (context, i) => RecipeRow(
                    recipe: recipes[i],
                    index: i,
                    onTap: () => Navigator.pop(context, recipes[i]),
                  ),
                ),
        );
      },
    );
  }

  Future<void> _exportWeek(String weekKey, AppState state, S s) async {
    final week = state.mealPlan[weekKey] ?? const <String, String>{};
    final recipes = <(Recipe, double)>[];
    for (final recipeId in week.values) {
      final recipe = await state.recipeById(recipeId);
      if (recipe != null) recipes.add((recipe, 1.0));
    }
    if (recipes.isEmpty) return;
    if (!mounted) return;
    if (!await saveCollectionEdit(
      context,
      () => state.addToShoppingList(recipes),
    )) {
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(s('weekExported'))));
  }
}

/// Preserve pointer-down data through provider rebuilds without remounting the
/// cell's independent tap recognizer. The drag avatar retains its own snapshot
/// after release, while the next pointer starts with the current assignment.
class _MealDragSource extends StatefulWidget {
  const _MealDragSource({
    required this.data,
    required this.feedback,
    required this.child,
  });

  final MealPlanDrag data;
  final Widget feedback;
  final Widget child;

  @override
  State<_MealDragSource> createState() => _MealDragSourceState();
}

class _MealDragSourceState extends State<_MealDragSource> {
  int? _pointer;
  MealPlanDrag? _data;
  Widget? _feedback;

  void _release(PointerEvent event) {
    // Pointer-up can still target the old hit-test path after a restore removes
    // this source from the tree.
    if (!mounted || event.pointer != _pointer) return;
    setState(() {
      _pointer = null;
      _data = null;
      _feedback = null;
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (!mounted || _pointer != null) return;
      setState(() {
        _pointer = event.pointer;
        _data = widget.data;
        _feedback = widget.feedback;
      });
    },
    onPointerUp: _release,
    onPointerCancel: _release,
    child: LongPressDraggable<MealPlanDrag>(
      data: _data ?? widget.data,
      feedback: _feedback ?? widget.feedback,
      childWhenDragging: Opacity(opacity: 0.35, child: widget.child),
      child: widget.child,
    ),
  );
}

/// Capture context with the recognizer that owns the tap, before any rebuild.
/// A new gesture replaces the snapshot; disposal drops it with the recognizer.
class _MealSlotTapRecognizer extends TapGestureRecognizer {
  late _MealSlotSelection Function() selection;
  _MealSlotSelection? selected;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (state == GestureRecognizerState.ready) selected = selection();
    super.addAllowedPointer(event);
  }
}

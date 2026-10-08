import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/app_state.dart';
import '../../logic/import/recipe_photo_search.dart';
import '../../models/recipe_image.dart';
import '../strings.dart';
import '../theme.dart';

/// Message key for a photo that could not be stored.
String recipeImageFailureKey(RecipeImageFailure failure) => switch (failure) {
  RecipeImageFailure.tooLarge => 'recipeImageTooLarge',
  RecipeImageFailure.dimensionsTooLarge => 'recipeImageDimensionsTooLarge',
  RecipeImageFailure.unsupportedType => 'recipeImageUnsupported',
  RecipeImageFailure.storageLimit => 'recipeImageStorageFull',
  RecipeImageFailure.invalidRecipeId => 'recipeImageReadError',
};

/// Opt-in online photo search for one recipe. Opening this screen is the
/// owner's explicit request; it searches once with [initialQuery] and lets the
/// owner refine the words, compare previews, and keep one credited photo.
/// Pops with `true` after a photo was saved.
class RecipePhotoSearchScreen extends StatefulWidget {
  final String recipeId;
  final String initialQuery;
  final RecipePhotoSearch? photoSearch;

  const RecipePhotoSearchScreen({
    super.key,
    required this.recipeId,
    required this.initialQuery,
    this.photoSearch,
  });

  @override
  State<RecipePhotoSearchScreen> createState() =>
      _RecipePhotoSearchScreenState();
}

class _RecipePhotoSearchScreenState extends State<RecipePhotoSearchScreen> {
  late final _search = widget.photoSearch ?? RecipePhotoSearch();
  late final _query = TextEditingController(
    text: normalizeRecipePhotoQuery(widget.initialQuery),
  );
  List<RecipePhotoCandidate> _results = [];
  final _previews = <RecipePhotoCandidate, Future<Uint8List?>>{};
  final _loaded = <RecipePhotoCandidate, Uint8List>{};
  RecipePhotoCandidate? _selected;
  bool _searching = false;
  bool _searched = false;

  /// Message key explaining why the last search failed.
  String? _failure;
  bool _saving = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (_query.text.isNotEmpty) _run();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final words = normalizeRecipePhotoQuery(_query.text);
    if (words.isEmpty || _saving) return;
    final generation = ++_generation;
    final lang = context.read<AppState>().lang;
    setState(() {
      _searching = true;
      _failure = null;
      _results = [];
      _previews.clear();
      _loaded.clear();
      _selected = null;
    });
    List<RecipePhotoCandidate> results;
    try {
      results = await _search.search(words, lang: lang);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _searching = false;
          _searched = true;
          _failure =
              error is RecipePhotoSearchException &&
                  error.failure == RecipePhotoSearchFailure.busy
              ? 'photoSearchBusy'
              : 'photoSearchFailed';
        });
      }
      return;
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _searching = false;
      _searched = true;
      _results = results;
    });
  }

  /// Previews load lazily as tiles become visible; failures stay per tile.
  Future<Uint8List?> _preview(RecipePhotoCandidate candidate) =>
      _previews.putIfAbsent(candidate, () async {
        final generation = _generation;
        try {
          final bytes = await _search.download(candidate);
          if (!mounted || generation != _generation) return null;
          return bytes;
        } catch (_) {
          return null;
        }
      });

  Future<void> _use(S s) async {
    final candidate = _selected;
    final bytes = candidate == null ? null : _loaded[candidate];
    if (candidate == null || bytes == null || _saving) return;
    setState(() => _saving = true);
    try {
      await context.read<AppState>().setRecipeImage(
        widget.recipeId,
        bytes,
        credit: candidate.credit,
      );
    } on RecipeImageException catch (error) {
      _failSave(s(recipeImageFailureKey(error.failure)));
      return;
    } catch (_) {
      _failSave(s('recipeImageReadError'));
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  void _failSave(String message) {
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final morph = MorphTheme.of(context);
    final lang = context.watch<AppState>().lang;
    final s = S(lang);
    final selected = _selected;
    final ready = selected != null && _loaded.containsKey(selected);

    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final footer = Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                selected.credit.label(lang),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: morph.text.mono.copyWith(fontSize: 11),
              ),
            ),
          FilledButton.icon(
            key: const ValueKey('use-found-photo'),
            onPressed: ready && !_saving ? () => _use(s) : null,
            icon: const Icon(Icons.check),
            label: Text(
              selected == null ? s('choosePhotoFirst') : s('useThisPhoto'),
            ),
          ),
        ],
      ),
    );
    final content = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  s('photoSearchHint'),
                  style: morph.text.mono.copyWith(
                    fontSize: 12,
                    color: morph.colors.inkSoft,
                  ),
                ),
                TextField(
                  key: const ValueKey('photo-search-query'),
                  controller: _query,
                  enabled: !_saving,
                  textInputAction: TextInputAction.search,
                  maxLength: maxRecipePhotoQueryLength,
                  onSubmitted: (_) => _run(),
                  decoration: InputDecoration(
                    labelText: s('photoSearchQuery'),
                    counterText: '',
                    suffixIcon: IconButton(
                      key: const ValueKey('run-photo-search'),
                      tooltip: s('photoSearchButton'),
                      icon: const Icon(Icons.search),
                      onPressed: _saving ? null : _run,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_searching)
          const SliverToBoxAdapter(child: LinearProgressIndicator()),
        if (_failure != null || (_searched && !_searching && _results.isEmpty))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Text(
                s(_failure ?? 'photoSearchEmpty'),
                key: const ValueKey('photo-search-message'),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemCount: _results.length,
            itemBuilder: (context, index) =>
                _tile(_results[index], index, lang, s),
          ),
        ),
        if (keyboardVisible) SliverToBoxAdapter(child: footer),
      ],
    );
    return Scaffold(
      appBar: AppBar(title: Text(s('photoSearchTitle'))),
      body: SafeArea(
        child: keyboardVisible
            ? content
            : Column(
                children: [
                  Expanded(child: content),
                  footer,
                ],
              ),
      ),
    );
  }

  Widget _tile(RecipePhotoCandidate candidate, int index, String lang, S s) {
    final morph = MorphTheme.of(context);
    final selected = identical(_selected, candidate);
    final credit = candidate.credit;
    return Semantics(
      button: true,
      selected: selected,
      label: credit.label(lang),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('found-photo-$index'),
        // Only a photo whose preview loaded can be chosen and saved.
        onTap: _saving || !_loaded.containsKey(candidate)
            ? null
            : () => setState(() => _selected = candidate),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: morph.colors.card,
            border: Border.all(
              color: selected ? morph.colors.terracotta : morph.colors.line,
              width: selected ? 3 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: FutureBuilder<Uint8List?>(
                  future: _preview(candidate),
                  builder: (context, snapshot) {
                    final bytes = snapshot.data;
                    if (bytes != null) {
                      final generation = _generation;
                      return Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 480,
                        gaplessPlayback: true,
                        // A completed download may still fail platform decoding.
                        // Enable selection only after a frame is displayed.
                        frameBuilder: (_, child, frame, _) {
                          if (frame != null &&
                              !_loaded.containsKey(candidate)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && generation == _generation) {
                                setState(() => _loaded[candidate] = bytes);
                              }
                            });
                          }
                          return child;
                        },
                        errorBuilder: (_, __, ___) {
                          if (_loaded.containsKey(candidate)) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && generation == _generation) {
                                setState(() {
                                  _loaded.remove(candidate);
                                  if (identical(_selected, candidate)) {
                                    _selected = null;
                                  }
                                });
                              }
                            });
                          }
                          return _unavailable(s);
                        },
                      );
                    }
                    if (snapshot.connectionState == ConnectionState.done) {
                      return _unavailable(s);
                    }
                    return const Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  [
                    if (credit.author != null) credit.author!,
                    credit.license,
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: morph.text.mono.copyWith(
                    fontSize: 10,
                    color: morph.colors.inkSoft,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unavailable(S s) {
    final morph = MorphTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          s('photoPreviewFailed'),
          textAlign: TextAlign.center,
          style: morph.text.mono.copyWith(
            fontSize: 11,
            color: morph.colors.inkSoft,
          ),
        ),
      ),
    );
  }
}

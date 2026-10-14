import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/recipe_image.dart';

import 'helpers.dart';

class PausedPhotoStore extends MemoryStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool failFirst = false;

  @override
  Future<void> putRecipeImageBytes(String id, Uint8List bytes) async {
    await super.putRecipeImageBytes(id, bytes);
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
      if (failFirst) throw StateError('photo write failed');
    }
  }
}

RecipeImageCredit credit(String author) => RecipeImageCredit.tryCreate(
  title: '$author photo',
  author: author,
  license: 'CC BY 4.0',
  provider: 'Wikimedia Commons',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:$author.png',
)!;

void main() {
  for (final fails in [false, true]) {
    test(
      'overlapping photo writes preserve later save: fails=$fails',
      () async {
        final store = PausedPhotoStore()..failFirst = fails;
        final corpus = await loadRealCorpus();
        final state = AppState(store: store, corpus: corpus);
        await state.load();
        final first = state.setRecipeImage(
          'doener-vegan',
          testPngBytes(),
          credit: credit('Ann'),
        );
        final firstResult = fails
            ? expectLater(first, throwsStateError)
            : first;
        await store.entered.future;
        final second = state.setRecipeImage(
          'doener-classic',
          testPngBytes(),
          credit: credit('Bob'),
        );
        // Let the second call reach its asynchronous writes on the old code.
        await Future<void>.delayed(Duration.zero);
        store.release.complete();
        await firstResult;
        await second;

        final recovered = AppState(store: store, corpus: corpus);
        await recovered.load();
        for (final snapshot in [state, recovered]) {
          expect(
            snapshot.recipeImageFor('doener-vegan')?.credit,
            fails ? isNull : credit('Ann'),
          );
          expect(
            snapshot.recipeImageFor('doener-classic')?.credit,
            credit('Bob'),
          );
          expect(
            snapshot.buildBackup().recipeImages.map((image) => image.recipeId),
            unorderedEquals([if (!fails) 'doener-vegan', 'doener-classic']),
          );
        }
        expect(
          store.loadRecipeImageBytes().keys,
          unorderedEquals([if (!fails) 'doener-vegan', 'doener-classic']),
        );
      },
    );
  }

  test('removal requested during a save removes its completed photo', () async {
    final store = PausedPhotoStore();
    final corpus = await loadRealCorpus();
    final state = AppState(store: store, corpus: corpus);
    await state.load();
    final saving = state.setRecipeImage('doener-vegan', testPngBytes());
    await store.entered.future;
    final removing = state.removeRecipeImage('doener-vegan');
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await saving;
    await removing;
    final recovered = AppState(store: store, corpus: corpus);
    await recovered.load();
    expect(state.recipeImages, isEmpty);
    expect(recovered.recipeImages, isEmpty);
    expect(store.loadRecipeImageBytes(), isEmpty);
  });
}

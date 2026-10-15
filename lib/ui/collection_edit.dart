import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../models/recipe.dart';
import 'strings.dart';

/// Keep a failed edit retryable and report it without success feedback.
Future<bool> saveCollectionEdit(
  BuildContext context,
  Future<void> Function() edit,
) async {
  try {
    await edit();
    return true;
  } catch (error) {
    if (context.mounted) {
      final s = S(context.read<AppState>().lang);
      final message = error is RecipeUnavailableException
          ? 'recipeUnavailable'
          : 'collectionSaveFailed';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s(message))));
    }
    return false;
  }
}

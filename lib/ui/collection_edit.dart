import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import 'strings.dart';

/// Keep a failed edit retryable and report it without success feedback.
Future<bool> saveCollectionEdit(
  BuildContext context,
  Future<void> Function() edit,
) async {
  try {
    await edit();
    return true;
  } catch (_) {
    if (context.mounted) {
      final s = S(context.read<AppState>().lang);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(s('collectionSaveFailed'))));
    }
    return false;
  }
}

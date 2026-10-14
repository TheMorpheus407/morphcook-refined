import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphcook/data/app_state.dart';
import 'package:morphcook/data/store.dart';
import 'package:morphcook/models/profile.dart';
import 'package:morphcook/logic/backup/backup_service.dart';
import 'package:morphcook/logic/local_file_bytes.dart';
import 'package:morphcook/ui/strings.dart';
import 'package:morphcook/ui/screens/settings_screen.dart';
import 'package:morphcook/ui/widgets/decor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'helpers.dart';
import 'widget_smoke_test.dart' show app;

// Keep startup cleanup inside the test; no shared desktop cache is touched.
class _NoTemporaryDirectory extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => null;
}

class _PausedProfileStore extends MemoryStore {
  bool pauseNext = false;
  bool failPausedWrite = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> saveProfile(Profile profile) async {
    if (pauseNext) {
      pauseNext = false;
      entered.complete();
      await release.future;
      if (failPausedWrite) throw StateError('profile write failed');
    }
    await super.saveProfile(profile);
  }
}

void main() {
  setUpAll(() async {
    // Initialize the shared cleanup queue outside a widget's FakeAsync zone.
    await withMorphCookShareFiles(() async {});
  });
  setUp(() {
    const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
          expect(call.method, 'clear');
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(picker, null),
    );
    FilePickerMacOS.registerWith();
    addTearDown(FilePickerLinux.registerWith);
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoTemporaryDirectory();
    addTearDown(() => PathProviderPlatform.instance = previous);
  });
  for (final merge in [true, false]) {
    for (final outcome in ['success', 'failure', 'cancel', 'navigation']) {
      final fail = outcome == 'failure';
      testWidgets(
        'pending ${merge ? 'merge' : 'replacement'} restore blocks settings and unlocks on $outcome',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1000, 3000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final semantics = tester.ensureSemantics();
          try {
            final store = _PausedProfileStore();
            final lang = merge ? 'en' : 'de';
            final original = Profile(name: 'Original', lang: lang);
            final restored = Profile(
              name: 'Restored',
              lang: lang,
              avoidFlags: {'dairy'},
              requiredAttributes: {'vegan'},
            );
            final state = (await tester.runAsync(() async {
              final state = AppState(
                store: store,
                corpus: await loadRealCorpus(),
              );
              await state.load();
              await state.completeOnboarding(original);
              return state;
            }))!;
            addTearDown(() {
              if (!store.release.isCompleted) store.release.complete();
              state.dispose();
            });
            final bytes = BackupService.export(
              BackupData(
                profile: restored,
                saved: const [],
                mealPlan: const {},
                history: const [],
              ),
            ).jsonFile;
            final fixture = (await tester.runAsync(() async {
              final directory = await Directory.systemTemp.createTemp(
                'morphcook-settings-test-',
              );
              final file = File('${directory.path}/backup.json');
              await file.writeAsBytes(bytes);
              return file;
            }))!;
            addTearDown(() => fixture.parent.delete(recursive: true));
            const picker = MethodChannel(
              'miguelruivo.flutter.plugins.filepicker',
            );
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              picker,
              (call) async {
                expect(call.method, 'pickFiles');
                return [fixture.path];
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(picker, null),
            );
            await tester.runAsync(() async {
              await tester.pumpWidget(
                app(state, const Scaffold(body: SettingsScreen())),
              );
              await Future<void>.delayed(Duration.zero);
            });
            await tester.pumpAndSettle();
            Finder chip(String label) => find
                .byWidgetPredicate(
                  (w) =>
                      w is MonoChip &&
                      w.label == state.corpus.ontology.nameOf(label, lang),
                )
                .last;
            final staleVeganTap = tester.widget<MonoChip>(chip('vegan')).onTap!;
            final staleNameSubmit = tester
                .widget<EditableText>(
                  find.descendant(
                    of: find.byType(TextFormField),
                    matching: find.byType(EditableText),
                  ),
                )
                .onSubmitted!;
            await tester.ensureVisible(find.text(S(lang)('importBackup')));
            await tester.tap(find.text(S(lang)('importBackup')));
            for (
              var attempt = 0;
              attempt < 100 && find.byType(AlertDialog).evaluate().isEmpty;
              attempt++
            ) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pump(const Duration(milliseconds: 20));
            }
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsOneWidget);
            if (outcome == 'cancel') {
              await tester.tapAt(const Offset(10, 10));
              await tester.pumpAndSettle();
              expect(find.byType(AlertDialog), findsNothing);
              expect(find.byType(CircularProgressIndicator), findsNothing);
              expect(state.profile.toJson(), original.toJson());
              await tester.ensureVisible(chip('dairy'));
              await tester.tap(chip('dairy'));
              await tester.pumpAndSettle();
              expect(state.profile.avoidFlags, {'dairy'});
              expect(store.loadProfile()!.toJson(), state.profile.toJson());
              await tester.pumpWidget(const SizedBox());
              return;
            }
            store
              ..pauseNext = true
              ..failPausedWrite = fail;
            await tester.tap(
              find.text(S(lang)(merge ? 'importMerge' : 'importReplace')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(store.entered.isCompleted, isTrue);
            expect(state.profile.toJson(), original.toJson());
            expect(
              find.bySemanticsLabel(S(lang)('backupRestoring')),
              findsOneWidget,
            );
            expect(
              find.semantics.byLabel(
                state.corpus.ontology.nameOf('dairy', lang),
              ),
              findsNothing,
            );
            expect(
              tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
              isFalse,
            );
            // Pointer taps and callbacks delivered after the confirmation must
            // not queue edits against the profile being replaced.
            await tester.ensureVisible(chip('dairy'));
            await tester.tap(chip('dairy'), warnIfMissed: false);
            staleVeganTap();
            staleNameSubmit('Stale name');
            await tester.pump();
            if (outcome == 'navigation') {
              await tester.pumpWidget(const SizedBox());
            }
            store.release.complete();
            await tester.pumpAndSettle();
            final expected = fail ? original : restored;
            expect(state.profile.avoidFlags, expected.avoidFlags);
            expect(
              state.profile.requiredAttributes,
              expected.requiredAttributes,
            );
            expect(state.profile.toJson(), expected.toJson());
            expect(store.loadProfile()!.toJson(), expected.toJson());
            final reloaded = AppState(store: store, corpus: state.corpus);
            await reloaded.load();
            expect(reloaded.profile.toJson(), expected.toJson());
            reloaded.dispose();
            if (outcome == 'navigation') {
              expect(tester.takeException(), isNull);
              return;
            }
            expect(
              find.text(S(lang)(fail ? 'backupImportFailed' : 'importDone')),
              findsOneWidget,
            );
            expect(find.byType(CircularProgressIndicator), findsNothing);
            final nameField = tester.widget<EditableText>(
              find.descendant(
                of: find.byType(TextFormField),
                matching: find.byType(EditableText),
              ),
            );
            expect(nameField.controller.text, expected.name);
            await tester.ensureVisible(chip('egg'));
            await tester.tap(chip('egg'));
            await tester.pumpAndSettle();
            expect(state.profile.avoidFlags, {...expected.avoidFlags, 'egg'});
            expect(store.loadProfile()!.toJson(), state.profile.toJson());
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}

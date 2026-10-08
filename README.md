# MorphCook

*The same dish exists for every body.*

Recipe apps treat dietary needs as filters that remove dishes from the world:
go vegan and the Döner disappears, develop a nut allergy and Pad Thai is gone.
MorphCook inverts this. Every dish exists as fully-authored variants — vegan
Döner, gluten-free Alfredo, keto burger — and your profile decides which
variant of each dish you see. You keep the whole cookbook.

The app is an offline-first Flutter app (Android + iOS): no backend, no
accounts, no telemetry, no runtime AI. Network access is used only for explicit
imports and online photo searches. The bilingual (EN/DE) recipe corpus ships bundled with the app.

This repository is the maintained, actively-refined build of MorphCook. It was
originally produced by Claude Fable 5 as one entry in a
[multi-model comparison](https://github.com/TheMorpheus407/morphcook) and has
been developed by hand since.

## Build

```sh
flutter pub get --enforce-lockfile
flutter test
flutter run
```

Release APK (what F-Droid builds):

```sh
flutter build apk --release
```

For reproducible F-Droid builds the Flutter SDK is pinned as a git submodule
(`submodules/flutter`, currently 3.41.9). A normal clone ignores it; the
F-Droid buildserver initializes it and builds with that exact toolchain. Local
development can use system Flutter 3.41.9 with the submodule uninitialized,
so dependency resolution matches the committed lockfile.
If you initialized the submodule to check the pinned SDK, return to the normal
local checkout with `git submodule deinit -- submodules/flutter` before running
app checks with your system SDK. This requires a clean submodule and preserves
its exact git pin. Otherwise, root-level analysis also traverses the SDK's
independent development and test packages, which are not app dependencies.

## Privacy

MorphCook is offline-first and collects no analytics. Website requests and optional photo downloads occur only when you choose an import. The optional online photo search contacts Wikimedia Commons only when you search. See
[PRIVACY.md](PRIVACY.md).

## Licenses

- Application code and recipe corpus: **MIT** — see [LICENSE](LICENSE).
- Bundled fonts, all under the **SIL Open Font License 1.1**:
  - Playfair Display — `assets/fonts/OFL-PlayfairDisplay.txt`
  - JetBrains Mono — `assets/fonts/OFL-JetBrainsMono.txt`
  - Caveat — `assets/fonts/OFL-Caveat.txt`

## Saving recipes

Tap the bookmark icon on any Start View card or featured dish to save it to
your cookbook without opening the recipe first. Tap it again to remove that
variant; the bookmark in recipe details uses the same saved state. Dishes
with the same frequency tier have a consistent order. The featured dish stays
in place while the home screen remains open, including across tab switches and
returns from recipe details. Its variant still follows your profile. Changing
your profile or pulling down to refresh picks a featured dish using the current
time and cooking history; restarting the app also starts a new selection.

## Website imports

In the cookbook, use the link icon to import a recipe URL. Review its ingredients,
steps, time and servings before saving. Text is available offline; photos download
only if selected. Website diet and allergy claims are unverified. Ambiguous
amounts retain their original text and are explicitly marked as unscaled.

## Online recipe photos

Settings → online photos → turn on "find recipe photos online" (off by default).
Recipe pages then offer "find photo online", which searches Wikimedia Commons for
the dish name. Refine the words, choose a preview and save it for offline use.
Results carry supported free-license metadata and may not show the exact recipe;
Their author, license and source page are shown on the recipe page and travel
with the photo.

## Recipe sharing

Share one recipe from its details or the whole cookbook from the sharing screen.
The ZIP includes readable text and importable recipe data, with optional photos.
Recipients preview additions; their profile, plans and history stay private.
Android offers Bluetooth, Quick Share and other installed compatible apps.

## PDF import, manual and feedback

Import selectable-text PDF recipes from the cookbook and review before saving.
Settings includes the offline EN/DE manual, feedback drafts and license notices.
Recipe details let you request and privately record attributed expert assessments.
The app does not supply professional reviews or verify credentials. Notes travel
only in full backups, with a warning when the assessed recipe changes.

# MorphCook

*The same dish exists for every body.*

Recipe apps treat dietary needs as filters that remove dishes from the world:
go vegan and the Döner disappears, develop a nut allergy and Pad Thai is gone.
MorphCook inverts this. Every dish exists as fully-authored variants — vegan
Döner, gluten-free Alfredo, keto burger — and your profile decides which
variant of each dish you see. You keep the whole cookbook.

The app is an offline-first Flutter app (Android + iOS): no backend, no
accounts, no telemetry, no runtime AI, no network permission. The bilingual
(EN/DE) recipe corpus ships bundled with the app.

This repository is the maintained, actively-refined build of MorphCook. It was
originally produced by Claude Fable 5 as one entry in a
[multi-model comparison](https://github.com/TheMorpheus407/morphcook) and has
been developed by hand since.

## Build

```sh
flutter pub get
flutter test
flutter run
```

Release APK (what F-Droid builds):

```sh
flutter build apk --release
```

For reproducible F-Droid builds the Flutter SDK is pinned as a git submodule
(`submodules/flutter`, currently 3.38.3). A normal clone ignores it; the
F-Droid buildserver initializes it and builds with that exact toolchain. Local
development can just use your system Flutter.

## Privacy

MorphCook makes no network requests and collects nothing. See
[PRIVACY.md](PRIVACY.md).

## Licenses

- Application code and recipe corpus: **MIT** — see [LICENSE](LICENSE).
- Bundled fonts, all under the **SIL Open Font License 1.1**:
  - Playfair Display — `assets/fonts/OFL-PlayfairDisplay.txt`
  - JetBrains Mono — `assets/fonts/OFL-JetBrainsMono.txt`
  - Caveat — `assets/fonts/OFL-Caveat.txt`

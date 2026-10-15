# Profile persistence regression checks

Profile edits and onboarding share the mutation queue used by backup restore
and reset. Each operation finishes before the next begins. A profile is
published and listeners are notified only after its persistence succeeds;
a failed edit leaves the previously published profile usable and allows the
next queued operation to run.

Reset also requires SharedPreferences to confirm its clear before erasing Hive
collections or photos. A false result or exception propagates without publishing
an empty AppState. Both the Dart cache and native preferences may already be
empty when a clear fails. HiveStore snapshots all preferences before clearing
and attempts to restore each value independently before reporting the original
failure. Settings reports the failure in English or German and permits retry.
Hive collections and photo bytes are also snapshotted before deletion and
restored independently after a later clear failure; see the
[native reset checks](collection-write-failures.md). Recovery is best effort if
storage also rejects rollback, so a partial reset remains possible in that case.
These writes do not provide transaction atomicity or a device-crash guarantee.

`test/reset_confirmation_test.dart` covers rejected and throwing native clears
before and after changing native values, with real Hive storage, no publication,
a fresh-cache reload and successful retry. All five preference types are restored,
including lists returned by platform channels. Rejected or throwing recovery
writes do not block recovery of other keys or replace the original error. Its
English and German widget cases check failure feedback and retry. The four
original cases fail with the pre-fix store and settings code from `1779b5d`. Six
after-write/rollback cases fail with the submitted PR #24 store from `a592271`.

A confirmed reset may finish while recipe details opened from Home are still
visible. Reset replaces the root shell with onboarding and disposes Home;
returning from details then completes Home's pending navigation callback.
Home checks `mounted` before reading `context` in `_recompute`, so this late
callback safely returns. The existing checks after asynchronous variant loads
still reject disposed state, stale generations and changed profiles.

The English and German `returning from detail after pending reset is safe`
cases in `test/reset_confirmation_test.dart` use the real reset dialog, Home
tab, recipe route and back navigation, pausing only the store's clear. They
verify Home is removed before returning and onboarding is visible afterward.
Both fail with `State.context → _recompute` when the entry guard is removed
from PR #33's submitted head `09359f7`, and pass with it present. These are
Flutter widget checks with injected storage timing.

`test/profile_write_ordering_test.dart` covers these boundaries with paused
storage calls and checks notifications, memory, storage and a fresh AppState:

| Ordering | Expected result |
|---|---|
| Edit paused before or after persistence → another edit | The later profile wins in memory and after reload. |
| Edit paused before or after persistence → onboarding | The onboarding profile is published last. |
| Edit paused before or after persistence → reset | Profile storage is empty; the app returns to onboarding without resurrecting the old profile. |
| Edit paused before or after persistence → backup merge or replacement | The incoming backup profile is published last. |
| Edit fails before persistence → any of the above | The failure propagates without notification; the next operation still succeeds. |
| Onboarding, backup merge or replacement paused after profile persistence → edit | The later edit waits for completion and remains the final profile. |

All 18 ordering cases fail on the submitted PR head `d424c43`. The four
`failed profile write leaves bookmarks usable` widget cases in
`test/home_bookmark_test.dart` also fail with the original publication order
from base `74dc03c`: grid and featured bookmarks, with and without refresh.
They tap save and remove after an injected failure and check that the previous
profile stays in memory and storage. These are injected storage and Flutter
widget checks; they do not simulate a device crash or guarantee atomicity
across all backup writes.

Settings use `editProfile` to enqueue a change rather than a complete profile
captured by a widget build. Each change reads the last successfully persisted
profile when its turn starts. This preserves overlapping edits to different
fields and set membership, including two clicks on the same allergy chip.
`test/settings_profile_edits_test.dart` exercises these UI actions with a
paused first write and verifies persisted and reloaded profiles. The three original allergy/language
cases fail on base `1d03b818` before this change.

During a confirmed backup merge or replacement, Settings briefly blocks edits
until application and any failure recovery finish. Pointer input, focus and
settings accessibility actions are excluded; callbacks already in flight are
also guarded. The busy indicator announces restoration in English or German.
Cancellation leaves settings usable, and navigating away safely lets restore
finish. Blocked taps are never replayed against imported data. The name field
refreshes to a successfully restored name. Ordinary name saves keep the field's
controller and focus, and completion only refreshes text if no newer typing has
occurred. A newer draft remains editable and can be submitted separately, even
if it matches the old persisted name. A failed restore retains unsaved name text.

`test/settings_backup_restore_test.dart` covers successful and failed paused
restores, cancellation and navigation away, with English merge and German
replacement flows. The restore-interaction and name-refresh regressions fail
on submitted head `807acfe`. The settings edit tests also cover required-attribute
double taps and localized save failures with an unchanged persisted profile
and a successful retry. Removing the save-error handler fails both language
cases. These tests use injected storage delays/failures and a mocked file
picker with a real temporary backup fixture; they do not simulate a device
crash or a native picker dialog.

The four `pending en/de name save preserves newer Alicia/Original draft` cases
in `test/settings_profile_edits_test.dart` fail on fixed head `b70b32f` before
the draft-preservation correction. They check the draft, controller identity,
selection and focus after a delayed save, then submit the draft and check
memory, storage and reload.

`test/profile_persistence_failure_test.dart` injects `false` confirmations and
exceptions before or after native preference writes, using the real HiveStore
and SharedPreferences Dart implementations. It checks the previous published
profile, the preferences cache, native data and a fresh cache after failed
profile edits or onboarding, followed by a successful retry. Recovery is best
effort if storage also rejects rollback; these checks do not simulate a device
crash.

The after-write ordering case pauses rollback before it restores storage and
checks that the queued edit's callback has not started. It also reads storage
inside that callback, before the next edit can repair it. With pre-PR AppState
from `776f04b7`, the original ordering case passes; the strengthened case fails
because the next edit starts before recovery. The other 13 failure cases fail
with that pre-PR AppState as well.

Onboarding copies the submitted dietary flags and locks language, diet/allergy
choices and back navigation while saving. A failed save keeps those choices,
reports the localized error and unlocks editing and navigation for retry.
`test/onboarding_pending_profile_test.dart` covers adding/removing dairy during
delayed native flag confirmation, failure/retry and a fresh preferences cache.
Its four cases fail on base `5510d112` and pass with the onboarding fix.

`test/onboarding_pending_controls_test.dart` adds six English/German cases for
pending language selection, compound diet chips, toolbar/system back and
recovery after failure. All six fail on base `5510d112`; removing the language
and navigation guards also breaks the corresponding tests while keeping the
flag snapshot and chip locks. These control tests use an injected in-memory
store and a second route to observe attempted system-back navigation.

Mounted search results follow each successfully published profile without
requiring a new query. `test/search_profile_refresh_test.dart` covers tightening
and relaxing ingredient, allergy, attribute, time and calorie restrictions.
Two additional English/German cases switch between the real RootShell tabs,
change the profile while search is offstage, and check that the mounted state,
query and selected category/tag filters survive. They also verify that a
bookmark notification retains the current results and pager. All seven cases
fail with the pre-fix SearchScreen from `08c4eade` and pass with the profile
dependency refresh. These are Flutter widget checks using the bundled corpus
and in-memory storage.

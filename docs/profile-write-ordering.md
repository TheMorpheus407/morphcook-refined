# Profile persistence regression checks

Profile edits and onboarding share the mutation queue used by backup restore
and reset. Each operation finishes before the next begins. A profile is
published and listeners are notified only after its persistence succeeds;
a failed edit leaves the previously published profile usable and allows the
next queued operation to run.

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

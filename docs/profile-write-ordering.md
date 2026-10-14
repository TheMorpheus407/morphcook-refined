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

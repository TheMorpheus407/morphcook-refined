# Collection save failures

History, meal plans, shopping lists/history, cook progress and local content requests share
AppState's mutation queue. Each operation builds a private next snapshot and
publishes it only after every required write succeeds. Failure propagates the
original exception without publishing or notifying listeners. The queue waits
for recovery before starting the next mutation.

Recovery snapshots each affected key's raw JSON before writing. It restores
attempted keys independently, including deleting a key that was previously
absent. This preserves malformed records, unknown fields and original JSON
formatting on failure. Collections that were never attempted remain untouched.
The existing tolerant readers can still omit malformed collections from the
published view; this change does not repair malformed input on successful edits.

Rollback is best effort, matching profile and bookmark recovery. If storage
rejects both the edit and its rollback, memory retains the previous snapshot
but a restart can expose the partially persisted edit. The double-failure test
explicitly demonstrates this limit and subsequent queue/retry behavior. These
checks do not promise transaction atomicity or recovery from a device crash.

Full reset snapshots preferences, raw collections and photo bytes before clearing
any store. An unreadable box fails before deletion. If a later clear fails, each
affected store is restored independently and the original error is reported;
AppState keeps its previous published snapshot. `test/native_reset_rollback_test.dart`
closes each real Hive box before reset or after preference deletion and checks
raw data, reload, notifications and a successful retry. Two further cases inject
an I/O failure after truncating the real collection or photo file, close both
boxes and verify recovery from disk. The photo case fails if image recovery is
removed; all six cases fail with the pre-PR store from `c9b116ac`. The same
best-effort rollback limits apply if recovery itself fails.

An open personal-recipe detail page follows confirmed cookbook changes. A reset
or replacement backup that removes the recipe hides its cached content and all
recipe actions, with an English/German unavailable message and Back still usable.
A failed reset keeps the recipe and its supplied authorship. A restored revision
updates its title, ingredients and source together; absent personal data never
implies a bundled AI origin.

Shopping, meal-plan, recipe-add, cook-progress and cooking-completion controls report a failed
save in English or German and allow retry. Success feedback and leaving the
cooking completion screen happen only after confirmation. The completion note
asks the user to save the meal rather than claiming it is already recorded.
Navigating away during a failed save does not show feedback on a disposed page.

Meal-plan drags retain the week, source slot, recipe ID and feedback visible at
the first pointer-down, including provider rebuilds during the long-press delay.
Overlapping pointers on the same cell share that snapshot until all have lifted
or cancelled; the next independent interaction captures the current assignment
and feedback. The queued move checks that the source still contains that recipe
after earlier mutations settle. A backup replacement that changes or removes the source makes the drop
a no-op. If the source still matches, the move uses the current destination and
swaps an occupied destination back to the source. Save failures keep the previous
assignments and allow another drag to retry.

The planner retains its selected calendar week across midnight and provider
rebuilds. Both arrows navigate from that displayed week; the ±4-week window is
anchored when the screen first renders. A rebuild during an export press cannot
change which week is exported. A newly mounted planner starts at the current week.

Meal removal also retains the recipe ID from the rendered cell, including if a
restore completes between pointer-down and the tap callback or while the slot
menu is open. The tap recognizer owns this snapshot: fast scrolls, secondary
clicks and a restored empty slot cannot reuse it for a later tap. Additional
pointers do not replace the active tap's context. Accessibility taps use the
currently displayed slot. Remove and recipe selection retain the selected week
through an open menu or picker, including Sunday/Monday midnight rollover.
The queued clear checks that the slot still holds that recipe;
a changed or removed assignment makes the action a no-op. Direct `clearMeal`
calls without an explicit ID capture the current assignment before queueing.

Opening cook mode reads resume progress through the mutation queue, after earlier
edits and their recovery settle. While waiting, the screen shows a progress
indicator with an English/German accessibility label; Close and Back remain
available. Cooking controls appear only once the confirmed step, servings and
paused timer have been read. Leaving during this wait skips initialization.
The one-handed tap setting is also read after queued profile edits settle.
This prevents an older reopened session from overwriting a successful pending
save or resurrecting progress after a confirmed clear.

After the wait, cook mode resolves the current personal recipe and keeps that
confirmed snapshot for instructions, title, timers, servings and ingredients.
A successful pending backup import supplies its replacement recipe; a failed
import keeps the previous recipe after recovery. If the confirmed import removes
the personal recipe, cook mode shows the localized unavailable message with a
working Close action, without initializing cooking from its deleted snapshot.
Bundled recipes retain their supplied data.

Confirmed progress changes notify recipe details so its Start/Resume label
updates after a save or clear; pending and failed writes keep the previous label.

Finishing the last step clears only the cooking recipe's resume. Ownership is
checked inside the mutation queue after earlier saves and rollback finish; a
resume belonging to another recipe keeps its exact stored bytes.

Saving a completed meal also clears any resume state for that recipe, including
when the first progress-clear attempt failed. Both writes must confirm before
either snapshot is published; failure recovers both raw values. Progress for
another recipe remains untouched.

Cooking completion accepts one Done action while its history save is pending,
including taps before the disabled button rebuilds. A failed save enables retry.
After success, it closes only the current cooking route: Back or a covering route
cannot cause another page to close. When a covering route is dismissed, Done can
close the already-saved completion without recording the meal again.

Search results appear independently of local content-request writes. A failed
log is silent and can retry on a later search; AppState deduplicates successful
queries. Distinct consecutive empty searches are recorded independently. The
empty-results hint suggests another query or fewer filters, without claiming
that logging succeeded or that anything was sent to the developer.

Targeted checks:

- `test/detail_initial_removal_test.dart`: real cookbook taps followed by a
  confirmed reset before the detail route's first frame, starting from EN/DE
  profiles. Successful resets show unavailable content instead of a persistent
  skeleton and allow Back to onboarding; failed resets retain recipe actions.
  Reset restores the default English profile. Separate deletion-before-first-frame
  cases retain each language and check the English/German unavailable message,
  absent recipe actions and Back to the empty cookbook.
- `test/personal_detail_reset_test.dart`: EN/DE navigation from a pending Settings
  reset into a personal recipe, confirmed removal versus failed reset, Back to
  onboarding, direct deletion, and open-page backup replacement/removal. Checks
  private content, authorship, available actions, current ingredients, instructions,
  cooking time and servings.
- `test/meal_gesture_week_test.dart`: EN/DE long-press source replacement
  before the drag starts, adjacent-week navigation across midnight, and an
  export press held through a midnight restore/rebuild. Unchanged-source/clock
  controls and persisted plan/shopping reloads accompany the bug cases. Overlapping
  pointers cover pending/started drags, either release order, up/cancel, restores
  before/after the second down, removal, unchanged moves/swaps, frozen feedback
  and fresh snapshots for subsequent gestures.
- `test/cook_progress_confirmation_test.dart`: progress creation, update and
  clearing before/after-write failures, exact raw JSON recovery, unpublished
  pending values, queued retry, and EN/DE cook-mode errors and resume behavior.
  Finishing a different recipe preserves step, servings, timer and raw storage
  through reload. Scoped clears follow the owner after an earlier save succeeds
  or rolls back, in both ownership directions, without spurious notifications.
- `test/cook_import_snapshot_test.dart`: EN/DE Start Cooking from recipe details
  during a pending backup replacement, with success and failure before or after
  storage changes. Checks the waiting screen, confirmed instructions/title,
  timer, servings and scaled ingredients, plus recipe/progress after reload.
  Removal cases check unavailable actions and Close on success, and cooking
  completion/history after a failed import, including failures after storage was
  changed. The four successful-removal cases fail with pre-PR cook mode from
  `b7b7861`. `test/raw_ingredient_test.dart` persists its personal recipe before
  opening cook mode and verifies known amounts scale while raw text stays intact.
- `test/cook_progress_resume_test.dart`: EN/DE reopening during delayed saves,
  queued step changes, clearing and delayed failure recovery; paused timers and
  servings, subsequent edits and reload; unavailable controls while waiting,
  localized accessibility labels and safe Close/Back before initialization.
  The eight save/clear cases fail on submitted PR #26 head `94e2884` even
  without checking the waiting controls. All twenty cases fail with the waiting
  and timer checks included, and pass after the queued resume read.
  Four additional EN/DE checks toggle quick-tap while initialization waits,
  then check the hint and actual tap behavior. They fail on finishing head
  `6537a3b` and pass after reading that setting after the queued edits.
  Four detail-screen checks cover EN/DE Start/Resume labels during and after
  progress saves and clears; all fail without the confirmed-change notification.
- `test/collection_write_failure_test.dart`: before/after-write failures for
  every collection edit, both shopping writes, retry/reload, notifications,
  queued assignment, exact raw JSON/unknown fields, absent keys and the
  double-failure limitation.
- `test/collection_queue_widget_test.dart`: EN/DE search failures and retry,
  consecutive distinct empty queries, results while logging waits in the
  mutation queue, stale-query protection and shopping row identity.
- `test/meal_drag_identity_test.dart`: sixteen real RootShell EN/DE long-press
  drags, with empty/occupied destinations and unchanged/replaced sources.
  Restore completes before or after drop; exact plan snapshots are checked in
  memory and after reload. The original four cases yield two passing controls
  and two replacement failures with the pre-fix production code.
- `test/meal_remove_identity_test.dart`: sixteen EN/DE widget cases covering
  restore completion before the tap callback, across a frame rebuild during the
  tap, while the menu is open and after Remove, with unchanged-meal controls.
  Four direct-call cases cover unchanged, replaced, removed and initially empty
  slots while restore waits. Every case
  checks memory and reload. The two pointer-timing replacement cases fail on
  submitted PR #34 head `1436564`; moving the default identity capture inside
  the queue also fails the direct replacement and initially empty cases.
- `test/meal_tap_context_test.dart`: EN/DE fast scrolls, secondary clicks and
  subtree disposal when a restore empties a pressed slot, followed by week
  navigation and removal or cookbook assignment. Checks exact memory/reloaded
  plans, accessibility taps and additional pointers during an active tap.
- `test/meal_week_rollover_test.dart`: EN/DE removal and cookbook/search picking
  across Sunday/Monday midnight, with same-week controls and reload checks.
  Changing assignment back to recomputing the current week fails all four new
  rollover picker cases while the four same-week picker controls pass.
- `test/meal_week_boundaries_test.dart`: displayed-week export and real drags
  across Sunday/Monday midnight, with unchanged-clock controls and reload
  checks; calendar navigation across spring/autumn DST in Europe/Berlin.
  Also covers calendar Monday calculation and EN/DE exports after a weekday
  DST change in Asia/Jerusalem. All three new checks fail on PR #36's submitted
  head `4892bbe`: the helper returns Sunday 22 March at 23:00, and both exports
  persist W12 ingredients instead of W13. Run this file with
  `TZ=Europe/Berlin`, `TZ=Asia/Jerusalem` and `TZ=UTC`.
- `test/collection_failure_feedback_test.dart`: EN/DE shopping toggle/clear,
  meal assignment/removal/move/export, recipe additions, cooking completion,
  failure feedback, retry/reload, truthful completion text and navigation.
- `test/cooking_completion_pending_test.dart`: EN/DE rapid Done taps, Back during
  a pending save, and a covering route followed by closing the saved completion;
  checks persisted history and the exact route-pop sequence.

The finisher evidence directory for PR #20 records the failing checks against
submitted head `62aa25f` and passing checks after the fixes. The controller runs
the full configured gate and performs the final merge separately.

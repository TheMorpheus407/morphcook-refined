# Collection save failures

History, meal plans, shopping lists/history and local content requests share
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

Shopping, meal-plan, recipe-add and cooking-completion controls report a failed
save in English or German and allow retry. Success feedback and leaving the
cooking completion screen happen only after confirmation. The completion note
asks the user to save the meal rather than claiming it is already recorded.
Navigating away during a failed save does not show feedback on a disposed page.

Search results appear independently of local content-request writes. A failed
log is silent and can retry on a later search; AppState deduplicates successful
queries. Distinct consecutive empty searches are recorded independently. The
empty-results hint suggests another query or fewer filters, without claiming
that logging succeeded or that anything was sent to the developer.

Targeted checks:

- `test/collection_write_failure_test.dart`: before/after-write failures for
  every collection edit, both shopping writes, retry/reload, notifications,
  queued assignment, exact raw JSON/unknown fields, absent keys and the
  double-failure limitation.
- `test/collection_queue_widget_test.dart`: EN/DE search failures and retry,
  consecutive distinct empty queries, results while logging waits in the
  mutation queue, stale-query protection and shopping row identity.
- `test/collection_failure_feedback_test.dart`: EN/DE shopping toggle/clear,
  meal assignment/removal/move/export, recipe additions, cooking completion,
  failure feedback, retry/reload, truthful completion text and navigation.

The finisher evidence directory for PR #20 records the failing checks against
submitted head `62aa25f` and passing checks after the fixes. The controller runs
the full configured gate and performs the final merge separately.

# Recipe photo event ordering checks

These tables cover the behavioural findings from PR #10, the shared mutation ordering in PR #11, and accessible photo selection in PR #12. Each row has a targeted regression. Async results belong to the latest search generation; persisted attribution belongs to its exact photo bytes. A crash may recover a partial backup without misattributing replacement photos. Full-backup atomicity is outside this feature.

## Accessible photo selection

The English and German `screen reader selects only decoded idle photos ($lang)` widget cases in `test/recipe_photo_search_widget_test.dart` perform the tile's semantic tap action and check its localized credit, selected state and enabled save button. Pending previews have no tap action. Saving removes the action; a failed save restores it without publishing a photo. Both cases fail on the pre-fix base `56cf59d` because the decoded tile has no semantic tap action. These are Flutter semantics checks; TalkBack and VoiceOver device acceptance remains unverified.

## Overlapping photo mutations

Tests in `test/recipe_photo_write_ordering_test.dart` pause a photo binary write and request another mutation before releasing it. Saves, removals, shared imports, backup restore, personal-recipe deletion, reset and expert assessments share one queue. Later mutations take their snapshots after the preceding operation has completed or rolled back. These checks inspect memory, restart, backup contents and stored binary keys.

| Event ordering | Intended behaviour | Regression name |
|---|---|---|
| Save → second save → first succeeds or fails | Preserve the second photo and credit; a failed first save propagates its error and leaves the queue usable. | `overlapping photo writes preserve later save: fails=$fails` |
| Save → removal of the same photo | Finish saving before removing the photo and its binary. | `removal requested during a save removes its completed photo` |
| Save → shared import → first succeeds or fails | Wait for completion/rollback, then retain the local recipe and import the incoming recipe/photo/credit. | `import waits for a photo save and rollback: fails=$fails` |
| Save → backup merge → first succeeds or fails | Merge the completed local photo, or its rolled-back absence, with the incoming recipe/photo/credit and profile. | `merge waits for a photo save and rollback: fails=$fails` |
| Save → backup replacement → first succeeds or fails | Replace with incoming recipes/photos/credits and profile; remove the old-only photo binary. | `replace waits for a photo save and rollback: fails=$fails` |
| Save → deletion of its personal recipe → first succeeds or fails | Delete the recipe after completion/rollback; remove its photo, metadata and binary. | `delete waits for a photo save and rollback: fails=$fails` |
| Save → reset → first succeeds or fails | Reset after completion/rollback; clear recipes, photos, binaries and profile/onboarding state. | `reset waits for a photo save and rollback: fails=$fails` |

All 13 cases fail against the pre-fix base `ddb9f16`. Bypassing the shared queue only for imports, restore, deletion and reset keeps the original three cases passing and fails all ten additional cases.

## Restore and merge

Each restart row runs all eight combinations of replace/merge, legacy/current credit metadata, and credited/device replacement. Each test pauses a real persistence call, reloads another AppState, checks the recovered photo and its next backup, then completes the write and checks publication. Tests are in `test/recipe_photo_restore_ordering_test.dart`.

The dedicated replace-cleanup cases include an old-only credited photo and an incoming-only photo. They check the actual binary keys after deletion, restoration of the deleted photo and credit after a cleanup failure, removal of the incoming-only binary during rollback, and successful retry. Both legacy and current credit metadata are covered.

| Event ordering | Intended photo behaviour after restart | Regression name (all parameter combinations) |
|---|---|---|
| Restore → binding → restart | Old bytes and old credit. | `restore restart after binding: merge=$merge legacy=$legacy credited=$credited` |
| Restore → partial bytes → restart | Replaced entry has new bytes without credit; untouched entry keeps old bytes/credit. | `restore restart after partial bytes: merge=$merge legacy=$legacy credited=$credited` |
| Restore → bytes → restart | New bytes without old or incoming credit until metadata is written. | `restore restart after bytes: merge=$merge legacy=$legacy credited=$credited` |
| Restore → metadata → restart | New bytes and incoming credit, or no credit for device photos. | `restore restart after metadata: merge=$merge legacy=$legacy credited=$credited` |
| Restore → profile → restart | New bytes and incoming credit choice. | `restore restart after profile: merge=$merge legacy=$legacy credited=$credited` |
| Restore → onboarding → restart | New bytes and incoming credit choice. | `restore restart after onboarding: merge=$merge legacy=$legacy credited=$credited` |
| Restore → cleanup → restart | New bytes and incoming credit choice; successful completion publishes memory. | `restore restart after cleanup: merge=$merge legacy=$legacy credited=$credited` |
| Restore → binding → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after binding rolls back: merge=$merge` |
| Restore → partial bytes → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after partial bytes rolls back: merge=$merge` |
| Restore → bytes → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after bytes rolls back: merge=$merge` |
| Restore → metadata → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after metadata rolls back: merge=$merge` |
| Restore → profile → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after profile rolls back: merge=$merge` |
| Restore → onboarding → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after onboarding rolls back: merge=$merge` |
| Restore → cleanup → exception → rollback → restart → retry | Previous bytes/credit/profile restored; retry succeeds. | `restore failure after cleanup rolls back: merge=$merge` |
| Replace → cleanup deletes old-only photo → restart → completion | Only incoming photo binaries remain; recovered photos and exported credits match the incoming backup. Memory publishes after completion. | `replace cleanup deletes obsolete photo: legacy=$legacy` |
| Replace → cleanup deletes old-only photo → exception → rollback → restart → retry | Deleted old bytes/credit are restored, incoming-only binary is removed, and memory/export remain unchanged. Retry deletes the obsolete photo and saves the incoming photos/credits. | `replace cleanup failure restores deleted photo: legacy=$legacy` |

## Searches, selection and keyboard

| Event ordering | Intended behaviour | Regression in `test/recipe_photo_search_widget_test.dart` |
|---|---|---|
| Two overlapping searches; older completes first=false, older fails=false, newer fails=false | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=false oldFails=false newFails=false` |
| Two overlapping searches; older completes first=false, older fails=false, newer fails=true | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=false oldFails=false newFails=true` |
| Two overlapping searches; older completes first=false, older fails=true, newer fails=false | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=false oldFails=true newFails=false` |
| Two overlapping searches; older completes first=false, older fails=true, newer fails=true | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=false oldFails=true newFails=true` |
| Two overlapping searches; older completes first=true, older fails=false, newer fails=false | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=true oldFails=false newFails=false` |
| Two overlapping searches; older completes first=true, older fails=false, newer fails=true | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=true oldFails=false newFails=true` |
| Two overlapping searches; older completes first=true, older fails=true, newer fails=false | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=true oldFails=true newFails=false` |
| Two overlapping searches; older completes first=true, older fails=true, newer fails=true | Only the newer search controls results/error/loading. Older success triggers no preview. Newer success permits selection only after its preview decodes. | `latest search wins: olderFirst=true oldFails=true newFails=true` |
| Old preview pending → new search; old download completes first=false, fails=false | Old download never enables or changes the new tile. A save uses only new bytes and new credit, without another download. | `stale download stays discarded: oldFinishesFirst=false oldFails=false` |
| Old preview pending → new search; old download completes first=false, fails=true | Old download never enables or changes the new tile. A save uses only new bytes and new credit, without another download. | `stale download stays discarded: oldFinishesFirst=false oldFails=true` |
| Old preview pending → new search; old download completes first=true, fails=false | Old download never enables or changes the new tile. A save uses only new bytes and new credit, without another download. | `stale download stays discarded: oldFinishesFirst=true oldFails=false` |
| Old preview pending → new search; old download completes first=true, fails=true | Old download never enables or changes the new tile. A save uses only new bytes and new credit, without another download. | `stale download stays discarded: oldFinishesFirst=true oldFails=true` |
| Dispose screen → pending search completes with success | No state update on the disposed screen, no implicit save, and no preview request after a disposed search completes. | `disposed search ignores completion: preview=false fails=false` |
| Dispose screen → pending search completes with failure | No state update on the disposed screen, no implicit save, and no preview request after a disposed search completes. | `disposed search ignores completion: preview=false fails=true` |
| Dispose screen → pending preview completes with success | No state update on the disposed screen, no implicit save, and no preview request after a disposed search completes. | `disposed search ignores completion: preview=true fails=false` |
| Dispose screen → pending preview completes with failure | No state update on the disposed screen, no implicit save, and no preview request after a disposed search completes. | `disposed search ignores completion: preview=true fails=true` |
| Old photo displayed and selected → new search resolves before cleared grid frame → replacement success | Clear selection and decoded state; pending replacement cannot inherit old bytes. Only successful current decoding permits saving with matching credit. | `repeated search never reuses old preview: success` |
| Old photo displayed and selected → new search resolves before cleared grid frame → replacement download failure | Clear selection and decoded state; pending replacement cannot inherit old bytes. Only successful current decoding permits saving with matching credit. | `repeated search never reuses old preview: download failure` |
| Old photo displayed and selected → new search resolves before cleared grid frame → replacement decoder failure | Clear selection and decoded state; pending replacement cannot inherit old bytes. Only successful current decoding permits saving with matching credit. | `repeated search never reuses old preview: decoder failure` |
| Old photo displayed and selected → new search resolves before cleared grid frame → replacement same candidate | Clear selection and decoded state; pending replacement cannot inherit old bytes. Only successful current decoding permits saving with matching credit. | `repeated search never reuses old preview: same candidate` |
| Focus query → keyboard opens → type → submit → keyboard closes; landscape=false | Keep the same editable state and input connection, submit refined words, retain text, and avoid overflow. | `query keeps focus when keyboard opens: landscape=false` |
| Focus query → keyboard opens → type → submit → keyboard closes; landscape=true | Keep the same editable state and input connection, submit refined words, retain text, and avoid overflow. | `query keeps focus when keyboard opens: landscape=true` |
| Landscape German search starts with keyboard already open → scroll controls | Search and save controls remain reachable without overflow. | `search and save controls scroll with a landscape keyboard` |
| Download finishes with structurally valid, undecodable PNG → tap tile | Selection stays disabled and existing photo remains unchanged. | `decoder failures cannot replace a working photo` |
| Default off → enable setting → remain on detail screen | No request until explicit search is opened. | `recipe pages offer no online search while it is off` |
| Decode → choose → save → disable setting → replace from device | Persist chosen bytes and matching credit without redownload; disabling retains both; device replacement clears credit. | `choosing a found photo stores it with a visible credit` |
| Select decoded photo → storage-limit failure → retry available | Keep screen open, explain the limit and retain existing state. | `a full photo store keeps the search open with a reason` |
| Open blank query → submit blank query | No network request and no misleading empty-result message. | `an empty query opens without searching` |
| Network failure → busy response → empty search → successful search | Each new search replaces the prior status with its own result. | `search words can be refined; failures and no results explain` |

## Other persistence and import paths

| Event ordering | Intended behaviour | Regression in `test/recipe_photo_search_test.dart` |
|---|---|---|
| New bound credit → overwrite binary → restart before metadata | Recover new bytes without previous credit, including in the next backup. | `stored found photos interrupted replacement never applies stale credit to new bytes` |
| Legacy unbound credit → setRecipeImage → restart after binary write | Persist old byte binding first; recover replacement without stale credit. | `stored found photos legacy credited replacement is safe before its metadata completes` |
| Legacy-compatible single replacement → binding write fails → retry | Retain previous photo/credit; retry succeeds. | `stored found photos failed attribution binding preserves the previous credited photo` |
| Save credit → restart → export/import backup → replace from device | Credit survives correct round trips and clears on explicit device replacement. | `stored found photos credit survives restart, backup restore and replacement` |
| Share creditless photo → import same bytes with credit → restart → repeat | Enrich persisted attribution without another recipe; repeat is idempotent. | `stored found photos an identical shared photo gains missing credit without another recipe` |
| Import credited photo → import same content/bytes with equal credit → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Import credited photo → import same content/bytes with incoming null credit → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Import credited photo → import same content/bytes with different title → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Import credited photo → import same content/bytes with different author → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Import credited photo → import same content/bytes with different license → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Import credited photo → import same content/bytes with different provider → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Import credited photo → import same content/bytes with different source → repeat | Equal/null credits preserve existing attribution; each different non-null field creates a separate idempotent copy. | `stored found photos conflicting credits get idempotent copies; null and equal credits preserve existing` |
| Share enrichment → metadata write fails → restart | Existing binary and metadata survive rollback. | `stored found photos credit enrichment rollback keeps existing binary and metadata` |
| Collect share → readable text and JSON → decode → import | Photo credit survives all share stages and appears in readable text. | `stored found photos recipe shares carry the credit to the recipient` |
| Invalid metadata entry → valid entry with same preview | Only eligible entries participate in deduplication; offer the valid candidate. | `Commons response parsing rejected candidates do not suppress a valid duplicate preview` |

Personal recipe editor saves also use the common mutation queue, including
validation, collection snapshots, persistence, rollback and publication. A
pending editor save can no longer overwrite a later shared import or leave its
credited photo without a recipe. `personal_recipe_write_ordering_test.dart`
checks save followed by import, another editor save, backup merge/replacement,
delete or reset, with successful and failed first writes, including reload.
All twelve ordering cases fail on base `76481c2` before this fix.

Bookmark toggles and cooking-progress writes share this queue as well. Otherwise
a pending recipe save could discard a later bookmark in memory or storage, and
a delayed cooking-progress write could restore progress invalidated by an edit.
The fourteen additional cases in `personal_recipe_write_ordering_test.dart`
check bookmark additions/removals during creation and editing, bookmark writes
before creation, progress writes before editing, and new cooking sessions during
successful or failed edits. They inspect memory and reload; all fourteen fail
on submitted PR head `d8e57da` before those two writers join the queue.
These are injected storage-ordering checks, not device-crash guarantees.

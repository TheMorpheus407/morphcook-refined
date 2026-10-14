# Bookmark persistence checks

Bookmark additions and removals share the mutation queue used by recipe edits,
deletion, imports, restore and reset. AppState publishes the new saved list only
after persistence succeeds. A failure leaves the previous list in memory and
attempts storage rollback before the queue continues. Home and recipe details
report failures in English or German and allow the same change to be retried.

`test/bookmark_write_failure_test.dart` checks additions and removals paused
before persistence and after persistence but before confirmation. An explicit
unrelated rebuild notification still exposes the previous saved list. A meal assignment
requested while the bookmark is pending waits in the shared queue; successful
completion publishes the bookmark once, then the meal assignment, and both
survive reload. All four paused cases fail when publication is moved before the
write, even with rollback on failure retained.

The failure tests cover errors before and after persistence, rollback, reload,
notifications and retry. The six English/German widget cases exercise failed
saves and removals on featured cards, grid cards and recipe details, checking
error feedback and unchanged icons after an unrelated rebuild. All fourteen
cases fail with the pre-PR implementation at `5ef3d680`.

These checks use injected storage delays and errors. Rollback is best effort;
they do not guarantee recovery if rollback also fails or simulate device crashes.

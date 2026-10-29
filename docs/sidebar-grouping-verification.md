# Sidebar grouping verification

No Grouping remains the default. Grouping changes presentation and uses new
preference keys; the existing repository list, manual order, stars, recency,
filters, and discovery exclusions keep their established formats.

Choose View > Group Repositories by or the Repository Options menu at the bottom
of the sidebar. Forge and Account use a cached remote URL, preferring `origin` and then
the first configured remote. They make no network request. Account identity
includes both the host and complete owner namespace, so equally named accounts
on different hosts remain separate. Self-hosted forges use their actual host and
web port rather than a guessed provider name. First Letter supports Unicode
letters, folds accented initials, and places non-letter initials under `#`.

Each window remembers one expanded group. Expanding another group closes the
previous one. Searching reveals the first matching group while other matching
group headers retain their counts. Clearing the search restores the previous
accordion state, or reveals the repository selected during the search.

Manual groups support New Group, Rename Group, Delete Group, and the repository
context menu's Move to Group. Deleting a group moves its repository registrations
to Ungrouped. It does not remove repository registrations or change their files.
Creating a group or choosing an explicit destination clears filters so the new
destination is visible. Empty manual groups remain manageable outside filters.

## Automated checks

The grouping/store tests use a unique UserDefaults suite per test and never
modify production preferences:

```sh
swift test --filter 'SidebarGroupingTests|ManualRepositoryGroupStoreTests'
```

Coverage includes host/account separation, nested namespaces, Unicode initials,
local/unavailable/loading repositories, incoming sort order, empty manual groups,
name validation, stable group IDs after reload, normalized repository identities,
removal/re-add behavior, and byte-preservation of established preference values
when grouping data changes.

## Running-app checks

Use disposable repositories with GitHub, GitLab, a self-hosted forge, and no
remote. Remote URL strings are enough; do not fetch example remotes.

1. Verify No Grouping preserves the original order, stars, sorting, logical
   filters, text search, and manual drag reordering.
2. Check Forge, Account, and First Letter. Verify all registrations remain
   reachable, including local repositories. Expand two groups successively and
   confirm only the latest stays open. Exercise disclosure headers with mouse,
   Tab, and arrow keys.
3. Search for a repository inside a currently collapsed group. Its matching
   group should open. Clear the search and check the prior accordion state;
   repeat after selecting a search result and check the new selection is visible.
4. Create an empty group with Return, cancel another with Escape, and verify a
   blank name is disabled. Try a duplicate name with different capitalization;
   the sheet should show an actionable error and preserve its text.
5. Move two repositories to the group, rename it, then reopen the app and verify
   membership persists. Delete the group and confirm both registrations appear
   under Ungrouped with their files, stars, and original flat order intact.
6. Open two repository windows. Change the app-wide grouping mode, then expand
   different groups in the two windows. Verify their expansions remain
   independent and restore after reopening.
7. Delete a group from another window while it is expanded. The first window
   should recover to a valid group. Apply a filter with no matches and use Clear
   Filters to recover without losing the selected repository.

## Header keyboard regression

The initial grouped build selected a GitLab disclosure header in the accessibility
outline after a mouse click, but the window remained first responder. Right Arrow
did not expand it. Repository rows already had the native-list responder bridge;
headers did not, and the selection binding rejected their IDs.

Headers now have explicit stable tags and window-local outline selection. Selecting
a header requests the native list as first responder without changing the active
repository. Selecting a repository clears header selection; external repository
navigation also clears it and reveals the appropriate group. Verify the original
sequence in the running app: open GitHub, click collapsed GitLab, press Right Arrow,
then Left Arrow. GitLab should open and close, the prior repository should remain
in the detail pane, and opening another header should preserve the accordion rule.

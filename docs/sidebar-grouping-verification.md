# Sidebar grouping verification

No Grouping remains the default. Grouping changes presentation and uses new
preference keys; the existing repository list, manual order, stars, recency,
filters, and discovery exclusions keep their established formats.

Choose View > Group Repositories by or the Repository Options menu at the bottom
of the sidebar. Forge and Account use a cached remote URL, preferring `origin` and then
the first configured remote. They make no network request. Account mode combines
matching complete owner namespaces across hosts, ignoring case for presentation.
It preserves the first display spelling and lists sorted unique forge names in
the group subtitle, such as `GitHub, GitLab, codeberg.org`. This grouping does not
claim that similarly named accounts share authentication or identity. Nested
namespaces remain distinct: `team/tools` and `other/tools` are separate groups.
Forge mode stays host-specific. Self-hosted forges use their actual host and web
port rather than a guessed provider name. First Letter supports Unicode
letters, folds accented initials, and places non-letter initials under `#`.

Grouped mode uses fixed headers and one independently scrollable repository
body. Opening another group replaces the open body. The first header stays at
the top; the last stays at the bottom unless its own body is open below it.
Headers remain present during text and logical filtering, including groups with
no matching repositories. Searching opens a group with matches; clearing the
search restores the prior group or reveals the repository chosen during search.
Each open window has its own expanded group. The quit/relaunch limitation is recorded below. If headers cannot physically fit a
short window, an accessible overflow scroll must keep them reachable rather than
compress or clip them.

Manual groups support New Group, Rename Group, Delete Group, and the repository
context menu's Move to Group. Deleting a group moves its repository registrations
to Ungrouped. It does not remove repository registrations or change their files.
Creating a group or choosing an explicit destination clears filters so the new
destination is visible. Empty manual groups remain manageable, including while
filters are active.

## Automated checks

The grouping/store tests use a unique UserDefaults suite per test and never
modify production preferences:

```sh
swift test --filter 'SidebarGroupingTests|ManualRepositoryGroupStoreTests'
```

Coverage includes host-specific Forge groups, cross-host Account aggregation,
case variants, decoded nested namespaces, Unicode initials,
local/unavailable/loading repositories, incoming sort order, empty manual groups,
name validation, stable group IDs after reload, normalized repository identities,
removal/re-add behavior, and byte-preservation of established preference values
when grouping data changes.

## Running-app checks

Use disposable repositories with GitHub, GitLab, a self-hosted forge, and no
remote. Remote URL strings are enough; do not fetch example remotes.

1. Verify No Grouping preserves the original order, stars, sorting, logical
   filters, text search, and manual drag reordering.
2. Check Forge, Account, and First Letter. In Account mode, check matching
   `Acme`/`acme` namespaces on GitHub, GitLab, and a self-hosted forge combine
   under the first display spelling with all forge names in the subtitle.
   Forge mode should keep the hosts separate. Verify all registrations remain
   reachable, including local repositories. Open two groups successively and
   confirm one body stays open. Up/Down moves header focus; Right, Space, or
   Return opens the focused group. Tab enters its native repository List, where
   repeated Up/Down selects rows. Header focus leaves the active repository intact.
3. Search for a repository inside another group. A matching body should open,
   and every header should remain reachable with updated counts. Clear the search
   and check the prior open group; repeat after choosing a search result and
   check the new repository selection is visible.
4. Create an empty group with Return, cancel another with Escape, and verify a
   blank name is disabled. Try a duplicate name with different capitalization;
   the sheet should show an actionable error and preserve its text.
5. Move two repositories to the group, rename it, then reopen the app and verify
   membership persists. Delete the group and confirm both registrations appear
   under Ungrouped with their files, stars, and original flat order intact.
6. Open two repository windows. Change the app-wide grouping mode, then open
   different groups and select different repositories. Verify their live states
   remain independent while switching between windows. Record quit/relaunch
   behavior separately: the independently browsed group currently resets to the
   selected repository's group, as described under restoration limits below.
7. Delete a group from another window while it is expanded. The first window
   should recover to a valid group. Apply a filter with no matches and use Clear
   Filters to recover without losing the selected repository.

## Fixed-header regression and observed results

The revised fixed-header layout was exercised in the running app using owned
disposable fixtures. Automated coverage includes seven rendered
accordion/split-window tests and the explicit-navigation window-state contract.
Those component checks do not cover full-app repository reveal and do not
replace the running-app checks below.

Before this revision, DisclosureGroups lived inside one scrolling outline.
Opening a group with many repositories made its siblings scroll away. The
reproduction was to open the first group, scroll its repositories to the bottom,
and look for the first and last group headers. The revised layout keeps the
headers fixed and scrolls the open repository body between them.

Verified behavior:

- **First, middle, and last groups:** every header remained visible in the normal
  layout. The first header stayed at the top and the last at the bottom unless
  its body was open beneath it. Only the active group's body scrolled.
- **Empty, short, and long bodies:** each occupied the same remaining vertical
  budget. Empty or short content did not pull later headers upward or reduce the
  body to its content height.
- **Keyboard and selection:** Up/Down moved focus between headers. Right, Space,
  and Return opened the focused group while one body stayed open. Tab entered
  the native List; repeated Up/Down selected repository rows stably. Header
  navigation preserved the active repository until a row was chosen.
- **Search and recovery:** searching for the eighteenth Alpha repository kept
  all headers present, including zero-match counts. Escape restored the prior
  group. Clear Filters exposed its native accessibility name and action and
  worked from the empty body outside a List.
- **Manual groups:** Return created an empty group; rename and deletion worked.
  Deleting it opened a valid fallback and preserved all 29 fixture registrations.
- **Explicit opening and reveal:** reopening the already selected eighteenth
  Alpha repository while a query hid its row cleared the query, reapplied native
  selection, and scrolled it fully into view. Grouped and flat modes passed, with
  fixed headers retained in grouped mode. Ordinary arrow navigation stayed stable.
- **Independent windows:** two windows retained different open groups and
  repository selections when switching between them.
- **Flat mode:** mouse and keyboard selection, stars, the Uncommitted Changes
  filter, and Show All worked in the unchanged flat List.
- **Physical overflow:** with 24 empty group headers in an insufficiently tall
  window, the exceptional overflow scroll made the final header reachable and
  clickable. Normal windows used body-only scrolling.
- **Actual resizing:** with the commit inspector visible, resizing the real app
  between 961 × 573 and 1920 × 960 passed after the metadata ScrollView fix
  described below. This covers the short and tall window layouts.

## Reopening an already selected repository

Before the fix, explicitly opening an already selected repository after a query
hid its row could clear the query yet leave the row offscreen. Accessibility
reported Alpha18 selected while the scrollbar stayed at the top and only
Alpha01–Alpha12 were visible. The manual reproduction uses name sorting: select
Alpha18, search for Alpha01 in the same group, then use Command-O to open Alpha18
again.

In the corrected running app, Command-O cleared the query, selected Alpha18, and
scrolled it fully into view at the bottom with all headers pinned. The same
selection-and-visibility flow passed in flat mode. Repeated ordinary arrow
navigation retained the existing List and stable selection. Explicit Open, add,
and drop refresh the native List and reapply selection after its body mounts;
ordinary row navigation preserves its native table and keyboard focus.

This regression is verified manually in the actual app. The rendered component
and native split-window tests do not establish this full-app reveal behavior.
Repeat the procedure after changing sidebar identity, filtering, selection,
or scroll-view ownership; require both the correct native selection and a fully
visible target row.

## Inspector resize regression

The full app crashed in the inspector-resize path on clean main `9366597`.
Headless component and native split-window tests
did not reproduce that full-app crash, so their passing results were insufficient
to establish the fix.

The fix removes the existing vertical `fixedSize` modifier from the commit
metadata ScrollView in `CommitDetailView`. The inspector-visible 961 × 573 ↔
1920 × 960 sequence then passed in the actual app. This is the manual regression
evidence for that change; it should be repeated after later layout changes.

## Long metadata and restoration limits

The long-metadata fixture contains twenty paragraphs and a final sentinel. Show
More expanded the body, metadata scrolling reached the sentinel and Show Less at
both 1240 × 780 and 961 × 573, and Show Less returned to bounded content. Resizing
with that commit selected remained stable. Its empty test commit changed no files.

Live windows retain independent selections and expanded groups. In repeated
quit/relaunch checks on this macOS 27.0.1 test machine, an independently browsed
group reset to the selected repository's group in both Manual and Forge modes.
The owned profile had `NSQuitAlwaysKeepsWindows=true` and no
`ApplePersistenceIgnoreState` value; native `open -a` launch was also checked.
This remains a limitation; earlier one-off restoration observations are not
claimed as a repeatable pass. Repository registrations and manual assignments
persist, and fresh scenes always have one group open. No custom window-state
persistence or changes to the user's system restoration settings were added.

## Earlier observed results

The preceding outline-based build passed these checks in an isolated running app
with disposable working copies: the original grouping modes, manual
create/move/rename/delete, duplicate-name validation, Return/Escape sheets,
repository-row keyboard selection, search recovery, independent window expansion,
and cross-window recovery after group deletion. The earlier header-focus defect
was also reproduced and fixed: an accessibility-selected header had left the
window as first responder, so Right Arrow did nothing. Those results predate the
fixed-header component and do not establish its keyboard or layout behavior.

# History layout verification

The history list measures its available width once and shares the text-column
width with every row. The graph retains its existing lane geometry and 27-point
row height. Below 600 points of text-column width, rows show the subject, one
bounded reference chip, and the remaining reference count. Wider rows also show
up to three reference chips, the author, and the relative date.

The existing horizontal `fixedSize` modifiers remain intentional. A standalone
SwiftUI rendering comparison at text widths of 599, 600, and 800 points with long
author and reference names confirmed that the preceding `maxWidth` frames still
truncate those fields. Neither the reference group nor author overlapped the
subject or the 110-point date column.

## Disposable repository

Run this block in a terminal. It creates a repository under `/tmp`, with twelve
independent branches to exercise the crowded graph, deliberately long metadata,
and an unstaged text change for checking the diff.

```sh
fixture="$(mktemp -d /tmp/GitEnough-History-Layout.XXXXXX)"
git -C "$fixture" init -b main
git -C "$fixture" config user.name 'An Author With A Deliberately Very Long Full Name That Must Truncate'
git -C "$fixture" config user.email 'history-layout@example.invalid'
git -C "$fixture" config commit.gpgsign false
git -C "$fixture" config core.hooksPath /dev/null
printf 'Keep the original text readable.\n' > "$fixture/notes.txt"
git -C "$fixture" add notes.txt
git -C "$fixture" commit -m 'Start the history layout fixture'
base="$(git -C "$fixture" rev-parse HEAD)"
for index in 1 2 3 4 5 6 7 8 9 10 11 12; do
  git -C "$fixture" switch -c "feature/a-deliberately-very-long-reference-name-for-layout-$index" "$base"
  printf 'Independent branch %s.\n' "$index" > "$fixture/notes.txt"
  git -C "$fixture" add notes.txt
  git -C "$fixture" commit -m "Keep commit subjects readable with long metadata on branch $index"
done
git -C "$fixture" switch main
printf 'Keep the original text readable in the main branch.\n' > "$fixture/notes.txt"
git -C "$fixture" add notes.txt
git -C "$fixture" commit -m 'Keep commit subjects readable when author and reference names are long'
git -C "$fixture" tag 'release/a-deliberately-very-long-reference-name-one'
git -C "$fixture" tag 'release/a-deliberately-very-long-reference-name-two'
printf 'Keep the revised text readable in the main branch.\n' > "$fixture/notes.txt"
printf 'Fixture: %s\n' "$fixture"
```

Build and launch the app from the repository root:

```sh
xcodebuild -project GitEnough.xcodeproj -scheme GitEnough -configuration Debug -derivedDataPath /tmp/GitEnough-History-Polish CODE_SIGN_IDENTITY=- build
open -a /tmp/GitEnough-History-Polish/Build/Products/Debug/GitEnough.app "$fixture"
```

## Running-app checks

1. Keep the sidebar and inspector open at the default window size. Subjects
   should remain readable beside the crowded graph; compact rows should show
   one reference chip and a count. Select the top commit to see the complete
   author and date in the inspector.
2. Hide the inspector or enlarge the window, then resize through the compact
   threshold. Wide rows should show bounded reference chips and author, with
   the relative date visible at the trailing edge. Long metadata must truncate
   inside its column rather than paint over neighboring content.
3. Hover the row and inspect its accessibility label. Both should contain the
   full subject, author and email, date, hash, and every reference name, including
   names omitted by the compact layout.
4. Use Changes to inspect `notes.txt`. Text should retain the system monospaced
   callout font, semantic addition/deletion colors, and bold underlined changed
   words. Select and copy a line to confirm ordinary text selection still works.
5. Resize and scroll a loaded history, filter it with Command-F, and use arrow
   keys after selecting a row. Confirm selection and graph alignment are stable.
6. Remove the fixture from GitEnough when finished. This changes only its sidebar
   registration; the disposable repository remains under `/tmp`.

## Rendering equivalence

A separate SwiftUI ImageRenderer comparison rendered the old concatenated Text
and the replacement interpolated Text with multiple bold underlined segments,
monospaced callout typography, and the semantic addition color. Their pixel
buffers were byte-for-byte equal. This check does not replace the running-app
checks above.

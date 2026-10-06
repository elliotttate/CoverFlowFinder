# FlowFinder Deep-Dive Review — October 2026

**Scope:** all 37 Swift files (~25K lines), plus Info.plist, the entitlements, `scripts/notarize.sh`, `RELEASING.md` and the appcast. Reviewed at `7d9606a` (v1.38.0) plus the uncommitted `MasonryView.swift` changes.
**Build:** succeeds with Xcode-beta, with ~100 warnings (see §7). No source files were changed.
**Method:** six parallel reviewers, each covering one area and reading every line. Several findings were then checked again by reading the code directly; those are marked ✔. Findings marked *likely* were traced but not reproduced. Line numbers refer to the current working tree.

---

## TL;DR — the 12 things to fix first

| # | Issue | Where | Impact |
|---|---|---|---|
| 1 | ✔ **Zip-slip**: copying a folder out of a crafted ZIP writes/deletes files outside the temp dir | `FileBrowserViewModel.swift:2694-2711`, `:2659-2662` | Security: arbitrary file overwrite or delete (non-sandboxed app) |
| 2 | ✔ The Edit menu replaces Copy/Cut/Paste/Delete with file actions, so **⌘⌫ while renaming trashes the file** and ⌘C/⌘V in text fields act on files | `FlowFinderApp.swift:71-118` | Data loss / broken text editing (*likely*) |
| 3 | ✔ Dual/Quad key handlers **ignore text-field focus**: Space/Return/arrows are swallowed in search & rename, and ⌘⌫ trashes | `DualPaneView.swift:107-167`, `QuadPaneView.swift:160-218` | Data loss; you can't type a space in search in dual mode |
| 4 | ✔ **One app-wide keyboard handler**, not scoped to a window: keys in window A act on window B; Esc is swallowed in sheets; Return in alerts opens files | `KeyboardHandler.swift:17-35, 90, 129-131` | Data loss across windows |
| 5 | ✔ Menu/toolbar commands always target the **left pane**, even when the right pane is active | `ContentView.swift:227` | Trash/Duplicate/New Folder hit the wrong pane |
| 6 | ✔ Cover Flow **performs a drop twice**, and a **cancelled drag (Esc) still moves files** | `CoverFlowView.swift:2939-2983` | Duplicate copies; unintended moves |
| 7 | ✔ Drag always **moves**, even across volumes, where the "move" is copy + **permanent `removeItem`** (Finder copies across volumes) | `FileBrowserViewModel.swift:2902, 3143-3156` | Data loss risk from USB/SMB |
| 8 | ✔ **Copying a folder into itself** recurses until the path limit (no descendant check) | `paste(to:)` `:2787-2797`, `handleDrop` | Fills disk with nested copies |
| 9 | Cover Flow reads **live `NSEvent.modifierFlags`**, so Shift+letter type-ahead becomes a range selection, then ⌘⌫ trashes the range | `CoverFlowView.swift:133-139` | Accidental mass-trash |
| 10 | ✔ Cover Flow **hit-testing ignores the 3D transforms**: clicks and drops land on the wrong cover | `CoverFlowView.swift:2301-2347` | Files dropped into the wrong folder |
| 11 | ✔ The **folder watcher dies** after you leave a folder and come back (ZIP, Photos, /Network, app backgrounding) | `DirectoryWatcher.stop()` `:3519-3525` | Folder never live-updates again |
| 12 | ✔ **Every rename/paste/new folder/⌘R triggers a full reload**: spinner, scroll jumps to top, selection lost | `refresh()` `:2350` → `loadContents` `:565-566`; `ContentView.swift:952-973` | Most-felt UX bug |

---

## 1. Security & data loss

**1.1 ✔ Zip-slip in archive extraction (Critical)**
- **Where:** `FileBrowserViewModel.swift:2694-2711` (`extractArchiveDirectory`) and `:2659-2662`.
- **Problem:** The relative path of each ZIP entry goes straight into `destURL.appendingPathComponent(relativePath)`, which is then passed to `removeItem` + `copyItem`. An entry like `a/../../../../usr/local/bin/x` shows up as folder `a`, and ⌘C on it overwrites the target. An entry named `..` makes `destURL = $TMPDIR/FlowFinder-Extract/..`, and `removeItem` then deletes all of `$TMPDIR`.
- **Fix:** reject entries with `..`, `.`, a leading `/` or backslashes. Verify `itemDestURL.standardizedFileURL.path` has the extraction root as a prefix. Never `removeItem` a path derived from archive data.

**1.2 Extracted files aren't quarantined (High, *likely*)**
- **Where:** `ZipArchiveManager.swift:256-258`, `FileBrowserViewModel.swift:2172, 2674, 2710`.
- **Problem:** A `.pkg`, `.dmg`, `.terminal` or `.fileloc` inside a downloaded ZIP is opened or pasted without `com.apple.quarantine`, which bypasses Gatekeeper.
- **Fix:** copy the archive's quarantine xattr onto every extracted file, as Archive Utility does.

**1.3 A crafted ZIP crashes the app just by browsing into it (High)**
- **Problem:** unchecked integer conversion/overflow at `ZipArchiveManager.swift:105` (`cdOffset + cdSize`), `:430`, `:748` (`Int64(entry.uncompressedSize)`, on every listing), `:211/239/250`. `parseZip64ExtraField` (`:621-631`) bounds-checks against the declared size rather than `data.count`. `extractFile` doesn't verify that it read 30 header bytes (`:220-232`).
- **Fix:** use `Int64(exactly:)`, `addingReportingOverflow`, clamp to file size, and bound reads by `data.count`.

**1.4 Zip bomb / unbounded memory (Medium)**
- **Where:** `ZipArchiveManager.swift:239, 250, 655-680`.
- **Problem:** The whole compressed entry is read into memory and a buffer of the *declared* size is allocated, then copied again. There's no output cap and no CRC/size verification.
- **Fix:** stream through `compression_stream` to a `FileHandle`, with a cap.

**1.5 ✔ Edit menu hijacks text editing (High, *likely*)**
- **Where:** `FlowFinderApp.swift:71-118`.
- **Problem:** `CommandGroup(replacing: .pasteboard)` removes the standard `copy:`/`paste:`/`cut:` actions. Menu key equivalents fire before the field editor sees the key, so:
  - in the rename or search field, ⌘V pastes *files* into the folder, or **moves** them if a cut is pending;
  - ⌘C/⌘X replace the clipboard with files;
  - ⌘⌫ (normally "delete to start of line") **moves the file being renamed to the Trash**.
- Only Select All checks for a text first responder.
- **Fix:** in each button, if the first responder is an `NSText`, forward the standard selector (`NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)`), and disable Move to Trash while editing.

**1.6 ✔ Dual/Quad key handlers ignore text fields (Critical)**
- **Where:** `DualPaneView.swift:107-167`, `QuadPaneView.swift:160-218`.
- **Problem:** Unlike `KeyboardNavigable` (`KeyboardHandler.swift:98-102`), these handlers never check the first responder and they consume the key. In search, the path field or rename:
  - Space opens Quick Look;
  - Return opens the selected item instead of committing;
  - arrows move the file selection;
  - ⌘⌫ trashes.
- **Fix:** add the same guard, or better, route the panes through `keyboardNavigable`.

**1.7 ✔ Global keyboard handler (High)**
- **Where:** `KeyboardHandler.swift:17-35, 90`.
- **Problem:** One `activeHandler` for the entire app; whichever view registered last wins, and nothing re-registers on window focus or clears on disappear.
  - With two windows open, arrows and ⌘⌫ in window A act on window B's selection.
  - In the Settings window, the Get Info sheet, the Sparkle window and `NSAlert`s: arrows move the background list, Return opens a file, and Esc is always swallowed (`:129-131`), so the Get Info sheet's Esc-to-close never fires (`FileInfoView.swift:37`).
  - A closed tab's view model stays retained and keeps receiving ⌘⌫ until another view registers.
- **Fix:** act only when `event.window` is the owning window and the first responder is inside its content view. Long term, drop the global monitor for per-view `keyDown` or `.onKeyPress`.

**1.8 ✔ Menu commands go to the wrong pane (High)**
- **Where:** `ContentView.swift:227`.
- **Problem:** `.focusedSceneValue(\.viewModel, viewModel)` always publishes the primary (left / top-left) view model. With the right pane active, Edit › Move to Trash, ⌘D, ⌘A, ⇧⌘N, ⌘R, ⌘[ and the Go menu all hit the left pane, and `DualPaneView.onAppear` auto-selects the left pane's first item (`:72-74`). The toolbar search and back/forward buttons also drive the left pane only.
- **Fix:** publish `activeViewModel`.

**1.9 ✔ Cover Flow double drop / cancelled drag moves (High)**
- **Where:** `CoverFlowView.swift:2939-2983`.
- **Problem:** `performDragOperation` drops and clears `dropTargetIndex`. Then `draggingSession(_:endedAt:operation:)` re-hit-tests and calls `onDropToFolder` again, ignoring `operation`.
  - Option-drag onto a folder cover makes "file" and "file 2".
  - Esc-cancelling over a folder cover still moves the files.
  - Dropping into an overlapping Finder window also moves the file into the cover underneath.
- **Fix:** delete the drop logic from `endedAt`.

**1.10 ✔ Drag semantics (High)**
- **Where:** `FileBrowserViewModel.swift:2902, 3143-3156`; `DropHelper.swift:43-54`; `KeyboardHandler.swift:245, 256-261`.
- **Problem:**
  - Plain drag always moves. Across volumes, the EXDEV fallback copies then calls `removeItem` (a permanent delete, not Trash), whereas Finder copies across volumes.
  - Option is read via `NSEvent.modifierFlags` *after* the async `loadItem`, so releasing Option early turns a copy into a move.
  - The pane `.onDrop` closures show a "+" copy badge but move.
- **Fix:** compute the operation at drop time: same `volumeIdentifierKey` → move, else copy; ⌥ forces copy, ⌘ forces move. Return a matching `DropProposal`.

**1.11 ✔ Copy-into-self (High)**
- **Where:** `paste(to:)` `:2787-2797`, `handleDrop` `:2904-2916`.
- **Problem:** There's no check that the destination is inside the source. ⌘C a folder, open it, ⌘V: it recurses (the reviewer reproduced 1,300+ nested entries). The partial copy stays behind and only a `print` reports it.
- **Fix:** refuse when `dest.standardized.path.hasPrefix(src.path + "/")`, after resolving symlinks.

**1.12 Stale internal clipboard beats the system pasteboard (High)**
- **Where:** `:2755-2766`, `:184-185`, `:2733-2741`.
- **Problem:** Each tab/pane prefers its own `clipboardItems`. Copy X in FlowFinder, copy Y in Finder, ⌘V in FlowFinder: you get X. Cut in tab A, paste in tab B: A keeps a stale cut list, and a later paste there tries to move files that are gone.
- **Fix:** record `NSPasteboard.general.changeCount` at copy/cut and only use the internal list while it still matches. Make the clipboard app-wide.

**1.13 Cover Flow uses global modifier state for selection (High)**
- **Where:** `CoverFlowView.swift:133-139`, called from type-ahead (`:2626-2635`), scroll settle (`:2451`), auto-scroll (`:2693/2699`).
- **Problem:**
  - Typing Shift+R in type-ahead jumps to "Report…" *and* range-selects from the anchor.
  - Shift+wheel (horizontal scroll on a mouse) range-selects.
  - ⌘-drag auto-scroll toggles items.
- **Fix:** pass the triggering event's modifiers explicitly; keyboard navigation, scroll and type-ahead should do a plain select.

**1.14 Cover Flow stops following selection after ⇧-arrow (High)**
- **Where:** `CoverFlowView.swift:1358-1364, 2561-2584`.
- **Problem:** `isExtendingSelection` stays true until a plain arrow or a click on a *different* cover, and `updateItems` ignores incoming indices while it's set. The centred cover then differs from `selectedItems`: Return/Space act on the centred item while ⌘⌫ trashes the list's selection.
- **Fix:** clear the flag after `onExtendSelect` is applied, and always sync on `itemsChanged`.

**1.15 Cover Flow hit-testing (High)**
- **Where:** `CoverFlowView.swift:2301-2347` (also used for drop targets at `:2865-2893` and skim mapping at `:1221-1235`).
- **Problem:** Each cover is tested as a flat full-size rectangle, plus 20 pt padding. Side covers are rotated ~60° and scaled to 0.75, so clicking side cover *k* usually selects *k-1* or *k-2*, and folder drops go to the wrong folder.
- **Fix:** hit-test the presentation layers front-to-back with `layer.hitTest`, or project each cover's outline.

**1.16 Get Info crashes on some photos (Medium)**
- **Where:** `FileInfoView.swift:640-643`.
- **Problem:** ✔ `Int(round(1.0 / exposureTime))` traps when EXIF ExposureTime is 0.
- **Fix:** guard `exposureTime > 0` and check the range.

**1.17 Settings can wipe favorites (Medium-Low)**
- **Where:** `AppSettings.swift:259-266, 306`; `SettingsView.swift:87-91`.
- **Problem:**
  - A decode failure (e.g. an unknown `Kind` after a downgrade) or an empty list falls back to the defaults, and the next write overwrites the user's list.
  - "Reset to Defaults" has no confirmation.
- **Fix:** decode per element, allow an empty list, and confirm before resetting.

---

## 2. Your uncommitted `MasonryView.swift` change

**Verdict: keep it. It fixes a real bug in shipped 1.38, but fix four things before committing.**

**What it fixes:** in 1.38, `recalculateLayout()` inside `onChange(of: items)` and the prefetch closure read the *old* `items`. The deprecated single-parameter `onChange` closure captures the previous render's values, which the reviewer confirmed with a throwaway SwiftUI test. After a filter keystroke, sort change, add or delete, Masonry kept showing the previous list, including deleted files, until a resize. Passing `newItems` through fixes that.

**Fix before committing:**
1. **`oldCount = items.count` (line 446) only works by accident**, because of the same old-capture behaviour. Switch to `.onChange(of: items) { oldItems, newItems in … }`. If you migrate later without changing this, the fast path silently turns off.
2. **`newCount < oldCount` isn't a removal test.** Filter typing and mixed batches (2 removed + 1 added) take this path. Use `Set(newIDs).isSubset(of: oldIDs)` instead.
3. **`suppressNextSelectionScroll` gets stuck.**
   - In the delete flow, the selection `onChange` runs *before* the items `onChange` (it's nested inside it), so the flag is set *after* the scroll it was meant to suppress. It then swallows the user's next arrow-key or click scroll.
   - It also sticks whenever items shrink without a selection change.
   - Clear it on the next runloop turn, or suppress only for a specific expected item ID.
4. **The fast path's `scheduleHydration()` (line 476) reads old `items`**, so it hydrates the file you just deleted. Also, the structural path's prefetch completion (`:498-503`) has no `itemsToken == newToken` guard, so a slow prefetch can resurrect a deleted tile.

Minor: columns are assigned by `index % columnCount`, so everything after the deleted tile still reflows to a different column, despite the "preserving layout state" log message.

---

## 3. Correctness bugs by area

### Navigation & file operations (`FileBrowserViewModel.swift`)
- **✔ Folder watcher dies after returning to a folder.** `stop()` never clears `watchedPath`, so `start()` early-returns on `watchedPath == path` (`:3484`, `:3519-3525`). This triggers after exiting a ZIP, going Back from Photos or /Network, or resuming a background tab. Fix: `watchedPath = nil` in `stop()`.
- **✔ Sidebar, Go menu and pane path fields don't leave archive mode.** `navigateTo`/`navigateToAndSelectCurrent` (`:1839-1887`) never reset `isInsideArchive`/`currentArchiveURL`, so `loadContents` keeps showing the ZIP. Fix: reset as `applyNavigationLocation(.filesystem)` does.
- **✔ Sorting by Date/Size in folders over 400 items uses the old column.**
  - `$sortColumn` publishes in `willSet`, so the sink's `loadContents()` (`:491-511`) reads the *old* sort column from `sortStateSnapshot()` and loads without metadata. Rows then reshuffle as hydration fills dates in.
  - It also does `items = []`, losing scroll on each header click.
  - Fix: build the `SortState` from `newColumn`, or hop to the next runloop.
- **✔ Live updates miss deleted folders and symlinked paths** (`:1170-1250`).
  - Lookups use URL-keyed dictionaries; directory URLs from `contentsOfDirectory` carry a trailing slash, but a deleted folder's FSEvents URL doesn't, so ghost rows remain.
  - FSEvents reports real paths (`/private/tmp`), so `/tmp`, `/var` and symlinked folders never update.
  - Fix: key on `standardizedFileURL.path` and resolve the watched path.
- **Redo never works for file operations, and ⌘Z flip-flops** (`:2399-2410, 2446-2457, 2495-2504, 2541-2551`). Inverse operations are registered asynchronously, after `undo()` returns, so they land as new undo actions and clear the redo stack. Fix: register synchronously inside the undo handler.
- **Errors are silently swallowed** (`:2392, 2439, 2488, 2534, 3114, 2174`; load failures `:767-776`). Rename onto an existing name, Trash on SMB/USB volumes without a Trash, disk full, and a partial copy left behind all only `print`. An unreadable folder looks empty. There's no "Replace / Keep Both / Skip" on conflicts; everything auto-renames.
- **Rename** (`:2960-2972`):
  - "a/b" moves the file into subfolder `a` (Finder maps `/` → `:`).
  - After rename, the selection still points at the old URL.
  - Tab/⇧Tab rename-next uses unsorted `items`, not `filteredItems` (`:2985-2999, 3016-3030`), so it jumps to an unrelated file.
  - The click-to-rename delay of 0.2 s is shorter than the double-click interval (`:158`), so a slow double-click starts a rename.
- **Duplicate in Spotlight results** puts the copy in the search root, not next to the original (`:2939`).
- **Cut + paste in the same folder** produces "x 2" instead of a no-op (`handleDrop` filters this case; `paste` doesn't).
- **One serial `fileOperationQueue`** (`:169`): ⌘C and New Folder queue behind a long copy. A ⌘V during a big copy uses the previous clipboard. There's no progress or cancel.
- **Symlinks and aliases to folders** are treated as files (`FileItem.swift:312-349` gets `isDirectory=false`, type `public.symlink`). Double-click hands off to Finder instead of browsing.
- **Stale per-folder state** (`:2221-2223`): `selectionAnchorIndex`/`lastSelectedIndex` aren't reset on navigation, so the first ⇧-click in a new folder uses the old anchor. A `pendingSelectionURL` that isn't found is never cleared.
- `cancelSearch` doesn't reset `isSearching` (spinner can spin forever); `suspendBackgroundWork` doesn't clear `pendingHydrationURLs`, so rows can be stuck at "--".

### Windows, tabs & commands
- **`.newTab`, `.closeTab`, `.next/previousTab`, `.showGetInfo` and `.focusSearch` are posted with `object: nil`**, and every window reacts (`ContentView.swift:93-120, 231-237`; `FlowFinderApp.swift:36-68`). ⌘T and ⌘W hit all windows and Get Info opens in all windows. ⌘W with one tab does nothing, so the window can't be closed from the keyboard (*likely*). ⌘W in Settings closes tabs in the main windows.
- **`@FocusedValue` on an `ObservableObject`** doesn't observe it, so the enabled state of Copy, Trash, Back and similar items is stale (`FlowFinderApp.swift:6`). Use `@FocusedObject` / `focusedSceneObject`.
- **Sort and column state is one global** (`ListColumnConfigManager.shared`). Navigating any pane re-sorts the others, and the save-on-leave can store pane B's sort under pane A's folder. Back/Forward never saves the current state. (`ListColumnConfig.swift:89-102`, `PerFolderColumnState.swift:129-150`)
- **Arrow keys are consumed with any modifier** (`KeyboardHandler.swift:110-122`, also Dual/Quad):
  - ⌘↑ (Enclosing Folder) never reaches the Go menu.
  - ⌘↓ moves the selection instead of opening.
  - ⇧⌘⌫ (Empty Trash in Finder) trashes the selection.
- **Hard-coded key codes 7/8/9 for X/C/V** (`KeyboardHandler.swift:138-155`, `FileTableView.swift:341-348`). On Dvorak, physical X is ⌘Q, which is swallowed as Cut, so the app can't quit via ⌘Q.
- The list-view keyboard handler captures the `items` array at registration (`KeyboardHandler.swift:75-91`), so after a sort or filter, arrows follow the old order and can select hidden filtered-out items.

### Selection & context menus
- **Right-click collapses a multi-selection to the clicked item**: `ContentView.swift:546-549, 608-635` (icon, masonry, column, dual and quad views), `CoverFlowView.swift:1967-1972`, `FileTableView.swift:1543-1613`. Right-clicking one of 5 selected files and choosing Move to Trash trashes 1. Finder acts on the whole selection when the clicked item is in it.
- **`selectedItems` is a `Set`**, so `.first` is arbitrary. Scroll-to-selection, Quick Look, the Cover Flow sync, and Return/Space with a multi-selection pick a random member (Masonry `:341`, IconGrid `:139`, CoverFlow `:496, 523`, FileListView `:52-94`). Keep an ordered lead/cursor item.
- In the table, `tableViewSelectionDidChange` sets the anchor to the *highest* selected row (`FileTableView.swift:823-826`), so click row 5, ⇧-click row 10, then ⇧↓ selects 10–11.
- "Show Package Contents" is offered for `.app` entries inside ZIPs and navigates to a fake path (`ContentView.swift:521-538`).

### Cover Flow (`CoverFlowView.swift`)
- **Ghost covers** stay on screen when the folder or filter becomes empty; the "transient state" skip at `:1366-1376` never rebuilds.
- **The video preview layer can end up on the wrong cover.**
  - It isn't detached when layers are recycled or pooled, or in `rebuildCovers` (`:1517-1625`).
  - Scrolling never stops it: `scrollWheel` sets `isScrolling` before the stop check at `:2485-2491`, so that code is unreachable.
- **`InlineVideoPreviewManager.onPlayerLayerReady` is a single shared slot** (`:1249-1256`), so with two windows the previews show up in the wrong one. Any Cover Flow going inactive calls `stopAllPreviews()` for all windows.
- **`requestFocus()` steals focus from the search field** (`:2281-2290`). Combined with `.id` including `searchResults.count` (`ContentView.swift:980-994`), every Spotlight batch recreates Cover Flow, which grabs focus mid-typing and discards all thumbnails.
- **ZIP browsing in Cover Flow loops `loadVisibleThumbnails` every 150 ms forever**, because archive items never count as "settled" (`:665-787`).
- **The info panel shows "Zero KB / --" in folders over 400 items**, because URL-only `FileItem` equality means `onChange(of: items)` never sees the hydrated metadata (`:301`).
- **The mouse wheel barely moves.** Line-based deltas are compared against a 20-pixel threshold (about 20 notches per cover), and the custom momentum stacks on top of the system's (`:2357-2530`).
- **The centre cover is blurry on Retina.** Thumbnail pixel size ignores `backingScaleFactor` and actual cover size (`:78-82` vs `:1034-1038`).
- `item.icon.size = 64×64` during a drag mutates the shared cached icon (`:1934-1936`). `onActivityStateChange` writes `@State` inside `updateNSView` (`:967`). No VoiceOver labels; Reduce Motion is ignored; the background gradient doesn't follow a light/dark switch.

### List view (`FileTableView.swift`)
- **Column resize/reorder rebuilds every column on each mouse-move** (`:957-991, 678-687`). Width is part of the snapshot equality, so `setupColumns()` removes and re-adds every `NSTableColumn`, calls `reloadData`, and writes JSON to UserDefaults per pixel.
- **Inline rename races** (`:455-491, 1015-1029, 1297-1311`):
  - The row index is captured 0.15 s before editing starts.
  - `reloadData` runs with no editing guard, so the editing cell can be recycled and `isCurrentlyEditing` stays true. After that, `updateNSView` returns early forever and the table freezes (*likely*).
  - Fix: look up the row by URL inside the block, and add `prepareForReuse`.
- **After a refresh nothing is highlighted**, because new UUIDs don't match `syncSelectionFromViewModel`'s match-by-`id` (`:858-861`), although `selectedItems` still holds the items.
- **The "stale items" heuristic** (`:223-236`) drops genuine same-count updates, e.g. an external rename.
- **The iCloud Status column is always blank.** Cloud status is never hydrated (see below), and saved column configs from before this column existed lack it entirely (`ListColumnConfig.swift:106-139`, no merge of `allCases`).
- Display settings (font/icon size, show tags) don't refresh visible rows. Row height is fixed at 22 while the icon slider goes to 32. The name cell ignores "Show file extensions".
- Ending a rename always refocuses the table (`FileTableCellViews.swift:201-206`), stealing focus from the search field you just clicked.
- Cut dimming compares only count and operation (`:218-221`), so cutting A then B leaves A dimmed.

### Icon grid, Masonry, Column view
- **Masonry `onAppear` computes the layout synchronously** (`MasonryView.swift:320-324` → `ThumbnailCacheManager.swift:160-252`). It reads every image header and does a synchronous `AVURLAsset.tracks` on the main thread, so a 5K-photo folder or an SMB share freezes. On iCloud "Optimize Storage" it may force downloads. The prefetch-first path only runs in `onChange`.
- **The icon grid reverts visible thumbnails to generic icons after any item change** (`IconGridView.swift:249-265`). It clears `thumbnails`/`visibleItemIDs` but nothing re-hydrates the tiles that stay on screen.
- **Thumbnails never upgrade after zoom, resize or quality change.** The loop only loads when `thumbnails[url] == nil`, so the `imageSatisfiesMinimum` check is unreachable (`MasonryView.swift:806-816`, `IconGridView.swift:421-431`).
- **Masonry tiles render the `FileItem` copies stored in `cachedLayout`** (`:183-188, 271`), so hydrated metadata, cloud status and in-place edits never reach them. Store IDs only.
- **Masonry layout isn't recomputed** when `masonryShowFilenames`, `showItemTags` or `iconGridFontSize` change, so images get squashed by the label height.
- **Column view:**
  - Async `loadColumn` appends without a staleness check (`ColumnView.swift:157-175`). Holding ↓ over folders produces several child columns side by side.
  - Sub-columns are static snapshots: delete in column 3 and it stays listed, while the selection jumps to item 0 of the root column.
  - Sub-columns ignore hidden-files, sort and folders-first, and use a case-sensitive `<` sort (`file10` before `file2`).
  - Packages (`.app`, `.rtfd`, `.photoslibrary`) open as columns.
  - `columnSelections` is never synced with `viewModel.selectedItems`.
- **Can't drop into an empty folder.** `EmptyFolderView` has no `.onDrop` (`ContentView.swift:955-956`).
- **The internal-drag flag can stick** (`ViewModifiers.swift:203-249`). Local monitors don't see the mouse-up consumed by the drag session, so external drops onto folders are rejected until the next click (*likely*).
- **File promises** (Mail, Photos, Safari) are only accepted by the sidebar, and there they're received on the main queue.

### Thumbnails (`ThumbnailCacheManager.swift`)
- **Edited files keep their old thumbnail all session.** The cache key uses an mtime cache that's only cleared on add/rename (`:754-776`), and `failedURLs` has no mtime, so an image that failed once (e.g. still downloading) stays a generic icon.
- **`clearForNewFolder()` bumps one global generation counter** and drops every pending completion *without calling it* (`:128-146, 338, 424, 476, 508`). Rows in other windows/panes that were mid-request keep their placeholder forever, because `AsyncListIconView` won't retry.
- **A stale job's `pendingRequests.removeValue(forKey:)`** deletes the *newer* generation's entry for the same key (`:326-329, 454-457, 601-615`), which silently stops the new request.
- `QLThumbnailGenerator` requests are never cancelled. The comment "short timeout" is wrong: `.thumbnail` does a full generation with no timeout.
- **The disk cache has no size cap** (age-pruned only, at launch). It stores PNG via a TIFF round-trip and lives at `~/Library/Caches/CoverFlowThumbnails` (old name, not under the bundle ID). `getCachedThumbnail` does `fileExists` + `NSImage(contentsOf:)` on the main thread.

### Quick Look & inline previews
- **`previewPanelWillClose` is not a real delegate method** (`QuickLookController.swift:226-229`), so closing via the panel's X leaves the key monitors installed and the hidden controller as first responder.
- **QL key monitors swallow arrows, Space and Esc app-wide** while the panel is visible, including in text fields, and ignore modifiers (`:142-192`). The *global* monitor only sees other apps' keys, so it's useless and looks like a keylogger to anyone auditing. Use `previewPanel(_:handle:)` instead.
- **One shared QL controller view lives in one window** (`:8, 70-93`), so QL from a second window can show nothing.
- **Audio previews never stop on navigation, view switch or selection change.** `InlineAudioPreviewManager.stopAllPreviews()` only runs on deactivate/quit (`:99-101`), so a hovered track can loop at 50 % volume with no visible control.
- **Skimming loses the final position.** Throttled seeks are never replayed (`InlineVideoPreviewManager.swift:160-177`).

### Sidebar & volumes (`SidebarView.swift`)
- **Dragging a favorite can move the real folder.** Favorite drags put a `.fileURL` with a `.move` mask on the pasteboard and don't set `InternalDragState` (`:53-54, 145-155`), so dropping one onto a folder in the file area moves the actual folder there.
- **No mount/unmount observation.** New drives appear only after an unrelated refresh. Eject is synchronous on the main thread and plays its sound before success, and panes showing the ejected volume aren't redirected (`:347-391, 896-941`).
- **Favorites are stored as paths** (`AppSettings.swift:439-474`), so renaming or moving the folder greys the favorite out permanently. Use bookmarks.
- Clicking the already-highlighted sidebar row does nothing (`NSOutlineView` only reports changes), so you can't click "Documents" to go back to it from a subfolder, or click an active tag to clear the filter.
- Photos Library sets `viewModel.viewMode = .masonry` without updating `currentViewMode` (`:411-414`), so the toolbar and the active pane disagree in dual/quad.
- `SIDEBAR_DRAG_DROP_DEEP_DIVE.md` is outdated: the NSOutlineView rewrite fixed its main symptoms. Small leftovers: hovering the "Favorites" header inserts at the end, and only the bottom 6 px of a row counts as "insert after".

### iCloud, tags, models
- **iCloud status is never loaded.** `hydrateCloudStatus` is not called from any view (`FileBrowserViewModel.swift:1057-1103`), and metadata hydration rebuilds items with `cloudStatus = nil`. Badges, the column and the Download / Remove Download menu never appear.
- **`CloudStatusManager.statusCache` never expires** (`:12, 89-104`): "Downloading…" sticks for the session. `.waitingForUpload` is never produced, and any path containing `.icloud` is treated as iCloud (`:72`).
- **The tag cache is never invalidated by external changes** (Finder edits never show, even after ⌘R). `setxattr`/`removexattr` results are ignored, yet an undo is registered (`FileItem.swift:35-81`). The tag filter cache key ignores `tagRefreshToken` (`:194-200`).
- `kindDescription` returns "Folder" for `.app`/`.rtfd` (`FileItem.swift:426-453`).
- `formattedDate`/`formattedSize` allocate a formatter per call.
- **Get Info folder size** skips hidden files (`.git` etc.), uses `fileSizeKey` not allocated size, and never checks cancellation, so closing Get Info on `~` leaves a full-disk walk running (`FileInfoView.swift:435-459`).
- ZIP filename decoding: ISO-Latin-1 always succeeds, so the CP1252, Shift-JIS and MacRoman fallbacks never run, and the UTF-8 flag (bit 11) is ignored (`ZipArchiveManager.swift:574-597`). A zero-length name stops parsing of the rest of the directory (`:480-484`).
- Copying out of archives drops Unix modes, exec bits and mtimes. Empty deflated entries fail (`:675`). Any one failure aborts a whole folder copy with no message.

---

## 4. Performance

| Hot spot | Where | Fix |
|---|---|---|
| **Spotlight results** are fully re-sorted *and appended to a log file* on every `filteredItems` read (4+ reads per render); per-update attribute reads on main; `.id` includes `searchResults.count`, so the whole content view is rebuilt per batch | `FileBrowserViewModel.swift:99-140, 342-350, 3266-3324`; `ContentView.swift:955-1010` | Cache by (count, sort state), delete the file logging, drop the count from `.id` |
| **Sidebar `updateNSView`** runs on every active-VM publish and calls `Host.current().localizedName` (can block on DNS), lists `/Volumes` and `~/Pictures`, and resolves symlinks | `SidebarView.swift:67-112, 709-773, 896-941` | Build once; refresh on mount/unmount notifications; cache the host name |
| **`ContentView.init` builds two throwaway `FileBrowserViewModel`s** (FSEvents stream, `PHCachingImageManager`, Combine, a background listing) each time; the App body re-runs on any `AppSettings` change, e.g. dragging a Settings slider | `ContentView.swift:127-128, 217-221` | Create the view model in exactly one place |
| **Every refresh** sets `items = []` and `isLoading = true` (spinner, view rebuild, all thumbnails reloaded) | `:565-566` | Diff in place; `applyDirectoryEventUpdates` already does this |
| **Cover Flow `loadVisibleThumbnails`** does main-thread `resourceValues`, several SHA-256 keys built with `String(format:)`, `fileExists` and `NSImage(contentsOf:)` for ~200 items per arrow-key step (and every 150 ms while pending) | `CoverFlowView.swift:634-700` → `ThumbnailCacheManager.swift:59-94, 754-776` | Key on `FileItem.modificationDate` with a cheap hash; async disk lookup |
| **`.metadataHydrationCompleted` is posted with `object: nil`**, so every table in every window re-sorts 10K items and calls `reloadData` per batch | `FileTableView.swift:171-176, 1015-1029` | Post with `object: viewModel`; reload only the hydrated rows |
| **ZIP central directory** is parsed with 3-5 tiny reads per entry on the main thread; `entriesAtPath` is O(n·d) | `ZipArchiveManager.swift:59-183`, called from `FileBrowserViewModel.swift:2062` | One bounded read off main; build a path index once |
| **`@State [URL: NSImage]` dictionaries** in Masonry, IconGrid, the table and Dual/Quad hold ~1–2K full-size thumbnails outside the NSCache limit; dual/quad never prune | `MasonryView.swift:827-838`, `IconGridView.swift:442-454`, `DualPaneView.swift:535`, `QuadPaneView.swift:587` | Per-tile loader objects; rely on NSCache |
| **Preview managers publish `skimProgress` on every mouse move** and audio `progress` at 30 Hz; every visible grid cell observes them | `VideoPreviewOverlay.swift:188-189`, `InlineAudioPreviewManager.swift:170-180` | `@Observable`, or observe only in the matching overlay |
| **Table thumbnail bookkeeping** is O(n·k) `firstIndex(where:)` per completed thumbnail | `FileTableView.swift:407, 1157-1181` | Maintain a `[URL: Int]` index |
| **Tag reads** happen synchronously in cells and in the sort comparator | `FileTableCellViews.swift:436`, `ListColumnConfig.swift:223-226` | Prefetch tags with metadata |
| **`NSLog` of file names** on every click/selection change (Cmd+A on 10K files builds a huge string) | `FileTableView.swift:21, 43, 365, 812-873`, `CoverFlowView.swift:341, 372, 499`, `[DELETE]`/`[NewFolder]` logs | Use `os_log` with `.private` and keep it off hot paths |
| **SMB subnet scanner** mutates `discoveredHosts` on `resultQueue` while main reads it (a data race), and fires 254 blocking jobs at once | `FileBrowserViewModel.swift:3571, 3697-3702` | Copy on the queue, then publish; limit concurrency |

---

## 5. Root causes: a few structural changes fix most of the above

1. **Per-window command routing.** One global `KeyboardManager` handler, a replaced Edit menu, `focusedSceneValue` bound to the left pane, and `NotificationCenter` posts with `object: nil` together cause §1.5–1.8 and most of "Windows, tabs & commands". Replace them with per-window/per-pane key handling (`keyDown` / `.onKeyPress`), let menu items own the ⌘-shortcuts (forwarding to the field editor when it's first responder), publish `activeViewModel` via `focusedSceneObject`, and scope notifications to the window.
2. **Stable `FileItem` identity plus a content version.** Today every load mints new UUIDs, while `==`/`hash` compare only the URL. The result: views rebuild everything, the table loses selection, and `onChange(of: items)` never sees metadata or mtime changes (stale info panels, stale thumbnails). Reuse IDs by URL across reloads, and give `FileItem` a `version` (mtime, size, cloudStatus, tags) that views and caches key on.
3. **Incremental refresh.** Make `refresh()` and post-operation reloads diff into `items` without `items = []` or `isLoading = true`. You already have the diff logic in `applyDirectoryEventUpdates`.
4. **Per-pane sort state.** Move `sortColumn`/`sortDirection` into each `FileBrowserViewModel` (seeded from the per-folder or default state), and save only on explicit user changes.
5. **An ordered selection model.** Add a lead/cursor item and anchor alongside the `Set`, and pass event modifiers explicitly. This removes `Set.first` randomness, the Cover Flow `isExtendingSelection` desync, and modifier misreads.
6. **One drop/paste pipeline.** A single function that resolves the operation (volume-aware, ⌥/⌘), rejects self/descendant targets, batches into one undo group, offers Replace/Keep Both, and shows errors to the user.
7. **One safe-extraction helper** for ZIPs: path containment, streaming with caps, CRC check, modes, quarantine. Run it off the main thread.
8. **Migrate to the two-parameter `onChange`** (~70 warnings). The deprecated form's old-value capture is the direct cause of the Masonry and `AsyncListIconView` (reloads at the *old* size) bugs, and probably others not yet found.

---

## 6. Release & repo hygiene

- **`RELEASING.md` manual process** says to bump only `MARKETING_VERSION`. Sparkle compares `CFBundleVersion` (`CURRENT_PROJECT_VERSION`), and the doc never mentions `sign_update` or updating the appcast. A release done by the doc reaches no Sparkle user. (The appcast itself is fine: https feed, EdDSA key present, and both 1.37/1.38 signatures verify against `SUPublicEDKey`.)
- **`scripts/notarize.sh`:**
  - Sparkle tools are downloaded with `curl -L` without `--fail` or a checksum, then given access to the EdDSA private key (`:114-126`).
  - It uses fixed `/tmp` paths (`:132-137, 257-279`).
  - `commit_appcast` commits anything already staged and always pushes `main` regardless of the current branch (`:366-377`).
  - No `set -o pipefail`. Consider having it check that `CFBundleVersion` is higher than the appcast's latest.
- **Repo:** three release zips (12.8 MB) are tracked and `*.zip` isn't ignored; `output/` (Playwright artifacts) isn't ignored. `Package.resolved` is gitignored while Sparkle is only pinned to `minimumVersion 2.0.0`, so builds aren't reproducible (it currently resolves 2.9.0).
- **Info.plist:**
  - The copyright still says 2024.
  - `GENERATE_INFOPLIST_FILE = NO`, so the `INFOPLIST_KEY_*` build settings (including `CFBundleDisplayName = "Flow Finder"` and `LSApplicationCategoryType`) are silently ignored. They're absent from the built app.
- `AUTO_UPDATE_REPORT.md:53` still says the app isn't signed or notarized.

## 7. Compiler warnings (Xcode-beta, Debug)

- ~70 × deprecated `onChange(of:perform:)` (see §5.8).
- Swift 6 isolation errors-in-waiting:
  - `FileBrowserViewModel.swift:619` calls main-actor `sortStateRequiresMetadata` from the background load.
  - `:3328`/`:3334`: delegate conformances cross into main-actor code.
  - `FileTableCoordinator` → `FileNameCellViewDelegate`.
  - Non-Sendable `AVPlayerLayer` captures (`InlineVideoPreviewManager.swift:222, 257`).
  - `FinderSoundEffects.swift:166/176` (harmless: the observer runs on `.main`).
- Deprecated sync AVAsset APIs (`ThumbnailCacheManager.swift:225-231`). Switch to `load(.naturalSize)` etc., which also fixes the main-thread stall in Masonry.
- Unused values: `zip64EocdDiskNumber`, `bootVolumePath`, and unused `sync` results.

## 8. Status of the Feb 2025 `REVIEW_REPORT.md`

| Old item | Status |
|---|---|
| Date Created sorted by mtime | **Fixed** |
| Two parallel sort systems | **Fixed** (`SortOption` removed), but replaced by one *global* config (§5.4) |
| `#` encoding in history | **Fixed** (`NavigationLocation.archive`) |
| Archive ops on virtual URLs | **Mostly fixed** (beep/filter); archive Quick Look is now disabled; "Show Package Contents" is still offered |
| Three overlapping Quick Look implementations | **Fixed**; one shared controller, with new issues (§3 Quick Look) |
| Cover Flow QL not reloading on selection change | **Fixed** |
| Thumbnail cache thread-safety | **Fixed** (`queue.sync` + locks); a logic race remains (§3 Thumbnails) |
| Dual/Quad ignore sort | **Fixed** |
| `syncSelection` collapsing multi-selection | **Mostly fixed**; now picks an arbitrary `Set.first` |
| Shift-select semantics | **Fixed** |

## 9. Feature & UX ideas

1. Conflict dialog (Replace / Keep Both / Skip / Apply to All) and a progress panel with Cancel for long copies.
2. Per-window state restoration (`SceneStorage`), native window tabs or tab drag-reorder, ⌘1–9 for tabs.
3. Missing Finder shortcuts: ⇧⌘G Go to Folder (with autocomplete), ⇧⌘. toggle hidden files, ⌘K Connect to Server, ⌘E Eject, ⌥⌘⌫ Delete Immediately, Put Back, Copy as Pathname.
4. Dual-pane power features: Tab to switch panes, F5/F6 copy/move to the other pane, multi-item drag in panes.
5. Archives: Quick Look and drag-out via on-demand extraction, nested ZIPs, tar/gz/7z.
6. Search: explicit scope (This Mac / this folder), folder-scan fallback for unindexed volumes, kind/date filters, "Show in Enclosing Folder".
7. Sidebar: Eject buttons on rows, "Add to Sidebar", favorites context menu, Spotlight-backed tag views (not just a filter on the current folder), free space in the status bar.
8. Cover Flow polish: `CALayer` subclass per cover (typed properties, transform-aware hit-testing), Retina-aware thumbnail sizing, display-link momentum, Reduce Motion, VoiceOver labels, QL zoom from the centre cover (`sourceFrameOnScreen`).

## 10. Dead code worth deleting

- **FileBrowserViewModel:** `writePhotoAsset`, `networkServiceURL(for:)`, `needsCloudStatusHydration`, `moveSelectedItemsToTrash`, `displayPath`, `smbScanComplete` (write-only), plus the computed-and-discarded first-batch selection logic (`:631-657`).
- **MasonryView:** `aspectRatio(for:)`, `tileHeight`, `estimatedItemHeight`, `initialEstimatedHeight`, `updateAspectRatio`, `handleDrop`, `handleDoubleClick`, `layoutNeedsUpdate` (write-only), `aspectRatios`.
- **ThumbnailCacheManager:** `generateArchiveThumbnail` (unreachable).
- **DropHelper / ViewModifiers:** `processDroppedItems` (which also has a data race), `SelectionHelper`, `MultiFileDrag*`, `SelectionBackground`, `ItemDropTargetStyle`, `ActivePaneBorder`, `cutItemOpacity`.
- **ContentView:** `searchModeBinding`, `LiquidGlassWindowConfigurator`.
- **FileInfoView:** `FileInfoWindow`.
- **FileItem:** the `Transferable` conformance.
- **CoverFlowView:** `FileListSection.onSelect`/`onOpen`, the unreachable stop block at `:2485-2491`.
- **VideoPreviewOverlay:** `VideoPreviewModifier`.
- **FileTableView:** empty-space handling in `TableClipView`/`TableScrollView`, and most of `KeyboardTableView.keyDown` (shadowed by the global monitor).

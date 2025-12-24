Sidebar Favorites Drag/Drop Deep Dive
=====================================

Scope
-----
This document focuses on the Favorites sidebar drag/drop behavior in
`CoverFlowFinder/CoverFlowFinder/Views/SidebarView.swift`, especially the
insert-line and row-highlight logic. The goal is to make the drag experience
Finder-like: always show either an insertion line (between rows) or a row
highlight (drop onto a favorite), with no dead zones.

Current Implementation (as of now)
----------------------------------
File: `CoverFlowFinder/CoverFlowFinder/Views/SidebarView.swift`

Key pieces:
- `FavoriteRowFrameKey` collects row frames for favorites.
- `favoriteRowFrames: [String: CGRect]` stores those frames.
- `FavoritesSectionDropDelegate` is attached to the Favorites section and
  computes a `DropTarget` from `DropInfo.location` and row frames.
- Visuals are driven by:
  - `dropIndicator` (insertion line)
  - `dropTargetedFavoriteID` (row highlight)

Drop target decision (simplified):
1. Iterate rows in order (top to bottom).
2. If pointer is above a row -> show line before that row.
3. If pointer is inside a row:
   - Internal drag or non-droppable row -> line.
   - External drag -> line near top, highlight otherwise.
4. If pointer below last row -> line at end.

Observed Symptoms
-----------------
- The insertion line sticks at the bottom regardless of pointer position.
- Sometimes neither line nor highlight shows (dead zone).
- The plus icon appears in some zones (copy drop), which may or may not be
  desired.

Likely Root Causes
------------------
1) Coordinate space mismatch.
   - `DropInfo.location` is local to the view that owns `onDrop`.
   - Row frames are stored relative to a named coordinate space.
   - If those spaces are not the same, location comparisons fail and the
     logic defaults to "bottom line" (targetID = nil).

2) `List` / `Section` layout and virtualization.
   - `List` is backed by AppKit (`NSTableView`/`NSOutlineView`), which may
     not give stable row geometry to SwiftUI.
   - Row backgrounds can be clipped, and separators are not part of any
     row frame. This creates gaps that your row-frame algorithm never sees.

3) Dead zones between rows.
   - Even if coordinates match, if there is space between row frames, the
     location can fall into "no row", and your logic defaults to line at end
     (or none). Finder always chooses a nearest insert point or row.

4) `DropDelegate` called for the container only.
   - If the drop target is the section container, `DropInfo.location` is
     reported in the section's coordinate system. If row frames are in a
     different coordinate system (List, row, or global), comparisons will
     be wrong.

How to Fix It Properly (three viable paths)
-------------------------------------------

Option A: Keep SwiftUI List, fix coordinate space + target math
--------------------------------------------------------------
This is the minimal-change path.

Key requirements:
1) Ensure row frames and `DropInfo.location` are in the same coordinate space.
2) Compute a target for every Y value inside the favorites section.
3) Explicitly map gaps to the nearest insert line.

Recommended approach:
- Attach `onDrop` to the same view that defines the coordinate space used
  by `FavoriteRowFrameKey`.
- If the drop target remains the section, then define the coordinate space
  on that same section and capture frames in that space.
- If the coordinate space must be on the `List`, move `onDrop` to the `List`
  and filter by favorites section frame.

To avoid dead zones, compute "gap boundaries":
- Sort row frames by `minY`.
- For each row, compute a "line zone" at the top (e.g. 6-10px).
- For space between rows:
  - Use the midpoint between row[i].maxY and row[i+1].minY.
  - If location.y is above that midpoint -> line before row[i+1].
  - If below -> highlight row[i+1] (or line before it if you want always
    insert between).

Example decision logic (pseudo):
```
let lineZone = 8.0
for each row in order:
  if y < row.minY { return line(before: row) }
  if y <= row.maxY {
    if y - row.minY <= lineZone { return line(before: row) }
    else { return highlight(row) }
  }
// y after last row
return line(at end)
```

If you want "always line OR highlight":
- Ensure any gap between rows is mapped to one of the two states.
- Do NOT allow a "none" branch.

Also:
- For internal favorite reordering, it is safer to move items only in
  `performDrop` rather than continuously in `dropUpdated`.
- For external drop onto a row, use `handleDrop` and allow move/copy based
  on modifier keys (Option = copy). This matches Finder.

Option B: Replace List with ScrollView + LazyVStack for Favorites
-----------------------------------------------------------------
This avoids List virtualization and gives full control over geometry.

Benefits:
- Stable row frames; no hidden separators.
- Easy to measure each row with `GeometryReader`.
- `onDrop` attached to a single known container.

Steps:
1) Build a sidebar favorites section using `ScrollView` + `LazyVStack`.
2) Use `PreferenceKey` to collect row frames in a named coordinate space.
3) Implement the same line/highlight logic as above.

Tradeoff: you lose some List-specific styling and selection behavior, but
you gain reliable drag/drop behavior.

Option C: Use NSOutlineView / NSTableView (most Finder-like)
------------------------------------------------------------
Finder uses AppKit controls for this behavior. If you want true Finder-like
drag indicators, consider wrapping an `NSOutlineView` or `NSTableView` with
`NSViewRepresentable`.

Benefits:
- Built-in insertion line handling.
- Native drag/drop delegate callbacks:
  - `outlineView(_:validateDrop:proposedItem:proposedChildIndex:)`
  - `outlineView(_:acceptDrop:item:childIndex:)`
- Reliable reorder and insertion behavior.

Tradeoff: bigger refactor, but this is the most robust long-term solution.

Debugging Plan (quick sanity checks)
------------------------------------
1) Log row frame count:
   - If `rowFrames` is empty or too small, the `PreferenceKey` is not firing.
2) Log drop locations and row frames in the same space:
   - If coordinates are in different spaces, Y values will be off by hundreds.
3) Add a temporary overlay to show row frames:
   - Draw translucent rectangles over rows.
   - Draw the current drop y-position as a horizontal line.
4) Temporarily force a line/highlight for every drop update to confirm that
   the state updates and UI binding are working.

Why the Plus Icon Appears
-------------------------
The plus icon is shown when your `DropProposal` returns `.copy`. If you want
Finder-like behavior:
- Internal reorder -> `.move`
- External drop onto a favorite -> `.move` by default, `.copy` if Option key
  is held (matching your `handleDrop` behavior).
- External drop into Favorites list (line) -> `.copy` is fine if this means
  "add shortcut", but that may feel weird. Consider `.move` or `.link` if
  you want a "favorites shortcut" mental model.

External References (needs network access)
------------------------------------------
I cannot fetch external examples without network access. If you allow it, I
can gather and cite specific URLs and code samples. Suggested targets:
- Apple docs: `DropDelegate`, `DropInfo`, `List` drag/drop, `NSOutlineView`
  drag/drop delegates.
- GitHub examples: "SwiftUI reorderable list drag drop", "NSOutlineView
  drag drop Swift".

Proposed Minimal Fix Path
-------------------------
If you want to keep SwiftUI List:
1) Ensure the `onDrop` target and row-frame coordinate space match.
2) Treat every Y position inside Favorites as either:
   - line before row X, or
   - highlight row X.
3) Map gaps between rows to a line target (midpoint rule).
4) Move items only on `performDrop` for internal reorder.

If that still feels unreliable, move to Option B or Option C.

Notes
-----
This document is based on a local code review only. If you want external
references and sample code links, please allow network access and I will
append them here.

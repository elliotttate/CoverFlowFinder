# Development

This document is a quick map of the codebase and the conventions used by the app.
It is geared toward experienced macOS developers who want to extend or refactor the project.

## Quick Start

- Open `CoverFlowFinder.xcodeproj` in Xcode and build/run.
- CLI build:
  ```bash
  xcodebuild -project CoverFlowFinder.xcodeproj -scheme CoverFlowFinder -configuration Debug -destination "platform=macOS" build
  ```

## Project Structure

- `CoverFlowFinder/Models`
  - `FileItem` and `FileTagManager` (file metadata and tag caching)
  - `ListColumnConfigManager` (column visibility and `SortState`)
  - `ThumbnailCacheManager` (memory/disk thumbnail caching)
  - `ZipArchiveManager` (ZIP parsing and extraction)
- `CoverFlowFinder/ViewModels`
  - `FileBrowserViewModel` (navigation, selection, clipboard, archive state, file ops)
- `CoverFlowFinder/Views`
  - SwiftUI view modes, plus AppKit-backed Cover Flow
  - `QuickLookControllerView` (single Quick Look controller)

## Data Flow and Conventions

- `FileBrowserViewModel` is the single source of truth for navigation and selection.
- Use `viewModel.filteredItems` for view data. It applies search/tag filters and global sort.
- Sorting comes from `ListColumnConfigManager` via `SortState`. Do not re-sort in views.
- Quick Look goes through `QuickLookControllerView.shared` and always uses
  `viewModel.previewURL(for:)` to support archive extraction.
- Archive items are virtual:
  - `FileItem.isFromArchive` means `item.url` is not a real filesystem URL.
  - Use `item.archiveURL` + `item.archivePath` or `viewModel.previewURL(for:)`.
  - File operations are intentionally disabled for archive items.

## File Operations

- File operations run on `fileOperationQueue` in `FileBrowserViewModel`.
- Use `moveItemWithFallback` for cut/move to handle cross-volume moves.
- UI updates must be dispatched back to the main actor.

## View Mode Implementation Guide

1. Add a new case to `ViewMode` in `CoverFlowFinder/ViewModels/FileBrowserViewModel.swift`.
2. Add the view mode picker entry in `CoverFlowFinder/Views/ContentView.swift`.
3. Update `TabContentWrapper.mainContentView` to render the new view.
4. Use `viewModel.filteredItems` as input, not `items`.
5. Use `viewModel.handleSelection` for click selection (Shift/Cmd support).
6. Update Quick Look on selection changes using `viewModel.previewURL(for:)`.
7. Disable drag/drop and file operations for `item.isFromArchive`.

## Metadata and Kind Labels

- Kind strings are centralized in `FileItem.kindDescription`.
- Tags are cached in `FileTagManager`; call `invalidateCache(for:)` on tag changes.

## Quick Look

- `QuickLookControllerView` is the only Quick Look panel controller.
- Do not introduce additional `QLPreviewPanel` handlers in view-specific code.


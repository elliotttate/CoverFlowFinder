import SwiftUI
import AppKit
import QuickLookThumbnailing
import Quartz

struct ColumnView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    let items: [FileItem]

    /// Selected item ("path item") of each column, keyed by the column's folder URL
    @State private var columnSelections: [URL: FileItem] = [:]
    /// Sub-columns to the right of the root column; `columns[i]` is depth i + 1
    @State private var columns: [ColumnData] = []
    @State private var activeColumnIndex: Int = 0
    /// Load tokens, folder watchers and selection bookkeeping (never publishes)
    @StateObject private var columnState = ColumnViewState()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                // First column with current items
                SingleColumnView(
                    items: items,
                    selectedItem: columnSelections[viewModel.currentPath],
                    columnURL: viewModel.currentPath,
                    viewModel: viewModel,
                    onSelect: { item in
                        selectInColumn(depth: 0, item: item)
                        columnState.notePushed(viewModel.selectedItems)
                    },
                    onDoubleClick: { item in
                        viewModel.openItem(item)
                    }
                )

                // Additional columns for subdirectories
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    Divider()
                    SingleColumnView(
                        items: column.items,
                        selectedItem: columnSelections[column.url],
                        columnURL: column.url,
                        viewModel: viewModel,
                        onSelect: { item in
                            selectInColumn(depth: index + 1, item: item)
                            columnState.notePushed(viewModel.selectedItems)
                        },
                        onDoubleClick: { item in
                            viewModel.openItem(item)
                        }
                    )
                }

                // Preview column for selected file
                if appSettings.columnShowPreview,
                   let lastSelection = lastSelectedItem,
                   !ColumnBrowsing.isBrowsableFolder(lastSelection) {
                    Divider()
                    PreviewColumn(item: lastSelection)
                        .id(lastSelection.url)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .keyboardNavigable(
            onUpArrow: { shift in navigateInActiveColumn(by: -1, extend: shift) },
            onDownArrow: { shift in navigateInActiveColumn(by: 1, extend: shift) },
            onLeftArrow: { _ in navigateToParentColumn() },
            onRightArrow: { _ in navigateToChildColumn() },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() },
            onDelete: { deleteSelection() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste(to: activeColumnURL) },
            onTypeAhead: { searchString in jumpToMatch(searchString) }
        )
        .onAppear {
            columnState.watcher.onChange = { url in
                MainActor.assumeIsolated {
                    reloadColumn(at: url)
                }
            }
            columnState.watcher.watch(columns.map(\.url))
            // Show the view model's selection (and the folder it's in) when the view appears
            syncSelectionFromViewModel(force: true)
        }
        .onDisappear {
            columnState.watcher.watch([])
            columnState.invalidateLoads(fromDepth: 0)
            // When leaving column view (e.g. switching view modes), navigate to the
            // deepest selected folder so other views show where the user drilled into.
            // Skip this during normal folder loads while we remain in Columns mode.
            if viewModel.viewMode != .columns, let deepestFolder = deepestSelectedFolder {
                if deepestFolder != viewModel.currentPath {
                    viewModel.navigateTo(deepestFolder)
                }
            }
        }
        .onChange(of: columns.map(\.url)) { _, urls in
            // Watch the folders shown in sub-columns (the view model watches the root)
            columnState.watcher.watch(urls)
        }
        .onChange(of: viewModel.selectedItems) { _, _ in
            syncSelectionFromViewModel(force: false)
        }
        .onChange(of: items) { oldItems, newItems in
            reconcileSelection(depth: 0, oldItems: oldItems, newItems: newItems)
            resolvePendingSelection()
        }
        .onChange(of: items.map(\.contentVersion)) { _, _ in
            // Keep the root selection (preview column) on the current metadata
            refreshSelection(depth: 0, in: items)
        }
        .onChange(of: appSettings.showHiddenFiles) { _, _ in
            reloadAllSubColumns()
        }
        .onChange(of: appSettings.foldersFirst) { _, _ in
            reloadAllSubColumns()
        }
        .onChange(of: columnConfig.sortStateSnapshot()) { _, _ in
            reloadAllSubColumns()
        }
    }

    /// The URL of the folder represented by the currently active column.
    private var activeColumnURL: URL {
        columnURL(atDepth: activeColumnIndex) ?? viewModel.currentPath
    }

    private var lastSelectedItem: FileItem? {
        if let last = columns.last, let selection = columnSelections[last.url] {
            return selection
        }
        return columnSelections[viewModel.currentPath]
    }

    /// The deepest folder the user has drilled into via sub-columns.
    private var deepestSelectedFolder: URL? {
        // Walk columns in reverse to find the deepest selected directory
        if let column = columns.last {
            if let selection = columnSelections[column.url], ColumnBrowsing.isBrowsableFolder(selection) {
                return selection.url
            }
            // The column itself represents a folder the user drilled into
            return column.url
        }
        // No sub-columns — check if root selection is a directory
        if let rootSelection = columnSelections[viewModel.currentPath], ColumnBrowsing.isBrowsableFolder(rootSelection) {
            return rootSelection.url
        }
        return nil
    }

    // MARK: - Columns

    private func columnURL(atDepth depth: Int) -> URL? {
        if depth == 0 { return viewModel.currentPath }
        return columns.indices.contains(depth - 1) ? columns[depth - 1].url : nil
    }

    private func columnItems(atDepth depth: Int) -> [FileItem]? {
        if depth == 0 { return items }
        return columns.indices.contains(depth - 1) ? columns[depth - 1].items : nil
    }

    private func depth(ofColumn url: URL) -> Int? {
        if url == viewModel.currentPath { return 0 }
        return columns.firstIndex { $0.url == url }.map { $0 + 1 }
    }

    /// Select `item` in the column at `depth`, make that column active and show the folder's
    /// contents to its right (packages are files). Does not touch the view model's selection.
    private func selectInColumn(depth: Int, item: FileItem) {
        guard let url = columnURL(atDepth: depth) else { return }
        let previous = columnSelections[url]
        columnSelections[url] = item
        if let index = columnItems(atDepth: depth)?.firstIndex(where: { $0.url == item.url }) {
            columnState.selectionIndex[url] = index
        }
        activeColumnIndex = depth

        if ColumnBrowsing.isBrowsableFolder(item) {
            // Keep the open child column when the same folder is selected again
            let isAlreadyOpen = previous?.url == item.url && columns.count > depth && columns[depth].url == item.url
            if !isAlreadyOpen {
                openColumn(for: item.url, atDepth: depth + 1)
            }
        } else {
            truncateColumns(keepingThrough: depth)
        }
        updateQuickLook(for: item)
    }

    /// Remove the columns deeper than `depth` (and forget their pending loads).
    private func truncateColumns(keepingThrough depth: Int) {
        columnState.invalidateLoads(fromDepth: depth + 1)
        if columns.count > depth {
            for column in columns[depth...] {
                columnSelections.removeValue(forKey: column.url)
            }
            columns = Array(columns.prefix(depth))
        }
        if activeColumnIndex > depth {
            activeColumnIndex = depth
        }
    }

    private func openColumn(for folderURL: URL, atDepth depth: Int) {
        truncateColumns(keepingThrough: depth - 1)
        loadColumn(for: folderURL, atDepth: depth, reloading: false)
    }

    private func reloadColumn(at url: URL) {
        guard let depth = depth(ofColumn: url), depth > 0 else { return }
        loadColumn(for: url, atDepth: depth, reloading: true)
    }

    private func reloadAllSubColumns() {
        for column in columns {
            reloadColumn(at: column.url)
        }
    }

    /// Lists a folder in the background. Each depth has one current request: a newer open or a
    /// truncation invalidates older ones, so holding ↓ over folders never stacks columns.
    private func loadColumn(for url: URL, atDepth depth: Int, reloading: Bool) {
        let token = UUID()
        columnState.loadTokens[depth] = token
        let showHiddenFiles = appSettings.showHiddenFiles
        let foldersFirst = appSettings.foldersFirst
        let sortState = columnConfig.sortStateSnapshot()
        let existingIDs: [URL: UUID] = reloading
            ? Dictionary(columnItems(atDepth: depth)?.map { ($0.url, $0.id) } ?? [], uniquingKeysWith: { first, _ in first })
            : [:]

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? ColumnBrowsing.loadItems(
                in: url,
                showHiddenFiles: showHiddenFiles,
                sortState: sortState,
                foldersFirst: foldersFirst,
                reusingIDs: existingIDs
            )

            DispatchQueue.main.async {
                guard columnState.loadTokens[depth] == token else { return }
                columnState.loadTokens.removeValue(forKey: depth)

                if reloading {
                    applyReload(of: url, atDepth: depth, loaded: loaded)
                    return
                }
                guard let loaded else { return }
                // Replace whatever is at this depth (and drop anything deeper)
                columns = Array(columns.prefix(depth - 1)) + [ColumnData(url: url, items: loaded)]
                resolvePendingSelection()
            }
        }
    }

    private func applyReload(of url: URL, atDepth depth: Int, loaded: [FileItem]?) {
        guard columns.indices.contains(depth - 1), columns[depth - 1].url == url else { return }
        guard let loaded else {
            // The folder itself is gone: close it and everything to its right. Its parent column
            // reloads too and moves its selection.
            truncateColumns(keepingThrough: depth - 1)
            return
        }
        let old = columns[depth - 1]
        columns[depth - 1] = ColumnData(id: old.id, url: url, items: loaded)
        reconcileSelection(depth: depth, oldItems: old.items, newItems: loaded)
        resolvePendingSelection()
    }

    /// After a column's contents changed: keep its selection when the item still exists (with
    /// fresh metadata); otherwise select the neighbour in that column, like Finder.
    private func reconcileSelection(depth: Int, oldItems: [FileItem], newItems: [FileItem]) {
        guard let url = columnURL(atDepth: depth), let selected = columnSelections[url] else { return }
        if newItems.contains(where: { $0.url == selected.url }) {
            refreshSelection(depth: depth, in: newItems)
            return
        }

        if depth < activeColumnIndex {
            // A folder on the drilled path vanished: close what showed its contents (the
            // selection was in there)
            columnSelections.removeValue(forKey: url)
            truncateColumns(keepingThrough: depth)
            pushSelection([])
            return
        }
        guard depth == activeColumnIndex else { return }

        // Prefer the view model's own choice when it already points into this column
        let selectedURLs = Set(viewModel.selectedItems.map(\.url))
        if let lead = newItems.first(where: { selectedURLs.contains($0.url) }) {
            selectInColumn(depth: depth, item: lead)
            return
        }

        let fallbackIndex = oldItems.firstIndex { $0.url == selected.url } ?? columnState.selectionIndex[url] ?? 0
        let removed = Set(oldItems.map(\.url)).subtracting(newItems.map(\.url))
        if let neighbor = ColumnBrowsing.neighbor(in: newItems, removing: removed.union([selected.url]), fallbackIndex: fallbackIndex) {
            selectInColumn(depth: depth, item: neighbor)
            pushSelection([neighbor], index: newItems.firstIndex(of: neighbor))
            // The view model may still announce its own post-delete selection; keep ours.
            if depth > 0 {
                columnState.deleteGuard = .init(columnURL: url, deletedURLs: removed, expires: Date().addingTimeInterval(2))
            }
        } else {
            columnSelections.removeValue(forKey: url)
            truncateColumns(keepingThrough: depth)
            pushSelection([])
        }
    }

    /// Swap the column's selected item for the current copy (metadata for the preview column).
    private func refreshSelection(depth: Int, in columnItems: [FileItem]) {
        guard let url = columnURL(atDepth: depth),
              let selected = columnSelections[url],
              let fresh = columnItems.first(where: { $0.url == selected.url }),
              fresh.contentVersion != selected.contentVersion || fresh.id != selected.id else { return }
        columnSelections[url] = fresh
    }

    // MARK: - Selection sync with the view model

    /// Set the view model's selection and remember that we did (so the sync ignores it).
    private func pushSelection(_ selection: Set<FileItem>, index: Int? = nil) {
        viewModel.selectedItems = selection
        if let index {
            viewModel.lastSelectedIndex = index
            viewModel.selectionAnchorIndex = index
        }
        columnState.notePushed(selection)
    }

    /// Mirror selection changes made elsewhere (delete, Select All, menus, another view) into
    /// the columns.
    private func syncSelectionFromViewModel(force: Bool) {
        let selection = viewModel.selectedItems
        let selectedURLs = Set(selection.map(\.url))
        if !force && columnState.pushedSelectionURLs == selectedURLs { return }
        columnState.pushedSelectionURLs = selectedURLs
        columnState.pendingSelectionURLs = nil

        // After deleting in a sub-column the view model selects an item of the root column.
        // Keep the selection in the column the user was working in instead.
        if activeColumnIndex > 0, let activeItems = columnItems(atDepth: activeColumnIndex),
           let activeURL = columnURL(atDepth: activeColumnIndex),
           let current = columnSelections[activeURL],
           !selection.contains(where: { selected in activeItems.contains { $0.url == selected.url } }) {
            // New items of this folder (e.g. just renamed) that the column hasn't listed yet:
            // select them after its reload instead.
            if !selection.isEmpty,
               selection.allSatisfy({ $0.url.deletingLastPathComponent().path == activeURL.path }) {
                columnState.pendingSelectionURLs = selectedURLs
                return
            }
            let deleteGuard = columnState.deleteGuard.flatMap { $0.columnURL == activeURL && $0.expires > Date() ? $0 : nil }
            let deleted = deleteGuard?.deletedURLs ?? []
            let currentIsGone = deleted.contains(current.url) || !FileManager.default.fileExists(atPath: current.url.path)
            if deleteGuard != nil || currentIsGone {
                columnState.deleteGuard = nil
                let fallbackIndex = activeItems.firstIndex { $0.url == current.url } ?? columnState.selectionIndex[activeURL] ?? 0
                let removed = currentIsGone ? deleted.union([current.url]) : deleted
                let neighbor = currentIsGone
                    ? ColumnBrowsing.neighbor(in: activeItems, removing: removed, fallbackIndex: fallbackIndex) {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    : current
                if let neighbor {
                    selectInColumn(depth: activeColumnIndex, item: neighbor)
                    pushSelection([neighbor], index: activeItems.firstIndex(of: neighbor))
                } else {
                    columnSelections.removeValue(forKey: activeURL)
                    truncateColumns(keepingThrough: activeColumnIndex)
                    pushSelection([])
                }
                return
            }
        }

        guard !selection.isEmpty else {
            // Nothing selected: clear the active column's selection and what it opened
            if let activeURL = columnURL(atDepth: activeColumnIndex) {
                columnSelections.removeValue(forKey: activeURL)
            }
            truncateColumns(keepingThrough: activeColumnIndex)
            return
        }

        // Find the column showing the selection: the active one first, then deepest to root
        var depths = [activeColumnIndex]
        depths += (0...columns.count).reversed().filter { $0 != activeColumnIndex }
        for depth in depths {
            guard let url = columnURL(atDepth: depth), let columnItems = columnItems(atDepth: depth) else { continue }
            let selectedInColumn = columnItems.filter { selectedURLs.contains($0.url) }
            guard !selectedInColumn.isEmpty else { continue }

            // Lead item: the column's current one if still selected, else the first in display order
            let lead = selectedInColumn.first { $0.url == columnSelections[url]?.url } ?? selectedInColumn[0]
            if columnSelections[url]?.url != lead.url || activeColumnIndex != depth {
                selectInColumn(depth: depth, item: lead)
            } else {
                refreshSelection(depth: depth, in: columnItems)
            }
            return
        }

        // Not shown yet (e.g. a new folder before the refresh): try again when columns change
        columnState.pendingSelectionURLs = selectedURLs
    }

    private func resolvePendingSelection() {
        guard let pending = columnState.pendingSelectionURLs,
              pending == Set(viewModel.selectedItems.map(\.url)) else { return }
        syncSelectionFromViewModel(force: true)
    }

    private func deleteSelection() {
        if activeColumnIndex > 0, let activeURL = columnURL(atDepth: activeColumnIndex) {
            // The view model picks the next item from the root column; we keep it in this one
            columnState.deleteGuard = .init(
                columnURL: activeURL,
                deletedURLs: Set(viewModel.selectedItems.map(\.url)),
                expires: Date().addingTimeInterval(5)
            )
        }
        viewModel.deleteSelectedItems()
    }

    // MARK: - Keyboard Navigation

    private func navigateInActiveColumn(by offset: Int, extend: Bool = false) {
        let (columnItems, columnURL) = getActiveColumnData()
        guard !columnItems.isEmpty else { return }

        let currentIndex: Int
        if let selected = columnSelections[columnURL],
           let index = columnItems.firstIndex(where: { $0.url == selected.url }) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(columnItems.count - 1, currentIndex + offset))
        let newItem = columnItems[newIndex]

        if extend {
            columnSelections[columnURL] = newItem
            columnState.selectionIndex[columnURL] = newIndex
            // Use the active column's items for range selection
            viewModel.selectRange(to: newIndex, in: columnItems)
            columnState.notePushed(viewModel.selectedItems)
            updateQuickLook(for: newItem)
        } else {
            // Updates subsequent columns (opens folders, closes them for files)
            selectInColumn(depth: activeColumnIndex, item: newItem)
            pushSelection([newItem], index: newIndex)
        }
    }

    private func navigateToParentColumn() {
        if activeColumnIndex > 0 {
            activeColumnIndex -= 1
            // Reset anchor to the selected item in the parent column
            let (columnItems, columnURL) = getActiveColumnData()
            if let sel = columnSelections[columnURL],
               let idx = columnItems.firstIndex(where: { $0.url == sel.url }) {
                pushSelection([sel], index: idx)
                updateQuickLook(for: sel)
            }
        }
    }

    private func navigateToChildColumn() {
        let (_, columnURL) = getActiveColumnData()
        if let selected = columnSelections[columnURL], ColumnBrowsing.isBrowsableFolder(selected) {
            if activeColumnIndex < columns.count {
                activeColumnIndex += 1
                let column = columns[activeColumnIndex - 1]
                // Select first item in new column if nothing selected
                if columnSelections[column.url] == nil, let firstItem = column.items.first {
                    selectInColumn(depth: activeColumnIndex, item: firstItem)
                    pushSelection([firstItem], index: 0)
                } else if let sel = columnSelections[column.url],
                          let idx = column.items.firstIndex(where: { $0.url == sel.url }) {
                    // Entering a column with an existing selection
                    pushSelection([sel], index: idx)
                    updateQuickLook(for: sel)
                }
            }
        }
    }

    private func getActiveColumnData() -> ([FileItem], URL) {
        if activeColumnIndex == 0 {
            return (items, viewModel.currentPath)
        } else if activeColumnIndex <= columns.count {
            let column = columns[activeColumnIndex - 1]
            return (column.items, column.url)
        }
        return ([], viewModel.currentPath)
    }

    /// The lead selected item: the active column's selection, else the view model's
    private var activeSelectedItem: FileItem? {
        if let selection = columnSelections[activeColumnURL], viewModel.selectedItems.contains(selection) {
            return selection
        }
        return viewModel.primarySelectedItem
    }

    private func openSelectedItem() {
        if let selectedItem = activeSelectedItem {
            viewModel.openItem(selectedItem)
        }
    }

    private func jumpToMatch(_ searchString: String) {
        guard !searchString.isEmpty else { return }
        let lowercased = searchString.lowercased()
        let (columnItems, _) = getActiveColumnData()

        if let matchIndex = columnItems.firstIndex(where: { $0.name.lowercased().hasPrefix(lowercased) }) {
            let matchItem = columnItems[matchIndex]
            selectInColumn(depth: activeColumnIndex, item: matchItem)
            pushSelection([matchItem], index: matchIndex)
        }
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection { [self] offset in
            navigateInActiveColumn(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item)
    }
}

struct ColumnData: Identifiable {
    let id: UUID
    let url: URL
    let items: [FileItem]

    init(id: UUID = UUID(), url: URL, items: [FileItem]) {
        self.id = id
        self.url = url
        self.items = items
    }
}

/// Column view bookkeeping that must not trigger renders (it never publishes).
final class ColumnViewState: ObservableObject {
    struct DeleteGuard {
        let columnURL: URL
        let deletedURLs: Set<URL>
        let expires: Date
    }

    let watcher = ColumnDirectoryWatcher()
    /// Current load request per column depth
    var loadTokens: [Int: UUID] = [:]
    /// The selection this view last set on the view model
    var pushedSelectionURLs: Set<URL>?
    /// A view-model selection not visible in any column yet
    var pendingSelectionURLs: Set<URL>?
    var deleteGuard: DeleteGuard?
    /// Last known index of each column's selection (to pick a neighbour when it disappears)
    var selectionIndex: [URL: Int] = [:]

    func notePushed(_ selection: Set<FileItem>) {
        pushedSelectionURLs = Set(selection.map(\.url))
    }

    func invalidateLoads(fromDepth depth: Int) {
        loadTokens = loadTokens.filter { $0.key < depth }
    }
}

/// Watches the folders shown in sub-columns and reports changes (coalesced) on the main queue.
final class ColumnDirectoryWatcher {
    var onChange: ((URL) -> Void)?
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var pendingNotifications: [URL: DispatchWorkItem] = [:]

    func watch(_ urls: [URL]) {
        let wanted = Set(urls)
        for (url, source) in sources where !wanted.contains(url) {
            source.cancel()
            sources.removeValue(forKey: url)
            pendingNotifications.removeValue(forKey: url)?.cancel()
        }
        for url in wanted where sources[url] == nil {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .link],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.folderChanged(url)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources[url] = source
        }
    }

    private func folderChanged(_ url: URL) {
        // Coalesce bursts (a copy of many files) into one reload
        pendingNotifications[url]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNotifications.removeValue(forKey: url)
            self.onChange?(url)
        }
        pendingNotifications[url] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    deinit {
        for source in sources.values {
            source.cancel()
        }
        for work in pendingNotifications.values {
            work.cancel()
        }
    }
}

/// Folder listing and selection helpers for the column view.
enum ColumnBrowsing {
    private static let packageCacheLock = NSLock()
    private static var packageCache: [String: Bool] = [:]

    /// Folders open as columns; packages (.app, .rtfd, .photoslibrary…) behave like files.
    static func isBrowsableFolder(_ item: FileItem) -> Bool {
        guard item.isDirectory else { return false }
        if item.isFromArchive || !item.url.isFileURL { return true }
        return !isPackage(item.url)
    }

    static func isPackage(_ url: URL) -> Bool {
        let path = url.path
        packageCacheLock.lock()
        if let cached = packageCache[path] {
            packageCacheLock.unlock()
            return cached
        }
        packageCacheLock.unlock()

        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage)
            ?? NSWorkspace.shared.isFilePackage(atPath: path)
        packageCacheLock.lock()
        if packageCache.count > 5000 {
            packageCache.removeAll()
        }
        packageCache[path] = isPackage
        packageCacheLock.unlock()
        return isPackage
    }

    /// Contents of a sub-column, filtered and sorted like the main file list.
    static func loadItems(
        in folder: URL,
        showHiddenFiles: Bool,
        sortState: SortState,
        foldersFirst: Bool,
        reusingIDs existingIDs: [URL: UUID] = [:]
    ) throws -> [FileItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey, .isPackageKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )
        let fileItems = contents.map { url in
            // Warm the package cache from the prefetched value
            _ = isPackage(url)
            return FileItem(url: url, id: existingIDs[url] ?? UUID())
        }
        return ListColumnConfigManager.sortedItems(fileItems, sortState: sortState, foldersFirst: foldersFirst)
    }

    /// The item to select after `removed` items disappear from a column: the first remaining
    /// item at or after the first removed one, else the closest one before it (Finder behaviour).
    /// `fallbackIndex` is used when the removed items are no longer in `items`.
    static func neighbor(
        in items: [FileItem],
        removing removed: Set<URL>,
        fallbackIndex: Int,
        exists: (URL) -> Bool = { _ in true }
    ) -> FileItem? {
        guard !items.isEmpty else { return nil }
        let start = items.firstIndex { removed.contains($0.url) } ?? min(max(0, fallbackIndex), items.count - 1)
        let isCandidate: (FileItem) -> Bool = { !removed.contains($0.url) && exists($0.url) }
        if let after = items[start...].first(where: isCandidate) {
            return after
        }
        return items[..<start].last(where: isCandidate)
    }
}

struct SingleColumnView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let items: [FileItem]
    /// This column's selected item; in parent columns it's the folder on the drilled path
    let selectedItem: FileItem?
    let columnURL: URL
    @ObservedObject var viewModel: FileBrowserViewModel
    let onSelect: (FileItem) -> Void
    let onDoubleClick: (FileItem) -> Void
    @State private var dropTargetedItemID: UUID?
    @State private var isColumnDropTargeted = false

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        let isSelected = viewModel.selectedItems.contains(item)
                        // Parent columns keep the drilled-into folder highlighted (inactive style)
                        let isPathItem = !isSelected && selectedItem?.url == item.url
                        ColumnRowView(
                            item: item,
                            viewModel: viewModel,
                            isSelected: isSelected
                        )
                        .id(item.url)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .background(
                            dropTargetedItemID == item.id
                                ? Color.accentColor.opacity(0.3)
                                : (isSelected
                                    ? Color.accentColor.opacity(0.2)
                                    : (isPathItem ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .opacity(dropTargetedItemID == item.id ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                        .internalDrag(url: item.url)
                        .onDrop(of: [.fileURL], delegate: UnifiedFolderDropDelegate(
                            item: item,
                            viewModel: viewModel,
                            dropTargetedItemID: $dropTargetedItemID
                        ))
                        .instantTap(
                            id: item.id,
                            onSingleClick: {
                                if let index = items.firstIndex(of: item) {
                                    let modifiers = NSEvent.modifierFlags
                                    viewModel.handleSelection(
                                        item: item,
                                        index: index,
                                        in: items,
                                        withShift: modifiers.contains(.shift),
                                        withCommand: modifiers.contains(.command)
                                    )
                                }
                                onSelect(item)
                            },
                            onDoubleClick: {
                                onDoubleClick(item)
                            }
                        )
                        .contextMenu {
                            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                viewModel.renamingURL = item.url
                            }
                        }
                    }
                }
            }
            .frame(width: appSettings.columnWidthValue)
            .onDrop(of: [.fileURL], delegate: ColumnBackgroundDropDelegate(
                columnURL: columnURL,
                viewModel: viewModel,
                dropTargetedItemID: $dropTargetedItemID,
                isColumnDropTargeted: $isColumnDropTargeted
            ))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isColumnDropTargeted && dropTargetedItemID == nil ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contextMenu {
                Button("New Folder") {
                    viewModel.createNewFolder()
                }

                if viewModel.canPaste {
                    Divider()
                    Button("Paste") {
                        viewModel.paste(to: columnURL)
                    }
                }

                Divider()

                Button("Refresh") {
                    viewModel.refresh()
                }

                Button("Show in Finder") {
                    viewModel.showInFinder()
                }
            }
            .onAppear {
                // Scroll to selected item when view appears (e.g., when switching view modes)
                if let selected = selectedItem {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollProxy.scrollTo(selected.url, anchor: .center)
                    }
                }
            }
            .onChange(of: selectedItem?.url) { _, selectedURL in
                if let selectedURL {
                    withAnimation {
                        scrollProxy.scrollTo(selectedURL)
                    }
                }
            }
        }
    }
}

struct ColumnRowView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            AsyncListIconView(item: item, size: appSettings.columnIconSizeValue)

            // Cloud status badge (shown inline after icon)
            if let cloudStatus = item.cloudStatus, cloudStatus.shouldShowBadge {
                CloudStatusBadgeView(status: cloudStatus, size: 12)
            }

            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.columnFont, alignment: .leading, lineLimit: 1)

            if appSettings.showItemTags, !item.tags.isEmpty {
                TagDotsView(tags: item.tags)
            }

            Spacer()

            if ColumnBrowsing.isBrowsableFolder(item) {
                Image(systemName: "chevron.right")
                    .font(appSettings.columnDetailFont)
                    .foregroundColor(.secondary)
            }
        }
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
    }
}

struct PreviewColumn: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.displayScale) private var displayScale
    let item: FileItem

    @State private var thumbnail: NSImage?
    @State private var thumbnailRequest: QLThumbnailGenerator.Request?
    @State private var isHovering = false

    private var previewSize: CGSize {
        CGSize(width: 200, height: 200)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Thumbnail or icon
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: previewSize.width, maxHeight: previewSize.height)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                } else {
                    Image(nsImage: item.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                }
            }
            .videoPreviewOnHover(item: item, isHovering: $isHovering, size: previewSize)
            .onHover { hovering in
                isHovering = hovering
            }
            .padding(.top, 20)

            // File info
            VStack(spacing: 8) {
                Text(item.displayName(showFileExtensions: appSettings.showFileExtensions))
                    .font(appSettings.columnPreviewTitleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 100)

                VStack(alignment: .leading, spacing: 4) {
                    InfoRow(label: "Kind", value: item.isDirectory ? "Folder" : kindDescription)
                    InfoRow(label: "Size", value: item.formattedSize)
                    InfoRow(label: "Modified", value: item.formattedDate)
                }
                .font(appSettings.columnDetailFont)
            }

            Spacer()
        }
        .frame(width: appSettings.columnPreviewWidthValue)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadThumbnail()
        }
        .onChange(of: item.contentVersion) { _, _ in
            // Edited in place: show the new contents
            loadThumbnail()
        }
        .onDisappear {
            // The selection moved on (this view is recreated per item)
            cancelThumbnailRequest()
            if isHovering {
                InlineVideoPreviewManager.shared.cancelPreview()
                isHovering = false
            }
        }
    }

    private var kindDescription: String {
        item.kindDescription
    }

    private func cancelThumbnailRequest() {
        if let thumbnailRequest {
            QLThumbnailGenerator.shared.cancel(thumbnailRequest)
            self.thumbnailRequest = nil
        }
    }

    private func loadThumbnail() {
        cancelThumbnailRequest()
        // Sized for what's on screen: the preview area at the display's scale
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: previewSize,
            scale: max(1, displayScale),
            representationTypes: .all
        )
        thumbnailRequest = request

        // Called once per representation (icon, low quality, full thumbnail)
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, _, _ in
            guard let thumbnail else { return }
            let image = thumbnail.nsImage
            DispatchQueue.main.async {
                guard thumbnailRequest === request else { return }
                self.thumbnail = image
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .lineLimit(1)
        }
    }
}

// MARK: - Column Background Drop Delegate

struct ColumnBackgroundDropDelegate: DropDelegate {
    let columnURL: URL
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?
    @Binding var isColumnDropTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        // Don't accept drops during internal drag operations
        if InternalDragState.shared.isDragging { return false }
        return !viewModel.isInsideArchive && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        // Don't show drop target during internal drags
        if InternalDragState.shared.isDragging { return }
        if dropTargetedItemID == nil {
            isColumnDropTargeted = true
        }
    }

    func dropExited(info: DropInfo) {
        isColumnDropTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Don't show drop indicator during internal drags
        if InternalDragState.shared.isDragging {
            isColumnDropTargeted = false
            return DropProposal(operation: .forbidden)
        }
        guard !viewModel.isInsideArchive else {
            isColumnDropTargeted = false
            return DropProposal(operation: .forbidden)
        }
        // Show column highlight when not over a folder
        if dropTargetedItemID == nil {
            isColumnDropTargeted = true
        } else {
            isColumnDropTargeted = false
        }
        let operation: DropOperation = FileDropOperation(modifierFlags: NSEvent.modifierFlags) == .copy ? .copy : .move
        return DropProposal(operation: operation)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Don't accept drops during internal drag operations
        if InternalDragState.shared.isDragging { return false }
        // If hovering over a folder, that delegate handles it
        guard dropTargetedItemID == nil, !viewModel.isInsideArchive else { return false }

        // Resolve copy/move now, from the modifiers held at drop time
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        let providers = info.itemProviders(for: [.fileURL])
        let collector = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                if let data = data as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.append(url)
                }
                group.leave()
            }
        }
        let destination = columnURL
        let viewModel = viewModel
        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else { return }
            viewModel.handleDrop(urls: urls, to: destination, operation: operation)
        }
        return true
    }
}

/// Thread-safe accumulator for URLs delivered by item providers.
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        collected.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

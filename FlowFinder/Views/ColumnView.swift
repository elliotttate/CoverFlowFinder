import SwiftUI
import AppKit
import Combine
import QuickLookThumbnailing
import Quartz

struct ColumnView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.browserWindow) private var browserWindow
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    /// The view model's `itemsRevision` for `items`. FileItem equality is identity, so after an
    /// in-place update (metadata or iCloud status loaded) the new `items` compares equal to the old
    /// and SwiftUI keeps the old array: the preview and badges never showed what was loaded.
    /// A new revision makes the view take the new array.
    var itemsRevision = 0

    /// Selected item ("path item") of each column, keyed by the column's folder URL
    @State private var columnSelections: [URL: FileItem] = [:]
    /// Sub-columns to the right of the root column; `columns[i]` is depth i + 1
    @State private var columns: [ColumnData] = []
    @State private var activeColumnIndex: Int = 0
    /// Load tokens, folder watchers and selection bookkeeping (never publishes)
    @StateObject private var columnState = ColumnViewState()

    /// Scroll targets in the horizontal scroll view (sub-columns use their IDs)
    private static let rootColumnID = "column-root"
    private static let previewColumnID = "column-preview"

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    // First column with current items
                    singleColumn(depth: 0, items: items, url: viewModel.currentPath)
                        .id(Self.rootColumnID)

                    // Additional columns for subdirectories
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        HStack(spacing: 0) {
                            Divider()
                            singleColumn(depth: index + 1, items: column.items, url: column.url)
                        }
                        .id(column.id)
                    }

                    // Preview column for selected file
                    if let previewItem {
                        HStack(spacing: 0) {
                            Divider()
                            PreviewColumn(item: previewItem)
                                .id(previewItem.url)
                        }
                        .id(Self.previewColumnID)
                    }
                }
            }
            // Drilling in shows the new column (Finder scrolls it into view)
            .onChange(of: rightmostColumnID) { _, id in
                DispatchQueue.main.async {
                    withAnimation { scrollProxy.scrollTo(id, anchor: .trailing) }
                }
            }
            .onChange(of: activeColumnIndex) { _, depth in
                let id: AnyHashable = depth == 0 ? AnyHashable(Self.rootColumnID) : columns.indices.contains(depth - 1) ? AnyHashable(columns[depth - 1].id) : rightmostColumnID
                DispatchQueue.main.async {
                    withAnimation { scrollProxy.scrollTo(id) }
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
            // ⌘A selects the active column's items (the view model's are the root column's)
            onSelectAll: { selectAllInActiveColumn() },
            onTypeAhead: { searchString in jumpToMatch(searchString) }
        )
        .onAppear {
            columnState.watcher.watch(columns.map(\.url))
            // Show the view model's selection (and the folders it's in) when the view appears
            syncSelectionFromViewModel(force: true, restoringColumns: true)
            loadRootSelectionMetadata()
        }
        .onDisappear {
            columnState.watcher.watch([])
            columnState.invalidateLoads(fromDepth: 0)
            // When leaving column view (e.g. switching view modes), navigate to the
            // deepest selected folder so other views show where the user drilled into.
            // Skip this during normal folder loads while we remain in Columns mode.
            if viewModel.viewMode != .columns {
                showDeepestFolderInViewModel()
            }
        }
        // Folder watcher events (delivered through the state object: no closure holds this view)
        .onReceive(columnState.folderChanges) { url in
            reloadColumn(at: url)
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
        .onChange(of: columnSelections[viewModel.currentPath]?.url) { _, _ in
            loadRootSelectionMetadata()
        }
        .onChange(of: appSettings.showHiddenFiles) { _, _ in
            reloadAllSubColumns()
        }
        .onChange(of: appSettings.foldersFirst) { _, _ in
            reloadAllSubColumns()
        }
        .onChange(of: viewModel.sortState) { _, _ in
            reloadAllSubColumns()
        }
    }

    private func singleColumn(depth: Int, items: [FileItem], url: URL) -> some View {
        SingleColumnView(
            items: items,
            selectedItem: columnSelections[url],
            columnURL: url,
            viewModel: viewModel,
            onClick: { item, index, modifiers in
                handleClick(depth: depth, item: item, index: index, modifiers: modifiers)
            },
            onDoubleClick: { item in
                viewModel.openItem(item)
            },
            onRowAppear: { item in
                rowAppeared(item, depth: depth)
            },
            onNewFolder: { createNewFolder(inColumnAt: depth) },
            onRefresh: { refreshColumn(atDepth: depth) }
        )
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

    /// The file shown in the preview column (the deepest selection, when it isn't a folder)
    private var previewItem: FileItem? {
        guard appSettings.columnShowPreview, let item = lastSelectedItem,
              !ColumnBrowsing.isBrowsableFolder(item) else { return nil }
        return item
    }

    /// The rightmost column: the preview, else the deepest column
    private var rightmostColumnID: AnyHashable {
        if previewItem != nil { return Self.previewColumnID }
        if let last = columns.last { return last.id }
        return Self.rootColumnID
    }

    /// Navigates the view model to the deepest folder the user has drilled into via sub-columns.
    private func showDeepestFolderInViewModel() {
        if let column = columns.last {
            if let selection = columnSelections[column.url], ColumnBrowsing.isBrowsableFolder(selection) {
                show(selection, listedAt: nil)
            } else {
                // The column itself represents a folder the user drilled into
                show(column.folder, listedAt: column.url)
            }
        } else if let rootSelection = columnSelections[viewModel.currentPath], ColumnBrowsing.isBrowsableFolder(rootSelection) {
            // No sub-columns: the root selection is a folder
            show(rootSelection, listedAt: nil)
        }
    }

    /// Shows `folder` in the view model. `contentsURL` is where its column listed it (an alias's
    /// original); nil when it hasn't been listed.
    private func show(_ folder: FileItem, listedAt contentsURL: URL?) {
        if let archiveFolder = ColumnBrowsing.archiveColumnSource(for: folder) {
            // A folder inside the archive being browsed: go there within the archive
            if viewModel.isInsideArchive, viewModel.currentArchiveURL == archiveFolder.archiveURL {
                viewModel.navigateInArchive(to: archiveFolder.path)
            }
        } else if folder.isAliasFile && contentsURL == nil {
            // Resolves the alias, then navigates to its original
            viewModel.openItem(folder)
        } else {
            let url = contentsURL ?? folder.url
            if url != viewModel.currentPath {
                viewModel.navigateTo(url)
            }
        }
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
    /// - Parameter opensFolder: false when it's one of several selected items (no column to the right).
    private func selectInColumn(depth: Int, item: FileItem, opensFolder: Bool = true) {
        guard let url = columnURL(atDepth: depth) else { return }
        let previous = columnSelections[url]
        columnSelections[url] = item
        if let index = columnItems(atDepth: depth)?.firstIndex(where: { $0.url == item.url }) {
            columnState.selectionIndex[url] = index
        }
        activeColumnIndex = depth

        if opensFolder, ColumnBrowsing.isBrowsableFolder(item) {
            // Keep the open child column when the same folder is selected again
            let isAlreadyOpen = previous?.url == item.url && columns.count > depth && columns[depth].folder.url == item.url
            if !isAlreadyOpen {
                openColumn(for: item, atDepth: depth + 1)
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

    private func openColumn(for folder: FileItem, atDepth depth: Int) {
        truncateColumns(keepingThrough: depth - 1)
        loadColumn(for: folder, atDepth: depth, reloading: false)
    }

    private func reloadColumn(at url: URL) {
        guard let depth = depth(ofColumn: url), depth > 0 else { return }
        loadColumn(for: columns[depth - 1].folder, atDepth: depth, reloading: true)
    }

    private func reloadAllSubColumns() {
        for column in columns {
            reloadColumn(at: column.url)
        }
    }

    /// Lists a folder (or a folder inside a ZIP archive) in the background. Each depth has one
    /// current request: a newer open or a truncation invalidates older ones, so holding ↓ over
    /// folders never stacks columns.
    /// - Parameter rename: a folder the column is inside was renamed: its items keep their IDs
    ///   under their new paths.
    private func loadColumn(for folder: FileItem, atDepth depth: Int, reloading: Bool, movedBy rename: (from: URL, to: URL)? = nil) {
        let archiveFolder = ColumnBrowsing.archiveColumnSource(for: folder)
        let token = UUID()
        columnState.loadTokens[depth] = token
        let showHiddenFiles = appSettings.showHiddenFiles
        let foldersFirst = appSettings.foldersFirst
        let sortState = viewModel.sortState
        let existingIDs: [URL: UUID] = reloading
            ? Dictionary((columnItems(atDepth: depth) ?? []).map { item in
                (rename.flatMap { ColumnBrowsing.url(item.url, movedFrom: $0.from, to: $0.to) } ?? item.url, item.id)
            }, uniquingKeysWith: { first, _ in first })
            : [:]

        DispatchQueue.global(qos: .userInitiated).async {
            let listing: ColumnBrowsing.Listing?
            var contentsURL = folder.url
            if let archiveFolder {
                // Archive entries keep their IDs while the archive is unchanged
                listing = (try? ColumnBrowsing.loadArchiveItems(
                    in: archiveFolder.archiveURL,
                    at: archiveFolder.path,
                    showHiddenFiles: showHiddenFiles,
                    sortState: sortState,
                    foldersFirst: foldersFirst
                )).map { ColumnBrowsing.Listing(items: $0, fileIDs: [:]) }
            } else if let resolved = ColumnBrowsing.contentsURL(of: folder) {
                contentsURL = resolved
                listing = try? ColumnBrowsing.loadListing(
                    in: resolved,
                    showHiddenFiles: showHiddenFiles,
                    sortState: sortState,
                    foldersFirst: foldersFirst,
                    reusingIDs: existingIDs
                )
            } else {
                // An alias whose original can't be found
                listing = nil
            }
            // The folder's own identity, to follow it when it's renamed
            let folderID = archiveFolder == nil ? FileIdentity(folder.url) : nil

            DispatchQueue.main.async {
                guard columnState.loadTokens[depth] == token else { return }
                columnState.loadTokens.removeValue(forKey: depth)

                if reloading {
                    applyReload(of: folder.url, atDepth: depth, listing: listing, folderID: folderID)
                    return
                }
                guard let listing else { return }
                // Replace whatever is at this depth (and drop anything deeper)
                columns = Array(columns.prefix(depth - 1)) + [ColumnData(
                    folder: folder, url: contentsURL, items: listing.items, fileIDs: listing.fileIDs, folderID: folderID
                )]
                loadCloudStatus(ofColumnAt: depth)
                resolvePendingSelection()
            }
        }
    }

    private func applyReload(of folderURL: URL, atDepth depth: Int, listing: ColumnBrowsing.Listing?, folderID: FileIdentity?) {
        guard columns.indices.contains(depth - 1), columns[depth - 1].folder.url == folderURL else { return }
        let old = columns[depth - 1]
        guard let listing else {
            // The folder itself is gone. Renamed, its parent column's reload moves the columns to
            // the new name; otherwise (a second look later) close it and everything to its right.
            // Its parent column reloads too and moves its selection.
            if columnState.missingFolders.insert(old.url).inserted {
                let url = old.url
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak columnState] in
                    columnState?.folderChanges.send(url)
                }
            } else {
                columnState.missingFolders.remove(old.url)
                truncateColumns(keepingThrough: depth - 1)
            }
            return
        }
        columnState.missingFolders.remove(old.url)
        // iCloud badges stay until their status is reloaded
        let statuses = Dictionary(old.items.compactMap { item in item.cloudStatus.map { (item.url, $0) } }, uniquingKeysWith: { first, _ in first })
        let items = statuses.isEmpty ? listing.items : listing.items.map { item in
            statuses[item.url].map { item.withCloudStatus($0) } ?? item
        }
        columns[depth - 1] = ColumnData(id: old.id, folder: old.folder, url: old.url, items: items, fileIDs: listing.fileIDs, folderID: folderID ?? old.folderID)
        reconcileSelection(depth: depth, oldItems: old.items, newItems: items, oldIDs: old.fileIDs, newIDs: listing.fileIDs)
        loadCloudStatus(ofColumnAt: depth)
        resolvePendingSelection()
    }

    /// Sub-columns list their folders themselves: their items' iCloud status (badges, preview) is
    /// loaded in the background.
    private func loadCloudStatus(ofColumnAt depth: Int) {
        guard columns.indices.contains(depth - 1) else { return }
        let column = columns[depth - 1]
        guard CloudStatusManager.shared.isInICloud(column.url) else { return }
        let urls = column.items.compactMap { $0.cloudStatus == nil && !$0.isFromArchive ? $0.url : nil }
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var statuses: [URL: CloudSyncStatus] = [:]
            for url in urls {
                statuses[url] = CloudStatusManager.shared.getStatus(for: url)
            }
            DispatchQueue.main.async {
                guard let index = columns.firstIndex(where: { $0.id == column.id }), columns[index].url == column.url else { return }
                let current = columns[index]
                var changed = false
                let items = current.items.map { item -> FileItem in
                    guard let status = statuses[item.url], item.cloudStatus != status else { return item }
                    changed = true
                    return item.withCloudStatus(status)
                }
                guard changed else { return }
                columns[index] = ColumnData(id: current.id, folder: current.folder, url: current.url, items: items, fileIDs: current.fileIDs, folderID: current.folderID)
                refreshSelection(depth: index + 1, in: items)
            }
        }
    }

    /// After a column's contents changed: keep its selection when the item still exists (with
    /// fresh metadata) or was renamed; otherwise select the neighbour in that column, like Finder.
    /// `oldIDs`/`newIDs` are the listings' file identities (none for the root column).
    private func reconcileSelection(
        depth: Int,
        oldItems: [FileItem],
        newItems: [FileItem],
        oldIDs: [URL: FileIdentity] = [:],
        newIDs: [URL: FileIdentity] = [:]
    ) {
        guard let url = columnURL(atDepth: depth), let selected = columnSelections[url] else { return }
        if newItems.contains(where: { $0.url == selected.url }) {
            refreshSelection(depth: depth, in: newItems)
            return
        }

        // Renamed (the same file under a new name): it stays selected, and the columns showing
        // its contents stay open
        let oldURLs = Set(oldItems.map(\.url))
        let added = newItems.filter { !oldURLs.contains($0.url) }
        if let renamed = renamedItem(selected, atDepth: depth, oldIDs: oldIDs, among: added, newIDs: newIDs) {
            applyRename(atDepth: depth, from: selected, to: renamed)
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

    // MARK: - Renames

    /// The item among `candidates` (items that just appeared in the column at `depth`) that is
    /// `item` under a new name: the same file. Identities come from the column listings, or from
    /// the open column for a folder on the drilled path; the few candidates without one are read.
    private func renamedItem(
        _ item: FileItem,
        atDepth depth: Int,
        oldIDs: [URL: FileIdentity],
        among candidates: [FileItem],
        newIDs: [URL: FileIdentity]
    ) -> FileItem? {
        guard !candidates.isEmpty, !item.isFromArchive else { return nil }
        var identity = oldIDs[item.url]
        if identity == nil, columns.indices.contains(depth), columns[depth].folder.url == item.url {
            identity = columns[depth].folderID
        }
        guard let identity else { return nil }
        let unlisted = candidates.filter { newIDs[$0.url] == nil }
        guard unlisted.count <= 32 else { return nil }
        return candidates.first { candidate in
            !candidate.isFromArchive && (newIDs[candidate.url] ?? FileIdentity(candidate.url)) == identity
        }
    }

    /// `old`, selected in the column at `depth`, was renamed to `new`: select it under its new
    /// name, move the columns showing its contents (and their selections) along, and point the
    /// view model's selection at the new paths.
    private func applyRename(atDepth depth: Int, from old: FileItem, to new: FileItem) {
        guard let url = columnURL(atDepth: depth) else { return }
        columnSelections[url] = new
        if let index = columnItems(atDepth: depth)?.firstIndex(where: { $0.url == new.url }) {
            columnState.selectionIndex[url] = index
        }

        if columns.indices.contains(depth), columns[depth].folder.url == old.url {
            for index in depth..<columns.count {
                let column = columns[index]
                let folder = index == depth ? new : Self.item(column.folder, movedFrom: old.url, to: new.url)
                // An alias's column lists its original, elsewhere: that one keeps its path
                let columnURL = ColumnBrowsing.url(column.url, movedFrom: old.url, to: new.url) ?? column.url
                if columnURL != column.url {
                    if let selection = columnSelections.removeValue(forKey: column.url) {
                        columnSelections[columnURL] = Self.item(selection, movedFrom: old.url, to: new.url)
                    }
                    if let selectionIndex = columnState.selectionIndex.removeValue(forKey: column.url) {
                        columnState.selectionIndex[columnURL] = selectionIndex
                    }
                    columnState.missingFolders.remove(column.url)
                }
                // The items are relisted under their new paths right away
                columns[index] = ColumnData(id: column.id, folder: folder, url: columnURL, items: column.items, fileIDs: column.fileIDs, folderID: column.folderID)
            }
            for index in depth..<columns.count {
                loadColumn(for: columns[index].folder, atDepth: index + 1, reloading: true, movedBy: (old.url, new.url))
            }
        }

        // The view model's selection follows: the renamed item, or items inside a renamed folder
        var moved = false
        let selection = Set(viewModel.selectedItems.map { selected -> FileItem in
            if selected.url == old.url {
                moved = true
                return new
            }
            let item = Self.item(selected, movedFrom: old.url, to: new.url)
            if item.url != selected.url {
                moved = true
            }
            return item
        })
        if moved {
            pushSelection(selection, index: columnItems(atDepth: activeColumnIndex)?.firstIndex { selection.contains($0) })
        }
    }

    /// `item` under its new path after the folder it's in (or it) moved from `old` to `new`.
    private static func item(_ item: FileItem, movedFrom old: URL, to new: URL) -> FileItem {
        guard let url = ColumnBrowsing.url(item.url, movedFrom: old, to: new) else { return item }
        return FileItem(url: url, id: item.id)
    }

    /// The view model selected the renamed copy of a folder on the drilled path (it selects items
    /// it renamed): the columns showing that folder's contents move along instead of closing.
    private func followRenamedPathFolder(to selection: Set<FileItem>) {
        guard selection.count == 1, let selected = selection.first else { return }
        for depth in 0..<columns.count {
            guard let url = columnURL(atDepth: depth),
                  let pathItem = columnSelections[url],
                  pathItem.url != selected.url,
                  columns[depth].folder.url == pathItem.url,
                  let listed = columnItems(atDepth: depth),
                  listed.contains(where: { $0.url == selected.url }),
                  !listed.contains(where: { $0.url == pathItem.url }) else { continue }
            let newIDs = depth > 0 ? columns[depth - 1].fileIDs : [:]
            if let renamed = renamedItem(pathItem, atDepth: depth, oldIDs: [:], among: [selected], newIDs: newIDs) {
                applyRename(atDepth: depth, from: pathItem, to: renamed)
            }
            return
        }
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

    /// Mirror selection changes made elsewhere (delete, menus, another view) into the columns.
    /// - Parameter restoringColumns: the view just appeared: a selection inside folders below the
    ///   root opens the columns down to it.
    private func syncSelectionFromViewModel(force: Bool, restoringColumns: Bool = false) {
        let selection = viewModel.selectedItems
        let selectedURLs = Set(selection.map(\.url))
        if !force && columnState.pushedSelectionURLs == selectedURLs { return }
        columnState.pushedSelectionURLs = selectedURLs
        columnState.pendingSelectionURLs = nil
        // All the columns down to a restored selection are open now
        let restoredPathIsOpen = columnState.pendingPath?.isEmpty == true
        columnState.pendingPath = nil

        followRenamedPathFolder(to: selection)

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

            // Lead item: the column's current one if still selected, else the first in display order.
            // Several selected items show no column to their right (Finder).
            let lead = selectedInColumn.first { $0.url == columnSelections[url]?.url } ?? selectedInColumn[0]
            let isSingle = selectedInColumn.count == 1
            if columnSelections[url]?.url != lead.url || activeColumnIndex != depth {
                selectInColumn(depth: depth, item: lead, opensFolder: isSingle)
            } else {
                refreshSelection(depth: depth, in: columnItems)
                if !isSingle {
                    truncateColumns(keepingThrough: depth)
                }
            }
            return
        }

        if restoredPathIsOpen {
            // The columns down to its folder are open and it isn't there (hidden, gone): select
            // nothing rather than something no column shows
            pushSelection([])
            return
        }
        if restoringColumns, restoreColumnPath(to: selection) {
            return
        }
        // Not shown yet (e.g. a new folder before the refresh): try again when columns change
        columnState.pendingSelectionURLs = selectedURLs
    }

    private func resolvePendingSelection() {
        guard let pending = columnState.pendingSelectionURLs else { return }
        guard pending == Set(viewModel.selectedItems.map(\.url)) else {
            // The selection changed meanwhile: stop opening columns for the old one
            columnState.pendingPath = nil
            return
        }
        if let path = columnState.pendingPath, !path.isEmpty {
            continuePendingPath()
            return
        }
        syncSelectionFromViewModel(force: true)
    }

    /// The view model's selection is in a folder below the root that no column shows (the column
    /// view was recreated, e.g. for a tab switch): opens the columns down to it, one load at a time.
    /// False when it isn't below the root.
    private func restoreColumnPath(to selection: Set<FileItem>) -> Bool {
        guard let first = selection.first, !first.isFromArchive, first.url.isFileURL else { return false }
        let parent = first.url.deletingLastPathComponent()
        let parentKey = parent.standardizedPathKey
        guard selection.allSatisfy({ $0.url.deletingLastPathComponent().standardizedPathKey == parentKey }) else { return false }
        let rootKey = viewModel.currentPath.standardizedPathKey
        guard parentKey.hasPrefix(rootKey.hasSuffix("/") ? rootKey : rootKey + "/") else { return false }

        // The folders from the root's child down to the selection's folder
        var path: [URL] = []
        var folder = parent
        while folder.standardizedPathKey != rootKey {
            guard path.count < 256 else { return false }
            path.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        truncateColumns(keepingThrough: 0)
        columnState.pendingPath = path
        columnState.pendingSelectionURLs = Set(selection.map(\.url))
        continuePendingPath()
        return true
    }

    /// Opens the next folder of a restored path once the column listing it is loaded.
    private func continuePendingPath() {
        guard let path = columnState.pendingPath, let next = path.first else { return }
        let depth = columns.count
        // Wait for the column that lists it
        guard next.deletingLastPathComponent().standardizedPathKey == columnURL(atDepth: depth)?.standardizedPathKey else { return }
        let nextKey = next.standardizedPathKey
        guard let folder = columnItems(atDepth: depth)?.first(where: { $0.url.standardizedPathKey == nextKey }),
              ColumnBrowsing.isBrowsableFolder(folder) else {
            // Not listed (hidden, gone): select nothing rather than something no column shows
            columnState.pendingPath = nil
            columnState.pendingSelectionURLs = nil
            pushSelection([])
            return
        }
        columnState.pendingPath = Array(path.dropFirst())
        // Opens its column; its load continues with `resolvePendingSelection`
        selectInColumn(depth: depth, item: folder)
    }

    /// Select All in the active column (with several items selected, nothing opens to its right).
    private func selectAllInActiveColumn() {
        guard let url = columnURL(atDepth: activeColumnIndex),
              let activeItems = columnItems(atDepth: activeColumnIndex), !activeItems.isEmpty else { return }
        truncateColumns(keepingThrough: activeColumnIndex)
        let lead = columnSelections[url].flatMap { selected in activeItems.first { $0.url == selected.url } } ?? activeItems[0]
        columnSelections[url] = lead
        pushSelection(Set(activeItems), index: activeItems.firstIndex(of: lead))
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

    // MARK: - Mouse

    /// A click on `item` (at `index`) in the column at `depth`.
    private func handleClick(depth: Int, item: FileItem, index: Int, modifiers: NSEvent.ModifierFlags) {
        guard let url = columnURL(atDepth: depth), let columnItems = columnItems(atDepth: depth) else { return }
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)
        if (shift || command) && depth != activeColumnIndex {
            // Selections don't span columns: ⇧/⌘-click in another column starts over in that one,
            // a ⇧ range from its own selected item (the folder on the drilled path)
            let here = Set(columnItems.map(\.url))
            let kept = viewModel.selectedItems.filter { here.contains($0.url) }
            if kept.count != viewModel.selectedItems.count {
                viewModel.selectedItems = kept
            }
            if shift {
                viewModel.selectionAnchorIndex = columnSelections[url].flatMap { selected in
                    columnItems.firstIndex { $0.url == selected.url }
                } ?? index
            }
        }
        viewModel.handleSelection(item: item, index: index, in: columnItems, withShift: shift, withCommand: command)

        let selection = viewModel.selectedItems
        if selection.count == 1, selection.contains(item) {
            // Opens a folder's contents to the right
            selectInColumn(depth: depth, item: item)
        } else {
            // Several items (or the clicked one deselected): nothing opens to the right
            if let lead = selection.contains(item) ? item : columnItems.first(where: { selection.contains($0) }) {
                columnSelections[url] = lead
                columnState.selectionIndex[url] = columnItems.firstIndex { $0.url == lead.url }
            } else {
                columnSelections.removeValue(forKey: url)
            }
            activeColumnIndex = depth
            truncateColumns(keepingThrough: depth)
            updateQuickLook(for: selection.contains(item) ? item : nil)
        }
        columnState.notePushed(selection)
    }

    // MARK: - Metadata

    /// Root-column rows appearing on screen load their metadata (and iCloud status), as the list
    /// does for its visible rows: big folders are listed without it. Coalesced per run loop turn.
    /// Rows show no metadata, so scrolling doesn't load it: each loaded batch replaces the view
    /// model's items and redraws the whole column, which made scrolling large folders stutter.
    /// Root rows in iCloud folders load their iCloud status (badges); sub-columns load theirs
    /// with their listing. The preview column's item loads its metadata (`loadRootSelectionMetadata`).
    private func rowAppeared(_ item: FileItem, depth: Int) {
        guard depth == 0, item.cloudStatus == nil, !viewModel.isInsideArchive,
              CloudStatusManager.shared.isInICloud(viewModel.currentPath) else { return }
        columnState.hydrationURLs.insert(item.url)
        guard !columnState.isHydrationScheduled else { return }
        columnState.isHydrationScheduled = true
        let viewModel = viewModel
        DispatchQueue.main.async { [weak columnState] in
            guard let columnState else { return }
            columnState.isHydrationScheduled = false
            let urls = Array(columnState.hydrationURLs)
            columnState.hydrationURLs.removeAll()
            viewModel.hydrateCloudStatus(for: urls)
        }
    }

    /// The root column's selected item, once its metadata is loaded, shows its size and date in
    /// the preview column (large folders list without metadata).
    private func loadRootSelectionMetadata() {
        guard let selection = columnSelections[viewModel.currentPath], !selection.hasMetadata else { return }
        viewModel.hydrateMetadata(for: [selection.url])
    }

    // MARK: - Background Menu

    /// New Folder in a column's folder (the root column's is the view model's).
    private func createNewFolder(inColumnAt depth: Int) {
        guard depth > 0, let url = columnURL(atDepth: depth) else {
            viewModel.createNewFolder()
            return
        }
        // The view model creates it (with Undo) and selects it for renaming; the column selects
        // it once its reload lists it, and its row shows the rename field
        guard let folderURL = viewModel.createNewFolder(in: url) else { return }
        truncateColumns(keepingThrough: depth)
        activeColumnIndex = depth
        // As the column will list it (a folder URL, "…/untitled folder/"): the selection and the
        // rename field match its row by URL
        let listedURL = url.appendingPathComponent(folderURL.lastPathComponent, isDirectory: true)
        viewModel.selectedItems = [FileItem(url: listedURL)]
        viewModel.renamingURL = listedURL
    }

    /// Refresh from a column's background menu: the root column refreshes the view model; a
    /// sub-column relists its folder and re-reads its items' tags.
    private func refreshColumn(atDepth depth: Int) {
        guard depth > 0, let url = columnURL(atDepth: depth), let columnItems = columnItems(atDepth: depth) else {
            viewModel.refresh()
            return
        }
        viewModel.refreshTags(for: columnItems.filter { !$0.isFromArchive }.map(\.url))
        reloadColumn(at: url)
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
            let selection = viewModel.selectedItems
            if selection.count == 1, let only = selection.first {
                // Back to one item: its folder opens again
                selectInColumn(depth: activeColumnIndex, item: only)
            } else {
                // Several items: nothing opens to their right (Finder)
                truncateColumns(keepingThrough: activeColumnIndex)
            }
            columnState.notePushed(selection)
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

        if let matchIndex = columnItems.firstIndex(where: { $0.displayName.lowercased().hasPrefix(lowercased) }) {
            let matchItem = columnItems[matchIndex]
            selectInColumn(depth: activeColumnIndex, item: matchItem)
            pushSelection([matchItem], index: matchIndex)
        }
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection(in: browserWindow?.window) { [self] offset in
            navigateInActiveColumn(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item, in: browserWindow?.window)
    }
}

struct ColumnData: Identifiable {
    let id: UUID
    /// The item that was opened: a folder, a symlink or Finder alias to one, or a folder in a ZIP
    let folder: FileItem
    /// The folder whose contents are listed (the item's own path; an alias's original)
    let url: URL
    let items: [FileItem]
    /// File identity of each listed item, to recognise one renamed between two listings
    let fileIDs: [URL: FileIdentity]
    /// The opened item's own identity (follows it when it's renamed)
    let folderID: FileIdentity?

    init(id: UUID = UUID(), folder: FileItem, url: URL? = nil, items: [FileItem], fileIDs: [URL: FileIdentity] = [:], folderID: FileIdentity? = nil) {
        self.id = id
        self.folder = folder
        self.url = url ?? folder.url
        self.items = items
        self.fileIDs = fileIDs
        self.folderID = folderID
    }
}

/// A file's identity on its volume: the same after a rename, different for a new file at the
/// same path.
struct FileIdentity: Hashable {
    private let identifier: NSObject

    /// From the URL's resource values (prefetched by a directory listing, else read).
    init?(_ url: URL) {
        guard let identifier = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject else {
            return nil
        }
        self.identifier = identifier
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
    /// Folders shown in sub-columns that changed (the view reloads them)
    let folderChanges = PassthroughSubject<URL, Never>()
    /// Current load request per column depth
    var loadTokens: [Int: UUID] = [:]
    /// The selection this view last set on the view model
    var pushedSelectionURLs: Set<URL>?
    /// A view-model selection not visible in any column yet
    var pendingSelectionURLs: Set<URL>?
    /// Folders still to open, root to leaf, to show `pendingSelectionURLs` (a recreated view)
    var pendingPath: [URL]?
    var deleteGuard: DeleteGuard?
    /// Last known index of each column's selection (to pick a neighbour when it disappears)
    var selectionIndex: [URL: Int] = [:]
    /// Sub-column folders found missing once (closed if they're still missing on a second look)
    var missingFolders: Set<URL> = []
    /// Root-column rows waiting for their metadata (requested together)
    var hydrationURLs: Set<URL> = []
    var isHydrationScheduled = false

    init() {
        // Weak: the watcher must not keep this state (or a view) alive
        watcher.onChange = { [weak self] url in
            self?.folderChanges.send(url)
        }
    }

    func notePushed(_ selection: Set<FileItem>) {
        pushedSelectionURLs = Set(selection.map(\.url))
    }

    func invalidateLoads(fromDepth depth: Int) {
        loadTokens = loadTokens.filter { $0.key < depth }
    }
}

/// Watches the folders shown in sub-columns and reports changes (coalesced) on the main queue.
/// A folder that is deleted or moved away is watched again at its path (it may be replaced there).
final class ColumnDirectoryWatcher {
    var onChange: ((URL) -> Void)?
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var pendingNotifications: [URL: DispatchWorkItem] = [:]
    /// Watched folders whose directory was deleted or renamed (the watch must be renewed)
    private var replacedURLs: Set<URL> = []

    func watch(_ urls: [URL]) {
        let wanted = Set(urls)
        for url in sources.keys where !wanted.contains(url) {
            stopWatching(url)
        }
        for url in wanted where sources[url] == nil {
            startWatching(url)
        }
    }

    private func startWatching(_ url: URL) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.sources[url] else { return }
            // The directory itself went away (deleted, renamed, replaced by an atomic swap)
            let replaced = !source.data.isDisjoint(with: [.delete, .rename])
            self.folderChanged(url, replaced: replaced)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        sources[url] = source
    }

    private func stopWatching(_ url: URL) {
        sources.removeValue(forKey: url)?.cancel()
        pendingNotifications.removeValue(forKey: url)?.cancel()
        replacedURLs.remove(url)
    }

    private func folderChanged(_ url: URL, replaced: Bool) {
        if replaced {
            replacedURLs.insert(url)
        }
        // Coalesce bursts (a copy of many files) into one reload
        pendingNotifications[url]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNotifications.removeValue(forKey: url)
            if self.replacedURLs.remove(url) != nil, self.sources[url] != nil {
                // Watch whatever is at the path now (nothing: `watch` tries again when asked)
                self.sources.removeValue(forKey: url)?.cancel()
                self.startWatching(url)
            }
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
    private static var aliasCache: [String: Bool] = [:]

    /// Folders open as columns, and so do symbolic links and Finder aliases to folders; packages
    /// (.app, .rtfd, .photoslibrary…) behave like files.
    static func isBrowsableFolder(_ item: FileItem) -> Bool {
        if item.isAliasFile { return isAliasToFolder(item.url) }
        guard item.isDirectory else { return false }
        if item.isFromArchive || !item.url.isFileURL { return true }
        // For a symlink, `isPackage` describes its target (the link itself is never a package)
        return !item.isPackage && !isPackage(item.url)
    }

    /// `isBrowsableFolder` from what is already known, without reading the disk (for drawing);
    /// nil when it would have to read.
    static func cachedIsBrowsableFolder(_ item: FileItem) -> Bool? {
        if item.isAliasFile { return cachedFlag(item.url.path, inAliasCache: true) }
        guard item.isDirectory else { return false }
        if item.isFromArchive || !item.url.isFileURL { return true }
        if item.isPackage { return false }
        return cachedFlag(item.url.path, inAliasCache: false).map { !$0 }
    }

    private static func cachedFlag(_ path: String, inAliasCache: Bool) -> Bool? {
        packageCacheLock.lock()
        defer { packageCacheLock.unlock() }
        return inAliasCache ? aliasCache[path] : packageCache[path]
    }

    /// Whether a Finder alias points to a folder, from the alias's bookmark data (a small file
    /// read, cached by path; the alias isn't resolved).
    static func isAliasToFolder(_ url: URL) -> Bool {
        let path = url.path
        packageCacheLock.lock()
        if let cached = aliasCache[path] {
            packageCacheLock.unlock()
            return cached
        }
        packageCacheLock.unlock()

        var isFolder = false
        if let data = try? URL.bookmarkData(withContentsOf: url),
           let values = URL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey], fromBookmarkData: data) {
            isFolder = values.isDirectory == true && values.isPackage != true
        }
        packageCacheLock.lock()
        if aliasCache.count > 1000 {
            aliasCache.removeAll()
        }
        aliasCache[path] = isFolder
        packageCacheLock.unlock()
        return isFolder
    }

    /// The folder whose contents a column for `folder` lists: the item itself (a symlink is browsed
    /// under its own path), or a Finder alias's original — resolved without UI or mounting, nil
    /// when it can't be found. Call off the main thread.
    static func contentsURL(of folder: FileItem) -> URL? {
        guard folder.isAliasFile else { return folder.url }
        guard let resolved = try? URL(resolvingAliasFileAt: folder.url, options: [.withoutUI, .withoutMounting]),
              (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return nil
        }
        return resolved
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

    /// A sub-column's contents with each item's file identity.
    struct Listing {
        let items: [FileItem]
        let fileIDs: [URL: FileIdentity]
    }

    /// Contents of a sub-column, filtered and sorted like the main file list.
    static func loadItems(
        in folder: URL,
        showHiddenFiles: Bool,
        sortState: SortState,
        foldersFirst: Bool,
        reusingIDs existingIDs: [URL: UUID] = [:]
    ) throws -> [FileItem] {
        try loadListing(in: folder, showHiddenFiles: showHiddenFiles, sortState: sortState, foldersFirst: foldersFirst, reusingIDs: existingIDs).items
    }

    /// `loadItems`, with the items' file identities (to recognise renamed items).
    static func loadListing(
        in folder: URL,
        showHiddenFiles: Bool,
        sortState: SortState,
        foldersFirst: Bool,
        reusingIDs existingIDs: [URL: UUID] = [:]
    ) throws -> Listing {
        // contentsOfDirectory(at:) doesn't follow a symlink in the last path component: list the
        // link's target, but keep the children under the link's path (browsed where it's listed)
        var directoryToList = folder
        var info = stat()
        if lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            directoryToList = folder.resolvingSymlinksInPath()
        }
        let listed = try FileManager.default.contentsOfDirectory(
            at: directoryToList,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey, .isPackageKey, .fileResourceIdentifierKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )
        // Children keep the folder's path form (/tmp rather than /private/tmp, the link's path)
        let contents = URL.childURLs(listed, reRootedUnder: folder)
        var fileIDs: [URL: FileIdentity] = [:]
        fileIDs.reserveCapacity(contents.count)
        let fileItems = zip(listed, contents).map { listedURL, url in
            // Warm the package cache from the prefetched value
            _ = isPackage(url)
            // Prefetched with the listing
            if let identity = FileIdentity(listedURL) {
                fileIDs[url] = identity
            }
            return FileItem(url: url, id: existingIDs[url] ?? UUID())
        }
        return Listing(
            items: ListColumnConfigManager.sortedItems(fileItems, sortState: sortState, foldersFirst: foldersFirst),
            fileIDs: fileIDs
        )
    }

    /// `url` once `old` (a folder it's in, or itself) moved to `new`; nil when it isn't inside `old`.
    static func url(_ url: URL, movedFrom old: URL, to new: URL) -> URL? {
        let path = url.standardizedPathKey
        let oldPath = old.standardizedPathKey
        if path == oldPath { return new }
        let prefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return new.appendingPathComponent(String(path.dropFirst(prefix.count)), isDirectory: url.hasDirectoryPath)
    }

    /// A folder inside a ZIP archive, shown as a column from the archive's entries.
    struct ArchiveFolder: Equatable {
        let archiveURL: URL
        /// The folder's path inside the archive
        let path: String
    }

    /// Where an archive folder's column gets its contents; nil for anything else.
    static func archiveColumnSource(for folder: FileItem) -> ArchiveFolder? {
        guard folder.isFromArchive, folder.isDirectory,
              let archiveURL = folder.archiveURL, let path = folder.archivePath else { return nil }
        return ArchiveFolder(archiveURL: archiveURL, path: path)
    }

    /// Contents of a folder inside a ZIP archive, filtered and sorted like `loadItems`. The archive
    /// is read through ZipArchiveManager's cache, so item IDs stay the same while it's unchanged.
    static func loadArchiveItems(
        in archiveURL: URL,
        at path: String,
        showHiddenFiles: Bool,
        sortState: SortState,
        foldersFirst: Bool
    ) throws -> [FileItem] {
        let archive = ZipArchiveManager.shared
        let entries = try archive.readContents(of: archiveURL)
        var fileItems = archive.fileItems(from: archive.entriesAtPath(path, in: entries), archiveURL: archiveURL)
        if !showHiddenFiles {
            fileItems = fileItems.filter { !$0.name.hasPrefix(".") }
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
    /// A click on a row: the item, its index in `items` and the modifier keys held
    let onClick: (FileItem, Int, NSEvent.ModifierFlags) -> Void
    let onDoubleClick: (FileItem) -> Void
    /// A row came on screen
    let onRowAppear: (FileItem) -> Void
    /// Background menu: New Folder and Refresh in this column's folder
    let onNewFolder: () -> Void
    let onRefresh: () -> Void
    @State private var dropTargetedItemID: UUID?
    @State private var isColumnDropTargeted = false
    /// Finder tags of this column's items that have any, read off the main thread
    @StateObject private var tagReader = GridTagReader()
    @State private var tagsByURL: [URL: [String]] = [:]

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
                            isSelected: isSelected,
                            tags: appSettings.showItemTags ? tagsByURL[item.url] ?? [] : []
                        )
                        .id(item.url)
                        // Every row is the same height: the column's drop target finds rows by position
                        .frame(maxWidth: .infinity, minHeight: rowContentHeight, maxHeight: rowContentHeight, alignment: .leading)
                        .padding(.vertical, ColumnRowMetrics.verticalPadding)
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
                        .fileDragItem(item)
                        .instantTap(
                            id: item.id,
                            onSingleClick: {
                                if let index = items.firstIndex(of: item) {
                                    onClick(item, index, NSEvent.modifierFlags)
                                }
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
                        .onAppear {
                            onRowAppear(item)
                        }
                    }
                }
                // Drops onto the rows: the folder row under the pointer, else this column's folder.
                // One target for the column, not one per row (an AppKit view each, built as rows
                // scroll in, which made scrolling slow).
                .onDrop(of: DropHelper.acceptedDropTypes, delegate: ColumnRowsDropDelegate(
                    items: items,
                    rowHeight: rowContentHeight + 2 * ColumnRowMetrics.verticalPadding,
                    columnURL: columnURL,
                    viewModel: viewModel,
                    dropTargetedItemID: $dropTargetedItemID,
                    isColumnDropTargeted: $isColumnDropTargeted
                ))
                // Dragging a selected item drags the whole selection
                .fileDragContainer(for: viewModel)
            }
            .frame(width: appSettings.columnWidthValue)
            .onDrop(of: DropHelper.acceptedDropTypes, delegate: ColumnBackgroundDropDelegate(
                columnURL: columnURL,
                viewModel: viewModel,
                dropTargetedItemID: $dropTargetedItemID,
                isColumnDropTargeted: $isColumnDropTargeted
            ))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isColumnDropTargeted && dropTargetedItemID == nil ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // The background menu acts on this column's folder
            .contextMenu {
                Button("New Folder") {
                    onNewFolder()
                }

                if viewModel.canPaste {
                    Divider()
                    Button("Paste") {
                        viewModel.paste(to: columnURL)
                    }
                }

                Divider()

                Button("Refresh") {
                    onRefresh()
                }

                Button("Show in Finder") {
                    if columnURL.isFileURL && !viewModel.isInsideArchive {
                        NSWorkspace.shared.activateFileViewerSelecting([columnURL])
                    } else {
                        viewModel.showInFinder()
                    }
                }
            }
            .onAppear {
                startTagRead()
                // Scroll to selected item when view appears (e.g., when switching view modes)
                if let selected = selectedItem {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollProxy.scrollTo(selected.url, anchor: .center)
                    }
                }
            }
            .onDisappear {
                tagReader.cancel()
            }
            .onChange(of: selectedItem?.url) { _, selectedURL in
                if let selectedURL {
                    withAnimation {
                        scrollProxy.scrollTo(selectedURL)
                    }
                }
            }
            .onChange(of: items) { _, _ in
                startTagRead()
            }
            .onChange(of: appSettings.showItemTags) { _, _ in
                startTagRead()
            }
            // Tags edited here or elsewhere, or a refresh (the cache entries were dropped)
            .onChange(of: viewModel.tagRefreshToken) { _, _ in
                startTagRead()
            }
        }
    }

    /// Height of a row's contents (icon or name, whichever is taller)
    private var rowContentHeight: CGFloat {
        ColumnRowMetrics.contentHeight(fontSize: appSettings.columnFontSize, iconSize: appSettings.columnIconSizeValue)
    }

    /// Reads the items' tags in the background (like the icon grid); rows show them once they arrive.
    private func startTagRead() {
        guard appSettings.showItemTags else { return }
        tagReader.read(items) { tags in
            if tags != tagsByURL {
                tagsByURL = tags
            }
        }
    }
}

struct ColumnRowView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let isSelected: Bool
    /// The item's Finder tags, read by its column in the background
    let tags: [String]
    /// Whether it opens as a column, read in the background (drawing never reads the disk)
    @State private var loadedURL: URL?
    @State private var loadedIsBrowsableFolder: Bool?

    var body: some View {
        HStack(spacing: 8) {
            AsyncListIconView(item: item, size: appSettings.columnIconSizeValue)

            // Cloud status badge (shown inline after icon)
            if let cloudStatus = item.cloudStatus, cloudStatus.shouldShowBadge {
                CloudStatusBadgeView(status: cloudStatus, size: 12)
            }

            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.columnFont, alignment: .leading, lineLimit: 1)

            if appSettings.showItemTags, !tags.isEmpty {
                TagDotsView(tags: tags)
            }

            Spacer()

            if isBrowsableFolder {
                Image(systemName: "chevron.right")
                    .font(appSettings.columnDetailFont)
                    .foregroundColor(.secondary)
            }
        }
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
        .onAppear {
            loadFolderStatusIfNeeded()
        }
        .onChange(of: item.url) { _, _ in
            loadFolderStatusIfNeeded()
        }
    }

    private var isBrowsableFolder: Bool {
        if let cached = ColumnBrowsing.cachedIsBrowsableFolder(item) { return cached }
        if loadedURL == item.url, let loadedIsBrowsableFolder { return loadedIsBrowsableFolder }
        // Until it's known: folders are, packages and other files aren't
        return item.isDirectory && !item.isPackage
    }

    /// Reads the alias/package status the caches don't know yet off the main thread.
    private func loadFolderStatusIfNeeded() {
        let item = item
        guard ColumnBrowsing.cachedIsBrowsableFolder(item) == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // Fills the cache
            let isBrowsableFolder = ColumnBrowsing.isBrowsableFolder(item)
            DispatchQueue.main.async {
                loadedURL = item.url
                loadedIsBrowsableFolder = isBrowsableFolder
            }
        }
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
                    InfoRow(label: "Kind", value: item.kindDescription)
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

/// Drops onto a column's background go into the folder the column shows. Internal drags are
/// allowed (e.g. from another column or pane); dropping a folder into itself or one of its
/// descendants, or items into the folder they're already in, is refused.
enum ColumnRowMetrics {
    static let verticalPadding: CGFloat = 4

    /// Height of a row's contents: the icon, or a line of the name, whichever is taller.
    static func contentHeight(fontSize: Double, iconSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize))
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return max(iconSize, lineHeight)
    }

    /// The index of the row at `y` (in the rows' coordinates), or nil past the ends.
    static func rowIndex(atY y: CGFloat, rowHeight: CGFloat, count: Int) -> Int? {
        guard rowHeight > 0, y >= 0 else { return nil }
        let index = Int(y / rowHeight)
        return index < count ? index : nil
    }
}

/// Drop target over a column's rows: a folder row under the pointer takes the drop (like its
/// own `UnifiedFolderDropDelegate`); anywhere else it goes into the column's folder (like
/// `ColumnBackgroundDropDelegate`, which covers the empty area below the rows).
struct ColumnRowsDropDelegate: DropDelegate {
    let items: [FileItem]
    let rowHeight: CGFloat
    let columnURL: URL
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?
    @Binding var isColumnDropTargeted: Bool

    private var columnDelegate: ColumnBackgroundDropDelegate {
        ColumnBackgroundDropDelegate(
            columnURL: columnURL,
            viewModel: viewModel,
            dropTargetedItemID: $dropTargetedItemID,
            isColumnDropTargeted: $isColumnDropTargeted
        )
    }

    /// The delegate of the folder row under the pointer, when that folder takes this drop.
    private func folderDelegate(at location: CGPoint, info: DropInfo) -> UnifiedFolderDropDelegate? {
        guard let index = ColumnRowMetrics.rowIndex(atY: location.y, rowHeight: rowHeight, count: items.count) else { return nil }
        let delegate = UnifiedFolderDropDelegate(item: items[index], viewModel: viewModel, dropTargetedItemID: $dropTargetedItemID)
        return delegate.validateDrop(info: info) ? delegate : nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Where it may land (a folder row or the column) is decided as the pointer moves
        info.hasItemsConforming(to: DropHelper.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let folder = folderDelegate(at: info.location, info: info) {
            isColumnDropTargeted = false
            if dropTargetedItemID != folder.item.id {
                folder.dropEntered(info: info)
            }
            return folder.dropUpdated(info: info)
        }
        dropTargetedItemID = nil
        return columnDelegate.dropUpdated(info: info)
    }

    func dropExited(info: DropInfo) {
        dropTargetedItemID = nil
        isColumnDropTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        if let folder = folderDelegate(at: info.location, info: info) {
            isColumnDropTargeted = false
            return folder.performDrop(info: info)
        }
        dropTargetedItemID = nil
        return columnDelegate.performDrop(info: info)
    }
}

struct ColumnBackgroundDropDelegate: DropDelegate {
    let columnURL: URL
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?
    @Binding var isColumnDropTargeted: Bool

    /// Not inside an archive, the Photos library or the network browser, and not into the root
    /// column while it shows Spotlight results (they come from anywhere; folder rows still take drops).
    private var acceptsDrops: Bool {
        !viewModel.isInsideArchive
            && !viewModel.isPhotosLibraryActive
            && columnURL.isFileURL
            && columnURL.path != "/Network"
            && !(columnURL == viewModel.currentPath && FileListActions.showsSearchResults(viewModel))
            && !DropHelper.isSidebarFavoriteDrag()
    }

    /// Items already in this folder are refused, unless Option duplicates them (Finder).
    private func isUsefulDrop() -> Bool {
        let sources = DropHelper.dragSourceURLs()
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return !DropHelper.isSelfOrDescendantDrop(sources: sources, destination: columnURL)
            && !DropHelper.isNoOpDrop(sources: sources, destination: columnURL, operation: operation)
    }

    func validateDrop(info: DropInfo) -> Bool {
        acceptsDrops && info.hasItemsConforming(to: DropHelper.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        if dropTargetedItemID == nil, acceptsDrops, isUsefulDrop() {
            setColumnHighlighted(true)
        }
    }

    /// The column's drop highlight. A drag that leaves without an exit event (it happens with
    /// the rows' drop target nested inside the column's) still clears it when it ends.
    private func setColumnHighlighted(_ highlighted: Bool) {
        guard highlighted != isColumnDropTargeted else { return }
        isColumnDropTargeted = highlighted
        if highlighted {
            let binding = $isColumnDropTargeted
            DropHighlightReset.shared.clearWhenDragEnds {
                binding.wrappedValue = false
            }
        }
    }

    func dropExited(info: DropInfo) {
        isColumnDropTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard acceptsDrops, isUsefulDrop() else {
            isColumnDropTargeted = false
            return DropProposal(operation: .forbidden)
        }
        // Over a folder row that row's delegate takes the drop; highlight the column otherwise
        setColumnHighlighted(dropTargetedItemID == nil)
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropProposal(operation: DropHelper.dropOperation(
            for: operation,
            sources: DropHelper.dragSourceURLs(),
            destination: columnURL
        ))
    }

    func performDrop(info: DropInfo) -> Bool {
        isColumnDropTargeted = false
        defer { InternalDragState.shared.endDrag() }
        // If hovering over a folder, that delegate handles it
        guard dropTargetedItemID == nil, acceptsDrops, isUsefulDrop() else { return false }

        // Resolve copy/move now, from the modifiers held at drop time
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropHelper.performDrop(
            providers: info.itemProviders(for: [.fileURL]),
            into: columnURL,
            viewModel: viewModel,
            operation: operation
        )
    }
}

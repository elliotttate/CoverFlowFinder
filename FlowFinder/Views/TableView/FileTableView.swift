import AppKit
import SwiftUI
import Combine

// MARK: - NSViewRepresentable Wrapper

struct FileTableView: NSViewRepresentable {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var columnConfig: ListColumnConfigManager
    @ObservedObject var appSettings: AppSettings
    let items: [FileItem]
    let tagRefreshToken: Int
    var onEmptySpaceClick: (() -> Void)? = nil
    /// Whether `.focusFileList` requests focus this table. Off for the list under Cover Flow, where
    /// Cover Flow takes them (exactly one view may respond).
    var takesFocusRequests = true

    func makeCoordinator() -> FileTableCoordinator {
        FileTableCoordinator(
            viewModel: viewModel,
            columnConfig: columnConfig,
            appSettings: appSettings,
            onEmptySpaceClick: onEmptySpaceClick
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.bind(viewModel: viewModel)
        coordinator.columnConfig = columnConfig
        coordinator.appSettings = appSettings
        coordinator.onEmptySpaceClick = onEmptySpaceClick
        coordinator.takesFocusRequests = takesFocusRequests

        // Ensure header menu is set up (in case it wasn't ready before)
        coordinator.ensureHeaderMenu()

        coordinator.update(items: items, tagRefreshToken: tagRefreshToken)
    }
}

// MARK: - Custom TableView with Keyboard Handling

@MainActor
final class KeyboardTableView: NSTableView {
    weak var coordinator: FileTableCoordinator?

    override var acceptsFirstResponder: Bool {
        // Don't take focus away from the inline rename field while it's editing
        if coordinator?.isCurrentlyEditing == true {
            return false
        }
        return super.acceptsFirstResponder
    }

    // Enable periodic updates for auto-scroll during drag (Finder-style)
    override func wantsPeriodicDraggingUpdates() -> Bool {
        return true
    }

    // Auto-scroll when dragging near edges
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Call autoscroll on enclosing scroll view for Finder-style edge scrolling
        if let scrollView = enclosingScrollView, let event = NSApp.currentEvent {
            scrollView.contentView.autoscroll(with: event)
        }
        return super.draggingUpdated(sender)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘-shortcuts (copy, cut, paste, select all, trash) belong to the menu bar; arrows and
        // type-select fall through to NSTableView. Space and Return work here as well as through
        // the window's keyboard handler, so the table works whichever one sees the key first.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty {
            switch event.charactersIgnoringModifiers {
            case " ":
                coordinator?.triggerQuickLook()
                return
            case "\r", "\u{3}": // Return, keypad Enter
                coordinator?.openSelectedItems()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// Identity of the last mouse-down handled, to drop a re-delivery of the same click.
    private var lastMouseDown: (timestamp: TimeInterval, eventNumber: Int, clickCount: Int)?

    override func mouseDown(with event: NSEvent) {
        // AppKit's gesture-recognizer machinery can deliver the same mouse-down a second time
        // ("delayed event") after it was already handled. Handling it twice turned a row click
        // into a row click followed by an empty-space click, which cleared the selection.
        if let last = lastMouseDown, last.timestamp == event.timestamp, last.eventNumber == event.eventNumber,
           last.clickCount == event.clickCount {
            return
        }
        lastMouseDown = (event.timestamp, event.eventNumber, event.clickCount)

        let point = convert(event.locationInWindow, from: nil)
        var clickedRow = row(at: point)
        let modifiers = event.modifierFlags

        // A click anywhere outside the rename field commits the rename first (Finder)
        coordinator?.commitEditingForMouseDown()

        if clickedRow >= 0, numberOfRows > 0, point.y > rect(ofRow: numberOfRows - 1).maxY {
            clickedRow = -1
        }

        // Control-click opens the context menu; it must not trigger click-to-rename
        if modifiers.contains(.control) {
            super.mouseDown(with: event)
            return
        }

        if clickedRow < 0 {
            // A point outside the table isn't a click on its empty space (e.g. a stray re-delivered
            // event); never clear the selection for it.
            guard visibleRect.contains(point) else {
                super.mouseDown(with: event)
                return
            }
            // Empty space below the rows
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                // ⌘/⇧-click on empty space keeps the selection (Finder)
                window?.makeFirstResponder(self)
                return
            }
            coordinator?.handleEmptySpaceClick()
            // Let NSTableView track the mouse so a drag-select can start from empty space
            coordinator?.beginMouseSelection(row: -1)
            super.mouseDown(with: event)
            coordinator?.endMouseSelection()
            return
        }

        if modifiers.contains(.shift) && !modifiers.contains(.command) {
            // Range from the view model's anchor, the same anchor ⇧↑/⇧↓ extend from
            coordinator?.handleShiftClick(row: clickedRow)
            window?.makeFirstResponder(self)
            return
        }

        // Call coordinator's handleClick before super to capture pre-selection state
        coordinator?.handleRowClick(row: clickedRow, event: event)

        coordinator?.beginMouseSelection(row: clickedRow)
        super.mouseDown(with: event)
        coordinator?.endMouseSelection()
    }
}

// MARK: - Custom Row View with Always-Emphasized Selection

final class EmphasizedTableRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { /* Always emphasized */ }
    }
}

// MARK: - Opening Items

@MainActor
enum FileListActions {
    /// Opening more external items than this at once asks for confirmation.
    static let openConfirmationThreshold = 20

    /// True if opening `item` navigates inside the browser (folders, ZIPs, folders in archives)
    /// rather than handing it to another app.
    static func navigatesInApp(_ item: FileItem) -> Bool {
        if item.isFromArchive { return item.isDirectory }
        if item.isZipArchive { return true }
        guard item.url.isFileURL, item.isDirectory else { return false }
        return !NSWorkspace.shared.isFilePackage(atPath: item.url.path)
    }

    /// Opens every item (Finder). Only one folder can be shown, so of several folders the lead
    /// item (or the first) is entered after the other items have been opened.
    static func open(_ items: [FileItem], primary: FileItem?, viewModel: FileBrowserViewModel) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            viewModel.openItem(items[0])
            return
        }

        let navigable = items.filter { navigatesInApp($0) }
        let external = items.filter { !navigatesInApp($0) }

        if external.count > openConfirmationThreshold {
            let alert = NSAlert()
            alert.messageText = "Are you sure you want to open \(external.count) items?"
            alert.informativeText = "Each item opens in its own application window."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        for item in external {
            viewModel.openItem(item)
        }
        if let target = navigable.first(where: { $0 == primary }) ?? navigable.first {
            viewModel.openItem(target)
        }
    }

    /// Whether the list shows Spotlight results (items from anywhere) rather than a folder.
    static func showsSearchResults(_ viewModel: FileBrowserViewModel) -> Bool {
        viewModel.searchMode == .finder && !viewModel.searchText.isEmpty
    }

    /// Whether files can be dropped into the location shown: not inside an archive, the Photos
    /// library or the network browser.
    static func acceptsDrops(in viewModel: FileBrowserViewModel) -> Bool {
        !viewModel.isInsideArchive
            && !viewModel.isPhotosLibraryActive
            && viewModel.currentPath.isFileURL
            && viewModel.currentPath.path != "/Network"
    }
}

// MARK: - Thumbnail Store

/// The table's row thumbnails: bounded by the coordinator (pruned to the rows around the visible
/// ones) and dropped when a file's modification date or size changes, so edited files refresh.
struct TableThumbnailStore {
    private struct Entry {
        let image: NSImage
        var modificationDate: Date?
        var size: Int64
        var hasMetadata: Bool
    }

    private var entries: [URL: Entry] = [:]
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int { entries.count }
    var isOverLimit: Bool { entries.count > limit }

    func contains(_ url: URL) -> Bool {
        entries[url] != nil
    }

    /// The stored thumbnail for `item`, unless the file changed since it was made.
    mutating func image(for item: FileItem) -> NSImage? {
        guard var entry = entries[item.url] else { return nil }
        if item.hasMetadata {
            if entry.hasMetadata {
                if entry.modificationDate != item.modificationDate || entry.size != item.size {
                    entries[item.url] = nil
                    return nil
                }
            } else {
                // Made before the item's metadata was loaded: adopt its version now
                entry.modificationDate = item.modificationDate
                entry.size = item.size
                entry.hasMetadata = true
                entries[item.url] = entry
            }
        }
        return entry.image
    }

    mutating func store(_ image: NSImage, for item: FileItem) {
        entries[item.url] = Entry(
            image: image,
            modificationDate: item.modificationDate,
            size: item.size,
            hasMetadata: item.hasMetadata
        )
    }

    mutating func prune(keeping shouldKeep: (URL) -> Bool) {
        entries = entries.filter { shouldKeep($0.key) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

// MARK: - Coordinator (NSTableViewDataSource & NSTableViewDelegate)

@MainActor
final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, FileNameCellViewDelegate, OpenWithActionTarget {
    private(set) var viewModel: FileBrowserViewModel
    var columnConfig: ListColumnConfigManager
    var appSettings: AppSettings
    weak var tableView: NSTableView?

    /// Rows shown by the table. Content always comes from the view model's current items.
    private(set) var items: [FileItem] = []
    /// Row of each URL in `items`; rebuilt whenever rows are added, removed or reordered.
    private(set) var rowIndex: [URL: Int] = [:]

    // Freshest item per URL (from viewModel.items); nil = rebuild on next use
    private var freshItemsByURL: [URL: FileItem]?
    private var viewModelItemsCancellable: AnyCancellable?
    private var observedViewModel: FileBrowserViewModel?

    // Items that arrived while renaming and would add, remove or move rows; applied when editing ends
    private var deferredItems: [FileItem]?
    // Scroll position kept across a reload that briefly empties the list (same folder)
    private var pendingScrollAnchor: ScrollAnchor?
    private var lastFolder: URL?
    private struct SortKey: Equatable {
        let sort: SortState
        let foldersFirst: Bool
    }
    private var lastSortKey: SortKey?
    // The last items array SwiftUI passed in, retained so its storage identity can't be reused
    private var lastIncomingItems: [FileItem] = []

    private var isUpdatingSelection = false
    private var isUpdatingSort = false  // Prevent sort feedback loop
    private var lastSortColumn: ListColumn?
    private var lastSortDirection: SortDirection?
    private var lastSyncedSelection: Set<FileItem>?
    private var activeMouseSelection: Int?  // row the current mouse-down started on (-1 = empty space)
    private var selectionCancellable: AnyCancellable?

    /// The view model's anchor and cursor are row indexes. Recorded with the items they pointed at
    /// (and the selection then) so a re-sort or reload can move them to those items' new rows.
    private struct SelectionEnds {
        let anchor: Int
        let anchorURL: URL?
        let cursor: Int
        let cursorURL: URL?
        let selection: Set<FileItem>
    }
    private var selectionEnds: SelectionEnds?

    /// A click elsewhere in the list committed a rename. The view model selects the renamed item
    /// when its listing reloads; the click's selection is kept instead (Finder).
    private struct ClickCommittedRename {
        let oldURL: URL
        let newURL: URL
        let expires: Date
    }
    private var clickCommittedRename: ClickCommittedRename?
    private var isCommittingForClick = false
    /// The view model's items changed this run loop turn (a listing was applied, with the
    /// selection it brings)
    private var isApplyingViewModelListing = false
    /// A click on an item of a multi-selection: the table selects just that row on mouse-up, so a
    /// double-click that follows still opens the whole selection (like Return)
    private var multiSelectionClick: (row: Int, urls: Set<URL>, time: TimeInterval)?

    // Columns
    private var appliedColumns: [ColumnSettings] = []
    private var isApplyingColumnLayout = false
    private var columnCommitWorkItem: DispatchWorkItem?
    private weak var columnCommitViewModel: FileBrowserViewModel?
    private var columnCommitFolderKey: String?
    private static let columnCommitDelay: TimeInterval = 0.15

    // Display settings
    private var lastDisplaySettings: DisplaySettings?
    var lastTagRefreshToken: Int = 0  // Track tag changes for UI refresh

    // Cut dimming
    private(set) var cutURLs: Set<URL> = []

    // Lazy loading state
    private var lastVisibleRange: Range<Int>?
    private var hydrationDebounceTimer: Timer?
    private let hydrationDebounceInterval: TimeInterval = 0.05
    private var isLiveScrolling = false
    private(set) var requestedCloudStatusURLs: Set<URL> = []

    // Tags are read off the main thread; FileTagManager's cache is warm for these URLs. A tag
    // refresh starts a new generation (reads still in flight from before it are dropped).
    private var loadedTagURLs: Set<URL> = []
    private var pendingTagURLs: Set<URL> = []
    private var tagGeneration = 0
    private static let tagQueue = DispatchQueue(label: "com.flowfinder.table.tags", qos: .userInitiated)

    // Thumbnails, bounded to the rows around the visible ones
    private var thumbnails = TableThumbnailStore(limit: 400)
    var thumbnailCount: Int { thumbnails.count }
    private let thumbnailCache = ThumbnailCacheManager.shared
    // This table's requests (cancelled on folder change, and when the coordinator goes away)
    private let thumbnailOwner = ThumbnailRequestOwner()
    private var thumbnailRequests: [URL: ThumbnailRequestToken] = [:]
    private static let thumbnailPixelSize: CGFloat = 64

    // Thumbnail preheat state (like PHCachingImageManager)
    private var lastPreheatRange: Range<Int>?
    private let preheatBuffer = 20  // Rows to preheat beyond visible

    // Renaming state
    private var lastProcessedRenamingURL: URL?
    private weak var currentEditingCell: FileNameCellView?
    private var pendingRenameWorkItem: DispatchWorkItem?

    // Drag and drop (cached per dragging session)
    private var dropSessionNumber: Int?
    private var dropSessionURLs: [URL] = []
    private var dropVolumeCache: [URL: Bool] = [:]

    // Context menu targets, captured when the menu opens
    private var contextMenuItems: [FileItem] = []
    private var contextMenuClickedItem: FileItem?

    // Callback for empty space click (used by CoverFlow view)
    var onEmptySpaceClick: (() -> Void)?
    /// See `FileTableView.takesFocusRequests`.
    var takesFocusRequests = true

    /// True while an inline rename is in progress (derived from the cell's field editor).
    var isCurrentlyEditing: Bool {
        currentEditingCell?.isEditingActive ?? false
    }

    init(viewModel: FileBrowserViewModel, columnConfig: ListColumnConfigManager, appSettings: AppSettings, onEmptySpaceClick: (() -> Void)? = nil) {
        self.viewModel = viewModel
        self.columnConfig = columnConfig
        self.appSettings = appSettings
        self.onEmptySpaceClick = onEmptySpaceClick
        super.init()
        bind(viewModel: viewModel)
    }

    deinit {
        hydrationDebounceTimer?.invalidate()
    }

    // MARK: - View Setup

    func makeScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let tableView = KeyboardTableView()
        tableView.coordinator = self
        tableView.style = .automatic  // Use automatic for best native appearance
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = Self.rowHeight(fontSize: appSettings.listFontSize, iconSize: appSettings.listIconSizeValue)
        tableView.gridStyleMask = []
        tableView.focusRingType = .none

        // Register for drag and drop. Like Cover Flow, drags offer move, copy (Option) and generic
        // (Command = force move) inside and outside the app; the destination picks (Finder and the
        // Trash move within a volume)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: true)
        tableView.setDraggingSourceOperationMask([.move, .copy, .generic], forLocal: false)

        // Set delegate and data source
        tableView.delegate = self
        tableView.dataSource = self
        self.tableView = tableView

        // Double-click to open
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        tableView.target = self

        // Setup columns first
        setupColumns()

        // Ensure the table view is properly configured as the document view
        scrollView.documentView = tableView

        NotificationCenter.default.addObserver(self, selector: #selector(columnDidResize(_:)), name: NSTableView.columnDidResizeNotification, object: tableView)
        NotificationCenter.default.addObserver(self, selector: #selector(columnDidMove(_:)), name: NSTableView.columnDidMoveNotification, object: tableView)

        // Observe scroll for lazy metadata hydration
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidScroll(_:)), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewDidEndScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)

        // Observe focus file list notification (e.g., after Escape from search)
        NotificationCenter.default.addObserver(self, selector: #selector(handleFocusFileList(_:)), name: .focusFileList, object: nil)

        // Setup menus after a short delay to ensure view hierarchy is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupHeaderMenu()
            self?.setupRowMenu()
        }

        return scrollView
    }

    /// Observes `newViewModel`'s items and its own hydration notifications (not other windows').
    func bind(viewModel newViewModel: FileBrowserViewModel) {
        guard observedViewModel !== newViewModel else { return }
        if let old = observedViewModel {
            NotificationCenter.default.removeObserver(self, name: .metadataHydrationCompleted, object: old)
            NotificationCenter.default.removeObserver(self, name: .cloudStatusHydrationCompleted, object: old)
        }
        viewModel = newViewModel
        observedViewModel = newViewModel
        freshItemsByURL = nil
        viewModelItemsCancellable = newViewModel.$items.sink { [weak self] _ in
            // Sent before the new value is stored; rebuilt lazily on next use
            self?.freshItemsByURL = nil
            self?.viewModelItemsWillChange()
        }
        selectionCancellable = newViewModel.$selectedItems.sink { [weak self] selection in
            // Sent before the new value is stored
            self?.viewModelSelectionWillChange(to: selection)
        }
        clickCommittedRename = nil
        selectionEnds = nil
        NotificationCenter.default.addObserver(self, selector: #selector(handleHydrationCompleted(_:)), name: .metadataHydrationCompleted, object: newViewModel)
        NotificationCenter.default.addObserver(self, selector: #selector(handleHydrationCompleted(_:)), name: .cloudStatusHydrationCompleted, object: newViewModel)
    }

    // MARK: - Updates

    /// Applies a SwiftUI update: rows, display settings, tags, cut dimming, columns, selection, rename.
    func update(items newItems: [FileItem], tagRefreshToken: Int) {
        guard tableView != nil else { return }
        reconcileEditingState()
        applyDisplaySettingsIfNeeded()

        let cutChanged = refreshCutURLs()

        // Most updates (selection, clipboard…) pass the very same array and the view model's items
        // haven't changed: nothing to do for the rows.
        let rowsUnchanged = freshItemsByURL != nil && deferredItems == nil && Self.sameStorage(newItems, lastIncomingItems)
        lastIncomingItems = newItems
        if !rowsUnchanged {
            let resolved = resolveFreshContent(newItems)
            if isCurrentlyEditing && !Self.sameURLs(resolved, items) {
                // Don't add, remove or move rows under the rename field; apply when editing ends
                deferredItems = newItems
            } else {
                deferredItems = nil
                applyItems(resolved)
            }
        }

        if tagRefreshToken != lastTagRefreshToken {
            lastTagRefreshToken = tagRefreshToken
            reloadTagsForLoadedRows()
        }
        if cutChanged {
            applyCutDimmingToLoadedRows()
        }

        syncColumnsIfNeeded()

        if !isCurrentlyEditing {
            syncSelectionFromViewModel()
        }
        noteSelectionEnds()

        checkForPendingRename()
    }

    /// The freshest version of each item. viewModel.items is updated in place by metadata and
    /// cloud-status hydration, while the `items` SwiftUI passes in can lag behind it (e.g. Cover Flow's
    /// sorted copy), so row content always comes from the view model.
    func resolveFreshContent(_ incoming: [FileItem]) -> [FileItem] {
        let index = freshIndex()
        guard !index.isEmpty else { return incoming }
        return incoming.map { index[$0.url] ?? $0 }
    }

    private func freshIndex() -> [URL: FileItem] {
        if let cached = freshItemsByURL { return cached }
        var index = [URL: FileItem](minimumCapacity: viewModel.items.count)
        for item in viewModel.items {
            index[item.url] = item
        }
        freshItemsByURL = index
        return index
    }

    /// Same array storage (cheap identity check; `rhs` is retained by the caller, so its storage
    /// can't have been freed and reused).
    static func sameStorage(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.isEmpty { return true }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    static func sameURLs(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices where lhs[index].url != rhs[index].url {
            return false
        }
        return true
    }

    /// Replaces the rows. Same URLs in the same order only reloads rows whose content changed;
    /// anything else reloads the table, keeping the scroll position and the selection (by URL).
    func applyItems(_ newItems: [FileItem]) {
        guard let tableView else { return }
        let oldItems = items

        // A re-sort by the user shows the selection (or the top); data-driven changes keep the position
        let sortKey = SortKey(sort: viewModel.sortState, foldersFirst: appSettings.foldersFirst)
        let sortChanged = lastSortKey != nil && lastSortKey != sortKey
        lastSortKey = sortKey

        if Self.sameURLs(oldItems, newItems) {
            items = newItems
            reloadRows(Self.rowsWithChangedContent(old: oldItems, new: newItems, in: loadedRows()))
            return
        }

        let folderChanged = lastFolder != nil && lastFolder != viewModel.currentPath
        if lastFolder != viewModel.currentPath {
            lastFolder = viewModel.currentPath
            pendingScrollAnchor = nil
            thumbnails.removeAll()
            thumbnailRequests.removeAll()
            thumbnailCache.cancelRequests(for: thumbnailOwner)
            loadedTagURLs.removeAll()
            requestedCloudStatusURLs.removeAll()
        }

        let anchor = folderChanged || sortChanged ? nil : (captureScrollAnchor() ?? pendingScrollAnchor)
        items = newItems
        rebuildRowIndex()
        moveSelectionEndsToNewRows()
        pruneThumbnails(force: true)
        isLiveScrolling = false
        lastVisibleRange = nil
        lastPreheatRange = nil

        // reloadData may trim the selection; the view model's selection is re-applied below
        isUpdatingSelection = true
        tableView.reloadData()
        isUpdatingSelection = false

        syncSelectionFromViewModel(allowScroll: false)

        if folderChanged || sortChanged {
            pendingScrollAnchor = nil
            if let row = sortChanged ? cursorRow(in: tableView.selectedRowIndexes) : nil {
                tableView.scrollRowToVisible(row)
            } else if !newItems.isEmpty {
                tableView.scrollRowToVisible(0)
            }
        } else if newItems.isEmpty {
            // e.g. a refresh that empties the list first: restore once the rows are back
            pendingScrollAnchor = anchor
        } else {
            pendingScrollAnchor = nil
            restoreScrollAnchor(anchor)
        }

        // Trigger hydration for newly visible rows, and again once layout has settled
        hydrateVisibleRows()
        DispatchQueue.main.async { [weak self] in
            self?.hydrateVisibleRows()
        }
    }

    private func rebuildRowIndex() {
        var index = [URL: Int](minimumCapacity: items.count)
        for (row, item) in items.enumerated() {
            index[item.url] = row
        }
        rowIndex = index
    }

    // MARK: - Anchor and Cursor

    /// Records which items the view model's anchor and cursor point at (call when they're known to
    /// index the rows shown).
    private func noteSelectionEnds() {
        guard deferredItems == nil else { return }
        let anchor = viewModel.selectionAnchorIndex
        let cursor = viewModel.lastSelectedIndex
        selectionEnds = SelectionEnds(
            anchor: anchor,
            anchorURL: items.indices.contains(anchor) ? items[anchor].url : nil,
            cursor: cursor,
            cursorURL: items.indices.contains(cursor) ? items[cursor].url : nil,
            selection: viewModel.selectedItems
        )
    }

    /// After the rows were re-sorted or reloaded: moves the anchor and cursor to the rows of the
    /// items they pointed at, so ⇧-click and ⇧↑/⇧↓ extend from the same item. Indexes the view
    /// model set since (with a new selection, e.g. after a paste) already refer to the new rows.
    private func moveSelectionEndsToNewRows() {
        guard let ends = selectionEnds, viewModel.selectedItems == ends.selection else { return }
        if viewModel.selectionAnchorIndex == ends.anchor, let url = ends.anchorURL, let row = rowIndex[url] {
            viewModel.selectionAnchorIndex = row
        }
        if viewModel.lastSelectedIndex == ends.cursor, let url = ends.cursorURL, let row = rowIndex[url] {
            viewModel.lastSelectedIndex = row
        }
        noteSelectionEnds()
    }

    static func rowsWithChangedContent(old: [FileItem], new: [FileItem], in rows: IndexSet) -> IndexSet {
        var changed = IndexSet()
        for row in rows where row < old.count && row < new.count {
            if old[row].contentVersion != new[row].contentVersion || old[row].creationDate != new[row].creationDate {
                changed.insert(row)
            }
        }
        return changed
    }

    /// Rows that currently have cell views (visible plus the table's prepared overdraw).
    func loadedRows() -> IndexSet {
        guard let tableView, !items.isEmpty else { return IndexSet() }
        var rows = IndexSet()
        for rect in [tableView.visibleRect, tableView.preparedContentRect] {
            let range = tableView.rows(in: rect)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let end = min(range.location + range.length, items.count)
            if range.location < end {
                rows.insert(integersIn: range.location..<end)
            }
        }
        return rows
    }

    /// Reloads the given rows, never recycling the name cell that is being edited.
    private func reloadRows(_ rows: IndexSet) {
        guard let tableView, !rows.isEmpty, tableView.numberOfColumns > 0 else { return }
        var rows = rows.filteredIndexSet { $0 < items.count }
        let allColumns = IndexSet(integersIn: 0..<tableView.numberOfColumns)

        if let editingRow = editingRow, rows.contains(editingRow) {
            rows.remove(editingRow)
            var otherColumns = allColumns
            otherColumns.remove(nameColumnIndex(in: tableView))
            if !otherColumns.isEmpty {
                tableView.reloadData(forRowIndexes: IndexSet(integer: editingRow), columnIndexes: otherColumns)
            }
        }
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: allColumns)
    }

    private var editingRow: Int? {
        guard isCurrentlyEditing, let url = currentEditingCell?.representedURL else { return nil }
        return rowIndex[url]
    }

    // MARK: - Scroll Position

    private struct ScrollAnchor {
        let url: URL
        let offset: CGFloat
        let folder: URL
    }

    /// The first visible row and its distance from the top of the visible area.
    private func captureScrollAnchor() -> ScrollAnchor? {
        guard let tableView, let clipView = tableView.enclosingScrollView?.contentView else { return nil }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0, visible.location < items.count else { return nil }
        let row = visible.location
        return ScrollAnchor(
            url: items[row].url,
            offset: tableView.rect(ofRow: row).minY - clipView.bounds.minY,
            folder: viewModel.currentPath
        )
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, anchor.folder == viewModel.currentPath,
              let row = rowIndex[anchor.url],
              let tableView, let scrollView = tableView.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        var bounds = clipView.bounds
        bounds.origin.y = tableView.rect(ofRow: row).minY - anchor.offset
        let target = clipView.constrainBoundsRect(bounds).origin
        guard abs(target.y - clipView.bounds.origin.y) > 0.5 else { return }
        clipView.scroll(to: target)
        scrollView.reflectScrolledClipView(clipView)
    }

    // MARK: - Display Settings

    struct DisplaySettings: Equatable {
        let fontSize: Double
        let iconSize: Double
        let showTags: Bool
        let showFileExtensions: Bool
    }

    /// Row height that fits the list's icon and font size settings.
    static func rowHeight(fontSize: Double, iconSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(fontSize))
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        return max(22, ceil(iconSize) + 2, textHeight + 4)
    }

    private func applyDisplaySettingsIfNeeded() {
        guard let tableView else { return }
        let settings = DisplaySettings(
            fontSize: appSettings.listFontSize,
            iconSize: appSettings.listIconSize,
            showTags: appSettings.showItemTags,
            showFileExtensions: appSettings.showFileExtensions
        )
        guard settings != lastDisplaySettings else { return }
        let isInitial = lastDisplaySettings == nil
        lastDisplaySettings = settings

        let height = Self.rowHeight(fontSize: settings.fontSize, iconSize: CGFloat(settings.iconSize))
        if tableView.rowHeight != height {
            tableView.rowHeight = height
        }
        if !isInitial {
            reloadRows(loadedRows())
        }
    }

    // MARK: - Cut Dimming

    /// Picks up the app-wide cut set (compared as a set, so cutting A then B is a change).
    /// Returns whether it changed.
    private func refreshCutURLs() -> Bool {
        let current = viewModel.cutItemURLs
        guard current != cutURLs else { return false }
        cutURLs = current
        return true
    }

    /// Re-dims the rows that have cells; other rows get their dimming when they're shown.
    private func applyCutDimmingToLoadedRows() {
        guard let tableView else { return }
        for row in loadedRows() {
            let alpha: CGFloat = viewModel.isItemCut(items[row]) ? 0.5 : 1.0
            for column in 0..<tableView.numberOfColumns {
                tableView.view(atColumn: column, row: row, makeIfNecessary: false)?.alphaValue = alpha
            }
        }
    }

    // MARK: - Inline Rename

    /// Called from updateNSView to check if we should start editing
    func checkForPendingRename() {
        guard let renamingURL = viewModel.renamingURL else {
            lastProcessedRenamingURL = nil
            return
        }

        // Don't re-process the same URL
        guard renamingURL != lastProcessedRenamingURL else { return }

        // Don't start if we're already editing
        guard !isCurrentlyEditing else { return }

        // Not in the table yet (e.g. a new folder whose row hasn't arrived): retry on a later update
        guard let row = rowIndex[renamingURL], let tableView = tableView else { return }
        lastProcessedRenamingURL = renamingURL

        // Scroll to make the row visible
        tableView.scrollRowToVisible(row)

        // Start editing after a delay for the view to settle. The row is looked up again then:
        // a directory event or re-sort may have moved it in the meantime.
        pendingRenameWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.beginEditing(url: renamingURL)
        }
        pendingRenameWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func beginEditing(url: URL) {
        pendingRenameWorkItem = nil
        guard viewModel.renamingURL == url, !isCurrentlyEditing, let tableView else { return }
        let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.name.rawValue))
        guard nameColumn >= 0, let row = rowIndex[url] else {
            // Row is gone for now; let a later update try again
            lastProcessedRenamingURL = nil
            return
        }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? FileNameCellView,
              cell.representedURL == url else {
            lastProcessedRenamingURL = nil
            return
        }
        currentEditingCell = cell
        cell.delegate = self
        cell.startEditing()
    }

    /// Commits an in-progress rename before a click elsewhere in the table is handled.
    func commitEditingForMouseDown() {
        guard let cell = currentEditingCell, cell.isEditing else { return }
        isCommittingForClick = true
        defer { isCommittingForClick = false }
        cell.commitEditingFromOutsideClick()
    }

    /// Ends editing state that outlived its field editor (so it can never block updates).
    private func reconcileEditingState() {
        guard let cell = currentEditingCell else { return }
        if cell.isEditing && !cell.isEditingActive {
            // Async: this runs during a SwiftUI update, where the cancel can't publish changes
            DispatchQueue.main.async { [weak cell] in
                guard let cell, cell.isEditing, !cell.isEditingActive else { return }
                cell.abandonEditing()
            }
        } else if !cell.isEditing {
            currentEditingCell = nil
        }
    }

    private func editingDidEnd() {
        currentEditingCell = nil
        lastProcessedRenamingURL = nil
        // Not synchronously: this runs inside the text field's end-editing callback
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCurrentlyEditing, let deferred = self.deferredItems else { return }
            self.deferredItems = nil
            self.applyItems(self.resolveFreshContent(deferred))
            self.syncSelectionFromViewModel()
        }
    }

    // MARK: - FileNameCellViewDelegate

    func fileNameCellView(_ cell: FileNameCellView, didRenameItem item: FileItem, to newName: String) {
        editingDidEnd()
        if isCommittingForClick {
            // The click that ended editing picks the selection
            let newURL = item.url.deletingLastPathComponent()
                .appendingPathComponent(FileOperationEngine.fileSystemName(forDisplayName: newName))
            clickCommittedRename = ClickCommittedRename(oldURL: item.url, newURL: newURL, expires: Date().addingTimeInterval(5))
        }
        viewModel.renameItem(item, to: newName)
        viewModel.renamingURL = nil
    }

    /// The view model's items are about to change. While a click-committed rename is pending, notes
    /// that a listing is being applied; once the listing with the renamed item is in, the view
    /// model has made its selection for it and nothing is pending any more.
    private func viewModelItemsWillChange() {
        guard clickCommittedRename != nil, !isApplyingViewModelListing else { return }
        isApplyingViewModelListing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isApplyingViewModelListing = false
            if let rename = self.clickCommittedRename, self.viewModel.items.contains(where: { $0.url == rename.newURL }) {
                self.clickCommittedRename = nil
            }
        }
    }

    /// The view model is about to select `newSelection` (its old selection is still current). After a
    /// rename committed by a click, a listing reload selecting just the renamed item is undone: the
    /// click's selection is restored, with the renamed item (if it was in it) under its new name.
    private func viewModelSelectionWillChange(to newSelection: Set<FileItem>) {
        guard let rename = clickCommittedRename else { return }
        guard rename.expires > Date() else {
            clickCommittedRename = nil
            return
        }
        // Only the selection a reload applies (not the user selecting the renamed item)
        guard isApplyingViewModelListing, newSelection.count == 1, newSelection.first?.url == rename.newURL else { return }
        clickCommittedRename = nil
        let clickSelection = Set(viewModel.selectedItems.map { $0.url == rename.oldURL ? rename.newURL : $0.url })
        guard clickSelection != [rename.newURL] else { return }
        let ends = selectionEnds
        // Not from inside the publisher's willSet: the view model is still storing its value
        DispatchQueue.main.async { [weak self] in
            guard let self, Set(self.viewModel.selectedItems.map(\.url)) == [rename.newURL] else { return }
            let current = self.viewModel.filteredItems
            let restored = current.filter { clickSelection.contains($0.url) }
            self.viewModel.selectedItems = Set(restored)
            let urlAt = { (url: URL?) in url.map { $0 == rename.oldURL ? rename.newURL : $0 } }
            if let anchor = urlAt(ends?.anchorURL), let index = current.firstIndex(where: { $0.url == anchor }) {
                self.viewModel.selectionAnchorIndex = index
            }
            if let cursor = urlAt(ends?.cursorURL), let index = current.firstIndex(where: { $0.url == cursor }) {
                self.viewModel.lastSelectedIndex = index
            }
        }
    }

    func fileNameCellViewDidCancelRename(_ cell: FileNameCellView) {
        editingDidEnd()
        viewModel.renamingURL = nil
    }

    func fileNameCellView(_ cell: FileNameCellView, commitRenameAndMoveNext item: FileItem, newName: String) {
        editingDidEnd()
        viewModel.commitRenameAndNext(currentItem: item, newName: newName)
    }

    func fileNameCellView(_ cell: FileNameCellView, commitRenameAndMovePrevious item: FileItem, newName: String) {
        editingDidEnd()
        viewModel.commitRenameAndPrevious(currentItem: item, newName: newName)
    }

    func fileNameCellView(_ cell: FileNameCellView, didAbortEditingOf item: FileItem) {
        if currentEditingCell === cell || currentEditingCell == nil {
            editingDidEnd()
        }
        if viewModel.renamingURL == item.url {
            viewModel.renamingURL = nil
        }
    }

    // MARK: - Click Handling

    func handleRowClick(row: Int, event: NSEvent) {
        guard row >= 0, row < items.count else { return }
        guard let tableView = tableView else { return }

        let item = items[row]

        // ⌘-click toggles natively in NSTableView (via tableViewSelectionDidChange);
        // calling handleSelection here too would toggle twice.
        if event.modifierFlags.contains(.command) {
            viewModel.cancelPendingRename()
            if viewModel.renamingURL != nil {
                viewModel.renamingURL = nil
            }
            return
        }

        // If clicking on an already-selected item without modifiers,
        // preserve the multi-selection (for potential drag)
        // handleSelection would reset to single selection otherwise
        if viewModel.selectedItems.count > 1 && viewModel.selectedItems.contains(item) {
            if event.clickCount == 1 {
                multiSelectionClick = (row, Set(viewModel.selectedItems.map(\.url)), event.timestamp)
            }
            return
        }

        // Determine if click was on the text area (for Finder-style rename behavior)
        let clickedOnTextArea = isClickOnTextArea(event: event, row: row, tableView: tableView)

        // Use handleSelection to get Finder-style click-to-rename behavior (plain clicks only)
        viewModel.handleSelection(
            item: item,
            index: row,
            in: items,
            withShift: false,
            withCommand: false,
            clickedOnTextArea: clickedOnTextArea
        )
    }

    /// ⇧-click: select from the view model's anchor to `row`.
    func handleShiftClick(row: Int) {
        guard row >= 0, row < items.count else { return }
        viewModel.cancelPendingRename()
        if viewModel.renamingURL != nil {
            viewModel.renamingURL = nil
        }
        if viewModel.selectedItems.isEmpty || !items.indices.contains(viewModel.selectionAnchorIndex) {
            viewModel.selectionAnchorIndex = row
        }
        viewModel.selectRange(to: row, in: items)
        syncSelectionFromViewModel(allowScroll: false)
        lastSyncedSelection = viewModel.selectedItems
        noteSelectionEnds()
    }

    /// Handle click on empty space (below all rows) - deselect all items
    func handleEmptySpaceClick() {
        // Call callback first (used by CoverFlow to set userClearedSelection before clearing items)
        onEmptySpaceClick?()
        if !viewModel.selectedItems.isEmpty {
            viewModel.selectedItems.removeAll()
        }
        viewModel.cancelPendingRename()
    }

    func beginMouseSelection(row: Int) {
        activeMouseSelection = row
    }

    func endMouseSelection() {
        activeMouseSelection = nil
    }

    /// Determine if a click event was on the text area of the name column
    private func isClickOnTextArea(event: NSEvent, row: Int, tableView: NSTableView) -> Bool {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let clickedColumn = tableView.column(at: point)

        // If not clicking on a column or not on the name column, it's not on text area
        guard clickedColumn >= 0 else { return false }
        let columnId = tableView.tableColumns[clickedColumn].identifier.rawValue
        guard columnId == ListColumn.name.rawValue else { return false }

        // Get the cell rect for this row/column
        let cellRect = tableView.frameOfCell(atColumn: clickedColumn, row: row)

        // Icon area: 4pt leading padding + icon size + 6pt trailing padding
        let iconSize = appSettings.listIconSizeValue
        let iconAreaWidth: CGFloat = 4 + iconSize + 6

        // Check if click was past the icon area (on the text portion)
        let clickXInCell = point.x - cellRect.minX
        return clickXInCell > iconAreaWidth
    }

    // MARK: - Column Setup

    func setupColumns() {
        applyColumnConfiguration()
    }

    private func makeTableColumn(for settings: ColumnSettings) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(settings.column.rawValue))
        column.title = settings.column.rawValue
        column.width = settings.width
        column.minWidth = settings.column.minWidth
        column.maxWidth = 600
        column.isEditable = false
        column.resizingMask = .userResizingMask

        // Sort descriptor - set ascending based on column type
        // NSTableView will toggle direction automatically on subsequent clicks
        let usesStringCompare: Bool
        switch settings.column {
        case .name, .kind, .tags, .cloudStatus:
            usesStringCompare = true
        case .dateModified, .dateCreated, .size:
            usesStringCompare = false
        }
        column.sortDescriptorPrototype = NSSortDescriptor(
            key: settings.column.rawValue,
            ascending: settings.column.defaultSortDirection == .ascending,
            selector: usesStringCompare ? #selector(NSString.localizedStandardCompare(_:)) : nil
        )

        // Configure header cell
        column.headerCell.alignment = .left
        return column
    }

    /// The column layout this list shows: the folder's own (per-folder memory) or the shared one.
    private var currentColumns: [ColumnSettings] {
        viewModel.folderColumns ?? columnConfig.columns
    }

    /// Makes the table's columns match the configuration in place (visibility, order, width)
    /// instead of rebuilding them, so nothing is reloaded for a width or order change.
    private func applyColumnConfiguration() {
        guard let tableView = tableView else { return }
        let columns = currentColumns
        let desired = columns.filter(\.isVisible)
        let desiredIDs = Set(desired.map { $0.column.rawValue })

        isApplyingColumnLayout = true
        defer { isApplyingColumnLayout = false }

        var columnsChanged = false
        for column in tableView.tableColumns where !desiredIDs.contains(column.identifier.rawValue) {
            tableView.removeTableColumn(column)
            columnsChanged = true
        }

        var addedIDs: [NSUserInterfaceItemIdentifier] = []
        for (targetIndex, settings) in desired.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier(settings.column.rawValue)
            var currentIndex = tableView.column(withIdentifier: identifier)
            if currentIndex < 0 {
                tableView.addTableColumn(makeTableColumn(for: settings))
                currentIndex = tableView.numberOfColumns - 1
                addedIDs.append(identifier)
                columnsChanged = true
            }
            if currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
            let column = tableView.tableColumns[targetIndex]
            if abs(column.width - settings.width) > 0.5 {
                column.width = settings.width
            }
        }
        appliedColumns = columns

        if columnsChanged {
            // The sort column may have just been added
            lastSortColumn = nil
            lastSortDirection = nil
        }
        if !addedIDs.isEmpty {
            let addedIndexes = IndexSet(addedIDs.map { tableView.column(withIdentifier: $0) }.filter { $0 >= 0 })
            let rows = loadedRows()
            if !rows.isEmpty, !addedIndexes.isEmpty {
                tableView.reloadData(forRowIndexes: rows, columnIndexes: addedIndexes)
            }
            if addedIDs.contains(NSUserInterfaceItemIdentifier(ListColumn.cloudStatus.rawValue)) {
                requestCloudStatusForVisibleRows()
            }
        }
    }

    /// Shows the view model's sort (this pane's) in the header.
    private func applySortDescriptorToTableView() {
        guard let tableView = tableView else { return }
        let sort = viewModel.sortState

        // Only update if sort actually changed
        guard lastSortColumn != sort.column ||
              lastSortDirection != sort.direction else { return }

        // Find the column matching our current sort. Sorted by a hidden column (e.g. from the
        // toolbar's Sort menu): no header shows a sort. Showing the column re-applies it.
        let sortColumnID = sort.column.rawValue
        let prototype = tableView.tableColumns.first(where: { $0.identifier.rawValue == sortColumnID })?.sortDescriptorPrototype
        let descriptors = prototype.map {
            [NSSortDescriptor(key: $0.key, ascending: sort.direction == .ascending, selector: $0.selector)]
        } ?? []

        // Set this as the active sort descriptor (prevent feedback loop)
        isUpdatingSort = true
        tableView.sortDescriptors = descriptors
        lastSortColumn = sort.column
        lastSortDirection = sort.direction
        updateSortIndicator()
        isUpdatingSort = false
    }

    func syncColumnsIfNeeded() {
        // While a resize/reorder drag is uncommitted the table is ahead of the configuration
        if columnCommitWorkItem == nil && currentColumns != appliedColumns {
            applyColumnConfiguration()
        }
        applySortDescriptorToTableView()
    }

    private func updateSortIndicator() {
        guard let tableView = tableView else { return }

        // Clear all indicators
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }

        // Set indicator on sorted column
        let sort = viewModel.sortState
        if let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == sort.column.rawValue }) {
            let image = sort.direction == .ascending
                ? NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Ascending")
                : NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Descending")
            tableView.setIndicatorImage(image, in: column)
            tableView.highlightedTableColumn = column
        } else {
            tableView.highlightedTableColumn = nil
        }
    }

    // MARK: - Column Resize/Move Notifications

    // Live resizes and reorders stay local to the table; the configuration is updated (and
    // published/persisted) once, after the mouse button is released.

    @objc func columnDidResize(_ notification: Notification) {
        guard !isApplyingColumnLayout else { return }
        scheduleColumnLayoutCommit()
    }

    @objc func columnDidMove(_ notification: Notification) {
        guard !isApplyingColumnLayout else { return }
        scheduleColumnLayoutCommit()
    }

    private func scheduleColumnLayoutCommit() {
        if let pending = columnCommitWorkItem {
            pending.cancel()
        } else {
            // The pane and folder the drag happened in
            columnCommitViewModel = viewModel
            columnCommitFolderKey = viewModel.currentPath.standardizedPathKey
        }
        let work = DispatchWorkItem { [weak self] in
            self?.commitColumnLayoutWhenMouseUp()
        }
        columnCommitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.columnCommitDelay, execute: work)
    }

    private func commitColumnLayoutWhenMouseUp() {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            scheduleColumnLayoutCommit()
            return
        }
        columnCommitWorkItem = nil
        guard columnCommitViewModel === viewModel,
              columnCommitFolderKey == viewModel.currentPath.standardizedPathKey else {
            // The pane moved to another folder before the commit: show that folder's layout
            // rather than storing the old one there
            syncColumnsIfNeeded()
            return
        }
        commitColumnLayout()
    }

    /// Stores the table's current column order and widths in the configuration.
    func commitColumnLayout() {
        guard let tableView = tableView else { return }
        var order: [ListColumn] = []
        var widths: [ListColumn: CGFloat] = [:]
        for column in tableView.tableColumns {
            guard let listColumn = ListColumn(rawValue: column.identifier.rawValue) else { continue }
            order.append(listColumn)
            widths[listColumn] = column.width
        }
        applyUserColumnChange(
            shown: ListColumnConfigManager.columns(currentColumns, applyingVisibleOrder: order, widths: widths),
            // The shared layout takes the new widths and order, not this folder's column visibility
            shared: ListColumnConfigManager.columns(columnConfig.columns, reordering: order, widths: widths)
        )
        appliedColumns = currentColumns
    }

    /// Applies a column change the user made in this list: `shown` is the layout the list now
    /// shows (with per-folder memory on, saved as this folder's), `shared` the change applied to
    /// the shared layout that folders without their own use (one publish, one debounced save).
    private func applyUserColumnChange(shown: [ColumnSettings], shared: [ColumnSettings]) {
        if columnConfig.columns != shared {
            columnConfig.columns = shared
        }
        viewModel.columnLayoutChangedByUser(shown)
    }

    // MARK: - Header Menu

    private var headerMenuSet = false
    private var headerMenu: NSMenu?
    private var rowMenu: NSMenu?

    func setupHeaderMenu() {
        guard !headerMenuSet else { return }
        guard let tableView = tableView,
              let headerView = tableView.headerView else { return }

        // Create menu for header - this is the right-click context menu for columns
        let menu = NSMenu(title: "Columns")
        menu.delegate = self
        menu.autoenablesItems = false
        headerMenu = menu

        // Set menu on header view for right-click
        headerView.menu = menu
        headerMenuSet = true
    }

    func setupRowMenu() {
        guard let tableView = tableView else { return }
        guard rowMenu == nil else { return }

        // Create menu for rows - context menu for file items
        let menu = NSMenu(title: "File Actions")
        menu.delegate = self
        menu.autoenablesItems = false
        rowMenu = menu

        // Set menu on table view for row right-click
        tableView.menu = menu

        // Also set on enclosing scroll view for when table is empty
        if let scrollView = tableView.enclosingScrollView {
            scrollView.menu = menu
        }
    }

    func ensureHeaderMenu() {
        if !headerMenuSet {
            setupHeaderMenu()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn,
              row < items.count else { return nil }

        let item = items[row]
        let columnID = tableColumn.identifier.rawValue

        guard let listColumn = ListColumn(rawValue: columnID) else { return nil }

        let cellView: NSTableCellView

        switch listColumn {
        case .name:
            cellView = makeNameCell(for: item, tableView: tableView)
        case .dateModified:
            cellView = makeDateCell(for: item.modificationDate, tableView: tableView, identifier: columnID)
        case .dateCreated:
            cellView = makeDateCell(for: item.creationDate, tableView: tableView, identifier: columnID)
        case .size:
            cellView = makeSizeCell(for: item, tableView: tableView)
        case .kind:
            cellView = makeKindCell(for: item, tableView: tableView)
        case .tags:
            cellView = makeTagsCell(for: item, tableView: tableView)
        case .cloudStatus:
            cellView = makeCloudStatusCell(for: item, tableView: tableView)
        }

        // Dim cut items (Finder-style visual feedback)
        cellView.alphaValue = viewModel.isItemCut(item) ? 0.5 : 1.0

        return cellView
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return EmphasizedTableRowView()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        // Type-select matches names only (not dates or sizes)
        guard tableColumn?.identifier.rawValue == ListColumn.name.rawValue, row < items.count else { return nil }
        return items[row].displayName
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        guard let tableView = tableView else { return }
        let selectedRows = tableView.selectedRowIndexes

        var selectedItems = Set<FileItem>(minimumCapacity: selectedRows.count)
        for row in selectedRows where row < items.count {
            selectedItems.insert(items[row])
        }

        let positions = Self.anchorAndCursor(
            selectedRows: selectedRows,
            previousAnchor: viewModel.selectionAnchorIndex,
            mouseDownRow: activeMouseSelection,
            currentMouseRow: activeMouseSelection == nil ? nil : currentMouseRow()
        )

        isUpdatingSelection = true
        if viewModel.selectedItems != selectedItems {
            viewModel.selectedItems = selectedItems
        }
        // Keep the anchor and cursor in step with the table so keyboard navigation (in all
        // view modes) continues from where the user clicked or moved.
        if let positions {
            viewModel.selectionAnchorIndex = positions.anchor
            viewModel.lastSelectedIndex = positions.cursor
        }
        lastSyncedSelection = selectedItems
        noteSelectionEnds()
        isUpdatingSelection = false
    }

    /// Row under the mouse during a click or drag-select.
    private func currentMouseRow() -> Int? {
        guard let tableView, let event = NSApp.currentEvent, event.window === tableView.window else { return nil }
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    /// Anchor (fixed end) and cursor (moving end) after the table changed the selection itself.
    /// - mouseDownRow: the row a click/drag started on (-1 = empty space), nil for keyboard changes.
    static func anchorAndCursor(selectedRows: IndexSet, previousAnchor: Int, mouseDownRow: Int?, currentMouseRow: Int?) -> (anchor: Int, cursor: Int)? {
        guard let first = selectedRows.first, let last = selectedRows.last else {
            // Nothing selected: a click still moves the anchor (⌘-click deselecting the last item)
            if let mouseDownRow, mouseDownRow >= 0 { return (mouseDownRow, mouseDownRow) }
            return nil
        }

        if let mouseDownRow {
            let cursor = currentMouseRow.map { min(max($0, first), last) }
            if mouseDownRow >= 0 {
                // Click or drag that started on a row: that row is the anchor
                return (mouseDownRow, cursor ?? mouseDownRow)
            }
            // Drag-select that started in empty space: the anchor is the far end
            let resolvedCursor = cursor ?? last
            let anchor = abs(first - resolvedCursor) > abs(last - resolvedCursor) ? first : last
            return (anchor, resolvedCursor)
        }

        // Keyboard (native navigation or type-select)
        if first == last { return (first, first) }
        if selectedRows.contains(previousAnchor) {
            let cursor = previousAnchor == last ? first : last
            return (previousAnchor, cursor)
        }
        return (first, last)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Prevent feedback loop when we programmatically set sort descriptors
        guard !isUpdatingSort else { return }

        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = ListColumn(rawValue: key) else { return }

        let newSort = SortState(column: column, direction: descriptor.ascending ? .ascending : .descending)

        // Only update if something actually changed. Sorts this pane only.
        if viewModel.sortState != newSort {
            isUpdatingSort = true
            viewModel.setSort(newSort)
            lastSortColumn = newSort.column
            lastSortDirection = newSort.direction
            updateSortIndicator()
            isUpdatingSort = false
        }
    }

    // MARK: - Selection Sync

    /// Selects the view model's selection (matched by URL, so it survives reloads that create new
    /// items). Scrolls to the cursor only when the selection itself changed, not on reloads.
    func syncSelectionFromViewModel(allowScroll: Bool = true) {
        guard !isUpdatingSelection else { return }
        guard let tableView = tableView else { return }

        let selected = viewModel.selectedItems
        var rows = IndexSet()
        for item in selected {
            if let row = rowIndex[item.url] {
                rows.insert(row)
            }
        }

        if rows != tableView.selectedRowIndexes {
            isUpdatingSelection = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        guard allowScroll else { return }
        let selectionChanged = selected != lastSyncedSelection
        lastSyncedSelection = selected
        if selectionChanged, let row = cursorRow(in: rows) {
            tableView.scrollRowToVisible(row)
        }
    }

    /// The lead row of the selection (the clicked or keyboard-moved end), else the first selected row.
    private func cursorRow(in rows: IndexSet) -> Int? {
        guard !rows.isEmpty else { return nil }
        if let primary = viewModel.primarySelectedItem, let row = rowIndex[primary.url], rows.contains(row) {
            return row
        }
        return rows.first
    }

    // MARK: - Actions

    @objc func tableViewDoubleClicked(_ sender: Any?) {
        guard let tableView = tableView else { return }
        openForDoubleClick(row: tableView.clickedRow, at: NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }

    /// Like Return, a double-click on a selected item opens the whole selection (Finder).
    func openForDoubleClick(row clickedRow: Int, at time: TimeInterval) {
        guard clickedRow >= 0, clickedRow < items.count else { return }

        let item = items[clickedRow]
        var selection = Set(viewModel.selectedItems.map(\.url))
        // The first click of the double-click reduced a multi-selection to this row: open them all
        if let click = multiSelectionClick, click.row == clickedRow, click.urls.contains(item.url),
           time - click.time <= NSEvent.doubleClickInterval + 0.1 {
            selection = click.urls
        }
        multiSelectionClick = nil
        guard selection.count > 1, selection.contains(item.url) else {
            viewModel.openItem(item)
            return
        }

        let targets = items.filter { selection.contains($0.url) }
        if Set(viewModel.selectedItems.map(\.url)) != selection {
            viewModel.selectedItems = Set(targets)
            viewModel.lastSelectedIndex = clickedRow
            syncSelectionFromViewModel(allowScroll: false)
        }
        FileListActions.open(targets, primary: item, viewModel: viewModel)
    }

    // MARK: - Keyboard Actions

    func triggerQuickLook() {
        guard let item = viewModel.primarySelectedItem else {
            NSSound.beep()
            return
        }
        let window = tableView?.window
        // Use async version to avoid blocking main thread during archive extraction
        viewModel.previewURL(for: item) { [weak self] previewURL in
            guard let previewURL = previewURL else {
                NSSound.beep()
                return
            }
            QuickLookControllerView.shared.togglePreview(for: previewURL, in: window) { [weak self] offset in
                self?.navigateSelection(by: offset)
            }
        }
    }

    func openSelectedItems() {
        FileListActions.open(viewModel.orderedSelectedItems, primary: viewModel.primarySelectedItem, viewModel: viewModel)
    }

    private func navigateSelection(by offset: Int) {
        guard let tableView = tableView, !items.isEmpty else { return }
        let currentRow = cursorRow(in: tableView.selectedRowIndexes) ?? -1
        let newRow = max(0, min(items.count - 1, currentRow + offset))
        if newRow != currentRow {
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    // MARK: - Scroll & Lazy Hydration

    @objc func scrollViewDidScroll(_ notification: Notification) {
        isLiveScrolling = true
        // Debounce hydration during active scrolling
        hydrationDebounceTimer?.invalidate()
        hydrationDebounceTimer = Timer.scheduledTimer(withTimeInterval: hydrationDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hydrateVisibleRows()
            }
        }
    }

    @objc func scrollViewDidEndScroll(_ notification: Notification) {
        // Immediately hydrate when scroll ends
        hydrationDebounceTimer?.invalidate()
        isLiveScrolling = false
        hydrateVisibleRows()
        loadThumbnailsForVisibleRows()
    }

    @objc func handleHydrationCompleted(_ notification: Notification) {
        guard tableView != nil else { return }
        // Same rows, fresher content: reloads only the loaded rows whose content changed.
        // A new order (e.g. sorted by date) arrives with the next SwiftUI update.
        applyItems(resolveFreshContent(items))
        requestCloudStatusForVisibleRows()
    }

    @objc func handleFocusFileList(_ notification: Notification) {
        // Focus the table view (e.g., after pressing Escape in search field). Only the table in the
        // key window, and only one that's on screen; the poster may also name a window or view model.
        guard takesFocusRequests,
              let tableView = tableView,
              let window = tableView.window,
              window.isKeyWindow,
              !tableView.isHiddenOrHasHiddenAncestor,
              tableView.visibleRect.size.height > 0 else { return }
        if let targetWindow = notification.object as? NSWindow, targetWindow !== window { return }
        if let targetViewModel = notification.object as? FileBrowserViewModel, targetViewModel !== viewModel { return }
        window.makeFirstResponder(tableView)
    }

    private func visibleRowRange(buffer: Int = 0) -> (visible: Range<Int>, extended: Range<Int>)? {
        guard let tableView = tableView else { return nil }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return nil }
        let start = visibleRows.location
        let end = min(start + visibleRows.length, items.count)
        guard start < end else { return nil }
        return (start..<end, max(0, start - buffer)..<min(items.count, end + buffer))
    }

    /// Hydrate metadata (and cloud status, when that column is shown) for currently visible rows
    func hydrateVisibleRows() {
        guard let ranges = visibleRowRange(buffer: 10) else { return }
        let newRange = ranges.extended

        requestCloudStatus(forRows: newRange)

        // Check if range actually changed
        if newRange == lastVisibleRange { return }
        lastVisibleRange = newRange

        // Collect URLs that need hydration
        var urlsToHydrate: [URL] = []
        for i in newRange {
            let item = items[i]
            if viewModel.needsHydration(item) {
                urlsToHydrate.append(item.url)
            }
        }

        if !urlsToHydrate.isEmpty {
            viewModel.hydrateMetadata(for: urlsToHydrate)
        }

        // Also preheat thumbnails and tags
        preheat(visibleStart: ranges.visible.lowerBound, visibleEnd: ranges.visible.upperBound)
    }

    private func requestCloudStatusForVisibleRows() {
        guard let ranges = visibleRowRange(buffer: 10) else { return }
        requestCloudStatus(forRows: ranges.extended)
    }

    private var isCloudStatusColumnVisible: Bool {
        guard let tableView else { return false }
        return tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.cloudStatus.rawValue)) >= 0
    }

    /// Loads iCloud status for the given rows while the iCloud Status column is shown.
    private func requestCloudStatus(forRows rows: Range<Int>) {
        guard isCloudStatusColumnVisible else { return }
        var urls: [URL] = []
        for row in rows where row < items.count {
            let item = items[row]
            // Wait for metadata first: hydrating metadata replaces the item, dropping a cloud status
            // loaded before it.
            guard item.hasMetadata, item.cloudStatus == nil,
                  !requestedCloudStatusURLs.contains(item.url), item.isInICloud else { continue }
            urls.append(item.url)
        }
        guard !urls.isEmpty else { return }
        requestedCloudStatusURLs.formUnion(urls)
        viewModel.hydrateCloudStatus(for: urls)
    }

    private func loadThumbnailsForVisibleRows() {
        guard let ranges = visibleRowRange() else { return }
        for row in ranges.visible {
            let item = items[row]
            if !thumbnails.contains(item.url), let cell = nameCell(atRow: row) {
                // Replace the scrolling placeholder; the thumbnail follows when it's ready
                cell.setIcon(item.icon)
            }
            loadThumbnailIfNeeded(for: item)
        }
    }

    /// Preheat thumbnails and tags for rows coming into view (like PHCachingImageManager)
    private func preheat(visibleStart: Int, visibleEnd: Int) {
        let preheatStart = max(0, visibleStart - preheatBuffer)
        let preheatEnd = min(items.count, visibleEnd + preheatBuffer)

        guard preheatStart < preheatEnd else { return }

        let newPreheatRange = preheatStart..<preheatEnd
        let oldPreheatRange = lastPreheatRange ?? 0..<0
        lastPreheatRange = newPreheatRange

        cancelThumbnailRequests(forRows: oldPreheatRange.filter { !newPreheatRange.contains($0) })

        var tagURLs: [URL] = []
        for row in newPreheatRange where !oldPreheatRange.contains(row) {
            let item = items[row]
            if !item.isDirectory {
                loadThumbnailIfNeeded(for: item)
            }
            if appSettings.showItemTags, Self.hasReadableTags(item) {
                tagURLs.append(item.url)
            }
        }
        requestTags(for: tagURLs)
    }

    // MARK: - Tags

    private static func hasReadableTags(_ item: FileItem) -> Bool {
        !item.isFromArchive && item.url.isFileURL
    }

    /// Tags to display, or nil while they're being read in the background (no disk reads here).
    func displayTags(for item: FileItem) -> [String]? {
        guard appSettings.showItemTags, Self.hasReadableTags(item) else { return [] }
        if loadedTagURLs.contains(item.url) {
            return item.tags  // FileTagManager's cache is warm
        }
        requestTags(for: [item.url])
        return nil
    }

    private func requestTags(for urls: [URL]) {
        let needed = urls.filter { !loadedTagURLs.contains($0) && !pendingTagURLs.contains($0) }
        guard !needed.isEmpty else { return }
        pendingTagURLs.formUnion(needed)
        let generation = tagGeneration
        Self.tagQueue.async { [weak self] in
            let results = needed.map { ($0, FileTagManager.getTags(for: $0)) }
            DispatchQueue.main.async {
                self?.tagsLoaded(results, generation: generation)
            }
        }
    }

    private func tagsLoaded(_ results: [(URL, [String])], generation: Int) {
        // Read before a tag refresh: those rows were requested again
        guard generation == tagGeneration else { return }
        for (url, tags) in results {
            pendingTagURLs.remove(url)
            loadedTagURLs.insert(url)
            if let row = rowIndex[url] {
                updateTagViews(row: row, tags: tags)
            }
        }
    }

    /// Tags may have changed (refresh, edits elsewhere): the loaded rows re-read theirs in the
    /// background and keep showing the current ones meanwhile; other rows read theirs when shown.
    /// Never reads tags here: this runs during a SwiftUI update.
    private func reloadTagsForLoadedRows() {
        tagGeneration &+= 1
        loadedTagURLs.removeAll()
        pendingTagURLs.removeAll()
        guard appSettings.showItemTags else { return }
        let urls = loadedRows().compactMap { row in Self.hasReadableTags(items[row]) ? items[row].url : nil }
        guard !urls.isEmpty else { return }
        // Next turn, together with the rows this update configures
        DispatchQueue.main.async { [weak self] in
            self?.requestTags(for: urls)
        }
    }

    private func updateTagViews(row: Int, tags: [String]) {
        guard let tableView else { return }
        nameCell(atRow: row)?.setTags(tags, showTags: appSettings.showItemTags)
        let tagsColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.tags.rawValue))
        if tagsColumn >= 0, let cell = tableView.view(atColumn: tagsColumn, row: row, makeIfNecessary: false) as? TagsCellView {
            cell.configure(tags: tags, appSettings: appSettings)
        }
    }

    // MARK: - Cell Factories

    private func nameCell(atRow row: Int) -> FileNameCellView? {
        guard let tableView, row < items.count else { return nil }
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(ListColumn.name.rawValue))
        guard column >= 0,
              let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? FileNameCellView,
              cell.representedURL == items[row].url else { return nil }
        return cell
    }

    private func makeNameCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("NameCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileNameCellView
            ?? FileNameCellView()
        cell.identifier = identifier
        cell.delegate = self

        let thumbnail = cachedThumbnail(for: item) ?? (isLiveScrolling ? item.placeholderIcon : item.icon)
        cell.configure(item: item, thumbnail: thumbnail, tags: displayTags(for: item), appSettings: appSettings)

        // Load thumbnail if needed
        loadThumbnailIfNeeded(for: item)

        return cell
    }

    private func makeDateCell(for date: Date?, tableView: NSTableView, identifier: String) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier + "Cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DateCellView
            ?? DateCellView()
        cell.identifier = id
        cell.configure(date: date, appSettings: appSettings)
        return cell
    }

    private func makeSizeCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("SizeCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SizeCellView
            ?? SizeCellView()
        cell.identifier = identifier
        cell.configure(item: item, appSettings: appSettings)
        return cell
    }

    private func makeKindCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("KindCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KindCellView
            ?? KindCellView()
        cell.identifier = identifier
        cell.configure(item: item, appSettings: appSettings)
        return cell
    }

    private func makeTagsCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("TagsCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? TagsCellView
            ?? TagsCellView()
        cell.identifier = identifier
        cell.configure(tags: displayTags(for: item), appSettings: appSettings)
        return cell
    }

    private func makeCloudStatusCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("CloudStatusCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CloudStatusCellView
            ?? CloudStatusCellView()
        cell.identifier = identifier
        cell.configure(item: item)
        return cell
    }

    // MARK: - Thumbnail Loading

    private func cachedThumbnail(for item: FileItem) -> NSImage? {
        thumbnails.image(for: item)
    }

    private func storeThumbnail(_ image: NSImage, for item: FileItem) {
        thumbnails.store(image, for: item)
        pruneThumbnails()
        // Update the cell in place: no reload, so a cell being edited is never recycled
        if let row = rowIndex[item.url], let cell = nameCell(atRow: row) {
            cell.setIcon(image)
        }
    }

    /// Keeps the thumbnail store bounded to the rows around the visible ones.
    private func pruneThumbnails(force: Bool = false) {
        guard force || thumbnails.isOverLimit else { return }
        let keep = visibleRowRange(buffer: preheatBuffer * 2)?.extended ?? 0..<0
        thumbnails.prune { url in
            guard let row = rowIndex[url] else { return false }
            return keep.contains(row)
        }
    }

    // Item-based APIs throughout: they key on the item's metadata instead of re-reading the file.
    private func loadThumbnailIfNeeded(for item: FileItem) {
        let url = item.url
        let targetPixelSize = Self.thumbnailPixelSize

        if cachedThumbnail(for: item) != nil { return }
        if thumbnailRequests[url] != nil { return }
        if let cached = thumbnailCache.cachedThumbnail(for: item, maxPixelSize: targetPixelSize) {
            storeThumbnail(cached, for: item)
            return
        }
        if thumbnailCache.hasFailed(item: item) {
            if isLiveScrolling {
                return
            }
            storeThumbnail(item.icon, for: item)
            return
        }

        // The completion runs on the main queue, or synchronously (returning no token) when the
        // answer is already known. Only this request's own token is forgotten: a cancelled one can
        // report after a newer request for the same file was made.
        var requestToken: ThumbnailRequestToken?
        let token = thumbnailCache.requestThumbnail(for: item, maxPixelSize: targetPixelSize, owner: thumbnailOwner) { [weak self] result in
            guard let self = self else { return }
            if let requestToken, self.thumbnailRequests[url] == requestToken {
                self.thumbnailRequests[url] = nil
            }
            switch result {
            case .loaded(let image):
                self.storeThumbnail(image, for: item)
            case .failed:
                // Retried when scrolling ends
                if !self.isLiveScrolling {
                    self.storeThumbnail(item.icon, for: item)
                }
            case .cancelled:
                break
            }
        }
        if let token {
            requestToken = token
            thumbnailRequests[url] = token
        }
    }

    /// Cancels thumbnail requests for rows that scrolled out of the preheat range.
    private func cancelThumbnailRequests(forRows rows: [Int]) {
        for row in rows where row < items.count {
            if let token = thumbnailRequests.removeValue(forKey: items[row].url) {
                thumbnailCache.cancel(token)
            }
        }
    }

    private func nameColumnIndex(in tableView: NSTableView) -> Int {
        if let index = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == ListColumn.name.rawValue }) {
            return index
        }
        return 0
    }
}

// MARK: - NSMenuDelegate for Menus

extension FileTableCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Determine which menu is being updated
        if menu === headerMenu {
            buildHeaderMenu(menu)
        } else if menu === rowMenu {
            buildRowMenu(menu)
        }
    }

    private func buildHeaderMenu(_ menu: NSMenu) {
        let titleItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let columns = currentColumns
        for column in ListColumn.allCases {
            let isVisible = columns.first(where: { $0.column == column })?.isVisible ?? false
            let item = NSMenuItem(
                title: column.rawValue,
                action: #selector(toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column
            item.state = isVisible ? .on : .off
            item.isEnabled = column != .name // Name always visible
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(
            title: "Reset to Defaults",
            action: #selector(resetColumnsToDefaults(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)
    }

    /// Finder: right-clicking an item inside the selection acts on the whole selection;
    /// right-clicking outside it selects just that item first.
    func prepareContextMenuTargets(clickedRow: Int) {
        guard let tableView, clickedRow >= 0, clickedRow < items.count else {
            contextMenuItems = []
            contextMenuClickedItem = nil
            return
        }
        let clickedItem = items[clickedRow]
        if !tableView.selectedRowIndexes.contains(clickedRow) {
            isUpdatingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            viewModel.selectedItems = [clickedItem]
            viewModel.selectionAnchorIndex = clickedRow
            viewModel.lastSelectedIndex = clickedRow
            lastSyncedSelection = viewModel.selectedItems
            noteSelectionEnds()
            isUpdatingSelection = false
        }
        contextMenuItems = tableView.selectedRowIndexes.compactMap { $0 < items.count ? items[$0] : nil }
        contextMenuClickedItem = clickedItem
    }

    var contextMenuTargets: [FileItem] { contextMenuItems }

    private func buildRowMenu(_ menu: NSMenu) {
        guard let tableView = tableView else { return }
        let clickedRow = tableView.clickedRow

        // If clicked on empty space, show folder-level menu
        guard clickedRow >= 0, clickedRow < items.count else {
            buildEmptySpaceMenu(menu)
            return
        }

        prepareContextMenuTargets(clickedRow: clickedRow)
        let targets = contextMenuItems
        guard let item = contextMenuClickedItem, !targets.isEmpty else { return }
        let isSingle = targets.count == 1
        let anyFromArchive = targets.contains { $0.isFromArchive }

        // Open
        let openItem = NSMenuItem(title: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Show Package Contents (for .app, .bundle, etc.)
        if isSingle && isPackage(item) {
            let packageItem = NSMenuItem(title: "Show Package Contents", action: #selector(menuShowPackageContents(_:)), keyEquivalent: "")
            packageItem.target = self
            menu.addItem(packageItem)
        }

        // Open With submenu
        if !anyFromArchive && !targets.contains(where: { $0.isDirectory }) {
            let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWithItem.submenu = OpenWithMenuBuilder.buildNSMenu(for: targets.map(\.url), target: self)
            menu.addItem(openWithItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Get Info
        let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(menuGetInfo(_:)), keyEquivalent: "")
        getInfoItem.target = self
        getInfoItem.isEnabled = !anyFromArchive
        menu.addItem(getInfoItem)

        menu.addItem(NSMenuItem.separator())

        // Tags submenu (only for non-archive items)
        if !anyFromArchive {
            let targetTags = targets.map { $0.tags }
            let tagsMenu = NSMenu(title: "Tags")
            for tag in FinderTag.allTags {
                let tagItem = NSMenuItem(title: tag.name, action: #selector(menuToggleTag(_:)), keyEquivalent: "")
                tagItem.target = self
                tagItem.representedObject = tag.name
                let taggedCount = targetTags.filter { $0.contains(tag.name) }.count
                tagItem.state = taggedCount == 0 ? .off : (taggedCount == targets.count ? .on : .mixed)

                // Add color indicator
                let colorImage = NSImage(size: NSSize(width: 12, height: 12))
                colorImage.lockFocus()
                NSColor(tag.color).setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
                colorImage.unlockFocus()
                tagItem.image = colorImage

                tagsMenu.addItem(tagItem)
            }

            if targetTags.contains(where: { !$0.isEmpty }) {
                tagsMenu.addItem(NSMenuItem.separator())
                let removeAllItem = NSMenuItem(title: "Remove All Tags", action: #selector(menuRemoveAllTags(_:)), keyEquivalent: "")
                removeAllItem.target = self
                tagsMenu.addItem(removeAllItem)
            }

            let tagsMenuItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            tagsMenuItem.submenu = tagsMenu
            menu.addItem(tagsMenuItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Copy
        let copyItem = NSMenuItem(title: "Copy", action: #selector(menuCopy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        // Cut
        let cutItem = NSMenuItem(title: "Cut", action: #selector(menuCut(_:)), keyEquivalent: "")
        cutItem.target = self
        menu.addItem(cutItem)

        // Duplicate
        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(menuDuplicate(_:)), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.isEnabled = !anyFromArchive
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        // Rename
        let renameItem = NSMenuItem(title: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = isSingle && !anyFromArchive
        menu.addItem(renameItem)

        // Move to Trash
        let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(menuMoveToTrash(_:)), keyEquivalent: "")
        trashItem.target = self
        trashItem.isEnabled = !anyFromArchive
        menu.addItem(trashItem)

        menu.addItem(NSMenuItem.separator())

        // Show in Finder
        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(menuShowInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)
    }

    private func buildEmptySpaceMenu(_ menu: NSMenu) {
        contextMenuItems = []
        contextMenuClickedItem = nil

        // New Folder
        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(menuNewFolder(_:)), keyEquivalent: "")
        newFolderItem.target = self
        menu.addItem(newFolderItem)

        // Paste (if clipboard has files)
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(menuPaste(_:)), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = viewModel.canPaste
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        // Show in Finder
        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(menuShowCurrentFolderInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)
    }

    // MARK: - Header Menu Actions

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? ListColumn else { return }
        toggleColumn(column)
    }

    /// Shows or hides a column (header menu).
    func toggleColumn(_ column: ListColumn) {
        let visible = !(currentColumns.first(where: { $0.column == column })?.isVisible ?? false)
        applyUserColumnChange(
            shown: ListColumnConfigManager.columns(currentColumns, setting: column, visible: visible),
            shared: ListColumnConfigManager.columns(columnConfig.columns, setting: column, visible: visible)
        )
        syncColumnsIfNeeded()
    }

    @objc private func resetColumnsToDefaults(_ sender: NSMenuItem) {
        columnConfig.resetToDefaults()
        viewModel.resetFolderColumnState()
        syncColumnsIfNeeded()
    }

    // MARK: - Row Menu Actions

    @objc private func menuOpen(_ sender: NSMenuItem) {
        FileListActions.open(contextMenuItems, primary: contextMenuClickedItem, viewModel: viewModel)
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? OpenWithAction else { return }
        OpenWithMenuBuilder.openFiles(action.fileURLs, withAppAt: action.appURL)
    }

    @objc func openWithOther(_ sender: NSMenuItem) {
        guard let fileURLs = sender.representedObject as? [URL] else { return }
        OpenWithMenuBuilder.showOpenWithPanel(for: fileURLs, relativeTo: tableView?.window)
    }

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        viewModel.getInfo()
    }

    /// Adds the tag to every target, or removes it from all of them if they all have it.
    @objc private func menuToggleTag(_ sender: NSMenuItem) {
        guard let tagName = sender.representedObject as? String else { return }
        let targets = contextMenuItems.filter { !$0.isFromArchive }
        guard !targets.isEmpty else { return }

        let allTagged = targets.allSatisfy { $0.tags.contains(tagName) }
        for item in targets {
            var tags = item.tags
            if allTagged {
                tags.removeAll { $0 == tagName }
            } else if !tags.contains(tagName) {
                tags.append(tagName)
            } else {
                continue
            }
            viewModel.setTags(tags, for: item.url, invalidateCache: false)
            loadedTagURLs.insert(item.url)
            if let row = rowIndex[item.url] {
                updateTagViews(row: row, tags: tags)
            }
        }
    }

    @objc private func menuRemoveAllTags(_ sender: NSMenuItem) {
        for item in contextMenuItems where !item.isFromArchive && !item.tags.isEmpty {
            viewModel.setTags([], for: item.url, invalidateCache: false)
            loadedTagURLs.insert(item.url)
            if let row = rowIndex[item.url] {
                updateTagViews(row: row, tags: [])
            }
        }
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        viewModel.copySelectedItems()
    }

    @objc private func menuCut(_ sender: NSMenuItem) {
        viewModel.cutSelectedItems()
    }

    @objc private func menuDuplicate(_ sender: NSMenuItem) {
        viewModel.duplicateSelectedItems()
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard contextMenuItems.count == 1, let item = contextMenuItems.first else { return }
        viewModel.renamingURL = item.url
    }

    @objc private func menuMoveToTrash(_ sender: NSMenuItem) {
        viewModel.deleteSelectedItems()
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        viewModel.showInFinder()
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        viewModel.createNewFolder()
    }

    @objc private func menuPaste(_ sender: NSMenuItem) {
        viewModel.paste()
    }

    @objc private func menuShowCurrentFolderInFinder(_ sender: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([viewModel.currentPath])
    }

    @objc private func menuShowPackageContents(_ sender: NSMenuItem) {
        guard let item = contextMenuClickedItem else { return }
        viewModel.showPackageContents(item)
    }

    // MARK: - Package Detection

    private func isPackage(_ item: FileItem) -> Bool {
        let packageExtensions = ["app", "bundle", "framework", "plugin", "kext", "prefPane", "qlgenerator", "saver", "wdgt", "xpc"]
        let ext = item.url.pathExtension.lowercased()
        return packageExtensions.contains(ext) || NSWorkspace.shared.isFilePackage(atPath: item.url.path)
    }
}

// MARK: - Drag and Drop

extension FileTableCoordinator {
    // Modern drag support - called for each selected row
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count else { return nil }
        let item = items[row]
        guard !item.isFromArchive else { return nil }
        return item.url as NSURL
    }

    // Customize drag image for multi-selection (shows stacked icons)
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // Mark the drag as internal (suppresses drop overlays; drop targets validate the URLs)
        let urls = rowIndexes.compactMap { row in
            row < items.count && !items[row].isFromArchive ? items[row].url : nil
        }
        InternalDragState.shared.beginDrag(urls: urls)

        // Use stack formation for multiple items (like Finder)
        if rowIndexes.count > 1 {
            session.draggingFormation = .stack
        }
    }

    // Clear internal drag state when drag ends
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        InternalDragState.shared.endDrag()
    }

    /// The folder row a drop lands in, or nil when the drop goes into the folder being shown.
    func dropTargetFolder(row: Int, dropOperation: NSTableView.DropOperation) -> FileItem? {
        guard dropOperation == .on, row >= 0, row < items.count else { return nil }
        let item = items[row]
        guard item.isDirectory, !item.isFromArchive, item.url.isFileURL,
              !NSWorkspace.shared.isFilePackage(atPath: item.url.path) else { return nil }
        return item
    }

    /// Drops onto rows and into the folder being shown: never inside an archive, the Photos library
    /// or the network browser.
    private var acceptsDrops: Bool {
        FileListActions.acceptsDrops(in: viewModel)
    }

    /// Spotlight results come from anywhere: a drop there goes onto a folder row or nowhere (not
    /// into the folder the search started in).
    private var acceptsDropsIntoShownFolder: Bool {
        acceptsDrops && !FileListActions.showsSearchResults(viewModel)
    }

    private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
        if dropSessionNumber != info.draggingSequenceNumber {
            dropSessionNumber = info.draggingSequenceNumber
            dropVolumeCache.removeAll()
            dropSessionURLs = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        }
        return dropSessionURLs
    }

    /// Finder's rule for a plain drag: move within a volume, copy across volumes.
    static func isSameVolume(_ source: URL, _ destination: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let sourceVolume = (try? source.resourceValues(forKeys: [key]))?.volumeIdentifier,
              let destinationVolume = (try? destination.resourceValues(forKeys: [key]))?.volumeIdentifier else {
            return true
        }
        return sourceVolume.isEqual(destinationVolume)
    }

    /// The operation for dropping `urls` into `destination`, or [] to refuse.
    /// - sourceMask: what the drag source allows (AppKit already narrows it for ⌥/⌘).
    /// - sameVolume: whether the first dragged item is on the destination's volume.
    static func dropOperation(
        for urls: [URL],
        into destination: URL,
        sourceMask: NSDragOperation,
        modifierFlags: NSEvent.ModifierFlags,
        sameVolume: () -> Bool
    ) -> NSDragOperation {
        guard !urls.isEmpty else { return [] }
        let destinationPath = destination.standardizedFileURL.path

        // A folder can't be dropped into itself or one of its own subfolders
        for url in urls {
            let path = url.standardizedFileURL.path
            if destinationPath == path || destinationPath.hasPrefix(path.hasSuffix("/") ? path : path + "/") {
                return []
            }
        }

        // Everything is already in the destination: nothing to do
        if urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == destinationPath }) {
            return []
        }

        let canMove = sourceMask.contains(.move) || sourceMask.contains(.generic)
        let canCopy = sourceMask.contains(.copy)

        switch FileDropOperation(modifierFlags: modifierFlags) {
        case .copy:
            return canCopy ? .copy : []
        case .move:
            return canMove ? .move : (canCopy ? .copy : [])
        case .automatic:
            if !canMove { return canCopy ? .copy : [] }
            if !canCopy { return .move }
            return sameVolume() ? .move : .copy
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard acceptsDrops else { return [] }
        let urls = draggedURLs(info)
        guard !urls.isEmpty else { return [] }

        let destination: URL
        if let folder = dropTargetFolder(row: row, dropOperation: dropOperation) {
            destination = folder.url
        } else {
            guard acceptsDropsIntoShownFolder else { return [] }
            // Not on a folder row: the drop goes into the folder being shown (highlight the whole list)
            tableView.setDropRow(-1, dropOperation: .on)
            destination = viewModel.currentPath
        }

        return Self.dropOperation(
            for: urls,
            into: destination,
            sourceMask: info.draggingSourceOperationMask,
            modifierFlags: NSEvent.modifierFlags,
            sameVolume: {
                if let cached = dropVolumeCache[destination] { return cached }
                let result = Self.isSameVolume(urls[0], destination)
                dropVolumeCache[destination] = result
                return result
            }
        )
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard acceptsDrops else { return false }
        let urls = draggedURLs(info)
        dropSessionNumber = nil
        guard !urls.isEmpty else { return false }

        // Resolve the operation now, from the modifiers held at drop time
        let sourceMask = info.draggingSourceOperationMask
        let operation: FileDropOperation = sourceMask.contains(.move) || sourceMask.contains(.generic)
            ? FileDropOperation(modifierFlags: NSEvent.modifierFlags)
            : .copy

        // nil destination = the folder being shown
        let destination = dropTargetFolder(row: row, dropOperation: dropOperation)?.url
        guard destination != nil || acceptsDropsIntoShownFolder else { return false }
        viewModel.handleDrop(urls: urls, to: destination, operation: operation)
        return true
    }
}

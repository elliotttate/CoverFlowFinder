import AppKit
import SwiftUI

// MARK: - NSViewRepresentable Wrapper

struct FileTableView: NSViewRepresentable {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var columnConfig: ListColumnConfigManager
    @ObservedObject var appSettings: AppSettings
    let items: [FileItem]

    func makeCoordinator() -> FileTableCoordinator {
        FileTableCoordinator(
            viewModel: viewModel,
            columnConfig: columnConfig,
            appSettings: appSettings
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let tableView = KeyboardTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .automatic  // Use automatic for best native appearance
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 22
        tableView.gridStyleMask = []
        tableView.focusRingType = .none

        // Register for drag and drop
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)

        // Set delegate and data source
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        context.coordinator.tableView = tableView

        // Double-click to open
        tableView.doubleAction = #selector(context.coordinator.tableViewDoubleClicked(_:))
        tableView.target = context.coordinator

        // Setup columns first
        context.coordinator.setupColumns()

        // Ensure the table view is properly configured as the document view
        scrollView.documentView = tableView

        // Register for notifications
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: tableView
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: tableView
        )

        // Observe scroll for lazy metadata hydration
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.scrollViewDidEndScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        // Setup header menu after a short delay to ensure view hierarchy is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.coordinator.setupHeaderMenu()
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.columnConfig = columnConfig
        context.coordinator.appSettings = appSettings

        // Ensure header menu is set up (in case it wasn't ready before)
        context.coordinator.ensureHeaderMenu()

        // Update items
        let oldItems = context.coordinator.items
        context.coordinator.items = items

        // Check if items actually changed (not just reference)
        let changed = oldItems.count != items.count || !oldItems.elementsEqual(items, by: { $0.id == $1.id })
        if changed {
            context.coordinator.resetThumbnailState()
            context.coordinator.tableView?.reloadData()
            // Trigger hydration for newly visible rows
            context.coordinator.hydrateVisibleRows()
        }

        // Sync columns if configuration changed
        context.coordinator.syncColumnsIfNeeded()

        // Sync selection from SwiftUI to NSTableView
        context.coordinator.syncSelectionFromViewModel()
    }
}

// MARK: - Custom TableView with Keyboard Handling

@MainActor
final class KeyboardTableView: NSTableView {
    weak var coordinator: FileTableCoordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space - Quick Look
            coordinator?.triggerQuickLook()
        case 36: // Return - Open item
            coordinator?.openSelectedItem()
        case 51 where event.modifierFlags.contains(.command): // Cmd+Backspace - Delete
            coordinator?.deleteSelectedItems()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Coordinator (NSTableViewDataSource & NSTableViewDelegate)

@MainActor
final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var viewModel: FileBrowserViewModel
    var columnConfig: ListColumnConfigManager
    var appSettings: AppSettings
    weak var tableView: NSTableView?

    var items: [FileItem] = []
    private var thumbnails: [URL: NSImage] = [:]
    private var pendingThumbnailRows = IndexSet()
    private let thumbnailCache = ThumbnailCacheManager.shared
    private var isUpdatingSelection = false
    private var isUpdatingSort = false  // Prevent sort feedback loop
    private var lastColumnSnapshot: [ColumnSettings] = []
    private var lastSortColumn: ListColumn?
    private var lastSortDirection: SortDirection?

    // Lazy loading state
    private var lastVisibleRange: Range<Int>?
    private var hydrationDebounceTimer: Timer?
    private let hydrationDebounceInterval: TimeInterval = 0.05
    private var isLiveScrolling = false

    // Thumbnail preheat state (like PHCachingImageManager)
    private var lastPreheatRange: Range<Int>?
    private var preheatBuffer = 20  // Rows to preheat beyond visible
    private var preheatURLs: Set<URL> = []  // Currently preheating

    init(viewModel: FileBrowserViewModel, columnConfig: ListColumnConfigManager, appSettings: AppSettings) {
        self.viewModel = viewModel
        self.columnConfig = columnConfig
        self.appSettings = appSettings
        super.init()
    }

    deinit {
        hydrationDebounceTimer?.invalidate()
    }

    // MARK: - Column Setup

    func setupColumns() {
        guard let tableView = tableView else { return }

        // Remove existing columns
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }

        // Add columns based on configuration
        for settings in columnConfig.visibleColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(settings.column.rawValue))
            column.title = settings.column.rawValue
            column.width = settings.width
            column.minWidth = settings.column.minWidth
            column.maxWidth = 600
            column.isEditable = false
            column.resizingMask = .userResizingMask

            // Sort descriptor - set ascending based on column type
            // NSTableView will toggle direction automatically on subsequent clicks
            let ascending: Bool
            switch settings.column {
            case .name, .kind, .tags:
                ascending = true
            case .dateModified, .dateCreated, .size:
                ascending = false
            }

            let sortDescriptor = NSSortDescriptor(
                key: settings.column.rawValue,
                ascending: ascending,
                selector: settings.column == .name || settings.column == .kind || settings.column == .tags
                    ? #selector(NSString.localizedStandardCompare(_:))
                    : nil
            )
            column.sortDescriptorPrototype = sortDescriptor

            // Configure header cell
            let headerCell = column.headerCell
            headerCell.alignment = .left

            tableView.addTableColumn(column)
        }

        // Set the current sort descriptor on the table view to match our config
        lastSortColumn = nil  // Force update on first setup
        lastSortDirection = nil
        applySortDescriptorToTableView()

        lastColumnSnapshot = columnConfig.visibleColumns
    }

    private func applySortDescriptorToTableView() {
        guard let tableView = tableView else { return }

        // Only update if sort actually changed
        guard lastSortColumn != columnConfig.sortColumn ||
              lastSortDirection != columnConfig.sortDirection else { return }

        // Find the column matching our current sort
        let sortColumnID = columnConfig.sortColumn.rawValue
        guard let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == sortColumnID }),
              let prototype = column.sortDescriptorPrototype else { return }

        // Create a new descriptor with the correct direction
        let descriptor = NSSortDescriptor(
            key: prototype.key,
            ascending: columnConfig.sortDirection == .ascending,
            selector: prototype.selector
        )

        // Set this as the active sort descriptor (prevent feedback loop)
        isUpdatingSort = true
        tableView.sortDescriptors = [descriptor]
        lastSortColumn = columnConfig.sortColumn
        lastSortDirection = columnConfig.sortDirection
        updateSortIndicator()
        isUpdatingSort = false
    }

    func syncColumnsIfNeeded() {
        let currentVisible = columnConfig.visibleColumns
        if currentVisible != lastColumnSnapshot {
            setupColumns()
            tableView?.reloadData()
        } else {
            // Even if columns haven't changed, update sort indicator if sort changed
            applySortDescriptorToTableView()
        }
    }

    private func updateSortIndicator() {
        guard let tableView = tableView else { return }

        // Clear all indicators
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }

        // Set indicator on sorted column
        let sortColumnID = columnConfig.sortColumn.rawValue
        if let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == sortColumnID }) {
            let image = columnConfig.sortDirection == .ascending
                ? NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Ascending")
                : NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Descending")
            tableView.setIndicatorImage(image, in: column)
            tableView.highlightedTableColumn = column
        }
    }

    // MARK: - Header Menu

    private var headerMenuSet = false

    func setupHeaderMenu() {
        guard !headerMenuSet else { return }
        guard let tableView = tableView,
              let headerView = tableView.headerView else { return }

        // Create menu for header - this is the right-click context menu
        let menu = NSMenu(title: "Columns")
        menu.delegate = self
        menu.autoenablesItems = false

        // Set menu on header view for right-click
        headerView.menu = menu
        headerMenuSet = true
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
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }

        guard let tableView = tableView else { return }
        let selectedRows = tableView.selectedRowIndexes

        let selectedItems = Set(selectedRows.compactMap { row -> FileItem? in
            guard row < items.count else { return nil }
            return items[row]
        })

        isUpdatingSelection = true
        viewModel.selectedItems = selectedItems
        isUpdatingSelection = false
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // Prevent feedback loop when we programmatically set sort descriptors
        guard !isUpdatingSort else { return }

        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = ListColumn(rawValue: key) else { return }

        let newDirection: SortDirection = descriptor.ascending ? .ascending : .descending

        // Only update if something actually changed
        if columnConfig.sortColumn != column || columnConfig.sortDirection != newDirection {
            isUpdatingSort = true
            columnConfig.sortColumn = column
            columnConfig.sortDirection = newDirection
            lastSortColumn = column
            lastSortDirection = newDirection
            updateSortIndicator()
            isUpdatingSort = false
        }
    }

    // MARK: - Selection Sync

    func syncSelectionFromViewModel() {
        guard !isUpdatingSelection else { return }
        guard let tableView = tableView else { return }

        let selectedIDs = Set(viewModel.selectedItems.map { $0.id })
        let rowsToSelect = items.enumerated().compactMap { index, item -> Int? in
            selectedIDs.contains(item.id) ? index : nil
        }

        let newIndexSet = IndexSet(rowsToSelect)
        let currentSelection = tableView.selectedRowIndexes

        if newIndexSet != currentSelection {
            isUpdatingSelection = true
            tableView.selectRowIndexes(newIndexSet, byExtendingSelection: false)
            isUpdatingSelection = false
        }

        // Always scroll to make the first selected row visible
        // This ensures the list follows cover flow selection even during rapid browsing
        if let firstSelectedRow = rowsToSelect.first {
            tableView.scrollRowToVisible(firstSelectedRow)
        }
    }

    // MARK: - Actions

    @objc func tableViewDoubleClicked(_ sender: Any?) {
        guard let tableView = tableView else { return }
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }

        let item = items[clickedRow]
        viewModel.openItem(item)
    }

    // MARK: - Keyboard Actions

    func triggerQuickLook() {
        guard let item = viewModel.selectedItems.first else {
            NSSound.beep()
            return
        }
        // Use async version to avoid blocking main thread during archive extraction
        viewModel.previewURL(for: item) { [weak self] previewURL in
            guard let previewURL = previewURL else {
                NSSound.beep()
                return
            }
            QuickLookControllerView.shared.togglePreview(for: previewURL) { [weak self] offset in
                self?.navigateSelection(by: offset)
            }
        }
    }

    func openSelectedItem() {
        guard let item = viewModel.selectedItems.first else { return }
        viewModel.openItem(item)
    }

    func deleteSelectedItems() {
        viewModel.deleteSelectedItems()
    }

    private func navigateSelection(by offset: Int) {
        guard let tableView = tableView else { return }
        let currentRow = tableView.selectedRow
        let newRow = max(0, min(items.count - 1, currentRow + offset))
        if newRow != currentRow && newRow >= 0 && newRow < items.count {
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    // MARK: - Column Resize/Move Notifications

    @objc func columnDidResize(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let column = userInfo["NSTableColumn"] as? NSTableColumn else { return }

        let columnID = column.identifier.rawValue
        guard let listColumn = ListColumn(rawValue: columnID) else { return }

        columnConfig.setColumnWidth(listColumn, width: column.width)
    }

    @objc func columnDidMove(_ notification: Notification) {
        guard let tableView = tableView else { return }

        // Get new column order from table view
        let newOrder = tableView.tableColumns.compactMap { column -> ListColumn? in
            ListColumn(rawValue: column.identifier.rawValue)
        }

        // Update column config to match new order
        var reorderedColumns: [ColumnSettings] = []
        for listColumn in newOrder {
            if let settings = columnConfig.columns.first(where: { $0.column == listColumn }) {
                reorderedColumns.append(settings)
            }
        }

        // Add hidden columns at the end
        for settings in columnConfig.columns where !settings.isVisible {
            if !reorderedColumns.contains(where: { $0.column == settings.column }) {
                reorderedColumns.append(settings)
            }
        }

        columnConfig.columns = reorderedColumns
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
        flushPendingThumbnailRowReloads()
    }

    /// Hydrate metadata for currently visible rows
    func hydrateVisibleRows() {
        guard let tableView = tableView else { return }

        let visibleRect = tableView.visibleRect
        let visibleRows = tableView.rows(in: visibleRect)

        guard visibleRows.location != NSNotFound else { return }

        let start = visibleRows.location
        let end = min(start + visibleRows.length, items.count)

        // Extend range for metadata hydration
        let hydrationBuffer = 10
        let hydrationStart = max(0, start - hydrationBuffer)
        let hydrationEnd = min(items.count, end + hydrationBuffer)

        guard hydrationStart < hydrationEnd else { return }

        // Check if range actually changed
        let newRange = hydrationStart..<hydrationEnd
        if newRange == lastVisibleRange { return }
        lastVisibleRange = newRange

        // Collect URLs that need hydration
        var urlsToHydrate: [URL] = []
        for i in hydrationStart..<hydrationEnd {
            let item = items[i]
            if viewModel.needsHydration(item) {
                urlsToHydrate.append(item.url)
            }
        }

        if !urlsToHydrate.isEmpty {
            viewModel.hydrateMetadata(for: urlsToHydrate)
        }

        // Also preheat thumbnails
        preheatThumbnails(visibleStart: start, visibleEnd: end)
    }

    private func loadThumbnailsForVisibleRows() {
        guard let tableView = tableView else { return }

        let visibleRect = tableView.visibleRect
        let visibleRows = tableView.rows(in: visibleRect)

        guard visibleRows.location != NSNotFound else { return }

        let start = visibleRows.location
        let end = min(start + visibleRows.length, items.count)

        guard start < end else { return }

        for row in start..<end {
            loadThumbnailIfNeeded(for: items[row])
        }
    }

    /// Preheat thumbnails for rows coming into view (like PHCachingImageManager)
    private func preheatThumbnails(visibleStart: Int, visibleEnd: Int) {
        let preheatStart = max(0, visibleStart - preheatBuffer)
        let preheatEnd = min(items.count, visibleEnd + preheatBuffer)

        guard preheatStart < preheatEnd else { return }

        let newPreheatRange = preheatStart..<preheatEnd

        // Calculate what's added and removed
        let oldPreheatRange = lastPreheatRange ?? 0..<0
        lastPreheatRange = newPreheatRange

        // Find items that entered the preheat zone
        let addedURLs: [URL] = (preheatStart..<preheatEnd).compactMap { i in
            guard !oldPreheatRange.contains(i) else { return nil }
            let item = items[i]
            guard !item.isDirectory && thumbnails[item.url] == nil else { return nil }
            return item.url
        }

        // Find items that left the preheat zone (cancel their requests)
        let removedURLs: [URL] = oldPreheatRange.compactMap { i in
            guard !newPreheatRange.contains(i), i < items.count else { return nil }
            return items[i].url
        }

        // Update preheat set
        for url in removedURLs {
            preheatURLs.remove(url)
        }

        // Start preheating new items
        for url in addedURLs where !preheatURLs.contains(url) {
            preheatURLs.insert(url)
            if let item = items.first(where: { $0.url == url }) {
                loadThumbnailIfNeeded(for: item)
            }
        }
    }

    // MARK: - Cell Factories

    private func makeNameCell(for item: FileItem, tableView: NSTableView) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("NameCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileNameCellView
            ?? FileNameCellView()
        cell.identifier = identifier

        let thumbnail = thumbnails[item.url] ?? (isLiveScrolling ? item.placeholderIcon : item.icon)
        cell.configure(item: item, thumbnail: thumbnail, appSettings: appSettings)

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
        cell.configure(item: item, appSettings: appSettings)
        return cell
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnailIfNeeded(for item: FileItem) {
        let url = item.url
        let targetPixelSize: CGFloat = 64

        if thumbnails[url] != nil { return }
        if thumbnailCache.isPending(url: url, maxPixelSize: targetPixelSize) { return }
        if thumbnailCache.hasFailed(url: url) {
            if isLiveScrolling {
                return
            }
            thumbnails[url] = item.icon
            queueThumbnailRowReload(for: url)
            return
        }

        if let cached = thumbnailCache.getCachedThumbnail(for: url, maxPixelSize: targetPixelSize) {
            thumbnails[url] = cached
            queueThumbnailRowReload(for: url)
            return
        }

        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { [weak self] loadedURL, image in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.thumbnailCache.hasFailed(url: loadedURL) {
                    if self.isLiveScrolling {
                        return
                    }
                    self.thumbnails[loadedURL] = item.icon
                    self.queueThumbnailRowReload(for: loadedURL)
                    return
                }

                self.thumbnails[loadedURL] = image ?? item.icon
                self.queueThumbnailRowReload(for: loadedURL)
            }
        }
    }

    func resetThumbnailState() {
        pendingThumbnailRows.removeAll()
        isLiveScrolling = false
    }

    private func queueThumbnailRowReload(for url: URL) {
        guard let tableView = tableView else { return }
        guard let row = items.firstIndex(where: { $0.url == url }) else { return }

        if isLiveScrolling {
            pendingThumbnailRows.insert(row)
            return
        }

        let columnIndex = nameColumnIndex(in: tableView)
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: columnIndex)
        )
    }

    private func flushPendingThumbnailRowReloads() {
        guard let tableView = tableView else { return }
        guard !pendingThumbnailRows.isEmpty else { return }

        let maxIndex = items.count - 1
        var validRows = IndexSet()
        if maxIndex >= 0 {
            for row in pendingThumbnailRows where row <= maxIndex {
                validRows.insert(row)
            }
        }

        pendingThumbnailRows.removeAll()
        guard !validRows.isEmpty else { return }

        let columnIndex = nameColumnIndex(in: tableView)
        tableView.reloadData(forRowIndexes: validRows, columnIndexes: IndexSet(integer: columnIndex))
    }

    private func nameColumnIndex(in tableView: NSTableView) -> Int {
        if let index = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == ListColumn.name.rawValue }) {
            return index
        }
        return 0
    }
}

// MARK: - NSMenuDelegate for Header Menu

extension FileTableCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        for column in ListColumn.allCases {
            let isVisible = columnConfig.columns.first(where: { $0.column == column })?.isVisible ?? false
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

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? ListColumn else { return }
        columnConfig.toggleColumnVisibility(column)
        setupColumns()
        tableView?.reloadData()
    }

    @objc private func resetColumnsToDefaults(_ sender: NSMenuItem) {
        columnConfig.resetToDefaults()
        setupColumns()
        tableView?.reloadData()
    }
}

// MARK: - Drag and Drop

extension FileTableCoordinator {
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < items.count else { return nil }
        let item = items[row]
        guard !item.isFromArchive else { return nil }
        return item.url as NSURL
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Allow dropping on folders
        if dropOperation == .on, row < items.count {
            let targetItem = items[row]
            if targetItem.isDirectory && !targetItem.isFromArchive {
                return NSEvent.modifierFlags.contains(.option) ? .copy : .move
            }
        }

        // Allow dropping between items (into current folder)
        if dropOperation == .above {
            return NSEvent.modifierFlags.contains(.option) ? .copy : .move
        }

        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }

        if dropOperation == .on, row < items.count {
            let targetItem = items[row]
            if targetItem.isDirectory && !targetItem.isFromArchive {
                viewModel.handleDrop(urls: urls, to: targetItem.url)
                return true
            }
        }

        // Drop into current folder
        viewModel.handleDrop(urls: urls)
        return true
    }
}

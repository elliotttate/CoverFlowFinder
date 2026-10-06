import AppKit
import Combine
import SwiftUI
import SystemConfiguration

struct SidebarView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    var isDualPane: Bool = false

    var body: some View {
        SidebarOutlineView(appSettings: appSettings, viewModel: viewModel, isDualPane: isDualPane)
            .frame(minWidth: 180)
    }
}

struct SidebarOutlineView: NSViewRepresentable {
    @ObservedObject var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    var isDualPane: Bool = false

    /// Pasteboard type of a favorite being reordered in the sidebar. A favorite drag carries only this type (no file
    /// URL), so dropping it anywhere else does nothing; it never moves or copies the folder itself.
    static let favoriteDragType = NSPasteboard.PasteboardType("com.coverflowfinder.sidebar.favorite")

    func makeCoordinator() -> Coordinator {
        Coordinator(appSettings: appSettings, viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false

        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = true
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.backgroundColor = .clear
        outlineView.allowsMultipleSelection = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.autoresizesOutlineColumn = true

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        // Clicks go through the action (not selection changes) so clicking the highlighted row still acts.
        outlineView.target = context.coordinator
        outlineView.action = #selector(Coordinator.outlineViewClicked(_:))

        var draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, Self.favoriteDragType]
        draggedTypes.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        outlineView.registerForDraggedTypes(draggedTypes)
        // Favorites are only reordered inside the sidebar; nothing is offered to other apps.
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)

        let menu = NSMenu(title: "Sidebar")
        menu.delegate = context.coordinator
        outlineView.menu = menu

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        context.coordinator.isDualPane = isDualPane
        context.coordinator.refreshIfNeeded(force: true)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Runs on every change the active view model publishes: this must stay cheap (no file-system access).
        context.coordinator.appSettings = appSettings
        context.coordinator.viewModel = viewModel
        context.coordinator.isDualPane = isDualPane
        context.coordinator.refreshIfNeeded(force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var appSettings: AppSettings
        var viewModel: FileBrowserViewModel
        var isDualPane = false
        weak var outlineView: NSOutlineView?
        let internalDragType = SidebarOutlineView.favoriteDragType

        private let store = SidebarEnvironmentStore.shared
        private var storeSubscription: AnyCancellable?
        private var requestedFavorites: [SidebarFavorite]?
        private var sections: [SidebarSection] = []
        private var snapshot: SidebarSnapshot?
        private var environment: SidebarEnvironment
        private var isUpdatingSelection = false
        private var volumeComparisonCache: (sequence: Int, destination: URL, sameVolume: Bool)?
        /// File promises are written on this queue so large files don't block the UI.
        private let filePromiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.flowfinder.sidebar.filePromises"
            queue.qualityOfService = .userInitiated
            return queue
        }()

        init(appSettings: AppSettings, viewModel: FileBrowserViewModel) {
            self.appSettings = appSettings
            self.viewModel = viewModel
            self.environment = SidebarEnvironmentStore.shared.environment
            super.init()
            storeSubscription = store.environmentDidChange.sink { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshIfNeeded(force: false)
                }
            }
        }

        /// Rebuilds the rows only when something they show changed. File-system state comes from
        /// `SidebarEnvironmentStore`, which refreshes in the background.
        func refreshIfNeeded(force: Bool) {
            let favorites = appSettings.sidebarFavorites
            if favorites != requestedFavorites {
                requestedFavorites = favorites
                store.requestRefresh(favorites: favorites, settings: appSettings)
            }

            let nextEnvironment = store.environment
            let nextSnapshot = SidebarSnapshot(
                showFavorites: appSettings.sidebarShowFavorites,
                showICloud: appSettings.sidebarShowICloud,
                showLocations: appSettings.sidebarShowLocations,
                showTags: appSettings.sidebarShowTags,
                favorites: favorites,
                filterTag: viewModel.filterTag,
                environment: nextEnvironment
            )

            if force || snapshot != nextSnapshot {
                snapshot = nextSnapshot
                environment = nextEnvironment
                sections = buildSections()
                // Reloading can change the selected row; that must not count as a user selection.
                isUpdatingSelection = true
                outlineView?.reloadData()
                expandAllSections()
                isUpdatingSelection = false
            }

            updateSelection()
        }

        private func expandAllSections() {
            guard let outlineView else { return }
            for section in sections {
                outlineView.expandItem(section)
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let section = item as? SidebarSection {
                return section.items.count
            }
            return sections.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let section = item as? SidebarSection {
                return section.items[index]
            }
            return sections[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            item is SidebarSection
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            item is SidebarSection
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let sidebarItem = item as? SidebarItem else { return nil }
            guard case let .favorite(resolution) = sidebarItem.kind else { return nil }

            // Reorder data only: no file URL, so the drag can't move or copy the folder anywhere.
            let pbItem = NSPasteboardItem()
            pbItem.setString(resolution.favorite.id, forType: internalDragType)
            return pbItem
        }

        func outlineView(_ outlineView: NSOutlineView,
                         draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
            // Pressing on a row to drag it selected it without navigating; put the highlight back.
            updateSelection()
        }

        func outlineView(_ outlineView: NSOutlineView,
                         validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let favoritesSection = favoritesSection() else { return [] }

            let isInternal = isInternalDrag(info)
            let hasURLs = hasFileURLs(info)
            let hasPromises = hasFilePromises(info)
            let isExternal = (hasURLs || hasPromises) && !isInternal

            guard isInternal || isExternal else { return [] }

            guard let target = dropTarget(
                for: info,
                in: favoritesSection,
                isInternal: isInternal,
                isExternal: isExternal
            ) else {
                return []
            }

            switch target {
            case .between(let sectionIndex, _):
                if !isInternal && hasPromises && !hasURLs {
                    return []
                }
                outlineView.setDropItem(favoritesSection, dropChildIndex: sectionIndex)
                return isInternal ? .move : .copy
            case .onFavorite(let favoriteItem):
                guard !isInternal,
                      case let .favorite(resolution) = favoriteItem.kind,
                      let destination = resolution.url else { return [] }
                outlineView.setDropItem(favoriteItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return fileDragOperation(for: info, destination: destination, hasURLs: hasURLs)
            case .airDrop(let airDropItem):
                outlineView.setDropItem(airDropItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return isExternal ? .copy : []
            }
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            guard let favoritesSection = favoritesSection() else { return false }
            // Resolve copy/move now, while the modifier keys still reflect the drop.
            let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
            let isInternal = isInternalDrag(info)
            let hasURLs = hasFileURLs(info)
            let hasPromises = hasFilePromises(info)
            let isExternal = (hasURLs || hasPromises) && !isInternal

            guard let target = dropTarget(
                for: info,
                in: favoritesSection,
                isInternal: isInternal,
                isExternal: isExternal
            ) else {
                return false
            }

            if isInternal {
                let ids = draggingFavoriteIDs(from: info.draggingPasteboard)
                guard !ids.isEmpty else { return false }

                switch target {
                case .between(_, let favoritesIndex):
                    moveFavorites(ids: ids, to: favoritesIndex)
                    return true
                case .onFavorite, .airDrop:
                    return false
                }
            }

            if hasURLs,
               let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
               ) as? [URL],
               !urls.isEmpty {
                switch target {
                case .between(_, let favoritesIndex):
                    insertFavorites(urls: urls, at: favoritesIndex)
                    return true
                case .onFavorite(let favoriteItem):
                    guard case let .favorite(resolution) = favoriteItem.kind,
                          let destination = resolution.url else { return false }
                    viewModel.handleDrop(urls: urls, to: destination, operation: operation)
                    return true
                case .airDrop:
                    performAirDrop(urls: urls)
                    return true
                }
            }

            guard hasPromises else { return false }

            switch target {
            case .between:
                return false
            case .onFavorite(let favoriteItem):
                guard case let .favorite(resolution) = favoriteItem.kind,
                      let destination = resolution.url else { return false }
                let viewModel = self.viewModel
                receiveFilePromises(from: info) { urls, tempDirectory in
                    guard !urls.isEmpty else {
                        if let tempDirectory {
                            try? FileManager.default.removeItem(at: tempDirectory)
                        }
                        return
                    }
                    // Promised files are new files in our temp folder: always copy them out.
                    viewModel.handleDrop(urls: urls, to: destination, operation: .copy) {
                        if let tempDirectory {
                            try? FileManager.default.removeItem(at: tempDirectory)
                        }
                    }
                }
                return true
            case .airDrop:
                receiveFilePromises(from: info) { [weak self] urls, tempDirectory in
                    if let self, !urls.isEmpty {
                        self.performAirDrop(urls: urls)
                    }
                    if let tempDirectory {
                        try? FileManager.default.removeItem(at: tempDirectory)
                    }
                }
                return true
            }
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            if let section = item as? SidebarSection {
                let view = outlineView.makeView(withIdentifier: SidebarGroupCellView.identifier, owner: nil) as? SidebarGroupCellView
                    ?? SidebarGroupCellView()
                view.identifier = SidebarGroupCellView.identifier
                view.configure(title: section.title)
                return view
            }

            guard let sidebarItem = item as? SidebarItem else { return nil }
            let view = outlineView.makeView(withIdentifier: SidebarItemCellView.identifier, owner: nil) as? SidebarItemCellView
                ?? SidebarItemCellView()
            view.identifier = SidebarItemCellView.identifier

            let presentation = presentation(for: sidebarItem)
            view.configure(presentation: presentation)
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            if item is SidebarSection { return false }
            if let sidebarItem = item as? SidebarItem {
                return sidebarItem.isEnabled
            }
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            guard let outlineView = outlineView else { return }

            // Mouse clicks are handled by `outlineViewClicked`, which (unlike selection changes) also fires when
            // the clicked row is already highlighted. Selection changes here come from the keyboard.
            if let eventType = NSApp.currentEvent?.type,
               eventType == .leftMouseDown || eventType == .leftMouseUp || eventType == .leftMouseDragged {
                return
            }

            let row = outlineView.selectedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
            handleSelection(for: item)
        }

        @objc func outlineViewClicked(_ sender: Any?) {
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
            if item.isEnabled {
                handleSelection(for: item)
            }
            // Re-highlight the row matching where we are (e.g. after AirDrop, or a click on a disabled row).
            updateSelection()
        }

        // MARK: - NSMenuDelegate

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }

            switch item.kind {
            case .favorite(let resolution):
                let removeItem = NSMenuItem(title: "Remove from Favorites", action: #selector(removeFavoriteFromMenu(_:)), keyEquivalent: "")
                removeItem.representedObject = resolution.favorite.id
                removeItem.target = self
                menu.addItem(removeItem)

            case .location(let location):
                if location.isEjectable {
                    let ejectItem = NSMenuItem(title: "Eject “\(location.name.finderDisplayName)”", action: #selector(ejectVolumeFromMenu(_:)), keyEquivalent: "")
                    ejectItem.representedObject = location.url
                    ejectItem.target = self
                    menu.addItem(ejectItem)
                }

            default:
                break
            }
        }

        @objc private func ejectVolumeFromMenu(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? URL,
                  let location = environment.locations.first(where: { $0.url == url }) else { return }
            SidebarVolumeEjector.eject(location, window: outlineView?.window)
        }

        @objc private func removeFavoriteFromMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            let beforeCount = appSettings.sidebarFavorites.count
            appSettings.sidebarFavorites.removeAll { $0.id == id }
            if appSettings.sidebarFavorites.count != beforeCount {
                FinderSoundEffects.shared.play(.poofItemOffDock)
            }
        }

        // MARK: - Selection

        private func handleSelection(for item: SidebarItem) {
            switch item.kind {
            case .airDrop:
                triggerAirDropFromSelection()
            case .favorite(let resolution):
                guard resolution.isAvailable, let url = resolution.url else { return }
                viewModel.navigateTo(url)
            case .photosLibrary(let info, let isAvailable):
                guard isAvailable, let info else { return }
                requestViewMode(.masonry)
                viewModel.navigateToPhotosLibrary(info)
            case .iCloud(let url, let isAvailable):
                guard isAvailable, let url else { return }
                viewModel.navigateTo(url)
            case .location(let location):
                viewModel.navigateTo(location.url)
            case .tag(let tag):
                if viewModel.filterTag == tag.name {
                    viewModel.filterTag = nil
                } else {
                    viewModel.filterTag = tag.name
                }
            case .clearTagFilter:
                viewModel.filterTag = nil
            }
        }

        /// The window shell owns the view mode (and which pane layout is showing), so ask it via
        /// `.requestViewModeChange`. In a single pane the mode is also applied directly, as before; in Dual/Quad
        /// changing a pane's view model would desynchronize the shell, so only the request is sent.
        private func requestViewMode(_ mode: ViewMode) {
            if !isDualPane {
                viewModel.viewMode = mode
            }
            NotificationCenter.default.post(
                name: .requestViewModeChange,
                object: viewModel,
                userInfo: [AppNotificationKey.viewMode: mode]
            )
        }

        private func updateSelection() {
            guard let outlineView = outlineView else { return }
            let itemToSelect: SidebarItem?

            if let filterTag = viewModel.filterTag {
                itemToSelect = findTagItem(named: filterTag)
            } else {
                itemToSelect = bestMatchingLocationItem(for: viewModel.currentPath)
            }

            let targetRow = itemToSelect.map { outlineView.row(forItem: $0) } ?? -1
            guard targetRow != outlineView.selectedRow else { return }

            isUpdatingSelection = true
            if targetRow >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            } else {
                outlineView.deselectAll(nil)
            }
            isUpdatingSelection = false
        }

        private func findTagItem(named name: String) -> SidebarItem? {
            for section in sections where section.kind == .tags {
                if let match = section.items.first(where: {
                    if case let .tag(tag) = $0.kind {
                        return tag.name == name
                    }
                    return false
                }) {
                    return match
                }
            }
            return nil
        }

        private func bestMatchingLocationItem(for url: URL) -> SidebarItem? {
            var bestItem: SidebarItem?
            var bestMatchDepth: Int = -1
            let targetComponents = url.standardizedFileURL.pathComponents

            for section in sections {
                for item in section.items {
                    guard let itemURL = item.url else { continue }
                    let itemComponents = itemURL.standardizedFileURL.pathComponents
                    guard targetComponents.starts(with: itemComponents) else { continue }
                    if itemComponents.count > bestMatchDepth {
                        bestItem = item
                        bestMatchDepth = itemComponents.count
                    }
                }
            }

            return bestItem
        }

        // MARK: - Drag Helpers

        private enum DropTarget {
            case between(sectionIndex: Int, favoritesIndex: Int)
            case onFavorite(SidebarItem)
            case airDrop(SidebarItem)
        }

        private func isInternalDrag(_ info: NSDraggingInfo) -> Bool {
            info.draggingPasteboard.types?.contains(internalDragType) == true
        }

        private func hasFileURLs(_ info: NSDraggingInfo) -> Bool {
            info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )
        }

        private func hasFilePromises(_ info: NSDraggingInfo) -> Bool {
            info.draggingPasteboard.canReadObject(
                forClasses: [NSFilePromiseReceiver.self],
                options: nil
            )
        }

        /// The cursor badge for dropping files onto a favorite folder, following Finder: Option copies, Command
        /// moves, otherwise move on the same volume and copy across volumes.
        private func fileDragOperation(for info: NSDraggingInfo, destination: URL, hasURLs: Bool) -> NSDragOperation {
            switch FileDropOperation(modifierFlags: NSEvent.modifierFlags) {
            case .copy:
                return .copy
            case .move:
                return hasURLs ? .move : .copy
            case .automatic:
                guard hasURLs else { return .copy }
                return isSameVolume(info, destination: destination) ? .move : .copy
            }
        }

        private func isSameVolume(_ info: NSDraggingInfo, destination: URL) -> Bool {
            if let cached = volumeComparisonCache,
               cached.sequence == info.draggingSequenceNumber,
               cached.destination == destination {
                return cached.sameVolume
            }
            guard let source = (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL])?.first else { return true }

            func volumeID(_ url: URL) -> NSObject? {
                (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            }
            let sameVolume: Bool
            if let sourceVolume = volumeID(source), let destinationVolume = volumeID(destination) {
                sameVolume = sourceVolume.isEqual(destinationVolume)
            } else {
                sameVolume = true
            }
            volumeComparisonCache = (info.draggingSequenceNumber, destination, sameVolume)
            return sameVolume
        }

        private func filePromiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
            (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        }

        /// Receives promised files into a temporary folder. The files are written on `filePromiseQueue`;
        /// `completion` runs on the main queue once all of them have arrived.
        private func receiveFilePromises(from info: NSDraggingInfo, completion: @escaping @MainActor ([URL], URL?) -> Void) {
            let receivers = filePromiseReceivers(from: info.draggingPasteboard)
            guard !receivers.isEmpty else {
                completion([], nil)
                return
            }

            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FlowFinderDrop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

            let group = DispatchGroup()
            let lock = NSLock()
            var receivedURLs: [URL] = []

            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: tempDirectory, options: [:], operationQueue: filePromiseQueue) { url, error in
                    if error == nil {
                        lock.lock()
                        receivedURLs.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                lock.lock()
                let urls = receivedURLs
                lock.unlock()
                MainActor.assumeIsolated {
                    completion(urls, tempDirectory)
                }
            }
        }

        private func draggingFavoriteIDs(from pasteboard: NSPasteboard) -> [String] {
            guard let items = pasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: internalDragType) }
        }

        /// Where a drag over the sidebar would land. The Favorites header inserts at the start; the strip below the
        /// last favorite, through the next section's header, appends; over a row, the upper half inserts before it
        /// and the lower half after it, except that external files dropped on the middle of a favorite go into that
        /// folder. Between rows, the nearest row decides.
        private func dropTarget(for info: NSDraggingInfo,
                                in favoritesSection: SidebarSection,
                                isInternal: Bool,
                                isExternal: Bool) -> DropTarget? {
            guard let outlineView = outlineView else { return nil }
            let location = outlineView.convert(info.draggingLocation, from: nil)

            let headerRow = outlineView.row(forItem: favoritesSection)
            guard headerRow >= 0 else { return nil }
            let headerRect = outlineView.rect(ofRow: headerRow)

            let minSectionIndex = firstFavoriteSectionIndex(in: favoritesSection)
            let maxSectionIndex = favoritesSection.items.count

            func insertion(at sectionIndex: Int) -> DropTarget {
                let clamped = min(max(sectionIndex, minSectionIndex), maxSectionIndex)
                return .between(sectionIndex: clamped, favoritesIndex: favoritesIndex(forSectionIndex: clamped, in: favoritesSection))
            }

            let itemRows = favoritesSection.items.map { outlineView.row(forItem: $0) }
            let itemRects: [NSRect] = itemRows.map { $0 >= 0 ? outlineView.rect(ofRow: $0) : .null }
            let sectionBottom = itemRects.last(where: { !$0.isNull })?.maxY ?? headerRect.maxY

            // Below the last favorite, the gap and the next section's header still append to Favorites.
            let lastRow = itemRows.last(where: { $0 >= 0 }) ?? headerRow
            let appendZoneBottom = lastRow + 1 < outlineView.numberOfRows
                ? outlineView.rect(ofRow: lastRow + 1).maxY
                : sectionBottom + headerRect.height

            // The outline view is flipped: y grows downwards. Favorites is the first section, so anything
            // above its header inserts at the start.
            guard location.y < appendZoneBottom else { return nil }
            if location.y < headerRect.maxY {
                return insertion(at: minSectionIndex)
            }
            if location.y >= sectionBottom {
                return insertion(at: maxSectionIndex)
            }

            var sectionIndex: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (index, rect) in itemRects.enumerated() where !rect.isNull {
                if location.y >= rect.minY && location.y < rect.maxY {
                    sectionIndex = index
                    break
                }
                let distance = abs(rect.midY - location.y)
                if distance < bestDistance {
                    bestDistance = distance
                    sectionIndex = index
                }
            }
            guard let sectionIndex else { return insertion(at: maxSectionIndex) }

            let item = favoritesSection.items[sectionIndex]
            let rowRect = itemRects[sectionIndex]
            let fraction = (location.y - rowRect.minY) / max(rowRect.height, 1)

            if case .airDrop = item.kind, isExternal {
                return .airDrop(item)
            }

            if !isInternal,
               case let .favorite(resolution) = item.kind,
               resolution.isAvailable,
               resolution.url != nil {
                if fraction < 0.25 { return insertion(at: sectionIndex) }
                if fraction >= 0.75 { return insertion(at: sectionIndex + 1) }
                return .onFavorite(item)
            }

            return insertion(at: fraction < 0.5 ? sectionIndex : sectionIndex + 1)
        }

        private func firstFavoriteSectionIndex(in section: SidebarSection) -> Int {
            for (index, item) in section.items.enumerated() {
                if case .favorite = item.kind {
                    return index
                }
            }
            return section.items.count
        }

        private func favoritesIndex(forSectionIndex index: Int, in section: SidebarSection) -> Int {
            let clamped = min(max(0, index), section.items.count)
            return section.items.prefix(clamped).reduce(0) { count, item in
                if case .favorite = item.kind {
                    return count + 1
                }
                return count
            }
        }

        private func moveFavorites(ids: [String], to destinationIndex: Int) {
            let favorites = appSettings.sidebarFavorites
            let moving = favorites.filter { ids.contains($0.id) }
            guard !moving.isEmpty else { return }

            let countBefore = favorites.prefix(destinationIndex).filter { ids.contains($0.id) }.count
            let adjustedIndex = max(0, destinationIndex - countBefore)

            var remaining = favorites.filter { !ids.contains($0.id) }
            let clampedIndex = min(adjustedIndex, remaining.count)
            remaining.insert(contentsOf: moving, at: clampedIndex)
            appSettings.sidebarFavorites = remaining
        }

        private func insertFavorites(urls: [URL], at index: Int) {
            var favorites = appSettings.sidebarFavorites
            var insertIndex = min(max(0, index), favorites.count)

            for url in urls {
                guard let favorite = favoriteFromURL(url) else { continue }
                if isDuplicateFavorite(favorite, in: favorites) { continue }

                favorites.insert(favorite, at: insertIndex)
                insertIndex += 1
            }

            if favorites != appSettings.sidebarFavorites {
                appSettings.sidebarFavorites = favorites
            }
        }

        private func favoriteFromURL(_ url: URL) -> SidebarFavorite? {
            let standardizedURL = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            // Path only; the bookmark is added by the next background refresh.
            return SidebarFavorite.custom(path: standardizedURL.path)
        }

        private func isDuplicateFavorite(_ favorite: SidebarFavorite, in favorites: [SidebarFavorite]) -> Bool {
            guard let newURL = currentURL(for: favorite) else { return false }
            let newPath = newURL.standardizedFileURL.path
            return favorites.contains { existing in
                guard let existingURL = currentURL(for: existing) else { return false }
                return existingURL.standardizedFileURL.path == newPath
            }
        }

        /// Where a favorite points, from the last background resolution (no file-system access).
        private func currentURL(for favorite: SidebarFavorite) -> URL? {
            if let resolution = environment.favoriteResolutions[favorite.id] {
                return resolution.url
            }
            return SidebarFavoriteResolution.provisional(for: favorite).url
        }

        // MARK: - Data Building

        private func buildSections() -> [SidebarSection] {
            var sections: [SidebarSection] = []

            if appSettings.sidebarShowFavorites {
                let section = SidebarSection(kind: .favorites, title: "Favorites")
                var items: [SidebarItem] = []
                items.append(SidebarItem(kind: .airDrop, id: "airdrop", title: "AirDrop"))

                let photosAvailable = environment.photosLibraryInfo != nil
                items.append(SidebarItem(
                    kind: .photosLibrary(environment.photosLibraryInfo, photosAvailable),
                    id: "photosLibrary",
                    title: "Photos Library",
                    isEnabled: photosAvailable
                ))

                for favorite in appSettings.sidebarFavorites {
                    // Until the background refresh has resolved a new favorite, show it as stored.
                    let resolution = environment.favoriteResolutions[favorite.id]
                        ?? SidebarFavoriteResolution.provisional(for: favorite)
                    let item = SidebarItem(
                        kind: .favorite(resolution),
                        id: favorite.id,
                        title: resolution.name,
                        isEnabled: resolution.isAvailable
                    )
                    items.append(item)
                }
                section.items = items
                sections.append(section)
            }

            if appSettings.sidebarShowICloud {
                let section = SidebarSection(kind: .icloud, title: "iCloud")
                let isAvailable = environment.iCloudURL != nil
                let item = SidebarItem(
                    kind: .iCloud(environment.iCloudURL, isAvailable),
                    id: "icloud",
                    title: "iCloud Drive",
                    isEnabled: isAvailable
                )
                section.items = [item]
                sections.append(section)
            }

            if appSettings.sidebarShowLocations {
                let section = SidebarSection(kind: .locations, title: "Locations")
                section.items = environment.locations.map { location in
                    SidebarItem(
                        kind: .location(location),
                        id: "location:\(location.url.path)",
                        title: location.name
                    )
                }
                sections.append(section)
            }

            if appSettings.sidebarShowTags {
                let section = SidebarSection(kind: .tags, title: "Tags")
                var items: [SidebarItem] = FinderTag.allTags.map { tag in
                    SidebarItem(kind: .tag(tag), id: "tag:\(tag.name)", title: tag.name)
                }
                if viewModel.filterTag != nil {
                    items.append(SidebarItem(kind: .clearTagFilter, id: "tag:clear", title: "Clear Filter"))
                }
                section.items = items
                sections.append(section)
            }

            return sections
        }

        private func favoritesSection() -> SidebarSection? {
            sections.first { $0.kind == .favorites }
        }

        private func presentation(for item: SidebarItem) -> SidebarItemPresentation {
            switch item.kind {
            case .airDrop:
                return SidebarItemPresentation(
                    title: item.title,
                    icon: symbolIcon(name: "antenna.radiowaves.left.and.right"),
                    iconTint: .controlAccentColor,
                    accessory: nil,
                    isEnabled: true
                )
            case .favorite(let resolution):
                let icon = resolution.url.flatMap { environment.icons.icon(forPath: $0.path) } ?? symbolIcon(name: "folder")
                return SidebarItemPresentation(
                    title: resolution.name.finderDisplayName,
                    icon: icon,
                    iconTint: nil,
                    accessory: nil,
                    isEnabled: resolution.isAvailable
                )
            case .photosLibrary:
                return SidebarItemPresentation(
                    title: item.title,
                    icon: photosLibraryIcon(),
                    iconTint: .controlAccentColor,
                    accessory: nil,
                    isEnabled: item.isEnabled
                )
            case .iCloud:
                return SidebarItemPresentation(
                    title: item.title,
                    icon: symbolIcon(name: "icloud"),
                    iconTint: nil,
                    accessory: nil,
                    isEnabled: item.isEnabled
                )
            case .location(let location):
                if location.url.path == "/Network" {
                    let icon = symbolIcon(name: "globe")
                        ?? symbolIcon(name: "network")
                        ?? NSImage(named: NSImage.networkName)
                    return SidebarItemPresentation(
                        title: location.name,
                        icon: icon,
                        iconTint: .labelColor,
                        accessory: nil,
                        isEnabled: true
                    )
                }
                let fallbackSymbol = location.url.path == "/" ? "desktopcomputer" : "externaldrive"
                let icon = environment.icons.icon(forPath: location.url.path) ?? symbolIcon(name: fallbackSymbol)
                return SidebarItemPresentation(
                    title: location.name.finderDisplayName,
                    icon: icon,
                    iconTint: nil,
                    accessory: nil,
                    isEnabled: true
                )
            case .tag(let tag):
                let checkmark = viewModel.filterTag == tag.name
                    ? symbolIcon(name: "checkmark")
                    : nil
                return SidebarItemPresentation(
                    title: tag.name,
                    icon: symbolIcon(name: "circle.fill"),
                    iconTint: NSColor(tag.color),
                    accessory: checkmark,
                    isEnabled: true
                )
            case .clearTagFilter:
                return SidebarItemPresentation(
                    title: item.title,
                    icon: symbolIcon(name: "xmark.circle"),
                    iconTint: .secondaryLabelColor,
                    accessory: nil,
                    isEnabled: true
                )
            }
        }

        private func symbolIcon(name: String) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }

        private func photosLibraryIcon() -> NSImage? {
            symbolIcon(name: "photo")
        }

        private func triggerAirDropFromSelection() {
            let urls = airDropURLsFromSelection()
            guard !urls.isEmpty else {
                showAirDropAlert(
                    title: "AirDrop",
                    message: "Select files in the main view or drop them onto AirDrop to send."
                )
                return
            }

            performAirDrop(urls: urls)
        }

        private func airDropURLsFromSelection() -> [URL] {
            viewModel.orderedSelectedItems.compactMap { item in
                guard !item.isFromArchive else { return nil }
                return item.url
            }
        }

        private func performAirDrop(urls: [URL]) {
            let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !validURLs.isEmpty else {
                showAirDropAlert(
                    title: "AirDrop",
                    message: "The selected items are not available to share."
                )
                return
            }

            guard let service = NSSharingService(named: .sendViaAirDrop) else {
                showAirDropAlert(
                    title: "AirDrop Unavailable",
                    message: "AirDrop is not available on this Mac right now."
                )
                return
            }

            guard service.canPerform(withItems: validURLs) else {
                showAirDropAlert(
                    title: "AirDrop Unavailable",
                    message: "AirDrop cannot share the selected items."
                )
                return
            }

            FinderSoundEffects.shared.play(.invitation)
            service.perform(withItems: validURLs)
        }

        private func showAirDropAlert(title: String, message: String) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational

            if let window = outlineView?.window {
                alert.beginSheetModal(for: window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }
}

// MARK: - Sidebar environment (file-system state, loaded off the main thread)

/// Everything the sidebar shows that needs file-system access. Built by `load(favorites:)` on a background queue.
struct SidebarEnvironment: Equatable {
    var computerName: String
    var iCloudURL: URL?
    var photosLibraryInfo: PhotosLibraryInfo?
    var locations: [SidebarLocation]
    /// Keyed by favorite id.
    var favoriteResolutions: [String: SidebarFavoriteResolution]
    /// Icons by path. Not compared: they only change together with the paths above.
    var icons: SidebarIconSet

    /// Before the first background load: nothing that needs I/O.
    static let initial = SidebarEnvironment(
        computerName: "",
        iCloudURL: nil,
        photosLibraryInfo: nil,
        locations: [SidebarLocation.network],
        favoriteResolutions: [:],
        icons: SidebarIconSet([:])
    )

    static func == (lhs: SidebarEnvironment, rhs: SidebarEnvironment) -> Bool {
        lhs.computerName == rhs.computerName
            && lhs.iCloudURL == rhs.iCloudURL
            && lhs.photosLibraryInfo == rhs.photosLibraryInfo
            && lhs.locations == rhs.locations
            && lhs.favoriteResolutions == rhs.favoriteResolutions
    }

    /// Gathers the sidebar's file-system state. Blocking (volume and bookmark lookups can hang on a dead network
    /// mount): never call on the main thread.
    static func load(favorites: [SidebarFavorite], fileManager: FileManager = .default) -> SidebarEnvironment {
        let computerName = currentComputerName()
        let locations = volumeLocations(computerName: computerName, fileManager: fileManager)

        var resolutions: [String: SidebarFavoriteResolution] = [:]
        for favorite in favorites {
            resolutions[favorite.id] = favorite.resolve(fileManager: fileManager)
        }

        var icons: [String: NSImage] = [:]
        for location in locations where location != .network {
            icons[location.url.path] = NSWorkspace.shared.icon(forFile: location.url.path)
        }
        for resolution in resolutions.values where resolution.isAvailable {
            if let url = resolution.url {
                icons[url.path] = NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        return SidebarEnvironment(
            computerName: computerName,
            iCloudURL: iCloudDriveURL(fileManager: fileManager),
            photosLibraryInfo: photosLibraryInfo(fileManager: fileManager),
            locations: locations,
            favoriteResolutions: resolutions,
            icons: SidebarIconSet(icons)
        )
    }

    /// The "Computer Name" from Sharing settings. Unlike `Host.current().localizedName` or
    /// `ProcessInfo.hostName`, this never does a DNS lookup.
    static func currentComputerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return name
        }
        return "Computer"
    }

    static func volumeLocations(computerName: String, fileManager: FileManager = .default) -> [SidebarLocation] {
        var locations = [SidebarLocation(name: computerName, url: URL(fileURLWithPath: "/", isDirectory: true), isEjectable: false, isNetwork: false)]

        let keys: [URLResourceKey] = [
            .volumeIsRootFileSystemKey,
            .volumeIsLocalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey
        ]
        // Browsable volumes only, like Finder: no system/hidden volumes or `-nobrowse` mounts.
        let volumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var mounted: [SidebarLocation] = []
        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            // The boot volume is already listed as the computer.
            if values?.volumeIsRootFileSystem == true || volume.standardizedFileURL.path == "/" { continue }

            let isNetwork = values?.volumeIsLocal == false
            let isEjectable = isNetwork
                || values?.volumeIsEjectable == true
                || values?.volumeIsRemovable == true
                || values?.volumeIsInternal == false
            mounted.append(SidebarLocation(name: volume.lastPathComponent, url: volume, isEjectable: isEjectable, isNetwork: isNetwork))
        }
        mounted.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        locations += mounted
        locations.append(.network)
        return locations
    }

    static func iCloudDriveURL(fileManager: FileManager = .default) -> URL? {
        guard fileManager.ubiquityIdentityToken != nil else { return nil }

        let homeURL = fileManager.homeDirectoryForCurrentUser
        let cloudStorageURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("CloudStorage", isDirectory: true)
            .appendingPathComponent("iCloud Drive", isDirectory: true)

        if fileManager.fileExists(atPath: cloudStorageURL.path) {
            return cloudStorageURL
        }

        let mobileDocsURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)

        if fileManager.fileExists(atPath: mobileDocsURL.path) {
            return mobileDocsURL
        }

        return nil
    }

    static func photosLibraryInfo(fileManager fm: FileManager = .default) -> PhotosLibraryInfo? {
        let picturesURL = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)

        guard let contents = try? fm.contentsOfDirectory(
            at: picturesURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let libraries = contents.filter { $0.pathExtension == "photoslibrary" }
        guard !libraries.isEmpty else { return nil }

        let preferred = libraries.first { $0.lastPathComponent == "Photos Library.photoslibrary" }
            ?? libraries.max(by: { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            })

        guard let libraryURL = preferred else { return nil }

        let imageFolderNames = ["originals", "Originals", "Masters"]
        for folderName in imageFolderNames {
            let candidate = libraryURL.appendingPathComponent(folderName, isDirectory: true)
            if fm.fileExists(atPath: candidate.path) {
                return PhotosLibraryInfo(libraryURL: libraryURL, imagesURL: candidate)
            }
        }

        return nil
    }
}

/// Immutable icon lookup shared between the background loader and the sidebar.
final class SidebarIconSet: @unchecked Sendable {
    private let icons: [String: NSImage]

    init(_ icons: [String: NSImage]) {
        self.icons = icons
    }

    func icon(forPath path: String) -> NSImage? {
        icons[path]
    }
}

struct SidebarLocation: Equatable {
    let name: String
    let url: URL
    /// Offer "Eject": removable or external media, disk images and network shares.
    let isEjectable: Bool
    let isNetwork: Bool

    static let network = SidebarLocation(name: "Network", url: URL(fileURLWithPath: "/Network", isDirectory: true), isEjectable: false, isNetwork: false)
}

extension SidebarFavoriteResolution {
    /// What to show for a favorite before it has been resolved in the background (no file-system access).
    static func provisional(for favorite: SidebarFavorite) -> SidebarFavoriteResolution {
        if let location = favorite.kind.systemLocation {
            return SidebarFavoriteResolution(favorite: favorite, url: location.url, name: location.name, isAvailable: location.url != nil, updatedFavorite: nil)
        }
        guard let path = favorite.path, !path.isEmpty else {
            return SidebarFavoriteResolution(favorite: favorite, url: nil, name: "Missing Folder", isAvailable: false, updatedFavorite: nil)
        }
        // isDirectory avoids the file-system check URL(fileURLWithPath:) would otherwise make.
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return SidebarFavoriteResolution(favorite: favorite, url: url, name: url.lastPathComponent, isAvailable: true, updatedFavorite: nil)
    }
}

/// Keeps one `SidebarEnvironment` for all sidebars and refreshes it in the background: when volumes mount, unmount
/// or are renamed, when favorites change, when the app becomes active, and on a slow timer.
@MainActor
final class SidebarEnvironmentStore {
    static let shared = SidebarEnvironmentStore()

    private(set) var environment = SidebarEnvironment.initial
    /// Sent on the main queue whenever `environment` changes.
    let environmentDidChange = PassthroughSubject<Void, Never>()

    private static let timerInterval: TimeInterval = 60
    private static let activationRefreshInterval: TimeInterval = 5

    private let loadQueue = DispatchQueue(label: "com.flowfinder.sidebar.environment", qos: .utility)
    private var isLoading = false
    private var needsAnotherLoad = false
    private var lastLoadStart = Date.distantPast
    private var favorites: [SidebarFavorite] = []
    private weak var settings: AppSettings?
    /// Favorites whose bookmark was created or refreshed this session. That happens at most once per favorite, so
    /// a bookmark that keeps failing can't cause endless rewrites. (Moves always apply; they converge.)
    private var rebookmarkedFavoriteIDs: Set<String> = []
    private var timer: Timer?

    private init() {
        observeSystemChanges()
    }

    func requestRefresh(favorites: [SidebarFavorite], settings: AppSettings) {
        self.favorites = favorites
        self.settings = settings
        requestRefresh()
    }

    /// Reloads in the background. Requests made while a load is running are coalesced into one more load.
    func requestRefresh() {
        guard !isLoading else {
            needsAnotherLoad = true
            return
        }
        isLoading = true
        lastLoadStart = Date()
        let favorites = self.favorites
        loadQueue.async {
            let loaded = SidebarEnvironment.load(favorites: favorites)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SidebarEnvironmentStore.shared.finishLoad(loaded)
                }
            }
        }
    }

    private func finishLoad(_ loaded: SidebarEnvironment) {
        isLoading = false
        if loaded != environment {
            environment = loaded
            environmentDidChange.send()
        }
        applyFavoriteUpdates(from: loaded)

        if needsAnotherLoad {
            needsAnotherLoad = false
            requestRefresh()
        }
    }

    /// Stores moved paths and new bookmarks back into the settings.
    private func applyFavoriteUpdates(from loaded: SidebarEnvironment) {
        guard let settings else { return }
        var favorites = settings.sidebarFavorites
        var changed = false

        for (index, favorite) in favorites.enumerated() {
            // Only if the favorite hasn't been edited since it was resolved.
            guard let resolution = loaded.favoriteResolutions[favorite.id],
                  resolution.favorite == favorite,
                  let updated = resolution.updatedFavorite else { continue }
            if !resolution.didMove {
                guard rebookmarkedFavoriteIDs.insert(favorite.id).inserted else { continue }
            }
            favorites[index] = updated
            changed = true
        }

        if changed {
            settings.sidebarFavorites = favorites
        }
    }

    private func observeSystemChanges() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        _ = workspaceCenter.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { notification in
            let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                SidebarEnvironmentStore.postVolumeNotification(.volumeWillUnmount, volumeURL: volumeURL)
            }
        }

        _ = workspaceCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { notification in
            let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                SidebarEnvironmentStore.postVolumeNotification(.volumeDidUnmount, volumeURL: volumeURL)
                SidebarEnvironmentStore.shared.requestRefresh()
            }
        }

        for name in [NSWorkspace.didMountNotification, NSWorkspace.didRenameVolumeNotification] {
            _ = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    SidebarEnvironmentStore.shared.requestRefresh()
                }
            }
        }

        // Pick up folders renamed, moved or deleted (e.g. in Finder) while we were in the background.
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = SidebarEnvironmentStore.shared
                if Date().timeIntervalSince(store.lastLoadStart) >= Self.activationRefreshInterval {
                    store.requestRefresh()
                }
            }
        }

        let timer = Timer(timeInterval: Self.timerInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApp?.isActive == true {
                    SidebarEnvironmentStore.shared.requestRefresh()
                }
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func postVolumeNotification(_ name: Notification.Name, volumeURL: URL?) {
        guard let volumeURL else { return }
        NotificationCenter.default.post(name: name, object: nil, userInfo: [AppNotificationKey.url: volumeURL])
    }
}

/// Ejects volumes from the sidebar without blocking the main thread.
@MainActor
enum SidebarVolumeEjector {
    static func eject(_ location: SidebarLocation, window: NSWindow?) {
        let url = location.url
        let name = location.name
        // Let panes showing this volume move away and stop watching it first, so we don't block our own eject.
        SidebarEnvironmentStore.postVolumeNotification(.volumeWillUnmount, volumeURL: url)

        // Network shares have no disk to eject; everything else is unmounted with all its partitions and ejected.
        let options: FileManager.UnmountOptions = location.isNetwork
            ? [.withoutUI]
            : [.allPartitionsAndEjectDisk, .withoutUI]

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak window] in
            FileManager.default.unmountVolume(at: url, options: options) { error in
                let failure = error.map { $0 as NSError }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let failure {
                            presentEjectError(failure, volumeName: name, window: window)
                        } else {
                            // The eject sound comes from FinderSoundEffectsMonitor's didUnmount observer.
                            SidebarEnvironmentStore.shared.requestRefresh()
                        }
                    }
                }
            }
        }
    }

    static func presentEjectError(_ error: NSError, volumeName: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The volume “\(volumeName)” wasn’t ejected."

        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileManagerUnmountBusy.rawValue {
            var reason = "It’s in use"
            if let pid = error.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber,
               let app = NSRunningApplication(processIdentifier: pid.int32Value),
               let appName = app.localizedName {
                reason += " by “\(appName)”"
            }
            alert.informativeText = reason + ". Quit apps or close files that are using it, then try again."
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")

        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Rows

private struct SidebarSnapshot: Equatable {
    let showFavorites: Bool
    let showICloud: Bool
    let showLocations: Bool
    let showTags: Bool
    let favorites: [SidebarFavorite]
    let filterTag: String?
    let environment: SidebarEnvironment
}

private struct SidebarItemPresentation {
    let title: String
    let icon: NSImage?
    let iconTint: NSColor?
    let accessory: NSImage?
    let isEnabled: Bool
}

private final class SidebarSection: NSObject {
    enum Kind {
        case favorites
        case icloud
        case locations
        case tags
    }

    let kind: Kind
    let title: String
    var items: [SidebarItem]

    init(kind: Kind, title: String, items: [SidebarItem] = []) {
        self.kind = kind
        self.title = title
        self.items = items
    }
}

private final class SidebarItem: NSObject {
    enum Kind {
        case airDrop
        case favorite(SidebarFavoriteResolution)
        case photosLibrary(PhotosLibraryInfo?, Bool)
        case iCloud(URL?, Bool)
        case location(SidebarLocation)
        case tag(FinderTag)
        case clearTagFilter
    }

    let kind: Kind
    let id: String
    let title: String
    let isEnabled: Bool

    init(kind: Kind, id: String, title: String, isEnabled: Bool = true) {
        self.kind = kind
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
    }

    var url: URL? {
        switch kind {
        case .favorite(let resolution):
            return resolution.url
        case .photosLibrary(let info, _):
            return info?.libraryURL
        case .iCloud(let url, _):
            return url
        case .location(let location):
            return location.url
        default:
            return nil
        }
    }
}

private final class SidebarItemCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let accessoryView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.translatesAutoresizingMaskIntoConstraints = false

        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyDown
        accessoryView.imageScaling = .scaleProportionallyDown
        accessoryView.contentTintColor = .controlAccentColor

        textField = titleField
        imageView = iconView

        addSubview(iconView)
        addSubview(titleField)
        addSubview(accessoryView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            accessoryView.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryView.widthAnchor.constraint(equalToConstant: 12),
            accessoryView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    func configure(presentation: SidebarItemPresentation) {
        titleField.stringValue = presentation.title
        titleField.textColor = presentation.isEnabled ? .labelColor : .secondaryLabelColor

        iconView.image = presentation.icon
        iconView.contentTintColor = presentation.iconTint
        iconView.alphaValue = presentation.isEnabled ? 1.0 : 0.5

        accessoryView.image = presentation.accessory
        accessoryView.isHidden = presentation.accessory == nil
    }
}

private final class SidebarGroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarGroupCell")

    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor

        textField = titleField

        addSubview(titleField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(title: String) {
        titleField.stringValue = title
    }
}

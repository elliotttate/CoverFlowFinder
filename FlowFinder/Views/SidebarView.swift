import AppKit
import Combine
import SwiftUI
import IOKit
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

/// Where files dropped on a favorite row go: into the favorite folder (the middle of the row) or
/// between rows as new favorites (the edges, shown as the insertion line). Dragged folders are more
/// likely meant to become favorites, so their edges are wider and near a row boundary insertion wins.
enum FavoriteRowDropZone: Equatable {
    case before
    case into
    case after

    /// `fraction` is the pointer's position down the row (0 = top edge, 1 = bottom edge).
    static func zone(fraction: CGFloat, isDraggingFolders: Bool) -> FavoriteRowDropZone {
        let edge: CGFloat = isDraggingFolders ? 0.3 : 0.25
        if fraction < edge { return .before }
        if fraction >= 1 - edge { return .after }
        return .into
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

        let outlineView = SidebarNSOutlineView()
        outlineView.onReturn = { [weak coordinator = context.coordinator] in
            coordinator?.activateSelectedRow()
        }
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
        /// Set while the sections are expanded or collapsed in code, so only the user's changes are remembered.
        private var isRestoringExpansion = false
        private var volumeComparisonCache: (sequence: Int, destination: URL, sameVolume: Bool)?
        private var draggedKindsCache: (sequence: Int, kinds: DraggedFileKinds)?
        /// File promises for AirDrop are written on this queue so large files don't block the UI. Serial, so an
        /// operation added after the readers runs after every file already delivered.
        private let filePromiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.flowfinder.sidebar.filePromises"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 1
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
                isRestoringExpansion = true
                outlineView?.reloadData()
                restoreSectionExpansion()
                isRestoringExpansion = false
                isUpdatingSelection = false
            }

            updateSelection()
        }

        /// The rebuilt sections start collapsed: expand them, except the ones the user collapsed.
        private func restoreSectionExpansion() {
            guard let outlineView else { return }
            let collapsed = appSettings.sidebarCollapsedSections
            for section in sections {
                if collapsed.contains(section.kind.rawValue) {
                    outlineView.collapseItem(section)
                } else {
                    outlineView.expandItem(section)
                }
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            sectionExpansionChanged(notification, isCollapsed: false)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            sectionExpansionChanged(notification, isCollapsed: true)
        }

        private func sectionExpansionChanged(_ notification: Notification, isCollapsed: Bool) {
            guard !isRestoringExpansion,
                  let section = notification.userInfo?["NSObject"] as? SidebarSection else { return }
            var collapsed = appSettings.sidebarCollapsedSections
            if isCollapsed {
                collapsed.insert(section.kind.rawValue)
            } else {
                collapsed.remove(section.kind.rawValue)
            }
            appSettings.sidebarCollapsedSections = collapsed
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
                // Only folders become favorites; files can still be dropped into a favorite (the middle of its row).
                if !isInternal && !(hasURLs && draggedFileKinds(info).hasDirectory) {
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
                    return insertFavorites(urls: urls, at: favoritesIndex)
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
                // Written straight into the folder, like promises dropped on the file views.
                return DropHelper.receivePromisedFiles(into: destination)
            case .airDrop:
                return receiveFilePromisesForAirDrop(from: info) { [weak self] urls, tempDirectory in
                    guard let self, !urls.isEmpty else {
                        try? FileManager.default.removeItem(at: tempDirectory)
                        return
                    }
                    self.performAirDrop(urls: urls, temporaryDirectory: tempDirectory)
                }
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
            switch item.kind {
            case .airDrop, .photosLibrary:
                // Arrowing past these must not open the AirDrop picker or switch to the Photos library (which can
                // ask for permission): they act on a click or Return only.
                return
            default:
                handleSelection(for: item)
            }
        }

        /// Return on the highlighted row acts like clicking it.
        func activateSelectedRow() {
            guard let outlineView else { return }
            let row = outlineView.selectedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem, item.isEnabled else { return }
            handleSelection(for: item)
            updateSelection()
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

        /// Receives promised files into a new temporary folder, to send with AirDrop. `completion` runs on the main
        /// queue and owns the temporary folder. Returns false when there are no promises.
        private func receiveFilePromisesForAirDrop(from info: NSDraggingInfo, completion: @escaping @MainActor ([URL], URL) -> Void) -> Bool {
            let receivers = filePromiseReceivers(from: info.draggingPasteboard)
            guard !receivers.isEmpty else { return false }

            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FlowFinderDrop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

            Self.receivePromisedFiles(from: receivers, into: tempDirectory, queue: filePromiseQueue) { urls in
                completion(urls, tempDirectory)
            }
            return true
        }

        /// Receives every receiver's files into `directory`; `completion` runs once, on the main queue, with the
        /// files that arrived. A receiver's reader runs once per file it delivers (a legacy promise can deliver
        /// several), so each receiver leaves the group exactly once: when it has delivered its `fileNames.count`
        /// files (at least one), or on its first error. Files delivered after that are still collected: they're
        /// queued behind it on the serial `queue`.
        static func receivePromisedFiles(
            from receivers: [NSFilePromiseReceiver],
            into directory: URL,
            queue: OperationQueue,
            completion: @escaping @MainActor ([URL]) -> Void
        ) {
            let group = DispatchGroup()
            let lock = NSLock()
            var receivedURLs: [URL] = []

            for receiver in receivers {
                group.enter()
                var deliveries = 0
                var hasLeft = false
                receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                    lock.lock()
                    if error == nil {
                        receivedURLs.append(url)
                    }
                    deliveries += 1
                    let shouldLeave = !hasLeft && (error != nil || deliveries >= max(1, receiver.fileNames.count))
                    if shouldLeave {
                        hasLeft = true
                    }
                    lock.unlock()
                    if shouldLeave {
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                // Further files from a receiver are queued behind the ones waited for on the serial queue: take those too.
                queue.addOperation {
                    lock.lock()
                    let urls = receivedURLs
                    lock.unlock()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            completion(urls)
                        }
                    }
                }
            }
        }

        private struct DraggedFileKinds {
            /// Everything dragged is a folder (not a package).
            let isFolders: Bool
            /// At least one dragged item is a directory (packages included), i.e. something that can become a favorite.
            let hasDirectory: Bool
        }

        /// What kind of files are being dragged, read once per drag.
        private func draggedFileKinds(_ info: NSDraggingInfo) -> DraggedFileKinds {
            if let cached = draggedKindsCache, cached.sequence == info.draggingSequenceNumber {
                return cached.kinds
            }
            let urls = (info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]) ?? []
            let values = urls.map { try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) }
            let kinds = DraggedFileKinds(
                isFolders: !values.isEmpty && values.allSatisfy { $0?.isDirectory == true && $0?.isPackage != true },
                hasDirectory: values.contains { $0?.isDirectory == true }
            )
            draggedKindsCache = (info.draggingSequenceNumber, kinds)
            return kinds
        }

        private func draggingFavoriteIDs(from pasteboard: NSPasteboard) -> [String] {
            guard let items = pasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: internalDragType) }
        }

        /// Where a drag over the sidebar would land. The Favorites header inserts at the start; the strip below the
        /// last favorite, through the next section's header, appends; over a row, the upper half inserts before it
        /// and the lower half after it, except that external files dropped on the middle of a favorite go into that
        /// folder (see `FavoriteRowDropZone`). Between rows, the nearest row decides.
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
                switch FavoriteRowDropZone.zone(fraction: fraction, isDraggingFolders: draggedFileKinds(info).isFolders) {
                case .before: return insertion(at: sectionIndex)
                case .after: return insertion(at: sectionIndex + 1)
                case .into: return .onFavorite(item)
                }
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

        /// Adds the dragged folders as favorites; false when none could be added (no folders, or all already there).
        private func insertFavorites(urls: [URL], at index: Int) -> Bool {
            var favorites = appSettings.sidebarFavorites
            var insertIndex = min(max(0, index), favorites.count)

            for url in urls {
                guard let favorite = favoriteFromURL(url) else { continue }
                if isDuplicateFavorite(favorite, in: favorites) { continue }

                favorites.insert(favorite, at: insertIndex)
                insertIndex += 1
            }

            guard favorites != appSettings.sidebarFavorites else { return false }
            appSettings.sidebarFavorites = favorites
            return true
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
                // Network volumes have no icon loaded (reading one could hang on an unresponsive server).
                let fallbackSymbol = location.url.path == "/"
                    ? "desktopcomputer"
                    : location.isNetwork ? "externaldrive.connected.to.line.below" : "externaldrive"
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

        /// Opens the AirDrop picker for `urls`. `temporaryDirectory` (received file promises) is removed once AirDrop
        /// is done with it, or right away if nothing is shared.
        private func performAirDrop(urls: [URL], temporaryDirectory: URL? = nil) {
            func discardTemporaryFiles() {
                if let temporaryDirectory {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                }
            }

            let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !validURLs.isEmpty else {
                discardTemporaryFiles()
                showAirDropAlert(
                    title: "AirDrop",
                    message: "The selected items are not available to share."
                )
                return
            }

            guard let service = NSSharingService(named: .sendViaAirDrop) else {
                discardTemporaryFiles()
                showAirDropAlert(
                    title: "AirDrop Unavailable",
                    message: "AirDrop is not available on this Mac right now."
                )
                return
            }

            guard service.canPerform(withItems: validURLs) else {
                discardTemporaryFiles()
                showAirDropAlert(
                    title: "AirDrop Unavailable",
                    message: "AirDrop cannot share the selected items."
                )
                return
            }

            if let temporaryDirectory {
                // `perform` only opens the picker; the files are read when the user picks a recipient.
                service.delegate = SidebarAirDropTemporaryFiles.keep(temporaryDirectory)
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

/// Everything the sidebar shows that needs file-system access, kept up to date in the background by
/// `SidebarEnvironmentStore`.
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

    /// The computer, mounted volumes, iCloud Drive and the Photos library. Blocking, but it only reads local disks
    /// (network volumes are never touched, see `volumeLocations`): call off the main thread.
    static func loadVolumes(fileManager: FileManager = .default) -> SidebarVolumeState {
        let computerName = currentComputerName()
        let locations = volumeLocations(computerName: computerName)

        var icons: [String: NSImage] = [:]
        for location in locations where location != .network && !location.isNetwork {
            icons[location.url.path] = NSWorkspace.shared.icon(forFile: location.url.path)
        }

        return SidebarVolumeState(
            computerName: computerName,
            iCloudURL: iCloudDriveURL(fileManager: fileManager),
            photosLibraryInfo: photosLibraryInfo(fileManager: fileManager),
            locations: locations,
            icons: icons
        )
    }

    /// Resolves one favorite and loads its icon. Blocking (bookmark resolution, existence checks): call off the main
    /// thread. A custom favorite on a network volume isn't touched at all (a server that stopped responding would
    /// block here): it counts as available while its volume is mounted.
    static func resolveFavorite(_ favorite: SidebarFavorite, mounts: SidebarMountTable) -> (resolution: SidebarFavoriteResolution, icon: NSImage?) {
        if favorite.kind == .custom,
           let path = favorite.path, !path.isEmpty,
           let mount = mounts.mount(containing: path), !mount.isLocal {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let resolution = SidebarFavoriteResolution(favorite: favorite, url: url, name: url.lastPathComponent, isAvailable: true, updatedFavorite: nil)
            return (resolution, nil)
        }

        let resolution = favorite.resolve()
        guard resolution.isAvailable, let url = resolution.url else { return (resolution, nil) }
        return (resolution, NSWorkspace.shared.icon(forFile: url.path))
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

    /// The computer, then the browsable mounted volumes by name, then Network. Local volumes are asked for their name
    /// and whether they're ejectable; network volumes come from the mount table alone.
    static func volumeLocations(computerName: String, mounts: SidebarMountTable = .current()) -> [SidebarLocation] {
        var locations = [SidebarLocation(name: computerName, url: URL(fileURLWithPath: "/", isDirectory: true), isEjectable: false, isNetwork: false)]

        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey
        ]
        var mounted: [SidebarLocation] = []
        // Browsable volumes only, like Finder: no system volumes or `-nobrowse` mounts. The boot volume is already
        // listed as the computer.
        for mount in mounts.mounts where mount.isBrowsable && !mount.isRoot && mount.path != "/" {
            let url = URL(fileURLWithPath: mount.path, isDirectory: true)
            guard mount.isLocal else {
                mounted.append(SidebarLocation(name: networkVolumeName(mount), url: url, isEjectable: true, isNetwork: true))
                continue
            }
            let values = try? url.resourceValues(forKeys: keys)
            let isEjectable = values?.volumeIsEjectable == true
                || values?.volumeIsRemovable == true
                || values?.volumeIsInternal == false
            // The name Finder shows: two disks named "Untitled" are both "Untitled" (mounted at "Untitled" and "Untitled 1").
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            mounted.append(SidebarLocation(name: name, url: url, isEjectable: isEjectable, isNetwork: false))
        }
        mounted.sort { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }

        locations += mounted
        locations.append(.network)
        return locations
    }

    /// A network share's name from what was mounted (`//user@server/My%20Share` is "My Share"), else its mount point's.
    private static func networkVolumeName(_ mount: SidebarMountTable.Mount) -> String {
        if mount.source.hasPrefix("//") {
            let components = mount.source.split(separator: "/")
            if components.count >= 2, let share = components.last {
                let name = String(share).removingPercentEncoding ?? String(share)
                if !name.isEmpty { return name }
            }
        }
        return URL(fileURLWithPath: mount.path, isDirectory: true).lastPathComponent
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

/// The part of `SidebarEnvironment` that doesn't depend on the favorites, from `SidebarEnvironment.loadVolumes()`.
struct SidebarVolumeState {
    let computerName: String
    let iCloudURL: URL?
    let photosLibraryInfo: PhotosLibraryInfo?
    let locations: [SidebarLocation]
    /// Icons of the local volumes, by path.
    let icons: [String: NSImage]
}

/// The mounted file systems, from `getfsstat` with `MNT_NOWAIT`: the kernel's cached list, so reading it never waits
/// on a volume (not even a network share whose server stopped responding). Cheap enough for the main thread.
struct SidebarMountTable {
    struct Mount: Equatable {
        /// Mount point.
        let path: String
        /// What's mounted there, e.g. `/dev/disk5s1` or `//user@server/Share`.
        let source: String
        let isLocal: Bool
        /// Not mounted `nobrowse` (system volumes, `-nobrowse` disk images): the volumes Finder lists.
        let isBrowsable: Bool
        let isRoot: Bool
    }

    let mounts: [Mount]

    static func current() -> SidebarMountTable {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return SidebarMountTable(mounts: []) }
        // Room for volumes mounted in between the two calls.
        let capacity = Int(count) + 8
        let entries = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { entries.deallocate() }
        let filled = Int(getfsstat(entries, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        guard filled > 0 else { return SidebarMountTable(mounts: []) }

        func string<T>(_ characters: T) -> String {
            withUnsafeBytes(of: characters) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        let localFlag = UInt32(MNT_LOCAL)
        let noBrowseFlag = UInt32(MNT_DONTBROWSE)
        let rootFlag = UInt32(MNT_ROOTFS)
        var mounts: [Mount] = []
        for index in 0..<min(filled, capacity) {
            let entry = entries[index]
            let flags: UInt32 = entry.f_flags
            mounts.append(Mount(
                path: string(entry.f_mntonname),
                source: string(entry.f_mntfromname),
                isLocal: flags & localFlag != 0,
                isBrowsable: flags & noBrowseFlag == 0,
                isRoot: flags & rootFlag != 0
            ))
        }
        return SidebarMountTable(mounts: mounts)
    }

    /// The mount that holds `path`: the longest mount point it's inside of (by path, symlinks aren't followed).
    func mount(containing path: String) -> Mount? {
        var best: Mount?
        for mount in mounts {
            let isInside = mount.path == "/" || path == mount.path || path.hasPrefix(mount.path + "/")
            guard isInside, mount.path.count > (best?.path.count ?? -1) else { continue }
            best = mount
        }
        return best
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
///
/// The volume list and the favorites load independently: volumes in one coalesced load at a time, each favorite on
/// its own. A favorite whose folder doesn't answer (a disk that hangs) never holds up mount and unmount updates or
/// the other favorites.
@MainActor
final class SidebarEnvironmentStore {
    static let shared = SidebarEnvironmentStore()

    private(set) var environment = SidebarEnvironment.initial
    /// Sent on the main queue whenever `environment` changes.
    let environmentDidChange = PassthroughSubject<Void, Never>()

    private static let timerInterval: TimeInterval = 60
    private static let activationRefreshInterval: TimeInterval = 5
    /// A new or edited favorite that hasn't resolved after this long shows as unavailable until its answer arrives.
    static let favoriteResolutionTimeout: TimeInterval = 5

    private let volumeQueue = DispatchQueue(label: "com.flowfinder.sidebar.volumes", qos: .utility)
    private let favoriteQueue = DispatchQueue(label: "com.flowfinder.sidebar.favorites", qos: .utility, attributes: .concurrent)
    private var isLoadingVolumes = false
    private var needsAnotherVolumeLoad = false
    private var lastLoadStart = Date.distantPast
    private var favorites: [SidebarFavorite] = []
    private weak var settings: AppSettings?

    private struct PendingResolution {
        let favorite: SidebarFavorite
        let token: Int
        /// Requested again while running: resolve once more when it finishes.
        var needsRerun = false
    }
    /// Resolutions in flight, by favorite id: at most one per favorite, so one on a hung volume ties up one thread
    /// rather than one per refresh. A newer request for an edited favorite replaces it (the old answer is dropped).
    private var pendingResolutions: [String: PendingResolution] = [:]
    private var nextResolutionToken = 0
    private var locationIcons: [String: NSImage] = [:]
    /// By favorite id.
    private var favoriteIcons: [String: (path: String, image: NSImage)] = [:]
    /// Resolutions whose moved path or new bookmark is waiting to be written to the settings (in one batch).
    private var pendingFavoriteUpdates: [SidebarFavoriteResolution] = []
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
        // Forget removed favorites (not a visible change: rows come from the favorites list).
        let ids = Set(favorites.map(\.id))
        environment.favoriteResolutions = environment.favoriteResolutions.filter { ids.contains($0.key) }
        favoriteIcons = favoriteIcons.filter { ids.contains($0.key) }
        requestRefresh()
    }

    /// Reloads the volumes and resolves every favorite again, in the background.
    func requestRefresh() {
        lastLoadStart = Date()
        loadVolumes()
        let mounts = SidebarMountTable.current()
        for favorite in favorites {
            resolve(favorite, mounts: mounts)
        }
    }

    // MARK: Volumes

    /// One load at a time; requests made meanwhile are coalesced into one more load.
    private func loadVolumes() {
        guard !isLoadingVolumes else {
            needsAnotherVolumeLoad = true
            return
        }
        isLoadingVolumes = true
        volumeQueue.async {
            let state = SidebarEnvironment.loadVolumes()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SidebarEnvironmentStore.shared.finishVolumeLoad(state)
                }
            }
        }
    }

    private func finishVolumeLoad(_ state: SidebarVolumeState) {
        isLoadingVolumes = false
        locationIcons = state.icons
        var updated = environment
        updated.computerName = state.computerName
        updated.iCloudURL = state.iCloudURL
        updated.photosLibraryInfo = state.photosLibraryInfo
        updated.locations = state.locations
        apply(updated)

        if needsAnotherVolumeLoad {
            needsAnotherVolumeLoad = false
            loadVolumes()
        }
    }

    // MARK: Favorites

    private func resolve(_ favorite: SidebarFavorite, mounts: SidebarMountTable) {
        if var pending = pendingResolutions[favorite.id], pending.favorite == favorite {
            pending.needsRerun = true
            pendingResolutions[favorite.id] = pending
            return
        }
        nextResolutionToken += 1
        let token = nextResolutionToken
        pendingResolutions[favorite.id] = PendingResolution(favorite: favorite, token: token)

        favoriteQueue.async {
            let result = SidebarEnvironment.resolveFavorite(favorite, mounts: mounts)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SidebarEnvironmentStore.shared.finishResolution(result.resolution, icon: result.icon, token: token)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.favoriteResolutionTimeout) {
            MainActor.assumeIsolated {
                SidebarEnvironmentStore.shared.resolutionTimedOut(favoriteID: favorite.id, token: token)
            }
        }
    }

    private func finishResolution(_ resolution: SidebarFavoriteResolution, icon: NSImage?, token: Int) {
        let id = resolution.favorite.id
        guard let pending = pendingResolutions[id], pending.token == token else { return }
        pendingResolutions[id] = nil

        // Only for the favorite as it is now (not one edited or removed meanwhile).
        if favorites.contains(resolution.favorite) {
            if let icon, let url = resolution.url {
                favoriteIcons[id] = (url.path, icon)
            } else {
                favoriteIcons[id] = nil
            }
            var updated = environment
            updated.favoriteResolutions[id] = resolution
            apply(updated)
            if resolution.updatedFavorite != nil {
                scheduleFavoriteUpdate(resolution)
            }
        }

        if pending.needsRerun, let current = favorites.first(where: { $0.id == id }) {
            resolve(current, mounts: .current())
        }
    }

    private func resolutionTimedOut(favoriteID id: String, token: Int) {
        guard let pending = pendingResolutions[id], pending.token == token,
              favorites.contains(pending.favorite),
              environment.favoriteResolutions[id]?.favorite != pending.favorite else { return }
        // Not known yet and not answering: show it as unavailable rather than let a click wait on it. (A favorite
        // that resolved before keeps its last state.)
        let provisional = SidebarFavoriteResolution.provisional(for: pending.favorite)
        var updated = environment
        updated.favoriteResolutions[id] = SidebarFavoriteResolution(
            favorite: pending.favorite,
            url: provisional.url,
            name: provisional.name,
            isAvailable: false,
            updatedFavorite: nil
        )
        apply(updated)
    }

    /// Updates arriving together are written to the settings in one go.
    private func scheduleFavoriteUpdate(_ resolution: SidebarFavoriteResolution) {
        pendingFavoriteUpdates.append(resolution)
        guard pendingFavoriteUpdates.count == 1 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SidebarEnvironmentStore.shared.applyFavoriteUpdates()
            }
        }
    }

    /// Stores moved paths and new bookmarks back into the settings.
    private func applyFavoriteUpdates() {
        let resolutions = pendingFavoriteUpdates
        pendingFavoriteUpdates.removeAll()
        guard let settings else { return }
        var favorites = settings.sidebarFavorites
        var changed = false

        for resolution in resolutions {
            // Only if the favorite hasn't been edited since it was resolved.
            guard let updated = resolution.updatedFavorite,
                  let index = favorites.firstIndex(of: resolution.favorite) else { continue }
            if !resolution.didMove {
                guard rebookmarkedFavoriteIDs.insert(resolution.favorite.id).inserted else { continue }
            }
            favorites[index] = updated
            changed = true
        }

        if changed {
            settings.sidebarFavorites = favorites
        }
    }

    // MARK: Publishing

    /// Replaces the environment (with the current icons) and announces it if anything shown changed.
    private func apply(_ updated: SidebarEnvironment) {
        var icons = locationIcons
        for (path, image) in favoriteIcons.values {
            icons[path] = image
        }
        var updated = updated
        updated.icons = SidebarIconSet(icons)
        let changed = updated != environment
        environment = updated
        if changed {
            environmentDidChange.send()
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
    /// Like Finder: a volume that shares its disk with other mounted volumes asks whether to eject all of them or
    /// just this one; otherwise the whole disk is ejected. Network shares are unmounted.
    static func eject(_ location: SidebarLocation, window: NSWindow?) {
        guard !location.isNetwork else {
            unmount(location, otherVolumes: [], ejectingDisk: false, window: window)
            return
        }
        let others = otherMountedVolumes(onDiskOf: location.url)
        guard !others.isEmpty else {
            unmount(location, otherVolumes: [], ejectingDisk: true, window: window)
            return
        }

        let name = location.name.finderDisplayName
        let otherNames = others.map { "“\(URL(fileURLWithPath: $0.path, isDirectory: true).finderDisplayName)”" }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "“\(name)” is on a disk with other volumes."
        alert.informativeText = "Do you want to eject all volumes on the disk (also \(ListFormatter.localizedString(byJoining: otherNames))), or just “\(name)”?"
        alert.addButton(withTitle: "Eject All")
        alert.addButton(withTitle: "Eject")
        alert.addButton(withTitle: "Cancel")

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                unmount(location, otherVolumes: others, ejectingDisk: true, window: window)
            case .alertSecondButtonReturn:
                unmount(location, otherVolumes: [], ejectingDisk: false, window: window)
            default:
                break
            }
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            handle(alert.runModal())
        }
    }

    /// Unmounts `location`; with `ejectingDisk`, every volume on its disk and the disk itself.
    private static func unmount(_ location: SidebarLocation, otherVolumes: [SidebarMountTable.Mount], ejectingDisk: Bool, window: NSWindow?) {
        let url = location.url
        let name = location.name
        // Let panes showing these volumes move away and stop watching them first, so we don't block our own eject.
        let announcedURLs = [url] + otherVolumes.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        for volumeURL in announcedURLs {
            SidebarEnvironmentStore.postVolumeNotification(.volumeWillUnmount, volumeURL: volumeURL)
        }

        let options: FileManager.UnmountOptions = ejectingDisk
            ? [.allPartitionsAndEjectDisk, .withoutUI]
            : [.withoutUI]

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak window] in
            FileManager.default.unmountVolume(at: url, options: options) { error in
                let failure = error.map { $0 as NSError }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let failure {
                            // Panes that left these volumes for the eject come back (volumes that did go
                            // away were already reported by didUnmount).
                            for volumeURL in announcedURLs {
                                SidebarEnvironmentStore.postVolumeNotification(.volumeUnmountFailed, volumeURL: volumeURL)
                            }
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

    /// The other browsable volumes mounted from the physical disk that holds `volumeURL` (none for a network volume).
    /// Reads only the mount table and the I/O Registry, so it never waits on a volume.
    static func otherMountedVolumes(onDiskOf volumeURL: URL, mounts: SidebarMountTable = .current()) -> [SidebarMountTable.Mount] {
        let path = volumeURL.standardizedFileURL.path
        guard let volume = mounts.mounts.first(where: { $0.path == path }),
              let disk = physicalDisk(ofDevice: volume.source) else { return [] }
        return mounts.mounts.filter { mount in
            mount.path != volume.path && mount.isBrowsable && !mount.isRoot
                && physicalDisk(ofDevice: mount.source) == disk
        }
    }

    /// The BSD name of the physical disk a device such as `/dev/disk5s1` is on: the outermost whole disk above it in
    /// the I/O Registry, which follows an APFS container to its physical store. Nil for anything that isn't a disk.
    static func physicalDisk(ofDevice device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let bsdName = String(device.dropFirst("/dev/".count))
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        var outermost: String?
        while entry != IO_OBJECT_NULL {
            if IOObjectConformsTo(entry, "IOMedia") != 0,
               (IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true,
               let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                outermost = name
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = status == KERN_SUCCESS ? parent : IO_OBJECT_NULL
        }
        return outermost
    }

    static func presentEjectError(_ error: NSError, volumeName: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The volume “\(volumeName.finderDisplayName)” wasn’t ejected."

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

/// Promised files received for AirDrop live in a temporary folder that must outlast `NSSharingService.perform`, which
/// only opens the picker. The folder is removed when the share finishes, fails or is cancelled, or when the app quits.
@MainActor
final class SidebarAirDropTemporaryFiles: NSObject, NSSharingServiceDelegate {
    private static var pending: [SidebarAirDropTemporaryFiles] = []
    private static var quitObserver: NSObjectProtocol?

    let directory: URL

    private init(directory: URL) {
        self.directory = directory
    }

    /// Keeps `directory` until the share ends. Use the result as the sharing service's delegate (it's kept alive here:
    /// the service only holds its delegate weakly).
    static func keep(_ directory: URL) -> SidebarAirDropTemporaryFiles {
        let files = SidebarAirDropTemporaryFiles(directory: directory)
        pending.append(files)
        if quitObserver == nil {
            quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    for files in SidebarAirDropTemporaryFiles.pending {
                        try? FileManager.default.removeItem(at: files.directory)
                    }
                    SidebarAirDropTemporaryFiles.pending.removeAll()
                }
            }
        }
        return files
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish()
    }

    private func finish() {
        try? FileManager.default.removeItem(at: directory)
        Self.pending.removeAll { $0 === self }
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

/// Return acts on the highlighted row (arrowing only moves the highlight for AirDrop and Photos).
private final class SidebarNSOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
    }
}

private final class SidebarSection: NSObject {
    /// Raw values are stored in `AppSettings.sidebarCollapsedSections`.
    enum Kind: String {
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

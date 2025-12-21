import AppKit
import SwiftUI

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

        var draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, context.coordinator.internalDragType]
        draggedTypes.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        outlineView.registerForDraggedTypes(draggedTypes)
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu(title: "Sidebar")
        menu.delegate = context.coordinator
        outlineView.menu = menu

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        context.coordinator.refreshIfNeeded(force: true)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.appSettings = appSettings
        context.coordinator.viewModel = viewModel
        context.coordinator.refreshIfNeeded(force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var appSettings: AppSettings
        var viewModel: FileBrowserViewModel
        weak var outlineView: NSOutlineView?
        let internalDragType = NSPasteboard.PasteboardType("com.coverflowfinder.sidebar.favorite")

        private var sections: [SidebarSection] = []
        private var snapshot: SidebarSnapshot?
        private var isUpdatingSelection = false
        private let insertZoneHeight: CGFloat = 6

        init(appSettings: AppSettings, viewModel: FileBrowserViewModel) {
            self.appSettings = appSettings
            self.viewModel = viewModel
        }

        func refreshIfNeeded(force: Bool) {
            let context = buildContext()
            let nextSnapshot = SidebarSnapshot(
                showFavorites: appSettings.sidebarShowFavorites,
                showICloud: appSettings.sidebarShowICloud,
                showLocations: appSettings.sidebarShowLocations,
                showTags: appSettings.sidebarShowTags,
                favorites: appSettings.sidebarFavorites,
                filterTag: viewModel.filterTag,
                iCloudURL: context.iCloudURL,
                photosLibraryInfo: context.photosLibraryInfo,
                locations: context.locations
            )

            if force || snapshot != nextSnapshot {
                snapshot = nextSnapshot
                sections = buildSections(context: context)
                outlineView?.reloadData()
                expandAllSections()
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
            guard case let .favorite(resolvedFavorite) = sidebarItem.kind else { return nil }

            let pbItem = NSPasteboardItem()
            pbItem.setString(resolvedFavorite.favorite.id, forType: internalDragType)
            if let url = resolvedFavorite.url {
                pbItem.setString(url.absoluteString, forType: .fileURL)
            }
            return pbItem
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
                outlineView.setDropItem(favoriteItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
                if isInternal {
                    return .move
                }
                return NSEvent.modifierFlags.contains(.option) ? .copy : .move
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
                    guard case let .favorite(resolvedFavorite) = favoriteItem.kind,
                          let destination = resolvedFavorite.url else { return false }
                    viewModel.handleDrop(urls: urls, to: destination)
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
                guard case let .favorite(resolvedFavorite) = favoriteItem.kind,
                      let destination = resolvedFavorite.url else { return false }
                receiveFilePromises(from: info) { [weak self] urls, tempDirectory in
                    guard let self, !urls.isEmpty else { return }
                    self.viewModel.handleDrop(urls: urls, to: destination) {
                        if let tempDirectory {
                            try? FileManager.default.removeItem(at: tempDirectory)
                        }
                    }
                }
                return true
            case .airDrop:
                receiveFilePromises(from: info) { [weak self] urls, tempDirectory in
                    guard let self, !urls.isEmpty else { return }
                    self.performAirDrop(urls: urls)
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

            let row = outlineView.selectedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }
            handleSelection(for: item)
        }

        // MARK: - NSMenuDelegate

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outlineView = outlineView else { return }
            let row = outlineView.clickedRow
            guard row >= 0, let item = outlineView.item(atRow: row) as? SidebarItem else { return }

            guard case let .favorite(resolvedFavorite) = item.kind else { return }

            let removeItem = NSMenuItem(title: "Remove from Favorites", action: #selector(removeFavoriteFromMenu(_:)), keyEquivalent: "")
            removeItem.representedObject = resolvedFavorite.favorite.id
            removeItem.target = self
            menu.addItem(removeItem)
        }

        @objc private func removeFavoriteFromMenu(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            appSettings.sidebarFavorites.removeAll { $0.id == id }
        }

        // MARK: - Selection

        private func handleSelection(for item: SidebarItem) {
            switch item.kind {
            case .airDrop:
                triggerAirDropFromSelection()
            case .favorite(let resolvedFavorite):
                guard resolvedFavorite.isAvailable, let url = resolvedFavorite.url else { return }
                viewModel.navigateTo(url)
            case .photosLibrary(let info, let isAvailable):
                guard isAvailable, let info else { return }
                viewModel.viewMode = .masonry
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

        private func updateSelection() {
            guard let outlineView = outlineView else { return }
            let itemToSelect: SidebarItem?

            if let filterTag = viewModel.filterTag {
                itemToSelect = findTagItem(named: filterTag)
            } else {
                itemToSelect = bestMatchingLocationItem(for: viewModel.currentPath)
            }

            isUpdatingSelection = true
            if let itemToSelect {
                let row = outlineView.row(forItem: itemToSelect)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else {
                    outlineView.deselectAll(nil)
                }
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

        private func filePromiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
            (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        }

        private func receiveFilePromises(from info: NSDraggingInfo, completion: @escaping ([URL], URL?) -> Void) {
            let receivers = filePromiseReceivers(from: info.draggingPasteboard)
            guard !receivers.isEmpty else {
                completion([], nil)
                return
            }

            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("CoverFlowFinderDrop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

            let group = DispatchGroup()
            let lock = NSLock()
            var receivedURLs: [URL] = []

            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: tempDirectory, options: [:], operationQueue: .main) { url, error in
                    if error == nil {
                        lock.lock()
                        receivedURLs.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                completion(receivedURLs, tempDirectory)
            }
        }

        private func draggingFavoriteIDs(from pasteboard: NSPasteboard) -> [String] {
            guard let items = pasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: internalDragType) }
        }

        private func dropTarget(for info: NSDraggingInfo,
                                in favoritesSection: SidebarSection,
                                isInternal: Bool,
                                isExternal: Bool) -> DropTarget? {
            guard let outlineView = outlineView else { return nil }
            let location = outlineView.convert(info.draggingLocation, from: nil)
            let row = outlineView.row(at: location)

            let minSectionIndex = firstFavoriteSectionIndex(in: favoritesSection)
            let maxSectionIndex = favoritesSection.items.count

            if row >= 0 {
                if let section = outlineView.item(atRow: row) as? SidebarSection {
                    guard section.kind == .favorites else { return nil }
                    let sectionIndex = maxSectionIndex
                    let favoritesIndex = favoritesIndex(forSectionIndex: sectionIndex, in: favoritesSection)
                    return .between(sectionIndex: sectionIndex, favoritesIndex: favoritesIndex)
                }

                guard let item = outlineView.item(atRow: row) as? SidebarItem else { return nil }
                guard item.sectionKind == .favorites else { return nil }

                if case .airDrop = item.kind, isExternal {
                    return .airDrop(item)
                }

                let rowRect = outlineView.rect(ofRow: row)
                let yInRow = location.y - rowRect.minY
                let inTopZone = yInRow <= insertZoneHeight
                let inBottomZone = yInRow >= (rowRect.height - insertZoneHeight)

                let sectionIndex = favoritesSection.items.firstIndex(where: { $0 === item }) ?? 0

                if !isInternal,
                   case let .favorite(resolvedFavorite) = item.kind,
                   resolvedFavorite.isAvailable,
                   resolvedFavorite.url != nil,
                   !inTopZone,
                   !inBottomZone {
                    return .onFavorite(item)
                }

                let insertionIndex = (inBottomZone ? sectionIndex + 1 : sectionIndex)
                let clampedSectionIndex = min(max(insertionIndex, minSectionIndex), maxSectionIndex)
                let favoritesIndex = favoritesIndex(forSectionIndex: clampedSectionIndex, in: favoritesSection)
                return .between(sectionIndex: clampedSectionIndex, favoritesIndex: favoritesIndex)
            }

            guard favoritesSection.kind == .favorites else { return nil }

            if let firstRow = firstRowIndex(for: favoritesSection),
               let lastRow = lastRowIndex(for: favoritesSection) {
                let firstRect = outlineView.rect(ofRow: firstRow)
                let lastRect = outlineView.rect(ofRow: lastRow)

                if location.y < firstRect.minY {
                    let sectionIndex = minSectionIndex
                    let favoritesIndex = favoritesIndex(forSectionIndex: sectionIndex, in: favoritesSection)
                    return .between(sectionIndex: sectionIndex, favoritesIndex: favoritesIndex)
                }

                if location.y > lastRect.maxY {
                    let sectionIndex = maxSectionIndex
                    let favoritesIndex = favoritesIndex(forSectionIndex: sectionIndex, in: favoritesSection)
                    return .between(sectionIndex: sectionIndex, favoritesIndex: favoritesIndex)
                }
            }

            return nil
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

        private func firstRowIndex(for section: SidebarSection) -> Int? {
            guard let outlineView = outlineView else { return nil }
            let rows = section.items.compactMap { item -> Int? in
                let row = outlineView.row(forItem: item)
                return row >= 0 ? row : nil
            }
            return rows.min()
        }

        private func lastRowIndex(for section: SidebarSection) -> Int? {
            guard let outlineView = outlineView else { return nil }
            let rows = section.items.compactMap { item -> Int? in
                let row = outlineView.row(forItem: item)
                return row >= 0 ? row : nil
            }
            return rows.max()
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
            var insertIndex = min(max(0, index), appSettings.sidebarFavorites.count)

            for url in urls {
                guard let favorite = favoriteFromURL(url) else { continue }
                if isDuplicateFavorite(favorite) { continue }

                appSettings.sidebarFavorites.insert(favorite, at: insertIndex)
                insertIndex += 1
            }
        }

        private func favoriteFromURL(_ url: URL) -> SidebarFavorite? {
            let standardizedURL = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return SidebarFavorite.custom(path: standardizedURL.path)
        }

        private func isDuplicateFavorite(_ favorite: SidebarFavorite) -> Bool {
            guard let newURL = resolvedURL(for: favorite) else { return false }
            let newPath = newURL.standardizedFileURL.path
            return appSettings.sidebarFavorites.contains { existing in
                guard let existingURL = resolvedURL(for: existing) else { return false }
                return existingURL.standardizedFileURL.path == newPath
            }
        }

        // MARK: - Data Building

        private func buildContext() -> SidebarBuildContext {
            let iCloudURL = iCloudDriveURL()
            let locations = volumeLocations()
            let photosLibraryInfo = photosLibraryInfo()
            return SidebarBuildContext(iCloudURL: iCloudURL, photosLibraryInfo: photosLibraryInfo, locations: locations)
        }

        private func iCloudDriveURL() -> URL? {
            guard FileManager.default.ubiquityIdentityToken != nil else { return nil }

            let homeURL = FileManager.default.homeDirectoryForCurrentUser
            let cloudStorageURL = homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("CloudStorage", isDirectory: true)
                .appendingPathComponent("iCloud Drive", isDirectory: true)

            if FileManager.default.fileExists(atPath: cloudStorageURL.path) {
                return cloudStorageURL
            }

            let mobileDocsURL = homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Mobile Documents", isDirectory: true)
                .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)

            if FileManager.default.fileExists(atPath: mobileDocsURL.path) {
                return mobileDocsURL
            }

            return nil
        }

        private func photosLibraryInfo() -> PhotosLibraryInfo? {
            let fm = FileManager.default
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
                ?? libraries.sorted(by: { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate > rhsDate
                }).first

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

        private func buildSections(context: SidebarBuildContext) -> [SidebarSection] {
            var sections: [SidebarSection] = []

            if appSettings.sidebarShowFavorites {
                let section = SidebarSection(kind: .favorites, title: "Favorites")
                var items: [SidebarItem] = []
                items.append(SidebarItem(kind: .airDrop, id: "airdrop", title: "AirDrop"))

                let photosAvailable = context.photosLibraryInfo != nil
                items.append(SidebarItem(
                    kind: .photosLibrary(context.photosLibraryInfo, photosAvailable),
                    id: "photosLibrary",
                    title: "Photos Library",
                    isEnabled: photosAvailable
                ))

                for favorite in appSettings.sidebarFavorites {
                    let resolved = resolveFavorite(favorite)
                    let item = SidebarItem(
                        kind: .favorite(resolved),
                        id: resolved.favorite.id,
                        title: resolved.name,
                        isEnabled: resolved.isAvailable
                    )
                    items.append(item)
                }
                section.items = items
                sections.append(section)
            }

            if appSettings.sidebarShowICloud {
                let section = SidebarSection(kind: .icloud, title: "iCloud")
                let isAvailable = context.iCloudURL != nil
                let item = SidebarItem(
                    kind: .iCloud(context.iCloudURL, isAvailable),
                    id: "icloud",
                    title: "iCloud Drive",
                    isEnabled: isAvailable
                )
                section.items = [item]
                sections.append(section)
            }

            if appSettings.sidebarShowLocations {
                let section = SidebarSection(kind: .locations, title: "Locations")
                section.items = context.locations.map { location in
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

        private func resolveFavorite(_ favorite: SidebarFavorite) -> ResolvedFavorite {
            switch favorite.kind {
            case .custom:
                let path = favorite.path ?? ""
                let url = path.isEmpty ? nil : URL(fileURLWithPath: path)
                let name = path.isEmpty ? "Missing Folder" : url?.lastPathComponent ?? "Missing Folder"
                let isAvailable = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                return ResolvedFavorite(favorite: favorite, name: name, url: url, isAvailable: isAvailable)
            default:
                let info = systemFavoriteInfo(for: favorite.kind)
                let isAvailable = info?.url != nil
                return ResolvedFavorite(favorite: favorite, name: info?.name ?? favorite.kind.rawValue.capitalized, url: info?.url, isAvailable: isAvailable)
            }
        }

        private func systemFavoriteInfo(for kind: SidebarFavorite.Kind) -> SystemFavoriteInfo? {
            let fm = FileManager.default
            switch kind {
            case .documents:
                return SystemFavoriteInfo(name: "Documents", url: fm.urls(for: .documentDirectory, in: .userDomainMask).first)
            case .applications:
                return SystemFavoriteInfo(name: "Applications", url: fm.urls(for: .applicationDirectory, in: .localDomainMask).first)
            case .desktop:
                return SystemFavoriteInfo(name: "Desktop", url: fm.urls(for: .desktopDirectory, in: .userDomainMask).first)
            case .downloads:
                return SystemFavoriteInfo(name: "Downloads", url: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first)
            case .movies:
                return SystemFavoriteInfo(name: "Movies", url: fm.urls(for: .moviesDirectory, in: .userDomainMask).first)
            case .music:
                return SystemFavoriteInfo(name: "Music", url: fm.urls(for: .musicDirectory, in: .userDomainMask).first)
            case .pictures:
                return SystemFavoriteInfo(name: "Pictures", url: fm.urls(for: .picturesDirectory, in: .userDomainMask).first)
            case .custom:
                return nil
            }
        }

        private func resolvedURL(for favorite: SidebarFavorite) -> URL? {
            switch favorite.kind {
            case .custom:
                guard let path = favorite.path else { return nil }
                return URL(fileURLWithPath: path)
            default:
                return systemFavoriteInfo(for: favorite.kind)?.url
            }
        }

        private func favoritesSection() -> SidebarSection? {
            sections.first { $0.kind == .favorites }
        }

        private func volumeLocations() -> [SidebarLocation] {
            var locations: [SidebarLocation] = []
            let fm = FileManager.default

            // Add the computer itself, pointing to root
            let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            locations.append(SidebarLocation(name: computerName, url: URL(fileURLWithPath: "/")))

            // Get the boot volume name (the volume that "/" is on)
            let bootVolumePath = (try? fm.destinationOfSymbolicLink(atPath: "/Volumes/Macintosh HD")) ?? "/"
            let bootVolumeRealPath = URL(fileURLWithPath: "/").standardizedFileURL.path

            // Add mounted volumes, excluding the boot volume (which is already "/" via the computer name)
            let volumesURL = URL(fileURLWithPath: "/Volumes")
            if let volumes = try? fm.contentsOfDirectory(
                at: volumesURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .volumeIsLocalKey],
                options: .skipsHiddenFiles
            ) {
                for volume in volumes {
                    // Skip symlinks that point to root (like "Macintosh HD" -> "/")
                    let isSymlink = (try? volume.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                    if isSymlink {
                        if let destination = try? fm.destinationOfSymbolicLink(atPath: volume.path) {
                            let resolvedPath = URL(fileURLWithPath: destination, relativeTo: volumesURL).standardizedFileURL.path
                            if resolvedPath == bootVolumeRealPath || resolvedPath == "/" {
                                continue
                            }
                        }
                    }

                    // Also check if this volume resolves to the same device as root
                    let volumeRealPath = volume.standardizedFileURL.resolvingSymlinksInPath().path
                    if volumeRealPath == bootVolumeRealPath || volumeRealPath == "/" {
                        continue
                    }

                    let name = volume.lastPathComponent
                    locations.append(SidebarLocation(name: name, url: volume))
                }
            }

            // Add Network location
            locations.append(SidebarLocation(name: "Network", url: URL(fileURLWithPath: "/Network")))
            return locations
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
            case .favorite(let resolvedFavorite):
                let icon = resolvedFavorite.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? symbolIcon(name: "folder")
                return SidebarItemPresentation(
                    title: resolvedFavorite.name,
                    icon: icon,
                    iconTint: nil,
                    accessory: nil,
                    isEnabled: resolvedFavorite.isAvailable
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
                let icon = NSWorkspace.shared.icon(forFile: location.url.path)
                return SidebarItemPresentation(
                    title: location.name,
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
            viewModel.selectedItems.compactMap { item in
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

private struct SidebarSnapshot: Equatable {
    let showFavorites: Bool
    let showICloud: Bool
    let showLocations: Bool
    let showTags: Bool
    let favorites: [SidebarFavorite]
    let filterTag: String?
    let iCloudURL: URL?
    let photosLibraryInfo: PhotosLibraryInfo?
    let locations: [SidebarLocation]
}

private struct SidebarBuildContext {
    let iCloudURL: URL?
    let photosLibraryInfo: PhotosLibraryInfo?
    let locations: [SidebarLocation]
}

private struct SidebarLocation: Equatable {
    let name: String
    let url: URL
}

private struct ResolvedFavorite {
    let favorite: SidebarFavorite
    let name: String
    let url: URL?
    let isAvailable: Bool
}

private struct SystemFavoriteInfo {
    let name: String
    let url: URL?
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
        case favorite(ResolvedFavorite)
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
        case .favorite(let resolved):
            return resolved.url
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

    var sectionKind: SidebarSection.Kind? {
        switch kind {
        case .airDrop, .favorite, .photosLibrary:
            return .favorites
        case .iCloud:
            return .icloud
        case .location:
            return .locations
        case .tag, .clearTagFilter:
            return .tags
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

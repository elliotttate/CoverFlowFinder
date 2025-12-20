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

        outlineView.registerForDraggedTypes([.fileURL, context.coordinator.internalDragType])
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
            let isExternal = info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )

            guard isInternal || isExternal else { return [] }

            guard let target = dropTarget(for: info, in: favoritesSection, isInternal: isInternal) else {
                return []
            }

            switch target {
            case .between(let sectionIndex, _):
                outlineView.setDropItem(favoritesSection, dropChildIndex: sectionIndex)
                return isInternal ? .move : .copy
            case .onFavorite(let favoriteItem):
                outlineView.setDropItem(favoriteItem, dropChildIndex: NSOutlineViewDropOnItemIndex)
                if isInternal {
                    return .move
                }
                return NSEvent.modifierFlags.contains(.option) ? .copy : .move
            }
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            guard let favoritesSection = favoritesSection() else { return false }
            guard let target = dropTarget(for: info, in: favoritesSection, isInternal: isInternalDrag(info)) else {
                return false
            }

            if isInternalDrag(info) {
                let ids = draggingFavoriteIDs(from: info.draggingPasteboard)
                guard !ids.isEmpty else { return false }

                switch target {
                case .between(_, let favoritesIndex):
                    moveFavorites(ids: ids, to: favoritesIndex)
                    return true
                case .onFavorite:
                    return false
                }
            }

            guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty else {
                return false
            }

            switch target {
            case .between(_, let favoritesIndex):
                insertFavorites(urls: urls, at: favoritesIndex)
                return true
            case .onFavorite(let favoriteItem):
                guard case let .favorite(resolvedFavorite) = favoriteItem.kind,
                      let destination = resolvedFavorite.url else { return false }
                viewModel.handleDrop(urls: urls, to: destination)
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
                openAirDrop()
            case .favorite(let resolvedFavorite):
                guard resolvedFavorite.isAvailable, let url = resolvedFavorite.url else { return }
                viewModel.navigateTo(url)
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
        }

        private func isInternalDrag(_ info: NSDraggingInfo) -> Bool {
            info.draggingPasteboard.types?.contains(internalDragType) == true
        }

        private func draggingFavoriteIDs(from pasteboard: NSPasteboard) -> [String] {
            guard let items = pasteboard.pasteboardItems else { return [] }
            return items.compactMap { $0.string(forType: internalDragType) }
        }

        private func dropTarget(for info: NSDraggingInfo,
                                in favoritesSection: SidebarSection,
                                isInternal: Bool) -> DropTarget? {
            guard let outlineView = outlineView else { return nil }
            let location = outlineView.convert(info.draggingLocation, from: nil)
            let row = outlineView.row(at: location)

            let airDropOffset: Int
            if let firstItem = favoritesSection.items.first, case .airDrop = firstItem.kind {
                airDropOffset = 1
            } else {
                airDropOffset = 0
            }
            let minSectionIndex = airDropOffset
            let maxSectionIndex = favoritesSection.items.count

            if row >= 0 {
                if let section = outlineView.item(atRow: row) as? SidebarSection {
                    guard section.kind == .favorites else { return nil }
                    let sectionIndex = minSectionIndex
                    let favoritesIndex = max(0, sectionIndex - airDropOffset)
                    return .between(sectionIndex: sectionIndex, favoritesIndex: favoritesIndex)
                }

                guard let item = outlineView.item(atRow: row) as? SidebarItem else { return nil }
                guard item.sectionKind == .favorites else { return nil }

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
                let favoritesIndex = max(0, clampedSectionIndex - airDropOffset)
                return .between(sectionIndex: clampedSectionIndex, favoritesIndex: favoritesIndex)
            }

            guard favoritesSection.kind == .favorites else { return nil }

            if let firstRow = firstRowIndex(for: favoritesSection),
               let lastRow = lastRowIndex(for: favoritesSection) {
                let firstRect = outlineView.rect(ofRow: firstRow)
                let lastRect = outlineView.rect(ofRow: lastRow)

                if location.y < firstRect.minY {
                    let sectionIndex = minSectionIndex
                    let favoritesIndex = max(0, sectionIndex - airDropOffset)
                    return .between(sectionIndex: sectionIndex, favoritesIndex: favoritesIndex)
                }

                if location.y > lastRect.maxY {
                    let sectionIndex = maxSectionIndex
                    let favoritesIndex = max(0, sectionIndex - airDropOffset)
                    return .between(sectionIndex: sectionIndex, favoritesIndex: favoritesIndex)
                }
            }

            return nil
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
            let iCloudURL = FileManager.default
                .url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents")
            let locations = volumeLocations()
            return SidebarBuildContext(iCloudURL: iCloudURL, locations: locations)
        }

        private func buildSections(context: SidebarBuildContext) -> [SidebarSection] {
            var sections: [SidebarSection] = []

            if appSettings.sidebarShowFavorites {
                let section = SidebarSection(kind: .favorites, title: "Favorites")
                var items: [SidebarItem] = []
                items.append(SidebarItem(kind: .airDrop, id: "airdrop", title: "AirDrop"))

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

            let rootURL = URL(fileURLWithPath: "/")
            let rootName = Host.current().localizedName ?? "Macintosh HD"
            locations.append(SidebarLocation(name: rootName, url: rootURL))

            let volumesURL = URL(fileURLWithPath: "/Volumes")
            if let volumes = try? FileManager.default.contentsOfDirectory(
                at: volumesURL,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) {
                for volume in volumes {
                    let name = volume.lastPathComponent
                    if name != rootName {
                        locations.append(SidebarLocation(name: name, url: volume))
                    }
                }
            }

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
            NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }

        private func openAirDrop() {
            let script = """
            tell application "Finder"
                activate
                if exists window "AirDrop" then
                    set index of window "AirDrop" to 1
                else
                    make new Finder window
                    set target of Finder window 1 to (POSIX file "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
                end if
            end tell
            """

            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                if error != nil {
                    if let url = URL(string: "nwnode://domain-AirDrop") {
                        NSWorkspace.shared.open(url)
                    }
                }
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
    let locations: [SidebarLocation]
}

private struct SidebarBuildContext {
    let iCloudURL: URL?
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
        case .airDrop, .favorite:
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

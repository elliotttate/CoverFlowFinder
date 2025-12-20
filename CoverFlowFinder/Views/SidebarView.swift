import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SidebarView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    var isDualPane: Bool = false
    @State private var draggingFavorite: SidebarFavorite?
    @State private var dropIndicator: SidebarDropIndicator?
    @State private var dropTargetedFavoriteID: String?
    @State private var favoriteRowFrames: [String: CGRect] = [:]
    @State private var favoritesDropZoneFrame: CGRect = .zero
    @State private var dropJustCompleted: Bool = false
    private static let favoriteDragType = UTType(exportedAs: "com.coverflowfinder.sidebar.favorite")
    private static let dropIndicatorYOffset: CGFloat = -5

    var body: some View {
        List(selection: Binding(
            get: { viewModel.currentPath },
            set: { if let url = $0 { viewModel.navigateTo(url) } }
        )) {
            // Favorites Section
            if appSettings.sidebarShowFavorites {
                Section(header: Text("Favorites").font(.caption).foregroundColor(.secondary)) {
                    // AirDrop - special handling (opens Finder's AirDrop window)
                    Button(action: {
                        openAirDrop()
                    }) {
                        Label {
                            Text("AirDrop")
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                    .padding(.bottom, 2)

                    ForEach(Array(appSettings.sidebarFavorites.enumerated()), id: \.element.id) { index, favorite in
                        let location = resolveFavorite(favorite)
                        SidebarRow(icon: location.icon, title: location.name)
                        .tag(location.url)
                        .opacity(location.isAvailable ? 1 : 0.5)
                        .contextMenu {
                            Button("Remove from Favorites") {
                                removeFavorite(favorite)
                            }
                        }
                        .instantTap(
                            id: favorite.id,
                            onSingleClick: {
                                guard location.isAvailable else { return }
                                viewModel.navigateTo(location.url)
                            },
                            onDoubleClick: {
                                guard location.isAvailable else { return }
                                viewModel.navigateTo(location.url)
                            }
                        )
                        .listRowInsets(EdgeInsets())
                        .padding(.vertical, 4)
                        .padding(.leading, 6)
                        .padding(.trailing, 8)
                        .background {
                            if dropTargetedFavoriteID == favorite.id {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.4))
                                    .padding(.horizontal, -4)
                                    .padding(.vertical, -2)
                            }
                        }
                        .overlay(alignment: .top) {
                            if dropIndicator?.targetID == favorite.id && dropIndicator?.position == .before {
                                SidebarDropIndicatorView()
                                    .offset(y: Self.dropIndicatorYOffset)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if dropIndicator?.targetID == favorite.id && dropIndicator?.position == .after {
                                SidebarDropIndicatorView()
                                    .offset(y: -Self.dropIndicatorYOffset)
                            }
                        }
                        // Extend hit area to cover gaps between rows
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .padding(.vertical, -4)
                        .onDrag {
                            draggingFavorite = favorite
                            return favoriteItemProvider(for: favorite)
                        }
                        .onDrop(of: [Self.favoriteDragType, UTType.fileURL], delegate: FavoriteRowDropDelegate(
                            favorite: favorite,
                            index: index,
                            favorites: $appSettings.sidebarFavorites,
                            draggingFavorite: $draggingFavorite,
                            dragType: Self.favoriteDragType,
                            dropIndicator: $dropIndicator,
                            dropTargetedFavoriteID: $dropTargetedFavoriteID,
                            dropJustCompleted: $dropJustCompleted,
                            onExternalDrop: { providers, insertIndex in
                                handleFavoritesDrop(providers: providers, insertAt: insertIndex)
                            },
                            onExternalDropToFavorite: { urls, destinationURL in
                                viewModel.handleDrop(urls: urls, to: destinationURL)
                            },
                            resolveTargetURL: { fav in
                                resolvedURL(for: fav)
                            }
                        ))
                    }
                    // Drop zone at the end of the list
                    Color.clear
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if let indicator = dropIndicator, indicator.targetID == nil {
                                SidebarDropIndicatorView()
                                    .offset(y: Self.dropIndicatorYOffset)
                            }
                        }
                        .onDrop(of: [Self.favoriteDragType, UTType.fileURL], delegate: FavoriteEndDropDelegate(
                            favorites: $appSettings.sidebarFavorites,
                            draggingFavorite: $draggingFavorite,
                            dragType: Self.favoriteDragType,
                            dropIndicator: $dropIndicator,
                            dropTargetedFavoriteID: $dropTargetedFavoriteID,
                            dropJustCompleted: $dropJustCompleted,
                            onExternalDrop: { providers in
                                handleFavoritesDrop(providers: providers, insertAt: nil)
                            }
                        ))
                }
                // Section-level fallback to catch drops that fall through gaps between rows
                .onDrop(of: [Self.favoriteDragType, UTType.fileURL], delegate: FavoritesSectionFallbackDropDelegate(
                    dropIndicator: $dropIndicator,
                    dropTargetedFavoriteID: $dropTargetedFavoriteID,
                    draggingFavorite: $draggingFavorite,
                    dropJustCompleted: $dropJustCompleted,
                    onExternalDrop: { providers in
                        handleFavoritesDrop(providers: providers, insertAt: nil)
                    }
                ))
            }

            // iCloud Section
            if appSettings.sidebarShowICloud {
                Section(header: Text("iCloud").font(.caption).foregroundColor(.secondary)) {
                    if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
                        SidebarRow(icon: .system("icloud"), title: "iCloud Drive")
                            .tag(iCloudURL)
                    } else {
                        SidebarRow(icon: .system("icloud"), title: "iCloud Drive")
                            .disabled(true)
                    }
                }
            }

            // Locations Section
            if appSettings.sidebarShowLocations {
                Section(header: Text("Locations").font(.caption).foregroundColor(.secondary)) {
                    ForEach(volumeLocations, id: \.url) { location in
                        SidebarRow(icon: .system(location.icon), title: location.name)
                            .tag(location.url)
                    }
                }
            }

            // Tags Section
            if appSettings.sidebarShowTags {
                Section(header: Text("Tags").font(.caption).foregroundColor(.secondary)) {
                    ForEach(FinderTag.allTags) { tag in
                        Button(action: {
                            if viewModel.filterTag == tag.name {
                                viewModel.filterTag = nil  // Clicking active filter clears it
                            } else {
                                viewModel.filterTag = tag.name  // Set new filter
                            }
                        }) {
                            HStack {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                Text(tag.name)
                                    .lineLimit(1)
                                Spacer()
                                if viewModel.filterTag == tag.name {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    if viewModel.filterTag != nil {
                        Button(action: {
                            viewModel.filterTag = nil
                        }) {
                            Label("Clear Filter", systemImage: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
        .coordinateSpace(name: "favoritesDropZone")
        .onPreferenceChange(FavoriteRowFrameKey.self) { frames in
            favoriteRowFrames = frames
        }
        .onChange(of: appSettings.sidebarFavorites) { _ in
            clearDropIndicators()
        }
    }

    private struct ResolvedFavorite: Identifiable {
        let id: String
        let name: String
        let icon: SidebarIcon
        let url: URL
        let isAvailable: Bool
    }

    private func resolveFavorite(_ favorite: SidebarFavorite) -> ResolvedFavorite {
        switch favorite.kind {
        case .custom:
            let path = favorite.path ?? ""
            let url = path.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser
                : URL(fileURLWithPath: path)
            let name = path.isEmpty ? "Missing Folder" : url.lastPathComponent
            let icon = SidebarIcon.system("folder")
            let isAvailable = !path.isEmpty && FileManager.default.fileExists(atPath: url.path)
            return ResolvedFavorite(
                id: favorite.id,
                name: name,
                icon: icon,
                url: url,
                isAvailable: isAvailable
            )
        default:
            let info = systemFavoriteInfo(for: favorite.kind)
            let url = info?.url ?? FileManager.default.homeDirectoryForCurrentUser
            let icon = SidebarIcon.system(info?.icon ?? "folder")
            let isAvailable = info?.url != nil
            return ResolvedFavorite(
                id: favorite.id,
                name: info?.name ?? favorite.kind.rawValue.capitalized,
                icon: icon,
                url: url,
                isAvailable: isAvailable
            )
        }
    }

    private struct SystemFavoriteInfo {
        let name: String
        let icon: String
        let url: URL?
    }

    private func systemFavoriteInfo(for kind: SidebarFavorite.Kind) -> SystemFavoriteInfo? {
        let fm = FileManager.default
        switch kind {
        case .documents:
            return SystemFavoriteInfo(
                name: "Documents",
                icon: "doc",
                url: fm.urls(for: .documentDirectory, in: .userDomainMask).first
            )
        case .applications:
            return SystemFavoriteInfo(
                name: "Applications",
                icon: "square.grid.2x2",
                url: fm.urls(for: .applicationDirectory, in: .localDomainMask).first
            )
        case .desktop:
            return SystemFavoriteInfo(
                name: "Desktop",
                icon: "menubar.dock.rectangle",
                url: fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            )
        case .downloads:
            return SystemFavoriteInfo(
                name: "Downloads",
                icon: "arrow.down.circle",
                url: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            )
        case .movies:
            return SystemFavoriteInfo(
                name: "Movies",
                icon: "film",
                url: fm.urls(for: .moviesDirectory, in: .userDomainMask).first
            )
        case .music:
            return SystemFavoriteInfo(
                name: "Music",
                icon: "music.note",
                url: fm.urls(for: .musicDirectory, in: .userDomainMask).first
            )
        case .pictures:
            return SystemFavoriteInfo(
                name: "Pictures",
                icon: "photo",
                url: fm.urls(for: .picturesDirectory, in: .userDomainMask).first
            )
        case .custom:
            return nil
        }
    }

    private func handleFavoritesDrop(providers: [NSItemProvider], insertAt index: Int?) -> Bool {
        clearDropIndicators()

        // Schedule multiple cleanup passes to ensure indicators are cleared
        // even if SwiftUI sends late drop events
        for delay in [0.05, 0.1, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                clearDropIndicators()
            }
        }

        let acceptedProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !acceptedProviders.isEmpty else { return false }

        for provider in acceptedProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    self.addFavorite(from: url, insertAt: index)
                }
            }
        }
        return true
    }

    private func addFavorite(from url: URL, insertAt index: Int?) {
        // Always clear indicators when this is called, even if we don't add the favorite
        defer { clearDropIndicators() }

        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        guard !isDuplicateFavorite(standardizedURL) else { return }

        let favorite = SidebarFavorite.custom(path: standardizedURL.path)
        if let index, index < appSettings.sidebarFavorites.count {
            appSettings.sidebarFavorites.insert(favorite, at: index)
        } else {
            appSettings.sidebarFavorites.append(favorite)
        }
    }

    private func isDuplicateFavorite(_ url: URL) -> Bool {
        let targetPath = url.standardizedFileURL.path
        return appSettings.sidebarFavorites.contains { favorite in
            guard let existingURL = resolvedURL(for: favorite) else { return false }
            return existingURL.standardizedFileURL.path == targetPath
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

    private func removeFavorite(_ favorite: SidebarFavorite) {
        appSettings.sidebarFavorites.removeAll { $0.id == favorite.id }
    }

    private func favoriteItemProvider(for favorite: SidebarFavorite) -> NSItemProvider {
        let data = favorite.id.data(using: .utf8) ?? Data()
        return NSItemProvider(item: data as NSData, typeIdentifier: Self.favoriteDragType.identifier)
    }

    private func indicatorPosition(for favoriteID: String) -> SidebarDropIndicatorPosition? {
        guard let indicator = dropIndicator, indicator.targetID == favoriteID else { return nil }
        return indicator.position
    }

    private func clearDropIndicators() {
        dropIndicator = nil
        dropTargetedFavoriteID = nil
    }

    private func openAirDrop() {
        // Open Finder's AirDrop window using AppleScript
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
                // Fallback: try opening via URL scheme
                if let url = URL(string: "nwnode://domain-AirDrop") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var volumeLocations: [SidebarLocation] {
        var locations: [SidebarLocation] = []

        // Main disk
        locations.append(SidebarLocation(name: Host.current().localizedName ?? "Macintosh HD", icon: "desktopcomputer", url: URL(fileURLWithPath: "/")))

        // External volumes
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        if let volumes = try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for volume in volumes {
                let name = volume.lastPathComponent
                if name != "Macintosh HD" {
                    locations.append(SidebarLocation(name: name, icon: "externaldrive", url: volume))
                }
            }
        }

        // Network
        locations.append(SidebarLocation(name: "Network", icon: "network", url: URL(fileURLWithPath: "/Network")))

        return locations
    }
}

struct SidebarLocation {
    let name: String
    let icon: String
    let url: URL
}

struct SidebarIcon {
    let symbolName: String

    static func system(_ symbolName: String) -> SidebarIcon {
        SidebarIcon(symbolName: symbolName)
    }
}

struct SidebarRow: View {
    let icon: SidebarIcon
    let title: String

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon.symbolName)
                .foregroundColor(.primary)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct FavoriteRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

enum SidebarDropIndicatorPosition {
    case before
    case after
}

struct SidebarDropIndicator: Equatable {
    let targetID: String?
    let position: SidebarDropIndicatorPosition
}

struct SidebarDropIndicatorView: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 6)
        .padding(.trailing, 8)
    }
}

struct FavoritesSectionDropDelegate: DropDelegate {
    @Binding var favorites: [SidebarFavorite]
    @Binding var draggingFavorite: SidebarFavorite?
    let dragType: UTType
    @Binding var dropIndicator: SidebarDropIndicator?
    @Binding var dropTargetedFavoriteID: String?
    @Binding var rowFrames: [String: CGRect]
    let dropZoneFrame: CGRect
    let onExternalDrop: ([NSItemProvider], Int?) -> Bool
    let onExternalDropToFavorite: ([URL], URL) -> Void
    let resolveTargetURL: (SidebarFavorite) -> URL?
    private let insertZoneHeight: CGFloat = 8

    func validateDrop(info: DropInfo) -> Bool {
        isInternalDrag(info) || info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        _ = updateDropState(info: info, isInternal: isInternalDrag(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let isInternal = isInternalDrag(info)
        let target = updateDropState(info: info, isInternal: isInternal)

        if isInternal {
            handleInternalMove(target: target)
            return DropProposal(operation: .move)
        }

        switch target {
        case .highlight:
            let operation: DropOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
            return DropProposal(operation: operation)
        case .line:
            return DropProposal(operation: .copy)
        }
    }

    func dropExited(info: DropInfo) {
        dropIndicator = nil
        dropTargetedFavoriteID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggingFavorite = nil
            dropIndicator = nil
            dropTargetedFavoriteID = nil
        }

        if isInternalDrag(info) {
            return true
        }

        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        let target = dropTarget(for: info.location, isInternal: false)
        switch target {
        case .highlight(let favoriteID):
            guard let favorite = favorites.first(where: { $0.id == favoriteID }),
                  let destinationURL = resolveTargetURL(favorite) else {
                return false
            }
            loadFileURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                DispatchQueue.main.async {
                    onExternalDropToFavorite(urls, destinationURL)
                }
            }
            return true
        case .line(let targetID):
            let insertIndex: Int?
            if let targetID,
               let targetIndex = favorites.firstIndex(where: { $0.id == targetID }) {
                insertIndex = targetIndex
            } else {
                insertIndex = nil
            }
            return onExternalDrop(providers, insertIndex)
        }
    }

    private enum DropTarget: Equatable {
        case line(targetID: String?)
        case highlight(favoriteID: String)
    }

    private func isInternalDrag(_ info: DropInfo) -> Bool {
        guard draggingFavorite != nil else { return false }

        let providers = info.itemProviders(for: [dragType])
        let hasCustomType = providers.contains { provider in
            provider.registeredTypeIdentifiers.contains(dragType.identifier)
        }

        if hasCustomType {
            return true
        }

        return !info.hasItemsConforming(to: [UTType.fileURL])
    }

    @discardableResult
    private func updateDropState(info: DropInfo, isInternal: Bool) -> DropTarget {
        let target = dropTarget(for: info.location, isInternal: isInternal)
        applyDropTarget(target)
        return target
    }

    private func dropTarget(for location: CGPoint, isInternal: Bool) -> DropTarget {
        let orderedRows = orderedFavoritesByFrame()
        guard !orderedRows.isEmpty else {
            return .line(targetID: nil)
        }

        // Check each row to determine insertion point
        for (index, row) in orderedRows.enumerated() {
            let rowMidY = (row.frame.minY + row.frame.maxY) / 2
            
            // If we're above the midpoint of this row, insert before it
            if location.y < rowMidY {
                return .line(targetID: row.favorite.id)
            }
            
            // If we're within this row's bounds
            if location.y <= row.frame.maxY {
                // For external drops to folders, check if we should highlight (drop into) the folder
                if !isInternal && canDropIntoFavorite(row.favorite) {
                    // If we're in the top insert zone, insert before
                    if location.y - row.frame.minY <= insertZoneHeight {
                        return .line(targetID: row.favorite.id)
                    }
                    // Otherwise, highlight for dropping into the folder
                    return .highlight(favoriteID: row.favorite.id)
                }
                
                // For internal drags or non-folder items, check if we should insert after
                if index < orderedRows.count - 1 {
                    // Insert after this row (which is before the next row)
                    return .line(targetID: orderedRows[index + 1].favorite.id)
                } else {
                    // This is the last row, insert at the end
                    return .line(targetID: nil)
                }
            }
        }

        // If we're below all rows, insert at the end
        return .line(targetID: nil)
    }

    private func applyDropTarget(_ target: DropTarget) {
        switch target {
        case .line(let targetID):
            if dropTargetedFavoriteID != nil {
                dropTargetedFavoriteID = nil
            }
            let position: SidebarDropIndicatorPosition = targetID == nil ? .after : .before
            let indicator = SidebarDropIndicator(targetID: targetID, position: position)
            if dropIndicator != indicator {
                dropIndicator = indicator
            }
        case .highlight(let favoriteID):
            if dropIndicator != nil {
                dropIndicator = nil
            }
            if dropTargetedFavoriteID != favoriteID {
                dropTargetedFavoriteID = favoriteID
            }
        }
    }

    private func orderedFavoritesByFrame() -> [(favorite: SidebarFavorite, frame: CGRect)] {
        let rows = favorites.compactMap { favorite -> (favorite: SidebarFavorite, frame: CGRect)? in
            guard let frame = rowFrames[favorite.id] else { return nil }
            return (favorite: favorite, frame: frame)
        }
        return rows.sorted(by: { $0.frame.minY < $1.frame.minY })
    }

    private func canDropIntoFavorite(_ favorite: SidebarFavorite) -> Bool {
        resolveTargetURL(favorite) != nil
    }

    private func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }

    private func handleInternalMove(target: DropTarget) {
        guard let dragging = draggingFavorite,
              let fromIndex = favorites.firstIndex(of: dragging) else { return }

        let targetIndex: Int
        switch target {
        case .line(let targetID):
            if let targetID, let index = favorites.firstIndex(where: { $0.id == targetID }) {
                targetIndex = index
            } else {
                targetIndex = favorites.endIndex
            }
        case .highlight(let favoriteID):
            if let index = favorites.firstIndex(where: { $0.id == favoriteID }) {
                targetIndex = index
            } else {
                targetIndex = favorites.endIndex
            }
        }

        var destination = targetIndex
        if fromIndex < destination {
            destination -= 1
        }
        guard destination != fromIndex else { return }

        withAnimation(.easeInOut(duration: 0.08)) {
            favorites.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: destination)
        }
    }
}

// MARK: - Per-Row Drop Delegate
struct FavoriteRowDropDelegate: DropDelegate {
    let favorite: SidebarFavorite
    let index: Int
    @Binding var favorites: [SidebarFavorite]
    @Binding var draggingFavorite: SidebarFavorite?
    let dragType: UTType
    @Binding var dropIndicator: SidebarDropIndicator?
    @Binding var dropTargetedFavoriteID: String?
    @Binding var dropJustCompleted: Bool
    let onExternalDrop: ([NSItemProvider], Int?) -> Bool
    let onExternalDropToFavorite: ([URL], URL) -> Void
    let resolveTargetURL: (SidebarFavorite) -> URL?

    func validateDrop(info: DropInfo) -> Bool {
        let isInternal = isInternalDrag(info)
        let hasFileURL = info.hasItemsConforming(to: [UTType.fileURL])
        return isInternal || hasFileURL
    }

    func dropEntered(info: DropInfo) {
        guard !dropJustCompleted else { return }
        updateDropState(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard !dropJustCompleted else { return nil }
        updateDropState(info: info)

        if isInternalDrag(info) {
            return DropProposal(operation: .move)
        }

        // If hovering in upper half, show insert line; otherwise highlight for drop into folder
        if isUpperHalf(info.location) {
            return DropProposal(operation: .copy)
        } else if canDropIntoFavorite() {
            let operation: DropOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
            return DropProposal(operation: operation)
        } else {
            return DropProposal(operation: .copy)
        }
    }

    func dropExited(info: DropInfo) {
        // Don't clear indicators here - let the section fallback delegate handle it
        // This prevents the "dead zone" issue where indicators disappear between rows
    }

    func performDrop(info: DropInfo) -> Bool {
        dropJustCompleted = true
        defer {
            draggingFavorite = nil
            dropIndicator = nil
            dropTargetedFavoriteID = nil
            // Schedule multiple cleanup passes to ensure indicators are cleared
            // even if SwiftUI sends late drop events
            for delay in [0.05, 0.1, 0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    dropIndicator = nil
                    dropTargetedFavoriteID = nil
                }
            }
            // Reset the flag after cleanup passes complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dropJustCompleted = false
            }
        }

        let isInternal = isInternalDrag(info)

        if isInternal {
            // Handle internal reordering
            guard let dragging = draggingFavorite,
                  let fromIndex = favorites.firstIndex(of: dragging) else { return false }

            var targetIndex = index
            if isUpperHalf(info.location) {
                // Insert before this row
            } else {
                // Insert after this row
                targetIndex = index + 1
            }

            if fromIndex < targetIndex {
                targetIndex -= 1
            }
            guard targetIndex != fromIndex else { return true }

            withAnimation(.easeInOut(duration: 0.08)) {
                favorites.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: targetIndex)
            }
            return true
        }

        // External drop
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        let inUpperHalf = isUpperHalf(info.location)
        let canDropInto = canDropIntoFavorite()

        if inUpperHalf {
            // Insert as new favorite before this row
            return onExternalDrop(providers, index)
        } else if canDropInto, let destinationURL = resolveTargetURL(favorite) {
            // Drop into this favorite's folder
            loadFileURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                DispatchQueue.main.async {
                    self.onExternalDropToFavorite(urls, destinationURL)
                }
            }
            return true
        } else {
            // Insert as new favorite after this row
            return onExternalDrop(providers, index + 1)
        }
    }

    private func isInternalDrag(_ info: DropInfo) -> Bool {
        guard draggingFavorite != nil else { return false }
        let providers = info.itemProviders(for: [dragType])
        return providers.contains { $0.registeredTypeIdentifiers.contains(dragType.identifier) }
            || !info.hasItemsConforming(to: [UTType.fileURL])
    }

    private func isUpperHalf(_ location: CGPoint) -> Bool {
        // Very small insert zone at top of row (6px), rest of row triggers folder highlight
        location.y < 6
    }

    private func updateDropState(info: DropInfo) {
        let isInternal = isInternalDrag(info)

        if isUpperHalf(info.location) {
            // Show insert line above this row
            dropTargetedFavoriteID = nil
            dropIndicator = SidebarDropIndicator(targetID: favorite.id, position: .before)
        } else if !isInternal && canDropIntoFavorite() {
            // Highlight this row for dropping into it
            dropIndicator = nil
            dropTargetedFavoriteID = favorite.id
        } else {
            // Show insert line below this row
            dropTargetedFavoriteID = nil
            dropIndicator = SidebarDropIndicator(targetID: favorite.id, position: .after)
        }
    }

    private func canDropIntoFavorite() -> Bool {
        resolveTargetURL(favorite) != nil
    }

    private func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }
}

// MARK: - Section Fallback Drop Delegate (catches drops that fall through gaps)
struct FavoritesSectionFallbackDropDelegate: DropDelegate {
    @Binding var dropIndicator: SidebarDropIndicator?
    @Binding var dropTargetedFavoriteID: String?
    @Binding var draggingFavorite: SidebarFavorite?
    @Binding var dropJustCompleted: Bool
    let onExternalDrop: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Return nil to let child delegates take priority
        nil
    }

    func dropExited(info: DropInfo) {
        guard !dropJustCompleted else { return }
        dropIndicator = nil
        dropTargetedFavoriteID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        dropJustCompleted = true
        defer {
            dropIndicator = nil
            dropTargetedFavoriteID = nil
            draggingFavorite = nil
            // Schedule cleanup
            for delay in [0.05, 0.1, 0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    dropIndicator = nil
                    dropTargetedFavoriteID = nil
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dropJustCompleted = false
            }
        }

        // Handle the drop - add at the end of favorites
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        return onExternalDrop(providers)
    }
}

// MARK: - End of List Drop Delegate
struct FavoriteEndDropDelegate: DropDelegate {
    @Binding var favorites: [SidebarFavorite]
    @Binding var draggingFavorite: SidebarFavorite?
    let dragType: UTType
    @Binding var dropIndicator: SidebarDropIndicator?
    @Binding var dropTargetedFavoriteID: String?
    @Binding var dropJustCompleted: Bool
    let onExternalDrop: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        isInternalDrag(info) || info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard !dropJustCompleted else { return }
        dropTargetedFavoriteID = nil
        dropIndicator = SidebarDropIndicator(targetID: nil, position: .after)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard !dropJustCompleted else { return nil }
        dropTargetedFavoriteID = nil
        dropIndicator = SidebarDropIndicator(targetID: nil, position: .after)
        return DropProposal(operation: isInternalDrag(info) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        // Don't clear indicators here - let the section fallback delegate handle it
    }

    func performDrop(info: DropInfo) -> Bool {
        dropJustCompleted = true
        defer {
            draggingFavorite = nil
            dropIndicator = nil
            dropTargetedFavoriteID = nil
            // Schedule multiple cleanup passes to ensure indicators are cleared
            for delay in [0.05, 0.1, 0.2, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    dropIndicator = nil
                    dropTargetedFavoriteID = nil
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dropJustCompleted = false
            }
        }

        if isInternalDrag(info) {
            guard let dragging = draggingFavorite,
                  let fromIndex = favorites.firstIndex(of: dragging) else { return false }

            let targetIndex = favorites.count - 1
            guard targetIndex != fromIndex else { return true }

            withAnimation(.easeInOut(duration: 0.08)) {
                favorites.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: favorites.count)
            }
            return true
        }

        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        return onExternalDrop(providers)
    }

    private func isInternalDrag(_ info: DropInfo) -> Bool {
        guard draggingFavorite != nil else { return false }
        let providers = info.itemProviders(for: [dragType])
        return providers.contains { $0.registeredTypeIdentifiers.contains(dragType.identifier) }
            || !info.hasItemsConforming(to: [UTType.fileURL])
    }
}

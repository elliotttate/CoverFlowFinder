import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import Photos
import os
import CoreServices

private let zipNavLogger = Logger(subsystem: "com.flowfinder.app", category: "ZipNav")
private let sortLogger = Logger(subsystem: "com.flowfinder.app", category: "Sorting")

// Notification names are defined in UIConstants.swift

enum ViewMode: String, CaseIterable {
    case coverFlow = "Cover Flow"
    case icons = "Icons"
    case masonry = "Masonry"
    case list = "List"
    case columns = "Columns"
    case dualPane = "Dual Pane"
    case quadPane = "Quad Pane"

    var systemImage: String {
        switch self {
        case .coverFlow: return "square.stack.3d.forward.dottedline"
        case .icons: return "square.grid.2x2"
        case .masonry: return "square.grid.3x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .dualPane: return "rectangle.split.2x1"
        case .quadPane: return "rectangle.grid.2x2"
        }
    }
}

struct PhotosLibraryInfo: Equatable {
    let libraryURL: URL
    let imagesURL: URL
}

enum NavigationLocation: Equatable {
    case filesystem(URL)
    case archive(archiveURL: URL, internalPath: String)
    case photosLibrary(PhotosLibraryInfo)
}

enum ClipboardOperation {
    case copy
    case cut
}

// Custom pasteboard type to track cut operations
private let cutOperationPasteboardType = NSPasteboard.PasteboardType("com.coverflowfinder.cut-operation")

/// Thread-safe sort function for background use (non-isolated)
private func sortItemsForBackground(_ items: [FileItem], sortState: SortState, foldersFirst: Bool) -> [FileItem] {
    ListColumnConfigManager.sortedItems(items, sortState: sortState, foldersFirst: foldersFirst)
}

@MainActor
class FileBrowserViewModel: ObservableObject {
    @Published var currentPath: URL
    @Published var items: [FileItem] = [] {
        didSet {
            itemsRevision &+= 1
            filteredItemsCacheKey = nil
        }
    }
    @Published var selectedItems: Set<FileItem> = []
    @Published var viewMode: ViewMode = .coverFlow
    @Published var searchText: String = ""
    @Published var filterTag: String? = nil
    @Published var isLoading: Bool = false
    @Published var navigationHistory: [NavigationLocation] = []
    @Published var historyIndex: Int = -1
    @Published var coverFlowSelectedIndex: Int = 0
    @Published var renamingURL: URL? = nil
    // Navigation generation counter - forces SwiftUI to update on navigation
    @Published var navigationGeneration: Int = 0
    @Published var tagRefreshToken: Int = 0

    // Track click timing for Finder-style rename triggering
    private var lastClickedURL: URL?
    private var lastClickTime: Date = .distantPast
    private var pendingRenameWorkItem: DispatchWorkItem?
    private let renameDelay: TimeInterval = 0.2

    // Track the folder we entered so we can select it when going back
    private var enteredFolderURL: URL?
    // URL to select after loading (used when going back)
    private var pendingSelectionURL: URL?

    private let fileOperationQueue = DispatchQueue(label: "com.coverflowfinder.fileops", qos: .userInitiated)

    // Clipboard state
    @Published var clipboardItems: [URL] = []
    @Published var clipboardOperation: ClipboardOperation = .copy

    /// Check if a file is marked for cut (should appear dimmed)
    func isItemCut(_ item: FileItem) -> Bool {
        clipboardOperation == .cut && clipboardItems.contains(item.url)
    }

    @Published var infoItem: FileItem?
    private var itemsRevision: Int = 0
    private struct FilteredItemsCacheKey: Equatable {
        let itemsRevision: Int
        let searchText: String
        let filterTag: String?
        let sortState: SortState
        let foldersFirst: Bool
    }
    private var filteredItemsCacheKey: FilteredItemsCacheKey?
    private var filteredItemsCache: [FileItem] = []

    private var photosLibraryInfo: PhotosLibraryInfo?
    private let photosImageManager = PHCachingImageManager()
    private var photosAssetCache: [String: PHAsset] = [:]
    private var photosAspectRatioCache: [String: CGFloat] = [:]
    private var photosThumbnailRequests: [String: PHImageRequestID] = [:]
    private var photosExportCache: [String: URL] = [:]
    private var isRequestingPhotosAccess = false
    private var pendingPhotosAccessCompletions: [(PHAuthorizationStatus) -> Void] = []
    private var didForcePhotosAuthRefresh = false
    private let photosLogger = Logger(subsystem: "com.coverflowfinder.app", category: "Photos")
    private var photosLoadToken = UUID()
    private var photosSortState: SortState?

    private var networkServiceBrowser: NetworkServiceBrowser?
    private var networkServiceIDs: [String: UUID] = [:]
    private var isNetworkBrowsing = false
    private var smbSubnetScanner: SMBSubnetScanner?
    private var discoveredSMBHosts: [SMBHostInfo] = []
    private var smbScanComplete = false

    // MARK: - Lazy Metadata Loading
    /// Batch size for progressive loading of large directories
    private let directoryBatchSize = 400
    /// Token to invalidate in-flight loads when navigating away
    private var directoryLoadToken = UUID()
    /// Track which items have had their metadata loaded
    private var hydratedURLs: Set<URL> = []
    /// Flag to prevent redundant reloads during navigation
    private var isNavigating = false
    /// Queue for metadata hydration requests
    private var pendingHydrationURLs: Set<URL> = []
    private let hydrationQueue = DispatchQueue(label: "com.coverflowfinder.hydration", qos: .userInitiated)
    private var directoryWatcher: DirectoryWatcher?
    private var watchingDirectoryURL: URL?
    private var pendingDirectoryEventURLs: Set<URL> = []
    private var directoryEventWorkItem: DispatchWorkItem?
    private let directoryEventDebounce: TimeInterval = 0.25
    struct PhotoAssetDragInfo {
        let filename: String
        let uti: String
    }

    // MARK: - ZIP Archive Browsing State
    @Published var isInsideArchive: Bool = false
    @Published var currentArchiveURL: URL? = nil
    @Published var currentArchivePath: String = ""
    private var archiveEntries: [ZipEntry] = []

    /// Get a display path for the path bar (shows archive path when inside ZIP)
    var displayPath: URL {
        if isInsideArchive, let archiveURL = currentArchiveURL {
            // Create a virtual URL for display
            let archiveName = archiveURL.lastPathComponent
            let virtualPath = currentArchivePath.isEmpty ? archiveName : "\(archiveName)/\(currentArchivePath)"
            return archiveURL.deletingLastPathComponent().appendingPathComponent(virtualPath)
        }
        return currentPath
    }

    /// Path components for breadcrumb navigation (handles both regular paths and archive paths)
    var pathComponents: [(name: String, url: URL?, archivePath: String?)] {
        var components: [(name: String, url: URL?, archivePath: String?)] = []

        // Add regular filesystem path components up to the archive
        let basePath = isInsideArchive ? (currentArchiveURL?.deletingLastPathComponent() ?? currentPath) : currentPath
        var url = basePath
        var pathComps: [(name: String, url: URL)] = []

        while url.path != "/" {
            pathComps.insert((name: url.lastPathComponent, url: url), at: 0)
            url = url.deletingLastPathComponent()
        }
        let rootName = FileManager.default.displayName(atPath: "/")
        pathComps.insert((name: rootName, url: URL(fileURLWithPath: "/")), at: 0)

        for comp in pathComps {
            components.append((name: comp.name, url: comp.url, archivePath: nil))
        }

        // If inside archive, add archive and its internal path components
        if isInsideArchive, let archiveURL = currentArchiveURL {
            // Add the archive itself (clicking navigates to archive root)
            components.append((name: archiveURL.lastPathComponent, url: nil, archivePath: ""))

            // Add internal path components
            if !currentArchivePath.isEmpty {
                let internalComps = currentArchivePath.split(separator: "/")
                var builtPath = ""
                for comp in internalComps {
                    builtPath = builtPath.isEmpty ? String(comp) : "\(builtPath)/\(comp)"
                    components.append((name: String(comp), url: nil, archivePath: builtPath))
                }
            }
        }

        return components
    }

    private var cancellables = Set<AnyCancellable>()

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    var filteredItems: [FileItem] {
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let foldersFirst = AppSettings.shared.foldersFirst
        let cacheKey = FilteredItemsCacheKey(
            itemsRevision: itemsRevision,
            searchText: searchText,
            filterTag: filterTag,
            sortState: sortState,
            foldersFirst: foldersFirst
        )

        if let cachedKey = filteredItemsCacheKey, cachedKey == cacheKey {
            return filteredItemsCache
        }

        if photosLibraryInfo != nil,
           searchText.isEmpty,
           filterTag == nil {
            if sortState.column == .dateCreated || sortState.column == .dateModified {
                if photosSortState == sortState {
                    return items
                }
            } else {
                return items
            }
        }

        var filtered = items

        // Filter by search text
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Filter by tag - skip for archive items since they have no tags
        if let tag = filterTag, !isInsideArchive {
            filtered = filtered.filter { item in
                item.tags.contains(tag)
            }
        }

        let sorted = sortItemsForBackground(filtered, sortState: sortState, foldersFirst: foldersFirst)
        filteredItemsCacheKey = cacheKey
        filteredItemsCache = sorted
        return sorted
    }

    var isPhotosLibraryActive: Bool {
        photosLibraryInfo != nil
    }

    init(initialPath: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentPath = initialPath
        loadContents()
        addToHistory(.filesystem(initialPath))

        $searchText
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        $filterTag
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                self?.navigationGeneration += 1
            }
            .store(in: &cancellables)

        let columnConfig = ListColumnConfigManager.shared
        columnConfig.$sortColumn
            .dropFirst() // Skip initial value
            .sink { [weak self] newColumn in
                guard let self else { return }
                self.objectWillChange.send()

                // Skip reload during navigation - loadContents will be called with correct sort state
                guard !self.isNavigating else { return }

                // If the new sort column requires metadata (date/size) and items don't have it,
                // we need to reload the directory to get proper sorting
                let sortRequiresMetadata = self.sortStateRequiresMetadata(SortState(column: newColumn, direction: .descending))
                if sortRequiresMetadata && !self.items.isEmpty {
                    // Check if items have metadata by looking at hydratedURLs
                    // If fewer items are hydrated than total items, we need to reload
                    let itemsNeedMetadata = self.hydratedURLs.count < self.items.count
                    if itemsNeedMetadata {
                        self.loadContents()
                    }
                }
            }
            .store(in: &cancellables)

        columnConfig.$sortDirection
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        AppSettings.shared.$masonryShowFilenames
            .removeDuplicates()
            .sink { [weak self] showFilenames in
                guard let self else { return }
                guard showFilenames, self.photosLibraryInfo != nil else { return }
                self.loadContents()
            }
            .store(in: &cancellables)
    }

    func loadContents() {
        // If we're inside an archive, load archive contents instead
        if isInsideArchive {
            stopDirectoryWatcher()
            loadArchiveContents()
            return
        }
        if let photosLibraryInfo {
            photosLogger.info("loadContents routing to Photos library for path: \(self.currentPath.path, privacy: .public)")
            stopDirectoryWatcher()
            loadPhotosLibraryContents(info: photosLibraryInfo)
            return
        }
        if currentPath.path == "/Network" {
            stopDirectoryWatcher()
            loadNetworkContents()
            return
        }
        stopNetworkBrowsing()
        isLoading = true
        items = []
        hydratedURLs.removeAll()
        pendingHydrationURLs.removeAll()
        let pathToLoad = currentPath
        let listingURL = resolvedListingURL(for: pathToLoad)
        startDirectoryWatcher(for: listingURL)
        let pendingURL = pendingSelectionURL  // Capture before async
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let foldersFirst = AppSettings.shared.foldersFirst
        let batchSize = directoryBatchSize
        let loadToken = UUID()
        directoryLoadToken = loadToken

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Special handling for autofs mount points like /Network
                // These require triggering the automounter before listing
                let isAutofsMountPoint = listingURL.path == "/Network" ||
                    listingURL.path.hasPrefix("/Network/")

                if isAutofsMountPoint {
                    // Trigger automounter by attempting to access the path
                    // This may take a moment for network discovery
                    _ = FileManager.default.fileExists(atPath: listingURL.path)
                    // Give automounter a moment to populate
                    Thread.sleep(forTimeInterval: 0.5)
                }

                // Phase 1: Get file list instantly (no stat calls)
                let contents: [URL] = try autoreleasepool {
                    try FileManager.default.contentsOfDirectory(
                        at: listingURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
                        options: showHiddenFiles ? [] : [.skipsHiddenFiles]
                    )
                }

                let totalCount = contents.count
                let isLargeDirectory = totalCount > batchSize

                // Phase 2: Create items with or without metadata
                // For small directories, load metadata upfront for better UX
                // For large directories, check if sorting requires metadata (date/size columns)
                // If sorting by date or size, we MUST load metadata to sort correctly
                let sortRequiresMetadata = self.sortStateRequiresMetadata(sortState)
                let loadMetadataUpfront = !isLargeDirectory || sortRequiresMetadata

                var allItems = [FileItem]()
                allItems.reserveCapacity(totalCount)

                // First batch - create items and show immediately
                let firstBatchCount = min(batchSize, totalCount)
                for i in 0..<firstBatchCount {
                    allItems.append(FileItem(url: contents[i], loadMetadata: loadMetadataUpfront))
                }

                // Calculate selection for first batch
                var selectedIndex = 0
                var selectedItem: FileItem?
                if let pendingURL = pendingURL,
                   let item = allItems.first(where: { $0.url == pendingURL }) {
                    selectedItem = item
                    let sorted = sortItemsForBackground(allItems, sortState: sortState, foldersFirst: foldersFirst)
                    if let index = sorted.firstIndex(of: item) {
                        selectedIndex = index
                    }
                }

                // Show first batch immediately (unless large directory - we'll show all at once to prevent jumping)
                if !isLargeDirectory {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self,
                              self.directoryLoadToken == loadToken,
                              !self.isInsideArchive,
                              self.currentPath == pathToLoad else { return }

                        if let item = selectedItem {
                            self.coverFlowSelectedIndex = selectedIndex
                            self.selectedItems = [item]
                            self.pendingSelectionURL = nil
                        } else {
                            self.coverFlowSelectedIndex = min(self.coverFlowSelectedIndex, max(0, allItems.count - 1))
                        }

                        self.items = allItems
                        if !isLargeDirectory {
                            self.isLoading = false
                        }
                        self.navigationGeneration += 1

                        if loadMetadataUpfront {
                            for item in allItems {
                                self.hydratedURLs.insert(item.url)
                            }
                        }
                    }
                }

                // Phase 3: Load remaining batches for large directories
                // Always collect ALL items before displaying to prevent visual jumping
                // as items get re-sorted after each batch append
                if isLargeDirectory {
                    // Collect remaining items without updating UI until complete
                    for batchStart in stride(from: batchSize, to: totalCount, by: batchSize) {
                        guard DispatchQueue.main.sync(execute: { self.directoryLoadToken == loadToken }) else { return }

                        let batchEnd = min(batchStart + batchSize, totalCount)
                        for i in batchStart..<batchEnd {
                            allItems.append(FileItem(url: contents[i], loadMetadata: loadMetadataUpfront))
                        }
                    }

                    // Now update UI with complete list
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self,
                              self.directoryLoadToken == loadToken,
                              !self.isInsideArchive,
                              self.currentPath == pathToLoad else { return }

                        // Handle selection
                        if let pendingURL = pendingURL,
                           let item = allItems.first(where: { $0.url == pendingURL }) {
                            let sorted = sortItemsForBackground(allItems, sortState: sortState, foldersFirst: foldersFirst)
                            if let index = sorted.firstIndex(of: item) {
                                self.coverFlowSelectedIndex = index
                            }
                            self.selectedItems = [item]
                            self.pendingSelectionURL = nil
                        } else {
                            self.coverFlowSelectedIndex = min(self.coverFlowSelectedIndex, max(0, allItems.count - 1))
                        }

                        self.items = allItems
                        self.isLoading = false
                        self.navigationGeneration += 1

                        // Track hydrated items
                        if loadMetadataUpfront {
                            for item in allItems {
                                self.hydratedURLs.insert(item.url)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.items = []
                    self.isLoading = false
                }
            }
        }
    }

    private func loadNetworkContents() {
        stopNetworkBrowsing()
        isNetworkBrowsing = true
        isLoading = true
        items = []
        hydratedURLs.removeAll()
        pendingHydrationURLs.removeAll()
        navigationGeneration += 1
        discoveredSMBHosts = []
        smbScanComplete = false

        // Start Bonjour discovery (finds Macs and other Bonjour-advertising devices)
        if networkServiceBrowser == nil {
            networkServiceBrowser = NetworkServiceBrowser(delegate: self)
        }
        networkServiceBrowser?.start()

        // Start SMB subnet scan (finds Windows PCs and other SMB servers)
        if smbSubnetScanner == nil {
            smbSubnetScanner = SMBSubnetScanner(delegate: self)
        }
        smbSubnetScanner?.start()

        // Show initial results after short delay (Bonjour results usually come fast)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard self.isNetworkBrowsing, self.currentPath.path == "/Network" else { return }
            if self.isLoading {
                self.isLoading = false
            }
        }
    }

    private func stopNetworkBrowsing() {
        guard isNetworkBrowsing else { return }
        isNetworkBrowsing = false
        networkServiceBrowser?.stop()
        smbSubnetScanner?.stop()
        networkServiceIDs.removeAll()
        discoveredSMBHosts.removeAll()
        lastBonjourServices.removeAll()
    }

    private var lastBonjourServices: [NetworkServiceInfo] = []

    private func updateNetworkItems(from services: [NetworkServiceInfo], isFinal: Bool) {
        guard isNetworkBrowsing, currentPath.path == "/Network" else { return }
        lastBonjourServices = services
        rebuildNetworkItems()
        if isLoading && (isFinal || !items.isEmpty) {
            isLoading = false
        }
    }

    private func rebuildNetworkItems() {
        guard isNetworkBrowsing, currentPath.path == "/Network" else { return }

        // Collect hosts from Bonjour services
        var hostsByKey: [String: (name: String, scheme: String, host: String, port: Int, priority: Int)] = [:]

        for info in lastBonjourServices {
            guard let host = normalizedHostName(info.hostName) else { continue }
            let hostKey = host.lowercased()
            if let existing = hostsByKey[hostKey], existing.priority >= info.priority {
                continue
            }
            hostsByKey[hostKey] = (
                name: info.name,
                scheme: info.scheme,
                host: host,
                port: info.port,
                priority: info.priority
            )
        }

        // Add SMB hosts discovered via subnet scan (only if not already found via Bonjour)
        for smbHost in discoveredSMBHosts {
            // Use IP address or resolved hostname as key
            let hostKey = smbHost.ipAddress.lowercased()
            let nameKey = smbHost.name.lowercased()

            // Skip if we already have this host from Bonjour (by IP or name)
            let existingKeys = hostsByKey.keys
            let alreadyExists = existingKeys.contains(hostKey) ||
                                existingKeys.contains(nameKey) ||
                                existingKeys.contains(where: { $0.contains(nameKey) || nameKey.contains($0) })

            if !alreadyExists {
                // SMB scan results have lower priority than Bonjour (priority -1)
                hostsByKey[hostKey] = (
                    name: smbHost.name,
                    scheme: "smb",
                    host: smbHost.ipAddress,
                    port: smbHost.port,
                    priority: -1
                )
            }
        }

        // Sort by name
        let sortedHosts = hostsByKey.sorted { lhs, rhs in
            lhs.value.name.localizedCaseInsensitiveCompare(rhs.value.name) == .orderedAscending
        }

        // Build FileItems
        var nextItems: [FileItem] = []
        nextItems.reserveCapacity(sortedHosts.count)

        for (hostKey, info) in sortedHosts {
            var components = URLComponents()
            components.scheme = info.scheme
            components.host = info.host

            // Add port if non-standard
            let defaultPort: Int? = info.scheme == "smb" ? 445 : (info.scheme == "afp" ? 548 : nil)
            if info.port > 0, let defaultPort, info.port != defaultPort {
                components.port = info.port
            }

            guard let url = components.url else { continue }

            let id = networkServiceIDs[hostKey] ?? UUID()
            networkServiceIDs[hostKey] = id

            let item = FileItem(
                id: id,
                url: url,
                name: info.name,
                isDirectory: true,
                size: 0,
                modificationDate: nil,
                creationDate: nil,
                contentType: nil
            )
            nextItems.append(item)
        }

        items = nextItems
    }

    private func normalizedHostName(_ hostName: String?) -> String? {
        guard let hostName, !hostName.isEmpty else { return nil }
        if hostName.hasSuffix(".") {
            return String(hostName.dropLast())
        }
        return hostName
    }

    private func networkServiceURL(for info: NetworkServiceInfo) -> URL? {
        guard let hostName = normalizedHostName(info.hostName) else { return nil }

        var components = URLComponents()
        components.scheme = info.scheme
        components.host = hostName

        let defaultPort: Int?
        switch info.scheme {
        case "smb":
            defaultPort = 445
        case "afp":
            defaultPort = 548
        default:
            defaultPort = nil
        }

        if info.port > 0, let defaultPort, info.port != defaultPort {
            components.port = info.port
        }

        return components.url
    }

    private func resolvedListingURL(for url: URL) -> URL {
        if url.path == "/Network" {
            let serversURL = URL(fileURLWithPath: "/Network/Servers")
            if FileManager.default.fileExists(atPath: serversURL.path) {
                return serversURL
            }
        }
        return url
    }

    // MARK: - Lazy Metadata Hydration

    /// Request metadata loading for specific items (call from visible row detection)
    func hydrateMetadata(for urls: [URL]) {
        let urlsToHydrate = urls.filter { !hydratedURLs.contains($0) && !pendingHydrationURLs.contains($0) }
        guard !urlsToHydrate.isEmpty else { return }

        for url in urlsToHydrate {
            pendingHydrationURLs.insert(url)
        }

        let idByURL = Dictionary(uniqueKeysWithValues: items.map { ($0.url, $0.id) })
        let loadToken = directoryLoadToken
        hydrationQueue.async { [weak self] in
            guard let self = self else { return }

            var hydratedItems: [(url: URL, item: FileItem)] = []

            for url in urlsToHydrate {
                // Check if still valid
                guard DispatchQueue.main.sync(execute: { self.directoryLoadToken == loadToken }) else { return }

                // Load full metadata
                let existingID = idByURL[url]
                let hydratedItem = FileItem(url: url, id: existingID ?? UUID(), loadMetadata: true)
                hydratedItems.append((url: url, item: hydratedItem))
            }

            // Batch update on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.directoryLoadToken == loadToken else { return }

                var updatedItems = self.items
                let indicesByURL = Dictionary(uniqueKeysWithValues: updatedItems.enumerated().map { ($0.element.url, $0.offset) })
                var didUpdate = false

                for (url, hydratedItem) in hydratedItems {
                    self.pendingHydrationURLs.remove(url)
                    self.hydratedURLs.insert(url)

                    // Replace item in-place
                    if let index = indicesByURL[url] {
                        updatedItems[index] = hydratedItem
                        didUpdate = true
                    }
                }

                if didUpdate {
                    self.items = updatedItems
                    // Post notification so table view can force reload of visible rows
                    NotificationCenter.default.post(name: .metadataHydrationCompleted, object: nil)
                }
            }
        }
    }

    /// Check if an item needs metadata hydration
    func needsHydration(_ item: FileItem) -> Bool {
        !item.hasMetadata && !hydratedURLs.contains(item.url)
    }

    // MARK: - Directory Watching

    private func startDirectoryWatcher(for url: URL) {
        if watchingDirectoryURL == url, directoryWatcher != nil { return }
        if directoryWatcher == nil {
            directoryWatcher = DirectoryWatcher { [weak self] urls in
                guard let self else { return }
                Task { @MainActor in
                    self.queueDirectoryEvents(urls)
                }
            }
        }
        watchingDirectoryURL = url
        directoryWatcher?.start(watching: url)
    }

    private func stopDirectoryWatcher() {
        watchingDirectoryURL = nil
        directoryEventWorkItem?.cancel()
        directoryEventWorkItem = nil
        pendingDirectoryEventURLs.removeAll()
        directoryWatcher?.stop()
    }

    private func queueDirectoryEvents(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !isInsideArchive, photosLibraryInfo == nil else { return }
        guard let watchURL = watchingDirectoryURL else { return }
        let isNetworkRootListing = currentPath.path == "/Network" && watchURL.path == "/Network/Servers"
        guard watchURL == currentPath || isNetworkRootListing else { return }

        let filtered = urls.filter { url in
            url.deletingLastPathComponent() == watchURL || url == watchURL
        }
        guard !filtered.isEmpty else { return }

        pendingDirectoryEventURLs.formUnion(filtered)
        directoryEventWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.processDirectoryEvents()
        }
        directoryEventWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + directoryEventDebounce, execute: workItem)
    }

    private func processDirectoryEvents() {
        if isLoading {
            let workItem = DispatchWorkItem { [weak self] in
                self?.processDirectoryEvents()
            }
            directoryEventWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + directoryEventDebounce, execute: workItem)
            return
        }
        let urls = pendingDirectoryEventURLs
        pendingDirectoryEventURLs.removeAll()
        applyDirectoryEventUpdates(for: urls)
    }

    private func applyDirectoryEventUpdates(for urls: Set<URL>) {
        guard let watchURL = watchingDirectoryURL, watchURL == currentPath else { return }
        guard !urls.isEmpty else { return }

        let showHidden = AppSettings.shared.showHiddenFiles
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let shouldLoadMetadata = items.count <= directoryBatchSize || sortStateRequiresMetadata(sortState)

        var updatedItems = items
        var updatedSelection = selectedItems
        var indicesByURL = Dictionary(uniqueKeysWithValues: updatedItems.enumerated().map { ($0.element.url, $0.offset) })
        var indicesToRemove: [Int] = []
        var urlsToUpdate: [URL] = []
        var urlsToAdd: [URL] = []

        for url in urls {
            if url == watchURL { continue }
            guard url.deletingLastPathComponent() == watchURL else { continue }

            if !showHidden, url.lastPathComponent.hasPrefix(".") {
                if let idx = indicesByURL[url] {
                    indicesToRemove.append(idx)
                }
                continue
            }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists {
                if indicesByURL[url] != nil {
                    urlsToUpdate.append(url)
                } else {
                    urlsToAdd.append(url)
                }
            } else if let idx = indicesByURL[url] {
                indicesToRemove.append(idx)
            }
        }

        if indicesToRemove.isEmpty && urlsToUpdate.isEmpty && urlsToAdd.isEmpty { return }

        for idx in indicesToRemove.sorted(by: >) {
            let removed = updatedItems.remove(at: idx)
            updatedSelection.remove(removed)
            hydratedURLs.remove(removed.url)
            pendingHydrationURLs.remove(removed.url)
        }

        indicesByURL = Dictionary(uniqueKeysWithValues: updatedItems.enumerated().map { ($0.element.url, $0.offset) })

        for url in urlsToUpdate {
            guard let idx = indicesByURL[url] else { continue }
            let existing = updatedItems[idx]
            let loadMetadata = existing.hasMetadata || shouldLoadMetadata
            updatedItems[idx] = FileItem(url: url, id: existing.id, loadMetadata: loadMetadata)
        }

        for url in urlsToAdd {
            let newItem = FileItem(url: url, loadMetadata: shouldLoadMetadata)
            updatedItems.append(newItem)
        }

        items = updatedItems
        selectedItems = updatedSelection
        // NOTE: Don't increment navigationGeneration here - incremental updates
        // should not cause full view recreation which loses scroll position
    }

    private func sortStateRequiresMetadata(_ sortState: SortState) -> Bool {
        switch sortState.column {
        case .dateModified, .dateCreated, .size:
            return true
        default:
            return false
        }
    }

    /// Load contents from within a ZIP archive
    private func loadArchiveContents() {
        guard let archiveURL = currentArchiveURL else {
            exitArchive()
            return
        }

        isLoading = true
        items = []

        // Get entries at the current path within the archive
        let entriesAtPath = ZipArchiveManager.shared.entriesAtPath(currentArchivePath, in: archiveEntries)
        var fileItems = ZipArchiveManager.shared.fileItems(from: entriesAtPath, archiveURL: archiveURL)

        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let foldersFirst = AppSettings.shared.foldersFirst
        if !showHiddenFiles {
            fileItems = fileItems.filter { !$0.name.hasPrefix(".") }
        }

        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let sorted = sortItemsForBackground(fileItems, sortState: sortState, foldersFirst: foldersFirst)

        items = sorted
        coverFlowSelectedIndex = min(coverFlowSelectedIndex, max(0, sorted.count - 1))
        isLoading = false
        navigationGeneration += 1
    }

    private func loadPhotosLibraryContents(info: PhotosLibraryInfo) {
        isLoading = true
        items = []
        let infoSnapshot = info
        let pendingURL = pendingSelectionURL
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let useOriginalFilenames = AppSettings.shared.masonryShowFilenames
        let loadToken = UUID()
        photosLoadToken = loadToken

        photosLogger.info("Starting Photos library load: \(info.libraryURL.path, privacy: .public)")

        ensurePhotosAccess { [weak self] status in
            guard let self else { return }
            let authorized = status == .authorized || status == .limited
            guard authorized else {
                self.photosLogger.warning("Photos access denied with status: \(status.rawValue)")
                self.items = []
                self.isLoading = false
                self.showPhotosAccessAlert(for: status)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = .current
                fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

                var effectiveSortState = sortState
                switch effectiveSortState.column {
                case .dateCreated, .dateModified:
                    break
                default:
                    effectiveSortState = SortState(column: .dateCreated, direction: .descending)
                }

                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(
                    format: "mediaType == %d || mediaType == %d",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue
                )
                fetchOptions.sortDescriptors = self.photosSortDescriptors(for: effectiveSortState)

                let assets = PHAsset.fetchAssets(with: fetchOptions)
                self.photosLogger.info("Fetched \(assets.count) Photos assets (status: \(status.rawValue))")

                let totalCount = assets.count
                let batchSize = 400
                let initialCount = min(batchSize, totalCount)

                func buildBatch(range: Range<Int>) -> (items: [FileItem], assetCache: [String: PHAsset], ratioCache: [String: CGFloat], selectedItem: FileItem?) {
                    var batchItems: [FileItem] = []
                    batchItems.reserveCapacity(range.count)
                    var assetCache: [String: PHAsset] = [:]
                    assetCache.reserveCapacity(range.count)
                    var ratioCache: [String: CGFloat] = [:]
                    ratioCache.reserveCapacity(range.count)
                    var selectedItem: FileItem?

                    let indexSet = IndexSet(integersIn: range)
                    assets.enumerateObjects(at: indexSet, options: []) { asset, _, _ in
                        guard let assetURL = self.photosAssetURL(for: asset.localIdentifier) else { return }
                        let name = useOriginalFilenames
                            ? self.photosAssetName(for: asset, fallbackFormatter: fallbackFormatter)
                            : self.photosAssetFallbackName(for: asset, fallbackFormatter: fallbackFormatter)
                        let contentType: UTType? = asset.mediaType == .video ? .movie : .image
                        let modDate = asset.modificationDate ?? asset.creationDate
                        let identifier = asset.localIdentifier
                        assetCache[identifier] = asset
                        if asset.pixelHeight > 0 {
                            ratioCache[identifier] = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                        }

                        let item = FileItem(
                            url: assetURL,
                            name: name,
                            isDirectory: false,
                            size: 0,
                            modificationDate: modDate,
                            creationDate: asset.creationDate,
                            contentType: contentType
                        )
                        if let pendingURL, pendingURL == assetURL {
                            selectedItem = item
                        }
                        batchItems.append(item)
                    }

                    return (batchItems, assetCache, ratioCache, selectedItem)
                }

                let initialBatch = buildBatch(range: 0..<initialCount)
                DispatchQueue.main.async {
                    let infoMatches = self.photosLibraryInfo == infoSnapshot
                    let pathMatches = self.currentPath == infoSnapshot.libraryURL
                    let tokenMatches = self.photosLoadToken == loadToken
                    if !infoMatches || !pathMatches || !tokenMatches {
                        self.photosLogger.warning("Photos load abandoned infoMatches=\(infoMatches) pathMatches=\(pathMatches) tokenMatches=\(tokenMatches) currentPath=\(self.currentPath.path, privacy: .public)")
                        return
                    }

                    self.photosSortState = effectiveSortState
                    self.photosAssetCache = initialBatch.assetCache
                    self.photosAspectRatioCache = initialBatch.ratioCache

                    if let item = initialBatch.selectedItem {
                        self.selectedItems = [item]
                        self.pendingSelectionURL = nil
                    }

                    self.items = initialBatch.items
                    self.isLoading = false
                    self.navigationGeneration += 1
                    if totalCount == 0 {
                        self.photosLogger.warning("Photos load completed with 0 items (status: \(status.rawValue))")
                    }
                }

                guard totalCount > initialCount else { return }

                for start in stride(from: initialCount, to: totalCount, by: batchSize) {
                    let range = start..<min(start + batchSize, totalCount)
                    let batch = buildBatch(range: range)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let infoMatches = self.photosLibraryInfo == infoSnapshot
                        let pathMatches = self.currentPath == infoSnapshot.libraryURL
                        let tokenMatches = self.photosLoadToken == loadToken
                        guard infoMatches, pathMatches, tokenMatches else { return }

                        self.photosAssetCache.merge(batch.assetCache) { current, _ in current }
                        self.photosAspectRatioCache.merge(batch.ratioCache) { current, _ in current }
                        self.items.append(contentsOf: batch.items)

                        if self.pendingSelectionURL != nil, let item = batch.selectedItem {
                            self.selectedItems = [item]
                            self.pendingSelectionURL = nil
                        }
                    }
                }
            }
        }
    }

    private func ensurePhotosAccess(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let status = photosAuthorizationStatus()
        photosLogger.info("Photos authorization status: \(status.rawValue)")

        switch status {
        case .authorized, .limited:
            completion(status)
        case .notDetermined:
            if isRequestingPhotosAccess {
                pendingPhotosAccessCompletions.append(completion)
                return
            }
            isRequestingPhotosAccess = true
            pendingPhotosAccessCompletions.append(completion)
            requestPhotosAuthorization { [weak self] newStatus in
                guard let self else { return }
                self.isRequestingPhotosAccess = false
                self.photosLogger.info("Photos authorization result: \(newStatus.rawValue)")
                let completions = self.pendingPhotosAccessCompletions
                self.pendingPhotosAccessCompletions.removeAll()
                completions.forEach { $0(newStatus) }
            }
        case .denied:
            if didForcePhotosAuthRefresh {
                completion(status)
                return
            }
            didForcePhotosAuthRefresh = true
            requestPhotosAuthorization { [weak self] newStatus in
                guard let self else { return }
                self.photosLogger.info("Photos authorization refresh result: \(newStatus.rawValue)")
                completion(newStatus)
            }
        default:
            completion(status)
        }
    }

    private func photosAuthorizationStatus() -> PHAuthorizationStatus {
        if #available(macOS 11.0, *) {
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        return PHPhotoLibrary.authorizationStatus()
    }

    private func requestPhotosAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let requestBlock = {
            NSApp.activate(ignoringOtherApps: true)
            if #available(macOS 11.0, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    DispatchQueue.main.async {
                        completion(status)
                    }
                }
            } else {
                PHPhotoLibrary.requestAuthorization { status in
                    DispatchQueue.main.async {
                        completion(status)
                    }
                }
            }
        }

        if Thread.isMainThread {
            requestBlock()
        } else {
            DispatchQueue.main.async {
                requestBlock()
            }
        }
    }

    private func showPhotosAccessAlert(for status: PHAuthorizationStatus) {
        let alert = NSAlert()
        alert.messageText = "Photos Access Needed"
        if status == .restricted {
            alert.informativeText = "Photos access is restricted on this Mac. Check Screen Time or configuration profiles."
        } else {
            alert.informativeText = "Allow Photos access in System Settings to show your full library."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if let window = NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    self.openPhotosPrivacySettings()
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openPhotosPrivacySettings()
            }
        }
    }

    private func openPhotosPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
    }

    func isPhotosItem(_ item: FileItem) -> Bool {
        photosAssetIdentifier(from: item.url) != nil
    }

    func photosAssetIdentifier(for item: FileItem) -> String? {
        photosAssetIdentifier(from: item.url)
    }

    func photosAssetAspectRatio(for item: FileItem) -> CGFloat? {
        guard let identifier = photosAssetIdentifier(from: item.url),
              !identifier.isEmpty else { return nil }
        if let cached = photosAspectRatioCache[identifier] {
            return cached
        }
        guard let asset = photosAsset(for: identifier),
              asset.pixelHeight > 0 else { return nil }
        let ratio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        photosAspectRatioCache[identifier] = ratio
        return ratio
    }

    func startCachingPhotos(for items: [FileItem], targetSize: CGSize) {
        let assets = items.compactMap { item -> PHAsset? in
            guard let identifier = photosAssetIdentifier(from: item.url),
                  let asset = photosAsset(for: identifier) else { return nil }
            return asset
        }
        guard !assets.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        photosImageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    func stopCachingPhotos(for items: [FileItem], targetSize: CGSize) {
        let assets = items.compactMap { item -> PHAsset? in
            guard let identifier = photosAssetIdentifier(from: item.url),
                  let asset = photosAsset(for: identifier) else { return nil }
            return asset
        }
        guard !assets.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        photosImageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    func stopCachingAllPhotos() {
        photosImageManager.stopCachingImagesForAllAssets()
    }

    func requestPhotoThumbnail(
        for item: FileItem,
        targetPixelSize: CGFloat,
        completion: @escaping (NSImage?, CGFloat?) -> Void
    ) {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier) else {
            completion(nil, nil)
            return
        }

        let requestKey = "\(identifier)-\(Int(targetPixelSize))"
        if photosThumbnailRequests[requestKey] != nil { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        let targetSize = CGSize(width: targetPixelSize, height: targetPixelSize)
        let requestID = photosImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.photosThumbnailRequests.removeValue(forKey: requestKey)
                let ratio = asset.pixelHeight > 0
                    ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                    : nil
                completion(image, ratio)
            }
        }

        photosThumbnailRequests[requestKey] = requestID
    }

    func photoAssetDragInfo(for item: FileItem) -> PhotoAssetDragInfo? {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier),
              let resource = primaryResource(for: asset) else { return nil }
        let filename = resource.originalFilename.isEmpty ? item.name : resource.originalFilename
        let uti = resource.uniformTypeIdentifier.isEmpty
            ? (asset.mediaType == .video ? UTType.movie.identifier : UTType.image.identifier)
            : resource.uniformTypeIdentifier
        return PhotoAssetDragInfo(filename: filename, uti: uti)
    }

    func writePhotoAsset(for item: FileItem, to destinationURL: URL, completion: @escaping (Bool) -> Void) {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier),
              let resource = primaryResource(for: asset) else {
            completion(false)
            return
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try? FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destinationURL)

        PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    func exportPhotoAsset(for item: FileItem, completion: @escaping (URL?) -> Void) {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier) else {
            completion(nil)
            return
        }

        if let cached = photosExportCache[identifier], FileManager.default.fileExists(atPath: cached.path) {
            completion(cached)
            return
        }

        guard let resource = primaryResource(for: asset) else {
            completion(nil)
            return
        }

        let exportURL = photosExportURL(for: identifier, suggestedFilename: resource.originalFilename)
        try? FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: exportURL, options: options) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    self.photosExportCache[identifier] = exportURL
                    completion(exportURL)
                } else {
                    completion(nil)
                }
            }
        }
    }

    nonisolated private func photosAssetURL(for identifier: String) -> URL? {
        let scheme = "photos"
        let host = "asset"
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: identifier)]
        return components.url
    }

    nonisolated private func photosAssetIdentifier(from url: URL) -> String? {
        let scheme = "photos"
        let host = "asset"
        guard url.scheme == scheme, url.host == host else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "id" })?.value
    }

    nonisolated private func photosSortDescriptors(for sortState: SortState) -> [NSSortDescriptor] {
        switch sortState.column {
        case .dateCreated:
            return [NSSortDescriptor(key: "creationDate", ascending: sortState.direction == .ascending)]
        case .dateModified:
            return [NSSortDescriptor(key: "modificationDate", ascending: sortState.direction == .ascending)]
        default:
            return [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
    }

    private func photosAsset(for identifier: String) -> PHAsset? {
        if let cached = photosAssetCache[identifier] {
            return cached
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        let asset = result.firstObject
        if let asset {
            photosAssetCache[identifier] = asset
        }
        return asset
    }

    nonisolated private func photosAssetName(for asset: PHAsset, fallbackFormatter: DateFormatter) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            return resource.originalFilename
        }
        if let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) {
            return resource.originalFilename
        }
        return photosAssetFallbackName(for: asset, fallbackFormatter: fallbackFormatter)
    }

    nonisolated private func photosAssetFallbackName(for asset: PHAsset, fallbackFormatter: DateFormatter) -> String {
        if let date = asset.creationDate {
            return "Photo \(fallbackFormatter.string(from: date))"
        }
        return "Photo"
    }

    private func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first { $0.type == .video || $0.type == .fullSizeVideo } ?? resources.first
        }
        return resources.first { $0.type == .photo || $0.type == .fullSizePhoto } ?? resources.first
    }

    private func photosExportURL(for identifier: String, suggestedFilename: String) -> URL {
        let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "-")
        let filename = suggestedFilename.isEmpty ? safeIdentifier : "\(safeIdentifier)-\(suggestedFilename)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FlowFinder-PhotosExport", isDirectory: true)
        return folder.appendingPathComponent(filename)
    }

    private func clearPhotosCaches() {
        photosAssetCache.removeAll()
        photosAspectRatioCache.removeAll()
        photosThumbnailRequests.removeAll()
        photosExportCache.removeAll()
        photosImageManager.stopCachingImagesForAllAssets()
        photosSortState = nil
        photosLoadToken = UUID()
    }


    func navigateTo(_ url: URL) {
        guard url != currentPath else { return }

        // Save column state for current folder before navigating
        ListColumnConfigManager.shared.saveCurrentStateForFolder(currentPath, appSettings: AppSettings.shared)

        photosLibraryInfo = nil
        clearPhotosCaches()
        currentPath = url
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0

        // Apply column state for new folder (set flag to prevent redundant reload from sortColumn sink)
        isNavigating = true
        ListColumnConfigManager.shared.applyPerFolderState(for: url, appSettings: AppSettings.shared)
        isNavigating = false

        loadContents()
        addToHistory(.filesystem(url))
    }

    /// Navigate to a URL and select the folder we came from (for path bar navigation)
    func navigateToAndSelectCurrent(_ url: URL) {
        guard url != currentPath else { return }

        // Save column state for current folder before navigating
        ListColumnConfigManager.shared.saveCurrentStateForFolder(currentPath, appSettings: AppSettings.shared)

        photosLibraryInfo = nil
        clearPhotosCaches()
        // Remember current path to select it after navigating
        pendingSelectionURL = currentPath
        currentPath = url
        selectedItems.removeAll()
        // Note: Don't reset coverFlowSelectedIndex here - let loadContents set the correct index

        // Apply column state for new folder (set flag to prevent redundant reload from sortColumn sink)
        isNavigating = true
        ListColumnConfigManager.shared.applyPerFolderState(for: url, appSettings: AppSettings.shared)
        isNavigating = false

        loadContents()
        addToHistory(.filesystem(url))
    }

    func navigateToPhotosLibrary(_ info: PhotosLibraryInfo) {
        clearPhotosCaches()
        photosLibraryInfo = info
        photosLogger.info("Navigate to Photos library: \(info.libraryURL.path, privacy: .public)")
        isInsideArchive = false
        currentArchiveURL = nil
        currentArchivePath = ""
        archiveEntries = []
        currentPath = info.libraryURL
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0
        loadContents()
        addToHistory(.photosLibrary(info))
    }

    func navigateToParent() {
        let parent = currentPath.deletingLastPathComponent()
        if parent != currentPath {
            navigateTo(parent)
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let location = navigationHistory[historyIndex]
        if case .filesystem = location {
            pendingSelectionURL = enteredFolderURL ?? currentPath
        } else if case .photosLibrary = location {
            pendingSelectionURL = nil
        } else {
            pendingSelectionURL = nil
        }
        enteredFolderURL = nil
        applyNavigationLocation(location)
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let location = navigationHistory[historyIndex]
        pendingSelectionURL = nil
        applyNavigationLocation(location)
    }

    private func applyNavigationLocation(_ location: NavigationLocation) {
        switch location {
        case .filesystem(let url):
            isInsideArchive = false
            currentArchiveURL = nil
            currentArchivePath = ""
            archiveEntries = []
            photosLibraryInfo = nil
            clearPhotosCaches()
            currentPath = url
            selectedItems.removeAll()
            loadContents()
        case .archive(let archiveURL, let internalPath):
            do {
                if currentArchiveURL != archiveURL || archiveEntries.isEmpty {
                    archiveEntries = try ZipArchiveManager.shared.readContents(of: archiveURL)
                }
                currentArchiveURL = archiveURL
                currentArchivePath = internalPath
                isInsideArchive = true
                selectedItems.removeAll()
                coverFlowSelectedIndex = 0
                loadContents()
            } catch {
                zipNavLogger.error("Failed to restore archive state: \(error.localizedDescription)")
                isInsideArchive = false
                currentArchiveURL = nil
                currentArchivePath = ""
                archiveEntries = []
                photosLibraryInfo = nil
                clearPhotosCaches()
                currentPath = archiveURL.deletingLastPathComponent()
                loadContents()
            }
        case .photosLibrary(let info):
            isInsideArchive = false
            currentArchiveURL = nil
            currentArchivePath = ""
            archiveEntries = []
            photosLibraryInfo = info
            photosLogger.info("Apply navigation to Photos library: \(info.libraryURL.path, privacy: .public)")
            currentPath = info.libraryURL
            selectedItems.removeAll()
            coverFlowSelectedIndex = 0
            loadContents()
        }
    }

    func openItem(_ item: FileItem) {
        cancelPendingRename()

        if isPhotosItem(item) {
            exportPhotoAsset(for: item) { url in
                guard let url else {
                    NSSound.beep()
                    return
                }
                NSWorkspace.shared.open(url)
            }
            return
        }

        // Handle items inside an archive
        if item.isFromArchive {
            if item.isDirectory {
                // Navigate into the folder within the archive
                if let archivePath = item.archivePath {
                    navigateInArchive(to: archivePath)
                }
            } else {
                // Extract and open the file
                openArchiveItem(item)
            }
            return
        }

        // Check if this is a ZIP file we should browse into
        if item.isZipArchive {
            enterArchive(at: item.url)
            return
        }

        if !item.url.isFileURL {
            NSWorkspace.shared.open(item.url)
            return
        }

        if item.isDirectory {
            enteredFolderURL = item.url
            navigateTo(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Archive Navigation

    /// Enter a ZIP archive and browse its contents
    func enterArchive(at url: URL) {
        do {
            // Read archive entries
            let entries = try ZipArchiveManager.shared.readContents(of: url)
            archiveEntries = entries

            // Store the archive URL and set archive mode
            currentArchiveURL = url
            currentArchivePath = ""
            isInsideArchive = true

            // Clear search text and tag filter when entering an archive
            // since we're now browsing different content
            if !searchText.isEmpty {
                searchText = ""
            }
            if filterTag != nil {
                filterTag = nil
            }

            // Remember where we came from for back navigation
            enteredFolderURL = url

            // Reset selection and load archive contents
            selectedItems.removeAll()
            coverFlowSelectedIndex = 0
            loadContents()

            // Add to history (use a virtual URL)
            addToHistory(.archive(archiveURL: url, internalPath: ""))
        } catch {
            // Fall back to opening with default app
            zipNavLogger.error("Error reading archive: \(error.localizedDescription)")
            NSWorkspace.shared.open(url)
        }
    }

    /// Navigate to a path within the current archive
    func navigateInArchive(to path: String) {
        guard isInsideArchive else { return }

        // Ensure path ends with / for directories
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        currentArchivePath = normalizedPath
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0
        loadContents()

        // Add to history
        if let archiveURL = currentArchiveURL {
            addToHistory(.archive(archiveURL: archiveURL, internalPath: normalizedPath))
        }
    }

    /// Exit the current archive and return to the filesystem
    func exitArchive() {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }

        isInsideArchive = false
        currentArchiveURL = nil
        currentArchivePath = ""
        archiveEntries = []

        // Navigate to the folder containing the archive
        currentPath = archiveURL.deletingLastPathComponent()
        pendingSelectionURL = archiveURL
        selectedItems.removeAll()
        loadContents()
        addToHistory(.filesystem(currentPath))
    }

    /// Navigate up one level (handles both archive and filesystem)
    func navigateUp() {
        if isInsideArchive {
            if currentArchivePath.isEmpty {
                // At archive root, exit the archive
                exitArchive()
            } else {
                // Go up one level within the archive
                let components = currentArchivePath.split(separator: "/")
                if components.count > 1 {
                    let parentPath = components.dropLast().joined(separator: "/")
                    navigateInArchive(to: parentPath)
                } else {
                    // Go to archive root
                    currentArchivePath = ""
                    selectedItems.removeAll()
                    coverFlowSelectedIndex = 0
                    loadContents()
                }
            }
        } else {
            navigateToParent()
        }
    }

    /// Extract and open a file from the archive
    private func openArchiveItem(_ item: FileItem) {
        guard let archiveURL = item.archiveURL,
              let archivePath = item.archivePath else {
            return
        }

        guard !item.isDirectory else { return }

        // Extract on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tempURL = try ZipArchiveManager.shared.extractByPath(archivePath, from: archiveURL)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(tempURL)
                }
            } catch {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
                print("Failed to extract file: \(error.localizedDescription)")
            }
        }
    }

    private func archiveEntry(for item: FileItem) -> ZipEntry? {
        guard let archivePath = item.archivePath else { return nil }
        if let entry = archiveEntries.first(where: { $0.path == archivePath }) {
            return entry
        }
        if let entry = archiveEntries.first(where: { $0.path == archivePath + "/" }) {
            return entry
        }
        if archivePath.hasSuffix("/") {
            let trimmed = String(archivePath.dropLast())
            return archiveEntries.first(where: { $0.path == trimmed })
        }
        return nil
    }

    func previewURL(for item: FileItem) -> URL? {
        // For archive items, return nil - caller should use async version
        if item.isFromArchive {
            return nil
        }
        if let identifier = photosAssetIdentifier(from: item.url) {
            return photosExportCache[identifier]
        }
        return item.url
    }

    /// Async version for archive items - extracts on background thread
    func previewURL(for item: FileItem, completion: @escaping (URL?) -> Void) {
        if item.isFromArchive {
            // TEMP: Skip archive preview entirely to diagnose freeze
            completion(nil)
            return
        }
        // Non-archive items return immediately
        completion(previewURL(for: item))
    }

    // Track anchor index for Shift+click range selection
    var lastSelectedIndex: Int = 0

    func selectItem(_ item: FileItem, extend: Bool = false) {
        if extend {
            if selectedItems.contains(item) {
                selectedItems.remove(item)
            } else {
                selectedItems.insert(item)
            }
        } else {
            selectedItems = [item]
        }
    }

    /// Select a range of items from lastSelectedIndex to the given index (Shift+click behavior)
    func selectRange(to index: Int, in items: [FileItem]) {
        guard !items.isEmpty else { return }
        let start = min(lastSelectedIndex, index)
        let end = max(lastSelectedIndex, index)
        let clampedStart = max(0, start)
        let clampedEnd = min(items.count - 1, end)

        selectedItems = Set(items[clampedStart...clampedEnd])
        lastSelectedIndex = index
    }

    /// Handle selection with all modifier combinations
    func handleSelection(item: FileItem, index: Int, in items: [FileItem], withShift: Bool, withCommand: Bool) {
        let now = Date()
        cancelPendingRename()

        // Cancel any active rename when clicking on a different item
        if renamingURL != nil && renamingURL != item.url {
            renamingURL = nil
        }

        if withShift {
            // Shift+click: select range from anchor to clicked item
            selectRange(to: index, in: items)
            lastClickedURL = nil
        } else if withCommand {
            // Cmd+click: toggle selection
            if selectedItems.contains(item) {
                selectedItems.remove(item)
            } else {
                selectedItems.insert(item)
            }
            lastSelectedIndex = index
            lastClickedURL = nil
        } else {
            // Normal click: check for Finder-style rename trigger
            let wasOnlySelected = selectedItems.count == 1 && selectedItems.contains(item)
            let timeSinceLastClick = now.timeIntervalSince(lastClickTime)
            let isSameItem = lastClickedURL == item.url
            let doubleClickInterval = NSEvent.doubleClickInterval

            // If clicking the only selected item after the system double-click interval,
            // schedule rename with a short delay to avoid double-click collisions.
            if wasOnlySelected && isSameItem && timeSinceLastClick > doubleClickInterval && timeSinceLastClick < 3.0 && renamingURL == nil {
                if item.isFromArchive {
                    NSSound.beep()
                } else {
                    scheduleRename(for: item)
                    lastClickedURL = item.url
                }
            } else {
                // Normal selection
                selectedItems = [item]
                lastSelectedIndex = index
                lastClickedURL = item.url
            }
        }

        lastClickTime = now
    }

    private func scheduleRename(for item: FileItem) {
        cancelPendingRename()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.renamingURL == nil else { return }
            guard self.selectedItems.count == 1, self.selectedItems.contains(item) else { return }
            self.renamingURL = item.url
        }
        pendingRenameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + renameDelay, execute: workItem)
    }

    private func cancelPendingRename() {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
    }

    private func addToHistory(_ location: NavigationLocation) {
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((historyIndex + 1)...)
        }
        navigationHistory.append(location)
        historyIndex = navigationHistory.count - 1
    }

    func refresh() {
        loadContents()
    }

    func refreshTags(for urls: [URL]) {
        for url in urls {
            FileTagManager.invalidateCache(for: url)
        }
        tagRefreshToken &+= 1
        // Force UI refresh by sending objectWillChange
        objectWillChange.send()
    }

    // MARK: - Clipboard Operations

    var canPaste: Bool {
        if isInsideArchive { return false }
        if !clipboardItems.isEmpty {
            return true
        }
        // Also check system pasteboard
        let pasteboard = NSPasteboard.general
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func copySelectedItems() {
        let itemsToCopy = Array(selectedItems)
        guard !itemsToCopy.isEmpty else { return }
        let entriesSnapshot = archiveEntries

        fileOperationQueue.async { [weak self, itemsToCopy, entriesSnapshot] in
            guard let self else { return }
            var urlsToCopy: [URL] = []
            urlsToCopy.reserveCapacity(itemsToCopy.count)

            for item in itemsToCopy {
                if item.isFromArchive {
                    // Extract archive item to temp location for copying
                    if let extractedURL = self.extractArchiveItemForCopy(item, entries: entriesSnapshot) {
                        urlsToCopy.append(extractedURL)
                    }
                } else {
                    urlsToCopy.append(item.url)
                }
            }

            guard !urlsToCopy.isEmpty else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clipboardItems = urlsToCopy
                self.clipboardOperation = .copy

                // Also copy to system pasteboard
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects(urlsToCopy as [NSURL])
            }
        }
    }

    /// Extract an archive item to a temp directory for copy/paste operations
    nonisolated private func extractArchiveItemForCopy(_ item: FileItem, entries: [ZipEntry]) -> URL? {
        guard let archiveURL = item.archiveURL,
              let archivePath = item.archivePath else { return nil }

        // Create temp directory for extractions
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FlowFinder-Extract")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let destURL = tempDir.appendingPathComponent(item.name)

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destURL)

        if item.isDirectory {
            // For directories, we need to extract all contents
            return extractArchiveDirectory(item, from: archiveURL, to: destURL, entries: entries)
        } else {
            // For files, extract single file
            if let entry = entries.first(where: { $0.path == archivePath || $0.path == archivePath + "/" }) {
                do {
                    let extractedURL = try ZipArchiveManager.shared.extractFile(entry, from: archiveURL)
                    // Move from temp extraction location to our desired location
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: extractedURL, to: destURL)
                    return destURL
                } catch {
                    // Extraction failed
                }
            }
        }
        return nil
    }

    /// Extract an entire directory from archive
    nonisolated private func extractArchiveDirectory(_ item: FileItem, from archiveURL: URL, to destURL: URL, entries: [ZipEntry]) -> URL? {
        guard let basePath = item.archivePath else { return nil }

        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"

        do {
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

            // Find all entries under this directory
            for entry in entries {
                guard entry.path.hasPrefix(normalizedBase) else { continue }

                let relativePath = String(entry.path.dropFirst(normalizedBase.count))
                guard !relativePath.isEmpty else { continue }

                let itemDestURL = destURL.appendingPathComponent(relativePath)

                if entry.isDirectory {
                    try FileManager.default.createDirectory(at: itemDestURL, withIntermediateDirectories: true)
                } else {
                    // Extract file
                    let extractedURL = try ZipArchiveManager.shared.extractFile(entry, from: archiveURL)
                    // Ensure parent directory exists
                    try FileManager.default.createDirectory(at: itemDestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: itemDestURL)
                    try FileManager.default.copyItem(at: extractedURL, to: itemDestURL)
                }
            }
            return destURL
        } catch {
            return nil
        }
    }

    func cutSelectedItems() {
        guard !selectedItems.isEmpty else { return }

        // Check if any items are from archive - cut from archive acts as copy
        let hasArchiveItems = selectedItems.contains { $0.isFromArchive }

        if hasArchiveItems {
            // Can't cut from archive, just copy instead
            copySelectedItems()
            return
        }

        clipboardItems = selectedItems.map { $0.url }
        clipboardOperation = .cut

        // Also copy to system pasteboard with cut marker
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(clipboardItems as [NSURL])
        // Add marker to indicate this is a cut operation
        pasteboard.setData(Data([1]), forType: cutOperationPasteboardType)
    }

    func paste() {
        guard !isInsideArchive else {
            NSSound.beep()
            return
        }

        // Use internal clipboard if available, otherwise read from system pasteboard
        var urlsToPaste = clipboardItems
        var operationIsCut = clipboardOperation == .cut

        if urlsToPaste.isEmpty {
            // Fall back to system pasteboard
            let pasteboard = NSPasteboard.general
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                urlsToPaste = urls
                // Check if this was a cut operation (our custom marker)
                operationIsCut = pasteboard.data(forType: cutOperationPasteboardType) != nil
            }
        }

        guard !urlsToPaste.isEmpty else { return }

        let destinationPath = currentPath

        fileOperationQueue.async { [urlsToPaste, operationIsCut, destinationPath] in
            let fileManager = FileManager.default
            var didPasteAny = false
            for sourceURL in urlsToPaste {
                let destinationURL = destinationPath.appendingPathComponent(sourceURL.lastPathComponent)
                let finalDestination = self.uniqueDestinationURL(for: destinationURL)

                do {
                    if operationIsCut {
                        try self.moveItemWithFallback(fileManager, from: sourceURL, to: finalDestination)
                    } else {
                        try fileManager.copyItem(at: sourceURL, to: finalDestination)
                    }
                    didPasteAny = true
                } catch {
                    print("Failed to paste \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if operationIsCut && didPasteAny {
                    self.clipboardItems.removeAll()
                    // Clear the cut marker from pasteboard to prevent re-pasting moved files
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                }

                self.refresh()
            }
        }
    }

    func deleteSelectedItems() {
        let itemsToDelete = selectedItems.filter { !$0.isFromArchive }
        guard !itemsToDelete.isEmpty else {
            NSSound.beep()
            return
        }

        // Find the URL to select after deletion (next item, or previous if at end)
        let currentItems = filteredItems
        let deletedURLs = Set(itemsToDelete.map { $0.url })
        var nextSelectionURL: URL? = nil
        var nextSelectionIndex: Int = 0

        // Find the first item that's NOT being deleted, preferring items after the deleted ones
        if let firstDeletedIndex = currentItems.firstIndex(where: { deletedURLs.contains($0.url) }) {
            // Look for first non-deleted item after the deleted range
            for i in firstDeletedIndex..<currentItems.count {
                if !deletedURLs.contains(currentItems[i].url) {
                    nextSelectionURL = currentItems[i].url
                    // Calculate what index this will be after deletion
                    let deletedBefore = currentItems[0..<i].filter { deletedURLs.contains($0.url) }.count
                    nextSelectionIndex = i - deletedBefore
                    break
                }
            }

            // If no item after, look before
            if nextSelectionURL == nil && firstDeletedIndex > 0 {
                for i in stride(from: firstDeletedIndex - 1, through: 0, by: -1) {
                    if !deletedURLs.contains(currentItems[i].url) {
                        nextSelectionURL = currentItems[i].url
                        let deletedBefore = currentItems[0..<i].filter { deletedURLs.contains($0.url) }.count
                        nextSelectionIndex = i - deletedBefore
                        break
                    }
                }
            }
        }

        // Store the target index to use after refresh - this prevents race conditions
        let targetIndex = nextSelectionIndex

        // DON'T clear selectedItems here - it triggers syncSelection which re-selects
        // the about-to-be-deleted item. We'll clear it in the async block instead.

        fileOperationQueue.async {
            let fileManager = FileManager.default
            var didTrashAny = false
            for item in itemsToDelete {
                do {
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                    didTrashAny = true
                } catch {
                    print("Failed to delete \(item.name): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Set the target index BEFORE refresh so CoverFlowView knows where to position
                self.coverFlowSelectedIndex = targetIndex

                // Clear selectedItems so syncSelection will auto-select at coverFlowSelectedIndex
                // when items are reloaded. This must happen BEFORE refresh so the index is set first.
                self.selectedItems.removeAll()

                // Refresh to get updated file list - items load asynchronously
                // CoverFlowView's syncSelection will auto-select at coverFlowSelectedIndex when items arrive
                self.refresh()

                if didTrashAny {
                    FinderSoundEffects.shared.play(.moveToTrash)
                }
            }
        }
    }

    func handleDrop(urls: [URL], to destPath: URL? = nil, completion: (() -> Void)? = nil) {
        guard !isInsideArchive else {
            NSSound.beep()
            return
        }

        let destination = destPath ?? currentPath
        // Finder behavior: Drag = Move, Option+Drag = Copy
        let shouldCopy = NSEvent.modifierFlags.contains(.option)
        let destinationPath = destination

        fileOperationQueue.async { [urls, shouldCopy, destinationPath] in
            let fileManager = FileManager.default

            for sourceURL in urls {
                if sourceURL.deletingLastPathComponent() == destinationPath { continue }

                let destURL = destinationPath.appendingPathComponent(sourceURL.lastPathComponent)
                let finalURL = self.uniqueDestinationURL(for: destURL)

                do {
                    if shouldCopy {
                        try fileManager.copyItem(at: sourceURL, to: finalURL)
                    } else {
                        try self.moveItemWithFallback(fileManager, from: sourceURL, to: finalURL)
                    }
                } catch {
                    print("Failed to \(shouldCopy ? "copy" : "move") \(sourceURL.lastPathComponent): \(error)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.refresh()
                completion?()
            }
        }
    }

    func duplicateSelectedItems() {
        guard !isInsideArchive else {
            NSSound.beep()
            return
        }

        let itemsToDuplicate = selectedItems.filter { !$0.isFromArchive }
        guard !itemsToDuplicate.isEmpty else {
            NSSound.beep()
            return
        }

        let destinationPath = currentPath

        fileOperationQueue.async { [itemsToDuplicate, destinationPath] in
            let fileManager = FileManager.default
            for item in itemsToDuplicate {
                let baseName = item.url.deletingPathExtension().lastPathComponent
                let ext = item.url.pathExtension
                var copyName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
                var destinationURL = destinationPath.appendingPathComponent(copyName)

                // Handle existing copies
                var copyNumber = 2
                while fileManager.fileExists(atPath: destinationURL.path) {
                    copyName = ext.isEmpty ? "\(baseName) copy \(copyNumber)" : "\(baseName) copy \(copyNumber).\(ext)"
                    destinationURL = destinationPath.appendingPathComponent(copyName)
                    copyNumber += 1
                }

                do {
                    try fileManager.copyItem(at: item.url, to: destinationURL)
                } catch {
                    print("Failed to duplicate \(item.name): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }
    }

    func renameItem(_ item: FileItem, to newName: String) {
        guard !item.isFromArchive else {
            NSSound.beep()
            return
        }

        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)

        guard newURL != item.url else { return }

        fileOperationQueue.async {
            do {
                try FileManager.default.moveItem(at: item.url, to: newURL)
                DispatchQueue.main.async { [weak self] in
                    self?.refresh()
                }
            } catch {
                print("Failed to rename \(item.name): \(error.localizedDescription)")
            }
        }
    }

    func moveSelectedItemsToTrash() {
        deleteSelectedItems()
    }

    func getInfo() {
        guard let item = selectedItems.first else { return }
        guard !item.isFromArchive else {
            NSSound.beep()
            return
        }
        infoItem = item
        NotificationCenter.default.post(name: .showGetInfo, object: item)
    }

    func showInFinder() {
        let urls: [URL]
        if selectedItems.isEmpty {
            if isInsideArchive, let archiveURL = currentArchiveURL {
                urls = [archiveURL]
            } else {
                urls = [currentPath]
            }
        } else {
            urls = selectedItems.compactMap { item in
                if item.isFromArchive {
                    return item.archiveURL
                }
                return item.url
            }
        }

        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func createNewFolder() {
        guard !isInsideArchive else {
            NSSound.beep()
            return
        }

        let destinationPath = currentPath

        fileOperationQueue.async {
            let fileManager = FileManager.default
            var folderName = "untitled folder"
            var folderURL = destinationPath.appendingPathComponent(folderName)

            var counter = 2
            while fileManager.fileExists(atPath: folderURL.path) {
                folderName = "untitled folder \(counter)"
                folderURL = destinationPath.appendingPathComponent(folderName)
                counter += 1
            }

            do {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
                DispatchQueue.main.async { [weak self] in
                    self?.refresh()
                }
            } catch {
                print("Failed to create folder: \(error.localizedDescription)")
            }
        }
    }

    func selectAll() {
        selectedItems = Set(filteredItems)
    }

    nonisolated func uniqueDestinationURL(for url: URL) -> URL {
        let fileManager = FileManager.default
        var destinationURL = url

        if fileManager.fileExists(atPath: destinationURL.path) {
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var counter = 2

            repeat {
                let newName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
                destinationURL = url.deletingLastPathComponent().appendingPathComponent(newName)
                counter += 1
            } while fileManager.fileExists(atPath: destinationURL.path)
        }

        return destinationURL
    }

    nonisolated private func moveItemWithFallback(_ fileManager: FileManager, from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain &&
                nsError.code == POSIXErrorCode.EXDEV.rawValue {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                try fileManager.removeItem(at: sourceURL)
            } else {
                throw error
            }
        }
    }
}

extension FileBrowserViewModel: NetworkServiceBrowserDelegate {
    fileprivate func networkServiceBrowser(_ browser: NetworkServiceBrowser, didUpdate services: [NetworkServiceInfo], isFinal: Bool) {
        updateNetworkItems(from: services, isFinal: isFinal)
    }
}

extension FileBrowserViewModel: SMBSubnetScannerDelegate {
    fileprivate func smbSubnetScanner(_ scanner: SMBSubnetScanner, didDiscover hosts: [SMBHostInfo]) {
        guard isNetworkBrowsing, currentPath.path == "/Network" else { return }
        discoveredSMBHosts = hosts
        rebuildNetworkItems()
        if isLoading && !items.isEmpty {
            isLoading = false
        }
    }

    fileprivate func smbSubnetScannerDidFinish(_ scanner: SMBSubnetScanner) {
        smbScanComplete = true
        // Ensure we rebuild one final time with all results
        if isNetworkBrowsing, currentPath.path == "/Network" {
            rebuildNetworkItems()
        }
    }
}

fileprivate struct NetworkServiceInfo: Hashable {
    let key: String
    let name: String
    let scheme: String
    let hostName: String?
    let port: Int
    let priority: Int
}

fileprivate protocol NetworkServiceBrowserDelegate: AnyObject {
    func networkServiceBrowser(_ browser: NetworkServiceBrowser, didUpdate services: [NetworkServiceInfo], isFinal: Bool)
}

fileprivate final class NetworkServiceBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private weak var delegate: NetworkServiceBrowserDelegate?
    private var browsers: [NetServiceBrowser] = []
    private var netServices: [String: NetService] = [:]
    private var services: [String: NetworkServiceInfo] = [:]
    private let serviceTypes = ["_smb._tcp.", "_afp._tcp.", "_workstation._tcp."]

    init(delegate: NetworkServiceBrowserDelegate) {
        self.delegate = delegate
    }

    func start() {
        stop()
        for type in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "")
        }
    }

    func stop() {
        for browser in browsers {
            browser.stop()
        }
        browsers.removeAll()
        netServices.removeAll()
        services.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = serviceKey(for: service)
        guard netServices[key] == nil else { return }

        netServices[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
        updateServiceInfo(for: service)
        notifyDelegate(isFinal: !moreComing)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = serviceKey(for: service)
        netServices.removeValue(forKey: key)
        services.removeValue(forKey: key)
        notifyDelegate(isFinal: !moreComing)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        updateServiceInfo(for: sender)
        notifyDelegate(isFinal: true)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        updateServiceInfo(for: sender)
        notifyDelegate(isFinal: true)
    }

    private func updateServiceInfo(for service: NetService) {
        let key = serviceKey(for: service)
        let scheme = schemeForType(service.type)
        let priority = priorityForType(service.type)
        let info = NetworkServiceInfo(
            key: key,
            name: service.name,
            scheme: scheme,
            hostName: service.hostName,
            port: service.port,
            priority: priority
        )
        services[key] = info
    }

    private func notifyDelegate(isFinal: Bool) {
        let snapshot = Array(services.values)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.networkServiceBrowser(self, didUpdate: snapshot, isFinal: isFinal)
        }
    }

    private func serviceKey(for service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func schemeForType(_ type: String) -> String {
        if type.contains("_afp._tcp") {
            return "afp"
        }
        return "smb"
    }

    private func priorityForType(_ type: String) -> Int {
        if type.contains("_smb._tcp") {
            return 2
        }
        if type.contains("_afp._tcp") {
            return 1
        }
        if type.contains("_workstation._tcp") {
            return 0
        }
        return 0
    }
}

private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.coverflowfinder.directorywatcher", qos: .utility)
    private let callback: ([URL]) -> Void
    private var watchedPath: String?

    init(callback: @escaping ([URL]) -> Void) {
        self.callback = callback
    }

    func start(watching url: URL) {
        let path = url.path
        if watchedPath == path { return }
        stop()
        watchedPath = path

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        let pathsToWatch = [path] as CFArray
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.eventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private static let eventCallback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
        guard let clientInfo else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        watcher.callback(urls)
    }
}

// MARK: - SMB Network Scanner

fileprivate struct SMBHostInfo: Hashable {
    let ipAddress: String
    let name: String
    let port: Int
}

fileprivate protocol SMBSubnetScannerDelegate: AnyObject {
    func smbSubnetScanner(_ scanner: SMBSubnetScanner, didDiscover hosts: [SMBHostInfo])
    func smbSubnetScannerDidFinish(_ scanner: SMBSubnetScanner)
}

/// Scans the local subnet for SMB hosts (port 445)
fileprivate final class SMBSubnetScanner {
    private weak var delegate: SMBSubnetScannerDelegate?
    private let scanQueue = DispatchQueue(label: "com.flowfinder.smbscanner", qos: .utility, attributes: .concurrent)
    private let resultQueue = DispatchQueue(label: "com.flowfinder.smbscanner.results", qos: .utility)
    private var discoveredHosts: [SMBHostInfo] = []
    private var isScanning = false
    private var scanWorkItem: DispatchWorkItem?
    private let smbPort: UInt16 = 445
    private let connectionTimeout: TimeInterval = 0.3

    init(delegate: SMBSubnetScannerDelegate) {
        self.delegate = delegate
    }

    func start() {
        guard !isScanning else { return }
        isScanning = true
        discoveredHosts = []

        // Get local network info
        guard let (localIP, netmask) = getLocalNetworkInfo() else {
            finishScanning()
            return
        }

        // Calculate subnet range
        let ipRange = calculateIPRange(localIP: localIP, netmask: netmask)
        guard !ipRange.isEmpty else {
            finishScanning()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.scanIPRange(ipRange, localIP: localIP)
        }
        scanWorkItem = workItem
        scanQueue.async(execute: workItem)
    }

    func stop() {
        scanWorkItem?.cancel()
        scanWorkItem = nil
        isScanning = false
    }

    private func getLocalNetworkInfo() -> (ip: String, netmask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            // Look for common interface names (en0 is usually WiFi, en1 ethernet)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var netmaskHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            // Get IP address
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NUMERICHOST)

            // Get netmask
            if let netmask = interface.ifa_netmask {
                getnameinfo(netmask, socklen_t(netmask.pointee.sa_len),
                           &netmaskHost, socklen_t(netmaskHost.count),
                           nil, 0, NI_NUMERICHOST)
            }

            let ip = String(cString: hostname)
            let mask = String(cString: netmaskHost)

            // Skip loopback and link-local addresses
            guard !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") else { continue }
            guard !ip.isEmpty && !mask.isEmpty else { continue }

            return (ip, mask)
        }
        return nil
    }

    private func calculateIPRange(localIP: String, netmask: String) -> [String] {
        let ipParts = localIP.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt32($0) }

        guard ipParts.count == 4, maskParts.count == 4 else { return [] }

        let ip = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let mask = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]

        let network = ip & mask
        let broadcast = network | ~mask

        // Limit scan to /24 or smaller to avoid scanning huge ranges
        let hostCount = broadcast - network
        guard hostCount > 0 && hostCount <= 254 else {
            // For larger networks, just scan first 254 hosts
            var range: [String] = []
            for i: UInt32 in 1...254 {
                let hostIP = network + i
                let a = (hostIP >> 24) & 0xFF
                let b = (hostIP >> 16) & 0xFF
                let c = (hostIP >> 8) & 0xFF
                let d = hostIP & 0xFF
                range.append("\(a).\(b).\(c).\(d)")
            }
            return range
        }

        var range: [String] = []
        for hostIP in (network + 1)..<broadcast {
            let a = (hostIP >> 24) & 0xFF
            let b = (hostIP >> 16) & 0xFF
            let c = (hostIP >> 8) & 0xFF
            let d = hostIP & 0xFF
            range.append("\(a).\(b).\(c).\(d)")
        }
        return range
    }

    private func scanIPRange(_ ips: [String], localIP: String) {
        let group = DispatchGroup()

        for ip in ips {
            guard isScanning else { break }
            // Skip our own IP
            guard ip != localIP else { continue }

            group.enter()
            scanQueue.async { [weak self] in
                defer { group.leave() }
                guard let self, self.isScanning else { return }

                if self.checkSMBPort(ip: ip) {
                    let hostName = self.resolveHostName(ip: ip) ?? ip
                    let hostInfo = SMBHostInfo(ipAddress: ip, name: hostName, port: Int(self.smbPort))

                    self.resultQueue.async {
                        self.discoveredHosts.append(hostInfo)
                        // Notify delegate of progress
                        DispatchQueue.main.async {
                            self.delegate?.smbSubnetScanner(self, didDiscover: self.discoveredHosts)
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finishScanning()
        }
    }

    private func checkSMBPort(ip: String) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }

        // Set non-blocking
        let flags = fcntl(socket, F_GETFL, 0)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = smbPort.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return true
        }

        if errno == EINPROGRESS {
            // Use poll to wait for connection with timeout
            var pfd = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            let timeoutMs = Int32(connectionTimeout * 1000)
            let pollResult = poll(&pfd, 1, timeoutMs)

            if pollResult > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                var error: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &len)
                return error == 0
            }
        }

        return false
    }

    private func resolveHostName(ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, 0)
            }
        }

        if result == 0 {
            let name = String(cString: hostname)
            // Remove .local suffix if present
            if name.hasSuffix(".local") {
                return String(name.dropLast(6))
            }
            // Don't return if it's just the IP address
            if name != ip {
                return name
            }
        }
        return nil
    }

    private func finishScanning() {
        isScanning = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.smbSubnetScannerDidFinish(self)
        }
    }
}

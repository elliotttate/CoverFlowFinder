import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import Photos
import os
import CoreServices

private let zipNavLogger = Logger(subsystem: "com.flowfinder.app", category: "ZipNav")
private let searchDebugLogger = Logger(subsystem: "com.flowfinder.app", category: "SearchDebug")

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

enum SearchMode: String, CaseIterable {
    case filter = "Filter"
    case finder = "Spotlight"

    var placeholder: String {
        switch self {
        case .filter: return "Filter"
        case .finder: return "Spotlight search..."
        }
    }

    var systemImage: String {
        switch self {
        case .filter: return "line.3.horizontal.decrease"
        case .finder: return "magnifyingglass"
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

/// realpath(3): resolves every symlink, including /tmp → /private/tmp
/// (`URL.resolvingSymlinksInPath()` strips /private again).
private func resolvedFilesystemPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Thread-safe cancellation flag for background loads (checked between items instead of
/// hopping to the main thread).
private final class LoadCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Collects results produced on many threads and publishes ordered snapshots on the main queue.
/// Appends are serialized on a private queue and each snapshot is copied there before it is
/// dispatched, so snapshots arrive on main in append order and never shrink.
final class SerialResultAccumulator<Element>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.flowfinder.result-accumulator")
    private var elements: [Element] = []

    func append(_ element: Element, publish: @escaping ([Element]) -> Void) {
        queue.async {
            self.elements.append(element)
            let snapshot = self.elements
            DispatchQueue.main.async {
                publish(snapshot)
            }
        }
    }

    var snapshot: [Element] {
        queue.sync { elements }
    }
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
    @Published var searchMode: SearchMode = .filter
    @Published var filterTag: String? = nil
    @Published var isLoading: Bool = false
    @Published var isSearching: Bool = false

    // Search results for Finder and Everything modes
    @Published var searchResults: [FileItem] = [] {
        didSet {
            searchResultsRevision &+= 1
        }
    }
    private var searchResultsRevision: Int = 0
    private struct SortedSearchResultsCacheKey: Equatable {
        let revision: Int
        let sortState: SortState
        let foldersFirst: Bool
        let tagRefreshToken: Int
    }
    private var sortedSearchResultsCacheKey: SortedSearchResultsCacheKey?
    private var sortedSearchResultsCache: [FileItem] = []

    /// Sorted search results - uses ListColumnConfigManager for consistency with normal file sorting
    /// This means clicking column headers in List View sorts search results too.
    /// Cached per (results, sort state): views read this several times per render.
    var sortedSearchResults: [FileItem] {
        guard !searchResults.isEmpty else {
            sortedSearchResultsStructuralToken = 0
            return []
        }

        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let cacheKey = SortedSearchResultsCacheKey(
            revision: searchResultsRevision,
            sortState: sortState,
            foldersFirst: AppSettings.shared.foldersFirst,
            tagRefreshToken: sortState.column == .tags ? tagRefreshToken : 0
        )
        if sortedSearchResultsCacheKey == cacheKey {
            return sortedSearchResultsCache
        }

        let result = ListColumnConfigManager.sortedItems(searchResults, sortState: sortState, foldersFirst: cacheKey.foldersFirst)
        sortedSearchResultsCacheKey = cacheKey
        sortedSearchResultsCache = result
        sortedSearchResultsStructuralToken = structuralToken(for: result)
        return result
    }
    private var spotlightSearch: SpotlightSearchSession?
    private var spotlightSearchToken = UUID()
    /// Stable IDs for Spotlight results, by path (kept while the search UI stays in use).
    private var spotlightIDsByPath: [String: UUID] = [:]
    /// A Spotlight search was interrupted by suspending background work; rerun it on resume.
    private var searchNeedsRerunOnResume = false
    @Published var navigationHistory: [NavigationLocation] = []
    @Published var historyIndex: Int = -1
    @Published var coverFlowSelectedIndex: Int = 0
    @Published var renamingURL: URL? = nil
    // Navigation generation counter - forces SwiftUI to update on navigation
    @Published var navigationGeneration: Int = 0
    @Published var tagRefreshToken: Int = 0
    weak var undoManager: UndoManager?

    // Track click timing for Finder-style rename triggering
    private var lastClickedURL: URL?
    private var lastClickTime: Date = .distantPast
    private var pendingRenameWorkItem: DispatchWorkItem?
    private let renameDelay: TimeInterval = 0.2

    // Track the folder we entered so we can select it when going back
    private var enteredFolderURL: URL?
    // URL to select after loading (used when going back)
    private var pendingSelectionURL: URL?
    // URLs to select after loading (used for paste operations with multiple files)
    private var pendingSelectionURLs: Set<URL>?
    // URL to select and immediately start renaming (used for new folder creation)
    private var pendingNewFolderRenameURL: URL?

    private let fileOperationQueue = DispatchQueue(label: "com.coverflowfinder.fileops", qos: .userInitiated)
    private struct MoveRecord {
        let from: URL
        let to: URL
    }
    private struct CopyRecord {
        let from: URL
        let to: URL
    }
    private struct TrashRecord {
        let original: URL
        let trashed: URL
    }

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
        /// Tag edits change what the tag filter and the Tags sort produce
        let tagRefreshToken: Int
    }
    private var filteredItemsCacheKey: FilteredItemsCacheKey?
    private var filteredItemsCache: [FileItem] = []
    private var filteredItemsStructuralToken: Int = 0
    private var sortedSearchResultsStructuralToken: Int = 0

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
    private var photosLoadCancellation: LoadCancellationFlag?
    private var photosSortState: SortState?

    private var networkServiceBrowser: NetworkServiceBrowser?
    private var networkServiceIDs: [String: UUID] = [:]
    private var isNetworkBrowsing = false
    private var smbSubnetScanner: SMBSubnetScanner?
    private var discoveredSMBHosts: [SMBHostInfo] = []
    private var isBackgroundWorkActive = true
    private var needsReloadOnResume = false
    /// Set by `tearDown()`; the view model does no further background work.
    private var isTornDown = false

    // MARK: - Lazy Metadata Loading
    /// Batch size for progressive loading of large directories
    private let directoryBatchSize = 400
    /// Token to invalidate in-flight loads when navigating away or reloading
    private var directoryLoadToken = UUID()
    private var directoryLoadCancellation: LoadCancellationFlag?
    /// Key of the location whose complete listing is in `items` (folder path, or archive + internal
    /// path). Reloading the same location diffs into `items` instead of clearing it.
    private var loadedLocationKey: String?
    /// Stable item identities for the current location, by path (see `URL.standardizedPathKey`).
    /// Reset when a different location is loaded.
    private var itemIDsByPath: [String: UUID] = [:]
    /// Whether the current folder is inside iCloud Drive (cloud status is hydrated with metadata)
    private var currentFolderIsInICloud = false
    /// Track which items have had their metadata loaded
    private var hydratedURLs: Set<URL> = []
    /// Track which items have had their cloud status loaded
    private var cloudStatusLoadedURLs: Set<URL> = []
    private var pendingCloudStatusURLs: Set<URL> = []
    /// Flag to prevent redundant reloads during navigation
    private var isNavigating = false
    /// Queue for metadata hydration requests
    private var pendingHydrationURLs: Set<URL> = []
    private let hydrationQueue = DispatchQueue(label: "com.coverflowfinder.hydration", qos: .userInitiated)
    /// Invalidates in-flight metadata/cloud hydration (new folder, suspension)
    private var hydrationToken = UUID()
    private var hydrationCancellation = LoadCancellationFlag()
    /// Lookup of `items` indices by URL, rebuilt lazily when `items` changes
    private var itemIndexCache: (revision: Int, indexByURL: [URL: Int])?
    private var sortChangeWorkScheduled = false
    private var directoryWatcher: DirectoryWatcher?
    /// Path key of the folder (currentPath) the watcher was started for
    private var watchedFolderKey: String?
    private var pendingDirectoryEventPaths: Set<String> = []
    private var pendingDirectoryRescan = false
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
    /// Invalidates in-flight archive reads (ZipArchiveManager.readContents runs off the main thread)
    private var archiveReadToken = UUID()
    /// Token of the archive read that turned on the loading spinner (slow reads only)
    private var archiveReadSpinnerToken: UUID?

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

    /// Order-insensitive token for the currently displayed item set.
    /// Cover Flow uses this to distinguish structural changes from pure reordering.
    var coverFlowItemsToken: Int {
        switch searchMode {
        case .finder:
            if searchText.isEmpty {
                _ = filterCurrentDirectoryItems()
                return filteredItemsStructuralToken
            }
            _ = sortedSearchResults
            return sortedSearchResultsStructuralToken
        case .filter:
            _ = filterCurrentDirectoryItems()
            return filteredItemsStructuralToken
        }
    }

    var filteredItems: [FileItem] {
        // For Finder search mode, return search results
        switch searchMode {
        case .finder:
            // When in search mode, return the search results
            // If search text is empty, show current directory items
            if searchText.isEmpty {
                return filterCurrentDirectoryItems()
            }
            return sortedSearchResults

        case .filter:
            // Don't log filter mode to reduce noise
            return filterCurrentDirectoryItems()
        }
    }

    private func structuralToken(for items: [FileItem]) -> Int {
        var xorValue = 0
        var sumValue = 0

        for item in items {
            let hash = item.url.absoluteString.hashValue
            xorValue ^= hash
            sumValue &+= hash
        }

        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(xorValue)
        hasher.combine(sumValue)
        return hasher.finalize()
    }

    /// Filter items in the current directory (original filter behavior)
    private func filterCurrentDirectoryItems() -> [FileItem] {
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let foldersFirst = AppSettings.shared.foldersFirst
        let tagsMatter = (filterTag != nil && !isInsideArchive) || sortState.column == .tags
        let cacheKey = FilteredItemsCacheKey(
            itemsRevision: itemsRevision,
            searchText: searchMode == .filter ? searchText : "",
            filterTag: filterTag,
            sortState: sortState,
            foldersFirst: foldersFirst,
            tagRefreshToken: tagsMatter ? tagRefreshToken : 0
        )

        if let cachedKey = filteredItemsCacheKey, cachedKey == cacheKey {
            return filteredItemsCache
        }

        // Photos arrive pre-sorted by PhotoKit for date sorts and are shown in library order otherwise
        if photosLibraryInfo != nil,
           searchText.isEmpty,
           filterTag == nil,
           !(sortState.column == .dateCreated || sortState.column == .dateModified) || photosSortState == sortState {
            filteredItemsCacheKey = cacheKey
            filteredItemsCache = items
            filteredItemsStructuralToken = structuralToken(for: items)
            return items
        }

        var filtered = items

        // Filter by search text (only in filter mode)
        if searchMode == .filter && !searchText.isEmpty {
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
        filteredItemsStructuralToken = structuralToken(for: sorted)
        return sorted
    }

    var isPhotosLibraryActive: Bool {
        photosLibraryInfo != nil
    }

    init(initialPath: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentPath = initialPath
        loadContents()
        addToHistory(.filesystem(initialPath))

        // Observe search text changes
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] newText in
                guard let self else { return }
                // Trigger search for Finder/Everything modes
                if self.searchMode != .filter {
                    self.objectWillChange.send()
                    self.performSearch(query: newText)
                } else if !newText.isEmpty {
                    // Filter mode with non-empty text — trigger view update for filtering
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        // Observe search mode changes. @Published emits in willSet, so `self.searchMode` still
        // holds the old mode here — pass the new one explicitly.
        $searchMode
            .dropFirst()
            .sink { [weak self] newMode in
                guard let self else { return }
                // Clear search results when changing modes
                self.searchResults = []
                self.cancelSearch()
                // If switching to a search mode with existing text, trigger search
                if newMode != .filter && !self.searchText.isEmpty {
                    self.performSearch(query: self.searchText, mode: newMode)
                }
            }
            .store(in: &cancellables)

        $filterTag
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                self?.navigationGeneration += 1
            }
            .store(in: &cancellables)

        // Cancel pending rename when drag starts (Finder behavior: dragging cancels rename)
        InternalDragState.shared.$isDragging
            .filter { $0 == true }
            .sink { [weak self] _ in
                self?.cancelPendingRename()
            }
            .store(in: &cancellables)

        let columnConfig = ListColumnConfigManager.shared
        columnConfig.$sortColumn
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()

                // Skip reload during navigation - loadContents will be called with correct sort state
                guard !self.isNavigating else { return }
                self.scheduleSortChangeHandling()
            }
            .store(in: &cancellables)

        columnConfig.$sortDirection
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                guard !self.isNavigating else { return }
                self.scheduleSortChangeHandling()
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

    func setBackgroundWorkActive(_ isActive: Bool) {
        guard !isTornDown, isBackgroundWorkActive != isActive else { return }
        isBackgroundWorkActive = isActive

        if isActive {
            resumeBackgroundWork()
        } else {
            suspendBackgroundWork()
        }
    }

    /// Stops all background activity: directory watching, Spotlight, Bonjour/SMB browsing,
    /// in-flight loads and hydration. Call when the tab or pane that owns this view model
    /// closes; the view model does no background work afterwards.
    func tearDown() {
        guard !isTornDown else { return }
        suspendBackgroundWork()
        isTornDown = true
        isBackgroundWorkActive = false
        needsReloadOnResume = false
        searchNeedsRerunOnResume = false
        directoryWatcher = nil
        networkServiceBrowser = nil
        smbSubnetScanner = nil
        clearPhotosCaches()
        cancellables.removeAll()
    }

    func loadContents() {
        guard isBackgroundWorkActive else {
            needsReloadOnResume = true
            return
        }

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

        let pathToLoad = currentPath
        let locationKey = pathToLoad.standardizedPathKey
        // Reloading the folder that's already shown (refresh, file operations, re-sort, resume)
        // diffs into `items`: no spinner, no cleared list, IDs and selection are kept.
        let isReload = loadedLocationKey == locationKey
        if !isReload {
            beginLoadingNewLocation()
            currentFolderIsInICloud = CloudStatusManager.shared.isInICloud(pathToLoad)
        }
        let listingURL = resolvedListingURL(for: pathToLoad)
        startDirectoryWatcher(for: listingURL)

        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let batchSize = directoryBatchSize
        let existingIDs = itemIDsByPath
        // Keep metadata that was already loaded so hydrated rows don't fall back to "--"
        let idsWithMetadata = Set(items.lazy.filter(\.hasMetadata).map(\.id))
        let loadToken = UUID()
        directoryLoadToken = loadToken
        directoryLoadCancellation?.cancel()
        let cancellation = LoadCancellationFlag()
        directoryLoadCancellation = cancellation
        needsReloadOnResume = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = try? Self.listDirectory(
                at: listingURL,
                showHiddenFiles: showHiddenFiles,
                sortState: sortState,
                batchSize: batchSize,
                existingIDs: existingIDs,
                idsWithMetadata: idsWithMetadata,
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.directoryLoadToken == loadToken,
                      !self.isInsideArchive,
                      self.photosLibraryInfo == nil,
                      self.currentPath.standardizedPathKey == locationKey else { return }
                // An unreadable (or vanished) folder shows as empty
                self.applyListing(listing ?? [], locationKey: locationKey, isReload: isReload)
            }
        }
    }

    /// An item produced off the main thread together with its path key.
    private struct ListedItem {
        let key: String
        let item: FileItem
    }

    /// Lists a folder (off the main thread). Small folders, and folders sorted by date or size,
    /// load full metadata up front; large ones load it lazily for visible rows. IDs are reused
    /// per path and items that already had metadata keep it.
    nonisolated private static func listDirectory(
        at listingURL: URL,
        showHiddenFiles: Bool,
        sortState: SortState,
        batchSize: Int,
        existingIDs: [String: UUID],
        idsWithMetadata: Set<UUID>,
        cancellation: LoadCancellationFlag
    ) throws -> [ListedItem] {
        // Special handling for autofs mount points like /Network
        // These require triggering the automounter before listing
        if listingURL.path == "/Network" || listingURL.path.hasPrefix("/Network/") {
            // Trigger automounter by attempting to access the path, then give it a moment
            _ = FileManager.default.fileExists(atPath: listingURL.path)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // contentsOfDirectory(at:) doesn't follow a symlink in the last path component: list the
        // link's target, but keep the children under the link's path (browsed where it's listed)
        var directoryToList = listingURL
        var info = stat()
        if lstat(listingURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            directoryToList = URL(fileURLWithPath: resolvedFilesystemPath(listingURL.path), isDirectory: true)
        }

        // Phase 1: Get file list instantly (no stat calls)
        var contents: [URL] = try autoreleasepool {
            try FileManager.default.contentsOfDirectory(
                at: directoryToList,
                includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey],
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
        }
        if directoryToList != listingURL {
            contents = contents.map { listingURL.appendingPathComponent($0.lastPathComponent, isDirectory: $0.hasDirectoryPath) }
        }

        // Phase 2: Create items. If sorting by date or size we MUST load metadata to sort correctly.
        let loadMetadataUpfront = contents.count <= batchSize || sortStateRequiresMetadata(sortState)
        var listed: [ListedItem] = []
        listed.reserveCapacity(contents.count)
        for (index, url) in contents.enumerated() {
            if index % batchSize == 0, cancellation.isCancelled {
                throw CancellationError()
            }
            let key = url.standardizedPathKey
            let existingID = existingIDs[key]
            let loadMetadata = loadMetadataUpfront || existingID.map(idsWithMetadata.contains) == true
            let item = autoreleasepool {
                FileItem(url: url, id: existingID ?? UUID(), loadMetadata: loadMetadata)
            }
            listed.append(ListedItem(key: key, item: item))
        }
        return listed
    }

    /// Clears per-location state before loading a different location (shows the spinner).
    private func beginLoadingNewLocation() {
        isLoading = true
        loadedLocationKey = nil
        items = []
        itemIDsByPath.removeAll()
        hydratedURLs.removeAll()
        cloudStatusLoadedURLs.removeAll()
        currentFolderIsInICloud = false
        resetHydrationState()
    }

    /// Applies a completed listing. A first load replaces `items`; a reload of the same location
    /// merges into them (see `mergeReloadedItems`).
    private func applyListing(_ listed: [ListedItem], locationKey: String, isReload: Bool) {
        // IDs registered on main win: a directory event may have added a path meanwhile
        let reconciled = listed.map { entry -> FileItem in
            if let registered = itemIDsByPath[entry.key] {
                return registered == entry.item.id ? entry.item : entry.item.withID(registered)
            }
            itemIDsByPath[entry.key] = entry.item.id
            return entry.item
        }

        if isReload {
            mergeReloadedItems(reconciled)
        } else {
            items = reconciled
            navigationGeneration += 1
        }
        for item in reconciled where item.hasMetadata {
            hydratedURLs.insert(item.url)
        }
        if isLoading {
            isLoading = false
        }
        loadedLocationKey = locationKey
        if itemIDsByPath.count > 2 * items.count + 1_000 {
            pruneItemIDs()
        }

        applySelectionAfterLoad()
        triggerPendingNewFolderRename()
        if currentFolderIsInICloud, items.count <= directoryBatchSize {
            hydrateCloudStatus(for: items.map(\.url))
        }
    }

    /// Merges a reloaded listing into `items` without disturbing what's on screen: existing
    /// items keep their position and identity (updated in place when their metadata changed),
    /// vanished ones are removed and new ones appended. `items` is only reassigned when
    /// something actually changed.
    private func mergeReloadedItems(_ listed: [FileItem]) {
        var listedByID = [UUID: FileItem](minimumCapacity: listed.count)
        for item in listed {
            listedByID[item.id] = item
        }

        var merged: [FileItem] = []
        merged.reserveCapacity(listed.count)
        var changed = false
        for old in items {
            guard let new = listedByID.removeValue(forKey: old.id) else {
                // Gone
                changed = true
                hydratedURLs.remove(old.url)
                pendingHydrationURLs.remove(old.url)
                cloudStatusLoadedURLs.remove(old.url)
                continue
            }
            // Keep the known cloud status until it's re-hydrated
            let updated = new.cloudStatus == nil && old.cloudStatus != nil ? new.withCloudStatus(old.cloudStatus) : new
            if Self.displaysIdentically(old, updated) {
                merged.append(old)
            } else {
                merged.append(updated)
                changed = true
            }
        }
        if !listedByID.isEmpty {
            changed = true
            for item in listed where listedByID[item.id] != nil {
                merged.append(item)
            }
        }

        if changed {
            items = merged
        }
    }

    nonisolated private static func displaysIdentically(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.url == rhs.url &&
        lhs.contentVersion == rhs.contentVersion &&
        lhs.isDirectory == rhs.isDirectory &&
        lhs.fileType == rhs.fileType &&
        lhs.kindDescription == rhs.kindDescription
    }

    /// Drops remembered IDs for paths that no longer exist (bounded growth across reloads).
    private func pruneItemIDs() {
        let liveIDs = Set(items.map(\.id))
        itemIDsByPath = itemIDsByPath.filter { liveIDs.contains($0.value) }
    }

    /// After a load: applies a pending selection (paste, new folder, Back, path bar) or re-points
    /// the existing selection at the reloaded items. A pending selection is consumed by the load
    /// whether or not its item was found, so it can't select something in a later load.
    private func applySelectionAfterLoad() {
        let pendingURLs = pendingSelectionURLs
        let pendingURL = pendingSelectionURL
        pendingSelectionURLs = nil
        pendingSelectionURL = nil

        var targetKeys: [String] = []
        if let pendingURLs, !pendingURLs.isEmpty {
            targetKeys = pendingURLs.map(\.standardizedPathKey)
        } else if let pendingURL {
            targetKeys = [pendingURL.standardizedPathKey]
        }
        let targetIDs = Set(targetKeys.compactMap { itemIDsByPath[$0] })
        let matched = targetIDs.isEmpty ? [] : items.filter { targetIDs.contains($0.id) }

        if !matched.isEmpty {
            selectedItems = Set(matched)
            if let index = filteredItems.firstIndex(where: { targetIDs.contains($0.id) }) {
                coverFlowSelectedIndex = index
                lastSelectedIndex = index
                selectionAnchorIndex = index
            }
        } else {
            refreshSelectedItems()
            let clampedIndex = min(coverFlowSelectedIndex, max(0, items.count - 1))
            if clampedIndex != coverFlowSelectedIndex {
                coverFlowSelectedIndex = clampedIndex
            }
        }
    }

    /// Points the selection at the current versions of the selected items (fresh metadata) and
    /// drops items of this location that no longer exist. Publishes only when something changed.
    private func refreshSelectedItems() {
        guard !selectedItems.isEmpty else { return }
        let indexByURL = itemIndexByURL()
        let locationKey = isInsideArchive ? nil : currentPath.standardizedPathKey
        var updated = Set<FileItem>()
        var changed = false
        for item in selectedItems {
            if let index = indexByURL[item.url] {
                let current = items[index]
                updated.insert(current)
                if current.id != item.id || current.contentVersion != item.contentVersion {
                    changed = true
                }
            } else if item.isFromArchive || item.url.deletingLastPathComponent().standardizedPathKey == locationKey {
                // Was listed here and is gone
                changed = true
            } else {
                // e.g. a Spotlight result from another folder
                updated.insert(item)
            }
        }
        if changed {
            selectedItems = updated
        }
    }

    /// Index of `items` by URL, rebuilt lazily when `items` changes.
    private func itemIndexByURL() -> [URL: Int] {
        if let cache = itemIndexCache, cache.revision == itemsRevision {
            return cache.indexByURL
        }
        var indexByURL = [URL: Int](minimumCapacity: items.count)
        for (offset, item) in items.enumerated() {
            indexByURL[item.url] = offset
        }
        itemIndexCache = (itemsRevision, indexByURL)
        return indexByURL
    }

    /// Handles a sort column/direction change on the next run-loop turn: `@Published` emits in
    /// willSet and `setSortColumn` sets the column and then the direction, so the final sort
    /// state is only readable afterwards.
    private func scheduleSortChangeHandling() {
        guard !sortChangeWorkScheduled else { return }
        sortChangeWorkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sortChangeWorkScheduled = false
            self.handleSortChange()
        }
    }

    private func handleSortChange() {
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        guard Self.sortStateRequiresMetadata(sortState),
              !isInsideArchive,
              photosLibraryInfo == nil,
              !isNetworkBrowsing else { return }
        guard loadedLocationKey != nil else {
            // Restart an in-flight first load so it loads metadata for the new sort
            if isLoading {
                loadContents()
            }
            return
        }
        // Sorting by date/size needs metadata for every item: reload in place with metadata
        // (one re-sort, no cleared list) instead of reshuffling rows as visible ones hydrate.
        if items.contains(where: { !$0.hasMetadata }) {
            loadContents()
        }
    }

    private func loadNetworkContents() {
        guard isBackgroundWorkActive else {
            needsReloadOnResume = true
            return
        }

        stopNetworkBrowsing()
        isNetworkBrowsing = true
        beginLoadingNewLocation()
        navigationGeneration += 1
        discoveredSMBHosts = []

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

    private func suspendBackgroundWork() {
        needsReloadOnResume = needsReloadOnResume || isLoading
        searchNeedsRerunOnResume = searchNeedsRerunOnResume || (isSearching && spotlightSearch != nil)
        isLoading = false
        directoryLoadToken = UUID()
        directoryLoadCancellation?.cancel()
        directoryLoadCancellation = nil
        photosLoadToken = UUID()
        photosLoadCancellation?.cancel()
        photosLoadCancellation = nil
        archiveReadToken = UUID()
        // In-flight hydration is dropped; forget it so visible rows are requested again on resume
        resetHydrationState()
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        pendingNewFolderRenameURL = nil
        stopDirectoryWatcher()
        stopNetworkBrowsing()
        cancelSearch()
    }

    private func resumeBackgroundWork() {
        needsReloadOnResume = false
        // Always re-list: changes made while suspended weren't watched. Reloading the location
        // that's already shown is incremental, so scroll position and selection are kept.
        loadContents()
        if searchNeedsRerunOnResume {
            searchNeedsRerunOnResume = false
            if searchMode == .finder, !searchText.isEmpty {
                performSearch(query: searchText)
            }
        }
    }

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

    /// Request metadata loading for specific items (call from visible row detection).
    /// In iCloud folders this also loads the items' cloud status (badges, iCloud column,
    /// Download/Remove Download), so views only need to call this one API.
    func hydrateMetadata(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let indexByURL = itemIndexByURL()
        var metadataURLs: [URL] = []
        var cloudURLs: [URL] = []
        var idByURL: [URL: UUID] = [:]
        for url in urls {
            guard let index = indexByURL[url] else { continue }
            let item = items[index]
            if !item.hasMetadata, !hydratedURLs.contains(url), !pendingHydrationURLs.contains(url) {
                metadataURLs.append(url)
                idByURL[url] = item.id
            }
            if needsCloudStatus(url) {
                cloudURLs.append(url)
            }
        }

        if !cloudURLs.isEmpty {
            hydrateCloudStatus(for: cloudURLs)
        }
        guard !metadataURLs.isEmpty else { return }
        pendingHydrationURLs.formUnion(metadataURLs)

        let token = hydrationToken
        let cancellation = hydrationCancellation
        hydrationQueue.async { [weak self] in
            var hydratedItems: [FileItem] = []
            hydratedItems.reserveCapacity(metadataURLs.count)
            for url in metadataURLs {
                guard !cancellation.isCancelled else { return }
                hydratedItems.append(FileItem(url: url, id: idByURL[url] ?? UUID(), loadMetadata: true))
            }

            // Batch update on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hydrationToken == token else { return }
                self.applyHydratedItems(hydratedItems)
            }
        }
    }

    private func applyHydratedItems(_ hydratedItems: [FileItem]) {
        var updatedItems = items
        let indexByURL = itemIndexByURL()
        var didUpdate = false

        for hydratedItem in hydratedItems {
            pendingHydrationURLs.remove(hydratedItem.url)
            hydratedURLs.insert(hydratedItem.url)

            // Replace item in-place, keeping its identity and the cloud status loaded so far
            guard let index = indexByURL[hydratedItem.url] else { continue }
            let existing = updatedItems[index]
            var replacement = existing.id == hydratedItem.id ? hydratedItem : hydratedItem.withID(existing.id)
            if replacement.cloudStatus == nil {
                replacement.cloudStatus = existing.cloudStatus
            }
            updatedItems[index] = replacement
            didUpdate = true
        }

        if didUpdate {
            items = updatedItems
            refreshSelectedItems()
            // Post notification so table view can force reload of visible rows
            NotificationCenter.default.post(name: .metadataHydrationCompleted, object: self)
        }
    }

    /// Check if an item needs hydration: metadata, or (in iCloud folders) its cloud status.
    /// Views pass the URLs of items for which this is true to `hydrateMetadata(for:)`.
    func needsHydration(_ item: FileItem) -> Bool {
        (!item.hasMetadata && !hydratedURLs.contains(item.url)) || needsCloudStatus(item.url)
    }

    private func needsCloudStatus(_ url: URL) -> Bool {
        currentFolderIsInICloud &&
        !isInsideArchive &&
        !cloudStatusLoadedURLs.contains(url) &&
        !pendingCloudStatusURLs.contains(url)
    }

    /// Forget in-flight metadata/cloud hydration (new location, suspension). Rows that were
    /// pending are requested again by the views.
    private func resetHydrationState() {
        hydrationCancellation.cancel()
        hydrationCancellation = LoadCancellationFlag()
        hydrationToken = UUID()
        pendingHydrationURLs.removeAll()
        pendingCloudStatusURLs.removeAll()
    }

    // MARK: - Cloud Status Hydration

    /// Request cloud status loading for specific items. `hydrateMetadata(for:)` calls this for
    /// iCloud folders, and loads call it for small iCloud folders.
    func hydrateCloudStatus(for urls: [URL]) {
        let urlsToHydrate = urls.filter {
            !cloudStatusLoadedURLs.contains($0) &&
            !pendingCloudStatusURLs.contains($0) &&
            CloudStatusManager.shared.isInICloud($0)
        }
        guard !urlsToHydrate.isEmpty else { return }
        pendingCloudStatusURLs.formUnion(urlsToHydrate)

        let token = hydrationToken
        let cancellation = hydrationCancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updates: [(URL, CloudSyncStatus)] = []
            updates.reserveCapacity(urlsToHydrate.count)
            for url in urlsToHydrate {
                guard !cancellation.isCancelled else { return }
                updates.append((url, CloudStatusManager.shared.getStatus(for: url)))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.hydrationToken == token else { return }

                var updatedItems = self.items
                let indexByURL = self.itemIndexByURL()
                var didUpdate = false

                for (url, status) in updates {
                    self.pendingCloudStatusURLs.remove(url)
                    self.cloudStatusLoadedURLs.insert(url)
                    if let index = indexByURL[url], updatedItems[index].cloudStatus != status {
                        updatedItems[index] = updatedItems[index].withCloudStatus(status)
                        didUpdate = true
                    }
                }

                if didUpdate {
                    self.items = updatedItems
                    self.refreshSelectedItems()
                    NotificationCenter.default.post(name: .cloudStatusHydrationCompleted, object: self)
                }
            }
        }
    }

    /// Download an iCloud item to make it available locally
    func downloadCloudItem(_ item: FileItem) {
        guard item.cloudStatus?.canDownload == true else { return }

        do {
            try CloudStatusManager.shared.downloadItem(at: item.url)
            // Refresh the item's status
            cloudStatusLoadedURLs.remove(item.url)
            hydrateCloudStatus(for: [item.url])
        } catch {
            // Show error alert
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Download Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Evict (remove local copy of) an iCloud item to free up space
    func evictCloudItem(_ item: FileItem) {
        guard item.cloudStatus?.canEvict == true else { return }

        do {
            try CloudStatusManager.shared.evictItem(at: item.url)
            // Refresh the item's status
            cloudStatusLoadedURLs.remove(item.url)
            hydrateCloudStatus(for: [item.url])
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Remove Download Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - Directory Watching

    private func startDirectoryWatcher(for url: URL) {
        let folderKey = currentPath.standardizedPathKey
        let watchPath = url.standardizedPathKey
        if watchedFolderKey == folderKey, directoryWatcher?.watchedPath == watchPath { return }
        if directoryWatcher == nil {
            directoryWatcher = DirectoryWatcher { [weak self] paths, needsRescan, watchedPath in
                self?.queueDirectoryEvents(paths, needsRescan: needsRescan, watchedPath: watchedPath)
            }
        }
        watchedFolderKey = folderKey
        directoryWatcher?.start(watching: watchPath)
    }

    private func stopDirectoryWatcher() {
        watchedFolderKey = nil
        directoryEventWorkItem?.cancel()
        directoryEventWorkItem = nil
        pendingDirectoryEventPaths.removeAll()
        pendingDirectoryRescan = false
        directoryWatcher?.stop()
    }

    /// `paths` are direct children of the watched folder, already mapped to the folder's
    /// displayed path form (FSEvents reports resolved paths, e.g. /private/tmp for /tmp).
    private func queueDirectoryEvents(_ paths: [String], needsRescan: Bool, watchedPath: String) {
        guard !isTornDown, !isInsideArchive, photosLibraryInfo == nil else { return }
        guard let folderKey = watchedFolderKey,
              folderKey == currentPath.standardizedPathKey,
              directoryWatcher?.watchedPath == watchedPath else { return }
        guard needsRescan || !paths.isEmpty else { return }

        pendingDirectoryEventPaths.formUnion(paths)
        pendingDirectoryRescan = pendingDirectoryRescan || needsRescan
        scheduleDirectoryEventProcessing()
    }

    private func scheduleDirectoryEventProcessing() {
        directoryEventWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processDirectoryEvents()
        }
        directoryEventWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + directoryEventDebounce, execute: workItem)
    }

    private func processDirectoryEvents() {
        if isLoading {
            // Apply after the first load of this folder completes
            scheduleDirectoryEventProcessing()
            return
        }
        let paths = pendingDirectoryEventPaths
        let needsRescan = pendingDirectoryRescan
        pendingDirectoryEventPaths.removeAll()
        pendingDirectoryRescan = false

        if needsRescan {
            // FSEvents dropped or coalesced events: re-list (incremental)
            loadContents()
        } else {
            applyDirectoryEventUpdates(for: paths)
        }
    }

    private enum DirectoryEventChange {
        case removed(key: String)
        case present(key: String, item: FileItem)
    }

    /// Re-reads the changed paths off the main thread and applies the result on main.
    private func applyDirectoryEventUpdates(for paths: Set<String>) {
        guard !paths.isEmpty,
              let locationKey = loadedLocationKey,
              locationKey == currentPath.standardizedPathKey,
              !isInsideArchive, photosLibraryInfo == nil else { return }

        let showHidden = AppSettings.shared.showHiddenFiles
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let shouldLoadMetadata = items.count <= directoryBatchSize || Self.sortStateRequiresMetadata(sortState)
        var existingIDs: [String: UUID] = [:]
        for path in paths {
            existingIDs[path] = itemIDsByPath[path]
        }
        let affectedIDs = Set(existingIDs.values)
        let idsWithMetadata = Set(items.lazy.filter { affectedIDs.contains($0.id) && $0.hasMetadata }.map(\.id))
        // Build URLs the way the listing does (same base, e.g. /private/tmp rather than /tmp)
        let listingURL = resolvedListingURL(for: currentPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var changes: [DirectoryEventChange] = []
            var tagsChanged = false
            for path in paths {
                var info = stat()
                guard lstat(path, &info) == 0 else {
                    changes.append(.removed(key: path))
                    continue
                }
                let url = listingURL.appendingPathComponent((path as NSString).lastPathComponent)
                if !showHidden,
                   url.lastPathComponent.hasPrefix(".") || (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true {
                    changes.append(.removed(key: path))
                    continue
                }

                // Tags may have been edited elsewhere (e.g. in Finder): drop the cached value and
                // tell the views if what they showed is now different.
                let cachedTags = FileTagManager.cachedTags(for: url)
                FileTagManager.invalidateCache(for: url)
                if let cachedTags, FileTagManager.getTags(for: url) != cachedTags {
                    tagsChanged = true
                }

                let existingID = existingIDs[path]
                let loadMetadata = shouldLoadMetadata || existingID.map(idsWithMetadata.contains) == true
                let item = FileItem(url: url, id: existingID ?? UUID(), loadMetadata: loadMetadata)
                changes.append(.present(key: path, item: item))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.loadedLocationKey == locationKey,
                      self.currentPath.standardizedPathKey == locationKey,
                      !self.isInsideArchive,
                      self.photosLibraryInfo == nil else { return }
                self.applyDirectoryChanges(changes, tagsChanged: tagsChanged)
            }
        }
    }

    private func applyDirectoryChanges(_ changes: [DirectoryEventChange], tagsChanged: Bool) {
        var updatedItems = items
        var indexByID = [UUID: Int](minimumCapacity: updatedItems.count)
        for (offset, item) in updatedItems.enumerated() {
            indexByID[item.id] = offset
        }
        var removedIDs = Set<UUID>()
        var cloudURLsToRefresh: [URL] = []
        var changed = false

        for change in changes {
            switch change {
            case .removed(let key):
                if let id = itemIDsByPath[key], indexByID[id] != nil {
                    removedIDs.insert(id)
                }
            case .present(let key, let newItem):
                let id: UUID
                if let registered = itemIDsByPath[key] {
                    id = registered
                } else {
                    id = newItem.id
                    itemIDsByPath[key] = id
                }
                var item = newItem.id == id ? newItem : newItem.withID(id)
                removedIDs.remove(id)
                if let index = indexByID[id] {
                    let existing = updatedItems[index]
                    if item.cloudStatus == nil {
                        item.cloudStatus = existing.cloudStatus
                    }
                    if !Self.displaysIdentically(existing, item) {
                        updatedItems[index] = item
                        changed = true
                    }
                } else {
                    indexByID[id] = updatedItems.count
                    updatedItems.append(item)
                    changed = true
                }
                if item.hasMetadata {
                    hydratedURLs.insert(item.url)
                }
                if currentFolderIsInICloud {
                    cloudURLsToRefresh.append(item.url)
                }
            }
        }

        if !removedIDs.isEmpty {
            for item in updatedItems where removedIDs.contains(item.id) {
                hydratedURLs.remove(item.url)
                pendingHydrationURLs.remove(item.url)
                cloudStatusLoadedURLs.remove(item.url)
            }
            updatedItems.removeAll { removedIDs.contains($0.id) }
            changed = true
        }

        if changed {
            items = updatedItems
            refreshSelectedItems()
            // NOTE: Don't increment navigationGeneration here - incremental updates
            // should not cause full view recreation which loses scroll position
        }
        if tagsChanged {
            tagRefreshToken &+= 1
        }
        if !cloudURLsToRefresh.isEmpty {
            for url in cloudURLsToRefresh {
                CloudStatusManager.shared.invalidateCache(for: url)
                cloudStatusLoadedURLs.remove(url)
            }
            hydrateCloudStatus(for: cloudURLsToRefresh)
        }
    }

    nonisolated private static func sortStateRequiresMetadata(_ sortState: SortState) -> Bool {
        switch sortState.column {
        case .dateModified, .dateCreated, .size:
            return true
        default:
            return false
        }
    }

    /// Load contents from within a ZIP archive (the listing is built off the main thread)
    private func loadArchiveContents() {
        guard let archiveURL = currentArchiveURL else {
            isInsideArchive = false
            currentArchivePath = ""
            archiveEntries = []
            loadContents()
            return
        }

        let archivePath = currentArchivePath
        let locationKey = "\(archiveURL.standardizedPathKey)#\(archivePath)"
        let isReload = loadedLocationKey == locationKey
        if !isReload {
            beginLoadingNewLocation()
        }

        let entries = archiveEntries
        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let loadToken = UUID()
        directoryLoadToken = loadToken
        directoryLoadCancellation?.cancel()
        directoryLoadCancellation = nil
        needsReloadOnResume = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Get entries at the current path within the archive
            let entriesAtPath = ZipArchiveManager.shared.entriesAtPath(archivePath, in: entries)
            var fileItems = ZipArchiveManager.shared.fileItems(from: entriesAtPath, archiveURL: archiveURL)
            if !showHiddenFiles {
                fileItems = fileItems.filter { !$0.name.hasPrefix(".") }
            }
            let listed = fileItems.map { ListedItem(key: $0.url.standardizedPathKey, item: $0) }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.directoryLoadToken == loadToken,
                      self.isInsideArchive,
                      self.currentArchiveURL == archiveURL,
                      self.currentArchivePath == archivePath else { return }
                self.applyListing(listed, locationKey: locationKey, isReload: isReload)
            }
        }
    }

    private func loadPhotosLibraryContents(info: PhotosLibraryInfo) {
        beginLoadingNewLocation()
        let infoSnapshot = info
        let pendingURL = pendingSelectionURL
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let useOriginalFilenames = AppSettings.shared.masonryShowFilenames
        let loadToken = UUID()
        photosLoadToken = loadToken
        photosLoadCancellation?.cancel()
        let cancellation = LoadCancellationFlag()
        photosLoadCancellation = cancellation

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
                let isComplete = totalCount <= initialCount
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
                    } else if isComplete {
                        self.pendingSelectionURL = nil
                    }

                    self.items = initialBatch.items
                    self.isLoading = false
                    self.navigationGeneration += 1
                    if totalCount == 0 {
                        self.photosLogger.warning("Photos load completed with 0 items (status: \(status.rawValue))")
                    }
                }

                guard !isComplete else { return }

                // Publish the rest in a few large chunks: every publish re-renders the whole grid,
                // so appending each 400-item batch would redo that work hundreds of times.
                var pendingItems: [FileItem] = []
                var pendingAssetCache: [String: PHAsset] = [:]
                var pendingRatioCache: [String: CGFloat] = [:]
                var pendingSelectedItem: FileItem?
                var lastPublish = Date()

                for start in stride(from: initialCount, to: totalCount, by: batchSize) {
                    guard !cancellation.isCancelled else { return }
                    let range = start..<min(start + batchSize, totalCount)
                    let batch = buildBatch(range: range)
                    pendingItems.append(contentsOf: batch.items)
                    pendingAssetCache.merge(batch.assetCache) { current, _ in current }
                    pendingRatioCache.merge(batch.ratioCache) { current, _ in current }
                    pendingSelectedItem = pendingSelectedItem ?? batch.selectedItem

                    let isLastBatch = range.upperBound >= totalCount
                    guard isLastBatch || pendingItems.count >= 5_000 || Date().timeIntervalSince(lastPublish) >= 0.5 else { continue }

                    let chunkItems = pendingItems
                    let chunkAssetCache = pendingAssetCache
                    let chunkRatioCache = pendingRatioCache
                    let chunkSelectedItem = pendingSelectedItem
                    pendingItems = []
                    pendingAssetCache = [:]
                    pendingRatioCache = [:]
                    pendingSelectedItem = nil
                    lastPublish = Date()

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let infoMatches = self.photosLibraryInfo == infoSnapshot
                        let pathMatches = self.currentPath == infoSnapshot.libraryURL
                        let tokenMatches = self.photosLoadToken == loadToken
                        guard infoMatches, pathMatches, tokenMatches else { return }

                        self.photosAssetCache.merge(chunkAssetCache) { current, _ in current }
                        self.photosAspectRatioCache.merge(chunkRatioCache) { current, _ in current }
                        self.items.append(contentsOf: chunkItems)

                        if self.pendingSelectionURL != nil, let item = chunkSelectedItem {
                            self.selectedItems = [item]
                            self.pendingSelectionURL = nil
                        }
                        if isLastBatch {
                            // Consumed by this load whether or not it was found
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
        photosLoadCancellation?.cancel()
        photosLoadCancellation = nil
    }

    private func refreshFinderSearchScopeIfNeeded() {
        guard searchMode == .finder, !searchText.isEmpty else { return }
        searchResults = []
        performSearch(query: searchText)
    }

    private func clearFinderSearchIfNeeded() {
        guard searchMode == .finder, !searchText.isEmpty else { return }
        clearSearchQuery()
    }

    // MARK: - Navigation

    /// Bookkeeping before leaving the current location: stops inline previews, saves the
    /// folder's column state and resets per-folder selection state.
    private func prepareForNavigation() {
        InlinePreviews.stopAll()
        cancelPendingRename()
        if !isInsideArchive, photosLibraryInfo == nil, currentPath.path != "/Network" {
            ListColumnConfigManager.shared.saveCurrentStateForFolder(currentPath, appSettings: AppSettings.shared)
        }
        archiveReadToken = UUID()
        selectedItems.removeAll()
        lastSelectedIndex = 0
        selectionAnchorIndex = 0
        pendingSelectionURL = nil
        pendingSelectionURLs = nil
        pendingNewFolderRenameURL = nil
    }

    private func resetArchiveState() {
        isInsideArchive = false
        currentArchiveURL = nil
        currentArchivePath = ""
        archiveEntries = []
    }

    /// Applies the folder's saved column state without the sort sink reloading (a load follows).
    private func applyFolderColumnState(for url: URL) {
        isNavigating = true
        ListColumnConfigManager.shared.applyPerFolderState(for: url, appSettings: AppSettings.shared)
        isNavigating = false
    }

    /// Whether `url` is the folder that's already shown. Inside an archive or the Photos
    /// library `currentPath` names the enclosing folder, so that never counts.
    private func isShowingFolder(_ url: URL) -> Bool {
        !isInsideArchive && photosLibraryInfo == nil && url.standardizedPathKey == currentPath.standardizedPathKey
    }

    /// Navigates to a folder, leaving archive / Photos browsing if needed.
    func navigateTo(_ url: URL) {
        guard !isShowingFolder(url) else { return }

        prepareForNavigation()
        resetArchiveState()
        photosLibraryInfo = nil
        clearPhotosCaches()
        currentPath = url
        coverFlowSelectedIndex = 0
        applyFolderColumnState(for: url)
        loadContents()
        refreshFinderSearchScopeIfNeeded()
        addToHistory(.filesystem(url))
    }

    /// Navigate to a URL and select the item we came from (path bar, window title menu,
    /// leaving an archive). Leaves archive / Photos browsing in a single history step, so callers
    /// don't need to call `exitArchive()` first.
    func navigateToAndSelectCurrent(_ url: URL) {
        guard !isShowingFolder(url) else { return }
        let origin: URL? = isInsideArchive ? currentArchiveURL : (photosLibraryInfo == nil ? currentPath : nil)

        prepareForNavigation()
        resetArchiveState()
        photosLibraryInfo = nil
        clearPhotosCaches()
        // Select the child of the target on the way to where we were (the folder or archive itself
        // when going to its parent)
        pendingSelectionURL = origin.flatMap { Self.childURL(of: url, leadingTo: $0) }
        currentPath = url
        // Note: Don't reset coverFlowSelectedIndex here - let loadContents set the correct index
        applyFolderColumnState(for: url)
        loadContents()
        refreshFinderSearchScopeIfNeeded()
        addToHistory(.filesystem(url))
    }

    /// The child of `ancestor` on the way to `descendant` ("/a" and "/a/b/c" → "/a/b"), or nil.
    nonisolated static func childURL(of ancestor: URL, leadingTo descendant: URL) -> URL? {
        let ancestorPath = ancestor.standardizedPathKey
        let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
        let descendantPath = descendant.standardizedPathKey
        guard descendantPath.hasPrefix(prefix),
              let component = descendantPath.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return URL(fileURLWithPath: prefix + component)
    }

    func navigateToPhotosLibrary(_ info: PhotosLibraryInfo) {
        prepareForNavigation()
        clearFinderSearchIfNeeded()
        clearPhotosCaches()
        photosLibraryInfo = info
        photosLogger.info("Navigate to Photos library: \(info.libraryURL.path, privacy: .public)")
        resetArchiveState()
        currentPath = info.libraryURL
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
        // Going back to a folder selects the folder (or archive) we're leaving
        let selection = enteredFolderURL ?? (isInsideArchive ? currentArchiveURL : currentPath)
        historyIndex -= 1
        let location = navigationHistory[historyIndex]
        enteredFolderURL = nil
        if case .filesystem = location {
            applyNavigationLocation(location, selecting: selection)
        } else {
            applyNavigationLocation(location, selecting: nil)
        }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        applyNavigationLocation(navigationHistory[historyIndex], selecting: nil)
    }

    private func applyNavigationLocation(_ location: NavigationLocation, selecting selection: URL?) {
        switch location {
        case .filesystem(let url):
            prepareForNavigation()
            resetArchiveState()
            photosLibraryInfo = nil
            clearPhotosCaches()
            pendingSelectionURL = selection
            currentPath = url
            applyFolderColumnState(for: url)
            loadContents()
            refreshFinderSearchScopeIfNeeded()
        case .archive(let archiveURL, let internalPath):
            if currentArchiveURL == archiveURL, !archiveEntries.isEmpty {
                showArchive(archiveURL, entries: archiveEntries, at: internalPath)
                return
            }
            InlinePreviews.stopAll()
            readArchiveEntries(at: archiveURL) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let entries):
                    self.showArchive(archiveURL, entries: entries, at: internalPath)
                case .failure(let error):
                    zipNavLogger.error("Failed to restore archive state: \(error.localizedDescription)")
                    self.applyNavigationLocation(.filesystem(archiveURL.deletingLastPathComponent()), selecting: archiveURL)
                }
            }
        case .photosLibrary(let info):
            prepareForNavigation()
            clearFinderSearchIfNeeded()
            resetArchiveState()
            photosLibraryInfo = info
            photosLogger.info("Apply navigation to Photos library: \(info.libraryURL.path, privacy: .public)")
            currentPath = info.libraryURL
            coverFlowSelectedIndex = 0
            loadContents()
        }
    }

    /// Shows a location inside an archive whose entries are already read.
    private func showArchive(_ archiveURL: URL, entries: [ZipEntry], at internalPath: String) {
        prepareForNavigation()
        photosLibraryInfo = nil
        clearPhotosCaches()
        archiveEntries = entries
        currentArchiveURL = archiveURL
        currentArchivePath = internalPath
        currentPath = archiveURL.deletingLastPathComponent()
        isInsideArchive = true
        coverFlowSelectedIndex = 0
        loadContents()
    }

    /// Reads an archive's entries off the main thread; the spinner only shows if that takes a while.
    private func readArchiveEntries(at archiveURL: URL, completion: @escaping (Result<[ZipEntry], Error>) -> Void) {
        let token = UUID()
        archiveReadToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Still reading (the token is replaced when the read completes or is superseded)
            guard let self, self.archiveReadToken == token else { return }
            self.archiveReadSpinnerToken = token
            self.isLoading = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ZipArchiveManager.shared.readContents(of: archiveURL) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.archiveReadToken == token else { return }
                self.archiveReadToken = UUID()
                if case .failure = result, self.archiveReadSpinnerToken == token {
                    self.isLoading = false
                }
                self.archiveReadSpinnerToken = nil
                completion(result)
            }
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

        // Finder aliases are resolved when opened
        if item.isAliasFile {
            openAlias(at: item.url)
            return
        }

        // Packages/bundles (like .app) are opened, not navigated into. Symlinks to folders are
        // directories here (FileItem classifies them by target) and are browsed under their own path.
        if item.isPackage || NSWorkspace.shared.isFilePackage(atPath: item.url.path) {
            NSWorkspace.shared.open(item.url)
        } else if item.isDirectory {
            enterFolder(item.url, from: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Navigate into a folder; `itemURL` is selected when going Back.
    private func enterFolder(_ url: URL, from itemURL: URL) {
        // Clear search when navigating to a folder from search results
        if searchMode != .filter && !searchText.isEmpty {
            searchText = ""
            searchResults = []
        }
        enteredFolderURL = itemURL
        navigateTo(url)
    }

    /// Resolves a Finder alias (off the main thread: it may have to reach another volume) and
    /// browses into it when it points to a folder, otherwise opens the original.
    private func openAlias(at aliasURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolvedURL = try? URL(resolvingAliasFileAt: aliasURL, options: [.withoutUI])
            let values = try? resolvedURL?.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let resolvedURL else {
                    // The original item can't be found
                    NSSound.beep()
                    return
                }
                if values?.isDirectory == true, values?.isPackage != true {
                    self.enterFolder(resolvedURL, from: aliasURL)
                } else {
                    NSWorkspace.shared.open(resolvedURL)
                }
            }
        }
    }

    /// Show the contents of a package/bundle (navigate into it like a folder)
    func showPackageContents(_ item: FileItem) {
        cancelPendingRename()
        enterFolder(item.url, from: item.url)
    }

    // MARK: - Archive Navigation

    /// Enter a ZIP archive and browse its contents (the archive is read off the main thread)
    func enterArchive(at url: URL) {
        InlinePreviews.stopAll()
        readArchiveEntries(at: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let entries):
                self.prepareForNavigation()
                // Clear search text and tag filter when entering an archive
                // since we're now browsing different content
                if !self.searchText.isEmpty {
                    self.searchText = ""
                }
                if self.filterTag != nil {
                    self.filterTag = nil
                }

                self.archiveEntries = entries
                self.currentArchiveURL = url
                self.currentArchivePath = ""
                self.currentPath = url.deletingLastPathComponent()
                self.isInsideArchive = true
                // Remember where we came from for back navigation
                self.enteredFolderURL = url
                self.coverFlowSelectedIndex = 0
                self.loadContents()
                self.addToHistory(.archive(archiveURL: url, internalPath: ""))
            case .failure(let error):
                // Fall back to opening with default app
                zipNavLogger.error("Error reading archive: \(error.localizedDescription)")
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Navigate to a path within the current archive ("" is the archive root)
    func navigateInArchive(to path: String) {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }

        // Directory paths are stored without a trailing slash
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        prepareForNavigation()
        currentArchivePath = normalizedPath
        coverFlowSelectedIndex = 0
        loadContents()
        addToHistory(.archive(archiveURL: archiveURL, internalPath: normalizedPath))
    }

    /// Exit the current archive and return to the folder containing it (the archive is selected)
    func exitArchive() {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }
        navigateToAndSelectCurrent(archiveURL.deletingLastPathComponent())
    }

    /// Navigate up one level (handles both archive and filesystem)
    func navigateUp() {
        if isInsideArchive {
            if currentArchivePath.isEmpty {
                // At archive root, exit the archive
                exitArchive()
            } else {
                // Go up one level within the archive (to the root for a top-level folder)
                let components = currentArchivePath.split(separator: "/")
                navigateInArchive(to: components.dropLast().joined(separator: "/"))
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
                zipNavLogger.error("Failed to extract archive item: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
        }
    }

    func previewURL(for item: FileItem) -> URL? {
        // Quick Look is disabled for archive items
        if item.isFromArchive {
            return nil
        }
        if let identifier = photosAssetIdentifier(from: item.url) {
            return photosExportCache[identifier]
        }
        return item.url
    }

    /// Completion-based variant used by the Quick Look callers (archive items have no preview URL)
    func previewURL(for item: FileItem, completion: @escaping (URL?) -> Void) {
        completion(previewURL(for: item))
    }

    /// The lead ("focused") item of the selection: the most recently clicked or navigated item
    /// if it is still selected, otherwise the first selected item in display order.
    /// Use this instead of `selectedItems.first` — a Set has no order.
    var primarySelectedItem: FileItem? {
        guard !selectedItems.isEmpty else { return nil }
        if selectedItems.count == 1 { return selectedItems.first }
        let items = filteredItems
        if items.indices.contains(lastSelectedIndex), selectedItems.contains(items[lastSelectedIndex]) {
            return items[lastSelectedIndex]
        }
        return items.first(where: { selectedItems.contains($0) }) ?? selectedItems.first
    }

    /// Selected items in display order.
    var orderedSelectedItems: [FileItem] {
        guard !selectedItems.isEmpty else { return [] }
        if selectedItems.count == 1 { return Array(selectedItems) }
        return filteredItems.filter { selectedItems.contains($0) }
    }

    // Track anchor index for Shift+click range selection
    var lastSelectedIndex: Int = 0
    // Anchor index stays fixed during shift+arrow extend operations
    var selectionAnchorIndex: Int = 0

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

    /// Select a range of items from selectionAnchorIndex to the given index (Shift+click/arrow behavior)
    func selectRange(to index: Int, in items: [FileItem]) {
        guard !items.isEmpty else { return }
        let start = min(selectionAnchorIndex, index)
        let end = max(selectionAnchorIndex, index)
        let clampedStart = max(0, start)
        let clampedEnd = min(items.count - 1, end)

        selectedItems = Set(items[clampedStart...clampedEnd])
        lastSelectedIndex = index
    }

    /// Handle selection with all modifier combinations
    /// - Parameters:
    ///   - clickedOnTextArea: If true, this click can trigger rename (Finder-style: only text label clicks trigger rename)
    func handleSelection(item: FileItem, index: Int, in items: [FileItem], withShift: Bool, withCommand: Bool, allowRename: Bool = true, clickedOnTextArea: Bool = true) {
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
            selectionAnchorIndex = index
            lastClickedURL = nil
        } else {
            // Normal click: check for Finder-style rename trigger
            let wasOnlySelected = selectedItems.count == 1 && selectedItems.contains(item)
            let timeSinceLastClick = now.timeIntervalSince(lastClickTime)
            let isSameItem = lastClickedURL == item.url
            let doubleClickInterval = NSEvent.doubleClickInterval

            // If clicking the only selected item after the system double-click interval,
            // schedule rename with a short delay to avoid double-click collisions.
            // Skip rename trigger if:
            // - allowRename is false (e.g., for CoverFlow view)
            // - clickedOnTextArea is false (Finder-style: only clicks on text label trigger rename)
            if allowRename && clickedOnTextArea && wasOnlySelected && isSameItem && timeSinceLastClick > doubleClickInterval && timeSinceLastClick < 3.0 && renamingURL == nil {
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
                selectionAnchorIndex = index
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

    /// Cancel any pending rename operation (e.g., when drag starts)
    func cancelPendingRename() {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
    }

    /// Trigger rename for a newly created folder after it appears in the loaded items.
    /// Called from loadContents() after items are set and selection is resolved.
    private func triggerPendingNewFolderRename() {
        guard let newFolderURL = pendingNewFolderRenameURL else { return }
        pendingNewFolderRenameURL = nil

        let newFolderPath = newFolderURL.standardizedFileURL.path
        // Dispatch to the next run loop iteration so SwiftUI has a chance to
        // propagate the new items to the FileTableView before we start editing.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.selectedItems.count == 1,
                  let selectedItem = self.selectedItems.first,
                  selectedItem.url.standardizedFileURL.path == newFolderPath else { return }
            self.renamingURL = selectedItem.url
        }
    }

    private func addToHistory(_ location: NavigationLocation) {
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((historyIndex + 1)...)
        }
        navigationHistory.append(location)
        historyIndex = navigationHistory.count - 1
    }

    /// Re-lists the current location. Reloading the folder that's shown is incremental
    /// (no spinner, scroll position, selection and item IDs are kept).
    func refresh() {
        InlinePreviews.stopAll()
        if !isInsideArchive, photosLibraryInfo == nil, currentPath.path != "/Network" {
            // Tags and iCloud status can change behind our back (e.g. edited in Finder)
            FileTagManager.invalidateCache(forDirectory: currentPath)
            CloudStatusManager.shared.invalidateCacheForDirectory(currentPath)
            cloudStatusLoadedURLs.removeAll()
            tagRefreshToken &+= 1
        }
        loadContents()
    }

    func refreshTags(for urls: [URL], invalidateCache: Bool = true) {
        if invalidateCache {
            FileTagManager.invalidateCache(for: urls)
        }
        tagRefreshToken &+= 1
        // Force UI refresh by sending objectWillChange
        objectWillChange.send()
    }

    func setUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    // MARK: - Undo Support

    private func performMoves(
        _ moves: [MoveRecord],
        actionName: String,
        registerUndo: Bool,
        resolveCollisions: Bool,
        refreshAfter: Bool = true,
        completion: (([MoveRecord]) -> Void)? = nil
    ) {
        guard !moves.isEmpty else { return }
        fileOperationQueue.async { [weak self, moves] in
            guard let self else { return }
            let fileManager = FileManager.default
            var completed: [MoveRecord] = []
            completed.reserveCapacity(moves.count)

            for move in moves {
                let destination = resolveCollisions ? self.uniqueDestinationURL(for: move.to) : move.to
                do {
                    try self.moveItemWithFallback(fileManager, from: move.from, to: destination)
                    completed.append(MoveRecord(from: move.from, to: destination))
                } catch {
                    print("Failed to move \(move.from.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if registerUndo, !completed.isEmpty {
                    let inverse = completed.map { MoveRecord(from: $0.to, to: $0.from) }
                    self.undoManager?.registerUndo(withTarget: self) { target in
                        target.performMoves(
                            inverse,
                            actionName: actionName,
                            registerUndo: true,
                            resolveCollisions: true
                        )
                    }
                    self.undoManager?.setActionName(actionName)
                }
                completion?(completed)
                if refreshAfter {
                    self.refresh()
                }
            }
        }
    }

    private func performCopies(
        _ copies: [CopyRecord],
        actionName: String,
        registerUndo: Bool,
        resolveCollisions: Bool = true,
        refreshAfter: Bool = true,
        completion: (([CopyRecord]) -> Void)? = nil
    ) {
        guard !copies.isEmpty else { return }
        fileOperationQueue.async { [weak self, copies] in
            guard let self else { return }
            let fileManager = FileManager.default
            var completed: [CopyRecord] = []
            completed.reserveCapacity(copies.count)

            for copy in copies {
                let destination = resolveCollisions ? self.uniqueDestinationURL(for: copy.to) : copy.to
                do {
                    try fileManager.copyItem(at: copy.from, to: destination)
                    completed.append(CopyRecord(from: copy.from, to: destination))
                } catch {
                    print("Failed to copy \(copy.from.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if registerUndo, !completed.isEmpty {
                    let copiedURLs = completed.map { $0.to }
                    self.undoManager?.registerUndo(withTarget: self) { target in
                        target.performTrash(
                            copiedURLs,
                            actionName: actionName,
                            registerUndo: true,
                            playSound: false
                        )
                    }
                    self.undoManager?.setActionName(actionName)
                }
                completion?(completed)
                if refreshAfter {
                    self.refresh()
                }
            }
        }
    }

    private func performTrash(
        _ urls: [URL],
        actionName: String,
        registerUndo: Bool,
        refreshAfter: Bool = true,
        playSound: Bool = false,
        completion: (([TrashRecord]) -> Void)? = nil
    ) {
        guard !urls.isEmpty else { return }
        fileOperationQueue.async { [weak self, urls] in
            guard let self else { return }
            let fileManager = FileManager.default
            var completed: [TrashRecord] = []
            completed.reserveCapacity(urls.count)

            for url in urls {
                var trashedURL: NSURL?
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
                    if let trashedURL = trashedURL as URL? {
                        completed.append(TrashRecord(original: url, trashed: trashedURL))
                    }
                } catch {
                    print("Failed to move \(url.lastPathComponent) to Trash: \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if registerUndo, !completed.isEmpty {
                    self.undoManager?.registerUndo(withTarget: self) { target in
                        target.performRestoreFromTrash(
                            completed,
                            actionName: actionName,
                            registerUndo: true
                        )
                    }
                    self.undoManager?.setActionName(actionName)
                }
                completion?(completed)
                if refreshAfter {
                    self.refresh()
                }
                if playSound, !completed.isEmpty {
                    FinderSoundEffects.shared.play(.moveToTrash)
                }
            }
        }
    }

    private func performRestoreFromTrash(
        _ records: [TrashRecord],
        actionName: String,
        registerUndo: Bool,
        refreshAfter: Bool = true
    ) {
        guard !records.isEmpty else { return }
        fileOperationQueue.async { [weak self, records] in
            guard let self else { return }
            let fileManager = FileManager.default
            var restoredURLs: [URL] = []
            restoredURLs.reserveCapacity(records.count)

            for record in records {
                let destination = self.uniqueDestinationURL(for: record.original)
                do {
                    try self.moveItemWithFallback(fileManager, from: record.trashed, to: destination)
                    restoredURLs.append(destination)
                } catch {
                    print("Failed to restore \(record.original.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if registerUndo, !restoredURLs.isEmpty {
                    self.undoManager?.registerUndo(withTarget: self) { target in
                        target.performTrash(
                            restoredURLs,
                            actionName: actionName,
                            registerUndo: true,
                            playSound: false
                        )
                    }
                    self.undoManager?.setActionName(actionName)
                }
                if refreshAfter {
                    self.refresh()
                }
            }
        }
    }

    @discardableResult
    private func applyTags(
        _ tags: [String],
        to url: URL,
        actionName: String,
        registerUndo: Bool,
        invalidateCache: Bool
    ) -> Bool {
        let beforeTags = FileTagManager.getTags(for: url)
        guard beforeTags != tags else { return true }
        guard FileTagManager.setTags(tags, for: url) else {
            // Nothing changed on disk: no undo entry, show what's really there
            refreshTags(for: [url], invalidateCache: true)
            presentTagEditFailure(for: url)
            return false
        }

        if registerUndo {
            let beforeSnapshot = beforeTags
            self.undoManager?.registerUndo(withTarget: self) { target in
                target.applyTags(
                    beforeSnapshot,
                    to: url,
                    actionName: actionName,
                    registerUndo: true,
                    invalidateCache: invalidateCache
                )
            }
            self.undoManager?.setActionName(actionName)
        }

        refreshTags(for: [url], invalidateCache: invalidateCache)
        return true
    }

    /// Toggles a tag; returns false (and tells the user) when the tags couldn't be written.
    @discardableResult
    func toggleTag(_ tagName: String, for url: URL, invalidateCache: Bool = true) -> Bool {
        let currentTags = FileTagManager.getTags(for: url)
        var updatedTags = currentTags
        if let index = updatedTags.firstIndex(of: tagName) {
            updatedTags.remove(at: index)
        } else {
            updatedTags.append(tagName)
        }
        return applyTags(updatedTags, to: url, actionName: "Tags", registerUndo: true, invalidateCache: invalidateCache)
    }

    /// Sets tags; returns false (and tells the user) when the tags couldn't be written.
    @discardableResult
    func setTags(_ tags: [String], for url: URL, invalidateCache: Bool = true) -> Bool {
        applyTags(tags, to: url, actionName: "Tags", registerUndo: true, invalidateCache: invalidateCache)
    }

    private func presentTagEditFailure(for url: URL) {
        // Only when running as an app (not headless, e.g. in tests)
        guard let app = NSApp, app.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "The tags of “\(url.lastPathComponent)” couldn’t be changed."
        alert.informativeText = "You may not have permission to change this item, or its volume may be read-only."
        alert.alertStyle = .warning
        if let window = app.keyWindow ?? app.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
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
        guard !selectedItems.isEmpty else {
            return
        }

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
        paste(to: currentPath)
    }

    func paste(to destination: URL) {
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

        if operationIsCut {
            let moves = urlsToPaste.map {
                MoveRecord(from: $0, to: destination.appendingPathComponent($0.lastPathComponent))
            }
            performMoves(moves, actionName: "Move", registerUndo: true, resolveCollisions: true) { [weak self] completed in
                guard let self else { return }
                guard !completed.isEmpty else { return }
                // Select pasted files after refresh
                let pastedURLs = Set(completed.map { $0.to })
                self.pendingSelectionURLs = pastedURLs
                self.pendingSelectionURL = completed.first?.to
                self.clipboardItems.removeAll()
                // Clear the cut marker from pasteboard to prevent re-pasting moved files
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
            }
        } else {
            let copies = urlsToPaste.map {
                CopyRecord(from: $0, to: destination.appendingPathComponent($0.lastPathComponent))
            }
            performCopies(copies, actionName: "Copy", registerUndo: true, resolveCollisions: true) { [weak self] completed in
                guard let self else { return }
                guard !completed.isEmpty else { return }
                // Select pasted files after refresh
                let pastedURLs = Set(completed.map { $0.to })
                self.pendingSelectionURLs = pastedURLs
                self.pendingSelectionURL = completed.first?.to
            }
        }
    }

    func deleteSelectedItems() {
        let itemsToDelete = selectedItems.filter { !$0.isFromArchive }
        guard !itemsToDelete.isEmpty else {
            NSSound.beep()
            return
        }

        NSLog("[DELETE] Starting delete of %d items. lastSelectedIndex=%d, items.count=%d, filteredItems.count=%d", itemsToDelete.count, lastSelectedIndex, items.count, filteredItems.count)
        for item in itemsToDelete {
            NSLog("[DELETE]   Deleting: %@", item.name)
        }

        // Find the URL to select after deletion (next item, or previous if at end)
        let currentItems = filteredItems
        let deletedURLs = Set(itemsToDelete.map { $0.url })
        var nextSelectionItem: FileItem? = nil
        var nextSelectionIndex: Int = 0

        // Find the first item that's NOT being deleted, preferring items after the deleted ones
        if let firstDeletedIndex = currentItems.firstIndex(where: { deletedURLs.contains($0.url) }) {
            // Look for first non-deleted item after the deleted range
            for i in firstDeletedIndex..<currentItems.count {
                if !deletedURLs.contains(currentItems[i].url) {
                    nextSelectionItem = currentItems[i]
                    // Calculate what index this will be after deletion
                    let deletedBefore = currentItems[0..<i].filter { deletedURLs.contains($0.url) }.count
                    nextSelectionIndex = i - deletedBefore
                    break
                }
            }

            // If no item after, look before
            if nextSelectionItem == nil && firstDeletedIndex > 0 {
                for i in stride(from: firstDeletedIndex - 1, through: 0, by: -1) {
                    if !deletedURLs.contains(currentItems[i].url) {
                        nextSelectionItem = currentItems[i]
                        let deletedBefore = currentItems[0..<i].filter { deletedURLs.contains($0.url) }.count
                        nextSelectionIndex = i - deletedBefore
                        break
                    }
                }
            }
        }

        // Store selection info to use after deletion
        let targetIndex = nextSelectionIndex
        let targetItem = nextSelectionItem

        performTrash(
            itemsToDelete.map { $0.url },
            actionName: "Move to Trash",
            registerUndo: true,
            refreshAfter: false,  // Don't do full refresh - we'll update incrementally
            playSound: true
        ) { [weak self] records in
            guard let self else { return }
            guard !records.isEmpty else { return }

            // Remove deleted items from the items array directly (incremental update)
            let trashedURLs = Set(records.map { $0.original })
            NSLog("[DELETE] Trash completed. Trashed %d items. items.count before removal=%d", trashedURLs.count, self.items.count)
            self.items.removeAll { trashedURLs.contains($0.url) }
            NSLog("[DELETE] items.count after removal=%d, targetIndex=%d, targetItem=%@", self.items.count, targetIndex, targetItem?.name ?? "nil")

            // Update selection to the next/previous item
            let safeTargetIndex = self.items.isEmpty ? 0 : min(targetIndex, self.items.count - 1)
            self.coverFlowSelectedIndex = safeTargetIndex
            self.lastSelectedIndex = safeTargetIndex
            self.selectionAnchorIndex = safeTargetIndex
            let debugSelectedName = targetItem?.name ?? (safeTargetIndex < self.items.count ? self.items[safeTargetIndex].name : "nil")
            NSLog("[DELETE] Set lastSelectedIndex=%d, selectedItem=%@", safeTargetIndex, debugSelectedName)
            if let targetItem = targetItem {
                self.selectedItems = [targetItem]
            } else if !self.items.isEmpty {
                // Select item at the target index if original target was deleted
                if safeTargetIndex >= 0 {
                    self.selectedItems = [self.items[safeTargetIndex]]
                } else {
                    self.selectedItems.removeAll()
                }
            } else {
                self.selectedItems.removeAll()
            }
            NSLog("[DELETE] Final state: selectedItems.count=%d, selectedItems=%@, lastSelectedIndex=%d", self.selectedItems.count, self.selectedItems.map { $0.name }.joined(separator: ", "), self.lastSelectedIndex)

            // Clean up hydration tracking
            for url in trashedURLs {
                self.hydratedURLs.remove(url)
                self.pendingHydrationURLs.remove(url)
            }
        }
    }

    /// - Parameter operation: The drop operation resolved by the caller at drop time
    ///   (use `FileDropOperation(modifierFlags:)` with the drop event's modifiers).
    ///   `nil` falls back to the current keyboard modifiers.
    func handleDrop(urls: [URL], to destPath: URL? = nil, operation: FileDropOperation? = nil, completion: (() -> Void)? = nil) {
        guard !isInsideArchive else {
            NSSound.beep()
            return
        }

        let destination = destPath ?? currentPath
        let resolvedOperation = operation ?? FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        // Finder behavior: Drag = Move, Option+Drag = Copy
        let shouldCopy = resolvedOperation == .copy
        let destinationPath = destination
        let filteredURLs = urls.filter { $0.deletingLastPathComponent() != destinationPath }
        guard !filteredURLs.isEmpty else {
            completion?()
            return
        }

        if shouldCopy {
            let copies = filteredURLs.map {
                CopyRecord(from: $0, to: destinationPath.appendingPathComponent($0.lastPathComponent))
            }
            performCopies(copies, actionName: "Copy", registerUndo: true, resolveCollisions: true) { _ in
                completion?()
            }
        } else {
            let moves = filteredURLs.map {
                MoveRecord(from: $0, to: destinationPath.appendingPathComponent($0.lastPathComponent))
            }
            performMoves(moves, actionName: "Move", registerUndo: true, resolveCollisions: true) { _ in
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
        let fileManager = FileManager.default
        let copies: [CopyRecord] = itemsToDuplicate.map { item in
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

            return CopyRecord(from: item.url, to: destinationURL)
        }
        performCopies(copies, actionName: "Duplicate", registerUndo: true, resolveCollisions: false)
    }

    func renameItem(_ item: FileItem, to newName: String) {
        guard !item.isFromArchive else {
            NSSound.beep()
            return
        }

        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)

        guard newURL != item.url else { return }

        let move = MoveRecord(from: item.url, to: newURL)
        performMoves([move], actionName: "Rename", registerUndo: true, resolveCollisions: false)
    }

    /// Commit current rename and start renaming the next item (Tab behavior)
    func commitRenameAndNext(currentItem: FileItem, newName: String) {
        // Commit the current rename
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != currentItem.nameWithoutExtension {
            let ext = currentItem.url.pathExtension
            let finalName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
            renameItem(currentItem, to: finalName)
        }

        // Find next item to rename
        if let currentIndex = items.firstIndex(where: { $0.url == currentItem.url }) {
            let nextIndex = currentIndex + 1
            if nextIndex < items.count {
                let nextItem = items[nextIndex]
                if !nextItem.isFromArchive {
                    selectedItems = [nextItem]
                    lastSelectedIndex = nextIndex
                    selectionAnchorIndex = nextIndex
                    // Small delay to allow the rename to complete before starting new one
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.renamingURL = nextItem.url
                    }
                    return
                }
            }
        }
        // No next item or it's not renamable - just clear rename state
        renamingURL = nil
    }

    /// Commit current rename and start renaming the previous item (Shift+Tab behavior)
    func commitRenameAndPrevious(currentItem: FileItem, newName: String) {
        // Commit the current rename
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != currentItem.nameWithoutExtension {
            let ext = currentItem.url.pathExtension
            let finalName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
            renameItem(currentItem, to: finalName)
        }

        // Find previous item to rename
        if let currentIndex = items.firstIndex(where: { $0.url == currentItem.url }) {
            let prevIndex = currentIndex - 1
            if prevIndex >= 0 {
                let prevItem = items[prevIndex]
                if !prevItem.isFromArchive {
                    selectedItems = [prevItem]
                    lastSelectedIndex = prevIndex
                    selectionAnchorIndex = prevIndex
                    // Small delay to allow the rename to complete before starting new one
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.renamingURL = prevItem.url
                    }
                    return
                }
            }
        }
        // No previous item or it's not renamable - just clear rename state
        renamingURL = nil
    }

    func moveSelectedItemsToTrash() {
        deleteSelectedItems()
    }

    func getInfo() {
        guard let item = primarySelectedItem else { return }
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
                    guard let self else { return }
                    NSLog("[NewFolder] Created folder: %@", folderURL.lastPathComponent)
                    self.undoManager?.registerUndo(withTarget: self) { target in
                        target.performTrash(
                            [folderURL],
                            actionName: "New Folder",
                            registerUndo: true,
                            playSound: false
                        )
                    }
                    self.undoManager?.setActionName("New Folder")
                    NSLog("[NewFolder] Setting pendingSelectionURL and pendingNewFolderRenameURL to: %@", folderURL.absoluteString)
                    self.pendingSelectionURL = folderURL
                    self.pendingNewFolderRenameURL = folderURL
                    self.refresh()
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

    // MARK: - Search

    /// Perform search based on current search mode
    func performSearch(query: String) {
        performSearch(query: query, mode: searchMode)
    }

    private func performSearch(query: String, mode: SearchMode) {
        // Cancel any existing search
        cancelSearch()

        guard !query.isEmpty else {
            searchResults = []
            return
        }

        switch mode {
        case .filter:
            // Filter mode doesn't use async search
            return
        case .finder:
            guard isBackgroundWorkActive else {
                searchNeedsRerunOnResume = true
                return
            }
            isSearching = true
            performFinderSearch(query: query)
        }
    }

    /// Cancel any ongoing search
    func cancelSearch() {
        spotlightSearch?.stop()
        spotlightSearch = nil
        spotlightSearchToken = UUID()
        isSearching = false
    }

    func clearSearchQuery() {
        cancelSearch()
        searchResults = []
        searchText = ""
        spotlightIDsByPath.removeAll()
    }

    /// Perform Finder search using NSMetadataQuery (Spotlight)
    private func performFinderSearch(query: String) {
        searchDebugLogger.debug("Starting Spotlight search, \(query.count) characters")
        let token = UUID()
        spotlightSearchToken = token
        let session = SpotlightSearchSession(
            queryString: query,
            scope: currentPath,
            idsByPath: spotlightIDsByPath
        ) { [weak self] results, idsByPath in
            guard let self, self.spotlightSearchToken == token else { return }
            self.spotlightIDsByPath = idsByPath
            self.searchResults = results
            self.isSearching = false
        }
        spotlightSearch = session
        session.start()
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
        // Ensure we rebuild one final time with all results
        if isNetworkBrowsing, currentPath.path == "/Network" {
            rebuildNetworkItems()
        }
    }
}

// MARK: - Spotlight Search

/// Runs one Spotlight query with its notifications on a private serial queue and builds the
/// FileItems there from the attributes Spotlight returns (no per-result file system reads on
/// main). IDs stay stable per path across result updates and successive queries.
private final class SpotlightSearchSession: @unchecked Sendable {
    private let query = NSMetadataQuery()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flowfinder.spotlight"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let cancellation = LoadCancellationFlag()
    private var observers: [NSObjectProtocol] = []
    /// Accessed on `queue` only
    private var idsByPath: [String: UUID]
    private let deliver: @MainActor (_ results: [FileItem], _ idsByPath: [String: UUID]) -> Void
    private static let maxRememberedIDs = 50_000

    init(queryString: String,
         scope: URL,
         idsByPath: [String: UUID],
         deliver: @escaping @MainActor (_ results: [FileItem], _ idsByPath: [String: UUID]) -> Void) {
        self.idsByPath = idsByPath
        self.deliver = deliver
        // Build predicate for filename search in the scope folder and its subfolders
        query.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", queryString)
        query.searchScopes = [scope]
        query.operationQueue = queue
    }

    deinit {
        stop()
    }

    func start() {
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: query, queue: nil) { [weak self] _ in
                // Posted on the query's operation queue
                self?.collectResults()
            }
            observers.append(observer)
        }
        let query = self.query
        queue.addOperation {
            query.start()
        }
    }

    func stop() {
        guard !cancellation.isCancelled else { return }
        cancellation.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        let query = self.query
        queue.addOperation {
            query.stop()
        }
    }

    /// Runs on `queue`
    private func collectResults() {
        guard !cancellation.isCancelled else { return }
        query.disableUpdates()
        if idsByPath.count > Self.maxRememberedIDs {
            idsByPath.removeAll()
        }

        var results: [FileItem] = []
        results.reserveCapacity(query.resultCount)
        for index in 0..<query.resultCount {
            guard let result = query.result(at: index) as? NSMetadataItem,
                  let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else {
                continue
            }
            let id: UUID
            if let existing = idsByPath[path] {
                id = existing
            } else {
                id = UUID()
                idsByPath[path] = id
            }
            results.append(Self.makeItem(from: result, path: path, id: id))
        }
        query.enableUpdates()

        let idsSnapshot = idsByPath
        let cancellation = self.cancellation
        let deliver = self.deliver
        DispatchQueue.main.async {
            guard !cancellation.isCancelled else { return }
            MainActor.assumeIsolated {
                deliver(results, idsSnapshot)
            }
        }
    }

    private static func makeItem(from result: NSMetadataItem, path: String, id: UUID) -> FileItem {
        guard let typeIdentifier = result.value(forAttribute: kMDItemContentType as String) as? String,
              let contentType = UTType(typeIdentifier) else {
            // Not fully indexed: read from the file system (we're off the main thread)
            return FileItem(url: URL(fileURLWithPath: path), id: id, loadMetadata: true)
        }
        // Folders and packages conform to public.directory
        let isDirectory = contentType.conforms(to: .directory)
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        let size = (result.value(forAttribute: kMDItemFSSize as String) as? NSNumber)?.int64Value ?? 0
        return FileItem(
            id: id,
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: size,
            modificationDate: result.value(forAttribute: kMDItemFSContentChangeDate as String) as? Date,
            creationDate: result.value(forAttribute: kMDItemFSCreationDate as String) as? Date,
            contentType: contentType
        )
    }
}

// MARK: - Bonjour Browsing

fileprivate struct NetworkServiceInfo: Hashable {
    let key: String
    let name: String
    let scheme: String
    let hostName: String?
    let port: Int
    let priority: Int
}

@MainActor
fileprivate protocol NetworkServiceBrowserDelegate: AnyObject {
    func networkServiceBrowser(_ browser: NetworkServiceBrowser, didUpdate services: [NetworkServiceInfo], isFinal: Bool)
}

/// Bonjour browsing for SMB/AFP hosts. Used on the main thread (NetService callbacks arrive on
/// the run loop it was scheduled on); delegate updates are delivered on the main queue.
fileprivate final class NetworkServiceBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private weak var delegate: NetworkServiceBrowserDelegate?
    private var browsers: [NetServiceBrowser] = []
    private var netServices: [String: NetService] = [:]
    private var services: [String: NetworkServiceInfo] = [:]
    private let serviceTypes = ["_smb._tcp.", "_afp._tcp.", "_workstation._tcp."]

    init(delegate: NetworkServiceBrowserDelegate) {
        self.delegate = delegate
    }

    deinit {
        stop()
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
            browser.delegate = nil
            browser.stop()
        }
        browsers.removeAll()
        for service in netServices.values {
            service.delegate = nil
            service.stop()
        }
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
            MainActor.assumeIsolated {
                self.delegate?.networkServiceBrowser(self, didUpdate: snapshot, isFinal: isFinal)
            }
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

// MARK: - Directory Watcher

/// Watches one folder with FSEvents and reports changed direct children. Paths are mapped to
/// the folder's displayed form (FSEvents reports resolved paths such as /private/tmp for /tmp
/// or a symlinked folder's target). Callbacks are delivered on the main queue.
private final class DirectoryWatcher {
    typealias Callback = @MainActor (_ childPaths: [String], _ needsRescan: Bool, _ watchedPath: String) -> Void

    /// Per-stream state, retained by the stream through its context
    fileprivate final class StreamContext {
        let displayPath: String
        let callback: Callback
        /// Resolved on the stream's queue on first use (realpath may touch the disk)
        lazy var resolvedPath: String = resolvedFilesystemPath(displayPath)

        init(displayPath: String, callback: @escaping Callback) {
            self.displayPath = displayPath
            self.callback = callback
        }

        /// Maps an event path to the displayed form, or nil when it's outside the watched folder.
        func displayFormPath(for eventPath: String) -> String? {
            var path = eventPath
            if path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            let displayPrefix = displayPath == "/" ? "/" : displayPath + "/"
            if path == displayPath || path.hasPrefix(displayPrefix) {
                return path
            }
            let resolved = resolvedPath
            guard resolved != displayPath else { return nil }
            if path == resolved {
                return displayPath
            }
            let resolvedPrefix = resolved == "/" ? "/" : resolved + "/"
            if path.hasPrefix(resolvedPrefix) {
                return displayPrefix + path.dropFirst(resolvedPrefix.count)
            }
            return nil
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.coverflowfinder.directorywatcher", qos: .utility)
    private let callback: Callback
    /// Displayed path of the watched folder (nil when stopped)
    private(set) var watchedPath: String?

    init(callback: @escaping Callback) {
        self.callback = callback
    }

    func start(watching path: String) {
        if watchedPath == path, stream != nil { return }
        stop()

        let context = StreamContext(displayPath: path, callback: callback)
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<StreamContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<StreamContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.eventCallback,
            &streamContext,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        self.stream = stream
        watchedPath = path
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops watching; `start` then watches again even for the same path.
    func stop() {
        watchedPath = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private static let eventCallback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
        guard let clientInfo else { return }
        let context = Unmanaged<StreamContext>.fromOpaque(clientInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let droppedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let scanFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

        var childPaths: [String] = []
        var needsRescan = false
        for (index, eventPath) in paths.enumerated() where index < numEvents {
            let flags = eventFlags[index]
            if flags & droppedFlags != 0 {
                needsRescan = true
                continue
            }
            guard let path = context.displayFormPath(for: eventPath) else {
                // Coalesced events for an ancestor of the watched folder
                if flags & scanFlag != 0, context.displayPath.hasPrefix(eventPath) {
                    needsRescan = true
                }
                continue
            }
            if path == context.displayPath {
                if flags & scanFlag != 0 {
                    needsRescan = true
                }
                continue
            }
            // Only direct children affect the listing
            if (path as NSString).deletingLastPathComponent == context.displayPath {
                childPaths.append(path)
            }
        }
        guard needsRescan || !childPaths.isEmpty else { return }

        let callback = context.callback
        let watchedPath = context.displayPath
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                callback(childPaths, needsRescan, watchedPath)
            }
        }
    }
}

// MARK: - SMB Network Scanner

fileprivate struct SMBHostInfo: Hashable {
    let ipAddress: String
    let name: String
    let port: Int
}

@MainActor
fileprivate protocol SMBSubnetScannerDelegate: AnyObject {
    func smbSubnetScanner(_ scanner: SMBSubnetScanner, didDiscover hosts: [SMBHostInfo])
    func smbSubnetScannerDidFinish(_ scanner: SMBSubnetScanner)
}

/// Scans the local subnet for SMB hosts (port 445). `start`/`stop` and the delegate callbacks
/// run on the main thread; probes run on a bounded operation queue and their results are
/// accumulated serially, then published to main.
fileprivate final class SMBSubnetScanner {
    private weak var delegate: SMBSubnetScannerDelegate?
    /// At most this many blocking connect/reverse-DNS probes run at once
    static let maxConcurrentProbes = 16
    private let probeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flowfinder.smbscanner"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = SMBSubnetScanner.maxConcurrentProbes
        return queue
    }()
    /// Main thread only
    private var isScanning = false
    private var scanCancellation: LoadCancellationFlag?
    private static let smbPort: UInt16 = 445
    private static let connectionTimeout: TimeInterval = 0.3

    init(delegate: SMBSubnetScannerDelegate) {
        self.delegate = delegate
    }

    deinit {
        scanCancellation?.cancel()
        probeQueue.cancelAllOperations()
    }

    func start() {
        guard !isScanning else { return }
        isScanning = true
        let cancellation = LoadCancellationFlag()
        scanCancellation = cancellation

        // Get local network info and calculate subnet range
        guard let (localIP, netmask) = Self.getLocalNetworkInfo() else {
            finishScanning(cancellation)
            return
        }
        let ipRange = Self.calculateIPRange(localIP: localIP, netmask: netmask)
        guard !ipRange.isEmpty else {
            finishScanning(cancellation)
            return
        }

        let results = SerialResultAccumulator<SMBHostInfo>()
        // Skip our own IP
        for ip in ipRange where ip != localIP {
            probeQueue.addOperation { [weak self] in
                guard !cancellation.isCancelled, Self.checkSMBPort(ip: ip) else { return }
                let hostName = Self.resolveHostName(ip: ip) ?? ip
                let hostInfo = SMBHostInfo(ipAddress: ip, name: hostName, port: Int(Self.smbPort))
                results.append(hostInfo) { [weak self] hosts in
                    // Main queue, snapshots in discovery order
                    guard let self, !cancellation.isCancelled else { return }
                    MainActor.assumeIsolated {
                        self.delegate?.smbSubnetScanner(self, didDiscover: hosts)
                    }
                }
            }
        }
        // Runs once every probe has finished
        probeQueue.addBarrierBlock { [weak self] in
            self?.finishScanning(cancellation)
        }
    }

    func stop() {
        scanCancellation?.cancel()
        scanCancellation = nil
        probeQueue.cancelAllOperations()
        isScanning = false
    }

    private func finishScanning(_ cancellation: LoadCancellationFlag) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            self.isScanning = false
            self.scanCancellation = nil
            MainActor.assumeIsolated {
                self.delegate?.smbSubnetScannerDidFinish(self)
            }
        }
    }

    private static func getLocalNetworkInfo() -> (ip: String, netmask: String)? {
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

    private static func calculateIPRange(localIP: String, netmask: String) -> [String] {
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

    private static func checkSMBPort(ip: String) -> Bool {
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

    private static func resolveHostName(ip: String) -> String? {
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
}

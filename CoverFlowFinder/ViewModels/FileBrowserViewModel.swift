import Foundation
import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let showGetInfo = Notification.Name("showGetInfo")
}

enum ViewMode: String, CaseIterable {
    case coverFlow = "Cover Flow"
    case icons = "Icons"
    case list = "List"
    case columns = "Columns"
    case dualPane = "Dual Pane"
    case quadPane = "Quad Pane"

    var systemImage: String {
        switch self {
        case .coverFlow: return "square.stack.3d.forward.dottedline"
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .dualPane: return "rectangle.split.2x1"
        case .quadPane: return "rectangle.grid.2x2"
        }
    }
}

enum NavigationLocation: Equatable {
    case filesystem(URL)
    case archive(archiveURL: URL, internalPath: String)
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
    @Published var items: [FileItem] = []
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
        var filtered = items

        // Filter by search text
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Filter by tag
        if let tag = filterTag {
            filtered = filtered.filter { item in
                item.tags.contains(tag)
            }
        }

        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let foldersFirst = AppSettings.shared.foldersFirst
        return sortItemsForBackground(filtered, sortState: sortState, foldersFirst: foldersFirst)
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
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        columnConfig.$sortDirection
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func loadContents() {
        // If we're inside an archive, load archive contents instead
        if isInsideArchive {
            loadArchiveContents()
            return
        }

        isLoading = true
        items = []
        let pathToLoad = currentPath
        let pendingURL = pendingSelectionURL  // Capture before async
        let sortState = ListColumnConfigManager.shared.sortStateSnapshot()
        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let foldersFirst = AppSettings.shared.foldersFirst

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Use autoreleasepool to release temporary objects promptly
                let fileItems: [FileItem] = try autoreleasepool {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: pathToLoad,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .contentTypeKey
                        ],
                        options: showHiddenFiles ? [] : [.skipsHiddenFiles]
                    )

                    // Build lightweight items - use reserveCapacity for better performance
                    var items = [FileItem]()
                    items.reserveCapacity(contents.count)
                    for url in contents {
                        items.append(FileItem(url: url, loadMetadata: true))
                    }
                    return items
                }

                // Calculate selection index on background thread to avoid main thread work
                var selectedIndex = 0
                var selectedItem: FileItem?

                if let pendingURL = pendingURL,
                   let item = fileItems.first(where: { $0.url == pendingURL }) {
                    selectedItem = item
                    // Pre-sort on background thread using captured sort settings
                    let sorted = sortItemsForBackground(fileItems, sortState: sortState, foldersFirst: foldersFirst)
                    if let index = sorted.firstIndex(of: item) {
                        selectedIndex = index
                    }
                }

                DispatchQueue.main.async {
                    // Don't overwrite items if we've entered an archive while this async load was in progress
                    guard !self.isInsideArchive else { return }

                    // Don't overwrite if path changed while loading
                    guard self.currentPath == pathToLoad else { return }

                    if let item = selectedItem {
                        self.coverFlowSelectedIndex = selectedIndex
                        self.selectedItems = [item]
                        self.pendingSelectionURL = nil
                    } else {
                        let clamped = min(self.coverFlowSelectedIndex, max(0, fileItems.count - 1))
                        self.coverFlowSelectedIndex = clamped
                    }

                    // Set items AFTER index so SwiftUI sees both changes together
                    self.items = fileItems
                    self.isLoading = false
                    // Increment navigation generation to force SwiftUI update
                    self.navigationGeneration += 1
                }
            } catch {
                DispatchQueue.main.async {
                    self.items = []
                    self.isLoading = false
                }
            }
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

        items = fileItems
        coverFlowSelectedIndex = min(coverFlowSelectedIndex, max(0, sorted.count - 1))
        isLoading = false
        navigationGeneration += 1
    }


    func navigateTo(_ url: URL) {
        guard url != currentPath else { return }
        currentPath = url
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0
        loadContents()
        addToHistory(.filesystem(url))
    }

    /// Navigate to a URL and select the folder we came from (for path bar navigation)
    func navigateToAndSelectCurrent(_ url: URL) {
        guard url != currentPath else { return }
        // Remember current path to select it after navigating
        pendingSelectionURL = currentPath
        currentPath = url
        selectedItems.removeAll()
        // Note: Don't reset coverFlowSelectedIndex here - let loadContents set the correct index
        loadContents()
        addToHistory(.filesystem(url))
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
                print("Failed to restore archive state: \(error)")
                isInsideArchive = false
                currentArchiveURL = nil
                currentArchivePath = ""
                archiveEntries = []
                currentPath = archiveURL.deletingLastPathComponent()
                loadContents()
            }
        }
    }

    func openItem(_ item: FileItem) {
        cancelPendingRename()

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
              let entry = archiveEntry(for: item) else {
            return
        }

        guard !entry.isDirectory else { return }

        do {
            let tempURL = try ZipArchiveManager.shared.extractFile(entry, from: archiveURL)
            NSWorkspace.shared.open(tempURL)
        } catch {
            print("Failed to extract file: \(error.localizedDescription)")
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
        if item.isFromArchive {
            guard !item.isDirectory,
                  let archiveURL = item.archiveURL,
                  let entry = archiveEntry(for: item) else {
                return nil
            }
            return try? ZipArchiveManager.shared.extractFile(entry, from: archiveURL)
        }
        return item.url
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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CoverFlowFinder-Extract")
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

        selectedItems.removeAll()

        fileOperationQueue.async {
            let fileManager = FileManager.default
            for item in itemsToDelete {
                do {
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                } catch {
                    print("Failed to delete \(item.name): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.refresh()
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

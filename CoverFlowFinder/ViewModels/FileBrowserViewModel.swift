import Foundation
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

enum SortOption: String, CaseIterable {
    case name = "Name"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"
    case kind = "Kind"
}

enum ClipboardOperation {
    case copy
    case cut
}

/// Thread-safe sort function for background use (non-isolated)
private func sortItemsForBackground(_ items: [FileItem], sortOption: SortOption, ascending: Bool) -> [FileItem] {
    return items.sorted { (item1: FileItem, item2: FileItem) -> Bool in
        // Folders always come first
        if item1.isDirectory != item2.isDirectory {
            return item1.isDirectory
        }

        let result: Bool
        switch sortOption {
        case .name:
            result = item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
        case .dateModified, .dateCreated:
            let date1 = item1.modificationDate ?? .distantPast
            let date2 = item2.modificationDate ?? .distantPast
            result = date1 < date2
        case .size:
            result = item1.size < item2.size
        case .kind:
            let kind1 = String(describing: item1.fileType)
            let kind2 = String(describing: item2.fileType)
            result = kind1 < kind2
        }
        return ascending ? result : !result
    }
}

@MainActor
class FileBrowserViewModel: ObservableObject {
    @Published var currentPath: URL
    @Published var items: [FileItem] = []
    @Published var selectedItems: Set<FileItem> = []
    @Published var viewMode: ViewMode = .coverFlow
    @Published var sortOption: SortOption = .name
    @Published var sortAscending: Bool = true
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var navigationHistory: [URL] = []
    @Published var historyIndex: Int = -1
    @Published var coverFlowSelectedIndex: Int = 0
    @Published var renamingURL: URL? = nil
    // Navigation generation counter - forces SwiftUI to update on navigation
    @Published var navigationGeneration: Int = 0

    // Track click timing for Finder-style rename triggering
    private var lastClickedURL: URL?
    private var lastClickTime: Date = .distantPast

    // Track the folder we entered so we can select it when going back
    private var enteredFolderURL: URL?
    // URL to select after loading (used when going back)
    private var pendingSelectionURL: URL?
    private var metadataHydrationWorkItem: DispatchWorkItem?
    private let metadataHydrationWindow = 200

    // Clipboard state
    @Published var clipboardItems: [URL] = []
    @Published var clipboardOperation: ClipboardOperation = .copy

    @Published var infoItem: FileItem?

    private var cancellables = Set<AnyCancellable>()

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    var filteredItems: [FileItem] {
        let filtered = searchText.isEmpty ? items : items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        return sortItems(filtered)
    }

    init(initialPath: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentPath = initialPath
        loadContents()
        addToHistory(initialPath)

        $searchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func loadContents() {
        isLoading = true
        items = []
        let pathToLoad = currentPath
        let pendingURL = pendingSelectionURL  // Capture before async
        // Capture sort settings for thread-safe access
        let capturedSortOption = sortOption
        let capturedSortAscending = sortAscending

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
                        options: [.skipsHiddenFiles]
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
                    let viewModelSorted = sortItemsForBackground(fileItems, sortOption: capturedSortOption, ascending: capturedSortAscending)
                    let finalSorted = ListColumnConfigManager.shared.sortedItems(viewModelSorted)
                    if let index = finalSorted.firstIndex(of: item) {
                        selectedIndex = index
                    }
                }

                DispatchQueue.main.async {
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
                    self.hydrateMetadataAroundSelection()
                }
            } catch {
                DispatchQueue.main.async {
                    self.items = []
                    self.isLoading = false
                }
            }
        }
    }


    func navigateTo(_ url: URL) {
        guard url != currentPath else { return }
        currentPath = url
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0
        loadContents()
        addToHistory(url)
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
        addToHistory(url)
    }

    func navigateToParent() {
        let parent = currentPath.deletingLastPathComponent()
        if parent != currentPath {
            navigateTo(parent)
        }
    }

    func goBack() {
        guard canGoBack else { return }
        pendingSelectionURL = enteredFolderURL ?? currentPath
        enteredFolderURL = nil
        historyIndex -= 1
        currentPath = navigationHistory[historyIndex]
        selectedItems.removeAll()
        // Note: Don't reset coverFlowSelectedIndex here - let loadContents set the correct index
        // Setting it to 0 triggers an unnecessary SwiftUI update before items are loaded
        loadContents()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = navigationHistory[historyIndex]
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0
        loadContents()
    }

    func openItem(_ item: FileItem) {
        if item.isDirectory {
            enteredFolderURL = item.url
            navigateTo(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
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

        // Select all items in the range
        for i in clampedStart...clampedEnd {
            selectedItems.insert(items[i])
        }
    }

    /// Handle selection with all modifier combinations
    func handleSelection(item: FileItem, index: Int, in items: [FileItem], withShift: Bool, withCommand: Bool) {
        let now = Date()

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

            // If clicking on the only selected item again after 0.8-3 seconds, trigger rename
            // (0.8s minimum prevents accidental activation during double-click)
            if wasOnlySelected && isSameItem && timeSinceLastClick > 0.8 && timeSinceLastClick < 3.0 && renamingURL == nil {
                renamingURL = item.url
                lastClickedURL = nil
            } else {
                // Normal selection
                selectedItems = [item]
                lastSelectedIndex = index
                lastClickedURL = item.url
            }
        }

        lastClickTime = now
    }

    func quickLook(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func addToHistory(_ url: URL) {
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((historyIndex + 1)...)
        }
        navigationHistory.append(url)
        historyIndex = navigationHistory.count - 1
    }

    private func sortItems(_ items: [FileItem]) -> [FileItem] {
        let sorted = items.sorted { item1, item2 in
            // Folders always come first
            if item1.isDirectory != item2.isDirectory {
                return item1.isDirectory
            }

            let result: Bool
            switch sortOption {
            case .name:
                result = item1.name.localizedCaseInsensitiveCompare(item2.name) == .orderedAscending
            case .dateModified:
                result = (item1.modificationDate ?? Date.distantPast) < (item2.modificationDate ?? Date.distantPast)
            case .dateCreated:
                result = (item1.creationDate ?? Date.distantPast) < (item2.creationDate ?? Date.distantPast)
            case .size:
                result = item1.size < item2.size
            case .kind:
                result = String(describing: item1.fileType) < String(describing: item2.fileType)
            }
            return sortAscending ? result : !result
        }
        return sorted
    }

    /// Hydrate heavy metadata (size/dates/type) around the current selection window.
    func hydrateMetadataAroundSelection() {
        let currentItems = items
        guard !currentItems.isEmpty else { return }
        let targetPath = currentPath

        let sorted = ListColumnConfigManager.shared.sortedItems(sortItems(currentItems))
        guard !sorted.isEmpty else { return }

        let selected = min(max(0, coverFlowSelectedIndex), sorted.count - 1)
        let halfWindow = metadataHydrationWindow / 2
        let start = max(0, selected - halfWindow)
        let end = min(sorted.count - 1, selected + halfWindow)
        guard start <= end else { return }

        let slice = sorted[start...end]
        let targets = slice.filter { !$0.hasMetadata }
        guard !targets.isEmpty else { return }

        metadataHydrationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            let hydrated = targets.map { $0.hydrated() }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.currentPath == targetPath else { return }
                var updatedItems = self.items
                var changed = false
                for item in hydrated {
                    if let index = updatedItems.firstIndex(where: { $0.url == item.url }) {
                        updatedItems[index] = item
                        changed = true
                    }
                }
                if changed {
                    self.items = updatedItems
                }
            }
        }
        metadataHydrationWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    func refresh() {
        loadContents()
    }

    // MARK: - Clipboard Operations

    var canPaste: Bool {
        !clipboardItems.isEmpty
    }

    func copySelectedItems() {
        guard !selectedItems.isEmpty else { return }
        clipboardItems = selectedItems.map { $0.url }
        clipboardOperation = .copy

        // Also copy to system pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(clipboardItems as [NSURL])
    }

    func cutSelectedItems() {
        guard !selectedItems.isEmpty else { return }
        clipboardItems = selectedItems.map { $0.url }
        clipboardOperation = .cut

        // Also copy to system pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(clipboardItems as [NSURL])
    }

    func paste() {
        guard !clipboardItems.isEmpty else { return }

        let fileManager = FileManager.default
        var pastedAny = false

        for sourceURL in clipboardItems {
            let destinationURL = currentPath.appendingPathComponent(sourceURL.lastPathComponent)

            // Handle name conflicts
            let finalDestination = uniqueDestinationURL(for: destinationURL)

            do {
                if clipboardOperation == .cut {
                    try fileManager.moveItem(at: sourceURL, to: finalDestination)
                } else {
                    try fileManager.copyItem(at: sourceURL, to: finalDestination)
                }
                pastedAny = true
            } catch {
                print("Failed to paste \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if clipboardOperation == .cut && pastedAny {
            clipboardItems.removeAll()
        }

        refresh()
    }

    func deleteSelectedItems() {
        guard !selectedItems.isEmpty else { return }

        let fileManager = FileManager.default

        for item in selectedItems {
            do {
                try fileManager.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                print("Failed to delete \(item.name): \(error.localizedDescription)")
            }
        }

        selectedItems.removeAll()
        refresh()
    }

    func handleDrop(urls: [URL], to destPath: URL? = nil) {
        let destination = destPath ?? currentPath
        let shouldMove = NSEvent.modifierFlags.contains(.option)

        for sourceURL in urls {
            if sourceURL.deletingLastPathComponent() == destination { continue }

            let destURL = destination.appendingPathComponent(sourceURL.lastPathComponent)
            let finalURL = uniqueDestinationURL(for: destURL)

            do {
                if shouldMove {
                    try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                } else {
                    try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                }
            } catch {
                print("Failed to \(shouldMove ? "move" : "copy") \(sourceURL.lastPathComponent): \(error)")
            }
        }

        refresh()
    }

    func duplicateSelectedItems() {
        guard !selectedItems.isEmpty else { return }

        let fileManager = FileManager.default

        for item in selectedItems {
            let baseName = item.url.deletingPathExtension().lastPathComponent
            let ext = item.url.pathExtension
            var copyName = ext.isEmpty ? "\(baseName) copy" : "\(baseName) copy.\(ext)"
            var destinationURL = currentPath.appendingPathComponent(copyName)

            // Handle existing copies
            var copyNumber = 2
            while fileManager.fileExists(atPath: destinationURL.path) {
                copyName = ext.isEmpty ? "\(baseName) copy \(copyNumber)" : "\(baseName) copy \(copyNumber).\(ext)"
                destinationURL = currentPath.appendingPathComponent(copyName)
                copyNumber += 1
            }

            do {
                try fileManager.copyItem(at: item.url, to: destinationURL)
            } catch {
                print("Failed to duplicate \(item.name): \(error.localizedDescription)")
            }
        }

        refresh()
    }

    func renameItem(_ item: FileItem, to newName: String) {
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)

        guard newURL != item.url else { return }

        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
            refresh()
        } catch {
            print("Failed to rename \(item.name): \(error.localizedDescription)")
        }
    }

    func moveSelectedItemsToTrash() {
        deleteSelectedItems()
    }

    func getInfo() {
        guard let item = selectedItems.first else { return }
        infoItem = item
        NotificationCenter.default.post(name: .showGetInfo, object: item)
    }

    func showInFinder() {
        let urls = selectedItems.isEmpty ? [currentPath] : selectedItems.map { $0.url }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func createNewFolder() {
        let fileManager = FileManager.default
        var folderName = "untitled folder"
        var folderURL = currentPath.appendingPathComponent(folderName)

        var counter = 2
        while fileManager.fileExists(atPath: folderURL.path) {
            folderName = "untitled folder \(counter)"
            folderURL = currentPath.appendingPathComponent(folderName)
            counter += 1
        }

        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            refresh()
        } catch {
            print("Failed to create folder: \(error.localizedDescription)")
        }
    }

    func selectAll() {
        selectedItems = Set(items)
    }

    func uniqueDestinationURL(for url: URL) -> URL {
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
}

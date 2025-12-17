import Foundation
import SwiftUI
import Combine

enum ViewMode: String, CaseIterable {
    case coverFlow = "Cover Flow"
    case icons = "Icons"
    case list = "List"
    case columns = "Columns"
    case dualPane = "Dual Pane"

    var systemImage: String {
        switch self {
        case .coverFlow: return "square.stack.3d.forward.dottedline"
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .dualPane: return "rectangle.split.2x1"
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

    // Clipboard state
    @Published var clipboardItems: [URL] = []
    @Published var clipboardOperation: ClipboardOperation = .copy

    // Debug state
    @Published var showDebug: Bool = false

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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: pathToLoad,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .creationDateKey,
                        .contentTypeKey
                    ],
                    options: [.skipsHiddenFiles]
                )

                let fileItems = contents.map { FileItem(url: $0) }

                DispatchQueue.main.async {
                    self.items = fileItems
                    self.isLoading = false
                    self.coverFlowSelectedIndex = min(self.coverFlowSelectedIndex, max(0, fileItems.count - 1))
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

    func navigateToParent() {
        let parent = currentPath.deletingLastPathComponent()
        if parent != currentPath {
            navigateTo(parent)
        }
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = navigationHistory[historyIndex]
        selectedItems.removeAll()
        coverFlowSelectedIndex = 0
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
            navigateTo(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

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
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
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

    private func uniqueDestinationURL(for url: URL) -> URL {
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

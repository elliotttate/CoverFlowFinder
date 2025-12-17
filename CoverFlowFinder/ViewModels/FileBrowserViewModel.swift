import Foundation
import SwiftUI
import Combine

enum ViewMode: String, CaseIterable {
    case coverFlow = "Cover Flow"
    case icons = "Icons"
    case list = "List"
    case columns = "Columns"

    var systemImage: String {
        switch self {
        case .coverFlow: return "square.stack.3d.forward.dottedline"
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
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
}

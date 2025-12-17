import SwiftUI

struct ContentView: View {
    // Tab management
    @State private var tabs: [BrowserTab] = [BrowserTab()]
    @State private var selectedTabId: UUID = UUID()

    // Right pane for dual pane mode (shared across tabs for simplicity)
    @StateObject private var rightPaneViewModel: FileBrowserViewModel = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return FileBrowserViewModel(initialPath: desktop)
    }()

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var renamingItem: FileItem?
    @State private var renameText: String = ""
    @State private var activePane: DualPaneView.Pane = .left

    // Current tab's viewModel
    private var viewModel: FileBrowserViewModel {
        tabs.first(where: { $0.id == selectedTabId })?.viewModel ?? tabs[0].viewModel
    }

    // Binding to current viewModel's viewMode
    private var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { viewModel.viewMode },
            set: { viewModel.viewMode = $0 }
        )
    }

    // Binding to current viewModel's searchText
    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText },
            set: { viewModel.searchText = $0 }
        )
    }

    // Binding to current viewModel's infoItem
    private var infoItemBinding: Binding<FileItem?> {
        Binding(
            get: { viewModel.infoItem },
            set: { viewModel.infoItem = $0 }
        )
    }

    // The viewModel to navigate based on active pane in dual mode
    private var activeViewModel: FileBrowserViewModel {
        if viewModel.viewMode == .dualPane && activePane == .right {
            return rightPaneViewModel
        }
        return viewModel
    }

    // Initialize selectedTabId to first tab
    init() {
        let initialTab = BrowserTab()
        _tabs = State(initialValue: [initialTab])
        _selectedTabId = State(initialValue: initialTab.id)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: activeViewModel, isDualPane: viewModel.viewMode == .dualPane)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // Tab bar (show when more than 1 tab or always for discoverability)
                if tabs.count > 1 {
                    TabBarView(
                        tabs: $tabs,
                        selectedTabId: $selectedTabId,
                        onNewTab: addNewTab,
                        onCloseTab: closeTab
                    )
                    Divider()
                }

                if viewModel.viewMode == .dualPane {
                    // Dual pane mode - full width without path bar/status bar
                    DualPaneView(leftViewModel: viewModel, rightViewModel: rightPaneViewModel, activePane: $activePane)
                        .frame(minWidth: 700, minHeight: 400)
                        .id("dualpane-\(viewModel.currentPath.path)-\(selectedTabId)")
                } else {
                    VStack(spacing: 0) {
                        // Path bar
                        PathBarView(viewModel: viewModel)

                        Divider()

                        // Main content area
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewModel.filteredItems.isEmpty {
                            EmptyFolderView()
                        } else {
                            switch viewModel.viewMode {
                            case .coverFlow:
                                CoverFlowView(viewModel: viewModel, items: viewModel.filteredItems)
                                    .id("coverflow-\(viewModel.currentPath.path)-\(selectedTabId)")
                            case .icons:
                                IconGridView(viewModel: viewModel, items: viewModel.filteredItems)
                                    .id("icons-\(viewModel.currentPath.path)-\(selectedTabId)")
                            case .list:
                                FileListView(viewModel: viewModel, items: viewModel.filteredItems)
                                    .id("list-\(viewModel.currentPath.path)-\(selectedTabId)")
                            case .columns:
                                ColumnView(viewModel: viewModel, items: viewModel.filteredItems)
                                    .id("columns-\(viewModel.currentPath.path)-\(selectedTabId)")
                            case .dualPane:
                                EmptyView() // Handled above
                            }
                        }

                        // Status bar
                        StatusBarView(viewModel: viewModel)
                    }
                    .frame(minWidth: 500, minHeight: 400)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Back/Forward buttons
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)
                .help("Back")

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)
                .help("Forward")
            }

            ToolbarItem(placement: .principal) {
                // View mode picker
                Picker("View", selection: viewModeBinding) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("Change view mode")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Sort menu
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button(action: {
                            if viewModel.sortOption == option {
                                viewModel.sortAscending.toggle()
                            } else {
                                viewModel.sortOption = option
                                viewModel.sortAscending = true
                            }
                        }) {
                            HStack {
                                Text(option.rawValue)
                                if viewModel.sortOption == option {
                                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("Sort by")

                // Action menu
                Menu {
                    Button("New Folder") {
                        viewModel.createNewFolder()
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                    Divider()

                    Button("Get Info") {
                        viewModel.getInfo()
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(viewModel.selectedItems.isEmpty)

                    Divider()

                    Button("Show in Finder") {
                        viewModel.showInFinder()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Actions")

                // Search field
                TextField("Search", text: searchTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
        .navigationTitle(viewModel.currentPath.lastPathComponent)
        .focusedSceneValue(\.viewModel, viewModel)
        .onKeyPress(.delete) {
            viewModel.deleteSelectedItems()
            return .handled
        }
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
        .sheet(item: infoItemBinding) { (item: FileItem) in
            FileInfoView(item: item)
        }
        // Tab notifications from menu commands
        .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
            addNewTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
            closeTab(selectedTabId)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextTab)) { _ in
            selectNextTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .previousTab)) { _ in
            selectPreviousTab()
        }
    }

    // MARK: - Tab Management

    private func addNewTab() {
        let newTab = BrowserTab(initialPath: viewModel.currentPath)
        tabs.append(newTab)
        selectedTabId = newTab.id
    }

    private func closeTab(_ tabId: UUID) {
        guard tabs.count > 1 else { return }

        if let index = tabs.firstIndex(where: { $0.id == tabId }) {
            tabs.remove(at: index)

            // If we closed the selected tab, select an adjacent one
            if selectedTabId == tabId {
                let newIndex = min(index, tabs.count - 1)
                selectedTabId = tabs[newIndex].id
            }
        }
    }

    private func selectNextTab() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    private func selectPreviousTab() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        let prevIndex = currentIndex == 0 ? tabs.count - 1 : currentIndex - 1
        selectedTabId = tabs[prevIndex].id
    }
}

// MARK: - Context Menu for File Items

struct FileItemContextMenu: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    var onRename: (FileItem) -> Void

    var body: some View {
        Group {
            Button("Open") {
                viewModel.openItem(item)
            }

            Button("Open With...") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }

            Divider()

            Button("Get Info") {
                viewModel.selectItem(item)
                viewModel.getInfo()
            }

            Divider()

            Button("Copy") {
                viewModel.selectItem(item)
                viewModel.copySelectedItems()
            }

            Button("Cut") {
                viewModel.selectItem(item)
                viewModel.cutSelectedItems()
            }

            Button("Duplicate") {
                viewModel.selectItem(item)
                viewModel.duplicateSelectedItems()
            }

            Divider()

            Button("Rename") {
                onRename(item)
            }

            Button("Move to Trash") {
                viewModel.selectItem(item)
                viewModel.deleteSelectedItems()
            }

            Divider()

            Button("Show in Finder") {
                viewModel.selectItem(item)
                viewModel.showInFinder()
            }
        }
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    @Binding var isPresented: FileItem?
    @State private var newName: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename \"\(item.name)\"")
                .font(.headline)

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack {
                Button("Cancel") {
                    isPresented = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    viewModel.renameItem(item, to: newName)
                    isPresented = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty || newName == item.name)
            }
        }
        .padding(20)
        .onAppear {
            newName = item.name
        }
    }
}

struct PathBarView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    navigateToComponent(at: index)
                }) {
                    HStack(spacing: 4) {
                        if index == 0 {
                            Image(systemName: "desktopcomputer")
                                .font(.caption)
                        }
                        Text(component.name)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(index == pathComponents.count - 1 ? .primary : .secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var pathComponents: [(name: String, url: URL)] {
        var components: [(String, URL)] = []
        var url = viewModel.currentPath

        while url.path != "/" {
            components.insert((url.lastPathComponent, url), at: 0)
            url = url.deletingLastPathComponent()
        }
        components.insert(("Macintosh HD", URL(fileURLWithPath: "/")), at: 0)

        return components
    }

    private func navigateToComponent(at index: Int) {
        let url = pathComponents[index].url
        viewModel.navigateTo(url)
    }
}

struct StatusBarView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        HStack {
            Text("\(viewModel.filteredItems.count) items")
                .font(.caption)
                .foregroundColor(.secondary)

            if !viewModel.selectedItems.isEmpty {
                Text("• \(viewModel.selectedItems.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let totalSize = calculateTotalSize() {
                Text(totalSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func calculateTotalSize() -> String? {
        let files = viewModel.filteredItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { return nil }

        let total = files.reduce(0) { $0 + $1.size }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }
}

struct EmptyFolderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("This folder is empty")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// Focus value for keyboard shortcuts
struct ViewModelKey: FocusedValueKey {
    typealias Value = FileBrowserViewModel
}

extension FocusedValues {
    var viewModel: FileBrowserViewModel? {
        get { self[ViewModelKey.self] }
        set { self[ViewModelKey.self] = newValue }
    }
}

// Tab notification names
extension Notification.Name {
    static let newTab = Notification.Name("newTab")
    static let closeTab = Notification.Name("closeTab")
    static let nextTab = Notification.Name("nextTab")
    static let previousTab = Notification.Name("previousTab")
}

#Preview {
    ContentView()
}

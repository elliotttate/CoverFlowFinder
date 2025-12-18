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

    // Track viewMode changes to force re-render (workaround for computed viewModel)
    @State private var currentViewMode: ViewMode = .coverFlow

    // Track infoItem for Get Info sheet (needs to observe both viewModel and rightPaneViewModel)
    @State private var showingInfoItem: FileItem?

    // Focus state for search field
    @FocusState private var isSearchFocused: Bool

    // Track navigation state to force toolbar updates (workaround for computed viewModel)
    @State private var navHistoryIndex: Int = 0
    @State private var navHistoryCount: Int = 1

    // Current tab's viewModel
    private var viewModel: FileBrowserViewModel {
        tabs.first(where: { $0.id == selectedTabId })?.viewModel ?? tabs[0].viewModel
    }

    // Binding to current viewModel's viewMode (also updates local state for re-rendering)
    private var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { viewModel.viewMode },
            set: { newValue in
                viewModel.viewMode = newValue
                currentViewMode = newValue
            }
        )
    }

    // Binding to current viewModel's searchText
    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText },
            set: { viewModel.searchText = $0 }
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
            SidebarView(viewModel: activeViewModel, isDualPane: currentViewMode == .dualPane)
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

                if currentViewMode == .dualPane {
                    // Dual pane mode - full width without path bar/status bar
                    DualPaneView(leftViewModel: viewModel, rightViewModel: rightPaneViewModel, activePane: $activePane)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minWidth: 700, minHeight: 400)
                        .id("dualpane-\(viewModel.currentPath.path)-\(selectedTabId)")
                } else {
                    // Use wrapper view to properly observe viewModel changes
                    TabContentWrapper(viewModel: viewModel, selectedTabId: selectedTabId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            // Back/Forward buttons - placed in navigation area (left side)
            ToolbarItem(placement: .navigation) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(navHistoryIndex <= 0)
                .help("Back")
            }

            ToolbarItem(placement: .navigation) {
                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(navHistoryIndex >= navHistoryCount - 1)
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
                    .focused($isSearchFocused)
            }
        }
        .navigationTitle(viewModel.currentPath.lastPathComponent)
        .focusedSceneValue(\.viewModel, viewModel)
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
        .sheet(item: $showingInfoItem) { item in
            FileInfoView(item: item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGetInfo)) { notification in
            if let item = notification.object as? FileItem {
                showingInfoItem = item
            }
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
        // Sync currentViewMode when tab changes
        .onChange(of: selectedTabId) { _ in
            currentViewMode = viewModel.viewMode
            syncNavigationState()
        }
        .onAppear {
            currentViewMode = viewModel.viewMode
            syncNavigationState()
        }
        // Observe navigation changes from the viewModel
        .onReceive(viewModel.$historyIndex) { newIndex in
            navHistoryIndex = newIndex
        }
        .onReceive(viewModel.$navigationHistory) { newHistory in
            navHistoryCount = newHistory.count
        }
        .background(QuickLookWindowController())
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

    private func syncNavigationState() {
        navHistoryIndex = viewModel.historyIndex
        navHistoryCount = viewModel.navigationHistory.count
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
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isEditing {
                // Editable text field
                TextField("Path", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        navigateToPath(editText)
                    }
                    .onExitCommand {
                        cancelEditing()
                    }
                    .onAppear {
                        editText = viewModel.currentPath.path
                        isTextFieldFocused = true
                    }

                Button(action: { navigateToPath(editText) }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                Button(action: { cancelEditing() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                // Breadcrumb path display
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            startEditing()
        }
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
        viewModel.navigateToAndSelectCurrent(url)
    }

    private func startEditing() {
        editText = viewModel.currentPath.path
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        isTextFieldFocused = false
    }

    private func navigateToPath(_ path: String) {
        var expandedPath = path.trimmingCharacters(in: .whitespaces)

        // Expand ~ to home directory
        if expandedPath.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expandedPath = home + expandedPath.dropFirst()
        }

        let url = URL(fileURLWithPath: expandedPath)

        // Validate path exists and is a directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                viewModel.navigateTo(url)
                isEditing = false
                isTextFieldFocused = false
            } else {
                // It's a file - navigate to its parent and select it
                let parentURL = url.deletingLastPathComponent()
                viewModel.navigateTo(parentURL)
                // TODO: Could select the file after navigation
                isEditing = false
                isTextFieldFocused = false
            }
        } else {
            // Invalid path - shake or show error? For now just beep
            NSSound.beep()
        }
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

// Wrapper view that properly observes the viewModel via @ObservedObject
struct TabContentWrapper: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let selectedTabId: UUID

    var body: some View {
        VStack(spacing: 0) {
            // Path bar
            PathBarView(viewModel: viewModel)

            Divider()

            // Main content area
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredItems.isEmpty {
                    EmptyFolderView()
                } else {
                    mainContentView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar
            StatusBarView(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var mainContentView: some View {
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
            EmptyView() // Handled in parent
        }
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

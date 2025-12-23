import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.undoManager) private var undoManager
    @State private var tabs: [BrowserTab] = [BrowserTab()]
    @State private var selectedTabId: UUID = UUID()

    @StateObject private var rightPaneViewModel: FileBrowserViewModel = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return FileBrowserViewModel(initialPath: desktop)
    }()

    @StateObject private var bottomLeftPaneViewModel: FileBrowserViewModel = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return FileBrowserViewModel(initialPath: downloads)
    }()

    @StateObject private var bottomRightPaneViewModel: FileBrowserViewModel = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return FileBrowserViewModel(initialPath: documents)
    }()

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activePane: DualPaneView.Pane = .left
    @State private var activeQuadPane: QuadPaneView.Pane = .topLeft
    @State private var currentViewMode: ViewMode = .coverFlow
    @State private var showingInfoItem: FileItem?
    @FocusState private var isSearchFocused: Bool
    @State private var navHistoryIndex: Int = 0
    @State private var navHistoryCount: Int = 1
    @State private var showingEverythingSearchAlert: Bool = false
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared

    private var viewModel: FileBrowserViewModel {
        tabs.first(where: { $0.id == selectedTabId })?.viewModel ?? tabs[0].viewModel
    }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { viewModel.viewMode },
            set: { newValue in
                viewModel.viewMode = newValue
                currentViewMode = newValue
            }
        )
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { viewModel.searchText },
            set: { viewModel.searchText = $0 }
        )
    }

    private var searchModeBinding: Binding<SearchMode> {
        Binding(
            get: { viewModel.searchMode },
            set: { viewModel.searchMode = $0 }
        )
    }

    private var activeViewModel: FileBrowserViewModel {
        if viewModel.viewMode == .dualPane && activePane == .right {
            return rightPaneViewModel
        } else if viewModel.viewMode == .quadPane {
            switch activeQuadPane {
            case .topLeft: return viewModel
            case .topRight: return rightPaneViewModel
            case .bottomLeft: return bottomLeftPaneViewModel
            case .bottomRight: return bottomRightPaneViewModel
            }
        }
        return viewModel
    }

    private var viewModePickerWidth: CGFloat {
        let count = CGFloat(ViewMode.allCases.count)
        return min(420, max(260, count * 48))
    }

    init() {
        let initialTab = BrowserTab()
        _tabs = State(initialValue: [initialTab])
        _selectedTabId = State(initialValue: initialTab.id)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: activeViewModel, isDualPane: currentViewMode == .dualPane || currentViewMode == .quadPane)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            VStack(spacing: 0) {
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
                    DualPaneView(leftViewModel: viewModel, rightViewModel: rightPaneViewModel, activePane: $activePane)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minWidth: 700, minHeight: 400)
                        .id("dualpane-\(viewModel.currentPath.path)-\(selectedTabId)")
                } else if currentViewMode == .quadPane {
                    QuadPaneView(
                        topLeftViewModel: viewModel,
                        topRightViewModel: rightPaneViewModel,
                        bottomLeftViewModel: bottomLeftPaneViewModel,
                        bottomRightViewModel: bottomRightPaneViewModel,
                        activePane: $activeQuadPane
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 800, minHeight: 600)
                    .id("quadpane-\(viewModel.currentPath.path)-\(selectedTabId)")
                } else {
                    TabContentWrapper(viewModel: viewModel, selectedTabId: selectedTabId)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
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
                Picker("View", selection: viewModeBinding) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                            .help(mode.rawValue)
                            .accessibilityLabel(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: viewModePickerWidth)
                .help("Change view mode")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Sort menu
                Menu {
                    ForEach(ListColumn.allCases) { column in
                        Button(action: {
                            columnConfig.setSortColumn(column)
                        }) {
                            HStack {
                                Text(column.rawValue)
                                if columnConfig.sortColumn == column {
                                    Image(systemName: columnConfig.sortDirection == .ascending ? "chevron.up" : "chevron.down")
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

                // Search mode picker and search field
                HStack(spacing: 4) {
                    // Search mode picker
                    Menu {
                        ForEach(SearchMode.allCases, id: \.self) { mode in
                            if mode != .everything || settings.everythingSearchEnabled {
                                Button {
                                    viewModel.searchMode = mode
                                } label: {
                                    Label(mode.rawValue, systemImage: mode.systemImage)
                                }
                            }
                        }

                        if !settings.everythingSearchEnabled {
                            Divider()
                            Button {
                                showingEverythingSearchAlert = true
                            } label: {
                                Label("Enable Everything Search...", systemImage: "sparkle.magnifyingglass")
                            }
                        }
                    } label: {
                        Label(viewModel.searchMode.rawValue, systemImage: viewModel.searchMode.systemImage)
                            .frame(width: 90, alignment: .leading)
                    }
                    .frame(width: 110)
                    .help("Search mode: \(viewModel.searchMode.rawValue)")

                    // Search field
                    SearchField(text: searchTextBinding, placeholder: viewModel.searchMode.placeholder)
                        .frame(width: 180)

                    // Sort picker for Everything/Finder search results
                    if viewModel.searchMode != .filter && !viewModel.searchText.isEmpty {
                        Menu {
                            ForEach(SearchSortOption.allCases, id: \.self) { option in
                                Button {
                                    if viewModel.searchSortOption == option {
                                        viewModel.searchSortAscending.toggle()
                                    } else {
                                        viewModel.searchSortOption = option
                                        viewModel.searchSortAscending = true
                                    }
                                } label: {
                                    HStack {
                                        Label(option.rawValue, systemImage: option.systemImage)
                                        if viewModel.searchSortOption == option {
                                            Spacer()
                                            Image(systemName: viewModel.searchSortAscending ? "chevron.up" : "chevron.down")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label(viewModel.searchSortOption.rawValue, systemImage: viewModel.searchSortAscending ? "chevron.up" : "chevron.down")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Sort by: \(viewModel.searchSortOption.rawValue) (\(viewModel.searchSortAscending ? "ascending" : "descending"))")
                    }

                    // Loading indicator
                    if viewModel.isSearching {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    }
                }
            }
        }
        .navigationTitle(viewModel.currentPath.lastPathComponent)
        .focusedSceneValue(\.viewModel, viewModel)
        .sheet(item: $showingInfoItem) { item in
            FileInfoView(item: item)
        }
        .alert("Enable Everything Search", isPresented: $showingEverythingSearchAlert) {
            Button("Enable") {
                settings.everythingSearchEnabled = true
                // Open Settings to Search tab so user can monitor progress
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everything Search indexes your entire filesystem for instant searches.\n\nThis requires a one-time indexing process that runs in the background. You can monitor progress in Settings > Search.")
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
            assignUndoManager()
        }
        .onAppear {
            currentViewMode = viewModel.viewMode
            syncNavigationState()
            assignUndoManager()
        }
        .onChange(of: settings.showHiddenFiles) { _ in
            refreshAllViewModels()
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
        newTab.viewModel.setUndoManager(undoManager)
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

    private func refreshAllViewModels() {
        for tab in tabs {
            tab.viewModel.refresh()
        }
        rightPaneViewModel.refresh()
        bottomLeftPaneViewModel.refresh()
        bottomRightPaneViewModel.refresh()
    }

    private func assignUndoManager() {
        let manager = undoManager
        for tab in tabs {
            tab.viewModel.setUndoManager(manager)
        }
        rightPaneViewModel.setUndoManager(manager)
        bottomLeftPaneViewModel.setUndoManager(manager)
        bottomRightPaneViewModel.setUndoManager(manager)
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
            .disabled(item.isFromArchive)

            Divider()

            Button("Get Info") {
                viewModel.selectItem(item)
                viewModel.getInfo()
            }
            .disabled(item.isFromArchive)

            Divider()

            // Tags submenu
            if !item.isFromArchive {
                Menu("Tags") {
                    ForEach(FinderTag.allTags) { tag in
                        Button {
                            viewModel.toggleTag(tag.name, for: item.url)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                Text(tag.name)
                                if item.tags.contains(tag.name) {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    if !item.tags.isEmpty {
                        Divider()
                        Button("Remove All Tags") {
                            viewModel.setTags([], for: item.url)
                        }
                    }
                }

                Divider()
            }

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
            .disabled(item.isFromArchive)

            Divider()

            Button("Rename") {
                onRename(item)
            }
            .disabled(item.isFromArchive)

            Button("Move to Trash") {
                viewModel.selectItem(item)
                viewModel.deleteSelectedItems()
            }
            .disabled(item.isFromArchive)

            Divider()

            Button("Show in Finder") {
                viewModel.selectItem(item)
                viewModel.showInFinder()
            }
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
                // Breadcrumb path display - use archive-aware path components
                ForEach(Array(viewModel.pathComponents.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 4) {
                        if index == 0 {
                            Image(systemName: "desktopcomputer")
                                .font(.caption)
                        } else if component.archivePath != nil && component.archivePath == "" {
                            // This is the ZIP file itself
                            Image(systemName: "doc.zipper")
                                .font(.caption)
                        } else if component.url == nil && component.archivePath != nil {
                            // Folder inside archive
                            Image(systemName: "folder.fill")
                                .font(.caption)
                        }
                        Text(component.name)
                            .lineLimit(1)
                    }
                    .foregroundColor(index == viewModel.pathComponents.count - 1 ? .primary : .secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navigateToComponent(at: index)
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.001))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        startEditing()
                    }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func navigateToComponent(at index: Int) {
        let component = viewModel.pathComponents[index]

        if let url = component.url {
            // Regular filesystem navigation
            if viewModel.isInsideArchive {
                viewModel.exitArchive()
            }
            viewModel.navigateToAndSelectCurrent(url)
        } else if let archivePath = component.archivePath {
            // Navigate within archive
            viewModel.navigateInArchive(to: archivePath)
        }
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
                let parentURL = url.deletingLastPathComponent()
                viewModel.navigateTo(parentURL)
                isEditing = false
                isTextFieldFocused = false
            }
        } else {
            NSSound.beep()
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        HStack {
            Text("\(viewModel.filteredItems.count) items")
                .font(settings.listDetailFont)
                .foregroundColor(.secondary)

            if !viewModel.selectedItems.isEmpty {
                Text("• \(viewModel.selectedItems.count) selected")
                    .font(settings.listDetailFont)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let totalSize = calculateTotalSize() {
                Text(totalSize)
                    .font(settings.listDetailFont)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func calculateTotalSize() -> String? {
        if viewModel.isPhotosLibraryActive {
            return nil
        }
        let files = viewModel.filteredItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { return nil }

        let total = files.reduce(0) { $0 + $1.size }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }
}

struct EmptyFolderView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

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
        .contextMenu {
            Button("New Folder") {
                viewModel.createNewFolder()
            }

            if viewModel.canPaste {
                Button("Paste") {
                    viewModel.paste()
                }
            }

            Divider()

            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([viewModel.currentPath])
            }
        }
    }
}

// Wrapper view that properly observes the viewModel via @ObservedObject
struct TabContentWrapper: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let selectedTabId: UUID

    var body: some View {
        VStack(spacing: 0) {
            // Path bar
            if settings.showPathBar {
                PathBarView(viewModel: viewModel)
                Divider()
            }

            // Main content area
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredItems.isEmpty {
                    EmptyFolderView(viewModel: viewModel)
                } else {
                    mainContentView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Status bar
            if settings.showStatusBar {
                StatusBarView(viewModel: viewModel)
            }
        }
    }

    // Generate a unique ID for view refresh that includes archive state
    private var contentViewId: String {
        let archiveId = viewModel.isInsideArchive ? "-archive-\(viewModel.currentArchivePath)" : ""
        return "\(viewModel.currentPath.path)-\(selectedTabId)\(archiveId)-\(viewModel.navigationGeneration)"
    }

    @ViewBuilder
    private var mainContentView: some View {
        switch viewModel.viewMode {
        case .coverFlow:
            CoverFlowView(viewModel: viewModel, items: viewModel.filteredItems)
                .id("coverflow-\(contentViewId)")
        case .icons:
            IconGridView(viewModel: viewModel, items: viewModel.filteredItems)
                .id("icons-\(contentViewId)")
        case .masonry:
            if viewModel.isPhotosLibraryActive {
                PhotosMasonryView(viewModel: viewModel, items: viewModel.filteredItems)
                    .id("masonry-photos-\(contentViewId)")
            } else {
                MasonryView(viewModel: viewModel, items: viewModel.filteredItems)
                    .id("masonry-\(contentViewId)")
            }
        case .list:
            FileListView(viewModel: viewModel, items: viewModel.filteredItems)
                .id("list-\(contentViewId)")
        case .columns:
            ColumnView(viewModel: viewModel, items: viewModel.filteredItems)
                .id("columns-\(contentViewId)")
        case .dualPane, .quadPane:
            EmptyView()
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

// Tab notification names are defined in UIConstants.swift

// Native macOS search field
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchFieldAction(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Update placeholder if it changed
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let searchField = obj.object as? NSSearchField {
                updateText(from: searchField)
            }
        }

        @objc func searchFieldAction(_ sender: NSSearchField) {
            // Called when X button is clicked or Enter is pressed
            DispatchQueue.main.async { [weak self] in
                self?.updateText(from: sender)
            }
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            // Called when search is cancelled (X button clicked)
            updateText(from: sender)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if let searchField = obj.object as? NSSearchField {
                updateText(from: searchField)
            }
        }

        private func updateText(from searchField: NSSearchField) {
            let newValue = searchField.stringValue
            if parent.text != newValue {
                parent.text = newValue
            }
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
}
#endif

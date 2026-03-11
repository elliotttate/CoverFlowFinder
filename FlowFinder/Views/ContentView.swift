import SwiftUI
import AppKit

@MainActor
final class AuxiliaryPaneStore: ObservableObject {
    private var rightPaneStorage: FileBrowserViewModel?
    private var bottomLeftPaneStorage: FileBrowserViewModel?
    private var bottomRightPaneStorage: FileBrowserViewModel?

    var loadedViewModels: [FileBrowserViewModel] {
        [rightPaneStorage, bottomLeftPaneStorage, bottomRightPaneStorage].compactMap { $0 }
    }

    var rightPaneViewModel: FileBrowserViewModel {
        if let viewModel = rightPaneStorage {
            return viewModel
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let viewModel = FileBrowserViewModel(initialPath: desktop)
        rightPaneStorage = viewModel
        return viewModel
    }

    var bottomLeftPaneViewModel: FileBrowserViewModel {
        if let viewModel = bottomLeftPaneStorage {
            return viewModel
        }

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let viewModel = FileBrowserViewModel(initialPath: downloads)
        bottomLeftPaneStorage = viewModel
        return viewModel
    }

    var bottomRightPaneViewModel: FileBrowserViewModel {
        if let viewModel = bottomRightPaneStorage {
            return viewModel
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let viewModel = FileBrowserViewModel(initialPath: documents)
        bottomRightPaneStorage = viewModel
        return viewModel
    }
}

private struct ViewModelActivitySyncView: View {
    let selectedTabId: UUID
    let currentViewMode: ViewMode
    let activePane: DualPaneView.Pane
    let activeQuadPane: QuadPaneView.Pane
    let scenePhase: ScenePhase
    let tabIDs: [UUID]
    let showHiddenFiles: Bool
    let onAppearAction: () -> Void
    let onSelectedTabChange: () -> Void
    let onRefreshAll: () -> Void
    let onUpdateActivity: () -> Void
    let onTabsChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: onAppearAction)
            .onChange(of: selectedTabId) { _ in
                onSelectedTabChange()
            }
            .onChange(of: currentViewMode) { _ in
                onUpdateActivity()
            }
            .onChange(of: activePane) { _ in
                onUpdateActivity()
            }
            .onChange(of: activeQuadPane) { _ in
                onUpdateActivity()
            }
            .onChange(of: scenePhase) { _ in
                onUpdateActivity()
            }
            .onChange(of: tabIDs) { _ in
                onTabsChange()
            }
            .onChange(of: showHiddenFiles) { _ in
                onRefreshAll()
            }
    }
}

private struct NotificationReceivers: ViewModifier {
    @Binding var showingInfoItem: FileItem?
    let onNewTab: () -> Void
    let onCloseTab: () -> Void
    let onNextTab: () -> Void
    let onPreviousTab: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showGetInfo)) { notification in
                if let item = notification.object as? FileItem {
                    showingInfoItem = item
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
                onNewTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
                onCloseTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextTab)) { _ in
                onNextTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .previousTab)) { _ in
                onPreviousTab()
            }
    }
}

struct ContentView: View {

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var tabs: [BrowserTab] = [BrowserTab()]
    @State private var selectedTabId: UUID = UUID()
    @StateObject private var auxiliaryPaneStore = AuxiliaryPaneStore()

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activePane: DualPaneView.Pane = .left
    @State private var activeQuadPane: QuadPaneView.Pane = .topLeft
    @State private var currentViewMode: ViewMode = .coverFlow
    @State private var showingInfoItem: FileItem?
    @FocusState private var isSearchFocused: Bool
    @State private var navHistoryIndex: Int = 0
    @State private var navHistoryCount: Int = 1
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared

    private var viewModel: FileBrowserViewModel {
        tabs.first(where: { $0.id == selectedTabId })?.viewModel ?? tabs[0].viewModel
    }

    private var rightPaneViewModel: FileBrowserViewModel {
        auxiliaryPaneStore.rightPaneViewModel
    }

    private var bottomLeftPaneViewModel: FileBrowserViewModel {
        auxiliaryPaneStore.bottomLeftPaneViewModel
    }

    private var bottomRightPaneViewModel: FileBrowserViewModel {
        auxiliaryPaneStore.bottomRightPaneViewModel
    }

    private var viewModeBinding: Binding<ViewMode> {
        Binding(
            get: { viewModel.viewMode },
            set: { newValue in
                DispatchQueue.main.async {
                    viewModel.viewMode = newValue
                    currentViewMode = newValue
                }
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

    private var visibleViewModels: [FileBrowserViewModel] {
        switch currentViewMode {
        case .dualPane:
            return [viewModel, rightPaneViewModel]
        case .quadPane:
            return [viewModel, rightPaneViewModel, bottomLeftPaneViewModel, bottomRightPaneViewModel]
        default:
            return [viewModel]
        }
    }

    private var managedViewModels: [FileBrowserViewModel] {
        deduplicatedViewModels(tabs.map(\.viewModel) + auxiliaryPaneStore.loadedViewModels)
    }

    private var viewModePickerWidth: CGFloat {
        let count = CGFloat(ViewMode.allCases.count)
        return min(380, max(220, count * 40))
    }

    init() {
        let initialTab = BrowserTab()
        _tabs = State(initialValue: [initialTab])
        _selectedTabId = State(initialValue: initialTab.id)
    }

    var body: some View {
        splitView
            .toolbar { toolbarItems }
            .navigationTitle(viewModel.currentPath.lastPathComponent)
            .focusedSceneValue(\.viewModel, viewModel)
            .sheet(item: $showingInfoItem) { item in
                FileInfoView(item: item)
            }
            .modifier(NotificationReceivers(
                showingInfoItem: $showingInfoItem,
                onNewTab: addNewTab,
                onCloseTab: { closeTab(selectedTabId) },
                onNextTab: selectNextTab,
                onPreviousTab: selectPreviousTab
            ))
            .onReceive(viewModel.$historyIndex) { newIndex in
                navHistoryIndex = newIndex
            }
            .onReceive(viewModel.$navigationHistory) { newHistory in
                navHistoryCount = newHistory.count
            }
            .background(activitySyncView)
            .background(QuickLookWindowController())
            .background(LiquidGlassWindowConfigurator())
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
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
            toolbarActions
        }
    }

    private var activitySyncView: some View {
        ViewModelActivitySyncView(
            selectedTabId: selectedTabId,
            currentViewMode: currentViewMode,
            activePane: activePane,
            activeQuadPane: activeQuadPane,
            scenePhase: scenePhase,
            tabIDs: tabs.map(\.id),
            showHiddenFiles: settings.showHiddenFiles,
            onAppearAction: {
                currentViewMode = viewModel.viewMode
                syncNavigationState()
                assignUndoManager()
                updateViewModelActivity()
            },
            onSelectedTabChange: {
                currentViewMode = viewModel.viewMode
                syncNavigationState()
                assignUndoManager()
                updateViewModelActivity()
            },
            onRefreshAll: refreshAllViewModels,
            onUpdateActivity: updateViewModelActivity,
            onTabsChange: {
                assignUndoManager()
                updateViewModelActivity()
            }
        )
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: activeViewModel, isDualPane: currentViewMode == .dualPane || currentViewMode == .quadPane)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
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

    @ViewBuilder
    private var toolbarActions: some View {
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

        HStack(spacing: 2) {
            Menu {
                ForEach(SearchMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.searchMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                    }
                }
            } label: {
                Label(viewModel.searchMode.rawValue, systemImage: viewModel.searchMode.systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .id("search-mode-\(viewModel.searchMode.rawValue)")
            .fixedSize()
            .help("Search mode: \(viewModel.searchMode.rawValue)")

            SearchField(text: searchTextBinding, placeholder: viewModel.searchMode.placeholder)
                .frame(width: 180)
                .id("main-search-field")

            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
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
        for viewModel in visibleViewModels {
            viewModel.refresh()
        }
    }

    private func assignUndoManager() {
        let manager = undoManager
        for tab in tabs {
            tab.viewModel.setUndoManager(manager)
        }
        for viewModel in auxiliaryPaneStore.loadedViewModels {
            viewModel.setUndoManager(manager)
        }
    }

    private func updateViewModelActivity() {
        assignUndoManager()

        // Visible VMs are always active — scenePhase only affects non-visible auxiliary panes.
        // On macOS, scenePhase can be unreliable (may not report .active promptly at startup),
        // so we never suspend the primary/visible view models based on it.
        let visibleIdentifiers = Set(visibleViewModels.map { ObjectIdentifier($0) })

        for viewModel in managedViewModels {
            let isVisible = visibleIdentifiers.contains(ObjectIdentifier(viewModel))
            let isActive = isVisible || scenePhase == .active
            viewModel.setBackgroundWorkActive(isActive)
        }
    }

    private func deduplicatedViewModels(_ viewModels: [FileBrowserViewModel]) -> [FileBrowserViewModel] {
        var seen = Set<ObjectIdentifier>()
        return viewModels.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

// MARK: - Context Menu for File Items

struct FileItemContextMenu: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    var onRename: (FileItem) -> Void

    private var isPackage: Bool {
        let packageExtensions = ["app", "bundle", "framework", "plugin", "kext", "prefPane", "qlgenerator", "saver", "wdgt", "xpc"]
        let ext = item.url.pathExtension.lowercased()
        return packageExtensions.contains(ext) || NSWorkspace.shared.isFilePackage(atPath: item.url.path)
    }

    var body: some View {
        Group {
            Button("Open") {
                viewModel.openItem(item)
            }

            // Show Package Contents option for bundles like .app
            if isPackage {
                Button("Show Package Contents") {
                    viewModel.navigateTo(item.url)
                }
            }

            if !item.isFromArchive && !item.isDirectory {
                OpenWithSubmenu(fileURLs: [item.url])
            }

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

            // iCloud actions (only show for iCloud items)
            if item.isInICloud && !item.isFromArchive {
                if item.cloudStatus?.canDownload == true {
                    Button("Download Now") {
                        viewModel.downloadCloudItem(item)
                    }
                }

                if item.cloudStatus?.canEvict == true {
                    Button("Remove Download") {
                        viewModel.evictCloudItem(item)
                    }
                }

                if item.cloudStatus == .hasConflict {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
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

    private var hasSearchText: Bool {
        !viewModel.searchText.isEmpty
    }

    private var isFinderSearchEmptyState: Bool {
        viewModel.searchMode == .finder && hasSearchText
    }

    private var titleText: String {
        if isFinderSearchEmptyState {
            return "No search results"
        }
        if hasSearchText || viewModel.filterTag != nil {
            return "No matching items"
        }
        return "This folder is empty"
    }

    private var subtitleText: String? {
        if isFinderSearchEmptyState {
            return "No results for \"\(viewModel.searchText)\" in this location."
        }
        if hasSearchText, let tag = viewModel.filterTag {
            return "No items match \"\(viewModel.searchText)\" with the tag \"\(tag)\"."
        }
        if hasSearchText {
            return "No items match \"\(viewModel.searchText)\" in this folder."
        }
        if let tag = viewModel.filterTag {
            return "No items in this folder have the tag \"\(tag)\"."
        }
        return nil
    }

    private var iconName: String {
        if isFinderSearchEmptyState {
            return "magnifyingglass"
        }
        if viewModel.filterTag != nil {
            return "tag"
        }
        if hasSearchText {
            return "line.3.horizontal.decrease.circle"
        }
        return "folder"
    }

    private var clearSearchButtonTitle: String {
        viewModel.searchMode == .finder ? "Clear Search" : "Clear Filter"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text(titleText)
                .font(.title2)
                .foregroundColor(.secondary)

            if let subtitleText {
                Text(subtitleText)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if hasSearchText || viewModel.filterTag != nil {
                HStack(spacing: 12) {
                    if hasSearchText {
                        Button(clearSearchButtonTitle) {
                            viewModel.clearSearchQuery()
                        }
                    }

                    if viewModel.filterTag != nil {
                        Button("Clear Tag Filter") {
                            viewModel.filterTag = nil
                        }
                    }
                }
            }
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
                if shouldShowProgressView {
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

    private var shouldShowProgressView: Bool {
        viewModel.isLoading ||
        (viewModel.isSearching && viewModel.searchMode == .finder && !viewModel.searchText.isEmpty)
    }

    // Generate a unique ID for view refresh that includes archive state and search results
    // Note: Don't include navigationGeneration for scroll-preserving views (CoverFlow, Masonry)
    // to prevent scroll position reset during refresh
    private var contentViewId: String {
        let archiveId = viewModel.isInsideArchive ? "-archive-\(viewModel.currentArchivePath)" : ""
        let searchId = "-\(viewModel.searchMode.rawValue)-\(viewModel.searchResults.count)"
        return "\(viewModel.currentPath.path)-\(selectedTabId)\(archiveId)\(searchId)"
    }

    // Full content view ID including navigation generation - use for views that should reset on navigation
    private var fullContentViewId: String {
        return "\(contentViewId)-\(viewModel.navigationGeneration)"
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

        // Store reference for focus handling
        context.coordinator.searchField = searchField

        // Listen for focus notification
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusSearchField),
            name: .focusSearch,
            object: nil
        )

        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        // Only update text if different AND the field is not being actively edited
        // This prevents interference with user typing
        let isFirstResponder = nsView.window?.firstResponder == nsView.currentEditor()
        if nsView.stringValue != text && !isFirstResponder {
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
        weak var searchField: NSSearchField?

        init(_ parent: SearchField) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func focusSearchField() {
            guard let searchField = searchField,
                  let window = searchField.window else { return }
            window.makeFirstResponder(searchField)
        }

        // Handle Escape key to unfocus the search field and return focus to file list
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape pressed - return focus to file list
                // Post notification for FileTableView to handle (it will make itself first responder)
                NotificationCenter.default.post(name: .focusFileList, object: nil)

                // Fallback: if no view took focus (still on search field), focus content view
                // This allows KeyboardManager to handle keyboard for SwiftUI views
                DispatchQueue.main.async {
                    guard let window = control.window else { return }
                    // Only change focus if still on a text field (no one else took focus)
                    if let firstResponder = window.firstResponder,
                       firstResponder is NSTextView || firstResponder is NSText {
                        if let contentView = window.contentView {
                            window.makeFirstResponder(contentView)
                        }
                    }
                }
                return true
            }
            return false
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

// MARK: - Liquid Glass Window Configurator

/// Placeholder - Liquid Glass effect is now applied via FeatheredBlurOverlay in scroll views
struct LiquidGlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Feathered Blur Overlay

/// A SwiftUI view that creates the feathered blur effect at the top of scroll content.
/// Uses NSVisualEffectView with withinWindow blending and a gradient mask.
struct FeatheredBlurOverlay: NSViewRepresentable {
    let height: CGFloat

    init(height: CGFloat = 60) {
        self.height = height
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let blurView = NSVisualEffectView()
        blurView.material = .headerView
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.wantsLayer = true

        // Create and apply the gradient mask
        blurView.maskImage = createFeatheredMask(height: height)

        return blurView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // Update mask if height changes
        nsView.maskImage = createFeatheredMask(height: height)
    }

    private func createFeatheredMask(height: CGFloat) -> NSImage {
        let maskImage = NSImage(size: NSSize(width: 1, height: height))

        maskImage.lockFocus()

        // Gradient from opaque at top to transparent at bottom
        let gradient = NSGradient(colors: [
            NSColor(white: 0.0, alpha: 1.0),  // Full blur at top
            NSColor(white: 0.0, alpha: 0.5),  // Fading
            NSColor(white: 0.0, alpha: 0.0)   // No blur at bottom
        ], atLocations: [0.0, 0.4, 1.0], colorSpace: .deviceGray)

        gradient?.draw(in: NSRect(x: 0, y: 0, width: 1, height: height), angle: 270)

        maskImage.unlockFocus()

        maskImage.resizingMode = .stretch
        return maskImage
    }
}

/// View modifier that adds the feathered blur overlay at the top of a view
struct FeatheredBlurModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            FeatheredBlurOverlay(height: height)
                .frame(height: height)
                .allowsHitTesting(false)  // Pass through mouse events
        }
    }
}

extension View {
    /// Adds a feathered blur effect at the top of the view (Liquid Glass style)
    func featheredTopBlur(height: CGFloat = 60) -> some View {
        modifier(FeatheredBlurModifier(height: height))
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(AppSettings.shared)
}
#endif

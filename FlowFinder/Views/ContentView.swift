import SwiftUI
import AppKit
import Combine

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

/// The window a `ContentView` lives in. Deliberately not published: knowing the window never
/// needs to re-render anything.
@MainActor
final class HostWindowBox: ObservableObject {
    weak var window: NSWindow?
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
            .onChange(of: selectedTabId) { _, _ in
                onSelectedTabChange()
            }
            .onChange(of: currentViewMode) { _, _ in
                onUpdateActivity()
            }
            .onChange(of: activePane) { _, _ in
                onUpdateActivity()
            }
            .onChange(of: activeQuadPane) { _, _ in
                onUpdateActivity()
            }
            .onChange(of: scenePhase) { _, _ in
                onUpdateActivity()
            }
            .onChange(of: tabIDs) { _, _ in
                onTabsChange()
            }
            .onChange(of: showHiddenFiles) { _, _ in
                onRefreshAll()
            }
    }
}

/// Window-scoped commands: menu commands post these with the target window as `object`, and only
/// the `ContentView` of that window reacts.
private struct BrowserWindowNotifications: ViewModifier {
    let isTargetWindow: (Any?) -> Bool
    let onNewTab: () -> Void
    let onCloseTab: () -> Void
    let onNextTab: () -> Void
    let onPreviousTab: () -> Void
    let onSetViewMode: (ViewMode) -> Void
    let onShowInfo: (FileItem) -> Void
    let onVolumeUnmount: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showGetInfo)) { notification in
                // Posted by the view model with the item; the window owning that view model shows it.
                if let item = notification.object as? FileItem {
                    onShowInfo(item)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newTab)) { notification in
                if isTargetWindow(notification.object) { onNewTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { notification in
                if isTargetWindow(notification.object) { onCloseTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextTab)) { notification in
                if isTargetWindow(notification.object) { onNextTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .previousTab)) { notification in
                if isTargetWindow(notification.object) { onPreviousTab() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserSetViewMode)) { notification in
                guard isTargetWindow(notification.object),
                      let rawValue = notification.userInfo?[BrowserWindowCommand.viewModeKey] as? String,
                      let mode = ViewMode(rawValue: rawValue) else { return }
                onSetViewMode(mode)
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willUnmountNotification)) { notification in
                // Leave the volume before it goes away so open folders don't block the unmount.
                if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    onVolumeUnmount(volumeURL)
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { notification in
                if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    onVolumeUnmount(volumeURL)
                }
            }
    }
}

struct ContentView: View {

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    // @StateObject evaluates its initializer once per window, so the initial tab's view model is
    // created exactly once (a @State initial value would be rebuilt on every ContentView init).
    @StateObject private var tabStore = BrowserTabStore()
    @StateObject private var auxiliaryPaneStore = AuxiliaryPaneStore()
    @StateObject private var hostWindow = HostWindowBox()

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activePane: DualPaneView.Pane = .left
    @State private var activeQuadPane: QuadPaneView.Pane = .topLeft
    @State private var dualPaneModes = DualPaneView.PaneModes()
    @State private var quadPaneModes = QuadPaneView.PaneModes()
    @State private var currentViewMode: ViewMode = .coverFlow
    @State private var showingInfoItem: FileItem?
    @State private var windowTitle: String = ""

    private var tabs: [BrowserTab] {
        tabStore.tabs
    }

    private var selectedTabId: UUID {
        tabStore.selectedTabId
    }

    private var viewModel: FileBrowserViewModel {
        tabStore.selectedTab.viewModel
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
            get: { currentViewMode },
            set: { setViewMode($0) }
        )
    }

    /// The view model menus, the toolbar and the sidebar act on: the active pane in dual/quad mode.
    private var activeViewModel: FileBrowserViewModel {
        switch currentViewMode {
        case .dualPane:
            return activePane == .right ? rightPaneViewModel : viewModel
        case .quadPane:
            switch activeQuadPane {
            case .topLeft: return viewModel
            case .topRight: return rightPaneViewModel
            case .bottomLeft: return bottomLeftPaneViewModel
            case .bottomRight: return bottomRightPaneViewModel
            }
        default:
            return viewModel
        }
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

    var body: some View {
        splitView
            .toolbar { toolbarItems }
            .navigationTitle(windowTitle)
            .focusedSceneObject(activeViewModel)
            .sheet(item: $showingInfoItem) { item in
                FileInfoView(item: item)
            }
            .modifier(BrowserWindowNotifications(
                isTargetWindow: isTargetWindow,
                onNewTab: addNewTab,
                onCloseTab: closeTabOrWindow,
                onNextTab: { tabStore.selectNextTab() },
                onPreviousTab: { tabStore.selectPreviousTab() },
                onSetViewMode: setViewMode,
                onShowInfo: showInfoIfOwned,
                onVolumeUnmount: leaveUnmountedVolume
            ))
            .onReceive(activeViewModel.$currentPath) { path in
                windowTitle = path.lastPathComponent
            }
            .onReceive(viewModel.$viewMode) { mode in
                // Keep the layout in sync when something else changes the mode (e.g. the sidebar's
                // Photos Library switches to Masonry).
                if mode != currentViewMode {
                    currentViewMode = mode
                }
            }
            .background(activitySyncView)
            .background(QuickLookWindowController())
            .background(HostingWindowReader { window in
                attachHostWindow(window)
            })
            .background(RepresentedURLSync(viewModel: activeViewModel))
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ToolbarHistoryButton(viewModel: activeViewModel, direction: .back)
        }

        ToolbarItem(placement: .navigation) {
            ToolbarHistoryButton(viewModel: activeViewModel, direction: .forward)
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
            ToolbarSortMenu()
            ToolbarActionsMenu(viewModel: activeViewModel)
            ToolbarSearchControls(viewModel: activeViewModel)
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
                syncWindowTitle()
                updateViewModelActivity()
            },
            onSelectedTabChange: {
                currentViewMode = viewModel.viewMode
                syncWindowTitle()
                updateViewModelActivity()
            },
            onRefreshAll: refreshAllViewModels,
            onUpdateActivity: {
                syncWindowTitle()
                updateViewModelActivity()
            },
            onTabsChange: updateViewModelActivity
        )
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: activeViewModel)
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
                    tabs: $tabStore.tabs,
                    selectedTabId: $tabStore.selectedTabId,
                    onNewTab: addNewTab,
                    onCloseTab: closeTab
                )
                Divider()
            }

            // Keyed by tab only: navigating a pane must not rebuild the split view (that reset the
            // other panes' scroll positions and path editing).
            if currentViewMode == .dualPane {
                DualPaneView(
                    leftViewModel: viewModel,
                    rightViewModel: rightPaneViewModel,
                    activePane: $activePane,
                    paneModes: $dualPaneModes
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 700, minHeight: 400)
                .id("dualpane-\(selectedTabId)")
            } else if currentViewMode == .quadPane {
                QuadPaneView(
                    topLeftViewModel: viewModel,
                    topRightViewModel: rightPaneViewModel,
                    bottomLeftViewModel: bottomLeftPaneViewModel,
                    bottomRightViewModel: bottomRightPaneViewModel,
                    activePane: $activeQuadPane,
                    paneModes: $quadPaneModes
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minWidth: 800, minHeight: 600)
                .id("quadpane-\(selectedTabId)")
            } else {
                TabContentWrapper(viewModel: viewModel, selectedTabId: selectedTabId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Window

    private func attachHostWindow(_ window: NSWindow?) {
        hostWindow.window = window
        if let window {
            KeyboardManager.shared.registerBrowserWindow(window)
        }
    }

    private func isTargetWindow(_ object: Any?) -> Bool {
        guard let target = object as? NSWindow, let window = hostWindow.window else { return false }
        return target === window
    }

    private func syncWindowTitle() {
        windowTitle = activeViewModel.currentPath.lastPathComponent
    }

    private func setViewMode(_ mode: ViewMode) {
        // Deferred: switching modes replaces the content view, which must not happen inside the
        // picker's own update.
        DispatchQueue.main.async {
            viewModel.viewMode = mode
            currentViewMode = mode
        }
    }

    private func showInfoIfOwned(_ item: FileItem) {
        guard let owner = managedViewModels.first(where: { $0.infoItem == item }) else { return }
        owner.infoItem = nil
        showingInfoItem = item
    }

    /// Sends every pane showing a folder on an unmounting volume back to the home folder.
    private func leaveUnmountedVolume(_ volumeURL: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for viewModel in managedViewModels {
            let showsVolume = VolumePaths.isURL(viewModel.currentPath, onVolumeAt: volumeURL)
                || (viewModel.currentArchiveURL.map { VolumePaths.isURL($0, onVolumeAt: volumeURL) } ?? false)
            guard showsVolume else { continue }
            PendingSelection.cancel(for: viewModel)
            if viewModel.isInsideArchive {
                viewModel.exitArchive()
            }
            viewModel.navigateTo(home)
        }
    }

    // MARK: - Tab Management

    private func addNewTab() {
        let newTab = BrowserTab(initialPath: viewModel.currentPath)
        newTab.viewModel.setUndoManager(undoManager)
        tabStore.addTab(newTab)
    }

    private func closeTab(_ tabId: UUID) {
        guard let closed = tabStore.closeTab(tabId) else { return }
        shutDown(closed.viewModel)
    }

    /// ⌘W: close the current tab, or the window when it is the last tab.
    private func closeTabOrWindow() {
        if tabs.count > 1 {
            closeTab(selectedTabId)
        } else {
            hostWindow.window?.performClose(nil)
        }
    }

    private func shutDown(_ viewModel: FileBrowserViewModel) {
        InlinePreviews.stopAll()
        PendingSelection.cancel(for: viewModel)
        // Stops the closed tab's folder watcher, network browsing and searches.
        viewModel.setBackgroundWorkActive(false)
    }

    private func refreshAllViewModels() {
        // Every tab and pane of this window, not only the visible ones (hidden files toggle).
        for viewModel in managedViewModels {
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

// MARK: - Toolbar

/// Toolbar items observe the active view model themselves; `ContentView` doesn't re-render on its changes.
private struct ToolbarHistoryButton: View {
    enum Direction {
        case back, forward
    }

    @ObservedObject var viewModel: FileBrowserViewModel
    let direction: Direction

    var body: some View {
        Button(action: {
            if direction == .back {
                viewModel.goBack()
            } else {
                viewModel.goForward()
            }
        }) {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
        }
        .disabled(direction == .back ? !viewModel.canGoBack : !viewModel.canGoForward)
        .help(direction == .back ? "Back" : "Forward")
    }
}

private struct ToolbarSortMenu: View {
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared

    var body: some View {
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
    }
}

private struct ToolbarActionsMenu: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        // Shortcuts (⇧⌘N, ⌘I) live in the menu bar.
        Menu {
            Button("New Folder") {
                viewModel.createNewFolder()
            }

            Divider()

            Button("Get Info") {
                viewModel.presentInfo(for: viewModel.primarySelectedItem)
            }
            .disabled(viewModel.selectedItems.isEmpty)

            Divider()

            Button("Show in Finder") {
                viewModel.showInFinder()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help("Actions")
    }
}

private struct ToolbarSearchControls: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
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

            SearchField(text: $viewModel.searchText, placeholder: viewModel.searchMode.placeholder)
                .frame(width: 180)
                .id("main-search-field")

            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
    }
}

/// Keeps the window's represented URL (title-bar path menu) on the active pane's folder.
private struct RepresentedURLSync: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        WindowRepresentedURL(url: viewModel.isInsideArchive ? nil : viewModel.currentPath) { url in
            viewModel.navigateToAndSelectCurrent(url)
        }
    }
}

// MARK: - Context Menu for File Items

/// Which items a context-menu command acts on (Finder semantics).
enum ContextMenuTarget {
    /// Right-clicking an item that is part of the selection acts on the whole selection;
    /// right-clicking any other item first makes it the selection.
    static func shouldReselect<Item: Hashable>(clicked: Item, selection: Set<Item>) -> Bool {
        !selection.contains(clicked)
    }
}

struct FileItemContextMenu: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    var onRename: (FileItem) -> Void

    private var isPackage: Bool {
        // Archive entries have no real path to browse.
        guard !item.isFromArchive, item.url.isFileURL else { return false }
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
                    viewModel.showPackageContents(item)
                }
            }

            if !item.isFromArchive && !item.isDirectory {
                OpenWithSubmenu(fileURLs: [item.url])
            }

            Divider()

            if !item.isFromArchive {
                Button("Get Info") {
                    viewModel.presentInfo(for: item)
                }

                Divider()

                // Tags submenu
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
                targetSelection()
                viewModel.copySelectedItems()
            }

            Button("Cut") {
                targetSelection()
                viewModel.cutSelectedItems()
            }

            // Duplicate, rename and trash can't work on entries inside an archive.
            if !item.isFromArchive {
                Button("Duplicate") {
                    targetSelection()
                    viewModel.duplicateSelectedItems()
                }

                Divider()

                Button("Rename") {
                    onRename(item)
                }

                Button("Move to Trash") {
                    targetSelection()
                    viewModel.deleteSelectedItems()
                }
            }

            Divider()

            Button("Show in Finder") {
                targetSelection()
                viewModel.showInFinder()
            }
        }
    }

    /// Keeps a multi-selection that contains the clicked item; otherwise selects the clicked item.
    private func targetSelection() {
        guard ContextMenuTarget.shouldReselect(clicked: item, selection: viewModel.selectedItems) else { return }
        viewModel.selectItem(item)
        if let index = viewModel.filteredItems.firstIndex(of: item) {
            viewModel.lastSelectedIndex = index
            viewModel.selectionAnchorIndex = index
        }
    }
}

extension FileBrowserViewModel {
    /// Shows Get Info for a specific item (the clicked or lead item, not an arbitrary member of the
    /// selection). The window that owns this view model presents the sheet.
    func presentInfo(for item: FileItem?) {
        guard let item, !item.isFromArchive else {
            NSSound.beep()
            return
        }
        infoItem = item
        NotificationCenter.default.post(name: .showGetInfo, object: item)
    }
}

// MARK: - Path Entry

/// Turns a typed path (path bar, pane path fields, Go to Folder) into a location.
enum PathEntryResolver {
    enum Resolution: Equatable {
        case directory(URL)
        /// A file: navigate to `parent` and select the file.
        case file(URL, parent: URL)
        case notFound
    }

    /// Trims whitespace/newlines and surrounding quotes, accepts `file://` URLs, expands `~` and
    /// `~user`, resolves relative paths against `base`, and standardizes `.`/`..`.
    static func expandedURL(for input: String, relativeTo base: URL?) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            return url.standardizedFileURL
        }

        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        // "~name" for a user that doesn't exist stays unexpanded.
        if expanded.hasPrefix("~") {
            return nil
        }
        guard let base else { return nil }
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    static func resolve(_ input: String, relativeTo base: URL?, fileManager: FileManager = .default) -> Resolution {
        guard let url = expandedURL(for: input, relativeTo: base) else { return .notFound }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .notFound }
        if isDirectory.boolValue {
            return .directory(url)
        }
        return .file(url, parent: url.deletingLastPathComponent())
    }

    /// Navigates `viewModel` to the typed location; a file opens its folder with the file selected.
    /// Returns false (caller beeps) when nothing exists there.
    @MainActor
    @discardableResult
    static func navigate(_ viewModel: FileBrowserViewModel, to input: String) -> Bool {
        let base = viewModel.isInsideArchive ? nil : viewModel.currentPath
        switch resolve(input, relativeTo: base) {
        case .notFound:
            return false
        case .directory(let url):
            PendingSelection.cancel(for: viewModel)
            if viewModel.isInsideArchive {
                viewModel.exitArchive()
            }
            viewModel.navigateTo(url)
        case .file(let url, let parent):
            if viewModel.isInsideArchive {
                viewModel.exitArchive()
            }
            PendingSelection.select(url, in: viewModel, navigatingTo: parent)
        }
        return true
    }
}

/// Selects a file once its folder has loaded.
@MainActor
enum PendingSelection {
    private static var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]

    static func select(_ fileURL: URL, in viewModel: FileBrowserViewModel, navigatingTo parent: URL, timeout: TimeInterval = 10) {
        cancel(for: viewModel)
        let targetPath = fileURL.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        if viewModel.currentPath.standardizedFileURL.path != parentPath {
            viewModel.navigateTo(parent)
        }
        if trySelect(targetPath, in: viewModel) {
            return
        }

        let key = ObjectIdentifier(viewModel)
        let deadline = Date().addingTimeInterval(timeout)
        subscriptions[key] = viewModel.$items
            .receive(on: RunLoop.main)
            .sink { [weak viewModel] _ in
                MainActor.assumeIsolated {
                    guard let viewModel else {
                        subscriptions[key] = nil
                        return
                    }
                    if viewModel.currentPath.standardizedFileURL.path != parentPath
                        || trySelect(targetPath, in: viewModel)
                        || Date() > deadline {
                        subscriptions[key] = nil
                    }
                }
            }
    }

    static func cancel(for viewModel: FileBrowserViewModel) {
        subscriptions[ObjectIdentifier(viewModel)] = nil
    }

    private static func trySelect(_ path: String, in viewModel: FileBrowserViewModel) -> Bool {
        let items = viewModel.filteredItems
        guard let index = items.firstIndex(where: { $0.url.standardizedFileURL.path == path }) else { return false }
        viewModel.selectItem(items[index])
        viewModel.lastSelectedIndex = index
        viewModel.selectionAnchorIndex = index
        return true
    }
}

/// Go ▸ Go to Folder… (⇧⌘G).
@MainActor
enum GoToFolderPrompt {
    static func present(for viewModel: FileBrowserViewModel, in window: NSWindow) {
        guard window.attachedSheet == nil else { return }

        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "Enter a path. Use ~ for your home folder."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = viewModel.isInsideArchive ? "" : viewModel.currentPath.path
        field.placeholderString = "~/Documents"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if !PathEntryResolver.navigate(viewModel, to: field.stringValue) {
                NSSound.beep()
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
        if PathEntryResolver.navigate(viewModel, to: path) {
            cancelEditing()
        } else {
            NSSound.beep()
        }
    }
}

// MARK: - Status Bar

/// Free space per volume, read off the main thread and cached briefly.
enum VolumeSpaceCache {
    private static var cache: [String: (bytes: Int64?, date: Date)] = [:]
    private static let lifetime: TimeInterval = 10
    private static let queue = DispatchQueue(label: "com.coverflowfinder.volumespace", qos: .utility)

    @MainActor
    static func availableCapacity(for url: URL, completion: @escaping (Int64?) -> Void) {
        let key = url.standardizedFileURL.path
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < lifetime {
            completion(entry.bytes)
            return
        }
        queue.async {
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let bytes = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map { Int64($0) }
            DispatchQueue.main.async {
                cache[key] = (bytes, Date())
                completion(bytes)
            }
        }
    }
}

/// Status bar figures, recomputed only when the listing changes (not on every render).
@MainActor
final class StatusBarModel: ObservableObject {
    @Published private(set) var totalSizeText: String?
    @Published private(set) var availableText: String?

    private weak var viewModel: FileBrowserViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var availabilityRequest = UUID()

    func bind(to viewModel: FileBrowserViewModel) {
        guard self.viewModel !== viewModel else { return }
        self.viewModel = viewModel
        cancellables.removeAll()

        Publishers.Merge5(
            viewModel.$items.map { _ in () },
            viewModel.$searchResults.map { _ in () },
            viewModel.$searchText.map { _ in () },
            viewModel.$filterTag.map { _ in () },
            viewModel.$searchMode.map { _ in () }
        )
        .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
        .sink { [weak self] in
            MainActor.assumeIsolated {
                self?.recompute()
            }
        }
        .store(in: &cancellables)

        recompute()
    }

    private func recompute() {
        guard let viewModel else { return }

        if viewModel.isPhotosLibraryActive {
            totalSizeText = nil
        } else {
            var total: Int64 = 0
            var hasFiles = false
            for item in viewModel.filteredItems where !item.isDirectory {
                total += item.size
                hasFiles = true
            }
            totalSizeText = hasFiles ? ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : nil
        }

        let path = viewModel.currentPath
        guard path.isFileURL, !viewModel.isPhotosLibraryActive, path.path != "/Network" else {
            availableText = nil
            return
        }
        let request = UUID()
        availabilityRequest = request
        VolumeSpaceCache.availableCapacity(for: path) { [weak self] bytes in
            guard let self, self.availabilityRequest == request else { return }
            self.availableText = bytes.map { "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) available" }
        }
    }
}

struct StatusBarView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    @StateObject private var model = StatusBarModel()

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

            if let totalSize = model.totalSizeText {
                Text(totalSize)
                    .font(settings.listDetailFont)
                    .foregroundColor(.secondary)
            }

            if let available = model.availableText {
                Text(model.totalSizeText == nil ? available : "• \(available)")
                    .font(settings.listDetailFont)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.bind(to: viewModel)
        }
        .onChange(of: ObjectIdentifier(viewModel)) { _, _ in
            model.bind(to: viewModel)
        }
    }
}

struct EmptyFolderView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var isDropTargeted = false

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
        // Dropping into an empty folder works like dropping on any folder background.
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
            viewModel: viewModel,
            isDropTargeted: $isDropTargeted,
            containerHeight: 0,
            items: [],
            autoScroll: false
        ))
        .dropTargetOverlay(isTargeted: isDropTargeted, padding: UI.Spacing.standard)
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

/// When the content area shows a spinner instead of the listing.
enum ContentLoadingPolicy {
    /// Only while there is nothing to show yet: an in-place reload or a Spotlight search that
    /// already has results keeps the current content on screen.
    static func showsSpinner(isLoading: Bool, isSpotlightSearchRunning: Bool, hasItems: Bool) -> Bool {
        guard !hasItems else { return false }
        return isLoading || isSpotlightSearchRunning
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
        ContentLoadingPolicy.showsSpinner(
            isLoading: viewModel.isLoading,
            isSpotlightSearchRunning: viewModel.isSearching && viewModel.searchMode == .finder && !viewModel.searchText.isEmpty,
            hasItems: !viewModel.filteredItems.isEmpty
        )
    }

    // Identity of the content view: a new folder, tab, archive location or search mode gets a fresh
    // view. Search results streaming in must NOT change it (that rebuilt Cover Flow per batch,
    // dropping thumbnails and stealing focus); the views update from the published items instead.
    private var contentViewId: String {
        let archiveId = viewModel.isInsideArchive ? "-archive-\(viewModel.currentArchivePath)" : ""
        return "\(viewModel.currentPath.path)-\(selectedTabId)\(archiveId)-\(viewModel.searchMode.rawValue)"
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

// Tab notification names are defined in UIConstants.swift

// MARK: - Volumes

enum VolumePaths {
    /// Whether `url` is on the volume mounted at `volumeURL` (never true for the root volume).
    static func isURL(_ url: URL, onVolumeAt volumeURL: URL) -> Bool {
        var volumePath = volumeURL.standardizedFileURL.path
        while volumePath.count > 1 && volumePath.hasSuffix("/") {
            volumePath.removeLast()
        }
        guard volumePath != "/" else { return false }
        let path = url.standardizedFileURL.path
        return path == volumePath || path.hasPrefix(volumePath + "/")
    }
}

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

        // Listen for focus notification (⌘F); the coordinator ignores other windows' requests.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusSearchField(_:)),
            name: .focusSearch,
            object: nil
        )

        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        // The binding changes when the active pane or tab changes.
        context.coordinator.parent = self

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

        @objc func focusSearchField(_ notification: Notification) {
            guard let searchField = searchField,
                  let window = searchField.window else { return }
            if let target = notification.object as? NSWindow {
                guard target === window else { return }
            } else if !window.isKeyWindow {
                return
            }
            window.makeFirstResponder(searchField)
        }

        // Handle Escape key to unfocus the search field and return focus to file list
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape pressed - return focus to the file list of this window
                NotificationCenter.default.post(name: .focusFileList, object: control.window)

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

// MARK: - Window Represented URL

/// Sets the window's representedURL so that Command-clicking (or right-clicking)
/// the title bar folder name shows the native macOS path hierarchy popup.
/// Intercepts the popup menu so selections navigate within the app instead of opening Finder.
struct WindowRepresentedURL: NSViewRepresentable {
    let url: URL?
    let onNavigate: (URL) -> Void

    func makeNSView(context: Context) -> WindowRepresentedURLView {
        let view = WindowRepresentedURLView()
        view.representedURL = url
        view.onNavigate = onNavigate
        return view
    }

    func updateNSView(_ nsView: WindowRepresentedURLView, context: Context) {
        nsView.representedURL = url
        nsView.onNavigate = onNavigate
        nsView.applyRepresentedURL()
    }
}

/// Custom NSView that applies representedURL when it is attached to a window.
///
/// Customizing the title-bar path menu needs `window(_:shouldPopUpDocumentPathMenu:)`, a delegate
/// method with no notification equivalent, so a proxy is put in front of SwiftUI's window delegate.
/// The proxy forwards every other delegate method, lives as long as the window, never wraps a nil
/// delegate, and is removed again when this view leaves the window.
final class WindowRepresentedURLView: NSView {
    var representedURL: URL?
    var onNavigate: ((URL) -> Void)?
    private var delegateProxy: PathMenuWindowDelegateProxy?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, newWindow !== window {
            uninstallProxy(from: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRepresentedURL()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyRepresentedURL() {
        guard let window else { return }
        if window.representedURL != representedURL {
            window.representedURL = representedURL
        }
        installProxyIfNeeded(on: window)
    }

    private func installProxyIfNeeded(on window: NSWindow) {
        if let proxy = window.delegate as? PathMenuWindowDelegateProxy {
            // Already in place (possibly installed by an earlier instance of this view): take it over.
            proxy.parentView = self
            delegateProxy = proxy
            return
        }
        // Re-wrap when SwiftUI replaced the delegate, but never wrap nil: that would drop
        // SwiftUI's delegate (close handling, state restoration) for good.
        guard let original = window.delegate else { return }
        let proxy = delegateProxy ?? PathMenuWindowDelegateProxy()
        proxy.parentView = self
        proxy.originalDelegate = original
        delegateProxy = proxy
        PathMenuWindowDelegateProxy.retain(proxy, for: window)
        window.delegate = proxy
    }

    private func uninstallProxy(from window: NSWindow) {
        guard let proxy = delegateProxy else { return }
        delegateProxy = nil
        // Another instance may have taken the proxy over; only the current owner restores.
        guard proxy.parentView === self || proxy.parentView == nil else { return }
        proxy.parentView = nil
        if window.delegate === proxy, let original = proxy.originalDelegate {
            window.delegate = original
        }
    }
}

/// A delegate proxy that sits between the window and its original SwiftUI delegate.
/// It intercepts `window(_:shouldPopUpDocumentPathMenu:)` to customize the path
/// menu items, and forwards everything else to the original delegate.
final class PathMenuWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var parentView: WindowRepresentedURLView?
    weak var originalDelegate: (any NSWindowDelegate)?

    private static var associationKey: UInt8 = 0

    /// `NSWindow.delegate` is weak: tie the proxy's lifetime to the window, not to the view.
    static func retain(_ proxy: PathMenuWindowDelegateProxy, for window: NSWindow) {
        objc_setAssociatedObject(window, &associationKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func window(_ window: NSWindow, shouldPopUpDocumentPathMenu menu: NSMenu) -> Bool {
        // Replace each menu item's action so clicking navigates within the app
        for item in menu.items {
            item.target = self
            item.action = #selector(pathMenuItemClicked(_:))
        }
        return true
    }

    func window(_ window: NSWindow, shouldDragDocumentWith event: NSEvent, from dragImageLocation: NSPoint, with pasteboard: NSPasteboard) -> Bool {
        return originalDelegate?.window?(window, shouldDragDocumentWith: event, from: dragImageLocation, with: pasteboard) ?? true
    }

    @objc private func pathMenuItemClicked(_ sender: NSMenuItem) {
        // The native path menu items store the URL in their representedObject
        // But the path components can also be inferred from the menu item's title
        // and the window's representedURL
        guard let parentView else { return }
        guard let windowURL = parentView.representedURL else { return }

        // Build the URL from the menu item's position - items are ordered from
        // deepest (current folder) to root. The item's title is the path component name.
        let menu = sender.menu

        // Find the target URL by walking up from the window's representedURL
        // The menu lists path components from current to root (top to bottom)
        if let menu {
            var pathURL = windowURL
            var urls: [URL] = []

            // Build the full list of path components from root to current
            while pathURL.path != "/" {
                urls.insert(pathURL, at: 0)
                pathURL = pathURL.deletingLastPathComponent()
            }
            urls.insert(URL(fileURLWithPath: "/"), at: 0)

            // Menu items go from current (index 0) to root (last index)
            // Find which index our sender is in the menu
            if let itemIndex = menu.items.firstIndex(of: sender) {
                // Menu items are ordered current-to-root, so reverse index into urls
                let urlIndex = urls.count - 1 - itemIndex
                if urlIndex >= 0 && urlIndex < urls.count {
                    let targetURL = urls[urlIndex]
                    if targetURL != parentView.representedURL {
                        parentView.onNavigate?(targetURL)
                    }
                    return
                }
            }
        }

        // Fallback: try representedObject as URL
        if let url = sender.representedObject as? URL, url != parentView.representedURL {
            parentView.onNavigate?(url)
        }
    }

    // MARK: - Forward all other delegate methods to original

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }
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

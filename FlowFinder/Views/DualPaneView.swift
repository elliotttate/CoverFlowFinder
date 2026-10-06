import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

struct DualPaneView: View {
    @ObservedObject var leftViewModel: FileBrowserViewModel
    @ObservedObject var rightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane
    /// Owned by ContentView so the pane modes survive navigation and leaving dual mode.
    @Binding var paneModes: PaneModes
    @State private var leftPaneColumns: Int = 4
    @State private var rightPaneColumns: Int = 4

    enum Pane {
        case left, right
    }

    enum PaneViewMode: String, CaseIterable {
        case list = "List"
        case icons = "Icons"

        var systemImage: String {
            switch self {
            case .list: return "list.bullet"
            case .icons: return "square.grid.2x2"
            }
        }
    }

    struct PaneModes: Equatable {
        var left: PaneViewMode = .list
        var right: PaneViewMode = .list
    }

    // The active viewModel based on current pane
    private var activeViewModel: FileBrowserViewModel {
        activePane == .left ? leftViewModel : rightViewModel
    }

    private var activeMode: PaneViewMode {
        activePane == .left ? paneModes.left : paneModes.right
    }

    // Column count for active pane's view mode
    private var activeColumnsCount: Int {
        guard activeMode == .icons else { return 1 }
        return max(1, activePane == .left ? leftPaneColumns : rightPaneColumns)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left pane
                PaneView(
                    viewModel: leftViewModel,
                    otherViewModel: rightViewModel,
                    isActive: activePane == .left,
                    paneViewMode: $paneModes.left,
                    onActivate: { activePane = .left },
                    onColumnsCalculated: { cols in leftPaneColumns = cols }
                )

                // Right pane
                PaneView(
                    viewModel: rightViewModel,
                    otherViewModel: leftViewModel,
                    isActive: activePane == .right,
                    paneViewMode: $paneModes.right,
                    onActivate: { activePane = .right },
                    onColumnsCalculated: { cols in rightPaneColumns = cols }
                )
            }
        }
        .onAppear {
            // Give keyboard navigation a starting point in the active pane only.
            let viewModel = activeViewModel
            if viewModel.selectedItems.isEmpty, let first = viewModel.filteredItems.first {
                viewModel.selectItem(first)
            }
        }
        // Same guarded, per-window handling as the single-pane views; keys go to the active pane.
        // The closures read the active pane, its mode and column count when the key is pressed.
        .keyboardNavigable(
            onUpArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: -activeColumnsCount, extend: shift) },
            onDownArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: activeColumnsCount, extend: shift) },
            onLeftArrow: { shift in
                if activeMode == .icons { PaneKeyboardNavigation.move(activeViewModel, by: -1, extend: shift) }
            },
            onRightArrow: { shift in
                if activeMode == .icons { PaneKeyboardNavigation.move(activeViewModel, by: 1, extend: shift) }
            },
            onReturn: { PaneKeyboardNavigation.openSelection(in: activeViewModel) },
            onSpace: { PaneKeyboardNavigation.toggleQuickLook(in: activeViewModel) },
            onDelete: { activeViewModel.deleteSelectedItems() },
            onCopy: { activeViewModel.copySelectedItems() },
            onCut: { activeViewModel.cutSelectedItems() },
            onPaste: { activeViewModel.paste() },
            onTypeAhead: { prefix in PaneKeyboardNavigation.jumpToMatch(prefix, in: activeViewModel) }
        )
    }
}

struct PaneView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var otherViewModel: FileBrowserViewModel
    let isActive: Bool
    @Binding var paneViewMode: DualPaneView.PaneViewMode
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void
    @State private var isDropTargeted = false
    @State private var isEditingPath = false
    @State private var editPathText = ""
    @FocusState private var isPathFieldFocused: Bool

    // Cache path components
    private var pathComponents: [URL] {
        var components: [URL] = []
        var current = viewModel.currentPath

        while current.path != "/" {
            components.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        components.insert(URL(fileURLWithPath: "/"), at: 0)

        return components
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane toolbar
            HStack(spacing: 8) {
                // Back/Forward buttons
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(viewModel.historyIndex <= 0)
                .buttonStyle(.borderless)

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(viewModel.historyIndex >= viewModel.navigationHistory.count - 1)
                .buttonStyle(.borderless)

                // Path display
                Text(viewModel.currentPath.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // View mode picker
                Picker("", selection: $paneViewMode) {
                    ForEach(DualPaneView.PaneViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                            .help(mode.rawValue)
                            .accessibilityLabel(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))

            Divider()

            // Path bar
            if appSettings.showPathBar {
                HStack(spacing: 4) {
                    if isEditingPath {
                        TextField("Path", text: $editPathText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .focused($isPathFieldFocused)
                            .onSubmit { navigateToEditedPath() }
                            .onExitCommand { cancelPathEditing() }
                            .onAppear {
                                editPathText = viewModel.currentPath.path
                                isPathFieldFocused = true
                            }

                        Button(action: { navigateToEditedPath() }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)

                        Button(action: { cancelPathEditing() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(pathComponents, id: \.self) { component in
                                Text(component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.navigateToAndSelectCurrent(component)
                                        onActivate()
                                    }

                                if component != viewModel.currentPath {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Rectangle()
                            .fill(Color.primary.opacity(0.001))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                startPathEditing()
                            }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))

                Divider()
            }

            // Content with drop support
            Group {
                switch paneViewMode {
                case .list:
                    PaneListView(viewModel: viewModel, onActivate: onActivate)
                case .icons:
                    PaneIconView(viewModel: viewModel, onActivate: onActivate, onColumnsCalculated: onColumnsCalculated)
                }
            }
            // A delegate (not a perform closure) so the cursor shows move vs. copy correctly and
            // drags from the other pane are accepted while drags within this pane are refused.
            .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
                viewModel: viewModel,
                isDropTargeted: $isDropTargeted,
                containerHeight: 0,
                items: [],
                autoScroll: false,
                onComplete: { otherViewModel.refresh() }
            ))
            .dropTargetOverlay(isTargeted: isDropTargeted, cornerRadius: UI.CornerRadius.medium)

            Divider()

            // Status bar
            if appSettings.showStatusBar {
                HStack {
                    Text("\(viewModel.filteredItems.count) items")
                        .font(appSettings.compactListDetailFont)
                        .foregroundColor(.secondary)

                    Spacer()

                    if !viewModel.selectedItems.isEmpty {
                        Text("\(viewModel.selectedItems.count) selected")
                            .font(appSettings.compactListDetailFont)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(isActive ? Color.clear : Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
        }
    }

    private func startPathEditing() {
        editPathText = viewModel.currentPath.path
        isEditingPath = true
    }

    private func cancelPathEditing() {
        isEditingPath = false
        isPathFieldFocused = false
    }

    private func navigateToEditedPath() {
        if PathEntryResolver.navigate(viewModel, to: editPathText) {
            cancelPathEditing()
            onActivate()
        } else {
            NSSound.beep()
        }
    }
}

struct PaneListView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    @State private var dropTargetedItemID: UUID?

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredItems) { item in
                        let isSelected = viewModel.selectedItems.contains(item)
                        HStack(spacing: 8) {
                            AsyncListIconView(item: item, size: appSettings.compactListIconSize)

                            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.compactListFont, alignment: .leading, lineLimit: 1)

                            if appSettings.showItemTags, !item.tags.isEmpty {
                                TagDotsView(tags: item.tags)
                            }

                            Spacer()

                            Text(item.formattedSize)
                                .font(appSettings.compactListDetailFont)
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)

                            Text(item.formattedDate)
                                .font(appSettings.compactListDetailFont)
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .trailing)
                        }
                        .id(item.id)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(dropTargetedItemID == item.id
                                    ? Color.accentColor.opacity(0.4)
                                    : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear))
                                .padding(.horizontal, 4)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .opacity(dropTargetedItemID == item.id ? 1 : 0)
                                .padding(.horizontal, 4)
                        )
                        .contentShape(Rectangle())
                        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
                        .internalDrag(url: item.url)
                        .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
                            item: item,
                            viewModel: viewModel,
                            dropTargetedItemID: $dropTargetedItemID
                        ))
                        .instantTap(
                            id: item.id,
                            onSingleClick: {
                                onActivate()
                                if let index = viewModel.filteredItems.firstIndex(of: item) {
                                    let modifiers = NSEvent.modifierFlags
                                    viewModel.handleSelection(
                                        item: item,
                                        index: index,
                                        in: viewModel.filteredItems,
                                        withShift: modifiers.contains(.shift),
                                        withCommand: modifiers.contains(.command)
                                    )
                                    viewModel.updateQuickLookPreview(for: item)
                                }
                            },
                            onDoubleClick: {
                                onActivate()
                                viewModel.openItem(item)
                            }
                        )
                        .contextMenu {
                            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                viewModel.renamingURL = item.url
                            }
                        }
                    }
                }
            }
            .onAppear {
                if let lead = viewModel.primarySelectedItem {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollProxy.scrollTo(lead.id, anchor: .center)
                    }
                }
            }
            .onChange(of: viewModel.selectedItems) { _, _ in
                if let lead = viewModel.primarySelectedItem {
                    withAnimation {
                        scrollProxy.scrollTo(lead.id)
                    }
                }
            }
        }
    }
}

/// Per-pane thumbnail bookkeeping for the pane icon views: which cells are on screen and which
/// requests are in flight. Plain reference storage so cell appear/disappear doesn't re-render the
/// grid. Owns the pane's thumbnail requests (cancelled on folder change and when the pane goes away).
final class PaneThumbnailState {
    let owner = ThumbnailRequestOwner()
    var visibleURLs: Set<URL> = []
    var requestedURLs: Set<URL> = []

    func cancelAll() {
        ThumbnailCacheManager.shared.cancelRequests(for: owner)
        requestedURLs.removeAll()
    }

    /// Shared loader for the dual and quad pane icon views. `store` receives the image (or the
    /// item's placeholder when it has no thumbnail) on the main queue.
    func load(_ item: FileItem, maxPixelSize: CGFloat, current: NSImage?, store: @escaping (NSImage, URL) -> Void) {
        let url = item.url
        if let current, PaneThumbnailState.image(current, satisfies: maxPixelSize) { return }
        let cache = ThumbnailCacheManager.shared
        if let cached = cache.cachedThumbnail(for: item, maxPixelSize: maxPixelSize) {
            DispatchQueue.main.async { store(cached, url) }
            return
        }
        guard !requestedURLs.contains(url) else { return }
        requestedURLs.insert(url)
        cache.requestThumbnail(for: item, maxPixelSize: maxPixelSize, owner: owner) { [weak self] result in
            DispatchQueue.main.async {
                self?.requestedURLs.remove(url)
                switch result {
                case .loaded(let image):
                    store(image, url)
                case .failed:
                    store(item.placeholderIcon, url)
                case .cancelled:
                    break
                }
            }
        }
    }

    static func image(_ image: NSImage, satisfies minPixelSize: CGFloat) -> Bool {
        max(image.size.width, image.size.height) >= minPixelSize * 0.9
    }
}

struct PaneIconView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void

    // Display copies of on-screen thumbnails; ThumbnailCacheManager holds the real cache.
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var thumbnailState = PaneThumbnailState()
    @State private var dropTargetedItemID: UUID?
    private static let maxDisplayedThumbnails = 300

    private var cellWidth: CGFloat {
        appSettings.dualPaneIconSize + 32
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: appSettings.dualPaneGridSpacing)]
    }

    private var thumbnailPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let baseTarget = max(192, appSettings.dualPaneIconSize * scale)
        let target = baseTarget * appSettings.thumbnailQualityValue
        let bucket = (target / 64).rounded() * 64
        return min(1024, max(96, bucket))
    }

    private func calculateColumns(width: CGFloat) -> Int {
        let availableWidth = max(0, width - 32)
        let spacing = appSettings.dualPaneGridSpacing
        let columns = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, columns)
    }

    private func loadThumbnail(for item: FileItem) {
        thumbnailState.load(item, maxPixelSize: thumbnailPixelSize, current: thumbnails[item.url]) { image, url in
            storeThumbnail(image, for: url)
        }
    }

    /// Keeps the display dictionary bounded: past the limit only the cells on screen are kept
    /// (the rest come back from ThumbnailCacheManager's memory cache when they reappear).
    private func storeThumbnail(_ image: NSImage, for url: URL) {
        thumbnails[url] = image
        if thumbnails.count > Self.maxDisplayedThumbnails {
            let visible = thumbnailState.visibleURLs
            thumbnails = thumbnails.filter { visible.contains($0.key) }
        }
    }

    private func refreshThumbnails() {
        DispatchQueue.main.async {
            for item in viewModel.filteredItems where thumbnailState.visibleURLs.contains(item.url) {
                loadThumbnail(for: item)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: appSettings.dualPaneGridSpacing) {
                        ForEach(viewModel.filteredItems) { item in
                            let isSelected = viewModel.selectedItems.contains(item)
                            VStack(spacing: 4) {
                                Image(nsImage: thumbnails[item.url] ?? item.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: appSettings.dualPaneIconSize, height: appSettings.dualPaneIconSize)

                                InlineRenameField(item: item, viewModel: viewModel, font: appSettings.dualPaneFont, alignment: .center, lineLimit: 2)
                                    .frame(width: cellWidth - 16)

                                if appSettings.showItemTags, !item.tags.isEmpty {
                                    TagDotsView(tags: item.tags)
                                }
                            }
                            .id(item.id)
                            .onAppear {
                                thumbnailState.visibleURLs.insert(item.url)
                                loadThumbnail(for: item)
                            }
                            .onDisappear {
                                thumbnailState.visibleURLs.remove(item.url)
                            }
                            .padding(8)
                            .background(
                                dropTargetedItemID == item.id
                                    ? Color.accentColor.opacity(0.4)
                                    : (isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                                    .opacity(dropTargetedItemID == item.id ? 1 : 0)
                            )
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
                            .internalDrag(url: item.url)
                            .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
                                item: item,
                                viewModel: viewModel,
                                dropTargetedItemID: $dropTargetedItemID
                            ))
                            .instantTap(
                                id: item.id,
                                onSingleClick: {
                                    onActivate()
                                    if let index = viewModel.filteredItems.firstIndex(of: item) {
                                        let modifiers = NSEvent.modifierFlags
                                        viewModel.handleSelection(
                                            item: item,
                                            index: index,
                                            in: viewModel.filteredItems,
                                            withShift: modifiers.contains(.shift),
                                            withCommand: modifiers.contains(.command)
                                        )
                                        viewModel.updateQuickLookPreview(for: item)
                                    }
                                },
                                onDoubleClick: {
                                    onActivate()
                                    viewModel.openItem(item)
                                }
                            )
                            .contextMenu {
                                FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                    viewModel.renamingURL = item.url
                                }
                            }
                        }
                    }
                    .padding()
                }
                .onAppear {
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                    // Scroll to selected item when view appears (e.g., when switching view modes)
                    if let lead = viewModel.primarySelectedItem {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo(lead.id, anchor: .center)
                        }
                    }
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    onColumnsCalculated(calculateColumns(width: newWidth))
                }
                .onChange(of: appSettings.iconGridIconSize) { _, _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                    refreshThumbnails()
                }
                .onChange(of: appSettings.iconGridSpacing) { _, _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: appSettings.thumbnailQuality) { _, _ in
                    refreshThumbnails()
                }
                .onChange(of: viewModel.currentPath) { _, _ in
                    // A new folder: cancel this pane's requests and drop its thumbnails.
                    thumbnailState.cancelAll()
                    thumbnails.removeAll()
                }
                .onChange(of: viewModel.selectedItems) { _, _ in
                    if let lead = viewModel.primarySelectedItem {
                        withAnimation {
                            scrollProxy.scrollTo(lead.id)
                        }
                    }
                }
                .onDisappear {
                    thumbnailState.cancelAll()
                }
            }
        }
    }
}

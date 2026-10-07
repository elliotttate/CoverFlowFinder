import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

struct QuadPaneView: View {
    @ObservedObject var topLeftViewModel: FileBrowserViewModel
    @ObservedObject var topRightViewModel: FileBrowserViewModel
    @ObservedObject var bottomLeftViewModel: FileBrowserViewModel
    @ObservedObject var bottomRightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane
    /// Owned by ContentView so the pane modes survive navigation and leaving quad mode.
    @Binding var paneModes: PaneModes

    @State private var topLeftColumns: Int = 1
    @State private var topRightColumns: Int = 1
    @State private var bottomLeftColumns: Int = 1
    @State private var bottomRightColumns: Int = 1

    enum Pane {
        case topLeft, topRight, bottomLeft, bottomRight
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
        var topLeft: PaneViewMode = .list
        var topRight: PaneViewMode = .list
        var bottomLeft: PaneViewMode = .list
        var bottomRight: PaneViewMode = .list
    }

    private var activeViewModel: FileBrowserViewModel {
        switch activePane {
        case .topLeft: return topLeftViewModel
        case .topRight: return topRightViewModel
        case .bottomLeft: return bottomLeftViewModel
        case .bottomRight: return bottomRightViewModel
        }
    }

    private var activeMode: PaneViewMode {
        switch activePane {
        case .topLeft: return paneModes.topLeft
        case .topRight: return paneModes.topRight
        case .bottomLeft: return paneModes.bottomLeft
        case .bottomRight: return paneModes.bottomRight
        }
    }

    /// Items per row in the active pane (1 in list mode).
    private var activeColumnsCount: Int {
        guard activeMode == .icons else { return 1 }
        let columns: Int
        switch activePane {
        case .topLeft: columns = topLeftColumns
        case .topRight: columns = topRightColumns
        case .bottomLeft: columns = bottomLeftColumns
        case .bottomRight: columns = bottomRightColumns
        }
        return max(1, columns)
    }

    private func otherViewModels(for pane: Pane) -> [FileBrowserViewModel] {
        let all = [topLeftViewModel, topRightViewModel, bottomLeftViewModel, bottomRightViewModel]
        let current: FileBrowserViewModel
        switch pane {
        case .topLeft: current = topLeftViewModel
        case .topRight: current = topRightViewModel
        case .bottomLeft: current = bottomLeftViewModel
        case .bottomRight: current = bottomRightViewModel
        }
        return all.filter { $0 !== current }
    }

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                HSplitView {
                    QuadPaneCell(
                        viewModel: topLeftViewModel,
                        otherViewModels: otherViewModels(for: .topLeft),
                        isActive: activePane == .topLeft,
                        paneViewMode: $paneModes.topLeft,
                        onActivate: { activePane = .topLeft },
                        onColumnsCalculated: { topLeftColumns = $0 }
                    )

                    QuadPaneCell(
                        viewModel: topRightViewModel,
                        otherViewModels: otherViewModels(for: .topRight),
                        isActive: activePane == .topRight,
                        paneViewMode: $paneModes.topRight,
                        onActivate: { activePane = .topRight },
                        onColumnsCalculated: { topRightColumns = $0 }
                    )
                }

                HSplitView {
                    QuadPaneCell(
                        viewModel: bottomLeftViewModel,
                        otherViewModels: otherViewModels(for: .bottomLeft),
                        isActive: activePane == .bottomLeft,
                        paneViewMode: $paneModes.bottomLeft,
                        onActivate: { activePane = .bottomLeft },
                        onColumnsCalculated: { bottomLeftColumns = $0 }
                    )

                    QuadPaneCell(
                        viewModel: bottomRightViewModel,
                        otherViewModels: otherViewModels(for: .bottomRight),
                        isActive: activePane == .bottomRight,
                        paneViewMode: $paneModes.bottomRight,
                        onActivate: { activePane = .bottomRight },
                        onColumnsCalculated: { bottomRightColumns = $0 }
                    )
                }
            }
        }
        .onAppear {
            // Give keyboard navigation a starting point in the active pane only.
            let viewModel = activeViewModel
            if viewModel.selectedItems.isEmpty, let first = viewModel.filteredItems.first {
                viewModel.selectItem(first)
            }
        }
        .background(PaneFocusRequestHandler(activeViewModel: activeViewModel))
        // Same guarded, per-window handling as the single-pane views; keys go to the active pane.
        // The closures read the active pane, its mode and column count when the key is pressed.
        .keyboardNavigable(
            onUpArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: -activeColumnsCount, extend: shift) },
            onDownArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: activeColumnsCount, extend: shift) },
            onLeftArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: -1, extend: shift) },
            onRightArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: 1, extend: shift) },
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

struct QuadPaneCell: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let otherViewModels: [FileBrowserViewModel]
    let isActive: Bool
    @Binding var paneViewMode: QuadPaneView.PaneViewMode
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                }
                .disabled(viewModel.historyIndex <= 0)
                .buttonStyle(.borderless)

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .disabled(viewModel.historyIndex >= viewModel.navigationHistory.count - 1)
                .buttonStyle(.borderless)

                Text(viewModel.locationTitle)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Picker("", selection: $paneViewMode) {
                    ForEach(QuadPaneView.PaneViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                            .help(mode.rawValue)
                            .accessibilityLabel(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 70)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))

            Divider()

            if appSettings.showPathBar {
                PanePathBar(viewModel: viewModel, style: .quad, onActivate: onActivate)

                Divider()
            }

            Group {
                switch paneViewMode {
                case .list:
                    QuadPaneListView(viewModel: viewModel, onActivate: onActivate)
                case .icons:
                    QuadPaneIconView(viewModel: viewModel, onActivate: onActivate, onColumnsCalculated: onColumnsCalculated)
                }
            }
            // A delegate (not a perform closure) so the cursor shows move vs. copy correctly and
            // drags from other panes are accepted while drags within this pane are refused.
            .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
                viewModel: viewModel,
                isDropTargeted: $isDropTargeted,
                containerHeight: 0,
                items: [],
                autoScroll: false,
                onComplete: { otherViewModels.forEach { $0.refresh() } }
            ))
            .dropTargetOverlay(isTargeted: isDropTargeted, cornerRadius: UI.CornerRadius.medium, lineWidth: UI.LineWidth.standard, padding: UI.Spacing.tiny)

            Divider()

            // An archive copy-out in progress shows even when the status bar is hidden
            PaneStatusBar(viewModel: viewModel, horizontalPadding: 8, verticalPadding: 3)
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
}

struct QuadPaneListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    @State private var dropTargetedItemID: UUID?

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredItems) { item in
                        QuadPaneListRow(item: item, viewModel: viewModel, onActivate: onActivate, dropTargetedItemID: $dropTargetedItemID)
                    }
                }
                .fileDragContainer(for: viewModel)
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

struct QuadPaneListRow: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    @Binding var dropTargetedItemID: UUID?

    var body: some View {
        let isSelected = viewModel.selectedItems.contains(item)
        HStack(spacing: 6) {
            AsyncListIconView(item: item, size: appSettings.compactListIconSize)

            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.compactListFont, alignment: .leading, lineLimit: 1)

            if appSettings.showItemTags, !item.tags.isEmpty {
                TagDotsView(tags: item.tags)
            }

            Spacer()

            Text(item.formattedSize)
                .font(appSettings.compactListDetailFont)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            dropTargetedItemID == item.id
                ? Color.accentColor.opacity(0.4)
                : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(dropTargetedItemID == item.id ? 1 : 0)
        )
        .cornerRadius(3)
        .contentShape(Rectangle())
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
        .id(item.id)
        .fileDragItem(item)
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
            item: item,
            viewModel: viewModel,
            dropTargetedItemID: $dropTargetedItemID
        ))
        .instantTap(
            id: item.id,
            onSingleClick: {
                handleClick()
            },
            onDoubleClick: {
                viewModel.openItem(item)
            }
        )
        .contextMenu {
            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                viewModel.renamingURL = item.url
            }
        }
    }

    private func handleClick() {
        if let index = viewModel.filteredItems.firstIndex(of: item) {
            let modifiers = NSEvent.modifierFlags
            viewModel.handleSelection(
                item: item,
                index: index,
                in: viewModel.filteredItems,
                withShift: modifiers.contains(.shift),
                withCommand: modifiers.contains(.command)
            )
        }
        onActivate()
        viewModel.updateQuickLookPreview(for: item)
    }
}

struct QuadPaneIconView: View {
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
        appSettings.quadPaneIconSize + 32
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: appSettings.quadPaneGridSpacing)]
    }

    private var thumbnailPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let baseTarget = max(192, appSettings.quadPaneIconSize * scale)
        let target = baseTarget * appSettings.thumbnailQualityValue
        let bucket = (target / 64).rounded() * 64
        return min(512, max(96, bucket))
    }

    private func calculateColumns(width: CGFloat) -> Int {
        let availableWidth = max(0, width - 16)
        let spacing = appSettings.quadPaneGridSpacing
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
                    LazyVGrid(columns: columns, spacing: appSettings.quadPaneGridSpacing) {
                        ForEach(viewModel.filteredItems) { item in
                            QuadPaneIconCell(item: item, viewModel: viewModel, onActivate: onActivate, thumbnail: thumbnails[item.url], dropTargetedItemID: $dropTargetedItemID)
                                .onAppear {
                                    thumbnailState.visibleURLs.insert(item.url)
                                    loadThumbnail(for: item)
                                }
                                .onDisappear {
                                    thumbnailState.visibleURLs.remove(item.url)
                                }
                        }
                    }
                    .fileDragContainer(for: viewModel)
                    .padding(8)
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
                // Edited in place: reload the thumbnails of changed files
                .onChange(of: viewModel.filteredItems.map(\.contentVersion)) { _, _ in
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

struct QuadPaneIconCell: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let thumbnail: NSImage?
    @Binding var dropTargetedItemID: UUID?

    var body: some View {
        let isSelected = viewModel.selectedItems.contains(item)
        let iconSize = appSettings.quadPaneIconSize
        let labelWidth = iconSize + 24
        VStack(spacing: 2) {
            Image(nsImage: thumbnail ?? item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)

            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.quadPaneFont, alignment: .center, lineLimit: 2)
                .frame(width: labelWidth, height: 28)

            if appSettings.showItemTags, !item.tags.isEmpty {
                TagDotsView(tags: item.tags)
            }
        }
        .frame(width: labelWidth)
        .padding(4)
        .background(
            dropTargetedItemID == item.id
                ? Color.accentColor.opacity(0.4)
                : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(dropTargetedItemID == item.id ? 1 : 0)
        )
        .cornerRadius(6)
        .contentShape(Rectangle())
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
        .id(item.id)
        .fileDragItem(item)
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
            item: item,
            viewModel: viewModel,
            dropTargetedItemID: $dropTargetedItemID
        ))
        .instantTap(
            id: item.id,
            onSingleClick: {
                handleClick()
            },
            onDoubleClick: {
                viewModel.openItem(item)
            }
        )
        .contextMenu {
            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                viewModel.renamingURL = item.url
            }
        }
    }

    private func handleClick() {
        if let index = viewModel.filteredItems.firstIndex(of: item) {
            let modifiers = NSEvent.modifierFlags
            viewModel.handleSelection(
                item: item,
                index: index,
                in: viewModel.filteredItems,
                withShift: modifiers.contains(.shift),
                withCommand: modifiers.contains(.command)
            )
        }
        onActivate()
        viewModel.updateQuickLookPreview(for: item)
    }
}


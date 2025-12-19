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

    @State private var topLeftViewMode: PaneViewMode = .list
    @State private var topRightViewMode: PaneViewMode = .list
    @State private var bottomLeftViewMode: PaneViewMode = .list
    @State private var bottomRightViewMode: PaneViewMode = .list
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

    private var activeViewModel: FileBrowserViewModel {
        switch activePane {
        case .topLeft: return topLeftViewModel
        case .topRight: return topRightViewModel
        case .bottomLeft: return bottomLeftViewModel
        case .bottomRight: return bottomRightViewModel
        }
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
                        paneViewMode: $topLeftViewMode,
                        onActivate: { activePane = .topLeft },
                        onColumnsCalculated: { topLeftColumns = $0 }
                    )

                    QuadPaneCell(
                        viewModel: topRightViewModel,
                        otherViewModels: otherViewModels(for: .topRight),
                        isActive: activePane == .topRight,
                        paneViewMode: $topRightViewMode,
                        onActivate: { activePane = .topRight },
                        onColumnsCalculated: { topRightColumns = $0 }
                    )
                }

                HSplitView {
                    QuadPaneCell(
                        viewModel: bottomLeftViewModel,
                        otherViewModels: otherViewModels(for: .bottomLeft),
                        isActive: activePane == .bottomLeft,
                        paneViewMode: $bottomLeftViewMode,
                        onActivate: { activePane = .bottomLeft },
                        onColumnsCalculated: { bottomLeftColumns = $0 }
                    )

                    QuadPaneCell(
                        viewModel: bottomRightViewModel,
                        otherViewModels: otherViewModels(for: .bottomRight),
                        isActive: activePane == .bottomRight,
                        paneViewMode: $bottomRightViewMode,
                        onActivate: { activePane = .bottomRight },
                        onColumnsCalculated: { bottomRightColumns = $0 }
                    )
                }
            }
        }
        .onAppear {
            if topLeftViewModel.selectedItems.isEmpty && !topLeftViewModel.filteredItems.isEmpty {
                topLeftViewModel.selectItem(topLeftViewModel.filteredItems[0])
            }
            registerKeyboardHandler()
        }
        .onChange(of: activePane) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: topLeftViewMode) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: topRightViewMode) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: bottomLeftViewMode) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: bottomRightViewMode) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: topLeftColumns) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: topRightColumns) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: bottomLeftColumns) { _ in
            registerKeyboardHandler()
        }
        .onChange(of: bottomRightColumns) { _ in
            registerKeyboardHandler()
        }
    }

    private func registerKeyboardHandler() {
        let pane = activePane
        let vm = activeViewModel
        let mode: PaneViewMode
        let columnsCount: Int
        switch pane {
        case .topLeft:
            mode = topLeftViewMode
            columnsCount = topLeftColumns
        case .topRight:
            mode = topRightViewMode
            columnsCount = topRightColumns
        case .bottomLeft:
            mode = bottomLeftViewMode
            columnsCount = bottomLeftColumns
        case .bottomRight:
            mode = bottomRightViewMode
            columnsCount = bottomRightColumns
        }
        let safeColumns = max(1, columnsCount)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            KeyboardManager.shared.setHandler {
                guard let event = NSApp.currentEvent else { return false }

                switch event.keyCode {
                case 126: // Up arrow
                    let offset = mode == .icons ? -safeColumns : -1
                    navigateInViewModel(vm, by: offset)
                    return true
                case 125: // Down arrow
                    let offset = mode == .icons ? safeColumns : 1
                    navigateInViewModel(vm, by: offset)
                    return true
                case 123: // Left arrow
                    navigateInViewModel(vm, by: -1)
                    return true
                case 124: // Right arrow
                    navigateInViewModel(vm, by: 1)
                    return true
                case 36: // Return
                    if let item = vm.selectedItems.first {
                        vm.openItem(item)
                    }
                    return true
                case 49: // Space
                    if let selectedItem = vm.selectedItems.first {
                        guard let previewURL = vm.previewURL(for: selectedItem) else {
                            NSSound.beep()
                            return true
                        }

                        QuickLookControllerView.shared.togglePreview(for: previewURL) { offset in
                            self.navigateInViewModel(vm, by: offset)
                        }
                    }
                    return true
                default:
                    return false
                }
            }
        }
    }

    private func navigateInViewModel(_ vm: FileBrowserViewModel, by offset: Int) {
        let items = vm.filteredItems
        guard !items.isEmpty else { return }

        var currentIndex: Int
        if let selectedItem = vm.selectedItems.first,
           let index = items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        let newItem = items[newIndex]
        vm.selectItem(newItem)
        if let previewURL = vm.previewURL(for: newItem) {
            QuickLookControllerView.shared.updatePreview(for: previewURL)
        } else {
            QuickLookControllerView.shared.updatePreview(for: nil)
        }
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
    @State private var isEditingPath = false
    @State private var editPathText = ""
    @FocusState private var isPathFieldFocused: Bool

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

                Text(viewModel.currentPath.lastPathComponent)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Picker("", selection: $paneViewMode) {
                    ForEach(QuadPaneView.PaneViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
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
                HStack(spacing: 2) {
                    if isEditingPath {
                        TextField("Path", text: $editPathText)
                            .textFieldStyle(.plain)
                            .font(.caption2)
                            .focused($isPathFieldFocused)
                            .onSubmit { navigateToEditedPath() }
                            .onExitCommand { cancelPathEditing() }
                            .onAppear {
                                editPathText = viewModel.currentPath.path
                                isPathFieldFocused = true
                            }

                        Button(action: { navigateToEditedPath() }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)

                        Button(action: { cancelPathEditing() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack(spacing: 2) {
                            ForEach(pathComponents, id: \.self) { component in
                                Text(component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent)
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.navigateToAndSelectCurrent(component)
                                        onActivate()
                                    }

                                if component != viewModel.currentPath {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
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
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))

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
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    .padding(2)
            )

            Divider()

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
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
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

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [sourceURL]) {
                        for other in otherViewModels {
                            other.refresh()
                        }
                    }
                }
            }
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
        var expandedPath = editPathText.trimmingCharacters(in: .whitespaces)
        if expandedPath.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            expandedPath = home + expandedPath.dropFirst()
        }

        let url = URL(fileURLWithPath: expandedPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                viewModel.navigateTo(url)
            } else {
                viewModel.navigateTo(url.deletingLastPathComponent())
            }
            isEditingPath = false
            isPathFieldFocused = false
        } else {
            NSSound.beep()
        }
    }
}

struct QuadPaneListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    @State private var dropTargetedItemID: UUID?

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(viewModel.filteredItems) { item in
                    QuadPaneListRow(item: item, viewModel: viewModel, onActivate: onActivate, dropTargetedItemID: $dropTargetedItemID)
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.selectedItems) { newSelection in
                if let firstSelected = newSelection.first {
                    withAnimation {
                        scrollProxy.scrollTo(firstSelected.id)
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
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: appSettings.compactListIconSize, height: appSettings.compactListIconSize)

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
        .padding(.vertical, 1)
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
        .onDrag {
            guard !item.isFromArchive else { return NSItemProvider() }
            return NSItemProvider(object: item.url as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: QuadPaneFolderDropDelegate(
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
        if let previewURL = viewModel.previewURL(for: item) {
            QuickLookControllerView.shared.updatePreview(for: previewURL)
        } else {
            QuickLookControllerView.shared.updatePreview(for: nil)
        }
    }
}

struct QuadPaneIconView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void

    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var dropTargetedItemID: UUID?
    private let thumbnailCache = ThumbnailCacheManager.shared

    private var cellWidth: CGFloat {
        appSettings.quadPaneIconSize + 32
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: appSettings.quadPaneGridSpacing)]
    }

    private func calculateColumns(width: CGFloat) -> Int {
        let availableWidth = max(0, width - 16)
        let spacing = appSettings.quadPaneGridSpacing
        let columns = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, columns)
    }

    private func loadThumbnail(for item: FileItem) {
        let url = item.url
        guard thumbnails[url] == nil else { return }

        if thumbnailCache.hasFailed(url: url) {
            DispatchQueue.main.async { thumbnails[url] = item.icon }
            return
        }

        if let cached = thumbnailCache.getCachedThumbnail(for: url) {
            DispatchQueue.main.async { thumbnails[url] = cached }
            return
        }

        thumbnailCache.generateThumbnail(for: item) { url, image in
            DispatchQueue.main.async {
                thumbnails[url] = image ?? item.icon
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
                                .onAppear { loadThumbnail(for: item) }
                        }
                    }
                    .padding(8)
                }
                .onAppear {
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: geometry.size.width) { newWidth in
                    onColumnsCalculated(calculateColumns(width: newWidth))
                }
                .onChange(of: appSettings.iconGridIconSize) { _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: appSettings.iconGridSpacing) { _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: viewModel.selectedItems) { newSelection in
                    if let firstSelected = newSelection.first {
                        withAnimation {
                            scrollProxy.scrollTo(firstSelected.id)
                        }
                    }
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
        .onDrag {
            guard !item.isFromArchive else { return NSItemProvider() }
            return NSItemProvider(object: item.url as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: QuadPaneFolderDropDelegate(
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
        if let previewURL = viewModel.previewURL(for: item) {
            QuickLookControllerView.shared.updatePreview(for: previewURL)
        } else {
            QuickLookControllerView.shared.updatePreview(for: nil)
        }
    }
}

// MARK: - Folder Drop Delegate

struct QuadPaneFolderDropDelegate: DropDelegate {
    let item: FileItem
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        return item.isDirectory && !item.isFromArchive && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        if item.isDirectory {
            dropTargetedItemID = item.id
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetedItemID == item.id {
            dropTargetedItemID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard item.isDirectory && !item.isFromArchive else { return DropProposal(operation: .forbidden) }
        let operation: DropOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
        return DropProposal(operation: operation)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard item.isDirectory && !item.isFromArchive else { return false }

        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [url], to: item.url)
                }
            }
        }
        return true
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

struct DualPaneView: View {
    @ObservedObject var leftViewModel: FileBrowserViewModel
    @ObservedObject var rightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane
    @State private var leftPaneViewMode: PaneViewMode = .list
    @State private var rightPaneViewMode: PaneViewMode = .list
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

    // The active viewModel based on current pane
    private var activeViewModel: FileBrowserViewModel {
        activePane == .left ? leftViewModel : rightViewModel
    }

    // Column count for active pane's view mode
    private var activeColumnsCount: Int {
        let mode = activePane == .left ? leftPaneViewMode : rightPaneViewMode
        if mode == .icons {
            return activePane == .left ? leftPaneColumns : rightPaneColumns
        }
        return 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left pane
                PaneView(
                    viewModel: leftViewModel,
                    otherViewModel: rightViewModel,
                    isActive: activePane == .left,
                    paneViewMode: $leftPaneViewMode,
                    onActivate: { activePane = .left },
                    onColumnsCalculated: { cols in leftPaneColumns = cols }
                )

                // Right pane
                PaneView(
                    viewModel: rightViewModel,
                    otherViewModel: leftViewModel,
                    isActive: activePane == .right,
                    paneViewMode: $rightPaneViewMode,
                    onActivate: { activePane = .right },
                    onColumnsCalculated: { cols in rightPaneColumns = cols }
                )
            }
        }
        .onAppear {
            // Select first item in left pane if nothing selected
            if leftViewModel.selectedItems.isEmpty && !leftViewModel.filteredItems.isEmpty {
                leftViewModel.selectItem(leftViewModel.filteredItems[0])
            }
            registerKeyboardHandler(forPane: activePane)
        }
        .onChange(of: activePane) { newPane in
            registerKeyboardHandler(forPane: newPane)
        }
        .onChange(of: leftPaneViewMode) { _ in
            registerKeyboardHandler(forPane: activePane)
        }
        .onChange(of: rightPaneViewMode) { _ in
            registerKeyboardHandler(forPane: activePane)
        }
        .onChange(of: leftPaneColumns) { _ in
            if activePane == .left {
                registerKeyboardHandler(forPane: activePane)
            }
        }
        .onChange(of: rightPaneColumns) { _ in
            if activePane == .right {
                registerKeyboardHandler(forPane: activePane)
            }
        }
    }

    private func registerKeyboardHandler(forPane pane: Pane) {
        // Use explicit pane parameter to avoid race conditions
        let leftMode = leftPaneViewMode
        let rightMode = rightPaneViewMode
        let leftVM = leftViewModel
        let rightVM = rightViewModel
        let leftCols = leftPaneColumns
        let rightCols = rightPaneColumns

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            KeyboardManager.shared.setHandler {
                guard let event = NSApp.currentEvent else { return false }

                let vm = pane == .left ? leftVM : rightVM
                let mode = pane == .left ? leftMode : rightMode
                let columnsCount = mode == .icons ? (pane == .left ? leftCols : rightCols) : 1

                switch event.keyCode {
                case 126: // Up arrow
                    navigateInViewModel(vm, by: -columnsCount)
                    return true
                case 125: // Down arrow
                    navigateInViewModel(vm, by: columnsCount)
                    return true
                case 123: // Left arrow
                    if mode == .icons { navigateInViewModel(vm, by: -1) }
                    return true
                case 124: // Right arrow
                    if mode == .icons { navigateInViewModel(vm, by: 1) }
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

        let currentIndex: Int
        if let selectedItem = vm.selectedItems.first,
           let index = items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        let newItem = items[newIndex]
        vm.selectItem(newItem)

        // Refresh Quick Look if visible
        if let previewURL = vm.previewURL(for: newItem) {
            QuickLookControllerView.shared.updatePreview(for: previewURL)
        } else {
            QuickLookControllerView.shared.updatePreview(for: nil)
        }
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
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                    .padding(4)
            )

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

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [sourceURL]) {
                        otherViewModel.refresh()
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

struct PaneListView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    @State private var dropTargetedItemID: UUID?

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(viewModel.filteredItems) { item in
                    let isSelected = viewModel.selectedItems.contains(item)
                    HStack(spacing: 8) {
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
                            .frame(width: 60, alignment: .trailing)

                        Text(item.formattedDate)
                            .font(appSettings.compactListDetailFont)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .trailing)
                    }
                    .id(item.id)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        dropTargetedItemID == item.id
                            ? Color.accentColor.opacity(0.4)
                            : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .opacity(dropTargetedItemID == item.id ? 1 : 0)
                    )
                    .contentShape(Rectangle())
                    .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
                    .onDrag {
                        guard !item.isFromArchive else { return NSItemProvider() }
                        return NSItemProvider(object: item.url as NSURL)
                    }
                    .onDrop(of: [.fileURL], delegate: DualPaneFolderDropDelegate(
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
                                if let previewURL = viewModel.previewURL(for: item) {
                                    QuickLookControllerView.shared.updatePreview(for: previewURL)
                                } else {
                                    QuickLookControllerView.shared.updatePreview(for: nil)
                                }
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
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
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

struct PaneIconView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void

    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var dropTargetedItemID: UUID?
    private let thumbnailCache = ThumbnailCacheManager.shared

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
        return min(512, max(96, bucket))
    }

    private func calculateColumns(width: CGFloat) -> Int {
        let availableWidth = max(0, width - 32)
        let spacing = appSettings.dualPaneGridSpacing
        let columns = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, columns)
    }

    private func loadThumbnail(for item: FileItem) {
        let url = item.url
        let targetPixelSize = thumbnailPixelSize
        if let existing = thumbnails[url],
           imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
            return
        }
        if thumbnailCache.isPending(url: url, maxPixelSize: targetPixelSize) { return }

        if thumbnailCache.hasFailed(url: url) {
            DispatchQueue.main.async { thumbnails[url] = item.icon }
            return
        }

        if let cached = thumbnailCache.getCachedThumbnail(for: url, maxPixelSize: targetPixelSize) {
            DispatchQueue.main.async { thumbnails[url] = cached }
            return
        }

        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { url, image in
            DispatchQueue.main.async {
                thumbnails[url] = image ?? item.icon
            }
        }
    }

    private func refreshThumbnails() {
        let targetPixelSize = thumbnailPixelSize
        DispatchQueue.main.async {
            for item in viewModel.filteredItems {
                if let existing = thumbnails[item.url],
                   imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
                    continue
                }
                loadThumbnail(for: item)
            }
        }
    }

    private func imageSatisfiesMinimum(_ image: NSImage, minPixelSize: CGFloat) -> Bool {
        let maxDimension = max(image.size.width, image.size.height)
        return maxDimension >= minPixelSize * 0.9
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
                            .onAppear { loadThumbnail(for: item) }
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
                            .onDrag {
                                guard !item.isFromArchive else { return NSItemProvider() }
                                return NSItemProvider(object: item.url as NSURL)
                            }
                            .onDrop(of: [.fileURL], delegate: DualPaneFolderDropDelegate(
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
                                        if let previewURL = viewModel.previewURL(for: item) {
                                            QuickLookControllerView.shared.updatePreview(for: previewURL)
                                        } else {
                                            QuickLookControllerView.shared.updatePreview(for: nil)
                                        }
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
                }
                .onChange(of: geometry.size.width) { newWidth in
                    onColumnsCalculated(calculateColumns(width: newWidth))
                }
                .onChange(of: appSettings.iconGridIconSize) { _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                    refreshThumbnails()
                }
                .onChange(of: appSettings.iconGridSpacing) { _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: appSettings.thumbnailQuality) { _ in
                    refreshThumbnails()
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

// MARK: - Folder Drop Delegate

struct DualPaneFolderDropDelegate: DropDelegate {
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

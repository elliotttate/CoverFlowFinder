import SwiftUI
import AppKit
import Quartz

struct FileListView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @State private var isDropTargeted = false
    @State private var dropTargetedItemID: UUID?

    // Thumbnail loading
    @State private var thumbnails: [URL: NSImage] = [:]
    private let thumbnailCache = ThumbnailCacheManager.shared

    private var listThumbnailPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let baseTarget = max(192, settings.listIconSizeValue * scale)
        let target = baseTarget * settings.thumbnailQualityValue
        let bucket = (target / 64).rounded() * 64
        return min(512, max(96, bucket))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Column headers - fixed at top
            ColumnHeaderView(columnConfig: columnConfig)
            Divider()

            // File list - fills remaining space
            ScrollViewReader { scrollProxy in
                List(selection: Binding(
                    get: { Set(viewModel.selectedItems.map { $0.id }) },
                    set: { ids in
                        viewModel.selectedItems = Set(items.filter { ids.contains($0.id) })
                    }
                )) {
                    ForEach(items) { item in
                        FileListRowView(
                            item: item,
                            viewModel: viewModel,
                            isSelected: viewModel.selectedItems.contains(item),
                            columnConfig: columnConfig,
                            thumbnail: thumbnails[item.url]
                        )
                        .tag(item.id)
                        .id(item.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(
                            dropTargetedItemID == item.id
                                ? Color.accentColor.opacity(0.3)
                                : (viewModel.selectedItems.contains(item)
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .opacity(dropTargetedItemID == item.id ? 1 : 0)
                        )
                        .onAppear {
                            loadThumbnail(for: item)
                        }
                        .onDrag {
                            guard !item.isFromArchive else { return NSItemProvider() }
                            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                        }
                        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(
                            item: item,
                            viewModel: viewModel,
                            dropTargetedItemID: $dropTargetedItemID
                        ))
                        .instantTap(
                            id: item.id,
                            onSingleClick: {
                                if let index = items.firstIndex(of: item) {
                                    let modifiers = NSEvent.modifierFlags
                                    viewModel.handleSelection(
                                        item: item,
                                        index: index,
                                        in: items,
                                        withShift: modifiers.contains(.shift),
                                        withCommand: modifiers.contains(.command)
                                    )
                                    updateQuickLook(for: item)
                                }
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
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.visible)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
                .onChange(of: viewModel.selectedItems) { newSelection in
                    if let firstSelected = newSelection.first {
                        withAnimation {
                            scrollProxy.scrollTo(firstSelected.id)
                        }
                        updateQuickLook(for: firstSelected)
                    } else {
                        updateQuickLook(for: nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(4)
        )
        .onChange(of: items) { _ in
            DispatchQueue.main.async {
                thumbnails.removeAll()
                thumbnailCache.clearForNewFolder()
            }
        }
        .onChange(of: settings.thumbnailQuality) { _ in
            refreshThumbnails()
        }
        .onChange(of: settings.listIconSize) { _ in
            refreshThumbnails()
        }
        .keyboardNavigable(
            onUpArrow: { navigateSelection(by: -1) },
            onDownArrow: { navigateSelection(by: 1) },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() }
        )
    }

    private func navigateSelection(by offset: Int) {
        guard !items.isEmpty else { return }

        let currentIndex: Int
        if let selectedItem = viewModel.selectedItems.first,
           let index = items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        let newItem = items[newIndex]
        viewModel.selectItem(newItem)

        // Refresh Quick Look if visible
        updateQuickLook(for: newItem)
    }

    private func openSelectedItem() {
        if let selectedItem = viewModel.selectedItems.first {
            viewModel.openItem(selectedItem)
        }
    }

    private func toggleQuickLook() {
        guard let selectedItem = viewModel.selectedItems.first else { return }

        guard let previewURL = viewModel.previewURL(for: selectedItem) else {
            NSSound.beep()
            return
        }

        QuickLookControllerView.shared.togglePreview(for: previewURL) { [self] offset in
            // List: up/down navigation (offset is 1 or -1)
            navigateSelection(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        guard let item else {
            QuickLookControllerView.shared.updatePreview(for: nil)
            return
        }

        if let previewURL = viewModel.previewURL(for: item) {
            QuickLookControllerView.shared.updatePreview(for: previewURL)
        } else {
            QuickLookControllerView.shared.updatePreview(for: nil)
        }
    }

    private func loadThumbnail(for item: FileItem) {
        let url = item.url
        let targetPixelSize = listThumbnailPixelSize

        // Already loaded or loading
        if let existing = thumbnails[url],
           imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
            return
        }
        if thumbnailCache.isPending(url: url, maxPixelSize: targetPixelSize) { return }
        if thumbnailCache.hasFailed(url: url) {
            // Defer state change to avoid publishing during view update
            DispatchQueue.main.async {
                thumbnails[url] = item.icon
            }
            return
        }

        // Check cache first
        if let cached = thumbnailCache.getCachedThumbnail(for: url, maxPixelSize: targetPixelSize) {
            DispatchQueue.main.async {
                thumbnails[url] = cached
            }
            return
        }

        // Generate thumbnail
        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { url, image in
            DispatchQueue.main.async { [self] in
                if let image = image {
                    thumbnails[url] = image
                } else {
                    thumbnails[url] = item.icon
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [sourceURL])
                }
            }
        }
    }

    private func refreshThumbnails() {
        let targetPixelSize = listThumbnailPixelSize
        DispatchQueue.main.async {
            for item in items {
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
}

// MARK: - Column Header View

struct ColumnHeaderView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var columnConfig: ListColumnConfigManager
    @State private var resizingColumn: ListColumn?
    @State private var initialWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columnConfig.visibleColumns) { settings in
                ColumnHeaderCell(
                    settings: settings,
                    isSortColumn: columnConfig.sortColumn == settings.column,
                    sortDirection: columnConfig.sortDirection,
                    onSort: { columnConfig.setSortColumn(settings.column) },
                    onResize: { delta in
                        columnConfig.setColumnWidth(settings.column, width: settings.width + delta)
                    }
                )
                .contextMenu {
                    columnVisibilityMenu
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var columnVisibilityMenu: some View {
        Text("Columns")
            .font(appSettings.listDetailFont)

        Divider()

        ForEach(ListColumn.allCases) { column in
            let isVisible = columnConfig.columns.first(where: { $0.column == column })?.isVisible ?? false
            Button {
                columnConfig.toggleColumnVisibility(column)
            } label: {
                HStack {
                    if isVisible {
                        Image(systemName: "checkmark")
                    }
                    Text(column.rawValue)
                }
            }
            .disabled(column == .name) // Name column always visible
        }

        Divider()

        Button("Reset to Defaults") {
            columnConfig.resetToDefaults()
        }
    }
}

// MARK: - Column Header Cell

struct ColumnHeaderCell: View {
    @EnvironmentObject private var appSettings: AppSettings
    let settings: ColumnSettings
    let isSortColumn: Bool
    let sortDirection: SortDirection
    let onSort: () -> Void
    let onResize: (CGFloat) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSort) {
                HStack(spacing: 4) {
                    Text(settings.column.rawValue)
                        .font(appSettings.listDetailFont)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if isSortColumn {
                        Image(systemName: sortDirection == .ascending ? "chevron.up" : "chevron.down")
                            .font(appSettings.listDetailFont)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: settings.column.alignment)
            }
            .buttonStyle(.plain)

            // Resize handle
            Rectangle()
                .fill(isHovering ? Color.accentColor : Color.clear)
                .frame(width: 4)
                .contentShape(Rectangle().inset(by: -4))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            onResize(value.translation.width)
                        }
                )
                .onHover { hovering in
                    isHovering = hovering
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .frame(width: settings.width)
    }
}

// MARK: - File List Row View

struct FileListRowView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let isSelected: Bool
    @ObservedObject var columnConfig: ListColumnConfigManager
    let thumbnail: NSImage?

    private var displayImage: NSImage {
        thumbnail ?? item.icon
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columnConfig.visibleColumns) { settings in
                cellContent(for: settings.column)
                    .frame(width: settings.width, alignment: settings.column.alignment)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
    }

    @ViewBuilder
    private func cellContent(for column: ListColumn) -> some View {
        switch column {
        case .name:
            HStack(spacing: 8) {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: appSettings.listIconSizeValue, height: appSettings.listIconSizeValue)
                    .cornerRadius(2)
                InlineRenameField(item: item, viewModel: viewModel, font: appSettings.listFont, alignment: .leading, lineLimit: 1)
                if appSettings.showItemTags, !item.tags.isEmpty {
                    TagDotsView(tags: item.tags)
                }
            }
        case .dateModified:
            Text(item.formattedDate)
                .foregroundColor(.secondary)
                .font(appSettings.listDetailFont)
        case .dateCreated:
            Text(formattedCreationDate)
                .foregroundColor(.secondary)
                .font(appSettings.listDetailFont)
        case .size:
            Text(item.formattedSize)
                .foregroundColor(.secondary)
                .font(appSettings.listDetailFont)
        case .kind:
            Text(item.kindDescription)
                .foregroundColor(.secondary)
                .font(appSettings.listDetailFont)
        case .tags:
            TagsView(url: item.url)
        }
    }

    private var formattedCreationDate: String {
        guard let date = item.creationDate else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}

// MARK: - Tags View

struct TagsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let url: URL
    @State private var tags: [String] = []

    var body: some View {
        Group {
            if appSettings.showItemTags {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        TagBadge(name: tag)
                    }
                    if tags.count > 3 {
                        Text("+\(tags.count - 3)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .onAppear {
            tags = FileTagManager.getTags(for: url)
        }
    }
}

/// Displays tag dots inline (Finder-style) - just colored circles
struct TagDotsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let tags: [String]

    var body: some View {
        Group {
            if appSettings.showItemTags {
                HStack(spacing: 2) {
                    ForEach(tags.prefix(3), id: \.self) { tagName in
                        if let tag = FinderTag.from(name: tagName) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 10, height: 10)
                        }
                    }
                }
            }
        }
    }
}

struct TagBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tagColor.opacity(0.3))
            .foregroundColor(tagColor)
            .clipShape(Capsule())
    }

    private var tagColor: Color {
        if let finderTag = FinderTag.from(name: name) {
            return finderTag.color
        }
        return .accentColor
    }
}

// MARK: - Folder Drop Delegate

struct FolderDropDelegate: DropDelegate {
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

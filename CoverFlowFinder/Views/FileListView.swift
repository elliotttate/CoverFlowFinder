import SwiftUI
import Quartz

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @State private var renamingItem: FileItem?
    @State private var isDropTargeted = false

    // Thumbnail loading
    @State private var thumbnails: [URL: NSImage] = [:]
    private let thumbnailCache = ThumbnailCacheManager.shared

    private var sortedItems: [FileItem] {
        columnConfig.sortedItems(items)
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
                        viewModel.selectedItems = Set(sortedItems.filter { ids.contains($0.id) })
                    }
                )) {
                    ForEach(sortedItems) { item in
                        FileListRowView(
                            item: item,
                            isSelected: viewModel.selectedItems.contains(item),
                            columnConfig: columnConfig,
                            thumbnail: thumbnails[item.url]
                        )
                        .tag(item.id)
                        .id(item.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .onAppear {
                            loadThumbnail(for: item)
                        }
                        .onDrag {
                            NSItemProvider(object: item.url as NSURL)
                        }
                        .instantTap(
                            id: item.id,
                            onSingleClick: {
                                if let index = sortedItems.firstIndex(of: item) {
                                    let modifiers = NSEvent.modifierFlags
                                    viewModel.handleSelection(
                                        item: item,
                                        index: index,
                                        in: sortedItems,
                                        withShift: modifiers.contains(.shift),
                                        withCommand: modifiers.contains(.command)
                                    )
                                }
                            },
                            onDoubleClick: {
                                viewModel.openItem(item)
                            }
                        )
                        .contextMenu {
                            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                renamingItem = item
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
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(QuickLookHost())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(4)
        )
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
        .onChange(of: items) { _ in
            DispatchQueue.main.async {
                thumbnails.removeAll()
                thumbnailCache.clearForNewFolder()
            }
        }
        .keyboardNavigable(
            onUpArrow: { navigateSelection(by: -1) },
            onDownArrow: { navigateSelection(by: 1) },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() }
        )
    }

    private func navigateSelection(by offset: Int) {
        guard !sortedItems.isEmpty else { return }

        let currentIndex: Int
        if let selectedItem = viewModel.selectedItems.first,
           let index = sortedItems.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(sortedItems.count - 1, currentIndex + offset))
        let newItem = sortedItems[newIndex]
        viewModel.selectItem(newItem)

        // Refresh Quick Look if visible
        QuickLookControllerView.shared.updatePreview(for: newItem.url)
    }

    private func openSelectedItem() {
        if let selectedItem = viewModel.selectedItems.first {
            viewModel.openItem(selectedItem)
        }
    }

    private func toggleQuickLook() {
        guard let selectedItem = viewModel.selectedItems.first else { return }

        QuickLookControllerView.shared.togglePreview(for: selectedItem.url) { [self] offset in
            // List: up/down navigation (offset is 1 or -1)
            navigateSelection(by: offset)
        }
    }

    private func loadThumbnail(for item: FileItem) {
        let url = item.url

        // Already loaded or loading
        if thumbnails[url] != nil { return }
        if thumbnailCache.isPending(url: url) { return }
        if thumbnailCache.hasFailed(url: url) {
            // Defer state change to avoid publishing during view update
            DispatchQueue.main.async {
                thumbnails[url] = item.icon
            }
            return
        }

        // Check cache first
        if let cached = thumbnailCache.getCachedThumbnail(for: url) {
            DispatchQueue.main.async {
                thumbnails[url] = cached
            }
            return
        }

        // Generate thumbnail
        thumbnailCache.generateThumbnail(for: item) { url, image in
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
        let destPath = viewModel.currentPath
        let shouldMove = NSEvent.modifierFlags.contains(.option)

        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, error in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                if sourceURL.deletingLastPathComponent() == destPath {
                    return
                }

                let destURL = destPath.appendingPathComponent(sourceURL.lastPathComponent)

                var finalURL = destURL
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let name = sourceURL.deletingPathExtension().lastPathComponent
                    let ext = sourceURL.pathExtension
                    if ext.isEmpty {
                        finalURL = destPath.appendingPathComponent("\(name) \(counter)")
                    } else {
                        finalURL = destPath.appendingPathComponent("\(name) \(counter).\(ext)")
                    }
                    counter += 1
                }

                do {
                    if shouldMove {
                        try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                    } else {
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                    }
                    DispatchQueue.main.async {
                        viewModel.refresh()
                    }
                } catch {
                    print("Failed to \(shouldMove ? "move" : "copy") \(sourceURL.lastPathComponent): \(error)")
                }
            }
        }
    }
}

// MARK: - Column Header View

struct ColumnHeaderView: View {
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
            .font(.caption)

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
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if isSortColumn {
                        Image(systemName: sortDirection == .ascending ? "chevron.up" : "chevron.down")
                            .font(.caption2)
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
    let item: FileItem
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
    }

    @ViewBuilder
    private func cellContent(for column: ListColumn) -> some View {
        switch column {
        case .name:
            HStack(spacing: 8) {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .cornerRadius(2)
                Text(item.name)
                    .lineLimit(1)
            }
        case .dateModified:
            Text(item.formattedDate)
                .foregroundColor(.secondary)
                .font(.caption)
        case .dateCreated:
            Text(formattedCreationDate)
                .foregroundColor(.secondary)
                .font(.caption)
        case .size:
            Text(item.formattedSize)
                .foregroundColor(.secondary)
                .font(.caption)
        case .kind:
            Text(kindDescription(for: item))
                .foregroundColor(.secondary)
                .font(.caption)
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

    private func kindDescription(for item: FileItem) -> String {
        if item.isDirectory {
            return "Folder"
        }
        switch item.fileType {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .code: return "Source Code"
        case .archive: return "Archive"
        case .application: return "Application"
        default: return "Document"
        }
    }
}

// MARK: - Tags View

struct TagsView: View {
    let url: URL
    @State private var tags: [String] = []

    var body: some View {
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
        .onAppear {
            loadTags()
        }
    }

    private func loadTags() {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.tagNamesKey])
            tags = resourceValues.tagNames ?? []
        } catch {
            tags = []
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
        // Map common Finder tag colors
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "gray", "grey": return .gray
        default: return .accentColor
        }
    }
}

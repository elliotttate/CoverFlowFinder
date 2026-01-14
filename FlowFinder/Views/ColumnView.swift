import SwiftUI
import AppKit
import QuickLookThumbnailing
import Quartz

struct ColumnView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var columnSelections: [URL: FileItem] = [:]
    @State private var columns: [ColumnData] = []
    @State private var activeColumnIndex: Int = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                // First column with current items
                SingleColumnView(
                    items: items,
                    selectedItem: columnSelections[viewModel.currentPath],
                    columnURL: viewModel.currentPath,
                    viewModel: viewModel,
                    onSelect: { item in
                        columnSelections[viewModel.currentPath] = item
                        activeColumnIndex = 0
                        if item.isDirectory {
                            updateColumns(from: item)
                        } else {
                            columns = []
                        }
                        updateQuickLook(for: item)
                    },
                    onDoubleClick: { item in
                        viewModel.openItem(item)
                    }
                )

                // Additional columns for subdirectories
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    Divider()
                    SingleColumnView(
                        items: column.items,
                        selectedItem: columnSelections[column.url],
                        columnURL: column.url,
                        viewModel: viewModel,
                        onSelect: { item in
                            columnSelections[column.url] = item
                            activeColumnIndex = index + 1
                            if item.isDirectory {
                                updateColumnsFrom(column: column, selectedItem: item)
                            } else {
                                removeColumnsAfter(column)
                            }
                            updateQuickLook(for: item)
                        },
                        onDoubleClick: { item in
                            viewModel.openItem(item)
                        }
                    )
                }

                // Preview column for selected file
                if appSettings.columnShowPreview,
                   let lastSelection = lastSelectedItem,
                   !lastSelection.isDirectory {
                    Divider()
                    PreviewColumn(item: lastSelection)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .keyboardNavigable(
            onUpArrow: { navigateInActiveColumn(by: -1) },
            onDownArrow: { navigateInActiveColumn(by: 1) },
            onLeftArrow: { navigateToParentColumn() },
            onRightArrow: { navigateToChildColumn() },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() },
            onDelete: { viewModel.deleteSelectedItems() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste() },
            onTypeAhead: { searchString in jumpToMatch(searchString) }
        )
        .onAppear {
            // Sync viewModel's selection to local columnSelections when view appears
            if let firstSelected = viewModel.selectedItems.first,
               items.contains(firstSelected) {
                columnSelections[viewModel.currentPath] = firstSelected
            }
        }
    }

    private var lastSelectedItem: FileItem? {
        if let last = columns.last, let selection = columnSelections[last.url] {
            return selection
        }
        return columnSelections[viewModel.currentPath]
    }

    private func updateColumns(from item: FileItem) {
        columns = []
        if item.isDirectory {
            loadColumn(for: item.url)
        }
    }

    private func updateColumnsFrom(column: ColumnData, selectedItem: FileItem) {
        if let index = columns.firstIndex(where: { $0.id == column.id }) {
            columns = Array(columns.prefix(index + 1))
        }
        if selectedItem.isDirectory {
            loadColumn(for: selectedItem.url)
        }
    }

    private func removeColumnsAfter(_ column: ColumnData) {
        if let index = columns.firstIndex(where: { $0.id == column.id }) {
            columns = Array(columns.prefix(index + 1))
        }
    }

    private func loadColumn(for url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                let fileItems = contents.map { FileItem(url: $0) }.sorted { $0.name < $1.name }

                DispatchQueue.main.async {
                    let columnData = ColumnData(url: url, items: fileItems)
                    columns.append(columnData)
                }
            } catch {
                // Handle error silently
            }
        }
    }

    // MARK: - Keyboard Navigation

    private func navigateInActiveColumn(by offset: Int) {
        let (columnItems, columnURL) = getActiveColumnData()
        guard !columnItems.isEmpty else { return }

        let currentIndex: Int
        if let selected = columnSelections[columnURL],
           let index = columnItems.firstIndex(of: selected) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(columnItems.count - 1, currentIndex + offset))
        let newItem = columnItems[newIndex]
        columnSelections[columnURL] = newItem
        viewModel.selectItem(newItem)

        // Update subsequent columns if directory
        if activeColumnIndex == 0 {
            if newItem.isDirectory {
                updateColumns(from: newItem)
            } else {
                columns = []
            }
        } else if activeColumnIndex <= columns.count {
            let column = columns[activeColumnIndex - 1]
            if newItem.isDirectory {
                updateColumnsFrom(column: column, selectedItem: newItem)
            } else {
                removeColumnsAfter(column)
            }
        }

        // Refresh Quick Look if visible
        updateQuickLook(for: newItem)
    }

    private func navigateToParentColumn() {
        if activeColumnIndex > 0 {
            activeColumnIndex -= 1
        }
    }

    private func navigateToChildColumn() {
        let (_, columnURL) = getActiveColumnData()
        if let selected = columnSelections[columnURL], selected.isDirectory {
            if activeColumnIndex < columns.count {
                activeColumnIndex += 1
                // Select first item in new column if nothing selected
                let newColumnURL = columns[activeColumnIndex - 1].url
                if columnSelections[newColumnURL] == nil, let firstItem = columns[activeColumnIndex - 1].items.first {
                    columnSelections[newColumnURL] = firstItem
                    viewModel.selectItem(firstItem)
                }
            }
        }
    }

    private func getActiveColumnData() -> ([FileItem], URL) {
        if activeColumnIndex == 0 {
            return (items, viewModel.currentPath)
        } else if activeColumnIndex <= columns.count {
            let column = columns[activeColumnIndex - 1]
            return (column.items, column.url)
        }
        return ([], viewModel.currentPath)
    }

    private func openSelectedItem() {
        if let selectedItem = viewModel.selectedItems.first {
            viewModel.openItem(selectedItem)
        }
    }

    private func jumpToMatch(_ searchString: String) {
        guard !searchString.isEmpty else { return }
        let lowercased = searchString.lowercased()
        let (columnItems, columnURL) = getActiveColumnData()

        if let matchItem = columnItems.first(where: { $0.name.lowercased().hasPrefix(lowercased) }) {
            columnSelections[columnURL] = matchItem
            viewModel.selectItem(matchItem)
            updateQuickLook(for: matchItem)

            // Update columns if directory
            if activeColumnIndex == 0 {
                if matchItem.isDirectory {
                    updateColumns(from: matchItem)
                } else {
                    columns = []
                }
            } else if activeColumnIndex <= columns.count {
                let column = columns[activeColumnIndex - 1]
                if matchItem.isDirectory {
                    updateColumnsFrom(column: column, selectedItem: matchItem)
                } else {
                    removeColumnsAfter(column)
                }
            }
        }
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection { [self] offset in
            navigateInActiveColumn(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item)
    }
}

struct ColumnData: Identifiable {
    let id = UUID()
    let url: URL
    let items: [FileItem]
}

struct SingleColumnView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let items: [FileItem]
    let selectedItem: FileItem?
    let columnURL: URL
    @ObservedObject var viewModel: FileBrowserViewModel
    let onSelect: (FileItem) -> Void
    let onDoubleClick: (FileItem) -> Void
    @State private var dropTargetedItemID: UUID?
    @State private var isColumnDropTargeted = false

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(items) { item in
                    ColumnRowView(
                        item: item,
                        viewModel: viewModel,
                        isSelected: viewModel.selectedItems.contains(item)
                    )
                    .id(item.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
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
                    .onDrag {
                        guard !item.isFromArchive else { return NSItemProvider() }

                        // Check if this item is part of a multi-selection
                        let itemsToDrag: [FileItem]
                        if viewModel.selectedItems.contains(item) && viewModel.selectedItems.count > 1 {
                            itemsToDrag = Array(viewModel.selectedItems).filter { !$0.isFromArchive }
                        } else {
                            itemsToDrag = [item]
                        }

                        // Write all URLs to the pasteboard for multi-selection drag
                        let urls = itemsToDrag.map { $0.url as NSURL }
                        let pasteboard = NSPasteboard(name: .drag)
                        pasteboard.clearContents()
                        pasteboard.writeObjects(urls)

                        return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                    }
                    .onDrop(of: [.fileURL], delegate: UnifiedFolderDropDelegate(
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
                            }
                            onSelect(item)
                        },
                        onDoubleClick: {
                            onDoubleClick(item)
                        }
                    )
                    .contextMenu {
                        FileItemContextMenu(item: item, viewModel: viewModel) { item in
                            viewModel.renamingURL = item.url
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .frame(width: appSettings.columnWidthValue)
            .onDrop(of: [.fileURL], delegate: ColumnBackgroundDropDelegate(
                columnURL: columnURL,
                viewModel: viewModel,
                dropTargetedItemID: $dropTargetedItemID,
                isColumnDropTargeted: $isColumnDropTargeted
            ))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isColumnDropTargeted && dropTargetedItemID == nil ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onAppear {
                // Scroll to selected item when view appears (e.g., when switching view modes)
                if let selected = selectedItem {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollProxy.scrollTo(selected.id, anchor: .center)
                    }
                }
            }
            .onChange(of: selectedItem) { newSelection in
                if let selected = newSelection {
                    withAnimation {
                        scrollProxy.scrollTo(selected.id)
                    }
                }
            }
        }
    }
}

struct ColumnRowView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            AsyncListIconView(item: item, size: appSettings.columnIconSizeValue)

            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.columnFont, alignment: .leading, lineLimit: 1)

            if appSettings.showItemTags, !item.tags.isEmpty {
                TagDotsView(tags: item.tags)
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(appSettings.columnDetailFont)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
    }
}

struct PreviewColumn: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 16) {
            // Thumbnail or icon
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 200)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                } else {
                    Image(nsImage: item.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                }
            }
            .padding(.top, 20)

            // File info
            VStack(spacing: 8) {
                Text(item.displayName(showFileExtensions: appSettings.showFileExtensions))
                    .font(appSettings.columnPreviewTitleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 100)

                VStack(alignment: .leading, spacing: 4) {
                    InfoRow(label: "Kind", value: item.isDirectory ? "Folder" : kindDescription)
                    InfoRow(label: "Size", value: item.formattedSize)
                    InfoRow(label: "Modified", value: item.formattedDate)
                }
                .font(appSettings.columnDetailFont)
            }

            Spacer()
        }
        .frame(width: appSettings.columnPreviewWidthValue)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadThumbnail()
        }
    }

    private var kindDescription: String {
        item.kindDescription
    }

    private func loadThumbnail() {
        let baseSize = 400.0 * appSettings.thumbnailQualityValue
        let clamped = min(640.0, max(240.0, baseSize))
        let size = CGSize(width: clamped, height: clamped)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, type, error in
            if let thumbnail = thumbnail {
                DispatchQueue.main.async {
                    self.thumbnail = thumbnail.nsImage
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .lineLimit(1)
        }
    }
}

// MARK: - Column Background Drop Delegate

struct ColumnBackgroundDropDelegate: DropDelegate {
    let columnURL: URL
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?
    @Binding var isColumnDropTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        return !viewModel.isInsideArchive && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        if dropTargetedItemID == nil {
            isColumnDropTargeted = true
        }
    }

    func dropExited(info: DropInfo) {
        isColumnDropTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard !viewModel.isInsideArchive else {
            isColumnDropTargeted = false
            return DropProposal(operation: .forbidden)
        }
        // Show column highlight when not over a folder
        if dropTargetedItemID == nil {
            isColumnDropTargeted = true
        } else {
            isColumnDropTargeted = false
        }
        let operation: DropOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
        return DropProposal(operation: operation)
    }

    func performDrop(info: DropInfo) -> Bool {
        // If hovering over a folder, that delegate handles it
        guard dropTargetedItemID == nil, !viewModel.isInsideArchive else { return false }

        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [url], to: columnURL)
                }
            }
        }
        return true
    }
}

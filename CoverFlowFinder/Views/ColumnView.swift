import SwiftUI
import QuickLookThumbnailing
import Quartz

struct ColumnView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var columnSelections: [URL: FileItem] = [:]
    @State private var columns: [ColumnData] = []
    @State private var renamingItem: FileItem?
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
                    onRename: { item in renamingItem = item },
                    onSelect: { item in
                        columnSelections[viewModel.currentPath] = item
                        viewModel.selectItem(item)
                        activeColumnIndex = 0
                        if item.isDirectory {
                            updateColumns(from: item)
                        } else {
                            // Clear subsequent columns for files
                            columns = []
                        }
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
                        onRename: { item in renamingItem = item },
                        onSelect: { item in
                            columnSelections[column.url] = item
                            viewModel.selectItem(item)
                            activeColumnIndex = index + 1
                            if item.isDirectory {
                                updateColumnsFrom(column: column, selectedItem: item)
                            } else {
                                removeColumnsAfter(column)
                            }
                        },
                        onDoubleClick: { item in
                            viewModel.openItem(item)
                        }
                    )
                }

                // Preview column for selected file
                if let lastSelection = lastSelectedItem, !lastSelection.isDirectory {
                    Divider()
                    PreviewColumn(item: lastSelection)
                }
            }
        }
        .background(QuickLookHost())
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
        .keyboardNavigable(
            onUpArrow: { navigateInActiveColumn(by: -1) },
            onDownArrow: { navigateInActiveColumn(by: 1) },
            onLeftArrow: { navigateToParentColumn() },
            onRightArrow: { navigateToChildColumn() },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() }
        )
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
        QuickLookControllerView.shared.updatePreview(for: newItem.url)
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

    private func toggleQuickLook() {
        guard let selectedItem = viewModel.selectedItems.first else { return }

        QuickLookControllerView.shared.togglePreview(for: selectedItem.url) { [self] offset in
            // Column view: up/down navigation within column
            navigateInActiveColumn(by: offset)
        }
    }
}

struct ColumnData: Identifiable {
    let id = UUID()
    let url: URL
    let items: [FileItem]
}

struct SingleColumnView: View {
    let items: [FileItem]
    let selectedItem: FileItem?
    let columnURL: URL
    @ObservedObject var viewModel: FileBrowserViewModel
    let onRename: (FileItem) -> Void
    let onSelect: (FileItem) -> Void
    let onDoubleClick: (FileItem) -> Void
    @State private var isDropTargeted = false

    var body: some View {
        List(items, id: \.id) { item in
            ColumnRowView(
                item: item,
                isSelected: selectedItem?.id == item.id
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onDrag {
                NSItemProvider(object: item.url as NSURL)
            }
            .instantTap(
                id: item.id,
                onSingleClick: {
                    onSelect(item)
                },
                onDoubleClick: {
                    onDoubleClick(item)
                }
            )
            .contextMenu {
                FileItemContextMenu(item: item, viewModel: viewModel) { item in
                    onRename(item)
                }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(
                selectedItem?.id == item.id
                    ? Color.accentColor.opacity(0.3)
                    : Color.clear
            )
        }
        .listStyle(.plain)
        .frame(width: 220)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers, destPath: columnURL)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func handleDrop(providers: [NSItemProvider], destPath: URL) {
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

struct ColumnRowView: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)

            Text(item.name)
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .primary)

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PreviewColumn: View {
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
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 100)

                VStack(alignment: .leading, spacing: 4) {
                    InfoRow(label: "Kind", value: item.isDirectory ? "Folder" : kindDescription)
                    InfoRow(label: "Size", value: item.formattedSize)
                    InfoRow(label: "Modified", value: item.formattedDate)
                }
                .font(.caption)
            }

            Spacer()
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadThumbnail()
        }
    }

    private var kindDescription: String {
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

    private func loadThumbnail() {
        let size = CGSize(width: 400, height: 400)
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

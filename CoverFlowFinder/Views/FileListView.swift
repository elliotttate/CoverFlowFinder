import SwiftUI
import Quartz

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @State private var renamingItem: FileItem?
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: Binding(
            get: { Set(viewModel.selectedItems.map { $0.id }) },
            set: { ids in
                viewModel.selectedItems = Set(items.filter { ids.contains($0.id) })
            }
        )) {
            // Header row
            HStack(spacing: 0) {
                Text("Name")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(minWidth: 200, alignment: .leading)

                Spacer()

                Text("Date Modified")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 150, alignment: .trailing)

                Text("Size")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 80, alignment: .trailing)

                Text("Kind")
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 100, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(.secondary)

            ForEach(items) { item in
                FileListRowView(item: item, isSelected: viewModel.selectedItems.contains(item))
                    .tag(item.id)
                    .onDrag {
                        NSItemProvider(object: item.url as NSURL)
                    }
                    .onTapGesture(count: 2) {
                        viewModel.openItem(item)
                    }
                    .onTapGesture(count: 1) {
                        viewModel.selectItem(item, extend: NSEvent.modifierFlags.contains(.command))
                    }
                    .contextMenu {
                        FileItemContextMenu(item: item, viewModel: viewModel) { item in
                            renamingItem = item
                        }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
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
    }

    private func openSelectedItem() {
        if let selectedItem = viewModel.selectedItems.first {
            viewModel.openItem(selectedItem)
        }
    }

    private func toggleQuickLook() {
        guard viewModel.selectedItems.first != nil else { return }

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
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

struct FileListRowView: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                Text(item.name)
                    .lineLimit(1)
            }
            .frame(minWidth: 200, alignment: .leading)

            Spacer()

            Text(item.formattedDate)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 150, alignment: .trailing)

            Text(item.formattedSize)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 80, alignment: .trailing)

            Text(kindDescription(for: item))
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

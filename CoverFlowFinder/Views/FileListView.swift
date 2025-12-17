import SwiftUI

struct FileListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @State private var renamingItem: FileItem?

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
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
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

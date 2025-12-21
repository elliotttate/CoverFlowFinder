import SwiftUI
import AppKit
import Quartz

struct FileListView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @State private var isDropTargeted = false

    var body: some View {
        FileTableView(
            viewModel: viewModel,
            columnConfig: columnConfig,
            appSettings: settings,
            items: items
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(4)
                .allowsHitTesting(false)  // Don't capture clicks on the overlay
        )
        .onChange(of: viewModel.selectedItems) { newSelection in
            if let firstSelected = newSelection.first {
                updateQuickLook(for: firstSelected)
            } else {
                updateQuickLook(for: nil)
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

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
            items: items,
            tagRefreshToken: viewModel.tagRefreshToken
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .dropTargetOverlay(isTargeted: isDropTargeted)
        .allowsHitTesting(true)
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
            onSpace: { toggleQuickLook() },
            onDelete: { viewModel.deleteSelectedItems() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste() },
            onTypeAhead: { searchString in jumpToMatch(searchString) }
        )
    }

    private func jumpToMatch(_ searchString: String) {
        guard !searchString.isEmpty else { return }
        let lowercased = searchString.lowercased()

        if let matchItem = items.first(where: { $0.name.lowercased().hasPrefix(lowercased) }) {
            viewModel.selectItem(matchItem)
            updateQuickLook(for: matchItem)
        }
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
        viewModel.toggleQuickLookForSelection { [self] offset in
            navigateSelection(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        DropHelper.handleDrop(providers: providers, viewModel: viewModel)
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


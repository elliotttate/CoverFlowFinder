import SwiftUI
import AppKit
import Quartz

struct FileListView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var internalDragState = InternalDragState.shared
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
        // The table takes file drops itself; this catches what it doesn't (file promises from
        // Mail, Photos, Safari) and shows the badge of the operation that will happen. Those go into
        // the folder shown, so none while the list shows Spotlight results.
        .onDrop(of: FileListActions.showsSearchResults(viewModel) ? [] : DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
            viewModel: viewModel,
            isDropTargeted: $isDropTargeted,
            containerHeight: 0,
            items: items,
            autoScroll: false
        ))
        .dropTargetOverlay(isTargeted: isDropTargeted && !internalDragState.isDragging)
        .allowsHitTesting(true)
        .onChange(of: viewModel.selectedItems) {
            // Quick Look follows the lead item of the selection (refreshes if visible)
            updateQuickLook(for: viewModel.primarySelectedItem)
        }
        // These closures are registered once and outlive this view value, so they read the
        // view model's current (sorted, filtered) items when called, never the `items` snapshot.
        .keyboardNavigable(
            onUpArrow: { shift in FileListKeyboardNavigation.navigate(viewModel, by: -1, extend: shift) },
            onDownArrow: { shift in FileListKeyboardNavigation.navigate(viewModel, by: 1, extend: shift) },
            onReturn: { openSelectedItems() },
            onSpace: { toggleQuickLook() },
            onDelete: { viewModel.deleteSelectedItems() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste() },
            onTypeAhead: { searchString in FileListKeyboardNavigation.jumpToMatch(viewModel, prefix: searchString) }
        )
    }

    private func openSelectedItems() {
        FileListActions.open(viewModel.orderedSelectedItems, primary: viewModel.primarySelectedItem, viewModel: viewModel)
    }

    private func toggleQuickLook() {
        guard let item = viewModel.primarySelectedItem else { return }
        let viewModel = viewModel
        // Use async version to avoid blocking during archive extraction
        viewModel.previewURL(for: item) { previewURL in
            guard let previewURL else {
                NSSound.beep()
                return
            }
            QuickLookControllerView.shared.togglePreview(for: previewURL) { offset in
                FileListKeyboardNavigation.navigate(viewModel, by: offset, extend: false)
            }
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item)
    }
}

// MARK: - Keyboard Navigation

@MainActor
enum FileListKeyboardNavigation {
    /// ↑/↓ (and ⇧↑/⇧↓) over the view model's current filtered items.
    /// Plain arrows move past the ends of a multi-selection (Finder); ⇧ extends from the anchor.
    static func navigate(_ viewModel: FileBrowserViewModel, by offset: Int, extend: Bool) {
        let items = viewModel.filteredItems
        guard !items.isEmpty else { return }
        let maxIndex = items.count - 1
        let selection = viewModel.selectedItems

        var selectedIndices: [Int] = []
        if selection.count == 1, let only = selection.first, let index = items.firstIndex(of: only) {
            selectedIndices = [index]
        } else if !selection.isEmpty {
            selectedIndices = items.indices.filter { selection.contains(items[$0]) }
        }

        guard let lowest = selectedIndices.first, let highest = selectedIndices.last else {
            // Nothing (visible) selected: start at the end the arrow points to
            let index = offset > 0 ? 0 : maxIndex
            select(index, in: items, viewModel: viewModel)
            return
        }

        if extend {
            var anchor = viewModel.selectionAnchorIndex
            var cursor = viewModel.lastSelectedIndex
            if !items.indices.contains(cursor) || !selection.contains(items[cursor]) {
                // Stale cursor (filter or sort changed): extend from the end in the arrow's direction
                cursor = offset > 0 ? highest : lowest
                anchor = offset > 0 ? lowest : highest
            } else if !items.indices.contains(anchor) {
                anchor = cursor
            }
            let newIndex = max(0, min(maxIndex, cursor + offset))
            guard newIndex != cursor else { return }
            viewModel.selectionAnchorIndex = anchor
            viewModel.selectRange(to: newIndex, in: items)
            return
        }

        let newIndex = offset > 0 ? min(highest + 1, maxIndex) : max(lowest - 1, 0)
        if selectedIndices.count == 1 && newIndex == lowest { return }  // already at the end
        select(newIndex, in: items, viewModel: viewModel)
    }

    /// Type-ahead: selects the first item whose name (as displayed) starts with `prefix`.
    static func jumpToMatch(_ viewModel: FileBrowserViewModel, prefix: String) {
        guard !prefix.isEmpty else { return }
        let items = viewModel.filteredItems
        guard let index = items.firstIndex(where: {
            $0.displayName.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        }) else { return }
        select(index, in: items, viewModel: viewModel)
    }

    private static func select(_ index: Int, in items: [FileItem], viewModel: FileBrowserViewModel) {
        viewModel.selectItem(items[index])
        viewModel.lastSelectedIndex = index
        viewModel.selectionAnchorIndex = index
    }
}

// MARK: - Tags View

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

// MARK: - Cloud Status Badge

/// Displays iCloud sync status as an SF Symbol badge
struct CloudStatusBadgeView: View {
    let status: CloudSyncStatus?
    var size: CGFloat = 14

    var body: some View {
        if let status = status, status.shouldShowBadge {
            Image(systemName: status.systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(status.swiftUIColor)
                .help(status.description)
        }
    }
}

import SwiftUI
import AppKit

// MARK: - Drop Helper
// Shared utilities for drag and drop operations

enum DropHelper {
    /// Determines the drop operation based on modifier keys (Option = copy, otherwise move)
    static var currentDropOperation: DropOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    /// Processes dropped item providers and extracts file URLs
    static func processDroppedItems(
        _ providers: [NSItemProvider],
        completion: @escaping ([URL]) -> Void
    ) {
        var collectedURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: TypeIdentifiers.fileURL, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collectedURLs.append(url)
            }
        }

        group.notify(queue: .main) {
            completion(collectedURLs)
        }
    }

    /// Handles drop for a single provider (legacy compatibility)
    static func handleDrop(
        providers: [NSItemProvider],
        viewModel: FileBrowserViewModel,
        destinationURL: URL? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: TypeIdentifiers.fileURL, options: nil) { data, _ in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    if let destination = destinationURL {
                        viewModel.handleDrop(urls: [sourceURL], to: destination)
                    } else {
                        viewModel.handleDrop(urls: [sourceURL])
                    }
                    onComplete?()
                }
            }
        }
    }
}

// MARK: - Selection Helper
// Shared utilities for selection and keyboard modifier handling

@MainActor
enum SelectionHelper {
    /// Gets current modifier flags for selection handling
    static var currentModifiers: (shift: Bool, command: Bool) {
        let flags = NSEvent.modifierFlags
        return (flags.contains(.shift), flags.contains(.command))
    }

    /// Handles item selection with current modifier keys
    static func handleSelection(
        item: FileItem,
        in items: [FileItem],
        viewModel: FileBrowserViewModel
    ) {
        guard let index = items.firstIndex(of: item) else { return }
        let modifiers = currentModifiers
        viewModel.handleSelection(
            item: item,
            index: index,
            in: items,
            withShift: modifiers.shift,
            withCommand: modifiers.command
        )
    }

    /// Calculates the new selection index when navigating by offset
    static func calculateNewIndex(
        currentItem: FileItem?,
        in items: [FileItem],
        offset: Int
    ) -> Int {
        guard !items.isEmpty else { return 0 }

        let currentIndex: Int
        if let current = currentItem,
           let index = items.firstIndex(of: current) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        return max(0, min(items.count - 1, currentIndex + offset))
    }

    /// Navigates selection by offset and updates QuickLook
    static func navigateSelection(
        by offset: Int,
        in items: [FileItem],
        viewModel: FileBrowserViewModel
    ) {
        guard !items.isEmpty else { return }

        let newIndex = calculateNewIndex(
            currentItem: viewModel.selectedItems.first,
            in: items,
            offset: offset
        )
        let newItem = items[newIndex]
        viewModel.selectItem(newItem)
        viewModel.updateQuickLookPreview(for: newItem)
    }
}

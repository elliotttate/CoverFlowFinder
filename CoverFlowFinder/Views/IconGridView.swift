import SwiftUI
import AppKit
import Quartz

struct IconGridView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @State private var isDropTargeted = false
    @State private var dropTargetedItemID: UUID?
    @State private var currentWidth: CGFloat = 800

    // Thumbnail loading
    @State private var thumbnails: [URL: NSImage] = [:]
    private let thumbnailCache = ThumbnailCacheManager.shared

    private var cellWidth: CGFloat {
        let iconSize = settings.iconGridIconSizeValue
        let labelWidth = iconSize + 20
        let labelPadding: CGFloat = 8
        let outerPadding: CGFloat = 16
        return labelWidth + labelPadding + outerPadding
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: settings.iconGridSpacingValue)]
    }

    // Calculate columns based on current width - called at navigation time
    private var calculatedColumns: Int {
        let availableWidth = max(0, currentWidth - 40) // Subtract padding (20 each side)
        let spacing = settings.iconGridSpacingValue
        let cols = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, cols)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: settings.iconGridSpacingValue) {
                        ForEach(items) { item in
                            IconGridItem(
                                item: item,
                                viewModel: viewModel,
                                isSelected: viewModel.selectedItems.contains(item),
                                thumbnail: thumbnails[item.url]
                            )
                            .id(item.id)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                                    .opacity(dropTargetedItemID == item.id ? 1 : 0)
                            )
                            .onAppear {
                                loadThumbnail(for: item)
                            }
                            .onDrag {
                                guard !item.isFromArchive else { return NSItemProvider() }
                                return NSItemProvider(object: item.url as NSURL)
                            }
                            .onDrop(of: [.fileURL], delegate: IconFolderDropDelegate(
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
                    .padding(20)
                }
                .onAppear {
                    currentWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { newWidth in
                    currentWidth = newWidth
                }
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
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(8)
        )
        .contextMenu {
            Button("New Folder") {
                viewModel.createNewFolder()
            }

            if viewModel.canPaste {
                Divider()
                Button("Paste") {
                    viewModel.paste()
                }
            }

            Divider()

            Button("Refresh") {
                viewModel.refresh()
            }

            Button("Show in Finder") {
                viewModel.showInFinder()
            }
        }
        .onChange(of: items) { _ in
            DispatchQueue.main.async {
                thumbnails.removeAll()
                thumbnailCache.clearForNewFolder()
            }
        }
        .keyboardNavigable(
            onUpArrow: { navigateSelection(by: -calculatedColumns) },
            onDownArrow: { navigateSelection(by: calculatedColumns) },
            onLeftArrow: { navigateSelection(by: -1) },
            onRightArrow: { navigateSelection(by: 1) },
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

struct IconGridItem: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let isSelected: Bool
    let thumbnail: NSImage?

    @State private var isHovering = false

    private var displayImage: NSImage {
        thumbnail ?? item.icon
    }

    var body: some View {
        let iconSize = appSettings.iconGridIconSizeValue
        let backgroundSize = iconSize + 10
        let labelWidth = iconSize + 20

        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .frame(width: backgroundSize, height: backgroundSize)

                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .cornerRadius(4)
            }

            VStack(spacing: 2) {
                InlineRenameField(item: item, viewModel: viewModel, font: appSettings.iconGridFont, alignment: .center, lineLimit: 2)
                    .frame(width: labelWidth)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected && viewModel.renamingURL != item.url ? Color.accentColor : Color.clear)
                    )
                    .foregroundColor(isSelected && viewModel.renamingURL != item.url ? .white : .primary)

                if !item.tags.isEmpty {
                    TagDotsView(tags: item.tags)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering && !isSelected ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
    }
}

// MARK: - Folder Drop Delegate

struct IconFolderDropDelegate: DropDelegate {
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

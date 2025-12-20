import SwiftUI
import AppKit
import Quartz

struct MasonryView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var isDropTargeted = false
    @State private var dropTargetedItemID: UUID?
    @State private var currentWidth: CGFloat = 800

    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var aspectRatios: [URL: CGFloat] = [:]
    private let thumbnailCache = ThumbnailCacheManager.shared
    @State private var pinchStartIconSize: Double?
    @State private var pinchStartSpacing: Double?
    @State private var pinchStartFontSize: Double?
    @State private var targetThumbnailPixelSize: CGFloat = 256

    private var columnSpacing: CGFloat {
        max(12, settings.iconGridSpacingValue * 0.6)
    }

    private var sidePadding: CGFloat {
        16
    }

    private var idealColumnWidth: CGFloat {
        max(180, settings.iconGridIconSizeValue * 2.4)
    }

    private var columnCount: Int {
        let availableWidth = max(0, currentWidth - (sidePadding * 2))
        let count = Int((availableWidth + columnSpacing) / (idealColumnWidth + columnSpacing))
        return max(1, count)
    }

    private var columnWidth: CGFloat {
        let availableWidth = max(0, currentWidth - (sidePadding * 2))
        let totalSpacing = columnSpacing * CGFloat(max(0, columnCount - 1))
        let width = (availableWidth - totalSpacing) / CGFloat(columnCount)
        return max(1, width)
    }

    private var labelHeight: CGFloat {
        max(26, CGFloat(settings.iconGridFontSize) * 2.4)
    }

    private var folderTileHeight: CGFloat {
        max(56, columnWidth * 0.25)
    }

    private var masonryThumbnailPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let target = columnWidth * scale * settings.thumbnailQualityValue
        let bucket = (target / 128).rounded() * 128
        return min(1024, max(256, bucket))
    }

    private func aspectRatio(for item: FileItem) -> CGFloat {
        if let ratio = aspectRatios[item.url] {
            return ratio
        }

        switch item.fileType {
        case .image, .video:
            return 4.0 / 3.0
        default:
            return 1.0
        }
    }

    private func tileHeight(for item: FileItem) -> CGFloat {
        if item.isDirectory {
            return folderTileHeight
        }
        let ratio = aspectRatio(for: item)
        return columnWidth / ratio
    }

    private func estimatedItemHeight(for item: FileItem) -> CGFloat {
        let imageHeight = tileHeight(for: item)
        let tagHeight: CGFloat = settings.showItemTags && !item.tags.isEmpty ? 12 : 0
        let verticalPadding: CGFloat = 12
        return imageHeight + labelHeight + tagHeight + verticalPadding
    }

    private struct MasonryPosition {
        let column: Int
        let indexInColumn: Int
        let y: CGFloat
        let height: CGFloat
    }

    private struct MasonryLayout {
        let columns: [[FileItem]]
        let positions: [UUID: MasonryPosition]
    }

    private var masonryLayout: MasonryLayout {
        guard !items.isEmpty else { return MasonryLayout(columns: [], positions: [:]) }
        var buckets = Array(repeating: [FileItem](), count: columnCount)
        var heights = Array(repeating: CGFloat(0), count: columnCount)
        var positions: [UUID: MasonryPosition] = [:]

        for item in items {
            let targetIndex = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let itemHeight = estimatedItemHeight(for: item)
            let indexInColumn = buckets[targetIndex].count
            let y = heights[targetIndex]

            buckets[targetIndex].append(item)
            positions[item.id] = MasonryPosition(
                column: targetIndex,
                indexInColumn: indexInColumn,
                y: y,
                height: itemHeight
            )
            heights[targetIndex] += itemHeight + columnSpacing
        }

        return MasonryLayout(columns: buckets, positions: positions)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = masonryLayout
            ScrollViewReader { scrollProxy in
                ScrollView {
                    HStack(alignment: .top, spacing: columnSpacing) {
                        ForEach(layout.columns.indices, id: \.self) { columnIndex in
                            LazyVStack(spacing: columnSpacing) {
                                ForEach(layout.columns[columnIndex]) { item in
                                    let imageHeight = tileHeight(for: item)

                                    MasonryItemView(
                                        item: item,
                                        viewModel: viewModel,
                                        thumbnail: thumbnails[item.url],
                                        columnWidth: columnWidth,
                                        imageHeight: imageHeight,
                                        labelHeight: labelHeight,
                                        dropTargetedItemID: $dropTargetedItemID,
                                        onSelect: { selectItem($0) }
                                    )
                                    .id(item.id)
                                    .onAppear {
                                        loadThumbnail(for: item)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, sidePadding)
                    .padding(.vertical, sidePadding)
                }
                .onAppear {
                    currentWidth = geometry.size.width
                    refreshThumbnailTargetSize()
                }
                .onChange(of: geometry.size.width) { newWidth in
                    currentWidth = newWidth
                    refreshThumbnailTargetSize()
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
                .padding(6)
        )
        .onChange(of: items) { _ in
            DispatchQueue.main.async {
                thumbnails.removeAll()
                aspectRatios.removeAll()
                thumbnailCache.clearForNewFolder()
            }
        }
        .onChange(of: settings.iconGridIconSize) { _ in
            refreshThumbnailTargetSize()
        }
        .onChange(of: settings.iconGridSpacing) { _ in
            refreshThumbnailTargetSize()
        }
        .onChange(of: settings.thumbnailQuality) { _ in
            refreshThumbnailTargetSize()
        }
        .keyboardNavigable(
            onUpArrow: { navigateVertical(-1) },
            onDownArrow: { navigateVertical(1) },
            onLeftArrow: { navigateHorizontal(-1) },
            onRightArrow: { navigateHorizontal(1) },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() }
        )
        .simultaneousGesture(magnificationGesture)
    }

    private func selectItem(_ item: FileItem) {
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
    }

    private func navigateLinear(by offset: Int) {
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
        updateQuickLook(for: newItem)
    }

    private func navigateVertical(_ direction: Int) {
        guard let currentItem = ensureSelection() else { return }
        let layout = masonryLayout
        guard let position = layout.positions[currentItem.id] else { return }

        let columnItems = layout.columns[position.column]
        let nextIndex = position.indexInColumn + direction
        guard columnItems.indices.contains(nextIndex) else { return }

        selectItem(columnItems[nextIndex])
    }

    private func navigateHorizontal(_ direction: Int) {
        guard let currentItem = ensureSelection() else { return }
        let layout = masonryLayout
        guard let position = layout.positions[currentItem.id] else { return }

        let targetColumn = position.column + direction
        guard layout.columns.indices.contains(targetColumn) else { return }

        let targetItems = layout.columns[targetColumn]
        guard !targetItems.isEmpty else { return }

        let currentCenter = position.y + (position.height / 2)
        var closestItem = targetItems[0]
        var closestDelta = CGFloat.greatestFiniteMagnitude

        for item in targetItems {
            guard let targetPosition = layout.positions[item.id] else { continue }
            let targetCenter = targetPosition.y + (targetPosition.height / 2)
            let delta = abs(targetCenter - currentCenter)
            if delta < closestDelta {
                closestDelta = delta
                closestItem = item
            }
        }

        selectItem(closestItem)
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
            navigateLinear(by: offset)
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

    private func refreshThumbnailTargetSize() {
        let newSize = masonryThumbnailPixelSize
        guard abs(newSize - targetThumbnailPixelSize) >= 8 else { return }
        targetThumbnailPixelSize = newSize
        DispatchQueue.main.async {
            for item in items {
                loadThumbnail(for: item)
            }
        }
    }

    @discardableResult
    private func ensureSelection() -> FileItem? {
        if let current = viewModel.selectedItems.first {
            return current
        }

        guard let first = items.first else { return nil }
        viewModel.selectItem(first)
        updateQuickLook(for: first)
        return first
    }

    private func loadThumbnail(for item: FileItem) {
        let url = item.url
        let targetPixelSize = targetThumbnailPixelSize

        if let existing = thumbnails[url], imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
            return
        }
        if thumbnailCache.isPending(url: url, maxPixelSize: targetPixelSize) { return }

        if thumbnailCache.hasFailed(url: url) {
            DispatchQueue.main.async {
                thumbnails[url] = item.icon
            }
            return
        }

        if let cached = thumbnailCache.getCachedThumbnail(for: url, maxPixelSize: targetPixelSize) {
            DispatchQueue.main.async {
                thumbnails[url] = cached
                updateAspectRatio(for: item, image: cached)
            }
            return
        }

        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { url, image in
            DispatchQueue.main.async {
                if let image = image {
                    thumbnails[url] = image
                    updateAspectRatio(for: item, image: image)
                } else {
                    thumbnails[url] = item.icon
                }
            }
        }
    }

    private func updateAspectRatio(for item: FileItem, image: NSImage) {
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return }
        let ratio = size.width / size.height
        let clamped = min(max(ratio, 0.6), 2.4)
        aspectRatios[item.url] = clamped
    }

    private func imageSatisfiesMinimum(_ image: NSImage, minPixelSize: CGFloat) -> Bool {
        let maxDimension = max(image.size.width, image.size.height)
        return maxDimension >= minPixelSize * 0.9
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

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartIconSize == nil {
                    pinchStartIconSize = settings.iconGridIconSize
                    pinchStartSpacing = settings.iconGridSpacing
                    pinchStartFontSize = settings.iconGridFontSize
                }

                let baseIcon = pinchStartIconSize ?? settings.iconGridIconSize
                let baseSpacing = pinchStartSpacing ?? settings.iconGridSpacing
                let baseFont = pinchStartFontSize ?? settings.iconGridFontSize

                settings.iconGridIconSize = clamp(baseIcon * Double(value), range: 48...160)
                settings.iconGridSpacing = clamp(baseSpacing * Double(value), range: 12...40)
                settings.iconGridFontSize = clamp(baseFont * Double(value), range: 9...16)
            }
            .onEnded { _ in
                pinchStartIconSize = nil
                pinchStartSpacing = nil
                pinchStartFontSize = nil
            }
    }

    private func clamp(_ value: Double, range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct MasonryItemView: View {
    @EnvironmentObject private var settings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let thumbnail: NSImage?
    let columnWidth: CGFloat
    let imageHeight: CGFloat
    let labelHeight: CGFloat
    @Binding var dropTargetedItemID: UUID?
    let onSelect: (FileItem) -> Void

    private var isSelected: Bool {
        viewModel.selectedItems.contains(item)
    }

    var body: some View {
        let labelPadding: CGFloat = 6
        let usesPreview = thumbnail != nil && !item.isDirectory
        let displayImage = thumbnail ?? item.icon
        let iconSize = min(columnWidth * 0.5, imageHeight * 0.8)

        VStack(alignment: .center, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))

                if usesPreview {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: columnWidth, height: imageHeight)
                        .clipped()
                } else {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundColor(.primary)
                }
            }
            .frame(width: columnWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .opacity(dropTargetedItemID == item.id ? 1 : 0)
            )

            InlineRenameField(
                item: item,
                viewModel: viewModel,
                font: settings.iconGridFont,
                alignment: .center,
                lineLimit: 2
            )
            .frame(width: columnWidth - (labelPadding * 2), height: labelHeight, alignment: .center)
            .padding(.horizontal, labelPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected && viewModel.renamingURL != item.url ? Color.accentColor.opacity(0.9) : Color.clear)
            )
            .foregroundColor(isSelected && viewModel.renamingURL != item.url ? .white : .primary)

            if settings.showItemTags, !item.tags.isEmpty {
                TagDotsView(tags: item.tags)
                    .frame(width: columnWidth, alignment: .center)
            }
        }
        .frame(width: columnWidth)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .contentShape(Rectangle())
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
        .onDrag {
            guard !item.isFromArchive else { return NSItemProvider() }
            return NSItemProvider(object: item.url as NSURL)
        }
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(
            item: item,
            viewModel: viewModel,
            dropTargetedItemID: $dropTargetedItemID
        ))
        .instantTap(
            id: item.id,
            onSingleClick: {
                onSelect(item)
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

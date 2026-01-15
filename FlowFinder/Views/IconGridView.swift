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
    @State private var pinchStartIconSize: Double?
    @State private var pinchStartSpacing: Double?
    @State private var pinchStartFontSize: Double?

    // Thumbnail loading
    @State private var thumbnails: [URL: NSImage] = [:]
    private let thumbnailCache = ThumbnailCacheManager.shared
    @State private var itemsToken: Int = 0
    @State private var visibleItemIDs: Set<UUID> = []
    @State private var hydrationWorkItem: DispatchWorkItem?
    @State private var lastHydratedRange: Range<Int>?

    private var cellWidth: CGFloat {
        let iconSize = settings.iconGridIconSizeValue
        let labelWidth = iconSize + 20
        let labelPadding: CGFloat = 8
        let outerPadding: CGFloat = 16
        return labelWidth + labelPadding + outerPadding
    }

    // Calculate columns based on current width - used for both grid layout and navigation
    private var columnCount: Int {
        let availableWidth = max(0, currentWidth - 40) // Subtract padding (20 each side)
        let spacing = settings.iconGridSpacingValue
        let cols = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, cols)
    }

    private var columns: [GridItem] {
        // Use explicit column count to ensure navigation matches layout
        Array(repeating: GridItem(.flexible(), spacing: settings.iconGridSpacingValue), count: columnCount)
    }

    private var iconGridThumbnailPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let baseTarget = max(256, settings.iconGridIconSizeValue * scale)
        let target = baseTarget * settings.thumbnailQualityValue
        let bucket = (target / 64).rounded() * 64
        return min(768, max(96, bucket))
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
                                updateVisibility(for: item, isVisible: true)
                            }
                            .onDisappear {
                                updateVisibility(for: item, isVisible: false)
                            }
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
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onAppear {
                    currentWidth = geometry.size.width
                    // Scroll to selected item when view appears (e.g., when switching view modes)
                    if let firstSelected = viewModel.selectedItems.first {
                        // Use DispatchQueue to ensure layout is complete before scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo(firstSelected.id, anchor: .center)
                        }
                    }
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
        .featheredTopBlur(height: 50)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .dropTargetOverlay(isTargeted: isDropTargeted, padding: UI.Spacing.standard)
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
        .onChange(of: items) { newItems in
            let oldToken = itemsToken
            let newToken = itemsTokenFor(newItems)

            // Only clear thumbnails if items actually changed
            if oldToken != newToken {
                DispatchQueue.main.async {
                    itemsToken = newToken
                    thumbnails.removeAll()
                    thumbnailCache.clearForNewFolder()
                    visibleItemIDs.removeAll()
                    lastHydratedRange = nil
                    hydrationWorkItem?.cancel()
                    hydrationWorkItem = nil
                }
            }
        }
        .onChange(of: settings.thumbnailQuality) { _ in
            refreshThumbnails()
        }
        .onChange(of: settings.iconGridIconSize) { _ in
            refreshThumbnails()
        }
        .keyboardNavigable(
            onUpArrow: { navigateSelection(by: -columnCount) },
            onDownArrow: { navigateSelection(by: columnCount) },
            onLeftArrow: { navigateSelection(by: -1) },
            onRightArrow: { navigateSelection(by: 1) },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() },
            onDelete: { viewModel.deleteSelectedItems() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste() },
            onTypeAhead: { searchString in jumpToMatch(searchString) }
        )
        .simultaneousGesture(magnificationGesture)
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

    private func jumpToMatch(_ searchString: String) {
        guard !searchString.isEmpty else { return }
        let lowercased = searchString.lowercased()

        // Find the first item that starts with the typed string
        if let matchItem = items.first(where: { $0.name.lowercased().hasPrefix(lowercased) }) {
            viewModel.selectItem(matchItem)
            updateQuickLook(for: matchItem)
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

    private func updateVisibility(for item: FileItem, isVisible: Bool) {
        if isVisible {
            visibleItemIDs.insert(item.id)
        } else {
            visibleItemIDs.remove(item.id)
        }
        markScrolling()
        scheduleHydration()
    }

    @State private var isScrolling = false
    @State private var scrollEndTimer: Timer?

    private func markScrolling() {
        isScrolling = true
        scrollEndTimer?.invalidate()
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [self] _ in
            DispatchQueue.main.async {
                isScrolling = false
                scheduleHydration()
            }
        }
    }

    private func scheduleHydration() {
        hydrationWorkItem?.cancel()
        let debounceTime: TimeInterval = isScrolling ? 0.1 : 0.02
        let itemsSnapshot = items
        let visibleSnapshot = visibleItemIDs
        let currentColumnCount = columnCount
        let scrolling = isScrolling

        let workItem = DispatchWorkItem { [itemsSnapshot, visibleSnapshot, currentColumnCount, scrolling] in
            guard !visibleSnapshot.isEmpty else { return }
            let visibleIndices = itemsSnapshot.enumerated().compactMap { index, item in
                visibleSnapshot.contains(item.id) ? index : nil
            }
            guard let minIndex = visibleIndices.min(),
                  let maxIndex = visibleIndices.max() else { return }

            // Use larger buffer when not scrolling
            let buffer: Int
            if scrolling {
                buffer = max(12, currentColumnCount * 3)
            } else {
                let visibleCount = maxIndex - minIndex + 1
                buffer = max(80, visibleCount * 4)
            }

            let start = max(0, minIndex - buffer)
            let end = min(itemsSnapshot.count - 1, maxIndex + buffer)
            let range = start..<(end + 1)

            DispatchQueue.main.async {
                if range == self.lastHydratedRange && scrolling { return }
                self.lastHydratedRange = range

                var urlsToHydrate: [URL] = []
                urlsToHydrate.reserveCapacity(range.count)
                for index in range {
                    let item = itemsSnapshot[index]
                    if self.viewModel.needsHydration(item) {
                        urlsToHydrate.append(item.url)
                    }
                }
                if !urlsToHydrate.isEmpty {
                    self.viewModel.hydrateMetadata(for: urlsToHydrate)
                }

                // Load thumbnails with batching
                let maxLoadsPerPass = scrolling ? 8 : 48
                var loadCount = 0
                var hasMoreToLoad = false

                for index in range {
                    let item = itemsSnapshot[index]
                    guard !item.isDirectory else { continue }
                    if self.thumbnails[item.url] == nil {
                        if loadCount < maxLoadsPerPass {
                            self.loadThumbnail(for: item)
                            loadCount += 1
                        } else {
                            hasMoreToLoad = true
                        }
                    }
                }

                // Continue loading if not scrolling
                if hasMoreToLoad && !self.isScrolling {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.lastHydratedRange = nil
                        self.scheduleHydration()
                    }
                }
            }
        }
        hydrationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceTime, execute: workItem)
    }

    private func loadThumbnail(for item: FileItem) {
        let url = item.url
        let targetPixelSize = iconGridThumbnailPixelSize

        // Already loaded or loading
        if let existing = thumbnails[url],
           imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
            return
        }
        if thumbnailCache.isPending(url: url, maxPixelSize: targetPixelSize) { return }
        if thumbnailCache.hasFailed(url: url) {
            // Defer state change to avoid publishing during view update
            DispatchQueue.main.async {
                thumbnails[url] = item.icon
            }
            return
        }

        // Check cache first
        if let cached = thumbnailCache.getCachedThumbnail(for: url, maxPixelSize: targetPixelSize) {
            DispatchQueue.main.async {
                thumbnails[url] = cached
            }
            return
        }

        // Generate thumbnail
        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { url, image in
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
        DropHelper.handleDrop(providers: providers, viewModel: viewModel)
    }

    private func refreshThumbnails() {
        let targetPixelSize = iconGridThumbnailPixelSize
        DispatchQueue.main.async {
            for item in items {
                if let existing = thumbnails[item.url],
                   imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
                    continue
                }
                loadThumbnail(for: item)
            }
        }
    }

    private func imageSatisfiesMinimum(_ image: NSImage, minPixelSize: CGFloat) -> Bool {
        let maxDimension = max(image.size.width, image.size.height)
        return maxDimension >= minPixelSize * 0.9
    }

    private func itemsTokenFor(_ items: [FileItem]) -> Int {
        // Use a simple count + set of URL paths for stable comparison
        // This ignores order changes which happen frequently during sorting
        var hasher = Hasher()
        hasher.combine(items.count)
        // Sort URLs to make hash order-independent
        let sortedPaths = items.map { $0.url.path }.sorted()
        for path in sortedPaths {
            hasher.combine(path)
        }
        return hasher.finalize()
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


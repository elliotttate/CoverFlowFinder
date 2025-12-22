import SwiftUI
import AppKit
import Photos
import Quartz
import os.log

private let masonryLog = OSLog(subsystem: "com.flowfinder", category: "MasonryLayout")

struct MasonryView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var isDropTargeted = false
    @State private var dropTargetedItemID: UUID?
    @State private var currentWidth: CGFloat = 800

    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var aspectRatios: [URL: CGFloat] = [:]
    @State private var dimensionsFetched: Set<URL> = []  // Track which URLs we've fetched dimensions for
    private let thumbnailCache = ThumbnailCacheManager.shared
    @State private var itemsToken: Int = 0
    @State private var pinchStartIconSize: Double?
    @State private var pinchStartSpacing: Double?
    @State private var pinchStartFontSize: Double?
    @State private var targetThumbnailPixelSize: CGFloat = 256

    // Scroll optimization - defer thumbnail loading during scroll
    @State private var visibleItemIDs: Set<UUID> = []
    @State private var hydrationWorkItem: DispatchWorkItem?
    @State private var lastHydratedRange: Range<Int>?
    @State private var isScrolling = false
    @State private var scrollEndTimer: Timer?
    @State private var needsScrollToSelection = true  // Scroll to selected item when view appears

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

    private var baseLabelHeight: CGFloat {
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
        let name = item.name

        // First check our cached aspect ratios (from thumbnails)
        if let ratio = aspectRatios[item.url] {
            os_log(.debug, log: masonryLog, "aspectRatio [%{public}@]: using THUMBNAIL ratio %.3f", name, ratio)
            return ratio
        }

        // Then check the fast dimensions cache (from file metadata)
        if let dimensions = thumbnailCache.getImageDimensions(for: item.url),
           dimensions.width > 0, dimensions.height > 0 {
            let ratio = dimensions.width / dimensions.height
            let clamped = min(max(ratio, 0.4), 2.5)
            os_log(.debug, log: masonryLog, "aspectRatio [%{public}@]: using DIMENSIONS cache %.0fx%.0f -> ratio %.3f", name, dimensions.width, dimensions.height, clamped)
            return clamped
        }

        // Fallback to defaults
        switch item.fileType {
        case .image, .video:
            os_log(.debug, log: masonryLog, "aspectRatio [%{public}@]: using DEFAULT 4:3 (no cache)", name)
            return 4.0 / 3.0
        default:
            os_log(.debug, log: masonryLog, "aspectRatio [%{public}@]: using DEFAULT 1:1 (non-image)", name)
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
        return imageHeight + labelHeight(for: item) + tagHeight + verticalPadding
    }

    private func labelHeight(for item: FileItem) -> CGFloat {
        // Always show labels for folders, non-media files (show icon only), when filenames setting is on, or when renaming
        shouldShowLabel(for: item) ? baseLabelHeight : 0
    }

    private func shouldShowLabel(for item: FileItem) -> Bool {
        // Always show for folders
        if item.isDirectory { return true }
        // Always show when setting is enabled
        if settings.masonryShowFilenames { return true }
        // Always show when renaming
        if viewModel.renamingURL == item.url { return true }
        // Always show for non-media files (they only show icons, not thumbnails)
        if item.fileType != .image && item.fileType != .video { return true }
        return false
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

    // CACHED LAYOUT - calculated once when items/dimensions change, not on every frame
    @State private var cachedLayout: MasonryLayout?
    @State private var cachedColumnCount: Int = 0
    @State private var cachedColumnWidth: CGFloat = 0
    @State private var layoutNeedsUpdate: Bool = true

    /// Returns cached layout - only returns valid layout after dimensions are fetched
    private var masonryLayout: MasonryLayout {
        // Return cached layout if still valid for current column configuration
        if let cached = cachedLayout,
           cachedColumnCount == columnCount,
           abs(cachedColumnWidth - columnWidth) < 1 {
            return cached
        }

        // If we have a cached layout but column config changed, recalculate
        if cachedLayout != nil {
            return calculateLayout()
        }

        // No cached layout yet - waiting for dimensions to be prefetched
        // Return empty layout to avoid premature calculation
        return MasonryLayout(columns: [], positions: [:])
    }

    /// Calculate layout synchronously - called from computed property
    private func calculateLayout() -> MasonryLayout {
        guard !items.isEmpty else {
            return MasonryLayout(columns: [], positions: [:])
        }

        let currentColumnCount = columnCount
        let currentColumnWidth = columnWidth

        // SIMPLE DETERMINISTIC assignment: index % columnCount
        var buckets = Array(repeating: [FileItem](), count: currentColumnCount)

        for (index, item) in items.enumerated() {
            let columnIndex = index % currentColumnCount
            buckets[columnIndex].append(item)
        }

        // Calculate positions - use FIXED default heights
        var positions: [UUID: MasonryPosition] = [:]
        var columnHeights = Array(repeating: CGFloat(0), count: currentColumnCount)

        for columnIndex in 0..<currentColumnCount {
            for (indexInColumn, item) in buckets[columnIndex].enumerated() {
                let itemHeight = stableItemHeight(for: item)
                let y = columnHeights[columnIndex]

                positions[item.id] = MasonryPosition(
                    column: columnIndex,
                    indexInColumn: indexInColumn,
                    y: y,
                    height: itemHeight
                )
                columnHeights[columnIndex] += itemHeight + columnSpacing
            }
        }

        return MasonryLayout(columns: buckets, positions: positions)
    }

    /// Recalculate and cache the layout - called when items or dimensions change
    private func recalculateLayout() {
        let layout = calculateLayout()
        cachedLayout = layout
        cachedColumnCount = columnCount
        cachedColumnWidth = columnWidth
        layoutNeedsUpdate = false
    }

    /// Returns height for an item using CACHED dimensions (real aspect ratio)
    /// Falls back to 4:3 if dimensions not yet cached
    /// Layout is only calculated once per folder, so this is stable
    private func stableItemHeight(for item: FileItem) -> CGFloat {
        if item.isDirectory {
            return folderTileHeight + labelHeight(for: item) + 12
        }

        // Use cached dimensions for real aspect ratio
        let ratio: CGFloat
        if let dimensions = thumbnailCache.getImageDimensions(for: item.url),
           dimensions.width > 0, dimensions.height > 0 {
            ratio = min(max(dimensions.width / dimensions.height, 0.4), 2.5)
        } else {
            // Fallback for items without dimensions yet
            ratio = 4.0 / 3.0
        }

        let imageHeight = columnWidth / ratio
        let tagHeight: CGFloat = settings.showItemTags && !item.tags.isEmpty ? 12 : 0
        return imageHeight + labelHeight(for: item) + tagHeight + 12
    }

    /// Initial height estimate using default aspect ratios - used for column assignment only
    private func initialEstimatedHeight(for item: FileItem) -> CGFloat {
        if item.isDirectory {
            return folderTileHeight
        }
        // Use default 4:3 for images/videos, 1:1 for others - ensures stable column assignment
        let defaultRatio: CGFloat
        switch item.fileType {
        case .image, .video:
            defaultRatio = 4.0 / 3.0
        default:
            defaultRatio = 1.0
        }
        let imageHeight = columnWidth / defaultRatio
        let tagHeight: CGFloat = settings.showItemTags && !item.tags.isEmpty ? 12 : 0
        let verticalPadding: CGFloat = 12
        return imageHeight + labelHeight(for: item) + tagHeight + verticalPadding
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
                                    // Use CACHED height from layout positions - never recalculate during scroll
                                    let cachedHeight = layout.positions[item.id]?.height ?? stableItemHeight(for: item)
                                    // Extract just the image portion (subtract label and padding)
                                    let tagHeight: CGFloat = settings.showItemTags && !item.tags.isEmpty ? 12 : 0
                                    let imageHeight = cachedHeight - labelHeight(for: item) - tagHeight - 12

                                    MasonryItemView(
                                        item: item,
                                        viewModel: viewModel,
                                        thumbnail: thumbnails[item.url],
                                        columnWidth: columnWidth,
                                        imageHeight: imageHeight,
                                        labelHeight: labelHeight(for: item),
                                        showLabels: shouldShowLabel(for: item),
                                        dropTargetedItemID: $dropTargetedItemID,
                                        onSelect: { selectItem($0) }
                                    )
                                    .id(item.id)
                                    .onAppear {
                                        updateVisibility(for: item, isVisible: true)
                                    }
                                    .onDisappear {
                                        updateVisibility(for: item, isVisible: false)
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
                    layoutNeedsUpdate = true
                    recalculateLayout()
                    // Scroll to selected item when view appears (e.g., when switching view modes)
                    if let firstSelected = viewModel.selectedItems.first {
                        // Use DispatchQueue to ensure layout is complete before scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo(firstSelected.id, anchor: .center)
                        }
                    }
                    needsScrollToSelection = true
                }
                .onChange(of: geometry.size.width) { newWidth in
                    currentWidth = newWidth
                    refreshThumbnailTargetSize()
                    // Recalculate layout when window width changes
                    layoutNeedsUpdate = true
                    recalculateLayout()
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
                .onChange(of: cachedLayout != nil) { hasLayout in
                    // Scroll to selected item when layout first becomes available
                    if hasLayout && needsScrollToSelection {
                        needsScrollToSelection = false
                        if let firstSelected = viewModel.selectedItems.first {
                            // Small delay to ensure layout is applied
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollProxy.scrollTo(firstSelected.id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .dropTargetOverlay(isTargeted: isDropTargeted, padding: UI.Spacing.medium)
        .onChange(of: items) { newItems in
            let oldToken = itemsToken
            let newToken = itemsTokenFor(newItems)

            os_log(.info, log: masonryLog, "onChange(items): count=%d, oldToken=%d, newToken=%d", newItems.count, oldToken, newToken)

            // Only clear thumbnails if items actually changed
            if oldToken != newToken {
                os_log(.info, log: masonryLog, "  -> ITEMS CHANGED, clearing all caches")
                itemsToken = newToken
                thumbnails.removeAll()
                aspectRatios.removeAll()
                dimensionsFetched.removeAll()
                cachedLayout = nil  // Clear cached layout
                thumbnailCache.clearForNewFolder()
                thumbnailCache.clearDimensionsCache()
                visibleItemIDs.removeAll()
                lastHydratedRange = nil
                hydrationWorkItem?.cancel()
                hydrationWorkItem = nil

                // Get list of media files that need dimensions
                let mediaURLs = newItems.compactMap { item -> URL? in
                    guard !item.isDirectory && (item.fileType == .image || item.fileType == .video) else { return nil }
                    return item.url
                }

                // IMPORTANT: Prefetch dimensions FIRST, then calculate layout
                // This ensures we have real aspect ratios for the initial layout
                // Layout is calculated ONCE and cached - never recalculated during scroll
                if !mediaURLs.isEmpty {
                    os_log(.info, log: masonryLog, "  -> PREFETCHING dimensions for %d media files BEFORE layout", mediaURLs.count)
                    thumbnailCache.prefetchImageDimensions(for: mediaURLs) { [self] results in
                        os_log(.info, log: masonryLog, "  -> PREFETCH complete: got %d dimensions, NOW calculating layout", results.count)
                        // Calculate layout ONCE with real aspect ratios
                        layoutNeedsUpdate = true
                        recalculateLayout()
                    }
                } else {
                    // No media files, calculate layout immediately
                    layoutNeedsUpdate = true
                    recalculateLayout()
                }
            } else {
                os_log(.debug, log: masonryLog, "  -> token unchanged, keeping caches")
            }
        }
        .onChange(of: settings.iconGridIconSize) { _ in
            refreshThumbnailTargetSize()
            layoutNeedsUpdate = true
            recalculateLayout()
        }
        .onChange(of: settings.iconGridSpacing) { _ in
            refreshThumbnailTargetSize()
            layoutNeedsUpdate = true
            recalculateLayout()
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
            onSpace: { toggleQuickLook() },
            onDelete: { viewModel.deleteSelectedItems() },
            onCopy: { viewModel.copySelectedItems() },
            onCut: { viewModel.cutSelectedItems() },
            onPaste: { viewModel.paste() },
            onTypeAhead: { searchString in jumpToMatch(searchString) }
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

    private func jumpToMatch(_ searchString: String) {
        guard !searchString.isEmpty else { return }
        let lowercased = searchString.lowercased()

        // Find the first item that starts with the typed string
        if let matchItem = items.first(where: { $0.name.lowercased().hasPrefix(lowercased) }) {
            selectItem(matchItem)
        }
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection { [self] offset in
            navigateLinear(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item)
    }

    private func refreshThumbnailTargetSize() {
        let newSize = masonryThumbnailPixelSize
        guard abs(newSize - targetThumbnailPixelSize) >= 8 else { return }
        targetThumbnailPixelSize = newSize
        // Reset hydration range to force reload of visible items at new size
        lastHydratedRange = nil
        scheduleHydration()
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

    // MARK: - Scroll-Optimized Loading

    private func updateVisibility(for item: FileItem, isVisible: Bool) {
        let wasEmpty = visibleItemIDs.isEmpty
        if isVisible {
            visibleItemIDs.insert(item.id)
        } else {
            visibleItemIDs.remove(item.id)
        }

        if wasEmpty && !visibleItemIDs.isEmpty {
            os_log(.info, log: masonryLog, "VISIBILITY: first item appeared [%{public}@]", item.name)
        }

        markScrolling()
        scheduleHydration()
    }

    private func markScrolling() {
        let wasScrolling = isScrolling
        isScrolling = true
        scrollEndTimer?.invalidate()

        if !wasScrolling {
            os_log(.info, log: masonryLog, "SCROLL: started")
        }

        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [self] _ in
            DispatchQueue.main.async {
                os_log(.info, log: masonryLog, "SCROLL: ended, visible=%d items", visibleItemIDs.count)
                isScrolling = false
                // Trigger a final hydration pass when scroll stops
                scheduleHydration()
            }
        }
    }

    private func scheduleHydration() {
        hydrationWorkItem?.cancel()

        // During active scrolling, use longer debounce to reduce work
        let debounceTime: TimeInterval = isScrolling ? 0.1 : 0.02

        let itemsSnapshot = items
        let visibleSnapshot = visibleItemIDs
        let currentColumnCount = columnCount
        let scrolling = isScrolling
        let fetchedDimensions = dimensionsFetched

        let workItem = DispatchWorkItem { [itemsSnapshot, visibleSnapshot, currentColumnCount, scrolling, fetchedDimensions] in
            guard !visibleSnapshot.isEmpty else { return }

            // Find visible indices
            let visibleIndices = itemsSnapshot.enumerated().compactMap { index, item in
                visibleSnapshot.contains(item.id) ? index : nil
            }
            guard let minIndex = visibleIndices.min(),
                  let maxIndex = visibleIndices.max() else { return }

            // Use larger buffer when not scrolling for better preloading
            // During scroll: small buffer to prioritize visible items
            // When stopped: large buffer to preload ahead
            let buffer: Int
            if scrolling {
                buffer = max(12, currentColumnCount * 3)
            } else {
                // Preload 8 screens worth when stopped
                let visibleCount = maxIndex - minIndex + 1
                buffer = max(80, visibleCount * 4)
            }

            let start = max(0, minIndex - buffer)
            let end = min(itemsSnapshot.count - 1, maxIndex + buffer)
            let range = start..<(end + 1)

            DispatchQueue.main.async {
                // Skip if we already hydrated this exact range while scrolling
                if range == self.lastHydratedRange && scrolling { return }
                self.lastHydratedRange = range

                // Hydrate metadata for items in range
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

                // FIRST: Prefetch image/video dimensions for stable layout
                // This is very fast (just reads file headers) and prevents layout shifts
                var urlsNeedingDimensions: [URL] = []
                for index in range {
                    let item = itemsSnapshot[index]
                    if !item.isDirectory && (item.fileType == .image || item.fileType == .video) && !fetchedDimensions.contains(item.url) {
                        urlsNeedingDimensions.append(item.url)
                    }
                }

                if !urlsNeedingDimensions.isEmpty {
                    os_log(.info, log: masonryLog, "PREFETCH dimensions for %d images (range %d-%d)", urlsNeedingDimensions.count, start, end)

                    // Mark as fetched immediately to avoid duplicate requests
                    for url in urlsNeedingDimensions {
                        self.dimensionsFetched.insert(url)
                    }

                    // Prefetch dimensions (very fast, runs on background thread)
                    self.thumbnailCache.prefetchImageDimensions(for: urlsNeedingDimensions) { results in
                        os_log(.info, log: masonryLog, "PREFETCH complete: got %d dimensions", results.count)
                        // Dimensions are now cached - no need to store them here
                        // Just trigger a layout refresh if we're not scrolling
                        if !self.isScrolling {
                            // Force view update by touching a state variable
                            // The aspectRatio function will now find the cached dimensions
                        }
                    }
                }

                // THEN: Load thumbnails
                // During scroll: limit to avoid blocking UI
                // When stopped: load all items in range, batched for responsiveness
                let maxLoadsPerPass = scrolling ? 8 : 48
                var loadCount = 0
                var hasMoreToLoad = false

                for index in range {
                    let item = itemsSnapshot[index]
                    if self.thumbnails[item.url] == nil && !item.isDirectory {
                        if loadCount < maxLoadsPerPass {
                            self.loadThumbnail(for: item)
                            loadCount += 1
                        } else {
                            hasMoreToLoad = true
                        }
                    }
                }

                // If not scrolling and there are more items to load, schedule another pass
                if hasMoreToLoad && !self.isScrolling {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        // Clear lastHydratedRange to allow another pass
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
        let targetPixelSize = targetThumbnailPixelSize

        // For folders, always use the file system icon (preserves custom folder colors)
        // QuickLook returns a generic blue folder icon which loses custom colors
        if item.isDirectory {
            if thumbnails[url] == nil {
                thumbnails[url] = item.icon
            }
            return
        }

        if viewModel.isPhotosItem(item) {
            loadPhotosThumbnail(for: item, targetPixelSize: targetPixelSize)
            return
        }

        if let existing = thumbnails[url], imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
            os_log(.debug, log: masonryLog, "loadThumbnail [%{public}@]: already have adequate thumbnail", item.name)
            return
        }
        if thumbnailCache.isPending(url: url, maxPixelSize: targetPixelSize) {
            os_log(.debug, log: masonryLog, "loadThumbnail [%{public}@]: already pending", item.name)
            return
        }

        if thumbnailCache.hasFailed(url: url) {
            os_log(.debug, log: masonryLog, "loadThumbnail [%{public}@]: previously failed, using icon", item.name)
            DispatchQueue.main.async {
                thumbnails[url] = item.icon
            }
            return
        }

        if let cached = thumbnailCache.getCachedThumbnail(for: url, maxPixelSize: targetPixelSize) {
            os_log(.debug, log: masonryLog, "loadThumbnail [%{public}@]: found in cache", item.name)
            DispatchQueue.main.async {
                thumbnails[url] = cached
                // NOTE: Do NOT update aspect ratio here - it causes layout shift!
                // We rely on the dimension cache (getImageDimensions) for stable layout
            }
            return
        }

        os_log(.info, log: masonryLog, "loadThumbnail [%{public}@]: GENERATING new thumbnail", item.name)
        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { url, image in
            DispatchQueue.main.async {
                if let image = image {
                    os_log(.debug, log: masonryLog, "loadThumbnail [%{public}@]: generated %.0fx%.0f", item.name, image.size.width, image.size.height)
                    thumbnails[url] = image
                    // NOTE: Do NOT update aspect ratio here - it causes layout shift!
                    // We rely on the dimension cache (getImageDimensions) for stable layout
                } else {
                    os_log(.debug, log: masonryLog, "loadThumbnail [%{public}@]: generation failed, using icon", item.name)
                    thumbnails[url] = item.icon
                }
            }
        }
    }

    private func loadPhotosThumbnail(for item: FileItem, targetPixelSize: CGFloat) {
        let url = item.url

        if let existing = thumbnails[url], imageSatisfiesMinimum(existing, minPixelSize: targetPixelSize) {
            return
        }

        viewModel.requestPhotoThumbnail(for: item, targetPixelSize: targetPixelSize) { image, ratio in
            if let image {
                thumbnails[url] = image
            } else {
                thumbnails[url] = item.icon
            }
            // NOTE: For Photos items, we DO use the ratio since we can't read dimensions from URL
            // But only set it if we don't already have one (to avoid shifts)
            if let ratio, aspectRatios[url] == nil {
                aspectRatios[url] = ratio
            }
        }
    }

    private func updateAspectRatio(for item: FileItem, image: NSImage) {
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return }
        let ratio = size.width / size.height
        let clamped = min(max(ratio, 0.6), 2.4)

        let oldRatio = aspectRatios[item.url]
        aspectRatios[item.url] = clamped

        if let old = oldRatio {
            if abs(old - clamped) > 0.01 {
                os_log(.info, log: masonryLog, "updateAspectRatio [%{public}@]: CHANGED %.3f -> %.3f (delta=%.3f) ⚠️", item.name, old, clamped, abs(old - clamped))
            }
        } else {
            os_log(.debug, log: masonryLog, "updateAspectRatio [%{public}@]: SET to %.3f (size=%.0fx%.0f)", item.name, clamped, size.width, size.height)
        }
    }

    private func imageSatisfiesMinimum(_ image: NSImage, minPixelSize: CGFloat) -> Bool {
        let maxDimension = max(image.size.width, image.size.height)
        return maxDimension >= minPixelSize * 0.9
    }

    private func handleDrop(providers: [NSItemProvider]) {
        DropHelper.handleDrop(providers: providers, viewModel: viewModel)
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

struct MasonryItemView: View {
    @EnvironmentObject private var settings: AppSettings
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let thumbnail: NSImage?
    let columnWidth: CGFloat
    let imageHeight: CGFloat
    let labelHeight: CGFloat
    let showLabels: Bool
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

            if showLabels {
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
            }

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

struct PhotosMasonryView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var pinchStartIconSize: Double?
    @State private var pinchStartSpacing: Double?
    @State private var pinchStartFontSize: Double?

    var body: some View {
        PhotosMasonryRepresentable(
            viewModel: viewModel,
            items: items,
            iconSize: settings.iconGridIconSize,
            spacing: settings.iconGridSpacing,
            fontSize: settings.iconGridFontSize,
            showFilenames: settings.masonryShowFilenames,
            thumbnailQuality: settings.thumbnailQuality
        )
        .background(Color(nsColor: .controlBackgroundColor))
        .simultaneousGesture(magnificationGesture)
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

private struct PhotosMasonryRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    let iconSize: Double
    let spacing: Double
    let fontSize: Double
    let showFilenames: Bool
    let thumbnailQuality: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    @MainActor func makeNSView(context: Context) -> NSScrollView {
        let layout = PhotosMasonryLayout()
        layout.itemHeightProvider = { [weak coordinator = context.coordinator] indexPath, columnWidth in
            guard let coordinator else { return columnWidth }
            return coordinator.imageHeight(for: indexPath, columnWidth: columnWidth)
        }

        let collectionView = PhotosMasonryCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(PhotosMasonryItem.self, forItemWithIdentifier: PhotosMasonryItem.identifier)
        collectionView.onOpen = { [weak coordinator = context.coordinator] in
            coordinator?.openSelection()
        }
        collectionView.onQuickLook = { [weak coordinator = context.coordinator] in
            coordinator?.toggleQuickLook()
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.scrollView = scrollView
        context.coordinator.update(
            viewModel: viewModel,
            items: items,
            iconSize: iconSize,
            spacing: spacing,
            fontSize: fontSize,
            showFilenames: showFilenames,
            thumbnailQuality: thumbnailQuality,
            forceReload: true
        )

        return scrollView
    }

    @MainActor func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(
            viewModel: viewModel,
            items: items,
            iconSize: iconSize,
            spacing: spacing,
            fontSize: fontSize,
            showFilenames: showFilenames,
            thumbnailQuality: thumbnailQuality,
            forceReload: false
        )
    }

    @MainActor static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSFilePromiseProviderDelegate {
        private struct ItemsSignature: Equatable {
            let count: Int
            let firstID: UUID?
            let lastID: UUID?
        }
        private struct PromiseInfo {
            let item: FileItem
            let filename: String
        }

        var viewModel: FileBrowserViewModel
        weak var collectionView: PhotosMasonryCollectionView?
        weak var scrollView: NSScrollView?

        private var items: [FileItem] = []
        private var itemIndexByID: [UUID: Int] = [:]
        private var itemsSignature: ItemsSignature?

        private var iconSize: CGFloat = 80
        private var spacing: CGFloat = 24
        private var fontSize: CGFloat = 12
        private var showFilenames = false
        private var thumbnailQuality: CGFloat = 1.0

        private var targetPixelSize: CGFloat = 256
        private var previousPreheatRect: NSRect = .zero
        private var lastLayoutWidth: CGFloat = 0

        private let thumbnailCache = NSCache<NSString, NSImage>()
        private var pendingThumbnailKeys: Set<String> = []
        private var aspectRatios: [String: CGFloat] = [:]

        private var isUpdatingSelection = false

        init(viewModel: FileBrowserViewModel) {
            self.viewModel = viewModel
            thumbnailCache.countLimit = 600
        }

        func update(
            viewModel: FileBrowserViewModel,
            items: [FileItem],
            iconSize: Double,
            spacing: Double,
            fontSize: Double,
            showFilenames: Bool,
            thumbnailQuality: Double,
            forceReload: Bool
        ) {
            self.viewModel = viewModel

            let newSignature = ItemsSignature(
                count: items.count,
                firstID: items.first?.id,
                lastID: items.last?.id
            )

            let settingsChanged = updateSettings(
                iconSize: iconSize,
                spacing: spacing,
                fontSize: fontSize,
                showFilenames: showFilenames,
                thumbnailQuality: thumbnailQuality
            )

            updateLayoutForWidthIfNeeded()

            let previousCount = self.items.count
            let canAppend = !forceReload &&
                itemsSignature?.firstID == newSignature.firstID &&
                items.count > previousCount &&
                (collectionView?.numberOfItems(inSection: 0) ?? previousCount) == previousCount

            if canAppend {
                itemsSignature = newSignature
                self.items = items
                for index in previousCount..<items.count {
                    itemIndexByID[items[index].id] = index
                }
                let indexPaths = Set((previousCount..<items.count).map { IndexPath(item: $0, section: 0) })
                collectionView?.insertItems(at: indexPaths)
            } else if forceReload || itemsSignature != newSignature {
                itemsSignature = newSignature
                self.items = items
                rebuildIndexMap()
                collectionView?.reloadData()
                resetPreheat()
            } else if settingsChanged {
                collectionView?.collectionViewLayout?.invalidateLayout()
                refreshVisibleItems()
            }

            applySelectionFromViewModel()
            if forceReload || itemsSignature != newSignature || canAppend || settingsChanged {
                updatePreheat()
            }
        }

        func teardown() {
            if let contentView = scrollView?.contentView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: contentView)
            }
            viewModel.stopCachingAllPhotos()
            pendingThumbnailKeys.removeAll()
            thumbnailCache.removeAllObjects()
        }

        private func updateSettings(
            iconSize: Double,
            spacing: Double,
            fontSize: Double,
            showFilenames: Bool,
            thumbnailQuality: Double
        ) -> Bool {
            let iconSize = CGFloat(iconSize)
            let spacing = CGFloat(spacing)
            let fontSize = CGFloat(fontSize)
            let thumbnailQuality = CGFloat(thumbnailQuality)

            let changed = self.iconSize != iconSize ||
                self.spacing != spacing ||
                self.fontSize != fontSize ||
                self.showFilenames != showFilenames ||
                self.thumbnailQuality != thumbnailQuality

            guard changed else { return false }

            self.iconSize = iconSize
            self.spacing = spacing
            self.fontSize = fontSize
            self.showFilenames = showFilenames
            self.thumbnailQuality = thumbnailQuality

            updateLayoutSettings()
            return true
        }

        private func updateLayoutSettings() {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout as? PhotosMasonryLayout else { return }

            lastLayoutWidth = collectionView.bounds.width
            layout.columnSpacing = max(12, spacing * 0.6)
            layout.idealColumnWidth = max(180, iconSize * 2.4)
            layout.contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            layout.labelHeight = showFilenames ? max(26, fontSize * 2.4) : 0
            layout.showsLabels = showFilenames

            let metrics = PhotosMasonryLayout.columnMetrics(
                for: collectionView.bounds.width,
                idealColumnWidth: layout.idealColumnWidth,
                spacing: layout.columnSpacing,
                insets: layout.contentInsets
            )
            let scale = collectionView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let newTarget = thumbnailPixelSize(columnWidth: metrics.width, scale: scale, quality: thumbnailQuality)

            if abs(newTarget - targetPixelSize) >= 8 {
                targetPixelSize = newTarget
                thumbnailCache.removeAllObjects()
                pendingThumbnailKeys.removeAll()
                resetPreheat()
            }
        }

        private func thumbnailPixelSize(columnWidth: CGFloat, scale: CGFloat, quality: CGFloat) -> CGFloat {
            let target = columnWidth * scale * quality
            let bucket = (target / 128).rounded() * 128
            return min(1024, max(256, bucket))
        }

        private func rebuildIndexMap() {
            itemIndexByID.removeAll(keepingCapacity: true)
            for (index, item) in items.enumerated() {
                itemIndexByID[item.id] = index
            }
        }

        private func refreshVisibleItems() {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout as? PhotosMasonryLayout else { return }
            let layoutAttributes = layout.layoutAttributesForElements(in: collectionView.visibleRect)
            for attributes in layoutAttributes {
                guard let indexPath = attributes.indexPath else { continue }
                guard let item = collectionView.item(at: indexPath) as? PhotosMasonryItem else { continue }
                configure(item: item, at: indexPath)
            }
        }

        private func configure(item: PhotosMasonryItem, at indexPath: IndexPath) {
            guard items.indices.contains(indexPath.item) else { return }
            let fileItem = items[indexPath.item]
            let columnWidth = (collectionView?.collectionViewLayout as? PhotosMasonryLayout)?.currentColumnWidth ?? max(1, collectionView?.bounds.width ?? 1)
            let imageHeight = imageHeight(for: fileItem, columnWidth: columnWidth)
            let labelHeight = showFilenames ? max(26, fontSize * 2.4) : 0
            let image = thumbnail(for: fileItem)

            item.configure(
                item: fileItem,
                image: image,
                imageHeight: imageHeight,
                labelHeight: labelHeight,
                showTitle: showFilenames,
                fontSize: fontSize
            )
        }

        func imageHeight(for indexPath: IndexPath, columnWidth: CGFloat) -> CGFloat {
            guard items.indices.contains(indexPath.item) else { return columnWidth }
            return imageHeight(for: items[indexPath.item], columnWidth: columnWidth)
        }

        private func imageHeight(for item: FileItem, columnWidth: CGFloat) -> CGFloat {
            let ratio = aspectRatio(for: item)
            return max(1, columnWidth / ratio)
        }

        private func aspectRatio(for item: FileItem) -> CGFloat {
            let key = item.url.absoluteString
            if let cached = aspectRatios[key] {
                return cached
            }
            if let ratio = viewModel.photosAssetAspectRatio(for: item) {
                aspectRatios[key] = ratio
                return ratio
            }
            return 4.0 / 3.0
        }

        private func thumbnail(for item: FileItem) -> NSImage? {
            guard let identifier = viewModel.photosAssetIdentifier(for: item) else {
                return item.icon
            }

            let cacheKey = "\(identifier)-\(Int(targetPixelSize))"
            if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
                return cached
            }
            if pendingThumbnailKeys.contains(cacheKey) {
                return nil
            }

            pendingThumbnailKeys.insert(cacheKey)
            let itemID = item.id
            viewModel.requestPhotoThumbnail(for: item, targetPixelSize: targetPixelSize) { [weak self] image, _ in
                guard let self else { return }
                self.pendingThumbnailKeys.remove(cacheKey)

                if let image {
                    self.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
                }

                guard let index = self.itemIndexByID[itemID] else { return }
                let indexPath = IndexPath(item: index, section: 0)
                guard let cell = self.collectionView?.item(at: indexPath) as? PhotosMasonryItem else { return }
                cell.updateImage(image)
            }

            return nil
        }

        private func resetPreheat() {
            previousPreheatRect = .zero
            viewModel.stopCachingAllPhotos()
        }

        private func updateLayoutForWidthIfNeeded() {
            guard let collectionView else { return }
            let width = collectionView.bounds.width
            guard width > 0, abs(width - lastLayoutWidth) > 1 else { return }
            updateLayoutSettings()
            collectionView.collectionViewLayout?.invalidateLayout()
            refreshVisibleItems()
        }

        @objc func boundsDidChange(_ notification: Notification) {
            updateLayoutForWidthIfNeeded()
            updatePreheat()
        }

        private func updatePreheat() {
            guard let scrollView else { return }

            let visibleRect = scrollView.contentView.bounds
            if visibleRect.isEmpty { return }

            let preheatRect = visibleRect.insetBy(dx: 0, dy: -0.5 * visibleRect.height)
            let delta = abs(preheatRect.midY - previousPreheatRect.midY)
            if delta <= visibleRect.height / 3 {
                return
            }

            let differences = differencesBetweenRects(previousPreheatRect, preheatRect)
            let addedItems = differences.added.flatMap { items(in: $0) }
            let removedItems = differences.removed.flatMap { items(in: $0) }

            let targetSize = CGSize(width: targetPixelSize, height: targetPixelSize)
            if !addedItems.isEmpty {
                viewModel.startCachingPhotos(for: addedItems, targetSize: targetSize)
            }
            if !removedItems.isEmpty {
                viewModel.stopCachingPhotos(for: removedItems, targetSize: targetSize)
            }

            previousPreheatRect = preheatRect
        }

        private func items(in rect: NSRect) -> [FileItem] {
            guard let collectionView,
                  let layout = collectionView.collectionViewLayout else { return [] }
            let layoutAttributes = layout.layoutAttributesForElements(in: rect)
            var results: [FileItem] = []
            results.reserveCapacity(layoutAttributes.count)
            for attributes in layoutAttributes {
                guard let indexPath = attributes.indexPath else { continue }
                let index = indexPath.item
                if items.indices.contains(index) {
                    results.append(items[index])
                }
            }
            return results
        }

        private func differencesBetweenRects(_ old: NSRect, _ new: NSRect) -> (added: [NSRect], removed: [NSRect]) {
            guard !old.isEmpty else {
                return (added: [new], removed: [])
            }

            if new.intersects(old) {
                var added: [NSRect] = []
                if new.maxY > old.maxY {
                    added.append(NSRect(x: new.minX, y: old.maxY, width: new.width, height: new.maxY - old.maxY))
                }
                if new.minY < old.minY {
                    added.append(NSRect(x: new.minX, y: new.minY, width: new.width, height: old.minY - new.minY))
                }

                var removed: [NSRect] = []
                if new.maxY < old.maxY {
                    removed.append(NSRect(x: new.minX, y: new.maxY, width: new.width, height: old.maxY - new.maxY))
                }
                if new.minY > old.minY {
                    removed.append(NSRect(x: new.minX, y: old.minY, width: new.width, height: new.minY - old.minY))
                }
                return (added, removed)
            }

            return (added: [new], removed: [old])
        }

        private func applySelectionFromViewModel() {
            guard let collectionView else { return }
            let desired = Set<IndexPath>(viewModel.selectedItems.compactMap { item in
                guard let index = itemIndexByID[item.id] else { return nil }
                return IndexPath(item: index, section: 0)
            })
            guard collectionView.selectionIndexPaths != desired else { return }

            isUpdatingSelection = true
            collectionView.selectionIndexPaths = desired
            if let first = desired.sorted(by: { $0.item < $1.item }).first,
               items.indices.contains(first.item) {
                updateQuickLook(for: items[first.item])
            } else {
                updateQuickLook(for: nil)
            }
            isUpdatingSelection = false
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            guard let item = collectionView.makeItem(withIdentifier: PhotosMasonryItem.identifier, for: indexPath) as? PhotosMasonryItem else {
                return NSCollectionViewItem()
            }

            configure(item: item, at: indexPath)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard items.indices.contains(indexPath.item) else { return nil }
            let item = items[indexPath.item]
            guard let dragInfo = viewModel.photoAssetDragInfo(for: item) else { return nil }
            let provider = NSFilePromiseProvider(fileType: dragInfo.uti, delegate: self)
            provider.userInfo = PromiseInfo(item: item, filename: dragInfo.filename)
            return provider
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionFromCollectionView()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionFromCollectionView()
        }

        private func syncSelectionFromCollectionView() {
            guard let collectionView, !isUpdatingSelection else { return }
            isUpdatingSelection = true
            let selectedItems = collectionView.selectionIndexPaths.compactMap { indexPath -> FileItem? in
                guard items.indices.contains(indexPath.item) else { return nil }
                return items[indexPath.item]
            }
            let newSelection = Set(selectedItems)
            if newSelection == viewModel.selectedItems {
                isUpdatingSelection = false
                return
            }
            viewModel.selectedItems = newSelection
            if let first = collectionView.selectionIndexPaths.sorted(by: { $0.item < $1.item }).first,
               items.indices.contains(first.item) {
                viewModel.lastSelectedIndex = first.item
                updateQuickLook(for: items[first.item])
            } else {
                updateQuickLook(for: nil)
            }
            isUpdatingSelection = false
        }

        @objc func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
            guard let collectionView else { return }
            let point = sender.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  items.indices.contains(indexPath.item) else { return }
            viewModel.openItem(items[indexPath.item])
        }

        func openSelection() {
            guard let indexPath = collectionView?.selectionIndexPaths.first,
                  items.indices.contains(indexPath.item) else { return }
            viewModel.openItem(items[indexPath.item])
        }

        func toggleQuickLook() {
            guard let indexPath = collectionView?.selectionIndexPaths.first,
                  items.indices.contains(indexPath.item) else { return }

            let item = items[indexPath.item]
            // Use async version to avoid blocking during archive extraction
            viewModel.previewURL(for: item) { [weak self] previewURL in
                if let previewURL = previewURL {
                    QuickLookControllerView.shared.togglePreview(for: previewURL) { [weak self] offset in
                        self?.navigateLinear(by: offset)
                    }
                    return
                }

                // Fallback for Photos assets
                self?.viewModel.exportPhotoAsset(for: item) { [weak self] url in
                    guard let url else {
                        NSSound.beep()
                        return
                    }
                    QuickLookControllerView.shared.togglePreview(for: url) { [weak self] offset in
                        self?.navigateLinear(by: offset)
                    }
                }
            }
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            guard let info = filePromiseProvider.userInfo as? PromiseInfo else {
                return "Photo"
            }
            return info.filename
        }

        nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            guard let info = filePromiseProvider.userInfo as? PromiseInfo else {
                completionHandler(NSError(domain: "com.coverflowfinder.photos", code: 1))
                return
            }

            let destinationURL: URL
            if url.hasDirectoryPath || url.pathExtension.isEmpty {
                destinationURL = url.appendingPathComponent(info.filename)
            } else {
                destinationURL = url
            }
            guard let identifier = photosAssetIdentifier(from: info.item),
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
                  let resource = primaryResource(for: asset) else {
                completionHandler(NSError(domain: "com.coverflowfinder.photos", code: 2))
                return
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            try? FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destinationURL)

            PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
                completionHandler(error)
            }
        }

        nonisolated private func photosAssetIdentifier(from item: FileItem) -> String? {
            let url = item.url
            guard url.scheme == "photos", url.host == "asset" else { return nil }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            return components?.queryItems?.first(where: { $0.name == "id" })?.value
        }

        nonisolated private func primaryResource(for asset: PHAsset) -> PHAssetResource? {
            let resources = PHAssetResource.assetResources(for: asset)
            if asset.mediaType == .video {
                return resources.first { $0.type == .video || $0.type == .fullSizeVideo } ?? resources.first
            }
            return resources.first { $0.type == .photo || $0.type == .fullSizePhoto } ?? resources.first
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

        private func navigateLinear(by offset: Int) {
            guard !items.isEmpty else { return }
            let currentIndex = collectionView?.selectionIndexPaths.first?.item ?? 0
            let newIndex = max(0, min(items.count - 1, currentIndex + offset))
            let newIndexPath = IndexPath(item: newIndex, section: 0)
            viewModel.selectItem(items[newIndex])
            collectionView?.selectionIndexPaths = [newIndexPath]
            collectionView?.scrollToItems(at: [newIndexPath], scrollPosition: .centeredVertically)
            updateQuickLook(for: items[newIndex])
        }
    }
}

private final class PhotosMasonryLayout: NSCollectionViewLayout {
    var idealColumnWidth: CGFloat = 180 {
        didSet { invalidateLayout() }
    }
    var columnSpacing: CGFloat = 12 {
        didSet { invalidateLayout() }
    }
    var contentInsets: NSEdgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16) {
        didSet { invalidateLayout() }
    }
    var labelHeight: CGFloat = 0 {
        didSet { invalidateLayout() }
    }
    var showsLabels = false {
        didSet { invalidateLayout() }
    }

    var itemHeightProvider: ((IndexPath, CGFloat) -> CGFloat)?

    private(set) var currentColumnWidth: CGFloat = 0
    private var cachedAttributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var contentHeight: CGFloat = 0

    private let verticalPadding: CGFloat = 12
    private let labelSpacing: CGFloat = 6

    override func prepare() {
        guard let collectionView else { return }
        cachedAttributes.removeAll(keepingCapacity: true)
        contentHeight = 0

        let metrics = Self.columnMetrics(
            for: collectionView.bounds.width,
            idealColumnWidth: idealColumnWidth,
            spacing: columnSpacing,
            insets: contentInsets
        )
        currentColumnWidth = metrics.width

        let columnCount = metrics.count
        guard columnCount > 0, currentColumnWidth > 0 else { return }

        var xOffsets: [CGFloat] = []
        xOffsets.reserveCapacity(columnCount)
        for column in 0..<columnCount {
            let x = contentInsets.left + CGFloat(column) * (currentColumnWidth + columnSpacing)
            xOffsets.append(x)
        }

        var yOffsets = Array(repeating: contentInsets.top, count: columnCount)

        let itemCount = collectionView.numberOfItems(inSection: 0)
        for item in 0..<itemCount {
            let indexPath = IndexPath(item: item, section: 0)
            let imageHeight = itemHeightProvider?(indexPath, currentColumnWidth) ?? currentColumnWidth
            let labelStackHeight = showsLabels ? labelHeight + labelSpacing : 0
            let itemHeight = imageHeight + labelStackHeight + verticalPadding

            let column = yOffsets.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let frame = NSRect(x: xOffsets[column], y: yOffsets[column], width: currentColumnWidth, height: itemHeight)
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = frame
            cachedAttributes[indexPath] = attributes
            yOffsets[column] = frame.maxY + columnSpacing
            contentHeight = max(contentHeight, yOffsets[column])
        }

        if itemCount == 0 {
            contentHeight = contentInsets.top + contentInsets.bottom
        } else {
            contentHeight += contentInsets.bottom - columnSpacing
        }
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        cachedAttributes.values.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.size.width != collectionView.bounds.size.width
    }

    static func columnMetrics(
        for width: CGFloat,
        idealColumnWidth: CGFloat,
        spacing: CGFloat,
        insets: NSEdgeInsets
    ) -> (count: Int, width: CGFloat) {
        let availableWidth = max(0, width - insets.left - insets.right)
        let count = max(1, Int((availableWidth + spacing) / (idealColumnWidth + spacing)))
        let totalSpacing = spacing * CGFloat(max(0, count - 1))
        let columnWidth = max(1, (availableWidth - totalSpacing) / CGFloat(count))
        return (count, columnWidth)
    }
}

private final class PhotosMasonryCollectionView: NSCollectionView {
    var onOpen: (@MainActor () -> Void)?
    var onQuickLook: (@MainActor () -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.firstResponder == nil {
            window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if event.clickCount == 2 {
            onOpen?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            onOpen?()
        case 49:
            onQuickLook?()
        default:
            super.keyDown(with: event)
        }
    }
}

private final class PhotosMasonryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotosMasonryItem")

    private let tileView = PhotosMasonryTileView()
    private let titleField = NSTextField(labelWithString: "")
    private let titleBackground = NSView()

    private var imageHeight: CGFloat = 0
    private var labelHeight: CGFloat = 0
    private var showTitle = false

    override func loadView() {
        view = FlippedView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 0
        view.layer?.backgroundColor = NSColor.clear.cgColor

        tileView.wantsLayer = true
        tileView.layer?.cornerRadius = 10
        tileView.layer?.masksToBounds = true
        tileView.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor

        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 2
        titleField.isSelectable = false

        titleBackground.wantsLayer = true
        titleBackground.layer?.cornerRadius = 6
        titleBackground.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        titleBackground.isHidden = true

        view.addSubview(tileView)
        view.addSubview(titleBackground)
        view.addSubview(titleField)
    }

    override var isSelected: Bool {
        didSet {
            updateSelection()
        }
    }

    func configure(
        item: FileItem,
        image: NSImage?,
        imageHeight: CGFloat,
        labelHeight: CGFloat,
        showTitle: Bool,
        fontSize: CGFloat
    ) {
        representedObject = item
        tileView.image = image
        self.imageHeight = imageHeight
        self.labelHeight = labelHeight
        self.showTitle = showTitle

        titleField.stringValue = item.name
        titleField.font = NSFont.systemFont(ofSize: fontSize)
        titleField.isHidden = !showTitle
        titleBackground.isHidden = !showTitle || !isSelected
        titleField.textColor = isSelected ? .white : .labelColor

        view.needsLayout = true
        updateSelection()
    }

    func updateImage(_ image: NSImage?) {
        tileView.image = image
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        tileView.frame = NSRect(x: 0, y: 0, width: width, height: imageHeight)

        guard showTitle, labelHeight > 0 else { return }
        let labelY = imageHeight + 6
        let labelFrame = NSRect(x: 6, y: labelY, width: width - 12, height: labelHeight)
        titleBackground.frame = labelFrame
        titleField.frame = labelFrame
    }

    private func updateSelection() {
        if isSelected {
            view.layer?.borderWidth = 2
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            titleBackground.isHidden = !showTitle
            titleField.textColor = .white
        } else {
            view.layer?.borderWidth = 0
            view.layer?.backgroundColor = NSColor.clear.cgColor
            titleBackground.isHidden = true
            titleField.textColor = .labelColor
        }
    }
}

private final class PhotosMasonryTileView: NSView {
    var image: NSImage? {
        didSet {
            layer?.contents = image
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

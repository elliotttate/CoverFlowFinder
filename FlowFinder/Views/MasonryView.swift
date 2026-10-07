import SwiftUI
import AppKit
import Photos
import Quartz
import os.log

private let masonryLog = OSLog(subsystem: "com.flowfinder", category: "MasonryLayout")

struct MasonryView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.browserWindow) private var browserWindow
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var internalDragState = InternalDragState.shared
    let items: [FileItem]

    @State private var isDropTargeted = false
    @State private var dropTargetedItemID: UUID?
    @State private var currentWidth: CGFloat = 800
    @State private var currentHeight: CGFloat = 600
    @State private var autoScrollTimer: Timer?
    @State private var pinchStartIconSize: Double?
    @State private var pinchStartSpacing: Double?
    @State private var pinchStartFontSize: Double?

    // Thumbnail loading (visible tiles, batching, memory window)
    @StateObject private var thumbnailLoader = GridThumbnailLoader()
    // Layout bookkeeping that must not trigger renders
    @StateObject private var runtime = MasonryRuntime()
    private let thumbnailCache = ThumbnailCacheManager.shared

    // CACHED LAYOUT - calculated when items, dimensions or settings change, never during scroll.
    // nil until the first dimensions are known, so the folder doesn't open with estimated sizes.
    @State private var cachedLayout: MasonryLayout?
    /// Finder tags of the items that have any, read off the main thread (see `startTagRead`)
    @State private var tagsByURL: [URL: [String]] = [:]

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

    private func labelHeight(for item: FileItem) -> CGFloat {
        // Always show labels for folders, non-media files (show icon only), when filenames setting is on, or when renaming
        shouldShowLabel(for: item) ? baseLabelHeight : 0
    }

    private func tagHeight(for item: FileItem) -> CGFloat {
        settings.showItemTags && tagsByURL[item.url] != nil ? 12 : 0
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

    /// Tile height: image (real aspect ratio once known, 4:3 until then) + label + tags + padding
    private func itemHeight(for item: FileItem, dimensions: CGSize?) -> CGFloat {
        let imageHeight: CGFloat
        if item.isDirectory {
            imageHeight = folderTileHeight
        } else if let dimensions, dimensions.width > 0, dimensions.height > 0 {
            imageHeight = columnWidth / min(max(dimensions.width / dimensions.height, 0.4), 2.5)
        } else {
            imageHeight = columnWidth / (4.0 / 3.0)
        }
        return imageHeight + labelHeight(for: item) + tagHeight(for: item) + 12
    }

    /// Layout from cached dimensions only (no file access), so it's cheap enough to run on main
    private func calculateLayout(for sourceItems: [FileItem]) -> MasonryLayout {
        let dimensions = thumbnailCache.cachedImageDimensions(for: sourceItems.filter { !$0.isDirectory })
        let heights = sourceItems.map { itemHeight(for: $0, dimensions: dimensions[$0.url]) }
        return MasonryLayout.compute(
            keys: sourceItems.map(\.url),
            heights: heights,
            columnCount: columnCount,
            columnWidth: columnWidth,
            spacing: columnSpacing
        )
    }

    /// Recalculate and cache the layout for the current items
    private func recalculateLayout() {
        let layout = calculateLayout(for: runtime.items)
        runtime.layoutItemsVersion = runtime.itemsVersion
        if layout != cachedLayout {
            cachedLayout = layout
        }
    }

    /// Lays out again after dimensions arrived for `changedItems`. When the cached layout is for the current items
    /// and columns, only the items from the first changed one on are placed again (everything before it stays put),
    /// so reading a big folder's dimensions chunk by chunk doesn't redo the whole layout each time.
    private func relayoutAfterDimensionsArrived(for changedItems: [FileItem]) {
        guard let layout = cachedLayout,
              runtime.layoutItemsVersion == runtime.itemsVersion,
              layout.columnCount == columnCount, layout.columnWidth == columnWidth,
              layout.keys.count == runtime.items.count else {
            recalculateLayout()
            return
        }
        let indices = changedItems.compactMap { item -> Int? in
            guard let index = thumbnailLoader.index(of: item.url),
                  runtime.items.indices.contains(index), runtime.items[index].url == item.url else { return nil }
            return index
        }
        guard let start = indices.min() else { return }

        let tail = runtime.items[start...]
        let dimensions = thumbnailCache.cachedImageDimensions(for: tail.filter { !$0.isDirectory })
        let tailHeights = tail.map { itemHeight(for: $0, dimensions: dimensions[$0.url]) }
        if let updated = layout.relayout(from: start, tailHeights: tailHeights) {
            cachedLayout = updated
        }
    }

    /// Cached layout if it still matches the column configuration (otherwise computed fresh)
    private func currentLayout(for sourceItems: [FileItem]) -> MasonryLayout {
        guard let cached = cachedLayout else { return .empty }
        if cached.columnCount == columnCount, abs(cached.columnWidth - columnWidth) < 1 {
            return cached
        }
        return calculateLayout(for: sourceItems)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = currentLayout(for: items)
            let itemsByURL = runtime.lookup(for: items)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    HStack(alignment: .top, spacing: columnSpacing) {
                        ForEach(layout.columns.indices, id: \.self) { columnIndex in
                            LazyVStack(spacing: columnSpacing) {
                                ForEach(layout.columns[columnIndex], id: \.self) { url in
                                    // The layout stores URLs; tiles always render the current item
                                    if let item = itemsByURL[url] {
                                        tile(for: item, height: layout.positions[url]?.height)
                                    }
                                }
                            }
                        }
                    }
                    // Dragging a selected tile drags the whole selection
                    .fileDragContainer(for: viewModel)
                    .padding(.horizontal, sidePadding)
                    .padding(.vertical, sidePadding)
                    // Fill remaining space to allow clicking on empty area
                    .frame(minHeight: geometry.size.height)
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Click on empty space - deselect all
                                viewModel.selectedItems.removeAll()
                                viewModel.cancelPendingRename()
                            }
                    )
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .overlay {
                    // No layout until the first dimensions are read (seconds on a slow share): say so
                    if cachedLayout == nil && !items.isEmpty {
                        MasonryLoadingIndicator()
                    }
                }
                .onAppear {
                    currentWidth = geometry.size.width
                    currentHeight = geometry.size.height
                    runtime.items = items
                    runtime.itemsVersion += 1
                    thumbnailLoader.viewModel = viewModel
                    thumbnailLoader.loadsPhotosAssets = true
                    thumbnailLoader.columnCount = columnCount
                    thumbnailLoader.setTargetPixelSize(masonryThumbnailPixelSize)
                    thumbnailLoader.setItems(items)
                    if cachedLayout == nil {
                        // Scroll to the selection once the first layout exists
                        runtime.needsScrollToSelection = true
                    } else if let primary = viewModel.primarySelectedItem {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo(primary.url, anchor: .center)
                        }
                    }
                    // Dimensions are read in the background first; the layout follows
                    startDimensionPrefetch()
                    startTagRead()
                }
                .onDisappear {
                    // Abandon pending dimension reads; the next appearance starts over
                    runtime.prefetchGeneration += 1
                    runtime.prefetchingURLs.removeAll()
                    runtime.dimensionAttempts.removeAll()
                    thumbnailLoader.stop()
                    autoScrollTimer?.invalidate()
                    autoScrollTimer = nil
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    currentWidth = newWidth
                    layoutSettingsChanged()
                }
                .onChange(of: viewModel.selectedItems) { _, _ in
                    guard let primary = viewModel.primarySelectedItem else {
                        updateQuickLook(for: nil)
                        return
                    }
                    // Only scroll when the lead item isn't already on screen (after a delete the
                    // next item is usually visible and the grid should stay put).
                    if !thumbnailLoader.isOnScreen(primary.url) {
                        withAnimation {
                            scrollProxy.scrollTo(primary.url)
                        }
                    }
                    updateQuickLook(for: primary)
                }
                .onChange(of: cachedLayout == nil) { _, isMissing in
                    // Scroll to selected item when layout first becomes available
                    guard !isMissing, runtime.needsScrollToSelection else { return }
                    runtime.needsScrollToSelection = false
                    if let primary = viewModel.primarySelectedItem {
                        // Small delay to ensure layout is applied
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            scrollProxy.scrollTo(primary.url, anchor: .center)
                        }
                    }
                }
                .onChange(of: internalDragState.isDragging) { _, isDragging in
                    // Start/stop auto-scroll timer based on drag state
                    if isDragging {
                        autoScrollTimer?.invalidate()
                        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
                            guard internalDragState.isDragging else {
                                autoScrollTimer?.invalidate()
                                return
                            }

                            // Use window-relative coordinates for edge detection
                            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }

                            // Use current mouse location
                            let screenPoint = NSEvent.mouseLocation
                            let windowPoint = window.convertPoint(fromScreen: screenPoint)
                            let windowHeight = window.frame.height

                            // Edge detection - use percentage-based approach (15% of window height)
                            let edgePercent: CGFloat = 0.15
                            let topThreshold = windowHeight * (1.0 - edgePercent)
                            let bottomThreshold = windowHeight * edgePercent

                            var direction: DragAutoScrollState.ScrollDirection = .none

                            // Near top edge (high y value)
                            if windowPoint.y > topThreshold {
                                direction = .up
                            }
                            // Near bottom edge (low y value)
                            else if windowPoint.y < bottomThreshold {
                                direction = .down
                            }

                            guard direction != .none else { return }

                            // The loader always has the current items (this timer outlives renders)
                            let (currentItems, bounds) = MainActor.assumeIsolated {
                                (thumbnailLoader.items, thumbnailLoader.visibleIndexBounds())
                            }
                            guard let visible = bounds else { return }

                            let targetIndex = direction == .up
                                ? max(0, visible.lowerBound - 1)
                                : min(currentItems.count - 1, visible.upperBound + 1)

                            if currentItems.indices.contains(targetIndex) {
                                withAnimation(.linear(duration: 0.1)) {
                                    scrollProxy.scrollTo(currentItems[targetIndex].url, anchor: direction == .up ? .top : .bottom)
                                }
                            }
                        }
                    } else {
                        autoScrollTimer?.invalidate()
                        autoScrollTimer = nil
                    }
                }
                .onChange(of: geometry.size.height) { _, newHeight in
                    currentHeight = newHeight
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .featheredTopBlur(height: 50)
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
            viewModel: viewModel,
            isDropTargeted: $isDropTargeted,
            containerHeight: currentHeight,
            items: items
        ))
        .dropTargetOverlay(isTargeted: isDropTargeted && !internalDragState.isDragging, padding: UI.Spacing.medium)
        .onChange(of: items) { oldItems, newItems in
            itemsDidChange(from: oldItems, to: newItems)
        }
        .onChange(of: items.map(\.contentVersion)) { oldVersions, newVersions in
            // Metadata, cloud status or in-place edits: re-read changed files' dimensions/thumbnails.
            // When only iCloud status changed (syncing), sizes and tags didn't: no new layout or tag read.
            let onlyCloudStatus = oldVersions.count == newVersions.count
                && zip(oldVersions, newVersions).allSatisfy {
                    $0.modificationDate == $1.modificationDate && $0.size == $1.size && $0.hasMetadata == $1.hasMetadata
                }
                && runtime.items.count == items.count
                && zip(runtime.items, items).allSatisfy { $0.url == $1.url }
            itemsDidChange(from: runtime.items, to: items, layoutAffected: !onlyCloudStatus)
        }
        .onChange(of: settings.iconGridIconSize) { _, _ in
            layoutSettingsChanged()
        }
        .onChange(of: settings.iconGridSpacing) { _, _ in
            layoutSettingsChanged()
        }
        .onChange(of: settings.thumbnailQuality) { _, _ in
            thumbnailLoader.setTargetPixelSize(masonryThumbnailPixelSize)
        }
        // Label and tag heights are part of each tile's height
        .onChange(of: settings.masonryShowFilenames) { _, _ in
            recalculateLayoutIfReady()
        }
        .onChange(of: settings.showItemTags) { _, _ in
            recalculateLayoutIfReady()
            startTagRead()
        }
        // Tags edited here or elsewhere (the cache entries were dropped): read them again
        .onChange(of: viewModel.tagRefreshToken) { _, _ in
            startTagRead()
        }
        .onChange(of: settings.iconGridFontSize) { _, _ in
            recalculateLayoutIfReady()
        }
        .onChange(of: viewModel.renamingURL) { _, _ in
            recalculateLayoutIfReady()
        }
        .keyboardNavigable(
            onUpArrow: { shift in navigateVertical(-1, extend: shift) },
            onDownArrow: { shift in navigateVertical(1, extend: shift) },
            onLeftArrow: { shift in navigateHorizontal(-1, extend: shift) },
            onRightArrow: { shift in navigateHorizontal(1, extend: shift) },
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

    @ViewBuilder
    private func tile(for item: FileItem, height cachedHeight: CGFloat?) -> some View {
        // Use CACHED height from layout positions - never recalculate during scroll
        let tileHeight = cachedHeight ?? itemHeight(for: item, dimensions: nil)
        // Extract just the image portion (subtract label, tags and padding)
        let imageHeight = max(1, tileHeight - labelHeight(for: item) - tagHeight(for: item) - 12)

        MasonryItemView(
            item: item,
            viewModel: viewModel,
            thumbnail: thumbnailLoader.image(for: item.url),
            columnWidth: columnWidth,
            imageHeight: imageHeight,
            labelHeight: labelHeight(for: item),
            showLabels: shouldShowLabel(for: item),
            tags: settings.showItemTags ? tagsByURL[item.url] ?? [] : [],
            dropTargetedItemID: $dropTargetedItemID,
            onSelect: { item, clickedOnTextArea in
                selectItem(item, clickedOnTextArea: clickedOnTextArea)
            },
            onDoubleClick: { item in
                viewModel.openItem(item)
            }
        )
        .id(item.url)
        .onAppear {
            thumbnailLoader.tileAppeared(item.url)
        }
        .onDisappear {
            thumbnailLoader.tileDisappeared(item.url)
        }
        .onScrollVisibilityChange(threshold: GridThumbnailLoader.onScreenThreshold) { isVisible in
            thumbnailLoader.setOnScreen(item.url, isVisible)
        }
    }

    // MARK: - Items, dimensions and layout

    /// Items were added, removed, reordered or updated. Tiles that remain keep their thumbnails;
    /// the layout is recomputed from cached dimensions (shortest-column placement, so tiles above
    /// the first change don't move) and only files without known dimensions are read.
    /// `layoutAffected` is false when the same files only changed iCloud status.
    private func itemsDidChange(from oldItems: [FileItem], to newItems: [FileItem], layoutAffected: Bool = true) {
        if GridThumbnailLoader.sameStorage(newItems, runtime.items) { return }
        runtime.items = newItems
        thumbnailLoader.setItems(newItems)
        if layoutAffected {
            let change = MasonryLayout.classifyChange(from: oldItems.map(\.url), to: newItems.map(\.url))
            os_log(.debug, log: masonryLog, "items changed: %{public}@ %d -> %d", String(describing: change), oldItems.count, newItems.count)
            runtime.itemsVersion += 1
            recalculateLayoutIfReady()
            startTagRead()
        }
        startDimensionPrefetch()
    }

    /// Tags live in an extended attribute per file, so they're read in the background (through
    /// FileTagManager's cache) and the layout only uses what was read; tiles grow a tag row when
    /// the read finds tags. Only the latest read applies.
    private func startTagRead() {
        guard settings.showItemTags else { return }
        runtime.tagReadGeneration += 1
        let generation = runtime.tagReadGeneration
        let urls = runtime.items.filter { !$0.isFromArchive && $0.url.isFileURL }.map(\.url)
        let state = runtime
        DispatchQueue.global(qos: .userInitiated).async {
            let tags = MasonryRuntime.readTags(for: urls)
            DispatchQueue.main.async {
                guard state.tagReadGeneration == generation, tags != tagsByURL else { return }
                tagsByURL = tags
                recalculateLayoutIfReady()
            }
        }
    }

    private func recalculateLayoutIfReady() {
        // Before the first layout we're still waiting for dimensions
        guard cachedLayout != nil else { return }
        recalculateLayout()
    }

    private func layoutSettingsChanged() {
        thumbnailLoader.columnCount = columnCount
        thumbnailLoader.setTargetPixelSize(masonryThumbnailPixelSize)
        recalculateLayoutIfReady()
    }

    /// Read dimensions of media files we don't know yet, in display order and in chunks, and lay
    /// out again after each chunk. The first chunk covers the top of the folder and the selection
    /// (whose position depends only on the items before it), so the first layout is already right
    /// where the user looks. Completions use `runtime.items`, never a captured list, so a slow read
    /// can't bring back a deleted file.
    private func startDimensionPrefetch() {
        let needed = runtime.items.filter { item in
            !item.isDirectory
                && (item.fileType == .image || item.fileType == .video)
                && !runtime.prefetchingURLs.contains(item.url)
                && runtime.dimensionAttempts[item.url] != item.contentVersion
                && !thumbnailCache.hasDimensionRecord(for: item)
        }
        guard !needed.isEmpty else {
            if cachedLayout == nil && runtime.prefetchingURLs.isEmpty {
                recalculateLayout()
            }
            return
        }

        var firstChunkCount = min(needed.count, 150)
        if let primary = viewModel.primarySelectedItem,
           let selectedIndex = thumbnailLoader.index(of: primary.url) {
            let throughSelection = needed.prefix { (thumbnailLoader.index(of: $0.url) ?? 0) <= selectedIndex + 50 }.count
            firstChunkCount = min(needed.count, max(firstChunkCount, min(throughSelection, 3000)))
        }
        var chunks: [[FileItem]] = [Array(needed.prefix(firstChunkCount))]
        var start = firstChunkCount
        while start < needed.count {
            let end = min(needed.count, start + 300)
            chunks.append(Array(needed[start..<end]))
            start = end
        }
        for item in needed {
            runtime.prefetchingURLs.insert(item.url)
        }
        os_log(.debug, log: masonryLog, "prefetching dimensions for %d files in %d chunks", needed.count, chunks.count)
        prefetchDimensionChunks(chunks[...], generation: runtime.prefetchGeneration)
    }

    private func prefetchDimensionChunks(_ chunks: ArraySlice<[FileItem]>, generation: Int) {
        guard let chunk = chunks.first else { return }
        let state = runtime
        thumbnailCache.prefetchImageDimensions(for: chunk) { _ in
            // The view went away (onDisappear resets the bookkeeping): stop here
            guard state.prefetchGeneration == generation else { return }
            for item in chunk {
                state.prefetchingURLs.remove(item.url)
                if !thumbnailCache.hasDimensionRecord(for: item) {
                    // Not read (an iCloud file that isn't downloaded, an archive member): it keeps the default
                    // shape and is tried again only once it changes (e.g. when it has been downloaded).
                    state.dimensionAttempts[item.url] = item.contentVersion
                }
            }
            relayoutAfterDimensionsArrived(for: chunk)
            prefetchDimensionChunks(chunks.dropFirst(), generation: generation)
        }
    }

    // MARK: - Selection and keyboard navigation

    private func indexOfItem(at url: URL) -> Int? {
        if let index = thumbnailLoader.index(of: url), items.indices.contains(index), items[index].url == url {
            return index
        }
        return items.firstIndex { $0.url == url }
    }

    private func selectItem(_ item: FileItem, clickedOnTextArea: Bool = true) {
        if let index = items.firstIndex(of: item) {
            let modifiers = NSEvent.modifierFlags
            viewModel.handleSelection(
                item: item,
                index: index,
                in: items,
                withShift: modifiers.contains(.shift),
                withCommand: modifiers.contains(.command),
                clickedOnTextArea: clickedOnTextArea
            )
            updateQuickLook(for: item)
        }
    }

    private func navigateLinear(by offset: Int) {
        guard !items.isEmpty else { return }

        let currentIndex: Int
        if let selectedItem = viewModel.primarySelectedItem,
           let index = items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        let newItem = items[newIndex]
        viewModel.selectItem(newItem)
        viewModel.lastSelectedIndex = newIndex
        viewModel.selectionAnchorIndex = newIndex
        updateQuickLook(for: newItem)
    }

    /// The item the arrow keys move from: the moving end of a shift-selection, else the lead item
    private func navigationOrigin(extend: Bool) -> FileItem? {
        guard !items.isEmpty else { return nil }
        if extend {
            let idx = max(0, min(items.count - 1, viewModel.lastSelectedIndex))
            return items[idx]
        }
        return ensureSelection()
    }

    private func moveSelection(to targetURL: URL, extend: Bool) {
        guard let targetIndex = indexOfItem(at: targetURL) else { return }
        let targetItem = items[targetIndex]
        if extend {
            viewModel.selectRange(to: targetIndex, in: items)
            updateQuickLook(for: targetItem)
        } else {
            selectItem(targetItem)
        }
    }

    private func navigateVertical(_ direction: Int, extend: Bool = false) {
        guard let currentItem = navigationOrigin(extend: extend) else { return }
        let layout = currentLayout(for: items)
        guard let position = layout.positions[currentItem.url] else { return }

        let columnURLs = layout.columns[position.column]
        let nextIndex = position.indexInColumn + direction
        guard columnURLs.indices.contains(nextIndex) else { return }
        moveSelection(to: columnURLs[nextIndex], extend: extend)
    }

    private func navigateHorizontal(_ direction: Int, extend: Bool = false) {
        guard let currentItem = navigationOrigin(extend: extend) else { return }
        let layout = currentLayout(for: items)
        guard let position = layout.positions[currentItem.url] else { return }

        let targetColumn = position.column + direction
        guard layout.columns.indices.contains(targetColumn) else { return }

        let targetURLs = layout.columns[targetColumn]
        guard !targetURLs.isEmpty else { return }

        let currentCenter = position.y + (position.height / 2)
        var closestURL = targetURLs[0]
        var closestDelta = CGFloat.greatestFiniteMagnitude

        for url in targetURLs {
            guard let targetPosition = layout.positions[url] else { continue }
            let targetCenter = targetPosition.y + (targetPosition.height / 2)
            let delta = abs(targetCenter - currentCenter)
            if delta < closestDelta {
                closestDelta = delta
                closestURL = url
            }
        }

        moveSelection(to: closestURL, extend: extend)
    }

    private func openSelectedItem() {
        if let selectedItem = viewModel.primarySelectedItem {
            viewModel.openItem(selectedItem)
        }
    }

    private func jumpToMatch(_ searchString: String) {
        guard !searchString.isEmpty else { return }
        let lowercased = searchString.lowercased()

        // Find the first item that starts with the typed string
        if let matchItem = items.first(where: { $0.displayName.lowercased().hasPrefix(lowercased) }) {
            selectItem(matchItem)
        }
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection(in: browserWindow?.window) { [self] offset in
            navigateLinear(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item, in: browserWindow?.window)
    }

    @discardableResult
    private func ensureSelection() -> FileItem? {
        if let current = viewModel.primarySelectedItem {
            return current
        }

        guard let first = items.first else { return nil }
        viewModel.selectItem(first)
        viewModel.lastSelectedIndex = 0
        viewModel.selectionAnchorIndex = 0
        updateQuickLook(for: first)
        return first
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

// MARK: - Masonry Layout

/// Column layout for Masonry, keyed by file URL. Each item goes into the currently shortest
/// column (ties go left), so an item's position depends only on the items before it: removing or
/// adding a file leaves everything above it in place, appending never moves existing tiles, and
/// the same items always produce the same layout.
struct MasonryLayout: Equatable {
    struct Position: Equatable {
        let column: Int
        let indexInColumn: Int
        let y: CGFloat
        let height: CGFloat
    }

    var columns: [[URL]]
    var positions: [URL: Position]
    var columnCount: Int
    var columnWidth: CGFloat
    // The inputs, so `relayout(from:tailHeights:)` can place just the tail again (not compared: the
    // columns and positions above follow from them).
    /// All keys, in order
    var keys: [URL] = []
    /// The column each key went into; -1 for a repeated key (skipped)
    var placements: [Int] = []
    var heights: [CGFloat] = []
    var spacing: CGFloat = 0

    static let empty = MasonryLayout(columns: [], positions: [:], columnCount: 0, columnWidth: 0)

    static func == (lhs: MasonryLayout, rhs: MasonryLayout) -> Bool {
        lhs.columnCount == rhs.columnCount
            && lhs.columnWidth == rhs.columnWidth
            && lhs.columns == rhs.columns
            && lhs.positions == rhs.positions
    }

    static func compute(keys: [URL], heights: [CGFloat], columnCount: Int, columnWidth: CGFloat, spacing: CGFloat) -> MasonryLayout {
        let count = max(1, columnCount)
        guard !keys.isEmpty else {
            return MasonryLayout(columns: [], positions: [:], columnCount: count, columnWidth: columnWidth, spacing: spacing)
        }

        var layout = MasonryLayout(
            columns: Array(repeating: [URL](), count: count),
            positions: [:],
            columnCount: count,
            columnWidth: columnWidth,
            spacing: spacing
        )
        layout.positions.reserveCapacity(keys.count)
        layout.keys.reserveCapacity(keys.count)
        layout.placements.reserveCapacity(keys.count)
        layout.heights.reserveCapacity(keys.count)
        var columnHeights = Array(repeating: CGFloat(0), count: count)
        layout.place(keys[...], heights: heights, columnHeights: &columnHeights)
        return layout
    }

    /// This layout with new heights for the keys from `start` on (`tailHeights[0]` is the height of
    /// `keys[start]`). Items before `start` keep their places, since a position only depends on
    /// the items before it; only the rest are placed again. Nil when no height changed.
    func relayout(from start: Int, tailHeights: [CGFloat]) -> MasonryLayout? {
        guard start >= 0, start <= keys.count, tailHeights.count == keys.count - start,
              tailHeights != Array(heights[start...]) else { return nil }

        // How many items each column keeps, and how tall it is where the tail begins
        var kept = Array(repeating: 0, count: columnCount)
        for column in placements[..<start] where column >= 0 {
            kept[column] += 1
        }
        var columnHeights = Array(repeating: CGFloat(0), count: columnCount)
        for column in 0..<columnCount where kept[column] > 0 {
            if let last = positions[columns[column][kept[column] - 1]] {
                columnHeights[column] = last.y + last.height + spacing
            }
        }

        var layout = self
        for index in start..<keys.count where placements[index] >= 0 {
            layout.positions[keys[index]] = nil
        }
        for column in layout.columns.indices {
            layout.columns[column].removeSubrange(kept[column]...)
        }
        layout.keys.removeSubrange(start...)
        layout.placements.removeSubrange(start...)
        layout.heights.removeSubrange(start...)
        layout.place(keys[start...], heights: tailHeights, columnHeights: &columnHeights)
        return layout
    }

    /// Appends `newKeys`, each into the currently shortest column (ties go left); a key that's
    /// already placed is skipped.
    private mutating func place(_ newKeys: ArraySlice<URL>, heights newHeights: [CGFloat], columnHeights: inout [CGFloat]) {
        for (offset, key) in newKeys.enumerated() {
            let height = offset < newHeights.count ? newHeights[offset] : 0
            keys.append(key)
            heights.append(height)
            guard positions[key] == nil else {
                placements.append(-1)
                continue
            }
            var shortest = 0
            for column in 1..<columnCount where columnHeights[column] < columnHeights[shortest] {
                shortest = column
            }
            positions[key] = Position(
                column: shortest,
                indexInColumn: columns[shortest].count,
                y: columnHeights[shortest],
                height: height
            )
            columns[shortest].append(key)
            columnHeights[shortest] += height + spacing
            placements.append(shortest)
        }
    }

    enum Change: Equatable {
        case none
        /// Only removals (the new items are a subset of the old ones)
        case removal
        /// Only additions
        case addition
        /// Same items, different order (sort)
        case reorder
        /// Items both added and removed (filter edits, renames, refresh)
        case mixed
    }

    static func classifyChange(from old: [URL], to new: [URL]) -> Change {
        if old == new { return .none }
        let oldSet = Set(old)
        let newSet = Set(new)
        if oldSet == newSet { return .reorder }
        if !newSet.isEmpty && newSet.isSubset(of: oldSet) { return .removal }
        if oldSet.isSubset(of: newSet) { return .addition }
        return .mixed
    }
}

/// Masonry state that must not trigger re-renders (it never publishes).
final class MasonryRuntime: ObservableObject {
    /// Always the latest items: async work reads this, never a captured copy.
    var items: [FileItem] = []
    /// Bumped when the files in `items` (or their order) change, not for metadata or iCloud status updates
    var itemsVersion = 0
    /// The `itemsVersion` the cached layout was computed for
    var layoutItemsVersion = -1
    var needsScrollToSelection = false
    /// Media files whose dimensions are being read
    var prefetchingURLs: Set<URL> = []
    /// Media files whose dimensions couldn't be read, with the version that was tried
    var dimensionAttempts: [URL: FileItem.ContentVersion] = [:]
    /// Bumped when the view disappears so in-flight dimension reads stop
    var prefetchGeneration = 0
    /// Identifies the latest tag read (older ones are dropped)
    var tagReadGeneration = 0

    private var lookupSource: [FileItem] = []
    private var itemsByURL: [URL: FileItem] = [:]

    /// The tags of the files that have any (call off the main thread: reads extended attributes
    /// the first time, and warms FileTagManager's cache for everything else that shows tags).
    static func readTags(for urls: [URL]) -> [URL: [String]] {
        var tagsByURL: [URL: [String]] = [:]
        for url in urls {
            let tags = FileTagManager.getTags(for: url)
            if !tags.isEmpty {
                tagsByURL[url] = tags
            }
        }
        return tagsByURL
    }

    /// URL → current item, rebuilt only when the array changes.
    func lookup(for items: [FileItem]) -> [URL: FileItem] {
        if !GridThumbnailLoader.sameStorage(items, lookupSource) {
            lookupSource = items
            itemsByURL = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return itemsByURL
    }
}

/// Spinner shown while Masonry waits for its first layout; it only appears if that takes a moment,
/// so folders that open right away don't flash it.
private struct MasonryLoadingIndicator: View {
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isVisible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                isVisible = true
            }
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
    /// The item's tags, as read by the parent (never read here: that would hit the disk on main)
    let tags: [String]
    @Binding var dropTargetedItemID: UUID?
    let onSelect: (FileItem, Bool) -> Void  // Bool indicates if clicked on text area
    let onDoubleClick: (FileItem) -> Void

    @State private var clickState = ClickStateData()
    @State private var isHovering = false

    private var isSelected: Bool {
        viewModel.selectedItems.contains(item)
    }

    var body: some View {
        let labelPadding: CGFloat = 6
        let usesPreview = thumbnail != nil && !item.isDirectory
        let displayImage = thumbnail ?? item.icon
        let iconSize = min(columnWidth * 0.5, imageHeight * 0.8)

        VStack(alignment: .center, spacing: 6) {
            // Image/icon area - clicks here don't trigger rename
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))

                if usesPreview {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: columnWidth, height: imageHeight)
                        .clipped()
                        .videoPreviewOnHover(item: item, isHovering: $isHovering, size: CGSize(width: columnWidth, height: imageHeight))
                } else {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundColor(.primary)
                        .frame(width: columnWidth, height: imageHeight)
                }

                // Cloud status badge
                if let cloudStatus = item.cloudStatus, cloudStatus.shouldShowBadge {
                    CloudStatusBadgeView(status: cloudStatus, size: 14)
                        .padding(6)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                        .clipShape(Circle())
                }
            }
            .frame(width: columnWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .opacity(dropTargetedItemID == item.id ? 1 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(onTextArea: false)
            }

            // Text/label area - clicks here can trigger rename
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
                .contentShape(Rectangle())
                .onTapGesture {
                    handleTap(onTextArea: true)
                }
            }

            if !tags.isEmpty {
                TagDotsView(tags: tags)
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
        .opacity(viewModel.isItemCut(item) ? 0.5 : 1.0)
        .onHover { hovering in
            isHovering = hovering
        }
        .fileDragItem(item)
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
            item: item,
            viewModel: viewModel,
            dropTargetedItemID: $dropTargetedItemID
        ))
        .contextMenu {
            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                viewModel.renamingURL = item.url
            }
        }
    }

    private func handleTap(onTextArea: Bool) {
        let now = Date()
        let doubleClickThreshold = NSEvent.doubleClickInterval

        // Check if this is a double-click
        if let lastTime = clickState.lastClickTime,
           let lastId = clickState.lastClickId,
           lastId == AnyHashable(item.id),
           now.timeIntervalSince(lastTime) < doubleClickThreshold {
            // Double-click detected
            clickState.lastClickTime = nil
            clickState.lastClickId = nil
            onDoubleClick(item)
        } else {
            // Single click
            clickState.lastClickTime = now
            clickState.lastClickId = AnyHashable(item.id)
            onSelect(item, onTextArea)
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
            thumbnailQuality: Double(settings.thumbnailQualityValue)
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
        private struct PromiseInfo {
            let item: FileItem
            let filename: String
        }

        var viewModel: FileBrowserViewModel
        weak var collectionView: PhotosMasonryCollectionView?
        weak var scrollView: NSScrollView?

        private var items: [FileItem] = []
        private var itemIndexByID: [UUID: Int] = [:]
        /// IDs of `items`, compared in full so changes in the middle are noticed
        private var itemIDs: [UUID]?

        private var iconSize: CGFloat = 80
        private var spacing: CGFloat = 24
        private var fontSize: CGFloat = 12
        private var showFilenames = false
        private var thumbnailQuality: CGFloat = 1.0

        private var targetPixelSize: CGFloat = 256
        private var previousPreheatRect: NSRect = .zero
        private var lastLayoutWidth: CGFloat = 0

        private let thumbnailCache = NSCache<NSString, NSImage>()
        /// Thumbnail requests in flight (key -> start). The view model ignores a request whose key is
        /// already in flight, so entries older than `pendingThumbnailTimeout` are retried.
        private var pendingThumbnailKeys: [String: Date] = [:]
        private let pendingThumbnailTimeout: TimeInterval = 10
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

            let newIDs = items.map(\.id)
            let previousIDs = itemIDs ?? []
            let idsChanged = itemIDs != newIDs

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
                items.count > previousCount &&
                newIDs.starts(with: previousIDs) &&
                (collectionView?.numberOfItems(inSection: 0) ?? previousCount) == previousCount

            if canAppend {
                itemIDs = newIDs
                self.items = items
                for index in previousCount..<items.count {
                    itemIndexByID[items[index].id] = index
                }
                let indexPaths = Set((previousCount..<items.count).map { IndexPath(item: $0, section: 0) })
                collectionView?.insertItems(at: indexPaths)
            } else if forceReload || idsChanged {
                itemIDs = newIDs
                self.items = items
                rebuildIndexMap()
                collectionView?.reloadData()
                resetPreheat()
            } else {
                // Same items; pick up updated metadata
                self.items = items
                if settingsChanged {
                    collectionView?.collectionViewLayout?.invalidateLayout()
                    refreshVisibleItems()
                }
            }

            applySelectionFromViewModel()
            if forceReload || idsChanged || canAppend || settingsChanged {
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
            return min(1536, max(256, bucket))
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
            if let started = pendingThumbnailKeys[cacheKey],
               Date().timeIntervalSince(started) < pendingThumbnailTimeout {
                return nil
            }

            let requestStart = Date()
            pendingThumbnailKeys[cacheKey] = requestStart
            let itemID = item.id
            viewModel.requestPhotoThumbnail(for: item, targetPixelSize: targetPixelSize) { [weak self] image, _ in
                guard let self else { return }
                self.pendingThumbnailKeys.removeValue(forKey: cacheKey)

                if let image {
                    self.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
                }
                self.updateVisibleCell(forItemID: itemID, image: image)
            }

            // If no answer arrives (e.g. a request from a previous coordinator for the same key was
            // still in flight, so this one was dropped), forget the key and ask again.
            DispatchQueue.main.asyncAfter(deadline: .now() + pendingThumbnailTimeout + 0.5) { [weak self] in
                guard let self, self.pendingThumbnailKeys[cacheKey] == requestStart else { return }
                self.pendingThumbnailKeys.removeValue(forKey: cacheKey)
                guard let index = self.itemIndexByID[itemID],
                      let cell = self.collectionView?.item(at: IndexPath(item: index, section: 0)) as? PhotosMasonryItem,
                      self.items.indices.contains(index) else { return }
                self.configure(item: cell, at: IndexPath(item: index, section: 0))
            }

            return nil
        }

        private func updateVisibleCell(forItemID itemID: UUID, image: NSImage?) {
            guard let index = itemIndexByID[itemID] else { return }
            let indexPath = IndexPath(item: index, section: 0)
            guard let cell = collectionView?.item(at: indexPath) as? PhotosMasonryItem else { return }
            cell.updateImage(image)
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

        func openSelection() {
            guard let indexPath = collectionView?.selectionIndexPaths.first,
                  items.indices.contains(indexPath.item) else { return }
            viewModel.openItem(items[indexPath.item])
        }

        func toggleQuickLook() {
            guard let indexPath = collectionView?.selectionIndexPaths.first,
                  items.indices.contains(indexPath.item) else { return }

            let item = items[indexPath.item]
            let window = collectionView?.window
            // Use async version to avoid blocking during archive extraction
            viewModel.previewURL(for: item) { [weak self] previewURL in
                if let previewURL = previewURL {
                    QuickLookControllerView.shared.togglePreview(for: previewURL, in: window) { [weak self] offset in
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
                    QuickLookControllerView.shared.togglePreview(for: url, in: window) { [weak self] offset in
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

            let destinationURL = PhotosDragWriter.destinationURL(forPromisedURL: url, filename: info.filename)
            guard let identifier = photosAssetIdentifier(from: info.item),
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
                  let resource = primaryResource(for: asset) else {
                completionHandler(NSError(domain: "com.coverflowfinder.photos", code: 2))
                return
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            try? FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

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

        /// Shows `item` in an open Quick Look panel, if the panel belongs to this view's window.
        private func updateQuickLook(for item: FileItem?) {
            let previewURL = item.flatMap { viewModel.previewURL(for: $0) }
            QuickLookControllerView.shared.updatePreview(for: previewURL, from: collectionView?.window)
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

/// Where a dragged Photos asset is written for a file promise.
enum PhotosDragWriter {
    /// `promisedURL` is the file the receiver asked for (a folder only if it ends in "/", then
    /// `filename` goes inside it). Nothing already there is ever replaced: the file then gets the
    /// next free name next to it ("IMG_0001 2.HEIC"). A name without an extension is still a file.
    nonisolated static func destinationURL(forPromisedURL promisedURL: URL, filename: String) -> URL {
        let fileURL = promisedURL.hasDirectoryPath
            ? promisedURL.appendingPathComponent(filename, isDirectory: false)
            : promisedURL
        return FileOperationEngine.uniqueDestinationURL(for: fileURL)
    }
}

/// Masonry columns for the Photos library. Each item goes into the shortest column, so appending
/// items never moves the ones already placed: new items are laid out on their own, and only
/// settings, width or reload changes lay everything out again. Rect queries binary-search each
/// column (its items are stacked top to bottom) instead of testing every item.
final class PhotosMasonryLayout: NSCollectionViewLayout {
    var idealColumnWidth: CGFloat = 180 {
        didSet { invalidateEverything() }
    }
    var columnSpacing: CGFloat = 12 {
        didSet { invalidateEverything() }
    }
    var contentInsets: NSEdgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16) {
        didSet { invalidateEverything() }
    }
    var labelHeight: CGFloat = 0 {
        didSet { invalidateEverything() }
    }
    var showsLabels = false {
        didSet { invalidateEverything() }
    }

    var itemHeightProvider: ((IndexPath, CGFloat) -> CGFloat)?

    private(set) var currentColumnWidth: CGFloat = 0
    /// By item index
    private var cachedAttributes: [NSCollectionViewLayoutAttributes] = []
    /// Item indices of each column, top to bottom
    private var columnItems: [[Int]] = []
    private var columnX: [CGFloat] = []
    /// Where the next item of each column goes
    private var columnBottoms: [CGFloat] = []
    private var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat = -1
    /// Set by anything but appended items (settings, reload): lay out every item again
    private var needsFullLayout = true

    private let verticalPadding: CGFloat = 12
    private let labelSpacing: CGFloat = 6

    private func invalidateEverything() {
        needsFullLayout = true
        invalidateLayout()
    }

    override func invalidateLayout(with context: NSCollectionViewLayoutInvalidationContext) {
        // Inserting items only changes the counts; anything else (reloadData, invalidateLayout())
        // may change every item's height
        if context.invalidateEverything || !context.invalidateDataSourceCounts {
            needsFullLayout = true
        }
        super.invalidateLayout(with: context)
    }

    override func prepare() {
        guard let collectionView else { return }
        let width = collectionView.bounds.width
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let isUnchanged = !needsFullLayout && width == preparedWidth
        needsFullLayout = false

        if isUnchanged && itemCount == cachedAttributes.count {
            return
        } else if isUnchanged && itemCount > cachedAttributes.count && !columnBottoms.isEmpty {
            appendItems(upTo: itemCount)
        } else {
            layoutAllItems(width: width, itemCount: itemCount)
        }
    }

    private func layoutAllItems(width: CGFloat, itemCount: Int) {
        preparedWidth = width
        cachedAttributes.removeAll(keepingCapacity: true)
        let metrics = Self.columnMetrics(
            for: width,
            idealColumnWidth: idealColumnWidth,
            spacing: columnSpacing,
            insets: contentInsets
        )
        currentColumnWidth = metrics.width

        guard metrics.count > 0, currentColumnWidth > 0 else {
            columnItems = []
            columnX = []
            columnBottoms = []
            contentHeight = 0
            return
        }
        columnX = (0..<metrics.count).map { contentInsets.left + CGFloat($0) * (currentColumnWidth + columnSpacing) }
        columnBottoms = Array(repeating: contentInsets.top, count: metrics.count)
        columnItems = Array(repeating: [], count: metrics.count)
        appendItems(upTo: itemCount)
    }

    /// Places the items from `cachedAttributes.count` up to `itemCount`.
    private func appendItems(upTo itemCount: Int) {
        let labelStackHeight = showsLabels ? labelHeight + labelSpacing : 0
        for item in cachedAttributes.count..<max(itemCount, cachedAttributes.count) {
            let indexPath = IndexPath(item: item, section: 0)
            let imageHeight = itemHeightProvider?(indexPath, currentColumnWidth) ?? currentColumnWidth
            let itemHeight = imageHeight + labelStackHeight + verticalPadding

            var column = 0
            for candidate in 1..<columnBottoms.count where columnBottoms[candidate] < columnBottoms[column] {
                column = candidate
            }
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
            attributes.frame = NSRect(x: columnX[column], y: columnBottoms[column], width: currentColumnWidth, height: itemHeight)
            cachedAttributes.append(attributes)
            columnItems[column].append(item)
            columnBottoms[column] = attributes.frame.maxY + columnSpacing
        }

        if cachedAttributes.isEmpty {
            contentHeight = contentInsets.top + contentInsets.bottom
        } else {
            contentHeight = (columnBottoms.max() ?? contentInsets.top) - columnSpacing + contentInsets.bottom
        }
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var results: [NSCollectionViewLayoutAttributes] = []
        for items in columnItems {
            // First item that ends below the top of the rect
            var low = 0
            var high = items.count
            while low < high {
                let middle = (low + high) / 2
                if cachedAttributes[items[middle]].frame.maxY <= rect.minY {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            for item in items[low...] {
                let attributes = cachedAttributes[item]
                if attributes.frame.minY >= rect.maxY { break }
                if attributes.frame.intersects(rect) {
                    results.append(attributes)
                }
            }
        }
        return results
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, cachedAttributes.indices.contains(indexPath.item) else { return nil }
        return cachedAttributes[indexPath.item]
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

        titleField.stringValue = item.displayName
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

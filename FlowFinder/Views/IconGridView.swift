import SwiftUI
import AppKit
import Quartz

struct IconGridView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.browserWindow) private var browserWindow
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var internalDragState = InternalDragState.shared
    private var autoScrollState: DragAutoScrollState { DragAutoScrollState.shared }
    let items: [FileItem]
    /// The view model's `itemsRevision` for `items`: FileItem equality is identity, so without it
    /// SwiftUI keeps the old array after in-place updates (iCloud status, metadata).
    var itemsRevision = 0
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
    @StateObject private var tagReader = GridTagReader()
    /// Finder tags of the items that have any, read off the main thread (see `startTagRead`)
    @State private var tagsByURL: [URL: [String]] = [:]
    /// Tile frames for the grid's drop target
    @State private var tileFrames = TileFrameStore()
    private static let gridSpace = "iconGrid"

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
        return min(1024, max(96, bucket))
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
                                thumbnail: thumbnailLoader.image(for: item.url),
                                tags: settings.showItemTags ? tagsByURL[item.url] ?? [] : [],
                                onSingleClick: { clickedOnTextArea in
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
                                },
                                onDoubleClick: {
                                    viewModel.openItem(item)
                                }
                            )
                            .id(item.id)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                                    .opacity(dropTargetedItemID == item.id ? 1 : 0)
                            )
                            .onAppear {
                                thumbnailLoader.tileAppeared(item.url)
                            }
                            .onDisappear {
                                thumbnailLoader.tileDisappeared(item.url)
                            }
                            .onScrollVisibilityChange(threshold: GridThumbnailLoader.onScreenThreshold) { isVisible in
                                thumbnailLoader.setOnScreen(item.url, isVisible)
                            }
                            .fileDragItem(item)
                            .reportsTileFrame(item.url, in: tileFrames, space: Self.gridSpace)
                            .contextMenu {
                                FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                    viewModel.renamingURL = item.url
                                }
                            }
                        }
                    }
                    // Dragging a selected tile drags the whole selection
                    .fileDragContainer(for: viewModel)
                    .padding(20)
                    // Fill remaining space to allow clicking on empty area
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    // Drops onto the grid: the folder tile under the pointer, else this folder
                    .coordinateSpace(name: Self.gridSpace)
                    .onDrop(of: DropHelper.acceptedDropTypes, delegate: TileGridDropDelegate(
                        viewModel: viewModel,
                        item: { [tileFrames, items] point in
                            tileFrames.tile(at: point).flatMap { url in items.first { $0.url == url } }
                        },
                        dropTargetedItemID: $dropTargetedItemID,
                        container: ContainerDropDelegate(
                            viewModel: viewModel,
                            isDropTargeted: $isDropTargeted,
                            containerHeight: currentHeight,
                            items: items,
                            autoScroll: false
                        )
                    ))
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Click on empty space - deselect all and commit/dismiss active rename
                                viewModel.selectedItems.removeAll()
                                viewModel.cancelPendingRename()
                                viewModel.renamingURL = nil
                            }
                    )
                }
                .softTopScrollEdge()
                .onAppear {
                    currentWidth = geometry.size.width
                    currentHeight = geometry.size.height
                    thumbnailLoader.viewModel = viewModel
                    thumbnailLoader.columnCount = columnCount
                    thumbnailLoader.setTargetPixelSize(iconGridThumbnailPixelSize)
                    thumbnailLoader.setItems(items)
                    startTagRead()
                    // Scroll to selected item when view appears (e.g., when switching view modes)
                    if let primary = viewModel.primarySelectedItem {
                        // Use DispatchQueue to ensure layout is complete before scrolling
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo(primary.id, anchor: .center)
                        }
                    }
                }
                .onDisappear {
                    thumbnailLoader.stop()
                    tagReader.cancel()
                    autoScrollTimer?.invalidate()
                    autoScrollTimer = nil
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    currentWidth = newWidth
                    thumbnailLoader.columnCount = columnCount
                }
                .onChange(of: viewModel.selectedItems) { _, _ in
                    guard let primary = viewModel.primarySelectedItem else {
                        updateQuickLook(for: nil)
                        return
                    }
                    // Only scroll when the lead item isn't already on screen (e.g. after a delete
                    // the next item is usually visible and the grid should stay put).
                    if !thumbnailLoader.isOnScreen(primary.url) {
                        withAnimation {
                            scrollProxy.scrollTo(primary.id)
                        }
                    }
                    updateQuickLook(for: primary)
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
                                    scrollProxy.scrollTo(currentItems[targetIndex].id, anchor: direction == .up ? .top : .bottom)
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
        .dropTargetOverlay(isTargeted: isDropTargeted && !internalDragState.isDragging, padding: UI.Spacing.standard)
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
        .onChange(of: items) { _, newItems in
            // Keeps thumbnails of items that remain, drops removed ones and reloads around
            // the visible tiles.
            thumbnailLoader.setItems(newItems)
            startTagRead()
        }
        .onChange(of: settings.showItemTags) { _, _ in
            startTagRead()
        }
        // Tags edited here or elsewhere (the cache entries were dropped): read them again
        .onChange(of: viewModel.tagRefreshToken) { _, _ in
            startTagRead()
        }
        .onChange(of: items.map(\.contentVersion)) { _, _ in
            // Metadata/in-place edits: reload the thumbnails whose file version changed
            thumbnailLoader.setItems(items)
        }
        .onChange(of: settings.thumbnailQuality) { _, _ in
            thumbnailLoader.setTargetPixelSize(iconGridThumbnailPixelSize)
        }
        .onChange(of: settings.iconGridIconSize) { _, _ in
            thumbnailLoader.setTargetPixelSize(iconGridThumbnailPixelSize)
            thumbnailLoader.columnCount = columnCount
        }
        .onChange(of: settings.iconGridSpacing) { _, _ in
            thumbnailLoader.columnCount = columnCount
        }
        .keyboardNavigable(
            onUpArrow: { shift in navigateSelection(by: -columnCount, extend: shift) },
            onDownArrow: { shift in navigateSelection(by: columnCount, extend: shift) },
            onLeftArrow: { shift in navigateSelection(by: -1, extend: shift) },
            onRightArrow: { shift in navigateSelection(by: 1, extend: shift) },
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

    /// Reads the items' tags in the background; tiles show them once they arrive.
    private func startTagRead() {
        guard settings.showItemTags else { return }
        tagReader.read(items) { tags in
            if tags != tagsByURL {
                tagsByURL = tags
            }
        }
    }

    private func navigateSelection(by offset: Int, extend: Bool = false) {
        guard !items.isEmpty else { return }

        // When extending selection, use lastSelectedIndex to track the moving end
        // of the range. Using selectedItems.first would pick an arbitrary item from
        // the Set, causing the cursor to jump around during shift+arrow.
        let currentIndex: Int
        if extend {
            currentIndex = viewModel.lastSelectedIndex
        } else if let selected = viewModel.primarySelectedItem,
                  let idx = items.firstIndex(of: selected) {
            currentIndex = idx
        } else {
            currentIndex = viewModel.lastSelectedIndex
        }
        let clampedCurrentIndex = max(0, min(items.count - 1, currentIndex))
        let newIndex = max(0, min(items.count - 1, clampedCurrentIndex + offset))
        guard newIndex != clampedCurrentIndex || viewModel.selectedItems.isEmpty else { return }

        if extend {
            viewModel.selectRange(to: newIndex, in: items)
        } else {
            let newItem = items[newIndex]
            viewModel.selectItem(newItem)
            viewModel.lastSelectedIndex = newIndex
            viewModel.selectionAnchorIndex = newIndex
        }

        // Refresh Quick Look if visible
        updateQuickLook(for: items[newIndex])
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
        if let matchIndex = items.firstIndex(where: { $0.displayName.lowercased().hasPrefix(lowercased) }) {
            let matchItem = items[matchIndex]
            viewModel.selectItem(matchItem)
            viewModel.lastSelectedIndex = matchIndex
            viewModel.selectionAnchorIndex = matchIndex
            updateQuickLook(for: matchItem)
        }
    }

    private func toggleQuickLook() {
        viewModel.toggleQuickLookForSelection(in: browserWindow?.window) { [self] offset in
            navigateSelection(by: offset)
        }
    }

    private func updateQuickLook(for item: FileItem?) {
        viewModel.updateQuickLookPreview(for: item, in: browserWindow?.window)
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
    /// The item's tags, as read by the grid (never read here: that would hit the disk on main)
    let tags: [String]
    let onSingleClick: (Bool) -> Void  // Bool indicates if clicked on text area
    let onDoubleClick: () -> Void

    @State private var isHovering = false
    @State private var clickState = ClickStateData()

    private var displayImage: NSImage {
        thumbnail ?? item.icon
    }

    var body: some View {
        let iconSize = appSettings.iconGridIconSizeValue
        let backgroundSize = iconSize + 10
        let labelWidth = iconSize + 20

        VStack(spacing: 8) {
            // Icon area - clicks here don't trigger rename
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .frame(width: backgroundSize, height: backgroundSize)

                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
                    .cornerRadius(4)
                    .videoPreviewOnHover(item: item, isHovering: $isHovering, size: CGSize(width: iconSize, height: iconSize))
            }
            .overlay(alignment: .bottomTrailing) {
                // Cloud status badge
                if let cloudStatus = item.cloudStatus, cloudStatus.shouldShowBadge {
                    CloudStatusBadgeView(status: cloudStatus, size: 12)
                        .padding(2)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                        .clipShape(Circle())
                        .offset(x: 4, y: 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(onTextArea: false)
            }

            // Text/label area - clicks here can trigger rename
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

                if !tags.isEmpty {
                    TagDotsView(tags: tags)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(onTextArea: true)
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
            onDoubleClick()
        } else {
            // Single click
            clickState.lastClickTime = now
            clickState.lastClickId = AnyHashable(item.id)
            onSingleClick(onTextArea)
        }
    }
}

// MARK: - Grid Tag Reader

/// Reads the Finder tags of grid items off the main thread: the first read of a file's tags hits
/// its extended attributes, which is slow on network volumes. Only the latest read is delivered.
@MainActor
final class GridTagReader: ObservableObject {
    private var generation = 0

    /// Calls `completion` on the main thread with the tags of the items that have any.
    func read(_ items: [FileItem], completion: @escaping @MainActor ([URL: [String]]) -> Void) {
        generation += 1
        let current = generation
        let urls = items.filter { !$0.isFromArchive && $0.url.isFileURL }.map(\.url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tags = MasonryRuntime.readTags(for: urls)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    completion(tags)
                }
            }
        }
    }

    /// Drops the read in progress.
    func cancel() {
        generation += 1
    }
}

// MARK: - Grid Thumbnail Loader

/// Thumbnail loading for the scrolling grids (Icon grid, Masonry).
///
/// - Tracks which tiles exist (`tileAppeared`) and which are really on screen (`setOnScreen`).
/// - Around the visible tiles it hydrates metadata, keeps thumbnails for a small window and
///   preloads further ahead into `ThumbnailCacheManager` (whose NSCache holds the rest).
/// - Publishes arrivals at most once per runloop turn, and never for scroll bookkeeping.
/// - Reloads a thumbnail when the target size grows (zoom, resize, quality) or the file changes.
@MainActor
final class GridThumbnailLoader: ObservableObject {
    struct Thumbnail {
        let image: NSImage
        /// The size it was requested at (the image may be smaller if the source is).
        let pixelSize: CGFloat
        /// File version it was made from; nil when unknown (no metadata yet).
        let version: ThumbnailFileVersion?
        let isFallback: Bool
    }

    /// Fraction of a tile that must be visible to count as on screen.
    static let onScreenThreshold: Double = 0.9

    @Published private(set) var thumbnails: [URL: Thumbnail] = [:]

    weak var viewModel: FileBrowserViewModel?
    /// Load Photos-library items through the view model (Masonry).
    var loadsPhotosAssets = false
    var columnCount = 1
    private(set) var items: [FileItem] = []
    private(set) var targetPixelSize: CGFloat = 256

    private let cache: ThumbnailCacheManager
    private let owner = ThumbnailRequestOwner()
    private var indexByURL: [URL: Int] = [:]

    private var realizedURLs: Set<URL> = []
    private var onScreenURLs: Set<URL> = []
    private(set) var isScrolling = false
    private var scrollEndTimer: Timer?

    private struct Request {
        let pixelSize: CGFloat
        let version: ThumbnailFileVersion?
        let token: ThumbnailRequestToken?
        let startedAt: Date
    }
    private var inFlight: [URL: Request] = [:]
    /// Preloaded into the shared cache (outside the kept window) at this size/version.
    private var warmed: [URL: (pixelSize: CGFloat, version: ThumbnailFileVersion?)] = [:]
    private var keepRange: Range<Int> = 0..<0

    private var pendingUpdates: [URL: Thumbnail?] = [:]
    private var publishScheduled = false
    private var hydrationScheduled = false
    private var hydrationDeadline = Date.distantPast
    private var isActive = true

    init(cache: ThumbnailCacheManager = .shared) {
        self.cache = cache
    }

    deinit {
        scrollEndTimer?.invalidate()
    }

    func image(for url: URL) -> NSImage? {
        thumbnails[url]?.image
    }

    func index(of url: URL) -> Int? {
        indexByURL[url]
    }

    func isOnScreen(_ url: URL) -> Bool {
        onScreenURLs.contains(url)
    }

    /// Lowest and highest index among the tiles that currently exist.
    func visibleIndexBounds() -> ClosedRange<Int>? {
        let indices = realizedURLs.compactMap { indexByURL[$0] }
        guard let low = indices.min(), let high = indices.max() else { return nil }
        return low...high
    }

    // MARK: Inputs

    func setItems(_ newItems: [FileItem]) {
        isActive = true
        if Self.sameStorage(newItems, items) { return }

        items = newItems
        var newIndex: [URL: Int] = [:]
        newIndex.reserveCapacity(newItems.count)
        for (index, item) in newItems.enumerated() where newIndex[item.url] == nil {
            newIndex[item.url] = index
        }
        let removed = indexByURL.keys.filter { newIndex[$0] == nil }
        indexByURL = newIndex

        if !removed.isEmpty {
            for url in removed {
                if let token = inFlight.removeValue(forKey: url)?.token {
                    cache.cancel(token)
                }
                warmed.removeValue(forKey: url)
                realizedURLs.remove(url)
                onScreenURLs.remove(url)
                if thumbnails[url] != nil {
                    pendingUpdates[url] = .some(nil)
                }
            }
            schedulePublish()
        }
        // Remaining tiles keep their thumbnails; the pass reloads changed files and new items.
        scheduleHydration(after: 0)
    }

    func setTargetPixelSize(_ size: CGFloat) {
        guard abs(size - targetPixelSize) >= 8 else { return }
        targetPixelSize = size
        scheduleHydration(after: 0)
    }

    func tileAppeared(_ url: URL) {
        realizedURLs.insert(url)
        markScrolling()
        scheduleHydration(after: isScrolling ? 0.1 : 0.02)
    }

    func tileDisappeared(_ url: URL) {
        realizedURLs.remove(url)
        onScreenURLs.remove(url)
        markScrolling()
        scheduleHydration(after: isScrolling ? 0.1 : 0.02)
    }

    func setOnScreen(_ url: URL, _ isOnScreen: Bool) {
        if isOnScreen {
            onScreenURLs.insert(url)
        } else {
            onScreenURLs.remove(url)
        }
    }

    /// Cancel outstanding work (view disappeared). `setItems` resumes.
    func stop() {
        isActive = false
        scrollEndTimer?.invalidate()
        scrollEndTimer = nil
        cache.cancelRequests(for: owner)
        inFlight.removeAll()
    }

    // MARK: Scheduling

    private func markScrolling() {
        if !isScrolling {
            isScrolling = true
        }
        // Reuse one timer: push its fire date out while tiles keep appearing.
        let fireDate = Date().addingTimeInterval(0.15)
        if let timer = scrollEndTimer, timer.isValid {
            timer.fireDate = fireDate
            return
        }
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollEndTimer = nil
                self.isScrolling = false
                // Final, wider pass once scrolling stops
                self.scheduleHydration(after: 0)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollEndTimer = timer
    }

    /// Debounced: one pending block; later calls only move the deadline.
    private func scheduleHydration(after delay: TimeInterval) {
        hydrationDeadline = Date().addingTimeInterval(delay)
        guard !hydrationScheduled else { return }
        hydrationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.hydrationTimerFired()
        }
    }

    private func hydrationTimerFired() {
        let remaining = hydrationDeadline.timeIntervalSinceNow
        if remaining > 0.001 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.hydrationTimerFired()
            }
            return
        }
        hydrationScheduled = false
        runHydrationPass()
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.publish()
        }
    }

    /// One @Published write for everything that arrived since the last turn.
    private func publish() {
        publishScheduled = false
        guard !pendingUpdates.isEmpty else { return }
        var updated = thumbnails
        for (url, thumbnail) in pendingUpdates {
            if let thumbnail, let index = indexByURL[url], keepRange.contains(index) {
                updated[url] = thumbnail
            } else if thumbnail == nil {
                updated.removeValue(forKey: url)
            }
        }
        pendingUpdates.removeAll()
        thumbnails = updated
    }

    // MARK: Hydration pass

    private func currentVersion(of item: FileItem) -> ThumbnailFileVersion? {
        guard item.hasMetadata, item.modificationDate != nil else { return nil }
        return cache.fileVersion(for: item)
    }

    private func isOutdated(pixelSize: CGFloat, version: ThumbnailFileVersion?, isFallback: Bool, for item: FileItem) -> Bool {
        let current = currentVersion(of: item)
        if let current, let version, current != version {
            return true
        }
        // A fallback icon doesn't get better at a larger size.
        return !isFallback && pixelSize + 0.5 < targetPixelSize
    }

    private func runHydrationPass() {
        guard isActive, !items.isEmpty else { return }
        guard let visible = visibleIndexBounds() else { return }

        let scrolling = isScrolling
        let visibleCount = visible.count
        let preloadBuffer = scrolling ? max(12, columnCount * 3) : max(80, visibleCount * 4)
        let keepBuffer = max(24, columnCount * 4, visibleCount)
        let range = max(0, visible.lowerBound - preloadBuffer)..<min(items.count, visible.upperBound + preloadBuffer + 1)
        keepRange = max(0, visible.lowerBound - keepBuffer)..<min(items.count, visible.upperBound + keepBuffer + 1)

        // Hydrate metadata for items in range
        if let viewModel {
            var urlsToHydrate: [URL] = []
            for index in range where viewModel.needsHydration(items[index]) {
                urlsToHydrate.append(items[index].url)
            }
            if !urlsToHydrate.isEmpty {
                viewModel.hydrateMetadata(for: urlsToHydrate)
            }
        }

        // Visible tiles first, then outward
        let maxLoadsPerPass = scrolling ? 8 : 48
        var loadCount = 0
        var hasMoreToLoad = false
        for index in Self.centerOut(range, around: visible) {
            let item = items[index]
            guard !item.isDirectory else { continue }
            let url = item.url
            let inKeepWindow = keepRange.contains(index)

            if let request = inFlight[url] {
                // Photos requests have no token; the view model may drop duplicates, so retry stale ones.
                let isStale = request.token == nil && Date().timeIntervalSince(request.startedAt) > 10
                if !isStale && !isOutdated(pixelSize: request.pixelSize, version: request.version, isFallback: false, for: item) {
                    continue
                }
            } else if inKeepWindow {
                if let shown = displayedThumbnail(for: url),
                   !isOutdated(pixelSize: shown.pixelSize, version: shown.version, isFallback: shown.isFallback, for: item) {
                    continue
                }
                // Already in the shared memory cache: show it without a request
                if let cached = cache.cachedThumbnail(for: item, maxPixelSize: targetPixelSize) {
                    stage(url, Thumbnail(image: cached, pixelSize: targetPixelSize, version: currentVersion(of: item), isFallback: false))
                    continue
                }
            } else if let warm = warmed[url],
                      !isOutdated(pixelSize: warm.pixelSize, version: warm.version, isFallback: false, for: item) {
                continue
            }

            guard loadCount < maxLoadsPerPass else {
                hasMoreToLoad = true
                continue
            }
            loadCount += 1
            load(item)
        }

        // Keep only a window of images around the visible tiles; the shared cache has the rest.
        for url in thumbnails.keys where !(indexByURL[url].map(keepRange.contains) ?? false) {
            pendingUpdates[url] = .some(nil)
        }
        // Stop work for items scrolled far away.
        let abandoned = inFlight.filter { !(indexByURL[$0.key].map(range.contains) ?? false) }
        for (url, request) in abandoned {
            inFlight.removeValue(forKey: url)
            if let token = request.token {
                cache.cancel(token)
            }
        }
        if warmed.count > 4 * max(range.count, 100) {
            warmed = warmed.filter { indexByURL[$0.key].map(range.contains) ?? false }
        }
        if !pendingUpdates.isEmpty {
            schedulePublish()
        }

        // If not scrolling and there are more items to load, schedule another pass
        if hasMoreToLoad && !isScrolling {
            scheduleHydration(after: 0.05)
        }
    }

    private func stage(_ url: URL, _ thumbnail: Thumbnail) {
        pendingUpdates[url] = .some(thumbnail)
        schedulePublish()
    }

    /// What the tile shows (or will show after the pending publish).
    private func displayedThumbnail(for url: URL) -> Thumbnail? {
        if let pending = pendingUpdates[url] {
            return pending
        }
        return thumbnails[url]
    }

    private func load(_ item: FileItem) {
        let url = item.url
        let pixelSize = targetPixelSize
        let version = currentVersion(of: item)

        if let previous = inFlight.removeValue(forKey: url), let token = previous.token {
            cache.cancel(token)
        }

        if loadsPhotosAssets, let viewModel, viewModel.isPhotosItem(item) {
            inFlight[url] = Request(pixelSize: pixelSize, version: nil, token: nil, startedAt: Date())
            // Opportunistic delivery may call back twice (degraded, then final).
            viewModel.requestPhotoThumbnail(for: item, targetPixelSize: pixelSize) { [weak self] image, _ in
                guard let self else { return }
                if let request = self.inFlight[url] {
                    guard request.token == nil, request.pixelSize == pixelSize else { return }
                    self.inFlight.removeValue(forKey: url)
                }
                guard self.indexByURL[url] != nil else { return }
                self.stage(url, Thumbnail(image: image ?? item.icon, pixelSize: pixelSize, version: nil, isFallback: image == nil))
            }
            return
        }

        var completedSynchronously = false
        // Completions arrive on the main queue (or synchronously, right here)
        let token = cache.requestThumbnail(for: item, maxPixelSize: pixelSize, owner: owner) { [weak self] result in
            MainActor.assumeIsolated {
                completedSynchronously = true
                self?.handle(result, for: item, pixelSize: pixelSize, version: version)
            }
        }
        if let token, !completedSynchronously {
            inFlight[url] = Request(pixelSize: pixelSize, version: version, token: token, startedAt: Date())
        }
    }

    private func handle(_ result: ThumbnailRequestResult, for item: FileItem, pixelSize: CGFloat, version: ThumbnailFileVersion?) {
        let url = item.url
        if let request = inFlight[url] {
            // A newer request (bigger size, new version) replaced this one
            guard request.pixelSize == pixelSize, request.version == version else { return }
            inFlight.removeValue(forKey: url)
        }
        guard indexByURL[url] != nil else { return }

        switch result {
        case .loaded(let image):
            warmed[url] = (pixelSize, version)
            stage(url, Thumbnail(image: image, pixelSize: pixelSize, version: version, isFallback: false))
        case .failed:
            warmed[url] = (pixelSize, version)
            stage(url, Thumbnail(image: item.icon, pixelSize: pixelSize, version: version, isFallback: true))
        case .cancelled:
            // Retried by a later pass if it's still needed
            break
        }
    }

    // MARK: Helpers

    /// Indices of `range`, starting with `center` and moving outward.
    nonisolated static func centerOut(_ range: Range<Int>, around center: ClosedRange<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        let low = max(range.lowerBound, min(center.lowerBound, range.upperBound - 1))
        let high = min(range.upperBound - 1, max(center.upperBound, low))
        var result = Array(low...high)
        result.reserveCapacity(range.count)
        var below = low - 1
        var above = high + 1
        while below >= range.lowerBound || above < range.upperBound {
            if above < range.upperBound {
                result.append(above)
                above += 1
            }
            if below >= range.lowerBound {
                result.append(below)
                below -= 1
            }
        }
        return result
    }

    /// Cheap "same array" test: a changed array never shares storage with the one we keep.
    nonisolated static func sameStorage(_ lhs: [FileItem], _ rhs: [FileItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.isEmpty { return true }
        return lhs.withUnsafeBufferPointer { a in
            rhs.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
        }
    }
}

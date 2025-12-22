import SwiftUI
import QuickLookThumbnailing
import AppKit
import Quartz

struct CoverFlowView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var sortedItemsCache: [FileItem] = []
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var iconPlaceholders: Set<URL> = []
    @State private var thumbnailLoadGeneration: Int = 0
    @State private var rightClickedIndex: Int?
    @State private var isCoverFlowScrolling: Bool = false
    @State private var dragStartCoverFlowHeight: CGFloat?
    @State private var liveCoverFlowHeight: CGFloat?
    @State private var infoPanelHeight: CGFloat = 0

    @State private var lastThumbnailLoadTime: Date = .distantPast
    @State private var thumbnailLoadTimer: Timer?
    private let thumbnailLoadThrottle: TimeInterval = 0.016
    @State private var lastHydrationRange: Range<Int>? = nil
    @State private var itemsToken: Int = 0

    // Pending thumbnail updates - batched to reduce re-renders
    @State private var pendingThumbnailUpdates: [URL: NSImage] = [:]
    @State private var thumbnailBatchTimer: Timer?
    private let thumbnailBatchInterval: TimeInterval = 0.1

    // Debug logging (set to false for release)
    private static var debugEnabled = false
    private static var lastBodyTime: Date = .distantPast
    private static var bodyCallCount = 0
    private static let debugLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("flowfinder_debug.log")
    private static var debugLogHandle: FileHandle? = {
        FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
        return try? FileHandle(forWritingTo: debugLogURL)
    }()

    static func debugLog(_ message: String) {
        guard debugEnabled else { return }
        let line = "\(Date()): \(message)\n"
        if let data = line.data(using: .utf8) {
            debugLogHandle?.write(data)
        }
    }

    private func logBodyCall() {
        guard Self.debugEnabled else { return }
        Self.bodyCallCount += 1
        let now = Date()
        let interval = now.timeIntervalSince(Self.lastBodyTime)
        Self.lastBodyTime = now
        if interval < 0.5 {
            Self.debugLog("[CoverFlow] BODY #\(Self.bodyCallCount) - \(String(format: "%.3f", interval))s | thumbs:\(thumbnails.count) pending:\(pendingThumbnailUpdates.count) items:\(sortedItemsCache.count)")
        }
    }

    private var coverFlowThumbnailPixelSize: CGFloat {
        let base = 192 * settings.coverFlowScaleValue * settings.thumbnailQualityValue
        let bucket = (base / 64).rounded() * 64
        return min(768, max(128, bucket))
    }

    private var coverFlowPlaceholderPixelSize: CGFloat {
        let base = coverFlowThumbnailPixelSize * 0.5
        let bucket = (base / 32).rounded() * 32
        return min(256, max(96, bucket))
    }

    private let visibleRange = 12
    private let maxConcurrentThumbnails = 24
    private let maxConcurrentPreloadThumbnails = 16
    private let preloadRangeMultiplier = 8
    private let thumbnailCache = ThumbnailCacheManager.shared

    var body: some View {
        let _ = logBodyCall()
        GeometryReader { geometry in
            let handleHeight: CGFloat = 8
            let minCoverFlowHeight: CGFloat = 250
            let minListHeight: CGFloat = 160
            let infoHeight = settings.coverFlowShowInfo ? infoPanelHeight : 0
            let maxCoverFlowHeight = max(0, geometry.size.height - infoHeight - handleHeight - minListHeight)
            let defaultCoverFlowHeight = max(minCoverFlowHeight, geometry.size.height * 0.45)
            let storedCoverFlowHeight = settings.coverFlowPaneHeight > 0
                ? CGFloat(settings.coverFlowPaneHeight)
                : defaultCoverFlowHeight
            let activeCoverFlowHeight = liveCoverFlowHeight ?? storedCoverFlowHeight
            let coverFlowHeight: CGFloat = {
                if maxCoverFlowHeight < minCoverFlowHeight {
                    return maxCoverFlowHeight
                }
                return min(max(activeCoverFlowHeight, minCoverFlowHeight), maxCoverFlowHeight)
            }()

            VStack(spacing: 0) {
                CoverFlowContainer(
                    items: sortedItemsCache,
                    itemsToken: itemsToken,
                    selectedIndex: $viewModel.coverFlowSelectedIndex,
                    thumbnails: thumbnails,
                    thumbnailCount: thumbnails.count,
                    navigationGeneration: viewModel.navigationGeneration,
                    selectedItems: viewModel.selectedItems,
                    coverScale: settings.coverFlowScaleValue,
                    scrollSensitivity: settings.coverFlowSwipeSpeedValue,
                    onSelect: { index in
                        viewModel.coverFlowSelectedIndex = index
                        if index < sortedItemsCache.count {
                            let item = sortedItemsCache[index]
                            let modifiers = NSEvent.modifierFlags
                            viewModel.handleSelection(
                                item: item,
                                index: index,
                                in: sortedItemsCache,
                                withShift: modifiers.contains(.shift),
                                withCommand: modifiers.contains(.command)
                            )
                            updateQuickLook(for: item)
                        }
                    },
                    onOpen: { index in
                        if index < sortedItemsCache.count {
                            viewModel.openItem(sortedItemsCache[index])
                        }
                    },
                    onRightClick: { index in
                        rightClickedIndex = index
                    },
                    onDrop: { urls in
                        handleDrop(urls: urls)
                    },
                    onDropToFolder: { urls, folderURL in
                        viewModel.handleDrop(urls: urls, to: folderURL)
                    },
                    onScrollStateChange: { scrolling in
                        DispatchQueue.main.async {
                            isCoverFlowScrolling = scrolling
                            if !scrolling {
                                throttledLoadThumbnails()
                            }
                        }
                    },
                    onCopy: {
                        viewModel.copySelectedItems()
                    },
                    onCut: {
                        viewModel.cutSelectedItems()
                    },
                    onPaste: {
                        viewModel.paste()
                    },
                    onDelete: {
                        viewModel.deleteSelectedItems()
                    },
                    onQuickLook: { item in
                        viewModel.previewURL(for: item) { previewURL in
                            guard let previewURL = previewURL else {
                                NSSound.beep()
                                return
                            }
                            QuickLookControllerView.shared.togglePreview(for: previewURL) { offset in
                                navigateSelection(by: offset)
                            }
                        }
                    }
                )
                .id("coverFlowContainer")  // Stable identity to prevent view recreation
                .frame(height: coverFlowHeight)

                if settings.coverFlowShowInfo,
                   !sortedItemsCache.isEmpty,
                   viewModel.coverFlowSelectedIndex < sortedItemsCache.count {
                    let selectedItem = sortedItemsCache[viewModel.coverFlowSelectedIndex]
                    VStack(spacing: 4) {
                        Text(selectedItem.displayName(showFileExtensions: settings.showFileExtensions))
                            .font(settings.coverFlowTitleFont)
                            .lineLimit(1)
                        HStack(spacing: 16) {
                            if !selectedItem.isDirectory {
                                Text(selectedItem.formattedSize)
                                    .foregroundColor(.secondary)
                            }
                            Text(selectedItem.formattedDate)
                                .foregroundColor(.secondary)
                        }
                        .font(settings.coverFlowDetailFont)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: CoverFlowInfoHeightKey.self, value: proxy.size.height)
                        }
                    )
                }

                CoverFlowResizeHandle(
                    height: handleHeight,
                    onDrag: { delta in
                        updateCoverFlowHeight(
                            delta: delta,
                            currentHeight: coverFlowHeight,
                            minHeight: minCoverFlowHeight,
                            maxHeight: maxCoverFlowHeight
                        )
                    },
                    onDragEnded: {
                        if let liveHeight = liveCoverFlowHeight {
                            settings.coverFlowPaneHeight = Double(liveHeight)
                        }
                        liveCoverFlowHeight = nil
                        dragStartCoverFlowHeight = nil
                    }
                )

                FileListSection(
                    items: sortedItemsCache,
                    selectedItems: viewModel.selectedItems,
                    onSelect: { item, index in
                        viewModel.coverFlowSelectedIndex = index
                        updateQuickLook(for: item)
                    },
                    onOpen: { item in
                        viewModel.openItem(item)
                    },
                    viewModel: viewModel
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            KeyboardManager.shared.clearHandler()
            updateSortedItems(using: items, updateToken: true)
            loadVisibleThumbnails()
            syncSelection()
        }
        .onDisappear {
            thumbnailLoadTimer?.invalidate()
            thumbnailLoadTimer = nil
            thumbnailBatchTimer?.invalidate()
            thumbnailBatchTimer = nil
        }
        .onChange(of: items) { newItems in
            let oldCount = sortedItemsCache.count
            let newCount = newItems.count
            let oldToken = itemsToken
            let newToken = itemsTokenFor(newItems)
            let oldOrder = sortedItemsCache.map { $0.url }
            let newOrder = newItems.map { $0.url }
            let orderChanged = oldOrder != newOrder
            let tokenChanged = oldToken != newToken
            Self.debugLog("[CoverFlow] onChange(items) FIRED! old:\(oldCount) new:\(newCount) oldToken:\(oldToken) newToken:\(newToken) tokenMatch:\(oldToken == newToken)")

            // Only clear thumbnails if items actually changed
            if tokenChanged {
                Self.debugLog("[CoverFlow] Items actually changed - clearing thumbnails")
                DispatchQueue.main.async {
                    thumbnails.removeAll()
                    iconPlaceholders.removeAll()
                    thumbnailLoadGeneration += 1
                    thumbnailCache.clearForNewFolder()
                    updateSortedItems(using: newItems, updateToken: true)
                    loadVisibleThumbnails()
                    syncSelection()
                }
            } else {
                Self.debugLog("[CoverFlow] Items unchanged (same token) - skipping clear")
                DispatchQueue.main.async {
                    updateSortedItems(using: newItems, updateToken: false)
                    if orderChanged {
                        loadVisibleThumbnails()
                    }
                    syncSelection()
                }
            }
        }
        .onReceive(viewModel.$items) { _ in
            let newItems = viewModel.filteredItems
            guard newItems.count == sortedItemsCache.count else { return }

            let oldURLs = Set(sortedItemsCache.map { $0.url })
            let newURLs = Set(newItems.map { $0.url })
            guard oldURLs == newURLs else { return }

            let oldOrder = sortedItemsCache.map { $0.url }
            let newOrder = newItems.map { $0.url }
            let orderChanged = oldOrder != newOrder
            DispatchQueue.main.async {
                updateSortedItems(using: newItems, updateToken: false)
                if orderChanged {
                    loadVisibleThumbnails()
                }
                syncSelection()
            }
        }
        .onChange(of: viewModel.coverFlowSelectedIndex) { _ in
            DispatchQueue.main.async {
                throttledLoadThumbnails()
                updateQuickLookForSelection()
            }
        }
        .onChange(of: viewModel.selectedItems) { _ in
            // Sync Cover Flow selection when file list selection changes
            syncSelection()
        }
        .onPreferenceChange(CoverFlowInfoHeightKey.self) { newValue in
            if newValue > 0 {
                infoPanelHeight = newValue
            }
        }
        .onChange(of: settings.coverFlowScale) { _ in
            throttledLoadThumbnails()
        }
        .onChange(of: settings.thumbnailQuality) { _ in
            throttledLoadThumbnails()
        }
    }

    private func throttledLoadThumbnails() {
        let now = Date()
        let timeSinceLastLoad = now.timeIntervalSince(lastThumbnailLoadTime)

        if timeSinceLastLoad >= thumbnailLoadThrottle {
            lastThumbnailLoadTime = now
            loadVisibleThumbnails()
        } else {
            thumbnailLoadTimer?.invalidate()
            let delay = thumbnailLoadThrottle - timeSinceLastLoad
            thumbnailLoadTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                DispatchQueue.main.async {
                    self.lastThumbnailLoadTime = Date()
                    self.loadVisibleThumbnails()
                }
            }
        }
    }

    private func updateSortedItems(using newItems: [FileItem], updateToken: Bool) {
        sortedItemsCache = newItems
        if updateToken {
            itemsToken = itemsTokenFor(newItems)
        }
        if let selected = viewModel.selectedItems.first,
           let index = newItems.firstIndex(of: selected) {
            viewModel.coverFlowSelectedIndex = index
        } else {
            viewModel.coverFlowSelectedIndex = min(viewModel.coverFlowSelectedIndex, max(0, newItems.count - 1))
        }
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
        let result = hasher.finalize()
        return result
    }

    private func logTokenState(_ context: String) {
        if Self.debugEnabled {
            Self.debugLog("[CoverFlow] TOKEN \(context): itemsToken=\(itemsToken), items=\(sortedItemsCache.count)")
        }
    }

    private func syncSelection() {
        guard !sortedItemsCache.isEmpty && viewModel.coverFlowSelectedIndex < sortedItemsCache.count else { return }
        if let selected = viewModel.selectedItems.first,
           let index = sortedItemsCache.firstIndex(of: selected) {
            viewModel.coverFlowSelectedIndex = index
        } else if viewModel.selectedItems.isEmpty {
            let item = sortedItemsCache[viewModel.coverFlowSelectedIndex]
            viewModel.selectedItems = [item]
            updateQuickLook(for: item)
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

    private func updateQuickLookForSelection() {
        guard !sortedItemsCache.isEmpty else {
            QuickLookControllerView.shared.updatePreview(for: nil)
            return
        }
        let index = min(max(0, viewModel.coverFlowSelectedIndex), sortedItemsCache.count - 1)
        updateQuickLook(for: sortedItemsCache[index])
    }

    private func navigateSelection(by offset: Int) {
        guard !sortedItemsCache.isEmpty else { return }

        let currentIndex = min(max(0, viewModel.coverFlowSelectedIndex), sortedItemsCache.count - 1)
        let newIndex = max(0, min(sortedItemsCache.count - 1, currentIndex + offset))
        guard newIndex != currentIndex else { return }

        viewModel.coverFlowSelectedIndex = newIndex
        let item = sortedItemsCache[newIndex]
        viewModel.selectItem(item)
        updateQuickLook(for: item)
    }

    private func handleDrop(urls: [URL]) {
        viewModel.handleDrop(urls: urls)
    }

    private let thumbnailWindowSize = 100

    private static var loadVisibleCount = 0

    private func loadVisibleThumbnails() {
        guard !sortedItemsCache.isEmpty else { return }
        Self.loadVisibleCount += 1
        if Self.debugEnabled {
            Self.debugLog("[CoverFlow] loadVisibleThumbnails #\(Self.loadVisibleCount) - items:\(sortedItemsCache.count) scrolling:\(isCoverFlowScrolling)")
        }
        // Allow limited loading during scroll for smoother experience
        let isScrolling = isCoverFlowScrolling
        let thumbnailPixelSize = coverFlowThumbnailPixelSize
        let placeholderPixelSize = coverFlowPlaceholderPixelSize
        let selected = min(max(0, viewModel.coverFlowSelectedIndex), sortedItemsCache.count - 1)
        let start = max(0, selected - visibleRange)
        let end = min(sortedItemsCache.count - 1, selected + visibleRange)
        guard start <= end else { return }

        var thumbnailUpdates: [URL: NSImage] = [:]
        var placeholdersToAdd: Set<URL> = []
        var placeholdersToRemove: Set<URL> = []
        var itemsToLoadHigh: [(item: FileItem, distance: Int)] = []
        var itemsToLoadLow: [(item: FileItem, distance: Int)] = []

        let windowStart = max(0, selected - thumbnailWindowSize)
        let windowEnd = min(sortedItemsCache.count - 1, selected + thumbnailWindowSize)
        let preloadRange = min(visibleRange * preloadRangeMultiplier, thumbnailWindowSize)
        let preloadStart = max(0, selected - preloadRange)
        let preloadEnd = min(sortedItemsCache.count - 1, selected + preloadRange)

        if preloadStart <= preloadEnd {
            let hydrationEnd = min(sortedItemsCache.count, preloadEnd + 1)
            let hydrationRange = preloadStart..<hydrationEnd
            if hydrationRange != lastHydrationRange {
                lastHydrationRange = hydrationRange
                var urlsToHydrate: [URL] = []
                urlsToHydrate.reserveCapacity(hydrationRange.count)
                for index in hydrationRange {
                    let item = sortedItemsCache[index]
                    if viewModel.needsHydration(item) {
                        urlsToHydrate.append(item.url)
                    }
                }
                if !urlsToHydrate.isEmpty {
                    viewModel.hydrateMetadata(for: urlsToHydrate)
                }
            }
        }

        var keepURLs = Set<URL>()
        for i in windowStart...windowEnd {
            keepURLs.insert(sortedItemsCache[i].url)
        }
        var urlsToEvict: [URL] = []
        for url in thumbnails.keys {
            if !keepURLs.contains(url) {
                urlsToEvict.append(url)
            }
        }

        for index in start...end {
            let item = sortedItemsCache[index]
            let distance = abs(index - selected)
            let hasRealThumbnail = hasSufficientThumbnail(
                for: item.url,
                minPixelSize: thumbnailPixelSize
            )

            if hasRealThumbnail {
                continue
            } else if thumbnailCache.hasFailed(url: item.url) {
                thumbnailUpdates[item.url] = item.placeholderIcon
                placeholdersToRemove.insert(item.url)
            } else {
                if let cachedHigh = thumbnailCache.getCachedThumbnail(for: item.url, maxPixelSize: thumbnailPixelSize) {
                    thumbnailUpdates[item.url] = cachedHigh
                    placeholdersToRemove.insert(item.url)
                    continue
                }

                let cachedLow = thumbnailCache.getCachedThumbnail(for: item.url, maxPixelSize: placeholderPixelSize)
                if let cachedLow {
                    if thumbnails[item.url] == nil || iconPlaceholders.contains(item.url) {
                        thumbnailUpdates[item.url] = cachedLow
                        placeholdersToAdd.insert(item.url)
                    }
                } else if thumbnails[item.url] == nil {
                    thumbnailUpdates[item.url] = item.placeholderIcon
                    placeholdersToAdd.insert(item.url)
                }

                if !thumbnailCache.isPending(url: item.url, maxPixelSize: thumbnailPixelSize) {
                    itemsToLoadHigh.append((item, distance))
                }
                if cachedLow == nil && !thumbnailCache.isPending(url: item.url, maxPixelSize: placeholderPixelSize) {
                    itemsToLoadLow.append((item, distance))
                }
            }
        }

        if preloadStart <= preloadEnd {
            for index in preloadStart...preloadEnd {
                if index >= start && index <= end { continue }
                let item = sortedItemsCache[index]
                let distance = abs(index - selected)
                let hasRealThumbnail = hasSufficientThumbnail(
                    for: item.url,
                    minPixelSize: thumbnailPixelSize
                )

                if hasRealThumbnail || thumbnailCache.hasFailed(url: item.url) {
                    continue
                }

                if let cachedLow = thumbnailCache.getCachedThumbnail(for: item.url, maxPixelSize: placeholderPixelSize) {
                    if thumbnails[item.url] == nil || iconPlaceholders.contains(item.url) {
                        thumbnailUpdates[item.url] = cachedLow
                        placeholdersToAdd.insert(item.url)
                    }
                    continue
                }

                if !thumbnailCache.isPending(url: item.url, maxPixelSize: placeholderPixelSize) {
                    itemsToLoadLow.append((item, distance))
                }
            }
        }

        itemsToLoadHigh.sort { $0.distance < $1.distance }
        itemsToLoadLow.sort { $0.distance < $1.distance }
        // Load fewer items during scroll to keep UI responsive
        let highLimit = isScrolling ? 6 : maxConcurrentThumbnails
        let lowLimit = isScrolling ? 4 : maxConcurrentPreloadThumbnails
        let loadHighItems = Array(itemsToLoadHigh.prefix(highLimit))
        let loadLowItems = Array(itemsToLoadLow.prefix(lowLimit))
        let hasMoreToLoad = itemsToLoadHigh.count > highLimit || itemsToLoadLow.count > lowLimit

        DispatchQueue.main.async { [self] in
            // Evict old thumbnails
            if !urlsToEvict.isEmpty && Self.debugEnabled {
                Self.debugLog("[CoverFlow] EVICTING \(urlsToEvict.count) thumbnails, keeping window \(windowStart)...\(windowEnd) around selected \(selected)")
            }
            for url in urlsToEvict {
                thumbnails.removeValue(forKey: url)
                pendingThumbnailUpdates.removeValue(forKey: url)
                iconPlaceholders.remove(url)
            }

            // Apply cached thumbnails directly (they're already ready)
            if !thumbnailUpdates.isEmpty {
                if Self.debugEnabled {
                    Self.debugLog("[CoverFlow] APPLYING \(thumbnailUpdates.count) cached thumbnails")
                }
                for (url, image) in thumbnailUpdates {
                    thumbnails[url] = image
                }
            }

            for url in placeholdersToAdd {
                iconPlaceholders.insert(url)
            }
            for url in placeholdersToRemove {
                iconPlaceholders.remove(url)
            }

            // Start async thumbnail generation
            for (item, _) in loadHighItems {
                generateHighThumbnail(for: item)
            }
            for (item, _) in loadLowItems {
                generatePlaceholderThumbnail(for: item, maxPixelSize: placeholderPixelSize)
            }

            // If there are more items to load and we're not scrolling, schedule another pass
            // Use longer delay to prevent rapid cascading updates that cause UI flashing
            if hasMoreToLoad && !isCoverFlowScrolling {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                    loadVisibleThumbnails()
                }
            }
        }
    }

    private func generateHighThumbnail(for item: FileItem) {
        generateThumbnail(for: item, maxPixelSize: coverFlowThumbnailPixelSize, placeholder: false, refreshAfter: true)
    }

    private func generatePlaceholderThumbnail(for item: FileItem, maxPixelSize: CGFloat) {
        generateThumbnail(for: item, maxPixelSize: maxPixelSize, placeholder: true, refreshAfter: false)
    }

    private func generateThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat,
        placeholder: Bool,
        refreshAfter: Bool
    ) {
        // Skip archive items entirely - no closure creation, no dispatch
        if item.isFromArchive {
            let url = item.url
            pendingThumbnailUpdates[url] = item.placeholderIcon
            if placeholder {
                iconPlaceholders.insert(url)
            }
            scheduleThumbnailBatch()
            return
        }

        let currentGen = thumbnailLoadGeneration

        thumbnailCache.generateThumbnail(for: item, maxPixelSize: maxPixelSize) { url, image in
            DispatchQueue.main.async { [self] in
                guard currentGen == thumbnailLoadGeneration else { return }

                let finalImage = image ?? item.placeholderIcon

                if placeholder {
                    if thumbnails[url] != nil && !iconPlaceholders.contains(url) {
                        return
                    }
                    pendingThumbnailUpdates[url] = finalImage
                    iconPlaceholders.insert(url)
                } else {
                    pendingThumbnailUpdates[url] = finalImage
                    iconPlaceholders.remove(url)
                }

                // Schedule batch apply instead of immediate state update
                scheduleThumbnailBatch()
                _ = refreshAfter
            }
        }
    }

    private func scheduleThumbnailBatch() {
        // If timer already scheduled, let it handle the batch
        guard thumbnailBatchTimer == nil else { return }

        thumbnailBatchTimer = Timer.scheduledTimer(withTimeInterval: thumbnailBatchInterval, repeats: false) { [self] _ in
            flushPendingThumbnails()
        }
    }

    private func flushPendingThumbnails() {
        thumbnailBatchTimer?.invalidate()
        thumbnailBatchTimer = nil

        guard !pendingThumbnailUpdates.isEmpty else { return }

        let count = pendingThumbnailUpdates.count
        if Self.debugEnabled {
            Self.debugLog("[CoverFlow] FLUSH \(count) pending thumbnails")
        }

        // Apply all pending updates in one batch
        for (url, image) in pendingThumbnailUpdates {
            thumbnails[url] = image
        }
        pendingThumbnailUpdates.removeAll()
    }

    private func updateCoverFlowHeight(
        delta: CGFloat,
        currentHeight: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) {
        if dragStartCoverFlowHeight == nil {
            dragStartCoverFlowHeight = currentHeight
        }
        let startHeight = dragStartCoverFlowHeight ?? currentHeight
        let proposedHeight = startHeight + delta
        let clampedHeight: CGFloat
        if maxHeight < minHeight {
            clampedHeight = maxHeight
        } else {
            clampedHeight = min(max(proposedHeight, minHeight), maxHeight)
        }
        liveCoverFlowHeight = clampedHeight
    }

    private func hasSufficientThumbnail(for url: URL, minPixelSize: CGFloat) -> Bool {
        guard let image = thumbnails[url] else { return false }
        guard !iconPlaceholders.contains(url) else { return false }
        let maxDimension = max(image.size.width, image.size.height)
        return maxDimension >= minPixelSize * 0.9
    }
}

// MARK: - Native AppKit Cover Flow Container

struct CoverFlowContainer: NSViewRepresentable {
    let items: [FileItem]
    let itemsToken: Int
    @Binding var selectedIndex: Int
    let thumbnails: [URL: NSImage]
    let thumbnailCount: Int  // Explicit count to force SwiftUI updates
    let navigationGeneration: Int  // Forces update on every navigation
    let selectedItems: Set<FileItem>  // Multi-selection for drag
    let coverScale: CGFloat
    let scrollSensitivity: CGFloat
    let onSelect: (Int) -> Void
    let onOpen: (Int) -> Void
    let onRightClick: (Int) -> Void
    let onDrop: ([URL]) -> Void
    let onDropToFolder: ([URL], URL) -> Void  // Drop to specific folder
    let onScrollStateChange: (Bool) -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onDelete: () -> Void
    let onQuickLook: (FileItem) -> Void

    private static var viewInstanceCount = 0

    func makeNSView(context: Context) -> CoverFlowNSView {
        Self.viewInstanceCount += 1
        CoverFlowView.debugLog("[Container] makeNSView called - instance #\(Self.viewInstanceCount)")
        let view = CoverFlowNSView()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onRightClick = { index, _ in
            onRightClick(index)
        }
        view.onDrop = onDrop
        view.onDropToFolder = onDropToFolder
        view.onScrollStateChange = onScrollStateChange
        view.onCopy = onCopy
        view.onCut = onCut
        view.onPaste = onPaste
        view.onDelete = onDelete
        view.onQuickLook = onQuickLook
        view.selectedItems = selectedItems
        view.coverScale = coverScale
        view.scrollSensitivity = scrollSensitivity
        view.updateItems(items, itemsToken: itemsToken, thumbnails: thumbnails, selectedIndex: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: CoverFlowNSView, context: Context) {
        // Preserve first responder status during updates
        let wasFirstResponder = nsView.window?.firstResponder === nsView

        nsView.onSelect = onSelect
        nsView.onOpen = onOpen
        nsView.onRightClick = { index, _ in
            onRightClick(index)
        }
        nsView.onDrop = onDrop
        nsView.onDropToFolder = onDropToFolder
        nsView.onScrollStateChange = onScrollStateChange
        nsView.onCopy = onCopy
        nsView.onCut = onCut
        nsView.onPaste = onPaste
        nsView.onDelete = onDelete
        nsView.onQuickLook = onQuickLook
        nsView.selectedItems = selectedItems
        nsView.coverScale = coverScale
        nsView.scrollSensitivity = scrollSensitivity
        nsView.updateItems(items, itemsToken: itemsToken, thumbnails: thumbnails, selectedIndex: selectedIndex)

        // Restore first responder if it was lost during update
        if wasFirstResponder && nsView.window?.firstResponder !== nsView {
            CoverFlowView.debugLog("[Container] Focus lost during updateNSView - restoring")
            nsView.window?.makeFirstResponder(nsView)
        } else if nsView.window?.isKeyWindow == true {
            // Also check and restore if window is key but we don't have focus
            nsView.ensureFirstResponder()
        }
    }
}

class CoverFlowNSView: NSView {
    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    var onRightClick: ((Int, NSPoint) -> Void)?
    var onScrollStateChange: ((Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onDelete: (() -> Void)?
    var onQuickLook: ((FileItem) -> Void)?
    var selectedItems: Set<FileItem> = []  // Track multi-selection for drag

    private var items: [FileItem] = []
    private var itemsToken: Int = 0
    private var thumbnails: [URL: NSImage] = [:]
    private var selectedIndex: Int = 0
    private var coverLayers: [CALayer] = []
    private var layerPool: [CALayer] = []  // Reusable layer pool
    private var lastClickTime: Date = .distantPast

    // Fast scroll detection
    private var isScrolling = false
    private var scrollSettleTimer: Timer?
    private var lastClickIndex: Int = -1
    private var lastClickLocation: CGPoint = .zero

    // Momentum scrolling
    private var scrollVelocity: CGFloat = 0
    private var lastScrollTime: Date = .distantPast
    private var momentumTimer: Timer?
    private var accumulatedScroll: CGFloat = 0

    // Type-ahead search
    private var typeAheadBuffer: String = ""
    private var typeAheadTimer: Timer?
    private let typeAheadTimeout: TimeInterval = 1.0

    // Dynamic sizing based on view bounds
    var coverScale: CGFloat = 1.0 {
        didSet {
            if coverScale != oldValue {
                rebuildCovers()
                needsLayout = true
            }
        }
    }
    var scrollSensitivity: CGFloat = 1.0

    private var baseCoverSize: CGFloat {
        let heightDriven = bounds.height * 0.7
        let widthDriven = bounds.width * 0.28
        return min(heightDriven, widthDriven, 480) * coverScale
    }
    private var coverSpacing: CGFloat { baseCoverSize * 0.22 }  // Space between side covers
    private var sideOffset: CGFloat { baseCoverSize * 0.62 }    // Distance from center to first side cover
    private let sideAngle: CGFloat = 60
    private let visibleRange = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Drag and drop
    var onDrop: (([URL]) -> Void)?
    var onDropToFolder: (([URL], URL) -> Void)?  // Drop to specific folder
    private var dragStartLocation: NSPoint?
    private var dragStartIndex: Int?
    private var isDropTargeted = false
    private var dropTargetIndex: Int?  // Which folder cover is being hovered
    private var dropTargetHighlightLayer: CAShapeLayer?  // Visible hover ring

    private func setupView() {
        wantsLayer = true

        // Background gradient
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            NSColor.windowBackgroundColor.cgColor,
            NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black)?.cgColor ?? NSColor.black.cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.frame = bounds
        gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(gradientLayer)

        // Add right-click gesture recognizer as backup
        let rightClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClickGesture.buttonMask = 0x2 // Right mouse button
        addGestureRecognizer(rightClickGesture)

        // Register for drag and drop
        registerForDraggedTypes([.fileURL])
    }

    @objc private func handleRightClick(_ gesture: NSClickGestureRecognizer) {
        let location = gesture.location(in: self)
        let index = hitTestCover(at: location) ?? selectedIndex
        onSelect?(index)
        let menu = createContextMenu(for: index)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    private static var updateItemsCount = 0
    private static var lastUpdateTime: Date = .distantPast

    func updateItems(_ items: [FileItem], itemsToken: Int, thumbnails: [URL: NSImage], selectedIndex: Int) {
        Self.updateItemsCount += 1
        let now = Date()
        let interval = now.timeIntervalSince(Self.lastUpdateTime)
        Self.lastUpdateTime = now

        let countChanged = self.items.count != items.count
        let tokenChanged = self.itemsToken != itemsToken
        let itemsChanged = countChanged || tokenChanged
        let thumbnailsChanged = self.thumbnails.count != thumbnails.count

        if interval < 0.5 {
            if itemsChanged {
                CoverFlowView.debugLog("[NSView] updateItems #\(Self.updateItemsCount) - \(String(format: "%.3f", interval))s | ITEMS CHANGED! countChanged:\(countChanged) tokenChanged:\(tokenChanged) oldToken:\(self.itemsToken) newToken:\(itemsToken) oldCount:\(self.items.count) newCount:\(items.count)")
            } else {
                CoverFlowView.debugLog("[NSView] updateItems #\(Self.updateItemsCount) - \(String(format: "%.3f", interval))s | thumbsChanged:\(thumbnailsChanged) thumbs:\(thumbnails.count)")
            }
        }

        self.items = items
        self.itemsToken = itemsToken
        self.thumbnails = thumbnails

        let shouldSyncSelection = itemsChanged || !isScrolling
        let indexChanged = self.selectedIndex != selectedIndex
        if shouldSyncSelection {
            self.selectedIndex = selectedIndex
        }

        if itemsChanged {
            CoverFlowView.debugLog("[NSView] REBUILD covers - items changed")
            rebuildCovers()
            layer?.setNeedsLayout()
            layer?.layoutIfNeeded()
        } else if indexChanged && shouldSyncSelection {
            animateToSelection()
            DispatchQueue.main.async {
                self.updateCoverImages()
            }
        } else {
            updateCoverImages()
        }
    }

    private func updateCoverImages() {
        for coverLayer in coverLayers {
            guard let index = coverLayer.value(forKey: "itemIndex") as? Int,
                  index < items.count else { continue }

            let item = items[index]
            guard let thumbnail = thumbnails[item.url] else { continue }

            let token = thumbnailToken(for: item, thumbnail: thumbnail)
            if let existingToken = coverLayer.value(forKey: "thumbnailToken") as? Int,
               existingToken == token {
                continue
            }
            coverLayer.setValue(token, forKey: "thumbnailToken")

            let imageContent: Any
            if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageContent = cgImage
            } else {
                imageContent = thumbnail
            }

            // Find the image layer and reflection container
            var imageLayer: CALayer?
            var reflectionContainer: CALayer?

            for sublayer in coverLayer.sublayers ?? [] {
                if sublayer.name == "imageLayer" {
                    imageLayer = sublayer
                } else if sublayer.name == "reflectionContainer" {
                    reflectionContainer = sublayer
                }
            }

            // Update main image
            if let imageLayer = imageLayer {
                imageLayer.contents = imageContent
                imageLayer.contentsGravity = .resizeAspect
            }

            // Update reflection and fade it in
            if let reflectionContainer = reflectionContainer {
                // Find the reflection image layer
                for sublayer in reflectionContainer.sublayers ?? [] {
                    if sublayer.name == "reflectionImage" {
                        sublayer.contents = imageContent
                        sublayer.contentsGravity = .resizeAspect
                    }
                }

                // Fade in the reflection smoothly if it was hidden
                if reflectionContainer.opacity < 1.0 {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.3)
                    reflectionContainer.opacity = 1.0
                    CATransaction.commit()
                }
            }
        }
    }

    private func thumbnailToken(for item: FileItem, thumbnail: NSImage?) -> Int {
        if let thumbnail {
            return ObjectIdentifier(thumbnail).hashValue
        }
        // Use placeholderIcon for fast hash - avoids expensive icon lookup
        return ObjectIdentifier(item.placeholderIcon).hashValue
    }

    private func rebuildCovers() {
        CoverFlowView.debugLog("[NSView] rebuildCovers called - \(items.count) items")
        coverLayers.forEach { $0.removeFromSuperlayer() }
        coverLayers.removeAll()

        guard !items.isEmpty else { return }

        // Ensure selectedIndex is within bounds
        let safeSelectedIndex = min(max(0, selectedIndex), items.count - 1)

        let centerX = bounds.width / 2
        let centerY = bounds.height / 2

        let start = max(0, safeSelectedIndex - visibleRange)
        let end = min(items.count - 1, safeSelectedIndex + visibleRange)

        guard start <= end else { return }

        for index in start...end {
            let item = items[index]
            let coverLayer = createCoverLayer(for: item, at: index)
            positionCover(coverLayer, at: index, centerX: centerX, centerY: centerY, animated: false)
            layer?.addSublayer(coverLayer)
            coverLayers.append(coverLayer)
        }
    }

    private func animateToSelection() {
        guard !items.isEmpty else { return }

        // Ensure selectedIndex is within bounds
        let safeSelectedIndex = min(max(0, selectedIndex), items.count - 1)

        let centerX = bounds.width / 2
        let centerY = bounds.height / 2

        // Determine visible range
        let start = max(0, safeSelectedIndex - visibleRange)
        let end = min(items.count - 1, safeSelectedIndex + visibleRange)

        guard start <= end else { return }
        let visibleIndices = Set(start...end)

        // Find layers to recycle (outside visible range)
        var layersToRecycle: [CALayer] = []
        var existingIndices = Set<Int>()

        for coverLayer in coverLayers {
            if let index = coverLayer.value(forKey: "itemIndex") as? Int {
                if visibleIndices.contains(index) {
                    existingIndices.insert(index)
                } else {
                    layersToRecycle.append(coverLayer)
                }
            }
        }

        // Find indices that need layers
        let missingIndices = visibleIndices.subtracting(existingIndices).sorted()

        // Recycle layers for missing indices (or create new if pool empty)
        for index in missingIndices {
            guard index < items.count else { continue }
            let item = items[index]

            let coverLayer: CALayer
            if let recycled = layersToRecycle.popLast() {
                // Reuse existing layer
                coverLayer = recycled
                updateCoverLayer(coverLayer, for: item, at: index)
            } else if let pooled = layerPool.popLast() {
                // Get from pool
                coverLayer = pooled
                layer?.addSublayer(coverLayer)
                coverLayers.append(coverLayer)
                updateCoverLayer(coverLayer, for: item, at: index)
            } else {
                // Create new layer
                coverLayer = createCoverLayer(for: item, at: index)
                coverLayer.opacity = 1
                layer?.addSublayer(coverLayer)
                coverLayers.append(coverLayer)
            }
            positionCover(coverLayer, at: index, centerX: centerX, centerY: centerY, animated: false)
        }

        // Return unused recycled layers to pool (hide them)
        for unusedLayer in layersToRecycle {
            unusedLayer.removeFromSuperlayer()
            coverLayers.removeAll { $0 === unusedLayer }
            if layerPool.count < visibleRange * 3 {
                layerPool.append(unusedLayer)
            }
        }

        // Animate all covers to new positions
        CATransaction.begin()
        if isScrolling {
            // During scroll: very fast, snappy animations
            CATransaction.setAnimationDuration(0.08)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            // When stopped: smooth, elegant animation
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }

        for coverLayer in coverLayers {
            if let index = coverLayer.value(forKey: "itemIndex") as? Int {
                positionCover(coverLayer, at: index, centerX: centerX, centerY: centerY, animated: true)
                coverLayer.opacity = 1
            }
        }

        CATransaction.commit()

        // Ensure focus is maintained after animation updates
        DispatchQueue.main.async { [weak self] in
            self?.ensureFirstResponder()
        }
    }

    // Update existing layer with new item data (for recycling)
    private func updateCoverLayer(_ coverLayer: CALayer, for item: FileItem, at index: Int) {
        let thumbnail = thumbnails[item.url]
        let hasThumbnail = thumbnail != nil
        let coverSize = getCoverSize(for: thumbnail)

        coverLayer.setValue(index, forKey: "itemIndex")
        coverLayer.setValue(coverSize.width, forKey: "coverWidth")
        coverLayer.setValue(coverSize.height, forKey: "coverHeight")
        coverLayer.setValue(thumbnailToken(for: item, thumbnail: thumbnail), forKey: "thumbnailToken")
        // Match createCoverLayer - bounds should NOT include reflection height
        coverLayer.bounds = CGRect(x: 0, y: 0, width: coverSize.width, height: coverSize.height)

        // Get image content - use NSImage directly for icons to preserve transparency
        let imageContent: Any
        if let thumb = thumbnail {
            // For thumbnails, CGImage is fine
            imageContent = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? thumb
        } else {
            // Use fast placeholder - real icon will load async
            imageContent = item.placeholderIcon
        }

        // Update image layer - match createCoverLayer (y: 0, not offset)
        if let imageLayer = coverLayer.sublayers?.first(where: { $0.name == "imageLayer" }) {
            imageLayer.frame = CGRect(x: 0, y: 0, width: coverSize.width, height: coverSize.height)
            imageLayer.contents = imageContent
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.isOpaque = false
        }

        // Update reflection (hide during scroll for performance)
        // Match createCoverLayer - reflection is BELOW the image (negative y)
        let reflectionHeight = coverSize.height * 0.4
        if let reflectionContainer = coverLayer.sublayers?.first(where: { $0.name == "reflectionContainer" }) {
            reflectionContainer.opacity = (hasThumbnail && !isScrolling) ? 1.0 : 0.0
            reflectionContainer.frame = CGRect(x: 0, y: -reflectionHeight - 4, width: coverSize.width, height: reflectionHeight)
            if let mask = reflectionContainer.mask as? CAGradientLayer {
                mask.frame = reflectionContainer.bounds
            }
            if let reflectionImage = reflectionContainer.sublayers?.first(where: { $0.name == "reflectionImage" }) {
                reflectionImage.frame = CGRect(x: 0, y: reflectionHeight - coverSize.height, width: coverSize.width, height: coverSize.height)
                reflectionImage.contents = hasThumbnail ? imageContent : nil
            }
        }
    }

    private func getCoverSize(for thumbnail: NSImage?) -> CGSize {
        let maxSize = baseCoverSize

        guard let thumbnail = thumbnail else {
            // Default square for icons/folders
            return CGSize(width: maxSize, height: maxSize)
        }

        let imageSize = thumbnail.size
        let aspectRatio = imageSize.width / imageSize.height

        // Calculate size maintaining aspect ratio within maxSize bounds
        if aspectRatio > 1 {
            // Landscape/widescreen
            let width = maxSize
            let height = maxSize / aspectRatio
            return CGSize(width: width, height: max(height, maxSize * 0.5))
        } else if aspectRatio < 1 {
            // Portrait
            let height = maxSize
            let width = maxSize * aspectRatio
            return CGSize(width: max(width, maxSize * 0.5), height: height)
        } else {
            // Square
            return CGSize(width: maxSize, height: maxSize)
        }
    }

    private func createCoverLayer(for item: FileItem, at index: Int) -> CALayer {
        let thumbnail = thumbnails[item.url]
        let hasThumbnail = thumbnail != nil
        let coverSize = getCoverSize(for: thumbnail)
        let coverWidth = coverSize.width
        let coverHeight = coverSize.height

        let container = CALayer()
        container.setValue(index, forKey: "itemIndex")
        container.setValue(coverWidth, forKey: "coverWidth")
        container.setValue(coverHeight, forKey: "coverHeight")
        container.setValue(thumbnailToken(for: item, thumbnail: thumbnail), forKey: "thumbnailToken")
        container.backgroundColor = NSColor.clear.cgColor
        // CRITICAL: Set bounds so anchorPoint works correctly for rotation
        container.bounds = CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight)
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        // Image layer (no background box)
        let imageLayer = CALayer()
        imageLayer.name = "imageLayer"
        imageLayer.frame = CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight)
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.isOpaque = false  // Ensure transparency is rendered

        if let thumbnail = thumbnail {
            // For thumbnails (actual images), CGImage conversion is fine
            if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageLayer.contents = cgImage
            } else {
                imageLayer.contents = thumbnail
            }
        } else {
            // Use fast placeholder - real icon will load async
            imageLayer.contents = item.placeholderIcon
        }
        imageLayer.contentsGravity = .resizeAspect
        container.addSublayer(imageLayer)

        // Reflection - only show when we have a real thumbnail
        let reflectionHeight = coverHeight * 0.4
        let reflectionContainer = CALayer()
        reflectionContainer.name = "reflectionContainer"
        reflectionContainer.frame = CGRect(x: 0, y: -reflectionHeight - 4, width: coverWidth, height: reflectionHeight)
        reflectionContainer.masksToBounds = true
        reflectionContainer.backgroundColor = NSColor.clear.cgColor
        // Hide reflection until thumbnail is loaded to avoid flash
        reflectionContainer.opacity = hasThumbnail ? 1.0 : 0.0

        let reflectionImage = CALayer()
        reflectionImage.name = "reflectionImage"
        reflectionImage.frame = CGRect(x: 0, y: reflectionHeight - coverHeight, width: coverWidth, height: coverHeight)
        reflectionImage.masksToBounds = true
        reflectionImage.backgroundColor = NSColor.clear.cgColor
        reflectionImage.transform = CATransform3DMakeScale(1, -1, 1)

        if let thumbnail = thumbnail {
            if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                reflectionImage.contents = cgImage
            } else {
                reflectionImage.contents = thumbnail
            }
            reflectionImage.contentsGravity = .resizeAspect
        } else {
            // Don't show icon in reflection - leave empty
            reflectionImage.contents = nil
        }
        reflectionContainer.addSublayer(reflectionImage)

        // Reflection fade gradient
        let reflectionMask = CAGradientLayer()
        reflectionMask.frame = reflectionContainer.bounds
        reflectionMask.colors = [
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.clear.cgColor
        ]
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 1)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: 0.2)
        reflectionContainer.mask = reflectionMask

        container.addSublayer(reflectionContainer)

        return container
    }

    private func positionCover(_ coverLayer: CALayer, at index: Int, centerX: CGFloat, centerY: CGFloat, animated: Bool) {
        let diff = index - selectedIndex
        let isSelected = diff == 0

        // Calculate center
        let viewCenterX = bounds.width / 2
        let viewCenterY = bounds.height / 2

        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 1000.0 // Perspective

        let xPosition: CGFloat
        let angle: CGFloat
        let scale: CGFloat = isSelected ? 1.0 : 0.75
        let zOffset: CGFloat = isSelected ? 50 : 0

        if diff == 0 {
            xPosition = viewCenterX
            angle = 0
        } else if diff < 0 {
            // Position covers to the left
            xPosition = viewCenterX - sideOffset + CGFloat(diff + 1) * coverSpacing
            angle = sideAngle
        } else {
            // Position covers to the right
            xPosition = viewCenterX + sideOffset + CGFloat(diff - 1) * coverSpacing
            angle = -sideAngle
        }

        transform = CATransform3DTranslate(transform, 0, 0, zOffset)
        transform = CATransform3DRotate(transform, angle * .pi / 180, 0, 1, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)

        let zPosition = Double(1000 - abs(diff) * 10)

        // Y position: adjusted up for better visual balance
        let yPosition = viewCenterY

        if animated {
            coverLayer.transform = transform
            coverLayer.position = CGPoint(x: xPosition, y: yPosition)
            coverLayer.zPosition = CGFloat(zPosition)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            coverLayer.transform = transform
            coverLayer.position = CGPoint(x: xPosition, y: yPosition)
            coverLayer.zPosition = CGFloat(zPosition)
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.first?.frame = bounds // Update gradient
        guard !items.isEmpty else { return }
        if coverLayers.isEmpty {
            rebuildCovers()
            return
        }
        let centerX = bounds.width / 2
        let centerY = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for coverLayer in coverLayers {
            guard let index = coverLayer.value(forKey: "itemIndex") as? Int,
                  index < items.count else { continue }
            updateCoverLayer(coverLayer, for: items[index], at: index)
            positionCover(coverLayer, at: index, centerX: centerX, centerY: centerY, animated: false)
        }
        CATransaction.commit()
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        hadFocus = true
        CoverFlowView.debugLog("[NSView] becomeFirstResponder called - hadFocus set to true")
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        // Check what's taking focus
        if let newResponder = window?.firstResponder {
            let responderType = String(describing: type(of: newResponder))
            let responderAddress = Unmanaged.passUnretained(newResponder).toOpaque()
            let selfAddress = Unmanaged.passUnretained(self).toOpaque()
            let isSameView = newResponder === self
            CoverFlowView.debugLog("[NSView] resignFirstResponder - new responder: \(responderType) addr:\(responderAddress) self:\(selfAddress) isSame:\(isSameView)")
            if !isSameView {
                // Log stack trace when losing focus to a different view
                let symbols = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
                CoverFlowView.debugLog("[NSView] resignFirstResponder stack:\n\(symbols)")
            }
        } else {
            CoverFlowView.debugLog("[NSView] resignFirstResponder - no new responder")
        }
        return super.resignFirstResponder()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        if event.modifierFlags.contains(.control) {
            handleContextClick(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let now = Date()

        // Check for double-click: within time window AND within distance of last click
        let isWithinDoubleClickTime = now.timeIntervalSince(lastClickTime) < 0.4
        let clickDistance = hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y)
        let isNearLastClick = clickDistance < 50 // pixels

        // If this is a double-click (by location proximity), open the previously clicked item
        if isWithinDoubleClickTime && isNearLastClick && lastClickIndex >= 0 && lastClickIndex < items.count {
            onOpen?(lastClickIndex)
            lastClickTime = .distantPast
            lastClickIndex = -1
            lastClickLocation = .zero
            dragStartLocation = nil
            dragStartIndex = nil
            return
        }

        // Track for potential drag
        dragStartLocation = location
        dragStartIndex = hitTestCover(at: location)

        if let index = dragStartIndex {
            selectIndexLocally(index)
            lastClickTime = now
            lastClickIndex = index
            lastClickLocation = location
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = dragStartLocation,
              let index = dragStartIndex,
              index < items.count else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let distance = hypot(location.x - startLocation.x, location.y - startLocation.y)

        // Start drag if moved enough
        if distance > 5 {
            let clickedItem = items[index]

            // Determine items to drag - all selected items if the clicked item is selected,
            // otherwise just the clicked item
            let itemsToDrag: [FileItem]
            if selectedItems.contains(clickedItem) && selectedItems.count > 1 {
                itemsToDrag = Array(selectedItems)
            } else {
                itemsToDrag = [clickedItem]
            }

            let draggableItems = itemsToDrag.filter { !$0.isFromArchive }
            guard !draggableItems.isEmpty else { return }

            // Create dragging items for each file
            var draggingItems: [NSDraggingItem] = []
            for (offset, item) in draggableItems.enumerated() {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)

                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                // Use the item's icon for the drag image
                let iconSize = NSSize(width: 64, height: 64)
                let dragImage = item.icon
                dragImage.size = iconSize

                // Offset each subsequent item slightly for a stacked appearance
                let itemLocation = NSPoint(
                    x: location.x + CGFloat(offset * 8),
                    y: location.y - CGFloat(offset * 8)
                )
                draggingItem.setDraggingFrame(NSRect(origin: itemLocation, size: iconSize), contents: dragImage)
                draggingItems.append(draggingItem)
            }

            _ = beginDraggingSession(with: draggingItems, event: event, source: self)

            dragStartLocation = nil
            dragStartIndex = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartIndex = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleContextClick(with: event)
    }

    private func handleContextClick(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let index = hitTestCover(at: location) ?? selectedIndex
        onSelect?(index)
        showContextMenu(for: index, with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let index = hitTestCover(at: location) ?? selectedIndex
        return createContextMenu(for: index)
    }

    private func showContextMenu(for index: Int, with event: NSEvent) {
        guard index < items.count else { return }

        let menu = createContextMenu(for: index)
        let location = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    private func createContextMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let item = index < items.count ? items[index] : nil

        let openItem = NSMenuItem(title: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = index
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy", action: #selector(menuCopy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let cutItem = NSMenuItem(title: "Cut", action: #selector(menuCut(_:)), keyEquivalent: "")
        cutItem.target = self
        menu.addItem(cutItem)

        menu.addItem(NSMenuItem.separator())

        let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(menuTrash(_:)), keyEquivalent: "")
        trashItem.target = self
        if let item, item.isFromArchive {
            trashItem.isEnabled = false
        }
        menu.addItem(trashItem)

        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(menuShowInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        if let item, item.isFromArchive, item.archiveURL == nil {
            finderItem.isEnabled = false
        }
        menu.addItem(finderItem)

        return menu
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if selectedIndex >= 0 && selectedIndex < items.count {
            onOpen?(selectedIndex)
        }
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        onCopy?()
    }

    @objc private func menuCut(_ sender: NSMenuItem) {
        onCut?()
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        onDelete?()
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        if selectedIndex < items.count {
            let item = items[selectedIndex]
            if item.isFromArchive {
                if let archiveURL = item.archiveURL {
                    NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                } else {
                    NSSound.beep()
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    // Make sure we become first responder when view appears and on any click
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()

        // Observe first responder changes to debug focus loss
        if let window = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        // Check if we lost focus
        if let window = window, window.firstResponder !== self {
            let responderType = String(describing: type(of: window.firstResponder))
            // Only log if we had focus before (track with instance variable)
            if hadFocus {
                hadFocus = false
                CoverFlowView.debugLog("[NSView] FOCUS LOST via windowDidUpdate! New responder: \(responderType)")
                // Log the call stack to find the culprit
                let symbols = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
                CoverFlowView.debugLog("[NSView] Stack trace:\n\(symbols)")
            }
        } else if window?.firstResponder === self && !hadFocus {
            hadFocus = true
            CoverFlowView.debugLog("[NSView] FOCUS GAINED via windowDidUpdate")
        }
    }

    private var hadFocus = false

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        let isFirst = window?.firstResponder === self
        CoverFlowView.debugLog("[NSView] WINDOW became key - isFirstResponder: \(isFirst)")
        // Proactively restore focus when window becomes key
        if !isFirst {
            CoverFlowView.debugLog("[NSView] Re-requesting focus after window became key")
            requestFocus()
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        CoverFlowView.debugLog("[NSView] WINDOW resigned key")
    }

    /// Ensure we maintain first responder status - called periodically during scroll and after updates
    func ensureFirstResponder() {
        guard let window = window else { return }
        if window.isKeyWindow && window.firstResponder !== self {
            let currentResponder = String(describing: type(of: window.firstResponder))
            CoverFlowView.debugLog("[NSView] ensureFirstResponder - lost to \(currentResponder), reclaiming")
            window.makeFirstResponder(self)
        }
    }

    func requestFocus() {
        guard let window = window else { return }
        // Only request focus if we're not already the first responder
        if window.firstResponder !== self {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capture all clicks in this view
        let result = super.hitTest(point)
        if result == self || result?.isDescendant(of: self) == true {
            return self
        }
        return result
    }

    private func hitTestCover(at point: NSPoint) -> Int? {
        // First pass: check with expanded hit areas, sorted by z-order (front to back)
        let sortedLayers = coverLayers.sorted { $0.zPosition > $1.zPosition }

        for coverLayer in sortedLayers {
            let coverWidth = coverLayer.value(forKey: "coverWidth") as? CGFloat ?? baseCoverSize
            let coverHeight = coverLayer.value(forKey: "coverHeight") as? CGFloat ?? baseCoverSize

            let coverFrame = CGRect(
                x: coverLayer.position.x - coverWidth / 2,
                y: coverLayer.position.y - coverHeight / 2,
                width: coverWidth,
                height: coverHeight
            )

            // Generous hit area expansion
            let hitFrame = coverFrame.insetBy(dx: -20, dy: -20)
            if hitFrame.contains(point) {
                let idx = coverLayer.value(forKey: "itemIndex") as? Int
                return idx
            }
        }

        // Second pass: find nearest cover if click was in the cover flow area
        let coverFlowY = bounds.height * 0.5
        if point.y > coverFlowY - baseCoverSize && point.y < coverFlowY + baseCoverSize {
            var nearestIndex: Int?
            var nearestDistance: CGFloat = .infinity

            for coverLayer in coverLayers {
                if let index = coverLayer.value(forKey: "itemIndex") as? Int {
                    let distance = abs(coverLayer.position.x - point.x)
                    if distance < nearestDistance {
                        nearestDistance = distance
                        nearestIndex = index
                    }
                }
            }

            // Only return if reasonably close
            if nearestDistance < coverSpacing * 2 {
                return nearestIndex
            }
        }

        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Cancel any existing momentum
        momentumTimer?.invalidate()

        // Mark as scrolling and reset settle timer
        setScrolling(true)

        // Determine scroll delta (horizontal preferred, vertical as fallback)
        let delta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            delta = event.scrollingDeltaX
        } else {
            delta = -event.scrollingDeltaY
        }

        let adjustedDelta = delta * scrollSensitivity

        // Accumulate scroll for smooth single-item advancement
        accumulatedScroll += adjustedDelta

        // Track velocity for momentum
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastScrollTime)
        if timeDelta > 0 && timeDelta < 0.1 {
            scrollVelocity = adjustedDelta / CGFloat(timeDelta)
        } else {
            scrollVelocity = adjustedDelta * 10
        }
        lastScrollTime = now

        // Threshold for changing selection (lower = more responsive)
        let threshold: CGFloat = 20

        if accumulatedScroll > threshold {
            let steps = Int(accumulatedScroll / threshold)
            let newIndex = max(0, selectedIndex - steps)
            if newIndex != selectedIndex {
                selectIndexLocally(newIndex)
            }
            accumulatedScroll = accumulatedScroll.truncatingRemainder(dividingBy: threshold)
        } else if accumulatedScroll < -threshold {
            let steps = Int(-accumulatedScroll / threshold)
            let newIndex = min(items.count - 1, selectedIndex + steps)
            if newIndex != selectedIndex {
                selectIndexLocally(newIndex)
            }
            accumulatedScroll = accumulatedScroll.truncatingRemainder(dividingBy: threshold)
        }

        // Start momentum if this is the end of a scroll gesture
        if event.phase == .ended || event.momentumPhase == .began {
            startMomentumScroll()
        }
    }

    // Local-first selection: animate immediately, defer SwiftUI notification until scroll stops
    private func selectIndexLocally(_ newIndex: Int) {
        guard newIndex != selectedIndex && newIndex >= 0 && newIndex < items.count else { return }
        selectedIndex = newIndex
        animateToSelection()

        // Only notify SwiftUI immediately if NOT scrolling
        // If scrolling, we'll notify when scroll settles
        if !isScrolling {
            DispatchQueue.main.async { [weak self] in
                self?.onSelect?(newIndex)
            }
        }
    }

    private func setScrolling(_ scrolling: Bool) {
        let wasScrolling = isScrolling
        isScrolling = scrolling
        scrollSettleTimer?.invalidate()
        scrollSettleTimer = nil

        if scrolling != wasScrolling {
            onScrollStateChange?(scrolling)
        }

        if scrolling {
            // Reset settle timer (100ms after last scroll event)
            scrollSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                self?.onScrollSettled()
            }
        }
    }

    private func onScrollSettled() {
        // Notify SwiftUI before flipping scroll state to avoid selection snap-back
        onSelect?(selectedIndex)
        setScrolling(false)

        // Ensure we maintain focus after scroll completes
        ensureFirstResponder()

        // Re-enable reflections on all visible covers
        for coverLayer in coverLayers {
            if let reflectionContainer = coverLayer.sublayers?.first(where: { $0.name == "reflectionContainer" }),
               let index = coverLayer.value(forKey: "itemIndex") as? Int,
               index < items.count {
                let item = items[index]
                let hasThumbnail = thumbnails[item.url] != nil
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.3)
                reflectionContainer.opacity = hasThumbnail ? 1.0 : 0.0
                CATransaction.commit()
            }
        }
    }

    private func startMomentumScroll() {
        guard abs(scrollVelocity) > 100 else {
            accumulatedScroll = 0
            onScrollSettled()
            return
        }

        momentumTimer?.invalidate()
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // Keep scroll state active
            self.setScrolling(true)

            // Apply friction (lower = longer momentum)
            self.scrollVelocity *= 0.94

            // Accumulate based on velocity
            let delta = self.scrollVelocity / 60.0
            self.accumulatedScroll += delta

            let threshold: CGFloat = 20

            if self.accumulatedScroll > threshold {
                let newIndex = max(0, self.selectedIndex - 1)
                if newIndex != self.selectedIndex {
                    self.selectIndexLocally(newIndex)
                }
                self.accumulatedScroll -= threshold
            } else if self.accumulatedScroll < -threshold {
                let newIndex = min(self.items.count - 1, self.selectedIndex + 1)
                if newIndex != self.selectedIndex {
                    self.selectIndexLocally(newIndex)
                }
                self.accumulatedScroll += threshold
            }

            // Stop when velocity is low enough
            if abs(self.scrollVelocity) < 50 {
                timer.invalidate()
                self.accumulatedScroll = 0
                self.onScrollSettled()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let hasCommand = event.modifierFlags.contains(.command)

        // Handle Command key shortcuts first
        if hasCommand {
            switch event.keyCode {
            case 8: // Cmd+C - Copy
                onCopy?()
                return
            case 7: // Cmd+X - Cut
                onCut?()
                return
            case 9: // Cmd+V - Paste
                onPaste?()
                return
            case 51: // Cmd+Backspace - Delete/Move to Trash
                onDelete?()
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 123: // Left arrow
            if selectedIndex > 0 {
                selectIndexLocally(selectedIndex - 1)
            }
        case 124: // Right arrow
            if selectedIndex < items.count - 1 {
                selectIndexLocally(selectedIndex + 1)
            }
        case 126: // Up arrow - previous (up in list = lower index)
            if selectedIndex > 0 {
                selectIndexLocally(selectedIndex - 1)
            }
        case 125: // Down arrow - next (down in list = higher index)
            if selectedIndex < items.count - 1 {
                selectIndexLocally(selectedIndex + 1)
            }
        case 36: // Return
            if selectedIndex >= 0 && selectedIndex < items.count {
                onOpen?(selectedIndex)
            }
        case 49: // Space - Quick Look
            if selectedIndex >= 0 && selectedIndex < items.count {
                onQuickLook?(items[selectedIndex])
            }
        case 51: // Delete/Backspace - remove last character from type-ahead buffer (without Cmd)
            if !typeAheadBuffer.isEmpty {
                typeAheadBuffer.removeLast()
                resetTypeAheadTimer()
                if !typeAheadBuffer.isEmpty {
                    jumpToMatch()
                }
            }
        case 53: // Escape - clear type-ahead buffer
            typeAheadBuffer = ""
            typeAheadTimer?.invalidate()
        default:
            // Handle type-ahead search for printable characters
            if let characters = event.characters, !characters.isEmpty {
                let char = characters.first!
                if char.isLetter || char.isNumber || char == " " || char == "." || char == "-" || char == "_" {
                    typeAheadBuffer.append(char)
                    resetTypeAheadTimer()
                    jumpToMatch()
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    private func resetTypeAheadTimer() {
        typeAheadTimer?.invalidate()
        typeAheadTimer = Timer.scheduledTimer(withTimeInterval: typeAheadTimeout, repeats: false) { [weak self] _ in
            self?.typeAheadBuffer = ""
        }
    }

    private func jumpToMatch() {
        guard !typeAheadBuffer.isEmpty else { return }

        let searchString = typeAheadBuffer.lowercased()

        // Find the first item that starts with the typed string
        if let matchIndex = items.firstIndex(where: { $0.name.lowercased().hasPrefix(searchString) }) {
            onSelect?(matchIndex)
        }
    }

    deinit {
        momentumTimer?.invalidate()
        typeAheadTimer?.invalidate()
        scrollSettleTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Allow both move and copy - the actual operation depends on Option key
        return [.move, .copy]
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTargeted = true
        updateDropTarget(from: sender)
        return currentDragOperation()
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(from: sender)
        return currentDragOperation()
    }

    private func currentDragOperation() -> NSDragOperation {
        guard dropTargetIndex != nil else { return .generic }
        // Option key = copy (shows + icon), otherwise move (no icon)
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
        clearDropTargetHighlight()
        dropTargetIndex = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Re-evaluate the drop target at the final location so hovering glitches don't lose the folder target
        let windowPoint = sender.draggingLocation
        let viewPoint = convert(windowPoint, from: nil)
        if dropTargetIndex == nil,
           let hoveredIndex = hitTestCover(at: viewPoint),
           hoveredIndex < items.count,
           items[hoveredIndex].isDirectory,
           !items[hoveredIndex].isFromArchive {
            dropTargetIndex = hoveredIndex
        }

        let targetIndex = dropTargetIndex
        isDropTargeted = false
        clearDropTargetHighlight()
        dropTargetIndex = nil

        // Collect URLs from pasteboard
        var urls: [URL] = []
        // Prefer reading as file URLs directly for reliability (Finder and internal drags)
        if let objectURLs = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            urls.append(contentsOf: objectURLs)
        }
        // Fallback to raw pasteboard items if needed
        if urls.isEmpty, let items = sender.draggingPasteboard.pasteboardItems {
            for item in items {
                if let urlString = item.string(forType: .fileURL) {
                    // fileURL comes percent-encoded; URL(string:) keeps it intact
                    if let url = URL(string: urlString) {
                        urls.append(url)
                    }
                }
            }
        }

        guard !urls.isEmpty else {
            return false
        }

        // If dropping on a folder, drop into that folder
        if let targetIndex = targetIndex,
           targetIndex < items.count,
           items[targetIndex].isDirectory,
           !items[targetIndex].isFromArchive {
            onDropToFolder?(urls, items[targetIndex].url)
            return true
        }

        // Otherwise drop to current directory
        onDrop?(urls)
        return true
    }

    private func updateDropTarget(from draggingInfo: NSDraggingInfo) {
        // Try both interpretations of the drag location to be resilient to external drag sources
        var candidateLocations: [NSPoint] = []
        candidateLocations.append(normalizedDragLocation(from: draggingInfo))

        if let window {
            let screenPoint = draggingInfo.draggingLocation
            let correctedWindowPoint = window.convertPoint(fromScreen: screenPoint)
            candidateLocations.append(convert(correctedWindowPoint, from: nil))
        }

        updateDropTarget(at: candidateLocations)
    }

    private func updateDropTarget(at location: NSPoint) {
        updateDropTarget(at: [location])
    }

    private func updateDropTarget(at locations: [NSPoint]) {
        let oldTargetIndex = dropTargetIndex
        var newTarget: Int?

        // Hit test to find which cover we're over (first matching location wins)
        for location in locations {
            if let index = hitTestCover(at: location),
               index < items.count,
               items[index].isDirectory,
               !items[index].isFromArchive {
                newTarget = index
                break
            }
        }

        dropTargetIndex = newTarget

        // Update highlighting if target changed
        if oldTargetIndex != dropTargetIndex {
            if let oldIndex = oldTargetIndex {
                updateCoverHighlight(at: oldIndex, highlighted: false)
            }
            if let newIndex = dropTargetIndex {
                updateCoverHighlight(at: newIndex, highlighted: true)
            }
        } else if let current = dropTargetIndex {
            // Re-apply every update so highlight survives layer refreshes
            updateCoverHighlight(at: current, highlighted: true)
        }
    }

    private func clearDropTargetHighlight() {
        hideDropTargetHighlight()
    }

    private func updateCoverHighlight(at index: Int, highlighted: Bool) {
        // Use a single overlay drawn above everything. This avoids 3D transform / z-order issues.
        if highlighted {
            showDropTargetHighlight(for: index)
        } else {
            hideDropTargetHighlight()
        }
    }

    private func ensureDropTargetHighlightLayer() -> CAShapeLayer? {
        guard let rootLayer = layer else { return nil }

        if let existing = dropTargetHighlightLayer {
            return existing
        }

        let highlight = CAShapeLayer()
        highlight.name = "dropTargetHighlightLayer"
        highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        highlight.strokeColor = NSColor.controlAccentColor.cgColor
        highlight.lineWidth = 5
        highlight.lineJoin = .round
        highlight.lineCap = .round
        highlight.zPosition = 200_000
        highlight.isHidden = true

        // Prevent implicit animations while dragging
        highlight.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "path": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]

        rootLayer.addSublayer(highlight)
        dropTargetHighlightLayer = highlight
        return highlight
    }

    private func showDropTargetHighlight(for index: Int) {
        guard let highlight = ensureDropTargetHighlightLayer() else { return }

        // Find the visible cover layer for this index
        guard let coverLayer = coverLayers.first(where: { ($0.value(forKey: "itemIndex") as? Int) == index }) else {
            highlight.isHidden = true
            return
        }

        let coverWidth = coverLayer.value(forKey: "coverWidth") as? CGFloat ?? coverLayer.bounds.width
        let coverHeight = coverLayer.value(forKey: "coverHeight") as? CGFloat ?? coverLayer.bounds.height

        // NOTE: This is an axis-aligned box in view coordinates. It’s intentionally simple and reliable.
        var frame = CGRect(
            x: coverLayer.position.x - coverWidth / 2,
            y: coverLayer.position.y - coverHeight / 2,
            width: coverWidth,
            height: coverHeight
        )
        frame = frame.insetBy(dx: -8, dy: -8)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = frame
        highlight.path = CGPath(roundedRect: highlight.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        highlight.isHidden = false
        highlight.opacity = 1
        CATransaction.commit()
    }

    private func hideDropTargetHighlight() {
        guard let highlight = dropTargetHighlightLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.isHidden = true
        CATransaction.commit()
    }

    /// Normalize dragging location so we handle both window and screen-based coordinates
    private func normalizedDragLocation(from draggingInfo: NSDraggingInfo) -> NSPoint {
        // Default: treat draggingLocation as window coords (AppKit standard)
        let windowPoint = draggingInfo.draggingLocation
        let viewPoint = convert(windowPoint, from: nil)

        // Some external drags report screen coordinates; fallback if the point is far outside our bounds
        if !bounds.insetBy(dx: -200, dy: -200).contains(viewPoint), let window {
            let screenPoint = draggingInfo.draggingLocation
            let correctedWindowPoint = window.convertPoint(fromScreen: screenPoint)
            return convert(correctedWindowPoint, from: nil)
        }

        return viewPoint
    }
}

extension CoverFlowNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Convert screen point to view coordinates
        guard let window = window else { return }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)

        // Check if we're still within this view
        if bounds.contains(viewPoint) {
            updateDropTarget(at: viewPoint)
        } else {
            // Clear highlight when dragging outside
            if dropTargetIndex != nil {
                clearDropTargetHighlight()
                dropTargetIndex = nil
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {

        guard let window = window else {
            clearDropTargetHighlight()
            dropTargetIndex = nil
            return
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)

        // Ensure we have the final hovered folder when the drag ends (for drags we originate)
        if dropTargetIndex == nil,
           let hoveredIndex = hitTestCover(at: viewPoint),
           hoveredIndex < items.count,
           items[hoveredIndex].isDirectory,
           !items[hoveredIndex].isFromArchive {
            dropTargetIndex = hoveredIndex
        }

        // Check if dropped within this view on a folder
        if bounds.contains(viewPoint), let targetIndex = dropTargetIndex {

            // Get the dragged URLs from the session
            var urls: [URL] = []
            session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { draggingItem, _, _ in
                if let pasteboardItem = draggingItem.item as? NSPasteboardItem,
                   let urlString = pasteboardItem.string(forType: .fileURL),
                   let url = URL(string: urlString) {
                    urls.append(url)
                }
            }

            if !urls.isEmpty && targetIndex < items.count && items[targetIndex].isDirectory && !items[targetIndex].isFromArchive {
                onDropToFolder?(urls, items[targetIndex].url)
            }
        }

        clearDropTargetHighlight()
        dropTargetIndex = nil
    }
}

// MARK: - Cover Flow Resize Handle

struct CoverFlowResizeHandle: View {
    let height: CGFloat
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color.secondary.opacity(0.7))
                .frame(width: 36, height: 3)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    onDrag(value.translation.height)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
    }
}

struct CoverFlowInfoHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - File List Section (using NSTableView)

struct FileListSection: View {
    let items: [FileItem]  // Already sorted by parent
    let selectedItems: Set<FileItem>
    let onSelect: (FileItem, Int) -> Void
    let onOpen: (FileItem) -> Void
    @ObservedObject var viewModel: FileBrowserViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @State private var isDropTargeted = false

    var body: some View {
        FileTableView(
            viewModel: viewModel,
            columnConfig: columnConfig,
            appSettings: appSettings,
            items: items
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
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

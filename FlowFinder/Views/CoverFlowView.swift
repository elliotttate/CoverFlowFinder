import SwiftUI
import QuickLookThumbnailing
import AppKit
import Quartz
import AVFoundation
import Combine

/// Simple reference-type flag so mutations are immediately visible
/// regardless of SwiftUI's @State batching.
private class SelectionFlag {
    var userClearedSelection = false
}

/// Thumbnail-loading bookkeeping. Kept in a reference type held by @State so that updating it
/// doesn't re-render the view; only `thumbnails` (what the covers show) is real view state.
private final class CoverFlowThumbnailState {
    /// What each displayed image is good for, and which requests are in flight
    var ledger = CoverFlowThumbnailLedger()
    /// This view's thumbnail requests, cancelled together (other views' requests are untouched)
    let requestOwner = ThumbnailRequestOwner()
    /// Finished thumbnails waiting for the next batched apply
    var pendingUpdates: [URL: NSImage] = [:]
    var batchTimer: Timer?
    /// Bumped when work is suspended; completions from older generations are dropped
    var generation = 0
    var isActive = true
    var isScrolling = false
    var passScheduled = false
    /// The last pass had to leave items for later (concurrency limit)
    var hasMoreWork = false
    var retryWorkItem: DispatchWorkItem?
    var settleWorkItem: DispatchWorkItem?
    var lastSelectionChangeTime: CFTimeInterval = 0
    /// Selection is changing faster than a pass is worth (key repeat): do the minimum until it settles
    var isRapidNavigation = false
    var lastHydrationRange: Range<Int>?
    /// Index of each displayed URL in `sortedItemsCache`
    var indexByURL: [URL: Int] = [:]
    var metadataRefreshScheduled = false
    var loadedFolderPath: URL?
    /// The centre cover's size in device pixels, reported by the AppKit view
    var centreCoverPixels: CGFloat = 0

    func rebuildIndex(for items: [FileItem]) {
        var index: [URL: Int] = [:]
        index.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            index[item.url] = offset
        }
        indexByURL = index
    }

    func suspend() {
        batchTimer?.invalidate()
        batchTimer = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        settleWorkItem?.cancel()
        settleWorkItem = nil
        pendingUpdates.removeAll()
        passScheduled = false
        isScrolling = false
        isRapidNavigation = false
        ledger.cancelAllRequests()
        ThumbnailCacheManager.shared.cancelRequests(for: requestOwner)
        generation &+= 1
    }
}

struct CoverFlowView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var sortedItemsCache: [FileItem] = []
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var dragStartCoverFlowHeight: CGFloat?
    @State private var liveCoverFlowHeight: CGFloat?
    @State private var infoPanelHeight: CGFloat = 0

    @State private var itemsToken: Int = 0
    @State private var selectionFlag = SelectionFlag()
    @State private var thumbState = CoverFlowThumbnailState()
    @State private var stripReference = CoverFlowViewReference()

    // Pending thumbnail updates are applied in batches to reduce re-renders
    private let thumbnailBatchInterval: TimeInterval = 0.1
    /// Selection changes closer together than this count as key repeat
    private let rapidNavigationInterval: CFTimeInterval = 0.12
    private let thumbnailPolicy = CoverFlowThumbnailPolicy()
    private let maxConcurrentThumbnails = 12
    private let maxConcurrentPreloadThumbnails = 8
    private let thumbnailCache = ThumbnailCacheManager.shared

    // Debug logging (set to false for release)
    private static let debugEnabled = ProcessInfo.processInfo.environment["FLOWFINDER_COVERFLOW_DEBUG"] == "1" ||
        UserDefaults.standard.bool(forKey: "flowfinder.debug.coverflow")
    private static var lastBodyTime: Date = .distantPast
    private static var bodyCallCount = 0
    private static let debugLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("flowfinder_debug.log")
    private static var debugLogHandle: FileHandle? = {
        guard debugEnabled else { return nil }
        FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
        return try? FileHandle(forWritingTo: debugLogURL)
    }()

    static var isDebugLoggingEnabled: Bool {
        debugEnabled
    }

    /// The message is only built when debug logging is on.
    static func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let line = "\(Date()): \(message())\n"
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
            Self.debugLog("[CoverFlow] BODY #\(Self.bodyCallCount) - \(String(format: "%.3f", interval))s | thumbs:\(thumbnails.count) items:\(sortedItemsCache.count)")
        }
    }

    private var thumbnailSizes: CoverFlowThumbnailSizing.Sizes {
        CoverFlowThumbnailSizing.sizes(
            coverScale: settings.coverFlowScaleValue,
            qualityValue: settings.thumbnailQualityValue,
            quality: CGFloat(settings.thumbnailQuality),
            centreCoverPixels: thumbState.centreCoverPixels
        )
    }

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
                    cutItemURLs: viewModel.cutItemURLs,
                    coverScale: settings.coverFlowScaleValue,
                    scrollSensitivity: settings.coverFlowSwipeSpeedValue,
                    currentFolderURL: canModifyCurrentFolder ? viewModel.currentPath : nil,
                    canModifyFolder: canModifyCurrentFolder,
                    canShowFolderInfo: canShowCurrentFolderInfo,
                    focusViewModel: viewModel,
                    reference: stripReference,
                    onSelect: { index, intent in
                        applySelection(at: index, intent: intent)
                    },
                    onBrowse: { index in
                        // Drag auto-scroll: the strip moves, the selection being dragged stays
                        if index < sortedItemsCache.count {
                            setCentredIndex(index)
                        }
                    },
                    onOpen: { index in
                        openFromStrip(at: index)
                    },
                    onOpenItems: { targets in
                        openItems(targets)
                    },
                    onItemCommand: { command, targets in
                        performItemCommand(command, on: targets)
                    },
                    onDeselect: {
                        selectionFlag.userClearedSelection = true
                        viewModel.selectedItems.removeAll()
                        viewModel.cancelPendingRename()
                        updateQuickLook(for: nil)
                    },
                    onDrop: { urls, operation in
                        viewModel.handleDrop(urls: urls, operation: operation)
                    },
                    onDropToFolder: { urls, folderURL, operation in
                        viewModel.handleDrop(urls: urls, to: folderURL, operation: operation)
                    },
                    onScrollStateChange: { scrolling in
                        DispatchQueue.main.async {
                            thumbState.isScrolling = scrolling
                            if !scrolling {
                                scheduleThumbnailPass()
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
                        guard canModifyCurrentFolder, viewModel.canPaste else {
                            NSSound.beep()
                            return
                        }
                        viewModel.paste()
                    },
                    canPaste: {
                        viewModel.canPaste
                    },
                    onDelete: {
                        viewModel.deleteSelectedItems()
                    },
                    onShowPackageContents: { item in
                        viewModel.navigateTo(item.url)
                    },
                    onQuickLook: { item in
                        toggleQuickLook(for: item)
                    },
                    onExtendSelect: { index in
                        selectionFlag.userClearedSelection = false
                        viewModel.coverFlowSelectedIndex = index
                        if index < sortedItemsCache.count {
                            viewModel.selectRange(to: index, in: sortedItemsCache)
                            updateQuickLook(for: sortedItemsCache[index])
                        }
                    },
                    onSelectAll: {
                        selectionFlag.userClearedSelection = false
                        // Keep the centred item as the lead of the selection
                        viewModel.lastSelectedIndex = viewModel.coverFlowSelectedIndex
                        viewModel.selectedItems = Set(sortedItemsCache)
                    },
                    onNewFolder: {
                        guard canModifyCurrentFolder else {
                            NSSound.beep()
                            return
                        }
                        viewModel.createNewFolder()
                    },
                    onGetInfo: {
                        showInfoForCurrentFolder()
                    },
                    onActivityStateChange: { isActive in
                        // Called from updateNSView; don't touch view state during the update
                        DispatchQueue.main.async {
                            handleCoverFlowActivityChange(isActive)
                        }
                    },
                    onCentreCoverPixelSizeChange: { pixels in
                        DispatchQueue.main.async {
                            guard thumbState.centreCoverPixels != pixels else { return }
                            thumbState.centreCoverPixels = pixels
                            scheduleThumbnailPass()
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
                    viewModel: viewModel,
                    onEmptySpaceClick: {
                        // Click on empty space - deselect all
                        selectionFlag.userClearedSelection = true
                        viewModel.selectedItems.removeAll()
                        viewModel.cancelPendingRename()
                        updateQuickLook(for: nil)
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            thumbState.isActive = true
            thumbState.loadedFolderPath = viewModel.currentPath
            // Cover Flow handles its own keys: a handler registered in this window by the view it
            // replaces mustn't take them (the strip also does this when it joins a window)
            if let window = stripReference.window {
                KeyboardManager.shared.suspendHandlers(in: window)
            }
            updateSortedItems(using: items, updateToken: true, newToken: viewModel.coverFlowItemsToken)
            syncSelection(pruningHiddenItems: true)
            scheduleThumbnailPass()
        }
        .onDisappear {
            thumbState.isActive = false
            suspendCoverFlowWork()
        }
        .onChange(of: items) { _, newItems in
            handleItemsChange(newItems)
        }
        // FileItem equality is URL-only, so metadata hydration and in-place edits don't trigger
        // onChange(of: items). Re-read the items whenever the view model replaces them.
        .onReceive(viewModel.$items) { _ in
            scheduleMetadataRefresh()
        }
        .onReceive(viewModel.$searchResults) { _ in
            scheduleMetadataRefresh()
        }
        .onChange(of: viewModel.coverFlowSelectedIndex) { _, _ in
            noteSelectionChange()
            updateQuickLookForSelection()
        }
        .onChange(of: viewModel.selectedItems) { oldSelection, newSelection in
            // Sync Cover Flow selection when file list selection changes
            if newSelection.isEmpty {
                // Emptied while its items are still shown: the user deselected (⌘-click in the
                // list, a click on empty space). Keep it that way until something is selected.
                if oldSelection.contains(where: { thumbState.indexByURL[$0.url] != nil }) {
                    selectionFlag.userClearedSelection = true
                }
                updateQuickLook(for: nil)
            } else {
                selectionFlag.userClearedSelection = false
                syncSelection()
            }
        }
        .onPreferenceChange(CoverFlowInfoHeightKey.self) { newValue in
            if newValue > 0 {
                infoPanelHeight = newValue
            }
        }
        .onChange(of: settings.coverFlowScale) { _, _ in
            scheduleThumbnailPass()
        }
        .onChange(of: settings.thumbnailQuality) { _, _ in
            scheduleThumbnailPass()
        }
    }

    // MARK: - Items

    private func handleItemsChange(_ newItems: [FileItem]) {
        let newToken = viewModel.coverFlowItemsToken
        let tokenChanged = itemsToken != newToken
        let orderChanged = !sortedItemsCache.elementsEqual(newItems) { $0.url == $1.url }
        Self.debugLog("[CoverFlow] onChange(items) old:\(sortedItemsCache.count) new:\(newItems.count) tokenChanged:\(tokenChanged) orderChanged:\(orderChanged)")

        // A different folder in the same view: a deselection made in the last one doesn't carry over
        let folderChanged = tokenChanged && viewModel.currentPath != thumbState.loadedFolderPath
        if folderChanged {
            selectionFlag.userClearedSelection = false
        }

        // Update sortedItemsCache and selection synchronously so the embedded table
        // has the correct items for selection/navigation immediately (e.g. after deletion).
        // Items the list no longer shows (filtered out, gone) leave the selection, as in Finder:
        // nothing hidden may be acted on.
        updateSortedItems(using: newItems, updateToken: tokenChanged, newToken: newToken)
        syncSelection(pruningHiddenItems: true)

        if tokenChanged {
            if folderChanged {
                // Start over (cancels only our requests)
                thumbState.loadedFolderPath = viewModel.currentPath
                thumbState.suspend()
                thumbState.ledger.removeAll()
                thumbState.lastHydrationRange = nil
                thumbnails = [:]
            } else if !newItems.isEmpty {
                // Adds, renames, deletions and refreshes: keep the thumbnails of items still shown.
                // (A reload empties the list first; keep everything through that.)
                retainThumbnailsForDisplayedItems()
            }
            scheduleThumbnailPass()
        } else if orderChanged {
            scheduleThumbnailPass()
        }
    }

    private func retainThumbnailsForDisplayedItems() {
        let state = thumbState
        state.ledger.retain { state.indexByURL[$0] != nil }
        state.pendingUpdates = state.pendingUpdates.filter { state.indexByURL[$0.key] != nil }
        let removed = thumbnails.keys.filter { state.indexByURL[$0] == nil }
        guard !removed.isEmpty else { return }
        var newThumbnails = thumbnails
        for url in removed {
            newThumbnails.removeValue(forKey: url)
        }
        thumbnails = newThumbnails
    }

    private func scheduleMetadataRefresh() {
        let state = thumbState
        guard !state.metadataRefreshScheduled else { return }
        state.metadataRefreshScheduled = true
        // @Published fires before the new value is stored; read it on the next turn
        DispatchQueue.main.async {
            refreshItemMetadata()
        }
    }

    /// Picks up new metadata (hydration, cloud status, in-place edits) for the same items in the
    /// same order. Structural changes go through `handleItemsChange` instead.
    private func refreshItemMetadata() {
        thumbState.metadataRefreshScheduled = false
        let cached = sortedItemsCache
        let fresh = viewModel.filteredItems
        guard !fresh.isEmpty, fresh.count == cached.count else { return }
        var metadataChanged = false
        for (freshItem, cachedItem) in zip(fresh, cached) {
            guard freshItem.url == cachedItem.url else { return }
            if !metadataChanged && freshItem.contentVersion != cachedItem.contentVersion {
                metadataChanged = true
            }
        }
        guard metadataChanged else { return }
        sortedItemsCache = fresh
        // Thumbnails of items whose content changed are reloaded by the next pass
        scheduleThumbnailPass()
    }

    private func handleCoverFlowActivityChange(_ isActive: Bool) {
        guard thumbState.isActive != isActive else { return }
        thumbState.isActive = isActive

        if isActive {
            resumeCoverFlowWork()
        } else {
            suspendCoverFlowWork()
        }
    }

    private func suspendCoverFlowWork() {
        thumbState.suspend()
    }

    private func resumeCoverFlowWork() {
        guard !sortedItemsCache.isEmpty else { return }
        scheduleThumbnailPass()
    }

    private func updateSortedItems(using newItems: [FileItem], updateToken: Bool, newToken: Int? = nil) {
        Self.debugLog("[SELECTION] updateSortedItems: newItems.count=\(newItems.count), currentIndex=\(viewModel.coverFlowSelectedIndex), updateToken=\(updateToken)")

        sortedItemsCache = newItems
        thumbState.rebuildIndex(for: newItems)
        if updateToken {
            itemsToken = newToken ?? viewModel.coverFlowItemsToken
        }

        // Nothing to centre on when empty
        guard !newItems.isEmpty else { return }

        if let primary = viewModel.primarySelectedItem,
           let index = thumbState.indexByURL[primary.url] {
            setCentredIndex(index)
        } else if viewModel.coverFlowSelectedIndex >= newItems.count {
            // Only clamp if index is out of bounds, don't reset unnecessarily
            setCentredIndex(max(0, newItems.count - 1))
        }
    }

    private func setCentredIndex(_ index: Int) {
        if viewModel.coverFlowSelectedIndex != index {
            viewModel.coverFlowSelectedIndex = index
        }
    }

    // MARK: - Selection

    /// Selection flows one way: the view model's lead item decides which cover is centred.
    /// `pruningHiddenItems`: the displayed items just changed; drop selected items no longer shown.
    private func syncSelection(pruningHiddenItems: Bool = false) {
        Self.debugLog("[SELECTION] syncSelection: items=\(sortedItemsCache.count), index=\(viewModel.coverFlowSelectedIndex), selected=\(viewModel.selectedItems.count)")

        if pruningHiddenItems {
            pruneSelectionToDisplayedItems()
        }

        guard !sortedItemsCache.isEmpty else { return }

        // Clamp index to valid range
        let safeIndex = min(max(0, viewModel.coverFlowSelectedIndex), sortedItemsCache.count - 1)
        setCentredIndex(safeIndex)

        if viewModel.selectedItems.isEmpty {
            if selectionFlag.userClearedSelection {
                updateQuickLook(for: nil)
                return
            }
            selectCentredItemOnly(at: safeIndex)
            return
        }

        if let primary = viewModel.primarySelectedItem,
           let index = thumbState.indexByURL[primary.url] {
            setCentredIndex(index)
            return
        }

        // The lead item isn't displayed: centre on the first selected item that is,
        // without collapsing the selection.
        if let firstShown = viewModel.selectedItems.compactMap({ thumbState.indexByURL[$0.url] }).min() {
            setCentredIndex(firstShown)
            return
        }

        // Transient state: the selected item is in the incoming items but sortedItemsCache
        // hasn't caught up yet (e.g. new folder just created). Wait for the cache to sync.
        if let primary = viewModel.primarySelectedItem, items.contains(primary) {
            return
        }

        // None of the selected items is shown any more
        selectCentredItemOnly(at: safeIndex)
    }

    /// Keeps only the selected items the strip shows (Finder: filtering deselects what it hides),
    /// so Copy, Move to Trash and the rest never act on items the user can't see.
    private func pruneSelectionToDisplayedItems() {
        let selected = viewModel.selectedItems
        guard !selected.isEmpty else { return }
        let shown = selected.filter { thumbState.indexByURL[$0.url] != nil }
        guard shown.count != selected.count else { return }
        viewModel.selectedItems = shown
    }

    private func selectCentredItemOnly(at index: Int) {
        let item = sortedItemsCache[index]
        viewModel.selectedItems = [item]
        viewModel.lastSelectedIndex = index
        viewModel.selectionAnchorIndex = index
        updateQuickLook(for: item)
    }

    /// Applies a selection made in the cover strip. The intent comes from the triggering event,
    /// never from the live keyboard state.
    private func applySelection(at index: Int, intent: CoverFlowSelectionIntent) {
        guard index >= 0, index < sortedItemsCache.count else { return }
        viewModel.coverFlowSelectedIndex = index
        let item = sortedItemsCache[index]
        viewModel.handleSelection(
            item: item,
            index: index,
            in: sortedItemsCache,
            withShift: intent.extendsRange,
            withCommand: intent.toggles,
            allowRename: false  // Disable click-to-rename in CoverFlow
        )
        // A ⌘-click that deselected the last item is an explicit deselection: keep it
        selectionFlag.userClearedSelection = viewModel.selectedItems.isEmpty
        updateQuickLook(for: item)
    }

    // MARK: - Location

    /// Whether the folder shown takes drops, pastes and new folders — the same rule as the list's
    /// drop delegate: not inside an archive, the Photos library, the Network browser or Spotlight
    /// results (which come from many folders; the search's root isn't where they are).
    private var canModifyCurrentFolder: Bool {
        !viewModel.isInsideArchive
            && !viewModel.isPhotosLibraryActive
            && viewModel.currentPath.isFileURL
            && viewModel.currentPath.path != "/Network"
            && !isShowingSearchResults
    }

    /// Whether the background menu's Get Info has a folder to describe.
    private var canShowCurrentFolderInfo: Bool {
        !viewModel.isInsideArchive && viewModel.currentPath.isFileURL && !isShowingSearchResults
    }

    private var isShowingSearchResults: Bool {
        viewModel.searchMode == .finder && !viewModel.searchText.isEmpty
    }

    // MARK: - Actions

    /// Return, ⌘↓ and double-click. Like the list, an item of a multi-selection opens all of it.
    private func openFromStrip(at index: Int) {
        guard index >= 0, index < sortedItemsCache.count else { return }
        let item = sortedItemsCache[index]
        if viewModel.selectedItems.count > 1, viewModel.selectedItems.contains(item) {
            FileListActions.open(viewModel.orderedSelectedItems, primary: item, viewModel: viewModel)
        } else {
            viewModel.openItem(item)
        }
    }

    /// Opens what a menu (or a double-click on a multi-selection) named, if it's still shown.
    private func openItems(_ targets: [FileItem]) {
        let shown = displayedItems(of: targets)
        guard let first = shown.first else { return }
        if shown.count > 1 {
            // A double-click collapsed the selection on its first click: it's still what's open
            selectTargets(shown)
        }
        // The lead item (the one clicked) is the folder entered if several are opened
        let primary = viewModel.primarySelectedItem.flatMap { shown.contains($0) ? $0 : nil } ?? first
        FileListActions.open(shown, primary: primary, viewModel: viewModel)
    }

    private func displayedItems(of targets: [FileItem]) -> [FileItem] {
        targets.filter { thumbState.indexByURL[$0.url] != nil }
    }

    /// Makes `targets` the selection (normally they already are), so the view model's selection
    /// commands act on exactly what the menu showed — never on selected items it didn't.
    private func selectTargets(_ targets: [FileItem]) {
        let selection = Set(targets)
        guard viewModel.selectedItems != selection else { return }
        selectionFlag.userClearedSelection = false
        viewModel.selectedItems = selection
    }

    /// A cover context-menu command, on the items the menu was built for.
    private func performItemCommand(_ command: CoverFlowItemCommand, on targets: [FileItem]) {
        let items = displayedItems(of: targets)
        guard let first = items.first else {
            NSSound.beep()
            return
        }
        switch command {
        case .copy:
            selectTargets(items)
            viewModel.copySelectedItems()
        case .cut:
            selectTargets(items)
            viewModel.cutSelectedItems()
        case .duplicate:
            selectTargets(items)
            viewModel.duplicateSelectedItems()
        case .moveToTrash:
            selectTargets(items)
            viewModel.deleteSelectedItems()
        case .getInfo:
            viewModel.presentInfo(for: first)
        case .rename:
            // The embedded list edits the name in place
            guard items.count == 1, !first.isFromArchive else {
                NSSound.beep()
                return
            }
            selectTargets(items)
            viewModel.renamingURL = first.url
        case .quickLook:
            toggleQuickLook(for: first)
        case .toggleTag(let tagName):
            // Adds the tag to every item, or removes it from all of them if they all have it
            let editable = items.filter { !$0.isFromArchive }
            let allTagged = editable.allSatisfy { $0.tags.contains(tagName) }
            for item in editable {
                var tags = item.tags
                if allTagged {
                    tags.removeAll { $0 == tagName }
                } else if !tags.contains(tagName) {
                    tags.append(tagName)
                } else {
                    continue
                }
                viewModel.setTags(tags, for: item.url)
            }
        case .removeAllTags:
            for item in items where !item.isFromArchive && !item.tags.isEmpty {
                viewModel.setTags([], for: item.url)
            }
        }
    }

    private func showInfoForCurrentFolder() {
        guard canShowCurrentFolderInfo else {
            NSSound.beep()
            return
        }
        viewModel.presentInfo(for: FileItem(url: viewModel.currentPath))
    }

    // MARK: - Quick Look

    private func toggleQuickLook(for item: FileItem) {
        let reference = stripReference
        viewModel.previewURL(for: item) { previewURL in
            guard let previewURL = previewURL else {
                NSSound.beep()
                return
            }
            // Weak: the shared controller must not keep a closed tab's strip alive
            QuickLookControllerView.shared.togglePreview(for: previewURL, in: reference.window) { [weak strip = reference.view] offset in
                strip?.navigateQuickLook(by: offset)
            }
        }
    }

    /// Shows `item` in an open Quick Look panel, if the panel belongs to this window.
    private func updateQuickLook(for item: FileItem?) {
        // Closed panel: nothing to do (and no preview file to prepare)
        guard QuickLookControllerView.isPanelVisible, let window = stripReference.window else { return }
        let previewURL = item.flatMap { viewModel.previewURL(for: $0) }
        QuickLookControllerView.shared.updatePreview(for: previewURL, from: window)
    }

    private func updateQuickLookForSelection() {
        guard !sortedItemsCache.isEmpty else {
            updateQuickLook(for: nil)
            return
        }
        let index = min(max(0, viewModel.coverFlowSelectedIndex), sortedItemsCache.count - 1)
        updateQuickLook(for: sortedItemsCache[index])
    }

    // MARK: - Thumbnails

    private func noteSelectionChange() {
        let state = thumbState
        let now = CACurrentMediaTime()
        state.isRapidNavigation = now - state.lastSelectionChangeTime < rapidNavigationInterval
        state.lastSelectionChangeTime = now
        scheduleThumbnailPass()

        // During key repeat only the covers on screen are served; do the rest once it settles
        state.settleWorkItem?.cancel()
        state.settleWorkItem = nil
        if state.isRapidNavigation {
            let workItem = DispatchWorkItem {
                state.settleWorkItem = nil
                state.isRapidNavigation = false
                scheduleThumbnailPass()
            }
            state.settleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }
    }

    /// Coalesces requests: at most one pass is pending, and it runs on the next turn of the run loop.
    private func scheduleThumbnailPass() {
        let state = thumbState
        guard state.isActive, !state.passScheduled else { return }
        state.passScheduled = true
        DispatchQueue.main.async {
            runThumbnailPass()
        }
    }

    private func scheduleRetryPass(after delay: TimeInterval) {
        let state = thumbState
        guard state.retryWorkItem == nil else { return }
        let workItem = DispatchWorkItem {
            state.retryWorkItem = nil
            scheduleThumbnailPass()
        }
        state.retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Brings the thumbnails around the centred cover up to the resolution their distance needs
    /// and releases what's no longer needed. Items whose image is already good enough for their
    /// content version are skipped without touching the thumbnail cache.
    private func runThumbnailPass() {
        let state = thumbState
        state.passScheduled = false
        guard state.isActive, !sortedItemsCache.isEmpty else { return }

        let items = sortedItemsCache
        let count = items.count
        let selected = min(max(0, viewModel.coverFlowSelectedIndex), count - 1)
        let sizes = thumbnailSizes
        let policy = thumbnailPolicy
        let rapid = state.isRapidNavigation
        let now = CACurrentMediaTime()
        state.ledger.pruneStaleRequests(now: now)

        var updates: [URL: NSImage] = [:]
        var removals: [URL] = []

        // 1. Memory: release images far from the centre, and swap oversized ones for smaller copies
        if !rapid {
            for url in thumbnails.keys {
                guard let index = state.indexByURL[url] else {
                    removals.append(url)
                    continue
                }
                let distance = abs(index - selected)
                guard let maxSize = policy.maxRetainedPixelSize(distance: distance, sizes: sizes) else {
                    removals.append(url)
                    continue
                }
                guard let entry = state.ledger.entry(for: url), !entry.isFinal, entry.pixelSize > maxSize else { continue }
                let item = items[index]
                let version = item.contentVersion
                if let smaller = thumbnailCache.cachedThumbnail(for: item, maxPixelSize: maxSize) {
                    updates[url] = smaller
                    state.ledger.replace(url, version: version, pixelSize: maxSize)
                } else if maxSize > sizes.low, let low = thumbnailCache.cachedThumbnail(for: item, maxPixelSize: sizes.low) {
                    updates[url] = low
                    state.ledger.replace(url, version: version, pixelSize: sizes.low)
                } else if distance > policy.highRadius {
                    // Not on screen; it'll be reloaded if it comes back
                    removals.append(url)
                }
            }
            for url in removals {
                state.ledger.remove(url)
                state.pendingUpdates.removeValue(forKey: url)
            }
        }

        // 2. Load what each cover needs, nearest first
        let scrolling = state.isScrolling
        var highBudget = (scrolling ? 6 : maxConcurrentThumbnails) - state.ledger.activeRequestCount { $0 > sizes.low }
        var lowBudget = (scrolling ? 4 : maxConcurrentPreloadThumbnails) - state.ledger.activeRequestCount { $0 <= sizes.low }
        var requests: [(item: FileItem, pixelSize: CGFloat)] = []
        var hasMore = false
        let radius = rapid ? policy.highRadius : policy.preloadRadius

        for distance in 0...radius {
            let candidates = distance == 0 ? [selected] : [selected - distance, selected + distance]
            for index in candidates where index >= 0 && index < count {
                let item = items[index]
                let url = item.url
                guard let required = policy.requiredPixelSize(distance: distance, sizes: sizes, rapid: rapid) else { continue }
                let version = item.contentVersion
                let hasImage = updates[url] != nil || thumbnails[url] != nil || state.pendingUpdates[url] != nil
                if hasImage && state.ledger.isSatisfied(url, version: version, pixelSize: required) {
                    continue
                }

                if item.isFromArchive {
                    // Archive entries only ever get their type icon; settle them so passes stop
                    updates[url] = item.placeholderIcon
                    state.ledger.markFinal(url, version: version)
                    continue
                }

                if state.ledger.isRequested(url, version: version, atLeast: required) {
                    continue
                }

                // Memory cache only; disk-cache hits arrive through the request below
                if let cached = thumbnailCache.cachedThumbnail(for: item, maxPixelSize: required) {
                    updates[url] = cached
                    state.ledger.markSettled(url, version: version, pixelSize: required)
                    continue
                }

                // Show a cheap low-resolution copy while the full one loads
                if !hasImage, required > sizes.low,
                   let low = thumbnailCache.cachedThumbnail(for: item, maxPixelSize: sizes.low) {
                    updates[url] = low
                    state.ledger.markSettled(url, version: version, pixelSize: sizes.low)
                }

                if required > sizes.low {
                    guard highBudget > 0 else { hasMore = true; continue }
                    highBudget -= 1
                } else {
                    guard lowBudget > 0 else { hasMore = true; continue }
                    lowBudget -= 1
                }
                state.ledger.beginRequest(url, version: version, pixelSize: required, now: now)
                requests.append((item, required))
            }
        }

        if !rapid {
            hydrateMetadata(around: selected, radius: policy.preloadRadius, items: items)
        }

        if !removals.isEmpty || !updates.isEmpty {
            var newThumbnails = thumbnails
            for url in removals {
                newThumbnails.removeValue(forKey: url)
            }
            newThumbnails.merge(updates) { _, new in new }
            thumbnails = newThumbnails
        }

        for request in requests {
            requestThumbnail(for: request.item, pixelSize: request.pixelSize)
        }

        // Completions schedule the next pass; if every slot is taken, look again shortly
        // (requests that never complete go stale in the ledger and are retried).
        state.hasMoreWork = hasMore
        if hasMore && requests.isEmpty {
            scheduleRetryPass(after: 0.5)
        }
    }

    private func requestThumbnail(for item: FileItem, pixelSize: CGFloat) {
        let state = thumbState
        let generation = state.generation
        let version = item.contentVersion
        let url = item.url

        // The completion can run synchronously (memory hit, known failure); always handle it on
        // the next turn so it never mutates state in the middle of a pass.
        thumbnailCache.requestThumbnail(for: item, maxPixelSize: pixelSize, owner: state.requestOwner) { result in
            DispatchQueue.main.async {
                guard generation == state.generation, state.isActive else { return }
                state.ledger.finishRequest(url, pixelSize: pixelSize)

                // Drop results for content that changed (or left) since the request
                guard let index = state.indexByURL[url], index < sortedItemsCache.count,
                      CoverFlowThumbnailLedger.isSameContent(sortedItemsCache[index].contentVersion, version) else {
                    scheduleThumbnailPass()
                    return
                }

                let hasImage = thumbnails[url] != nil || state.pendingUpdates[url] != nil
                switch result {
                case .cancelled:
                    // Not settled: the next pass asks again if the cover still needs it
                    break
                case .failed:
                    // Keep any image we have rather than replacing it with a generic icon
                    if !hasImage {
                        state.pendingUpdates[url] = item.placeholderIcon
                        scheduleThumbnailBatch()
                    }
                    state.ledger.markFinal(url, version: version)
                case .loaded(let image):
                    if let existing = state.ledger.entry(for: url),
                       CoverFlowThumbnailLedger.isSameContent(existing.version, version),
                       existing.isFinal || existing.pixelSize > pixelSize {
                        // Something better arrived first
                        break
                    }
                    state.pendingUpdates[url] = image
                    state.ledger.markSettled(url, version: version, pixelSize: pixelSize)
                    scheduleThumbnailBatch()
                }

                if state.hasMoreWork {
                    scheduleThumbnailPass()
                }
            }
        }
    }

    /// Requests metadata for the items around the centre. The range is aligned to chunks so the
    /// request only changes every few covers instead of on every step.
    private func hydrateMetadata(around selected: Int, radius: Int, items: [FileItem]) {
        let chunk = 32
        let lower = max(0, selected - radius) / chunk * chunk
        let upper = min(items.count, (min(items.count - 1, selected + radius) / chunk + 1) * chunk)
        guard lower < upper else { return }
        let range = lower..<upper
        guard range != thumbState.lastHydrationRange else { return }
        thumbState.lastHydrationRange = range

        var urlsToHydrate: [URL] = []
        for item in items[range] where viewModel.needsHydration(item) {
            urlsToHydrate.append(item.url)
        }
        if !urlsToHydrate.isEmpty {
            viewModel.hydrateMetadata(for: urlsToHydrate)
        }
    }

    private func scheduleThumbnailBatch() {
        let state = thumbState
        guard state.isActive else { return }
        // If timer already scheduled, let it handle the batch
        guard state.batchTimer == nil else { return }

        state.batchTimer = Timer.scheduledTimer(withTimeInterval: thumbnailBatchInterval, repeats: false) { [self] _ in
            flushPendingThumbnails()
        }
    }

    private func flushPendingThumbnails() {
        let state = thumbState
        state.batchTimer?.invalidate()
        state.batchTimer = nil

        guard state.isActive, !state.pendingUpdates.isEmpty else {
            state.pendingUpdates.removeAll()
            return
        }

        Self.debugLog("[CoverFlow] FLUSH \(state.pendingUpdates.count) pending thumbnails")

        // Apply all pending updates in one batch
        var newThumbnails = thumbnails
        newThumbnails.merge(state.pendingUpdates) { _, new in new }
        state.pendingUpdates.removeAll()
        thumbnails = newThumbnails
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
}

// MARK: - Native AppKit Cover Flow Container

struct CoverFlowContainer: NSViewRepresentable {
    let items: [FileItem]
    let itemsToken: Int
    @Binding var selectedIndex: Int
    let thumbnails: [URL: NSImage]
    let thumbnailCount: Int  // Explicit count to force SwiftUI updates
    let navigationGeneration: Int  // Forces update on every navigation
    let selectedItems: Set<FileItem>  // Multi-selection for drag and context menus
    let cutItemURLs: Set<URL>  // URLs of items marked for cut (dimmed)
    let coverScale: CGFloat
    let scrollSensitivity: CGFloat
    let currentFolderURL: URL?  // Destination for drops onto the background (nil where nothing can be dropped)
    let canModifyFolder: Bool
    let canShowFolderInfo: Bool
    let focusViewModel: FileBrowserViewModel  // Identifies this view to `.focusFileList` posters
    let reference: CoverFlowViewReference
    let onSelect: (Int, CoverFlowSelectionIntent) -> Void
    let onBrowse: (Int) -> Void  // Centre a cover without selecting it (drag auto-scroll)
    let onOpen: (Int) -> Void
    let onOpenItems: ([FileItem]) -> Void
    let onItemCommand: (CoverFlowItemCommand, [FileItem]) -> Void
    let onDeselect: () -> Void
    let onDrop: ([URL], FileDropOperation) -> Void
    let onDropToFolder: ([URL], URL, FileDropOperation) -> Void  // Drop to specific folder
    let onScrollStateChange: (Bool) -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let canPaste: () -> Bool
    let onDelete: () -> Void
    let onShowPackageContents: (FileItem) -> Void
    let onQuickLook: (FileItem) -> Void
    let onExtendSelect: (Int) -> Void  // Shift+arrow range selection
    let onSelectAll: () -> Void
    let onNewFolder: () -> Void
    let onGetInfo: () -> Void  // Get Info for the current folder
    let onActivityStateChange: (Bool) -> Void
    let onCentreCoverPixelSizeChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> CoverFlowNSView {
        let view = CoverFlowNSView()
        view.applySwiftUIUpdate {
            configure(view)
            view.updateItems(items, itemsToken: itemsToken, thumbnails: thumbnails, selectedIndex: selectedIndex)
        }
        return view
    }

    func updateNSView(_ nsView: CoverFlowNSView, context: Context) {
        // Preserve first responder status during updates
        let wasFirstResponder = nsView.window?.firstResponder === nsView

        let cutURLsChanged = nsView.cutItemURLs != cutItemURLs
        nsView.applySwiftUIUpdate {
            configure(nsView)
            nsView.updateItems(items, itemsToken: itemsToken, thumbnails: thumbnails, selectedIndex: selectedIndex)
            if cutURLsChanged {
                nsView.updateCutItemOpacity()
            }
            nsView.updateActivityState()
        }

        // Restore first responder only if CoverFlowNSView was the first responder before update
        // Don't steal focus from other views like the search field
        if wasFirstResponder && nsView.window?.firstResponder !== nsView {
            CoverFlowView.debugLog("[Container] Focus lost during updateNSView - restoring")
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    private func configure(_ view: CoverFlowNSView) {
        reference.view = view
        view.onSelect = onSelect
        view.onBrowse = onBrowse
        view.onOpen = onOpen
        view.onOpenItems = onOpenItems
        view.onItemCommand = onItemCommand
        view.onDeselect = onDeselect
        view.onDrop = onDrop
        view.onDropToFolder = onDropToFolder
        view.onScrollStateChange = onScrollStateChange
        view.onCopy = onCopy
        view.onCut = onCut
        view.onPaste = onPaste
        view.canPaste = canPaste
        view.onDelete = onDelete
        view.onShowPackageContents = onShowPackageContents
        view.onQuickLook = onQuickLook
        view.onExtendSelect = onExtendSelect
        view.onSelectAll = onSelectAll
        view.onNewFolder = onNewFolder
        view.onGetInfo = onGetInfo
        view.onActivityStateChange = onActivityStateChange
        view.onCentreCoverPixelSizeChange = onCentreCoverPixelSizeChange
        view.selectedItems = selectedItems
        view.cutItemURLs = cutItemURLs
        view.coverScale = coverScale
        view.scrollSensitivity = scrollSensitivity
        view.currentFolderURL = currentFolderURL
        view.canModifyFolder = canModifyFolder
        view.canShowFolderInfo = canShowFolderInfo
        view.focusViewModel = focusViewModel
    }
}

/// The AppKit strip behind a `CoverFlowView`, for its SwiftUI side (which window it's in).
final class CoverFlowViewReference {
    weak var view: CoverFlowNSView?

    var window: NSWindow? { view?.window }
}

/// What a cover's context menu does to the items it was opened on.
enum CoverFlowItemCommand: Equatable {
    case copy
    case cut
    case duplicate
    case moveToTrash
    case getInfo
    case rename
    case quickLook
    case toggleTag(String)
    case removeAllTags
}

/// A cover context-menu item's represented object: the command and the items it acts on.
final class CoverFlowMenuAction: NSObject {
    let command: CoverFlowItemCommand
    let targets: [FileItem]

    init(_ command: CoverFlowItemCommand, targets: [FileItem]) {
        self.command = command
        self.targets = targets
    }
}

class CoverFlowNSView: NSView, OpenWithActionTarget {
    var onSelect: ((Int, CoverFlowSelectionIntent) -> Void)?
    var onBrowse: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    var onOpenItems: (([FileItem]) -> Void)?
    var onItemCommand: ((CoverFlowItemCommand, [FileItem]) -> Void)?
    var onDeselect: (() -> Void)?
    var onScrollStateChange: ((Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var canPaste: (() -> Bool)?
    var onDelete: (() -> Void)?
    var onShowPackageContents: ((FileItem) -> Void)?
    var onQuickLook: ((FileItem) -> Void)?
    var onExtendSelect: ((Int) -> Void)?  // Shift+arrow range selection
    var onSelectAll: (() -> Void)?
    var onNewFolder: (() -> Void)?
    var onGetInfo: (() -> Void)?
    var onActivityStateChange: ((Bool) -> Void)?
    var onCentreCoverPixelSizeChange: ((CGFloat) -> Void)?
    var selectedItems: Set<FileItem> = []  // Track multi-selection for drag
    var cutItemURLs: Set<URL> = []  // URLs of items marked for cut (dimmed)
    var currentFolderURL: URL?
    var canModifyFolder = true
    var canShowFolderInfo = true
    /// The view model this view shows; a `.focusFileList` notification may name it (or a window).
    weak var focusViewModel: FileBrowserViewModel?

    private var items: [FileItem] = []
    private var itemsToken: Int = 0
    private var thumbnails: [URL: NSImage] = [:]
    /// The centred cover
    private(set) var selectedIndex: Int = 0
    /// The centred index SwiftUI last asked for (the view model's); the strip leads while scrolling
    private var requestedIndex: Int = 0
    private var coverLayers: [CALayer] = []
    private var layerPool: [CALayer] = []  // Reusable layer pool
    private var backgroundLayer: CAGradientLayer?
    private var lastClickTime: Date = .distantPast
    private var lastClickIndex: Int = -1
    private var lastClickLocation: CGPoint = .zero
    /// A plain click on an item of a multi-selection keeps the selection (for dragging) and
    /// collapses it to that item on mouse-up if no drag started
    private var pendingCollapseIndex: Int?
    /// The selection a click just collapsed, so a double-click opens all of it (like the list)
    private var collapsedSelection: (index: Int, items: [FileItem])?
    /// Identity of the last mouse-down handled, to drop a re-delivery of the same click
    private var lastMouseDownIdentity: (timestamp: TimeInterval, eventNumber: Int, clickCount: Int)?

    // Scrolling
    private var isScrolling = false
    private var isViewActive = false
    private var scrollSettleTimer: Timer?
    private var scrollAccumulator = CoverFlowScrollAccumulator()
    /// The centred item when the current scroll began: settling only selects if it changed
    private var scrollStartURL: URL?

    // Type-ahead search
    private var typeAheadBuffer: String = ""
    private var typeAheadTimer: Timer?
    private let typeAheadTimeout: TimeInterval = 1.0
    private let pageStep = 10

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
        CoverFlowGeometry.baseCoverSize(viewSize: bounds.size, coverScale: coverScale)
    }
    private var coverSpacing: CGFloat { baseCoverSize * CoverFlowGeometry.spacingRatio }  // Space between side covers
    private let visibleRange = 12
    private var lastReportedCentrePixels: CGFloat = 0

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Drag and drop
    var onDrop: (([URL], FileDropOperation) -> Void)?
    var onDropToFolder: (([URL], URL, FileDropOperation) -> Void)?  // Drop to specific folder
    private var dragStartLocation: NSPoint?
    private var dragStartIndex: Int?
    private var dropTargetIndex: Int?  // Which cover takes the drop (folder or application)
    private var dropTargetHighlightLayer: CAShapeLayer?  // Visible hover ring
    private var dragSessionInfo: DragSessionInfo?

    /// Per-drag cache of what's being dragged, so the cursor badge can match the eventual operation
    private struct DragSessionInfo {
        let sequenceNumber: Int
        let sourceURLs: [URL]
        let sourceVolumes: [NSObject?]
        var destinationVolumes: [URL: NSObject?] = [:]
        /// Whether each application hovered can open everything dragged
        var openableByApplication: [URL: Bool] = [:]
    }

    /// What dropping on a cover does.
    private enum CoverDropAction: Equatable {
        /// Move or copy into the folder
        case folder(URL)
        /// Open the dropped items with the application (Finder); never copies into the bundle
        case application(URL)
    }

    // Inline video preview (mirrors Finder's TDesktopInlinePreviewController)
    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredCoverIndex: Int?
    private var previewHost: InlinePreviewHostToken?
    private var videoPreviewLayer: AVPlayerLayer?
    private var videoPreviewURL: URL?
    private var skimProgressLayer: CALayer?

    // Accessibility
    private var accessibilityElementsByIndex: [Int: CoverFlowAccessibilityElement] = [:]

    /// True while SwiftUI is pushing new state into the view (updateNSView)
    private var isApplyingSwiftUIUpdate = false

    private var emptyRebuildWorkItem: DispatchWorkItem?
    /// How long the list must stay empty before the covers are cleared
    let emptyRebuildDelay: TimeInterval = 0.3

    private func setupView() {
        wantsLayer = true

        // Background gradient
        let gradientLayer = CAGradientLayer()
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.frame = bounds
        gradientLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(gradientLayer)
        backgroundLayer = gradientLayer
        updateAppearanceColors()

        // Register for drag and drop
        registerForDraggedTypes([.fileURL])

        // Setup hover tracking for inline video preview
        setupHoverTracking()
    }

    private func currentActivityState() -> Bool {
        guard let window else { return false }
        guard NSApp.isActive else { return false }
        guard window.isVisible, !window.isMiniaturized else { return false }
        guard !isHiddenOrHasHiddenAncestor else { return false }
        guard bounds.width > 0, bounds.height > 0 else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Update cover layer opacity based on cut state
    func updateCutItemOpacity() {
        for coverLayer in coverLayers {
            if let index = coverLayer.value(forKey: "itemIndex") as? Int,
               index < items.count {
                let isCut = cutItemURLs.contains(items[index].url)
                coverLayer.opacity = isCut ? 0.5 : 1.0
            }
        }
    }

    func updateActivityState() {
        let newState = currentActivityState()
        guard newState != isViewActive else { return }

        isViewActive = newState
        if !newState {
            pauseTransientWork()
        }
        onActivityStateChange?(newState)
    }

    /// Applies state pushed by SwiftUI's updateNSView.
    func applySwiftUIUpdate(_ body: () -> Void) {
        let wasApplying = isApplyingSwiftUIUpdate
        isApplyingSwiftUIUpdate = true
        defer { isApplyingSwiftUIUpdate = wasApplying }
        body()
    }

    private func pauseTransientWork() {
        scrollSettleTimer?.invalidate()
        scrollSettleTimer = nil
        typeAheadTimer?.invalidate()
        typeAheadTimer = nil
        scrollAccumulator.reset()
        if isScrolling {
            isScrolling = false
            onScrollStateChange?(false)
        }
        clearDropTargetHighlight()
        dropTargetIndex = nil

        // Stop this view's inline video preview (not other windows')
        stopOwnedVideoPreview()
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        // Dynamic colors resolve against the current drawing appearance
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.backgroundLayer?.colors = [
                NSColor.windowBackgroundColor.cgColor,
                NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: .black)?.cgColor ?? NSColor.black.cgColor
            ]
            if let highlight = self.dropTargetHighlightLayer {
                highlight.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                highlight.strokeColor = NSColor.controlAccentColor.cgColor
            }
            CATransaction.commit()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for coverLayer in coverLayers {
            applyContentsScale(scale, to: coverLayer)
        }
        CATransaction.commit()
        reportCentreCoverPixelsIfNeeded()
    }

    private func applyContentsScale(_ scale: CGFloat, to coverLayer: CALayer) {
        coverLayer.contentsScale = scale
        if let imageLayer = imageSublayer(of: coverLayer) {
            imageLayer.contentsScale = scale
        }
        if let reflectionImage = reflectionSublayer(of: coverLayer)?.sublayers?.first(where: { $0.name == "reflectionImage" }) {
            reflectionImage.contentsScale = scale
        }
    }

    /// Tells SwiftUI how many device pixels the centre cover spans, so it can request sharp thumbnails.
    private func reportCentreCoverPixelsIfNeeded() {
        let pixels = (baseCoverSize * backingScale).rounded()
        guard pixels > 0, pixels != lastReportedCentrePixels else { return }
        lastReportedCentrePixels = pixels
        onCentreCoverPixelSizeChange?(pixels)
    }

    // MARK: - Inline Video Preview (Finder-style hover-to-play)

    private func setupHoverTracking() {
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTrackingArea {
            removeTrackingArea(old)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard AppSettings.shared.inlineVideoPreview, let host = previewHost else { return }
        guard !isScrolling else { return }

        let manager = InlineVideoPreviewManager.shared
        let location = convert(event.locationInWindow, from: nil)
        guard let hit = coverHit(at: location), hit.index < items.count else {
            // Mouse is over empty space
            if hoveredCoverIndex != nil {
                stopOwnedVideoPreview()
            }
            return
        }

        let index = hit.index
        let item = items[index]
        if hoveredCoverIndex != index {
            // New cover — request preview
            hoveredCoverIndex = index
            if item.fileType == .video {
                manager.requestPreview(for: item, host: host)
            } else {
                manager.stopPreviews(ownedBy: host)
            }
        } else if AppSettings.shared.videoSkimming, item.fileType == .video,
                  manager.previewURL(ownedBy: host) == item.url,
                  let fraction = hit.quad.horizontalFraction(at: location) {
            // Same video cover — drive skimming from the mouse position across the cover
            manager.seekToFraction(Double(fraction), for: item.url)
            updateSkimProgressLayer(fraction: fraction)
        }
    }

    override func mouseExited(with event: NSEvent) {
        stopOwnedVideoPreview()
    }

    /// Updates the skim progress bar layer width based on the current fraction.
    private func updateSkimProgressLayer(fraction: CGFloat) {
        guard let progressLayer = skimProgressLayer,
              let videoLayer = videoPreviewLayer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = videoLayer.bounds.width * fraction
        progressLayer.frame = CGRect(x: videoLayer.frame.minX, y: videoLayer.frame.minY, width: width, height: 3)
        CATransaction.commit()
    }

    private func registerPreviewHostIfNeeded() {
        guard previewHost == nil else { return }
        previewHost = InlineVideoPreviewManager.shared.registerHost(
            onLayerReady: { [weak self] playerLayer, url in
                self?.attachVideoPreviewLayer(playerLayer, for: url)
            },
            onLayerDetach: { [weak self] url in
                self?.detachVideoPreviewLayer(for: url)
            }
        )
    }

    private func unregisterPreviewHost() {
        hoveredCoverIndex = nil
        guard let host = previewHost else { return }
        previewHost = nil
        InlineVideoPreviewManager.shared.unregisterHost(host)
        detachVideoPreviewLayer(for: nil)
    }

    /// Stops the preview this view requested; previews in other windows keep playing.
    private func stopOwnedVideoPreview() {
        hoveredCoverIndex = nil
        guard let host = previewHost else { return }
        if isApplyingSwiftUIUpdate {
            // The manager publishes state; don't do that in the middle of a SwiftUI update
            DispatchQueue.main.async {
                InlineVideoPreviewManager.shared.stopPreviews(ownedBy: host)
            }
        } else {
            InlineVideoPreviewManager.shared.stopPreviews(ownedBy: host)
        }
    }

    private func attachVideoPreviewLayer(_ playerLayer: AVPlayerLayer, for url: URL) {
        // Remove any existing video preview
        detachVideoPreviewLayer(for: nil)

        playerLayer.name = "videoPreviewLayer"
        playerLayer.videoGravity = .resizeAspect
        videoPreviewLayer = playerLayer
        videoPreviewURL = url

        // Add skim progress bar layer if skimming is enabled
        if AppSettings.shared.videoSkimming {
            let progressBar = CALayer()
            progressBar.name = "skimProgressLayer"
            progressBar.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
            progressBar.frame = CGRect(x: 0, y: 0, width: 0, height: 3)
            progressBar.cornerRadius = 1.5
            skimProgressLayer = progressBar
        }

        reconcileVideoPreviewLayer(fadeIn: true)
    }

    private func detachVideoPreviewLayer(for url: URL?) {
        if let url, let current = videoPreviewURL, current != url { return }
        skimProgressLayer?.removeFromSuperlayer()
        skimProgressLayer = nil
        videoPreviewLayer?.removeFromSuperlayer()
        videoPreviewLayer = nil
        videoPreviewURL = nil
    }

    /// Keeps the player layer on the cover that currently shows its item. Covers are recycled and
    /// rebuilt, so the layer follows the item's URL rather than a layer instance; if the item is no
    /// longer on screen the preview stops.
    private func reconcileVideoPreviewLayer(fadeIn: Bool = false) {
        guard let playerLayer = videoPreviewLayer, let url = videoPreviewURL else { return }
        guard let coverLayer = cover(showing: url), let imageLayer = imageSublayer(of: coverLayer) else {
            stopOwnedVideoPreview()
            detachVideoPreviewLayer(for: nil)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.superlayer !== coverLayer {
            playerLayer.removeFromSuperlayer()
            coverLayer.insertSublayer(playerLayer, above: imageLayer)
        }
        playerLayer.frame = imageLayer.frame
        playerLayer.cornerRadius = imageLayer.cornerRadius
        if let progressLayer = skimProgressLayer {
            if progressLayer.superlayer !== coverLayer {
                progressLayer.removeFromSuperlayer()
                coverLayer.addSublayer(progressLayer)
            }
            progressLayer.frame = CGRect(x: imageLayer.frame.minX, y: imageLayer.frame.minY, width: progressLayer.frame.width, height: 3)
        }
        CATransaction.commit()

        if fadeIn && !reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.2
            playerLayer.add(fade, forKey: "fadeIn")
        }
    }

    /// Called whenever the centred cover changes.
    private func centredIndexDidChange() {
        // Stop a preview the selection has moved away from
        if let host = previewHost,
           let previewURL = InlineVideoPreviewManager.shared.previewURL(ownedBy: host),
           selectedIndex < items.count, items[selectedIndex].url != previewURL {
            stopOwnedVideoPreview()
        }
        NSAccessibility.post(element: self, notification: .valueChanged)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    // MARK: - Items

    func updateItems(_ items: [FileItem], itemsToken: Int, thumbnails: [URL: NSImage], selectedIndex: Int) {
        let itemsChanged = self.items.count != items.count || self.itemsToken != itemsToken
        if itemsChanged {
            CoverFlowView.debugLog("[NSView] updateItems - ITEMS CHANGED oldToken:\(self.itemsToken) newToken:\(itemsToken) oldCount:\(self.items.count) newCount:\(items.count)")
        }

        let previousItems = self.items
        self.items = items
        self.itemsToken = itemsToken
        self.thumbnails = thumbnails
        requestedIndex = selectedIndex

        // While the user scrolls, the strip leads and the incoming index lags behind: keep the
        // centred item, following it if the list changed under it
        let newIndex = isScrolling
            ? Self.index(following: self.selectedIndex, from: previousItems, to: items)
            : selectedIndex
        let indexChanged = self.selectedIndex != newIndex
        self.selectedIndex = newIndex

        if itemsChanged {
            emptyRebuildWorkItem?.cancel()
            emptyRebuildWorkItem = nil
            accessibilityElementsByIndex.removeAll()
            if items.isEmpty && !coverLayers.isEmpty {
                // A reload empties the list for a moment; clear the covers only if it stays
                // empty, so a refresh doesn't flash but no ghost covers stay behind
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, self.items.isEmpty else { return }
                    self.emptyRebuildWorkItem = nil
                    self.rebuildCovers()
                }
                emptyRebuildWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + emptyRebuildDelay, execute: workItem)
            } else {
                rebuildCovers()
                layer?.setNeedsLayout()
                layer?.layoutIfNeeded()
            }
            if indexChanged {
                centredIndexDidChange()
            }
        } else if indexChanged {
            animateToSelection()
            centredIndexDidChange()
            DispatchQueue.main.async { [weak self] in
                self?.updateCoverImages()
            }
        } else {
            updateCoverImages()
        }
    }

    /// Where the item at `index` of `oldItems` is in `newItems` (clamped if it's gone).
    static func index(following index: Int, from oldItems: [FileItem], to newItems: [FileItem]) -> Int {
        guard !newItems.isEmpty else { return 0 }
        if index >= 0, index < oldItems.count {
            let url = oldItems[index].url
            if index < newItems.count, newItems[index].url == url {
                return index
            }
            if let moved = newItems.firstIndex(where: { $0.url == url }) {
                return moved
            }
        }
        return min(max(0, index), newItems.count - 1)
    }

    private func updateCoverImages() {
        for coverLayer in coverLayers {
            guard let index = coverLayer.value(forKey: "itemIndex") as? Int,
                  index < items.count else { continue }

            let item = items[index]

            // Items can be reordered without the count changing; refresh the whole cover then
            if (coverLayer.value(forKey: "itemURL") as? URL) != item.url {
                updateCoverLayer(coverLayer, for: item, at: index)
                continue
            }

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

            // The real image can have a different aspect ratio than the placeholder;
            // resize the cover so the reflection sits right under the image
            let coverSize = getCoverSize(for: thumbnail)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if coverLayer.bounds.size != coverSize {
                applyCoverGeometry(to: coverLayer, size: coverSize)
            }

            // Update main image
            if let imageLayer = imageSublayer(of: coverLayer) {
                imageLayer.contents = imageContent
                imageLayer.contentsGravity = .resizeAspect
            }
            CATransaction.commit()

            // Update reflection and fade it in
            if let reflectionContainer = reflectionSublayer(of: coverLayer) {
                // Find the reflection image layer
                for sublayer in reflectionContainer.sublayers ?? [] where sublayer.name == "reflectionImage" {
                    sublayer.contents = imageContent
                    sublayer.contentsGravity = .resizeAspect
                }

                // Fade in the reflection smoothly if it was hidden
                if reflectionContainer.opacity < 1.0 && !isScrolling {
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.3)
                    CATransaction.setDisableActions(reduceMotion)
                    reflectionContainer.opacity = 1.0
                    CATransaction.commit()
                }
            }
        }
        reconcileVideoPreviewLayer()
    }

    private func thumbnailToken(for item: FileItem, thumbnail: NSImage?) -> Int {
        if let thumbnail {
            return ObjectIdentifier(thumbnail).hashValue
        }
        // Use placeholderIcon for fast hash - avoids expensive icon lookup
        return ObjectIdentifier(item.placeholderIcon).hashValue
    }

    private func imageSublayer(of coverLayer: CALayer) -> CALayer? {
        coverLayer.sublayers?.first(where: { $0.name == "imageLayer" })
    }

    private func reflectionSublayer(of coverLayer: CALayer) -> CALayer? {
        coverLayer.sublayers?.first(where: { $0.name == "reflectionContainer" })
    }

    private func cover(showing url: URL) -> CALayer? {
        coverLayers.first(where: {
            guard let index = $0.value(forKey: "itemIndex") as? Int, index < items.count else { return false }
            return items[index].url == url
        })
    }

    private func rebuildCovers() {
        CoverFlowView.debugLog("[NSView] rebuildCovers called - \(items.count) items")
        coverLayers.forEach { $0.removeFromSuperlayer() }
        coverLayers.removeAll()
        clearDropTargetHighlight()
        dropTargetIndex = nil

        if !items.isEmpty {
            // Ensure selectedIndex is within bounds
            let safeSelectedIndex = min(max(0, selectedIndex), items.count - 1)
            let start = max(0, safeSelectedIndex - visibleRange)
            let end = min(items.count - 1, safeSelectedIndex + visibleRange)

            if start <= end {
                for index in start...end {
                    let item = items[index]
                    let coverLayer = createCoverLayer(for: item, at: index)
                    positionCover(coverLayer, at: index, animated: false)
                    layer?.addSublayer(coverLayer)
                    coverLayers.append(coverLayer)
                }
            }
        }

        // The preview's cover was replaced: move the player layer to the new one (or stop it)
        reconcileVideoPreviewLayer()
    }

    private func animateToSelection() {
        guard !items.isEmpty else { return }

        // Ensure selectedIndex is within bounds
        let safeSelectedIndex = min(max(0, selectedIndex), items.count - 1)

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
                coverLayer.opacity = cutItemURLs.contains(item.url) ? 0.5 : 1.0
                layer?.addSublayer(coverLayer)
                coverLayers.append(coverLayer)
            }
            positionCover(coverLayer, at: index, animated: false)
        }

        // Return unused recycled layers to pool, without their images (memory)
        for unusedLayer in layersToRecycle {
            unusedLayer.removeFromSuperlayer()
            coverLayers.removeAll { $0 === unusedLayer }
            if layerPool.count < visibleRange * 3 {
                clearContents(of: unusedLayer)
                layerPool.append(unusedLayer)
            }
        }

        // Animate all covers to new positions
        CATransaction.begin()
        if reduceMotion {
            CATransaction.setDisableActions(true)
        } else if isScrolling {
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
                positionCover(coverLayer, at: index, animated: true)
                let isCut = index < items.count && cutItemURLs.contains(items[index].url)
                coverLayer.opacity = isCut ? 0.5 : 1.0
            }
        }

        CATransaction.commit()

        // Recycled covers may have carried (or lost) the video preview
        reconcileVideoPreviewLayer()
    }

    private func clearContents(of coverLayer: CALayer) {
        coverLayer.setValue(nil, forKey: "itemURL")
        coverLayer.setValue(nil, forKey: "thumbnailToken")
        imageSublayer(of: coverLayer)?.contents = nil
        reflectionSublayer(of: coverLayer)?.sublayers?.forEach { $0.contents = nil }
        coverLayer.sublayers?
            .filter { $0.name == "videoPreviewLayer" || $0.name == "skimProgressLayer" }
            .forEach { $0.removeFromSuperlayer() }
    }

    // Update existing layer with new item data (for recycling)
    private func updateCoverLayer(_ coverLayer: CALayer, for item: FileItem, at index: Int) {
        let thumbnail = thumbnails[item.url]
        let hasThumbnail = thumbnail != nil
        let coverSize = getCoverSize(for: thumbnail)

        coverLayer.setValue(index, forKey: "itemIndex")
        coverLayer.setValue(item.url, forKey: "itemURL")
        coverLayer.setValue(thumbnailToken(for: item, thumbnail: thumbnail), forKey: "thumbnailToken")
        coverLayer.opacity = cutItemURLs.contains(item.url) ? 0.5 : 1.0
        applyCoverGeometry(to: coverLayer, size: coverSize)

        // Get image content - use NSImage directly for icons to preserve transparency
        let imageContent: Any
        if let thumb = thumbnail {
            // For thumbnails, CGImage is fine
            imageContent = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? thumb
        } else {
            // Use fast placeholder - real icon will load async
            imageContent = item.placeholderIcon
        }

        if let imageLayer = imageSublayer(of: coverLayer) {
            imageLayer.contents = imageContent
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.isOpaque = false
        }

        // Update reflection (hide during scroll for performance)
        if let reflectionContainer = reflectionSublayer(of: coverLayer) {
            reflectionContainer.opacity = (hasThumbnail && !isScrolling) ? 1.0 : 0.0
            if let reflectionImage = reflectionContainer.sublayers?.first(where: { $0.name == "reflectionImage" }) {
                reflectionImage.contents = hasThumbnail ? imageContent : nil
            }
        }
    }

    /// Sizes the cover, its image and its reflection. The cover's bounds exclude the reflection,
    /// which hangs below the image (negative y).
    private func applyCoverGeometry(to coverLayer: CALayer, size coverSize: CGSize) {
        coverLayer.bounds = CGRect(x: 0, y: 0, width: coverSize.width, height: coverSize.height)
        if let imageLayer = imageSublayer(of: coverLayer) {
            imageLayer.frame = CGRect(x: 0, y: 0, width: coverSize.width, height: coverSize.height)
        }
        let reflectionHeight = coverSize.height * 0.4
        if let reflectionContainer = reflectionSublayer(of: coverLayer) {
            reflectionContainer.frame = CGRect(x: 0, y: -reflectionHeight - 4, width: coverSize.width, height: reflectionHeight)
            if let mask = reflectionContainer.mask as? CAGradientLayer {
                mask.frame = reflectionContainer.bounds
            }
            if let reflectionImage = reflectionContainer.sublayers?.first(where: { $0.name == "reflectionImage" }) {
                reflectionImage.frame = CGRect(x: 0, y: reflectionHeight - coverSize.height, width: coverSize.width, height: coverSize.height)
            }
        }
        if let playerLayer = videoPreviewLayer, playerLayer.superlayer === coverLayer {
            playerLayer.frame = CGRect(x: 0, y: 0, width: coverSize.width, height: coverSize.height)
        }
    }

    private func getCoverSize(for thumbnail: NSImage?) -> CGSize {
        let maxSize = baseCoverSize

        guard let thumbnail = thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else {
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
        let scale = backingScale

        let container = CALayer()
        container.setValue(index, forKey: "itemIndex")
        container.setValue(item.url, forKey: "itemURL")
        container.setValue(thumbnailToken(for: item, thumbnail: thumbnail), forKey: "thumbnailToken")
        container.backgroundColor = NSColor.clear.cgColor
        // CRITICAL: Set bounds so anchorPoint works correctly for rotation
        container.bounds = CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight)
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.contentsScale = scale

        // Image layer (no background box)
        let imageLayer = CALayer()
        imageLayer.name = "imageLayer"
        imageLayer.frame = CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight)
        imageLayer.masksToBounds = true
        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.isOpaque = false  // Ensure transparency is rendered
        imageLayer.contentsScale = scale

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
        reflectionImage.contentsScale = scale

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

    private func positionCover(_ coverLayer: CALayer, at index: Int, animated: Bool) {
        let placement = CoverFlowGeometry.placement(
            offsetFromCentre: index - selectedIndex,
            viewSize: bounds.size,
            baseCoverSize: baseCoverSize
        )

        if animated {
            coverLayer.transform = placement.transform
            coverLayer.position = placement.position
            coverLayer.zPosition = placement.zPosition
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            coverLayer.transform = placement.transform
            coverLayer.position = placement.position
            coverLayer.zPosition = placement.zPosition
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer?.frame = bounds
        CATransaction.commit()
        reportCentreCoverPixelsIfNeeded()
        guard !items.isEmpty else { return }
        if coverLayers.isEmpty {
            rebuildCovers()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for coverLayer in coverLayers {
            guard let index = coverLayer.value(forKey: "itemIndex") as? Int,
                  index < items.count else { continue }
            applyCoverGeometry(to: coverLayer, size: getCoverSize(for: thumbnails[items[index].url]))
            positionCover(coverLayer, at: index, animated: false)
        }
        CATransaction.commit()
        if let target = dropTargetIndex {
            showDropTargetHighlight(for: target)
        }
    }

    // MARK: - Hit Testing

    /// Each visible cover's on-screen outline (its 3D transform applied), front to back.
    private func coverCandidates() -> [CoverFlowGeometry.Candidate] {
        let rootLayer = layer
        let sublayerTransform = rootLayer?.sublayerTransform ?? CATransform3DIdentity
        let rootAnchor: CGPoint
        if let rootLayer {
            rootAnchor = CGPoint(
                x: rootLayer.bounds.minX + rootLayer.anchorPoint.x * rootLayer.bounds.width,
                y: rootLayer.bounds.minY + rootLayer.anchorPoint.y * rootLayer.bounds.height
            )
        } else {
            rootAnchor = .zero
        }

        return coverLayers.compactMap { coverLayer in
            guard let index = coverLayer.value(forKey: "itemIndex") as? Int else { return nil }
            // Use what's on screen mid-animation
            let geometry = coverLayer.presentation() ?? coverLayer
            guard let quad = CoverFlowGeometry.project(
                bounds: geometry.bounds,
                anchorPoint: geometry.anchorPoint,
                position: geometry.position,
                zPosition: geometry.zPosition,
                transform: geometry.transform,
                parentSublayerTransform: sublayerTransform,
                parentAnchor: rootAnchor
            ) else { return nil }
            return CoverFlowGeometry.Candidate(index: index, zPosition: geometry.zPosition, quad: quad)
        }
    }

    /// The cover under `point` (view coordinates) and its on-screen outline.
    func coverHit(at point: NSPoint) -> CoverFlowGeometry.Candidate? {
        let base = baseCoverSize
        let centreY = bounds.height / 2
        // The strip, including the reflections below the covers
        let band = (centreY - base * 0.5 - base * 0.45)...(centreY + base * 0.5)
        return CoverFlowGeometry.hitTest(point, candidates: coverCandidates(), stripBand: band, maxGap: coverSpacing)
    }

    /// The index of the cover under `point` (view coordinates). Used for clicks and hover.
    func coverIndex(at point: NSPoint) -> Int? {
        coverHit(at: point)?.index
    }

    /// The cover whose drawn outline contains `point`. Drops use this, without the nearest-cover
    /// fallback that makes clicks forgiving: a drop between two covers goes into the folder
    /// shown, not into a neighbouring subfolder.
    func dropTargetCoverIndex(at point: NSPoint) -> Int? {
        guard let hit = coverHit(at: point), hit.quad.contains(point) else { return nil }
        return hit.index
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        hadFocus = true
        CoverFlowView.debugLog("[NSView] becomeFirstResponder called - hadFocus set to true")
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if CoverFlowView.isDebugLoggingEnabled {
            // Check what's taking focus
            if let newResponder = window?.firstResponder, newResponder !== self {
                let symbols = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
                CoverFlowView.debugLog("[NSView] resignFirstResponder - new responder: \(type(of: newResponder))\n\(symbols)")
            }
        }
        return super.resignFirstResponder()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // AppKit can re-deliver an already-handled mouse-down (delayed gesture-recognizer event).
        // A second copy would read as a double-click and open the item, or as a click on empty space.
        if let last = lastMouseDownIdentity, last.timestamp == event.timestamp, last.eventNumber == event.eventNumber,
           last.clickCount == event.clickCount {
            return
        }
        lastMouseDownIdentity = (event.timestamp, event.eventNumber, event.clickCount)

        window?.makeFirstResponder(self)
        pendingCollapseIndex = nil
        let collapsed = collapsedSelection
        collapsedSelection = nil

        if event.modifierFlags.contains(.control) {
            showContextMenu(for: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        let now = Date()

        // Double-click: the clicked cover animates to the centre, so the second click lands on a
        // different cover. Detect it by time and distance and open the item clicked first.
        let isWithinDoubleClickTime = now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval
        let clickDistance = hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y)
        let isNearLastClick = clickDistance < 50 // points

        if isWithinDoubleClickTime && isNearLastClick && lastClickIndex >= 0 && lastClickIndex < items.count {
            if let collapsed, collapsed.index == lastClickIndex {
                // The first click collapsed a multi-selection: open all of it, like the list
                onOpenItems?(collapsed.items)
            } else {
                onOpen?(lastClickIndex)
            }
            lastClickTime = .distantPast
            lastClickIndex = -1
            lastClickLocation = .zero
            dragStartLocation = nil
            dragStartIndex = nil
            return
        }

        // Track for potential drag
        dragStartLocation = location
        dragStartIndex = coverIndex(at: location)

        if let index = dragStartIndex, index < items.count {
            let clickedItem = items[index]
            let modifiers = event.modifierFlags.intersection([.shift, .command])

            if !modifiers.isEmpty {
                // Shift-click extends, Command-click toggles — from this click's modifiers
                moveVisualIndex(to: index)
                onSelect?(index, .click(modifierFlags: modifiers))
            } else if selectedItems.contains(clickedItem) && selectedItems.count > 1 {
                // Keep the multi-selection for a possible drag; collapse to this item on mouse-up
                pendingCollapseIndex = index
            } else {
                selectIndexLocally(index, forceNotify: !selectedItems.contains(clickedItem))
            }

            lastClickTime = now
            lastClickIndex = index
            lastClickLocation = location
        } else {
            // Clicked on empty space - deselect all
            onDeselect?()
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
            pendingCollapseIndex = nil
            let clickedItem = items[index]

            // Determine items to drag - all selected items if the clicked item is selected,
            // otherwise just the clicked item
            let itemsToDrag: [FileItem]
            if selectedItems.contains(clickedItem) && selectedItems.count > 1 {
                itemsToDrag = orderedSelectedItems()
            } else {
                itemsToDrag = [clickedItem]
            }

            // Only real files: archive entries and Photos assets (photos:// URLs) aren't files
            let draggableItems = itemsToDrag.filter { !$0.isFromArchive && $0.url.isFileURL }
            guard !draggableItems.isEmpty else { return }

            // Create dragging items for each file
            var draggingItems: [NSDraggingItem] = []
            for (offset, item) in draggableItems.enumerated() {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)

                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                // Use a copy of the item's icon: the icon is shared and cached
                let iconSize = NSSize(width: 64, height: 64)
                let dragImage = (item.icon.copy() as? NSImage) ?? NSImage(size: iconSize)
                dragImage.size = iconSize

                // Offset each subsequent item slightly for a stacked appearance
                let itemLocation = NSPoint(
                    x: location.x + CGFloat(offset * 8),
                    y: location.y - CGFloat(offset * 8)
                )
                draggingItem.setDraggingFrame(NSRect(origin: itemLocation, size: iconSize), contents: dragImage)
                draggingItems.append(draggingItem)
            }

            // Mark the drag as internal (suppresses drop overlays; drop targets validate the URLs)
            InternalDragState.shared.beginDrag(urls: draggableItems.map(\.url))

            _ = beginDraggingSession(with: draggingItems, event: event, source: self)

            dragStartLocation = nil
            dragStartIndex = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let index = pendingCollapseIndex {
            // Clicked an item of a multi-selection without dragging: select just it (Finder behavior)
            pendingCollapseIndex = nil
            collapsedSelection = (index, orderedSelectedItems())
            selectIndexLocally(index, forceNotify: true)
        }
        dragStartLocation = nil
        dragStartIndex = nil
    }

    // MARK: - Context Menu

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    /// The one path for right-clicks and Control-clicks.
    private func showContextMenu(for event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = coverIndex(at: location), index < items.count else {
            return createBackgroundMenu()
        }

        let clickedItem = items[index]
        let targets: [FileItem]
        if selectedItems.contains(clickedItem) {
            // Finder acts on the whole selection when the clicked item is part of it
            targets = orderedSelectedItems()
        } else {
            // Otherwise the clicked item becomes the selection
            selectIndexLocally(index, forceNotify: true)
            targets = [clickedItem]
        }
        return createContextMenu(for: targets.isEmpty ? [clickedItem] : targets, clickedItem: clickedItem)
    }

    /// Selected items in display order. Only shown items: a filter may hide part of the selection.
    private func orderedSelectedItems() -> [FileItem] {
        items.filter { selectedItems.contains($0) }
    }

    /// Every action acts on `targets` (the menu item's represented object), never on whatever is
    /// selected when it runs.
    private func createContextMenu(for targets: [FileItem], clickedItem: FileItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let singleItem = targets.count == 1 ? targets.first : nil
        let anyFromArchive = targets.contains { $0.isFromArchive }
        // Photos assets and network services aren't files: no file operations on them
        let allFiles = targets.allSatisfy { $0.isFromArchive || $0.url.isFileURL }
        let canEdit = !anyFromArchive && allFiles

        func addItem(_ title: String, _ command: CoverFlowItemCommand, on items: [FileItem] = targets, enabled: Bool = true, to submenu: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: #selector(menuItemCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CoverFlowMenuAction(command, targets: items)
            item.isEnabled = enabled
            (submenu ?? menu).addItem(item)
        }

        let openItem = NSMenuItem(title: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = targets
        menu.addItem(openItem)

        // Show Package Contents for bundles like .app
        if let item = singleItem, !item.isFromArchive, item.url.isFileURL, isPackage(item) {
            let packageItem = NSMenuItem(title: "Show Package Contents", action: #selector(menuShowPackageContents(_:)), keyEquivalent: "")
            packageItem.target = self
            packageItem.representedObject = item
            menu.addItem(packageItem)
        }

        // Open With submenu (only for non-archive files)
        let openWithURLs = targets.filter { !$0.isFromArchive && !$0.isDirectory && $0.url.isFileURL }.map(\.url)
        if !openWithURLs.isEmpty && openWithURLs.count == targets.count {
            let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWithItem.submenu = OpenWithMenuBuilder.buildNSMenu(for: openWithURLs, target: self)
            menu.addItem(openWithItem)
        }

        menu.addItem(NSMenuItem.separator())

        addItem("Get Info", .getInfo, on: [clickedItem], enabled: canEdit)
        addItem("Quick Look", .quickLook, on: [clickedItem])

        menu.addItem(NSMenuItem.separator())

        // Tags submenu
        if canEdit {
            let targetTags = targets.map(\.tags)
            let tagsMenu = NSMenu(title: "Tags")
            tagsMenu.autoenablesItems = false
            for tag in FinderTag.allTags {
                let tagItem = NSMenuItem(title: tag.name, action: #selector(menuItemCommand(_:)), keyEquivalent: "")
                tagItem.target = self
                tagItem.representedObject = CoverFlowMenuAction(.toggleTag(tag.name), targets: targets)
                let taggedCount = targetTags.filter { $0.contains(tag.name) }.count
                tagItem.state = taggedCount == 0 ? .off : (taggedCount == targets.count ? .on : .mixed)
                tagItem.image = Self.tagColorImage(NSColor(tag.color))
                tagsMenu.addItem(tagItem)
            }
            if targetTags.contains(where: { !$0.isEmpty }) {
                tagsMenu.addItem(NSMenuItem.separator())
                addItem("Remove All Tags", .removeAllTags, to: tagsMenu)
            }
            let tagsMenuItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            tagsMenuItem.submenu = tagsMenu
            menu.addItem(tagsMenuItem)

            menu.addItem(NSMenuItem.separator())
        }

        addItem("Copy", .copy, enabled: allFiles)
        addItem("Cut", .cut, enabled: allFiles)
        addItem("Duplicate", .duplicate, enabled: canEdit)

        menu.addItem(NSMenuItem.separator())

        addItem("Rename", .rename, enabled: canEdit && singleItem != nil)
        addItem("Move to Trash", .moveToTrash, enabled: canEdit)

        menu.addItem(NSMenuItem.separator())

        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(menuShowInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.representedObject = targets
        if targets.contains(where: { ($0.isFromArchive && $0.archiveURL == nil) || (!$0.isFromArchive && !$0.url.isFileURL) }) {
            finderItem.isEnabled = false
        }
        menu.addItem(finderItem)

        return menu
    }

    private static func tagColorImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    /// Menu for a right-click on the background (no cover under the mouse).
    private func createBackgroundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(menuNewFolder(_:)), keyEquivalent: "")
        newFolderItem.target = self
        newFolderItem.isEnabled = canModifyFolder
        menu.addItem(newFolderItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(menuPaste(_:)), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = canModifyFolder && (canPaste?() ?? false)
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        let infoItem = NSMenuItem(title: "Get Info", action: #selector(menuGetInfo(_:)), keyEquivalent: "")
        infoItem.target = self
        infoItem.isEnabled = canShowFolderInfo
        menu.addItem(infoItem)

        return menu
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [FileItem] else { return }
        onOpenItems?(targets)
    }

    @objc private func menuItemCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? CoverFlowMenuAction else { return }
        onItemCommand?(action.command, action.targets)
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        guard let targets = sender.representedObject as? [FileItem] else { return }
        let urls = targets.compactMap { item -> URL? in
            item.isFromArchive ? item.archiveURL : item.url
        }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func menuShowPackageContents(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        onShowPackageContents?(item)
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        onNewFolder?()
    }

    @objc private func menuPaste(_ sender: NSMenuItem) {
        onPaste?()
    }

    @objc private func menuGetInfo(_ sender: NSMenuItem) {
        onGetInfo?()
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? OpenWithAction else { return }
        OpenWithMenuBuilder.openFiles(action.fileURLs, withAppAt: action.appURL)
    }

    @objc func openWithOther(_ sender: NSMenuItem) {
        guard let fileURLs = sender.representedObject as? [URL] else { return }
        OpenWithMenuBuilder.showOpenWithPanel(for: fileURLs, relativeTo: window)
    }

    private func isPackage(_ item: FileItem) -> Bool {
        let packageExtensions = ["app", "bundle", "framework", "plugin", "kext", "prefPane", "qlgenerator", "saver", "wdgt", "xpc"]
        let ext = item.url.pathExtension.lowercased()
        return packageExtensions.contains(ext) || NSWorkspace.shared.isFilePackage(atPath: item.url.path)
    }

    // MARK: - Window & Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)

        guard let window = window else {
            // Leaving the window: stop and release our inline preview
            unregisterPreviewHost()
            updateActivityState()
            return
        }

        registerPreviewHostIfNeeded()
        requestFocus(onlyIfNothingFocused: false)
        // This view handles its own keys: a handler the replaced view registered in this window
        // (not another window's) mustn't take them
        KeyboardManager.shared.suspendHandlers(in: window)

        // Observe first responder changes to debug focus loss
        if CoverFlowView.isDebugLoggingEnabled {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window
            )
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMiniaturize(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidDeminiaturize(_:)),
            name: NSWindow.didDeminiaturizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // Observe focus file list notification (e.g., after Escape from search)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFocusFileList(_:)),
            name: .focusFileList,
            object: nil
        )
        updateActivityState()
        reportCentreCoverPixelsIfNeeded()
    }

    @objc private func handleFocusFileList(_ notification: Notification) {
        // Focus this view when requested (e.g., after pressing Escape in search field)
        // Only take focus if we're actually visible in the key window, and only when the poster
        // names this view's window or view model (not another pane's or window's).
        guard let window = window,
              window.isKeyWindow,
              visibleRect.size.height > 0,
              currentActivityState() else { return }
        if let targetWindow = notification.object as? NSWindow, targetWindow !== window { return }
        if let targetViewModel = notification.object as? FileBrowserViewModel, targetViewModel !== focusViewModel { return }
        window.makeFirstResponder(self)
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        // Check if we lost focus (debug-only observer)
        if let window = window, window.firstResponder !== self {
            if hadFocus {
                hadFocus = false
                CoverFlowView.debugLog("[NSView] FOCUS LOST via windowDidUpdate! New responder: \(String(describing: type(of: window.firstResponder)))")
            }
        } else if window?.firstResponder === self && !hadFocus {
            hadFocus = true
            CoverFlowView.debugLog("[NSView] FOCUS GAINED via windowDidUpdate")
        }
    }

    private var hadFocus = false

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        updateActivityState()
        // Only claim focus if nothing in the window has it (don't take it from the list or search)
        if window?.firstResponder !== self {
            requestFocus(onlyIfNothingFocused: true)
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        updateActivityState()
        // Hover tracking only runs in the key window: no mouse-exit will come to stop the preview
        stopOwnedVideoPreview()
    }

    @objc private func windowDidMiniaturize(_ notification: Notification) {
        updateActivityState()
    }

    @objc private func windowDidDeminiaturize(_ notification: Notification) {
        updateActivityState()
    }

    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        updateActivityState()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        updateActivityState()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        updateActivityState()
    }

    /// Never take focus from text input (search, rename) or from another window.
    private func canTakeFocus(in window: NSWindow) -> Bool {
        if let responder = window.firstResponder,
           responder is NSText || responder is NSTextField {
            return false
        }
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            return false
        }
        return true
    }

    /// Take focus after the user scrolled the strip. Only takes focus if no text field has it.
    func ensureFirstResponder() {
        guard let window = window else { return }
        guard window.isKeyWindow, canTakeFocus(in: window) else { return }

        if window.firstResponder !== self {
            CoverFlowView.debugLog("[NSView] ensureFirstResponder - reclaiming from \(String(describing: type(of: window.firstResponder)))")
            window.makeFirstResponder(self)
        }
    }

    func requestFocus(onlyIfNothingFocused: Bool) {
        guard let window = window, window.firstResponder !== self else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, let window = self.window, window.firstResponder !== self else { return }
            guard self.canTakeFocus(in: window) else { return }
            if onlyIfNothingFocused, let responder = window.firstResponder, responder !== window {
                return
            }
            window.makeFirstResponder(self)
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

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard !items.isEmpty else { return }

        // Determine scroll delta (horizontal preferred, vertical as fallback)
        let delta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            delta = event.scrollingDeltaX
        } else {
            delta = -event.scrollingDeltaY
        }

        if event.phase == .began {
            scrollAccumulator.reset()
        }
        if delta != 0 || event.phase == .began {
            // Mark as scrolling and reset settle timer
            setScrolling(true)
        }

        // Trackpads report points (and the system adds momentum); wheels report lines, one per notch
        let steps = scrollAccumulator.coverSteps(
            for: delta,
            isPrecise: event.hasPreciseScrollingDeltas,
            sensitivity: scrollSensitivity,
            now: event.timestamp
        )
        if steps != 0 {
            selectIndexLocally(min(max(0, selectedIndex + steps), items.count - 1))
        }

        // The system's momentum ended (or the gesture was cancelled): settle now
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled || event.phase == .cancelled {
            finishScrolling()
        }
    }

    // Move visual position without triggering onSelect (used for shift+arrow extend)
    private func moveVisualIndex(to newIndex: Int) {
        guard newIndex >= 0 && newIndex < items.count, newIndex != selectedIndex else { return }
        selectedIndex = newIndex
        animateToSelection()
        centredIndexDidChange()
    }

    /// Local-first selection: animate immediately; SwiftUI hears about it right away, or once a
    /// scroll settles. Always a plain selection unless the caller passes the click's intent.
    private func selectIndexLocally(_ newIndex: Int, intent: CoverFlowSelectionIntent = .plain, forceNotify: Bool = false) {
        guard newIndex >= 0 && newIndex < items.count else { return }
        guard newIndex != selectedIndex || forceNotify else { return }
        if newIndex != selectedIndex {
            selectedIndex = newIndex
            animateToSelection()
            centredIndexDidChange()
        }

        if !isScrolling || forceNotify {
            onSelect?(newIndex, intent)
        }
    }

    private func setScrolling(_ scrolling: Bool) {
        let wasScrolling = isScrolling
        isScrolling = scrolling
        scrollSettleTimer?.invalidate()
        scrollSettleTimer = nil

        if scrolling != wasScrolling {
            onScrollStateChange?(scrolling)
            if scrolling {
                scrollStartURL = selectedIndex < items.count ? items[selectedIndex].url : nil
                // Covers are about to move under the mouse: stop the hover preview
                stopOwnedVideoPreview()
            }
        }

        if scrolling {
            // Settle 100ms after the last scroll event (momentum events keep it alive)
            scrollSettleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishScrolling()
                }
            }
        }
    }

    private func finishScrolling() {
        guard isScrolling else { return }
        scrollSettleTimer?.invalidate()
        scrollSettleTimer = nil
        scrollAccumulator.reset()
        onScrollSettled()
    }

    private func onScrollSettled() {
        // Only a scroll that moved the strip to another item selects it: a brush that moved
        // nothing keeps a multi-selection
        let centredURL = selectedIndex < items.count ? items[selectedIndex].url : nil
        let moved = centredURL != scrollStartURL
        scrollStartURL = nil
        if moved {
            // Notify SwiftUI before flipping scroll state to avoid selection snap-back
            onSelect?(selectedIndex, .plain)
        }
        setScrolling(false)
        if !moved, requestedIndex != selectedIndex, requestedIndex >= 0, requestedIndex < items.count {
            // The view model moved meanwhile (the strip ignores it while scrolling): follow it
            selectedIndex = requestedIndex
            animateToSelection()
            centredIndexDidChange()
        }

        // The user scrolled the strip: take focus (unless typing somewhere)
        ensureFirstResponder()

        // Re-enable reflections on all visible covers
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setDisableActions(reduceMotion)
        for coverLayer in coverLayers {
            if let reflectionContainer = reflectionSublayer(of: coverLayer),
               let index = coverLayer.value(forKey: "itemIndex") as? Int,
               index < items.count {
                let hasThumbnail = thumbnails[items[index].url] != nil
                reflectionContainer.opacity = hasThumbnail ? 1.0 : 0.0
            }
        }
        CATransaction.commit()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        // Command shortcuts by character, so they follow the keyboard layout (Dvorak etc.)
        if hasCommand {
            switch event.keyCode {
            case 125: // Cmd+Down - Open
                openCentredItem()
                return
            // ⌥⌘⌫ belongs to the menus (Delete Immediately)
            case 51 where !modifiers.contains(.option): // Cmd+Backspace - Move to Trash
                onDelete?()
                return
            default:
                break
            }
            if !modifiers.contains(.option) && !modifiers.contains(.control) && !hasShift {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c":
                    onCopy?()
                    return
                case "x":
                    onCut?()
                    return
                case "v":
                    onPaste?()
                    return
                case "a":
                    onSelectAll?()
                    return
                default:
                    break
                }
            }
            // Everything else (e.g. Cmd+Up for Enclosing Folder) belongs to the menus
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 123, 126: // Left arrow, Up arrow - previous
            moveSelection(to: selectedIndex - 1, extend: hasShift)
        case 124, 125: // Right arrow, Down arrow - next
            moveSelection(to: selectedIndex + 1, extend: hasShift)
        case 115: // Home
            moveSelection(to: 0, extend: false)
        case 119: // End
            moveSelection(to: items.count - 1, extend: false)
        case 116: // Page Up
            moveSelection(to: selectedIndex - pageStep, extend: false)
        case 121: // Page Down
            moveSelection(to: selectedIndex + pageStep, extend: false)
        case 36, 76: // Return, keypad Enter
            openCentredItem()
        case 49: // Space - Quick Look, or part of a type-ahead in progress
            if isTypeAheadActive {
                appendTypeAhead(" ")
            } else if selectedIndex >= 0 && selectedIndex < items.count {
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
            if !modifiers.contains(.control), let characters = event.characters, let char = characters.first,
               char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" {
                appendTypeAhead(char)
                return
            }
            super.keyDown(with: event)
        }
    }

    private func openCentredItem() {
        if selectedIndex >= 0 && selectedIndex < items.count {
            onOpen?(selectedIndex)
        }
    }

    /// Keyboard navigation. Plain moves select just the new item; Shift extends the range.
    private func moveSelection(to target: Int, extend: Bool) {
        guard !items.isEmpty else { return }
        let newIndex = min(max(0, target), items.count - 1)
        guard newIndex != selectedIndex else { return }
        if extend {
            moveVisualIndex(to: newIndex)
            onExtendSelect?(newIndex)
        } else {
            selectIndexLocally(newIndex)
        }
    }

    /// Arrow keys pressed while the Quick Look panel is key: a plain move, like the arrow keys here.
    func navigateQuickLook(by offset: Int) {
        moveSelection(to: selectedIndex + offset, extend: false)
    }

    private var isTypeAheadActive: Bool {
        !typeAheadBuffer.isEmpty && (typeAheadTimer?.isValid ?? false)
    }

    private func appendTypeAhead(_ char: Character) {
        typeAheadBuffer.append(char)
        resetTypeAheadTimer()
        jumpToMatch()
    }

    private func resetTypeAheadTimer() {
        typeAheadTimer?.invalidate()
        typeAheadTimer = Timer.scheduledTimer(withTimeInterval: typeAheadTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.typeAheadBuffer = ""
            }
        }
    }

    private func jumpToMatch() {
        guard !typeAheadBuffer.isEmpty else { return }

        let searchString = typeAheadBuffer.lowercased()

        // Find the first item that starts with the typed string. Shift may have been held to type
        // a capital; this is still a plain selection.
        if let matchIndex = items.firstIndex(where: { $0.displayName.lowercased().hasPrefix(searchString) }) {
            selectIndexLocally(matchIndex)
        }
    }

    deinit {
        typeAheadTimer?.invalidate()
        scrollSettleTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .list }

    override func accessibilityRoleDescription() -> String? { "cover flow" }

    override func accessibilityLabel() -> String? { "Cover Flow" }

    override func accessibilityValue() -> Any? {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return nil }
        return items[selectedIndex].displayName
    }

    override func accessibilityChildren() -> [Any]? {
        let indices = coverLayers.compactMap { $0.value(forKey: "itemIndex") as? Int }.sorted()
        var elements: [CoverFlowAccessibilityElement] = []
        var kept: [Int: CoverFlowAccessibilityElement] = [:]
        for index in indices where index < items.count {
            let element = accessibilityElementsByIndex[index] ?? CoverFlowAccessibilityElement(index: index, owner: self)
            element.setAccessibilityLabel(items[index].displayName)
            kept[index] = element
            elements.append(element)
        }
        accessibilityElementsByIndex = kept
        return elements
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        (accessibilityChildren() as? [CoverFlowAccessibilityElement])?.filter { isCoverSelected($0.index) }
    }

    fileprivate func isCoverSelected(_ index: Int) -> Bool {
        index < items.count && selectedItems.contains(items[index])
    }

    fileprivate func accessibilityScreenFrame(forCover index: Int) -> NSRect {
        guard let candidate = coverCandidates().first(where: { $0.index == index }), let window else { return .zero }
        return window.convertToScreen(convert(candidate.quad.boundingBox, to: nil))
    }

    fileprivate func accessibilitySelectCover(_ index: Int) -> Bool {
        guard index >= 0 && index < items.count else { return false }
        selectIndexLocally(index, forceNotify: true)
        return true
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Move, copy (Option) and generic (Command = force move); the destination picks
        return [.move, .copy, .generic]
    }

    // MARK: - NSDraggingDestination

    // Enable periodic updates for auto-scroll during drag (Finder-style)
    override func wantsPeriodicDraggingUpdates() -> Bool {
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(from: sender)
        return proposedDragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(from: sender)

        // Auto-scroll when dragging near edges (Finder-style)
        performAutoScroll(for: sender)

        return proposedDragOperation(for: sender)
    }

    // MARK: - Auto-Scroll During Drag

    private let autoScrollEdgeThreshold: CGFloat = 80  // Distance from edge to trigger scroll
    private var lastAutoScrollTime: Date = .distantPast
    private let autoScrollInterval: TimeInterval = 0.15  // Interval between auto-scroll steps

    private func performAutoScroll(for sender: NSDraggingInfo) {
        let location = normalizedDragLocation(from: sender)
        let viewWidth = bounds.width

        // Throttle auto-scroll to prevent too-fast scrolling
        let now = Date()
        guard now.timeIntervalSince(lastAutoScrollTime) >= autoScrollInterval else { return }

        // Near the left or right edge: bring the next cover to the centre without selecting it
        // (the selection may be what's being dragged)
        if location.x < autoScrollEdgeThreshold && selectedIndex > 0 {
            lastAutoScrollTime = now
            browse(to: selectedIndex - 1)
        } else if location.x > viewWidth - autoScrollEdgeThreshold && selectedIndex < items.count - 1 {
            lastAutoScrollTime = now
            browse(to: selectedIndex + 1)
        }
    }

    /// Centres a cover without changing the selection.
    private func browse(to index: Int) {
        guard index >= 0, index < items.count, index != selectedIndex else { return }
        selectedIndex = index
        animateToSelection()
        centredIndexDidChange()
        onBrowse?(index)
    }

    /// The cursor badge for the current drag, matching what a drop here would do.
    private func proposedDragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        var info = dragSessionInfo(for: sender)
        defer { dragSessionInfo = info }
        let sourceMask = sender.draggingSourceOperationMask

        let destination: URL
        switch dropTargetIndex.flatMap({ dropAction(forCover: $0, info: &info) }) {
        case .application?:
            // Opening needs no file operation: the plain arrow
            if sourceMask.contains(.generic) { return .generic }
            return sourceMask.contains(.copy) ? .copy : []
        case .folder(let folderURL)?:
            destination = folderURL
        case nil:
            guard canModifyFolder, let folder = currentFolderURL else { return [] }
            destination = folder
            // Dropping items back into the folder they're in does nothing
            if !info.sourceURLs.isEmpty,
               info.sourceURLs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL }) {
                return []
            }
        }

        let operation = CoverFlowDropPolicy.operation(
            modifierFlags: NSEvent.modifierFlags,
            sourceMask: sourceMask
        )
        return CoverFlowDropPolicy.dragOperation(
            for: operation,
            sourceMask: sourceMask,
            sameVolume: isSameVolume(&info, destination: destination)
        )
    }

    /// What a drop on cover `index` does, or nil if the cover doesn't take drops (the drop then
    /// goes to the folder shown). Folders take drops; packages aren't folders — documents
    /// dropped on an application open with it (Finder), nothing is moved into a bundle.
    private func dropAction(forCover index: Int, info: inout DragSessionInfo) -> CoverDropAction? {
        guard index >= 0, index < items.count else { return nil }
        let item = items[index]
        guard !item.isFromArchive, item.url.isFileURL, item.isDirectory else { return nil }
        let target = item.url.standardizedFileURL
        // Not onto itself
        guard !info.sourceURLs.contains(where: { $0.standardizedFileURL == target }) else { return nil }
        if item.isPackage || item.fileType == .application {
            guard item.fileType == .application, applicationCanOpen(item.url, info: &info) else { return nil }
            return .application(item.url)
        }
        return .folder(item.url)
    }

    /// Whether the application can open everything being dragged (looked up once per drag).
    private func applicationCanOpen(_ appURL: URL, info: inout DragSessionInfo) -> Bool {
        if let known = info.openableByApplication[appURL] {
            return known
        }
        let app = appURL.standardizedFileURL
        // Bounded: a huge drag isn't checked file by file
        let canOpen = !info.sourceURLs.isEmpty && info.sourceURLs.prefix(50).allSatisfy { url in
            NSWorkspace.shared.urlsForApplications(toOpen: url).contains { $0.standardizedFileURL == app }
        }
        info.openableByApplication[appURL] = canOpen
        return canOpen
    }

    private func dragSessionInfo(for sender: NSDraggingInfo) -> DragSessionInfo {
        if let info = dragSessionInfo, info.sequenceNumber == sender.draggingSequenceNumber {
            return info
        }
        let urls = draggedURLs(from: sender.draggingPasteboard)
        let info = DragSessionInfo(
            sequenceNumber: sender.draggingSequenceNumber,
            sourceURLs: urls,
            sourceVolumes: urls.map { volumeIdentifier(for: $0) }
        )
        dragSessionInfo = info
        return info
    }

    private func volumeIdentifier(for url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// true/false if every dragged item is/isn't on the destination's volume; nil if unknown or mixed.
    private func isSameVolume(_ info: inout DragSessionInfo, destination: URL) -> Bool? {
        let destinationVolume: NSObject?
        if let cached = info.destinationVolumes[destination] {
            destinationVolume = cached
        } else {
            destinationVolume = volumeIdentifier(for: destination)
            info.destinationVolumes[destination] = destinationVolume
        }
        guard let destinationVolume, !info.sourceVolumes.isEmpty else { return nil }
        let matches = info.sourceVolumes.map { $0?.isEqual(destinationVolume) }
        if matches.allSatisfy({ $0 == true }) { return true }
        if matches.allSatisfy({ $0 == false }) { return false }
        return nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropTargetHighlight()
        dropTargetIndex = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropTargetHighlight()
        dropTargetIndex = nil
        dragSessionInfo = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Resolve copy/move now, from the keys held at the moment of the drop
        let operation = CoverFlowDropPolicy.operation(
            modifierFlags: NSEvent.modifierFlags,
            sourceMask: sender.draggingSourceOperationMask
        )

        // Re-evaluate the drop target at the final location so hovering glitches don't lose the folder target
        if dropTargetIndex == nil {
            updateDropTarget(from: sender)
        }

        var info = dragSessionInfo(for: sender)
        let action = dropTargetIndex.flatMap { dropAction(forCover: $0, info: &info) }
        clearDropTargetHighlight()
        dropTargetIndex = nil
        dragSessionInfo = nil

        let urls = draggedURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            return false
        }

        switch action {
        case .application(let appURL)?:
            OpenWithMenuBuilder.openFiles(urls, withAppAt: appURL)
            return true
        case .folder(let folderURL)?:
            onDropToFolder?(urls, folderURL, operation)
            return true
        case nil:
            // Into the folder shown, if it takes drops
            guard canModifyFolder, currentFolderURL != nil else { return false }
            onDrop?(urls, operation)
            return true
        }
    }

    private func draggedURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        // Prefer reading as file URLs directly for reliability (Finder and internal drags)
        if let objectURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: objectURLs)
        }
        // Fallback to raw pasteboard items if needed
        if urls.isEmpty, let items = pasteboard.pasteboardItems {
            for item in items {
                // fileURL comes percent-encoded; URL(string:) keeps it intact
                if let urlString = item.string(forType: .fileURL), let url = URL(string: urlString) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private func updateDropTarget(from draggingInfo: NSDraggingInfo) {
        let location = normalizedDragLocation(from: draggingInfo)
        var info = dragSessionInfo(for: draggingInfo)
        defer { dragSessionInfo = info }
        let oldTargetIndex = dropTargetIndex
        var newTarget: Int?

        // Only a cover actually under the pointer takes the drop
        if let index = dropTargetCoverIndex(at: location), dropAction(forCover: index, info: &info) != nil {
            newTarget = index
        }

        dropTargetIndex = newTarget

        // Update highlighting if target changed
        if oldTargetIndex != dropTargetIndex {
            if let newIndex = dropTargetIndex {
                showDropTargetHighlight(for: newIndex)
            } else {
                hideDropTargetHighlight()
            }
        } else if let current = dropTargetIndex {
            // Re-apply every update so the highlight follows the animating covers
            showDropTargetHighlight(for: current)
        }
    }

    private func clearDropTargetHighlight() {
        hideDropTargetHighlight()
    }

    private func ensureDropTargetHighlightLayer() -> CAShapeLayer? {
        guard let rootLayer = layer else { return nil }

        if let existing = dropTargetHighlightLayer {
            return existing
        }

        let highlight = CAShapeLayer()
        highlight.name = "dropTargetHighlightLayer"
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
        updateAppearanceColors()
        return highlight
    }

    private func showDropTargetHighlight(for index: Int) {
        guard let highlight = ensureDropTargetHighlightLayer() else { return }

        // Outline the cover as drawn (rotated side covers included), drawn above everything
        guard let candidate = coverCandidates().first(where: { $0.index == index }) else {
            highlight.isHidden = true
            return
        }

        let outline = candidate.quad.outset(by: 8)
        let path = CGMutablePath()
        path.addLines(between: outline.corners)
        path.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        highlight.path = path
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
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // The destination (this view's performDragOperation, Finder, ...) has already handled the
        // drop, or the drag was cancelled. Only clean up here.
        clearDropTargetHighlight()
        dropTargetIndex = nil
        dragSessionInfo = nil

        // Clear internal drag state
        InternalDragState.shared.endDrag()
    }
}

/// VoiceOver element for one visible cover.
private final class CoverFlowAccessibilityElement: NSAccessibilityElement {
    let index: Int
    private weak var owner: CoverFlowNSView?

    init(index: Int, owner: CoverFlowNSView) {
        self.index = index
        self.owner = owner
        super.init()
        setAccessibilityRole(.image)
        setAccessibilityParent(owner)
    }

    override func accessibilityFrame() -> NSRect {
        owner?.accessibilityScreenFrame(forCover: index) ?? .zero
    }

    override func isAccessibilitySelected() -> Bool {
        owner?.isCoverSelected(index) ?? false
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.accessibilitySelectCover(index) ?? false
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
        .pointerStyle(.rowResize)
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
    @ObservedObject var viewModel: FileBrowserViewModel
    var onEmptySpaceClick: (() -> Void)? = nil
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @State private var isDropTargeted = false

    var body: some View {
        FileTableView(
            viewModel: viewModel,
            columnConfig: columnConfig,
            appSettings: appSettings,
            items: items,
            tagRefreshToken: viewModel.tagRefreshToken,
            onEmptySpaceClick: onEmptySpaceClick,
            // Cover Flow above handles `.focusFileList` (all its keys work there); only one view may
            takesFocusRequests: false
        )
        // The table takes file drops itself; this catches what it doesn't (file promises) and
        // shows the badge of the operation that will happen.
        .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
            viewModel: viewModel,
            isDropTargeted: $isDropTargeted,
            containerHeight: 0,
            items: items,
            autoScroll: false
        ))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Selection Intent

/// How a Cover Flow selection combines with the existing selection. Always derived from the
/// event that caused it, never from the live keyboard state: keyboard navigation, type-ahead,
/// scrolling and drag auto-scroll are plain selections even while Shift or Command is held.
struct CoverFlowSelectionIntent: Equatable {
    /// Shift-click: select the range from the anchor
    var extendsRange: Bool
    /// Command-click: toggle the item
    var toggles: Bool

    static let plain = CoverFlowSelectionIntent(extendsRange: false, toggles: false)

    static func click(modifierFlags: NSEvent.ModifierFlags) -> CoverFlowSelectionIntent {
        CoverFlowSelectionIntent(
            extendsRange: modifierFlags.contains(.shift),
            toggles: modifierFlags.contains(.command)
        )
    }
}

// MARK: - Geometry

/// Cover placement and transform-aware hit-testing. Side covers are rotated ~60° and scaled, so
/// hit-testing projects each cover's outline through its full 3D transform instead of treating
/// it as a flat rectangle.
enum CoverFlowGeometry {
    static let perspective: CGFloat = -1.0 / 1000.0
    static let sideAngle: CGFloat = 60  // degrees
    static let sideScale: CGFloat = 0.75
    static let centreZOffset: CGFloat = 50
    static let spacingRatio: CGFloat = 0.22      // Space between side covers
    static let sideOffsetRatio: CGFloat = 0.62   // Distance from center to first side cover

    static func baseCoverSize(viewSize: CGSize, coverScale: CGFloat) -> CGFloat {
        let heightDriven = viewSize.height * 0.7
        let widthDriven = viewSize.width * 0.28
        return min(heightDriven, widthDriven, 480) * coverScale
    }

    struct Placement {
        let position: CGPoint
        let transform: CATransform3D
        let zPosition: CGFloat
    }

    /// Where the cover `offset` places from the centre goes. Negative offsets are on the left.
    static func placement(offsetFromCentre diff: Int, viewSize: CGSize, baseCoverSize: CGFloat) -> Placement {
        let centreX = viewSize.width / 2
        let centreY = viewSize.height / 2
        let spacing = baseCoverSize * spacingRatio
        let sideOffset = baseCoverSize * sideOffsetRatio

        let xPosition: CGFloat
        let angle: CGFloat
        if diff == 0 {
            xPosition = centreX
            angle = 0
        } else if diff < 0 {
            // Position covers to the left
            xPosition = centreX - sideOffset + CGFloat(diff + 1) * spacing
            angle = sideAngle
        } else {
            // Position covers to the right
            xPosition = centreX + sideOffset + CGFloat(diff - 1) * spacing
            angle = -sideAngle
        }

        let scale: CGFloat = diff == 0 ? 1.0 : sideScale
        var transform = CATransform3DIdentity
        transform.m34 = perspective
        transform = CATransform3DTranslate(transform, 0, 0, diff == 0 ? centreZOffset : 0)
        transform = CATransform3DRotate(transform, angle * .pi / 180, 0, 1, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)

        return Placement(
            position: CGPoint(x: xPosition, y: centreY),
            transform: transform,
            zPosition: CGFloat(1000 - abs(diff) * 10)
        )
    }

    /// A cover's outline as drawn, in its superlayer's coordinates.
    struct Quad: Equatable {
        /// Corners in the layer's own order: bottom-left, bottom-right, top-right, top-left.
        let corners: [CGPoint]
        /// Perspective depth (homogeneous w) of each corner, for perspective-correct mapping.
        let depths: [CGFloat]

        var boundingBox: CGRect {
            let xs = corners.map(\.x)
            let ys = corners.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// Point-in-convex-polygon test (a projected rectangle is convex).
        func contains(_ point: CGPoint) -> Bool {
            guard corners.count == 4 else { return false }
            var sign: CGFloat = 0
            for i in 0..<4 {
                let a = corners[i]
                let b = corners[(i + 1) % 4]
                let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                if cross == 0 { continue }
                if sign == 0 {
                    sign = cross
                } else if (cross > 0) != (sign > 0) {
                    return false
                }
            }
            return sign != 0
        }

        /// Where `point` falls across the cover's image: 0 at its left edge, 1 at its right edge,
        /// corrected for perspective.
        func horizontalFraction(at point: CGPoint) -> CGFloat? {
            guard corners.count == 4, depths.count == 4,
                  let left = Self.x(onEdgeFrom: corners[0], to: corners[3], atY: point.y),
                  let right = Self.x(onEdgeFrom: corners[1], to: corners[2], atY: point.y),
                  abs(right - left) > .ulpOfOne else { return nil }
            let leftDepth = (depths[0] + depths[3]) / 2
            let rightDepth = (depths[1] + depths[2]) / 2
            let denominator = leftDepth * (point.x - left) + rightDepth * (right - point.x)
            guard abs(denominator) > .ulpOfOne else { return nil }
            let fraction = leftDepth * (point.x - left) / denominator
            return min(max(fraction, 0), 1)
        }

        /// The outline pushed out from its centre by `distance` points.
        func outset(by distance: CGFloat) -> Quad {
            let centre = CGPoint(
                x: corners.map(\.x).reduce(0, +) / CGFloat(max(corners.count, 1)),
                y: corners.map(\.y).reduce(0, +) / CGFloat(max(corners.count, 1))
            )
            let moved = corners.map { corner -> CGPoint in
                let dx = corner.x - centre.x
                let dy = corner.y - centre.y
                let length = max(hypot(dx, dy), .ulpOfOne)
                return CGPoint(x: corner.x + dx / length * distance, y: corner.y + dy / length * distance)
            }
            return Quad(corners: moved, depths: depths)
        }

        private static func x(onEdgeFrom a: CGPoint, to b: CGPoint, atY y: CGFloat) -> CGFloat? {
            guard a.x.isFinite, b.x.isFinite else { return nil }
            if abs(b.y - a.y) < .ulpOfOne { return (a.x + b.x) / 2 }
            let t = (y - a.y) / (b.y - a.y)
            return a.x + (b.x - a.x) * t
        }
    }

    /// Projects a layer's bounds into its superlayer the way Core Animation draws it: relative to
    /// the anchor point, through `transform` (including its perspective), offset by position, then
    /// through the superlayer's `sublayerTransform`. Returns nil if a corner is behind the viewer.
    static func project(
        bounds: CGRect,
        anchorPoint: CGPoint,
        position: CGPoint,
        zPosition: CGFloat = 0,
        transform: CATransform3D,
        parentSublayerTransform: CATransform3D = CATransform3DIdentity,
        parentAnchor: CGPoint = .zero
    ) -> Quad? {
        let anchor = CGPoint(
            x: bounds.minX + anchorPoint.x * bounds.width,
            y: bounds.minY + anchorPoint.y * bounds.height
        )
        // Row-vector convention: CATransform3DConcat(a, b) applies a, then b
        var matrix = CATransform3DMakeTranslation(-anchor.x, -anchor.y, 0)
        matrix = CATransform3DConcat(matrix, transform)
        matrix = CATransform3DConcat(matrix, CATransform3DMakeTranslation(position.x, position.y, zPosition))
        if !CATransform3DIsIdentity(parentSublayerTransform) {
            matrix = CATransform3DConcat(matrix, CATransform3DMakeTranslation(-parentAnchor.x, -parentAnchor.y, 0))
            matrix = CATransform3DConcat(matrix, parentSublayerTransform)
            matrix = CATransform3DConcat(matrix, CATransform3DMakeTranslation(parentAnchor.x, parentAnchor.y, 0))
        }

        let localCorners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY)
        ]
        var corners: [CGPoint] = []
        var depths: [CGFloat] = []
        for p in localCorners {
            let x = p.x * matrix.m11 + p.y * matrix.m21 + matrix.m41
            let y = p.x * matrix.m12 + p.y * matrix.m22 + matrix.m42
            let w = p.x * matrix.m14 + p.y * matrix.m24 + matrix.m44
            guard w > 0.0001 else { return nil }
            corners.append(CGPoint(x: x / w, y: y / w))
            depths.append(w)
        }
        return Quad(corners: corners, depths: depths)
    }

    struct Candidate {
        let index: Int
        let zPosition: CGFloat
        let quad: Quad
    }

    /// The cover drawn under `point`, testing covers front to back. If no cover is under it but the
    /// point is in the strip (e.g. between two covers or on a reflection), the nearest cover within
    /// `maxGap` points horizontally is used; this never overrides an actual hit.
    static func hitTest(_ point: CGPoint, candidates: [Candidate], stripBand: ClosedRange<CGFloat>?, maxGap: CGFloat) -> Candidate? {
        let frontToBack = candidates.sorted { $0.zPosition > $1.zPosition }
        if let hit = frontToBack.first(where: { $0.quad.contains(point) }) {
            return hit
        }

        guard let band = stripBand, band.contains(point.y) else { return nil }
        var best: (candidate: Candidate, distance: CGFloat)?
        for candidate in frontToBack {
            let box = candidate.quad.boundingBox
            let distance: CGFloat
            if point.x < box.minX {
                distance = box.minX - point.x
            } else if point.x > box.maxX {
                distance = point.x - box.maxX
            } else {
                distance = 0
            }
            // Strictly closer wins, so ties go to the frontmost cover
            if distance <= maxGap, best == nil || distance < best!.distance {
                best = (candidate, distance)
            }
        }
        return best?.candidate
    }
}

// MARK: - Scrolling

/// Turns scroll-wheel and trackpad deltas into cover steps.
struct CoverFlowScrollAccumulator {
    /// Trackpad / Magic Mouse travel (points, after sensitivity) per cover
    static let pointsPerCover: CGFloat = 20
    /// A wheel notch after this long a pause starts a new burst
    static let wheelBurstGap: TimeInterval = 0.3

    private(set) var accumulated: CGFloat = 0
    private var lastWheelTime: TimeInterval = -.infinity

    mutating func reset() {
        accumulated = 0
        lastWheelTime = -.infinity
    }

    /// Covers to move for one scroll event: negative towards the start of the list.
    /// Precise (pixel) deltas accumulate; line-based mouse wheels move one cover per notch,
    /// and a single notch always moves.
    mutating func coverSteps(for delta: CGFloat, isPrecise: Bool, sensitivity: CGFloat, now: TimeInterval) -> Int {
        guard delta != 0, delta.isFinite else { return 0 }

        // Reversing direction starts over instead of first undoing the leftover
        if accumulated != 0 && (accumulated > 0) != (delta > 0) {
            accumulated = 0
        }

        if isPrecise {
            accumulated += delta * sensitivity
            let steps = Int(accumulated / Self.pointsPerCover)
            accumulated -= CGFloat(steps) * Self.pointsPerCover
            return -steps
        }

        let startsBurst = now - lastWheelTime > Self.wheelBurstGap
        lastWheelTime = now
        if startsBurst {
            accumulated = 0
        }
        accumulated += delta
        var steps = Int(accumulated)
        if steps == 0 && startsBurst {
            steps = delta > 0 ? 1 : -1
            accumulated = 0
        } else {
            accumulated -= CGFloat(steps)
        }
        return -steps
    }
}

// MARK: - Thumbnail Sizing & Bookkeeping

enum CoverFlowThumbnailSizing {
    struct Sizes: Equatable {
        /// Centre covers: the real on-screen pixel size
        var hero: CGFloat
        /// Side covers (scaled down and rotated)
        var high: CGFloat
        /// Preloaded covers further out
        var low: CGFloat
    }

    static func sidePixelSize(coverScale: CGFloat, qualityValue: CGFloat) -> CGFloat {
        let base = 192 * coverScale * qualityValue
        let bucket = (base / 64).rounded() * 64
        return min(1024, max(128, bucket))
    }

    static func placeholderPixelSize(sidePixelSize: CGFloat) -> CGFloat {
        let base = sidePixelSize * 0.5
        let bucket = (base / 32).rounded() * 32
        return min(256, max(96, bucket))
    }

    /// The centre cover's device-pixel size (points × backing scale), so it's sharp on Retina.
    /// The quality setting can lower it, never raise it above what's on screen.
    static func heroPixelSize(centreCoverPixels: CGFloat, quality: CGFloat, sidePixelSize: CGFloat) -> CGFloat {
        guard centreCoverPixels.isFinite, centreCoverPixels > 0 else { return sidePixelSize }
        let target = centreCoverPixels * min(max(quality, 0.25), 1)
        let bucket = (target / 64).rounded(.up) * 64
        return min(1536, max(sidePixelSize, bucket))
    }

    static func sizes(coverScale: CGFloat, qualityValue: CGFloat, quality: CGFloat, centreCoverPixels: CGFloat) -> Sizes {
        let high = sidePixelSize(coverScale: coverScale, qualityValue: qualityValue)
        return Sizes(
            hero: heroPixelSize(centreCoverPixels: centreCoverPixels, quality: quality, sidePixelSize: high),
            high: high,
            low: placeholderPixelSize(sidePixelSize: high)
        )
    }
}

/// Which resolution each cover needs at a given distance from the centre, and how much may be kept.
struct CoverFlowThumbnailPolicy {
    var heroRadius = 2
    var heroRetainRadius = 6
    /// Covers on screen
    var highRadius = 12
    var fullResRetainRadius = 24
    var preloadRadius = 96
    var windowRadius = 100

    /// The pixel size to load at `distance`, or nil if nothing should be loaded.
    /// While navigating rapidly, nothing above side-cover resolution is requested.
    func requiredPixelSize(distance: Int, sizes: CoverFlowThumbnailSizing.Sizes, rapid: Bool = false) -> CGFloat? {
        let required: CGFloat
        if distance <= heroRadius {
            required = sizes.hero
        } else if distance <= highRadius {
            required = sizes.high
        } else if distance <= preloadRadius {
            required = sizes.low
        } else {
            return nil
        }
        return rapid ? min(required, sizes.high) : required
    }

    /// The largest image worth keeping at `distance`, or nil to release it.
    func maxRetainedPixelSize(distance: Int, sizes: CoverFlowThumbnailSizing.Sizes) -> CGFloat? {
        if distance <= heroRetainRadius { return sizes.hero }
        if distance <= fullResRetainRadius { return sizes.high }
        if distance <= windowRadius { return sizes.low }
        return nil
    }
}

/// Per-URL record of how good the displayed thumbnail is, keyed by the item's content version,
/// so items already satisfied are skipped without asking the thumbnail cache (and edited files
/// are reloaded).
struct CoverFlowThumbnailLedger {
    struct Entry: Equatable {
        var version: FileItem.ContentVersion
        var pixelSize: CGFloat
        /// Nothing better will come for this version (archive entries, failed thumbnails)
        var isFinal: Bool
    }

    private struct Request {
        var version: FileItem.ContentVersion
        var pixelSize: CGFloat
        var startedAt: TimeInterval
    }

    /// Requests that haven't completed after this long are assumed lost (the cache can drop them)
    static let requestTimeout: TimeInterval = 4

    private(set) var entries: [URL: Entry] = [:]
    private var requests: [URL: [Request]] = [:]

    /// Whether two versions describe the same file content. Fields that weren't loaded yet
    /// (metadata before hydration, cloud status) don't count as changes.
    static func isSameContent(_ a: FileItem.ContentVersion, _ b: FileItem.ContentVersion) -> Bool {
        if a.hasMetadata && b.hasMetadata {
            if a.modificationDate != b.modificationDate || a.size != b.size { return false }
        }
        if let statusA = a.cloudStatus, let statusB = b.cloudStatus, statusA != statusB {
            return false
        }
        return true
    }

    func entry(for url: URL) -> Entry? {
        entries[url]
    }

    /// Combines what's known about the same content: newly loaded fields fill in, known ones stay.
    static func merged(_ known: FileItem.ContentVersion, with newer: FileItem.ContentVersion) -> FileItem.ContentVersion {
        let metadata = newer.hasMetadata ? newer : known
        return FileItem.ContentVersion(
            modificationDate: metadata.modificationDate,
            size: metadata.size,
            hasMetadata: metadata.hasMetadata,
            cloudStatus: newer.cloudStatus ?? known.cloudStatus
        )
    }

    /// Whether the image held for `url` is good enough for this content and size.
    mutating func isSatisfied(_ url: URL, version: FileItem.ContentVersion, pixelSize: CGFloat) -> Bool {
        guard var entry = entries[url], Self.isSameContent(entry.version, version) else { return false }
        let merged = Self.merged(entry.version, with: version)
        if entry.version != merged {
            // Same content, more is known now
            entry.version = merged
            entries[url] = entry
        }
        return entry.isFinal || entry.pixelSize >= pixelSize
    }

    /// Records an image of `pixelSize`. A late, smaller result never downgrades a better entry.
    mutating func markSettled(_ url: URL, version: FileItem.ContentVersion, pixelSize: CGFloat) {
        if let existing = entries[url], Self.isSameContent(existing.version, version),
           existing.isFinal || existing.pixelSize >= pixelSize {
            return
        }
        entries[url] = Entry(version: version, pixelSize: pixelSize, isFinal: false)
    }

    /// Records a deliberate swap to a smaller image (memory).
    mutating func replace(_ url: URL, version: FileItem.ContentVersion, pixelSize: CGFloat) {
        entries[url] = Entry(version: version, pixelSize: pixelSize, isFinal: false)
    }

    mutating func markFinal(_ url: URL, version: FileItem.ContentVersion) {
        entries[url] = Entry(version: version, pixelSize: 0, isFinal: true)
    }

    mutating func remove(_ url: URL) {
        entries.removeValue(forKey: url)
        requests.removeValue(forKey: url)
    }

    mutating func retain(where keep: (URL) -> Bool) {
        entries = entries.filter { keep($0.key) }
        requests = requests.filter { keep($0.key) }
    }

    mutating func removeAll() {
        entries.removeAll()
        requests.removeAll()
    }

    // MARK: Requests

    mutating func beginRequest(_ url: URL, version: FileItem.ContentVersion, pixelSize: CGFloat, now: TimeInterval) {
        var list = requests[url] ?? []
        list.removeAll { $0.pixelSize == pixelSize }
        list.append(Request(version: version, pixelSize: pixelSize, startedAt: now))
        requests[url] = list
    }

    mutating func finishRequest(_ url: URL, pixelSize: CGFloat) {
        guard var list = requests[url] else { return }
        list.removeAll { $0.pixelSize == pixelSize }
        requests[url] = list.isEmpty ? nil : list
    }

    /// Whether a request for this content at `pixelSize` or more is in flight.
    func isRequested(_ url: URL, version: FileItem.ContentVersion, atLeast pixelSize: CGFloat) -> Bool {
        requests[url]?.contains { $0.pixelSize >= pixelSize && Self.isSameContent($0.version, version) } ?? false
    }

    func activeRequestCount(where matches: (CGFloat) -> Bool) -> Int {
        requests.values.reduce(0) { count, list in
            count + list.filter { matches($0.pixelSize) }.count
        }
    }

    mutating func pruneStaleRequests(now: TimeInterval) {
        guard !requests.isEmpty else { return }
        requests = requests.compactMapValues { list in
            let live = list.filter { now - $0.startedAt < Self.requestTimeout }
            return live.isEmpty ? nil : live
        }
    }

    mutating func cancelAllRequests() {
        requests.removeAll()
    }
}

// MARK: - Drop Operations

enum CoverFlowDropPolicy {
    /// What a drop should do, from the modifier keys held at the moment of the drop and what the
    /// drag source allows. Option copies, Command moves, otherwise Finder's automatic rule.
    static func operation(modifierFlags: NSEvent.ModifierFlags, sourceMask: NSDragOperation) -> FileDropOperation {
        let requested = FileDropOperation(modifierFlags: modifierFlags)
        if requested != .automatic {
            return requested
        }
        // The source only allows copying (e.g. a read-only location)
        if !sourceMask.contains(.move) && !sourceMask.contains(.generic) && sourceMask.contains(.copy) {
            return .copy
        }
        return .automatic
    }

    /// The drag operation (cursor badge) that matches what `operation` will do.
    /// `sameVolume` is nil when unknown.
    static func dragOperation(for operation: FileDropOperation, sourceMask: NSDragOperation, sameVolume: Bool?) -> NSDragOperation {
        switch operation {
        case .copy:
            return sourceMask.contains(.copy) ? .copy : []
        case .move:
            if sourceMask.contains(.move) { return .move }
            return sourceMask.contains(.generic) ? .generic : []
        case .automatic:
            if sameVolume == false {
                // Finder copies across volumes
                return sourceMask.contains(.copy) ? .copy : []
            }
            if sourceMask.contains(.move) { return .move }
            if sourceMask.contains(.generic) { return .generic }
            return sourceMask.contains(.copy) ? .copy : []
        }
    }
}

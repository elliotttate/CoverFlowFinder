import SwiftUI
import QuickLookThumbnailing
import AppKit
import Quartz

struct CoverFlowView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared

    // Use sorted items for consistent ordering between covers and file list
    private var sortedItems: [FileItem] {
        columnConfig.sortedItems(items)
    }

    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var pendingThumbnails: Set<URL> = []
    @State private var pendingStartTimes: [URL: Date] = [:]
    @State private var retryTimer: Timer?
    @State private var debugLog: [String] = []
    @State private var renamingItem: FileItem?
    @State private var rightClickedIndex: Int?

    private let visibleRange = 12
    private let maxConcurrentThumbnails = 8
    private let thumbnailTimeout: TimeInterval = 2.0

    private static let logFileURL: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("CoverFlowDebug.log")
    }()

    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] \(message)"
        print(entry)

        // Write to file
        let line = entry + "\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.logFileURL)
            }
        }

        DispatchQueue.main.async {
            debugLog.append(entry)
            if debugLog.count > 100 { debugLog.removeFirst() }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Cover Flow area - takes proportional space
                CoverFlowContainer(
                    items: sortedItems,
                    selectedIndex: $viewModel.coverFlowSelectedIndex,
                    thumbnails: thumbnails,
                    thumbnailCount: thumbnails.count,
                    navigationGeneration: viewModel.navigationGeneration,
                    onSelect: { index in
                        viewModel.coverFlowSelectedIndex = index
                        syncSelection()
                        // Refresh Quick Look if visible
                        if index < sortedItems.count {
                            QuickLookControllerView.shared.updatePreview(for: sortedItems[index].url)
                        }
                    },
                    onOpen: { index in
                        if index < sortedItems.count {
                            viewModel.openItem(sortedItems[index])
                        }
                    },
                    onRightClick: { index in
                        rightClickedIndex = index
                    },
                    onDrop: { urls in
                        handleDrop(urls: urls)
                    }
                )
                .frame(height: max(250, geometry.size.height * 0.45))

                // Selected item info
                if !sortedItems.isEmpty && viewModel.coverFlowSelectedIndex < sortedItems.count {
                    let selectedItem = sortedItems[viewModel.coverFlowSelectedIndex]
                    VStack(spacing: 4) {
                        Text(selectedItem.name)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 16) {
                            if !selectedItem.isDirectory {
                                Text(selectedItem.formattedSize)
                                    .foregroundColor(.secondary)
                            }
                            Text(selectedItem.formattedDate)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }

                Divider()

                // File list
                FileListSection(
                    items: sortedItems,
                    selectedItems: viewModel.selectedItems,
                    onSelect: { item, index in
                        viewModel.coverFlowSelectedIndex = index
                        syncSelection()
                    },
                    onOpen: { item in
                        viewModel.openItem(item)
                    },
                    viewModel: viewModel
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                // Debug overlay
                if viewModel.showDebug {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("DEBUG LOG")
                                .font(.system(size: 10, weight: .bold))
                            Spacer()
                            Text("Loaded: \(thumbnails.count) | Pending: \(pendingThumbnails.count)")
                                .font(.system(size: 10))
                        }
                        .padding(.bottom, 4)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(debugLog.suffix(20), id: \.self) { entry in
                                    Text(entry)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .frame(maxWidth: 400, maxHeight: 200)
                    .padding(10)
                }
            }
        }
        .onAppear {
            // Clear KeyboardManager so events pass through to native keyDown handler
            KeyboardManager.shared.clearHandler()
            loadVisibleThumbnails()
            syncSelection()
            startRetryTimer()
        }
        .onDisappear {
            retryTimer?.invalidate()
            retryTimer = nil
        }
        .onChange(of: items) { _ in
            thumbnails.removeAll()
            pendingThumbnails.removeAll()
            pendingStartTimes.removeAll()
            log("Items changed - cleared \(items.count) items")
            loadVisibleThumbnails()
            syncSelection()
        }
        .onChange(of: viewModel.coverFlowSelectedIndex) { _ in
            loadVisibleThumbnails()
        }
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                self.loadVisibleThumbnails()
            }
        }
    }

    private func syncSelection() {
        guard !sortedItems.isEmpty && viewModel.coverFlowSelectedIndex < sortedItems.count else { return }
        viewModel.selectedItems = [sortedItems[viewModel.coverFlowSelectedIndex]]
    }

    private func handleDrop(urls: [URL]) {
        let destPath = viewModel.currentPath
        let shouldMove = NSEvent.modifierFlags.contains(.option)

        for sourceURL in urls {
            if sourceURL.deletingLastPathComponent() == destPath {
                continue
            }

            let destURL = destPath.appendingPathComponent(sourceURL.lastPathComponent)

            var finalURL = destURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalURL.path) {
                let name = sourceURL.deletingPathExtension().lastPathComponent
                let ext = sourceURL.pathExtension
                if ext.isEmpty {
                    finalURL = destPath.appendingPathComponent("\(name) \(counter)")
                } else {
                    finalURL = destPath.appendingPathComponent("\(name) \(counter).\(ext)")
                }
                counter += 1
            }

            do {
                if shouldMove {
                    try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                } else {
                    try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                }
            } catch {
                print("Failed to \(shouldMove ? "move" : "copy") \(sourceURL.lastPathComponent): \(error)")
            }
        }

        viewModel.refresh()
    }

    private func loadVisibleThumbnails() {
        guard !sortedItems.isEmpty else { return }
        let selected = min(max(0, viewModel.coverFlowSelectedIndex), sortedItems.count - 1)
        let start = max(0, selected - visibleRange)
        let end = min(sortedItems.count - 1, selected + visibleRange)
        guard start <= end else { return }

        // Check for timed out requests and clear them
        let now = Date()
        var timedOut = 0
        for (url, startTime) in pendingStartTimes {
            if now.timeIntervalSince(startTime) > thumbnailTimeout {
                pendingThumbnails.remove(url)
                pendingStartTimes.removeValue(forKey: url)
                timedOut += 1
            }
        }
        if timedOut > 0 {
            log("⏰ Timed out \(timedOut) requests")
        }

        // Count how many visible items need thumbnails
        var needsLoading = 0
        var alreadyLoaded = 0
        var currentlyPending = 0

        for index in start...end {
            let item = sortedItems[index]
            if thumbnails[item.url] != nil {
                alreadyLoaded += 1
            } else if pendingThumbnails.contains(item.url) {
                currentlyPending += 1
            } else {
                needsLoading += 1
            }
        }

        // Build list of items to load, sorted by distance from selection
        var itemsToLoad: [(item: FileItem, distance: Int)] = []

        for index in start...end {
            let item = sortedItems[index]
            let distance = abs(index - selected)

            if thumbnails[item.url] == nil && !pendingThumbnails.contains(item.url) {
                itemsToLoad.append((item, distance))
            }
        }

        // Sort by distance (closest first)
        itemsToLoad.sort { $0.distance < $1.distance }

        // Load up to maxConcurrentThumbnails
        var started = 0
        for (item, _) in itemsToLoad {
            if pendingThumbnails.count >= maxConcurrentThumbnails {
                break
            }
            generateThumbnail(for: item)
            started += 1
        }

        if started > 0 || needsLoading > 0 {
            log("📊 Visible: \(end-start+1), Loaded: \(alreadyLoaded), Pending: \(currentlyPending), Need: \(needsLoading), Started: \(started)")
        }
    }

    private func generateThumbnail(for item: FileItem) {
        guard !pendingThumbnails.contains(item.url) else { return }

        pendingThumbnails.insert(item.url)
        pendingStartTimes[item.url] = Date()

        log("🔄 Start: \(item.name)")

        // For image files, load directly for better quality and reliability
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]
        let ext = item.url.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            // Load image directly on background thread
            DispatchQueue.global(qos: .userInitiated).async {
                var resultImage: NSImage? = nil

                if let image = NSImage(contentsOf: item.url) {
                    // Resize to reasonable thumbnail size while maintaining aspect ratio
                    let maxSize: CGFloat = 400
                    let originalSize = image.size

                    if originalSize.width > 0 && originalSize.height > 0 {
                        let scale = min(maxSize / originalSize.width, maxSize / originalSize.height, 1.0)
                        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)

                        let resizedImage = NSImage(size: newSize)
                        resizedImage.lockFocus()
                        image.draw(in: NSRect(origin: .zero, size: newSize),
                                   from: NSRect(origin: .zero, size: originalSize),
                                   operation: .copy,
                                   fraction: 1.0)
                        resizedImage.unlockFocus()
                        resultImage = resizedImage
                    } else {
                        resultImage = image
                    }
                }

                DispatchQueue.main.async {
                    self.pendingThumbnails.remove(item.url)
                    self.pendingStartTimes.removeValue(forKey: item.url)

                    if let image = resultImage {
                        self.thumbnails[item.url] = image
                        self.log("✅ Image: \(item.name)")
                    } else {
                        self.log("❌ ImageFail: \(item.name)")
                        self.thumbnails[item.url] = item.icon
                    }

                    self.loadVisibleThumbnails()
                }
            }
            return
        }

        // For non-image files, use QuickLook
        let size = CGSize(width: 400, height: 400)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: 2.0,
            representationTypes: [.thumbnail, .icon]
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
            DispatchQueue.main.async {
                self.pendingThumbnails.remove(item.url)
                self.pendingStartTimes.removeValue(forKey: item.url)

                if let thumbnail = thumbnail {
                    self.thumbnails[item.url] = thumbnail.nsImage
                    self.log("✅ Done: \(item.name)")
                } else if let error = error {
                    self.log("❌ Error: \(item.name) - \(error.localizedDescription)")
                    self.thumbnails[item.url] = item.icon
                } else {
                    self.log("⚠️ NoThumb: \(item.name)")
                    self.thumbnails[item.url] = item.icon
                }

                // Trigger more loading
                self.loadVisibleThumbnails()
            }
        }
    }
}

// MARK: - Native AppKit Cover Flow Container

struct CoverFlowContainer: NSViewRepresentable {
    let items: [FileItem]
    @Binding var selectedIndex: Int
    let thumbnails: [URL: NSImage]
    let thumbnailCount: Int  // Explicit count to force SwiftUI updates
    let navigationGeneration: Int  // Forces update on every navigation
    let onSelect: (Int) -> Void
    let onOpen: (Int) -> Void
    let onRightClick: (Int) -> Void
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> CoverFlowNSView {
        let view = CoverFlowNSView()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onRightClick = { index, _ in
            onRightClick(index)
        }
        view.onDrop = onDrop
        view.updateItems(items, thumbnails: thumbnails, selectedIndex: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: CoverFlowNSView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onOpen = onOpen
        nsView.onRightClick = { index, _ in
            onRightClick(index)
        }
        nsView.onDrop = onDrop
        nsView.updateItems(items, thumbnails: thumbnails, selectedIndex: selectedIndex)
    }
}

class CoverFlowNSView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    var onRightClick: ((Int, NSPoint) -> Void)?

    private var items: [FileItem] = []
    private var thumbnails: [URL: NSImage] = [:]

    private static let logFileURL: URL = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("CoverFlowDebug.log")
    }()

    private func nativeLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(timestamp)] 🔷 \(message)\n"
        print(entry)
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: Self.logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: Self.logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: Self.logFileURL)
            }
        }
    }
    private var selectedIndex: Int = 0
    private var coverLayers: [CALayer] = []
    private var lastClickTime: Date = .distantPast
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

    // Quick Look keyboard monitor
    private var quickLookKeyMonitor: Any?

    // Dynamic sizing based on view bounds
    private var baseCoverSize: CGFloat { min(bounds.height * 0.6, bounds.width * 0.22, 280) }
    private var coverSpacing: CGFloat { baseCoverSize * 0.22 }  // Space between side covers
    private var sideOffset: CGFloat { baseCoverSize * 0.62 }    // Distance from center to first side cover
    private let sideAngle: CGFloat = 60
    private let visibleRange = 12

    // MARK: - Quick Look Support

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return nil }
        return items[selectedIndex].url as QLPreviewItem
    }

    func toggleQuickLook() {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
                stopQuickLookKeyMonitor()
            } else {
                panel.orderFront(nil)
                startQuickLookKeyMonitor()
            }
        }
    }

    private func startQuickLookKeyMonitor() {
        // Remove any existing monitor
        stopQuickLookKeyMonitor()

        // Add local monitor to capture arrow keys even when Quick Look has focus
        quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let panel = QLPreviewPanel.shared(),
                  panel.isVisible else {
                return event
            }

            switch event.keyCode {
            case 123: // Left arrow - previous
                if self.selectedIndex > 0 {
                    self.onSelect?(self.selectedIndex - 1)
                }
                return nil // Consume the event
            case 124: // Right arrow - next
                if self.selectedIndex < self.items.count - 1 {
                    self.onSelect?(self.selectedIndex + 1)
                }
                return nil // Consume the event
            case 125: // Down arrow - next (down in list = higher index)
                if self.selectedIndex < self.items.count - 1 {
                    self.onSelect?(self.selectedIndex + 1)
                }
                return nil // Consume the event
            case 126: // Up arrow - previous (up in list = lower index)
                if self.selectedIndex > 0 {
                    self.onSelect?(self.selectedIndex - 1)
                }
                return nil // Consume the event
            case 49: // Space - close Quick Look
                panel.orderOut(nil)
                self.stopQuickLookKeyMonitor()
                return nil
            case 53: // Escape - close Quick Look
                panel.orderOut(nil)
                self.stopQuickLookKeyMonitor()
                return nil
            default:
                return event
            }
        }
    }

    private func stopQuickLookKeyMonitor() {
        if let monitor = quickLookKeyMonitor {
            NSEvent.removeMonitor(monitor)
            quickLookKeyMonitor = nil
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Drag and drop
    var onDrop: (([URL]) -> Void)?
    private var dragStartLocation: NSPoint?
    private var dragStartIndex: Int?
    private var isDropTargeted = false

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
        nativeLog("Right-click gesture triggered!")
        let location = gesture.location(in: self)
        let index = hitTestCover(at: location) ?? selectedIndex
        onSelect?(index)

        // Create and show menu
        let menu = createContextMenu(for: index)
        menu.popUp(positioning: nil, at: location, in: self)
    }

    func updateItems(_ items: [FileItem], thumbnails: [URL: NSImage], selectedIndex: Int) {
        // More robust items comparison - check first, last, and a sample from middle
        let itemsChanged: Bool = {
            if self.items.count != items.count { return true }
            if self.items.first?.id != items.first?.id { return true }
            if self.items.last?.id != items.last?.id { return true }
            // Also check a middle element if there are enough items
            if items.count > 2 {
                let midIdx = items.count / 2
                if self.items[midIdx].id != items[midIdx].id { return true }
            }
            return false
        }()

        let thumbCount = thumbnails.count
        let oldIndex = self.selectedIndex
        self.items = items
        self.thumbnails = thumbnails

        let indexChanged = self.selectedIndex != selectedIndex
        self.selectedIndex = selectedIndex

        if itemsChanged {
            nativeLog("itemsChanged - rebuild, thumbs=\(thumbCount), oldIdx=\(oldIndex), newIdx=\(selectedIndex)")
            rebuildCovers()
            // Force layout update after rebuild
            layer?.setNeedsLayout()
            layer?.layoutIfNeeded()
        } else if indexChanged {
            nativeLog("indexChanged to \(selectedIndex), thumbs=\(thumbCount), covers=\(coverLayers.count)")
            animateToSelection()
            DispatchQueue.main.async {
                self.updateCoverImages()
            }
        } else {
            nativeLog("thumbsOnly changed, thumbs=\(thumbCount), covers=\(coverLayers.count)")
            updateCoverImages()
        }
    }

    private func updateCoverImages() {
        for coverLayer in coverLayers {
            guard let index = coverLayer.value(forKey: "itemIndex") as? Int,
                  index < items.count else { continue }

            let item = items[index]
            guard let thumbnail = thumbnails[item.url] else { continue }

            // Convert NSImage to CGImage
            let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)

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
                imageLayer.contents = cgImage ?? thumbnail
                imageLayer.contentsGravity = .resizeAspect
            }

            // Update reflection and fade it in
            if let reflectionContainer = reflectionContainer {
                // Find the reflection image layer
                for sublayer in reflectionContainer.sublayers ?? [] {
                    if sublayer.name == "reflectionImage" {
                        sublayer.contents = cgImage ?? thumbnail
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

    private func rebuildCovers() {
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

        // Remove layers outside visible range
        var layersToRemove: [CALayer] = []
        for coverLayer in coverLayers {
            if let index = coverLayer.value(forKey: "itemIndex") as? Int,
               !visibleIndices.contains(index) {
                layersToRemove.append(coverLayer)
            }
        }
        for coverLayer in layersToRemove {
            coverLayer.removeFromSuperlayer()
            coverLayers.removeAll { $0 === coverLayer }
        }

        // Add new layers for missing indices
        let existingIndices = Set(coverLayers.compactMap { $0.value(forKey: "itemIndex") as? Int })
        for index in visibleIndices where !existingIndices.contains(index) {
            guard index < items.count else { continue }
            let item = items[index]
            let coverLayer = createCoverLayer(for: item, at: index)
            coverLayer.opacity = 1  // Start visible
            positionCover(coverLayer, at: index, centerX: centerX, centerY: centerY, animated: false)
            layer?.addSublayer(coverLayer)
            coverLayers.append(coverLayer)
        }

        // Animate all covers to new positions
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

        for coverLayer in coverLayers {
            if let index = coverLayer.value(forKey: "itemIndex") as? Int {
                positionCover(coverLayer, at: index, centerX: centerX, centerY: centerY, animated: true)
                coverLayer.opacity = 1  // Ensure visible
            }
        }

        CATransaction.commit()
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

        if let thumbnail = thumbnail {
            // Convert NSImage to CGImage for CALayer
            if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageLayer.contents = cgImage
            } else {
                imageLayer.contents = thumbnail
            }
            imageLayer.contentsGravity = .resizeAspect
        } else {
            // Always show file icon as placeholder
            let icon = item.icon
            if let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageLayer.contents = cgImage
            } else {
                imageLayer.contents = icon
            }
            imageLayer.contentsGravity = .resizeAspect
        }
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
        rebuildCovers()
    }

    // MARK: - Event Handling

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        // Check for control+click (right-click equivalent)
        if event.modifierFlags.contains(.control) {
            nativeLog("Control+click detected, showing context menu")
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
            onSelect?(index)
            lastClickTime = now
            lastClickIndex = index
            lastClickLocation = location
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = dragStartLocation,
              let index = dragStartIndex,
              index < items.count else { return }

        let location = convert(event.locationInWindow, from: nil)
        let distance = hypot(location.x - startLocation.x, location.y - startLocation.y)

        // Start drag if moved enough
        if distance > 5 {
            let item = items[index]
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

            // Use the item's icon for the drag image
            let iconSize = NSSize(width: 64, height: 64)
            let dragImage = item.icon
            dragImage.size = iconSize
            draggingItem.setDraggingFrame(NSRect(origin: location, size: iconSize), contents: dragImage)

            beginDraggingSession(with: [draggingItem], event: event, source: self)

            dragStartLocation = nil
            dragStartIndex = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartIndex = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        nativeLog("rightMouseDown called!")
        window?.makeFirstResponder(self)
        handleContextClick(with: event)
    }

    private func handleContextClick(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let index = hitTestCover(at: location) ?? selectedIndex
        nativeLog("Context click at index \(index)")

        // Select the item first
        onSelect?(index)

        // Show native context menu
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
        menu.addItem(trashItem)

        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(menuShowInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        menu.addItem(finderItem)

        return menu
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if selectedIndex >= 0 && selectedIndex < items.count {
            onOpen?(selectedIndex)
        }
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        if selectedIndex < items.count {
            let item = items[selectedIndex]
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([item.url as NSURL])
        }
    }

    @objc private func menuCut(_ sender: NSMenuItem) {
        // Cut is copy + mark for move (handled by paste)
        menuCopy(sender)
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        if selectedIndex < items.count {
            let item = items[selectedIndex]
            try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        }
    }

    @objc private func menuShowInFinder(_ sender: NSMenuItem) {
        if selectedIndex < items.count {
            let item = items[selectedIndex]
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    // Make sure we become first responder when view appears and on any click
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus()
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
                return coverLayer.value(forKey: "itemIndex") as? Int
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

        // Determine scroll delta (horizontal preferred, vertical as fallback)
        let delta: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            delta = event.scrollingDeltaX
        } else {
            delta = -event.scrollingDeltaY
        }

        // Accumulate scroll for smooth single-item advancement
        accumulatedScroll += delta

        // Track velocity for momentum
        let now = Date()
        let timeDelta = now.timeIntervalSince(lastScrollTime)
        if timeDelta > 0 && timeDelta < 0.1 {
            scrollVelocity = delta / CGFloat(timeDelta)
        } else {
            scrollVelocity = delta * 10
        }
        lastScrollTime = now

        // Threshold for changing selection
        let threshold: CGFloat = 30

        if accumulatedScroll > threshold {
            let steps = Int(accumulatedScroll / threshold)
            let newIndex = max(0, selectedIndex - steps)
            if newIndex != selectedIndex {
                onSelect?(newIndex)
            }
            accumulatedScroll = accumulatedScroll.truncatingRemainder(dividingBy: threshold)
        } else if accumulatedScroll < -threshold {
            let steps = Int(-accumulatedScroll / threshold)
            let newIndex = min(items.count - 1, selectedIndex + steps)
            if newIndex != selectedIndex {
                onSelect?(newIndex)
            }
            accumulatedScroll = accumulatedScroll.truncatingRemainder(dividingBy: threshold)
        }

        // Start momentum if this is the end of a scroll gesture
        if event.phase == .ended || event.momentumPhase == .began {
            startMomentumScroll()
        }
    }

    private func startMomentumScroll() {
        guard abs(scrollVelocity) > 100 else {
            accumulatedScroll = 0
            return
        }

        momentumTimer?.invalidate()
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            // Apply friction
            self.scrollVelocity *= 0.92

            // Accumulate based on velocity
            let delta = self.scrollVelocity / 60.0
            self.accumulatedScroll += delta

            let threshold: CGFloat = 30

            if self.accumulatedScroll > threshold {
                let newIndex = max(0, self.selectedIndex - 1)
                if newIndex != self.selectedIndex {
                    self.onSelect?(newIndex)
                }
                self.accumulatedScroll -= threshold
            } else if self.accumulatedScroll < -threshold {
                let newIndex = min(self.items.count - 1, self.selectedIndex + 1)
                if newIndex != self.selectedIndex {
                    self.onSelect?(newIndex)
                }
                self.accumulatedScroll += threshold
            }

            // Stop when velocity is low enough
            if abs(self.scrollVelocity) < 50 {
                timer.invalidate()
                self.accumulatedScroll = 0
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            if selectedIndex > 0 {
                onSelect?(selectedIndex - 1)
            }
        case 124: // Right arrow
            if selectedIndex < items.count - 1 {
                onSelect?(selectedIndex + 1)
            }
        case 126: // Up arrow - previous (up in list = lower index)
            if selectedIndex > 0 {
                onSelect?(selectedIndex - 1)
            }
        case 125: // Down arrow - next (down in list = higher index)
            if selectedIndex < items.count - 1 {
                onSelect?(selectedIndex + 1)
            }
        case 36: // Return
            if selectedIndex >= 0 && selectedIndex < items.count {
                onOpen?(selectedIndex)
            }
        case 49: // Space - Quick Look
            toggleQuickLook()
        case 51: // Delete/Backspace - remove last character from type-ahead buffer
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
        stopQuickLookKeyMonitor()
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .copy
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDropTargeted = true
        needsDisplay = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTargeted = false
        needsDisplay = true

        guard let pasteboard = sender.draggingPasteboard.propertyList(forType: .fileURL) as? String,
              let url = URL(string: pasteboard) else {
            // Try reading multiple URLs
            var urls: [URL] = []
            if let items = sender.draggingPasteboard.pasteboardItems {
                for item in items {
                    if let urlString = item.string(forType: .fileURL),
                       let url = URL(string: urlString) {
                        urls.append(url)
                    }
                }
            }

            if !urls.isEmpty {
                onDrop?(urls)
                return true
            }
            return false
        }

        onDrop?([url])
        return true
    }
}

extension CoverFlowNSView: NSDraggingSource {}

// MARK: - File List Section

struct FileListSection: View {
    let items: [FileItem]
    let selectedItems: Set<FileItem>
    let onSelect: (FileItem, Int) -> Void
    let onOpen: (FileItem) -> Void
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject private var columnConfig = ListColumnConfigManager.shared
    @State private var renamingItem: FileItem?
    @State private var isDropTargeted = false

    private var sortedItems: [FileItem] {
        columnConfig.sortedItems(items)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            CoverFlowColumnHeader(columnConfig: columnConfig)

            Divider()

            // File list
            ScrollViewReader { scrollProxy in
                List(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
                    CoverFlowFileRow(item: item, columnConfig: columnConfig)
                        .id(item.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(
                            selectedItems.contains(item)
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .onDrag {
                            NSItemProvider(object: item.url as NSURL)
                        }
                        .gesture(
                            TapGesture(count: 2).onEnded {
                                onOpen(item)
                            }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                // Find original index in unsorted items for selection sync
                                if let originalIndex = items.firstIndex(of: item) {
                                    onSelect(item, originalIndex)
                                }
                            }
                        )
                        .contextMenu {
                            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                renamingItem = item
                            }
                        }
                }
                .listStyle(.plain)
                .onChange(of: selectedItems) { newSelection in
                    if let firstSelected = newSelection.first {
                        withAnimation {
                            scrollProxy.scrollTo(firstSelected.id)
                        }
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let destPath = viewModel.currentPath
        let shouldMove = NSEvent.modifierFlags.contains(.option)

        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, error in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                if sourceURL.deletingLastPathComponent() == destPath {
                    return
                }

                let destURL = destPath.appendingPathComponent(sourceURL.lastPathComponent)

                var finalURL = destURL
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let name = sourceURL.deletingPathExtension().lastPathComponent
                    let ext = sourceURL.pathExtension
                    if ext.isEmpty {
                        finalURL = destPath.appendingPathComponent("\(name) \(counter)")
                    } else {
                        finalURL = destPath.appendingPathComponent("\(name) \(counter).\(ext)")
                    }
                    counter += 1
                }

                do {
                    if shouldMove {
                        try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                    } else {
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                    }
                    DispatchQueue.main.async {
                        viewModel.refresh()
                    }
                } catch {
                    print("Failed to \(shouldMove ? "move" : "copy") \(sourceURL.lastPathComponent): \(error)")
                }
            }
        }
    }
}

// Column header for CoverFlow file list
struct CoverFlowColumnHeader: View {
    @ObservedObject var columnConfig: ListColumnConfigManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columnConfig.visibleColumns) { settings in
                Button(action: { columnConfig.setSortColumn(settings.column) }) {
                    HStack(spacing: 4) {
                        Text(settings.column.rawValue)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .lineLimit(1)

                        if columnConfig.sortColumn == settings.column {
                            Image(systemName: columnConfig.sortDirection == .ascending ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: settings.width, alignment: settings.column.alignment)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    columnVisibilityMenu
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var columnVisibilityMenu: some View {
        Text("Columns")
            .font(.caption)

        Divider()

        ForEach(ListColumn.allCases) { column in
            let isVisible = columnConfig.columns.first(where: { $0.column == column })?.isVisible ?? false
            Button {
                columnConfig.toggleColumnVisibility(column)
            } label: {
                HStack {
                    if isVisible {
                        Image(systemName: "checkmark")
                    }
                    Text(column.rawValue)
                }
            }
            .disabled(column == .name)
        }

        Divider()

        Button("Reset to Defaults") {
            columnConfig.resetToDefaults()
        }
    }
}

// File row for CoverFlow file list
struct CoverFlowFileRow: View {
    let item: FileItem
    @ObservedObject var columnConfig: ListColumnConfigManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columnConfig.visibleColumns) { settings in
                cellContent(for: settings.column)
                    .frame(width: settings.width, alignment: settings.column.alignment)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func cellContent(for column: ListColumn) -> some View {
        switch column {
        case .name:
            HStack(spacing: 8) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                Text(item.name)
                    .lineLimit(1)
            }
        case .dateModified:
            Text(item.formattedDate)
                .foregroundColor(.secondary)
                .font(.caption)
        case .dateCreated:
            Text(formattedCreationDate)
                .foregroundColor(.secondary)
                .font(.caption)
        case .size:
            Text(item.formattedSize)
                .foregroundColor(.secondary)
                .font(.caption)
        case .kind:
            Text(kindDescription)
                .foregroundColor(.secondary)
                .font(.caption)
        case .tags:
            CoverFlowTagsView(url: item.url)
        }
    }

    private var formattedCreationDate: String {
        guard let date = item.creationDate else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var kindDescription: String {
        if item.isDirectory { return "Folder" }
        switch item.fileType {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .code: return "Source Code"
        case .archive: return "Archive"
        case .application: return "Application"
        default: return "Document"
        }
    }
}

struct CoverFlowTagsView: View {
    let url: URL
    @State private var tags: [String] = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.3))
                    .clipShape(Capsule())
            }
        }
        .onAppear {
            if let tagNames = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames {
                tags = tagNames
            }
        }
    }
}

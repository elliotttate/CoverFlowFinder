import SwiftUI
import QuickLookThumbnailing
import AppKit
import Quartz

struct CoverFlowView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var pendingThumbnails: Set<URL> = []
    @State private var pendingStartTimes: [URL: Date] = [:]
    @State private var retryTimer: Timer?
    @State private var debugLog: [String] = []

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

    @State private var showDebug = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                // Cover Flow area - takes proportional space
                CoverFlowContainer(
                    items: items,
                    selectedIndex: $viewModel.coverFlowSelectedIndex,
                    thumbnails: thumbnails,
                    thumbnailCount: thumbnails.count,
                    onSelect: { index in
                        viewModel.coverFlowSelectedIndex = index
                        syncSelection()
                    },
                    onOpen: { index in
                        if index < items.count {
                            viewModel.openItem(items[index])
                        }
                    }
                )
                .frame(height: max(250, geometry.size.height * 0.45))

                // Selected item info
                if !items.isEmpty && viewModel.coverFlowSelectedIndex < items.count {
                    let selectedItem = items[viewModel.coverFlowSelectedIndex]
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
                    items: items,
                    selectedItems: viewModel.selectedItems,
                    onSelect: { item, index in
                        viewModel.coverFlowSelectedIndex = index
                        syncSelection()
                    },
                    onOpen: { item in
                        viewModel.openItem(item)
                    }
                )
            }

            // Debug overlay - press D to toggle
            if showDebug {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("DEBUG LOG (press D to hide)")
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
        .onKeyPress("d") {
            showDebug.toggle()
            return .handled
        }
        .onAppear {
            loadVisibleThumbnails()
            syncSelection()
            startRetryTimer()
        }
        .onDisappear {
            retryTimer?.invalidate()
            retryTimer = nil
        }
        .onChange(of: items) { _, _ in
            thumbnails.removeAll()
            pendingThumbnails.removeAll()
            pendingStartTimes.removeAll()
            log("Items changed - cleared \(items.count) items")
            loadVisibleThumbnails()
            syncSelection()
        }
        .onChange(of: viewModel.coverFlowSelectedIndex) { _, _ in
            loadVisibleThumbnails()
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
        guard !items.isEmpty && viewModel.coverFlowSelectedIndex < items.count else { return }
        viewModel.selectedItems = [items[viewModel.coverFlowSelectedIndex]]
    }

    private func loadVisibleThumbnails() {
        guard !items.isEmpty else { return }
        let selected = viewModel.coverFlowSelectedIndex
        let start = max(0, selected - visibleRange)
        let end = min(items.count - 1, selected + visibleRange)

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
            let item = items[index]
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
            let item = items[index]
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

        let size = CGSize(width: 200, height: 200)
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
    let onSelect: (Int) -> Void
    let onOpen: (Int) -> Void

    func makeNSView(context: Context) -> CoverFlowNSView {
        let view = CoverFlowNSView()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.updateItems(items, thumbnails: thumbnails, selectedIndex: selectedIndex)
        return view
    }

    func updateNSView(_ nsView: CoverFlowNSView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onOpen = onOpen
        nsView.updateItems(items, thumbnails: thumbnails, selectedIndex: selectedIndex)
    }
}

class CoverFlowNSView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onSelect: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?

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

    // Momentum scrolling
    private var scrollVelocity: CGFloat = 0
    private var lastScrollTime: Date = .distantPast
    private var momentumTimer: Timer?
    private var accumulatedScroll: CGFloat = 0

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
        guard selectedIndex < items.count else { return nil }
        return items[selectedIndex].url as QLPreviewItem
    }

    func toggleQuickLook() {
        guard selectedIndex < items.count else { return }

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
    }

    func updateItems(_ items: [FileItem], thumbnails: [URL: NSImage], selectedIndex: Int) {
        let itemsChanged = self.items.count != items.count || self.items.first?.id != items.first?.id
        let thumbCount = thumbnails.count
        self.items = items
        self.thumbnails = thumbnails

        let indexChanged = self.selectedIndex != selectedIndex
        self.selectedIndex = selectedIndex

        if itemsChanged {
            nativeLog("itemsChanged - rebuild, thumbs=\(thumbCount)")
            rebuildCovers()
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

            // Find the image layer by searching all sublayers
            for sublayer in coverLayer.sublayers ?? [] {
                if sublayer.name == "imageLayer" {
                    sublayer.contents = cgImage ?? thumbnail
                    sublayer.contentsGravity = .resizeAspectFill
                }
            }

            // Update reflection - it's in the last sublayer which is a container
            if let reflectionContainer = coverLayer.sublayers?.last,
               let reflectionImage = reflectionContainer.sublayers?.first {
                reflectionImage.contents = cgImage ?? thumbnail
            }
        }
    }

    private func rebuildCovers() {
        coverLayers.forEach { $0.removeFromSuperlayer() }
        coverLayers.removeAll()

        guard !items.isEmpty else { return }

        let centerX = bounds.width / 2
        let centerY = bounds.height / 2

        let start = max(0, selectedIndex - visibleRange)
        let end = min(items.count - 1, selectedIndex + visibleRange)

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

        let centerX = bounds.width / 2
        let centerY = bounds.height / 2

        // Determine visible range
        let start = max(0, selectedIndex - visibleRange)
        let end = min(items.count - 1, selectedIndex + visibleRange)
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
        let coverSize = getCoverSize(for: thumbnail)
        let coverWidth = coverSize.width
        let coverHeight = coverSize.height

        let container = CALayer()
        container.setValue(index, forKey: "itemIndex")
        container.setValue(coverWidth, forKey: "coverWidth")
        container.setValue(coverHeight, forKey: "coverHeight")
        // CRITICAL: Set bounds so anchorPoint works correctly for rotation
        container.bounds = CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight)
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        // Image layer (no background box)
        let imageLayer = CALayer()
        imageLayer.name = "imageLayer"
        imageLayer.frame = CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight)
        imageLayer.masksToBounds = true

        if let thumbnail = thumbnail {
            // Convert NSImage to CGImage for CALayer
            if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageLayer.contents = cgImage
            } else {
                imageLayer.contents = thumbnail
            }
            imageLayer.contentsGravity = .resizeAspectFill
        } else {
            // Always show file icon as placeholder
            let icon = item.icon
            if let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                imageLayer.contents = cgImage
            } else {
                imageLayer.contents = icon
            }
            imageLayer.contentsGravity = .center
        }
        container.addSublayer(imageLayer)

        // Reflection
        let reflectionHeight = coverHeight * 0.4
        let reflectionContainer = CALayer()
        reflectionContainer.frame = CGRect(x: 0, y: -reflectionHeight - 4, width: coverWidth, height: reflectionHeight)
        reflectionContainer.masksToBounds = true

        let reflectionImage = CALayer()
        reflectionImage.frame = CGRect(x: 0, y: reflectionHeight - coverHeight, width: coverWidth, height: coverHeight)
        reflectionImage.masksToBounds = true
        reflectionImage.transform = CATransform3DMakeScale(1, -1, 1)

        if let thumbnail = thumbnail {
            if let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                reflectionImage.contents = cgImage
            } else {
                reflectionImage.contents = thumbnail
            }
            reflectionImage.contentsGravity = .resizeAspectFill
        } else {
            let icon = item.icon
            if let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                reflectionImage.contents = cgImage
            } else {
                reflectionImage.contents = icon
            }
            reflectionImage.contentsGravity = .center
        }
        reflectionContainer.addSublayer(reflectionImage)

        // Reflection fade gradient
        let reflectionMask = CAGradientLayer()
        reflectionMask.frame = reflectionContainer.bounds
        reflectionMask.colors = [
            NSColor.white.withAlphaComponent(0.3).cgColor,
            NSColor.clear.cgColor
        ]
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 1)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: 0.3)
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

        let location = convert(event.locationInWindow, from: nil)
        if let index = hitTestCover(at: location) {
            let now = Date()
            let isDoubleClick = (now.timeIntervalSince(lastClickTime) < 0.3) && (index == lastClickIndex)

            if isDoubleClick {
                onOpen?(index)
                lastClickTime = .distantPast
            } else {
                onSelect?(index)
                lastClickTime = now
                lastClickIndex = index
            }
        }
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
        case 126: // Up arrow
            if selectedIndex > 0 {
                onSelect?(selectedIndex - 1)
            }
        case 125: // Down arrow
            if selectedIndex < items.count - 1 {
                onSelect?(selectedIndex + 1)
            }
        case 36: // Return
            onOpen?(selectedIndex)
        case 49: // Space - Quick Look
            toggleQuickLook()
        default:
            super.keyDown(with: event)
        }
    }

    deinit {
        momentumTimer?.invalidate()
    }
}

// MARK: - File List Section

struct FileListSection: View {
    let items: [FileItem]
    let selectedItems: Set<FileItem>
    let onSelect: (FileItem, Int) -> Void
    let onOpen: (FileItem) -> Void

    var body: some View {
        List(Array(items.enumerated()), id: \.element.id) { index, item in
            FileListRow(item: item)
                .listRowBackground(
                    selectedItems.contains(item)
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                )
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2).onEnded {
                        onOpen(item)
                    }
                )
                .simultaneousGesture(
                    TapGesture(count: 1).onEnded {
                        onSelect(item, index)
                    }
                )
        }
        .listStyle(.inset)
    }
}

struct FileListRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)

            Text(item.name)
                .lineLimit(1)

            Spacer()

            Text(item.formattedDate)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 140, alignment: .trailing)

            Text(item.formattedSize)
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

import Foundation
import AppKit
import QuickLookThumbnailing
import CryptoKit

/// Manages thumbnail generation with disk cache, memory cache, and request cancellation
class ThumbnailCacheManager {
    static let shared = ThumbnailCacheManager()

    // MARK: - Memory Cache (NSCache with automatic LRU eviction)
    private let memoryCache = NSCache<NSString, NSImage>()

    // MARK: - Disk Cache
    private let diskCacheURL: URL
    private let fileManager = FileManager.default

    // MARK: - Request Tracking
    private var pendingRequests: [String: Int] = [:]  // Cache key -> generation
    private var failedURLs: Set<URL> = []  // URLs that failed - don't retry
    private var currentGeneration: Int = 0
    private let queue = DispatchQueue(label: "com.coverflowfinder.thumbnailcache", qos: .userInitiated)

    // MARK: - Settings
    private let maxMemoryCacheCount = 1000  // Max thumbnails in memory
    private let maxMemoryCacheCost = 400 * 1024 * 1024  // 400MB
    private let diskCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days
    private static let defaultMaxPixelSize: CGFloat = 256
    private static let minimumPixelSize: CGFloat = 96

    private init() {
        // Setup disk cache directory
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = cacheDir.appendingPathComponent("CoverFlowThumbnails", isDirectory: true)

        // Create cache directory if needed
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Configure memory cache limits
        memoryCache.countLimit = maxMemoryCacheCount
        memoryCache.totalCostLimit = maxMemoryCacheCost

        // Clean old disk cache entries on startup (async)
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.cleanOldDiskCache()
        }
    }

    // MARK: - Public API

    /// Get cached thumbnail (memory or disk), returns nil if not cached
    func getCachedThumbnail(
        for url: URL,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize
    ) -> NSImage? {
        // Check for cached directory icon first (size-aware)
        let targetSize = clampPixelSize(maxPixelSize)
        let sizeBucket = Int(targetSize)
        let dirKey = "dir_\(sizeBucket)_\(url.path)" as NSString
        if let cached = memoryCache.object(forKey: dirKey) {
            return cached
        }

        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)

        // Check memory cache first
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // Check disk cache
        if let diskImage = loadFromDisk(key: key) {
            // Promote to memory cache
            let cost = estimateCost(for: diskImage)
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            return diskImage
        }

        return nil
    }

    /// Check if URL has failed before (don't retry)
    func hasFailed(url: URL) -> Bool {
        queue.sync {
            failedURLs.contains(url)
        }
    }

    /// Check if request is pending
    func isPending(
        url: URL,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize
    ) -> Bool {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        return queue.sync {
            pendingRequests[key] != nil
        }
    }

    /// Increment generation (call when navigating to new folder or scrolling)
    func incrementGeneration() {
        queue.sync {
            currentGeneration += 1
        }
    }

    /// Clear all state for new folder navigation
    func clearForNewFolder() {
        queue.sync {
            currentGeneration += 1
            pendingRequests.removeAll()
            failedURLs.removeAll()
        }
        // Don't clear memory cache - thumbnails might be reused if user navigates back
    }

    /// Generate thumbnail with caching and cancellation support
    func generateThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url

        // Skip directories - QuickLook returns generic blue folder icons
        // which loses custom folder colors. Use item.icon instead.
        // Cache the icon at the requested size for high-resolution display.
        if item.isDirectory {
            let targetSize = clampPixelSize(maxPixelSize)
            let sizeBucket = Int(targetSize)
            let cacheKeyStr = "dir_\(sizeBucket)_\(url.path)"
            let cacheKey = cacheKeyStr as NSString

            // Check cache first
            if let cached = memoryCache.object(forKey: cacheKey) {
                completion(url, cached)
                return
            }

            // Skip if already pending
            let alreadyPending = queue.sync { pendingRequests[cacheKeyStr] != nil }
            if alreadyPending { return }

            // Mark as pending
            let generation: Int = queue.sync {
                pendingRequests[cacheKeyStr] = currentGeneration
                return currentGeneration
            }

            // Fetch and render icon entirely on background queue (thread-safe)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                // Check if still valid
                let isValid = self.queue.sync { self.pendingRequests[cacheKeyStr] == generation }
                guard isValid else {
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKeyStr) }
                    return
                }

                // Get icon and render at target size (both thread-safe now)
                let icon = item.icon
                let highResIcon = self.renderIconAtSize(icon, size: targetSize)

                // Cache and call completion on main queue
                DispatchQueue.main.async {
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKeyStr) }

                    let stillValid = self.queue.sync { generation >= self.currentGeneration - 1 }
                    guard stillValid else { return }

                    self.memoryCache.setObject(highResIcon, forKey: cacheKey)
                    completion(url, highResIcon)
                }
            }
            return
        }

        let targetSize = clampPixelSize(maxPixelSize)
        let cacheKey = cacheKey(for: url, maxPixelSize: targetSize)

        // Skip if already failed - use fast placeholder
        let alreadyFailed = queue.sync { failedURLs.contains(url) }
        guard !alreadyFailed else {
            completion(url, item.placeholderIcon)
            return
        }

        // Skip if already pending
        let alreadyPending = queue.sync { pendingRequests[cacheKey] != nil }
        guard !alreadyPending else {
            return
        }

        // Check caches first
        if let cached = getCachedThumbnail(for: url, maxPixelSize: targetSize) {
            completion(url, cached)
            return
        }

        // Track this request
        let generation: Int = queue.sync {
            pendingRequests[cacheKey] = currentGeneration
            return currentGeneration
        }

        // Determine if it's an image file (load directly for better quality)
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"])
        let ext = url.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            generateImageThumbnail(
                for: item,
                generation: generation,
                cacheKey: cacheKey,
                maxPixelSize: targetSize,
                completion: completion
            )
        } else {
            generateQuickLookThumbnail(
                for: item,
                generation: generation,
                cacheKey: cacheKey,
                maxPixelSize: targetSize,
                completion: completion
            )
        }
    }

    // MARK: - Private Generation Methods

    private func generateImageThumbnail(
        for item: FileItem,
        generation: Int,
        cacheKey: String,
        maxPixelSize: CGFloat,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url

        // First try QuickLook cache (instant if system has it cached)
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 1.0,
            representationTypes: [.thumbnail]  // Just thumbnail, not generating new
        )

        // Use short timeout - if not cached, we'll generate ourselves
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            guard let self = self else { return }

            if let thumbnail = thumbnail {
                // Got cached thumbnail instantly
                DispatchQueue.main.async {
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                    let stillValid = self.queue.sync { generation >= self.currentGeneration - 1 }
                    guard stillValid else { return }

                    let image = thumbnail.nsImage
                    self.cacheImage(image, for: url, maxPixelSize: maxPixelSize)
                    completion(url, image)
                }
            } else {
                // No cache - generate with ImageIO (fast)
                self.generateImageIOThumbnail(
                    for: item,
                    generation: generation,
                    cacheKey: cacheKey,
                    maxPixelSize: maxPixelSize,
                    completion: completion
                )
            }
        }
    }

    private func generateImageIOThumbnail(
        for item: FileItem,
        generation: Int,
        cacheKey: String,
        maxPixelSize: CGFloat,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let isValid = self.queue.sync { self.pendingRequests[cacheKey] == generation }
            guard isValid else {
                _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                return
            }

            var resultImage: NSImage? = nil

            // Use ImageIO - can read embedded EXIF thumbnails instantly
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false  // Don't cache full image
            ]

            if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                resultImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }

            DispatchQueue.main.async {
                _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                let stillValid = self.queue.sync { generation >= self.currentGeneration - 1 }
                guard stillValid else { return }

                if let image = resultImage {
                    self.cacheImage(image, for: url, maxPixelSize: maxPixelSize)
                    completion(url, image)
                } else {
                    _ = self.queue.sync { self.failedURLs.insert(url) }
                    completion(url, item.placeholderIcon)
                }
            }
        }
    }

    private func generateQuickLookThumbnail(
        for item: FileItem,
        generation: Int,
        cacheKey: String,
        maxPixelSize: CGFloat,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url
        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 1.0,
            representationTypes: [.thumbnail, .icon]
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                let stillValid = self.queue.sync { generation >= self.currentGeneration - 1 }
                guard stillValid else { return }

                if let thumbnail = thumbnail {
                    let image = thumbnail.nsImage
                    self.cacheImage(image, for: url, maxPixelSize: maxPixelSize)
                    completion(url, image)
                } else {
                    _ = self.queue.sync { self.failedURLs.insert(url) }
                    completion(url, item.placeholderIcon)
                }
            }
        }
    }

    // MARK: - Caching

    private func cacheImage(_ image: NSImage, for url: URL, maxPixelSize: CGFloat) {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)

        // Memory cache
        let cost = estimateCost(for: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        // Disk cache (async)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveToDisk(image: image, key: key)
        }
    }

    private func cacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        let sizeBucket = Int(clampPixelSize(maxPixelSize).rounded(.toNearestOrAwayFromZero))
        var keyString = "\(url.path)_\(sizeBucket)"
        if let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            keyString += "_\(mtime.timeIntervalSince1970)"
        }

        // Hash the key for safe filename
        let hash = SHA256.hash(data: Data(keyString.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func clampPixelSize(_ size: CGFloat) -> CGFloat {
        min(max(size, Self.minimumPixelSize), 1024)
    }

    private func estimateCost(for image: NSImage) -> Int {
        // Estimate memory cost based on image dimensions
        let size = image.size
        return Int(size.width * size.height * 4)  // 4 bytes per pixel (RGBA)
    }

    /// Render an icon at a specific size for high-resolution display
    /// Uses pure CGImage drawing for thread-safe off-main-thread rendering
    private func renderIconAtSize(_ icon: NSImage, size: CGFloat) -> NSImage {
        let targetSize = NSSize(width: size, height: size)
        let pixelSize = Int(size)

        // Get CGImage from the icon at the best available size
        var proposedRect = NSRect(origin: .zero, size: targetSize)
        guard let cgIcon = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]) else {
            return icon
        }

        // If the icon is already at or above target size, just wrap it
        if cgIcon.width >= pixelSize && cgIcon.height >= pixelSize {
            return NSImage(cgImage: cgIcon, size: targetSize)
        }

        // Create a context and draw at target size (thread-safe)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelSize,
                height: pixelSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return icon
        }

        // High quality scaling
        context.interpolationQuality = .high

        // Draw the CGImage scaled to fill
        let rect = CGRect(origin: .zero, size: CGSize(width: pixelSize, height: pixelSize))
        context.draw(cgIcon, in: rect)

        guard let resultImage = context.makeImage() else {
            return icon
        }

        return NSImage(cgImage: resultImage, size: targetSize)
    }

    // MARK: - Disk Cache Operations

    private func diskCachePath(for key: String) -> URL {
        return diskCacheURL.appendingPathComponent(key + ".png")
    }

    private func removeFromDisk(key: String) {
        let path = diskCachePath(for: key)
        try? fileManager.removeItem(at: path)
    }

    private func saveToDisk(image: NSImage, key: String) {
        let path = diskCachePath(for: key)

        // Use PNG format to preserve transparency
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }

        try? pngData.write(to: path)
    }

    private func loadFromDisk(key: String) -> NSImage? {
        let path = diskCachePath(for: key)

        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }

        return NSImage(contentsOf: path)
    }

    private func cleanOldDiskCache() {
        guard let enumerator = fileManager.enumerator(
            at: diskCacheURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoffDate = Date().addingTimeInterval(-diskCacheMaxAge)
        var filesToDelete: [URL] = []

        while let fileURL = enumerator.nextObject() as? URL {
            // Remove old .jpg files (we now use .png for transparency)
            if fileURL.pathExtension == "jpg" {
                filesToDelete.append(fileURL)
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = resourceValues.contentModificationDate else {
                continue
            }

            if modDate < cutoffDate {
                filesToDelete.append(fileURL)
            }
        }

        for fileURL in filesToDelete {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Clear all caches (for debugging/testing)
    func clearAllCaches() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        queue.sync {
            failedURLs.removeAll()
            pendingRequests.removeAll()
            currentGeneration = 0
        }
    }
}

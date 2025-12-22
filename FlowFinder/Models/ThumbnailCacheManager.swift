import Foundation
import AppKit
import QuickLookThumbnailing
import CryptoKit
import os.log
import AVFoundation

private let cacheLog = OSLog(subsystem: "com.flowfinder", category: "ThumbnailCache")

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
        // Skip archive items - they use generateArchiveThumbnail with different cache keys
        // Archive items have virtual URLs with # in the path
        // Use fast ASCII check instead of String.contains which is slow
        if url.path.utf8.contains(35) {  // 35 is ASCII code for '#'
            return nil
        }

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
        // Archive items use different cache keys - just return false here
        // The actual pending check happens in generateArchiveThumbnail
        // Use fast ASCII check instead of String.contains which is slow
        if url.path.utf8.contains(35) {  // 35 is ASCII code for '#'
            return false
        }
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

    // MARK: - Fast Image Dimensions

    /// Memory cache for image dimensions (very small, just CGSize)
    private var dimensionsCache: [URL: CGSize] = [:]
    private let dimensionsCacheLock = NSLock()

    /// Video file extensions
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv"]

    /// Get image/video dimensions from file metadata without loading the full file.
    /// This is very fast as it only reads the file header.
    /// Returns nil for unsupported files or if dimensions can't be determined.
    func getImageDimensions(for url: URL) -> CGSize? {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Check cache first
        dimensionsCacheLock.lock()
        if let cached = dimensionsCache[url] {
            dimensionsCacheLock.unlock()
            os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: CACHE HIT %.0fx%.0f", filename, cached.width, cached.height)
            return cached
        }
        dimensionsCacheLock.unlock()

        // Check if it's a video file
        if Self.videoExtensions.contains(ext) {
            return getVideoDimensions(for: url)
        }

        // Use ImageIO to read just the metadata for images
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: failed to create image source", filename)
            return nil
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: failed to get properties", filename)
            return nil
        }

        // Get pixel dimensions
        guard let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else {
            os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: no valid dimensions in properties", filename)
            return nil
        }

        // Check for orientation that swaps dimensions
        var finalWidth = width
        var finalHeight = height
        if let orientation = properties[kCGImagePropertyOrientation] as? Int {
            // Orientations 5, 6, 7, 8 swap width and height
            if orientation >= 5 && orientation <= 8 {
                finalWidth = height
                finalHeight = width
                os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: orientation %d swapped to %.0fx%.0f", filename, orientation, finalWidth, finalHeight)
            }
        }

        let size = CGSize(width: finalWidth, height: finalHeight)

        // Cache the result
        dimensionsCacheLock.lock()
        dimensionsCache[url] = size
        dimensionsCacheLock.unlock()

        os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: READ from file %.0fx%.0f", filename, finalWidth, finalHeight)
        return size
    }

    /// Get video dimensions using AVAsset (fast, reads only header)
    private func getVideoDimensions(for url: URL) -> CGSize? {
        let filename = url.lastPathComponent
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        guard let track = asset.tracks(withMediaType: .video).first else {
            os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: no video track found", filename)
            return nil
        }

        let naturalSize = track.naturalSize
        let transform = track.preferredTransform

        // Apply transform to get actual display size (handles rotation)
        let transformedSize = naturalSize.applying(transform)
        let width = abs(transformedSize.width)
        let height = abs(transformedSize.height)

        guard width > 0, height > 0 else {
            os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: invalid video dimensions", filename)
            return nil
        }

        let size = CGSize(width: width, height: height)

        // Cache the result
        dimensionsCacheLock.lock()
        dimensionsCache[url] = size
        dimensionsCacheLock.unlock()

        os_log(.debug, log: cacheLog, "getImageDimensions [%{public}@]: VIDEO dimensions %.0fx%.0f", filename, width, height)
        return size
    }

    /// Batch fetch dimensions for multiple URLs (runs on background queue)
    func prefetchImageDimensions(for urls: [URL], completion: @escaping ([URL: CGSize]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            var results: [URL: CGSize] = [:]
            for url in urls {
                if let size = self.getImageDimensions(for: url) {
                    results[url] = size
                }
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    /// Clear dimensions cache (call when navigating to new folder)
    func clearDimensionsCache() {
        dimensionsCacheLock.lock()
        dimensionsCache.removeAll()
        dimensionsCacheLock.unlock()
    }

    /// Generate thumbnail with caching and cancellation support
    func generateThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url

        // Skip archive items entirely - extraction causes freezes
        if item.isFromArchive {
            completion(url, item.placeholderIcon)
            return
        }

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

    // MARK: - Archive Thumbnail Generation

    /// File types that benefit from thumbnail extraction
    private static let thumbnailableExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp",
        "mp4", "mov", "avi", "mkv", "m4v", "pdf", "psd", "ai", "eps", "svg"
    ]

    private func generateArchiveThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url

        guard let archiveURL = item.archiveURL,
              let archivePath = item.archivePath else {
            completion(url, item.placeholderIcon)
            return
        }

        // Skip directories
        if item.isDirectory {
            completion(url, item.placeholderIcon)
            return
        }

        // Only extract for file types that benefit from thumbnails
        let ext = (item.name as NSString).pathExtension.lowercased()
        guard Self.thumbnailableExtensions.contains(ext) else {
            completion(url, item.placeholderIcon)
            return
        }

        // Skip files larger than 50MB to avoid slow extraction
        let maxExtractSize: Int64 = 50 * 1024 * 1024
        guard item.size < maxExtractSize else {
            completion(url, item.placeholderIcon)
            return
        }

        let targetSize = clampPixelSize(maxPixelSize)
        let cacheKey = archiveCacheKey(archiveURL: archiveURL, archivePath: archivePath, maxPixelSize: targetSize)

        // Check if already failed
        let alreadyFailed = queue.sync { failedURLs.contains(url) }
        guard !alreadyFailed else {
            completion(url, item.placeholderIcon)
            return
        }

        // Check if already pending
        let alreadyPending = queue.sync { pendingRequests[cacheKey] != nil }
        guard !alreadyPending else {
            return
        }

        // Check caches
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            completion(url, cached)
            return
        }
        if let diskImage = loadFromDisk(key: cacheKey) {
            let cost = estimateCost(for: diskImage)
            memoryCache.setObject(diskImage, forKey: cacheKey as NSString, cost: cost)
            completion(url, diskImage)
            return
        }

        // Track this request
        let generation: Int = queue.sync {
            pendingRequests[cacheKey] = currentGeneration
            return currentGeneration
        }

        // Extract and generate thumbnail on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Check if still valid
            let isValid = self.queue.sync { self.pendingRequests[cacheKey] == generation }
            guard isValid else {
                _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                return
            }

            do {
                // Extract file to temp location
                let extractedURL = try ZipArchiveManager.shared.extractByPath(archivePath, from: archiveURL)

                // Check if still valid after extraction
                let stillValid = self.queue.sync { self.pendingRequests[cacheKey] == generation }
                guard stillValid else {
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                    return
                }

                // Generate thumbnail from extracted file
                self.generateThumbnailFromExtractedFile(
                    extractedURL: extractedURL,
                    originalURL: url,
                    cacheKey: cacheKey,
                    generation: generation,
                    maxPixelSize: targetSize,
                    placeholder: item.placeholderIcon,
                    completion: completion
                )
            } catch {
                DispatchQueue.main.async {
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                    _ = self.queue.sync { self.failedURLs.insert(url) }
                    completion(url, item.placeholderIcon)
                }
            }
        }
    }

    private func generateThumbnailFromExtractedFile(
        extractedURL: URL,
        originalURL: URL,
        cacheKey: String,
        generation: Int,
        maxPixelSize: CGFloat,
        placeholder: NSImage,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        // Determine if it's an image (load directly) or use QuickLook
        let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"])
        let ext = extractedURL.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            // Use ImageIO for images
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false
            ]

            if let imageSource = CGImageSourceCreateWithURL(extractedURL as CFURL, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                    let stillValid = self.queue.sync { generation >= self.currentGeneration - 1 }
                    guard stillValid else { return }

                    self.cacheArchiveImage(image, cacheKey: cacheKey)
                    completion(originalURL, image)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    _ = self.queue.sync { self.pendingRequests.removeValue(forKey: cacheKey) }
                    _ = self.queue.sync { self.failedURLs.insert(originalURL) }
                    completion(originalURL, placeholder)
                }
            }
        } else {
            // Use QuickLook for other file types (PDFs, videos, etc.)
            let size = CGSize(width: maxPixelSize, height: maxPixelSize)
            let request = QLThumbnailGenerator.Request(
                fileAt: extractedURL,
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
                        self.cacheArchiveImage(image, cacheKey: cacheKey)
                        completion(originalURL, image)
                    } else {
                        _ = self.queue.sync { self.failedURLs.insert(originalURL) }
                        completion(originalURL, placeholder)
                    }
                }
            }
        }
    }

    private func archiveCacheKey(archiveURL: URL, archivePath: String, maxPixelSize: CGFloat) -> String {
        let sizeBucket = Int(clampPixelSize(maxPixelSize).rounded(.toNearestOrAwayFromZero))
        var keyString = "archive_\(archiveURL.path)_\(archivePath)_\(sizeBucket)"
        if let mtime = try? archiveURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            keyString += "_\(mtime.timeIntervalSince1970)"
        }

        let hash = SHA256.hash(data: Data(keyString.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func cacheArchiveImage(_ image: NSImage, cacheKey: String) {
        let cost = estimateCost(for: image)
        memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost)

        // Disk cache (async)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.saveToDisk(image: image, key: cacheKey)
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

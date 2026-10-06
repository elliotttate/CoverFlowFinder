import Foundation
import AppKit
import QuickLookThumbnailing
import CryptoKit
import os.log
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

private let cacheLog = OSLog(subsystem: "com.flowfinder", category: "ThumbnailCache")

/// One version of a file's contents. Thumbnails, image dimensions and failure records are keyed
/// on it, so a file edited in place (new mtime or size) gets a new thumbnail.
struct ThumbnailFileVersion: Hashable {
    let path: String
    let modificationTime: TimeInterval?
    let size: Int64
}

/// Groups the thumbnail requests of one view so they can be cancelled together with
/// `ThumbnailCacheManager.cancelRequests(for:)` without touching other views' requests.
/// Requests still pending when the owner is deallocated are cancelled.
final class ThumbnailRequestOwner {
    let id: UInt64
    private let lock = NSLock()
    private var managers: [WeakManager] = []

    private struct WeakManager {
        weak var manager: ThumbnailCacheManager?
    }

    private static let idLock = NSLock()
    private static var lastID: UInt64 = 0

    init() {
        Self.idLock.lock()
        Self.lastID += 1
        id = Self.lastID
        Self.idLock.unlock()
    }

    fileprivate func register(_ manager: ThumbnailCacheManager) {
        lock.lock()
        defer { lock.unlock() }
        managers.removeAll { $0.manager == nil }
        if !managers.contains(where: { $0.manager === manager }) {
            managers.append(WeakManager(manager: manager))
        }
    }

    deinit {
        let ownerID = id
        for entry in managers {
            entry.manager?.cancelRequests(forOwnerID: ownerID)
        }
    }
}

/// Handle for one pending thumbnail request; pass it to `ThumbnailCacheManager.cancel(_:)`.
struct ThumbnailRequestToken: Hashable {
    fileprivate let id: UInt64
}

/// Outcome delivered to a `requestThumbnail` completion.
enum ThumbnailRequestResult {
    case loaded(NSImage)
    /// The file has no thumbnail (unreadable, unsupported). Retried once the file changes.
    case failed
    /// The request was cancelled before it finished. Request again to retry.
    case cancelled

    var image: NSImage? {
        if case .loaded(let image) = self { return image }
        return nil
    }
}

/// Manages thumbnail generation with disk cache, memory cache, and request cancellation
class ThumbnailCacheManager {
    static let shared = ThumbnailCacheManager()

    // MARK: - Memory Cache (NSCache with automatic LRU eviction)
    private let memoryCache = NSCache<NSString, NSImage>()

    // MARK: - Disk Cache
    let diskCacheURL: URL
    private let legacyDiskCacheURLs: [URL]
    private let maxDiskCacheBytes: Int
    private var diskCacheBytes = 0  // ioQueue only
    private let fileManager = FileManager.default
    /// Serial queue for all disk-cache reads, writes and pruning.
    private let ioQueue = DispatchQueue(label: "com.flowfinder.thumbnailcache.io", qos: .userInitiated)
    /// Bounded pool for decoding and rendering, so a grid full of requests doesn't spawn a thread each.
    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flowfinder.thumbnailcache.work"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        return queue
    }()
    /// Encoding for the disk cache, kept apart so it never delays thumbnails on screen.
    private let encodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flowfinder.thumbnailcache.encode"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    // MARK: - Request Tracking (all guarded by stateLock)
    private final class Job {
        let key: String
        var waiters: [Waiter] = []
        var qlRequest: QLThumbnailGenerator.Request?
        var isCancelled = false
        var isFinished = false

        init(key: String) {
            self.key = key
        }
    }

    private struct Waiter {
        let token: UInt64
        let ownerID: UInt64?
        let completion: (ThumbnailRequestResult) -> Void
    }

    private struct FailureRecord {
        let version: ThumbnailFileVersion
        let date: Date
    }

    private let stateLock = NSLock()
    private var jobs: [String: Job] = [:]
    private var jobsByToken: [UInt64: Job] = [:]
    private var tokensByOwner: [UInt64: Set<UInt64>] = [:]
    private var failures: [String: FailureRecord] = [:]  // path -> failed version
    private var versionCache: [String: (version: ThumbnailFileVersion, date: Date)] = [:]
    private var lastToken: UInt64 = 0

    // MARK: - Settings
    private let maxMemoryCacheCount = 1000  // Max thumbnails in memory
    private let maxMemoryCacheCost = 400 * 1024 * 1024  // 400MB
    private let diskCacheMaxAge: TimeInterval = 7 * 24 * 60 * 60  // 7 days since last use
    /// How long a URL-only version lookup (stat) is trusted before it's read again.
    private let versionCacheTTL: TimeInterval = 5
    /// Failed files are retried when they change, or after this long (e.g. still downloading).
    private let failureRetryInterval: TimeInterval = 120
    private static let defaultMaxPixelSize: CGFloat = 256
    private static let minimumPixelSize: CGFloat = 96
    private static let directImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]

    /// Test hook: replaces QuickLook/ImageIO generation. The app never sets it.
    var generatorOverride: ((URL, CGFloat, @escaping (CGImage?) -> Void) -> Void)?

    static func defaultDiskCacheDirectory(cachesDirectory: URL, bundleIdentifier: String?) -> URL {
        cachesDirectory
            .appendingPathComponent(bundleIdentifier ?? "com.flowfinder.app", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    init(
        diskCacheDirectory: URL? = nil,
        legacyDiskCacheDirectories: [URL]? = nil,
        maxDiskCacheBytes: Int = 1024 * 1024 * 1024
    ) {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = diskCacheDirectory ?? Self.defaultDiskCacheDirectory(
            cachesDirectory: cachesDirectory,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        // Cache folder used before the cache moved under the bundle ID.
        legacyDiskCacheURLs = legacyDiskCacheDirectories ?? [cachesDirectory.appendingPathComponent("CoverFlowThumbnails", isDirectory: true)]
        self.maxDiskCacheBytes = maxDiskCacheBytes

        // Configure memory cache limits
        memoryCache.countLimit = maxMemoryCacheCount
        memoryCache.totalCostLimit = maxMemoryCacheCost

        ioQueue.async { [weak self] in
            self?.prepareDiskCache()
        }
    }

    // MARK: - File Versions

    /// The version used for cache keys. Items with loaded metadata need no filesystem access.
    func fileVersion(for item: FileItem) -> ThumbnailFileVersion {
        if item.hasMetadata, let date = item.modificationDate {
            return ThumbnailFileVersion(path: item.url.path, modificationTime: date.timeIntervalSince1970, size: item.size)
        }
        return fileVersion(for: item.url)
    }

    /// Version for a bare URL: one resource-values read, trusted for a couple of seconds.
    func fileVersion(for url: URL) -> ThumbnailFileVersion {
        let path = url.path
        let now = Date()
        stateLock.lock()
        if let cached = versionCache[path], now.timeIntervalSince(cached.date) < versionCacheTTL {
            stateLock.unlock()
            return cached.version
        }
        stateLock.unlock()

        // A fresh URL so we don't get resource values cached on the caller's URL instance.
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let version = ThumbnailFileVersion(
            path: path,
            modificationTime: values?.contentModificationDate?.timeIntervalSince1970,
            size: Int64(values?.fileSize ?? 0)
        )

        stateLock.lock()
        if versionCache.count > 4096 {
            versionCache = versionCache.filter { now.timeIntervalSince($0.value.date) < versionCacheTTL }
        }
        versionCache[path] = (version, now)
        stateLock.unlock()
        return version
    }

    // MARK: - Public API

    /// Memory-cached thumbnail for a URL, or nil. Never touches the disk cache (use
    /// `generateThumbnail`/`requestThumbnail`, which check it off the main thread).
    func getCachedThumbnail(
        for url: URL,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize
    ) -> NSImage? {
        // Archive items have virtual URLs with # in the path and are never cached.
        if url.path.utf8.contains(35) {  // 35 is ASCII code for '#'
            return nil
        }

        if let cached = memoryCache.object(forKey: directoryKey(path: url.path, maxPixelSize: maxPixelSize) as NSString) {
            return cached
        }
        let key = thumbnailKey(fileVersion(for: url), maxPixelSize: maxPixelSize)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Memory-cached thumbnail for an item, keyed on the item's metadata.
    func cachedThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize
    ) -> NSImage? {
        if item.isFromArchive { return nil }
        if item.isDirectory {
            return memoryCache.object(forKey: directoryKey(path: item.url.path, maxPixelSize: maxPixelSize) as NSString)
        }
        let key = thumbnailKey(fileVersion(for: item), maxPixelSize: maxPixelSize)
        return memoryCache.object(forKey: key as NSString)
    }

    /// Whether the current version of the file failed to produce a thumbnail.
    func hasFailed(url: URL) -> Bool {
        if url.path.utf8.contains(35) { return false }
        return hasFailed(version: fileVersion(for: url))
    }

    func hasFailed(item: FileItem) -> Bool {
        if item.isFromArchive || item.isDirectory { return false }
        return hasFailed(version: fileVersion(for: item))
    }

    private func hasFailed(version: ThumbnailFileVersion) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let record = failures[version.path] else { return false }
        if record.version != version || Date().timeIntervalSince(record.date) > failureRetryInterval {
            failures.removeValue(forKey: version.path)
            return false
        }
        return true
    }

    /// Check if request is pending
    func isPending(
        url: URL,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize
    ) -> Bool {
        if url.path.utf8.contains(35) {  // archive item
            return false
        }
        let key = thumbnailKey(fileVersion(for: url), maxPixelSize: maxPixelSize)
        let dirKey = directoryKey(path: url.path, maxPixelSize: maxPixelSize)
        stateLock.lock()
        defer { stateLock.unlock() }
        return jobs[key] != nil || jobs[dirKey] != nil
    }

    func isPending(item: FileItem, maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize) -> Bool {
        guard !item.isFromArchive else { return false }
        let key = item.isDirectory
            ? directoryKey(path: item.url.path, maxPixelSize: maxPixelSize)
            : thumbnailKey(fileVersion(for: item), maxPixelSize: maxPixelSize)
        stateLock.lock()
        defer { stateLock.unlock() }
        return jobs[key] != nil
    }

    /// Kept for source compatibility. Pending requests are no longer invalidated globally;
    /// cancel your own requests with `cancelRequests(for:)` or `cancel(_:)`.
    func incrementGeneration() {}

    /// Kept for source compatibility: forgets failures and cached file versions so files are
    /// re-checked. It no longer cancels anything, because other views' requests share this cache.
    func clearForNewFolder() {
        stateLock.lock()
        failures.removeAll()
        versionCache.removeAll()
        stateLock.unlock()
        // Don't clear memory cache - thumbnails might be reused if user navigates back
    }

    /// Generate thumbnail with caching. The completion runs on the main queue (or synchronously
    /// when the answer is already known) and is always called: with the thumbnail, the item's
    /// placeholder icon when it has none, or nil if the request was cancelled.
    func generateThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize,
        completion: @escaping (URL, NSImage?) -> Void
    ) {
        let url = item.url
        requestThumbnail(for: item, maxPixelSize: maxPixelSize, owner: nil) { result in
            switch result {
            case .loaded(let image):
                completion(url, image)
            case .failed:
                completion(url, item.placeholderIcon)
            case .cancelled:
                completion(url, nil)
            }
        }
    }

    /// Request a thumbnail on behalf of `owner`. Requests for the same file and size share one
    /// job. The completion is always called exactly once, on the main queue, or synchronously when
    /// the result is already known (memory cache hit, known failure); in that case nil is returned.
    @discardableResult
    func requestThumbnail(
        for item: FileItem,
        maxPixelSize: CGFloat = ThumbnailCacheManager.defaultMaxPixelSize,
        owner: ThumbnailRequestOwner?,
        completion: @escaping (ThumbnailRequestResult) -> Void
    ) -> ThumbnailRequestToken? {
        // Skip archive items entirely - extraction causes freezes
        if item.isFromArchive {
            completion(.failed)
            return nil
        }

        let targetSize = clampPixelSize(maxPixelSize)

        // Skip directories - QuickLook returns generic blue folder icons
        // which loses custom folder colors. Use item.icon instead, rendered at the requested size.
        if item.isDirectory {
            let key = directoryKey(path: item.url.path, maxPixelSize: targetSize)
            if let cached = memoryCache.object(forKey: key as NSString) {
                completion(.loaded(cached))
                return nil
            }
            return enqueue(key: key, owner: owner, completion: completion) { job in
                self.workQueue.addOperation { [weak self] in
                    guard let self, !self.isCancelled(job) else { return }
                    // Icon lookup and CGImage rendering are thread-safe
                    let icon = self.renderIconAtSize(item.icon, size: targetSize)
                    self.finish(job, result: .loaded(icon), cgImage: nil, version: nil)
                }
            }
        }

        let version = fileVersion(for: item)
        if hasFailed(version: version) {
            completion(.failed)
            return nil
        }

        let key = thumbnailKey(version, maxPixelSize: targetSize)
        if let cached = memoryCache.object(forKey: key as NSString) {
            completion(.loaded(cached))
            return nil
        }

        return enqueue(key: key, owner: owner, completion: completion) { job in
            self.startThumbnailJob(job, url: item.url, version: version, pixelSize: targetSize)
        }
    }

    /// Cancel one request. Its completion is called with `.cancelled`; the underlying work stops
    /// once no other request is waiting for it.
    func cancel(_ token: ThumbnailRequestToken) {
        cancel(tokenIDs: [token.id])
    }

    /// Cancel every pending request made on behalf of `owner`.
    func cancelRequests(for owner: ThumbnailRequestOwner) {
        cancelRequests(forOwnerID: owner.id)
    }

    fileprivate func cancelRequests(forOwnerID ownerID: UInt64) {
        stateLock.lock()
        let tokens = tokensByOwner[ownerID] ?? []
        stateLock.unlock()
        if !tokens.isEmpty {
            cancel(tokenIDs: Array(tokens))
        }
    }

    private func cancel(tokenIDs: [UInt64]) {
        var cancelledWaiters: [Waiter] = []
        var requestsToCancel: [QLThumbnailGenerator.Request] = []

        stateLock.lock()
        for tokenID in tokenIDs {
            guard let job = jobsByToken.removeValue(forKey: tokenID),
                  let index = job.waiters.firstIndex(where: { $0.token == tokenID }) else { continue }
            let waiter = job.waiters.remove(at: index)
            removeOwnerToken(waiter)
            cancelledWaiters.append(waiter)

            if job.waiters.isEmpty && !job.isFinished {
                job.isCancelled = true
                if jobs[job.key] === job {
                    jobs.removeValue(forKey: job.key)
                }
                if let request = job.qlRequest {
                    requestsToCancel.append(request)
                    job.qlRequest = nil
                }
            }
        }
        stateLock.unlock()

        for request in requestsToCancel {
            QLThumbnailGenerator.shared.cancel(request)
        }
        if !cancelledWaiters.isEmpty {
            DispatchQueue.main.async {
                for waiter in cancelledWaiters {
                    waiter.completion(.cancelled)
                }
            }
        }
    }

    // MARK: - Job Lifecycle

    private func enqueue(
        key: String,
        owner: ThumbnailRequestOwner?,
        completion: @escaping (ThumbnailRequestResult) -> Void,
        start: (Job) -> Void
    ) -> ThumbnailRequestToken {
        owner?.register(self)

        stateLock.lock()
        lastToken += 1
        let tokenID = lastToken
        let waiter = Waiter(token: tokenID, ownerID: owner?.id, completion: completion)
        let job: Job
        let isNew: Bool
        if let existing = jobs[key] {
            job = existing
            isNew = false
        } else {
            job = Job(key: key)
            jobs[key] = job
            isNew = true
        }
        job.waiters.append(waiter)
        jobsByToken[tokenID] = job
        if let ownerID = owner?.id {
            tokensByOwner[ownerID, default: []].insert(tokenID)
        }
        stateLock.unlock()

        if isNew {
            start(job)
        }
        return ThumbnailRequestToken(id: tokenID)
    }

    private func isCancelled(_ job: Job) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return job.isCancelled
    }

    /// Must be called with stateLock held.
    private func removeOwnerToken(_ waiter: Waiter) {
        guard let ownerID = waiter.ownerID else { return }
        tokensByOwner[ownerID]?.remove(waiter.token)
        if tokensByOwner[ownerID]?.isEmpty == true {
            tokensByOwner.removeValue(forKey: ownerID)
        }
    }

    /// Complete a job: cache the result, record failures, and call every waiter on main.
    private func finish(_ job: Job, result: ThumbnailRequestResult, cgImage: CGImage?, version: ThumbnailFileVersion?) {
        stateLock.lock()
        guard !job.isFinished else {
            stateLock.unlock()
            return
        }
        job.isFinished = true
        job.qlRequest = nil
        // Only remove our own entry; a newer job for the same key may have replaced it.
        if jobs[job.key] === job {
            jobs.removeValue(forKey: job.key)
        }
        let waiters = job.waiters
        job.waiters = []
        for waiter in waiters {
            jobsByToken.removeValue(forKey: waiter.token)
            removeOwnerToken(waiter)
        }
        if let version {
            switch result {
            case .failed where !job.isCancelled:
                failures[version.path] = FailureRecord(version: version, date: Date())
            case .loaded:
                failures.removeValue(forKey: version.path)
            default:
                break
            }
        }
        stateLock.unlock()

        if case .loaded(let image) = result {
            memoryCache.setObject(image, forKey: job.key as NSString, cost: estimateCost(for: image))
            if let cgImage {
                saveToDisk(cgImage: cgImage, key: job.key)
            }
        }

        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async {
            for waiter in waiters {
                waiter.completion(result)
            }
        }
    }

    private func startThumbnailJob(_ job: Job, url: URL, version: ThumbnailFileVersion, pixelSize: CGFloat) {
        ioQueue.async { [weak self] in
            guard let self, !self.isCancelled(job) else { return }
            if let data = self.readFromDisk(key: job.key) {
                self.workQueue.addOperation { [weak self] in
                    guard let self else { return }
                    if let cgImage = Self.decodeImage(data) {
                        self.finish(job, result: .loaded(Self.makeImage(cgImage)), cgImage: nil, version: version)
                    } else {
                        self.generate(job, url: url, version: version, pixelSize: pixelSize)
                    }
                }
            } else {
                self.generate(job, url: url, version: version, pixelSize: pixelSize)
            }
        }
    }

    private func generate(_ job: Job, url: URL, version: ThumbnailFileVersion, pixelSize: CGFloat) {
        guard !isCancelled(job) else { return }

        if let generatorOverride {
            generatorOverride(url, pixelSize) { [weak self] cgImage in
                guard let self else { return }
                if let cgImage {
                    self.finish(job, result: .loaded(Self.makeImage(cgImage)), cgImage: cgImage, version: version)
                } else {
                    self.finish(job, result: .failed, cgImage: nil, version: version)
                }
            }
            return
        }

        if Self.directImageExtensions.contains(url.pathExtension.lowercased()) {
            // QuickLook first: it serves its own thumbnail cache. It still generates when that
            // misses (there's no timeout), so fall back to ImageIO only when it fails.
            requestQuickLook(for: job, url: url, pixelSize: pixelSize, types: [.thumbnail]) { [weak self] cgImage in
                guard let self else { return }
                if let cgImage {
                    self.finish(job, result: .loaded(Self.makeImage(cgImage)), cgImage: cgImage, version: version)
                } else {
                    self.generateImageIOThumbnail(for: job, url: url, version: version, pixelSize: pixelSize)
                }
            }
        } else {
            requestQuickLook(for: job, url: url, pixelSize: pixelSize, types: [.thumbnail, .icon]) { [weak self] cgImage in
                guard let self else { return }
                if let cgImage {
                    self.finish(job, result: .loaded(Self.makeImage(cgImage)), cgImage: cgImage, version: version)
                } else {
                    self.finish(job, result: .failed, cgImage: nil, version: version)
                }
            }
        }
    }

    private func requestQuickLook(
        for job: Job,
        url: URL,
        pixelSize: CGFloat,
        types: QLThumbnailGenerator.Request.RepresentationTypes,
        completion: @escaping (CGImage?) -> Void
    ) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: 1.0,
            representationTypes: types
        )

        // Keep the request so cancel(_:) can stop it.
        stateLock.lock()
        let shouldStart = !job.isCancelled
        if shouldStart {
            job.qlRequest = request
        }
        stateLock.unlock()
        guard shouldStart else { return }

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            completion(thumbnail?.cgImage)
        }
    }

    private func generateImageIOThumbnail(for job: Job, url: URL, version: ThumbnailFileVersion, pixelSize: CGFloat) {
        workQueue.addOperation { [weak self] in
            guard let self, !self.isCancelled(job) else { return }

            // Reading a cloud file that isn't downloaded would download it.
            guard Self.isLocallyAvailable(url) else {
                self.finish(job, result: .failed, cgImage: nil, version: version)
                return
            }

            // ImageIO can use embedded EXIF thumbnails
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: Int(pixelSize),
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false  // Don't cache full image
            ]

            if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                self.finish(job, result: .loaded(Self.makeImage(cgImage)), cgImage: cgImage, version: version)
            } else {
                self.finish(job, result: .failed, cgImage: nil, version: version)
            }
        }
    }

    // MARK: - Fast Image Dimensions

    enum MediaKind {
        case image
        case video
        case other
    }

    /// Container extensions AVFoundation may not have a system type for.
    private static let extraVideoExtensions: Set<String> = ["mkv", "webm", "wmv", "flv", "avi", "mts", "m2ts"]

    static func mediaKind(forPathExtension pathExtension: String) -> MediaKind {
        let ext = pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || (type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio)) {
                return .video
            }
        }
        return extraVideoExtensions.contains(ext) ? .video : .other
    }

    private static func mediaKind(for item: FileItem) -> MediaKind {
        switch item.fileType {
        case .image: return .image
        case .video: return .video
        default: return mediaKind(forPathExtension: item.url.pathExtension)
        }
    }

    /// path -> dimensions for one file version; `size == nil` records a failed read.
    private struct DimensionRecord {
        let version: ThumbnailFileVersion
        let size: CGSize?
    }
    private var dimensionsCache: [String: DimensionRecord] = [:]
    private let dimensionsCacheLock = NSLock()

    /// Memory-only dimension lookup (no file access). For items without loaded metadata the
    /// latest record for the path is used.
    func cachedImageDimensions(for item: FileItem) -> CGSize? {
        dimensionsCacheLock.lock()
        defer { dimensionsCacheLock.unlock() }
        return cachedDimensionsLocked(for: item)
    }

    /// Batch form of `cachedImageDimensions(for:)` (one lock for the whole list).
    func cachedImageDimensions(for items: [FileItem]) -> [URL: CGSize] {
        dimensionsCacheLock.lock()
        defer { dimensionsCacheLock.unlock() }
        var results: [URL: CGSize] = [:]
        for item in items {
            if let size = cachedDimensionsLocked(for: item) {
                results[item.url] = size
            }
        }
        return results
    }

    /// Whether a dimension read was attempted for the item's current version (success or failure).
    func hasDimensionRecord(for item: FileItem) -> Bool {
        dimensionsCacheLock.lock()
        defer { dimensionsCacheLock.unlock() }
        guard let record = dimensionsCache[item.url.path] else { return false }
        guard item.hasMetadata, item.modificationDate != nil else { return true }
        return record.version == fileVersion(for: item)
    }

    private func cachedDimensionsLocked(for item: FileItem) -> CGSize? {
        guard let record = dimensionsCache[item.url.path] else { return nil }
        if item.hasMetadata, item.modificationDate != nil, record.version != fileVersion(for: item) {
            return nil
        }
        return record.size
    }

    private func dimensionRecord(for version: ThumbnailFileVersion) -> DimensionRecord? {
        dimensionsCacheLock.lock()
        defer { dimensionsCacheLock.unlock() }
        guard let record = dimensionsCache[version.path], record.version == version else { return nil }
        return record
    }

    private func storeDimensions(_ size: CGSize?, for version: ThumbnailFileVersion) {
        dimensionsCacheLock.lock()
        dimensionsCache[version.path] = DimensionRecord(version: version, size: size)
        dimensionsCacheLock.unlock()
    }

    /// Get image/video dimensions from file metadata without loading the full file.
    /// Images read only the file header; videos are only answered from the cache (fill it with
    /// `prefetchImageDimensions`), because reading a movie's tracks synchronously can block.
    /// Returns nil for unsupported files or if dimensions can't be determined.
    func getImageDimensions(for url: URL) -> CGSize? {
        let version = fileVersion(for: url)
        if let record = dimensionRecord(for: version) {
            return record.size
        }
        guard Self.mediaKind(forPathExtension: url.pathExtension) == .image,
              Self.isLocallyAvailable(url) else { return nil }
        let size = Self.readImageDimensions(at: url)
        storeDimensions(size, for: version)
        return size
    }

    /// Batch fetch dimensions for multiple URLs (runs in the background; completion on main)
    func prefetchImageDimensions(for urls: [URL], completion: @escaping ([URL: CGSize]) -> Void) {
        let requests = urls.map { (url: $0, version: ThumbnailFileVersion?.none, kind: Self.mediaKind(forPathExtension: $0.pathExtension)) }
        prefetchDimensions(requests, completion: completion)
    }

    /// Batch fetch dimensions for items (runs in the background; completion on main). Cached
    /// entries for the same file version are reused; cloud files that aren't downloaded are skipped.
    func prefetchImageDimensions(for items: [FileItem], completion: @escaping ([URL: CGSize]) -> Void) {
        let requests = items.compactMap { item -> (url: URL, version: ThumbnailFileVersion?, kind: MediaKind)? in
            guard !item.isDirectory, !item.isFromArchive, item.url.isFileURL else { return nil }
            let kind = Self.mediaKind(for: item)
            guard kind != .other else { return nil }
            let version: ThumbnailFileVersion? = item.hasMetadata && item.modificationDate != nil ? fileVersion(for: item) : nil
            return (item.url, version, kind)
        }
        prefetchDimensions(requests, completion: completion)
    }

    private func prefetchDimensions(
        _ requests: [(url: URL, version: ThumbnailFileVersion?, kind: MediaKind)],
        completion: @escaping ([URL: CGSize]) -> Void
    ) {
        guard !requests.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            var results: [URL: CGSize] = [:]
            var videos: [(url: URL, version: ThumbnailFileVersion)] = []
            for request in requests {
                let version = request.version ?? self.fileVersion(for: request.url)
                if let record = self.dimensionRecord(for: version) {
                    if let size = record.size {
                        results[request.url] = size
                    }
                    continue
                }
                guard request.kind != .other, Self.isLocallyAvailable(request.url) else { continue }
                if request.kind == .video {
                    videos.append((request.url, version))
                    continue
                }
                let size = Self.readImageDimensions(at: request.url)
                self.storeDimensions(size, for: version)
                if let size {
                    results[request.url] = size
                }
            }

            guard !videos.isEmpty else {
                DispatchQueue.main.async { completion(results) }
                return
            }

            let imageResults = results
            Task.detached(priority: .userInitiated) {
                let videoResults = await self.loadVideoDimensions(videos)
                let merged = imageResults.merging(videoResults) { current, _ in current }
                DispatchQueue.main.async { completion(merged) }
            }
        }
    }

    /// Reads video track sizes with the async AVFoundation API, a few at a time.
    private func loadVideoDimensions(_ videos: [(url: URL, version: ThumbnailFileVersion)]) async -> [URL: CGSize] {
        await withTaskGroup(of: (URL, ThumbnailFileVersion, CGSize?).self) { group in
            var results: [URL: CGSize] = [:]
            var next = 0
            let maxConcurrent = 4

            func addNext() {
                guard next < videos.count else { return }
                let video = videos[next]
                next += 1
                group.addTask {
                    let size = await Self.readVideoDimensions(at: video.url)
                    return (video.url, video.version, size)
                }
            }

            for _ in 0..<min(maxConcurrent, videos.count) {
                addNext()
            }
            while let result = await group.next() {
                storeDimensions(result.2, for: result.1)
                if let size = result.2 {
                    results[result.0] = size
                }
                addNext()
            }
            return results
        }
    }

    private static func readImageDimensions(at url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else {
            return nil
        }

        // Orientations 5, 6, 7, 8 swap width and height
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    private static func readVideoDimensions(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let properties = try? await track.load(.naturalSize, .preferredTransform) else {
            return nil
        }
        // Apply transform to get actual display size (handles rotation)
        let transformed = properties.0.applying(properties.1)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// False for iCloud files whose contents aren't on disk (reading them would download them).
    static func isLocallyAvailable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else {
            return true
        }
        return values.ubiquitousItemDownloadingStatus != .notDownloaded
    }

    /// Forget all image dimensions (they are keyed on file versions, so this is rarely needed).
    func clearDimensionsCache() {
        dimensionsCacheLock.lock()
        dimensionsCache.removeAll()
        dimensionsCacheLock.unlock()
    }

    // MARK: - Keys

    private func thumbnailKey(_ version: ThumbnailFileVersion, maxPixelSize: CGFloat) -> String {
        let sizeBucket = Int(clampPixelSize(maxPixelSize).rounded(.toNearestOrAwayFromZero))
        let mtime = version.modificationTime.map { String($0.bitPattern) } ?? "-"
        return "\(version.path)|\(mtime)|\(version.size)|\(sizeBucket)"
    }

    private func directoryKey(path: String, maxPixelSize: CGFloat) -> String {
        "dir_\(Int(clampPixelSize(maxPixelSize)))_\(path)"
    }

    private func clampPixelSize(_ size: CGFloat) -> CGFloat {
        min(max(size, Self.minimumPixelSize), 1536)
    }

    private func estimateCost(for image: NSImage) -> Int {
        // Estimate memory cost based on image dimensions
        let size = image.size
        return Int(size.width * size.height * 4)  // 4 bytes per pixel (RGBA)
    }

    private static func makeImage(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func diskFileName(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        var chars: [UInt8] = []
        chars.reserveCapacity(64)
        for byte in digest {
            chars.append(hexDigits[Int(byte >> 4)])
            chars.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: chars, as: UTF8.self)
    }

    /// Possible on-disk locations for a key: JPEG for opaque thumbnails, PNG when they have alpha.
    func diskCacheFiles(forKey key: String) -> [URL] {
        let name = Self.diskFileName(forKey: key)
        return [
            diskCacheURL.appendingPathComponent(name + ".jpg"),
            diskCacheURL.appendingPathComponent(name + ".png")
        ]
    }

    /// Disk cache key for a thumbnail (exposed for tests).
    func diskCacheKey(for item: FileItem, maxPixelSize: CGFloat) -> String {
        thumbnailKey(fileVersion(for: item), maxPixelSize: maxPixelSize)
    }

    /// ioQueue: drop the legacy cache folder, enforce age and size limits, and total up the cache.
    private func prepareDiskCache() {
        for legacyURL in legacyDiskCacheURLs where legacyURL.standardizedFileURL != diskCacheURL.standardizedFileURL {
            if fileManager.fileExists(atPath: legacyURL.path) {
                try? fileManager.removeItem(at: legacyURL)
            }
        }
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        pruneDiskCache(removingOlderThan: Date().addingTimeInterval(-diskCacheMaxAge))
    }

    /// Encode (from a CGImage we own, never an NSImage that's on screen) and write in the background.
    private func saveToDisk(cgImage: CGImage, key: String) {
        encodeQueue.addOperation { [weak self] in
            guard let self, let encoded = Self.encodeForDiskCache(cgImage) else { return }
            self.ioQueue.async { [weak self] in
                self?.writeToDisk(encoded.data, isPNG: encoded.isPNG, key: key)
            }
        }
    }

    /// JPEG for opaque images, PNG only when the image has transparency.
    static func encodeForDiskCache(_ cgImage: CGImage) -> (data: Data, isPNG: Bool)? {
        let hasAlpha = imageHasTransparency(cgImage)
        let data = NSMutableData()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, hasAlpha)
    }

    /// ioQueue only.
    private func writeToDisk(_ data: Data, isPNG: Bool, key: String) {
        let files = diskCacheFiles(forKey: key)
        let target = isPNG ? files[1] : files[0]
        if (try? data.write(to: target, options: .atomic)) == nil {
            // The folder may have been removed (clearAllCaches, user cleanup); recreate once.
            try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
            guard (try? data.write(to: target, options: .atomic)) != nil else { return }
        }
        diskCacheBytes += data.count
        if diskCacheBytes > maxDiskCacheBytes {
            pruneDiskCache(removingOlderThan: nil)
        }
    }

    /// ioQueue only. Returns the encoded thumbnail and marks it recently used.
    private func readFromDisk(key: String) -> Data? {
        for file in diskCacheFiles(forKey: key) {
            if let data = try? Data(contentsOf: file) {
                // Touch the modification date: pruning removes the least recently used files.
                _ = file.withUnsafeFileSystemRepresentation { path in
                    path.map { utimes($0, nil) }
                }
                return data
            }
        }
        return nil
    }

    /// Decode fully now (off the main thread) rather than lazily at first draw.
    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func imageHasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            break
        }
        // Many "alpha" thumbnails are fully opaque; check the actual alpha values.
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return true
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return true }
        let bytesPerRow = context.bytesPerRow
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for row in 0..<height {
            let rowStart = buffer + row * bytesPerRow
            for column in 0..<width where rowStart[column * 4 + 3] != 255 {
                return true
            }
        }
        return false
    }

    /// ioQueue only. Removes files last used before `cutoff`, then the least recently used files
    /// until the cache is below 80% of its size limit.
    private func pruneDiskCache(removingOlderThan cutoff: Date?) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: diskCacheURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            diskCacheBytes = 0
            return
        }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
            if let cutoff, date < cutoff {
                try? fileManager.removeItem(at: fileURL)
                continue
            }
            entries.append((fileURL, date, size))
            total += size
        }

        if total > maxDiskCacheBytes {
            let target = maxDiskCacheBytes / 10 * 8
            for entry in entries.sorted(by: { $0.date < $1.date }) {
                guard total > target else { break }
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    total -= entry.size
                }
            }
            os_log(.debug, log: cacheLog, "Pruned thumbnail disk cache to %d bytes", total)
        }
        diskCacheBytes = total
    }

    /// Run any queued disk work and enforce the size limit now (tests).
    func flushDiskCache() {
        waitForDiskIO()
        ioQueue.sync {
            pruneDiskCache(removingOlderThan: nil)
        }
    }

    /// Wait for queued encodes and disk writes (tests).
    func waitForDiskIO() {
        encodeQueue.waitUntilAllOperationsAreFinished()
        ioQueue.sync {}
    }

    /// Clear all caches (for debugging/testing)
    func clearAllCaches() {
        memoryCache.removeAllObjects()
        ioQueue.sync {
            try? fileManager.removeItem(at: diskCacheURL)
            try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
            diskCacheBytes = 0
        }
        stateLock.lock()
        failures.removeAll()
        versionCache.removeAll()
        stateLock.unlock()
        clearDimensionsCache()
    }
}

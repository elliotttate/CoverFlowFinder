import Foundation
import Combine

/// Manages iCloud status detection and monitoring for files
final class CloudStatusManager: ObservableObject {
    static let shared = CloudStatusManager()

    /// Publisher for status changes (sent on the main queue)
    let statusChanged = PassthroughSubject<URL, Never>()

    /// How long a cached status is trusted. Transitional states (and errors) change on their own, so they expire quickly.
    static let transitionalStatusTTL: TimeInterval = 5
    static let stableStatusTTL: TimeInterval = 60

    private struct CacheEntry {
        let status: CloudSyncStatus
        let fetchedAt: Date
    }

    /// Cache for cloud status to avoid repeated filesystem queries
    private var statusCache: [URL: CacheEntry] = [:]
    private let cacheQueue = DispatchQueue(label: "com.flowfinder.cloudstatus", qos: .userInitiated)
    private static let maxCacheEntries = 20_000

    /// iCloud locations (standardized paths without trailing slash). Anything outside them is local.
    private let iCloudRoots: [String]
    private let now: () -> Date
    private let fetcher: ((URL) -> CloudSyncStatus)?

    /// URLResourceKeys needed for iCloud status detection
    static let cloudResourceKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemDownloadRequestedKey,
        .ubiquitousItemHasUnresolvedConflictsKey
    ]

    /// - Parameters:
    ///   - iCloudRoots: Paths treated as iCloud locations; defaults to the current user's iCloud folders.
    ///   - now: Clock used for cache expiry (injectable for tests).
    ///   - fetcher: Replaces the file-system status lookup (tests only).
    init(iCloudRoots: [String]? = nil,
         now: @escaping () -> Date = Date.init,
         fetcher: ((URL) -> CloudSyncStatus)? = nil) {
        self.iCloudRoots = (iCloudRoots ?? Self.defaultICloudRoots()).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.now = now
        self.fetcher = fetcher
    }

    /// The current user's iCloud locations.
    static func defaultICloudRoots(fileManager: FileManager = .default) -> [String] {
        let home = NSHomeDirectory()
        // iCloud Drive (com~apple~CloudDocs) and app containers.
        var roots = [home + "/Library/Mobile Documents"]

        // iCloud Drive exposed through a File Provider domain.
        let cloudStoragePath = home + "/Library/CloudStorage"
        if let contents = try? fileManager.contentsOfDirectory(atPath: cloudStoragePath) {
            roots += contents.filter { $0.contains("iCloud") }.map { cloudStoragePath + "/" + $0 }
        }

        // With "Desktop & Documents Folders" turned on, these sync to iCloud in place.
        for name in ["Desktop", "Documents"] {
            let url = URL(fileURLWithPath: home).appendingPathComponent(name, isDirectory: true)
            if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
                roots.append(url.path)
            }
        }
        return roots
    }

    /// Whether a URL is inside an iCloud location. A cheap path check (no I/O); `getStatus` then confirms
    /// with `isUbiquitousItemKey`.
    func isInICloud(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        return iCloudRoots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Get the cloud sync status for a URL (cached; see `transitionalStatusTTL` / `stableStatusTTL`)
    func getStatus(for url: URL) -> CloudSyncStatus {
        let now = self.now()
        if let entry = cacheQueue.sync(execute: { statusCache[url] }),
           now.timeIntervalSince(entry.fetchedAt) < Self.timeToLive(for: entry.status) {
            return entry.status
        }

        // Not in iCloud = local file
        guard isInICloud(url) else {
            return .local
        }

        let status = fetcher?(url) ?? fetchStatus(for: url)
        cacheQueue.sync {
            if statusCache.count >= Self.maxCacheEntries {
                statusCache = statusCache.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.timeToLive(for: $0.value.status) }
                if statusCache.count >= Self.maxCacheEntries {
                    statusCache.removeAll()
                }
            }
            statusCache[url] = CacheEntry(status: status, fetchedAt: now)
        }
        return status
    }

    static func timeToLive(for status: CloudSyncStatus) -> TimeInterval {
        switch status {
        case .downloading, .uploading, .waitingForUpload, .error:
            return transitionalStatusTTL
        case .local, .downloaded, .notDownloaded, .hasConflict:
            return stableStatusTTL
        }
    }

    /// The iCloud-related resource values of an item, decoupled from `URLResourceValues` so the mapping is testable.
    struct ItemState: Equatable {
        var isUbiquitous = false
        var hasUnresolvedConflicts = false
        var isUploading = false
        var isUploaded: Bool?
        var hasUploadError = false
        var isDownloading = false
        var downloadRequested = false
        var hasDownloadError = false
        var downloadingStatus: URLUbiquitousItemDownloadingStatus?

        init() {}

        init(_ values: URLResourceValues) {
            isUbiquitous = values.isUbiquitousItem ?? false
            hasUnresolvedConflicts = values.ubiquitousItemHasUnresolvedConflicts ?? false
            isUploading = values.ubiquitousItemIsUploading ?? false
            isUploaded = values.ubiquitousItemIsUploaded
            hasUploadError = values.ubiquitousItemUploadingError != nil
            isDownloading = values.ubiquitousItemIsDownloading ?? false
            downloadRequested = values.ubiquitousItemDownloadRequested ?? false
            hasDownloadError = values.ubiquitousItemDownloadingError != nil
            downloadingStatus = values.ubiquitousItemDownloadingStatus
        }
    }

    static func status(for state: ItemState) -> CloudSyncStatus {
        guard state.isUbiquitous else { return .local }
        if state.hasUnresolvedConflicts { return .hasConflict }
        if state.isUploading { return .uploading(progress: nil) }
        if state.isDownloading { return .downloading(progress: nil) }
        if state.hasUploadError || state.hasDownloadError { return .error }

        if state.downloadingStatus == .notDownloaded {
            return state.downloadRequested ? .downloading(progress: nil) : .notDownloaded
        }
        // Present locally (downloaded/current). Not uploaded yet means changes are still queued for iCloud.
        if state.isUploaded == false {
            return .waitingForUpload
        }
        return .downloaded
    }

    /// Fetch status from filesystem
    private func fetchStatus(for url: URL) -> CloudSyncStatus {
        // Legacy placeholder for an item that isn't downloaded (".Name.ext.icloud")
        if Self.isPlaceholderName(url.lastPathComponent) {
            return .notDownloaded
        }

        guard let values = try? url.resourceValues(forKeys: Self.cloudResourceKeys) else {
            return .error
        }
        return Self.status(for: ItemState(values))
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > ".icloud".count + 1
    }

    // MARK: - Invalidation

    /// Drops the cached status of `url` and announces it on `statusChanged`. Call when the item changed on disk.
    func invalidate(url: URL) {
        cacheQueue.sync { _ = statusCache.removeValue(forKey: url) }
        DispatchQueue.main.async {
            self.statusChanged.send(url)
        }
    }

    /// Drops the cached statuses of `directory` and everything inside it (e.g. on file-system events for that folder).
    func invalidate(directory: URL) {
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        cacheQueue.sync {
            let keysToRemove = statusCache.keys.filter {
                let path = $0.standardizedFileURL.path
                return path == directoryPath || path.hasPrefix(prefix)
            }
            for key in keysToRemove {
                statusCache.removeValue(forKey: key)
            }
        }
        DispatchQueue.main.async {
            self.statusChanged.send(directory)
        }
    }

    /// Invalidate cache for a URL
    func invalidateCache(for url: URL) {
        invalidate(url: url)
    }

    /// Invalidate cache for all URLs in a directory
    func invalidateCacheForDirectory(_ directoryURL: URL) {
        invalidate(directory: directoryURL)
    }

    /// Clear all cached statuses
    func clearCache() {
        cacheQueue.sync { statusCache.removeAll() }
    }

    // MARK: - Download/Evict Operations

    /// Start downloading an iCloud item
    func downloadItem(at url: URL) throws {
        // Handle .icloud placeholder - need to get the actual file URL
        let actualURL = resolveICloudPlaceholder(url)

        try FileManager.default.startDownloadingUbiquitousItem(at: actualURL)
        invalidate(url: url)
        invalidate(url: actualURL)
        watchUntilSettled(actualURL)
    }

    /// Evict (remove local copy of) an iCloud item
    func evictItem(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
        invalidate(url: url)
    }

    /// Re-checks a transferring item until it leaves the transitional state, then invalidates it so the new status
    /// (e.g. Downloaded) is published on `statusChanged`.
    private func watchUntilSettled(_ url: URL, attempt: Int = 0) {
        let maxAttempts = 240 // 2 s apart: up to 8 minutes
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let status = self.fetcher?(url) ?? self.fetchStatus(for: url)
            if Self.timeToLive(for: status) == Self.stableStatusTTL || attempt >= maxAttempts {
                self.invalidate(url: url)
            } else {
                self.watchUntilSettled(url, attempt: attempt + 1)
            }
        }
    }

    /// Resolve .icloud placeholder to actual file URL
    private func resolveICloudPlaceholder(_ url: URL) -> URL {
        let filename = url.lastPathComponent

        // Check if it's a .icloud placeholder (format: .filename.icloud)
        if Self.isPlaceholderName(filename) {
            // Extract actual filename: .Document.pdf.icloud -> Document.pdf
            var actualName = filename
            actualName.removeFirst() // Remove leading dot
            actualName = String(actualName.dropLast(7)) // Remove .icloud suffix

            return url.deletingLastPathComponent().appendingPathComponent(actualName)
        }

        return url
    }

    /// Get the placeholder URL for an iCloud file (if it exists)
    func getPlaceholderURL(for url: URL) -> URL? {
        let placeholderName = "." + url.lastPathComponent + ".icloud"
        let placeholderURL = url.deletingLastPathComponent().appendingPathComponent(placeholderName)

        if FileManager.default.fileExists(atPath: placeholderURL.path) {
            return placeholderURL
        }
        return nil
    }
}

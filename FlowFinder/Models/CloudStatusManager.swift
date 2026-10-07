import Foundation
import Combine

/// Manages iCloud status detection and monitoring for files
final class CloudStatusManager: ObservableObject {
    static let shared = CloudStatusManager()

    /// Publisher for status changes: everything invalidated since the last announcement, in one
    /// batch per run-loop turn (sent on the main queue)
    let statusesChanged = PassthroughSubject<[URL], Never>()

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
    static let maxCacheEntries = 20_000
    /// A full cache is trimmed to this many entries (expired first, then the oldest), so trimming
    /// happens once per (max - this) insertions rather than on every insertion
    static let cacheEntriesKeptOnEviction = 15_000

    /// Invalidated URLs not announced yet, and whether an announcement is scheduled (on `cacheQueue`)
    private var pendingAnnouncements: [URL] = []
    private var announcementScheduled = false
    /// Items a Download is being watched for (one polling chain per item, on `cacheQueue`)
    private var settlingURLs: Set<URL> = []

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

        guard let status = fetcher?(url) ?? fetchStatus(for: url) else {
            // Gone (deleted, renamed): no badge, and nothing cached for whatever appears there next
            return .local
        }
        cacheQueue.sync {
            if statusCache.count >= Self.maxCacheEntries, statusCache[url] == nil {
                trimCache(now: now)
            }
            statusCache[url] = CacheEntry(status: status, fetchedAt: now)
        }
        return status
    }

    /// On `cacheQueue`: drops expired entries, then the oldest ones, down to `cacheEntriesKeptOnEviction`.
    private func trimCache(now: Date) {
        statusCache = statusCache.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.timeToLive(for: $0.value.status) }
        let excess = statusCache.count - Self.cacheEntriesKeptOnEviction
        guard excess > 0 else { return }
        let cutoff = statusCache.values.map(\.fetchedAt).sorted()[excess - 1]
        statusCache = statusCache.filter { $0.value.fetchedAt > cutoff }
    }

    /// Number of cached statuses (for tests and diagnostics).
    var cachedStatusCount: Int {
        cacheQueue.sync { statusCache.count }
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

    /// Fetch status from filesystem; nil when the item doesn't exist (anymore)
    private func fetchStatus(for url: URL) -> CloudSyncStatus? {
        // Legacy placeholder for an item that isn't downloaded (".Name.ext.icloud")
        if Self.isPlaceholderName(url.lastPathComponent) {
            return .notDownloaded
        }

        // A fresh URL: URL instances cache resource values
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: Self.cloudResourceKeys) else {
            var info = stat()
            return lstat(url.path, &info) == 0 ? .error : nil
        }
        return Self.status(for: ItemState(values))
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > ".icloud".count + 1
    }

    // MARK: - Invalidation

    /// Drops the cached status of `url` and announces it (see `statusesChanged`). Call when the item changed on disk.
    func invalidate(url: URL) {
        invalidate(urls: [url])
    }

    /// Drops the cached statuses of `urls` and announces them together.
    func invalidate(urls: [URL]) {
        guard !urls.isEmpty else { return }
        cacheQueue.sync {
            for url in urls {
                statusCache.removeValue(forKey: url)
            }
        }
        announce(urls)
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
        announce([directory])
    }

    /// Collects invalidated URLs and publishes them once on the next main-queue turn, so a burst
    /// of invalidations (an iCloud sync touching thousands of files) is one batch, not one
    /// main-queue hop and one re-hydration per file.
    private func announce(_ urls: [URL]) {
        let shouldSchedule: Bool = cacheQueue.sync {
            pendingAnnouncements.append(contentsOf: urls)
            guard !announcementScheduled else { return false }
            announcementScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            let batch: [URL] = self.cacheQueue.sync {
                let batch = self.pendingAnnouncements
                self.pendingAnnouncements.removeAll()
                self.announcementScheduled = false
                return batch
            }
            var seen = Set<URL>()
            self.statusesChanged.send(batch.filter { seen.insert($0).inserted })
        }
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
        invalidate(urls: url == actualURL ? [url] : [url, actualURL])
        // One watch per item: clicking Download again doesn't start another polling chain
        let isNewWatch = cacheQueue.sync { settlingURLs.insert(actualURL).inserted }
        if isNewWatch {
            watchUntilSettled(actualURL)
        }
    }

    /// Evict (remove local copy of) an iCloud item
    func evictItem(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
        invalidate(url: url)
    }

    /// Re-checks a transferring item until it leaves the transitional state (or is gone), then
    /// invalidates it so the new status (e.g. Downloaded) is announced.
    private func watchUntilSettled(_ url: URL, attempt: Int = 0) {
        let maxAttempts = 240 // 2 s apart: up to 8 minutes
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let status = self.fetcher?(url) ?? self.fetchStatus(for: url)
            let settled = status.map { Self.timeToLive(for: $0) == Self.stableStatusTTL } ?? true
            if settled || attempt >= maxAttempts {
                self.cacheQueue.sync { _ = self.settlingURLs.remove(url) }
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

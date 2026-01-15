import Foundation
import Combine

/// Manages iCloud status detection and monitoring for files
final class CloudStatusManager: ObservableObject {
    static let shared = CloudStatusManager()

    /// Publisher for status changes
    let statusChanged = PassthroughSubject<URL, Never>()

    /// Cache for cloud status to avoid repeated filesystem queries
    private var statusCache: [URL: CloudSyncStatus] = [:]
    private let cacheQueue = DispatchQueue(label: "com.flowfinder.cloudstatus", qos: .userInitiated)

    /// Known iCloud container paths (cached for performance)
    private var iCloudPaths: [String] = []
    private var iCloudPathsInitialized = false

    /// URLResourceKeys needed for iCloud status detection
    static let cloudResourceKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemDownloadRequestedKey,
        .ubiquitousItemHasUnresolvedConflictsKey
    ]

    private init() {
        initializeICloudPaths()
    }

    /// Initialize known iCloud paths
    private func initializeICloudPaths() {
        var paths: [String] = []

        // Modern iCloud Drive path (via CloudStorage)
        let cloudStoragePath = NSHomeDirectory() + "/Library/CloudStorage"
        if FileManager.default.fileExists(atPath: cloudStoragePath) {
            // Look for iCloud Drive specifically
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: cloudStoragePath) {
                for item in contents {
                    if item.contains("iCloud") {
                        paths.append(cloudStoragePath + "/" + item)
                    }
                }
            }
        }

        // Legacy Mobile Documents path
        let mobileDocsPath = NSHomeDirectory() + "/Library/Mobile Documents"
        if FileManager.default.fileExists(atPath: mobileDocsPath) {
            paths.append(mobileDocsPath)
        }

        // iCloud Drive symlink path
        let iCloudDrivePath = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloudDrivePath) {
            paths.append(iCloudDrivePath)
        }

        iCloudPaths = paths
        iCloudPathsInitialized = true
    }

    /// Check if a URL is within an iCloud container
    func isInICloud(_ url: URL) -> Bool {
        let path = url.path

        // Check for .icloud placeholder files
        if path.contains(".icloud") || url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" {
            return true
        }

        // Check against known iCloud paths
        for iCloudPath in iCloudPaths {
            if path.hasPrefix(iCloudPath) {
                return true
            }
        }

        // Fallback: check common path patterns
        return path.contains("/Library/Mobile Documents/") ||
               path.contains("/Library/CloudStorage/") && path.contains("iCloud")
    }

    /// Get the cloud sync status for a URL (cached)
    func getStatus(for url: URL) -> CloudSyncStatus {
        // Check cache first
        if let cached = cacheQueue.sync(execute: { statusCache[url] }) {
            return cached
        }

        // Not in iCloud = local file
        guard isInICloud(url) else {
            return .local
        }

        // Query filesystem
        let status = fetchStatus(for: url)
        cacheQueue.sync { statusCache[url] = status }
        return status
    }

    /// Fetch status from filesystem
    private func fetchStatus(for url: URL) -> CloudSyncStatus {
        // Handle .icloud placeholder files (not-downloaded items)
        if url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" {
            return .notDownloaded
        }

        do {
            let resourceValues = try url.resourceValues(forKeys: Self.cloudResourceKeys)

            // Check if it's actually an iCloud item
            guard resourceValues.isUbiquitousItem == true else {
                return .local
            }

            // Check for conflicts first (highest priority)
            if resourceValues.ubiquitousItemHasUnresolvedConflicts == true {
                return .hasConflict
            }

            // Check upload status
            if resourceValues.ubiquitousItemIsUploading == true {
                return .uploading(progress: nil)
            }

            // Check download status
            if resourceValues.ubiquitousItemIsDownloading == true {
                return .downloading(progress: nil)
            }

            // Check download status key for detailed state
            if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                switch downloadStatus {
                case URLUbiquitousItemDownloadingStatus.notDownloaded:
                    return .notDownloaded
                case URLUbiquitousItemDownloadingStatus.downloaded,
                     URLUbiquitousItemDownloadingStatus.current:
                    // Check if also uploaded (fully synced)
                    if resourceValues.ubiquitousItemIsUploaded == true {
                        return .downloaded
                    }
                    return .downloaded
                default:
                    break
                }
            }

            // If uploaded, it's synced
            if resourceValues.ubiquitousItemIsUploaded == true {
                return .downloaded
            }

            // Default to downloaded if we can't determine
            return .downloaded
        } catch {
            // If we can't read the attributes, assume local or error
            return isInICloud(url) ? .error : .local
        }
    }

    /// Invalidate cache for a URL
    func invalidateCache(for url: URL) {
        cacheQueue.sync { statusCache.removeValue(forKey: url) }
        DispatchQueue.main.async {
            self.statusChanged.send(url)
        }
    }

    /// Invalidate cache for all URLs in a directory
    func invalidateCacheForDirectory(_ directoryURL: URL) {
        let directoryPath = directoryURL.path
        cacheQueue.sync {
            let keysToRemove = statusCache.keys.filter { $0.path.hasPrefix(directoryPath) }
            for key in keysToRemove {
                statusCache.removeValue(forKey: key)
            }
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
        invalidateCache(for: url)
        invalidateCache(for: actualURL)
    }

    /// Evict (remove local copy of) an iCloud item
    func evictItem(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
        invalidateCache(for: url)
    }

    /// Resolve .icloud placeholder to actual file URL
    private func resolveICloudPlaceholder(_ url: URL) -> URL {
        let filename = url.lastPathComponent

        // Check if it's a .icloud placeholder (format: .filename.icloud)
        if filename.hasPrefix(".") && filename.hasSuffix(".icloud") {
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

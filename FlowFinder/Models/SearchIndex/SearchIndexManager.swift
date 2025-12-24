import Foundation
import AppKit
import Combine
import os
import UniformTypeIdentifiers

private let searchLogger = Logger(subsystem: "com.flowfinder.app", category: "SearchIndex")

/// Debug logging to file (bypasses stdout buffering)
private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("flowfinder_search.log")
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(logMessage.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? logMessage.data(using: .utf8)?.write(to: logURL)
    }

    // Also print to stdout (may be buffered)
    print(message)
}

/// Represents an indexed file entry
struct IndexedFile: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let fileExtension: String

    init(url: URL, isDirectory: Bool, size: Int64, modificationDate: Date?, creationDate: Date?) {
        self.id = UUID()
        self.path = url.path
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.fileExtension = url.pathExtension.lowercased()
    }

    /// Convert to FileItem for display
    func toFileItem() -> FileItem {
        let url = URL(fileURLWithPath: path)
        let contentType = UTType(filenameExtension: fileExtension)
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modificationDate: modificationDate,
            creationDate: creationDate,
            contentType: contentType
        )
    }
}

/// Node in the file tree structure for path-based queries
final class FileTreeNode: Sendable {
    let name: String
    let indexedFile: IndexedFile?
    private let _children: OSAllocatedUnfairLock<[String: FileTreeNode]>

    var children: [String: FileTreeNode] {
        _children.withLock { $0 }
    }

    init(name: String, indexedFile: IndexedFile? = nil) {
        self.name = name
        self.indexedFile = indexedFile
        self._children = OSAllocatedUnfairLock(initialState: [:])
    }

    func addChild(_ node: FileTreeNode) {
        _children.withLock { $0[node.name] = node }
    }

    func child(named name: String) -> FileTreeNode? {
        _children.withLock { $0[name] }
    }
}

/// Manager for the search index (singleton)
@MainActor
final class SearchIndexManager: ObservableObject {
    static let shared = SearchIndexManager()

    // MARK: - Published State

    @Published private(set) var indexProgress: Double = 0
    @Published private(set) var indexedFileCount: Int = 0
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var isLoadingCache: Bool = false  // True when loading from cache, false when building new index
    @Published private(set) var lastIndexTime: Date?
    @Published private(set) var indexError: String?

    /// Returns true if the index is ready to be searched (not indexing and has entries)
    var isIndexReady: Bool {
        !isIndexing && !nameIndex.isEmpty
    }

    /// Number of unique filenames in the index
    var uniqueNameCount: Int {
        nameIndex.count
    }

    // MARK: - Index Data Structures

    /// Maps lowercase filename → list of indexed files with that name
    private var nameIndex: [String: [IndexedFile]] = [:]

    /// Maps full path → indexed file
    private var pathIndex: [String: IndexedFile] = [:]

    /// Root of the file tree
    private var rootNode: FileTreeNode?

    /// Paths being indexed
    private var indexPaths: [URL] = []

    /// Paths to ignore during indexing
    private var ignorePaths: Set<String> = []

    // MARK: - Indexing State

    private var indexingTask: Task<Void, Never>?
    private var cancellationRequested = false

    // MARK: - Cache

    private let cacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let flowFinderCache = caches.appendingPathComponent("FlowFinder", isDirectory: true)
        try? FileManager.default.createDirectory(at: flowFinderCache, withIntermediateDirectories: true)
        return flowFinderCache.appendingPathComponent("search_index.cache")
    }()

    // MARK: - Initialization

    private init() {
        print("🔍 [SearchIndexManager] Initializing...")
        searchLogger.notice("🔍 SearchIndexManager initializing...")

        // Default paths to index (root)
        indexPaths = [URL(fileURLWithPath: "/")]

        // Default paths to ignore (system dirs, network/external volumes, caches, cloud storage)
        ignorePaths = [
            "/System",
            "/Library/Caches",
            "/.Trash",
            "/private/var",
            "/private/tmp",
            "/dev",
            "/Volumes",  // Skip all external/network volumes to avoid hangs
            "/.fseventsd",
            "/.Spotlight-V100",
            "/Library/Updates",
            "/System/Volumes/Data/.Spotlight-V100",
            "/System/Volumes/Data/private/var",
            "/private",
            "/cores",
            "/.vol",
            "/Library/CloudStorage",  // Skip cloud storage (Google Drive, iCloud, Dropbox, etc.)
            "Library/CloudStorage"    // Match inside user directories too
        ]

        print("🔍 [SearchIndexManager] Initialized. Index paths: \(self.indexPaths.map { $0.path })")
        searchLogger.notice("🔍 SearchIndexManager initialized. Index paths: \(self.indexPaths.map { $0.path })")
    }

    // MARK: - Public API

    /// Start building the index in the background
    func startIndexing() {
        print("🚀 [SearchIndexManager] startIndexing() called. isIndexing=\(self.isIndexing)")
        searchLogger.notice("🚀 startIndexing() called. isIndexing=\(self.isIndexing)")

        guard !isIndexing else {
            print("⚠️ [SearchIndexManager] Indexing already in progress, skipping")
            searchLogger.notice("⚠️ Indexing already in progress, skipping")
            return
        }

        // Set loading state immediately so UI shows loading indicator
        isIndexing = true
        isLoadingCache = true  // Assume loading from cache first
        indexProgress = 0

        // Load cache asynchronously to avoid blocking main thread
        print("📂 [SearchIndexManager] Checking for cached index at: \(self.cacheURL.path)")
        searchLogger.notice("📂 Checking for cached index at: \(self.cacheURL.path)")

        indexingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Try loading from cache on background thread
            let cacheResult = await self.loadFromCacheAsync()

            await MainActor.run {
                if cacheResult {
                    print("✅ [SearchIndexManager] Loaded index from cache with \(self.indexedFileCount) files, \(self.nameIndex.count) unique names")
                    searchLogger.notice("✅ Loaded index from cache with \(self.indexedFileCount) files, \(self.nameIndex.count) unique names")
                    self.isIndexing = false
                    self.isLoadingCache = false
                    self.lastIndexTime = Date()
                } else {
                    print("📂 [SearchIndexManager] No valid cache found, starting fresh index build")
                    searchLogger.notice("📂 No valid cache found, starting fresh index build")
                    // Start fresh build (this will set its own isIndexing state)
                    self.isIndexing = false  // Reset so rebuildIndex can set it
                    self.isLoadingCache = false
                    self.rebuildIndex()
                }
            }
        }
    }

    /// Rebuild the index from scratch
    func rebuildIndex() {
        searchLogger.info("🔄 rebuildIndex() called")
        cancelIndexing()

        isIndexing = true
        indexProgress = 0
        indexedFileCount = 0
        indexError = nil
        cancellationRequested = false

        // Clear existing index
        nameIndex.removeAll()
        pathIndex.removeAll()
        rootNode = nil

        searchLogger.info("🏗️ Starting index build task...")

        // Use background priority so indexing doesn't block UI
        indexingTask = Task(priority: .background) { [weak self] in
            guard let self else {
                searchLogger.error("❌ Self was nil in indexing task")
                return
            }

            do {
                debugLog("🏗️ [SearchIndexManager] buildIndex() starting (background priority)...")
                searchLogger.info("🏗️ buildIndex() starting...")
                try await self.buildIndex()
                debugLog("🏗️ [SearchIndexManager] buildIndex() completed, updating state...")
                await MainActor.run {
                    self.isIndexing = false
                    self.lastIndexTime = Date()
                    debugLog("✅ [SearchIndexManager] Indexing complete: \(self.indexedFileCount) files indexed, \(self.nameIndex.count) unique names")
                    self.saveToCache()
                    searchLogger.info("✅ Indexing complete: \(self.indexedFileCount) files indexed, \(self.nameIndex.count) unique names")
                }
            } catch {
                await MainActor.run {
                    self.isIndexing = false
                    self.indexError = error.localizedDescription
                    debugLog("❌ [SearchIndexManager] Indexing failed: \(error.localizedDescription)")
                    searchLogger.error("❌ Indexing failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Cancel ongoing indexing
    func cancelIndexing() {
        cancellationRequested = true
        indexingTask?.cancel()
        indexingTask = nil
    }

    /// Clear the index and remove cached data
    func clearIndex() {
        cancelIndexing()

        nameIndex.removeAll()
        pathIndex.removeAll()
        rootNode = nil
        indexedFileCount = 0
        indexProgress = 0
        lastIndexTime = nil
        indexError = nil

        // Remove cached index file
        try? FileManager.default.removeItem(at: cacheURL)
        searchLogger.info("Index cleared")
    }

    /// Search the index for files matching the query
    func search(query: String, maxResults: Int = 1000) -> [IndexedFile] {
        print("🔎 [SearchIndexManager] search() called with query: '\(query)', maxResults: \(maxResults)")
        print("📊 [SearchIndexManager] Index state: \(self.indexedFileCount) files, \(self.nameIndex.count) unique names, isIndexing: \(self.isIndexing)")
        searchLogger.notice("🔎 search() called with query: '\(query)', maxResults: \(maxResults)")
        searchLogger.notice("📊 Index state: \(self.indexedFileCount) files, \(self.nameIndex.count) unique names, isIndexing: \(self.isIndexing)")

        guard !query.isEmpty else {
            print("⚠️ [SearchIndexManager] Empty query, returning empty results")
            searchLogger.notice("⚠️ Empty query, returning empty results")
            return []
        }

        let queryLower = query.lowercased()
        var results: [IndexedFile] = []

        // Simple substring search on filename
        for (name, files) in nameIndex {
            if name.contains(queryLower) {
                for file in files {
                    results.append(file)
                    if results.count >= maxResults { break }
                }
            }
            if results.count >= maxResults { break }
        }

        print("🔎 [SearchIndexManager] search() found \(results.count) results for '\(query)'")
        searchLogger.notice("🔎 search() found \(results.count) results for '\(query)'")
        if results.count > 0 {
            print("🔎 [SearchIndexManager] First few results: \(results.prefix(3).map { $0.name })")
            searchLogger.notice("🔎 First few results: \(results.prefix(3).map { $0.name })")
        }

        return results
    }

    /// Search with advanced query parsing
    func searchAdvanced(query: String, maxResults: Int = 1000) -> [IndexedFile] {
        print("🔎 [SearchIndexManager] searchAdvanced() called with query: '\(query)'")
        print("📊 [SearchIndexManager] Index state: \(self.indexedFileCount) files, \(self.nameIndex.count) unique names, isIndexing: \(self.isIndexing)")
        searchLogger.notice("🔎 searchAdvanced() called with query: '\(query)'")
        searchLogger.notice("📊 Index state: \(self.indexedFileCount) files, \(self.nameIndex.count) unique names, isIndexing: \(self.isIndexing)")

        let parsedQuery = SearchQuery.parse(query)
        print("🔎 [SearchIndexManager] Parsed query - pattern: '\(parsedQuery.filenamePattern ?? "nil")', isRegex: \(parsedQuery.isRegex), extensions: \(parsedQuery.extensions)")
        searchLogger.notice("🔎 Parsed query - pattern: '\(parsedQuery.filenamePattern ?? "nil")', isRegex: \(parsedQuery.isRegex), extensions: \(parsedQuery.extensions)")

        let results = search(parsedQuery: parsedQuery, maxResults: maxResults)
        print("🔎 [SearchIndexManager] searchAdvanced() returning \(results.count) results")
        searchLogger.notice("🔎 searchAdvanced() returning \(results.count) results")

        return results
    }

    /// Search using a parsed query
    func search(parsedQuery: SearchQuery, maxResults: Int = 1000) -> [IndexedFile] {
        var results: [IndexedFile] = []

        // If no filename pattern, search all files
        let candidates: [IndexedFile]
        if let pattern = parsedQuery.filenamePattern {
            searchLogger.info("🔎 Searching by filename pattern: '\(pattern)'")
            candidates = searchByFilename(pattern: pattern, isRegex: parsedQuery.isRegex)
            searchLogger.info("🔎 Found \(candidates.count) filename matches")
        } else {
            searchLogger.info("🔎 No filename pattern, searching all \(self.pathIndex.count) files")
            candidates = Array(pathIndex.values)
        }

        // Apply filters
        for file in candidates {
            if parsedQuery.matches(file) {
                results.append(file)
                if results.count >= maxResults { break }
            }
        }

        searchLogger.info("🔎 After filters: \(results.count) results")
        return results
    }

    // MARK: - Private Methods

    /// Build the index by walking the filesystem
    private func buildIndex() async throws {
        let rootNode = FileTreeNode(name: "/")
        self.rootNode = rootNode

        var localNameIndex: [String: [IndexedFile]] = [:]
        var localPathIndex: [String: IndexedFile] = [:]
        var fileCount = 0

        for indexPath in indexPaths {
            guard !cancellationRequested else { break }

            let enumerator = FileManager.default.enumerator(
                at: indexPath,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .isSymbolicLinkKey
                ],
                options: [.skipsPackageDescendants]
            )

            guard let enumerator else { continue }

            for case let url as URL in enumerator {
                guard !cancellationRequested else { break }

                // Skip ignored paths
                let path = url.path
                if shouldIgnore(path: path) {
                    enumerator.skipDescendants()
                    continue
                }

                // Get file attributes
                guard let resourceValues = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isSymbolicLinkKey
                ]) else {
                    continue
                }

                // Skip symbolic links
                if resourceValues.isSymbolicLink == true {
                    continue
                }

                let isDirectory = resourceValues.isDirectory ?? false
                let size = Int64(resourceValues.fileSize ?? 0)
                let modDate = resourceValues.contentModificationDate
                let createDate = resourceValues.creationDate

                let indexedFile = IndexedFile(
                    url: url,
                    isDirectory: isDirectory,
                    size: size,
                    modificationDate: modDate,
                    creationDate: createDate
                )

                // Add to name index
                let nameLower = indexedFile.name.lowercased()
                if localNameIndex[nameLower] == nil {
                    localNameIndex[nameLower] = []
                }
                localNameIndex[nameLower]?.append(indexedFile)

                // Add to path index
                localPathIndex[path] = indexedFile

                fileCount += 1

                // Yield every 100 files to allow UI to remain responsive
                if fileCount % 100 == 0 {
                    await Task.yield()
                }

                // Update progress periodically
                if fileCount % 10000 == 0 {
                    debugLog("📊 [SearchIndexManager] Indexed \(fileCount) files...")
                    await MainActor.run {
                        self.indexedFileCount = fileCount
                    }
                }

                // Log every 1000 files after 970000 to find where it's stuck
                if fileCount > 970000 && fileCount % 1000 == 0 {
                    debugLog("🐌 [SearchIndexManager] At \(fileCount) files, current: \(path)")
                }
            }
            debugLog("📁 [SearchIndexManager] Finished indexPath: \(indexPath.path), total files: \(fileCount)")
        }

        debugLog("🏁 [SearchIndexManager] Enumeration complete. Total: \(fileCount) files, \(localNameIndex.count) unique names")

        // Update final counts
        debugLog("📝 [SearchIndexManager] Updating final state on MainActor...")
        await MainActor.run {
            self.nameIndex = localNameIndex
            self.pathIndex = localPathIndex
            self.indexedFileCount = fileCount
            self.indexProgress = 1.0
            debugLog("📝 [SearchIndexManager] State updated: \(self.indexedFileCount) files, \(self.nameIndex.count) unique names")
        }
    }

    /// Check if a path should be ignored
    private func shouldIgnore(path: String) -> Bool {
        // Check prefix matches
        for ignorePath in ignorePaths {
            if path.hasPrefix(ignorePath) {
                return true
            }
        }

        // Skip hidden directories (except root-level ones like .Trash)
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            if index > 0 && component.hasPrefix(".") && component != ".Trash" {
                return true
            }
        }

        // Skip cloud storage directories (can be very slow to enumerate)
        if path.contains("/Library/CloudStorage/") ||
           path.contains("/Library/Mobile Documents/") {
            return true
        }

        return false
    }

    /// Search by filename pattern
    private func searchByFilename(pattern: String, isRegex: Bool) -> [IndexedFile] {
        let patternLower = pattern.lowercased()
        var results: [IndexedFile] = []

        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return []
            }

            for (name, files) in nameIndex {
                let range = NSRange(name.startIndex..., in: name)
                if regex.firstMatch(in: name, options: [], range: range) != nil {
                    results.append(contentsOf: files)
                }
            }
        } else {
            // Substring search
            for (name, files) in nameIndex {
                if name.contains(patternLower) {
                    results.append(contentsOf: files)
                }
            }
        }

        return results
    }

    // MARK: - Cache Persistence

    private func saveToCache() {
        debugLog("💾 [SearchIndexManager] saveToCache() starting...")
        let cacheData = IndexCacheData(
            nameIndex: nameIndex,
            pathIndex: pathIndex,
            indexedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(cacheData)
            debugLog("💾 [SearchIndexManager] Encoded cache data: \(data.count) bytes, writing to \(cacheURL.path)")
            try data.write(to: cacheURL)
            debugLog("💾 [SearchIndexManager] Cache saved successfully")
            searchLogger.info("Saved index cache: \(data.count) bytes")
        } catch {
            debugLog("❌ [SearchIndexManager] Failed to save cache: \(error.localizedDescription)")
            searchLogger.error("Failed to save index cache: \(error.localizedDescription)")
        }
    }

    /// Load cache asynchronously on a background thread to avoid blocking UI
    private func loadFromCacheAsync() async -> Bool {
        let cacheURL = self.cacheURL

        // Perform heavy I/O on background thread using Task.detached
        let result: (success: Bool, nameIndex: [String: [IndexedFile]], pathIndex: [String: IndexedFile], indexedAt: Date?) = await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: cacheURL.path) else {
                debugLog("📖 [SearchIndexManager] No cache file found")
                return (false, [:], [:], nil)
            }

            do {
                debugLog("📖 [SearchIndexManager] Loading cache file...")
                let data = try Data(contentsOf: cacheURL)
                debugLog("📖 [SearchIndexManager] Cache file loaded (\(data.count) bytes), decoding...")

                let decoder = JSONDecoder()
                let cacheData = try decoder.decode(IndexCacheData.self, from: data)
                debugLog("📖 [SearchIndexManager] Cache decoded: \(cacheData.pathIndex.count) files")

                // Check if cache is too old (older than 24 hours)
                if let indexedAt = cacheData.indexedAt,
                   Date().timeIntervalSince(indexedAt) > 86400 {
                    debugLog("📖 [SearchIndexManager] Cache is stale")
                    return (false, [:], [:], nil)
                }

                return (true, cacheData.nameIndex, cacheData.pathIndex, cacheData.indexedAt)
            } catch {
                debugLog("📖 [SearchIndexManager] Cache load error: \(error.localizedDescription)")
                return (false, [:], [:], nil)
            }
        }.value

        // Update state on main actor
        if result.success {
            self.nameIndex = result.nameIndex
            self.pathIndex = result.pathIndex
            self.indexedFileCount = result.pathIndex.count
            self.lastIndexTime = result.indexedAt
        }

        return result.success
    }

    private func loadFromCache() -> Bool {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            let cacheData = try decoder.decode(IndexCacheData.self, from: data)

            // Check if cache is too old (older than 24 hours)
            if let indexedAt = cacheData.indexedAt,
               Date().timeIntervalSince(indexedAt) > 86400 {
                searchLogger.info("Index cache is stale, rebuilding")
                return false
            }

            nameIndex = cacheData.nameIndex
            pathIndex = cacheData.pathIndex
            indexedFileCount = pathIndex.count
            lastIndexTime = cacheData.indexedAt

            return true
        } catch {
            searchLogger.error("Failed to load index cache: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Cache Data Structure

private struct IndexCacheData: Codable {
    let nameIndex: [String: [IndexedFile]]
    let pathIndex: [String: IndexedFile]
    let indexedAt: Date?
}

import Foundation

/// Per-folder list view state (sort, column widths, order and visibility) with LRU eviction.
///
/// Used when "Remember column settings per folder" is on. A folder gets state only when the user
/// changes its sort or columns while in it (`FileBrowserViewModel`); folders without state use
/// the defaults in `ListColumnConfigManager`. Keyed by standardized path without a trailing slash.
/// Main thread only.
class PerFolderColumnStateManager {
    static let shared = PerFolderColumnStateManager()

    private let maxCacheSize = 100  // LRU limit
    private let persistenceKey = "PerFolderColumnStates"
    private let defaults: UserDefaults
    /// Entries not saved or used for this long are dropped
    private static let expiryInterval: TimeInterval = 30 * 24 * 60 * 60
    /// Using an entry refreshes its (persisted) timestamp at most this often
    private static let touchInterval: TimeInterval = 24 * 60 * 60

    private var cache: [String: FolderColumnState] = [:]
    private var accessOrder: [String] = []  // Most recently used at end

    struct FolderColumnState: Codable {
        let columns: [ColumnSettings]
        let sortColumn: ListColumn
        let sortDirection: SortDirection
        /// When the state was last saved or used
        var timestamp: Date

        init(columns: [ColumnSettings], sortColumn: ListColumn, sortDirection: SortDirection) {
            self.columns = columns
            self.sortColumn = sortColumn
            self.sortDirection = sortDirection
            self.timestamp = Date()
        }

        var sortState: SortState {
            SortState(column: sortColumn, direction: sortDirection)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDisk()
    }

    /// The key for a folder: its standardized path without a trailing slash, so "/a/b/" (from a
    /// directory listing) and "/a/b" (typed, or from FSEvents) share their state.
    static func key(for folderURL: URL) -> String {
        folderURL.standardizedPathKey
    }

    // MARK: - Public API

    /// Gets the stored state for a folder, or nil if none exists
    func getState(for folderURL: URL) -> FolderColumnState? {
        let key = Self.key(for: folderURL)
        guard var state = cache[key] else { return nil }
        markUsed(key)
        // Folders that are visited keep their state (expiry counts from the last use)
        if Date().timeIntervalSince(state.timestamp) > Self.touchInterval {
            state.timestamp = Date()
            cache[key] = state
            saveToDisk()
        }
        return state
    }

    /// Saves the state for a folder
    func saveState(for folderURL: URL, columns: [ColumnSettings], sortState: SortState) {
        let key = Self.key(for: folderURL)
        cache[key] = FolderColumnState(columns: columns, sortColumn: sortState.column, sortDirection: sortState.direction)
        markUsed(key)

        // Evict oldest if over limit
        while accessOrder.count > maxCacheSize {
            let oldestKey = accessOrder.removeFirst()
            cache.removeValue(forKey: oldestKey)
        }

        saveToDisk()
    }

    /// Clears the stored state for a folder
    func clearState(for folderURL: URL) {
        let key = Self.key(for: folderURL)
        guard cache.removeValue(forKey: key) != nil else { return }
        accessOrder.removeAll { $0 == key }
        saveToDisk()
    }

    /// Clears all stored states
    func clearAll() {
        cache.removeAll()
        accessOrder.removeAll()
        defaults.removeObject(forKey: persistenceKey)
    }

    private func markUsed(_ key: String) {
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let data = SavedData(cache: cache, accessOrder: accessOrder)
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: persistenceKey)
        }
    }

    private func loadFromDisk() {
        guard let data = defaults.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode(SavedData.self, from: data) else {
            return
        }

        // Older versions keyed by `URL.absoluteString` ("file:///a/b/"): rekey by path, keeping
        // the newer entry when two keys name the same folder. Stale entries are dropped.
        let cutoff = Date().addingTimeInterval(-Self.expiryInterval)
        var states: [String: FolderColumnState] = [:]
        for (key, state) in saved.cache where state.timestamp >= cutoff {
            let normalized = Self.normalizedKey(key)
            if let existing = states[normalized], existing.timestamp >= state.timestamp { continue }
            states[normalized] = state
        }
        var order: [String] = []
        var seen = Set<String>()
        for key in saved.accessOrder.reversed().map(Self.normalizedKey) where states[key] != nil && seen.insert(key).inserted {
            order.append(key)
        }
        order.reverse()
        // Entries missing from the access order count as least recently used
        let unordered = states.keys.filter { !seen.contains($0) }.sorted { states[$0]!.timestamp < states[$1]!.timestamp }
        order = unordered + order
        while order.count > maxCacheSize {
            states.removeValue(forKey: order.removeFirst())
        }

        cache = states
        accessOrder = order
    }

    private static func normalizedKey(_ key: String) -> String {
        guard key.hasPrefix("file:"), let url = URL(string: key), url.isFileURL else { return key }
        return url.standardizedPathKey
    }

    private struct SavedData: Codable {
        let cache: [String: FolderColumnState]
        let accessOrder: [String]
    }
}

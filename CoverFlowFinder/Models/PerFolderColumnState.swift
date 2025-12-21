import Foundation

/// Manages per-folder column state with LRU eviction
/// When enabled in settings, column configuration (widths, visibility, order, sort) is stored per folder
class PerFolderColumnStateManager {
    static let shared = PerFolderColumnStateManager()

    private let maxCacheSize = 100  // LRU limit
    private let persistenceKey = "PerFolderColumnStates"

    private var cache: [String: FolderColumnState] = [:]
    private var accessOrder: [String] = []  // Most recently used at end

    struct FolderColumnState: Codable {
        let columns: [ColumnSettings]
        let sortColumn: ListColumn
        let sortDirection: SortDirection
        let timestamp: Date

        init(columns: [ColumnSettings], sortColumn: ListColumn, sortDirection: SortDirection) {
            self.columns = columns
            self.sortColumn = sortColumn
            self.sortDirection = sortDirection
            self.timestamp = Date()
        }
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    /// Gets the stored column state for a folder, or nil if none exists
    func getState(for folderURL: URL) -> FolderColumnState? {
        let key = folderURL.absoluteString
        if let state = cache[key] {
            // Update access order (move to end = most recently used)
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
                accessOrder.append(key)
            }
            return state
        }
        return nil
    }

    /// Saves the current column state for a folder
    func saveState(for folderURL: URL, columns: [ColumnSettings], sortColumn: ListColumn, sortDirection: SortDirection) {
        let key = folderURL.absoluteString
        let state = FolderColumnState(columns: columns, sortColumn: sortColumn, sortDirection: sortDirection)

        // Update cache
        cache[key] = state

        // Update access order
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(key)

        // Evict oldest if over limit
        while accessOrder.count > maxCacheSize {
            let oldestKey = accessOrder.removeFirst()
            cache.removeValue(forKey: oldestKey)
        }

        saveToDisk()
    }

    /// Clears the stored state for a folder
    func clearState(for folderURL: URL) {
        let key = folderURL.absoluteString
        cache.removeValue(forKey: key)
        if let index = accessOrder.firstIndex(of: key) {
            accessOrder.remove(at: index)
        }
        saveToDisk()
    }

    /// Clears all stored states
    func clearAll() {
        cache.removeAll()
        accessOrder.removeAll()
        UserDefaults.standard.removeObject(forKey: persistenceKey)
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let data = SavedData(cache: cache, accessOrder: accessOrder)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: persistenceKey)
        }
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode(SavedData.self, from: data) else {
            return
        }

        cache = saved.cache
        accessOrder = saved.accessOrder

        // Clean up any stale entries (older than 30 days)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for key in cache.keys {
            if let state = cache[key], state.timestamp < thirtyDaysAgo {
                cache.removeValue(forKey: key)
                if let index = accessOrder.firstIndex(of: key) {
                    accessOrder.remove(at: index)
                }
            }
        }
    }

    private struct SavedData: Codable {
        let cache: [String: FolderColumnState]
        let accessOrder: [String]
    }
}

// MARK: - Integration with ListColumnConfigManager

extension ListColumnConfigManager {
    /// Applies the stored per-folder state if available and the setting is enabled
    @MainActor
    func applyPerFolderState(for folderURL: URL, appSettings: AppSettings) {
        guard appSettings.usePerFolderColumnState else { return }

        if let state = PerFolderColumnStateManager.shared.getState(for: folderURL) {
            self.columns = state.columns
            self.sortColumn = state.sortColumn
            self.sortDirection = state.sortDirection
        }
    }

    /// Saves the current state for the folder if per-folder state is enabled
    @MainActor
    func saveCurrentStateForFolder(_ folderURL: URL, appSettings: AppSettings) {
        guard appSettings.usePerFolderColumnState else { return }

        PerFolderColumnStateManager.shared.saveState(
            for: folderURL,
            columns: columns,
            sortColumn: sortColumn,
            sortDirection: sortDirection
        )
    }
}

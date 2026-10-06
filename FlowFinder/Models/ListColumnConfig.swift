import Foundation
import AppKit
import SwiftUI

// Column types available in the file list
enum ListColumn: String, CaseIterable, Codable, Identifiable {
    case name = "Name"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"
    case kind = "Kind"
    case tags = "Tags"
    case cloudStatus = "iCloud Status"

    var id: String { rawValue }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 250
        case .dateModified: return 150
        case .dateCreated: return 150
        case .size: return 90
        case .kind: return 110
        case .tags: return 120
        case .cloudStatus: return 80
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 120
        case .dateModified: return 100
        case .dateCreated: return 100
        case .size: return 60
        case .kind: return 70
        case .tags: return 80
        case .cloudStatus: return 50
        }
    }

    var alignment: Alignment {
        return .leading
    }

    var textAlignment: TextAlignment {
        return .leading
    }

    var defaultSortDirection: SortDirection {
        switch self {
        case .name, .kind, .tags, .cloudStatus:
            return .ascending
        case .dateModified, .dateCreated, .size:
            return .descending
        }
    }
}

// Configuration for a single column
struct ColumnSettings: Codable, Identifiable, Equatable {
    var column: ListColumn
    var width: CGFloat
    var isVisible: Bool

    var id: String { column.id }

    init(column: ListColumn, width: CGFloat? = nil, isVisible: Bool = true) {
        self.column = column
        self.width = width ?? column.defaultWidth
        self.isVisible = isVisible
    }
}

// Sort direction
enum SortDirection: String, Codable {
    case ascending
    case descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct SortState: Equatable {
    let column: ListColumn
    let direction: SortDirection
}

/// The list view's shared column layout and the default sort.
///
/// Each `FileBrowserViewModel` owns the sort it shows (`sortState`); `sortColumn`/`sortDirection`
/// here are only the sort a pane starts with in a folder without saved per-folder state. The
/// column layout is shared by every list, except in a folder with its own saved layout
/// (`FileBrowserViewModel.folderColumns`).
class ListColumnConfigManager: ObservableObject {
    static let shared = ListColumnConfigManager()

    @Published var columns: [ColumnSettings] {
        didSet { scheduleSave() }
    }

    /// Default sort column for folders without saved state (see `defaultSortState`)
    @Published var sortColumn: ListColumn {
        didSet { scheduleSave() }
    }

    /// Default sort direction for folders without saved state (see `defaultSortState`)
    @Published var sortDirection: SortDirection {
        didSet { scheduleSave() }
    }

    private let configKey = "ListColumnConfig"
    private let defaults: UserDefaults
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    /// Persistence is coalesced: a column drag or a burst of changes writes once.
    static let saveDebounceInterval: TimeInterval = 0.5

    static let defaultColumns: [ColumnSettings] = [
        ColumnSettings(column: .name, isVisible: true),
        ColumnSettings(column: .dateModified, isVisible: true),
        ColumnSettings(column: .size, isVisible: true),
        ColumnSettings(column: .kind, isVisible: true),
        ColumnSettings(column: .dateCreated, isVisible: false),
        ColumnSettings(column: .tags, isVisible: false),
        ColumnSettings(column: .cloudStatus, isVisible: false)
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load saved config or use defaults
        if let data = defaults.data(forKey: configKey),
           let config = try? JSONDecoder().decode(SavedConfig.self, from: data) {
            // Configs saved before a column existed lack it; merge it in (hidden) so the
            // header menu can show it.
            self.columns = Self.normalizedColumns(config.columns)
            self.sortColumn = config.sortColumn
            self.sortDirection = config.sortDirection
        } else {
            // Default column order and visibility
            self.columns = Self.defaultColumns
            self.sortColumn = .name
            self.sortDirection = .ascending
        }

        // Don't lose a pending (debounced) save when the app quits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushPendingSave()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Removes duplicates, appends any `ListColumn` missing from `columns` (hidden, default width),
    /// clamps widths to the column minimum and keeps Name visible.
    static func normalizedColumns(_ columns: [ColumnSettings]) -> [ColumnSettings] {
        var seen = Set<ListColumn>()
        var result: [ColumnSettings] = []
        result.reserveCapacity(ListColumn.allCases.count)
        for var settings in columns where seen.insert(settings.column).inserted {
            settings.width = max(settings.column.minWidth, settings.width)
            if settings.column == .name {
                settings.isVisible = true
            }
            result.append(settings)
        }
        for column in ListColumn.allCases where !seen.contains(column) {
            result.append(ColumnSettings(column: column, isVisible: column == .name))
        }
        return result
    }

    var visibleColumns: [ColumnSettings] {
        columns.filter { $0.isVisible }
    }

    func toggleColumnVisibility(_ column: ListColumn) {
        let isVisible = columns.first(where: { $0.column == column })?.isVisible ?? false
        let updated = Self.columns(columns, setting: column, visible: !isVisible)
        if updated != columns {
            columns = updated
        }
    }

    /// `columns` with `column` shown or hidden. Name can't be hidden; a column missing from
    /// `columns` is added.
    static func columns(_ columns: [ColumnSettings], setting column: ListColumn, visible: Bool) -> [ColumnSettings] {
        guard column != .name else { return columns }
        var updated = columns
        if let index = updated.firstIndex(where: { $0.column == column }) {
            updated[index].isVisible = visible
        } else {
            updated.append(ColumnSettings(column: column, isVisible: visible))
        }
        return updated
    }

    func setColumnWidth(_ column: ListColumn, width: CGFloat) {
        if let index = columns.firstIndex(where: { $0.column == column }) {
            columns[index].width = max(column.minWidth, width)
        }
    }

    /// Applies a new visible-column order and widths in one change (one publish, one save).
    /// Hidden columns keep their settings and stay after the visible ones.
    func applyColumnLayout(visibleOrder: [ListColumn], widths: [ListColumn: CGFloat]) {
        let updated = Self.columns(columns, applyingVisibleOrder: visibleOrder, widths: widths)
        if updated != columns {
            columns = updated
        }
    }

    /// `columns` with the visible columns in `visibleOrder`, with the given widths.
    static func columns(
        _ columns: [ColumnSettings],
        applyingVisibleOrder visibleOrder: [ListColumn],
        widths: [ListColumn: CGFloat]
    ) -> [ColumnSettings] {
        var updated: [ColumnSettings] = []
        for column in visibleOrder {
            guard var settings = columns.first(where: { $0.column == column }) else { continue }
            if let width = widths[column] {
                settings.width = max(column.minWidth, width)
            }
            settings.isVisible = true
            updated.append(settings)
        }
        for settings in columns where !visibleOrder.contains(settings.column) {
            updated.append(settings)
        }
        return updated
    }

    /// `columns` with the given widths, and the columns in `order` rearranged into that order
    /// within the positions they occupy. Visibility is unchanged.
    static func columns(
        _ columns: [ColumnSettings],
        reordering order: [ListColumn],
        widths: [ListColumn: CGFloat]
    ) -> [ColumnSettings] {
        var updated = columns
        for index in updated.indices {
            if let width = widths[updated[index].column] {
                updated[index].width = max(updated[index].column.minWidth, width)
            }
        }
        let moving = Set(order)
        let slots = updated.indices.filter { moving.contains(updated[$0].column) }
        let settingsByColumn = Dictionary(slots.map { (updated[$0].column, updated[$0]) }, uniquingKeysWith: { first, _ in first })
        for (slot, settings) in zip(slots, order.compactMap { settingsByColumn[$0] }) {
            updated[slot] = settings
        }
        return updated
    }

    func moveColumn(from source: IndexSet, to destination: Int) {
        columns.move(fromOffsets: source, toOffset: destination)
    }

    func resetToDefaults() {
        columns = Self.defaultColumns
        sortColumn = .name
        sortDirection = .ascending
    }

    /// The sort a pane starts with in a folder without saved state of its own. An explicit sort
    /// change in any pane updates it.
    var defaultSortState: SortState {
        get { SortState(column: sortColumn, direction: sortDirection) }
        set {
            if sortColumn != newValue.column { sortColumn = newValue.column }
            if sortDirection != newValue.direction { sortDirection = newValue.direction }
        }
    }

    @available(*, deprecated, message: "Sort is per pane: use FileBrowserViewModel.sortState (this is only the default)")
    func sortStateSnapshot() -> SortState {
        defaultSortState
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveConfig()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceInterval, execute: work)
    }

    /// Writes a pending (debounced) change immediately.
    func flushPendingSave() {
        guard let pendingSave else { return }
        pendingSave.cancel()
        saveConfig()
    }

    private func saveConfig() {
        pendingSave = nil
        let config = SavedConfig(columns: columns, sortColumn: sortColumn, sortDirection: sortDirection)
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: configKey)
        }
    }

    private struct SavedConfig: Codable {
        let columns: [ColumnSettings]
        let sortColumn: ListColumn
        let sortDirection: SortDirection
    }

    /// Sorts `items` for display with the given sort state. Pure (no shared state), safe off the main thread;
    /// any view that shows a sorted file list can reuse it.
    static func sortedItems(_ items: [FileItem], sortState: SortState, foldersFirst: Bool = true) -> [FileItem] {
        sortedItems(items, sortState: sortState, foldersFirst: foldersFirst, tagProvider: { $0.tags })
    }

    /// Sort keys are computed once per item (decorate-sort-undecorate), so sorting by tags
    /// reads each file's tags once instead of twice per comparison.
    static func sortedItems(
        _ items: [FileItem],
        sortState: SortState,
        foldersFirst: Bool,
        tagProvider: (FileItem) -> [String]
    ) -> [FileItem] {
        guard items.count > 1 else { return items }

        // String sort keys for the columns whose key is derived (only computed when needed)
        let keys: [String]
        switch sortState.column {
        case .kind:
            keys = items.map { $0.kindDescription }
        case .tags:
            keys = items.map { tagProvider($0).joined(separator: ",") }
        case .cloudStatus:
            keys = items.map { $0.cloudStatus?.description ?? "" }
        case .name, .dateModified, .dateCreated, .size:
            keys = []
        }

        // Folders first. Packages (.app, .rtfd, …) open as documents, so like Finder they sort with files.
        let isFolder: [Bool] = foldersFirst ? items.map { $0.isDirectory && !$0.isPackage } : []

        let ascending = sortState.direction == .ascending
        let order = items.indices.sorted { lhs, rhs in
            let item1 = items[lhs]
            let item2 = items[rhs]

            if foldersFirst, isFolder[lhs] != isFolder[rhs] {
                return isFolder[lhs]
            }

            let comparison: ComparisonResult
            switch sortState.column {
            case .name:
                comparison = item1.name.localizedStandardCompare(item2.name)
            case .dateModified:
                comparison = (item1.modificationDate ?? .distantPast).compare(item2.modificationDate ?? .distantPast)
            case .dateCreated:
                comparison = (item1.creationDate ?? .distantPast).compare(item2.creationDate ?? .distantPast)
            case .size:
                if item1.size == item2.size {
                    comparison = .orderedSame
                } else {
                    comparison = item1.size < item2.size ? .orderedAscending : .orderedDescending
                }
            case .kind, .tags, .cloudStatus:
                comparison = keys[lhs].localizedStandardCompare(keys[rhs])
            }

            if comparison != .orderedSame {
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }

            // Ties: natural name order, then path so the order is deterministic
            let nameComparison = item1.name.localizedStandardCompare(item2.name)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return item1.url.path < item2.url.path
        }
        return order.map { items[$0] }
    }
}

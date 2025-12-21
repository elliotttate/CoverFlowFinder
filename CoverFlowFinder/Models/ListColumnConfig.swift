import Foundation
import SwiftUI

// Column types available in the file list
enum ListColumn: String, CaseIterable, Codable, Identifiable {
    case name = "Name"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"
    case kind = "Kind"
    case tags = "Tags"

    var id: String { rawValue }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 250
        case .dateModified: return 150
        case .dateCreated: return 150
        case .size: return 90
        case .kind: return 110
        case .tags: return 120
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
        case .name, .kind, .tags:
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

// Observable column configuration manager
class ListColumnConfigManager: ObservableObject {
    static let shared = ListColumnConfigManager()

    @Published var columns: [ColumnSettings] {
        didSet { saveConfig() }
    }

    @Published var sortColumn: ListColumn {
        didSet { saveConfig() }
    }

    @Published var sortDirection: SortDirection {
        didSet { saveConfig() }
    }

    private let configKey = "ListColumnConfig"

    init() {
        // Load saved config or use defaults
        if let data = UserDefaults.standard.data(forKey: configKey),
           let config = try? JSONDecoder().decode(SavedConfig.self, from: data) {
            self.columns = config.columns
            self.sortColumn = config.sortColumn
            self.sortDirection = config.sortDirection
        } else {
            // Default column order and visibility
            self.columns = [
                ColumnSettings(column: .name, isVisible: true),
                ColumnSettings(column: .dateModified, isVisible: true),
                ColumnSettings(column: .size, isVisible: true),
                ColumnSettings(column: .kind, isVisible: true),
                ColumnSettings(column: .dateCreated, isVisible: false),
                ColumnSettings(column: .tags, isVisible: false)
            ]
            self.sortColumn = .name
            self.sortDirection = .ascending
        }
    }

    var visibleColumns: [ColumnSettings] {
        columns.filter { $0.isVisible }
    }

    func toggleColumnVisibility(_ column: ListColumn) {
        if let index = columns.firstIndex(where: { $0.column == column }) {
            // Don't allow hiding the name column
            if column == .name { return }
            columns[index].isVisible.toggle()
        }
    }

    func setColumnWidth(_ column: ListColumn, width: CGFloat) {
        if let index = columns.firstIndex(where: { $0.column == column }) {
            columns[index].width = max(column.minWidth, width)
        }
    }

    func setSortColumn(_ column: ListColumn) {
        if sortColumn == column {
            sortDirection.toggle()
        } else {
            sortColumn = column
            sortDirection = column.defaultSortDirection
        }
    }

    func moveColumn(from source: IndexSet, to destination: Int) {
        columns.move(fromOffsets: source, toOffset: destination)
    }

    func resetToDefaults() {
        columns = [
            ColumnSettings(column: .name, isVisible: true),
            ColumnSettings(column: .dateModified, isVisible: true),
            ColumnSettings(column: .size, isVisible: true),
            ColumnSettings(column: .kind, isVisible: true),
            ColumnSettings(column: .dateCreated, isVisible: false),
            ColumnSettings(column: .tags, isVisible: false)
        ]
        sortColumn = .name
        sortDirection = .ascending
    }

    func sortStateSnapshot() -> SortState {
        SortState(column: sortColumn, direction: sortDirection)
    }

    private func saveConfig() {
        let config = SavedConfig(columns: columns, sortColumn: sortColumn, sortDirection: sortDirection)
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private struct SavedConfig: Codable {
        let columns: [ColumnSettings]
        let sortColumn: ListColumn
        let sortDirection: SortDirection
    }

    // Sort items based on current configuration
    func sortedItems(_ items: [FileItem], foldersFirst: Bool = true) -> [FileItem] {
        Self.sortedItems(items, sortState: sortStateSnapshot(), foldersFirst: foldersFirst)
    }

    static func sortedItems(_ items: [FileItem], sortState: SortState, foldersFirst: Bool = true) -> [FileItem] {
        items.sorted { item1, item2 in
            // Folders always come first
            if foldersFirst, item1.isDirectory != item2.isDirectory {
                return item1.isDirectory
            }

            let comparison: ComparisonResult
            switch sortState.column {
            case .name:
                comparison = item1.name.localizedStandardCompare(item2.name)
            case .dateModified:
                let date1 = item1.modificationDate ?? Date.distantPast
                let date2 = item2.modificationDate ?? Date.distantPast
                comparison = date1.compare(date2)
            case .dateCreated:
                let date1 = item1.creationDate ?? Date.distantPast
                let date2 = item2.creationDate ?? Date.distantPast
                comparison = date1.compare(date2)
            case .size:
                if item1.size == item2.size {
                    comparison = .orderedSame
                } else {
                    comparison = item1.size < item2.size ? .orderedAscending : .orderedDescending
                }
            case .kind:
                comparison = item1.kindDescription.localizedStandardCompare(item2.kindDescription)
            case .tags:
                let tags1 = FileTagManager.getTags(for: item1.url).joined(separator: ",")
                let tags2 = FileTagManager.getTags(for: item2.url).joined(separator: ",")
                comparison = tags1.localizedCaseInsensitiveCompare(tags2)
            }

            if comparison == .orderedSame {
                return item1.name.localizedStandardCompare(item2.name) == .orderedAscending
            }

            return sortState.direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }
}

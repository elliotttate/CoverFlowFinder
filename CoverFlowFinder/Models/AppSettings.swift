import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let showHiddenFiles = "settings.showHiddenFiles"
        static let showFileExtensions = "settings.showFileExtensions"
        static let foldersFirst = "settings.foldersFirst"
        static let showPathBar = "settings.showPathBar"
        static let showStatusBar = "settings.showStatusBar"
        static let showItemTags = "settings.showItemTags"
        static let sidebarShowFavorites = "settings.sidebarShowFavorites"
        static let sidebarShowICloud = "settings.sidebarShowICloud"
        static let sidebarShowLocations = "settings.sidebarShowLocations"
        static let sidebarShowTags = "settings.sidebarShowTags"
        static let sidebarFavorites = "settings.sidebarFavorites"
        static let thumbnailQuality = "settings.thumbnailQuality"
        static let masonryShowFilenames = "settings.masonryShowFilenames"

        static let listFontSize = "settings.listFontSize"
        static let listIconSize = "settings.listIconSize"

        static let iconGridIconSize = "settings.iconGridIconSize"
        static let iconGridFontSize = "settings.iconGridFontSize"
        static let iconGridSpacing = "settings.iconGridSpacing"

        static let columnFontSize = "settings.columnFontSize"
        static let columnIconSize = "settings.columnIconSize"
        static let columnWidth = "settings.columnWidth"
        static let columnShowPreview = "settings.columnShowPreview"
        static let columnPreviewWidth = "settings.columnPreviewWidth"

        static let coverFlowTitleFontSize = "settings.coverFlowTitleFontSize"
        static let coverFlowScale = "settings.coverFlowScale"
        static let coverFlowSwipeSpeed = "settings.coverFlowSwipeSpeed"
        static let coverFlowShowInfo = "settings.coverFlowShowInfo"
        static let coverFlowPaneHeight = "settings.coverFlowPaneHeight"
        static let usePerFolderColumnState = "settings.usePerFolderColumnState"
    }

    private enum Defaults {
        static let showHiddenFiles = false
        static let showFileExtensions = true
        static let foldersFirst = true
        static let showPathBar = true
        static let showStatusBar = true
        static let showItemTags = true
        static let sidebarShowFavorites = true
        static let sidebarShowICloud = true
        static let sidebarShowLocations = true
        static let sidebarShowTags = true
        static let sidebarFavorites: [SidebarFavorite] = [
            .system(.documents),
            .system(.applications),
            .system(.desktop),
            .system(.downloads),
            .system(.movies),
            .system(.music),
            .system(.pictures)
        ]
        static let sidebarFavoritesData: Data = {
            (try? JSONEncoder().encode(sidebarFavorites)) ?? Data()
        }()
        static let thumbnailQuality: Double = 1.15
        static let masonryShowFilenames = false

        static let listFontSize: Double = 13
        static let listIconSize: Double = 20

        static let iconGridIconSize: Double = 80
        static let iconGridFontSize: Double = 12
        static let iconGridSpacing: Double = 24

        static let columnFontSize: Double = 13
        static let columnIconSize: Double = 16
        static let columnWidth: Double = 220
        static let columnShowPreview = true
        static let columnPreviewWidth: Double = 260

        static let coverFlowTitleFontSize: Double = 15
        static let coverFlowScale: Double = 1.2
        static let coverFlowSwipeSpeed: Double = 1.0
        static let coverFlowShowInfo = true
        static let coverFlowPaneHeight: Double = 0
        static let usePerFolderColumnState = true  // Finder-like behavior (default)
    }

    private let defaults: UserDefaults

    @Published var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Keys.showHiddenFiles) }
    }
    @Published var showFileExtensions: Bool {
        didSet { defaults.set(showFileExtensions, forKey: Keys.showFileExtensions) }
    }
    @Published var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: Keys.foldersFirst) }
    }
    @Published var showPathBar: Bool {
        didSet { defaults.set(showPathBar, forKey: Keys.showPathBar) }
    }
    @Published var showStatusBar: Bool {
        didSet { defaults.set(showStatusBar, forKey: Keys.showStatusBar) }
    }
    @Published var showItemTags: Bool {
        didSet { defaults.set(showItemTags, forKey: Keys.showItemTags) }
    }
    @Published var sidebarShowFavorites: Bool {
        didSet { defaults.set(sidebarShowFavorites, forKey: Keys.sidebarShowFavorites) }
    }
    @Published var sidebarShowICloud: Bool {
        didSet { defaults.set(sidebarShowICloud, forKey: Keys.sidebarShowICloud) }
    }
    @Published var sidebarShowLocations: Bool {
        didSet { defaults.set(sidebarShowLocations, forKey: Keys.sidebarShowLocations) }
    }
    @Published var sidebarShowTags: Bool {
        didSet { defaults.set(sidebarShowTags, forKey: Keys.sidebarShowTags) }
    }
    @Published var sidebarFavorites: [SidebarFavorite] {
        didSet {
            if let data = try? JSONEncoder().encode(sidebarFavorites) {
                defaults.set(data, forKey: Keys.sidebarFavorites)
            }
        }
    }
    @Published var thumbnailQuality: Double {
        didSet { defaults.set(thumbnailQuality, forKey: Keys.thumbnailQuality) }
    }
    @Published var masonryShowFilenames: Bool {
        didSet { defaults.set(masonryShowFilenames, forKey: Keys.masonryShowFilenames) }
    }

    @Published var listFontSize: Double {
        didSet { defaults.set(listFontSize, forKey: Keys.listFontSize) }
    }
    @Published var listIconSize: Double {
        didSet { defaults.set(listIconSize, forKey: Keys.listIconSize) }
    }

    @Published var iconGridIconSize: Double {
        didSet { defaults.set(iconGridIconSize, forKey: Keys.iconGridIconSize) }
    }
    @Published var iconGridFontSize: Double {
        didSet { defaults.set(iconGridFontSize, forKey: Keys.iconGridFontSize) }
    }
    @Published var iconGridSpacing: Double {
        didSet { defaults.set(iconGridSpacing, forKey: Keys.iconGridSpacing) }
    }

    @Published var columnFontSize: Double {
        didSet { defaults.set(columnFontSize, forKey: Keys.columnFontSize) }
    }
    @Published var columnIconSize: Double {
        didSet { defaults.set(columnIconSize, forKey: Keys.columnIconSize) }
    }
    @Published var columnWidth: Double {
        didSet { defaults.set(columnWidth, forKey: Keys.columnWidth) }
    }
    @Published var columnShowPreview: Bool {
        didSet { defaults.set(columnShowPreview, forKey: Keys.columnShowPreview) }
    }
    @Published var columnPreviewWidth: Double {
        didSet { defaults.set(columnPreviewWidth, forKey: Keys.columnPreviewWidth) }
    }

    @Published var coverFlowTitleFontSize: Double {
        didSet { defaults.set(coverFlowTitleFontSize, forKey: Keys.coverFlowTitleFontSize) }
    }
    @Published var coverFlowScale: Double {
        didSet { defaults.set(coverFlowScale, forKey: Keys.coverFlowScale) }
    }
    @Published var coverFlowSwipeSpeed: Double {
        didSet { defaults.set(coverFlowSwipeSpeed, forKey: Keys.coverFlowSwipeSpeed) }
    }
    @Published var coverFlowShowInfo: Bool {
        didSet { defaults.set(coverFlowShowInfo, forKey: Keys.coverFlowShowInfo) }
    }
    @Published var coverFlowPaneHeight: Double {
        didSet { defaults.set(coverFlowPaneHeight, forKey: Keys.coverFlowPaneHeight) }
    }
    @Published var usePerFolderColumnState: Bool {
        didSet { defaults.set(usePerFolderColumnState, forKey: Keys.usePerFolderColumnState) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Keys.showHiddenFiles: Defaults.showHiddenFiles,
            Keys.showFileExtensions: Defaults.showFileExtensions,
            Keys.foldersFirst: Defaults.foldersFirst,
            Keys.showPathBar: Defaults.showPathBar,
            Keys.showStatusBar: Defaults.showStatusBar,
            Keys.showItemTags: Defaults.showItemTags,
            Keys.sidebarShowFavorites: Defaults.sidebarShowFavorites,
            Keys.sidebarShowICloud: Defaults.sidebarShowICloud,
            Keys.sidebarShowLocations: Defaults.sidebarShowLocations,
            Keys.sidebarShowTags: Defaults.sidebarShowTags,
            Keys.sidebarFavorites: Defaults.sidebarFavoritesData,
            Keys.thumbnailQuality: Defaults.thumbnailQuality,
            Keys.masonryShowFilenames: Defaults.masonryShowFilenames,
            Keys.listFontSize: Defaults.listFontSize,
            Keys.listIconSize: Defaults.listIconSize,
            Keys.iconGridIconSize: Defaults.iconGridIconSize,
            Keys.iconGridFontSize: Defaults.iconGridFontSize,
            Keys.iconGridSpacing: Defaults.iconGridSpacing,
            Keys.columnFontSize: Defaults.columnFontSize,
            Keys.columnIconSize: Defaults.columnIconSize,
            Keys.columnWidth: Defaults.columnWidth,
            Keys.columnShowPreview: Defaults.columnShowPreview,
            Keys.columnPreviewWidth: Defaults.columnPreviewWidth,
            Keys.coverFlowTitleFontSize: Defaults.coverFlowTitleFontSize,
            Keys.coverFlowScale: Defaults.coverFlowScale,
            Keys.coverFlowSwipeSpeed: Defaults.coverFlowSwipeSpeed,
            Keys.coverFlowShowInfo: Defaults.coverFlowShowInfo,
            Keys.coverFlowPaneHeight: Defaults.coverFlowPaneHeight,
            Keys.usePerFolderColumnState: Defaults.usePerFolderColumnState
        ])

        showHiddenFiles = defaults.bool(forKey: Keys.showHiddenFiles)
        showFileExtensions = defaults.bool(forKey: Keys.showFileExtensions)
        foldersFirst = defaults.bool(forKey: Keys.foldersFirst)
        showPathBar = defaults.bool(forKey: Keys.showPathBar)
        showStatusBar = defaults.bool(forKey: Keys.showStatusBar)
        showItemTags = defaults.bool(forKey: Keys.showItemTags)
        sidebarShowFavorites = defaults.bool(forKey: Keys.sidebarShowFavorites)
        sidebarShowICloud = defaults.bool(forKey: Keys.sidebarShowICloud)
        sidebarShowLocations = defaults.bool(forKey: Keys.sidebarShowLocations)
        sidebarShowTags = defaults.bool(forKey: Keys.sidebarShowTags)
        sidebarFavorites = {
            if let data = defaults.data(forKey: Keys.sidebarFavorites),
               let favorites = try? JSONDecoder().decode([SidebarFavorite].self, from: data),
               !favorites.isEmpty {
                return favorites
            }
            return Defaults.sidebarFavorites
        }()
        thumbnailQuality = defaults.double(forKey: Keys.thumbnailQuality)
        masonryShowFilenames = defaults.bool(forKey: Keys.masonryShowFilenames)

        listFontSize = defaults.double(forKey: Keys.listFontSize)
        listIconSize = defaults.double(forKey: Keys.listIconSize)

        iconGridIconSize = defaults.double(forKey: Keys.iconGridIconSize)
        iconGridFontSize = defaults.double(forKey: Keys.iconGridFontSize)
        iconGridSpacing = defaults.double(forKey: Keys.iconGridSpacing)

        columnFontSize = defaults.double(forKey: Keys.columnFontSize)
        columnIconSize = defaults.double(forKey: Keys.columnIconSize)
        columnWidth = defaults.double(forKey: Keys.columnWidth)
        columnShowPreview = defaults.bool(forKey: Keys.columnShowPreview)
        columnPreviewWidth = defaults.double(forKey: Keys.columnPreviewWidth)

        coverFlowTitleFontSize = defaults.double(forKey: Keys.coverFlowTitleFontSize)
        coverFlowScale = defaults.double(forKey: Keys.coverFlowScale)
        coverFlowSwipeSpeed = defaults.double(forKey: Keys.coverFlowSwipeSpeed)
        coverFlowShowInfo = defaults.bool(forKey: Keys.coverFlowShowInfo)
        coverFlowPaneHeight = defaults.double(forKey: Keys.coverFlowPaneHeight)
        usePerFolderColumnState = defaults.bool(forKey: Keys.usePerFolderColumnState)
    }

    func resetToDefaults() {
        showHiddenFiles = Defaults.showHiddenFiles
        showFileExtensions = Defaults.showFileExtensions
        foldersFirst = Defaults.foldersFirst
        showPathBar = Defaults.showPathBar
        showStatusBar = Defaults.showStatusBar
        showItemTags = Defaults.showItemTags
        sidebarShowFavorites = Defaults.sidebarShowFavorites
        sidebarShowICloud = Defaults.sidebarShowICloud
        sidebarShowLocations = Defaults.sidebarShowLocations
        sidebarShowTags = Defaults.sidebarShowTags
        sidebarFavorites = Defaults.sidebarFavorites
        thumbnailQuality = Defaults.thumbnailQuality
        masonryShowFilenames = Defaults.masonryShowFilenames

        listFontSize = Defaults.listFontSize
        listIconSize = Defaults.listIconSize

        iconGridIconSize = Defaults.iconGridIconSize
        iconGridFontSize = Defaults.iconGridFontSize
        iconGridSpacing = Defaults.iconGridSpacing

        columnFontSize = Defaults.columnFontSize
        columnIconSize = Defaults.columnIconSize
        columnWidth = Defaults.columnWidth
        columnShowPreview = Defaults.columnShowPreview
        columnPreviewWidth = Defaults.columnPreviewWidth

        coverFlowTitleFontSize = Defaults.coverFlowTitleFontSize
        coverFlowScale = Defaults.coverFlowScale
        coverFlowSwipeSpeed = Defaults.coverFlowSwipeSpeed
        coverFlowShowInfo = Defaults.coverFlowShowInfo
        coverFlowPaneHeight = Defaults.coverFlowPaneHeight
        usePerFolderColumnState = Defaults.usePerFolderColumnState
    }

    var listFont: Font {
        .system(size: listFontSize)
    }

    var listDetailFont: Font {
        .system(size: max(9, listFontSize - 2))
    }

    var listIconSizeValue: CGFloat {
        CGFloat(listIconSize)
    }

    var iconGridFont: Font {
        .system(size: iconGridFontSize)
    }

    var iconGridIconSizeValue: CGFloat {
        CGFloat(iconGridIconSize)
    }

    var iconGridSpacingValue: CGFloat {
        CGFloat(iconGridSpacing)
    }

    var columnFont: Font {
        .system(size: columnFontSize)
    }

    var columnDetailFont: Font {
        .system(size: max(9, columnFontSize - 2))
    }

    var columnPreviewTitleFont: Font {
        .system(size: max(11, columnFontSize + 2), weight: .semibold)
    }

    var columnIconSizeValue: CGFloat {
        CGFloat(columnIconSize)
    }

    var columnWidthValue: CGFloat {
        CGFloat(columnWidth)
    }

    var columnPreviewWidthValue: CGFloat {
        CGFloat(columnPreviewWidth)
    }

    var coverFlowTitleFont: Font {
        .system(size: coverFlowTitleFontSize, weight: .semibold)
    }

    var coverFlowDetailFont: Font {
        .system(size: max(9, coverFlowTitleFontSize - 3))
    }

    var coverFlowScaleValue: CGFloat {
        CGFloat(coverFlowScale)
    }

    var coverFlowSwipeSpeedValue: CGFloat {
        CGFloat(coverFlowSwipeSpeed)
    }

    var compactListFont: Font {
        .system(size: max(10, listFontSize - 1))
    }

    var compactListDetailFont: Font {
        .system(size: max(9, listFontSize - 3))
    }

    var compactListIconSize: CGFloat {
        max(14, CGFloat(listIconSize) - 4)
    }

    var dualPaneIconSize: CGFloat {
        max(32, CGFloat(iconGridIconSize) * 0.6)
    }

    var dualPaneFont: Font {
        .system(size: max(9, iconGridFontSize - 1))
    }

    var dualPaneGridSpacing: CGFloat {
        max(8, CGFloat(iconGridSpacing) * 0.7)
    }

    var quadPaneIconSize: CGFloat {
        max(28, CGFloat(iconGridIconSize) * 0.45)
    }

    var quadPaneFont: Font {
        .system(size: max(8, iconGridFontSize - 2))
    }

    var quadPaneGridSpacing: CGFloat {
        max(6, CGFloat(iconGridSpacing) * 0.5)
    }

    var thumbnailQualityValue: CGFloat {
        CGFloat(thumbnailQuality)
    }
}

struct SidebarFavorite: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case documents
        case applications
        case desktop
        case downloads
        case movies
        case music
        case pictures
        case custom
    }

    let id: String
    let kind: Kind
    let path: String?

    init(kind: Kind, id: String? = nil, path: String? = nil) {
        self.kind = kind
        self.path = path
        if let id {
            self.id = id
        } else if kind == .custom {
            self.id = UUID().uuidString
        } else {
            self.id = kind.rawValue
        }
    }

    static func system(_ kind: Kind) -> SidebarFavorite {
        SidebarFavorite(kind: kind, id: kind.rawValue)
    }

    static func custom(path: String) -> SidebarFavorite {
        SidebarFavorite(kind: .custom, id: UUID().uuidString, path: path)
    }
}

import Foundation
import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// Represents a Finder tag with its color
struct FinderTag: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color

    static let none = FinderTag(id: "none", name: "None", color: .clear)

    // Standard Finder tag colors
    static let red = FinderTag(id: "red", name: "Red", color: Color(nsColor: NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)))
    static let orange = FinderTag(id: "orange", name: "Orange", color: Color(nsColor: NSColor(red: 1.0, green: 0.58, blue: 0.0, alpha: 1.0)))
    static let yellow = FinderTag(id: "yellow", name: "Yellow", color: Color(nsColor: NSColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1.0)))
    static let green = FinderTag(id: "green", name: "Green", color: Color(nsColor: NSColor(red: 0.27, green: 0.85, blue: 0.46, alpha: 1.0)))
    static let blue = FinderTag(id: "blue", name: "Blue", color: Color(nsColor: NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)))
    static let purple = FinderTag(id: "purple", name: "Purple", color: Color(nsColor: NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1.0)))
    static let gray = FinderTag(id: "gray", name: "Gray", color: Color(nsColor: NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)))

    static let allTags: [FinderTag] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

    /// Get FinderTag from tag name (case-insensitive match)
    static func from(name: String) -> FinderTag? {
        let lowercased = name.lowercased()
        return allTags.first { $0.name.lowercased() == lowercased }
    }
}

extension URL {
    /// Path used to compare and key file URLs: without "." / ".." segments or a trailing slash.
    /// Directory URLs from `contentsOfDirectory` end in "/" while FSEvents paths and
    /// `URL(fileURLWithPath:)` for deleted folders don't, so `URL ==` can't be used for lookups.
    /// Purely textual: `standardizedFileURL` also drops "/private" from /private/tmp/… paths, but
    /// only while they exist, so a renamed or deleted item's key wouldn't match the one it was
    /// listed under.
    var standardizedPathKey: String {
        let path = standardized.path
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    /// `contentsOfDirectory` lists a folder's children under its resolved path (/private/tmp/… for
    /// /tmp/…, a symlinked folder's target). Re-roots `children` under `folder` so a listing keeps
    /// the path form the user navigated with (path bar, watcher events, selection by URL). Returned
    /// unchanged — prefetched resource values included — when they already are under it.
    static func childURLs(_ children: [URL], reRootedUnder folder: URL) -> [URL] {
        guard let first = children.first,
              first.deletingLastPathComponent().standardizedPathKey != folder.standardizedPathKey else {
            return children
        }
        return children.map { folder.appendingPathComponent($0.lastPathComponent, isDirectory: $0.hasDirectoryPath) }
    }
}

/// Helper to read and write file tags using extended attributes
enum FileTagManager {
    private static let tagAttributeName = "com.apple.metadata:_kMDItemUserTags"
    /// Cached tags keyed by path. Entries are dropped on our own edits, for files reported by
    /// directory events and for a whole folder on refresh, so edits made in Finder show up.
    /// Least recently used entries are evicted in bulk when it's full, so a big folder being
    /// sorted or filtered by tags keeps its entries (no full clear and re-read).
    private struct CachedTags {
        let tags: [String]
        var lastUse: UInt64
    }
    private static var tagCache: [String: CachedTags] = [:]
    private static var useCounter: UInt64 = 0
    static let maxCachedEntries = 50_000
    /// Entries kept by an eviction (the most recently used ones)
    static let entriesKeptOnEviction = 37_500
    private static let cacheQueue = DispatchQueue(label: "com.coverflowfinder.tagcache", qos: .userInitiated)

    private static func cacheKey(for url: URL) -> String {
        let path = url.path
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    /// Read tags from a file URL
    static func getTags(for url: URL) -> [String] {
        let key = cacheKey(for: url)
        if let cached = cacheQueue.sync(execute: { cachedValue(forKey: key) }) {
            return cached
        }
        // URL instances cache resource values; read through a fresh one so external edits are seen.
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let tags = (try? freshURL.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        storeInCache(tags, forKey: key)
        return tags
    }

    /// The cached tags for a URL, without touching the file system (nil when not cached).
    static func cachedTags(for url: URL) -> [String]? {
        let key = cacheKey(for: url)
        return cacheQueue.sync { cachedValue(forKey: key) }
    }

    /// Number of cached entries (for tests and diagnostics).
    static var cachedEntryCount: Int {
        cacheQueue.sync { tagCache.count }
    }

    /// On `cacheQueue`: the cached tags, marking the entry as just used.
    private static func cachedValue(forKey key: String) -> [String]? {
        guard var entry = tagCache[key] else { return nil }
        useCounter &+= 1
        entry.lastUse = useCounter
        tagCache[key] = entry
        return entry.tags
    }

    /// Set tags on a file URL using xattr (compatible with Finder on all macOS versions).
    /// Returns false when the attribute couldn't be written (read-only volume, no permission, …).
    @discardableResult
    static func setTags(_ tags: [String], for url: URL) -> Bool {
        // Finder stores tags in the extended attribute as a binary plist array
        // Each tag name has a newline suffix (e.g., "Red\n", "Blue\n")
        // Empty array removes all tags
        let succeeded: Bool
        if tags.isEmpty {
            // Remove the attribute entirely when no tags (ENOATTR: there was nothing to remove)
            succeeded = url.withUnsafeFileSystemRepresentation { fileSystemPath -> Bool in
                guard let path = fileSystemPath else { return false }
                return removexattr(path, tagAttributeName, 0) == 0 || errno == ENOATTR
            }
        } else if let plistData = try? PropertyListSerialization.data(fromPropertyList: tags.map { $0 + "\n" }, format: .binary, options: 0) {
            succeeded = url.withUnsafeFileSystemRepresentation { fileSystemPath -> Bool in
                guard let path = fileSystemPath else { return false }
                // setxattr replaces any existing value
                return plistData.withUnsafeBytes { bytes in
                    setxattr(path, tagAttributeName, bytes.baseAddress, bytes.count, 0, 0)
                } == 0
            }
        } else {
            succeeded = false
        }

        if succeeded {
            // Update cache synchronously so immediate reads get the new value
            storeInCache(tags, forKey: cacheKey(for: url))
        } else {
            invalidateCache(for: url)
        }
        return succeeded
    }

    /// Add a tag to a file
    @discardableResult
    static func addTag(_ tag: String, to url: URL) -> Bool {
        var currentTags = getTags(for: url)
        guard !currentTags.contains(tag) else { return true }
        currentTags.append(tag)
        return setTags(currentTags, for: url)
    }

    /// Remove a tag from a file
    @discardableResult
    static func removeTag(_ tag: String, from url: URL) -> Bool {
        var currentTags = getTags(for: url)
        currentTags.removeAll { $0 == tag }
        return setTags(currentTags, for: url)
    }

    /// Toggle a tag on a file
    @discardableResult
    static func toggleTag(_ tag: String, on url: URL) -> Bool {
        let currentTags = getTags(for: url)
        if currentTags.contains(tag) {
            return removeTag(tag, from: url)
        } else {
            return addTag(tag, to: url)
        }
    }

    static func invalidateCache(for url: URL) {
        let key = cacheKey(for: url)
        cacheQueue.sync {
            _ = tagCache.removeValue(forKey: key)
        }
    }

    static func invalidateCache(for urls: [URL]) {
        let keys = urls.map(cacheKey(for:))
        cacheQueue.sync {
            for key in keys {
                tagCache.removeValue(forKey: key)
            }
        }
    }

    /// Drop cached tags for the direct children of a folder (used on refresh).
    static func invalidateCache(forDirectory directoryURL: URL) {
        let directoryPath = cacheKey(for: directoryURL)
        cacheQueue.sync {
            tagCache = tagCache.filter { key, _ in
                (key as NSString).deletingLastPathComponent != directoryPath
            }
        }
    }

    private static func storeInCache(_ tags: [String], forKey key: String) {
        cacheQueue.sync {
            if tagCache.count >= maxCachedEntries, tagCache[key] == nil {
                evictLeastRecentlyUsed()
            }
            useCounter &+= 1
            tagCache[key] = CachedTags(tags: tags, lastUse: useCounter)
        }
    }

    /// On `cacheQueue`: keeps the `entriesKeptOnEviction` most recently used entries. Runs once
    /// per (max - kept) insertions, not per insertion.
    private static func evictLeastRecentlyUsed() {
        let excess = tagCache.count - entriesKeptOnEviction
        guard excess > 0 else { return }
        let cutoff = tagCache.values.map(\.lastUse).sorted()[excess - 1]
        tagCache = tagCache.filter { $0.value.lastUse > cutoff }
    }
}

/// Cache for file icons to avoid repeated NSWorkspace lookups
private class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    /// Folder icons keyed by path + change time, so custom icons/colours still show up.
    private let folderCache = NSCache<NSString, NSImage>()

    // Pre-cached generic icons for fast display
    private let genericImageIcon: NSImage
    private let genericVideoIcon: NSImage
    private let genericAudioIcon: NSImage
    private let genericFolderIcon: NSImage
    private let genericApplicationIcon: NSImage
    private let genericDataIcon: NSImage

    // File extensions that should use generic icons for speed
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "raw", "cr2", "nef", "arw", "dng"]
    private let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg"]
    private let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff"]

    private init() {
        cache.countLimit = 500
        folderCache.countLimit = 500

        // Pre-load generic icons (these are instant)
        genericImageIcon = NSWorkspace.shared.icon(for: .image)
        genericVideoIcon = NSWorkspace.shared.icon(for: .movie)
        genericAudioIcon = NSWorkspace.shared.icon(for: .audio)
        genericFolderIcon = NSWorkspace.shared.icon(for: .folder)
        genericApplicationIcon = NSWorkspace.shared.icon(for: .application)
        genericDataIcon = NSWorkspace.shared.icon(for: .data)
    }

    func icon(for url: URL, isPlainFolder: Bool = false) -> NSImage {
        let key = url.path as NSString

        // For media files, use pre-cached generic icons (instant)
        // The actual thumbnail will load later and replace this
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return genericImageIcon
        } else if videoExtensions.contains(ext) {
            return genericVideoIcon
        } else if audioExtensions.contains(ext) {
            return genericAudioIcon
        }

        // Plain folders can have custom icons/colours. Those live in the folder's xattrs or an
        // "Icon\r" file, and changing either bumps the folder's ctime/mtime, so key on those.
        // Bundles (.app, .bundle, etc.) have stable icons and use the path-keyed cache below.
        if isPlainFolder {
            var info = stat()
            guard stat(url.path, &info) == 0 else {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            let folderKey = "\(url.path)|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" as NSString
            if let cached = folderCache.object(forKey: folderKey) {
                return cached
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            folderCache.setObject(icon, forKey: folderKey)
            return icon
        }

        // Check cache for non-media, non-folder files (including .app bundles)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Get the actual icon from filesystem and cache it
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }

    func genericIcon(for fileType: FileItem.FileType) -> NSImage {
        switch fileType {
        case .image: return genericImageIcon
        case .video: return genericVideoIcon
        case .audio: return genericAudioIcon
        case .folder: return genericFolderIcon
        case .application: return genericApplicationIcon
        default: return genericDataIcon
        }
    }
}

/// Finder-style kind strings per content type (LaunchServices lookups are not free, and
/// sorting by Kind reads the kind of every item).
private enum KindDescriptionCache {
    private static let lock = NSLock()
    private static var descriptions: [String: String] = [:]

    static func description(for type: UTType) -> String? {
        lock.lock()
        let cached = descriptions[type.identifier]
        lock.unlock()
        if let cached {
            return cached.isEmpty ? nil : cached
        }

        var description = type.localizedDescription ?? ""
        if let first = description.first, first.isLowercase {
            // "application" → "Application", "PNG image" stays as is
            description = first.uppercased() + description.dropFirst()
        }
        lock.lock()
        descriptions[type.identifier] = description
        lock.unlock()
        return description.isEmpty ? nil : description
    }
}

struct FileItem: Identifiable, Hashable {
    /// Stable identity. The view model reuses it per path across reloads so views keep their state.
    private(set) var id: UUID
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    /// Total size of a folder's or package's contents, once calculated in the background
    /// (`ItemSizeCalculator`); nil until then and for everything else. Kept apart from `size`,
    /// which stays the item's own size (thumbnail caches key on it).
    private(set) var calculatedSize: Int64?
    let modificationDate: Date?
    let creationDate: Date?
    let fileType: FileType
    let hasMetadata: Bool
    /// Bundles/packages (.app, .rtfd, …): directories that open as a single document.
    let isPackage: Bool
    /// The item is a symbolic link. `isDirectory`, `isPackage` and `fileType` describe the
    /// link's target, while `url` and `name` stay the link's own (the item shows where it's listed).
    let isSymbolicLink: Bool
    /// The item is a Finder alias file (resolved when opened, not when listed).
    let isAliasFile: Bool
    /// The item is hidden: its name starts with "." or it has the hidden flag (`chflags hidden`).
    /// Listed only while hidden files are shown, and then drawn dimmed like in Finder.
    let isHidden: Bool
    /// Finder-style kind ("Folder", "PNG image", "Application", …)
    let kindDescription: String

    // Archive support - for items inside ZIP files
    let isFromArchive: Bool
    let archiveURL: URL?
    let archivePath: String?

    // iCloud status (loaded on demand)
    var cloudStatus: CloudSyncStatus?

    /// Whether this file is in an iCloud container
    var isInICloud: Bool {
        guard !isFromArchive else { return false }
        return CloudStatusManager.shared.isInICloud(url)
    }

    /// Formatted cloud status description for display
    var formattedCloudStatus: String {
        cloudStatus?.description ?? ""
    }

    /// Get tags for this file (cached by FileTagManager)
    var tags: [String] {
        guard !isFromArchive else { return [] }
        return FileTagManager.getTags(for: url)
    }

    /// Get FinderTag objects for display
    var finderTags: [FinderTag] {
        tags.compactMap { FinderTag.from(name: $0) }
    }

    // Lazy icon lookup - only loads when accessed
    var icon: NSImage {
        if isFromArchive {
            // For archive items, use generic icons based on file type
            return IconCache.shared.genericIcon(for: fileType)
        }
        if isNetworkService {
            return Self.networkServiceIcon
        }
        if !url.isFileURL {
            return IconCache.shared.genericIcon(for: fileType)
        }
        // Actual folders (not bundles like .app) can have custom colors that might change
        let isPlainFolder = fileType == .folder
        return IconCache.shared.icon(for: url, isPlainFolder: isPlainFolder)
    }

    /// Fast placeholder icon - returns instantly without filesystem access
    /// Use this for initial display while the real icon loads asynchronously
    var placeholderIcon: NSImage {
        if isNetworkService {
            return Self.networkServiceIcon
        }
        return IconCache.shared.genericIcon(for: fileType)
    }

    var isNetworkService: Bool {
        guard !url.isFileURL else { return false }
        let scheme = url.scheme?.lowercased()
        return scheme == "smb" || scheme == "afp"
    }

    private static let networkServiceIcon: NSImage = {
        if let symbol = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil) {
            symbol.isTemplate = true
            return symbol
        }
        if let image = NSImage(named: NSImage.computerName) {
            return image
        }
        if let image = NSImage(named: NSImage.networkName) {
            return image
        }
        return IconCache.shared.genericIcon(for: .folder)
    }()

    /// Check if this item is a ZIP archive that can be browsed
    var isZipArchive: Bool {
        !isFromArchive && fileType == .archive && url.pathExtension.lowercased() == "zip"
    }

    enum FileType {
        case folder
        case image
        case video
        case audio
        case document
        case code
        case archive
        case application
        case other
    }

    init(url: URL, id: UUID = UUID(), loadMetadata: Bool = true) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent

        // Not from archive - regular file system item
        self.isFromArchive = false
        self.archiveURL = nil
        self.archivePath = nil

        // Listings prefetch these keys (see `FileItem.listingResourceKeys`), so reading them here
        // doesn't touch the disk again
        var requestedKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .contentTypeKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey
        ]
        if loadMetadata {
            requestedKeys.formUnion([.fileSizeKey, .contentModificationDateKey, .creationDateKey])
        }

        let resourceValues = try? url.resourceValues(forKeys: requestedKeys)

        // Resource values describe a symlink itself (not a directory, type public.symlink).
        // Classify symlinks by their target so linked folders sort and open as folders.
        let isSymbolicLink = resourceValues?.isSymbolicLink ?? false
        var isDirectory = resourceValues?.isDirectory ?? false
        var isPackage = resourceValues?.isPackage ?? false
        var contentType = resourceValues?.contentType
        if isSymbolicLink {
            let targetURL = url.resolvingSymlinksInPath()
            if targetURL != url,
               let targetValues = try? targetURL.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .isPackageKey]) {
                isDirectory = targetValues.isDirectory ?? false
                isPackage = targetValues.isPackage ?? false
                contentType = targetValues.contentType ?? contentType
            }
        }
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        // isAliasFile is also true for symlinks; keep it for Finder aliases only
        self.isAliasFile = !isSymbolicLink && (resourceValues?.isAliasFile ?? false)
        self.isHidden = url.lastPathComponent.hasPrefix(".") || resourceValues?.isHidden == true

        if loadMetadata {
            self.size = Int64(resourceValues?.fileSize ?? 0)
            self.modificationDate = resourceValues?.contentModificationDate
            self.creationDate = resourceValues?.creationDate
        } else {
            self.size = 0
            self.modificationDate = nil
            self.creationDate = nil
        }
        self.hasMetadata = loadMetadata

        // Determine file type - check content type first for bundles/packages
        let fileType: FileType
        if let contentType {
            // Check for application bundles BEFORE falling back to folder
            if isPackage || contentType.conforms(to: .application) || contentType.conforms(to: .bundle) || contentType.conforms(to: .package) {
                fileType = FileItem.determineFileType(from: contentType)
            } else if isDirectory {
                fileType = .folder
            } else {
                fileType = FileItem.determineFileType(from: contentType)
            }
        } else if let extType = UTType(filenameExtension: url.pathExtension) {
            // Check extension-based type for bundles
            if extType.conforms(to: .application) || extType.conforms(to: .bundle) || extType.conforms(to: .package) {
                fileType = FileItem.determineFileType(from: extType)
            } else if isDirectory {
                fileType = .folder
            } else {
                fileType = FileItem.determineFileType(from: extType)
            }
        } else if isDirectory {
            fileType = .folder
        } else {
            fileType = .other
        }
        self.fileType = fileType
        self.kindDescription = FileItem.kindDescription(
            contentType: contentType,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isLink: isSymbolicLink || self.isAliasFile,
            fileType: fileType
        )

        // Cloud status is loaded on demand, not during init
        self.cloudStatus = nil
    }

    /// Initialize from already-known values (ZIP entries, Spotlight results, network hosts, Photos).
    /// `isPackage` defaults to whether `contentType` is a package type, `isHidden` to whether the
    /// name starts with ".".
    init(id: UUID = UUID(),
         url: URL,
         name: String,
         isDirectory: Bool,
         size: Int64,
         modificationDate: Date?,
         creationDate: Date?,
         contentType: UTType?,
         icon: NSImage? = nil,
         isFromArchive: Bool = false,
         archiveURL: URL? = nil,
         archivePath: String? = nil,
         isPackage: Bool? = nil,
         isHidden: Bool? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.hasMetadata = true
        self.isFromArchive = isFromArchive
        self.archiveURL = archiveURL
        self.archivePath = archivePath
        let isPackage = isPackage ?? (isDirectory && contentType?.conforms(to: .package) == true)
        self.isPackage = isPackage
        self.isSymbolicLink = false
        self.isAliasFile = false
        self.isHidden = isHidden ?? name.hasPrefix(".")

        // Determine file type
        let fileType: FileType
        if isDirectory && !isPackage {
            fileType = .folder
        } else if let ct = contentType {
            fileType = FileItem.determineFileType(from: ct)
        } else {
            let ext = (name as NSString).pathExtension
            if let extType = UTType(filenameExtension: ext) {
                fileType = FileItem.determineFileType(from: extType)
            } else {
                fileType = isDirectory ? .folder : .other
            }
        }
        self.fileType = fileType
        self.kindDescription = FileItem.kindDescription(
            contentType: contentType,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isLink: false,
            fileType: fileType
        )

        // Archive items don't have cloud status
        self.cloudStatus = nil
    }

    /// Return a copy of this item with a different identity (used to keep IDs stable per path).
    func withID(_ id: UUID) -> FileItem {
        var copy = self
        copy.id = id
        return copy
    }

    /// Return a copy of this item with the specified cloud status
    func withCloudStatus(_ status: CloudSyncStatus?) -> FileItem {
        var copy = self
        copy.cloudStatus = status
        return copy
    }

    /// Return a copy of this item showing `size` as its contents' total (nil: not calculated)
    func withCalculatedSize(_ size: Int64?) -> FileItem {
        var copy = self
        copy.calculatedSize = size
        return copy
    }

    /// The size the Size column shows and sorts by: a folder's or package's calculated total,
    /// else the item's own size.
    var sizeForSorting: Int64 {
        calculatedSize ?? size
    }

    private static func determineFileType(from type: UTType) -> FileType {
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .sourceCode) { return .code }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .application) { return .application }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) ||
           type.conforms(to: .spreadsheet) || type.conforms(to: .text) { return .document }
        return .other
    }

    private static func kindDescription(contentType: UTType?, isDirectory: Bool, isPackage: Bool, isLink: Bool, fileType: FileType) -> String {
        if isLink { return "Alias" }
        if isDirectory && !isPackage { return "Folder" }
        if let contentType, let description = KindDescriptionCache.description(for: contentType) {
            return description
        }
        switch fileType {
        case .folder: return "Folder"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .code: return "Source Code"
        case .archive: return "Archive"
        case .application: return "Application"
        case .other: return isPackage ? "Package" : "Document"
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var formattedSize: String {
        // A folder's or package's contents, once totalled
        if isDirectory, let calculatedSize {
            return Self.formattedByteCount(calculatedSize)
        }
        // Not hydrated yet (large folders load sizes for visible rows): unknown, not "Zero KB"
        guard hasMetadata else { return "--" }
        // Folders have no size; packages show theirs when it's known
        if isDirectory && !(isPackage && size > 0) { return "--" }
        return Self.byteCountFormatter.string(fromByteCount: size)
    }

    /// A byte count as the Size column shows it ("12 KB").
    static func formattedByteCount(_ bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }

    var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return Self.dateFormatter.string(from: date)
    }

    /// Snapshot of the displayed metadata. Changes whenever size, dates, metadata hydration,
    /// cloud status, a calculated folder size or the hidden flag change, while `==`/`hash` stay
    /// URL-based (identity). Use this (not `==`) for change detection and cache keys.
    struct ContentVersion: Hashable {
        let modificationDate: Date?
        let size: Int64
        let hasMetadata: Bool
        let cloudStatus: CloudSyncStatus?
        var calculatedSize: Int64? = nil
        var isHidden = false
    }

    var contentVersion: ContentVersion {
        ContentVersion(modificationDate: modificationDate, size: size, hasMetadata: hasMetadata, cloudStatus: cloudStatus,
                       calculatedSize: calculatedSize, isHidden: isHidden)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}

extension FileItem {
    /// The name as Finder shows it: a ":" in the on-disk name is displayed as "/".
    /// Use this for display; `name` stays the real file-system name for path operations.
    var displayName: String {
        Self.displayForm(of: name)
    }

    func displayName(showFileExtensions: Bool) -> String {
        if showFileExtensions || isDirectory {
            return displayName
        }
        return Self.displayForm(of: nameWithoutExtension)
    }

    private static func displayForm(of fileSystemName: String) -> String {
        fileSystemName.contains(":") ? fileSystemName.replacingOccurrences(of: ":", with: "/") : fileSystemName
    }
}

// MARK: - Hidden Items

extension FileItem {
    /// Resource keys every folder listing prefetches, so creating items reads nothing more from
    /// the disk for them (`init(url:loadMetadata: false)` reads exactly these).
    static let listingResourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .contentTypeKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey
    ]

    /// Names never listed, even while hidden files are shown (like Finder: .DS_Store only stores
    /// Finder's view settings).
    static func isAlwaysHiddenName(_ name: String) -> Bool {
        name == ".DS_Store"
    }

    /// Opacity of hidden items' icons and names when hidden files are shown (Finder draws them
    /// at about half opacity).
    static let hiddenItemOpacity: Double = 0.5

    /// Opacity for the item's icon. Views draw cut items at half opacity as a whole, so a hidden
    /// item that is also cut isn't dimmed a second time.
    func iconOpacity(isCut: Bool) -> Double {
        isHidden && !isCut ? Self.hiddenItemOpacity : 1
    }

    /// Opacity for the item's name: like the icon, but selected names stay fully opaque so they
    /// remain readable on the selection highlight.
    func nameOpacity(isCut: Bool, isSelected: Bool) -> Double {
        isHidden && !isCut && !isSelected ? Self.hiddenItemOpacity : 1
    }
}

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

/// Helper to read and write file tags using extended attributes
enum FileTagManager {
    private static let tagAttributeName = "com.apple.metadata:_kMDItemUserTags"
    private static var tagCache: [URL: [String]] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.coverflowfinder.tagcache", qos: .userInitiated)

    /// Read tags from a file URL
    static func getTags(for url: URL) -> [String] {
        if let cached = cacheQueue.sync(execute: { tagCache[url] }) {
            return cached
        }
        guard let resourceValues = try? url.resourceValues(forKeys: [.tagNamesKey]),
              let tags = resourceValues.tagNames else {
            return []
        }
        cacheQueue.async {
            tagCache[url] = tags
        }
        return tags
    }

    /// Set tags on a file URL using xattr (works on all macOS versions)
    static func setTags(_ tags: [String], for url: URL) {
        // Use xattr command to set tags (macOS stores tags as a plist in extended attributes)
        let tagsWithNewlines = tags.map { $0 + "\n" }
        if let plistData = try? PropertyListSerialization.data(fromPropertyList: tagsWithNewlines, format: .binary, options: 0) {
            url.withUnsafeFileSystemRepresentation { fileSystemPath in
                guard let path = fileSystemPath else { return }
                let result = plistData.withUnsafeBytes { bytes in
                    setxattr(path, tagAttributeName, bytes.baseAddress, bytes.count, 0, 0)
                }
                if result != 0 {
                    // If setxattr fails, try removing the attribute first
                    removexattr(path, tagAttributeName, 0)
                    _ = plistData.withUnsafeBytes { bytes in
                        setxattr(path, tagAttributeName, bytes.baseAddress, bytes.count, 0, 0)
                    }
                }
            }
        }
        cacheQueue.async {
            tagCache[url] = tags
        }
    }

    /// Add a tag to a file
    static func addTag(_ tag: String, to url: URL) {
        var currentTags = getTags(for: url)
        if !currentTags.contains(tag) {
            currentTags.append(tag)
            setTags(currentTags, for: url)
        }
    }

    /// Remove a tag from a file
    static func removeTag(_ tag: String, from url: URL) {
        var currentTags = getTags(for: url)
        currentTags.removeAll { $0 == tag }
        setTags(currentTags, for: url)
    }

    /// Toggle a tag on a file
    static func toggleTag(_ tag: String, on url: URL) {
        let currentTags = getTags(for: url)
        if currentTags.contains(tag) {
            removeTag(tag, from: url)
        } else {
            addTag(tag, to: url)
        }
    }

    static func invalidateCache(for url: URL) {
        cacheQueue.async {
            tagCache.removeValue(forKey: url)
        }
    }
}

/// Cache for file icons to avoid repeated NSWorkspace lookups
private class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    // Pre-cached generic icons for fast display
    private let genericImageIcon: NSImage
    private let genericVideoIcon: NSImage
    private let genericAudioIcon: NSImage
    private let genericFolderIcon: NSImage

    // File extensions that should use generic icons for speed
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "raw", "cr2", "nef", "arw", "dng"]
    private let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg"]
    private let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff"]

    private init() {
        cache.countLimit = 500

        // Pre-load generic icons (these are instant)
        genericImageIcon = NSWorkspace.shared.icon(for: .image)
        genericVideoIcon = NSWorkspace.shared.icon(for: .movie)
        genericAudioIcon = NSWorkspace.shared.icon(for: .audio)
        genericFolderIcon = NSWorkspace.shared.icon(for: .folder)
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

        // Don't cache plain folder icons - they can have custom colors
        // But DO cache bundles (.app, .bundle, etc.) - they have stable icons
        if isPlainFolder {
            return NSWorkspace.shared.icon(forFile: url.path)
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
        default: return NSWorkspace.shared.icon(for: .data)
        }
    }
}

struct FileItem: Identifiable, Hashable, Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .fileURL) { item in
            SentTransferredFile(item.url)
        }
        ProxyRepresentation(exporting: \.url)
    }
    let id: UUID
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let fileType: FileType
    let hasMetadata: Bool

    // Archive support - for items inside ZIP files
    let isFromArchive: Bool
    let archiveURL: URL?
    let archivePath: String?

    /// Get tags for this file (reads from filesystem each time)
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
        // Only skip caching for actual folders (not bundles like .app)
        // Folders can have custom colors that might change
        let isPlainFolder = fileType == .folder
        return IconCache.shared.icon(for: url, isPlainFolder: isPlainFolder)
    }

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

        let requestedKeys: Set<URLResourceKey> = loadMetadata
            ? [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey]
            : [.isDirectoryKey, .contentTypeKey]

        let resourceValues = try? url.resourceValues(forKeys: requestedKeys)

        self.isDirectory = resourceValues?.isDirectory ?? false
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
        if let contentType = resourceValues?.contentType {
            // Check for application bundles BEFORE falling back to folder
            if contentType.conforms(to: .application) || contentType.conforms(to: .bundle) || contentType.conforms(to: .package) {
                self.fileType = FileItem.determineFileType(from: contentType)
            } else if self.isDirectory {
                self.fileType = .folder
            } else {
                self.fileType = FileItem.determineFileType(from: contentType)
            }
        } else if let extType = UTType(filenameExtension: url.pathExtension) {
            // Check extension-based type for bundles
            if extType.conforms(to: .application) || extType.conforms(to: .bundle) || extType.conforms(to: .package) {
                self.fileType = FileItem.determineFileType(from: extType)
            } else if self.isDirectory {
                self.fileType = .folder
            } else {
                self.fileType = FileItem.determineFileType(from: extType)
            }
        } else if self.isDirectory {
            self.fileType = .folder
        } else {
            self.fileType = .other
        }
    }

    /// Initialize from archive entry data (for ZIP file contents)
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
         archivePath: String? = nil) {
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

        // Determine file type
        if isDirectory {
            self.fileType = .folder
        } else if let ct = contentType {
            self.fileType = FileItem.determineFileType(from: ct)
        } else {
            let ext = (name as NSString).pathExtension
            if let extType = UTType(filenameExtension: ext) {
                self.fileType = FileItem.determineFileType(from: extType)
            } else {
                self.fileType = .other
            }
        }
    }

    /// Return a copy of this item with full metadata loaded (reuses the same identity).
    func hydrated() -> FileItem {
        FileItem(url: url, id: id, loadMetadata: true)
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

    var formattedSize: String {
        if isDirectory { return "--" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var kindDescription: String {
        if isDirectory { return "Folder" }
        switch fileType {
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .code: return "Source Code"
        case .archive: return "Archive"
        case .application: return "Application"
        default: return "Document"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}

extension FileItem {
    func displayName(showFileExtensions: Bool) -> String {
        if showFileExtensions || isDirectory {
            return name
        }
        return nameWithoutExtension
    }
}

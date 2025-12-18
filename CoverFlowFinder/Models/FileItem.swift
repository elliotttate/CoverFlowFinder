import Foundation
import AppKit
import UniformTypeIdentifiers
import SwiftUI

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
        genericImageIcon = NSWorkspace.shared.icon(forFileType: UTType.image.identifier)
        genericVideoIcon = NSWorkspace.shared.icon(forFileType: UTType.movie.identifier)
        genericAudioIcon = NSWorkspace.shared.icon(forFileType: UTType.audio.identifier)
        genericFolderIcon = NSWorkspace.shared.icon(forFileType: UTType.folder.identifier)
    }

    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

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

        // For other files, get the actual icon (usually fast for non-media)
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
        default: return NSWorkspace.shared.icon(forFileType: UTType.data.identifier)
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

    // Lazy icon lookup - only loads when accessed
    var icon: NSImage {
        IconCache.shared.icon(for: url)
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

        // Determine file type quickly, falling back to filename extension when metadata is deferred
        if self.isDirectory {
            self.fileType = .folder
        } else if let contentType = resourceValues?.contentType {
            self.fileType = FileItem.determineFileType(from: contentType)
        } else if let extType = UTType(filenameExtension: url.pathExtension) {
            self.fileType = FileItem.determineFileType(from: extType)
        } else {
            self.fileType = .other
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}

import Foundation
import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    let creationDate: Date?
    let icon: NSImage
    let fileType: FileType

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

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let resourceValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentTypeKey
        ])

        self.isDirectory = resourceValues?.isDirectory ?? false
        self.size = Int64(resourceValues?.fileSize ?? 0)
        self.modificationDate = resourceValues?.contentModificationDate
        self.creationDate = resourceValues?.creationDate
        self.icon = NSWorkspace.shared.icon(forFile: url.path)

        // Determine file type
        if self.isDirectory {
            self.fileType = .folder
        } else if let contentType = resourceValues?.contentType {
            self.fileType = FileItem.determineFileType(from: contentType)
        } else {
            self.fileType = .other
        }
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

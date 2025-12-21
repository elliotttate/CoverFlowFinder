import Foundation
import AppKit
import UniformTypeIdentifiers
import Compression
import CryptoKit

/// Represents an entry in a ZIP archive
struct ZipEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String           // Full path in archive (e.g., "folder/file.txt")
    let name: String           // Just the filename
    let isDirectory: Bool
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let modificationDate: Date?
    let crc32: UInt32
    let compressionMethod: UInt16
    let localHeaderOffset: UInt64  // For extraction

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(uncompressedSize), countStyle: .file)
    }
}

/// Manages reading ZIP archives without extraction
class ZipArchiveManager {
    static let shared = ZipArchiveManager()

    private init() {}

    private let extractionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowFinder-ArchivePreview", isDirectory: true)

    // ZIP signatures
    private let endOfCentralDirSignature: UInt32 = 0x06054b50
    private let centralDirFileHeaderSignature: UInt32 = 0x02014b50
    private let localFileHeaderSignature: UInt32 = 0x04034b50

    /// Read the contents of a ZIP file without extracting
    func readContents(of zipURL: URL) throws -> [ZipEntry] {
        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? fileHandle.close() }

        // Find End of Central Directory record
        guard let eocd = try findEndOfCentralDirectory(fileHandle: fileHandle) else {
            throw ZipError.invalidArchive("Could not find End of Central Directory")
        }

        // Read Central Directory entries
        let entries = try readCentralDirectory(fileHandle: fileHandle, eocd: eocd)
        return entries
    }

    /// Build a hierarchy of ZipEntry items for a given path within the archive
    func entriesAtPath(_ path: String, in entries: [ZipEntry]) -> [ZipEntry] {
        let normalizedPath = path.isEmpty ? "" : (path.hasSuffix("/") ? path : path + "/")

        var result: [ZipEntry] = []
        var seenDirectories: Set<String> = []

        for entry in entries {
            // Skip entries not under our path
            if !normalizedPath.isEmpty && !entry.path.hasPrefix(normalizedPath) {
                continue
            }

            // Get the relative path from our current location
            let relativePath = String(entry.path.dropFirst(normalizedPath.count))

            // Skip empty paths (the directory itself)
            if relativePath.isEmpty {
                continue
            }

            // Check if this is a direct child or deeper
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)

            if components.count == 1 || (components.count == 2 && components[1].isEmpty) {
                // Direct child file or directory
                result.append(entry)
            } else if components.count > 1 {
                // This is deeper - we need to show the intermediate directory
                let dirName = String(components[0])
                let dirPath = normalizedPath + dirName + "/"

                if !seenDirectories.contains(dirPath) {
                    seenDirectories.insert(dirPath)
                    // Create a synthetic directory entry if one doesn't exist
                    if !entries.contains(where: { $0.path == dirPath }) {
                        let syntheticDir = ZipEntry(
                            path: dirPath,
                            name: dirName,
                            isDirectory: true,
                            compressedSize: 0,
                            uncompressedSize: 0,
                            modificationDate: nil,
                            crc32: 0,
                            compressionMethod: 0,
                            localHeaderOffset: 0
                        )
                        result.append(syntheticDir)
                    }
                }
            }
        }

        // Sort: directories first, then alphabetically
        return result.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Extract a single file from the archive to a temporary location
    func extractFile(_ entry: ZipEntry, from zipURL: URL) throws -> URL {
        guard !entry.isDirectory else {
            throw ZipError.cannotExtractDirectory
        }

        let tempFile = extractionURL(for: entry, in: zipURL)
        if FileManager.default.fileExists(atPath: tempFile.path) {
            return tempFile
        }

        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? fileHandle.close() }

        // Seek to local file header
        try fileHandle.seek(toOffset: entry.localHeaderOffset)

        // Read local file header
        guard let localHeaderData = try fileHandle.read(upToCount: 30) else {
            throw ZipError.invalidArchive("Could not read local file header")
        }

        // Verify signature
        let signature = localHeaderData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard signature == localFileHeaderSignature else {
            throw ZipError.invalidArchive("Invalid local file header signature")
        }

        // Get filename length and extra field length
        let fileNameLength = localHeaderData.withUnsafeBytes { $0.load(fromByteOffset: 26, as: UInt16.self) }
        let extraFieldLength = localHeaderData.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt16.self) }

        // Skip filename and extra field to get to file data
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(fileNameLength) + UInt64(extraFieldLength)
        try fileHandle.seek(toOffset: dataOffset)

        // Read compressed data
        guard let compressedData = try fileHandle.read(upToCount: Int(entry.compressedSize)) else {
            throw ZipError.invalidArchive("Could not read file data")
        }

        // Decompress if needed
        let decompressedData: Data
        if entry.compressionMethod == 0 {
            // Stored (no compression)
            decompressedData = compressedData
        } else if entry.compressionMethod == 8 {
            // Deflate compression
            decompressedData = try decompressDeflate(compressedData, expectedSize: Int(entry.uncompressedSize))
        } else {
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }

        // Write to temp file (stable, hashed path)
        try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: tempFile)
        try decompressedData.write(to: tempFile)

        return tempFile
    }

    // MARK: - Private Methods

    private func findEndOfCentralDirectory(fileHandle: FileHandle) throws -> EndOfCentralDirectory? {
        // Get file size
        let fileSize = try fileHandle.seekToEnd()

        // Minimum ZIP file with EOCD is 22 bytes
        guard fileSize >= 22 else {
            return nil
        }

        // Search backwards for EOCD signature (max comment size is 65535)
        let searchSize = min(fileSize, 65557)
        let searchStart = fileSize - searchSize

        try fileHandle.seek(toOffset: searchStart)
        guard let searchData = try fileHandle.read(upToCount: Int(searchSize)),
              searchData.count >= 22 else {
            return nil
        }

        // Search backwards for signature - need at least 22 bytes from position i
        let maxSearchOffset = searchData.count - 22
        guard maxSearchOffset >= 0 else {
            return nil
        }

        for i in stride(from: maxSearchOffset, through: 0, by: -1) {
            // Read 4 bytes for signature check
            let sigBytes = searchData.subdata(in: i..<(i + 4))
            let sig = sigBytes.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self)
            }

            if sig == endOfCentralDirSignature {
                // Found it - parse the record
                let eocdData = searchData.subdata(in: i..<(i + 22))

                let diskNumber = eocdData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }
                let cdDiskNumber = eocdData.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }
                let cdEntriesOnDisk = eocdData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) }
                let cdEntriesTotal = eocdData.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self) }
                let cdSize = eocdData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                let cdOffset = eocdData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }

                return EndOfCentralDirectory(
                    diskNumber: diskNumber,
                    cdDiskNumber: cdDiskNumber,
                    cdEntriesOnDisk: cdEntriesOnDisk,
                    cdEntriesTotal: cdEntriesTotal,
                    cdSize: cdSize,
                    cdOffset: cdOffset
                )
            }
        }

        return nil
    }

    private func readCentralDirectory(fileHandle: FileHandle, eocd: EndOfCentralDirectory) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []

        try fileHandle.seek(toOffset: UInt64(eocd.cdOffset))

        for _ in 0..<eocd.cdEntriesTotal {
            guard let headerData = try fileHandle.read(upToCount: 46),
                  headerData.count >= 46 else {
                break
            }

            // Verify signature - use safe subdata extraction
            let sigData = headerData.subdata(in: 0..<4)
            let signature = sigData.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard signature == centralDirFileHeaderSignature else {
                break
            }

            // Parse header fields using safe subdata extraction
            func readUInt16(at offset: Int) -> UInt16 {
                let data = headerData.subdata(in: offset..<(offset + 2))
                return data.withUnsafeBytes { $0.load(as: UInt16.self) }
            }

            func readUInt32(at offset: Int) -> UInt32 {
                let data = headerData.subdata(in: offset..<(offset + 4))
                return data.withUnsafeBytes { $0.load(as: UInt32.self) }
            }

            let compressionMethod = readUInt16(at: 10)
            let modTime = readUInt16(at: 12)
            let modDate = readUInt16(at: 14)
            let crc32 = readUInt32(at: 16)
            let compressedSize = readUInt32(at: 20)
            let uncompressedSize = readUInt32(at: 24)
            let fileNameLength = readUInt16(at: 28)
            let extraFieldLength = readUInt16(at: 30)
            let commentLength = readUInt16(at: 32)
            let localHeaderOffset = readUInt32(at: 42)

            // Read filename
            guard fileNameLength > 0,
                  let fileNameData = try fileHandle.read(upToCount: Int(fileNameLength)),
                  fileNameData.count == Int(fileNameLength),
                  let fileName = String(data: fileNameData, encoding: .utf8) ?? String(data: fileNameData, encoding: .isoLatin1) else {
                continue
            }

            // Skip extra field and comment
            if extraFieldLength > 0 {
                _ = try fileHandle.read(upToCount: Int(extraFieldLength))
            }
            if commentLength > 0 {
                _ = try fileHandle.read(upToCount: Int(commentLength))
            }

            // Determine if directory
            let isDirectory = fileName.hasSuffix("/")

            // Get just the name (last component)
            let name = isDirectory ?
                String(fileName.dropLast().split(separator: "/").last ?? Substring(fileName)) :
                String(fileName.split(separator: "/").last ?? Substring(fileName))

            // Convert DOS date/time to Date
            let modificationDate = dosDateTimeToDate(date: modDate, time: modTime)

            let entry = ZipEntry(
                path: fileName,
                name: name,
                isDirectory: isDirectory,
                compressedSize: UInt64(compressedSize),
                uncompressedSize: UInt64(uncompressedSize),
                modificationDate: modificationDate,
                crc32: crc32,
                compressionMethod: compressionMethod,
                localHeaderOffset: UInt64(localHeaderOffset)
            )

            entries.append(entry)
        }

        return entries
    }

    private func dosDateTimeToDate(date: UInt16, time: UInt16) -> Date? {
        var components = DateComponents()
        components.year = Int((date >> 9) & 0x7F) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int((time & 0x1F) * 2)

        return Calendar.current.date(from: components)
    }

    private func decompressDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        // Use Compression framework for raw deflate decompression
        // ZIP uses raw deflate (COMPRESSION_ZLIB handles this)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: expectedSize)
        defer { destinationBuffer.deallocate() }

        let decodedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_decode_buffer(
                destinationBuffer,
                expectedSize,
                sourcePtr,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decodedSize > 0 else {
            throw ZipError.extractionFailed("Decompression failed")
        }

        return Data(bytes: destinationBuffer, count: decodedSize)
    }

    private func extractionURL(for entry: ZipEntry, in zipURL: URL) -> URL {
        let mtime = (try? zipURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(zipURL.path)|\(mtime)|\(entry.path)"
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let ext = (entry.name as NSString).pathExtension
        let filename = ext.isEmpty ? hash : "\(hash).\(ext)"
        return extractionRoot.appendingPathComponent(filename)
    }
}

// MARK: - Supporting Types

private struct EndOfCentralDirectory {
    let diskNumber: UInt16
    let cdDiskNumber: UInt16
    let cdEntriesOnDisk: UInt16
    let cdEntriesTotal: UInt16
    let cdSize: UInt32
    let cdOffset: UInt32
}

enum ZipError: LocalizedError {
    case invalidArchive(String)
    case cannotExtractDirectory
    case unsupportedCompression(UInt16)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason):
            return "Invalid ZIP archive: \(reason)"
        case .cannotExtractDirectory:
            return "Cannot extract a directory"
        case .unsupportedCompression(let method):
            return "Unsupported compression method: \(method)"
        case .extractionFailed(let reason):
            return "Extraction failed: \(reason)"
        }
    }
}

// MARK: - FileItem Extension for ZIP Support

extension ZipArchiveManager {
    /// Convert ZipEntry items to FileItems for display
    func fileItems(from entries: [ZipEntry], archiveURL: URL) -> [FileItem] {
        return entries.map { (entry: ZipEntry) -> FileItem in
            // Create a virtual URL that encodes the archive path
            let virtualPath = archiveURL.path + "#" + entry.path
            let virtualURL = URL(fileURLWithPath: virtualPath)

            let ext = (entry.name as NSString).pathExtension
            let contentType: UTType? = entry.isDirectory ? UTType.folder : UTType(filenameExtension: ext)

            return FileItem(
                id: entry.id,
                url: virtualURL,
                name: entry.name,
                isDirectory: entry.isDirectory,
                size: Int64(entry.uncompressedSize),
                modificationDate: entry.modificationDate,
                creationDate: entry.modificationDate,
                contentType: contentType,
                isFromArchive: true,
                archiveURL: archiveURL,
                archivePath: entry.path
            )
        }
    }
}

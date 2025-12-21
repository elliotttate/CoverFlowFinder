import Foundation
import AppKit
import UniformTypeIdentifiers
import Compression
import CryptoKit
import os.log

private let zipLogger = Logger(subsystem: "com.flowfinder.app", category: "ZipArchive")

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

    // Cache for archive entries to avoid re-reading ZIP files
    private struct CachedArchive {
        let entries: [ZipEntry]
        let mtime: Date
        let offsetAdjustment: Int64
    }
    private var archiveCache: [URL: CachedArchive] = [:]
    private let cacheLock = NSLock()

    // ZIP signatures
    private let endOfCentralDirSignature: UInt32 = 0x06054b50
    private let zip64EndOfCentralDirSignature: UInt32 = 0x06064b50
    private let zip64EndOfCentralDirLocatorSignature: UInt32 = 0x07064b50
    private let centralDirFileHeaderSignature: UInt32 = 0x02014b50
    private let localFileHeaderSignature: UInt32 = 0x04034b50

    // Zip64 marker values
    private let zip64MagicValue16: UInt16 = 0xFFFF
    private let zip64MagicValue32: UInt32 = 0xFFFFFFFF

    /// Read the contents of a ZIP file without extracting
    func readContents(of zipURL: URL) throws -> [ZipEntry] {
        // Check cache first
        let mtime = (try? zipURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast

        cacheLock.lock()
        if let cached = archiveCache[zipURL], cached.mtime == mtime {
            cacheLock.unlock()
            return cached.entries
        }
        cacheLock.unlock()

        zipLogger.info("Opening ZIP archive: \(zipURL.lastPathComponent)")

        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? fileHandle.close() }

        // Find End of Central Directory record
        guard let eocdResult = try findEndOfCentralDirectory(fileHandle: fileHandle) else {
            zipLogger.error("Could not find End of Central Directory in \(zipURL.lastPathComponent)")
            throw ZipError.invalidArchive("Could not find End of Central Directory")
        }

        let (eocd, eocdPosition) = eocdResult

        // Check for Zip64 and get actual values
        let zip64Info = try findZip64EndOfCentralDirectory(fileHandle: fileHandle, eocdPosition: eocdPosition)

        // Determine actual central directory offset and entry count
        var cdOffset: UInt64
        var cdEntryCount: UInt64

        if let zip64 = zip64Info {
            zipLogger.info("Zip64 archive detected")
            cdOffset = zip64.cdOffset
            cdEntryCount = zip64.cdEntriesTotal
        } else if eocd.cdOffset == zip64MagicValue32 || eocd.cdEntriesTotal == zip64MagicValue16 {
            // Zip64 markers present but no Zip64 EOCD found
            zipLogger.error("Zip64 markers present but Zip64 EOCD not found")
            throw ZipError.invalidArchive("Zip64 archive but Zip64 structures not found")
        } else {
            cdOffset = UInt64(eocd.cdOffset)
            cdEntryCount = UInt64(eocd.cdEntriesTotal)
        }

        // Calculate prepended data offset adjustment
        let fileSize = try fileHandle.seekToEnd()
        let expectedCdEnd = cdOffset + UInt64(eocd.cdSize)
        let actualCdEnd = eocdPosition

        var offsetAdjustment: Int64 = 0
        if expectedCdEnd != actualCdEnd && cdOffset < fileSize {
            // There might be prepended data (self-extracting archive, etc.)
            offsetAdjustment = Int64(actualCdEnd) - Int64(expectedCdEnd)
            if offsetAdjustment > 0 {
                zipLogger.info("Detected prepended data, offset adjustment: \(offsetAdjustment) bytes")
            }
        }

        // Read Central Directory entries
        let entries = try readCentralDirectory(
            fileHandle: fileHandle,
            cdOffset: cdOffset,
            entryCount: cdEntryCount,
            offsetAdjustment: offsetAdjustment
        )

        // Cache the entries
        cacheLock.lock()
        archiveCache[zipURL] = CachedArchive(entries: entries, mtime: mtime, offsetAdjustment: offsetAdjustment)
        cacheLock.unlock()

        zipLogger.info("Successfully read \(entries.count) entries from \(zipURL.lastPathComponent)")
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
    func extractFile(_ entry: ZipEntry, from zipURL: URL, offsetAdjustment: Int64 = 0) throws -> URL {
        guard !entry.isDirectory else {
            throw ZipError.cannotExtractDirectory
        }

        let tempFile = extractionURL(for: entry, in: zipURL)
        if FileManager.default.fileExists(atPath: tempFile.path) {
            return tempFile
        }

        let fileHandle = try FileHandle(forReadingFrom: zipURL)
        defer { try? fileHandle.close() }

        // Calculate adjusted offset
        let adjustedOffset = Int64(entry.localHeaderOffset) + offsetAdjustment
        guard adjustedOffset >= 0 else {
            throw ZipError.invalidArchive("Invalid local header offset after adjustment")
        }

        // Seek to local file header
        try fileHandle.seek(toOffset: UInt64(adjustedOffset))

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
        let dataOffset = UInt64(adjustedOffset) + 30 + UInt64(fileNameLength) + UInt64(extraFieldLength)
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

    /// Extract a file from the archive by its path (uses cached entries)
    func extractByPath(_ path: String, from archiveURL: URL) throws -> URL {
        // Ensure entries are cached
        let entries = try readContents(of: archiveURL)

        // Find the entry with matching path
        guard let entry = entries.first(where: { $0.path == path }) else {
            throw ZipError.invalidArchive("Entry not found: \(path)")
        }

        // Get offset adjustment from cache
        cacheLock.lock()
        let offsetAdjustment = archiveCache[archiveURL]?.offsetAdjustment ?? 0
        cacheLock.unlock()

        return try extractFile(entry, from: archiveURL, offsetAdjustment: offsetAdjustment)
    }

    /// Check if a file has already been extracted (for thumbnail caching)
    func extractedFileURL(for path: String, in archiveURL: URL) -> URL? {
        // Get entries to compute the extraction URL
        guard let entries = try? readContents(of: archiveURL),
              let entry = entries.first(where: { $0.path == path }) else {
            return nil
        }

        let tempFile = extractionURL(for: entry, in: archiveURL)
        return FileManager.default.fileExists(atPath: tempFile.path) ? tempFile : nil
    }

    // MARK: - Private Methods

    private func findEndOfCentralDirectory(fileHandle: FileHandle) throws -> (EndOfCentralDirectory, UInt64)? {
        // Get file size
        let fileSize = try fileHandle.seekToEnd()

        // Minimum ZIP file with EOCD is 22 bytes
        guard fileSize >= 22 else {
            zipLogger.warning("File too small to be a valid ZIP: \(fileSize) bytes")
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

                let eocdPosition = searchStart + UInt64(i)

                return (EndOfCentralDirectory(
                    diskNumber: diskNumber,
                    cdDiskNumber: cdDiskNumber,
                    cdEntriesOnDisk: cdEntriesOnDisk,
                    cdEntriesTotal: cdEntriesTotal,
                    cdSize: cdSize,
                    cdOffset: cdOffset
                ), eocdPosition)
            }
        }

        return nil
    }

    private func findZip64EndOfCentralDirectory(fileHandle: FileHandle, eocdPosition: UInt64) throws -> Zip64EndOfCentralDirectory? {
        // Zip64 EOCD Locator is 20 bytes and appears right before the regular EOCD
        guard eocdPosition >= 20 else {
            return nil
        }

        let locatorPosition = eocdPosition - 20
        try fileHandle.seek(toOffset: locatorPosition)

        guard let locatorData = try fileHandle.read(upToCount: 20),
              locatorData.count == 20 else {
            return nil
        }

        // Check for Zip64 EOCD Locator signature
        let locatorSig = locatorData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard locatorSig == zip64EndOfCentralDirLocatorSignature else {
            // No Zip64 locator found - this is a normal ZIP
            return nil
        }

        zipLogger.debug("Found Zip64 EOCD Locator")

        // Parse the locator
        let zip64EocdDiskNumber = locatorData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let zip64EocdOffset = locatorData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        let totalDisks = locatorData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }

        // Multi-disk not fully supported yet
        if totalDisks > 1 {
            zipLogger.warning("Multi-disk Zip64 archive detected (\(totalDisks) disks)")
        }

        // Read the Zip64 EOCD record
        try fileHandle.seek(toOffset: zip64EocdOffset)

        guard let zip64EocdData = try fileHandle.read(upToCount: 56),
              zip64EocdData.count >= 56 else {
            zipLogger.error("Could not read Zip64 EOCD record")
            return nil
        }

        // Verify signature
        let zip64EocdSig = zip64EocdData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard zip64EocdSig == zip64EndOfCentralDirSignature else {
            zipLogger.error("Invalid Zip64 EOCD signature")
            return nil
        }

        // Parse Zip64 EOCD
        let cdEntriesOnDisk = zip64EocdData.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self) }
        let cdEntriesTotal = zip64EocdData.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self) }
        let cdSize = zip64EocdData.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt64.self) }
        let cdOffset = zip64EocdData.withUnsafeBytes { $0.load(fromByteOffset: 48, as: UInt64.self) }

        zipLogger.info("Zip64 EOCD: \(cdEntriesTotal) entries, CD offset: \(cdOffset)")

        return Zip64EndOfCentralDirectory(
            cdEntriesOnDisk: cdEntriesOnDisk,
            cdEntriesTotal: cdEntriesTotal,
            cdSize: cdSize,
            cdOffset: cdOffset
        )
    }

    private func readCentralDirectory(
        fileHandle: FileHandle,
        cdOffset: UInt64,
        entryCount: UInt64,
        offsetAdjustment: Int64
    ) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var skippedEntries = 0
        var readErrors = 0

        let adjustedOffset = Int64(cdOffset) + offsetAdjustment
        guard adjustedOffset >= 0 else {
            zipLogger.error("Invalid central directory offset after adjustment: \(adjustedOffset)")
            throw ZipError.invalidArchive("Invalid central directory offset")
        }

        try fileHandle.seek(toOffset: UInt64(adjustedOffset))

        zipLogger.debug("Reading \(entryCount) central directory entries at offset \(adjustedOffset)")

        for entryIndex in 0..<entryCount {
            guard let headerData = try fileHandle.read(upToCount: 46),
                  headerData.count >= 46 else {
                zipLogger.error("Failed to read central directory header at entry \(entryIndex)")
                readErrors += 1
                break
            }

            // Verify signature - use safe subdata extraction
            let sigData = headerData.subdata(in: 0..<4)
            let signature = sigData.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard signature == centralDirFileHeaderSignature else {
                zipLogger.error("Invalid central directory signature at entry \(entryIndex): 0x\(String(signature, radix: 16))")
                readErrors += 1
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
            var compressedSize = UInt64(readUInt32(at: 20))
            var uncompressedSize = UInt64(readUInt32(at: 24))
            let fileNameLength = readUInt16(at: 28)
            let extraFieldLength = readUInt16(at: 30)
            let commentLength = readUInt16(at: 32)
            var localHeaderOffset = UInt64(readUInt32(at: 42))

            // Read filename with multiple encoding support
            guard fileNameLength > 0 else {
                zipLogger.debug("Skipping entry \(entryIndex) with empty filename")
                skippedEntries += 1
                continue
            }

            guard let fileNameData = try fileHandle.read(upToCount: Int(fileNameLength)),
                  fileNameData.count == Int(fileNameLength) else {
                zipLogger.warning("Failed to read filename for entry \(entryIndex)")
                skippedEntries += 1
                continue
            }

            // Try multiple encodings for filename
            guard let fileName = decodeFilename(fileNameData) else {
                zipLogger.warning("Could not decode filename for entry \(entryIndex) with any supported encoding")
                skippedEntries += 1
                // Still need to skip extra field and comment
                if extraFieldLength > 0 {
                    _ = try fileHandle.read(upToCount: Int(extraFieldLength))
                }
                if commentLength > 0 {
                    _ = try fileHandle.read(upToCount: Int(commentLength))
                }
                continue
            }

            // Read and parse extra field (may contain Zip64 extended info)
            var extraFieldData: Data? = nil
            if extraFieldLength > 0 {
                extraFieldData = try fileHandle.read(upToCount: Int(extraFieldLength))
            }

            // Parse Zip64 extended information if sizes/offset are maxed out
            if compressedSize == UInt64(zip64MagicValue32) ||
               uncompressedSize == UInt64(zip64MagicValue32) ||
               localHeaderOffset == UInt64(zip64MagicValue32) {
                if let extraData = extraFieldData {
                    let zip64Values = parseZip64ExtraField(
                        extraData,
                        needUncompressedSize: uncompressedSize == UInt64(zip64MagicValue32),
                        needCompressedSize: compressedSize == UInt64(zip64MagicValue32),
                        needLocalHeaderOffset: localHeaderOffset == UInt64(zip64MagicValue32)
                    )
                    if let values = zip64Values {
                        if let size = values.uncompressedSize { uncompressedSize = size }
                        if let size = values.compressedSize { compressedSize = size }
                        if let offset = values.localHeaderOffset { localHeaderOffset = offset }
                    }
                }
            }

            // Skip comment
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
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                modificationDate: modificationDate,
                crc32: crc32,
                compressionMethod: compressionMethod,
                localHeaderOffset: localHeaderOffset
            )

            entries.append(entry)
        }

        if skippedEntries > 0 {
            zipLogger.warning("Skipped \(skippedEntries) entries due to decoding issues")
        }
        if readErrors > 0 {
            zipLogger.error("Encountered \(readErrors) read errors while parsing central directory")
        }

        return entries
    }

    /// Try multiple encodings to decode a filename
    private func decodeFilename(_ data: Data) -> String? {
        // Try encodings in order of likelihood
        let encodings: [(String.Encoding, String)] = [
            (.utf8, "UTF-8"),
            (.isoLatin1, "ISO-Latin1"),
            (.windowsCP1252, "Windows-1252"),
            (.macOSRoman, "Mac OS Roman"),
            (.shiftJIS, "Shift-JIS"),
            (.ascii, "ASCII"),
        ]

        for (encoding, name) in encodings {
            if let decoded = String(data: data, encoding: encoding) {
                // Validate the string doesn't contain replacement characters for UTF-8
                if encoding == .utf8 && decoded.contains("\u{FFFD}") {
                    continue
                }
                zipLogger.debug("Decoded filename using \(name)")
                return decoded
            }
        }

        return nil
    }

    /// Parse Zip64 extended information extra field
    private func parseZip64ExtraField(
        _ data: Data,
        needUncompressedSize: Bool,
        needCompressedSize: Bool,
        needLocalHeaderOffset: Bool
    ) -> (uncompressedSize: UInt64?, compressedSize: UInt64?, localHeaderOffset: UInt64?)? {
        // Zip64 extended information extra field has header ID 0x0001
        var offset = 0
        while offset + 4 <= data.count {
            let headerID = data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.load(as: UInt16.self) }
            let dataSize = data.subdata(in: (offset + 2)..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt16.self) }

            if headerID == 0x0001 {
                // Found Zip64 extra field
                var fieldOffset = offset + 4
                var uncompressedSize: UInt64? = nil
                var compressedSize: UInt64? = nil
                var localHeaderOffset: UInt64? = nil

                // Values appear in order: uncompressed, compressed, local header offset, disk start
                // But only if the corresponding field in the header was 0xFFFFFFFF
                if needUncompressedSize && fieldOffset + 8 <= offset + 4 + Int(dataSize) {
                    uncompressedSize = data.subdata(in: fieldOffset..<(fieldOffset + 8)).withUnsafeBytes { $0.load(as: UInt64.self) }
                    fieldOffset += 8
                }
                if needCompressedSize && fieldOffset + 8 <= offset + 4 + Int(dataSize) {
                    compressedSize = data.subdata(in: fieldOffset..<(fieldOffset + 8)).withUnsafeBytes { $0.load(as: UInt64.self) }
                    fieldOffset += 8
                }
                if needLocalHeaderOffset && fieldOffset + 8 <= offset + 4 + Int(dataSize) {
                    localHeaderOffset = data.subdata(in: fieldOffset..<(fieldOffset + 8)).withUnsafeBytes { $0.load(as: UInt64.self) }
                    fieldOffset += 8
                }

                return (uncompressedSize, compressedSize, localHeaderOffset)
            }

            offset += 4 + Int(dataSize)
        }

        return nil
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

private struct Zip64EndOfCentralDirectory {
    let cdEntriesOnDisk: UInt64
    let cdEntriesTotal: UInt64
    let cdSize: UInt64
    let cdOffset: UInt64
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

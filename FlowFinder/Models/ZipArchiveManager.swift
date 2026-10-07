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
    var versionMadeBy: UInt16 = 0       // Upper byte = host system (3 = Unix, 19 = OS X)
    var flags: UInt16 = 0               // General-purpose bits (0 = encrypted, 11 = UTF-8 name)
    var externalAttributes: UInt32 = 0  // Unix st_mode in the upper 16 bits when made on Unix

    var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: uncompressedSize), countStyle: .file)
    }

    /// The Unix mode recorded by the archiver, if the entry was made on a Unix-like host
    var unixMode: UInt32? {
        let host = versionMadeBy >> 8
        guard host == 3 || host == 19 else { return nil }
        let mode = externalAttributes >> 16
        return mode == 0 ? nil : mode
    }

    var isSymbolicLink: Bool {
        guard let mode = unixMode else { return false }
        return mode & UInt32(S_IFMT) == UInt32(S_IFLNK)
    }

    var isEncrypted: Bool { flags & 0x0001 != 0 }
}

/// Caps applied while extracting, so a crafted archive can't exhaust memory or disk
struct ZipExtractionLimits {
    /// Largest single entry that will be written
    var maxEntryBytes: UInt64 = 8 << 30
    /// Largest total (declared) size of one folder extraction
    var maxTotalBytes: UInt64 = 64 << 30

    static let standard = ZipExtractionLimits()
}

struct ZipExtractionFailure {
    let path: String   // Relative to the extracted item
    let error: Error
}

struct ZipExtractionResult {
    let url: URL
    /// Entries of an extracted folder that couldn't be written (the rest were)
    let failures: [ZipExtractionFailure]
}

/// Keeps copy-out extractions (`ZipArchiveManager.extractItemForCopy`) on disk while it is alive.
/// When the last lease on an extraction ends (`release()` or deinit), its temporary folder is
/// deleted after `ZipArchiveManager.copyExtractionGracePeriod`.
final class ArchiveExtractionLease: @unchecked Sendable {
    private let folders: [String]
    private let lock = NSLock()
    private var isReleased = false

    fileprivate init(folders: [String]) {
        self.folders = folders
    }

    func release() {
        lock.lock()
        let wasReleased = isReleased
        isReleased = true
        lock.unlock()
        guard !wasReleased else { return }
        ZipArchiveManager.shared.endLease(on: folders)
    }

    deinit {
        release()
    }
}

/// Reads ZIP archives without extracting them, and extracts entries safely on demand.
/// Safe to call from any thread.
final class ZipArchiveManager: @unchecked Sendable {
    static let shared = ZipArchiveManager()

    private init() {}

    /// Single files extracted for open / Quick Look / thumbnails: `<hash>/<name>`, read-only
    private let extractionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowFinder-ArchivePreview", isDirectory: true)
    /// One fresh subdirectory per copy-out operation
    private let copyRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("FlowFinder-Extract", isDirectory: true)
    /// The copy-out root's path as given and with symbolic links resolved (/var is /private/var), to
    /// recognize URLs that come back in either form
    private let copyRootPaths: [String] = {
        let temporary = FileManager.default.temporaryDirectory
        var paths = [temporary.appendingPathComponent("FlowFinder-Extract", isDirectory: true).standardizedFileURL.path]
        if let real = ZipArchiveManager.realPath(temporary.path) {
            paths.append(real + "/FlowFinder-Extract")
        }
        return paths
    }()

    /// How long a copy-out extraction outlives its last lease (a paste in another app may still be reading it)
    var copyExtractionGracePeriod: TimeInterval = 30

    // Parsed archives, invalidated when the file's size, mtime or inode change
    private struct CachedArchive {
        let entries: [ZipEntry]
        let stamp: FileStamp
        let offsetAdjustment: Int64
        let index: ArchiveIndex
    }
    private var archiveCache = LRUCache<URL, CachedArchive>(capacity: 8)
    // entriesAtPath receives an entries array rather than a URL, so its index is looked up by fingerprint
    private var indexCache = LRUCache<EntriesFingerprint, ArchiveIndex>(capacity: 8)
    private let cacheLock = NSLock()
    private var didScheduleCleanup = false
    /// Preview and copy-out folders created or reused in this session; the stale-item cleanup keeps them (cacheLock)
    private var sessionItems = Set<String>()
    /// Leased copy-out folders: number of leases, and a generation bumped whenever the count drops to 0 (cacheLock)
    private var copyLeases: [String: (count: Int, generation: Int)] = [:]
    // Serializes writers of the same preview folder, and the cleanup against them (striped by path hash)
    private let itemLocks = (0..<16).map { _ in NSLock() }

    static let maxCentralDirectorySize: UInt64 = 512 << 20
    static let staleExtractionAge: TimeInterval = 24 * 60 * 60

    // ZIP signatures
    private let endOfCentralDirSignature: UInt32 = 0x06054b50
    private let zip64EndOfCentralDirSignature: UInt32 = 0x06064b50
    private let zip64EndOfCentralDirLocatorSignature: UInt32 = 0x07064b50
    private let centralDirFileHeaderSignature: UInt32 = 0x02014b50
    private let localFileHeaderSignature: UInt32 = 0x04034b50

    // Zip64 marker value for 32-bit size/offset fields
    private let zip64MagicValue32: UInt32 = 0xFFFFFFFF

    /// Read the contents of a ZIP file without extracting.
    /// Entries with unsafe paths (absolute, "..", ".", empty components, backslashes, NUL) are left out.
    func readContents(of zipURL: URL) throws -> [ZipEntry] {
        let reader = try ArchiveReader(url: zipURL)
        return try cachedArchive(for: zipURL, reader: reader).entries
    }

    /// Build a hierarchy of ZipEntry items for a given path within the archive
    func entriesAtPath(_ path: String, in entries: [ZipEntry]) -> [ZipEntry] {
        let normalizedPath = path.isEmpty ? "" : (path.hasSuffix("/") ? path : path + "/")
        return index(for: entries).children(of: normalizedPath)
    }

    /// Look up an entry (including implicit folders) by archive path, with or without a trailing "/"
    func entry(atPath path: String, in entries: [ZipEntry]) -> ZipEntry? {
        let index = index(for: entries)
        if path.hasSuffix("/") {
            return index.entry(atPath: path) ?? index.entry(atPath: String(path.dropLast()))
        }
        return index.entry(atPath: path) ?? index.entry(atPath: path + "/")
    }

    /// Extract a single file from the archive to a temporary location (for open / Quick Look / thumbnails).
    /// A symbolic link entry extracts the entry it points to. The file is read-only.
    /// Pass `offsetAdjustment` only to override the value detected when the archive was read.
    func extractFile(_ entry: ZipEntry, from zipURL: URL, offsetAdjustment: Int64? = nil) throws -> URL {
        guard !entry.isDirectory else {
            throw ZipError.cannotExtractDirectory
        }
        guard Self.isSafeEntryPath(entry.path) else {
            throw ZipError.unsafeEntryPath(entry.path)
        }

        let reader = try ArchiveReader(url: zipURL)
        let archive = try cachedArchive(for: zipURL, reader: reader)
        let adjustment = offsetAdjustment ?? archive.offsetAdjustment
        let target = entry.isSymbolicLink
            ? try resolveSymbolicLink(entry, in: archive, reader: reader, offsetAdjustment: adjustment)
            : entry
        return try extractPreviewFile(target, archiveURL: zipURL, reader: reader, offsetAdjustment: adjustment)
    }

    /// Extract a file from the archive by its path (uses cached entries). A symbolic link entry
    /// extracts the entry it points to. The file is read-only.
    func extractByPath(_ path: String, from archiveURL: URL) throws -> URL {
        let reader = try ArchiveReader(url: archiveURL)
        let archive = try cachedArchive(for: archiveURL, reader: reader)

        guard let entry = archive.index.entry(atPath: path) else {
            throw ZipError.entryNotFound(path)
        }
        guard !entry.isDirectory else {
            throw ZipError.cannotExtractDirectory
        }
        let target = entry.isSymbolicLink
            ? try resolveSymbolicLink(entry, in: archive, reader: reader, offsetAdjustment: archive.offsetAdjustment)
            : entry

        return try extractPreviewFile(target, archiveURL: archiveURL, reader: reader, offsetAdjustment: archive.offsetAdjustment)
    }

    /// Check if a file has already been extracted (for thumbnail caching)
    func extractedFileURL(for path: String, in archiveURL: URL) -> URL? {
        guard let reader = try? ArchiveReader(url: archiveURL),
              let archive = try? cachedArchive(for: archiveURL, reader: reader),
              let entry = archive.index.entry(atPath: path),
              !entry.isDirectory else {
            return nil
        }
        let target = entry.isSymbolicLink
            ? try? resolveSymbolicLink(entry, in: archive, reader: reader, offsetAdjustment: archive.offsetAdjustment)
            : entry
        guard let target else { return nil }

        let file = previewLocation(for: target, archiveURL: archiveURL, stamp: reader.stamp).file
        return Self.fileType(atPath: file.path) == S_IFREG ? file : nil
    }

    /// Extract the file or folder at `archivePath` into a new private temporary directory (for copy/paste).
    /// A path ending in "/" means the folder when a file has the same name (as in the listing).
    /// Paths are confined to that directory; Unix permissions (minus setuid/setgid/sticky), dates, safe
    /// relative symlinks and the archive's quarantine attribute are carried over. A folder extraction
    /// writes the members its listing shows and continues past per-entry errors, reporting them in
    /// `failures` — including entries whose names collide (duplicates, names differing only in case or
    /// Unicode form, a file and a folder of the same name): one of them is written, never a mix.
    /// Anything else throws, including too little free space for the declared size.
    ///
    /// `progress` (optional) gets the number of bytes to write as its total and advances as they're
    /// written. Cancelling it stops the extraction with `CocoaError.userCancelled` and removes
    /// everything written so far.
    ///
    /// The result stays until `discardCopyExtraction`, the end of the last `leaseCopyExtractions` lease
    /// on it, or a later launch's stale-item cleanup (a day after it was last used).
    func extractItemForCopy(archivePath: String, from archiveURL: URL, limits: ZipExtractionLimits = .standard,
                            progress: Progress? = nil) throws -> ZipExtractionResult {
        try Self.checkCancellation(progress)
        let reader = try ArchiveReader(url: archiveURL)
        let archive = try cachedArchive(for: archiveURL, reader: reader)

        let wantsFolder = archivePath.hasSuffix("/")
        let trimmedPath = wantsFolder ? String(archivePath.dropLast()) : archivePath
        guard Self.isSafeEntryPath(trimmedPath) else {
            throw ZipError.unsafeEntryPath(archivePath)
        }
        let preferred = archive.index.entry(atPath: wantsFolder ? trimmedPath + "/" : trimmedPath)
        guard let entry = preferred ?? archive.index.entry(atPath: wantsFolder ? trimmedPath : trimmedPath + "/") else {
            throw ZipError.entryNotFound(archivePath)
        }
        guard Self.isSafePathComponent(entry.name) else {
            throw ZipError.unsafeEntryPath(entry.path)
        }

        // Check the caps and the free space before anything is written
        let plan: FolderPlan?
        if entry.isDirectory {
            let folderPlan = try planFolderExtraction(entry, index: archive.index, limits: limits)
            try Self.checkFreeSpace(for: folderPlan.totalBytes)
            plan = folderPlan
        } else {
            guard entry.uncompressedSize <= limits.maxEntryBytes else {
                throw ZipError.entryTooLarge(entry.uncompressedSize)
            }
            try Self.checkFreeSpace(for: entry.uncompressedSize)
            plan = nil
        }

        let operationDirectory = try makeOperationDirectory()
        do {
            let destination = operationDirectory.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
            guard Self.isContained(destination, in: operationDirectory) else {
                throw ZipError.unsafeEntryPath(entry.path)
            }

            let quarantine = Self.quarantineAttribute(of: archiveURL)
            if let plan {
                let failures = try extractDirectory(entry, plan: plan, archive: archive, reader: reader, to: destination,
                                                    quarantine: quarantine, limits: limits, progress: progress)
                Self.finish(progress)
                return ZipExtractionResult(url: destination, failures: failures)
            }

            progress?.totalUnitCount = Int64(clamping: max(1, entry.uncompressedSize))
            if entry.isSymbolicLink {
                try writeSymbolicLink(entry, reader: reader, offsetAdjustment: archive.offsetAdjustment,
                                      components: [entry.name], to: destination,
                                      quarantine: quarantine, limits: limits, progress: progress)
            } else {
                try writeFile(entry, reader: reader, offsetAdjustment: archive.offsetAdjustment, to: destination,
                              attributes: Self.fileAttributes(for: entry, quarantine: quarantine, restoreDate: true),
                              limits: limits, exclusive: true, progress: progress)
            }
            Self.finish(progress)
            return ZipExtractionResult(url: destination, failures: [])
        } catch {
            // Only our own fresh, uniquely named directory is removed
            try? FileManager.default.removeItem(at: operationDirectory)
            throw error
        }
    }

    /// Removes the temporary folder an `extractItemForCopy` result lives in (e.g. after the copy
    /// it was made for was cancelled). Does nothing for paths outside the copy-out folder.
    func discardCopyExtraction(_ extractedURL: URL) {
        guard let folder = operationFolder(containing: extractedURL) else { return }
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// Keeps the copy-out extractions among `urls` (results of `extractItemForCopy`, or items inside
    /// them) on disk until the returned lease is released; then they're deleted, unless another lease
    /// still holds them. Hold one for as long as something may still read them — the clipboard
    /// referencing them, a paste in progress. Returns nil if none of `urls` is such an extraction.
    func leaseCopyExtractions(_ urls: [URL]) -> ArchiveExtractionLease? {
        let folders = Array(Set(urls.compactMap(operationFolder(containing:))))
        guard !folders.isEmpty else { return nil }
        cacheLock.lock()
        for folder in folders {
            let lease = copyLeases[folder] ?? (0, 0)
            copyLeases[folder] = (lease.count + 1, lease.generation)
        }
        cacheLock.unlock()
        return ArchiveExtractionLease(folders: folders)
    }

    fileprivate func endLease(on folders: [String]) {
        var released: [(folder: String, generation: Int)] = []
        cacheLock.lock()
        for folder in folders {
            guard let lease = copyLeases[folder] else { continue }
            if lease.count > 1 {
                copyLeases[folder] = (lease.count - 1, lease.generation)
            } else {
                copyLeases[folder] = (0, lease.generation + 1)
                released.append((folder, lease.generation + 1))
            }
        }
        let delay = copyExtractionGracePeriod
        cacheLock.unlock()
        guard !released.isEmpty else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            for (folder, generation) in released {
                cacheLock.lock()
                // Not leased again since
                let isUnused = copyLeases[folder].map { $0.count == 0 && $0.generation == generation } ?? false
                if isUnused {
                    copyLeases[folder] = nil
                }
                cacheLock.unlock()
                if isUnused {
                    try? FileManager.default.removeItem(atPath: folder)
                }
            }
        }
    }

    /// The per-operation folder (a direct child of the copy-out root) that `url` is or is inside of
    private func operationFolder(containing url: URL) -> String? {
        let path = url.standardizedFileURL.path
        for root in copyRootPaths {
            let prefix = root + "/"
            guard path.hasPrefix(prefix) else { continue }
            guard let name = path.dropFirst(prefix.count).split(separator: "/").first,
                  Self.isSafePathComponent(name) else { return nil }
            return copyRoot.appendingPathComponent(String(name), isDirectory: true).standardizedFileURL.path
        }
        return nil
    }

    /// Throws if the volume holding the temporary folder has less room than `bytes` (plus a margin)
    private static func checkFreeSpace(for bytes: UInt64) throws {
        guard bytes > 0,
              let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return }
        let available = UInt64(max(0, capacity))
        let (needed, overflow) = bytes.addingReportingOverflow(min(bytes / 10, 1 << 30))
        if overflow || needed > available {
            throw ZipError.insufficientSpace(needed: bytes, available: available)
        }
    }

    private static func checkCancellation(_ progress: Progress?) throws {
        if progress?.isCancelled == true {
            throw CocoaError(.userCancelled)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    private static func finish(_ progress: Progress?) {
        guard let progress else { return }
        if progress.totalUnitCount <= 0 {
            progress.totalUnitCount = 1
        }
        progress.completedUnitCount = progress.totalUnitCount
    }

    // MARK: - Path Safety

    /// True if `path` (an archive entry path, optionally ending in "/") stays inside the extraction directory
    static func isSafeEntryPath(_ path: String) -> Bool {
        var trimmed = Substring(path)
        if trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return false }
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isSafePathComponent($0) }
    }

    static func isSafePathComponent<S: StringProtocol>(_ component: S) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\\") && !component.contains("\0")
            && component.utf8.count <= 255
    }

    /// A symlink target (for a link at `linkComponents` below the extraction root) is accepted only if it is
    /// relative and can't leave the root: ".." may only lead the target, where it climbs through the real
    /// folders above the link (never past the root), and the rest only descends by name. Descending through
    /// other links from the archive is safe because each of them passed this same check. Matching names
    /// against the archive's other links instead would have to reproduce the file system's case and Unicode
    /// folding exactly (APFS treats "ſ" as "s", for one).
    static func isSafeSymlinkTarget(_ target: String, linkComponents: [String]) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0"), !target.contains("\\") else {
            return false
        }
        var foldersAbove = linkComponents.count - 1
        var isDescending = false
        for component in target.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !isDescending, foldersAbove > 0 else { return false }
                foldersAbove -= 1
            default:
                isDescending = true
            }
        }
        return true
    }

    /// Earlier form of `isSafeSymlinkTarget(_:linkComponents:)`; the other links no longer matter.
    static func isSafeSymlinkTarget(_ target: String, linkComponents: [String], symlinkKeys: Set<String>) -> Bool {
        isSafeSymlinkTarget(target, linkComponents: linkComponents)
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// The file type bits (S_IFREG, S_IFDIR, ...) of `path` itself, or nil if there's nothing there
    private static func fileType(atPath path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }

    fileprivate static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Caching

    private func cachedArchive(for url: URL, reader: ArchiveReader) throws -> CachedArchive {
        scheduleCleanupIfNeeded()
        let key = url.standardizedFileURL

        cacheLock.lock()
        if let cached = archiveCache.value(forKey: key), cached.stamp == reader.stamp {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let (entries, offsetAdjustment) = try parseArchive(reader)
        let index = ArchiveIndex(entries: entries)
        let archive = CachedArchive(entries: entries, stamp: reader.stamp, offsetAdjustment: offsetAdjustment, index: index)

        cacheLock.lock()
        archiveCache.setValue(archive, forKey: key)
        indexCache.setValue(index, forKey: EntriesFingerprint(entries))
        cacheLock.unlock()

        zipLogger.debug("Read \(entries.count) entries from ZIP archive")
        return archive
    }

    private func index(for entries: [ZipEntry]) -> ArchiveIndex {
        let key = EntriesFingerprint(entries)
        cacheLock.lock()
        if let index = indexCache.value(forKey: key) {
            cacheLock.unlock()
            return index
        }
        cacheLock.unlock()

        let index = ArchiveIndex(entries: entries)
        cacheLock.lock()
        indexCache.setValue(index, forKey: key)
        cacheLock.unlock()
        return index
    }

    /// Removes leftovers of earlier runs once per launch, off the calling thread. Items used in this
    /// session, leased, or on the clipboard (which can outlive the app) are kept.
    private func scheduleCleanupIfNeeded() {
        cacheLock.lock()
        let shouldRun = !didScheduleCleanup
        didScheduleCleanup = true
        cacheLock.unlock()
        guard shouldRun else { return }

        // The pasteboard is read on the main thread
        DispatchQueue.main.async { [self] in
            let clipboard = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            DispatchQueue.global(qos: .utility).async { [self] in
                removeStaleExtractions(keeping: clipboard)
            }
        }
    }

    /// Deletes previews and copy-out folders last used more than `staleExtractionAge` ago, except those used
    /// in this session, leased, or containing one of `clipboardURLs`. Runs once per launch on its own.
    func removeStaleExtractions(keeping clipboardURLs: [URL]) {
        let clipboardPaths = clipboardURLs.compactMap { Self.realPath($0.path) }
        for root in [extractionRoot, copyRoot] {
            Self.removeStaleItems(in: root, olderThan: Self.staleExtractionAge, isInUse: { [self] child in
                isInUse(child, clipboardPaths: clipboardPaths)
            }, exclusively: { [self] child, body in
                // Excludes a concurrent reuse of the same preview (see extractPreviewFile)
                let lock = itemLock(for: child)
                lock.lock()
                body()
                lock.unlock()
            })
        }
    }

    private func isInUse(_ item: URL, clipboardPaths: [String]) -> Bool {
        let path = item.standardizedFileURL.path
        cacheLock.lock()
        let isActive = sessionItems.contains(path) || copyLeases[path] != nil
        cacheLock.unlock()
        if isActive { return true }
        guard !clipboardPaths.isEmpty, let real = Self.realPath(item.path) else { return false }
        return clipboardPaths.contains { $0 == real || $0.hasPrefix(real + "/") }
    }

    /// Notes that `item` (a direct child of a temporary root) is in use in this session
    private func markUsed(_ item: URL) {
        cacheLock.lock()
        sessionItems.insert(item.standardizedFileURL.path)
        cacheLock.unlock()
    }

    private func itemLock(for item: URL) -> NSLock {
        itemLocks[Int(UInt(bitPattern: item.standardizedFileURL.path.hashValue) % UInt(itemLocks.count))]
    }

    /// Deletes direct children of `directory` that haven't been modified within `age` seconds, except those
    /// `isInUse` reports. Each check-and-delete runs inside `exclusively` (given the child). Read-only
    /// folders (opened previews) are made writable first so they can be deleted.
    static func removeStaleItems(in directory: URL, olderThan age: TimeInterval,
                                 isInUse: @escaping (URL) -> Bool = { _ in false },
                                 exclusively: (URL, () -> Void) -> Void = { _, body in body() }) {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let cutoff = Date().timeIntervalSince1970 - age
        for child in children {
            exclusively(child) {
                var info = stat()
                guard lstat(child.path, &info) == 0 else { return }
                let mtime = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
                guard mtime < cutoff, !isInUse(child) else { return }
                if info.st_mode & S_IFMT == S_IFDIR {
                    _ = chmod(child.path, 0o700)
                }
                try? fileManager.removeItem(at: child)
            }
        }
    }

    // MARK: - Parsing

    private func parseArchive(_ reader: ArchiveReader) throws -> (entries: [ZipEntry], offsetAdjustment: Int64) {
        let fileSize = reader.size
        guard fileSize >= 22 else {
            throw ZipError.invalidArchive("File is too small to be a ZIP archive")
        }

        // End of Central Directory: 22 bytes followed by a comment of up to 65535 bytes
        let tailLength = min(fileSize, 22 + 0xFFFF)
        let tailStart = fileSize - tailLength
        let tail = try reader.bytes(at: tailStart, count: Int(tailLength))
        guard let eocdIndex = lastIndex(of: endOfCentralDirSignature, in: tail, recordLength: 22) else {
            throw ZipError.invalidArchive("Could not find End of Central Directory")
        }
        let eocdPosition = tailStart + UInt64(eocdIndex)

        var entryCount = UInt64(tail.u16(eocdIndex + 10) ?? 0)
        var cdSize = UInt64(tail.u32(eocdIndex + 12) ?? 0)
        var cdOffset = UInt64(tail.u32(eocdIndex + 16) ?? 0)
        var cdEnd = eocdPosition

        if let zip64 = try readZip64EndOfCentralDirectory(reader, eocdPosition: eocdPosition) {
            entryCount = zip64.entryCount
            cdSize = zip64.cdSize
            cdOffset = zip64.cdOffset
            cdEnd = zip64.position
        } else if cdOffset == UInt64(zip64MagicValue32) || cdSize == UInt64(zip64MagicValue32) {
            throw ZipError.invalidArchive("Zip64 archive but Zip64 structures not found")
        }

        guard cdSize <= Self.maxCentralDirectorySize else {
            throw ZipError.invalidArchive("Central directory is too large")
        }
        guard cdSize <= cdEnd, let statedStart = Int64(exactly: cdOffset) else {
            throw ZipError.invalidArchive("Invalid central directory offset")
        }

        // The central directory ends where the (Zip64) EOCD record starts. If the stated offset disagrees,
        // data was prepended (self-extracting archives) and every stored offset is shifted by the difference.
        var cdStart = cdEnd - cdSize
        var offsetAdjustment = Int64(cdStart) - statedStart
        if offsetAdjustment != 0 && cdSize > 0 && !hasSignature(centralDirFileHeaderSignature, in: reader, at: cdStart) {
            let (statedEnd, overflow) = cdOffset.addingReportingOverflow(cdSize)
            if !overflow && statedEnd <= fileSize && hasSignature(centralDirFileHeaderSignature, in: reader, at: cdOffset) {
                cdStart = cdOffset
                offsetAdjustment = 0
            }
        }
        if offsetAdjustment != 0 {
            zipLogger.info("Detected prepended data, offset adjustment: \(offsetAdjustment) bytes")
        }

        // One bounded read, then parse from memory
        let centralDirectory = try reader.bytes(at: cdStart, count: Int(cdSize))
        guard centralDirectory.count == Int(cdSize) else {
            throw ZipError.invalidArchive("Central directory is truncated")
        }

        let entries = parseCentralDirectory(centralDirectory, expectedCount: entryCount)
        return (entries, offsetAdjustment)
    }

    private func lastIndex(of signature: UInt32, in bytes: [UInt8], recordLength: Int) -> Int? {
        guard bytes.count >= recordLength else { return nil }
        for i in stride(from: bytes.count - recordLength, through: 0, by: -1) where bytes.u32(i) == signature {
            return i
        }
        return nil
    }

    private func hasSignature(_ signature: UInt32, in reader: ArchiveReader, at offset: UInt64) -> Bool {
        (try? reader.bytes(at: offset, count: 4))?.u32(0) == signature
    }

    private func readZip64EndOfCentralDirectory(_ reader: ArchiveReader, eocdPosition: UInt64) throws -> Zip64EndOfCentralDirectory? {
        // Zip64 EOCD Locator is 20 bytes and appears right before the regular EOCD
        guard eocdPosition >= 20 else {
            return nil
        }
        let locatorPosition = eocdPosition - 20
        let locator = try reader.bytes(at: locatorPosition, count: 20)
        guard locator.u32(0) == zip64EndOfCentralDirLocatorSignature,
              let statedOffset = locator.u64(8) else {
            return nil
        }

        // The record normally sits right before the locator; with prepended data the stated offset is shifted
        var candidates = [statedOffset]
        if locatorPosition >= 56 { candidates.append(locatorPosition - 56) }
        for position in candidates where position < locatorPosition {
            let record = try reader.bytes(at: position, count: 56)
            guard record.count == 56,
                  record.u32(0) == zip64EndOfCentralDirSignature,
                  let entryCount = record.u64(32),
                  let cdSize = record.u64(40),
                  let cdOffset = record.u64(48) else {
                continue
            }
            return Zip64EndOfCentralDirectory(position: position, entryCount: entryCount, cdSize: cdSize, cdOffset: cdOffset)
        }

        zipLogger.error("Zip64 EOCD locator found but the Zip64 EOCD record is missing")
        return nil
    }

    private func parseCentralDirectory(_ cd: [UInt8], expectedCount: UInt64) -> [ZipEntry] {
        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(min(expectedCount, UInt64(cd.count / 46))))
        var skippedEmpty = 0
        var skippedUnsafe = 0
        var dateCache: [UInt32: Date?] = [:]
        let calendar = Calendar.current

        var p = 0
        // The record count in the EOCD can't be trusted (it wraps at 65535 without Zip64), so parse until the data ends
        while cd.u32(p) == centralDirFileHeaderSignature {
            guard p + 46 <= cd.count else {
                zipLogger.error("Central directory header is truncated")
                break
            }
            let versionMadeBy = cd.u16(p + 4) ?? 0
            let flags = cd.u16(p + 8) ?? 0
            let compressionMethod = cd.u16(p + 10) ?? 0
            let modTime = cd.u16(p + 12) ?? 0
            let modDate = cd.u16(p + 14) ?? 0
            let crc32 = cd.u32(p + 16) ?? 0
            var compressedSize = UInt64(cd.u32(p + 20) ?? 0)
            var uncompressedSize = UInt64(cd.u32(p + 24) ?? 0)
            let fileNameLength = Int(cd.u16(p + 28) ?? 0)
            let extraFieldLength = Int(cd.u16(p + 30) ?? 0)
            let commentLength = Int(cd.u16(p + 32) ?? 0)
            let externalAttributes = cd.u32(p + 38) ?? 0
            var localHeaderOffset = UInt64(cd.u32(p + 42) ?? 0)

            let nameStart = p + 46
            let extraStart = nameStart + fileNameLength
            let recordEnd = extraStart + extraFieldLength + commentLength
            guard recordEnd <= cd.count else {
                zipLogger.error("Central directory record is truncated")
                break
            }
            // Always advance past the whole record (name, extra field and comment), even for skipped entries
            p = recordEnd

            guard fileNameLength > 0 else {
                skippedEmpty += 1
                continue
            }
            let nameBytes = cd[nameStart..<extraStart]

            let extra = parseExtraFields(
                cd,
                range: extraStart..<(extraStart + extraFieldLength),
                nameBytes: nameBytes,
                needUncompressedSize: uncompressedSize == UInt64(zip64MagicValue32),
                needCompressedSize: compressedSize == UInt64(zip64MagicValue32),
                needLocalHeaderOffset: localHeaderOffset == UInt64(zip64MagicValue32)
            )
            if let size = extra.uncompressedSize { uncompressedSize = size }
            if let size = extra.compressedSize { compressedSize = size }
            if let offset = extra.localHeaderOffset { localHeaderOffset = offset }

            var fileName = Self.decodeFilename(nameBytes, flags: flags, unicodePath: extra.unicodePath)

            // Directories normally end in "/", but some archivers only mark them in the attributes
            var isDirectory = fileName.hasSuffix("/")
            if !isDirectory {
                let host = versionMadeBy >> 8
                let unixMode = (host == 3 || host == 19) ? externalAttributes >> 16 : 0
                let unixDirectory = unixMode & UInt32(S_IFMT) == UInt32(S_IFDIR)
                let dosDirectory = unixMode == 0 && externalAttributes & 0x10 != 0 && uncompressedSize == 0
                if unixDirectory || dosDirectory {
                    isDirectory = true
                    fileName += "/"
                }
            }

            guard Self.isSafeEntryPath(fileName) else {
                skippedUnsafe += 1
                continue
            }

            // Get just the name (last component)
            let trimmed = isDirectory ? fileName.dropLast() : Substring(fileName)
            let name = String(trimmed.split(separator: "/").last ?? trimmed)

            let modificationDate: Date?
            if let date = extra.modificationDate {
                modificationDate = date
            } else {
                let key = UInt32(modDate) << 16 | UInt32(modTime)
                if let cached = dateCache[key] {
                    modificationDate = cached
                } else {
                    modificationDate = Self.dosDateTimeToDate(date: modDate, time: modTime, calendar: calendar)
                    dateCache[key] = modificationDate
                }
            }

            entries.append(ZipEntry(
                path: fileName,
                name: name,
                isDirectory: isDirectory,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                modificationDate: modificationDate,
                crc32: crc32,
                compressionMethod: compressionMethod,
                localHeaderOffset: localHeaderOffset,
                versionMadeBy: versionMadeBy,
                flags: flags,
                externalAttributes: externalAttributes
            ))
        }

        if skippedEmpty > 0 {
            zipLogger.warning("Skipped \(skippedEmpty) entries with empty names")
        }
        if skippedUnsafe > 0 {
            zipLogger.warning("Skipped \(skippedUnsafe) entries with unsafe paths")
        }
        if UInt64(entries.count + skippedEmpty + skippedUnsafe) != expectedCount {
            zipLogger.info("Central directory has \(entries.count + skippedEmpty + skippedUnsafe) records; EOCD declares \(expectedCount)")
        }
        return entries
    }

    private struct ExtraFieldInfo {
        var uncompressedSize: UInt64?
        var compressedSize: UInt64?
        var localHeaderOffset: UInt64?
        var unicodePath: String?
        var modificationDate: Date?
    }

    /// Parse the extra fields we use; every read is bounded by both the declared lengths and the actual data
    private func parseExtraFields(
        _ bytes: [UInt8],
        range: Range<Int>,
        nameBytes: ArraySlice<UInt8>,
        needUncompressedSize: Bool,
        needCompressedSize: Bool,
        needLocalHeaderOffset: Bool
    ) -> ExtraFieldInfo {
        var info = ExtraFieldInfo()
        let end = min(range.upperBound, bytes.count)
        var offset = range.lowerBound
        while offset + 4 <= end {
            let headerID = bytes.u16(offset) ?? 0
            let dataSize = Int(bytes.u16(offset + 2) ?? 0)
            let dataStart = offset + 4
            let dataEnd = min(dataStart + dataSize, end)

            switch headerID {
            case 0x0001:
                // Zip64 extended information: only the fields that were 0xFFFFFFFF, in this order
                var field = dataStart
                func next() -> UInt64? {
                    guard field + 8 <= dataEnd, let value = bytes.u64(field) else { return nil }
                    field += 8
                    return value
                }
                if needUncompressedSize { info.uncompressedSize = next() }
                if needCompressedSize { info.compressedSize = next() }
                if needLocalHeaderOffset { info.localHeaderOffset = next() }
            case 0x7075:
                // Info-ZIP Unicode Path: version 1, CRC-32 of the header name, UTF-8 name
                if dataEnd - dataStart > 5, bytes[dataStart] == 1, let nameCRC = bytes.u32(dataStart + 1) {
                    var crc = CRC32()
                    nameBytes.withUnsafeBytes { crc.update($0) }
                    if crc.value == nameCRC,
                       let path = String(bytes: bytes[(dataStart + 5)..<dataEnd], encoding: .utf8) {
                        info.unicodePath = path
                    }
                }
            case 0x5455:
                // Extended timestamp: flags, then the modification time (Unix seconds, UTC) if bit 0 is set
                if dataEnd - dataStart >= 5, bytes[dataStart] & 0x01 != 0, let seconds = bytes.u32(dataStart + 1) {
                    info.modificationDate = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: seconds)))
                }
            default:
                break
            }
            offset = dataStart + dataSize
        }
        return info
    }

    private static let cp437Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    /// Legacy multi-byte encoding for the user's language, tried before CP437 (e.g. Shift-JIS for Japanese)
    private static let localeLegacyEncoding: String.Encoding? = {
        guard let language = Locale.preferredLanguages.first?.lowercased() else { return nil }
        let encoding: CFStringEncodings
        if language.hasPrefix("ja") {
            encoding = .dosJapanese
        } else if language.hasPrefix("ko") {
            encoding = .dosKorean
        } else if language.hasPrefix("zh-hant") || language.hasPrefix("zh-tw") || language.hasPrefix("zh-hk") {
            encoding = .dosChineseTrad
        } else if language.hasPrefix("zh") {
            encoding = .dosChineseSimplif
        } else {
            return nil
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }()

    /// Decode a filename: the Unicode Path extra field, then UTF-8 (always when bit 11 is set, and whenever the
    /// bytes are valid UTF-8), then the user's legacy encoding, then CP437, the ZIP default
    static func decodeFilename<C: Collection>(_ bytes: C, flags: UInt16, unicodePath: String? = nil) -> String where C.Element == UInt8 {
        if let unicodePath {
            return unicodePath
        }
        if let utf8 = String(bytes: bytes, encoding: .utf8) {
            return utf8
        }
        let data = Data(bytes)
        if flags & 0x0800 == 0, let encoding = localeLegacyEncoding, let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let decoded = String(data: data, encoding: cp437Encoding) {
            return decoded
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func dosDateTimeToDate(date: UInt16, time: UInt16, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.year = Int((date >> 9) & 0x7F) + 1980
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int((time >> 11) & 0x1F)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int((time & 0x1F) * 2)

        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day),
              let hour = components.hour, hour < 24,
              let minute = components.minute, minute < 60,
              let second = components.second, second < 60 else {
            return nil
        }
        return calendar.date(from: components)
    }

    // MARK: - Extraction

    /// Extracts `entry` (not a link) to its preview location, or reuses an earlier extraction. The file and
    /// its folder are read-only, so an app it's opened in can't save edits into this temporary copy.
    private func extractPreviewFile(_ entry: ZipEntry, archiveURL: URL, reader: ArchiveReader, offsetAdjustment: Int64) throws -> URL {
        scheduleCleanupIfNeeded()
        let (folder, destination) = previewLocation(for: entry, archiveURL: archiveURL, stamp: reader.stamp)

        let lock = itemLock(for: folder)
        lock.lock()
        defer { lock.unlock() }
        markUsed(folder)

        // Files only appear under their final name once fully written and verified.
        // Reuse refreshes the folder's date so a later launch's cleanup sees it as recently used.
        if Self.fileType(atPath: destination.path) == S_IFREG {
            _ = utimes(folder.path, nil)
            return destination
        }

        try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // An earlier attempt may have left the folder behind (read-only, or without the file)
        if mkdir(folder.path, 0o700) != 0 {
            guard errno == EEXIST, Self.fileType(atPath: folder.path) == S_IFDIR, chmod(folder.path, 0o700) == 0 else {
                throw Self.posixFailure("Couldn't create folder")
            }
        }
        do {
            let quarantine = Self.quarantineAttribute(of: archiveURL)
            try writeFile(entry, reader: reader, offsetAdjustment: offsetAdjustment, to: destination,
                          attributes: Self.previewAttributes(for: entry, quarantine: quarantine), limits: .standard)
        } catch {
            rmdir(folder.path)
            throw error
        }
        _ = chmod(folder.path, 0o555)
        return destination
    }

    /// Where an opened entry is extracted: a folder named by a hash of the archive's identity and the entry's
    /// path, holding the file under its own name (which is what the app it opens in shows)
    private func previewLocation(for entry: ZipEntry, archiveURL: URL, stamp: FileStamp) -> (folder: URL, file: URL) {
        let key = "v2|\(archiveURL.standardizedFileURL.path)|\(stamp.size)|\(stamp.mtimeSeconds).\(stamp.mtimeNanoseconds)|\(stamp.inode)|\(entry.path)"
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let folder = extractionRoot.appendingPathComponent(hash, isDirectory: true)
        return (folder, folder.appendingPathComponent(entry.name, isDirectory: false))
    }

    private func makeOperationDirectory() throws -> URL {
        scheduleCleanupIfNeeded()
        let directory = copyRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        markUsed(directory)
        return directory
    }

    /// The entry a symbolic link entry points to, resolved inside the archive the way the file system would
    /// resolve it once extracted (links to links are followed). Throws if it leads out of the archive, to a
    /// folder or to nothing.
    private func resolveSymbolicLink(_ link: ZipEntry, in archive: CachedArchive, reader: ArchiveReader,
                                     offsetAdjustment: Int64) throws -> ZipEntry {
        let index = archive.index
        var resolved: [String] = []
        // The link itself is the last component, so it is followed like any other
        var pending = link.path.split(separator: "/").map(String.init)[...]
        var hops = 0
        while let component = pending.popFirst() {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !resolved.isEmpty else { throw ZipError.brokenSymbolicLink(link.path) }
                resolved.removeLast()
            default:
                resolved.append(component)
                let path = resolved.joined(separator: "/")
                let isLast = pending.allSatisfy { $0.isEmpty || $0 == "." }
                // A folder of the same name wins on the way (its contents are listed under it)
                guard let entry = index.entry(atPath: path), entry.isSymbolicLink,
                      isLast || index.entry(atPath: path + "/") == nil else { continue }
                hops += 1
                guard hops <= 32,
                      let target = try readSymbolicLinkTarget(entry, reader: reader, offsetAdjustment: offsetAdjustment),
                      !target.hasPrefix("/") else {
                    throw ZipError.brokenSymbolicLink(link.path)
                }
                resolved.removeLast()
                pending = (target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending)[...]
            }
        }

        let path = resolved.joined(separator: "/")
        if let entry = index.entry(atPath: path), !entry.isDirectory {
            return entry
        }
        if resolved.isEmpty || index.entry(atPath: path + "/") != nil {
            throw ZipError.cannotExtractDirectory
        }
        throw ZipError.brokenSymbolicLink(link.path)
    }

    /// A link entry's target text, or nil if it is too long or not text. Throws if the data can't be read.
    private func readSymbolicLinkTarget(_ entry: ZipEntry, reader: ArchiveReader, offsetAdjustment: Int64,
                                        limits: ZipExtractionLimits = .standard) throws -> String? {
        guard entry.uncompressedSize <= UInt64(PATH_MAX) else { return nil }
        var bytes: [UInt8] = []
        try streamEntryData(entry, reader: reader, offsetAdjustment: offsetAdjustment, limits: limits) { chunk in
            bytes.append(contentsOf: chunk)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// A folder's members to extract, in the order to write them (folders before their contents)
    private struct FolderPlan {
        var members: [(entry: ZipEntry, components: [String])] = []
        /// Duplicate entries the listing doesn't show (another entry has the same path)
        var failures: [ZipExtractionFailure] = []
        var totalBytes: UInt64 = 0
    }

    /// Plans extracting `folder` from the archive index, so a copied folder holds exactly what its listing
    /// (and opening its items) shows: the first of several entries with the same path, folders whose paths
    /// differ only in Unicode form merged. Hidden duplicates are reported as failures. Throws if the
    /// declared sizes exceed `limits.maxTotalBytes`.
    private func planFolderExtraction(_ folder: ZipEntry, index: ArchiveIndex, limits: ZipExtractionLimits) throws -> FolderPlan {
        var plan = FolderPlan()
        var folders: [(path: String, components: [String])] = [(folder.path, [])]
        while let (path, components) = folders.popLast() {
            // Files first: where a file (or link) and a folder share a name, the file is written and
            // everything in the folder is reported, so nothing is ever written through a link
            let children = index.children(of: path)
            for child in children.filter({ !$0.isDirectory }) + children.filter(\.isDirectory) {
                let childComponents = components + [child.name]
                let relativePath = childComponents.joined(separator: "/")
                // Duplicate folder entries just merge; a hidden file would be lost (or swapped in), so say so
                if index.hiddenDuplicates(of: child.path).contains(where: { !($0.isDirectory && child.isDirectory) }) {
                    plan.failures.append(ZipExtractionFailure(path: relativePath, error: ZipError.pathConflict(relativePath)))
                }
                plan.members.append((child, childComponents))
                if child.isDirectory {
                    folders.append((child.path, childComponents))
                } else {
                    // Declared sizes are enforced while streaming, so their sum bounds the total output
                    let (sum, overflow) = plan.totalBytes.addingReportingOverflow(child.uncompressedSize)
                    guard !overflow, sum <= limits.maxTotalBytes else {
                        throw ZipError.entryTooLarge(overflow ? .max : sum)
                    }
                    plan.totalBytes = sum
                }
            }
        }
        return plan
    }

    private func extractDirectory(
        _ directoryEntry: ZipEntry,
        plan: FolderPlan,
        archive: CachedArchive,
        reader: ArchiveReader,
        to root: URL,
        quarantine: Data?,
        limits: ZipExtractionLimits,
        progress: Progress? = nil
    ) throws -> [ZipExtractionFailure] {
        var failures = plan.failures
        progress?.totalUnitCount = Int64(clamping: max(1, plan.totalBytes))

        guard mkdir(root.path, 0o700) == 0 else {
            throw Self.posixFailure("Couldn't create folder")
        }
        if let quarantine {
            try Self.setQuarantine(quarantine, path: root.path)
        }

        var directories: [(components: [String], entry: ZipEntry)] = [([], directoryEntry)]
        for (entry, components) in plan.members {
            try Self.checkCancellation(progress)
            let relativePath = components.joined(separator: "/")
            do {
                if entry.isDirectory {
                    _ = try makeDirectories(components, under: root, quarantine: quarantine)
                    directories.append((components, entry))
                    continue
                }

                let parent = try makeDirectories(Array(components.dropLast()), under: root, quarantine: quarantine)
                let destination = parent.appendingPathComponent(components[components.count - 1], isDirectory: false)
                guard Self.isContained(destination, in: root) else {
                    throw ZipError.unsafeEntryPath(relativePath)
                }

                // Never replaces what an earlier member wrote: names the file system considers the
                // same (case, Unicode form) are reported as conflicts
                if entry.isSymbolicLink {
                    try writeSymbolicLink(entry, reader: reader, offsetAdjustment: archive.offsetAdjustment,
                                          components: components, to: destination,
                                          quarantine: quarantine, limits: limits, progress: progress)
                } else {
                    try writeFile(entry, reader: reader, offsetAdjustment: archive.offsetAdjustment, to: destination,
                                  attributes: Self.fileAttributes(for: entry, quarantine: quarantine, restoreDate: true),
                                  limits: limits, exclusive: true, progress: progress)
                }
            } catch let error where Self.isCancellation(error) {
                throw error
            } catch {
                failures.append(ZipExtractionFailure(path: relativePath, error: error))
            }
        }

        // Folder modes and dates go last (deepest first): adding children changes a folder's mtime,
        // and a read-only mode would block them
        for (components, entry) in directories.sorted(by: { $0.components.count > $1.components.count }) {
            let url = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            Self.applyDirectoryAttributes(of: entry, at: url.path)
        }

        return failures
    }

    /// Returns `components` below `root`, creating missing folders. Never passes through anything that
    /// isn't a real folder (such as a symlink written by an earlier entry).
    private func makeDirectories(_ components: [String], under root: URL, quarantine: Data?) throws -> URL {
        var url = root
        for (index, component) in components.enumerated() {
            url = url.appendingPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw ZipError.pathConflict(components[...index].joined(separator: "/"))
                }
                continue
            }
            guard errno == ENOENT else {
                throw Self.posixFailure("Couldn't create folder")
            }
            guard mkdir(url.path, 0o700) == 0 else {
                throw Self.posixFailure("Couldn't create folder")
            }
            if let quarantine {
                try Self.setQuarantine(quarantine, path: url.path)
            }
        }
        return url
    }

    private struct OutputAttributes {
        var quarantine: Data?
        var mode: mode_t
        var modificationDate: Date?
    }

    private static func fileAttributes(for entry: ZipEntry, quarantine: Data?, restoreDate: Bool) -> OutputAttributes {
        var mode: mode_t = 0o644
        if let unixMode = entry.unixMode, !entry.isSymbolicLink, unixMode & 0o777 != 0 {
            // Drop setuid/setgid/sticky; keep it readable by the owner so it can be copied
            mode = mode_t(truncatingIfNeeded: unixMode & 0o777) | 0o400
        }
        return OutputAttributes(quarantine: quarantine, mode: mode, modificationDate: restoreDate ? entry.modificationDate : nil)
    }

    /// Opened entries are read-only (r--r--r--, keeping execute bits)
    private static func previewAttributes(for entry: ZipEntry, quarantine: Data?) -> OutputAttributes {
        var mode: mode_t = 0o444
        if let unixMode = entry.unixMode, !entry.isSymbolicLink, unixMode & 0o777 != 0 {
            mode |= mode_t(truncatingIfNeeded: unixMode & 0o111)
        }
        return OutputAttributes(quarantine: quarantine, mode: mode, modificationDate: nil)
    }

    private static func applyDirectoryAttributes(of entry: ZipEntry, at path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }

        if let date = entry.modificationDate {
            var times = [timespec(date), timespec(date)]
            _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
        }
        var mode: mode_t = 0o755
        if let unixMode = entry.unixMode, unixMode & 0o777 != 0 {
            // Always owner-writable so the temporary copy can be cleaned up
            mode = mode_t(truncatingIfNeeded: unixMode & 0o777) | 0o700
        }
        _ = chmod(path, mode)
    }

    /// Write `entry` to `destination` through a temporary file in the same folder that is renamed into place
    /// only after its size and CRC-32 have been verified, so no partial file is ever visible.
    /// With `exclusive`, an existing item at `destination` is not replaced (`ZipError.pathConflict`).
    private func writeFile(
        _ entry: ZipEntry,
        reader: ArchiveReader,
        offsetAdjustment: Int64,
        to destination: URL,
        attributes: OutputAttributes,
        limits: ZipExtractionLimits,
        exclusive: Bool = false,
        progress: Progress? = nil
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".flowfinder-\(UUID().uuidString).part", isDirectory: false)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw Self.posixFailure("Couldn't create file")
        }

        var isOpen = true
        do {
            try streamEntryData(entry, reader: reader, offsetAdjustment: offsetAdjustment, limits: limits, progress: progress) { chunk in
                try Self.writeAll(fd, chunk)
            }
            if let quarantine = attributes.quarantine {
                let result = quarantine.withUnsafeBytes {
                    fsetxattr(fd, Self.quarantineAttributeName, $0.baseAddress, quarantine.count, 0, 0)
                }
                guard result == 0 else { throw Self.posixFailure("Couldn't set quarantine attribute") }
            }
            if let date = attributes.modificationDate {
                var times = [timespec(date), timespec(date)]
                _ = futimens(fd, &times)
            }
            guard fchmod(fd, attributes.mode) == 0 else {
                throw Self.posixFailure("Couldn't set permissions")
            }
            isOpen = false
            guard close(fd) == 0 else {
                throw Self.posixFailure("Couldn't write file")
            }
            try Self.moveIntoPlace(temporary.path, destination, exclusive: exclusive)
        } catch {
            if isOpen { close(fd) }
            unlink(temporary.path)
            throw error
        }
    }

    /// Renames a finished temporary item to `destination`. With `exclusive`, an item already there — which
    /// may have a name the file system merely considers equal (other case or Unicode form) — is kept.
    private static func moveIntoPlace(_ temporary: String, _ destination: URL, exclusive: Bool) throws {
        if exclusive {
            if renamex_np(temporary, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
            let code = errno
            if code == EEXIST {
                throw ZipError.pathConflict(destination.lastPathComponent)
            }
            // File systems without RENAME_EXCL: check, then rename (the folder is private to this operation)
            guard code == ENOTSUP || code == EINVAL else {
                throw posixFailure("Couldn't move item into place", code)
            }
            if fileType(atPath: destination.path) != nil {
                throw ZipError.pathConflict(destination.lastPathComponent)
            }
        }
        guard rename(temporary, destination.path) == 0 else {
            throw posixFailure("Couldn't move item into place")
        }
    }

    /// Create a symlink only if its target stays inside the extraction root; otherwise keep the target text as
    /// a regular file. Never replaces an existing item.
    private func writeSymbolicLink(
        _ entry: ZipEntry,
        reader: ArchiveReader,
        offsetAdjustment: Int64,
        components: [String],
        to destination: URL,
        quarantine: Data?,
        limits: ZipExtractionLimits,
        progress: Progress? = nil
    ) throws {
        let target = try readSymbolicLinkTarget(entry, reader: reader, offsetAdjustment: offsetAdjustment, limits: limits)
        guard let target, Self.isSafeSymlinkTarget(target, linkComponents: components) else {
            try writeFile(entry, reader: reader, offsetAdjustment: offsetAdjustment, to: destination,
                          attributes: Self.fileAttributes(for: entry, quarantine: quarantine, restoreDate: true),
                          limits: limits, exclusive: true, progress: progress)
            return
        }

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".flowfinder-\(UUID().uuidString).part", isDirectory: false)
        guard symlink(target, temporary.path) == 0 else {
            throw Self.posixFailure("Couldn't create symbolic link")
        }
        do {
            try Self.moveIntoPlace(temporary.path, destination, exclusive: true)
        } catch {
            unlink(temporary.path)
            throw error
        }
        progress?.completedUnitCount += Int64(clamping: entry.uncompressedSize)
    }

    /// Stream an entry's uncompressed bytes to `sink` in bounded chunks, verifying size and CRC-32.
    /// Throws (after the sink may have received some data) if the entry is unsupported, too large or corrupt,
    /// or `CocoaError.userCancelled` once `progress` is cancelled; each chunk advances `progress`.
    private func streamEntryData(
        _ entry: ZipEntry,
        reader: ArchiveReader,
        offsetAdjustment: Int64,
        limits: ZipExtractionLimits,
        progress: Progress? = nil,
        sink: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        guard !entry.isEncrypted else {
            throw ZipError.encryptedEntry
        }
        guard entry.compressionMethod == 0 || entry.compressionMethod == 8 else {
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
        guard entry.uncompressedSize <= limits.maxEntryBytes else {
            throw ZipError.entryTooLarge(entry.uncompressedSize)
        }

        let (dataStart, dataLength) = try locateEntryData(entry, reader: reader, offsetAdjustment: offsetAdjustment)

        var crc = CRC32()
        var written: UInt64 = 0
        func emit(_ chunk: UnsafeRawBufferPointer) throws {
            try Self.checkCancellation(progress)
            guard UInt64(chunk.count) <= entry.uncompressedSize - written else {
                throw ZipError.corruptData("Entry expands beyond its declared size")
            }
            crc.update(chunk)
            try sink(chunk)
            written += UInt64(chunk.count)
            progress?.completedUnitCount += Int64(chunk.count)
        }

        let chunkSize = 256 * 1024
        let input = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { input.deallocate() }

        if entry.compressionMethod == 0 {
            guard dataLength == entry.uncompressedSize else {
                throw ZipError.corruptData("Stored entry sizes don't match")
            }
            var offset = dataStart
            var remaining = dataLength
            while remaining > 0 {
                let count = Int(min(UInt64(chunkSize), remaining))
                guard try reader.read(into: input, count: count, at: offset) == count else {
                    throw ZipError.corruptData("Entry data is truncated")
                }
                try emit(UnsafeRawBufferPointer(start: input, count: count))
                offset += UInt64(count)
                remaining -= UInt64(count)
            }
        } else if dataLength > 0 {
            try inflate(reader: reader, start: dataStart, length: dataLength, input: input, chunkSize: chunkSize, emit: emit)
        }

        guard written == entry.uncompressedSize else {
            throw ZipError.corruptData("Entry is smaller than its declared size")
        }
        guard crc.value == entry.crc32 else {
            throw ZipError.corruptData("CRC-32 checksum mismatch")
        }
    }

    /// Raw-deflate decode with compression_stream (COMPRESSION_ZLIB is raw DEFLATE, as used by ZIP)
    private func inflate(
        reader: ArchiveReader,
        start: UInt64,
        length: UInt64,
        input: UnsafeMutableRawPointer,
        chunkSize: Int,
        emit: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let output = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { output.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.extractionFailed("Couldn't start decompression")
        }
        defer { compression_stream_destroy(stream) }

        let inputBytes = input.assumingMemoryBound(to: UInt8.self)
        let outputBytes = output.assumingMemoryBound(to: UInt8.self)
        var offset = start
        var remaining = length
        stream.pointee.src_ptr = UnsafePointer(inputBytes)
        stream.pointee.src_size = 0

        while true {
            if stream.pointee.src_size == 0 && remaining > 0 {
                let count = Int(min(UInt64(chunkSize), remaining))
                guard try reader.read(into: input, count: count, at: offset) == count else {
                    throw ZipError.corruptData("Compressed data is truncated")
                }
                offset += UInt64(count)
                remaining -= UInt64(count)
                stream.pointee.src_ptr = UnsafePointer(inputBytes)
                stream.pointee.src_size = count
            }

            let pendingInput = stream.pointee.src_size
            stream.pointee.dst_ptr = outputBytes
            stream.pointee.dst_size = chunkSize
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            let produced = chunkSize - stream.pointee.dst_size
            if produced > 0 {
                try emit(UnsafeRawBufferPointer(start: output, count: produced))
            }

            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                if produced == 0 && stream.pointee.src_size == pendingInput {
                    throw ZipError.corruptData("Compressed data ended unexpectedly")
                }
            default:
                throw ZipError.corruptData("Compressed data is corrupt")
            }
        }
    }

    /// Locate an entry's compressed bytes via its local header; every offset is checked against the file size
    private func locateEntryData(_ entry: ZipEntry, reader: ArchiveReader, offsetAdjustment: Int64) throws -> (start: UInt64, length: UInt64) {
        guard let statedOffset = Int64(exactly: entry.localHeaderOffset) else {
            throw ZipError.invalidArchive("Local header offset is out of range")
        }
        let (adjustedOffset, overflow) = statedOffset.addingReportingOverflow(offsetAdjustment)
        guard !overflow, adjustedOffset >= 0 else {
            throw ZipError.invalidArchive("Local header offset is out of range")
        }

        let headerOffset = UInt64(adjustedOffset)
        let header = try reader.bytes(at: headerOffset, count: 30)
        guard header.count == 30 else {
            throw ZipError.invalidArchive("Local file header is truncated")
        }
        guard header.u32(0) == localFileHeaderSignature,
              let fileNameLength = header.u16(26),
              let extraFieldLength = header.u16(28) else {
            throw ZipError.invalidArchive("Invalid local file header signature")
        }

        let dataStart = headerOffset + 30 + UInt64(fileNameLength) + UInt64(extraFieldLength)
        let (dataEnd, endOverflow) = dataStart.addingReportingOverflow(entry.compressedSize)
        guard !endOverflow, dataEnd <= reader.size else {
            throw ZipError.invalidArchive("Entry data extends past the end of the file")
        }
        return (dataStart, entry.compressedSize)
    }

    // MARK: - Quarantine & POSIX Helpers

    private static let quarantineAttributeName = "com.apple.quarantine"

    /// The archive's quarantine attribute, copied onto everything extracted from it (as Archive Utility does)
    static func quarantineAttribute(of url: URL) -> Data? {
        let path = url.path
        let size = getxattr(path, quarantineAttributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, quarantineAttributeName, $0.baseAddress, size, 0, 0) }
        guard read > 0 else { return nil }
        return data.prefix(read)
    }

    private static func setQuarantine(_ data: Data, path: String) throws {
        let result = data.withUnsafeBytes {
            setxattr(path, quarantineAttributeName, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else {
            throw posixFailure("Couldn't set quarantine attribute")
        }
    }

    private static func writeAll(_ fd: Int32, _ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, base + offset, buffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw posixFailure("Couldn't write file")
            }
            offset += written
        }
    }

    private static func posixFailure(_ action: String, _ code: Int32 = errno) -> ZipError {
        .extractionFailed("\(action) (\(String(cString: strerror(code))))")
    }
}

// MARK: - Supporting Types

private struct Zip64EndOfCentralDirectory {
    let position: UInt64
    let entryCount: UInt64
    let cdSize: UInt64
    let cdOffset: UInt64
}

private struct FileStamp: Hashable {
    let size: UInt64
    let mtimeSeconds: Int
    let mtimeNanoseconds: Int
    let inode: UInt64
    let device: Int32
}

/// Read-only access to an archive through a file descriptor. pread keeps reads independent of other threads.
private final class ArchiveReader {
    let fd: Int32
    let size: UInt64
    let stamp: FileStamp

    init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw ZipError.invalidArchive("Couldn't open the archive (\(String(cString: strerror(errno))))")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw ZipError.invalidArchive("Not a regular file")
        }
        self.fd = fd
        size = UInt64(max(0, info.st_size))
        stamp = FileStamp(size: size,
                          mtimeSeconds: info.st_mtimespec.tv_sec,
                          mtimeNanoseconds: info.st_mtimespec.tv_nsec,
                          inode: info.st_ino,
                          device: info.st_dev)
    }

    deinit {
        close(fd)
    }

    /// Read up to `count` bytes at `offset`; returns fewer only at the end of the file
    func read(into buffer: UnsafeMutableRawPointer, count: Int, at offset: UInt64) throws -> Int {
        guard offset < size, count > 0 else { return 0 }
        let count = Int(min(UInt64(count), size - offset))
        var total = 0
        while total < count {
            let result = pread(fd, buffer + total, count - total, off_t(offset) + off_t(total))
            if result < 0 {
                if errno == EINTR { continue }
                throw ZipError.invalidArchive("Read error (\(String(cString: strerror(errno))))")
            }
            if result == 0 { break }
            total += result
        }
        return total
    }

    func bytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard offset < size, count > 0 else { return [] }
        let count = Int(min(UInt64(count), size - offset))
        var result = [UInt8](repeating: 0, count: count)
        let read = try result.withUnsafeMutableBytes { try self.read(into: $0.baseAddress!, count: count, at: offset) }
        if read < count { result.removeLast(count - read) }
        return result
    }
}

/// Path → entry and folder → children lookups for one archive, built once (O(n)) so listing a folder is O(children).
/// The single source of truth for which entry a path means — listing, opening and copying all go through it.
/// Paths are Swift strings, so Unicode-equivalent forms (NFC/NFD) are the same path; the first entry for a
/// path wins and later ones are kept aside as hidden duplicates.
private final class ArchiveIndex: @unchecked Sendable {
    private let entriesByPath: [String: ZipEntry]
    private let childrenByDirectory: [String: [ZipEntry]]
    private let hiddenByPath: [String: [ZipEntry]]
    private var sortedChildren: [String: [ZipEntry]] = [:]
    private let lock = NSLock()

    init(entries: [ZipEntry]) {
        var byPath: [String: ZipEntry] = [:]
        var hidden: [String: [ZipEntry]] = [:]
        byPath.reserveCapacity(entries.count)
        for entry in entries {
            if byPath[entry.path] == nil {
                byPath[entry.path] = entry
            } else {
                hidden[entry.path, default: []].append(entry)
            }
        }
        hiddenByPath = hidden

        // Synthesize folders that only exist implicitly (e.g. "a/" for "a/b.txt")
        for path in Array(byPath.keys) {
            var parent = Self.parentPath(of: path)
            while !parent.isEmpty && byPath[parent] == nil {
                byPath[parent] = ZipEntry(
                    path: parent,
                    name: Self.lastComponent(of: parent),
                    isDirectory: true,
                    compressedSize: 0,
                    uncompressedSize: 0,
                    modificationDate: nil,
                    crc32: 0,
                    compressionMethod: 0,
                    localHeaderOffset: 0
                )
                parent = Self.parentPath(of: parent)
            }
        }

        var children: [String: [ZipEntry]] = [:]
        for (path, entry) in byPath {
            children[Self.parentPath(of: path), default: []].append(entry)
        }
        entriesByPath = byPath
        childrenByDirectory = children
    }

    func entry(atPath path: String) -> ZipEntry? {
        entriesByPath[path]
    }

    /// Later entries with the same path as the one `entry(atPath:)` returns
    func hiddenDuplicates(of path: String) -> [ZipEntry] {
        hiddenByPath[path] ?? []
    }

    /// Children of a folder path ("" for the root, otherwise ending in "/"): directories first, then by name
    func children(of directory: String) -> [ZipEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let sorted = sortedChildren[directory] {
            return sorted
        }
        let sorted = (childrenByDirectory[directory] ?? []).sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch a.name.localizedCaseInsensitiveCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.name < b.name  // e.g. "Notes" and "notes": a stable order
            }
        }
        sortedChildren[directory] = sorted
        return sorted
    }

    static func parentPath(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? path.dropLast() : Substring(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    static func lastComponent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? path.dropLast() : Substring(path)
        return String(trimmed.split(separator: "/").last ?? trimmed)
    }
}

/// Identifies one parsed entries array (entry IDs are fresh UUIDs on every parse)
private struct EntriesFingerprint: Hashable {
    let count: Int
    let first: UUID?
    let middle: UUID?
    let last: UUID?

    init(_ entries: [ZipEntry]) {
        count = entries.count
        first = entries.first?.id
        middle = entries.isEmpty ? nil : entries[entries.count / 2].id
        last = entries.last?.id
    }
}

private struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []   // Least recently used first

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func value(forKey key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func setValue(_ value: Value, forKey key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            storage[order.removeFirst()] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}

/// Table-driven CRC-32 (IEEE 802.3, as used by ZIP), slice-by-8
private struct CRC32 {
    /// 8 tables of 256: table k maps a byte to its CRC contribution k bytes further along
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for index in 0..<256 {
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            tables[index] = c
        }
        for k in 1..<8 {
            for index in 0..<256 {
                let previous = tables[(k - 1) * 256 + index]
                tables[k * 256 + index] = (previous >> 8) ^ tables[Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    private var state: UInt32 = 0xFFFFFFFF

    var value: UInt32 { state ^ 0xFFFFFFFF }

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var c = state
        Self.tables.withUnsafeBufferPointer { t in
            var offset = 0
            while offset + 8 <= buffer.count {
                let low = c ^ UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let high = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                c = t[7 * 256 + Int(low & 0xFF)] ^ t[6 * 256 + Int((low >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((low >> 16) & 0xFF)] ^ t[4 * 256 + Int(low >> 24)]
                    ^ t[3 * 256 + Int(high & 0xFF)] ^ t[2 * 256 + Int((high >> 8) & 0xFF)]
                    ^ t[256 + Int((high >> 16) & 0xFF)] ^ t[Int(high >> 24)]
                offset += 8
            }
            while offset < buffer.count {
                c = t[Int((c ^ UInt32(buffer[offset])) & 0xFF)] ^ (c >> 8)
                offset += 1
            }
        }
        state = c
    }
}

private extension Array where Element == UInt8 {
    /// Little-endian integer of `width` bytes at `offset`, or nil if out of bounds
    func littleEndian(at offset: Int, width: Int) -> UInt64? {
        guard offset >= 0, offset <= count - width else { return nil }
        var value: UInt64 = 0
        for i in stride(from: width - 1, through: 0, by: -1) {
            value = value << 8 | UInt64(self[offset + i])
        }
        return value
    }

    func u16(_ offset: Int) -> UInt16? { littleEndian(at: offset, width: 2).map { UInt16(truncatingIfNeeded: $0) } }
    func u32(_ offset: Int) -> UInt32? { littleEndian(at: offset, width: 4).map { UInt32(truncatingIfNeeded: $0) } }
    func u64(_ offset: Int) -> UInt64? { littleEndian(at: offset, width: 8) }
}

private extension timespec {
    init(_ date: Date) {
        let interval = date.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        self.init(tv_sec: Int(seconds), tv_nsec: Int((interval - seconds) * 1_000_000_000))
    }
}

enum ZipError: LocalizedError {
    case invalidArchive(String)
    case cannotExtractDirectory
    case unsupportedCompression(UInt16)
    case extractionFailed(String)
    case encryptedEntry
    case entryNotFound(String)
    case unsafeEntryPath(String)
    case entryTooLarge(UInt64)
    case corruptData(String)
    case pathConflict(String)
    case brokenSymbolicLink(String)
    case insufficientSpace(needed: UInt64, available: UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason):
            return "Invalid ZIP archive: \(reason)"
        case .cannotExtractDirectory:
            return "Cannot extract a directory"
        case .unsupportedCompression(let method):
            return "Unsupported compression method: \(Self.compressionMethodName(method))"
        case .extractionFailed(let reason):
            return "Extraction failed: \(reason)"
        case .encryptedEntry:
            return "The item is encrypted; password-protected ZIP entries aren't supported"
        case .entryNotFound(let path):
            return "“\(path)” is no longer in the archive"
        case .unsafeEntryPath(let path):
            return "“\(path)” has an unsafe path and was skipped"
        case .entryTooLarge(let size):
            return "Too large to extract (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)))"
        case .corruptData(let reason):
            return "The archive data is corrupt: \(reason)"
        case .pathConflict(let path):
            return "“\(path)” conflicts with another item in the archive"
        case .brokenSymbolicLink(let path):
            return "“\(path)” is a symbolic link to an item that isn’t in the archive"
        case .insufficientSpace(let needed, let available):
            let format = { (bytes: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file) }
            return "There isn’t enough free space to extract it (\(format(needed)) needed, \(format(available)) available)"
        }
    }

    static func compressionMethodName(_ method: UInt16) -> String {
        switch method {
        case 1: return "Shrink (1)"
        case 6: return "Implode (6)"
        case 9: return "Deflate64 (9)"
        case 12: return "bzip2 (12)"
        case 14: return "LZMA (14)"
        case 93: return "Zstandard (93)"
        case 95: return "XZ (95)"
        case 98: return "PPMd (98)"
        case 99: return "AES encryption (99)"
        default: return "\(method)"
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
                size: Int64(clamping: entry.uncompressedSize),
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

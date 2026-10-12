import Foundation
import AppKit
import SevenZipKit

/// Every engine object, including its destruction, stays on this queue. Swift values and
/// caller-owned byte writers cross the boundary; extraction never lets the engine write members to disk.
final class SevenZipArchiveBackend: @unchecked Sendable {
    static let shared = SevenZipArchiveBackend()
    private let queue = DispatchQueue(label: "com.flowfinder.archive.engine", qos: .userInitiated)
    private struct Session {
        let archive: SZArchive
        let revision: String
    }
    private var sessions: [URL: Session] = [:]
    private var order: [URL] = []
    private var passwordProvider: ((String) -> String?)?

    /// Tests and other hosts can supply a password UI. Nil restores the app's secure prompt.
    func setPasswordProvider(_ provider: ((String) -> String?)?, resetSessions: Bool = true) {
        queue.sync {
            passwordProvider = provider
            if resetSessions { sessions.removeAll(); order.removeAll() }
        }
    }
    static let decoderMemoryLimit: UInt64 = 512 << 20

    private func session(at url: URL, revision: String, delegate: EngineProgress) throws -> SZArchive {
        let key = url.standardizedFileURL
        if let session = sessions[key], session.revision == revision {
            order.removeAll { $0 == key }; order.append(key)
            return session.archive
        }
        sessions.removeValue(forKey: key)
        let archive = try SZArchiveOpener.openArchive(atPath: url.path, formatHint: nil,
                                                      passwordDelegate: delegate, progress: delegate)
        sessions[key] = Session(archive: archive, revision: revision)
        order.removeAll { $0 == key }; order.append(key)
        while order.count > 8 {
            sessions.removeValue(forKey: order.removeFirst())
        }
        return archive
    }

    func entries(at url: URL, revision: String, progress: Progress?, allowPasswordPrompt: Bool) throws -> [ArchiveEntry] {
        try queue.sync {
            let delegate = EngineProgress(progress: progress, allowPasswordPrompt: allowPasswordPrompt, passwordProvider: passwordProvider)
            do {
                let archive = try session(at: url, revision: revision, delegate: delegate)
                let raw = try archive.streamEntries(limit: 250_000, progress: delegate)
                let byPath = Dictionary(raw.map { ($0["path"] as? String ?? "", $0) }, uniquingKeysWith: { first, _ in first })
                return raw.compactMap { item in
                    var path = item["path"] as? String ?? url.deletingPathExtension().lastPathComponent
                    let directory = (item["directory"] as? NSNumber)?.boolValue ?? false
                    path = path.replacingOccurrences(of: "\\", with: "/")
                    if directory && !path.hasSuffix("/") { path += "/" }
                    guard ArchiveManager.isSafeEntryPath(path) else { return nil }
                    // TAR hard links point to another archive member. Copy its verified data;
                    // never ask the engine to create a link or follow a filesystem path.
                    var content = item
                    var seen = Set<String>()
                    var brokenHardLink: String?
                    while let target = content["hardlink"] as? String {
                        guard ArchiveManager.isSafeEntryPath(target), seen.insert(target).inserted,
                              seen.count <= 40, let next = byPath[target],
                              (next["directory"] as? NSNumber)?.boolValue != true,
                              next["symlink"] == nil else { brokenHardLink = target; break }
                        content = next
                    }
                    let attributes = (item["attributes"] as? NSNumber)?.uint32Value ?? 0
                    let mode = (item["mode"] as? NSNumber)?.uint32Value
                        ?? (attributes & 0x8000 != 0 ? attributes >> 16 : 0)
                    let linkTarget = item["symlink"] as? String
                    var entry = ArchiveEntry(path: path, name: path.split(separator: "/").last.map(String.init) ?? path,
                        isDirectory: directory,
                        compressedSize: (content["packedSize"] as? NSNumber)?.uint64Value ?? 0,
                        uncompressedSize: linkTarget.map { UInt64($0.utf8.count) }
                            ?? (content["size"] as? NSNumber)?.uint64Value ?? 0,
                        modificationDate: item["modified"] as? Date,
                        crc32: (content["crc"] as? NSNumber)?.uint32Value ?? 0,
                        compressionMethod: 0, localHeaderOffset: 0, versionMadeBy: 3 << 8,
                        flags: (content["encrypted"] as? NSNumber)?.boolValue == true ? 1 : 0,
                        externalAttributes: mode << 16)
                    entry.engineIndex = (content["index"] as? NSNumber)?.uint32Value
                    entry.engineLinkTarget = linkTarget
                    entry.engineBrokenHardLink = brokenHardLink
                    entry.engineSizeUnknown = content["size"] == nil
                    return entry
                }
            } catch {
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                throw error
            }
        }
    }

    func stream(_ entry: ArchiveEntry, at url: URL, revision: String, maxBytes: UInt64,
                progress: Progress?, allowPasswordPrompt: Bool,
                sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        try withoutActuallyEscaping(sink) { escapedSink in
            try queue.sync {
            let delegate = EngineProgress(progress: progress, allowPasswordPrompt: allowPasswordPrompt, passwordProvider: passwordProvider)
            if let target = entry.engineLinkTarget {
                let data = Data(target.utf8)
                guard data.count <= PATH_MAX, UInt64(data.count) <= maxBytes else { throw ArchiveError.entryTooLarge(UInt64(data.count)) }
                try data.withUnsafeBytes(escapedSink)
                return
            }
            if entry.engineBrokenHardLink != nil { throw ArchiveError.brokenSymbolicLink(entry.path) }
            guard let index = entry.engineIndex else { throw ArchiveError.entryNotFound(entry.path) }
            var sinkError: Error?
            do {
                let archive = try session(at: url, revision: revision, delegate: delegate)
                try archive.streamItem(at: index, maxBytes: maxBytes,
                                       memoryLimit: Self.decoderMemoryLimit, progress: delegate) { data in
                    do { try data.withUnsafeBytes(escapedSink); return true }
                    catch { sinkError = error; return false }
                }
            } catch {
                if let sinkError { throw sinkError }
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                throw error
            }
            if let sinkError { throw sinkError }
            }
        }
    }

    func test(at url: URL, revision: String, progress: Progress) throws {
        try queue.sync {
            let delegate = EngineProgress(progress: progress, allowPasswordPrompt: true, passwordProvider: passwordProvider, reportsProgress: true)
            do {
                let archive = try session(at: url, revision: revision, delegate: delegate)
                try archive.test(memoryLimit: Self.decoderMemoryLimit, progress: delegate)
            }
            catch {
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                throw error
            }
        }
    }

    /// Creates only a fresh archive in caller-owned staging. Publishing is a separate file operation.
    func createArchive(at url: URL, sources: [URL], format: ArchiveCompressionFormat, progress: Progress) throws {
        try queue.sync {
            let delegate = EngineProgress(progress: progress, allowPasswordPrompt: true,
                                          passwordProvider: nil, reportsProgress: true)
            do {
                guard !FileOperationEngine.itemExists(at: url), !sources.isEmpty else {
                    throw FileOperationEngine.makeError("Choose files or folders and a new archive name.")
                }
                if delegate.progressCheckBreak() { throw CocoaError(.userCancelled) }
                let options = SZUpdateOptions(archivePath: url.path)
                options.formatName = format.rawValue
                options.nameMode = .exact
                options.pathMode = .relative
                options.workingDirectory = ""
                options.deleteAfterCompressing = false
                options.stopAfterOpenError = true
                options.storeSymLinks = true
                options.properties = [SZUpdateProperty(name: "x", value: "5"), SZUpdateProperty(name: "mt", value: "2")]
                if format == .zip {
                    options.properties.append(SZUpdateProperty(name: "m", value: "Deflate"))
                } else {
                    options.properties += [SZUpdateProperty(name: "0", value: "LZMA2"), SZUpdateProperty(name: "0d", value: "16m")]
                }
                let result = try SZUpdater.update(with: options, sourcePaths: sources.map(\.path), progress: delegate)
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                guard result.errorCount == 0, result.failedPaths.isEmpty else {
                    let detail = result.failedPaths.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                    throw FileOperationEngine.makeError("Some items could not be read. The archive was not created." + (detail.isEmpty ? "" : "\n" + detail))
                }
                guard URL(fileURLWithPath: result.archivePath).standardizedFileURL == url.standardizedFileURL,
                      FileOperationEngine.itemExists(at: url) else {
                    throw FileOperationEngine.makeError("The compression engine did not create the requested archive.")
                }
            } catch {
                if delegate.cancelled { throw CocoaError(.userCancelled) }
                throw error
            }
        }
    }
}

private final class EngineProgress: NSObject, SZProgressDelegate, SZPasswordDelegate {
    let progress: Progress?
    let allowPasswordPrompt: Bool
    private let passwordProvider: ((String) -> String?)?
    private let reportsProgress: Bool
    private let lock = NSLock()
    private var didCancel = false
    private let deadline: Date?
    private var decodedBytes: UInt64 = 0
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return didCancel || progress?.isCancelled == true }

    init(progress: Progress?, allowPasswordPrompt: Bool,
         passwordProvider: ((String) -> String?)?, reportsProgress: Bool = false) {
        self.progress = progress
        self.allowPasswordPrompt = allowPasswordPrompt
        self.passwordProvider = passwordProvider
        self.reportsProgress = reportsProgress
        deadline = allowPasswordPrompt ? nil : Date().addingTimeInterval(2)
    }

    func passwordForArchive(atPath path: String) -> String? { progressAskPassword(forPath: path) }
    func progressAskPassword(forPath path: String) -> String? {
        guard allowPasswordPrompt, !cancelled else { return nil }
        let ask = { () -> String? in
            let alert = NSAlert()
            alert.messageText = "Archive Password"
            alert.informativeText = "Enter the password for “\((path as NSString).lastPathComponent)”."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Password"
            alert.accessoryView = field
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        let password: String?
        if let passwordProvider { password = passwordProvider(path) }
        else { password = Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask) }
        if password == nil { lock.lock(); didCancel = true; lock.unlock() }
        return password
    }
    func progressCheckBreak() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if progress?.isCancelled == true || deadline.map({ Date() >= $0 }) == true ||
            (!allowPasswordPrompt && decodedBytes > 128 << 20) { didCancel = true }
        return didCancel
    }
    func progressSetTotal(_ total: UInt64) {
        // For extraction the safe writer owns progress; solid decoding may process earlier members.
        if reportsProgress { progress?.totalUnitCount = Int64(clamping: total) }
    }
    func progressSetCompleted(_ completed: UInt64) {
        lock.lock(); decodedBytes = completed; lock.unlock()
        if reportsProgress { progress?.completedUnitCount = Int64(clamping: completed) }
    }
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {}
    func progressSetNumFilesProcessed(_ numFiles: UInt64) {}
    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                     newName: String, newTime: Date?, newSize: NSNumber?,
                                     suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer { .no }
    func progressShowMessage(_ message: String) {}
    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}
}

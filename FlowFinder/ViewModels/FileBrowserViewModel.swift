import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import Photos
import os
import CoreServices

private let zipNavLogger = Logger(subsystem: "com.flowfinder.app", category: "ZipNav")
private let searchDebugLogger = Logger(subsystem: "com.flowfinder.app", category: "SearchDebug")

// Notification names are defined in UIConstants.swift

enum ViewMode: String, CaseIterable {
    case coverFlow = "Cover Flow"
    case icons = "Icons"
    case masonry = "Masonry"
    case list = "List"
    case columns = "Columns"
    case dualPane = "Dual Pane"
    case quadPane = "Quad Pane"

    var systemImage: String {
        switch self {
        case .coverFlow: return "square.stack.3d.forward.dottedline"
        case .icons: return "square.grid.2x2"
        case .masonry: return "square.grid.3x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .dualPane: return "rectangle.split.2x1"
        case .quadPane: return "rectangle.grid.2x2"
        }
    }
}

enum SearchMode: String, CaseIterable {
    case filter = "Filter"
    case finder = "Spotlight"

    var placeholder: String {
        switch self {
        case .filter: return "Filter"
        case .finder: return "Spotlight search..."
        }
    }

    var systemImage: String {
        switch self {
        case .filter: return "line.3.horizontal.decrease"
        case .finder: return "magnifyingglass"
        }
    }
}

struct PhotosLibraryInfo: Equatable {
    let libraryURL: URL
    let imagesURL: URL
}

enum NavigationLocation: Equatable {
    case filesystem(URL)
    case archive(archiveURL: URL, internalPath: String)
    case photosLibrary(PhotosLibraryInfo)
}

enum ClipboardOperation {
    case copy
    case cut
}

// MARK: - App-wide File Clipboard

/// The file clipboard shared by every window, tab and pane.
///
/// The internal list is trusted only while the pasteboard still holds what FlowFinder wrote
/// (same `changeCount`). Once anything else is copied — in Finder or any other app — the system
/// pasteboard wins and a pending cut is dropped.
@MainActor
final class FileClipboard {
    static let shared = FileClipboard()

    /// The pasteboard in use. Tests swap in a private one so they don't touch the user's clipboard.
    var pasteboard: NSPasteboard = .general

    private(set) var items: [URL] = []
    private(set) var operation: ClipboardOperation = .copy
    /// The cut URLs exactly as they were selected. Views dim these.
    private(set) var cutURLs: Set<URL> = []
    /// Bumped on every change, for cheap change detection.
    private(set) var revision = 0

    private var cutPaths: Set<String> = []
    private var ownedChangeCount: Int?
    private var writeToken = 0
    /// A copy out of an archive still being extracted (see `beginDeferredWrite`).
    private var pendingDeferredWrite: (token: Int, changeCount: Int, progress: Progress?)?
    /// Pastes issued while that extraction runs; they run once its result is on the clipboard.
    private var pastesWaitingForDeferredWrite: [() -> Void] = []
    /// Keeps archive copy-outs on the clipboard on disk while they're on it.
    private var extractionLease: ArchiveExtractionLease?
    private let observers = NSHashTable<FileBrowserViewModel>.weakObjects()

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                FileClipboard.shared.discardIfPasteboardChanged()
            }
        }
    }

    /// `viewModel` gets `objectWillChange` whenever the clipboard changes, so its views re-dim.
    func addObserver(_ viewModel: FileBrowserViewModel) {
        observers.add(viewModel)
    }

    private var ownsPasteboard: Bool {
        ownedChangeCount == pasteboard.changeCount
    }

    var canPaste: Bool {
        if isWaitingForDeferredWrite { return true }
        if !items.isEmpty && ownsPasteboard { return true }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// A copy out of an archive is being extracted and nothing has been copied since: a paste now
    /// has to wait for it (`pasteWhenReady`) — pasting the clipboard's previous contents (say, an
    /// earlier cut) would be wrong.
    var isWaitingForDeferredWrite: Bool {
        guard let pending = pendingDeferredWrite else { return false }
        return pending.changeCount == pasteboard.changeCount
    }

    /// Runs `paste` once the copy being extracted is on the clipboard. Dropped if that copy is
    /// cancelled, fails or is superseded.
    func pasteWhenReady(_ paste: @escaping () -> Void) {
        pastesWaitingForDeferredWrite.append(paste)
    }

    func isCut(_ url: URL) -> Bool {
        guard !cutPaths.isEmpty else { return false }
        return cutURLs.contains(url) || cutPaths.contains(Self.key(for: url))
    }

    /// Writes `urls` to the pasteboard now and makes them the clipboard contents.
    func write(_ urls: [URL], operation: ClipboardOperation) {
        supersedeDeferredWrite()
        writeToken &+= 1
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if operation == .cut {
            pasteboard.setData(Data([1]), forType: cutOperationPasteboardType)
        }
        ownedChangeCount = pasteboard.changeCount
        setContents(urls, operation: operation)
    }

    /// Starts a copy whose URLs are produced later (archive extraction). Pastes wait for it (see
    /// `isWaitingForDeferredWrite`). Any later copy supersedes it and cancels `progress`.
    func beginDeferredWrite(progress: Progress? = nil) -> (token: Int, changeCount: Int) {
        supersedeDeferredWrite()
        writeToken &+= 1
        pendingDeferredWrite = (writeToken, pasteboard.changeCount, progress)
        notifyObservers()
        return (writeToken, pasteboard.changeCount)
    }

    /// Finishes a deferred copy with what it produced (nothing, if it was cancelled or failed) and
    /// runs the pastes that waited for it. Returns false — the caller then discards what it
    /// produced — when nothing was written because something else was copied in the meantime.
    @discardableResult
    func finishDeferredWrite(_ start: (token: Int, changeCount: Int), urls: [URL]) -> Bool {
        var waitingPastes: [() -> Void] = []
        if pendingDeferredWrite?.token == start.token {
            pendingDeferredWrite = nil
            waitingPastes = pastesWaitingForDeferredWrite
            pastesWaitingForDeferredWrite.removeAll()
        }
        guard start.token == writeToken, start.changeCount == pasteboard.changeCount, !urls.isEmpty else {
            notifyObservers()
            return false
        }
        write(urls, operation: .copy)
        waitingPastes.forEach { $0() }
        return true
    }

    /// What a paste should use right now: our list while we still own the pasteboard, otherwise
    /// the file URLs on the pasteboard (always as a copy).
    func contentsForPaste() -> (urls: [URL], isCut: Bool) {
        if !items.isEmpty && ownsPasteboard {
            return (items, operation == .cut)
        }
        discardIfPasteboardChanged()
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return (urls, false)
    }

    /// Drops our contents (and any cut, or copy still being extracted) if another app has replaced
    /// the pasteboard.
    func discardIfPasteboardChanged() {
        if let pending = pendingDeferredWrite, pending.changeCount != pasteboard.changeCount {
            supersedeDeferredWrite()
        }
        guard ownedChangeCount != nil, !ownsPasteboard else { return }
        ownedChangeCount = nil
        setContents([], operation: .copy)
    }

    /// Called after a paste moved `sources` (a cut, or ⌥⌘V "Move Item Here"). Once everything is
    /// moved, the clipboard is cleared everywhere, along with the pasteboard (which still lists the
    /// old locations).
    func didMoveItems(_ sources: [URL]) {
        guard !sources.isEmpty, !items.isEmpty else { return }
        let movedPaths = Set(sources.map(Self.key(for:)))
        let remaining = items.filter { !movedPaths.contains(Self.key(for: $0)) }
        guard remaining.count != items.count else { return }
        if remaining.isEmpty {
            // Not while a copy is being extracted: that copy is about to replace it, and
            // clearing would make it look superseded.
            if ownsPasteboard, pendingDeferredWrite == nil {
                pasteboard.clearContents()
            }
            ownedChangeCount = nil
            setContents([], operation: .copy)
        } else {
            setContents(remaining, operation: operation)
        }
    }

    /// Keeps the clipboard pointing at items that were renamed or moved — also when it's a folder
    /// they're in that moved.
    func itemsDidMove(_ moves: [(from: URL, to: URL)]) {
        // (While a copy is being extracted the clipboard is about to be replaced anyway.)
        guard !moves.isEmpty, !items.isEmpty, ownsPasteboard, pendingDeferredWrite == nil else { return }
        let movedPaths = moves.map { (from: Self.key(for: $0.from), to: Self.key(for: $0.to)) }
        var changed = false
        let updated = items.map { url -> URL in
            let path = Self.key(for: url)
            for move in movedPaths where FileOperationEngine.isPath(path, sameAsOrInside: move.from) {
                changed = true
                return URL(fileURLWithPath: move.to + path.dropFirst(move.from.count))
            }
            return url
        }
        guard changed else { return }
        write(updated, operation: operation)
    }

    /// Keeps the clipboard pointing at an item that was renamed.
    func itemDidMove(from oldURL: URL, to newURL: URL) {
        itemsDidMove([(oldURL, newURL)])
    }

    private func supersedeDeferredWrite() {
        guard let pending = pendingDeferredWrite else { return }
        pendingDeferredWrite = nil
        pastesWaitingForDeferredWrite.removeAll()
        pending.progress?.cancel()
    }

    private func notifyObservers() {
        for viewModel in observers.allObjects {
            viewModel.objectWillChange.send()
        }
        revision &+= 1
    }

    private func setContents(_ urls: [URL], operation: ClipboardOperation) {
        notifyObservers()
        // The new lease is taken before the old one ends, so extractions on both stay.
        extractionLease = ZipArchiveManager.shared.leaseCopyExtractions(urls)
        items = urls
        self.operation = operation
        cutURLs = operation == .cut ? Set(urls) : []
        cutPaths = operation == .cut ? Set(urls.map(Self.key(for:))) : []
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

// MARK: - File Operation Alerts

struct FileOperationFailure {
    let url: URL
    let error: Error
}

/// Presents file-operation alerts one at a time, each as a sheet on the window of the operation it
/// is about (falling back to the key or main window), or app-modal when there is none.
@MainActor
enum FileOperationAlerts {
    /// Shows `alert` and reports the button pressed. Tests replace this to record and answer alerts.
    /// The default attaches it to `presentingWindow`.
    static var presentAlert: (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, completion in
        var window = FileOperationAlerts.presentingWindow.flatMap { $0.isVisible ? $0 : nil }
            ?? NSApp?.keyWindow.flatMap { $0.canBecomeMain ? $0 : nil }
            ?? NSApp?.mainWindow
        while let parent = window?.sheetParent {
            window = parent
        }
        if let window, window.isVisible {
            // AppKit queues this behind any sheet already on the window.
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// The window of the operation whose alert is being presented, if known.
    static var presentingWindow: NSWindow? {
        presentingWindowBox.window
    }

    private final class WindowBox {
        weak var window: NSWindow?
        init(_ window: NSWindow?) { self.window = window }
    }

    private static var presentingWindowBox = WindowBox(nil)
    private static var pending: [(alert: NSAlert, window: WindowBox, completion: (NSApplication.ModalResponse) -> Void)] = []
    private static var isPresenting = false

    /// Shows `alert` once the alerts before it are answered, as a sheet on `window` if it's still
    /// open.
    static func show(_ alert: NSAlert, in window: NSWindow? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        pending.append((alert, WindowBox(window), completion))
        presentNext()
    }

    private static func presentNext() {
        guard !isPresenting, !pending.isEmpty else { return }
        isPresenting = true
        let next = pending.removeFirst()
        presentingWindowBox = next.window
        presentAlert(next.alert) { response in
            next.completion(response)
            // Next turn, so the finished sheet is fully detached first. Alerts shown from the
            // completion wait until then.
            DispatchQueue.main.async {
                isPresenting = false
                presentNext()
            }
        }
    }

    /// One alert summarizing everything that failed in a batch. `verb` completes
    /// "“name” couldn’t be …", e.g. "copied".
    static func reportFailures(_ failures: [FileOperationFailure], verb: String, in window: NSWindow? = nil) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if failures.count == 1, let failure = failures.first {
            alert.messageText = "“\(displayName(failure.url))” couldn’t be \(verb)."
            alert.informativeText = reason(for: failure.error)
        } else {
            alert.messageText = "\(failures.count) items couldn’t be \(verb)."
            var lines = failures.prefix(5).map { "“\(displayName($0.url))”: \(reason(for: $0.error))" }
            if failures.count > 5 {
                lines.append("…and \(failures.count - 5) more.")
            }
            alert.informativeText = lines.joined(separator: "\n")
        }
        alert.addButton(withTitle: "OK")
        show(alert, in: window)
    }

    static func showMessage(_ message: String, information: String, in window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = information
        alert.addButton(withTitle: "OK")
        show(alert, in: window)
    }

    static func displayName(_ url: URL) -> String {
        FileOperationEngine.displayName(url)
    }

    private static func reason(for error: Error) -> String {
        let nsError = error as NSError
        return nsError.localizedFailureReason ?? nsError.localizedDescription
    }
}

// MARK: - File Operation Engine

/// A change to the file system, recorded so it can be reversed.
enum FileOperationStep {
    case moved(from: URL, to: URL)
    case copied(from: URL, to: URL)
    case trashed(original: URL, trashedAs: URL)
    case restored(from: URL, to: URL)
    case created(URL)
}

/// What one operation did. Filled in on the file-operation queue; undo and redo are queued after
/// the operation they reverse, so they read it once it is complete, and the main thread reads it
/// only after the work hops back. Hence unchecked.
final class FileOperationJournal: @unchecked Sendable {
    var steps: [FileOperationStep] = []
    /// The progress of the operation filling this journal while it's queued or running (set and
    /// cleared on the main thread). Undoing an operation that hasn't finished stops it first.
    var progress: Progress?

    /// Where moved and copied items ended up.
    var placedURLs: [URL] {
        steps.compactMap {
            switch $0 {
            case .moved(_, let to), .copied(_, let to): return to
            default: return nil
            }
        }
    }

    /// Sources that were moved away (not copies whose original stayed behind).
    var movedSources: [URL] {
        steps.compactMap {
            if case .moved(let from, _) = $0 { return from }
            return nil
        }
    }

    /// Items that changed place (moves and renames).
    var moves: [(from: URL, to: URL)] {
        steps.compactMap {
            if case let .moved(from, to) = $0 { return (from, to) }
            return nil
        }
    }

    var trashedOriginals: [URL] {
        steps.compactMap {
            if case .trashed(let original, _) = $0 { return original }
            return nil
        }
    }
}

/// One item of a copy/move batch, planned off the main thread and run on the file-operation queue.
struct FileTransferItem {
    enum Kind {
        case copy
        case move
    }

    enum Placement {
        /// No conflict when planned. Still never overwrites: a late conflict keeps both.
        case exact
        /// An item with this name exists; ask the user.
        case ask
        case keepBoth
        /// Move the existing item to the Trash first, so it can be undone.
        case replace
        /// "name copy" next to the original.
        case duplicate
        case skip
    }

    let source: URL
    let destination: URL
    let kind: Kind
    var placement: Placement
}

struct FileOperationResult {
    var failures: [FileOperationFailure] = []
    /// Items that weren't trashed because their volume has no Trash.
    var trashUnsupported: [URL] = []
    /// Volumes (mount points) that were left alone: they're never trashed or deleted, only ejected.
    var volumes: [URL] = []
    /// The user stopped the operation. What was done until then stays done (and can be undone).
    var wasCancelled = false
}

enum FileOperationEngine {
    /// All copy/move/trash work runs here, app-wide and in order, so undo and redo always run after
    /// the operation they reverse. Quick operations (pasteboard writes, New Folder, rename) don't
    /// use it.
    static let queue = DispatchQueue(label: "com.coverflowfinder.fileops", qos: .userInitiated)

    /// Plans copies and moves (file-system reads only) off the main thread. Separate from `queue`,
    /// so planning a drop doesn't wait for a long copy that's already running.
    static let planningQueue = DispatchQueue(label: "com.coverflowfinder.fileops.planning", qos: .userInitiated)

    /// Moves an item to the Trash and returns where it went. Replaceable for tests.
    static var trashItem: (URL) throws -> URL? = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    // MARK: Operations (file-operation queue)

    /// Copies and moves `items` in order. `progress` (bytes copied, plus one unit per item that's
    /// only renamed) stops the batch when cancelled; an item copied part-way is removed.
    static func transfer(_ items: [FileTransferItem], journal: FileOperationJournal, progress: Progress? = nil) -> FileOperationResult {
        var result = FileOperationResult()
        let active = items.filter { $0.placement != .skip }
        // Sized up front so the progress bar means something.
        let costs = progress == nil ? [] : active.map(transferCost)
        progress?.totalUnitCount = max(1, costs.reduce(0, +))
        // Replacing must never trash an item this batch still has to copy or move (or a folder
        // holding one), nor one it has just put in place.
        let sourcePaths = active.map { canonicalItemPath($0.source) }
        var placedPaths = Set<String>()
        var completed: Int64 = 0

        for (index, item) in active.enumerated() {
            if index > 0, !costs.isEmpty {
                completed += costs[index - 1]
                progress?.completedUnitCount = completed
            }
            if progress?.isCancelled == true {
                result.wasCancelled = true
                break
            }
            let source = item.source
            guard itemExists(at: source) else {
                result.failures.append(FileOperationFailure(url: source, error: notFoundError(source)))
                continue
            }

            var destination = item.destination
            var replaced: (original: URL, trashedAs: URL)?
            switch item.placement {
            case .duplicate:
                destination = duplicateDestinationURL(for: source, in: destination.deletingLastPathComponent())
            case .replace where itemExists(at: destination):
                let destinationPath = canonicalItemPath(destination)
                if placedPaths.contains(destinationPath) {
                    // Put there by this batch a moment ago: keep both.
                    destination = uniqueDestinationURL(for: destination)
                    break
                }
                let verb = item.kind == .move ? "moving" : "copying"
                if isPath(sourcePaths[index], sameAsOrInside: destinationPath) || isSameItem(source, destination) {
                    let error = makeError("“\(displayName(destination))” can’t be replaced because it contains the item you’re \(verb).")
                    result.failures.append(FileOperationFailure(url: source, error: error))
                    continue
                }
                if let later = sourcePaths[(index + 1)...].firstIndex(where: { isPath($0, sameAsOrInside: destinationPath) }) {
                    let error = makeError("“\(displayName(destination))” can’t be replaced because it contains “\(displayName(active[later].source))”, which you’re also \(verb).")
                    result.failures.append(FileOperationFailure(url: source, error: error))
                    continue
                }
                do {
                    guard let trashedURL = try moveToTrash(destination) else {
                        throw makeError("The existing item couldn’t be moved to the Trash.")
                    }
                    replaced = (destination, trashedURL)
                } catch {
                    result.failures.append(FileOperationFailure(url: destination, error: error))
                    continue
                }
            default:
                if itemExists(at: destination) {
                    destination = uniqueDestinationURL(for: destination)
                }
            }

            do {
                let step: FileOperationStep
                switch item.kind {
                case .copy:
                    try copyItem(at: source, to: destination, progress: progress, completedBefore: completed)
                    step = .copied(from: source, to: destination)
                case .move:
                    step = try moveItem(at: source, to: destination, failures: &result.failures, progress: progress, completedBefore: completed)
                }
                if let replaced {
                    journal.steps.append(.trashed(original: replaced.original, trashedAs: replaced.trashedAs))
                }
                journal.steps.append(step)
                placedPaths.insert(canonicalItemPath(destination))
            } catch {
                let wasCancelled = isCancellation(error)
                if !wasCancelled {
                    result.failures.append(FileOperationFailure(url: source, error: error))
                }
                // Nothing took its place: put the replaced item back (or leave it undoable).
                if let replaced, (try? FileManager.default.moveItem(at: replaced.trashedAs, to: replaced.original)) == nil {
                    journal.steps.append(.trashed(original: replaced.original, trashedAs: replaced.trashedAs))
                }
                if wasCancelled {
                    result.wasCancelled = true
                    break
                }
            }
        }
        return result
    }

    /// Moves `urls` to the Trash one by one; `progress` counts items and stops the rest when
    /// cancelled. `onTrashed` gets what was trashed so far every quarter second, so the rows can go
    /// while a long batch is still running. Volumes are never trashed (see `result.volumes`).
    static func trash(
        _ urls: [URL],
        journal: FileOperationJournal,
        progress: Progress? = nil,
        onTrashed: (([URL]) -> Void)? = nil
    ) -> FileOperationResult {
        var result = FileOperationResult()
        progress?.totalUnitCount = Int64(max(1, urls.count))
        var trashedBatch: [URL] = []
        var lastReport = Date()
        for (index, url) in urls.enumerated() {
            if progress?.isCancelled == true {
                result.wasCancelled = true
                break
            }
            if isMountPoint(url) {
                result.volumes.append(url)
            } else {
                do {
                    if let trashedURL = try trashItem(url) {
                        journal.steps.append(.trashed(original: url, trashedAs: trashedURL))
                        trashedBatch.append(url)
                    }
                } catch let error where isTrashUnsupported(error) {
                    result.trashUnsupported.append(url)
                } catch {
                    result.failures.append(FileOperationFailure(url: url, error: error))
                }
            }
            progress?.completedUnitCount = Int64(index + 1)
            if let onTrashed, !trashedBatch.isEmpty, Date().timeIntervalSince(lastReport) >= 0.25 {
                onTrashed(trashedBatch)
                trashedBatch.removeAll()
                lastReport = Date()
            }
        }
        return result
    }

    /// Permanent delete. Only after the user confirmed it; not undoable. Never deletes a volume
    /// (a mount point's contents are the whole volume): those end up in `result.volumes`.
    static func deleteImmediately(_ urls: [URL], progress: Progress? = nil) -> FileOperationResult {
        var result = FileOperationResult()
        progress?.totalUnitCount = Int64(max(1, urls.count))
        for (index, url) in urls.enumerated() {
            if progress?.isCancelled == true {
                result.wasCancelled = true
                break
            }
            if isMountPoint(url) {
                result.volumes.append(url)
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                result.failures.append(FileOperationFailure(url: url, error: error))
            }
            progress?.completedUnitCount = Int64(index + 1)
        }
        return result
    }

    /// Reverses `steps` (last first), recording what it did in `journal` so that can be reversed too.
    static func reverse(_ steps: [FileOperationStep], journal: FileOperationJournal, progress: Progress? = nil) -> FileOperationResult {
        var result = FileOperationResult()
        progress?.totalUnitCount = Int64(max(1, steps.count))
        var completed: Int64 = 0
        for step in steps.reversed() {
            if progress?.isCancelled == true {
                result.wasCancelled = true
                break
            }
            defer {
                completed += 1
                progress?.completedUnitCount = completed
            }
            switch step {
            case let .moved(from, to):
                guard itemExists(at: to) else {
                    result.failures.append(FileOperationFailure(url: to, error: notFoundError(to)))
                    continue
                }
                do {
                    if isSameItem(from, to) {
                        // A case-only rename.
                        try renameItem(at: to, to: from, caseOnly: true)
                        journal.steps.append(.moved(from: to, to: from))
                    } else {
                        let destination = itemExists(at: from) ? uniqueDestinationURL(for: from) : from
                        journal.steps.append(try moveItem(at: to, to: destination, failures: &result.failures))
                    }
                } catch {
                    result.failures.append(FileOperationFailure(url: to, error: error))
                }
            case let .copied(_, url), let .restored(_, url), let .created(url):
                guard itemExists(at: url) else {
                    result.failures.append(FileOperationFailure(url: url, error: notFoundError(url)))
                    continue
                }
                do {
                    if let trashedURL = try moveToTrash(url) {
                        journal.steps.append(.trashed(original: url, trashedAs: trashedURL))
                    }
                } catch {
                    result.failures.append(FileOperationFailure(url: url, error: error))
                }
            case let .trashed(original, trashedAs):
                guard itemExists(at: trashedAs) else {
                    result.failures.append(FileOperationFailure(url: original, error: notFoundError(trashedAs)))
                    continue
                }
                let destination = itemExists(at: original) ? uniqueDestinationURL(for: original) : original
                do {
                    _ = try moveItem(at: trashedAs, to: destination, failures: &result.failures)
                    journal.steps.append(.restored(from: trashedAs, to: destination))
                } catch {
                    result.failures.append(FileOperationFailure(url: original, error: error))
                }
            }
        }
        return result
    }

    /// Makes Finder aliases of `urls` in `directory`: named like the original, or "name alias" when
    /// that's taken (Finder's ⌥⌘-drag).
    static func makeAliases(_ urls: [URL], in directory: URL, journal: FileOperationJournal) -> FileOperationResult {
        var result = FileOperationResult()
        for url in urls {
            guard itemExists(at: url) else {
                result.failures.append(FileOperationFailure(url: url, error: notFoundError(url)))
                continue
            }
            var aliasURL = directory.appendingPathComponent(url.lastPathComponent)
            var counter = 1
            while itemExists(at: aliasURL) {
                let suffix = counter == 1 ? " alias" : " alias \(counter)"
                aliasURL = directory.appendingPathComponent(url.lastPathComponent + suffix)
                counter += 1
            }
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: aliasURL)
                journal.steps.append(.created(aliasURL))
            } catch {
                try? FileManager.default.removeItem(at: aliasURL)
                result.failures.append(FileOperationFailure(url: url, error: error))
            }
        }
        return result
    }

    // MARK: Primitives

    /// Moves an item to the Trash, refusing volumes: trashing a mount point would empty the volume.
    static func moveToTrash(_ url: URL) throws -> URL? {
        if isMountPoint(url) {
            throw makeError("“\(displayName(url))” is a volume. Volumes can only be ejected.")
        }
        return try trashItem(url)
    }

    /// Copies an item. A failed or cancelled copy leaves nothing behind. With `progress`, the bytes
    /// copied are added to `completedBefore` as the copy goes, and cancelling it stops the copy
    /// (throwing `CocoaError.userCancelled`).
    static func copyItem(at source: URL, to destination: URL, progress: Progress? = nil, completedBefore: Int64 = 0) throws {
        guard !itemExists(at: destination) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            if let progress {
                try copyReportingProgress(from: source, to: destination, progress: progress, completedBefore: completedBefore)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            removePartialCopy(destination)
            throw error
        }
    }

    /// Moves an item. Within a volume this is a rename. Across volumes the item is copied, the
    /// copy checked, and only then is the original removed — and only when all of it can be: an
    /// original holding locked items or folders that can't be changed stays whole, and the result
    /// is a copy (reported in `failures`). If removing still fails part-way, what was removed is put
    /// back from the copy, so an original is never left half deleted.
    static func moveItem(
        at source: URL,
        to destination: URL,
        failures: inout [FileOperationFailure],
        progress: Progress? = nil,
        completedBefore: Int64 = 0
    ) throws -> FileOperationStep {
        let fileManager = FileManager.default
        guard !itemExists(at: destination) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        // FileManager.moveItem silently copies + deletes across volumes, so only use it within one.
        if isSameVolume(source, destination.deletingLastPathComponent()) != false {
            do {
                try fileManager.moveItem(at: source, to: destination)
                return .moved(from: source, to: destination)
            } catch let error where isCrossDeviceError(error) {
                // Fall through to copy + remove.
            }
        }

        let name = displayName(source)
        try copyItem(at: source, to: destination, progress: progress, completedBefore: completedBefore)
        guard copyMatchesOriginal(source, destination) else {
            removePartialCopy(destination)
            throw makeError("The copy of “\(name)” didn’t match the original, so the original was kept.")
        }
        if let obstacle = obstacleToRemoving(source) {
            let message = "“\(name)” was copied, but the original couldn’t be removed because \(obstacle). The original was kept."
            failures.append(FileOperationFailure(url: source, error: makeError(message)))
            return .copied(from: source, to: destination)
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            let reason = (error as NSError).localizedDescription
            if restoreRemovedItems(of: source, from: destination) {
                let message = "“\(name)” was copied, but the original couldn’t be removed: \(reason) The original was kept."
                failures.append(FileOperationFailure(url: source, error: makeError(message)))
                return .copied(from: source, to: destination)
            }
            // The copy is the only complete one: record a move, so Undo moves it back.
            let message = "“\(name)” was moved, but part of the original couldn’t be removed: \(reason)"
            failures.append(FileOperationFailure(url: source, error: makeError(message)))
            return .moved(from: source, to: destination)
        }
        return .moved(from: source, to: destination)
    }

    /// Renames within a folder, refusing to replace an existing item. A case-only change on a
    /// case-insensitive volume goes through a temporary name.
    static func renameItem(at source: URL, to destination: URL, caseOnly: Bool) throws {
        let fileManager = FileManager.default
        guard caseOnly else {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        let temporary = source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).flowfinder-rename")
        try fileManager.moveItem(at: source, to: temporary)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.moveItem(at: temporary, to: source)
            throw error
        }
    }

    /// A file is copied by copyfile(3) (cloned where the volume can), reporting bytes as they're
    /// written and stopping mid-file when cancelled. A folder or link is copied by FileManager,
    /// whose delegate reports each file as the next one starts and skips the rest once cancelled.
    private static func copyReportingProgress(from source: URL, to destination: URL, progress: Progress, completedBefore: Int64) throws {
        var info = stat()
        if lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG {
            if try copyFile(from: source, to: destination, progress: progress, completedBefore: completedBefore) {
                return
            }
            // copyfile failed: FileManager gives the error users expect (and may yet succeed).
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let delegate = CopyProgressDelegate(progress: progress, completedBefore: completedBefore)
        let fileManager = FileManager()
        fileManager.delegate = delegate
        try withExtendedLifetime(delegate) {
            try fileManager.copyItem(at: source, to: destination)
        }
        if delegate.wasCancelled {
            throw CocoaError(.userCancelled)
        }
    }

    /// Returns false when copyfile failed (nothing is left at `destination`).
    private static func copyFile(from source: URL, to destination: URL, progress: Progress, completedBefore: Int64) throws -> Bool {
        guard let state = copyfile_state_alloc() else { return false }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passRetained(CopyFileContext(progress: progress, completedBefore: completedBefore))
        defer { context.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyFileCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context.toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL | COPYFILE_CLONE)
        if copyfile(source.path, destination.path, state, flags) == 0 {
            return true
        }
        removePartialCopy(destination)
        if context.takeUnretainedValue().wasCancelled {
            throw CocoaError(.userCancelled)
        }
        return false
    }

    private final class CopyFileContext {
        let progress: Progress
        let completedBefore: Int64
        var wasCancelled = false

        init(progress: Progress, completedBefore: Int64) {
            self.progress = progress
            self.completedBefore = completedBefore
        }
    }

    private static let copyFileCallback: copyfile_callback_t = { what, stage, state, _, _, context in
        guard let context else { return COPYFILE_CONTINUE }
        let copy = Unmanaged<CopyFileContext>.fromOpaque(context).takeUnretainedValue()
        if copy.progress.isCancelled {
            copy.wasCancelled = true
            return COPYFILE_QUIT
        }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state {
            var copied: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                copy.progress.completedUnitCount = copy.completedBefore + Int64(copied)
            }
        }
        return COPYFILE_CONTINUE
    }

    private final class CopyProgressDelegate: NSObject, FileManagerDelegate {
        let progress: Progress
        private var completed: Int64
        /// Size of the file being copied; counted once the next item starts.
        private var current: Int64 = 0
        private(set) var wasCancelled = false

        init(progress: Progress, completedBefore: Int64) {
            self.progress = progress
            self.completed = completedBefore
        }

        func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
            if progress.isCancelled {
                wasCancelled = true
                return false
            }
            completed += current
            progress.completedUnitCount = completed
            var info = stat()
            current = lstat(srcURL.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG ? Int64(info.st_size) : 0
            return true
        }
    }

    /// Removes what a failed or cancelled copy left, even items it copied locked.
    private static func removePartialCopy(_ url: URL) {
        guard itemExists(at: url) else { return }
        if (try? FileManager.default.removeItem(at: url)) != nil { return }
        var paths = [url.path]
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            while let relative = enumerator.nextObject() as? String {
                paths.append((url.path as NSString).appendingPathComponent(relative))
            }
        }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if info.st_flags & UInt32(UF_IMMUTABLE | UF_APPEND) != 0 {
                lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE | UF_APPEND))
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Why `url` (with everything in it) can't be deleted, or nil if it can: a locked item, or a
    /// folder — the one it's in, or one inside it — whose contents can't be changed.
    static func obstacleToRemoving(_ url: URL) -> String? {
        let path = url.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if !canRemoveEntry(owner: info.st_uid, fromDirectory: (path as NSString).deletingLastPathComponent) {
            return "you don’t have permission to change the folder it’s in"
        }
        if isLocked(info) {
            return "it’s locked"
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        if access(path, W_OK | X_OK) != 0 {
            return "you don’t have permission to change it"
        }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
        while let relative = enumerator.nextObject() as? String {
            let childPath = (path as NSString).appendingPathComponent(relative)
            guard lstat(childPath, &info) == 0 else { continue }
            if isLocked(info) {
                return "it contains locked items"
            }
            if (info.st_mode & S_IFMT) == S_IFDIR, access(childPath, W_OK | X_OK) != 0 {
                return "you don’t have permission to change some of the folders in it"
            }
        }
        return nil
    }

    private static func isLocked(_ info: stat) -> Bool {
        info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0
    }

    /// Whether an item owned by `owner` can be deleted from `directory` (write access, and the
    /// sticky bit's ownership rule).
    private static func canRemoveEntry(owner: uid_t, fromDirectory directory: String) -> Bool {
        guard access(directory, W_OK | X_OK) == 0 else { return false }
        var info = stat()
        guard stat(directory, &info) == 0 else { return false }
        if isLocked(info) { return false }
        let uid = getuid()
        if (info.st_mode & S_ISVTX) != 0, uid != 0, owner != uid, info.st_uid != uid {
            return false
        }
        return true
    }

    /// After a removal that failed part-way: copies back from `copy` whatever is missing from
    /// `original`. True when the original is complete again.
    private static func restoreRemovedItems(of original: URL, from copy: URL) -> Bool {
        let fileManager = FileManager.default
        guard itemExists(at: original) else {
            return (try? fileManager.copyItem(at: copy, to: original)) != nil
        }
        guard let enumerator = fileManager.enumerator(atPath: copy.path) else { return false }
        while let relative = enumerator.nextObject() as? String {
            let target = original.appendingPathComponent(relative)
            guard !itemExists(at: target) else { continue }
            guard (try? fileManager.copyItem(at: copy.appendingPathComponent(relative), to: target)) != nil else {
                return false
            }
            // A folder was copied back with everything in it.
            enumerator.skipDescendants()
        }
        return copyMatchesOriginal(copy, original)
    }

    /// Progress units for one item: a move within a volume is a rename (1); anything copied counts
    /// its bytes.
    private static func transferCost(_ item: FileTransferItem) -> Int64 {
        if item.kind == .move, isSameVolume(item.source, item.destination.deletingLastPathComponent()) == true {
            return 1
        }
        return 1 + (treeSummary(item.source)?.last ?? 0)
    }

    // MARK: Helpers

    /// Whether anything (including a dangling symlink) is at `url`.
    static func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Whether two URLs name the same file-system object (e.g. a case-only rename).
    static func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard itemExists(at: lhs), itemExists(at: rhs),
              let left = try? URL(fileURLWithPath: lhs.path).resourceValues(forKeys: key).fileResourceIdentifier as? NSObject,
              let right = try? URL(fileURLWithPath: rhs.path).resourceValues(forKeys: key).fileResourceIdentifier else {
            return false
        }
        return left.isEqual(right)
    }

    /// Whether the item at `item` lives on the same volume as the folder `directory`. A symlink is
    /// on the volume it's stored on, wherever it points. `nil` when either can't be read.
    static func isSameVolume(_ item: URL, _ directory: URL) -> Bool? {
        var itemInfo = stat()
        var directoryInfo = stat()
        guard lstat(item.path, &itemInfo) == 0, stat(directory.path, &directoryInfo) == 0 else {
            return nil
        }
        return itemInfo.st_dev == directoryInfo.st_dev
    }

    /// A volume's root (where it's mounted): moving it would copy the volume, trashing or deleting
    /// it would empty the volume.
    static func isVolumeRoot(_ url: URL) -> Bool {
        isMountPoint(url)
    }

    /// Whether a volume is mounted at `url` (not a symlink to one, which is safe to remove).
    static func isMountPoint(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return false }
        let mountPath = withUnsafeBytes(of: &volume.f_mntonname) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return canonicalPath(URL(fileURLWithPath: path)) == mountPath
    }

    /// The real path: symlinks (including /var → /private/var) resolved and case canonicalized.
    /// For a path that doesn't exist, the existing part is resolved.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (canonicalPath(URL(fileURLWithPath: parent)) as NSString)
            .appendingPathComponent((path as NSString).lastPathComponent)
    }

    /// Like `canonicalPath`, but a symlink itself isn't followed — copying a link copies the link.
    static func canonicalItemPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        var info = stat()
        let isSymlink = lstat(standardized.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        guard isSymlink else { return canonicalPath(standardized) }
        return (canonicalPath(standardized.deletingLastPathComponent()) as NSString)
            .appendingPathComponent(standardized.lastPathComponent)
    }

    static func isPath(_ path: String, sameAsOrInside ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    /// Volumes without a Trash (many SMB shares, some USB drives) fail `trashItem` this way.
    static func isTrashUnsupported(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFeatureUnsupportedError {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(ENOTSUP) || nsError.code == Int(EOPNOTSUPP)) {
                return true
            }
            let description = nsError.localizedDescription.lowercased()
            if description.contains("trash") && description.contains("support") {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    /// "name 2.ext", "name 3.ext", … — the first free name next to `url`.
    static func uniqueDestinationURL(for url: URL) -> URL {
        guard itemExists(at: url) else { return url }
        let (baseName, ext) = nameParts(of: url)
        let directory = url.deletingLastPathComponent()
        var counter = 2
        var candidate: URL
        repeat {
            let name = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        } while itemExists(at: candidate)
        return candidate
    }

    /// "name copy.ext", "name copy 2.ext", … in `directory`, as Finder's Duplicate names them.
    static func duplicateDestinationURL(for source: URL, in directory: URL) -> URL {
        let (baseName, ext) = nameParts(of: source)
        func candidate(_ suffix: String) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)")
        }
        var url = candidate("copy")
        var counter = 2
        while itemExists(at: url) {
            url = candidate("copy \(counter)")
            counter += 1
        }
        return url
    }

    /// Folders (other than packages) have no extension, whatever their name contains.
    private static func nameParts(of url: URL) -> (baseName: String, ext: String) {
        let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true {
            return (url.lastPathComponent, "")
        }
        return (url.deletingPathExtension().lastPathComponent, url.pathExtension)
    }

    /// The name as Finder shows it (":" on disk is displayed as "/").
    static func displayName(_ url: URL) -> String {
        url.lastPathComponent.replacingOccurrences(of: ":", with: "/")
    }

    /// The on-disk name for a name typed by the user: Finder stores "/" as ":".
    static func fileSystemName(forDisplayName name: String) -> String {
        name.replacingOccurrences(of: "/", with: ":")
    }

    /// Why `name` can't be used as a file name, or `nil` if it can.
    static func problemWithFileName(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." || name.contains("\0") {
            return "The name “\(name)” can’t be used."
        }
        if name.utf8.count > 255 {
            return "The name is too long."
        }
        return nil
    }

    /// Item count and total file size match. Catches truncated or partial copies.
    private static func copyMatchesOriginal(_ source: URL, _ copy: URL) -> Bool {
        guard let original = treeSummary(source), let copied = treeSummary(copy) else { return false }
        return original == copied
    }

    private static func treeSummary(_ url: URL) -> [Int64]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let root = URL(fileURLWithPath: url.path)
        guard let values = try? root.resourceValues(forKeys: Set(keys)) else { return nil }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return [1, Int64(values.fileSize ?? 0)]
        }
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { return nil }
        var count: Int64 = 1
        var bytes: Int64 = 0
        for case let child as URL in enumerator {
            count += 1
            if let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               childValues.isRegularFile == true {
                bytes += Int64(childValues.fileSize ?? 0)
            }
        }
        return enumerationFailed ? nil : [count, bytes]
    }

    private static func isCrossDeviceError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EXDEV) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func notFoundError(_ url: URL) -> Error {
        CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
    }

    static func makeError(_ description: String) -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

// MARK: - File Operation Activity

/// Operations that are queued or running, app-wide (main thread only).
extension FileOperationEngine {
    @MainActor private static var running: [ObjectIdentifier: Progress] = [:]
    @MainActor private static var idleHandlers: [() -> Void] = []
    /// Paths being trashed or deleted, so a second ⌘⌫ doesn't queue them again.
    @MainActor private static var removingPaths: [String: Int] = [:]

    /// Whether any copy, move, trash, delete or archive copy-out is queued or running in any
    /// window. Quitting now would leave a partly copied item behind: ask first, then
    /// `cancelAllOperations()` and quit from `whenIdle`.
    @MainActor static var hasPendingOperations: Bool {
        !running.isEmpty
    }

    @MainActor static func operationDidStart(_ progress: Progress) {
        running[ObjectIdentifier(progress)] = progress
    }

    @MainActor static func operationDidEnd(_ progress: Progress) {
        guard running.removeValue(forKey: ObjectIdentifier(progress)) != nil, running.isEmpty else { return }
        let handlers = idleHandlers
        idleHandlers.removeAll()
        handlers.forEach { $0() }
    }

    @MainActor static func isRunning(_ progress: Progress) -> Bool {
        running[ObjectIdentifier(progress)] != nil
    }

    /// Stops every queued or running operation. Each keeps what it finished (and Undo reverses
    /// it); an item copied part-way is removed.
    @MainActor static func cancelAllOperations() {
        running.values.forEach { $0.cancel() }
    }

    /// Runs `handler` once no operation is pending — right away when none is.
    @MainActor static func whenIdle(_ handler: @escaping () -> Void) {
        if running.isEmpty {
            handler()
        } else {
            idleHandlers.append(handler)
        }
    }

    @MainActor static func isBeingRemoved(_ url: URL) -> Bool {
        !removingPaths.isEmpty && removingPaths[url.path] != nil
    }

    @MainActor static func beginRemoving(_ urls: [URL]) {
        for url in urls {
            removingPaths[url.path, default: 0] += 1
        }
    }

    @MainActor static func endRemoving(_ urls: [URL]) {
        for url in urls {
            let key = url.path
            if let count = removingPaths[key], count > 1 {
                removingPaths[key] = count - 1
            } else {
                removingPaths.removeValue(forKey: key)
            }
        }
    }
}

// Custom pasteboard type to track cut operations
private let cutOperationPasteboardType = NSPasteboard.PasteboardType("com.coverflowfinder.cut-operation")

/// Thread-safe sort function for background use (non-isolated)
private func sortItemsForBackground(_ items: [FileItem], sortState: SortState, foldersFirst: Bool) -> [FileItem] {
    ListColumnConfigManager.sortedItems(items, sortState: sortState, foldersFirst: foldersFirst)
}

/// realpath(3): resolves every symlink, including /tmp → /private/tmp
/// (`URL.resolvingSymlinksInPath()` strips /private again).
private func resolvedFilesystemPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A file's identity and version as stat(2) reports them: equal signatures mean the same,
/// unchanged file (used to notice a browsed archive being rewritten or replaced).
private struct FileSignature: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int

    /// nil when there's nothing at `path`
    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
    }
}

/// A file-system object's identity (volume and object ID), to find it again after it was renamed
/// or moved on its volume. (A Swift `URL` can't hold a file reference URL: it turns it back into
/// a path.)
private struct FileObjectID {
    let fileSystemID: fsid_t
    let objectID: UInt64

    init?(path: String) {
        var info = stat()
        var volume = statfs()
        guard stat(path, &info) == 0, statfs(path, &volume) == 0 else { return nil }
        fileSystemID = volume.f_fsid
        objectID = UInt64(info.st_ino)
    }

    /// The object's path now, or nil when it no longer exists (or the volume can't tell).
    func currentPath() -> String? {
        var fileSystemID = self.fileSystemID
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&buffer, buffer.count, &fileSystemID, objectID) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Thread-safe cancellation flag for background loads (checked between items instead of
/// hopping to the main thread).
private final class LoadCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Collects results produced on many threads and publishes ordered snapshots on the main queue.
/// Appends are serialized on a private queue and each snapshot is copied there before it is
/// dispatched, so snapshots arrive on main in append order and never shrink.
final class SerialResultAccumulator<Element>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.flowfinder.result-accumulator")
    private var elements: [Element] = []

    func append(_ element: Element, publish: @escaping ([Element]) -> Void) {
        queue.async {
            self.elements.append(element)
            let snapshot = self.elements
            DispatchQueue.main.async {
                publish(snapshot)
            }
        }
    }

    var snapshot: [Element] {
        queue.sync { elements }
    }
}

@MainActor
class FileBrowserViewModel: ObservableObject {
    @Published var currentPath: URL
    @Published var items: [FileItem] = [] {
        didSet {
            let previousRevision = itemsRevision
            itemsRevision &+= 1
            let patch = pendingInPlacePatch
            pendingInPlacePatch = nil
            guard let patch else {
                filteredItemsCacheKey = nil
                return
            }
            // Same items in the same order, only metadata changed in a way the sort and filters
            // ignore: patch the caches instead of re-sorting (and re-indexing) the folder
            if let key = filteredItemsCacheKey, key.itemsRevision == previousRevision {
                patchFilteredItemsCache(with: patch)
                filteredItemsCacheKey = key.withItemsRevision(itemsRevision)
            } else {
                filteredItemsCacheKey = nil
            }
            if let cache = itemIndexCache, cache.revision == previousRevision {
                itemIndexCache = (itemsRevision, cache.indexByURL)
            }
            if let cache = itemIndexByIDCache, cache.revision == previousRevision {
                itemIndexByIDCache = (itemsRevision, cache.indexByID)
            }
        }
    }
    @Published var selectedItems: Set<FileItem> = []
    @Published var viewMode: ViewMode = .coverFlow
    @Published var searchText: String = ""
    @Published var searchMode: SearchMode = .filter
    @Published var filterTag: String? = nil
    @Published var isLoading: Bool = false
    @Published var isSearching: Bool = false
    /// Why the current folder couldn't be listed (no permission, gone, …), or nil. The views show it
    /// instead of an empty folder.
    @Published private(set) var loadError: String?
    /// This pane's sort. Navigating seeds it from the folder's saved state (per-folder memory) or
    /// the default sort; `setSort`/`setSortColumn` change it.
    @Published private(set) var sortState = SortState(column: .name, direction: .ascending) {
        didSet {
            if sortState != oldValue {
                // Spotlight results arrive sorted in this pane's sort
                spotlightSearch?.setSort(sortState, foldersFirst: AppSettings.shared.foldersFirst)
            }
        }
    }
    /// The current folder's own column layout (per-folder memory); nil shows the shared layout
    /// (`ListColumnConfigManager.columns`).
    @Published private(set) var folderColumns: [ColumnSettings]?

    // Search results for Finder and Everything modes
    @Published var searchResults: [FileItem] = [] {
        didSet {
            searchResultsRevision &+= 1
        }
    }
    private var searchResultsRevision: Int = 0
    private struct SortedSearchResultsCacheKey: Equatable {
        let revision: Int
        let sortState: SortState
        let foldersFirst: Bool
        let tagRefreshToken: Int
    }
    private var sortedSearchResultsCacheKey: SortedSearchResultsCacheKey?
    private var sortedSearchResultsCache: [FileItem] = []

    /// Sorted search results, in this pane's sort like the folder's items, so clicking column
    /// headers in List View sorts search results too.
    /// Cached per (results, sort state): views read this several times per render.
    var sortedSearchResults: [FileItem] {
        guard !searchResults.isEmpty else {
            sortedSearchResultsStructuralToken = 0
            return []
        }

        let cacheKey = currentSearchResultsCacheKey(sortState: sortState, foldersFirst: AppSettings.shared.foldersFirst)
        if sortedSearchResultsCacheKey == cacheKey {
            return sortedSearchResultsCache
        }

        let result = ListColumnConfigManager.sortedItems(searchResults, sortState: sortState, foldersFirst: cacheKey.foldersFirst)
        sortedSearchResultsCacheKey = cacheKey
        sortedSearchResultsCache = result
        sortedSearchResultsStructuralToken = Self.structuralToken(for: result)
        return result
    }

    private func currentSearchResultsCacheKey(sortState: SortState, foldersFirst: Bool) -> SortedSearchResultsCacheKey {
        SortedSearchResultsCacheKey(
            revision: searchResultsRevision,
            sortState: sortState,
            foldersFirst: foldersFirst,
            tagRefreshToken: sortState.column == .tags ? tagRefreshToken : 0
        )
    }
    private var spotlightSearch: SpotlightSearchSession?
    private var spotlightSearchToken = UUID()
    /// Stable IDs for Spotlight results, by path (kept while the search UI stays in use).
    private var spotlightIDsByPath: [String: UUID] = [:]
    /// A Spotlight search was interrupted by suspending background work; rerun it on resume.
    private var searchNeedsRerunOnResume = false
    @Published var navigationHistory: [NavigationLocation] = []
    @Published var historyIndex: Int = -1
    @Published var coverFlowSelectedIndex: Int = 0
    @Published var renamingURL: URL? = nil
    // Navigation generation counter - forces SwiftUI to update on navigation
    @Published var navigationGeneration: Int = 0
    @Published var tagRefreshToken: Int = 0
    weak var undoManager: UndoManager?

    // Track click timing for Finder-style rename triggering
    private var lastClickedURL: URL?
    private var lastClickTime: Date = .distantPast
    private var pendingRenameWorkItem: DispatchWorkItem?
    /// Watches for another click while a click-to-rename is pending (e.g. the second half of a slow double-click).
    private var pendingRenameClickMonitor: Any?

    // URL to select after loading (used when going back)
    private var pendingSelectionURL: URL?
    // URLs to select after loading (used for paste operations with multiple files)
    private var pendingSelectionURLs: Set<URL>?
    // URL to select and immediately start renaming (used for new folder creation)
    private var pendingNewFolderRenameURL: URL?

    // Clipboard state lives in the app-wide FileClipboard; these forward to it.
    private var isObservingClipboard = false

    var clipboardItems: [URL] {
        observeClipboard()
        return FileClipboard.shared.items
    }

    var clipboardOperation: ClipboardOperation {
        observeClipboard()
        return FileClipboard.shared.operation
    }

    /// The cut items (app-wide), as they were selected. Views dim these; compare sets to detect changes.
    var cutItemURLs: Set<URL> {
        observeClipboard()
        return FileClipboard.shared.cutURLs
    }

    /// Check if a file is marked for cut (should appear dimmed)
    func isItemCut(_ item: FileItem) -> Bool {
        observeClipboard()
        return FileClipboard.shared.isCut(item.url)
    }

    /// Re-render this view model's views when the clipboard changes in any window or pane.
    private func observeClipboard() {
        guard !isObservingClipboard else { return }
        isObservingClipboard = true
        FileClipboard.shared.addObserver(self)
    }

    @Published var infoItem: FileItem?
    /// Changes whenever `items` is set, including in-place metadata and iCloud status updates
    /// (which FileItem's identity equality can't see).
    private(set) var itemsRevision: Int = 0
    private struct FilteredItemsCacheKey: Equatable {
        let itemsRevision: Int
        let searchText: String
        let filterTag: String?
        let sortState: SortState
        let foldersFirst: Bool
        /// Tag edits change what the tag filter and the Tags sort produce
        let tagRefreshToken: Int

        func withItemsRevision(_ revision: Int) -> FilteredItemsCacheKey {
            FilteredItemsCacheKey(itemsRevision: revision, searchText: searchText, filterTag: filterTag,
                                  sortState: sortState, foldersFirst: foldersFirst, tagRefreshToken: tagRefreshToken)
        }
    }
    private var filteredItemsCacheKey: FilteredItemsCacheKey?
    private var filteredItemsCache: [FileItem] = []
    /// Positions in `filteredItemsCache` by ID, built when an in-place update first patches it
    /// (reset whenever the cache is recomputed)
    private var filteredItemsCacheIndexByID: [UUID: Int]?
    private var filteredItemsStructuralToken: Int = 0
    private var sortedSearchResultsStructuralToken: Int = 0
    /// Replacements for an in-place `items` update that can't change the sorted, filtered order
    /// (see `assignInPlaceUpdates`); consumed by `items.didSet`.
    private var pendingInPlacePatch: [UUID: FileItem]?

    private var photosLibraryInfo: PhotosLibraryInfo?
    private let photosImageManager = PHCachingImageManager()
    private var photosAssetCache: [String: PHAsset] = [:]
    private var photosAspectRatioCache: [String: CGFloat] = [:]
    /// In-flight Photos thumbnail requests by "identifier-size"; callers asking for the same
    /// thumbnail meanwhile wait for the same result.
    private struct PhotoThumbnailRequest {
        let token: UUID
        var requestID: PHImageRequestID?
        var completions: [(NSImage?, CGFloat?) -> Void]
    }
    private var photosThumbnailRequests: [String: PhotoThumbnailRequest] = [:]
    private var photosExportCache: [String: URL] = [:]
    private var isRequestingPhotosAccess = false
    private var pendingPhotosAccessCompletions: [(PHAuthorizationStatus) -> Void] = []
    private var didForcePhotosAuthRefresh = false
    private let photosLogger = Logger(subsystem: "com.coverflowfinder.app", category: "Photos")
    private var photosLoadToken = UUID()
    private var photosLoadCancellation: LoadCancellationFlag?
    private var photosSortState: SortState?

    private var networkServiceBrowser: NetworkServiceBrowser?
    private var networkServiceIDs: [String: UUID] = [:]
    private var isNetworkBrowsing = false
    private var smbSubnetScanner: SMBSubnetScanner?
    private var discoveredSMBHosts: [SMBHostInfo] = []
    private var isBackgroundWorkActive = true
    private var needsReloadOnResume = false
    /// Set by `tearDown()`; the view model does no further background work.
    private var isTornDown = false

    // MARK: - Lazy Metadata Loading
    /// Batch size for progressive loading of large directories
    private let directoryBatchSize = 400
    /// Token to invalidate in-flight loads when navigating away or reloading
    private var directoryLoadToken = UUID()
    private var directoryLoadCancellation: LoadCancellationFlag?
    /// Key of the location whose complete listing is in `items` (folder path, or archive + internal
    /// path). Reloading the same location diffs into `items` instead of clearing it.
    private var loadedLocationKey: String?
    /// Stable item identities for the current location, by path (see `URL.standardizedPathKey`).
    /// Reset when a different location is loaded.
    private var itemIDsByPath: [String: UUID] = [:]
    /// Whether the current folder is inside iCloud Drive (cloud status is hydrated with metadata)
    private var currentFolderIsInICloud = false
    /// Track which items have had their metadata loaded
    private var hydratedURLs: Set<URL> = []
    /// Track which items have had their cloud status loaded
    private var cloudStatusLoadedURLs: Set<URL> = []
    private var pendingCloudStatusURLs: Set<URL> = []
    /// Queue for metadata hydration requests
    private var pendingHydrationURLs: Set<URL> = []
    private let hydrationQueue = DispatchQueue(label: "com.coverflowfinder.hydration", qos: .userInitiated)
    /// Invalidates in-flight metadata/cloud hydration (new folder, suspension)
    private var hydrationToken = UUID()
    private var hydrationCancellation = LoadCancellationFlag()
    /// Lookup of `items` indices by URL, rebuilt lazily when `items` changes
    private var itemIndexCache: (revision: Int, indexByURL: [URL: Int])?
    /// Lookup of `items` indices by ID, rebuilt lazily when `items` changes
    private var itemIndexByIDCache: (revision: Int, indexByID: [UUID: Int])?
    /// An in-place reload whose listing is in flight: what was shown when it started, and the paths
    /// directory events changed since. Changes made after the listing started win over it.
    private struct ReloadSnapshot {
        let token: UUID
        let presentIDs: Set<UUID>
        var touchedKeys: Set<String> = []
    }
    private var activeReload: ReloadSnapshot?
    /// `CloudStatusManager` announcements collected until the next run-loop turn
    private var pendingCloudStatusChanges: Set<URL> = []
    private var cloudStatusChangesScheduled = false
    /// Re-checks items in a transitional iCloud state (downloading, uploading, …) while they're shown
    private var cloudStatusPollWorkItem: DispatchWorkItem?
    private var sortChangeWorkScheduled = false
    private var directoryWatcher: DirectoryWatcher?
    /// Path key of the folder (currentPath) the watcher was started for
    private var watchedFolderKey: String?
    /// The watched folder's identity (nil when the volume can't tell) and real path, recorded by
    /// its listing, so the folder can be followed when it's renamed or moved
    private var watchedFolderReference: (identity: FileObjectID?, resolvedPath: String)?
    private var pendingDirectoryEventPaths: Set<String> = []
    private var pendingDirectoryRescan = false
    /// The watched folder itself (or a folder above it) was renamed, moved or deleted
    private var pendingWatchedRootCheck = false
    private var directoryEventWorkItem: DispatchWorkItem?
    private let directoryEventDebounce: TimeInterval = 0.25
    struct PhotoAssetDragInfo {
        let filename: String
        let uti: String
    }

    // MARK: - ZIP Archive Browsing State
    @Published var isInsideArchive: Bool = false
    @Published var currentArchiveURL: URL? = nil
    @Published var currentArchivePath: String = ""
    private var archiveEntries: [ZipEntry] = []
    /// The archive file as it was when `archiveEntries` were read (changed → re-read)
    private var archiveEntriesSignature: FileSignature?
    /// Invalidates in-flight archive reads (ZipArchiveManager.readContents runs off the main thread)
    private var archiveReadToken = UUID()
    /// Token of the archive read that turned on the loading spinner (slow reads only)
    private var archiveReadSpinnerToken: UUID?
    /// The folder last entered with `enterFolder` and the item it was entered from (an alias may
    /// differ from the folder): Back selects that item while the folder is still the one shown.
    private var enteredFolder: (folderKey: String, itemURL: URL)?

    /// Path components for breadcrumb navigation (handles both regular paths and archive paths)
    var pathComponents: [(name: String, url: URL?, archivePath: String?)] {
        var components: [(name: String, url: URL?, archivePath: String?)] = []

        // Add regular filesystem path components up to the archive
        let basePath = isInsideArchive ? (currentArchiveURL?.deletingLastPathComponent() ?? currentPath) : currentPath
        var url = basePath.isFileURL ? basePath.standardized : basePath
        var pathComps: [(name: String, url: URL)] = []

        // Bounded: deletingLastPathComponent of a path it can't shorten ("/a/..", "") returns it
        // unchanged or longer
        var remaining = 256
        while url.path != "/", !url.path.isEmpty, remaining > 0 {
            pathComps.insert((name: url.lastPathComponent, url: url), at: 0)
            let parent = url.deletingLastPathComponent()
            guard parent.path.count < url.path.count else { break }
            url = parent
            remaining -= 1
        }
        let rootName = FileManager.default.displayName(atPath: "/")
        pathComps.insert((name: rootName, url: URL(fileURLWithPath: "/")), at: 0)

        for comp in pathComps {
            components.append((name: comp.name, url: comp.url, archivePath: nil))
        }

        // If inside archive, add archive and its internal path components
        if isInsideArchive, let archiveURL = currentArchiveURL {
            // Add the archive itself (clicking navigates to archive root)
            components.append((name: archiveURL.lastPathComponent, url: nil, archivePath: ""))

            // Add internal path components
            if !currentArchivePath.isEmpty {
                let internalComps = currentArchivePath.split(separator: "/")
                var builtPath = ""
                for comp in internalComps {
                    builtPath = builtPath.isEmpty ? String(comp) : "\(builtPath)/\(comp)"
                    components.append((name: String(comp), url: nil, archivePath: builtPath))
                }
            }
        }

        return components
    }

    /// The name of the location shown, as the path bar's last component: the folder, or inside an
    /// archive the archive or the folder in it. Window, tab and pane titles show it.
    var locationTitle: String {
        Self.locationTitle(currentPath: currentPath, archiveURL: isInsideArchive ? currentArchiveURL : nil, archivePath: currentArchivePath)
    }

    /// `locationTitle` as it changes. (`@Published` publishes before the new value is stored, so this
    /// is built from the published values rather than by reading `locationTitle`.)
    var locationTitlePublisher: AnyPublisher<String, Never> {
        Publishers.CombineLatest4($currentPath, $isInsideArchive, $currentArchiveURL, $currentArchivePath)
            .map { path, isInsideArchive, archiveURL, archivePath in
                Self.locationTitle(currentPath: path, archiveURL: isInsideArchive ? archiveURL : nil, archivePath: archivePath)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// `archiveURL` is the archive being browsed (nil outside one), `archivePath` the folder in it.
    nonisolated static func locationTitle(currentPath: URL, archiveURL: URL?, archivePath: String) -> String {
        if let archiveURL {
            let folderName = archivePath.split(separator: "/").last.map(String.init)
            return (folderName ?? archiveURL.lastPathComponent).finderDisplayName
        }
        if currentPath.isFileURL, currentPath.standardizedPathKey == "/" {
            return FileManager.default.displayName(atPath: "/")
        }
        return currentPath.finderDisplayName
    }

    private var cancellables = Set<AnyCancellable>()

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    /// Order-insensitive token for the currently displayed item set.
    /// Cover Flow uses this to distinguish structural changes from pure reordering.
    var coverFlowItemsToken: Int {
        switch searchMode {
        case .finder:
            if searchText.isEmpty {
                _ = filterCurrentDirectoryItems()
                return filteredItemsStructuralToken
            }
            _ = sortedSearchResults
            return sortedSearchResultsStructuralToken
        case .filter:
            _ = filterCurrentDirectoryItems()
            return filteredItemsStructuralToken
        }
    }

    var filteredItems: [FileItem] {
        // For Finder search mode, return search results
        switch searchMode {
        case .finder:
            // When in search mode, return the search results
            // If search text is empty, show current directory items
            if searchText.isEmpty {
                return filterCurrentDirectoryItems()
            }
            return sortedSearchResults

        case .filter:
            // Don't log filter mode to reduce noise
            return filterCurrentDirectoryItems()
        }
    }

    nonisolated static func structuralToken(for items: [FileItem]) -> Int {
        var xorValue = 0
        var sumValue = 0

        for item in items {
            let hash = item.url.absoluteString.hashValue
            xorValue ^= hash
            sumValue &+= hash
        }

        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(xorValue)
        hasher.combine(sumValue)
        return hasher.finalize()
    }

    /// Filter items in the current directory (original filter behavior)
    private func filterCurrentDirectoryItems() -> [FileItem] {
        let sortState = self.sortState
        let foldersFirst = AppSettings.shared.foldersFirst
        let tagsMatter = (filterTag != nil && !isInsideArchive) || sortState.column == .tags
        let cacheKey = FilteredItemsCacheKey(
            itemsRevision: itemsRevision,
            searchText: searchMode == .filter ? searchText : "",
            filterTag: filterTag,
            sortState: sortState,
            foldersFirst: foldersFirst,
            tagRefreshToken: tagsMatter ? tagRefreshToken : 0
        )

        if let cachedKey = filteredItemsCacheKey, cachedKey == cacheKey {
            return filteredItemsCache
        }

        // Photos arrive pre-sorted by PhotoKit for date sorts and are shown in library order otherwise
        if photosLibraryInfo != nil,
           searchText.isEmpty,
           filterTag == nil,
           !(sortState.column == .dateCreated || sortState.column == .dateModified) || photosSortState == sortState {
            filteredItemsCacheKey = cacheKey
            filteredItemsCache = items
            filteredItemsCacheIndexByID = nil
            filteredItemsStructuralToken = Self.structuralToken(for: items)
            return items
        }

        var filtered = items

        // Filter by search text (only in filter mode)
        if searchMode == .filter && !searchText.isEmpty {
            filtered = filtered.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Filter by tag - skip for archive items since they have no tags
        if let tag = filterTag, !isInsideArchive {
            filtered = filtered.filter { item in
                item.tags.contains(tag)
            }
        }

        let sorted = sortItemsForBackground(filtered, sortState: sortState, foldersFirst: foldersFirst)
        filteredItemsCacheKey = cacheKey
        filteredItemsCache = sorted
        filteredItemsCacheIndexByID = nil
        filteredItemsStructuralToken = Self.structuralToken(for: sorted)
        return sorted
    }

    /// Replaces items in the sorted, filtered cache by ID (see `assignInPlaceUpdates`).
    private func patchFilteredItemsCache(with replacements: [UUID: FileItem]) {
        let indexByID: [UUID: Int]
        if let cached = filteredItemsCacheIndexByID {
            indexByID = cached
        } else {
            var built = [UUID: Int](minimumCapacity: filteredItemsCache.count)
            for (offset, item) in filteredItemsCache.enumerated() {
                built[item.id] = offset
            }
            filteredItemsCacheIndexByID = built
            indexByID = built
        }
        for (id, item) in replacements {
            // Items the filter hides aren't in the cache, and a neutral change can't show them
            if let index = indexByID[id] {
                filteredItemsCache[index] = item
            }
        }
    }

    /// Assigns `updated`: `items` with the elements at `replaced` swapped for new versions of the
    /// same items (same IDs at the same positions — hydrated metadata, cloud status, an event's
    /// fresh values). When none of the changes can move or hide a row under the current sort and
    /// filters, the sorted list is patched instead of re-sorting the whole folder.
    private func assignInPlaceUpdates(_ updated: [FileItem], replaced: [Int]) {
        guard !replaced.isEmpty else { return }
        var patch = [UUID: FileItem](minimumCapacity: replaced.count)
        var isNeutral = updated.count == items.count
        if isNeutral {
            for index in replaced {
                let old = items[index]
                let new = updated[index]
                guard isSortAndFilterNeutral(old, new) else {
                    isNeutral = false
                    break
                }
                patch[new.id] = new
            }
        }
        pendingInPlacePatch = isNeutral ? patch : nil
        items = updated
    }

    /// Whether replacing `old` by `new` leaves the sorted, filtered list's order and membership as
    /// it is (the search filter matches names and the tag filter reads tags, neither of which a
    /// replacement changes).
    private func isSortAndFilterNeutral(_ old: FileItem, _ new: FileItem) -> Bool {
        guard old.id == new.id, old.url == new.url,
              old.isDirectory == new.isDirectory, old.isPackage == new.isPackage else { return false }
        switch sortState.column {
        case .name, .tags:
            return true
        case .kind:
            return old.kindDescription == new.kindDescription
        case .size:
            return old.size == new.size
        case .dateModified:
            return old.modificationDate == new.modificationDate
        case .dateCreated:
            return old.creationDate == new.creationDate
        case .cloudStatus:
            return old.cloudStatus?.description == new.cloudStatus?.description
        }
    }

    var isPhotosLibraryActive: Bool {
        photosLibraryInfo != nil
    }

    init(initialPath: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let initialPath = Self.normalizedLocation(initialPath)
        self.currentPath = initialPath
        applyFolderColumnState(for: initialPath)
        loadContents()
        addToHistory(.filesystem(initialPath))

        // Observe search text changes
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] newText in
                guard let self else { return }
                // Trigger search for Finder/Everything modes
                if self.searchMode != .filter {
                    self.objectWillChange.send()
                    self.performSearch(query: newText)
                } else if !newText.isEmpty {
                    // Filter mode with non-empty text — trigger view update for filtering
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        // Observe search mode changes. @Published emits in willSet, so `self.searchMode` still
        // holds the old mode here — pass the new one explicitly.
        $searchMode
            .dropFirst()
            .sink { [weak self] newMode in
                guard let self else { return }
                // Clear search results when changing modes
                self.searchResults = []
                self.cancelSearch()
                // If switching to a search mode with existing text, trigger search
                if newMode != .filter && !self.searchText.isEmpty {
                    self.performSearch(query: self.searchText, mode: newMode)
                }
            }
            .store(in: &cancellables)

        $filterTag
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                self?.navigationGeneration += 1
            }
            .store(in: &cancellables)

        // Cancel pending rename when drag starts (Finder behavior: dragging cancels rename)
        InternalDragState.shared.$isDragging
            .filter { $0 == true }
            .sink { [weak self] _ in
                self?.cancelPendingRename()
            }
            .store(in: &cancellables)

        // Photos names come from the original filenames only while they're shown (reading them is
        // slow). @Published emits in willSet, so the setting still holds the old value here: the
        // reload is given the new one.
        AppSettings.shared.$masonryShowFilenames
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] showFilenames in
                guard let self, showFilenames, let info = self.photosLibraryInfo else { return }
                guard self.isBackgroundWorkActive else {
                    self.needsReloadOnResume = true
                    return
                }
                self.loadPhotosLibraryContents(info: info, useOriginalFilenames: showFilenames)
            }
            .store(in: &cancellables)

        // Sent on the main queue, in batches
        CloudStatusManager.shared.statusesChanged
            .sink { [weak self] urls in
                self?.cloudStatusesDidChange(urls)
            }
            .store(in: &cancellables)

        // Posted on the main thread right before a volume is ejected
        NotificationCenter.default.publisher(for: .volumeWillUnmount)
            .sink { [weak self] notification in
                guard let volumeURL = notification.userInfo?[AppNotificationKey.url] as? URL else { return }
                self?.volumeWillUnmount(volumeURL)
            }
            .store(in: &cancellables)
    }

    /// Stops watching (and Spotlight-searching) a folder on a volume that's about to be unmounted,
    /// so our FSEvents stream doesn't make the eject fail as "in use". The window shell navigates
    /// panes away from the volume.
    private func volumeWillUnmount(_ volumeURL: URL) {
        let volumeKey = volumeURL.standardizedPathKey
        guard volumeKey != "/" else { return }
        let folderKey = currentPath.standardizedPathKey
        guard folderKey == volumeKey || folderKey.hasPrefix(volumeKey + "/") else { return }
        stopDirectoryWatcher()
        cancelSearch()
    }

    func setBackgroundWorkActive(_ isActive: Bool) {
        guard !isTornDown, isBackgroundWorkActive != isActive else { return }
        isBackgroundWorkActive = isActive

        if isActive {
            resumeBackgroundWork()
        } else {
            suspendBackgroundWork()
        }
    }

    /// Stops all background activity: directory watching, Spotlight, Bonjour/SMB browsing,
    /// in-flight loads and hydration. Call when the tab or pane that owns this view model
    /// closes; the view model does no background work afterwards.
    func tearDown() {
        guard !isTornDown else { return }
        stopInlinePreviews()
        suspendBackgroundWork()
        isTornDown = true
        isBackgroundWorkActive = false
        needsReloadOnResume = false
        searchNeedsRerunOnResume = false
        directoryWatcher = nil
        networkServiceBrowser = nil
        smbSubnetScanner = nil
        clearPhotosCaches()
        cancellables.removeAll()
    }

    /// Stops the inline video/audio preview if it plays an item this view model shows, leaving
    /// previews in other windows and panes alone. (Two panes showing the same folder can't be told
    /// apart: both stop it.)
    func stopInlinePreviews() {
        let video = InlineVideoPreviewManager.shared
        if let url = video.currentPreviewURL, isShowingItem(at: url) {
            video.cancelPreview()
        }
        let audio = InlineAudioPreviewManager.shared
        if let url = audio.currentPreviewURL, isShowingItem(at: url) {
            audio.cancelPreview()
        }
    }

    /// Whether `url` is one of the items listed here (folder items or search results).
    private func isShowingItem(at url: URL) -> Bool {
        if itemIDsByPath[url.standardizedPathKey] != nil || itemIndexByURL()[url] != nil {
            return true
        }
        return !searchResults.isEmpty && searchResults.contains { $0.url == url }
    }

    func loadContents() {
        guard isBackgroundWorkActive else {
            needsReloadOnResume = true
            return
        }

        // Discovery only runs while /Network is shown
        if currentPath.path != "/Network" || isInsideArchive || photosLibraryInfo != nil {
            stopNetworkBrowsing()
        }
        // If we're inside an archive, load archive contents instead
        if isInsideArchive {
            loadArchiveContents()
            return
        }
        if let photosLibraryInfo {
            photosLogger.info("loadContents routing to Photos library for path: \(self.currentPath.path, privacy: .private)")
            stopDirectoryWatcher()
            loadPhotosLibraryContents(info: photosLibraryInfo)
            return
        }
        if currentPath.path == "/Network" {
            stopDirectoryWatcher()
            loadNetworkContents()
            return
        }

        let pathToLoad = currentPath
        let locationKey = pathToLoad.standardizedPathKey
        // Reloading the folder that's already shown (refresh, file operations, re-sort, resume)
        // diffs into `items`: no spinner, no cleared list, IDs and selection are kept.
        let isReload = loadedLocationKey == locationKey
        if !isReload {
            beginLoadingNewLocation()
            currentFolderIsInICloud = CloudStatusManager.shared.isInICloud(pathToLoad)
        }
        let listingURL = resolvedListingURL(for: pathToLoad)
        startDirectoryWatcher(for: listingURL)

        let sortState = self.sortState
        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let batchSize = directoryBatchSize
        let existingIDs = itemIDsByPath
        // Keep metadata that was already loaded so hydrated rows don't fall back to "--"
        var idsWithMetadata = Set<UUID>()
        var presentIDs = Set<UUID>(minimumCapacity: isReload ? items.count : 0)
        for item in items {
            if item.hasMetadata {
                idsWithMetadata.insert(item.id)
            }
            if isReload {
                presentIDs.insert(item.id)
            }
        }
        let loadToken = UUID()
        directoryLoadToken = loadToken
        directoryLoadCancellation?.cancel()
        let cancellation = LoadCancellationFlag()
        directoryLoadCancellation = cancellation
        activeReload = isReload ? ReloadSnapshot(token: loadToken, presentIDs: presentIDs) : nil
        needsReloadOnResume = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Self.listDirectory(
                    at: listingURL,
                    showHiddenFiles: showHiddenFiles,
                    sortState: sortState,
                    batchSize: batchSize,
                    existingIDs: existingIDs,
                    idsWithMetadata: idsWithMetadata,
                    cancellation: cancellation
                )
            }
            guard !cancellation.isCancelled else { return }
            // The folder's identity, to follow it when it's renamed or moved
            let identity = FileObjectID(path: listingURL.path)
            let resolvedPath = resolvedFilesystemPath(listingURL.path)

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.directoryLoadToken == loadToken,
                      !self.isInsideArchive,
                      self.photosLibraryInfo == nil,
                      self.currentPath.standardizedPathKey == locationKey else { return }
                if self.directoryWatcher?.watchedPath == listingURL.standardizedPathKey {
                    self.watchedFolderReference = (identity, resolvedPath)
                }
                switch result {
                case .success(let listing):
                    self.setLoadError(nil)
                    self.applyListing(listing, locationKey: locationKey, isReload: isReload, loadToken: loadToken)
                case .failure(let error):
                    // An unreadable (or vanished) folder shows as empty, with the reason
                    self.setLoadError(Self.loadErrorMessage(for: error, folder: pathToLoad))
                    self.applyListing([], locationKey: locationKey, isReload: isReload, loadToken: loadToken)
                }
            }
        }
    }

    private func setLoadError(_ message: String?) {
        if loadError != message {
            loadError = message
        }
    }

    /// Finder's wording for a folder that can't be listed.
    nonisolated static func loadErrorMessage(for error: Error, folder: URL) -> String {
        let name = folder.finderDisplayName
        let nsError = error as NSError
        var posixCode: Int32?
        if nsError.domain == NSPOSIXErrorDomain {
            posixCode = Int32(nsError.code)
        } else if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            posixCode = Int32(underlying.code)
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
            || posixCode == EACCES || posixCode == EPERM {
            return "The folder “\(name)” can’t be opened because you don’t have permission to see its contents."
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError || posixCode == ENOENT {
            return "The folder “\(name)” can’t be found."
        }
        return "The folder “\(name)” can’t be opened. \(nsError.localizedDescription)"
    }

    /// An item produced off the main thread together with its path key.
    private struct ListedItem {
        let key: String
        let item: FileItem
    }

    /// Lists a folder (off the main thread). Small folders, and folders sorted by date or size,
    /// load full metadata up front; large ones load it lazily for visible rows. IDs are reused
    /// per path and items that already had metadata keep it.
    nonisolated private static func listDirectory(
        at listingURL: URL,
        showHiddenFiles: Bool,
        sortState: SortState,
        batchSize: Int,
        existingIDs: [String: UUID],
        idsWithMetadata: Set<UUID>,
        cancellation: LoadCancellationFlag
    ) throws -> [ListedItem] {
        // Special handling for autofs mount points like /Network
        // These require triggering the automounter before listing
        if listingURL.path == "/Network" || listingURL.path.hasPrefix("/Network/") {
            // Trigger automounter by attempting to access the path, then give it a moment
            _ = FileManager.default.fileExists(atPath: listingURL.path)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // contentsOfDirectory(at:) doesn't follow a symlink in the last path component: list the
        // link's target, but keep the children under the link's path (browsed where it's listed)
        var directoryToList = listingURL
        var info = stat()
        if lstat(listingURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            directoryToList = URL(fileURLWithPath: resolvedFilesystemPath(listingURL.path), isDirectory: true)
        }

        // Phase 1: Get file list instantly (no stat calls)
        var contents: [URL] = try autoreleasepool {
            try FileManager.default.contentsOfDirectory(
                at: directoryToList,
                includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey],
                options: showHiddenFiles ? [] : [.skipsHiddenFiles]
            )
        }
        // Children keep the folder's path form (/tmp rather than /private/tmp, the link's path)
        contents = URL.childURLs(contents, reRootedUnder: listingURL)

        // Phase 2: Create items. If sorting by date or size we MUST load metadata to sort correctly.
        let loadMetadataUpfront = contents.count <= batchSize || sortStateRequiresMetadata(sortState)
        var listed: [ListedItem] = []
        listed.reserveCapacity(contents.count)
        for (index, url) in contents.enumerated() {
            if index % batchSize == 0, cancellation.isCancelled {
                throw CancellationError()
            }
            let key = url.standardizedPathKey
            let existingID = existingIDs[key]
            let loadMetadata = loadMetadataUpfront || existingID.map(idsWithMetadata.contains) == true
            let item = autoreleasepool {
                FileItem(url: url, id: existingID ?? UUID(), loadMetadata: loadMetadata)
            }
            listed.append(ListedItem(key: key, item: item))
        }
        return listed
    }

    /// Clears per-location state before loading a different location (shows the spinner).
    private func beginLoadingNewLocation() {
        isLoading = true
        setLoadError(nil)
        loadedLocationKey = nil
        activeReload = nil
        cloudStatusPollWorkItem?.cancel()
        cloudStatusPollWorkItem = nil
        items = []
        itemIDsByPath.removeAll()
        hydratedURLs.removeAll()
        cloudStatusLoadedURLs.removeAll()
        currentFolderIsInICloud = false
        resetHydrationState()
    }

    /// Applies a completed listing. A first load replaces `items`; a reload of the same location
    /// merges into them (see `mergeReloadedItems`).
    private func applyListing(_ listed: [ListedItem], locationKey: String, isReload: Bool, loadToken: UUID) {
        let snapshot = activeReload?.token == loadToken ? activeReload : nil
        activeReload = nil
        // IDs registered on main win: a directory event may have added a path meanwhile
        let reconciled = listed.map { entry -> FileItem in
            if let registered = itemIDsByPath[entry.key] {
                return registered == entry.item.id ? entry.item : entry.item.withID(registered)
            }
            itemIDsByPath[entry.key] = entry.item.id
            return entry.item
        }

        if isReload {
            mergeReloadedItems(reconciled, since: snapshot)
        } else {
            items = reconciled
            navigationGeneration += 1
        }
        // A row without metadata must stay requestable, so it's never stuck at "--"
        for item in items {
            if item.hasMetadata {
                hydratedURLs.insert(item.url)
            } else if !hydratedURLs.isEmpty {
                hydratedURLs.remove(item.url)
            }
        }
        if isLoading {
            isLoading = false
        }
        loadedLocationKey = locationKey
        if itemIDsByPath.count > 2 * items.count + 1_000 {
            pruneItemIDs()
        }

        applySelectionAfterLoad(isReload: isReload)
        triggerPendingNewFolderRename()
        if currentFolderIsInICloud, items.count <= directoryBatchSize {
            hydrateCloudStatus(for: items.map(\.url))
        }
    }

    /// Merges a reloaded listing into `items` without disturbing what's on screen: existing
    /// items keep their position and identity (updated in place when their metadata changed),
    /// vanished ones are removed and new ones appended. `items` is only reassigned when
    /// something actually changed.
    ///
    /// The listing is a snapshot taken off the main thread; `snapshot` tells what changed on main
    /// since it started, and those changes win: paths directory events updated keep what the events
    /// showed, items removed meanwhile (trashed, deleted) stay removed and items added meanwhile
    /// stay. Any later change on disk sends another event. Metadata hydrated meanwhile is kept
    /// when the listing has none.
    private func mergeReloadedItems(_ listed: [FileItem], since snapshot: ReloadSnapshot?) {
        var listedByID = [UUID: FileItem](minimumCapacity: listed.count)
        for item in listed {
            listedByID[item.id] = item
        }
        let presentAtStart = snapshot?.presentIDs
        var touchedIDs = Set<UUID>()
        for key in snapshot?.touchedKeys ?? [] {
            if let id = itemIDsByPath[key] {
                touchedIDs.insert(id)
            }
        }

        var merged: [FileItem] = []
        merged.reserveCapacity(max(listed.count, items.count))
        var structuralChange = false
        var replaced: [Int] = []
        for old in items {
            if touchedIDs.contains(old.id) {
                // A directory event updated this path after the listing started
                listedByID.removeValue(forKey: old.id)
                merged.append(old)
                continue
            }
            guard let new = listedByID.removeValue(forKey: old.id) else {
                if let presentAtStart, !presentAtStart.contains(old.id) {
                    // Added after the listing started
                    merged.append(old)
                    continue
                }
                // Gone
                structuralChange = true
                hydratedURLs.remove(old.url)
                pendingHydrationURLs.remove(old.url)
                cloudStatusLoadedURLs.remove(old.url)
                continue
            }
            var updated = new
            if !updated.hasMetadata, old.hasMetadata, Self.isSameKindOfItem(old, updated) {
                // Hydrated after the listing started: that metadata is the newer one
                updated = old
            } else if updated.cloudStatus == nil, old.cloudStatus != nil {
                // Keep the known cloud status until it's re-hydrated
                updated.cloudStatus = old.cloudStatus
            }
            if Self.displaysIdentically(old, updated) {
                merged.append(old)
            } else {
                replaced.append(merged.count)
                merged.append(updated)
            }
        }
        if !listedByID.isEmpty {
            for item in listed where listedByID[item.id] != nil {
                // Removed after the listing started (by a directory event or a file operation)
                if touchedIDs.contains(item.id) || presentAtStart?.contains(item.id) == true {
                    continue
                }
                structuralChange = true
                merged.append(item)
            }
        }

        if structuralChange {
            items = merged
        } else if !replaced.isEmpty {
            assignInPlaceUpdates(merged, replaced: replaced)
        }
    }

    /// Same file-system object, type and kind: only metadata may differ.
    nonisolated private static func isSameKindOfItem(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        lhs.url == rhs.url &&
        lhs.isDirectory == rhs.isDirectory &&
        lhs.isPackage == rhs.isPackage &&
        lhs.isSymbolicLink == rhs.isSymbolicLink &&
        lhs.fileType == rhs.fileType &&
        lhs.kindDescription == rhs.kindDescription
    }

    nonisolated private static func displaysIdentically(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.url == rhs.url &&
        lhs.contentVersion == rhs.contentVersion &&
        lhs.isDirectory == rhs.isDirectory &&
        lhs.fileType == rhs.fileType &&
        lhs.kindDescription == rhs.kindDescription
    }

    /// Drops remembered IDs for paths that no longer exist (bounded growth across reloads).
    private func pruneItemIDs() {
        let liveIDs = Set(items.map(\.id))
        itemIDsByPath = itemIDsByPath.filter { liveIDs.contains($0.value) }
    }

    /// After a load: applies a pending selection (paste, new folder, Back, path bar) or re-points
    /// the existing selection at the reloaded items. A pending selection is consumed by the load
    /// whether or not its item was found, so it can't select something in a later load. A new
    /// location without a match starts at its first item.
    private func applySelectionAfterLoad(isReload: Bool) {
        let pendingURLs = pendingSelectionURLs
        let pendingURL = pendingSelectionURL
        pendingSelectionURLs = nil
        pendingSelectionURL = nil

        var targetKeys: [String] = []
        if let pendingURLs, !pendingURLs.isEmpty {
            targetKeys = pendingURLs.map(\.standardizedPathKey)
        } else if let pendingURL {
            targetKeys = [pendingURL.standardizedPathKey]
        }
        let targetIDs = Set(targetKeys.compactMap { itemIDsByPath[$0] })
        let matched = targetIDs.isEmpty ? [] : items.filter { targetIDs.contains($0.id) }

        if !matched.isEmpty {
            selectedItems = Set(matched)
            if let index = filteredItems.firstIndex(where: { targetIDs.contains($0.id) }) {
                coverFlowSelectedIndex = index
                lastSelectedIndex = index
                selectionAnchorIndex = index
            }
        } else if !isReload {
            // e.g. Back/Forward or the path bar to a folder the remembered item has left
            refreshSelectedItems()
            if coverFlowSelectedIndex != 0 {
                coverFlowSelectedIndex = 0
            }
            lastSelectedIndex = 0
            selectionAnchorIndex = 0
        } else {
            refreshSelectedItems()
            let clampedIndex = min(coverFlowSelectedIndex, max(0, items.count - 1))
            if clampedIndex != coverFlowSelectedIndex {
                coverFlowSelectedIndex = clampedIndex
            }
        }
    }

    /// Points the selection at the current versions of the selected items (fresh metadata) and
    /// drops items of this location that no longer exist. Publishes only when something changed.
    private func refreshSelectedItems() {
        guard !selectedItems.isEmpty else { return }
        let indexByURL = itemIndexByURL()
        let locationKey = isInsideArchive ? nil : currentPath.standardizedPathKey
        var updated = Set<FileItem>()
        var changed = false
        for item in selectedItems {
            if let index = indexByURL[item.url] {
                let current = items[index]
                updated.insert(current)
                if current.id != item.id || current.contentVersion != item.contentVersion {
                    changed = true
                }
            } else if let index = itemIndexByID()[item.id] {
                // The same item under another URL (renamed in place keeps its ID, or the URL's form
                // changed, e.g. a trailing slash)
                updated.insert(items[index])
                changed = true
            } else if item.isFromArchive || item.url.deletingLastPathComponent().standardizedPathKey == locationKey {
                // Was listed here and is gone
                changed = true
            } else {
                // e.g. a Spotlight result from another folder
                updated.insert(item)
            }
        }
        if changed {
            selectedItems = updated
        }
    }

    /// Index of `items` by URL, rebuilt lazily when `items` changes.
    private func itemIndexByURL() -> [URL: Int] {
        if let cache = itemIndexCache, cache.revision == itemsRevision {
            return cache.indexByURL
        }
        var indexByURL = [URL: Int](minimumCapacity: items.count)
        for (offset, item) in items.enumerated() {
            indexByURL[item.url] = offset
        }
        itemIndexCache = (itemsRevision, indexByURL)
        return indexByURL
    }

    /// Index of `items` by ID, rebuilt lazily when `items` changes.
    private func itemIndexByID() -> [UUID: Int] {
        if let cache = itemIndexByIDCache, cache.revision == itemsRevision {
            return cache.indexByID
        }
        var indexByID = [UUID: Int](minimumCapacity: items.count)
        for (offset, item) in items.enumerated() {
            indexByID[item.id] = offset
        }
        itemIndexByIDCache = (itemsRevision, indexByID)
        return indexByID
    }

    // MARK: - Sort & Column State

    /// Sorts this pane by `column` (column header click, Sort menu), or reverses the direction
    /// when it's already sorted by it.
    func setSortColumn(_ column: ListColumn) {
        if sortState.column == column {
            setSort(SortState(column: column, direction: sortState.direction == .ascending ? .descending : .ascending))
        } else {
            setSort(SortState(column: column, direction: column.defaultSortDirection))
        }
    }

    /// An explicit sort change by the user. Only this pane re-sorts; the sort becomes the default
    /// for folders without saved state and, with per-folder memory on, is saved for this folder.
    func setSort(_ newSort: SortState) {
        guard newSort != sortState else { return }
        sortState = newSort
        ListColumnConfigManager.shared.defaultSortState = newSort
        saveFolderColumnState()
        scheduleSortChangeHandling()
    }

    /// An explicit column change (show/hide, resize, reorder) made in this pane's list: `columns`
    /// is the layout it now shows. The list also applied the change to the shared layout. With
    /// per-folder memory on, this folder keeps `columns`.
    func columnLayoutChangedByUser(_ columns: [ColumnSettings]) {
        guard AppSettings.shared.usePerFolderColumnState, columnStateFolderURL != nil else {
            // Show the shared layout, which has the change
            if folderColumns != nil {
                folderColumns = nil
            }
            return
        }
        saveFolderColumnState(columns: columns)
    }

    /// Column header menu "Reset to Defaults" (after the shared layout and default sort were
    /// reset): forgets this folder's saved state and shows the defaults.
    func resetFolderColumnState() {
        if let folder = columnStateFolderURL {
            PerFolderColumnStateManager.shared.clearState(for: folder)
        }
        if folderColumns != nil {
            folderColumns = nil
        }
        let defaultSort = ListColumnConfigManager.shared.defaultSortState
        if sortState != defaultSort {
            sortState = defaultSort
            scheduleSortChangeHandling()
        }
    }

    /// The folder whose saved column state applies to the current location: nil inside an
    /// archive, the Photos library and /Network (they keep the pane's current sort and columns).
    private var columnStateFolderURL: URL? {
        guard !isInsideArchive, photosLibraryInfo == nil, currentPath.path != "/Network" else { return nil }
        return currentPath
    }

    /// Saves this pane's sort and columns for the current folder when per-folder memory is on.
    /// The folder then shows its own column layout rather than the shared one.
    private func saveFolderColumnState(columns: [ColumnSettings]? = nil) {
        guard AppSettings.shared.usePerFolderColumnState, let folder = columnStateFolderURL else { return }
        let layout = columns ?? folderColumns ?? ListColumnConfigManager.shared.columns
        if folderColumns != layout {
            folderColumns = layout
        }
        PerFolderColumnStateManager.shared.saveState(for: folder, columns: layout, sortState: sortState)
    }

    /// Shows `url` with its saved sort and columns (per-folder memory) or with the default sort and
    /// the shared layout. Called while navigating, before the load: no reload for the sort here.
    private func applyFolderColumnState(for url: URL) {
        let saved = AppSettings.shared.usePerFolderColumnState ? PerFolderColumnStateManager.shared.getState(for: url) : nil
        let sort = saved?.sortState ?? ListColumnConfigManager.shared.defaultSortState
        if sortState != sort {
            sortState = sort
        }
        // Saved layouts predating a column get it (hidden)
        let columns = saved.map { ListColumnConfigManager.normalizedColumns($0.columns) }
        if folderColumns != columns {
            folderColumns = columns
        }
    }

    /// Reloads for a sort change on the next run-loop turn, once for quick successive changes.
    private func scheduleSortChangeHandling() {
        guard !sortChangeWorkScheduled else { return }
        sortChangeWorkScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sortChangeWorkScheduled = false
            self.handleSortChange()
        }
    }

    private func handleSortChange() {
        let sortState = self.sortState
        guard Self.sortStateRequiresMetadata(sortState),
              !isInsideArchive,
              photosLibraryInfo == nil,
              !isNetworkBrowsing else { return }
        guard loadedLocationKey != nil else {
            // Restart an in-flight first load so it loads metadata for the new sort
            if isLoading {
                loadContents()
            }
            return
        }
        // Sorting by date/size needs metadata for every item: reload in place with metadata
        // (one re-sort, no cleared list) instead of reshuffling rows as visible ones hydrate.
        if items.contains(where: { !$0.hasMetadata }) {
            loadContents()
        }
    }

    private func loadNetworkContents() {
        guard isBackgroundWorkActive else {
            needsReloadOnResume = true
            return
        }

        stopNetworkBrowsing()
        isNetworkBrowsing = true
        networkScanFinished = false
        beginLoadingNewLocation()
        navigationGeneration += 1
        discoveredSMBHosts = []

        // Start Bonjour discovery (finds Macs and other Bonjour-advertising devices)
        if networkServiceBrowser == nil {
            networkServiceBrowser = NetworkServiceBrowser(delegate: self)
        }
        networkServiceBrowser?.start()

        // Start SMB subnet scan (finds Windows PCs and other SMB servers)
        if smbSubnetScanner == nil {
            smbSubnetScanner = SMBSubnetScanner(delegate: self)
        }
        smbSubnetScanner?.start()

        // Show initial results after short delay (Bonjour results usually come fast)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            guard self.isNetworkBrowsing, self.currentPath.path == "/Network" else { return }
            if self.isLoading {
                self.isLoading = false
            }
        }
    }

    private func stopNetworkBrowsing() {
        guard isNetworkBrowsing else { return }
        isNetworkBrowsing = false
        networkServiceBrowser?.stop()
        smbSubnetScanner?.stop()
        networkServiceIDs.removeAll()
        discoveredSMBHosts.removeAll()
        lastBonjourServices.removeAll()
    }

    private var lastBonjourServices: [NetworkServiceInfo] = []
    /// The SMB subnet scan of the current /Network load has completed
    private var networkScanFinished = false

    private func suspendBackgroundWork() {
        // Work cut short must be redone on resume: a load, the Photos library still streaming in,
        // network discovery still scanning
        let photosLoadInFlight = photosLoadCancellation != nil
        let networkScanInFlight = isNetworkBrowsing && !networkScanFinished
        needsReloadOnResume = needsReloadOnResume || isLoading || photosLoadInFlight || networkScanInFlight
        searchNeedsRerunOnResume = searchNeedsRerunOnResume || (isSearching && spotlightSearch != nil)
        isLoading = false
        directoryLoadToken = UUID()
        directoryLoadCancellation?.cancel()
        directoryLoadCancellation = nil
        activeReload = nil
        photosLoadToken = UUID()
        photosLoadCancellation?.cancel()
        photosLoadCancellation = nil
        archiveReadToken = UUID()
        archiveReadSpinnerToken = nil
        // In-flight hydration is dropped; forget it so visible rows are requested again on resume
        resetHydrationState()
        pendingCloudStatusChanges.removeAll()
        cloudStatusPollWorkItem?.cancel()
        cloudStatusPollWorkItem = nil
        cancelPendingRename()
        pendingNewFolderRenameURL = nil
        stopDirectoryWatcher()
        stopNetworkBrowsing()
        cancelSearch()
    }

    private func resumeBackgroundWork() {
        let wasInterrupted = needsReloadOnResume
        needsReloadOnResume = false
        if photosLibraryInfo != nil || currentPath.path == "/Network" {
            // Not watched, and re-listing them is expensive (the whole library; a subnet scan):
            // only redo a load that was cut short. ⌘R refreshes them.
            if wasInterrupted || (items.isEmpty && !isLoading) {
                loadContents()
            }
        } else if isInsideArchive {
            if wasInterrupted {
                loadContents()
            } else {
                // Watch the archive's folder again
                startDirectoryWatcher(for: currentPath)
            }
            // Re-read the archive if it changed (or leave it if it's gone) meanwhile
            checkBrowsedArchive()
        } else {
            // Re-list: changes made while suspended weren't watched. Reloading the folder that's
            // already shown is incremental, so scroll position and selection are kept.
            loadContents()
        }
        scheduleCloudStatusPollIfNeeded()
        if searchNeedsRerunOnResume {
            searchNeedsRerunOnResume = false
            if searchMode == .finder, !searchText.isEmpty {
                performSearch(query: searchText)
            }
        }
    }

    private func updateNetworkItems(from services: [NetworkServiceInfo], isFinal: Bool) {
        guard isNetworkBrowsing, currentPath.path == "/Network" else { return }
        lastBonjourServices = services
        rebuildNetworkItems()
        if isLoading && (isFinal || !items.isEmpty) {
            isLoading = false
        }
    }

    private func rebuildNetworkItems() {
        guard isNetworkBrowsing, currentPath.path == "/Network" else { return }

        // Collect hosts from Bonjour services
        var hostsByKey: [String: (name: String, scheme: String, host: String, port: Int, priority: Int)] = [:]

        for info in lastBonjourServices {
            guard let host = normalizedHostName(info.hostName) else { continue }
            let hostKey = host.lowercased()
            if let existing = hostsByKey[hostKey], existing.priority >= info.priority {
                continue
            }
            hostsByKey[hostKey] = (
                name: info.name,
                scheme: info.scheme,
                host: host,
                port: info.port,
                priority: info.priority
            )
        }

        // Add SMB hosts discovered via subnet scan (only if not already found via Bonjour)
        for smbHost in discoveredSMBHosts {
            // Use IP address or resolved hostname as key
            let hostKey = smbHost.ipAddress.lowercased()
            let nameKey = smbHost.name.lowercased()

            // Skip if we already have this host from Bonjour (by IP or name)
            let existingKeys = hostsByKey.keys
            let alreadyExists = existingKeys.contains(hostKey) ||
                                existingKeys.contains(nameKey) ||
                                existingKeys.contains(where: { $0.contains(nameKey) || nameKey.contains($0) })

            if !alreadyExists {
                // SMB scan results have lower priority than Bonjour (priority -1)
                hostsByKey[hostKey] = (
                    name: smbHost.name,
                    scheme: "smb",
                    host: smbHost.ipAddress,
                    port: smbHost.port,
                    priority: -1
                )
            }
        }

        // Sort by name
        let sortedHosts = hostsByKey.sorted { lhs, rhs in
            lhs.value.name.localizedCaseInsensitiveCompare(rhs.value.name) == .orderedAscending
        }

        // Build FileItems
        var nextItems: [FileItem] = []
        nextItems.reserveCapacity(sortedHosts.count)

        for (hostKey, info) in sortedHosts {
            var components = URLComponents()
            components.scheme = info.scheme
            components.host = info.host

            // Add port if non-standard
            let defaultPort: Int? = info.scheme == "smb" ? 445 : (info.scheme == "afp" ? 548 : nil)
            if info.port > 0, let defaultPort, info.port != defaultPort {
                components.port = info.port
            }

            guard let url = components.url else { continue }

            let id = networkServiceIDs[hostKey] ?? UUID()
            networkServiceIDs[hostKey] = id

            let item = FileItem(
                id: id,
                url: url,
                name: info.name,
                isDirectory: true,
                size: 0,
                modificationDate: nil,
                creationDate: nil,
                contentType: nil
            )
            nextItems.append(item)
        }

        items = nextItems
    }

    private func normalizedHostName(_ hostName: String?) -> String? {
        guard let hostName, !hostName.isEmpty else { return nil }
        if hostName.hasSuffix(".") {
            return String(hostName.dropLast())
        }
        return hostName
    }

    private func resolvedListingURL(for url: URL) -> URL {
        if url.path == "/Network" {
            let serversURL = URL(fileURLWithPath: "/Network/Servers")
            if FileManager.default.fileExists(atPath: serversURL.path) {
                return serversURL
            }
        }
        return url
    }

    // MARK: - Lazy Metadata Hydration

    /// Request metadata loading for specific items (call from visible row detection).
    /// In iCloud folders this also loads the items' cloud status (badges, iCloud column,
    /// Download/Remove Download), so views only need to call this one API.
    func hydrateMetadata(for urls: [URL]) {
        requestMetadata(for: urls, evenIfLoaded: false)
    }

    /// `evenIfLoaded`: read the metadata again for items that have it (it may be outdated).
    private func requestMetadata(for urls: [URL], evenIfLoaded: Bool) {
        guard !urls.isEmpty, isBackgroundWorkActive, !isTornDown else { return }
        let indexByURL = itemIndexByURL()
        var metadataURLs: [URL] = []
        var cloudURLs: [URL] = []
        var idByURL: [URL: UUID] = [:]
        for url in urls {
            guard let index = indexByURL[url] else { continue }
            let item = items[index]
            let needsMetadata = evenIfLoaded || (!item.hasMetadata && !hydratedURLs.contains(url))
            if needsMetadata, !pendingHydrationURLs.contains(url) {
                metadataURLs.append(url)
                idByURL[url] = item.id
            }
            if needsCloudStatus(url) {
                cloudURLs.append(url)
            }
        }

        if !cloudURLs.isEmpty {
            hydrateCloudStatus(for: cloudURLs)
        }
        guard !metadataURLs.isEmpty else { return }
        pendingHydrationURLs.formUnion(metadataURLs)

        let token = hydrationToken
        let cancellation = hydrationCancellation
        hydrationQueue.async { [weak self] in
            var hydratedItems: [FileItem] = []
            hydratedItems.reserveCapacity(metadataURLs.count)
            for url in metadataURLs {
                guard !cancellation.isCancelled else { return }
                hydratedItems.append(FileItem(url: url, id: idByURL[url] ?? UUID(), loadMetadata: true))
            }

            // Batch update on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hydrationToken == token else { return }
                self.applyHydratedItems(hydratedItems)
            }
        }
    }

    private func applyHydratedItems(_ hydratedItems: [FileItem]) {
        var updatedItems = items
        let indexByURL = itemIndexByURL()
        var replaced: [Int] = []

        for hydratedItem in hydratedItems {
            pendingHydrationURLs.remove(hydratedItem.url)
            hydratedURLs.insert(hydratedItem.url)

            // Replace item in-place, keeping its identity and the cloud status loaded so far
            guard let index = indexByURL[hydratedItem.url] else { continue }
            let existing = updatedItems[index]
            var replacement = existing.id == hydratedItem.id ? hydratedItem : hydratedItem.withID(existing.id)
            if replacement.cloudStatus == nil {
                replacement.cloudStatus = existing.cloudStatus
            }
            updatedItems[index] = replacement
            replaced.append(index)
        }

        if !replaced.isEmpty {
            assignInPlaceUpdates(updatedItems, replaced: replaced)
            refreshSelectedItems()
            // Post notification so table view can force reload of visible rows
            NotificationCenter.default.post(name: .metadataHydrationCompleted, object: self)
        }
    }

    /// Check if an item needs hydration: metadata, or (in iCloud folders) its cloud status.
    /// Views pass the URLs of items for which this is true to `hydrateMetadata(for:)`.
    func needsHydration(_ item: FileItem) -> Bool {
        (!item.hasMetadata && !hydratedURLs.contains(item.url)) || needsCloudStatus(item.url)
    }

    private func needsCloudStatus(_ url: URL) -> Bool {
        currentFolderIsInICloud &&
        !isInsideArchive &&
        !cloudStatusLoadedURLs.contains(url) &&
        !pendingCloudStatusURLs.contains(url)
    }

    /// Forget in-flight metadata/cloud hydration (new location, suspension). Rows that were
    /// pending are requested again by the views.
    private func resetHydrationState() {
        hydrationCancellation.cancel()
        hydrationCancellation = LoadCancellationFlag()
        hydrationToken = UUID()
        pendingHydrationURLs.removeAll()
        pendingCloudStatusURLs.removeAll()
    }

    // MARK: - Cloud Status Hydration

    /// `CloudStatusManager` announced changed statuses (items invalidated after file-system events,
    /// download/eviction progress, or a whole folder): re-hydrate what we show. Announcements are
    /// collected and handled once per run-loop turn, as one batch.
    private func cloudStatusesDidChange(_ urls: [URL]) {
        guard currentFolderIsInICloud, !isInsideArchive, photosLibraryInfo == nil, !isTornDown, isBackgroundWorkActive else { return }
        pendingCloudStatusChanges.formUnion(urls)
        guard !cloudStatusChangesScheduled else { return }
        cloudStatusChangesScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cloudStatusChangesScheduled = false
            let changed = self.pendingCloudStatusChanges
            self.pendingCloudStatusChanges.removeAll()
            self.processCloudStatusChanges(changed)
        }
    }

    private func processCloudStatusChanges(_ urls: Set<URL>) {
        guard !urls.isEmpty, currentFolderIsInICloud, !isInsideArchive, photosLibraryInfo == nil,
              !isTornDown, isBackgroundWorkActive else { return }
        let folderKey = currentPath.standardizedPathKey
        let indexByID = itemIndexByID()
        var toRefresh = Set<URL>()
        for url in urls {
            let key = url.standardizedPathKey
            if key == folderKey {
                // The folder itself: refresh every status loaded so far (all of them in small folders)
                toRefresh.formUnion(items.count <= directoryBatchSize ? items.map(\.url) : Array(cloudStatusLoadedURLs))
            } else if let id = itemIDsByPath[key], let index = indexByID[id] {
                toRefresh.insert(items[index].url)
            }
        }
        guard !toRefresh.isEmpty else { return }
        cloudStatusLoadedURLs.subtract(toRefresh)
        hydrateCloudStatus(for: Array(toRefresh))
    }

    /// While items are shown in a transitional iCloud state (downloading, uploading, waiting, error),
    /// re-checks them when their cached status expires, so their badges update on their own.
    private func scheduleCloudStatusPollIfNeeded() {
        guard cloudStatusPollWorkItem == nil, currentFolderIsInICloud, !isInsideArchive,
              isBackgroundWorkActive, !isTornDown,
              items.contains(where: { $0.cloudStatus.map(Self.isTransitionalCloudStatus) == true }) else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cloudStatusPollWorkItem = nil
            guard self.currentFolderIsInICloud, !self.isInsideArchive, self.isBackgroundWorkActive, !self.isTornDown else { return }
            let urls = self.items.filter { $0.cloudStatus.map(Self.isTransitionalCloudStatus) == true }.map(\.url)
            guard !urls.isEmpty else { return }
            self.cloudStatusLoadedURLs.subtract(urls)
            // The results schedule the next check while something is still in transit
            self.hydrateCloudStatus(for: urls)
        }
        cloudStatusPollWorkItem = workItem
        // Just after the cached transitional status expires, so the check reads fresh values
        DispatchQueue.main.asyncAfter(deadline: .now() + CloudStatusManager.transitionalStatusTTL + 0.25, execute: workItem)
    }

    nonisolated private static func isTransitionalCloudStatus(_ status: CloudSyncStatus) -> Bool {
        CloudStatusManager.timeToLive(for: status) < CloudStatusManager.stableStatusTTL
    }

    /// Request cloud status loading for specific items. `hydrateMetadata(for:)` calls this for
    /// iCloud folders, and loads call it for small iCloud folders.
    func hydrateCloudStatus(for urls: [URL]) {
        guard isBackgroundWorkActive, !isTornDown else { return }
        let urlsToHydrate = urls.filter {
            !cloudStatusLoadedURLs.contains($0) &&
            !pendingCloudStatusURLs.contains($0) &&
            CloudStatusManager.shared.isInICloud($0)
        }
        guard !urlsToHydrate.isEmpty else { return }
        pendingCloudStatusURLs.formUnion(urlsToHydrate)

        let token = hydrationToken
        let cancellation = hydrationCancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updates: [(URL, CloudSyncStatus)] = []
            updates.reserveCapacity(urlsToHydrate.count)
            for url in urlsToHydrate {
                guard !cancellation.isCancelled else { return }
                updates.append((url, CloudStatusManager.shared.getStatus(for: url)))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.hydrationToken == token else { return }

                var updatedItems = self.items
                let indexByURL = self.itemIndexByURL()
                var replaced: [Int] = []

                for (url, status) in updates {
                    self.pendingCloudStatusURLs.remove(url)
                    self.cloudStatusLoadedURLs.insert(url)
                    if let index = indexByURL[url], updatedItems[index].cloudStatus != status {
                        updatedItems[index] = updatedItems[index].withCloudStatus(status)
                        replaced.append(index)
                    }
                }

                if !replaced.isEmpty {
                    self.assignInPlaceUpdates(updatedItems, replaced: replaced)
                    self.refreshSelectedItems()
                    NotificationCenter.default.post(name: .cloudStatusHydrationCompleted, object: self)
                }
                self.scheduleCloudStatusPollIfNeeded()
            }
        }
    }

    /// Download an iCloud item to make it available locally
    func downloadCloudItem(_ item: FileItem) {
        guard item.cloudStatus?.canDownload == true else { return }

        do {
            try CloudStatusManager.shared.downloadItem(at: item.url)
            // Refresh the item's status
            cloudStatusLoadedURLs.remove(item.url)
            hydrateCloudStatus(for: [item.url])
        } catch {
            // Show error alert
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Download Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Evict (remove local copy of) an iCloud item to free up space
    func evictCloudItem(_ item: FileItem) {
        guard item.cloudStatus?.canEvict == true else { return }

        do {
            try CloudStatusManager.shared.evictItem(at: item.url)
            // Refresh the item's status
            cloudStatusLoadedURLs.remove(item.url)
            hydrateCloudStatus(for: [item.url])
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Remove Download Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    // MARK: - Directory Watching

    private func startDirectoryWatcher(for url: URL) {
        let folderKey = currentPath.standardizedPathKey
        let watchPath = url.standardizedPathKey
        if watchedFolderKey == folderKey, directoryWatcher?.watchedPath == watchPath { return }
        if watchedFolderKey != folderKey {
            // Events still queued for the previous folder must never be applied to this one
            directoryEventWorkItem?.cancel()
            directoryEventWorkItem = nil
            pendingDirectoryEventPaths.removeAll()
            pendingDirectoryRescan = false
            pendingWatchedRootCheck = false
        }
        if directoryWatcher == nil {
            directoryWatcher = DirectoryWatcher { [weak self] paths, needsRescan, rootChanged, watchedPath in
                self?.queueDirectoryEvents(paths, needsRescan: needsRescan, rootChanged: rootChanged, watchedPath: watchedPath)
            }
        }
        watchedFolderKey = folderKey
        watchedFolderReference = nil
        directoryWatcher?.start(watching: watchPath)
    }

    /// Stops the FSEvents stream for the current folder (synchronously). Called internally when
    /// leaving a folder, and by the window shell before ejecting the volume the folder is on;
    /// the next load of a folder starts watching again.
    func stopDirectoryWatcher() {
        watchedFolderKey = nil
        watchedFolderReference = nil
        directoryEventWorkItem?.cancel()
        directoryEventWorkItem = nil
        pendingDirectoryEventPaths.removeAll()
        pendingDirectoryRescan = false
        pendingWatchedRootCheck = false
        directoryWatcher?.stop()
    }

    /// `paths` are direct children of the watched folder, already mapped to the folder's
    /// displayed path form (FSEvents reports resolved paths, e.g. /private/tmp for /tmp).
    /// `rootChanged`: the watched folder, or a folder above it, was renamed, moved or deleted.
    /// Inside an archive the archive's folder is watched, for changes to the archive itself.
    private func queueDirectoryEvents(_ paths: [String], needsRescan: Bool, rootChanged: Bool, watchedPath: String) {
        guard !isTornDown, photosLibraryInfo == nil else { return }
        guard let folderKey = watchedFolderKey,
              folderKey == currentPath.standardizedPathKey,
              directoryWatcher?.watchedPath == watchedPath else { return }
        guard needsRescan || rootChanged || !paths.isEmpty else { return }

        pendingDirectoryEventPaths.formUnion(paths)
        pendingDirectoryRescan = pendingDirectoryRescan || needsRescan
        pendingWatchedRootCheck = pendingWatchedRootCheck || rootChanged
        scheduleDirectoryEventProcessing()
    }

    private func scheduleDirectoryEventProcessing() {
        directoryEventWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.processDirectoryEvents()
        }
        directoryEventWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + directoryEventDebounce, execute: workItem)
    }

    private func processDirectoryEvents() {
        if isLoading {
            // Apply after the first load of this folder completes
            scheduleDirectoryEventProcessing()
            return
        }
        // Only direct children of the folder being shown
        let folderKey = currentPath.standardizedPathKey
        let paths = pendingDirectoryEventPaths.filter { ($0 as NSString).deletingLastPathComponent == folderKey }
        let needsRescan = pendingDirectoryRescan
        let rootChanged = pendingWatchedRootCheck
        pendingDirectoryEventPaths.removeAll()
        pendingDirectoryRescan = false
        pendingWatchedRootCheck = false

        if rootChanged {
            // The folder may be gone or elsewhere now; that decides what to show
            checkWatchedFolder()
        } else if isInsideArchive {
            // Only the archive being browsed matters (renamed, deleted, rewritten)
            if needsRescan || paths.contains(where: { $0 == currentArchiveURL?.standardizedPathKey }) {
                checkBrowsedArchive()
            }
        } else if needsRescan {
            // FSEvents dropped or coalesced events: re-list (incremental)
            loadContents()
        } else {
            applyDirectoryEventUpdates(for: paths)
        }
    }

    // MARK: - Displayed Folder Moved or Deleted

    /// The watched folder (or a folder above it) was renamed, moved or deleted. Like Finder, follow
    /// the folder to its new place (by its file ID); if it's gone, show the closest folder above it
    /// that still exists. A folder recreated at the same path is just re-listed.
    private func checkWatchedFolder() {
        let folder = currentPath
        let folderKey = folder.standardizedPathKey
        let identity = watchedFolderReference?.identity
        let oldResolvedPath = watchedFolderReference?.resolvedPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var info = stat()
            let stillThere = stat(folder.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            // Where the folder is now (found by its identity, through renames and moves)
            let movedTo: URL? = stillThere ? nil : identity?.currentPath().map { URL(fileURLWithPath: $0, isDirectory: true) }
            let fallback = stillThere ? nil : Self.closestExistingAncestor(of: folder)

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown, self.photosLibraryInfo == nil,
                      self.currentPath.standardizedPathKey == folderKey else { return }
                if stillThere {
                    // Recreated, or an ancestor was renamed back: watch and list it again
                    self.stopDirectoryWatcher()
                    if self.isInsideArchive {
                        self.startDirectoryWatcher(for: self.currentPath)
                        self.checkBrowsedArchive()
                    } else {
                        self.loadContents()
                    }
                } else if let movedTo, FileManager.default.fileExists(atPath: movedTo.path) {
                    let newURL = Self.displayFormURL(for: movedTo, displayedFolder: folder, resolvedFolderPath: oldResolvedPath)
                    self.relocateDisplayedFolder(to: newURL, isSameFolder: true)
                } else if let fallback {
                    // Deleted. A volume that went away is handled by the window (it moves its panes).
                    if Self.isOnUnmountedVolume(folder) { return }
                    self.relocateDisplayedFolder(to: fallback, isSameFolder: false)
                }
            }
        }
    }

    /// The new path of a folder that moved, in the form the user navigated with when only its name
    /// changed (/tmp/new rather than /private/tmp/new).
    nonisolated static func displayFormURL(for movedURL: URL, displayedFolder: URL, resolvedFolderPath: String?) -> URL {
        let movedPath = movedURL.standardizedPathKey
        if let resolvedFolderPath,
           (movedPath as NSString).deletingLastPathComponent == (resolvedFolderPath as NSString).deletingLastPathComponent {
            return displayedFolder.deletingLastPathComponent().appendingPathComponent(movedURL.lastPathComponent, isDirectory: true)
        }
        return URL(fileURLWithPath: movedPath, isDirectory: true)
    }

    nonisolated static func closestExistingAncestor(of url: URL) -> URL? {
        var candidate = url.standardized.deletingLastPathComponent()
        var remaining = 256
        while remaining > 0 {
            var info = stat()
            if stat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard candidate.path != "/", parent.path.count < candidate.path.count else { return nil }
            candidate = parent
            remaining -= 1
        }
        return nil
    }

    /// Whether `url` was on a volume under /Volumes that is no longer mounted.
    nonisolated static func isOnUnmountedVolume(_ url: URL) -> Bool {
        let components = url.standardized.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/" + components[2])
    }

    /// Shows `url` in place of the current folder, which moved (`isSameFolder`) or was deleted:
    /// the history entry is replaced (Back doesn't lead to a folder that's gone), and items selected
    /// in a moved folder stay selected.
    private func relocateDisplayedFolder(to url: URL, isSameFolder: Bool) {
        let newFolder = Self.normalizedLocation(url)
        let archiveName = isInsideArchive ? currentArchiveURL?.lastPathComponent : nil
        let selectedNames = selectedItems.filter { !$0.isFromArchive }.map(\.url.lastPathComponent)

        prepareForNavigation()
        resetArchiveState()
        clearPhotosCaches()
        if isSameFolder, let archiveName {
            // Leave the archive (its path changed); select it in its folder's new place
            pendingSelectionURL = newFolder.appendingPathComponent(archiveName)
        } else if isSameFolder, !selectedNames.isEmpty {
            pendingSelectionURLs = Set(selectedNames.map { newFolder.appendingPathComponent($0) })
        }
        currentPath = newFolder
        coverFlowSelectedIndex = 0
        applyFolderColumnState(for: newFolder)
        loadContents()
        refreshFinderSearchScopeIfNeeded()
        if navigationHistory.indices.contains(historyIndex) {
            navigationHistory[historyIndex] = .filesystem(newFolder)
        } else {
            addToHistory(.filesystem(newFolder))
        }
    }

    private enum DirectoryEventChange {
        case removed(key: String)
        case present(key: String, item: FileItem)
    }

    /// Re-reads the changed paths off the main thread and applies the result on main.
    private func applyDirectoryEventUpdates(for paths: Set<String>) {
        guard !paths.isEmpty,
              let locationKey = loadedLocationKey,
              locationKey == currentPath.standardizedPathKey,
              !isInsideArchive, photosLibraryInfo == nil else { return }

        let showHidden = AppSettings.shared.showHiddenFiles
        let sortState = self.sortState
        let shouldLoadMetadata = items.count <= directoryBatchSize || Self.sortStateRequiresMetadata(sortState)
        var existingIDs: [String: UUID] = [:]
        for path in paths {
            existingIDs[path] = itemIDsByPath[path]
        }
        let affectedIDs = Set(existingIDs.values)
        let idsWithMetadata = Set(items.lazy.filter { affectedIDs.contains($0.id) && $0.hasMetadata }.map(\.id))
        // Build URLs the way the listing does: under the folder's path as shown (e.g. /tmp, not
        // /private/tmp), like the event paths
        let listingURL = resolvedListingURL(for: currentPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var changes: [DirectoryEventChange] = []
            var tagsChanged = false
            for path in paths {
                var info = stat()
                guard lstat(path, &info) == 0 else {
                    changes.append(.removed(key: path))
                    continue
                }
                let url = listingURL.appendingPathComponent((path as NSString).lastPathComponent)
                let values = try? url.resourceValues(forKeys: [.nameKey, .isHiddenKey])
                // On a case-insensitive volume the old name of a case-only rename ("b.txt" after
                // b.txt → B.TXT) still resolves to the file: it's only listed under its on-disk name
                if let onDiskName = values?.name, onDiskName != url.lastPathComponent {
                    changes.append(.removed(key: path))
                    continue
                }
                if !showHidden, url.lastPathComponent.hasPrefix(".") || values?.isHidden == true {
                    changes.append(.removed(key: path))
                    continue
                }

                // Tags may have been edited elsewhere (e.g. in Finder): drop the cached value and
                // tell the views if what they showed is now different.
                let cachedTags = FileTagManager.cachedTags(for: url)
                FileTagManager.invalidateCache(for: url)
                if let cachedTags, FileTagManager.getTags(for: url) != cachedTags {
                    tagsChanged = true
                }

                let existingID = existingIDs[path]
                let loadMetadata = shouldLoadMetadata || existingID.map(idsWithMetadata.contains) == true
                let item = FileItem(url: url, id: existingID ?? UUID(), loadMetadata: loadMetadata)
                changes.append(.present(key: path, item: item))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.loadedLocationKey == locationKey,
                      self.currentPath.standardizedPathKey == locationKey,
                      !self.isInsideArchive,
                      self.photosLibraryInfo == nil else { return }
                self.applyDirectoryChanges(changes, tagsChanged: tagsChanged)
            }
        }
    }

    private func applyDirectoryChanges(_ changes: [DirectoryEventChange], tagsChanged: Bool) {
        var updatedItems = items
        var indexByID = itemIndexByID()
        var removedIDs = Set<UUID>()
        var cloudURLsToRefresh: [URL] = []
        var metadataURLsToRefresh: [URL] = []
        var replaced: [Int] = []
        var appended = false

        for change in changes {
            switch change {
            case .removed(let key), .present(let key, _):
                // A reload in flight must not undo what the event shows (see `mergeReloadedItems`)
                activeReload?.touchedKeys.insert(key)
            }
            switch change {
            // Events can be older than the IDs: a rename (or its undo) moves its ID to the new path
            // while events read off the main thread still name the old one. Only ever act on the
            // row that is at the event's path, and never let two rows share an ID.
            case .removed(let key):
                if let id = itemIDsByPath[key], let index = indexByID[id],
                   updatedItems[index].url.standardizedPathKey == key {
                    removedIDs.insert(id)
                }
            case .present(let key, let newItem):
                let id: UUID
                if let registered = itemIDsByPath[key] {
                    id = registered
                } else {
                    if let index = indexByID[newItem.id], updatedItems[index].url.standardizedPathKey != key {
                        id = UUID()
                    } else {
                        id = newItem.id
                    }
                    itemIDsByPath[key] = id
                }
                var item = newItem.id == id ? newItem : newItem.withID(id)
                removedIDs.remove(id)
                if let index = indexByID[id] {
                    let existing = updatedItems[index]
                    if !item.hasMetadata, existing.hasMetadata, Self.isSameKindOfItem(existing, item) {
                        // Hydrated while the event was being read: keep showing that metadata, and
                        // read it again (the hydration may have read the file before this change)
                        item = existing
                        metadataURLsToRefresh.append(existing.url)
                    } else if item.cloudStatus == nil {
                        item.cloudStatus = existing.cloudStatus
                    }
                    if !Self.displaysIdentically(existing, item) {
                        updatedItems[index] = item
                        replaced.append(index)
                    }
                } else {
                    indexByID[id] = updatedItems.count
                    updatedItems.append(item)
                    appended = true
                }
                if item.hasMetadata {
                    hydratedURLs.insert(item.url)
                } else {
                    hydratedURLs.remove(item.url)
                }
                if currentFolderIsInICloud {
                    cloudURLsToRefresh.append(item.url)
                }
            }
        }

        if !removedIDs.isEmpty {
            for item in updatedItems where removedIDs.contains(item.id) {
                hydratedURLs.remove(item.url)
                pendingHydrationURLs.remove(item.url)
                cloudStatusLoadedURLs.remove(item.url)
            }
            updatedItems.removeAll { removedIDs.contains($0.id) }
        }

        if !removedIDs.isEmpty || appended {
            items = updatedItems
            refreshSelectedItems()
            // NOTE: Don't increment navigationGeneration here - incremental updates
            // should not cause full view recreation which loses scroll position
        } else if !replaced.isEmpty {
            assignInPlaceUpdates(updatedItems, replaced: replaced)
            refreshSelectedItems()
        }
        if tagsChanged {
            tagRefreshToken &+= 1
        }
        if !metadataURLsToRefresh.isEmpty {
            requestMetadata(for: metadataURLsToRefresh, evenIfLoaded: true)
        }
        if !cloudURLsToRefresh.isEmpty {
            // Its `statusesChanged` announcement re-hydrates these (see `cloudStatusesDidChange`)
            cloudStatusLoadedURLs.subtract(cloudURLsToRefresh)
            CloudStatusManager.shared.invalidate(urls: cloudURLsToRefresh)
        }
    }

    nonisolated private static func sortStateRequiresMetadata(_ sortState: SortState) -> Bool {
        switch sortState.column {
        case .dateModified, .dateCreated, .size:
            return true
        default:
            return false
        }
    }

    /// Load contents from within a ZIP archive (the listing is built off the main thread)
    private func loadArchiveContents() {
        guard let archiveURL = currentArchiveURL else {
            isInsideArchive = false
            currentArchivePath = ""
            archiveEntries = []
            loadContents()
            return
        }

        let archivePath = currentArchivePath
        let locationKey = "\(archiveURL.standardizedPathKey)#\(archivePath)"
        let isReload = loadedLocationKey == locationKey
        if !isReload {
            beginLoadingNewLocation()
        }
        // Watch the archive's folder: the archive may be renamed, deleted or rewritten
        startDirectoryWatcher(for: currentPath)

        let entries = archiveEntries
        let showHiddenFiles = AppSettings.shared.showHiddenFiles
        let loadToken = UUID()
        directoryLoadToken = loadToken
        directoryLoadCancellation?.cancel()
        directoryLoadCancellation = nil
        activeReload = isReload ? ReloadSnapshot(token: loadToken, presentIDs: Set(items.map(\.id))) : nil
        needsReloadOnResume = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Get entries at the current path within the archive
            let entriesAtPath = ZipArchiveManager.shared.entriesAtPath(archivePath, in: entries)
            var fileItems = ZipArchiveManager.shared.fileItems(from: entriesAtPath, archiveURL: archiveURL)
            if !showHiddenFiles {
                fileItems = fileItems.filter { !$0.name.hasPrefix(".") }
            }
            let listed = fileItems.map { ListedItem(key: $0.url.standardizedPathKey, item: $0) }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.directoryLoadToken == loadToken,
                      self.isInsideArchive,
                      self.currentArchiveURL == archiveURL,
                      self.currentArchivePath == archivePath else { return }
                self.applyListing(listed, locationKey: locationKey, isReload: isReload, loadToken: loadToken)
            }
        }
    }

    /// Checks the archive being browsed against the disk (after events for it, or on resume):
    /// re-reads it if it changed, and leaves it for its folder if it's gone.
    private func checkBrowsedArchive() {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }
        let knownSignature = archiveEntriesSignature
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signature = FileSignature(path: archiveURL.path)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInsideArchive, self.currentArchiveURL == archiveURL else { return }
                if signature == nil {
                    self.leaveVanishedArchive()
                } else if signature != knownSignature {
                    self.rereadArchive()
                }
            }
        }
    }

    /// Reads the browsed archive again (⌘R, or it changed on disk) and shows the same folder in it,
    /// or the closest folder above it that's still there. Leaves the archive if it can't be read.
    private func rereadArchive() {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }
        readArchiveEntries(at: archiveURL) { [weak self] result in
            guard let self, self.isInsideArchive, self.currentArchiveURL == archiveURL else { return }
            switch result {
            case .success(let read):
                self.archiveEntries = read.entries
                self.archiveEntriesSignature = read.signature
                var path = self.currentArchivePath
                while !path.isEmpty, ZipArchiveManager.shared.entry(atPath: path, in: read.entries)?.isDirectory != true {
                    path = path.split(separator: "/").dropLast().joined(separator: "/")
                }
                if path != self.currentArchivePath {
                    self.navigateInArchive(to: path)
                } else {
                    self.loadContents()
                }
            case .failure(let error):
                zipNavLogger.error("Failed to re-read archive: \(error.localizedDescription)")
                self.leaveVanishedArchive()
            }
        }
    }

    /// The archive being browsed was deleted, moved or can't be read anymore: show its folder.
    private func leaveVanishedArchive() {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }
        let folder = archiveURL.deletingLastPathComponent()
        prepareForNavigation()
        resetArchiveState()
        // Still selects the archive if it's there (e.g. rewritten unreadable)
        pendingSelectionURL = archiveURL
        currentPath = folder
        coverFlowSelectedIndex = 0
        applyFolderColumnState(for: folder)
        loadContents()
        addToHistory(.filesystem(folder))
    }

    private func loadPhotosLibraryContents(info: PhotosLibraryInfo, useOriginalFilenames: Bool? = nil) {
        beginLoadingNewLocation()
        let infoSnapshot = info
        let pendingURL = pendingSelectionURL
        let sortState = self.sortState
        let useOriginalFilenames = useOriginalFilenames ?? AppSettings.shared.masonryShowFilenames
        let loadToken = UUID()
        photosLoadToken = loadToken
        photosLoadCancellation?.cancel()
        let cancellation = LoadCancellationFlag()
        photosLoadCancellation = cancellation

        photosLogger.info("Starting Photos library load: \(info.libraryURL.path, privacy: .private)")

        ensurePhotosAccess { [weak self] status in
            guard let self else { return }
            let authorized = status == .authorized || status == .limited
            guard authorized else {
                self.photosLogger.warning("Photos access denied with status: \(status.rawValue)")
                // The user may have gone elsewhere while the access prompt was up
                guard self.photosLoadToken == loadToken, self.photosLibraryInfo == infoSnapshot else { return }
                self.photosLoadCancellation = nil
                self.items = []
                self.isLoading = false
                self.showPhotosAccessAlert(for: status)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let fallbackFormatter = DateFormatter()
                fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
                fallbackFormatter.timeZone = .current
                fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

                var effectiveSortState = sortState
                switch effectiveSortState.column {
                case .dateCreated, .dateModified:
                    break
                default:
                    effectiveSortState = SortState(column: .dateCreated, direction: .descending)
                }

                let fetchOptions = PHFetchOptions()
                fetchOptions.predicate = NSPredicate(
                    format: "mediaType == %d || mediaType == %d",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue
                )
                fetchOptions.sortDescriptors = self.photosSortDescriptors(for: effectiveSortState)

                let assets = PHAsset.fetchAssets(with: fetchOptions)
                self.photosLogger.info("Fetched \(assets.count) Photos assets (status: \(status.rawValue))")

                let totalCount = assets.count
                let batchSize = 400
                let initialCount = min(batchSize, totalCount)

                func buildBatch(range: Range<Int>) -> (items: [FileItem], assetCache: [String: PHAsset], ratioCache: [String: CGFloat], selectedItem: FileItem?) {
                    var batchItems: [FileItem] = []
                    batchItems.reserveCapacity(range.count)
                    var assetCache: [String: PHAsset] = [:]
                    assetCache.reserveCapacity(range.count)
                    var ratioCache: [String: CGFloat] = [:]
                    ratioCache.reserveCapacity(range.count)
                    var selectedItem: FileItem?

                    let indexSet = IndexSet(integersIn: range)
                    assets.enumerateObjects(at: indexSet, options: []) { asset, _, _ in
                        guard let assetURL = self.photosAssetURL(for: asset.localIdentifier) else { return }
                        let name = useOriginalFilenames
                            ? self.photosAssetName(for: asset, fallbackFormatter: fallbackFormatter)
                            : self.photosAssetFallbackName(for: asset, fallbackFormatter: fallbackFormatter)
                        let contentType: UTType? = asset.mediaType == .video ? .movie : .image
                        let modDate = asset.modificationDate ?? asset.creationDate
                        let identifier = asset.localIdentifier
                        assetCache[identifier] = asset
                        if asset.pixelHeight > 0 {
                            ratioCache[identifier] = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                        }

                        let item = FileItem(
                            url: assetURL,
                            name: name,
                            isDirectory: false,
                            size: 0,
                            modificationDate: modDate,
                            creationDate: asset.creationDate,
                            contentType: contentType
                        )
                        if let pendingURL, pendingURL == assetURL {
                            selectedItem = item
                        }
                        batchItems.append(item)
                    }

                    return (batchItems, assetCache, ratioCache, selectedItem)
                }

                let initialBatch = buildBatch(range: 0..<initialCount)
                let isComplete = totalCount <= initialCount
                DispatchQueue.main.async {
                    let infoMatches = self.photosLibraryInfo == infoSnapshot
                    let pathMatches = self.currentPath == infoSnapshot.libraryURL
                    let tokenMatches = self.photosLoadToken == loadToken
                    if !infoMatches || !pathMatches || !tokenMatches {
                        self.photosLogger.warning("Photos load abandoned infoMatches=\(infoMatches) pathMatches=\(pathMatches) tokenMatches=\(tokenMatches) currentPath=\(self.currentPath.path, privacy: .private)")
                        return
                    }

                    self.photosSortState = effectiveSortState
                    self.photosAssetCache = initialBatch.assetCache
                    self.photosAspectRatioCache = initialBatch.ratioCache

                    if let item = initialBatch.selectedItem {
                        self.selectedItems = [item]
                        self.pendingSelectionURL = nil
                    } else if isComplete {
                        self.pendingSelectionURL = nil
                    }

                    self.items = initialBatch.items
                    self.isLoading = false
                    self.navigationGeneration += 1
                    if isComplete {
                        // Done: nothing to redo after a suspension
                        self.photosLoadCancellation = nil
                    }
                    if totalCount == 0 {
                        self.photosLogger.warning("Photos load completed with 0 items (status: \(status.rawValue))")
                    }
                }

                guard !isComplete else { return }

                // Publish the rest in a few large chunks: every publish re-renders the whole grid,
                // so appending each 400-item batch would redo that work hundreds of times.
                var pendingItems: [FileItem] = []
                var pendingAssetCache: [String: PHAsset] = [:]
                var pendingRatioCache: [String: CGFloat] = [:]
                var pendingSelectedItem: FileItem?
                var lastPublish = Date()

                for start in stride(from: initialCount, to: totalCount, by: batchSize) {
                    guard !cancellation.isCancelled else { return }
                    let range = start..<min(start + batchSize, totalCount)
                    let batch = buildBatch(range: range)
                    pendingItems.append(contentsOf: batch.items)
                    pendingAssetCache.merge(batch.assetCache) { current, _ in current }
                    pendingRatioCache.merge(batch.ratioCache) { current, _ in current }
                    pendingSelectedItem = pendingSelectedItem ?? batch.selectedItem

                    let isLastBatch = range.upperBound >= totalCount
                    guard isLastBatch || pendingItems.count >= 5_000 || Date().timeIntervalSince(lastPublish) >= 0.5 else { continue }

                    let chunkItems = pendingItems
                    let chunkAssetCache = pendingAssetCache
                    let chunkRatioCache = pendingRatioCache
                    let chunkSelectedItem = pendingSelectedItem
                    pendingItems = []
                    pendingAssetCache = [:]
                    pendingRatioCache = [:]
                    pendingSelectedItem = nil
                    lastPublish = Date()

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let infoMatches = self.photosLibraryInfo == infoSnapshot
                        let pathMatches = self.currentPath == infoSnapshot.libraryURL
                        let tokenMatches = self.photosLoadToken == loadToken
                        guard infoMatches, pathMatches, tokenMatches else { return }

                        self.photosAssetCache.merge(chunkAssetCache) { current, _ in current }
                        self.photosAspectRatioCache.merge(chunkRatioCache) { current, _ in current }
                        self.items.append(contentsOf: chunkItems)

                        if self.pendingSelectionURL != nil, let item = chunkSelectedItem {
                            self.selectedItems = [item]
                            self.pendingSelectionURL = nil
                        }
                        if isLastBatch {
                            // Consumed by this load whether or not it was found
                            self.pendingSelectionURL = nil
                            self.photosLoadCancellation = nil
                        }
                    }
                }
            }
        }
    }

    private func ensurePhotosAccess(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let status = photosAuthorizationStatus()
        photosLogger.info("Photos authorization status: \(status.rawValue)")

        switch status {
        case .authorized, .limited:
            completion(status)
        case .notDetermined:
            if isRequestingPhotosAccess {
                pendingPhotosAccessCompletions.append(completion)
                return
            }
            isRequestingPhotosAccess = true
            pendingPhotosAccessCompletions.append(completion)
            requestPhotosAuthorization { [weak self] newStatus in
                guard let self else { return }
                self.isRequestingPhotosAccess = false
                self.photosLogger.info("Photos authorization result: \(newStatus.rawValue)")
                let completions = self.pendingPhotosAccessCompletions
                self.pendingPhotosAccessCompletions.removeAll()
                completions.forEach { $0(newStatus) }
            }
        case .denied:
            if didForcePhotosAuthRefresh {
                completion(status)
                return
            }
            didForcePhotosAuthRefresh = true
            requestPhotosAuthorization { [weak self] newStatus in
                guard let self else { return }
                self.photosLogger.info("Photos authorization refresh result: \(newStatus.rawValue)")
                completion(newStatus)
            }
        default:
            completion(status)
        }
    }

    private func photosAuthorizationStatus() -> PHAuthorizationStatus {
        if #available(macOS 11.0, *) {
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        return PHPhotoLibrary.authorizationStatus()
    }

    private func requestPhotosAuthorization(completion: @escaping (PHAuthorizationStatus) -> Void) {
        let requestBlock = {
            NSApp.activate(ignoringOtherApps: true)
            if #available(macOS 11.0, *) {
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    DispatchQueue.main.async {
                        completion(status)
                    }
                }
            } else {
                PHPhotoLibrary.requestAuthorization { status in
                    DispatchQueue.main.async {
                        completion(status)
                    }
                }
            }
        }

        if Thread.isMainThread {
            requestBlock()
        } else {
            DispatchQueue.main.async {
                requestBlock()
            }
        }
    }

    private func showPhotosAccessAlert(for status: PHAuthorizationStatus) {
        let alert = NSAlert()
        alert.messageText = "Photos Access Needed"
        if status == .restricted {
            alert.informativeText = "Photos access is restricted on this Mac. Check Screen Time or configuration profiles."
        } else {
            alert.informativeText = "Allow Photos access in System Settings to show your full library."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if let window = NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    self.openPhotosPrivacySettings()
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openPhotosPrivacySettings()
            }
        }
    }

    private func openPhotosPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else { return }
        NSWorkspace.shared.open(url)
    }

    func isPhotosItem(_ item: FileItem) -> Bool {
        photosAssetIdentifier(from: item.url) != nil
    }

    func photosAssetIdentifier(for item: FileItem) -> String? {
        photosAssetIdentifier(from: item.url)
    }

    func photosAssetAspectRatio(for item: FileItem) -> CGFloat? {
        guard let identifier = photosAssetIdentifier(from: item.url),
              !identifier.isEmpty else { return nil }
        if let cached = photosAspectRatioCache[identifier] {
            return cached
        }
        guard let asset = photosAsset(for: identifier),
              asset.pixelHeight > 0 else { return nil }
        let ratio = CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        photosAspectRatioCache[identifier] = ratio
        return ratio
    }

    func startCachingPhotos(for items: [FileItem], targetSize: CGSize) {
        let assets = items.compactMap { item -> PHAsset? in
            guard let identifier = photosAssetIdentifier(from: item.url),
                  let asset = photosAsset(for: identifier) else { return nil }
            return asset
        }
        guard !assets.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        photosImageManager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    func stopCachingPhotos(for items: [FileItem], targetSize: CGSize) {
        let assets = items.compactMap { item -> PHAsset? in
            guard let identifier = photosAssetIdentifier(from: item.url),
                  let asset = photosAsset(for: identifier) else { return nil }
            return asset
        }
        guard !assets.isEmpty else { return }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast

        photosImageManager.stopCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    func stopCachingAllPhotos() {
        photosImageManager.stopCachingImagesForAllAssets()
    }

    func requestPhotoThumbnail(
        for item: FileItem,
        targetPixelSize: CGFloat,
        completion: @escaping (NSImage?, CGFloat?) -> Void
    ) {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier) else {
            completion(nil, nil)
            return
        }

        let requestKey = "\(identifier)-\(Int(targetPixelSize))"
        if photosThumbnailRequests[requestKey] != nil {
            // Already requested: this caller gets the same result
            photosThumbnailRequests[requestKey]?.completions.append(completion)
            return
        }

        let token = UUID()
        photosThumbnailRequests[requestKey] = PhotoThumbnailRequest(token: token, requestID: nil, completions: [completion])

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        let targetSize = CGSize(width: targetPixelSize, height: targetPixelSize)
        let requestID = photosImageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            // Opportunistic delivery: maybe a degraded image first, then the final one
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            DispatchQueue.main.async {
                guard let self, let request = self.photosThumbnailRequests[requestKey], request.token == token else { return }
                if !isDegraded {
                    self.photosThumbnailRequests.removeValue(forKey: requestKey)
                }
                let ratio = asset.pixelHeight > 0
                    ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
                    : nil
                for waiting in request.completions {
                    waiting(image, ratio)
                }
            }
        }

        if photosThumbnailRequests[requestKey]?.token == token {
            photosThumbnailRequests[requestKey]?.requestID = requestID
        }
    }

    /// Cancels in-flight Photos thumbnail requests; their callers get (nil, nil).
    private func cancelPhotoThumbnailRequests() {
        let requests = photosThumbnailRequests.values
        photosThumbnailRequests.removeAll()
        for request in requests {
            if let requestID = request.requestID {
                photosImageManager.cancelImageRequest(requestID)
            }
            for waiting in request.completions {
                waiting(nil, nil)
            }
        }
    }

    func photoAssetDragInfo(for item: FileItem) -> PhotoAssetDragInfo? {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier),
              let resource = primaryResource(for: asset) else { return nil }
        let filename = resource.originalFilename.isEmpty ? item.name : resource.originalFilename
        let uti = resource.uniformTypeIdentifier.isEmpty
            ? (asset.mediaType == .video ? UTType.movie.identifier : UTType.image.identifier)
            : resource.uniformTypeIdentifier
        return PhotoAssetDragInfo(filename: filename, uti: uti)
    }

    func exportPhotoAsset(for item: FileItem, completion: @escaping (URL?) -> Void) {
        guard let identifier = photosAssetIdentifier(from: item.url),
              let asset = photosAsset(for: identifier) else {
            completion(nil)
            return
        }

        if let cached = photosExportCache[identifier], FileManager.default.fileExists(atPath: cached.path) {
            completion(cached)
            return
        }

        guard let resource = primaryResource(for: asset) else {
            completion(nil)
            return
        }

        let exportURL = photosExportURL(for: identifier, suggestedFilename: resource.originalFilename)
        try? FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: exportURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: exportURL, options: options) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    self.photosExportCache[identifier] = exportURL
                    completion(exportURL)
                } else {
                    completion(nil)
                }
            }
        }
    }

    nonisolated private func photosAssetURL(for identifier: String) -> URL? {
        let scheme = "photos"
        let host = "asset"
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: identifier)]
        return components.url
    }

    nonisolated private func photosAssetIdentifier(from url: URL) -> String? {
        let scheme = "photos"
        let host = "asset"
        guard url.scheme == scheme, url.host == host else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return components?.queryItems?.first(where: { $0.name == "id" })?.value
    }

    nonisolated private func photosSortDescriptors(for sortState: SortState) -> [NSSortDescriptor] {
        switch sortState.column {
        case .dateCreated:
            return [NSSortDescriptor(key: "creationDate", ascending: sortState.direction == .ascending)]
        case .dateModified:
            return [NSSortDescriptor(key: "modificationDate", ascending: sortState.direction == .ascending)]
        default:
            return [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
    }

    private func photosAsset(for identifier: String) -> PHAsset? {
        if let cached = photosAssetCache[identifier] {
            return cached
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        let asset = result.firstObject
        if let asset {
            photosAssetCache[identifier] = asset
        }
        return asset
    }

    nonisolated private func photosAssetName(for asset: PHAsset, fallbackFormatter: DateFormatter) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            return resource.originalFilename
        }
        if let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) {
            return resource.originalFilename
        }
        return photosAssetFallbackName(for: asset, fallbackFormatter: fallbackFormatter)
    }

    nonisolated private func photosAssetFallbackName(for asset: PHAsset, fallbackFormatter: DateFormatter) -> String {
        if let date = asset.creationDate {
            return "Photo \(fallbackFormatter.string(from: date))"
        }
        return "Photo"
    }

    private func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first { $0.type == .video || $0.type == .fullSizeVideo } ?? resources.first
        }
        return resources.first { $0.type == .photo || $0.type == .fullSizePhoto } ?? resources.first
    }

    private func photosExportURL(for identifier: String, suggestedFilename: String) -> URL {
        let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "-")
        let filename = suggestedFilename.isEmpty ? safeIdentifier : "\(safeIdentifier)-\(suggestedFilename)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FlowFinder-PhotosExport", isDirectory: true)
        return folder.appendingPathComponent(filename)
    }

    private func clearPhotosCaches() {
        photosAssetCache.removeAll()
        photosAspectRatioCache.removeAll()
        cancelPhotoThumbnailRequests()
        photosExportCache.removeAll()
        photosImageManager.stopCachingImagesForAllAssets()
        photosSortState = nil
        photosLoadToken = UUID()
        photosLoadCancellation?.cancel()
        photosLoadCancellation = nil
    }

    private func refreshFinderSearchScopeIfNeeded() {
        guard searchMode == .finder, !searchText.isEmpty else { return }
        searchResults = []
        performSearch(query: searchText)
    }

    private func clearFinderSearchIfNeeded() {
        guard searchMode == .finder, !searchText.isEmpty else { return }
        clearSearchQuery()
    }

    // MARK: - Navigation

    /// Bookkeeping before leaving the current location: stops inline previews and resets
    /// per-folder selection state. (Column state is saved when the user changes it, not here.)
    private func prepareForNavigation() {
        stopInlinePreviews()
        cancelPendingRename()
        archiveReadToken = UUID()
        selectedItems.removeAll()
        lastSelectedIndex = 0
        selectionAnchorIndex = 0
        pendingSelectionURL = nil
        pendingSelectionURLs = nil
        pendingNewFolderRenameURL = nil
        // Only applies while the folder entered is shown (`enterFolder` sets it after navigating)
        enteredFolder = nil
    }

    private func resetArchiveState() {
        isInsideArchive = false
        currentArchiveURL = nil
        currentArchivePath = ""
        archiveEntries = []
        archiveEntriesSignature = nil
    }

    /// File URLs without "." / ".." segments (textually, keeping the path form the user navigated
    /// with: /tmp stays /tmp).
    nonisolated static func normalizedLocation(_ url: URL) -> URL {
        url.isFileURL ? url.standardized : url
    }

    /// Whether `url` is the folder that's already shown. Inside an archive or the Photos
    /// library `currentPath` names the enclosing folder, so that never counts.
    private func isShowingFolder(_ url: URL) -> Bool {
        !isInsideArchive && photosLibraryInfo == nil && url.standardizedPathKey == currentPath.standardizedPathKey
    }

    /// Navigates to a folder, leaving archive / Photos browsing if needed.
    func navigateTo(_ url: URL) {
        let url = Self.normalizedLocation(url)
        guard !isShowingFolder(url) else { return }

        prepareForNavigation()
        resetArchiveState()
        photosLibraryInfo = nil
        clearPhotosCaches()
        currentPath = url
        coverFlowSelectedIndex = 0
        applyFolderColumnState(for: url)
        loadContents()
        refreshFinderSearchScopeIfNeeded()
        addToHistory(.filesystem(url))
    }

    /// Navigate to a URL and select the item we came from (path bar, window title menu,
    /// Enclosing Folder, leaving an archive). Leaves archive / Photos browsing in a single history
    /// step, so callers don't need to call `exitArchive()` first.
    func navigateToAndSelectCurrent(_ url: URL) {
        let url = Self.normalizedLocation(url)
        guard !isShowingFolder(url) else { return }
        // The archive, or the folder (or Photos library package) being shown
        let origin: URL? = isInsideArchive ? currentArchiveURL : currentPath

        prepareForNavigation()
        resetArchiveState()
        photosLibraryInfo = nil
        clearPhotosCaches()
        // Select the child of the target on the way to where we were (the folder or archive itself
        // when going to its parent)
        pendingSelectionURL = origin.flatMap { Self.childURL(of: url, leadingTo: $0) }
        currentPath = url
        // Note: Don't reset coverFlowSelectedIndex here - let loadContents set the correct index
        applyFolderColumnState(for: url)
        loadContents()
        refreshFinderSearchScopeIfNeeded()
        addToHistory(.filesystem(url))
    }

    /// The child of `ancestor` on the way to `descendant` ("/a" and "/a/b/c" → "/a/b"), or nil.
    nonisolated static func childURL(of ancestor: URL, leadingTo descendant: URL) -> URL? {
        let ancestorPath = ancestor.standardizedPathKey
        let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
        let descendantPath = descendant.standardizedPathKey
        guard descendantPath.hasPrefix(prefix),
              let component = descendantPath.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return URL(fileURLWithPath: prefix + component)
    }

    func navigateToPhotosLibrary(_ info: PhotosLibraryInfo) {
        prepareForNavigation()
        clearFinderSearchIfNeeded()
        clearPhotosCaches()
        photosLibraryInfo = info
        photosLogger.info("Navigate to Photos library: \(info.libraryURL.path, privacy: .private)")
        resetArchiveState()
        currentPath = info.libraryURL
        coverFlowSelectedIndex = 0
        loadContents()
        addToHistory(.photosLibrary(info))
    }

    /// Enclosing Folder (⌘↑): the parent, with the folder we came from selected, like Finder.
    func navigateToParent() {
        let folder = Self.normalizedLocation(currentPath)
        let parent = folder.deletingLastPathComponent()
        if parent.standardizedPathKey != folder.standardizedPathKey {
            navigateToAndSelectCurrent(parent)
        }
    }

    func goBack() {
        guard canGoBack else { return }
        // Going back to a folder selects the folder (or archive) we're leaving — or the item it was
        // entered from (e.g. an alias) while it's still that folder that's shown
        var selection = isInsideArchive ? currentArchiveURL : currentPath
        if !isInsideArchive, photosLibraryInfo == nil, let enteredFolder,
           enteredFolder.folderKey == currentPath.standardizedPathKey {
            selection = enteredFolder.itemURL
        }
        historyIndex -= 1
        let location = navigationHistory[historyIndex]
        if case .filesystem = location {
            applyNavigationLocation(location, selecting: selection)
        } else {
            applyNavigationLocation(location, selecting: nil)
        }
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        applyNavigationLocation(navigationHistory[historyIndex], selecting: nil)
    }

    private func applyNavigationLocation(_ location: NavigationLocation, selecting selection: URL?) {
        switch location {
        case .filesystem(let url):
            let url = Self.normalizedLocation(url)
            prepareForNavigation()
            resetArchiveState()
            photosLibraryInfo = nil
            clearPhotosCaches()
            pendingSelectionURL = selection
            currentPath = url
            applyFolderColumnState(for: url)
            loadContents()
            refreshFinderSearchScopeIfNeeded()
        case .archive(let archiveURL, let internalPath):
            if currentArchiveURL == archiveURL, !archiveEntries.isEmpty {
                showArchive(archiveURL, entries: archiveEntries, signature: archiveEntriesSignature, at: internalPath)
                return
            }
            stopInlinePreviews()
            readArchiveEntries(at: archiveURL) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let read):
                    self.showArchive(archiveURL, entries: read.entries, signature: read.signature, at: internalPath)
                case .failure(let error):
                    zipNavLogger.error("Failed to restore archive state: \(error.localizedDescription)")
                    self.applyNavigationLocation(.filesystem(archiveURL.deletingLastPathComponent()), selecting: archiveURL)
                }
            }
        case .photosLibrary(let info):
            prepareForNavigation()
            clearFinderSearchIfNeeded()
            resetArchiveState()
            photosLibraryInfo = info
            photosLogger.info("Apply navigation to Photos library: \(info.libraryURL.path, privacy: .private)")
            currentPath = info.libraryURL
            coverFlowSelectedIndex = 0
            loadContents()
        }
    }

    /// Shows a location inside an archive whose entries are already read.
    private func showArchive(_ archiveURL: URL, entries: [ZipEntry], signature: FileSignature?, at internalPath: String) {
        prepareForNavigation()
        photosLibraryInfo = nil
        clearPhotosCaches()
        archiveEntries = entries
        archiveEntriesSignature = signature
        currentArchiveURL = archiveURL
        currentArchivePath = internalPath
        currentPath = archiveURL.deletingLastPathComponent()
        isInsideArchive = true
        coverFlowSelectedIndex = 0
        loadContents()
    }

    /// Reads an archive's entries off the main thread; the spinner only shows if that takes a while.
    /// The signature is the archive file's as it was read (to notice it change later).
    private func readArchiveEntries(
        at archiveURL: URL,
        completion: @escaping (Result<(entries: [ZipEntry], signature: FileSignature?), Error>) -> Void
    ) {
        let token = UUID()
        archiveReadToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // Still reading (the token is replaced when the read completes or is superseded)
            guard let self, self.archiveReadToken == token else { return }
            self.archiveReadSpinnerToken = token
            self.isLoading = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let signature = FileSignature(path: archiveURL.path)
            let result = Result { (entries: try ZipArchiveManager.shared.readContents(of: archiveURL), signature: signature) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.archiveReadToken == token else { return }
                self.archiveReadToken = UUID()
                if case .failure = result, self.archiveReadSpinnerToken == token {
                    self.isLoading = false
                }
                self.archiveReadSpinnerToken = nil
                completion(result)
            }
        }
    }

    func openItem(_ item: FileItem) {
        cancelPendingRename()

        if isPhotosItem(item) {
            exportPhotoAsset(for: item) { url in
                guard let url else {
                    NSSound.beep()
                    return
                }
                NSWorkspace.shared.open(url)
            }
            return
        }

        // Handle items inside an archive
        if item.isFromArchive {
            if item.isDirectory {
                // Navigate into the folder within the archive
                if let archivePath = item.archivePath {
                    navigateInArchive(to: archivePath)
                }
            } else {
                // Extract and open the file
                openArchiveItem(item)
            }
            return
        }

        // Check if this is a ZIP file we should browse into
        if item.isZipArchive {
            enterArchive(at: item.url)
            return
        }

        if !item.url.isFileURL {
            NSWorkspace.shared.open(item.url)
            return
        }

        // Finder aliases are resolved when opened
        if item.isAliasFile {
            openAlias(at: item.url)
            return
        }

        // Packages/bundles (like .app) are opened, not navigated into. Symlinks to folders are
        // directories here (FileItem classifies them by target) and are browsed under their own path.
        if item.isPackage || NSWorkspace.shared.isFilePackage(atPath: item.url.path) {
            NSWorkspace.shared.open(item.url)
        } else if item.isDirectory {
            enterFolder(item.url, from: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Navigate into a folder; `itemURL` is selected when going Back.
    private func enterFolder(_ url: URL, from itemURL: URL) {
        // Clear search when navigating to a folder from search results
        if searchMode != .filter && !searchText.isEmpty {
            searchText = ""
            searchResults = []
        }
        let url = Self.normalizedLocation(url)
        guard !isShowingFolder(url) else { return }
        navigateTo(url)
        // Remembered for this folder only: once another location is shown it no longer applies
        enteredFolder = (url.standardizedPathKey, itemURL)
    }

    /// Resolves a Finder alias (off the main thread: it may have to reach another volume) and
    /// browses into it when it points to a folder, otherwise opens the original.
    private func openAlias(at aliasURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolvedURL = try? URL(resolvingAliasFileAt: aliasURL, options: [.withoutUI])
            let values = try? resolvedURL?.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let resolvedURL else {
                    // The original item can't be found
                    NSSound.beep()
                    return
                }
                if values?.isDirectory == true, values?.isPackage != true {
                    self.enterFolder(resolvedURL, from: aliasURL)
                } else {
                    NSWorkspace.shared.open(resolvedURL)
                }
            }
        }
    }

    /// Show the contents of a package/bundle (navigate into it like a folder)
    func showPackageContents(_ item: FileItem) {
        cancelPendingRename()
        enterFolder(item.url, from: item.url)
    }

    // MARK: - Archive Navigation

    /// Enter a ZIP archive and browse its contents (the archive is read off the main thread)
    func enterArchive(at url: URL) {
        stopInlinePreviews()
        readArchiveEntries(at: url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let read):
                self.prepareForNavigation()
                // Clear search text and tag filter when entering an archive
                // since we're now browsing different content
                if !self.searchText.isEmpty {
                    self.searchText = ""
                }
                if self.filterTag != nil {
                    self.filterTag = nil
                }

                self.archiveEntries = read.entries
                self.archiveEntriesSignature = read.signature
                self.currentArchiveURL = url
                self.currentArchivePath = ""
                self.currentPath = url.deletingLastPathComponent()
                self.isInsideArchive = true
                self.coverFlowSelectedIndex = 0
                self.loadContents()
                self.addToHistory(.archive(archiveURL: url, internalPath: ""))
            case .failure(let error):
                // Fall back to opening with default app
                zipNavLogger.error("Error reading archive: \(error.localizedDescription)")
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Navigate to a path within the current archive ("" is the archive root)
    func navigateInArchive(to path: String) {
        navigateInArchive(to: path, selecting: nil)
    }

    /// `selecting`: the archive path of an item to select there (the folder we came from).
    private func navigateInArchive(to path: String, selecting selectedPath: String?) {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }

        // Directory paths are stored without a trailing slash
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        prepareForNavigation()
        if let selectedPath {
            // How archive items are addressed (see `ZipArchiveManager.fileItems`)
            pendingSelectionURL = URL(fileURLWithPath: archiveURL.path + "#" + selectedPath)
        }
        currentArchivePath = normalizedPath
        coverFlowSelectedIndex = 0
        loadContents()
        addToHistory(.archive(archiveURL: archiveURL, internalPath: normalizedPath))
    }

    /// Exit the current archive and return to the folder containing it (the archive is selected)
    func exitArchive() {
        guard isInsideArchive, let archiveURL = currentArchiveURL else { return }
        navigateToAndSelectCurrent(archiveURL.deletingLastPathComponent())
    }

    /// Navigate up one level (handles both archive and filesystem)
    func navigateUp() {
        if isInsideArchive {
            if currentArchivePath.isEmpty {
                // At archive root, exit the archive
                exitArchive()
            } else {
                // Go up one level within the archive (to the root for a top-level folder),
                // selecting the folder we came from
                let components = currentArchivePath.split(separator: "/")
                navigateInArchive(to: components.dropLast().joined(separator: "/"), selecting: currentArchivePath)
            }
        } else {
            navigateToParent()
        }
    }

    /// Extract and open a file from the archive
    private func openArchiveItem(_ item: FileItem) {
        guard let archiveURL = item.archiveURL,
              let archivePath = item.archivePath else {
            return
        }

        guard !item.isDirectory else { return }

        // Extract on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tempURL = try ZipArchiveManager.shared.extractByPath(archivePath, from: archiveURL)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(tempURL)
                }
            } catch {
                DispatchQueue.main.async {
                    FileOperationAlerts.reportFailures([FileOperationFailure(url: item.url, error: error)], verb: "opened")
                }
            }
        }
    }

    func previewURL(for item: FileItem) -> URL? {
        // Quick Look is disabled for archive items
        if item.isFromArchive {
            return nil
        }
        if let identifier = photosAssetIdentifier(from: item.url) {
            return photosExportCache[identifier]
        }
        return item.url
    }

    /// Completion-based variant used by the Quick Look callers (archive items have no preview URL)
    func previewURL(for item: FileItem, completion: @escaping (URL?) -> Void) {
        completion(previewURL(for: item))
    }

    /// The lead ("focused") item of the selection: the most recently clicked or navigated item
    /// if it is still selected, otherwise the first selected item in display order.
    /// Use this instead of `selectedItems.first` — a Set has no order.
    var primarySelectedItem: FileItem? {
        guard !selectedItems.isEmpty else { return nil }
        if selectedItems.count == 1 { return selectedItems.first }
        let items = filteredItems
        if items.indices.contains(lastSelectedIndex), selectedItems.contains(items[lastSelectedIndex]) {
            return items[lastSelectedIndex]
        }
        return items.first(where: { selectedItems.contains($0) }) ?? selectedItems.first
    }

    /// Selected items in display order.
    var orderedSelectedItems: [FileItem] {
        guard !selectedItems.isEmpty else { return [] }
        if selectedItems.count == 1 { return Array(selectedItems) }
        return filteredItems.filter { selectedItems.contains($0) }
    }

    // Track anchor index for Shift+click range selection
    var lastSelectedIndex: Int = 0
    // Anchor index stays fixed during shift+arrow extend operations
    var selectionAnchorIndex: Int = 0

    func selectItem(_ item: FileItem, extend: Bool = false) {
        if extend {
            if selectedItems.contains(item) {
                selectedItems.remove(item)
            } else {
                selectedItems.insert(item)
            }
        } else {
            selectedItems = [item]
        }
    }

    /// Select a range of items from selectionAnchorIndex to the given index (Shift+click/arrow behavior)
    func selectRange(to index: Int, in items: [FileItem]) {
        guard !items.isEmpty else { return }
        let start = min(selectionAnchorIndex, index)
        let end = max(selectionAnchorIndex, index)
        let clampedStart = max(0, start)
        let clampedEnd = min(items.count - 1, end)

        selectedItems = Set(items[clampedStart...clampedEnd])
        lastSelectedIndex = index
    }

    /// Handle selection with all modifier combinations
    /// - Parameters:
    ///   - clickedOnTextArea: If true, this click can trigger rename (Finder-style: only text label clicks trigger rename)
    func handleSelection(item: FileItem, index: Int, in items: [FileItem], withShift: Bool, withCommand: Bool, allowRename: Bool = true, clickedOnTextArea: Bool = true) {
        let now = Date()
        cancelPendingRename()

        // Cancel any active rename when clicking on a different item
        if renamingURL != nil && renamingURL != item.url {
            renamingURL = nil
        }

        if withShift {
            // Shift+click: select range from anchor to clicked item
            selectRange(to: index, in: items)
            lastClickedURL = nil
        } else if withCommand {
            // Cmd+click: toggle selection
            if selectedItems.contains(item) {
                selectedItems.remove(item)
            } else {
                selectedItems.insert(item)
            }
            lastSelectedIndex = index
            selectionAnchorIndex = index
            lastClickedURL = nil
        } else {
            // Normal click: check for Finder-style rename trigger
            let wasOnlySelected = selectedItems.count == 1 && selectedItems.contains(item)
            let timeSinceLastClick = now.timeIntervalSince(lastClickTime)
            let isSameItem = lastClickedURL == item.url
            let doubleClickInterval = NSEvent.doubleClickInterval

            // If clicking the only selected item after the system double-click interval,
            // schedule rename with a short delay to avoid double-click collisions.
            // Skip rename trigger if:
            // - allowRename is false (e.g., for CoverFlow view)
            // - clickedOnTextArea is false (Finder-style: only clicks on text label trigger rename)
            if allowRename && clickedOnTextArea && wasOnlySelected && isSameItem && timeSinceLastClick > doubleClickInterval && timeSinceLastClick < 3.0 && renamingURL == nil {
                if item.isFromArchive || !item.url.isFileURL || isPhotosItem(item) {
                    NSSound.beep()
                } else {
                    scheduleRename(for: item)
                    lastClickedURL = item.url
                }
            } else {
                // Normal selection
                selectedItems = [item]
                lastSelectedIndex = index
                selectionAnchorIndex = index
                lastClickedURL = item.url
            }
        }

        lastClickTime = now
    }

    /// Starts renaming after the double-click interval, unless another click comes first — so the
    /// second click of a slow double-click opens the item instead of also starting a rename.
    private func scheduleRename(for item: FileItem) {
        cancelPendingRename()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cancelPendingRename()
            guard self.renamingURL == nil else { return }
            guard self.selectedItems.count == 1, self.selectedItems.contains(item) else { return }
            self.renamingURL = item.url
        }
        pendingRenameWorkItem = workItem
        pendingRenameClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.cancelPendingRename()
            }
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    /// Cancel any pending rename operation (e.g., when drag starts)
    func cancelPendingRename() {
        pendingRenameWorkItem?.cancel()
        pendingRenameWorkItem = nil
        if let monitor = pendingRenameClickMonitor {
            NSEvent.removeMonitor(monitor)
            pendingRenameClickMonitor = nil
        }
    }

    /// Trigger rename for a newly created folder after it appears in the loaded items.
    /// Called from loadContents() after items are set and selection is resolved.
    private func triggerPendingNewFolderRename() {
        guard let newFolderURL = pendingNewFolderRenameURL else { return }
        pendingNewFolderRenameURL = nil

        let newFolderPath = newFolderURL.standardizedFileURL.path
        // Dispatch to the next run loop iteration so SwiftUI has a chance to
        // propagate the new items to the FileTableView before we start editing.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.selectedItems.count == 1,
                  let selectedItem = self.selectedItems.first,
                  selectedItem.url.standardizedFileURL.path == newFolderPath else { return }
            self.renamingURL = selectedItem.url
        }
    }

    private func addToHistory(_ location: NavigationLocation) {
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((historyIndex + 1)...)
        }
        navigationHistory.append(location)
        historyIndex = navigationHistory.count - 1
    }

    /// Re-lists the current location. Reloading the folder that's shown is incremental
    /// (no spinner, scroll position, selection and item IDs are kept).
    func refresh() {
        stopInlinePreviews()
        if isInsideArchive {
            // The archive may have changed on disk: read it again (cheap when it hasn't)
            guard isBackgroundWorkActive else {
                needsReloadOnResume = true
                return
            }
            rereadArchive()
            return
        }
        if photosLibraryInfo == nil, currentPath.path != "/Network" {
            // Tags and iCloud status can change behind our back (e.g. edited in Finder)
            FileTagManager.invalidateCache(forDirectory: currentPath)
            if currentFolderIsInICloud {
                CloudStatusManager.shared.invalidate(directory: currentPath)
                cloudStatusLoadedURLs.removeAll()
            }
            tagRefreshToken &+= 1
        }
        loadContents()
    }

    func refreshTags(for urls: [URL], invalidateCache: Bool = true) {
        if invalidateCache {
            FileTagManager.invalidateCache(for: urls)
        }
        tagRefreshToken &+= 1
        // Force UI refresh by sending objectWillChange
        objectWillChange.send()
    }

    func setUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    // MARK: - File Operations & Undo

    /// A long operation shown in the status bar with its progress and a Stop button: a copy out of
    /// an archive, or a copy, move, Move to Trash or delete still running after
    /// `archiveCopyProgressDelay`. (Named after the first of these.)
    struct ArchiveCopyActivity {
        let progress: Progress
        let title: String
    }

    /// This view model's long operations that are running, oldest first.
    @Published private var operationActivities: [ArchiveCopyActivity] = []

    /// The operation shown in the status bar (the most recent one still running), if any.
    var archiveCopyProgress: ArchiveCopyActivity? {
        operationActivities.last
    }

    static let archiveCopyProgressDelay: TimeInterval = 0.5

    /// Whether any file operation is queued or running, in any window. See
    /// `FileOperationEngine.hasPendingOperations` (quitting now would cut a copy short).
    var hasPendingFileOperations: Bool {
        FileOperationEngine.hasPendingOperations
    }

    /// Stops the operation shown in the status bar. What it finished stays done (Undo reverses
    /// it); an item it was copying is removed. A copy out of an archive puts nothing on the clipboard.
    func cancelArchiveCopy() {
        archiveCopyProgress?.progress.cancel()
    }

    /// Shows `progress` in the status bar once it has run for `archiveCopyProgressDelay`.
    private func showActivity(_ progress: Progress, title: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.archiveCopyProgressDelay) { [weak self] in
            guard let self, FileOperationEngine.isRunning(progress), !progress.isCancelled else { return }
            self.operationActivities.append(ArchiveCopyActivity(progress: progress, title: title))
        }
    }

    private func endActivity(_ progress: Progress) {
        if operationActivities.contains(where: { $0.progress === progress }) {
            operationActivities.removeAll { $0.progress === progress }
        }
    }

    /// The window a command's alerts belong to: the browser window it came from. Captured when the
    /// command starts, so a long operation's alerts don't land on whatever window is in front when
    /// it ends.
    private func commandWindow() -> NSWindow? {
        guard let app = NSApp else { return nil }
        return KeyboardManager.shared.keyBrowserWindow() ?? app.mainWindow ?? app.keyWindow
    }

    /// The window under the mouse: where a drop lands (the key window may be another one).
    private static func windowUnderMouse() -> NSWindow? {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return number > 0 ? NSApp?.window(withWindowNumber: number) : nil
    }

    /// Whether items can be pasted, dropped or created in the location shown: not inside an
    /// archive, the Photos library, the Network browser or Spotlight results (Finder doesn't
    /// accept them in a search window either).
    var canAddItemsToCurrentLocation: Bool {
        !isInsideArchive
            && photosLibraryInfo == nil
            && currentPath.isFileURL
            && currentPath.path != "/Network"
            && !(searchMode == .finder && !searchText.isEmpty)
    }

    private func isShownLocation(_ url: URL) -> Bool {
        url.standardizedPathKey == currentPath.standardizedPathKey
    }

    /// Runs `work` on the file-operation queue, shows its progress (titled `title`) if it takes a
    /// while, and reports failures in one alert on `window`.
    ///
    /// With an `actionName`, the undo action is registered right away — in the same event as the
    /// user's command, so the undo stack keeps the order of commands — and reads the journal when
    /// it runs, which is after `work` because the queue is serial. Undoing before `work` has
    /// finished stops it first.
    private func runFileOperation(
        actionName: String?,
        failureVerb: String,
        title: String,
        window: NSWindow?,
        initialFailures: [FileOperationFailure] = [],
        work: @escaping (FileOperationJournal, Progress) -> FileOperationResult,
        completion: ((FileOperationJournal, FileOperationResult) -> Void)? = nil
    ) {
        let journal = FileOperationJournal()
        let progress = Progress(totalUnitCount: 1)
        journal.progress = progress
        FileOperationEngine.operationDidStart(progress)
        showActivity(progress, title: title)
        let undoManager = self.undoManager
        if let actionName {
            FileBrowserViewModel.registerUndo(reversing: journal, actionName: actionName, undoManager: undoManager, viewModel: self, window: window)
        }
        FileOperationEngine.queue.async { [weak self, weak undoManager] in
            var result = progress.isCancelled ? FileOperationResult(wasCancelled: true) : work(journal, progress)
            result.failures.insert(contentsOf: initialFailures, at: 0)
            DispatchQueue.main.async {
                journal.progress = nil
                self?.endActivity(progress)
                FileOperationEngine.operationDidEnd(progress)
                if actionName != nil, journal.steps.isEmpty {
                    // Nothing happened, so there's nothing to undo.
                    undoManager?.removeAllActions(withTarget: journal)
                }
                completion?(journal, result)
                FileOperationAlerts.reportFailures(result.failures, verb: failureVerb, in: window)
            }
        }
    }

    /// Registers an undo action that reverses whatever `journal` records. When it runs (inside
    /// undo or redo) it stops the operation if that is still queued or running, registers its own
    /// reversal immediately, so it lands on the opposite stack, and then does the file work on the
    /// queue.
    private static func registerUndo(
        reversing journal: FileOperationJournal,
        actionName: String,
        undoManager: UndoManager?,
        viewModel: FileBrowserViewModel?,
        window: NSWindow?
    ) {
        guard let undoManager else { return }
        // The handler keeps the journal alive; the undo manager holds its target unowned.
        undoManager.registerUndo(withTarget: journal) { [journal, weak undoManager, weak viewModel, weak window] _ in
            journal.progress?.cancel()
            let reversal = FileOperationJournal()
            let progress = Progress(totalUnitCount: 1)
            reversal.progress = progress
            registerUndo(reversing: reversal, actionName: actionName, undoManager: undoManager, viewModel: viewModel, window: window)
            FileOperationEngine.operationDidStart(progress)
            viewModel?.showActivity(progress, title: "Undoing \(actionName)")
            FileOperationEngine.queue.async {
                let result = FileOperationEngine.reverse(journal.steps, journal: reversal, progress: progress)
                DispatchQueue.main.async {
                    reversal.progress = nil
                    viewModel?.endActivity(progress)
                    FileOperationEngine.operationDidEnd(progress)
                    // Undoing (or redoing) a rename keeps the item's identity, like the rename itself
                    viewModel?.carryItemIDs(movedIn: reversal)
                    FileClipboard.shared.itemsDidMove(reversal.moves)
                    viewModel?.refresh()
                    FileOperationAlerts.reportFailures(result.failures, verb: "restored", in: window)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    private enum TransferOrigin {
        case paste
        case drop
        case duplicate
    }

    /// Why a whole copy or move was refused before anything happened.
    private enum TransferRefusal {
        /// The destination isn't a folder (or is gone).
        case notAFolder
        /// A package (an app, a Photos library, …) isn't a folder things are put in.
        case package
        case intoItself(URL, FileTransferItem.Kind)
        /// Two of the items would get the same name in one folder.
        case sameName(String, FileTransferItem.Kind)
    }

    private struct TransferPlan {
        var items: [FileTransferItem] = []
        var failures: [FileOperationFailure] = []
        var refusal: TransferRefusal?
    }

    /// The one copy/move pipeline behind paste, drop and duplicate: plans the batch off the main
    /// thread (operation per item, refusals, same-folder no-ops), asks about name conflicts, then
    /// runs everything as one undoable operation. `browsedFolder` is the folder being shown when
    /// the items go there: it may be a package (Show Package Contents); other packages are refused.
    /// `completion` gets the journal, or `nil` if nothing was started.
    private func transferItems(
        _ requests: [(source: URL, directory: URL)],
        operation: FileDropOperation,
        origin: TransferOrigin,
        browsedFolder: URL?,
        window: NSWindow?,
        completion: @escaping (FileOperationJournal?) -> Void
    ) {
        FileOperationEngine.planningQueue.async { [weak self] in
            let plan = FileBrowserViewModel.planTransfer(requests, operation: operation, origin: origin, browsedFolder: browsedFolder)
            DispatchQueue.main.async {
                guard let self else {
                    completion(nil)
                    return
                }
                if let refusal = plan.refusal {
                    self.presentTransferRefusal(refusal, window: window)
                    completion(nil)
                    return
                }
                self.resolveConflicts(in: plan.items, window: window) { [weak self] resolved in
                    guard let self, let resolved else {
                        completion(nil)
                        return
                    }
                    let items = resolved.filter { $0.placement != .skip }
                    guard !items.isEmpty || !plan.failures.isEmpty else {
                        completion(nil)
                        return
                    }
                    let allCopies = items.allSatisfy { $0.kind == .copy }
                    let actionName = origin == .duplicate ? "Duplicate" : (allCopies ? "Copy" : "Move")
                    let verb = origin == .duplicate ? "duplicated" : (allCopies ? "copied" : "moved")
                    let progressVerb = origin == .duplicate ? "Duplicating" : (allCopies ? "Copying" : "Moving")
                    let title = items.count == 1
                        ? "\(progressVerb) “\(FileOperationAlerts.displayName(items[0].source))”"
                        : "\(progressVerb) \(items.count) items"
                    self.runFileOperation(
                        actionName: actionName,
                        failureVerb: verb,
                        title: title,
                        window: window,
                        initialFailures: plan.failures,
                        work: { journal, progress in FileOperationEngine.transfer(items, journal: journal, progress: progress) },
                        completion: { journal, _ in
                            completion(journal)
                            // Copied or cut items moved by a drag stay on the clipboard where they are now.
                            FileClipboard.shared.itemsDidMove(journal.moves)
                        }
                    )
                }
            }
        }
    }

    /// Plans a copy/move batch (file-system reads only; runs on the planning queue).
    nonisolated private static func planTransfer(
        _ requests: [(source: URL, directory: URL)],
        operation: FileDropOperation,
        origin: TransferOrigin,
        browsedFolder: URL?
    ) -> TransferPlan {
        var plan = TransferPlan()
        var seenSources = Set<String>()
        /// Destination folders checked so far, with whether their volume has case-sensitive names.
        var caseSensitiveDirectories: [String: Bool] = [:]
        var destinationNames = Set<String>()
        let browsedPath = browsedFolder.map(FileOperationEngine.canonicalPath)

        for (source, directory) in requests {
            let directoryPath = FileOperationEngine.canonicalPath(directory)
            if caseSensitiveDirectories[directoryPath] == nil {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    return TransferPlan(refusal: .notAFolder)
                }
                let values = try? URL(fileURLWithPath: directoryPath)
                    .resourceValues(forKeys: [.isPackageKey, .volumeSupportsCaseSensitiveNamesKey])
                // Dropping onto an app or document package doesn't put things inside it; only a
                // package being browsed (Show Package Contents) takes them.
                if values?.isPackage == true, origin != .duplicate, directoryPath != browsedPath {
                    return TransferPlan(refusal: .package)
                }
                caseSensitiveDirectories[directoryPath] = values?.volumeSupportsCaseSensitiveNames ?? false
            }

            let sourcePath = FileOperationEngine.canonicalItemPath(source)
            guard seenSources.insert(sourcePath).inserted else { continue }
            guard FileOperationEngine.itemExists(at: source) else {
                plan.failures.append(FileOperationFailure(url: source, error: FileOperationEngine.notFoundError(source)))
                continue
            }

            var kind: FileTransferItem.Kind
            switch operation {
            case .copy:
                kind = .copy
            case .move:
                kind = .move
            case .automatic:
                // Finder: move within a volume, copy across volumes.
                kind = FileOperationEngine.isSameVolume(source, directory) == true ? .move : .copy
            }
            if kind == .move && FileOperationEngine.isVolumeRoot(source) {
                // "Moving" a volume would erase it after copying; Finder only copies.
                kind = .copy
            }

            if FileOperationEngine.isPath(directoryPath, sameAsOrInside: sourcePath) {
                // Dropping an item onto itself does nothing; anything else into itself is refused.
                if origin == .drop && directoryPath == sourcePath { continue }
                return TransferPlan(refusal: .intoItself(source, kind))
            }

            let destination = directory.appendingPathComponent(source.lastPathComponent)
            let destinationExists = FileOperationEngine.itemExists(at: destination)
            // Also catches the same folder reached by another path (e.g. through a firmlink).
            let inSameFolder = (sourcePath as NSString).deletingLastPathComponent == directoryPath
                || (destinationExists && FileOperationEngine.isSameItem(source, destination))
            var placement = FileTransferItem.Placement.exact
            if origin == .duplicate {
                placement = .duplicate
            } else if inSameFolder {
                // Moving (or dropping) into the folder it's already in does nothing, as in Finder;
                // pasting a copy there, or ⌥-dragging, makes "name copy".
                if kind == .move || (origin == .drop && operation != .copy) { continue }
                placement = .duplicate
            } else if destinationExists {
                placement = .ask
            }

            if placement != .duplicate {
                // Two items can't take the same name in one folder ("A" and "a" are the same name
                // on a case-insensitive volume). Finder refuses these batches as a whole.
                var key = directoryPath + "/" + source.lastPathComponent.precomposedStringWithCanonicalMapping
                if caseSensitiveDirectories[directoryPath] != true {
                    key = key.lowercased()
                }
                guard destinationNames.insert(key).inserted else {
                    return TransferPlan(refusal: .sameName(FileOperationEngine.displayName(source), kind))
                }
            }
            plan.items.append(FileTransferItem(source: source, destination: destination, kind: kind, placement: placement))
        }
        return plan
    }

    private func presentTransferRefusal(_ refusal: TransferRefusal, window: NSWindow?) {
        NSSound.beep()
        switch refusal {
        case .notAFolder, .package:
            break
        case let .intoItself(source, kind):
            let name = FileOperationAlerts.displayName(source)
            let verb = kind == .move ? "moved" : "copied"
            FileOperationAlerts.showMessage(
                "“\(name)” can’t be \(verb) into itself.",
                information: "The destination is inside the item you’re \(kind == .move ? "moving" : "copying").",
                in: window
            )
        case let .sameName(name, kind):
            FileOperationAlerts.showMessage(
                "The items can’t be \(kind == .move ? "moved" : "copied") because more than one of them is named “\(name)”.",
                information: "Items in the same folder need different names. Rename one of them, then try again.",
                in: window
            )
        }
    }

    /// Finder-style Replace / Keep Both / Skip / Stop for each name conflict, with "Apply to All".
    /// `completion` gets the items with their placements decided, or `nil` for Stop.
    private func resolveConflicts(in items: [FileTransferItem], window: NSWindow?, completion: @escaping ([FileTransferItem]?) -> Void) {
        let conflictIndices = items.indices.filter { items[$0].placement == .ask }
        guard !conflictIndices.isEmpty else {
            completion(items)
            return
        }
        var resolved = items
        var choiceForAll: FileTransferItem.Placement?
        let allowSkip = items.count > 1

        func resolve(from start: Int) {
            var position = start
            while position < conflictIndices.count, let choice = choiceForAll {
                resolved[conflictIndices[position]].placement = choice
                position += 1
            }
            guard position < conflictIndices.count else {
                completion(resolved)
                return
            }
            let index = conflictIndices[position]
            let alert = FileBrowserViewModel.conflictAlert(
                for: resolved[index],
                allowSkip: allowSkip,
                offerApplyToAll: conflictIndices.count - position > 1
            )
            FileOperationAlerts.show(alert, in: window) { response in
                guard let choice = FileBrowserViewModel.conflictChoice(for: response, allowSkip: allowSkip) else {
                    completion(nil)
                    return
                }
                resolved[index].placement = choice
                if alert.suppressionButton?.state == .on {
                    choiceForAll = choice
                }
                resolve(from: position + 1)
            }
        }
        resolve(from: 0)
    }

    private static func conflictAlert(for item: FileTransferItem, allowSkip: Bool, offerApplyToAll: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An item named “\(FileOperationAlerts.displayName(item.destination))” already exists in this location."
        alert.informativeText = "Do you want to replace it with the one you’re \(item.kind == .move ? "moving" : "copying")?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace").hasDestructiveAction = true
        if allowSkip {
            alert.addButton(withTitle: "Skip")
        }
        alert.addButton(withTitle: "Stop").keyEquivalent = "\u{1b}"
        if offerApplyToAll {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Apply to All"
        }
        return alert
    }

    /// Button order: Keep Both, Replace, [Skip], Stop. `nil` means Stop.
    private static func conflictChoice(for response: NSApplication.ModalResponse, allowSkip: Bool) -> FileTransferItem.Placement? {
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .replace
        case .alertThirdButtonReturn where allowSkip:
            return .skip
        default:
            return nil
        }
    }

    @discardableResult
    private func applyTags(
        _ tags: [String],
        to url: URL,
        actionName: String,
        registerUndo: Bool,
        invalidateCache: Bool
    ) -> Bool {
        let beforeTags = FileTagManager.getTags(for: url)
        guard beforeTags != tags else { return true }
        guard FileTagManager.setTags(tags, for: url) else {
            // Nothing changed on disk: no undo entry, show what's really there
            refreshTags(for: [url], invalidateCache: true)
            presentTagEditFailure(for: url)
            return false
        }

        if registerUndo {
            let beforeSnapshot = beforeTags
            self.undoManager?.registerUndo(withTarget: self) { target in
                target.applyTags(
                    beforeSnapshot,
                    to: url,
                    actionName: actionName,
                    registerUndo: true,
                    invalidateCache: invalidateCache
                )
            }
            self.undoManager?.setActionName(actionName)
        }

        refreshTags(for: [url], invalidateCache: invalidateCache)
        return true
    }

    /// Toggles a tag; returns false (and tells the user) when the tags couldn't be written.
    @discardableResult
    func toggleTag(_ tagName: String, for url: URL, invalidateCache: Bool = true) -> Bool {
        let currentTags = FileTagManager.getTags(for: url)
        var updatedTags = currentTags
        if let index = updatedTags.firstIndex(of: tagName) {
            updatedTags.remove(at: index)
        } else {
            updatedTags.append(tagName)
        }
        return applyTags(updatedTags, to: url, actionName: "Tags", registerUndo: true, invalidateCache: invalidateCache)
    }

    /// Sets tags; returns false (and tells the user) when the tags couldn't be written.
    @discardableResult
    func setTags(_ tags: [String], for url: URL, invalidateCache: Bool = true) -> Bool {
        applyTags(tags, to: url, actionName: "Tags", registerUndo: true, invalidateCache: invalidateCache)
    }

    private func presentTagEditFailure(for url: URL) {
        // Only when running as an app (not headless, e.g. in tests)
        guard let app = NSApp, app.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "The tags of “\(url.lastPathComponent)” couldn’t be changed."
        alert.informativeText = "You may not have permission to change this item, or its volume may be read-only."
        alert.alertStyle = .warning
        if let window = app.keyWindow ?? app.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Clipboard Operations

    var canPaste: Bool {
        canAddItemsToCurrentLocation && FileClipboard.shared.canPaste
    }

    /// The selection in display order, followed by any selected items not currently displayed.
    private var selectedItemsInOrder: [FileItem] {
        let ordered = orderedSelectedItems
        guard ordered.count < selectedItems.count else { return ordered }
        let included = Set(ordered)
        return ordered + selectedItems.filter { !included.contains($0) }.sorted { $0.url.path < $1.url.path }
    }

    func copySelectedItems() {
        let itemsToCopy = selectedItemsInOrder
        guard !itemsToCopy.isEmpty else { return }
        guard itemsToCopy.contains(where: { $0.isFromArchive }) else {
            // Plain files: the pasteboard is written right away, so an immediate ⌘V sees it.
            FileClipboard.shared.write(itemsToCopy.map { $0.url }, operation: .copy)
            return
        }

        // Archive entries are extracted to a temp folder first, off the main thread. Each archive
        // item's extraction is a child of `progress` (measured in bytes), cancelled by Stop or by a
        // newer copy. A paste meanwhile waits for it.
        let archiveItems = itemsToCopy.filter(\.isFromArchive)
        let progress = Progress(totalUnitCount: Int64(archiveItems.count))
        let title = itemsToCopy.count == 1
            ? "Copying “\(itemsToCopy[0].displayName)”"
            : "Copying \(itemsToCopy.count) items"
        FileOperationEngine.operationDidStart(progress)
        showActivity(progress, title: title)
        let pendingWrite = FileClipboard.shared.beginDeferredWrite(progress: progress)
        let window = commandWindow()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, itemsToCopy] in
            var urlsToCopy: [URL] = []
            var extractedURLs: [URL] = []
            var failures: [FileOperationFailure] = []
            var partialProblems: [String] = []
            for item in itemsToCopy {
                if progress.isCancelled { break }
                guard item.isFromArchive else {
                    urlsToCopy.append(item.url)
                    continue
                }
                let itemProgress = Progress(totalUnitCount: 0)
                progress.addChild(itemProgress, withPendingUnitCount: 1)
                switch FileBrowserViewModel.extractArchiveItemForCopy(item, progress: itemProgress) {
                case let .extracted(url, problem):
                    urlsToCopy.append(url)
                    extractedURLs.append(url)
                    if let problem {
                        partialProblems.append(problem)
                    }
                case .failed(let failure):
                    failures.append(failure)
                case .cancelled:
                    break
                }
            }

            let wasCancelled = progress.isCancelled
            if wasCancelled {
                // Nothing is copied: drop what was already extracted (the interrupted item's
                // partial output is removed by the extraction itself)
                for url in extractedURLs {
                    ZipArchiveManager.shared.discardCopyExtraction(url)
                }
            }

            DispatchQueue.main.async { [weak self] in
                if !wasCancelled {
                    progress.completedUnitCount = progress.totalUnitCount
                }
                self?.endActivity(progress)
                FileOperationEngine.operationDidEnd(progress)
                let isOnClipboard = FileClipboard.shared.finishDeferredWrite(pendingWrite, urls: wasCancelled ? [] : urlsToCopy)
                guard !wasCancelled else { return }
                if !isOnClipboard, !extractedURLs.isEmpty {
                    // Something else was copied meanwhile: this copy lost.
                    DispatchQueue.global(qos: .utility).async {
                        for url in extractedURLs {
                            ZipArchiveManager.shared.discardCopyExtraction(url)
                        }
                    }
                }
                FileOperationAlerts.reportFailures(failures, verb: "copied", in: window)
                if !partialProblems.isEmpty {
                    FileOperationAlerts.showMessage(
                        "Some items couldn’t be extracted. The rest were copied.",
                        information: partialProblems.joined(separator: "\n"),
                        in: window
                    )
                }
            }
        }
    }

    private enum ArchiveExtraction {
        /// Extracted to `url`; `problem` describes entries of a folder that couldn't be written.
        case extracted(URL, problem: String?)
        case failed(FileOperationFailure)
        case cancelled
    }

    /// Extracts an archive item into a fresh private temp directory for copy/paste, off the main
    /// thread. ZipArchiveManager validates against the archive on disk (path containment, size
    /// caps, CRC, permissions, quarantine). Problems are returned, to be shown in one alert per
    /// copy; a cancelled extraction (via `progress`) has none.
    nonisolated private static func extractArchiveItemForCopy(_ item: FileItem, progress: Progress?) -> ArchiveExtraction {
        guard let archiveURL = item.archiveURL,
              let archivePath = item.archivePath else {
            let error = FileOperationEngine.makeError("It couldn’t be extracted from the archive.")
            return .failed(FileOperationFailure(url: item.url, error: error))
        }

        let result: ZipExtractionResult
        do {
            result = try ZipArchiveManager.shared.extractItemForCopy(archivePath: archivePath, from: archiveURL, progress: progress)
        } catch let error as CocoaError where error.code == .userCancelled {
            return .cancelled
        } catch {
            zipNavLogger.error("Couldn't extract archive item for copy: \(error.localizedDescription)")
            let message = "It couldn’t be extracted from “\(archiveURL.finderDisplayName)”. \(error.localizedDescription)"
            return .failed(FileOperationFailure(url: item.url, error: FileOperationEngine.makeError(message)))
        }

        guard result.failures.isEmpty else {
            zipNavLogger.error("Extracted archive folder for copy with \(result.failures.count) failed entries")
            var lines = result.failures.prefix(5).map { "\($0.path): \($0.error.localizedDescription)" }
            if result.failures.count > 5 {
                lines.append("…and \(result.failures.count - 5) more.")
            }
            let problem = "In “\(item.displayName)”:\n" + lines.joined(separator: "\n")
            return .extracted(result.url, problem: problem)
        }
        return .extracted(result.url, problem: nil)
    }

    func cutSelectedItems() {
        let itemsToCut = selectedItemsInOrder
        guard !itemsToCut.isEmpty else {
            return
        }

        // Items can't be moved out of an archive - cut from archive acts as copy
        if itemsToCut.contains(where: { $0.isFromArchive }) {
            copySelectedItems()
            return
        }

        FileClipboard.shared.write(itemsToCut.map { $0.url }, operation: .cut)
    }

    func paste() {
        paste(to: currentPath)
    }

    func paste(to destination: URL) {
        paste(to: destination, movingItems: false)
    }

    /// ⌥⌘V, Finder's "Move Item Here": moves the clipboard's items into the folder shown, also
    /// when they were copied rather than cut.
    func pasteMovingItems() {
        paste(to: currentPath, movingItems: true)
    }

    private func paste(to destination: URL, movingItems: Bool) {
        let isShown = isShownLocation(destination)
        guard !isInsideArchive, destination.isFileURL, !isShown || canAddItemsToCurrentLocation else {
            NSSound.beep()
            return
        }

        let clipboard = FileClipboard.shared
        if clipboard.isWaitingForDeferredWrite {
            // A copy out of an archive is still being extracted: paste it once it's ready.
            clipboard.pasteWhenReady { [weak self] in
                self?.paste(to: destination, movingItems: movingItems)
            }
            return
        }
        let contents = clipboard.contentsForPaste()
        guard !contents.urls.isEmpty else { return }
        let isMove = contents.isCut || movingItems
        // Archive copy-outs being pasted stay on disk until the paste is done, even if the
        // clipboard changes meanwhile.
        let extractionLease = ZipArchiveManager.shared.leaseCopyExtractions(contents.urls)

        transferItems(
            contents.urls.map { (source: $0, directory: destination) },
            operation: isMove ? .move : .copy,
            origin: .paste,
            browsedFolder: isShown ? destination : nil,
            window: commandWindow()
        ) { [weak self] journal in
            withExtendedLifetime(extractionLease) {}
            guard let journal else { return }
            if isMove {
                FileClipboard.shared.didMoveItems(journal.movedSources)
            }
            guard let self else { return }
            // Select pasted files after refresh
            let pastedURLs = journal.placedURLs
            if !pastedURLs.isEmpty {
                self.pendingSelectionURLs = Set(pastedURLs)
                self.pendingSelectionURL = pastedURLs.first
            }
            self.refresh()
        }
    }

    func deleteSelectedItems() {
        let candidates = selectedItemsInOrder.filter { !$0.isFromArchive && $0.url.isFileURL && !isPhotosItem($0) }
        guard !candidates.isEmpty else {
            NSSound.beep()
            return
        }
        // A second ⌘⌫ while the first is still running: those items are already on their way.
        let urls = candidates.map(\.url).filter { !FileOperationEngine.isBeingRemoved($0) }
        guard !urls.isEmpty else { return }

        let window = commandWindow()
        // Find the item to select after deletion (next item, or previous if at end)
        let nextSelection = selectionAfterRemoving(Set(urls))
        let title = urls.count == 1
            ? "Moving “\(FileOperationAlerts.displayName(urls[0]))” to the Trash"
            : "Moving \(urls.count) items to the Trash"
        FileOperationEngine.beginRemoving(urls)
        runFileOperation(
            actionName: "Move to Trash",
            failureVerb: "moved to the Trash",
            title: title,
            window: window,
            work: { [weak self] journal, progress in
                FileOperationEngine.trash(urls, journal: journal, progress: progress) { trashed in
                    // A long batch takes its rows away as it goes
                    DispatchQueue.main.async {
                        self?.removeItems(at: Set(trashed), nextSelection: nil, reloadListing: false)
                    }
                }
            }
        ) { [weak self] journal, result in
            FileOperationEngine.endRemoving(urls)
            guard let self else { return }
            let trashedURLs = Set(journal.trashedOriginals)
            if !trashedURLs.isEmpty {
                self.removeItems(at: trashedURLs, nextSelection: nextSelection)
                FinderSoundEffects.shared.play(.moveToTrash)
            }
            if !result.volumes.isEmpty {
                self.offerToEject(result.volumes, window: window)
            }
            if !result.trashUnsupported.isEmpty {
                self.confirmDeleteImmediately(result.trashUnsupported, window: window)
            }
        }
    }

    /// ⌥⌘⌫: deletes the selection permanently, without the Trash, after the user confirms.
    /// Can't be undone (no undo action is registered). Never offered for volumes.
    func deleteSelectionImmediately() {
        let urls = selectedItemsInOrder
            .filter { !$0.isFromArchive && $0.url.isFileURL && !isPhotosItem($0) }
            .map(\.url)
            .filter { !FileOperationEngine.isBeingRemoved($0) }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let window = commandWindow()

        let volumes = urls.filter(FileOperationEngine.isMountPoint)
        guard volumes.isEmpty else {
            // Deleting a mount point would erase everything on the volume.
            NSSound.beep()
            FileOperationAlerts.showMessage(
                volumes.count == 1 && urls.count == 1
                    ? "“\(FileOperationAlerts.displayName(volumes[0]))” can’t be deleted because it’s a volume."
                    : "The selected items can’t be deleted because some of them are volumes.",
                information: "Volumes can only be ejected.",
                in: window
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        if urls.count == 1, let url = urls.first {
            alert.messageText = "Are you sure you want to delete “\(FileOperationAlerts.displayName(url))” immediately?"
        } else {
            alert.messageText = "Are you sure you want to delete the \(urls.count) selected items immediately?"
        }
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true

        FileOperationAlerts.show(alert, in: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            // Chosen now: the listing may have changed while the alert was up
            let nextSelection = self.selectionAfterRemoving(Set(urls))
            FileOperationEngine.beginRemoving(urls)
            self.runFileOperation(
                actionName: nil,
                failureVerb: "deleted",
                title: Self.deletingTitle(urls),
                window: window,
                work: { _, progress in FileOperationEngine.deleteImmediately(urls, progress: progress) }
            ) { [weak self] _, _ in
                FileOperationEngine.endRemoving(urls)
                guard let self else { return }
                let deletedURLs = Set(urls.filter { !FileOperationEngine.itemExists(at: $0) })
                if !deletedURLs.isEmpty {
                    self.removeItems(at: deletedURLs, nextSelection: nextSelection)
                }
            }
        }
    }

    private static func deletingTitle(_ urls: [URL]) -> String {
        urls.count == 1 ? "Deleting “\(FileOperationAlerts.displayName(urls[0]))”" : "Deleting \(urls.count) items"
    }

    /// Volumes can't go to the Trash. Like Finder, offer to eject the ones that can be ejected.
    private func offerToEject(_ volumes: [URL], window: NSWindow?) {
        let ejectable = volumes.filter(Self.isEjectableVolume)
        let alert = NSAlert()
        alert.alertStyle = .warning
        if volumes.count == 1 {
            alert.messageText = "“\(FileOperationAlerts.displayName(volumes[0]))” is a volume and can’t be moved to the Trash."
        } else {
            alert.messageText = "\(volumes.count) of the items are volumes and can’t be moved to the Trash."
        }
        if ejectable.isEmpty {
            alert.informativeText = "Volumes can only be ejected."
            alert.addButton(withTitle: "OK")
        } else {
            alert.informativeText = ejectable.count == 1 ? "Do you want to eject it instead?" : "Do you want to eject them instead?"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Eject")
        }
        FileOperationAlerts.show(alert, in: window) { response in
            guard !ejectable.isEmpty, response == .alertSecondButtonReturn else { return }
            for volume in ejectable {
                let isNetwork = (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
                let location = SidebarLocation(name: volume.lastPathComponent, url: volume, isEjectable: true, isNetwork: isNetwork)
                SidebarVolumeEjector.eject(location, window: window)
            }
        }
    }

    /// Removable or external media, disk images and network shares (as the sidebar offers Eject).
    private static func isEjectableVolume(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsRootFileSystem != true else { return false }
        return values.volumeIsLocal == false
            || values.volumeIsEjectable == true
            || values.volumeIsRemovable == true
            || values.volumeIsInternal == false
    }

    /// The item to select once `deletedURLs` are gone: the first remaining item after the first
    /// deleted one in display order, else the closest one before it, with its index after the
    /// removal. Nil when none of them is displayed (e.g. deleted from a Column-view sub-column):
    /// the view showing them picks the next selection.
    private func selectionAfterRemoving(_ deletedURLs: Set<URL>) -> (index: Int, item: FileItem?)? {
        let currentItems = filteredItems
        guard let firstDeletedIndex = currentItems.firstIndex(where: { deletedURLs.contains($0.url) }) else {
            return nil
        }
        let candidates = Array(currentItems[firstDeletedIndex...]) + currentItems[..<firstDeletedIndex].reversed()
        guard let next = candidates.first(where: { !deletedURLs.contains($0.url) }),
              let nextIndex = currentItems.firstIndex(of: next) else {
            return (0, nil)
        }
        let deletedBefore = currentItems[..<nextIndex].filter { deletedURLs.contains($0.url) }.count
        return (nextIndex - deletedBefore, next)
    }

    /// Removes deleted items from the listing and selects `nextSelection` (see
    /// `selectionAfterRemoving`) among the displayed items — never one hidden by the filter or a
    /// search. Without one, the deleted items just leave the selection. `reloadListing` re-lists the
    /// folder: a listing that was already under way would bring the rows back.
    private func removeItems(at removedURLs: Set<URL>, nextSelection: (index: Int, item: FileItem?)?, reloadListing: Bool = true) {
        if items.contains(where: { removedURLs.contains($0.url) }) {
            items.removeAll { removedURLs.contains($0.url) }
        }
        if searchResults.contains(where: { removedURLs.contains($0.url) }) {
            searchResults.removeAll { removedURLs.contains($0.url) }
        }

        if let nextSelection {
            let displayed = filteredItems
            let safeTargetIndex = displayed.isEmpty ? 0 : min(nextSelection.index, displayed.count - 1)
            coverFlowSelectedIndex = safeTargetIndex
            lastSelectedIndex = safeTargetIndex
            selectionAnchorIndex = safeTargetIndex
            if let targetItem = nextSelection.item, !removedURLs.contains(targetItem.url),
               let current = displayed.first(where: { $0.url == targetItem.url }) {
                selectedItems = [current]
            } else if !displayed.isEmpty {
                // The target is gone too: select what's displayed at its position
                selectedItems = [displayed[safeTargetIndex]]
            } else {
                selectedItems.removeAll()
            }
        } else if selectedItems.contains(where: { removedURLs.contains($0.url) }) {
            selectedItems = selectedItems.filter { !removedURLs.contains($0.url) }
        }

        // Clean up hydration tracking
        for url in removedURLs {
            hydratedURLs.remove(url)
            pendingHydrationURLs.remove(url)
        }

        if reloadListing, !isInsideArchive, photosLibraryInfo == nil, currentPath.path != "/Network" {
            loadContents()
        }
    }

    /// Some volumes (many SMB shares, some USB drives) have no Trash. Like Finder, offer to delete
    /// those items immediately — only after an explicit confirmation, since it can't be undone.
    private func confirmDeleteImmediately(_ urls: [URL], window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        if urls.count == 1, let url = urls.first {
            alert.messageText = "“\(FileOperationAlerts.displayName(url))” can’t be moved to the Trash. Do you want to delete it immediately?"
        } else {
            alert.messageText = "\(urls.count) items can’t be moved to the Trash. Do you want to delete them immediately?"
        }
        alert.informativeText = "This volume doesn’t have a Trash. You can’t undo this action."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete Immediately").hasDestructiveAction = true

        FileOperationAlerts.show(alert, in: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            FileOperationEngine.beginRemoving(urls)
            self.runFileOperation(
                actionName: nil,
                failureVerb: "deleted",
                title: Self.deletingTitle(urls),
                window: window,
                work: { _, progress in FileOperationEngine.deleteImmediately(urls, progress: progress) }
            ) { [weak self] _, _ in
                FileOperationEngine.endRemoving(urls)
                self?.refresh()
            }
        }
    }

    /// - Parameter operation: The drop operation resolved by the caller at drop time
    ///   (use `FileDropOperation(modifierFlags:)` with the drop event's modifiers).
    ///   `nil` falls back to the current keyboard modifiers.
    ///   `.automatic` follows Finder: move within a volume, copy across volumes.
    ///   Documents dropped on an application open in it; other packages (and the Photos library,
    ///   the Network browser, Spotlight results) don't take drops.
    /// - Parameter completion: Called once, after the operation finished or was refused.
    func handleDrop(urls: [URL], to destPath: URL? = nil, operation: FileDropOperation? = nil, completion: (() -> Void)? = nil) {
        let destination = destPath ?? currentPath
        let isShown = destPath == nil || isShownLocation(destination)
        guard destination.isFileURL, !isShown || canAddItemsToCurrentLocation else {
            NSSound.beep()
            completion?()
            return
        }
        let window = Self.windowUnderMouse() ?? commandWindow()
        if !isShown, Self.isApplication(destination) {
            openDroppedItems(urls, withApplicationAt: destination, window: window)
            completion?()
            return
        }

        let resolvedOperation = operation ?? FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        // All URLs of one drop are one operation with one undo action.
        transferItems(
            urls.map { (source: $0, directory: destination) },
            operation: resolvedOperation,
            origin: .drop,
            browsedFolder: isShown ? destination : nil,
            window: window
        ) { [weak self] journal in
            if journal != nil {
                self?.refresh()
            }
            completion?()
        }
    }

    private static func isApplication(_ url: URL) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true
    }

    /// Opens dropped documents with the application they were dropped on (Finder).
    private func openDroppedItems(_ urls: [URL], withApplicationAt appURL: URL, window: NSWindow?) {
        let appPath = FileOperationEngine.canonicalPath(appURL)
        let documents = urls.filter { FileOperationEngine.canonicalItemPath($0) != appPath }
        guard !documents.isEmpty else { return }
        let appName = FileOperationAlerts.displayName(appURL.deletingPathExtension())
        NSWorkspace.shared.open(documents, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                FileOperationAlerts.showMessage(
                    "The items couldn’t be opened with “\(appName)”.",
                    information: error.localizedDescription,
                    in: window
                )
            }
        }
    }

    /// ⌥⌘-drag: makes aliases of `urls` in `directory` as one undoable step. Finder names them like
    /// the original, adding " alias" when that name is taken.
    func makeAliases(of urls: [URL], in directory: URL) {
        let isShown = isShownLocation(directory)
        let isPackage = (try? URL(fileURLWithPath: directory.path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        guard !urls.isEmpty, directory.isFileURL, !isShown || canAddItemsToCurrentLocation, isShown || !isPackage else {
            NSSound.beep()
            return
        }
        runFileOperation(
            actionName: "Make Alias",
            failureVerb: "made into an alias",
            title: "Making aliases",
            window: Self.windowUnderMouse() ?? commandWindow(),
            work: { journal, _ in FileOperationEngine.makeAliases(urls, in: directory, journal: journal) }
        ) { [weak self] journal, _ in
            guard let self else { return }
            let aliases = journal.steps.compactMap { step -> URL? in
                if case .created(let url) = step { return url }
                return nil
            }
            if isShown, !aliases.isEmpty {
                self.pendingSelectionURLs = Set(aliases)
                self.pendingSelectionURL = aliases.first
            }
            self.refresh()
        }
    }

    func duplicateSelectedItems() {
        guard !isInsideArchive else {
            NSSound.beep()
            return
        }

        let itemsToDuplicate = selectedItemsInOrder.filter { !$0.isFromArchive && $0.url.isFileURL && !isPhotosItem($0) }
        guard !itemsToDuplicate.isEmpty else {
            NSSound.beep()
            return
        }

        // Each copy goes next to its original (in search results they can be anywhere).
        transferItems(
            itemsToDuplicate.map { (source: $0.url, directory: $0.url.deletingLastPathComponent()) },
            operation: .copy,
            origin: .duplicate,
            browsedFolder: nil,
            window: commandWindow()
        ) { [weak self] journal in
            guard let self, let journal else { return }
            let copies = journal.placedURLs
            if !copies.isEmpty {
                self.pendingSelectionURLs = Set(copies)
                self.pendingSelectionURL = copies.first
            }
            self.refresh()
        }
    }

    /// Renames `item` to `newName`, the full new name as Finder shows it (rename fields get it from
    /// `FileItem.newName(forEditedText:)`). See `requestRename` for the rules. `selectRenamedItem`
    /// selects the item once the listing reloads; without it (a click elsewhere committed the
    /// rename) the selection isn't changed, but a renamed item that's selected stays selected.
    func renameItem(_ item: FileItem, to newName: String, selectRenamedItem: Bool = true) {
        requestRename(item, to: newName, selectRenamedItem: selectRenamedItem)
    }

    private enum RenameOutcome {
        case unchanged
        case renamed(URL)
        case failed
    }

    /// Renames with Finder's rules: "/" is stored as ":" on disk, an existing name is refused
    /// (never replaced), a case-only change is allowed, a name starting with "." is refused (it
    /// would hide the item), a volume isn't renamed, and changing or removing the extension of a
    /// file or package asks first ("Keep" keeps the old extension after the typed name).
    /// `completion` gets the outcome: right away, or once the extension question is answered.
    private func requestRename(_ item: FileItem, to newName: String, selectRenamedItem: Bool, completion: ((RenameOutcome) -> Void)? = nil) {
        guard !item.isFromArchive, item.url.isFileURL, !isPhotosItem(item) else {
            NSSound.beep()
            completion?(.failed)
            return
        }
        guard !newName.isEmpty else {
            completion?(.unchanged)
            return
        }

        let source = item.url
        let fileSystemName = FileOperationEngine.fileSystemName(forDisplayName: newName)
        guard fileSystemName != source.lastPathComponent else {
            completion?(.unchanged)
            return
        }

        let window = commandWindow()
        func refuse(_ message: String, _ information: String) {
            NSSound.beep()
            FileOperationAlerts.showMessage(message, information: information, in: window)
            completion?(.failed)
        }
        if let problem = FileOperationEngine.problemWithFileName(fileSystemName) {
            refuse(problem, "Try using a name with fewer characters, or with no punctuation marks.")
            return
        }
        if fileSystemName.hasPrefix("."), !source.lastPathComponent.hasPrefix(".") {
            refuse("You can’t use a name that begins with a dot “.”, because these names are reserved for the system.",
                   "Please choose another name.")
            return
        }
        if FileOperationEngine.isMountPoint(source) {
            refuse("“\(item.displayName)” can’t be renamed because it’s a volume.",
                   "A volume keeps the name it was given when it was formatted.")
            return
        }

        guard let change = Self.extensionChange(of: item, to: fileSystemName) else {
            let outcome = performRename(item, to: fileSystemName, selectRenamedItem: selectRenamedItem, window: window)
            completion?(outcome)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.informativeText = "If you make this change, your document may open in a different app."
        if change.new.isEmpty {
            alert.messageText = "Are you sure you want to remove the extension “.\(change.old)”?"
            alert.addButton(withTitle: "Keep")
            alert.addButton(withTitle: "Remove")
        } else {
            alert.messageText = "Are you sure you want to change the extension from “.\(change.old)” to “.\(change.new)”?"
            alert.addButton(withTitle: "Keep .\(change.old)")
            alert.addButton(withTitle: "Use .\(change.new)")
        }
        FileOperationAlerts.show(alert, in: window) { [weak self] response in
            guard let self else {
                completion?(.failed)
                return
            }
            let finalName = response == .alertSecondButtonReturn ? fileSystemName : fileSystemName + "." + change.old
            if finalName == source.lastPathComponent {
                completion?(.unchanged)
            } else if let problem = FileOperationEngine.problemWithFileName(finalName) {
                refuse(problem, "Try using a name with fewer characters, or with no punctuation marks.")
            } else {
                // (Not inside `completion?(…)`: that would skip the rename when there's no completion.)
                let outcome = self.performRename(item, to: finalName, selectRenamedItem: selectRenamedItem, window: window)
                completion?(outcome)
            }
        }
    }

    /// The extension change Finder asks about before a file or package is renamed to
    /// `newFileSystemName`: its extension changed or removed. Only extensions of known types count
    /// ("Report v1.2" → "Report v1.3" changes no extension), and a change of case isn't one.
    nonisolated private static func extensionChange(of item: FileItem, to newFileSystemName: String) -> (old: String, new: String)? {
        guard !item.isDirectory || item.isPackage else { return nil }
        let old = (item.name as NSString).pathExtension
        let new = (newFileSystemName as NSString).pathExtension
        guard !old.isEmpty, old.lowercased() != new.lowercased(),
              isKnownExtension(old) || isKnownExtension(new) else { return nil }
        return (old, new)
    }

    nonisolated private static func isKnownExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.isDeclared
    }

    /// Renames right away — it's one rename — and registers its undo.
    @discardableResult
    private func performRename(_ item: FileItem, to fileSystemName: String, selectRenamedItem: Bool, window: NSWindow?) -> RenameOutcome {
        let source = item.url
        let destination = source.deletingLastPathComponent().appendingPathComponent(fileSystemName)
        let isCaseOnlyChange = FileOperationEngine.isSameItem(source, destination)
        if !isCaseOnlyChange && FileOperationEngine.itemExists(at: destination) {
            NSSound.beep()
            FileOperationAlerts.showMessage(
                "The name “\(fileSystemName.finderDisplayName)” is already taken.",
                information: "Please choose a different name.",
                in: window
            )
            return .failed
        }

        do {
            try FileOperationEngine.renameItem(at: source, to: destination, caseOnly: isCaseOnlyChange)
        } catch {
            FileOperationAlerts.reportFailures([FileOperationFailure(url: source, error: error)], verb: "renamed", in: window)
            return .failed
        }

        let journal = FileOperationJournal()
        journal.steps = [.moved(from: source, to: destination)]
        FileBrowserViewModel.registerUndo(reversing: journal, actionName: "Rename", undoManager: undoManager, viewModel: self, window: window)
        FileClipboard.shared.itemDidMove(from: source, to: destination)
        carryItemID(from: source, to: destination)
        if selectRenamedItem {
            // Keep the renamed item selected once the listing reloads.
            pendingSelectionURL = destination
            pendingSelectionURLs = nil
        } else if let selected = selectedItems.first(where: { $0.url == source }) {
            // Still selected: follow it to its new name (the reload drops the old URL).
            var renamedSelection = selectedItems
            renamedSelection.remove(selected)
            renamedSelection.insert(FileItem(url: destination, id: selected.id))
            selectedItems = renamedSelection
        }
        refresh()
        return .renamed(destination)
    }

    /// A renamed item keeps its identity: its ID moves to the new path before the reload, so the
    /// listing updates it in place (views keep its thumbnail and selection) instead of removing it
    /// and inserting a new item. Only for items listed here (not search results from elsewhere).
    private func carryItemID(from source: URL, to destination: URL) {
        guard let id = itemIDsByPath.removeValue(forKey: source.standardizedPathKey) else { return }
        itemIDsByPath[destination.standardizedPathKey] = id
    }

    /// `carryItemID` for every item `journal` moved (an undone or redone rename). Call once the
    /// moves are done and before the reload.
    private func carryItemIDs(movedIn journal: FileOperationJournal) {
        for case let .moved(from, to) in journal.steps {
            carryItemID(from: from, to: to)
        }
    }

    /// Commit current rename and start renaming the next item (Tab behavior)
    func commitRenameAndNext(currentItem: FileItem, newName: String) {
        commitRenameAndAdvance(currentItem: currentItem, newName: newName, offset: 1)
    }

    /// Commit current rename and start renaming the previous item (Shift+Tab behavior)
    func commitRenameAndPrevious(currentItem: FileItem, newName: String) {
        commitRenameAndAdvance(currentItem: currentItem, newName: newName, offset: -1)
    }

    /// `newName` is the text typed in the rename field ("" = don't rename). It gets the same naming
    /// rule as a plain commit (`FileItem.newName(forEditedText:)`) and the same checks (`requestRename`).
    /// Next/previous follow the displayed order.
    private func commitRenameAndAdvance(currentItem: FileItem, newName: String, offset: Int) {
        // Find the item to rename next before the rename reloads the listing
        let displayedItems = filteredItems
        var nextItem: FileItem?
        var nextIndex = 0
        if let currentIndex = displayedItems.firstIndex(where: { $0.url == currentItem.url }) {
            let candidate = currentIndex + offset
            if displayedItems.indices.contains(candidate), !displayedItems[candidate].isFromArchive {
                nextItem = displayedItems[candidate]
                nextIndex = candidate
            }
        }

        let advance: (Bool) -> Void = { [weak self] didRename in
            guard let self else { return }
            guard let nextItem else {
                // No next item or it's not renamable - just clear rename state
                self.renamingURL = nil
                return
            }
            self.selectedItems = [nextItem]
            self.lastSelectedIndex = nextIndex
            self.selectionAnchorIndex = nextIndex
            if didRename {
                // The rename reloads the listing; keep the next item selected through it.
                self.pendingSelectionURL = nextItem.url
                self.pendingSelectionURLs = nil
            }
            // Small delay to allow the rename to complete before starting new one
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.renamingURL = nextItem.url
            }
        }

        guard let finalName = currentItem.newName(forEditedText: newName) else {
            advance(false)
            return
        }
        var isDecided = false
        requestRename(currentItem, to: finalName, selectRenamedItem: false) { [weak self] outcome in
            isDecided = true
            switch outcome {
            case .failed:
                self?.renamingURL = nil
            case .renamed:
                advance(true)
            case .unchanged:
                advance(false)
            }
        }
        if !isDecided {
            // Waiting for the extension question; the field closes meanwhile.
            renamingURL = nil
        }
    }

    func getInfo() {
        guard let item = primarySelectedItem else { return }
        guard !item.isFromArchive else {
            NSSound.beep()
            return
        }
        infoItem = item
        NotificationCenter.default.post(name: .showGetInfo, object: item)
    }

    func showInFinder() {
        let urls: [URL]
        if selectedItems.isEmpty {
            if isInsideArchive, let archiveURL = currentArchiveURL {
                urls = [archiveURL]
            } else {
                urls = [currentPath]
            }
        } else {
            urls = selectedItems.compactMap { item in
                if item.isFromArchive {
                    return item.archiveURL
                }
                return item.url
            }
        }

        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// New Folder in the folder shown (see `createNewFolder(in:)`).
    func createNewFolder() {
        createNewFolder(in: currentPath)
    }

    /// Creates "untitled folder" in `directory` right away (a single mkdir), then selects it and
    /// starts renaming it: in the folder shown once the listing has it; in another folder (a Column
    /// view sub-column) right away, for the view showing that folder. Returns the new folder.
    @discardableResult
    func createNewFolder(in directory: URL) -> URL? {
        let isShown = isShownLocation(directory)
        guard !isInsideArchive, directory.isFileURL, !isShown || canAddItemsToCurrentLocation else {
            NSSound.beep()
            return nil
        }

        let window = commandWindow()
        let folderURL = FileOperationEngine.uniqueDestinationURL(for: directory.appendingPathComponent("untitled folder"))
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
        } catch {
            FileOperationAlerts.reportFailures([FileOperationFailure(url: folderURL, error: error)], verb: "created", in: window)
            return nil
        }

        let journal = FileOperationJournal()
        journal.steps = [.created(folderURL)]
        FileBrowserViewModel.registerUndo(reversing: journal, actionName: "New Folder", undoManager: undoManager, viewModel: self, window: window)
        if isShown {
            pendingSelectionURL = folderURL
            pendingSelectionURLs = nil
            pendingNewFolderRenameURL = folderURL
            refresh()
        } else {
            selectedItems = [FileItem(url: folderURL)]
            renamingURL = folderURL
        }
        return folderURL
    }

    func selectAll() {
        selectedItems = Set(filteredItems)
    }

    // MARK: - Search

    /// Perform search based on current search mode
    func performSearch(query: String) {
        performSearch(query: query, mode: searchMode)
    }

    private func performSearch(query: String, mode: SearchMode) {
        // Cancel any existing search
        cancelSearch()

        guard !query.isEmpty else {
            searchResults = []
            return
        }

        switch mode {
        case .filter:
            // Filter mode doesn't use async search
            return
        case .finder:
            guard isBackgroundWorkActive else {
                searchNeedsRerunOnResume = true
                return
            }
            isSearching = true
            performFinderSearch(query: query)
        }
    }

    /// Cancel any ongoing search
    func cancelSearch() {
        spotlightSearch?.stop()
        spotlightSearch = nil
        spotlightSearchToken = UUID()
        isSearching = false
    }

    func clearSearchQuery() {
        cancelSearch()
        searchResults = []
        searchText = ""
        spotlightIDsByPath.removeAll()
    }

    /// Perform Finder search using NSMetadataQuery (Spotlight)
    private func performFinderSearch(query: String) {
        searchDebugLogger.debug("Starting Spotlight search, \(query.count) characters")
        let token = UUID()
        spotlightSearchToken = token
        let session = SpotlightSearchSession(
            queryString: query,
            scope: currentPath,
            idsByPath: spotlightIDsByPath,
            sortState: sortState,
            foldersFirst: AppSettings.shared.foldersFirst
        ) { [weak self] delivery in
            guard let self, self.spotlightSearchToken == token else { return }
            self.spotlightIDsByPath = delivery.idsByPath
            self.searchResults = delivery.results
            // Sorted off the main thread: use it as the sorted cache when the sort still matches
            let foldersFirst = AppSettings.shared.foldersFirst
            if delivery.sortState == self.sortState, delivery.foldersFirst == foldersFirst {
                self.sortedSearchResultsCacheKey = self.currentSearchResultsCacheKey(sortState: delivery.sortState, foldersFirst: foldersFirst)
                self.sortedSearchResultsCache = delivery.results
                self.sortedSearchResultsStructuralToken = delivery.structuralToken
            }
            self.isSearching = false
        }
        spotlightSearch = session
        session.start()
    }

}

extension FileBrowserViewModel: NetworkServiceBrowserDelegate {
    fileprivate func networkServiceBrowser(_ browser: NetworkServiceBrowser, didUpdate services: [NetworkServiceInfo], isFinal: Bool) {
        updateNetworkItems(from: services, isFinal: isFinal)
    }
}

extension FileBrowserViewModel: SMBSubnetScannerDelegate {
    fileprivate func smbSubnetScanner(_ scanner: SMBSubnetScanner, didDiscover hosts: [SMBHostInfo]) {
        guard isNetworkBrowsing, currentPath.path == "/Network" else { return }
        discoveredSMBHosts = hosts
        rebuildNetworkItems()
        if isLoading && !items.isEmpty {
            isLoading = false
        }
    }

    fileprivate func smbSubnetScannerDidFinish(_ scanner: SMBSubnetScanner) {
        // Ensure we rebuild one final time with all results
        if isNetworkBrowsing, currentPath.path == "/Network" {
            networkScanFinished = true
            rebuildNetworkItems()
        }
    }
}

// MARK: - Spotlight Search

/// Runs one Spotlight query with its notifications on a private serial queue and builds the
/// FileItems there from the attributes Spotlight returns (no per-result file system reads on
/// main). Live updates are applied incrementally (only added, removed and changed results are
/// rebuilt), notifications are batched, and results are delivered sorted in the pane's sort so
/// the main thread doesn't sort them. IDs stay stable per path across updates and queries.
private final class SpotlightSearchSession: @unchecked Sendable {
    struct Delivery {
        let results: [FileItem]
        let sortState: SortState
        let foldersFirst: Bool
        let structuralToken: Int
        let idsByPath: [String: UUID]
    }

    private let query = NSMetadataQuery()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flowfinder.spotlight"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let cancellation = LoadCancellationFlag()
    private var observers: [NSObjectProtocol] = []
    /// Accessed on `queue` only
    private var idsByPath: [String: UUID]
    /// The current results by Spotlight item (the query keeps its items across updates).
    /// Accessed on `queue` only.
    private var entries: [ObjectIdentifier: (result: NSMetadataItem, item: FileItem)] = [:]
    private let sortLock = NSLock()
    private var sort: (state: SortState, foldersFirst: Bool)
    private let deliver: @MainActor (Delivery) -> Void
    private static let maxRememberedIDs = 50_000

    init(queryString: String,
         scope: URL,
         idsByPath: [String: UUID],
         sortState: SortState,
         foldersFirst: Bool,
         deliver: @escaping @MainActor (Delivery) -> Void) {
        self.idsByPath = idsByPath
        self.sort = (sortState, foldersFirst)
        self.deliver = deliver
        // Build predicate for filename search in the scope folder and its subfolders
        query.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", queryString)
        query.searchScopes = [scope]
        query.operationQueue = queue
        // Live updates arrive at most this often (each one re-sorts and re-renders the results)
        query.notificationBatchingInterval = 0.5
    }

    deinit {
        stop()
    }

    /// The sort the next deliveries use (the pane's sort changed).
    func setSort(_ sortState: SortState, foldersFirst: Bool) {
        sortLock.lock()
        sort = (sortState, foldersFirst)
        sortLock.unlock()
    }

    func start() {
        let gathered = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil) { [weak self] _ in
            // Posted on the query's operation queue
            self?.collectAllResults()
        }
        let updated = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: nil) { [weak self] notification in
            self?.applyUpdate(notification.userInfo)
        }
        observers = [gathered, updated]
        let query = self.query
        queue.addOperation {
            query.start()
        }
    }

    func stop() {
        guard !cancellation.isCancelled else { return }
        cancellation.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        let query = self.query
        queue.addOperation {
            query.stop()
        }
    }

    /// Builds every result (gathering finished, or an update that couldn't be applied
    /// incrementally). Runs on `queue`.
    private func collectAllResults() {
        guard !cancellation.isCancelled else { return }
        query.disableUpdates()
        if idsByPath.count > Self.maxRememberedIDs {
            idsByPath.removeAll()
        }
        entries.removeAll(keepingCapacity: true)
        for index in 0..<query.resultCount {
            guard let result = query.result(at: index) as? NSMetadataItem else { continue }
            addEntry(for: result)
        }
        query.enableUpdates()
        deliverResults()
    }

    /// Applies a live update: only added, removed and changed results are rebuilt. Runs on `queue`.
    private func applyUpdate(_ userInfo: [AnyHashable: Any]?) {
        guard !cancellation.isCancelled else { return }
        let removed = userInfo?[NSMetadataQueryUpdateRemovedItemsKey] as? [NSMetadataItem] ?? []
        let added = userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
        let changed = userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
        guard userInfo != nil, !(removed.isEmpty && added.isEmpty && changed.isEmpty) else {
            collectAllResults()
            return
        }
        query.disableUpdates()
        var isConsistent = true
        for result in removed where entries.removeValue(forKey: ObjectIdentifier(result)) == nil {
            isConsistent = false
        }
        for result in added + changed {
            addEntry(for: result)
        }
        query.enableUpdates()
        guard isConsistent else {
            // A removed result we never had: rebuild from the query
            collectAllResults()
            return
        }
        deliverResults()
    }

    /// Runs on `queue`
    private func addEntry(for result: NSMetadataItem) {
        guard let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else {
            entries.removeValue(forKey: ObjectIdentifier(result))
            return
        }
        let id: UUID
        if let existing = idsByPath[path] {
            id = existing
        } else {
            id = UUID()
            idsByPath[path] = id
        }
        entries[ObjectIdentifier(result)] = (result, Self.makeItem(from: result, path: path, id: id))
    }

    /// Sorts the results here, off the main thread, and hands them to the view model. Runs on `queue`.
    private func deliverResults() {
        sortLock.lock()
        let sort = self.sort
        sortLock.unlock()
        let results = ListColumnConfigManager.sortedItems(entries.values.map(\.item), sortState: sort.state, foldersFirst: sort.foldersFirst)
        let delivery = Delivery(
            results: results,
            sortState: sort.state,
            foldersFirst: sort.foldersFirst,
            structuralToken: FileBrowserViewModel.structuralToken(for: results),
            idsByPath: idsByPath
        )
        let cancellation = self.cancellation
        let deliver = self.deliver
        DispatchQueue.main.async {
            guard !cancellation.isCancelled else { return }
            MainActor.assumeIsolated {
                deliver(delivery)
            }
        }
    }

    private static func makeItem(from result: NSMetadataItem, path: String, id: UUID) -> FileItem {
        guard let typeIdentifier = result.value(forAttribute: kMDItemContentType as String) as? String,
              let contentType = UTType(typeIdentifier) else {
            // Not fully indexed: read from the file system (we're off the main thread)
            return FileItem(url: URL(fileURLWithPath: path), id: id, loadMetadata: true)
        }
        // Folders and packages conform to public.directory
        let isDirectory = contentType.conforms(to: .directory)
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        let size = (result.value(forAttribute: kMDItemFSSize as String) as? NSNumber)?.int64Value ?? 0
        return FileItem(
            id: id,
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: size,
            modificationDate: result.value(forAttribute: kMDItemFSContentChangeDate as String) as? Date,
            creationDate: result.value(forAttribute: kMDItemFSCreationDate as String) as? Date,
            contentType: contentType
        )
    }
}

// MARK: - Bonjour Browsing

fileprivate struct NetworkServiceInfo: Hashable {
    let key: String
    let name: String
    let scheme: String
    let hostName: String?
    let port: Int
    let priority: Int
}

@MainActor
fileprivate protocol NetworkServiceBrowserDelegate: AnyObject {
    func networkServiceBrowser(_ browser: NetworkServiceBrowser, didUpdate services: [NetworkServiceInfo], isFinal: Bool)
}

/// Bonjour browsing for SMB/AFP hosts. Used on the main thread (NetService callbacks arrive on
/// the run loop it was scheduled on); delegate updates are delivered on the main queue.
fileprivate final class NetworkServiceBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private weak var delegate: NetworkServiceBrowserDelegate?
    private var browsers: [NetServiceBrowser] = []
    private var netServices: [String: NetService] = [:]
    private var services: [String: NetworkServiceInfo] = [:]
    private let serviceTypes = ["_smb._tcp.", "_afp._tcp.", "_workstation._tcp."]

    init(delegate: NetworkServiceBrowserDelegate) {
        self.delegate = delegate
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        for type in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "")
        }
    }

    func stop() {
        for browser in browsers {
            browser.delegate = nil
            browser.stop()
        }
        browsers.removeAll()
        for service in netServices.values {
            service.delegate = nil
            service.stop()
        }
        netServices.removeAll()
        services.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = serviceKey(for: service)
        guard netServices[key] == nil else { return }

        netServices[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
        updateServiceInfo(for: service)
        notifyDelegate(isFinal: !moreComing)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = serviceKey(for: service)
        netServices.removeValue(forKey: key)
        services.removeValue(forKey: key)
        notifyDelegate(isFinal: !moreComing)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        updateServiceInfo(for: sender)
        notifyDelegate(isFinal: true)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        updateServiceInfo(for: sender)
        notifyDelegate(isFinal: true)
    }

    private func updateServiceInfo(for service: NetService) {
        let key = serviceKey(for: service)
        let scheme = schemeForType(service.type)
        let priority = priorityForType(service.type)
        let info = NetworkServiceInfo(
            key: key,
            name: service.name,
            scheme: scheme,
            hostName: service.hostName,
            port: service.port,
            priority: priority
        )
        services[key] = info
    }

    private func notifyDelegate(isFinal: Bool) {
        let snapshot = Array(services.values)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.delegate?.networkServiceBrowser(self, didUpdate: snapshot, isFinal: isFinal)
            }
        }
    }

    private func serviceKey(for service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func schemeForType(_ type: String) -> String {
        if type.contains("_afp._tcp") {
            return "afp"
        }
        return "smb"
    }

    private func priorityForType(_ type: String) -> Int {
        if type.contains("_smb._tcp") {
            return 2
        }
        if type.contains("_afp._tcp") {
            return 1
        }
        if type.contains("_workstation._tcp") {
            return 0
        }
        return 0
    }
}

// MARK: - Directory Watcher

/// Watches one folder with FSEvents and reports changed direct children, and when the folder itself
/// (or a folder above it) is renamed, moved or deleted (`rootChanged`). Paths are mapped to the
/// folder's displayed form (FSEvents reports resolved paths such as /private/tmp for /tmp or a
/// symlinked folder's target). Callbacks are delivered on the main queue.
private final class DirectoryWatcher {
    typealias Callback = @MainActor (_ childPaths: [String], _ needsRescan: Bool, _ rootChanged: Bool, _ watchedPath: String) -> Void

    /// Per-stream state, retained by the stream through its context
    fileprivate final class StreamContext {
        let displayPath: String
        let callback: Callback
        /// Resolved on the stream's queue on first use (realpath may touch the disk)
        lazy var resolvedPath: String = resolvedFilesystemPath(displayPath)

        init(displayPath: String, callback: @escaping Callback) {
            self.displayPath = displayPath
            self.callback = callback
        }

        /// Maps an event path to the displayed form, or nil when it's outside the watched folder.
        func displayFormPath(for eventPath: String) -> String? {
            var path = eventPath
            if path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            let displayPrefix = displayPath == "/" ? "/" : displayPath + "/"
            if path == displayPath || path.hasPrefix(displayPrefix) {
                return path
            }
            let resolved = resolvedPath
            guard resolved != displayPath else { return nil }
            if path == resolved {
                return displayPath
            }
            let resolvedPrefix = resolved == "/" ? "/" : resolved + "/"
            if path.hasPrefix(resolvedPrefix) {
                return displayPrefix + path.dropFirst(resolvedPrefix.count)
            }
            return nil
        }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.coverflowfinder.directorywatcher", qos: .utility)
    private let callback: Callback
    /// Displayed path of the watched folder (nil when stopped)
    private(set) var watchedPath: String?

    init(callback: @escaping Callback) {
        self.callback = callback
    }

    func start(watching path: String) {
        if watchedPath == path, stream != nil { return }
        stop()

        let context = StreamContext(displayPath: path, callback: callback)
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<StreamContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<StreamContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.eventCallback,
            &streamContext,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        self.stream = stream
        watchedPath = path
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Stops watching; `start` then watches again even for the same path.
    func stop() {
        watchedPath = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    private static let eventCallback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
        guard let clientInfo else { return }
        let context = Unmanaged<StreamContext>.fromOpaque(clientInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let droppedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let scanFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let rootFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        let goneFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)

        var childPaths: [String] = []
        var needsRescan = false
        var rootChanged = false
        for (index, eventPath) in paths.enumerated() where index < numEvents {
            let flags = eventFlags[index]
            if flags & rootFlag != 0 {
                // The watched folder or one above it was renamed, moved or deleted (WatchRoot)
                rootChanged = true
                continue
            }
            if flags & droppedFlags != 0 {
                needsRescan = true
                continue
            }
            guard let path = context.displayFormPath(for: eventPath) else {
                // Coalesced events for an ancestor of the watched folder
                if flags & scanFlag != 0, context.displayPath.hasPrefix(eventPath) {
                    needsRescan = true
                }
                continue
            }
            if path == context.displayPath {
                if flags & scanFlag != 0 {
                    needsRescan = true
                }
                if flags & goneFlags != 0 {
                    // The folder itself was renamed or removed (checked against the disk)
                    rootChanged = true
                }
                continue
            }
            // Only direct children affect the listing
            if (path as NSString).deletingLastPathComponent == context.displayPath {
                childPaths.append(path)
            }
        }
        guard needsRescan || rootChanged || !childPaths.isEmpty else { return }

        let callback = context.callback
        let watchedPath = context.displayPath
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                callback(childPaths, needsRescan, rootChanged, watchedPath)
            }
        }
    }
}

// MARK: - SMB Network Scanner

fileprivate struct SMBHostInfo: Hashable {
    let ipAddress: String
    let name: String
    let port: Int
}

@MainActor
fileprivate protocol SMBSubnetScannerDelegate: AnyObject {
    func smbSubnetScanner(_ scanner: SMBSubnetScanner, didDiscover hosts: [SMBHostInfo])
    func smbSubnetScannerDidFinish(_ scanner: SMBSubnetScanner)
}

/// Scans the local subnet for SMB hosts (port 445). `start`/`stop` and the delegate callbacks
/// run on the main thread; probes run on a bounded operation queue and their results are
/// accumulated serially, then published to main.
fileprivate final class SMBSubnetScanner {
    private weak var delegate: SMBSubnetScannerDelegate?
    /// At most this many blocking connect/reverse-DNS probes run at once
    static let maxConcurrentProbes = 16
    private let probeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.flowfinder.smbscanner"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = SMBSubnetScanner.maxConcurrentProbes
        return queue
    }()
    /// Main thread only
    private var isScanning = false
    private var scanCancellation: LoadCancellationFlag?
    private static let smbPort: UInt16 = 445
    private static let connectionTimeout: TimeInterval = 0.3

    init(delegate: SMBSubnetScannerDelegate) {
        self.delegate = delegate
    }

    deinit {
        scanCancellation?.cancel()
        probeQueue.cancelAllOperations()
    }

    func start() {
        guard !isScanning else { return }
        isScanning = true
        let cancellation = LoadCancellationFlag()
        scanCancellation = cancellation

        // Get local network info and calculate subnet range
        guard let (localIP, netmask) = Self.getLocalNetworkInfo() else {
            finishScanning(cancellation)
            return
        }
        let ipRange = Self.calculateIPRange(localIP: localIP, netmask: netmask)
        guard !ipRange.isEmpty else {
            finishScanning(cancellation)
            return
        }

        let results = SerialResultAccumulator<SMBHostInfo>()
        // Skip our own IP
        for ip in ipRange where ip != localIP {
            probeQueue.addOperation { [weak self] in
                guard !cancellation.isCancelled, Self.checkSMBPort(ip: ip) else { return }
                let hostName = Self.resolveHostName(ip: ip) ?? ip
                let hostInfo = SMBHostInfo(ipAddress: ip, name: hostName, port: Int(Self.smbPort))
                results.append(hostInfo) { [weak self] hosts in
                    // Main queue, snapshots in discovery order
                    guard let self, !cancellation.isCancelled else { return }
                    MainActor.assumeIsolated {
                        self.delegate?.smbSubnetScanner(self, didDiscover: hosts)
                    }
                }
            }
        }
        // Runs once every probe has finished
        probeQueue.addBarrierBlock { [weak self] in
            self?.finishScanning(cancellation)
        }
    }

    func stop() {
        scanCancellation?.cancel()
        scanCancellation = nil
        probeQueue.cancelAllOperations()
        isScanning = false
    }

    private func finishScanning(_ cancellation: LoadCancellationFlag) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            self.isScanning = false
            self.scanCancellation = nil
            MainActor.assumeIsolated {
                self.delegate?.smbSubnetScannerDidFinish(self)
            }
        }
    }

    private static func getLocalNetworkInfo() -> (ip: String, netmask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            // Look for common interface names (en0 is usually WiFi, en1 ethernet)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var netmaskHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            // Get IP address
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                       &hostname, socklen_t(hostname.count),
                       nil, 0, NI_NUMERICHOST)

            // Get netmask
            if let netmask = interface.ifa_netmask {
                getnameinfo(netmask, socklen_t(netmask.pointee.sa_len),
                           &netmaskHost, socklen_t(netmaskHost.count),
                           nil, 0, NI_NUMERICHOST)
            }

            let ip = String(cString: hostname)
            let mask = String(cString: netmaskHost)

            // Skip loopback and link-local addresses
            guard !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") else { continue }
            guard !ip.isEmpty && !mask.isEmpty else { continue }

            return (ip, mask)
        }
        return nil
    }

    private static func calculateIPRange(localIP: String, netmask: String) -> [String] {
        let ipParts = localIP.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt32($0) }

        guard ipParts.count == 4, maskParts.count == 4 else { return [] }

        let ip = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let mask = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]

        let network = ip & mask
        let broadcast = network | ~mask

        // Limit scan to /24 or smaller to avoid scanning huge ranges
        let hostCount = broadcast - network
        guard hostCount > 0 && hostCount <= 254 else {
            // For larger networks, just scan first 254 hosts
            var range: [String] = []
            for i: UInt32 in 1...254 {
                let hostIP = network + i
                let a = (hostIP >> 24) & 0xFF
                let b = (hostIP >> 16) & 0xFF
                let c = (hostIP >> 8) & 0xFF
                let d = hostIP & 0xFF
                range.append("\(a).\(b).\(c).\(d)")
            }
            return range
        }

        var range: [String] = []
        for hostIP in (network + 1)..<broadcast {
            let a = (hostIP >> 24) & 0xFF
            let b = (hostIP >> 16) & 0xFF
            let c = (hostIP >> 8) & 0xFF
            let d = hostIP & 0xFF
            range.append("\(a).\(b).\(c).\(d)")
        }
        return range
    }

    private static func checkSMBPort(ip: String) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }

        // Set non-blocking
        let flags = fcntl(socket, F_GETFL, 0)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = smbPort.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return true
        }

        if errno == EINPROGRESS {
            // Use poll to wait for connection with timeout
            var pfd = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            let timeoutMs = Int32(connectionTimeout * 1000)
            let pollResult = poll(&pfd, 1, timeoutMs)

            if pollResult > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                var error: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &len)
                return error == 0
            }
        }

        return false
    }

    private static func resolveHostName(ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, ip, &addr.sin_addr)

        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, 0)
            }
        }

        if result == 0 {
            let name = String(cString: hostname)
            // Remove .local suffix if present
            if name.hasSuffix(".local") {
                return String(name.dropLast(6))
            }
            // Don't return if it's just the IP address
            if name != ip {
                return name
            }
        }
        return nil
    }
}

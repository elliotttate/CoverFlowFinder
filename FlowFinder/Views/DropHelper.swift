import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

private let dropLog = OSLog(subsystem: "com.coverflowfinder.app", category: "Drop")

// MARK: - Drop operation

/// What a file drop should do. Resolve it at drop time from the drop event's modifiers.
enum FileDropOperation: Equatable {
    /// Finder semantics: move within the same volume, copy across volumes.
    case automatic
    case copy
    case move

    /// Option forces copy, Command forces move, otherwise automatic.
    init(modifierFlags: NSEvent.ModifierFlags) {
        if modifierFlags.contains(.option) {
            self = .copy
        } else if modifierFlags.contains(.command) {
            self = .move
        } else {
            self = .automatic
        }
    }
}

// MARK: - Drop Helper
// Shared utilities for drag and drop operations

enum DropHelper {
    /// Types the main content drop targets accept: file URLs, plus file promises (Mail, Photos, Safari).
    static let acceptedDropTypes: [UTType] = {
        var types: [UTType] = [.fileURL]
        for identifier in NSFilePromiseReceiver.readableDraggedTypes {
            let type = UTType(identifier) ?? UTType(importedAs: identifier)
            if !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }()

    /// File-promise types only (see `acceptedDropTypes`).
    static var filePromiseTypes: [UTType] {
        Array(acceptedDropTypes.dropFirst())
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.coverflowfinder.filepromises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    // MARK: URL collection

    /// Extracts a file URL from whatever `NSItemProvider.loadItem` produced.
    static func fileURL(fromLoadedItem item: NSSecureCoding?) -> URL? {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let directURL = item as? URL {
            url = directURL
        } else if let string = item as? String {
            url = URL(string: string)
        } else {
            url = nil
        }
        guard let url, url.isFileURL else { return nil }
        return url
    }

    /// Loads the file URLs of all providers, then calls `completion` once on the main queue with
    /// every URL that loaded, in provider order.
    static func collectFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        let lock = NSLock()
        var results = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = fileURL(fromLoadedItem: item)
                lock.lock()
                results[index] = url
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            lock.lock()
            let urls = results.compactMap { $0 }
            lock.unlock()
            completion(urls)
        }
    }

    // MARK: Drop validation

    /// True when dropping `sources` into `destination` would put a folder inside itself
    /// (destination is one of the sources or inside one of them).
    static func isSelfOrDescendantDrop(sources: [URL], destination: URL) -> Bool {
        let destinationPath = normalizedPath(destination)
        return sources.contains { source in
            let sourcePath = normalizedPath(source)
            return destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/")
        }
    }

    /// True when every source already lives directly in `destination` (dropping would do nothing).
    static func isNoOpDrop(sources: [URL], destination: URL) -> Bool {
        guard !sources.isEmpty else { return false }
        let destinationPath = normalizedPath(destination)
        return sources.allSatisfy { normalizedPath($0.deletingLastPathComponent()) == destinationPath }
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// Whether two file URLs are on the same volume; nil when either can't be determined.
    static func areOnSameVolume(_ lhs: URL, _ rhs: URL) -> Bool? {
        guard let lhsVolume = volumeIdentifier(for: lhs),
              let rhsVolume = volumeIdentifier(for: rhs) else {
            return nil
        }
        return lhsVolume.isEqual(rhsVolume)
    }

    private static func volumeIdentifier(for url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// The cursor badge for a drop: copy only when the drop will copy.
    /// `.automatic` follows Finder: copy across volumes, move on the same volume; unknown sources
    /// (e.g. file promises) are created fresh, so they show copy.
    static func dropOperation(for operation: FileDropOperation, sources: [URL], destination: URL) -> DropOperation {
        switch operation {
        case .copy:
            return .copy
        case .move:
            return .move
        case .automatic:
            guard let first = sources.first else { return .copy }
            if let sameVolume = cachedSameVolume(first, destination) {
                return sameVolume ? .move : .copy
            }
            return .move
        }
    }

    private static var sameVolumeCache: (source: String, destination: String, result: Bool?)?

    /// `dropUpdated` runs on every mouse move, so remember the last volume comparison.
    private static func cachedSameVolume(_ source: URL, _ destination: URL) -> Bool? {
        if let cache = sameVolumeCache, cache.source == source.path, cache.destination == destination.path {
            return cache.result
        }
        let result = areOnSameVolume(source, destination)
        sameVolumeCache = (source.path, destination.path, result)
        return result
    }

    // MARK: Drag source

    private static var dragPasteboardCache: (changeCount: Int, urls: [URL])?

    /// The file URLs being dragged, available synchronously during a drag: from `InternalDragState`
    /// for SwiftUI drags started in this app, otherwise read from the drag pasteboard (Finder, the
    /// list view, Cover Flow). Empty for file promises.
    static func dragSourceURLs() -> [URL] {
        let internalURLs = InternalDragState.shared.draggedURLs
        if !internalURLs.isEmpty {
            return internalURLs
        }

        let pasteboard = NSPasteboard(name: .drag)
        if let cache = dragPasteboardCache, cache.changeCount == pasteboard.changeCount {
            return cache.urls
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        dragPasteboardCache = (pasteboard.changeCount, urls)
        return urls
    }

    // MARK: Performing drops

    /// Performs a drop of `providers` (file URLs) into `destination` as ONE operation (one undo step),
    /// or receives file promises from the drag pasteboard when there are no file URLs.
    /// Call synchronously from the drop handler; `operation` must be resolved at drop time.
    @MainActor
    @discardableResult
    static func performDrop(
        providers: [NSItemProvider],
        into destination: URL,
        viewModel: FileBrowserViewModel,
        operation: FileDropOperation,
        completion: (() -> Void)? = nil
    ) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            collectFileURLs(from: fileProviders) { urls in
                guard !urls.isEmpty else { return }
                if isSelfOrDescendantDrop(sources: urls, destination: destination) {
                    NSSound.beep()
                    return
                }
                viewModel.handleDrop(urls: urls, to: destination, operation: operation, completion: completion)
            }
            return true
        }
        return receivePromisedFiles(into: destination, completion: completion)
    }

    /// Receives file promises (Mail attachments, Photos, Safari images) from the current drag into
    /// `destination` on a background queue. Must be called while the drop is being performed.
    @discardableResult
    static func receivePromisedFiles(into destination: URL, completion: (() -> Void)? = nil) -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
              !receivers.isEmpty else {
            return false
        }

        // One receiver per dragged item; its reader runs once per file it delivers. Completion fires
        // once every receiver has delivered (or failed) at least once.
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            let lock = NSLock()
            var hasLeft = false
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { _, error in
                if let error {
                    os_log(.error, log: dropLog, "File promise failed: %{private}@", error.localizedDescription)
                }
                lock.lock()
                let shouldLeave = !hasLeft
                hasLeft = true
                lock.unlock()
                if shouldLeave {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            completion?()
        }
        return true
    }

    /// Legacy entry point for `.onDrop(of:isTargeted:perform:)` closures: resolves the operation now
    /// (at drop time), collects every URL and performs a single drop.
    @MainActor
    static func handleDrop(
        providers: [NSItemProvider],
        viewModel: FileBrowserViewModel,
        destinationURL: URL? = nil,
        operation: FileDropOperation? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        let resolvedOperation = operation ?? FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        let destination = destinationURL ?? viewModel.currentPath
        InternalDragState.shared.endDrag()
        performDrop(
            providers: providers,
            into: destination,
            viewModel: viewModel,
            operation: resolvedOperation,
            completion: onComplete
        )
    }
}

// MARK: - Unified Folder Drop Delegate

/// Drop delegate for dropping onto a folder item; used by every view's folder cells.
struct UnifiedFolderDropDelegate: DropDelegate {
    let item: FileItem
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?

    private var acceptsDrops: Bool {
        item.isDirectory && !item.isFromArchive && !viewModel.isPhotosItem(item)
    }

    /// Internal drags are allowed (e.g. onto a folder in the other pane); only dropping a folder
    /// onto itself / its own descendant, or into the folder the items already live in, is refused.
    private func isUsefulDrop() -> Bool {
        let sources = DropHelper.dragSourceURLs()
        if DropHelper.isSelfOrDescendantDrop(sources: sources, destination: item.url) { return false }
        if DropHelper.isNoOpDrop(sources: sources, destination: item.url) { return false }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        acceptsDrops && info.hasItemsConforming(to: DropHelper.acceptedDropTypes) && isUsefulDrop()
    }

    func dropEntered(info: DropInfo) {
        if acceptsDrops && isUsefulDrop() {
            dropTargetedItemID = item.id
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetedItemID == item.id {
            dropTargetedItemID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard acceptsDrops && isUsefulDrop() else { return DropProposal(operation: .forbidden) }
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropProposal(operation: DropHelper.dropOperation(
            for: operation,
            sources: DropHelper.dragSourceURLs(),
            destination: item.url
        ))
    }

    func performDrop(info: DropInfo) -> Bool {
        if dropTargetedItemID == item.id {
            dropTargetedItemID = nil
        }
        defer { InternalDragState.shared.endDrag() }
        guard acceptsDrops && isUsefulDrop() else { return false }

        // Resolve the operation now: the item providers load asynchronously, after the user may
        // have released Option.
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropHelper.performDrop(
            providers: info.itemProviders(for: [.fileURL]),
            into: item.url,
            viewModel: viewModel,
            operation: operation
        )
    }
}

// MARK: - Drag Auto-Scroll State
/// Shared state for triggering auto-scroll during drag operations

class DragAutoScrollState: ObservableObject {
    static let shared = DragAutoScrollState()

    enum ScrollDirection {
        case none, up, down
    }

    @Published var scrollDirection: ScrollDirection = .none
    @Published var scrollTargetID: UUID? = nil

    private init() {}

    func reset() {
        scrollDirection = .none
        scrollTargetID = nil
    }
}

// MARK: - Container Drop Delegate
/// Drop delegate for container-level drops (dropping into the current folder background).

struct ContainerDropDelegate: DropDelegate {
    let viewModel: FileBrowserViewModel
    @Binding var isDropTargeted: Bool
    let containerHeight: CGFloat
    let items: [FileItem]
    /// Drives `DragAutoScrollState` near the top/bottom edges (scrolling grids only).
    var autoScroll: Bool = true
    /// Called after the drop's file operation finished.
    var onComplete: (() -> Void)? = nil

    private var edgeThreshold: CGFloat { 60 }

    private var destination: URL { viewModel.currentPath }

    private var acceptsDrops: Bool {
        !viewModel.isInsideArchive
            && !viewModel.isPhotosLibraryActive
            && viewModel.currentPath.isFileURL
            && viewModel.currentPath.path != "/Network"
    }

    /// A drag of items that already live in this folder (e.g. from this very view) would do nothing.
    private func isUsefulDrop() -> Bool {
        let sources = DropHelper.dragSourceURLs()
        if DropHelper.isSelfOrDescendantDrop(sources: sources, destination: destination) { return false }
        if DropHelper.isNoOpDrop(sources: sources, destination: destination) { return false }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Internal drags stay valid so dropUpdated keeps running for edge auto-scroll; whether they
        // can actually drop is decided in dropUpdated.
        if autoScroll && InternalDragState.shared.isDragging { return true }
        return acceptsDrops && info.hasItemsConforming(to: DropHelper.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        isDropTargeted = acceptsDrops && isUsefulDrop()
    }

    func dropExited(info: DropInfo) {
        isDropTargeted = false
        if autoScroll {
            DragAutoScrollState.shared.reset()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if autoScroll {
            let location = info.location
            if location.y < edgeThreshold {
                DragAutoScrollState.shared.scrollDirection = .up
            } else if location.y > containerHeight - edgeThreshold {
                DragAutoScrollState.shared.scrollDirection = .down
            } else {
                DragAutoScrollState.shared.scrollDirection = .none
            }
        }

        guard acceptsDrops, isUsefulDrop() else {
            if isDropTargeted { isDropTargeted = false }
            return DropProposal(operation: .forbidden)
        }
        if !isDropTargeted { isDropTargeted = true }
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropProposal(operation: DropHelper.dropOperation(
            for: operation,
            sources: DropHelper.dragSourceURLs(),
            destination: destination
        ))
    }

    func performDrop(info: DropInfo) -> Bool {
        if autoScroll {
            DragAutoScrollState.shared.reset()
        }
        isDropTargeted = false
        defer { InternalDragState.shared.endDrag() }
        guard acceptsDrops, isUsefulDrop() else { return false }

        // Resolve the operation now, not inside the asynchronous item-provider callbacks.
        let operation = FileDropOperation(modifierFlags: NSEvent.modifierFlags)
        return DropHelper.performDrop(
            providers: info.itemProviders(for: [.fileURL]),
            into: destination,
            viewModel: viewModel,
            operation: operation,
            completion: onComplete
        )
    }
}

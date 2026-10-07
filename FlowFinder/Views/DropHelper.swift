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
    /// (destination is one of the sources or inside one of them). A dragged symlink is the link
    /// itself: a link to a folder can go into that folder's subfolders.
    static func isSelfOrDescendantDrop(sources: [URL], destination: URL) -> Bool {
        let destinationPath = FileOperationEngine.canonicalPath(destination)
        return canonicalPaths(of: sources).contains { FileOperationEngine.isPath(destinationPath, sameAsOrInside: $0.item) }
    }

    /// True when every source already lives directly in `destination`: dropping would do nothing.
    /// Not for an Option-drag (`.copy`), which duplicates them there, as in Finder.
    static func isNoOpDrop(sources: [URL], destination: URL, operation: FileDropOperation = .automatic) -> Bool {
        guard !sources.isEmpty, operation != .copy else { return false }
        let destinationPath = FileOperationEngine.canonicalPath(destination)
        return canonicalPaths(of: sources).allSatisfy { $0.parent == destinationPath }
    }

    private static var canonicalPathsCache: (sources: [URL], paths: [(item: String, parent: String)])?

    /// Real paths of dragged items and their folders. Drop validation runs on every mouse move,
    /// so the last drag's are remembered.
    private static func canonicalPaths(of sources: [URL]) -> [(item: String, parent: String)] {
        if let cache = canonicalPathsCache, cache.sources == sources {
            return cache.paths
        }
        let paths = sources.map { source in
            (item: FileOperationEngine.canonicalItemPath(source),
             parent: FileOperationEngine.canonicalPath(source.deletingLastPathComponent()))
        }
        canonicalPathsCache = (sources, paths)
        return paths
    }

    /// Whether a dragged item is on the same volume as the folder `destination`; nil when either
    /// can't be read.
    static func areOnSameVolume(_ lhs: URL, _ rhs: URL) -> Bool? {
        FileOperationEngine.isSameVolume(lhs, rhs)
    }

    /// The cursor badge for a drop: copy only when the drop will copy.
    /// `.automatic` follows Finder: copy across volumes, move on the same volume. Unknown sources
    /// (e.g. file promises) are created fresh and an unknown volume copies, so they show copy.
    static func dropOperation(for operation: FileDropOperation, sources: [URL], destination: URL) -> DropOperation {
        switch operation {
        case .copy:
            return .copy
        case .move:
            return .move
        case .automatic:
            guard let first = sources.first else { return .copy }
            return cachedSameVolume(first, destination) == true ? .move : .copy
        }
    }

    /// ⌥⌘-drag makes aliases (Finder).
    static func isAliasDrop(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains([.option, .command])
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

    /// Sidebar favorite reorder drags carry only an internal type; never treat them as file drops.
    @MainActor
    static func isSidebarFavoriteDrag() -> Bool {
        NSPasteboard(name: .drag).types?.contains(SidebarOutlineView.favoriteDragType) ?? false
    }

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
        return receivePromisedFiles(into: destination, viewModel: viewModel, completion: completion)
    }

    /// ⌥⌘-drop: makes aliases of the dropped files in `destination` (one undo step).
    @MainActor
    @discardableResult
    static func performAliasDrop(providers: [NSItemProvider], into destination: URL, viewModel: FileBrowserViewModel) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        collectFileURLs(from: fileProviders) { urls in
            guard !urls.isEmpty else { return }
            viewModel.makeAliases(of: urls, in: destination)
        }
        return true
    }

    /// Receives file promises (Mail attachments, Photos, Safari images) from the current drag. Must
    /// be called while the drop is being performed. With a `viewModel`, the files are received into
    /// a staging folder (on the destination's volume) and then copied into `destination` like any
    /// drop, with the name-conflict question and Undo; without one they're written straight there.
    @discardableResult
    static func receivePromisedFiles(into destination: URL, viewModel: FileBrowserViewModel? = nil, completion: (() -> Void)? = nil) -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
              !receivers.isEmpty else {
            return false
        }

        let staging = viewModel == nil ? nil : stagingDirectory(for: destination)
        let lock = NSLock()
        var receivedURLs: [URL] = []

        // A receiver's reader runs once per file it delivers. Completion fires once every receiver
        // has delivered (or failed) all its files.
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            var deliveries = 0
            var hasLeft = false
            receiver.receivePromisedFiles(atDestination: staging ?? destination, options: [:], operationQueue: promiseQueue) { url, error in
                if let error {
                    os_log(.error, log: dropLog, "File promise failed: %{private}@", error.localizedDescription)
                }
                lock.lock()
                if error == nil {
                    receivedURLs.append(url)
                }
                deliveries += 1
                let shouldLeave = !hasLeft && deliveries >= max(1, receiver.fileNames.count)
                if shouldLeave {
                    hasLeft = true
                }
                lock.unlock()
                if shouldLeave {
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            lock.lock()
            let urls = receivedURLs
            lock.unlock()
            guard let staging, let viewModel else {
                completion?()
                return
            }
            guard !urls.isEmpty else {
                try? FileManager.default.removeItem(at: staging)
                completion?()
                return
            }
            MainActor.assumeIsolated {
                // New files: always copied in (Undo moves the copies to the Trash).
                viewModel.handleDrop(urls: urls, to: destination, operation: .copy) {
                    DispatchQueue.global(qos: .utility).async {
                        try? FileManager.default.removeItem(at: staging)
                    }
                    completion?()
                }
            }
        }
        return true
    }

    /// A fresh temporary folder on `destination`'s volume (so the copy out of it is a clone), or in
    /// the temporary directory.
    private static func stagingDirectory(for destination: URL) -> URL? {
        let fileManager = FileManager.default
        if let directory = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true) {
            return directory
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent("FlowFinderDrop-\(UUID().uuidString)", isDirectory: true)
        return (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) == nil ? nil : directory
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

// MARK: - Drop highlight reset

/// SwiftUI doesn't always end a drop target's highlight: `dropExited` can be skipped (a drop on a
/// nested target, a refused or cancelled drop), which left e.g. the pane highlight on until the
/// next drag. The drop delegates register a reset whenever they turn a highlight on; all of them run
/// once the drag is over (the mouse button has been up for a moment).
@MainActor
final class DropHighlightReset {
    static let shared = DropHighlightReset()

    private var resets: [() -> Void] = []
    private var timer: Timer?
    private var buttonReleasedAt: Date?
    /// How long the button must be up: a drag session swallows its mouse-up, so it's polled.
    let releaseGrace: TimeInterval = 0.2

    private init() {}

    var pendingCount: Int { resets.count }

    func clearWhenDragEnds(_ reset: @escaping () -> Void) {
        resets.append(reset)
        guard timer == nil else { return }
        buttonReleasedAt = nil
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        // Common modes: it must fire while the drag session tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        if NSEvent.pressedMouseButtons & 1 != 0 {
            buttonReleasedAt = nil
            return
        }
        let now = Date()
        guard let releasedAt = buttonReleasedAt else {
            buttonReleasedAt = now
            return
        }
        if now.timeIntervalSince(releasedAt) >= releaseGrace {
            resetAll()
        }
    }

    /// Runs (and forgets) every registered reset.
    func resetAll() {
        let pending = resets
        resets.removeAll()
        timer?.invalidate()
        timer = nil
        buttonReleasedAt = nil
        pending.forEach { $0() }
    }
}

// MARK: - Unified Folder Drop Delegate

/// Drop delegate for dropping onto a folder item; used by every view's folder cells.
struct UnifiedFolderDropDelegate: DropDelegate {
    let item: FileItem
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?

    /// Folders take drops. A package (an app, a Photos library, an .rtfd …) isn't a folder things
    /// go into — except that files dropped on an application open in it, as in Finder.
    private var acceptsDrops: Bool {
        item.isDirectory
            && (!item.isPackage || isApplication)
            && !item.isFromArchive
            && !viewModel.isPhotosItem(item)
            && !DropHelper.isSidebarFavoriteDrag()
    }

    private var isApplication: Bool {
        item.isPackage && item.fileType == .application
    }

    /// File promises need a folder to be written to, so an application only takes file URLs.
    private var acceptedTypes: [UTType] {
        isApplication ? [.fileURL] : DropHelper.acceptedDropTypes
    }

    /// Internal drags are allowed (e.g. onto a folder in the other pane); only dropping a folder
    /// onto itself / its own descendant, or into the folder the items already live in (unless
    /// Option duplicates them), is refused. ⌥⌘ makes aliases, which is always possible.
    private func isUsefulDrop() -> Bool {
        let flags = NSEvent.modifierFlags
        if DropHelper.isAliasDrop(modifierFlags: flags) && !isApplication { return true }
        let sources = DropHelper.dragSourceURLs()
        if DropHelper.isSelfOrDescendantDrop(sources: sources, destination: item.url) { return false }
        if isApplication { return true }
        let operation = FileDropOperation(modifierFlags: flags)
        return !DropHelper.isNoOpDrop(sources: sources, destination: item.url, operation: operation)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Whether this drag can drop here is decided as it moves (Option can change it)
        acceptsDrops && info.hasItemsConforming(to: acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        if acceptsDrops && isUsefulDrop() {
            setTargeted()
        }
    }

    /// Turns the highlight on, making sure it goes off again when the drag ends.
    private func setTargeted() {
        guard dropTargetedItemID != item.id else { return }
        dropTargetedItemID = item.id
        let binding = $dropTargetedItemID
        let itemID = item.id
        DropHighlightReset.shared.clearWhenDragEnds {
            if binding.wrappedValue == itemID {
                binding.wrappedValue = nil
            }
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetedItemID == item.id {
            dropTargetedItemID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard acceptsDrops && isUsefulDrop() else {
            if dropTargetedItemID == item.id {
                dropTargetedItemID = nil
            }
            return DropProposal(operation: .forbidden)
        }
        setTargeted()
        if isApplication {
            return DropProposal(operation: .copy)
        }
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
        let flags = NSEvent.modifierFlags
        let providers = info.itemProviders(for: [.fileURL])
        if DropHelper.isAliasDrop(modifierFlags: flags) && !isApplication {
            return DropHelper.performAliasDrop(providers: providers, into: item.url, viewModel: viewModel)
        }
        return DropHelper.performDrop(
            providers: providers,
            into: item.url,
            viewModel: viewModel,
            operation: FileDropOperation(modifierFlags: flags)
        )
    }
}

// MARK: - Tile Grid Drop Delegate

/// Frames of a grid's tiles in the grid's coordinate space, as the tiles report them (see
/// `reportsTileFrame`). Only tiles that exist are kept. Not observable: writing a frame never
/// redraws anything.
@MainActor
final class TileFrameStore {
    private var frames: [URL: CGRect] = [:]

    func set(_ frame: CGRect, for url: URL) {
        frames[url] = frame
    }

    func remove(_ url: URL) {
        frames.removeValue(forKey: url)
    }

    /// The tile containing `point`.
    func tile(at point: CGPoint) -> URL? {
        frames.first { $0.value.contains(point) }?.key
    }
}

extension View {
    /// Records this tile's frame in `space` into `store` while the tile exists, for the grid's
    /// `TileGridDropDelegate`. Cheap: it reports when the tile's layout changes, not on scroll.
    func reportsTileFrame(_ url: URL, in store: TileFrameStore, space: String) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(space))
        } action: { frame in
            store.set(frame, for: url)
        }
        .onDisappear {
            store.remove(url)
        }
    }
}

/// Drop target over a grid of tiles (icon and masonry views): the folder tile under the pointer
/// takes the drop (like its own `UnifiedFolderDropDelegate`); anywhere else, a file tile or the
/// space between tiles, the drop goes into the folder the view shows (`container`), like Finder.
///
/// One target for the whole grid: a drop target per tile costs an AppKit view per tile, built
/// as tiles scroll in, and made scrolling these views several times slower.
struct TileGridDropDelegate: DropDelegate {
    let viewModel: FileBrowserViewModel
    /// The item of the tile at a location in the grid's coordinate space
    let item: (CGPoint) -> FileItem?
    @Binding var dropTargetedItemID: UUID?
    /// Drops outside folder tiles. Its location-based edge auto-scroll must be off: locations
    /// here are in the grid's (scrolling) coordinates.
    let container: ContainerDropDelegate

    /// The delegate of the folder tile under the pointer, when that folder takes this drop.
    private func folderDelegate(at location: CGPoint, info: DropInfo) -> UnifiedFolderDropDelegate? {
        guard let item = item(location) else { return nil }
        let delegate = UnifiedFolderDropDelegate(item: item, viewModel: viewModel, dropTargetedItemID: $dropTargetedItemID)
        return delegate.validateDrop(info: info) ? delegate : nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Where it may land (a folder tile or the folder shown) is decided as the pointer moves
        info.hasItemsConforming(to: DropHelper.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let folder = folderDelegate(at: info.location, info: info) {
            container.dropExited(info: info)
            if dropTargetedItemID != folder.item.id {
                folder.dropEntered(info: info)
            }
            return folder.dropUpdated(info: info)
        }
        dropTargetedItemID = nil
        return container.dropUpdated(info: info)
    }

    func dropExited(info: DropInfo) {
        dropTargetedItemID = nil
        container.dropExited(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        if let folder = folderDelegate(at: info.location, info: info) {
            container.dropExited(info: info)
            return folder.performDrop(info: info)
        }
        dropTargetedItemID = nil
        return container.performDrop(info: info)
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

    /// Not inside an archive, the Photos library, the Network browser or Spotlight results.
    private var acceptsDrops: Bool {
        viewModel.canAddItemsToCurrentLocation && !DropHelper.isSidebarFavoriteDrag()
    }

    /// A drag of items that already live in this folder (e.g. from this very view) would do
    /// nothing, unless Option duplicates them or ⌥⌘ makes aliases.
    private func isUsefulDrop() -> Bool {
        let flags = NSEvent.modifierFlags
        if DropHelper.isAliasDrop(modifierFlags: flags) { return true }
        let sources = DropHelper.dragSourceURLs()
        if DropHelper.isSelfOrDescendantDrop(sources: sources, destination: destination) { return false }
        let operation = FileDropOperation(modifierFlags: flags)
        return !DropHelper.isNoOpDrop(sources: sources, destination: destination, operation: operation)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Internal drags stay valid so dropUpdated keeps running for edge auto-scroll; whether they
        // can actually drop is decided in dropUpdated.
        if autoScroll && InternalDragState.shared.isDragging { return true }
        return acceptsDrops && info.hasItemsConforming(to: DropHelper.acceptedDropTypes)
    }

    func dropEntered(info: DropInfo) {
        if acceptsDrops && isUsefulDrop() {
            setTargeted()
        } else {
            isDropTargeted = false
        }
    }

    /// Turns the highlight on, making sure it goes off again when the drag ends.
    private func setTargeted() {
        guard !isDropTargeted else { return }
        isDropTargeted = true
        let binding = $isDropTargeted
        DropHighlightReset.shared.clearWhenDragEnds {
            if binding.wrappedValue {
                binding.wrappedValue = false
            }
        }
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
        setTargeted()
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
        let flags = NSEvent.modifierFlags
        let providers = info.itemProviders(for: [.fileURL])
        if DropHelper.isAliasDrop(modifierFlags: flags) {
            return DropHelper.performAliasDrop(providers: providers, into: destination, viewModel: viewModel)
        }
        return DropHelper.performDrop(
            providers: providers,
            into: destination,
            viewModel: viewModel,
            operation: FileDropOperation(modifierFlags: flags),
            completion: onComplete
        )
    }
}

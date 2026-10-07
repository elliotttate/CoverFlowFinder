import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Drop Target Overlay Modifier
// Reusable overlay for drop target indication

struct DropTargetOverlay: ViewModifier {
    let isTargeted: Bool
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let padding: CGFloat

    init(
        isTargeted: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        lineWidth: CGFloat = UI.LineWidth.thick,
        padding: CGFloat = UI.Spacing.small
    ) {
        self.isTargeted = isTargeted
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        self.padding = padding
    }

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: lineWidth)
                .padding(padding)
        )
    }
}

extension View {
    func dropTargetOverlay(
        isTargeted: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        lineWidth: CGFloat = UI.LineWidth.thick,
        padding: CGFloat = UI.Spacing.small
    ) -> some View {
        modifier(DropTargetOverlay(
            isTargeted: isTargeted,
            cornerRadius: cornerRadius,
            lineWidth: lineWidth,
            padding: padding
        ))
    }
}

// MARK: - Internal Drag State Tracking
// Tracks when a drag originates from within the app to suppress drop overlays

class InternalDragState: ObservableObject {
    static let shared = InternalDragState()

    /// True while a drag that started in this app is in progress.
    @Published var isDragging = false {
        didSet {
            guard isDragging != oldValue else { return }
            if isDragging {
                startWatchdog()
            } else {
                draggedURLs = []
                stopWatchdog()
            }
        }
    }

    /// The URLs of a SwiftUI drag started in this app (empty when unknown, e.g. list / Cover Flow drags).
    private(set) var draggedURLs: [URL] = []

    private var dragMonitor: Any?
    private var watchdog: Timer?
    private var dragStartedAt = Date.distantPast
    private var buttonReleasedAt: Date?

    /// A drag session swallows its mouse-up, so the flag is also cleared once the mouse button has
    /// been up for a moment, and after a hard timeout.
    private let releaseGrace: TimeInterval = 0.75
    private let maximumDragDuration: TimeInterval = 120

    private init() {
        // Clear drag state on a mouse-up the app does see (drags that never left the source view).
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            if self?.isDragging == true {
                DispatchQueue.main.async {
                    self?.endDrag()
                }
            }
            return event
        }
    }

    deinit {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        watchdog?.invalidate()
    }

    /// Marks the start of an internal drag of `urls`. The URLs are available immediately (drop
    /// targets validate against them); the published flag updates on the next runloop turn, since
    /// drag callbacks can run inside a SwiftUI update.
    func beginDrag(urls: [URL]) {
        draggedURLs = urls
        dragStartedAt = Date()
        buttonReleasedAt = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDragging else { return }
            self.isDragging = true
        }
    }

    /// Ends the current internal drag (drop performed, drag cancelled, or mouse released).
    func endDrag() {
        if isDragging {
            isDragging = false
        } else {
            draggedURLs = []
        }
    }

    private func startWatchdog() {
        if Date().timeIntervalSince(dragStartedAt) > 1 {
            // Started by a caller that set `isDragging` directly (list view, Cover Flow).
            dragStartedAt = Date()
        }
        buttonReleasedAt = nil
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkDragStillActive()
        }
        // Common modes: the timer must fire while the drag session tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        buttonReleasedAt = nil
    }

    private func checkDragStillActive() {
        let now = Date()
        if now.timeIntervalSince(dragStartedAt) > maximumDragDuration {
            endDrag()
            return
        }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            buttonReleasedAt = nil
            return
        }
        if let releasedAt = buttonReleasedAt {
            if now.timeIntervalSince(releasedAt) >= releaseGrace {
                endDrag()
            }
        } else {
            buttonReleasedAt = now
        }
    }
}

// MARK: - Internal Drag Modifier
// Wraps SwiftUI's onDrag to set internal drag state

struct InternalDragModifier: ViewModifier {
    let item: FileItem

    /// Only real files are dragged: an entry inside an archive has no file at its URL (copy it out
    /// with Copy instead), and network services aren't files. Same rule as the list view.
    static func canDrag(_ item: FileItem) -> Bool {
        !item.isFromArchive && item.url.isFileURL
    }

    func body(content: Content) -> some View {
        if Self.canDrag(item) {
            let url = item.url
            content.onDrag {
                InternalDragState.shared.beginDrag(urls: [url])
                return NSItemProvider(object: url as NSURL)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Adds drag support for `item` that marks the drag as internal (from within the app).
    /// Items that can't be dragged as files (archive entries) get none.
    func internalDrag(item: FileItem) -> some View {
        modifier(InternalDragModifier(item: item))
    }
}

// MARK: - Multi-Item File Drag
// Dragging a selected item drags the whole selection (Finder); `onDrag` can only drag one item.

/// A file dragged out of a SwiftUI file view, on the drag pasteboard as a file URL (what Finder,
/// other apps and this app's drop targets read).
struct DraggedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .fileURL) { file in
            Data(file.url.absoluteString.utf8)
        }
    }
}

/// The container of a file view's draggable items (see `fileDragItem`).
struct FileDragContainerModifier: ViewModifier {
    let viewModel: FileBrowserViewModel

    /// The selected items that can be dragged: the listed ones in display order, then any selected
    /// items the view model doesn't list (a Column view sub-column's), by path.
    @MainActor
    static func draggableSelection(of viewModel: FileBrowserViewModel) -> [URL] {
        let selection = viewModel.selectedItems
        var ordered = viewModel.orderedSelectedItems
        if ordered.count < selection.count {
            let listed = Set(ordered)
            ordered += selection.filter { !listed.contains($0) }.sorted { $0.url.path < $1.url.path }
        }
        return ordered.filter(InternalDragModifier.canDrag).map(\.url)
    }

    func body(content: Content) -> some View {
        let viewModel = viewModel
        content
            .dragContainer(for: DraggedFile.self, itemID: \.url) { urls in
                urls.map(DraggedFile.init)
            }
            // Read when a drag starts, not on every render.
            .dragContainerSelection(Self.draggableSelection(of: viewModel))
            // The drop target decides: move on the same volume, copy across volumes (Finder).
            .dragConfiguration(DragConfiguration(allowMove: true))
            .onDragSessionUpdated { session in
                let dragState = InternalDragState.shared
                switch session.phase {
                case .initial, .active:
                    if dragState.draggedURLs.isEmpty {
                        dragState.beginDrag(urls: session.draggedItemIDs(for: URL.self))
                    }
                case .ended, .dataTransferCompleted:
                    dragState.endDrag()
                default:
                    break
                }
            }
    }
}

/// One draggable item of a `fileDragContainer`.
struct FileDragItemModifier: ViewModifier {
    let item: FileItem

    func body(content: Content) -> some View {
        if InternalDragModifier.canDrag(item) {
            content.draggable(containerItemID: item.url)
        } else {
            content
        }
    }
}

extension View {
    /// Makes this view (a grid or stack of `fileDragItem`s) the drag container for
    /// `viewModel`'s items: dragging a selected item drags every selected file.
    func fileDragContainer(for viewModel: FileBrowserViewModel) -> some View {
        modifier(FileDragContainerModifier(viewModel: viewModel))
    }

    /// Makes `item` draggable as a file within the enclosing `fileDragContainer`: with the rest of
    /// the selection when it is selected, on its own otherwise. Archive entries and non-files
    /// can't be dragged.
    func fileDragItem(_ item: FileItem) -> some View {
        modifier(FileDragItemModifier(item: item))
    }
}

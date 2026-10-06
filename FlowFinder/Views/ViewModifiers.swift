import SwiftUI
import AppKit

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
    let url: URL

    func body(content: Content) -> some View {
        content.onDrag {
            InternalDragState.shared.beginDrag(urls: [url])
            return NSItemProvider(object: url as NSURL)
        }
    }
}

extension View {
    /// Adds drag support that marks the drag as internal (from within the app)
    func internalDrag(url: URL) -> some View {
        modifier(InternalDragModifier(url: url))
    }
}

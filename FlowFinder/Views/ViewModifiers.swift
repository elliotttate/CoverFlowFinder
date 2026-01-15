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

// MARK: - Selection Background Modifier
// Reusable background for selected/drop-targeted items

struct SelectionBackground: ViewModifier {
    let isSelected: Bool
    let isDropTarget: Bool
    let cornerRadius: CGFloat

    init(
        isSelected: Bool,
        isDropTarget: Bool = false,
        cornerRadius: CGFloat = UI.CornerRadius.large
    ) {
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor)
        )
    }

    private var backgroundColor: Color {
        if isDropTarget {
            return Color.accentColor.opacity(UI.Opacity.dropTarget)
        } else if isSelected {
            return Color.accentColor.opacity(UI.Opacity.selectedItem)
        } else {
            return Color.clear
        }
    }
}

extension View {
    func selectionBackground(
        isSelected: Bool,
        isDropTarget: Bool = false,
        cornerRadius: CGFloat = UI.CornerRadius.large
    ) -> some View {
        modifier(SelectionBackground(
            isSelected: isSelected,
            isDropTarget: isDropTarget,
            cornerRadius: cornerRadius
        ))
    }
}

// MARK: - Item Drop Target Overlay
// Combined selection background and drop stroke for list/grid items

struct ItemDropTargetStyle: ViewModifier {
    let isSelected: Bool
    let isDropTarget: Bool
    let cornerRadius: CGFloat
    let strokeWidth: CGFloat

    init(
        isSelected: Bool,
        isDropTarget: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        strokeWidth: CGFloat = UI.LineWidth.standard
    ) {
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        self.cornerRadius = cornerRadius
        self.strokeWidth = strokeWidth
    }

    func body(content: Content) -> some View {
        content
            .background(
                isDropTarget
                    ? Color.accentColor.opacity(UI.Opacity.dropTarget)
                    : (isSelected ? Color.accentColor.opacity(UI.Opacity.selectedItemStrong) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: strokeWidth)
                    .opacity(isDropTarget ? 1 : 0)
            )
    }
}

extension View {
    func itemDropTargetStyle(
        isSelected: Bool,
        isDropTarget: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        strokeWidth: CGFloat = UI.LineWidth.standard
    ) -> some View {
        modifier(ItemDropTargetStyle(
            isSelected: isSelected,
            isDropTarget: isDropTarget,
            cornerRadius: cornerRadius,
            strokeWidth: strokeWidth
        ))
    }
}

// MARK: - Active Pane Border
// Highlights the active pane in multi-pane views

struct ActivePaneBorder: ViewModifier {
    let isActive: Bool
    let lineWidth: CGFloat

    init(isActive: Bool, lineWidth: CGFloat = UI.LineWidth.standard) {
        self.isActive = isActive
        self.lineWidth = lineWidth
    }

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: lineWidth)
        )
    }
}

extension View {
    func activePaneBorder(isActive: Bool, lineWidth: CGFloat = UI.LineWidth.standard) -> some View {
        modifier(ActivePaneBorder(isActive: isActive, lineWidth: lineWidth))
    }
}

// MARK: - Cut Item Opacity
// Applies reduced opacity to items that are cut

extension View {
    func cutItemOpacity(isCut: Bool) -> some View {
        opacity(isCut ? UI.Opacity.cutItem : 1.0)
    }
}

// MARK: - Internal Drag State Tracking
// Tracks when a drag originates from within the app to suppress drop overlays

class InternalDragState: ObservableObject {
    static let shared = InternalDragState()
    @Published var isDragging = false
    @Published var mouseScreenLocation: NSPoint = .zero
    private var dragMonitor: Any?
    private var mouseDraggedMonitor: Any?

    private init() {
        setupDragMonitor()
    }

    private func setupDragMonitor() {
        // Monitor for drag session end at the app level
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            // Clear drag state on mouse up (drag end)
            if self?.isDragging == true {
                DispatchQueue.main.async {
                    self?.isDragging = false
                }
            }
            return event
        }

        // Monitor mouse position during drag
        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            if self?.isDragging == true {
                DispatchQueue.main.async {
                    self?.mouseScreenLocation = NSEvent.mouseLocation
                }
            }
            return event
        }
    }

    deinit {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseDraggedMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Internal Drag Modifier
// Wraps SwiftUI's onDrag to set internal drag state

struct InternalDragModifier: ViewModifier {
    let url: URL

    func body(content: Content) -> some View {
        content.onDrag {
            // Mark as internal drag when drag starts
            DispatchQueue.main.async {
                InternalDragState.shared.isDragging = true
            }
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

// MARK: - Multi-File Drag Support
// Custom drag modifier that supports dragging multiple selected files

struct MultiFileDragModifier: ViewModifier {
    let item: FileItem
    let selectedItems: Set<FileItem>
    let icon: NSImage

    func body(content: Content) -> some View {
        content.overlay(
            MultiFileDragView(
                item: item,
                selectedItems: selectedItems,
                icon: icon
            )
        )
    }
}

/// NSViewRepresentable that handles multi-file drag using AppKit
struct MultiFileDragView: NSViewRepresentable {
    let item: FileItem
    let selectedItems: Set<FileItem>
    let icon: NSImage

    func makeNSView(context: Context) -> MultiFileDragNSView {
        let view = MultiFileDragNSView()
        view.item = item
        view.selectedItems = selectedItems
        view.icon = icon
        return view
    }

    func updateNSView(_ nsView: MultiFileDragNSView, context: Context) {
        nsView.item = item
        nsView.selectedItems = selectedItems
        nsView.icon = icon
    }
}

/// Custom NSView that initiates multi-file drag sessions using Finder-style approach
/// This view passes through all events to SwiftUI but monitors for drag gestures
class MultiFileDragNSView: NSView, NSDraggingSource {
    var item: FileItem?
    var selectedItems: Set<FileItem> = []
    var icon: NSImage?

    private var dragStartLocation: NSPoint?
    private var mouseDownEvent: NSEvent?
    private let dragThreshold: CGFloat = 4
    private var isDragging = false
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupEventMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupEventMonitor()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupEventMonitor() {
        // Monitor mouse events globally within the app
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event // Always pass the event through
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard let window = self.window,
              event.window == window else { return }

        let windowPoint = event.locationInWindow
        let viewPoint = convert(windowPoint, from: nil)

        // Only handle events within our bounds
        guard bounds.contains(viewPoint) else {
            if event.type == .leftMouseUp {
                dragStartLocation = nil
                mouseDownEvent = nil
                isDragging = false
            }
            return
        }

        switch event.type {
        case .leftMouseDown:
            dragStartLocation = viewPoint
            mouseDownEvent = event
            isDragging = false

        case .leftMouseDragged:
            handleDrag(at: viewPoint, event: event)

        case .leftMouseUp:
            dragStartLocation = nil
            mouseDownEvent = nil
            isDragging = false

        default:
            break
        }
    }

    private func handleDrag(at viewPoint: NSPoint, event: NSEvent) {
        guard let startLocation = dragStartLocation,
              let item = item,
              !item.isFromArchive,
              !isDragging else { return }

        let distance = hypot(viewPoint.x - startLocation.x, viewPoint.y - startLocation.y)

        // Start drag if moved enough
        if distance > dragThreshold {
            isDragging = true

            // Determine items to drag
            let itemsToDrag: [FileItem]
            if selectedItems.contains(item) && selectedItems.count > 1 {
                itemsToDrag = Array(selectedItems).filter { !$0.isFromArchive }
            } else {
                itemsToDrag = [item]
            }

            guard !itemsToDrag.isEmpty else { return }

            // Create dragging items for each file (Finder-style)
            let iconSize = NSSize(width: 48, height: 48)
            var draggingItems: [NSDraggingItem] = []

            for (offset, dragItem) in itemsToDrag.enumerated() {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setString(dragItem.url.absoluteString, forType: .fileURL)

                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

                // Offset each subsequent item for stacked appearance (like Finder)
                let itemLocation = NSPoint(
                    x: startLocation.x + CGFloat(offset * 6),
                    y: startLocation.y - CGFloat(offset * 6)
                )

                // Use imageComponentsProvider for lazy image generation (Finder approach)
                draggingItem.imageComponentsProvider = {
                    let dragIcon = dragItem.icon
                    dragIcon.size = iconSize

                    // Create icon component
                    let iconComponent = NSDraggingImageComponent(key: .icon)
                    iconComponent.contents = dragIcon
                    iconComponent.frame = NSRect(origin: .zero, size: iconSize)

                    return [iconComponent]
                }

                draggingItem.setDraggingFrame(NSRect(origin: itemLocation, size: iconSize), contents: dragItem.icon)
                draggingItems.append(draggingItem)
            }

            // Mark internal drag as active to suppress drop overlays
            DispatchQueue.main.async {
                InternalDragState.shared.isDragging = true
            }

            // Start the drag session using the original mouseDown event
            let dragEvent = mouseDownEvent ?? event
            _ = beginDraggingSession(with: draggingItems, event: dragEvent, source: self)

            // Use stack formation for multiple items (like Finder)
            // Note: formation is set after session starts

            dragStartLocation = nil
            mouseDownEvent = nil
        }
    }

    // Make this view completely transparent to hit testing
    // All events pass through to SwiftUI, we just monitor them
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .withinApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        // Clear internal drag state
        DispatchQueue.main.async {
            InternalDragState.shared.isDragging = false
        }
    }
}

extension View {
    /// Adds multi-file drag support that works with Finder and other apps
    func multiFileDrag(item: FileItem, selectedItems: Set<FileItem>, icon: NSImage) -> some View {
        modifier(MultiFileDragModifier(item: item, selectedItems: selectedItems, icon: icon))
    }
}

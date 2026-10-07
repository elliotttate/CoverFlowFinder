import AppKit
import SwiftUI
import Quartz

/// Arrow-key navigation for the Quick Look panel while the panel itself is key.
enum QuickLookKeyAction: Equatable {
    case navigate(Int)
    case close

    /// The action for a key event, or nil if Quick Look shouldn't handle it.
    /// Events with Command, Option, Control or Shift are never handled (menus and text editing get them).
    init?(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        guard modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 125, 124: // Down, Right
            self = .navigate(1)
        case 126, 123: // Up, Left
            self = .navigate(-1)
        case 49, 53: // Space, Escape
            self = .close
        default:
            return nil
        }
    }
}

/// The app's Quick Look panel controller, shared by every view.
///
/// QLPreviewPanel looks for its controller in the responder chain of the key (or main) window.
/// While a preview is open, this responder is linked into the chain of the window that opened it,
/// right after the window itself, so the panel finds it whichever view of that window has focus.
/// Nothing takes first responder: the browser view keeps its keys (Return, ⌘↓, Home/End,
/// type-ahead), and clicking around the window doesn't cost the panel its controller.
///
/// Updates that name a window are only taken from the window the preview belongs to, so a
/// background window refreshing its listing can't take over (or close) the panel.
class QuickLookControllerView: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookControllerView()

    /// The URL currently being previewed
    var previewURL: URL?

    /// Moves the selection of the view that opened the preview (arrow keys while the panel is key).
    /// Dropped when the preview closes, so a closed tab's view isn't kept alive.
    var onNavigate: ((Int) -> Void)?

    /// The browser window the open preview belongs to; this controller is in its responder chain.
    private(set) weak var sessionWindow: NSWindow?
    private var panelCloseObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    /// Set while `showPreview` hands the panel to us (it may end and restart our control then)
    private var isOpeningPanel = false

    private override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Quick Look Panel Control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        // Only reachable through the responder chain of the window the preview belongs to
        return sessionWindow != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        observePanelClose(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if panel.dataSource as? QuickLookControllerView === self {
            panel.dataSource = nil
        }
        if panel.delegate as? QuickLookControllerView === self {
            panel.delegate = nil
        }
        // Another window became key: the panel takes us back when the preview's window does.
        // Closed (e.g. its close button): the session is over.
        if !isOpeningPanel && !panel.isVisible {
            finishPreviewSession()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let url = previewURL else { return nil }
        return url as QLPreviewItem
    }

    // MARK: - QLPreviewPanelDelegate

    /// Keys pressed while the panel itself is key (after the user clicked it).
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown,
              let action = QuickLookKeyAction(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
            return false
        }
        switch action {
        case .navigate(let offset):
            onNavigate?(offset)
            return true
        case .close:
            // Let the panel close itself; endPreviewPanelControl cleans up
            return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        // Provide the file icon as transition image
        guard let url = item.previewItemURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Public API

    /// The browser window that should own the panel: the key window, unless that's the panel itself.
    private var targetWindow: NSWindow? {
        if let key = NSApp.keyWindow, !(key is QLPreviewPanel) {
            return key
        }
        return NSApp.mainWindow
    }

    /// Whether the Quick Look panel is on screen (never creates the panel).
    static var isPanelVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return QLPreviewPanel.shared()?.isVisible == true
    }

    private var isPanelVisible: Bool {
        Self.isPanelVisible
    }

    /// Opens the panel on `url` for `window` (default: the key browser window).
    func showPreview(for url: URL, in window: NSWindow? = nil, navigate: @escaping (Int) -> Void) {
        guard let panel = QLPreviewPanel.shared() else { return }
        isOpeningPanel = true
        defer { isOpeningPanel = false }
        previewURL = url
        onNavigate = navigate

        if let window = window ?? targetWindow {
            beginSession(in: window)
        }
        // The responder chain changed without the panel noticing: let it find us
        panel.updateController()
        // With no key window (app not active, e.g. invoked from a Service or automation) the
        // responder chain finds nothing and the panel shows "No items selected": take control directly.
        if panel.dataSource as? QuickLookControllerView !== self {
            panel.dataSource = self
            panel.delegate = self
            observePanelClose(panel)
        }

        // Show panel and reload data
        panel.orderFront(nil)
        panel.reloadData()
    }

    func updatePreview(for url: URL) {
        updatePreview(for: Optional(url), from: nil)
    }

    func updatePreview(for url: URL?) {
        updatePreview(for: url, from: nil)
    }

    /// Shows `url` in the open panel (nil closes it). `window` is the caller's window: updates
    /// from any window other than the preview's are ignored. Nothing happens while the panel is
    /// closed (opening it sets the URL).
    func updatePreview(for url: URL?, from window: NSWindow?) {
        guard Self.acceptsUpdate(from: window, sessionWindow: sessionWindow, isPanelVisible: isPanelVisible),
              let panel = QLPreviewPanel.shared() else { return }
        previewURL = url
        if url == nil {
            panel.orderOut(nil)
            finishPreviewSession()
        } else {
            panel.reloadData()
        }
    }

    /// Whether an update from a view in `window` may change the preview. A caller that doesn't
    /// name its window is trusted.
    static func acceptsUpdate(from window: NSWindow?, sessionWindow: NSWindow?, isPanelVisible: Bool) -> Bool {
        guard isPanelVisible else { return false }
        guard let window, let sessionWindow else { return true }
        return window === sessionWindow
    }

    func hidePreview() {
        if isPanelVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        finishPreviewSession()
    }

    func togglePreview(for url: URL, in window: NSWindow? = nil, navigate: @escaping (Int) -> Void) {
        if isPanelVisible {
            hidePreview()
        } else {
            showPreview(for: url, in: window, navigate: navigate)
        }
    }

    // MARK: - Session

    /// Makes `window` the preview's window: links this controller into its responder chain, right
    /// after the window (and out of the previous window's chain).
    func beginSession(in window: NSWindow) {
        if sessionWindow === window, isLinked(into: window) { return }
        unlinkFromResponderChain()
        nextResponder = window.nextResponder
        window.nextResponder = self
        sessionWindow = window
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hidePreview()
            }
        }
    }

    /// The preview closed: leave the window's responder chain and drop what the session held.
    func finishPreviewSession() {
        onNavigate = nil
        previewURL = nil
        unlinkFromResponderChain()
    }

    private func isLinked(into window: NSWindow) -> Bool {
        var responder = window.nextResponder
        for _ in 0..<64 {
            guard let current = responder else { return false }
            if current === self { return true }
            responder = current.nextResponder
        }
        return false
    }

    private func unlinkFromResponderChain() {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
        defer {
            nextResponder = nil
            sessionWindow = nil
        }
        guard let window = sessionWindow else { return }
        // Bounded walk: a broken chain can't hang us
        var responder: NSResponder = window
        for _ in 0..<64 {
            guard let next = responder.nextResponder else { return }
            if next === self {
                responder.nextResponder = nextResponder
                return
            }
            responder = next
        }
    }

    private func observePanelClose(_ panel: QLPreviewPanel) {
        guard panelCloseObserver == nil else { return }
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishPreviewSession()
            }
        }
    }
}

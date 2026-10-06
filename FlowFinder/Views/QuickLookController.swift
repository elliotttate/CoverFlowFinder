import AppKit
import SwiftUI
import Quartz

/// Arrow-key navigation for the Quick Look panel, shared by the controller's keyDown and the
/// panel delegate's event handler.
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

/// A window-level Quick Look controller that handles preview for all SwiftUI views.
///
/// QLPreviewPanel looks for its controller in the key window's responder chain, so while the panel
/// is open this hidden view is installed in the window that opened it and made first responder
/// there. It works from any window: showing the panel moves the view into the current window.
/// Key handling is done through the responder chain (`keyDown`) and the panel delegate
/// (`previewPanel(_:handle:)`), never through event monitors.
class QuickLookControllerView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookControllerView(frame: .zero)

    /// The URL currently being previewed
    var previewURL: URL?

    private weak var previousFirstResponder: NSResponder?
    private var panelCloseObserver: NSObjectProtocol?

    /// Callback for navigation
    var onNavigate: ((Int) -> Void)?

    private override init(frame: NSRect) {
        super.init(frame: frame)
        // Make invisible but still in responder chain
        self.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Quick Look Panel Control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        // Only the window we're installed in can control the panel through us
        return window != nil
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
        // The panel closed (e.g. via its close button) or another controller took over
        finishPreviewSession()
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

    // MARK: - Keyboard (while we're first responder in the browser window)

    override func keyDown(with event: NSEvent) {
        guard isPanelVisible,
              let action = QuickLookKeyAction(keyCode: event.keyCode, modifierFlags: event.modifierFlags) else {
            super.keyDown(with: event)
            return
        }
        switch action {
        case .navigate(let offset):
            onNavigate?(offset)
        case .close:
            hidePreview()
        }
    }

    // MARK: - Public API

    fileprivate func installIfNeeded(in window: NSWindow?) {
        guard let window, self.window !== window else { return }
        moveToWindow(window)
    }

    private func moveToWindow(_ window: NSWindow) {
        // Leaving another window: give its focus back first
        if let oldWindow = self.window, oldWindow !== window {
            if oldWindow.firstResponder === self {
                restorePreviousFirstResponder()
            }
            previousFirstResponder = nil
        }
        removeFromSuperview()
        if let themeFrame = window.contentView?.superview {
            themeFrame.addSubview(self)
        } else {
            window.contentView?.addSubview(self)
        }
    }

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

    func showPreview(for url: URL, navigate: @escaping (Int) -> Void) {
        previewURL = url
        onNavigate = navigate

        guard let panel = QLPreviewPanel.shared() else { return }

        // Install in the window that asked for the preview
        if let target = targetWindow {
            installIfNeeded(in: target)
        }

        // Become the panel's controller through the responder chain
        if panel.dataSource as? QuickLookControllerView !== self || window?.firstResponder !== self {
            storePreviousFirstResponder()
            window?.makeFirstResponder(self)
            panel.updateController()
        }

        // Show panel and reload data
        panel.orderFront(nil)
        panel.reloadData()
    }

    func updatePreview(for url: URL) {
        updatePreview(for: Optional(url))
    }

    func updatePreview(for url: URL?) {
        previewURL = url

        guard isPanelVisible, let panel = QLPreviewPanel.shared() else { return }
        if url == nil {
            panel.orderOut(nil)
            finishPreviewSession()
        } else {
            panel.reloadData()
        }
    }

    func hidePreview() {
        if isPanelVisible {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        finishPreviewSession()
    }

    func togglePreview(for url: URL, navigate: @escaping (Int) -> Void) {
        if isPanelVisible {
            hidePreview()
        } else {
            showPreview(for: url, navigate: navigate)
        }
    }

    // MARK: - Session Cleanup

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

    /// Give focus back to whatever had it before the panel opened — but only if we still hold it.
    /// If the user has since clicked into a text field (e.g. typed a search that emptied the
    /// selection), focus stays there.
    private func finishPreviewSession() {
        restorePreviousFirstResponder()
    }

    private func storePreviousFirstResponder() {
        guard previousFirstResponder == nil else { return }
        if let window, window.firstResponder !== self {
            previousFirstResponder = window.firstResponder
        }
    }

    private func restorePreviousFirstResponder() {
        defer { previousFirstResponder = nil }
        guard let window, window.firstResponder === self else { return }
        if let previous = previousFirstResponder, previous !== self {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(window.contentView)
        }
    }
}

/// SwiftUI view that ensures QuickLookControllerView is installed in a window
struct QuickLookWindowController: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)

        // Install the shared controller in the first window; showing the panel moves it
        // into whichever window asks for a preview.
        DispatchQueue.main.async {
            if let window = view.window,
               QuickLookControllerView.shared.window == nil {
                QuickLookControllerView.shared.installIfNeeded(in: window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

import AppKit
import SwiftUI
import Quartz

/// A window-level Quick Look controller that handles preview for all SwiftUI views.
/// This NSView is added to the main window and stays in the responder chain.
class QuickLookControllerView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookControllerView(frame: .zero)

    /// The URL currently being previewed
    var previewURL: URL?

    /// Keyboard monitor for arrow navigation while Quick Look is open
    private var keyboardMonitor: Any?
    private weak var previousFirstResponder: NSResponder?

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
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
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

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        // Provide the file icon as transition image
        guard let url = item.previewItemURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Public API

    fileprivate func installIfNeeded(in window: NSWindow?) {
        guard let window, superview == nil else { return }
        if let themeFrame = window.contentView?.superview {
            themeFrame.addSubview(self)
        } else {
            window.contentView?.addSubview(self)
        }
    }

    func showPreview(for url: URL, navigate: @escaping (Int) -> Void) {
        previewURL = url
        onNavigate = navigate

        guard let panel = QLPreviewPanel.shared() else { return }

        // Make sure we're added to the window (above the hosting view, not as subview)
        installIfNeeded(in: NSApp.mainWindow)

        // Only need to set up responder chain if we're not already controlling
        if panel.dataSource as? QuickLookControllerView !== self {
            storePreviousFirstResponder()
            window?.makeFirstResponder(self)
            panel.updateController()
        }

        // Show panel and reload data
        panel.orderFront(nil)
        panel.reloadData()

        startKeyboardMonitor()
    }

    func updatePreview(for url: URL) {
        updatePreview(for: Optional(url))
    }

    func updatePreview(for url: URL?) {
        previewURL = url

        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            if url == nil {
                panel.orderOut(nil)
                stopKeyboardMonitor()
                restorePreviousFirstResponder()
            } else {
                panel.reloadData()
            }
        }
    }

    func hidePreview() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        stopKeyboardMonitor()
        restorePreviousFirstResponder()
    }

    func togglePreview(for url: URL, navigate: @escaping (Int) -> Void) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            hidePreview()
        } else {
            showPreview(for: url, navigate: navigate)
        }
    }

    // MARK: - Keyboard Monitor

    private func startKeyboardMonitor() {
        stopKeyboardMonitor()

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let panel = QLPreviewPanel.shared(),
                  panel.isVisible else {
                return event
            }

            switch event.keyCode {
            case 125: // Down arrow
                self.onNavigate?(1)
                return nil
            case 126: // Up arrow
                self.onNavigate?(-1)
                return nil
            case 123: // Left arrow
                self.onNavigate?(-1)
                return nil
            case 124: // Right arrow
                self.onNavigate?(1)
                return nil
            case 49, 53: // Space or Escape
                self.hidePreview()
                return nil
            default:
                return event
            }
        }
    }

    private func stopKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    private func storePreviousFirstResponder() {
        guard previousFirstResponder == nil else { return }
        if let window, window.firstResponder !== self {
            previousFirstResponder = window.firstResponder
        }
    }

    private func restorePreviousFirstResponder() {
        guard let window else {
            previousFirstResponder = nil
            return
        }
        if let previous = previousFirstResponder, previous !== self {
            window.makeFirstResponder(previous)
        } else {
            window.makeFirstResponder(window.contentView)
        }
        previousFirstResponder = nil
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        stopKeyboardMonitor()
        restorePreviousFirstResponder()
    }
}

/// SwiftUI view that ensures QuickLookControllerView is installed in the window
struct QuickLookWindowController: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)

        // Install the shared controller in the window after a delay
        DispatchQueue.main.async {
            if let window = view.window,
               QuickLookControllerView.shared.superview == nil {
                QuickLookControllerView.shared.installIfNeeded(in: window)
            }
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

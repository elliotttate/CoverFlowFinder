import AppKit
import SwiftUI
import Quartz

/// Shared Quick Look manager for SwiftUI views that don't have their own NSView
/// This provides the QLPreviewPanelDataSource for views like IconGridView, FileListView, etc.
class QuickLookManager: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookManager()

    /// The URL currently being previewed
    var previewURL: URL?

    /// Whether we're currently controlling the panel
    private(set) var isControlling = false

    private override init() {
        super.init()
    }

    // MARK: - Public API

    func toggleQuickLook(for url: URL?) {
        previewURL = url

        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else if previewURL != nil {
            // Manually set ourselves as the data source since we may not be in responder chain
            panel.dataSource = self
            panel.delegate = self
            isControlling = true
            // Show Quick Look panel without stealing focus
            panel.orderFront(nil)
            panel.reloadData()
            // Make sure our window stays key so arrow keys work
            DispatchQueue.main.async {
                NSApp.mainWindow?.makeKey()
            }
        }
    }

    func updatePreview(for url: URL?) {
        previewURL = url

        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.reloadData()
        }
    }

    // MARK: - Panel Control (called from QuickLookHostView)

    func beginControlling(_ panel: QLPreviewPanel) {
        isControlling = true
        panel.dataSource = self
        panel.delegate = self
    }

    func endControlling(_ panel: QLPreviewPanel) {
        isControlling = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return previewURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return previewURL as QLPreviewItem?
    }
}

/// NSView wrapper that accepts Quick Look panel control and delegates to QuickLookManager
/// Add this to SwiftUI views via NSViewRepresentable to enable Quick Look
class QuickLookHostView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookManager.shared.beginControlling(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookManager.shared.endControlling(panel)
    }
}

/// SwiftUI wrapper for QuickLookHostView
struct QuickLookHost: NSViewRepresentable {
    func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        return view
    }

    func updateNSView(_ nsView: QuickLookHostView, context: Context) {
    }
}

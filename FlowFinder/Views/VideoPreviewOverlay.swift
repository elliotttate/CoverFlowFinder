import SwiftUI
import AVFoundation
import AppKit

/// Custom NSView that keeps its AVPlayerLayer sublayer sized to fill the view bounds.
private class VideoPreviewHostView: NSView {
    override func layout() {
        super.layout()
        // Resize any AVPlayerLayer sublayers to match the current bounds
        layer?.sublayers?.forEach { sublayer in
            if sublayer is AVPlayerLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sublayer.frame = bounds
                CATransaction.commit()
            }
        }
    }
}

/// NSViewRepresentable that hosts an AVPlayerLayer for inline video preview.
/// Used by IconGridView and MasonryView to overlay video playback on thumbnails.
struct VideoPreviewLayerView: NSViewRepresentable {
    let url: URL
    /// Toggled by the manager when playback is active; forces SwiftUI to call updateNSView.
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let view = VideoPreviewHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Attach the player layer if available and not already attached
        guard let playerLayer = InlineVideoPreviewManager.shared.activePlayerLayer(for: url) else {
            // Remove stale layers if preview is no longer active
            nsView.layer?.sublayers?.forEach { sublayer in
                if sublayer is AVPlayerLayer {
                    sublayer.removeFromSuperlayer()
                }
            }
            return
        }

        // Check if already attached to this view
        if playerLayer.superlayer === nsView.layer {
            playerLayer.frame = nsView.bounds
            return
        }

        // Remove from any previous parent and attach here
        playerLayer.removeFromSuperlayer()
        playerLayer.frame = nsView.bounds
        nsView.layer?.addSublayer(playerLayer)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Remove any player layers when the view is torn down
        nsView.layer?.sublayers?.forEach { sublayer in
            if sublayer is AVPlayerLayer {
                sublayer.removeFromSuperlayer()
            }
        }
    }
}

/// View modifier that adds inline video preview on hover for video items.
/// Wraps the content with a video overlay that appears when hovering.
struct VideoPreviewModifier: ViewModifier {
    let item: FileItem
    @Binding var isHovering: Bool
    let size: CGSize

    @ObservedObject private var previewManager = InlineVideoPreviewManager.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                if item.fileType == .video && isHovering && previewManager.currentPreviewURL == item.url && previewManager.isPreviewActive {
                    VideoPreviewLayerView(url: item.url, isActive: previewManager.isPreviewActive)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .onChange(of: isHovering) { _, hovering in
                guard AppSettings.shared.inlineVideoPreview else { return }
                if item.fileType == .video {
                    if hovering {
                        InlineVideoPreviewManager.shared.requestPreview(for: item)
                    } else {
                        InlineVideoPreviewManager.shared.cancelPreview()
                    }
                }
            }
    }
}

extension View {
    /// Adds Finder-style inline video preview on hover for video file items.
    func videoPreviewOnHover(item: FileItem, isHovering: Binding<Bool>, size: CGSize) -> some View {
        modifier(VideoPreviewModifier(item: item, isHovering: isHovering, size: size))
    }
}

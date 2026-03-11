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

// MARK: - Audio Preview Overlay

/// Overlay that shows a progress bar and pause button for audio preview on hover.
struct AudioPreviewOverlayView: View {
    let url: URL
    let size: CGSize
    @ObservedObject private var audioManager = InlineAudioPreviewManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // Bottom bar with progress and pause button
            HStack(spacing: 6) {
                // Pause/play button
                Button {
                    audioManager.togglePause()
                } label: {
                    Image(systemName: audioManager.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                }
                .buttonStyle(.plain)

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Track
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(height: 4)

                        // Fill
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: max(0, geo.size.width * audioManager.progress), height: 4)
                    }
                    .frame(height: geo.size.height)
                }
                .frame(height: 20)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.5)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

/// View modifier that adds inline audio/video preview on hover.
struct MediaPreviewModifier: ViewModifier {
    let item: FileItem
    @Binding var isHovering: Bool
    let size: CGSize

    @ObservedObject private var videoManager = InlineVideoPreviewManager.shared
    @ObservedObject private var audioManager = InlineAudioPreviewManager.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                // Video preview overlay
                if item.fileType == .video && isHovering && videoManager.currentPreviewURL == item.url && videoManager.isPreviewActive {
                    VideoPreviewLayerView(url: item.url, isActive: videoManager.isPreviewActive)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                // Audio preview overlay (progress bar + pause)
                if item.fileType == .audio && isHovering && audioManager.currentPreviewURL == item.url && audioManager.isPreviewActive {
                    AudioPreviewOverlayView(url: item.url, size: size)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
            .onChange(of: isHovering) { _, hovering in
                if item.fileType == .video {
                    guard AppSettings.shared.inlineVideoPreview else { return }
                    if hovering {
                        InlineVideoPreviewManager.shared.requestPreview(for: item)
                    } else {
                        InlineVideoPreviewManager.shared.cancelPreview()
                    }
                } else if item.fileType == .audio {
                    guard AppSettings.shared.inlineAudioPreview else { return }
                    if hovering {
                        InlineAudioPreviewManager.shared.requestPreview(for: item)
                    } else {
                        InlineAudioPreviewManager.shared.cancelPreview()
                    }
                }
            }
    }
}

extension View {
    /// Adds Finder-style inline video preview on hover for video file items.
    func videoPreviewOnHover(item: FileItem, isHovering: Binding<Bool>, size: CGSize) -> some View {
        modifier(MediaPreviewModifier(item: item, isHovering: isHovering, size: size))
    }
}

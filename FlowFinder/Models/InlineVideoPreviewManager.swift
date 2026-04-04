import AVFoundation
import AppKit
import Combine
import os.log

private let previewLog = OSLog(subsystem: "com.flowfinder", category: "InlineVideoPreview")

/// Manages inline video preview playback within file thumbnails.
/// Mirrors Finder's QLInlinePreviewController architecture using public AVFoundation APIs.
///
/// Finder uses three private QLInlinePreviewController instances (rollover, play, mouse)
/// coordinated by TDesktopInlinePreviewController. We achieve the same with a single
/// AVPlayer pool and a state machine: idle → debouncing → loading → playing.
@MainActor
final class InlineVideoPreviewManager: ObservableObject {
    static let shared = InlineVideoPreviewManager()

    // MARK: - Published State

    /// The URL currently being previewed (nil when idle)
    @Published private(set) var currentPreviewURL: URL?

    /// Whether a preview is actively playing
    @Published private(set) var isPreviewActive: Bool = false

    /// Whether the user is currently skimming (mouse moving over video)
    @Published private(set) var isSkimming: Bool = false

    /// Current skim progress (0...1) for overlay display
    @Published private(set) var skimProgress: Double = 0

    // MARK: - State Machine

    private enum PreviewState {
        case idle
        case debouncing(URL)
        case loading(URL, AVPlayer)
        case playing(URL, AVPlayer, AVPlayerLayer)

        var isActive: Bool {
            switch self {
            case .idle: return false
            default: return true
            }
        }
    }

    private var state: PreviewState = .idle

    // MARK: - Configuration

    /// Delay before starting preview (prevents flicker on fast mouse movement)
    private let debounceInterval: TimeInterval = 0.3

    /// Seek past black frames at start of video
    private let seekOffset = CMTime(seconds: 0.5, preferredTimescale: 600)

    /// Minimum interval between seek operations during skimming (throttle)
    private let seekThrottleInterval: TimeInterval = 1.0 / 30.0

    // MARK: - Resources

    private var debounceTimer: Timer?
    private var playerPool: [AVPlayer] = []
    private let maxPoolSize = 2
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var lastSeekTime: TimeInterval = 0
    private var isSeeking: Bool = false

    // MARK: - Callbacks for CALayer-based views (CoverFlow)

    /// Called when a player layer is ready to be attached to a host view
    var onPlayerLayerReady: ((AVPlayerLayer, URL) -> Void)?

    /// Called when the player layer should be detached
    var onPlayerLayerDetach: ((URL) -> Void)?

    // MARK: - Init

    private init() {
        setupNotifications()
    }

    // MARK: - Public API

    /// Request a video preview for the given item. Called on hover enter.
    /// The preview starts after a debounce delay to avoid flicker.
    func requestPreview(for item: FileItem) {
        guard item.fileType == .video, !item.isFromArchive else { return }
        guard AppSettings.shared.inlineVideoPreview else { return }

        let url = item.url

        // Already previewing this URL
        if currentPreviewURL == url {
            return
        }

        // Cancel any existing preview first
        cancelCurrentState()

        // Start debounce
        state = .debouncing(url)
        currentPreviewURL = url

        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginLoading(for: url)
            }
        }

        os_log(.debug, log: previewLog, "requestPreview: debouncing for %{public}@", url.lastPathComponent)
    }

    /// Cancel the current preview. Called on hover exit.
    func cancelPreview() {
        guard state.isActive else { return }
        isSkimming = false
        skimProgress = 0
        let url = currentPreviewURL
        cancelCurrentState()
        os_log(.debug, log: previewLog, "cancelPreview: stopped for %{public}@", url?.lastPathComponent ?? "nil")
    }

    /// Stop all previews immediately. Called on folder navigation, scroll, window deactivation.
    func stopAllPreviews() {
        cancelCurrentState()
    }

    /// Get the active player layer if it matches the given URL.
    /// Used by CoverFlowNSView to grab the layer for direct CALayer insertion.
    func activePlayerLayer(for url: URL) -> AVPlayerLayer? {
        if case .playing(let playingURL, _, let layer) = state, playingURL == url {
            return layer
        }
        return nil
    }

    /// Seek the current preview to a fraction of its duration (0 = start, 1 = end).
    /// Called continuously as the mouse moves across the thumbnail.
    func seekToFraction(_ fraction: Double, for url: URL) {
        guard AppSettings.shared.videoSkimming else { return }
        guard case .playing(let playingURL, let player, _) = state, playingURL == url else { return }
        guard let duration = player.currentItem?.duration, duration != .zero, duration != .indefinite else { return }

        let clampedFraction = min(max(fraction, 0), 1)

        // Pause playback when skimming starts
        if !isSkimming {
            player.pause()
            isSkimming = true
            // Remove looping observer during skimming
            if let endObserver = endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }

        skimProgress = clampedFraction

        // Throttle seeks to avoid overwhelming the decoder
        let now = CACurrentMediaTime()
        guard now - lastSeekTime >= seekThrottleInterval else { return }
        guard !isSeeking else { return }

        lastSeekTime = now
        isSeeking = true

        let targetSeconds = CMTimeGetSeconds(duration) * clampedFraction
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
            }
        }
    }

    /// End skimming and resume normal playback. Called on hover exit.
    func endSkimming() {
        guard isSkimming else { return }
        isSkimming = false
        skimProgress = 0

        if case .playing(_, let player, _) = state {
            player.play()
            setupLooping(for: player)
        }
    }

    // MARK: - State Machine

    private func beginLoading(for url: URL) {
        guard case .debouncing(let debouncedURL) = state, debouncedURL == url else {
            return
        }

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let playerItem = AVPlayerItem(asset: asset)
        let player = acquirePlayer()
        player.replaceCurrentItem(with: playerItem)
        player.isMuted = true

        state = .loading(url, player)
        os_log(.debug, log: previewLog, "beginLoading: %{public}@", url.lastPathComponent)

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor

        // Observe player status to know when ready
        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard case .loading(let loadingURL, _) = self.state, loadingURL == url else { return }

                switch item.status {
                case .readyToPlay:
                    self.beginPlayback(url: url, player: player, layer: playerLayer)
                case .failed:
                    os_log(.error, log: previewLog, "Failed to load: %{public}@", url.lastPathComponent)
                    self.cancelCurrentState()
                default:
                    break
                }
            }
        }
    }

    private func beginPlayback(url: URL, player: AVPlayer, layer: AVPlayerLayer) {
        // Seek past potential black frame
        let duration = player.currentItem?.duration ?? .zero
        let seekTime: CMTime
        if duration != .zero && duration != .indefinite && CMTimeGetSeconds(duration) > 1.0 {
            seekTime = seekOffset
        } else {
            seekTime = .zero
        }

        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard case .loading(let loadingURL, _) = self.state, loadingURL == url else { return }

                let skimmingEnabled = AppSettings.shared.videoSkimming

                if skimmingEnabled {
                    // In skimming mode, pause and wait for mouse-driven seeking
                    player.pause()
                } else {
                    player.play()
                }

                self.state = .playing(url, player, layer)
                self.isPreviewActive = true

                if !skimmingEnabled {
                    // Only setup looping for non-skimming mode
                    self.setupLooping(for: player)
                }

                // Notify host views
                self.onPlayerLayerReady?(layer, url)

                os_log(.debug, log: previewLog, "beginPlayback: %{public}@ %{public}@", skimmingEnabled ? "skimming" : "playing", url.lastPathComponent)
            }
        }
    }

    private func setupLooping(for player: AVPlayer) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let player = player else { return }
                guard let self = self else { return }
                // Loop back, skipping potential black frame
                let duration = player.currentItem?.duration ?? .zero
                let seekTime: CMTime
                if CMTimeGetSeconds(duration) > 1.0 {
                    seekTime = self.seekOffset
                } else {
                    seekTime = .zero
                }
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
        }
    }

    private func cancelCurrentState() {
        // Cancel debounce timer
        debounceTimer?.invalidate()
        debounceTimer = nil

        // Clean up observers
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        // Handle state-specific cleanup
        switch state {
        case .playing(let url, let player, let layer):
            layer.removeFromSuperlayer()
            onPlayerLayerDetach?(url)
            releasePlayer(player)
        case .loading(_, let player):
            releasePlayer(player)
        case .debouncing, .idle:
            break
        }

        state = .idle
        currentPreviewURL = nil
        isPreviewActive = false
        isSkimming = false
        skimProgress = 0
        isSeeking = false
    }

    // MARK: - Player Pool

    private func acquirePlayer() -> AVPlayer {
        if let player = playerPool.popLast() {
            return player
        }
        let player = AVPlayer()
        player.isMuted = true
        return player
    }

    private func releasePlayer(_ player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if playerPool.count < maxPoolSize {
            playerPool.append(player)
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopAllPreviews()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopAllPreviews()
            }
        }
    }
}


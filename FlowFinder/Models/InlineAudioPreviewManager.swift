import AVFoundation
import AppKit
import Combine
import os.log

private let audioPreviewLog = OSLog(subsystem: "com.flowfinder", category: "InlineAudioPreview")

/// Safety net for audio previews whose hover-end never arrives (e.g. the hovered cell was recycled
/// or scrolled away). The overlay reports a heartbeat while the mouse moves over it; if the mouse
/// has since moved somewhere else and no heartbeat came for a while, the preview is stale.
/// A stationary mouse never trips it, so audio keeps playing while the user rests on a track.
struct InlineAudioHoverWatchdog {
    /// How long without a heartbeat before the preview may be stopped.
    var gracePeriod: TimeInterval = 2.0
    /// How far (in points) the mouse must have moved since the last heartbeat.
    var movementTolerance: CGFloat = 24

    private(set) var lastHeartbeatTime: TimeInterval = 0
    private(set) var lastHeartbeatLocation: CGPoint = .zero

    mutating func noteHeartbeat(at location: CGPoint, now: TimeInterval) {
        lastHeartbeatTime = now
        lastHeartbeatLocation = location
    }

    func shouldStop(mouseLocation: CGPoint, now: TimeInterval) -> Bool {
        guard now - lastHeartbeatTime >= gracePeriod else { return false }
        let distance = hypot(mouseLocation.x - lastHeartbeatLocation.x, mouseLocation.y - lastHeartbeatLocation.y)
        return distance >= movementTolerance
    }
}

/// Manages inline audio preview playback within file thumbnails.
/// Similar to InlineVideoPreviewManager but for audio files, with playback progress tracking.
@MainActor
final class InlineAudioPreviewManager: ObservableObject {
    static let shared = InlineAudioPreviewManager()

    // MARK: - Published State

    @Published private(set) var currentPreviewURL: URL?
    @Published private(set) var isPreviewActive: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var duration: TimeInterval = 0

    /// Playback position (0...1). Observed only by the overlay that draws the progress bar.
    let progressState = InlinePreviewProgress()

    /// Playback position, 0.0 to 1.0
    var progress: Double { progressState.value }

    // MARK: - State Machine

    private enum PreviewState {
        case idle
        case debouncing(URL)
        case loading(URL, AVPlayer)
        case playing(URL, AVPlayer)

        var isActive: Bool {
            switch self {
            case .idle: return false
            default: return true
            }
        }
    }

    private var state: PreviewState = .idle

    // MARK: - Configuration

    private let debounceInterval: TimeInterval = 0.3
    private let progressInterval: TimeInterval = 1.0 / 10.0
    private let watchdogInterval: TimeInterval = 0.5

    // MARK: - Resources

    private var debounceTimer: Timer?
    private var progressTimer: Timer?
    private var watchdogTimer: Timer?
    private var watchdog = InlineAudioHoverWatchdog()
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    // MARK: - Init

    private init() {
        setupNotifications()
    }

    // MARK: - Public API

    func requestPreview(for item: FileItem) {
        guard item.fileType == .audio, !item.isFromArchive else { return }
        guard AppSettings.shared.inlineAudioPreview else { return }

        let url = item.url

        if state.isActive, currentPreviewURL == url {
            return
        }

        cancelCurrentState()

        state = .debouncing(url)
        currentPreviewURL = url
        watchdog.noteHeartbeat(at: NSEvent.mouseLocation, now: CACurrentMediaTime())
        startWatchdog()

        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginLoading(for: url)
            }
        }
    }

    /// Cancel the current preview, whatever it is.
    func cancelPreview() {
        guard state.isActive else { return }
        cancelCurrentState()
    }

    /// Cancel the preview only if it is for `url` (hover-exit / disappearing cells).
    func cancelPreview(for url: URL) {
        guard state.isActive, currentPreviewURL == url else { return }
        cancelCurrentState()
    }

    /// Called while the mouse moves over `item`'s overlay. Keeps the current preview alive, or
    /// restarts it if the user came back to a track whose preview was stopped.
    func noteHover(for item: FileItem) {
        if state.isActive {
            guard currentPreviewURL == item.url else { return }
            watchdog.noteHeartbeat(at: NSEvent.mouseLocation, now: CACurrentMediaTime())
        } else {
            requestPreview(for: item)
        }
    }

    func togglePause() {
        guard case .playing(_, let player) = state else { return }
        if isPaused {
            player.play()
            isPaused = false
            startProgressTimer(player: player)
        } else {
            player.pause()
            isPaused = true
            stopProgressTimer()
        }
    }

    func stopAllPreviews() {
        cancelCurrentState()
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
        let player = AVPlayer(playerItem: playerItem)
        player.volume = 0.5

        state = .loading(url, player)

        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard case .loading(let loadingURL, _) = self.state, loadingURL == url else { return }

                switch item.status {
                case .readyToPlay:
                    self.beginPlayback(url: url, player: player)
                case .failed:
                    os_log(.error, log: audioPreviewLog, "Failed to load: %{private}@", url.lastPathComponent)
                    self.cancelCurrentState()
                default:
                    break
                }
            }
        }
    }

    private func beginPlayback(url: URL, player: AVPlayer) {
        duration = InlinePreviewTiming.seconds(of: player.currentItem?.duration ?? .invalid) ?? 0

        player.play()
        state = .playing(url, player)
        isPreviewActive = true
        isPaused = false
        progressState.reset()

        setupLooping(for: player)
        startProgressTimer(player: player)
    }

    private func setupLooping(for player: AVPlayer) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let player = player else { return }
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                self?.isPaused = false
            }
        }
    }

    private func startProgressTimer(player: AVPlayer) {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: progressInterval, repeats: true) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self = self, let player = player else { return }
                guard self.duration > 0 else { return }
                let currentTime = CMTimeGetSeconds(player.currentTime())
                guard currentTime.isFinite else { return }
                self.progressState.update(currentTime / self.duration)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkWatchdog()
            }
        }
    }

    private func checkWatchdog() {
        guard state.isActive else {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            return
        }
        if watchdog.shouldStop(mouseLocation: NSEvent.mouseLocation, now: CACurrentMediaTime()) {
            os_log(.debug, log: audioPreviewLog, "Stopping stale audio preview (no hover heartbeat)")
            cancelCurrentState()
        }
    }

    private func cancelCurrentState() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        stopProgressTimer()

        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        switch state {
        case .playing(_, let player), .loading(_, let player):
            player.pause()
            player.replaceCurrentItem(with: nil)
        case .debouncing, .idle:
            break
        }

        state = .idle
        if currentPreviewURL != nil { currentPreviewURL = nil }
        if isPreviewActive { isPreviewActive = false }
        if isPaused { isPaused = false }
        if duration != 0 { duration = 0 }
        progressState.reset()
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

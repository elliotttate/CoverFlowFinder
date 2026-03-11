import AVFoundation
import AppKit
import Combine
import os.log

private let audioPreviewLog = OSLog(subsystem: "com.flowfinder", category: "InlineAudioPreview")

/// Manages inline audio preview playback within file thumbnails.
/// Similar to InlineVideoPreviewManager but for audio files, with playback progress tracking.
@MainActor
final class InlineAudioPreviewManager: ObservableObject {
    static let shared = InlineAudioPreviewManager()

    // MARK: - Published State

    @Published private(set) var currentPreviewURL: URL?
    @Published private(set) var isPreviewActive: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var progress: Double = 0  // 0.0 to 1.0
    @Published private(set) var duration: TimeInterval = 0

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

    // MARK: - Resources

    private var debounceTimer: Timer?
    private var progressTimer: Timer?
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

        if currentPreviewURL == url {
            return
        }

        cancelCurrentState()

        state = .debouncing(url)
        currentPreviewURL = url

        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginLoading(for: url)
            }
        }
    }

    func cancelPreview() {
        guard state.isActive else { return }
        cancelCurrentState()
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
                    os_log(.error, log: audioPreviewLog, "Failed to load: %{public}@", url.lastPathComponent)
                    self.cancelCurrentState()
                default:
                    break
                }
            }
        }
    }

    private func beginPlayback(url: URL, player: AVPlayer) {
        let durationCMTime = player.currentItem?.duration ?? .zero
        if durationCMTime != .zero && durationCMTime != .indefinite {
            duration = CMTimeGetSeconds(durationCMTime)
        } else {
            duration = 0
        }

        player.play()
        state = .playing(url, player)
        isPreviewActive = true
        isPaused = false
        progress = 0

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
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self = self, let player = player else { return }
                guard self.duration > 0 else { return }
                let currentTime = CMTimeGetSeconds(player.currentTime())
                self.progress = min(1.0, max(0.0, currentTime / self.duration))
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func cancelCurrentState() {
        debounceTimer?.invalidate()
        debounceTimer = nil
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
        currentPreviewURL = nil
        isPreviewActive = false
        isPaused = false
        progress = 0
        duration = 0
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

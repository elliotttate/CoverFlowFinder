import AVFoundation
import AppKit
import Combine
import os.log

private let previewLog = OSLog(subsystem: "com.flowfinder", category: "InlineVideoPreview")

/// Entry points for stopping inline media previews (video and audio). A window or view model stops
/// only its own previews, so navigating in one window doesn't cut off a preview in another.
@MainActor
enum InlinePreviews {
    /// Stops every preview in every window (app-level: deactivation, termination).
    static func stopAll() {
        InlineVideoPreviewManager.shared.stopAllPreviews()
        InlineAudioPreviewManager.shared.stopAllPreviews()
    }

    /// Stops the previews started in `window` — the window under the mouse when the preview was
    /// requested. Use when that window navigates, refreshes, changes view mode or closes a tab.
    static func stopPreviews(inWindow window: NSWindow) {
        InlineVideoPreviewManager.shared.stopPreviews(inWindow: window)
        InlineAudioPreviewManager.shared.stopPreviews(inWindow: window)
    }

    /// Stops the previews whose file matches `predicate` — e.g. the items a view model shows, when it
    /// navigates away (a view model doesn't know its window).
    static func stopPreviews(where predicate: (URL) -> Bool) {
        InlineVideoPreviewManager.shared.stopPreviews(where: predicate)
        InlineAudioPreviewManager.shared.stopPreviews(where: predicate)
    }

    /// Stops the previews of files directly inside `folder`.
    static func stopPreviews(inFolder folder: URL) {
        let folderPath = folder.standardizedFileURL.path
        stopPreviews { $0.deletingLastPathComponent().standardizedFileURL.path == folderPath }
    }

    /// Whether `item`'s contents are on disk, judging by its cloud status; nil if that isn't known yet.
    /// Previewing a cloud file that isn't downloaded would download all of it, so hover previews skip it.
    static func isLocallyAvailable(_ item: FileItem) -> Bool? {
        switch item.cloudStatus {
        case nil:
            return nil
        case .notDownloaded?, .downloading?:
            return false
        default:
            return true
        }
    }

    /// The number of the window under the mouse (0 if none): the window a hover preview belongs to.
    static func windowNumberUnderMouse() -> Int {
        NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
    }

    /// Checks off the main thread whether `url`'s contents are on disk (an iCloud file may not be),
    /// then calls `completion` on the main thread.
    static func checkLocalAvailability(of url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // A fresh URL: resource values cached on the item's URL could be out of date
            let isAvailable = ThumbnailCacheManager.isLocallyAvailable(URL(fileURLWithPath: url.path))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(isAvailable)
                }
            }
        }
    }
}

/// A high-frequency progress value (0...1) kept out of the preview managers, so only the one
/// overlay that displays it re-renders. Publishes only changes large enough to see.
@MainActor
final class InlinePreviewProgress: ObservableObject {
    @Published private(set) var value: Double = 0

    /// Smallest change worth publishing (the ends 0 and 1 are always published).
    let minimumStep: Double

    init(minimumStep: Double = 0.002) {
        self.minimumStep = minimumStep
    }

    func update(_ newValue: Double) {
        let clamped = newValue.isFinite ? min(max(newValue, 0), 1) : 0
        guard clamped != value else { return }
        if clamped != 0 && clamped != 1 && abs(clamped - value) < minimumStep { return }
        value = clamped
    }

    func reset() {
        if value != 0 { value = 0 }
    }
}

/// Media time helpers that reject invalid, indefinite, infinite and NaN times.
enum InlinePreviewTiming {
    /// The duration in seconds, or nil if it isn't a usable positive number.
    static func seconds(of time: CMTime) -> Double? {
        guard time.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

/// Throttles skim seeks while remembering the latest target, so the final mouse position is always
/// shown: a target that arrives while a seek is in flight (or too soon after the last one) is replayed
/// once the decoder is free.
struct SkimSeekScheduler {
    enum Action: Equatable {
        /// Seek to this fraction now.
        case seek(Double)
        /// Hold the target. If `retryAfter` is set, call `retry(now:)` after that many seconds;
        /// otherwise the target is replayed by `seekFinished(now:)`.
        case wait(retryAfter: TimeInterval?)
    }

    let minimumInterval: TimeInterval
    private(set) var isSeeking = false
    private(set) var pendingFraction: Double?
    private(set) var lastSeekTime: TimeInterval = -.infinity

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func request(_ fraction: Double, now: TimeInterval) -> Action {
        if isSeeking {
            pendingFraction = fraction
            return .wait(retryAfter: nil)
        }
        let elapsed = now - lastSeekTime
        if elapsed < minimumInterval {
            pendingFraction = fraction
            return .wait(retryAfter: minimumInterval - elapsed)
        }
        return start(fraction, now: now)
    }

    /// Call when the in-flight seek completes. Returns a pending target to seek to now, if any.
    mutating func seekFinished(now: TimeInterval) -> Double? {
        isSeeking = false
        guard let pending = pendingFraction else { return nil }
        guard case .seek(let fraction) = start(pending, now: now) else { return nil }
        return fraction
    }

    /// Call when a `.wait(retryAfter:)` delay has elapsed.
    mutating func retry(now: TimeInterval) -> Action? {
        guard !isSeeking, let pending = pendingFraction else { return nil }
        let elapsed = now - lastSeekTime
        if elapsed < minimumInterval {
            return .wait(retryAfter: minimumInterval - elapsed)
        }
        return start(pending, now: now)
    }

    mutating func reset() {
        isSeeking = false
        pendingFraction = nil
        lastSeekTime = -.infinity
    }

    private mutating func start(_ fraction: Double, now: TimeInterval) -> Action {
        isSeeking = true
        lastSeekTime = now
        pendingFraction = nil
        return .seek(fraction)
    }
}

/// Identifies a view that hosts preview layers itself (Cover Flow) instead of observing the manager.
struct InlinePreviewHostToken: Hashable {
    fileprivate let id: Int
}

/// Manages inline video preview playback within file thumbnails.
/// Mirrors Finder's QLInlinePreviewController architecture using public AVFoundation APIs.
///
/// Finder uses three private QLInlinePreviewController instances (rollover, play, mouse)
/// coordinated by TDesktopInlinePreviewController. We achieve the same with a single
/// AVPlayer pool and a state machine: idle → debouncing → loading → playing.
///
/// SwiftUI overlays observe `currentPreviewURL`/`isPreviewActive` and fetch the layer with
/// `activePlayerLayer(for:)`. CALayer-based views (Cover Flow) register as hosts; a host only
/// receives the layer for previews it requested, and only stops its own previews.
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

    /// Skim position (0...1). Observed only by the overlay that draws the scrub bar.
    let skimProgressState = InlinePreviewProgress()

    /// Current skim progress (0...1)
    var skimProgress: Double { skimProgressState.value }

    /// The host that requested the current preview (nil for SwiftUI overlays).
    private(set) var currentHost: InlinePreviewHostToken?

    /// The window the current preview was requested in (0 if unknown).
    private var currentWindowNumber = 0

    /// The current item's cloud status wasn't known: check that it's downloaded before loading it.
    private var needsAvailabilityCheck = false

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
    private static let seekThrottleInterval: TimeInterval = 1.0 / 30.0

    // MARK: - Resources

    private var debounceTimer: Timer?
    private var playerPool: [AVPlayer] = []
    private let maxPoolSize = 2
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var seekScheduler = SkimSeekScheduler(minimumInterval: InlineVideoPreviewManager.seekThrottleInterval)
    private var seekRetryTimer: Timer?
    /// Bumped whenever the preview is torn down, so late seek completions are ignored.
    private var seekGeneration = 0

    // MARK: - Hosts (CALayer-based views)

    private struct HostCallbacks {
        let onLayerReady: (AVPlayerLayer, URL) -> Void
        let onLayerDetach: (URL) -> Void
    }

    private var hosts: [InlinePreviewHostToken: HostCallbacks] = [:]
    private var nextHostID = 1

    // MARK: - Init

    private init() {
        setupNotifications()
    }

    // MARK: - Host Registration

    /// Register a view that attaches the player layer itself. `onLayerReady` is called only for
    /// previews this host requested; `onLayerDetach` when such a preview stops.
    func registerHost(
        onLayerReady: @escaping (AVPlayerLayer, URL) -> Void,
        onLayerDetach: @escaping (URL) -> Void
    ) -> InlinePreviewHostToken {
        let token = InlinePreviewHostToken(id: nextHostID)
        nextHostID += 1
        hosts[token] = HostCallbacks(onLayerReady: onLayerReady, onLayerDetach: onLayerDetach)
        return token
    }

    /// Unregister a host, stopping its preview if it owns the current one.
    func unregisterHost(_ token: InlinePreviewHostToken) {
        if state.isActive, currentHost == token {
            cancelCurrentState()
        }
        hosts.removeValue(forKey: token)
    }

    // MARK: - Public API

    /// Request a video preview for the given item. Called on hover enter.
    /// The preview starts after a debounce delay to avoid flicker.
    /// - Parameter host: The registered host requesting the preview, or nil for SwiftUI overlays.
    /// iCloud files that aren't downloaded are skipped (playing one would download it).
    func requestPreview(for item: FileItem, host: InlinePreviewHostToken? = nil) {
        guard item.fileType == .video, !item.isFromArchive else { return }
        guard AppSettings.shared.inlineVideoPreview else { return }
        let isLocallyAvailable = InlinePreviews.isLocallyAvailable(item)
        guard isLocallyAvailable != false else { return }

        let url = item.url

        // Already previewing this URL for the same requester
        if state.isActive, currentPreviewURL == url, currentHost == host {
            return
        }

        // Cancel any existing preview first
        cancelCurrentState()

        // Start debounce
        state = .debouncing(url)
        currentHost = host
        currentWindowNumber = InlinePreviews.windowNumberUnderMouse()
        needsAvailabilityCheck = isLocallyAvailable == nil
        currentPreviewURL = url

        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.beginLoading(for: url)
            }
        }

        os_log(.debug, log: previewLog, "requestPreview: debouncing for %{private}@", url.lastPathComponent)
    }

    /// Cancel the current preview, whoever requested it.
    func cancelPreview() {
        guard state.isActive else { return }
        cancelCurrentState()
    }

    /// Cancel the preview only if it is for `url` and was requested by `host`
    /// (nil = SwiftUI overlays). Hover-exit uses this so it can't stop another view's preview.
    func cancelPreview(for url: URL, host: InlinePreviewHostToken? = nil) {
        guard state.isActive, currentPreviewURL == url, currentHost == host else { return }
        cancelCurrentState()
    }

    /// Stop the preview if `host` requested it.
    func stopPreviews(ownedBy host: InlinePreviewHostToken) {
        guard state.isActive, currentHost == host else { return }
        cancelCurrentState()
    }

    /// The URL being previewed for `host`, if it owns the current preview.
    func previewURL(ownedBy host: InlinePreviewHostToken) -> URL? {
        guard state.isActive, currentHost == host else { return nil }
        return currentPreviewURL
    }

    /// Stop the preview if it was requested in `window` (or the window isn't known).
    func stopPreviews(inWindow window: NSWindow) {
        guard state.isActive, currentWindowNumber == 0 || currentWindowNumber == window.windowNumber else { return }
        cancelCurrentState()
    }

    /// Stop the preview if its file matches `predicate`.
    func stopPreviews(where predicate: (URL) -> Bool) {
        guard state.isActive, let url = currentPreviewURL, predicate(url) else { return }
        cancelCurrentState()
    }

    /// Stop all previews immediately, in every window (app deactivation, termination).
    func stopAllPreviews() {
        cancelCurrentState()
    }

    /// Get the active player layer if it matches the given URL.
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
        guard fraction.isFinite else { return }
        guard case .playing(let playingURL, let player, _) = state, playingURL == url else { return }
        guard let duration = InlinePreviewTiming.seconds(of: player.currentItem?.duration ?? .invalid) else { return }

        let clampedFraction = min(max(fraction, 0), 1)

        // Pause playback when skimming starts
        if !isSkimming {
            player.pause()
            isSkimming = true
            // Remove looping observer during skimming
            removeEndObserver()
        }

        skimProgressState.update(clampedFraction)
        perform(seekScheduler.request(clampedFraction, now: CACurrentMediaTime()), player: player, duration: duration)
    }

    /// End skimming. In skimming mode the preview stays paused on the last frame (hovering
    /// elsewhere in the cell must not start looping playback); otherwise playback resumes.
    func endSkimming() {
        guard isSkimming else { return }
        isSkimming = false
        skimProgressState.reset()

        if !AppSettings.shared.videoSkimming, case .playing(_, let player, _) = state {
            player.play()
            setupLooping(for: player)
        }
    }

    /// End skimming only if the current preview is for `url`.
    func endSkimming(for url: URL) {
        guard currentPreviewURL == url else { return }
        endSkimming()
    }

    // MARK: - Skim Seeking

    private func perform(_ action: SkimSeekScheduler.Action, player: AVPlayer, duration: Double) {
        switch action {
        case .seek(let fraction):
            issueSeek(to: fraction, player: player, duration: duration)
        case .wait(let retryAfter):
            guard let retryAfter, seekRetryTimer == nil else { return }
            seekRetryTimer = Timer.scheduledTimer(withTimeInterval: max(retryAfter, 0.001), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.retryPendingSeek()
                }
            }
        }
    }

    private func issueSeek(to fraction: Double, player: AVPlayer, duration: Double) {
        let generation = seekGeneration
        let targetTime = CMTime(seconds: duration * fraction, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                self?.seekDidFinish(generation: generation)
            }
        }
    }

    private func seekDidFinish(generation: Int) {
        guard generation == seekGeneration else { return }
        guard case .playing(_, let player, _) = state,
              let duration = InlinePreviewTiming.seconds(of: player.currentItem?.duration ?? .invalid) else {
            seekScheduler.reset()
            return
        }
        if let next = seekScheduler.seekFinished(now: CACurrentMediaTime()) {
            issueSeek(to: next, player: player, duration: duration)
        }
    }

    private func retryPendingSeek() {
        seekRetryTimer = nil
        guard case .playing(_, let player, _) = state,
              let duration = InlinePreviewTiming.seconds(of: player.currentItem?.duration ?? .invalid),
              let action = seekScheduler.retry(now: CACurrentMediaTime()) else { return }
        perform(action, player: player, duration: duration)
    }

    // MARK: - State Machine

    private func beginLoading(for url: URL) {
        guard case .debouncing(let debouncedURL) = state, debouncedURL == url else {
            return
        }
        if needsAvailabilityCheck {
            InlinePreviews.checkLocalAvailability(of: url) { [weak self] isAvailable in
                guard let self, case .debouncing(let debouncedURL) = self.state, debouncedURL == url else { return }
                guard isAvailable else {
                    self.cancelCurrentState()
                    return
                }
                self.needsAvailabilityCheck = false
                self.beginLoading(for: url)
            }
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
        os_log(.debug, log: previewLog, "beginLoading: %{private}@", url.lastPathComponent)

        // Observe player status to know when ready
        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard case .loading(let loadingURL, _) = self.state, loadingURL == url else { return }

                switch item.status {
                case .readyToPlay:
                    self.beginPlayback(url: url, player: player)
                case .failed:
                    os_log(.error, log: previewLog, "Failed to load: %{private}@", url.lastPathComponent)
                    self.cancelCurrentState()
                default:
                    break
                }
            }
        }
    }

    private func beginPlayback(url: URL, player: AVPlayer) {
        // Seek past potential black frame
        let seekTime: CMTime
        if let duration = InlinePreviewTiming.seconds(of: player.currentItem?.duration ?? .invalid), duration > 1.0 {
            seekTime = seekOffset
        } else {
            seekTime = .zero
        }

        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                self?.didSeekToStart(url: url, player: player)
            }
        }
    }

    private func didSeekToStart(url: URL, player: AVPlayer) {
        guard case .loading(let loadingURL, let loadingPlayer) = state,
              loadingURL == url, loadingPlayer === player else { return }

        let skimmingEnabled = AppSettings.shared.videoSkimming

        if skimmingEnabled {
            // In skimming mode, pause and wait for mouse-driven seeking
            player.pause()
        } else {
            player.play()
        }

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.clear.cgColor

        state = .playing(url, player, layer)
        isPreviewActive = true

        if !skimmingEnabled {
            // Only setup looping for non-skimming mode
            setupLooping(for: player)
        }

        // Hand the layer to the host that asked for it (SwiftUI overlays pull it instead)
        if let host = currentHost {
            hosts[host]?.onLayerReady(layer, url)
        }

        os_log(.debug, log: previewLog, "beginPlayback: %{public}@ %{private}@", skimmingEnabled ? "skimming" : "playing", url.lastPathComponent)
    }

    private func setupLooping(for player: AVPlayer) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let player = player else { return }
                guard let self = self else { return }
                // Loop back, skipping potential black frame
                let seekTime: CMTime
                if let duration = InlinePreviewTiming.seconds(of: player.currentItem?.duration ?? .invalid), duration > 1.0 {
                    seekTime = self.seekOffset
                } else {
                    seekTime = .zero
                }
                player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func cancelCurrentState() {
        // Cancel debounce timer
        debounceTimer?.invalidate()
        debounceTimer = nil
        seekRetryTimer?.invalidate()
        seekRetryTimer = nil

        // Clean up observers
        statusObserver?.invalidate()
        statusObserver = nil
        removeEndObserver()

        let host = currentHost

        // Handle state-specific cleanup
        switch state {
        case .playing(let url, let player, let layer):
            layer.removeFromSuperlayer()
            if let host {
                hosts[host]?.onLayerDetach(url)
            }
            releasePlayer(player)
        case .loading(_, let player):
            releasePlayer(player)
        case .debouncing, .idle:
            break
        }

        state = .idle
        currentHost = nil
        currentWindowNumber = 0
        needsAvailabilityCheck = false
        seekGeneration &+= 1
        seekScheduler.reset()
        if currentPreviewURL != nil { currentPreviewURL = nil }
        if isPreviewActive { isPreviewActive = false }
        if isSkimming { isSkimming = false }
        skimProgressState.reset()
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

import AppKit
import AudioToolbox
import Foundation

enum FinderSoundEffect: String, CaseIterable {
    case emptyTrash
    case moveToTrash
    case dragToTrash
    case poofItemOffDock
    case volumeMount
    case volumeUnmount
    case screenCapture
    case grab
    case shutter
    case burnComplete
    case burnFailed
    case paymentSuccess
    case paymentFailure
    case alertBasso
    case alertBlow
    case alertBottle
    case alertFrog
    case alertFunk
    case alertGlass
    case alertHero
    case alertMorse
    case alertPing
    case alertPop
    case alertPurr
    case alertSosumi
    case alertSubmarine
    case alertTink
    case invitation
}

private enum FinderSoundPaths {
    static let finder = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder"
    static let dock = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock"
    static let system = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system"
    static let alerts = "/System/Library/Sounds"
    static let finderBundle = "/System/Library/CoreServices/Finder.app/Contents/Resources"
}

extension FinderSoundEffect {
    var fileURL: URL? {
        let path: String
        switch self {
        case .emptyTrash:
            path = "\(FinderSoundPaths.finder)/empty trash.aif"
        case .moveToTrash:
            path = "\(FinderSoundPaths.finder)/move to trash.aif"
        case .dragToTrash:
            path = "\(FinderSoundPaths.dock)/drag to trash.aif"
        case .poofItemOffDock:
            path = "\(FinderSoundPaths.dock)/poof item off dock.aif"
        case .volumeMount:
            path = "\(FinderSoundPaths.system)/Volume Mount.aif"
        case .volumeUnmount:
            path = "\(FinderSoundPaths.system)/Volume Unmount.aif"
        case .screenCapture:
            path = "\(FinderSoundPaths.system)/Screen Capture.aif"
        case .grab:
            path = "\(FinderSoundPaths.system)/Grab.aif"
        case .shutter:
            path = "\(FinderSoundPaths.system)/Shutter.aif"
        case .burnComplete:
            path = "\(FinderSoundPaths.system)/burn complete.aif"
        case .burnFailed:
            path = "\(FinderSoundPaths.system)/burn failed.aif"
        case .paymentSuccess:
            path = "\(FinderSoundPaths.system)/payment_success.aif"
        case .paymentFailure:
            path = "\(FinderSoundPaths.system)/payment_failure.aif"
        case .alertBasso:
            path = "\(FinderSoundPaths.alerts)/Basso.aiff"
        case .alertBlow:
            path = "\(FinderSoundPaths.alerts)/Blow.aiff"
        case .alertBottle:
            path = "\(FinderSoundPaths.alerts)/Bottle.aiff"
        case .alertFrog:
            path = "\(FinderSoundPaths.alerts)/Frog.aiff"
        case .alertFunk:
            path = "\(FinderSoundPaths.alerts)/Funk.aiff"
        case .alertGlass:
            path = "\(FinderSoundPaths.alerts)/Glass.aiff"
        case .alertHero:
            path = "\(FinderSoundPaths.alerts)/Hero.aiff"
        case .alertMorse:
            path = "\(FinderSoundPaths.alerts)/Morse.aiff"
        case .alertPing:
            path = "\(FinderSoundPaths.alerts)/Ping.aiff"
        case .alertPop:
            path = "\(FinderSoundPaths.alerts)/Pop.aiff"
        case .alertPurr:
            path = "\(FinderSoundPaths.alerts)/Purr.aiff"
        case .alertSosumi:
            path = "\(FinderSoundPaths.alerts)/Sosumi.aiff"
        case .alertSubmarine:
            path = "\(FinderSoundPaths.alerts)/Submarine.aiff"
        case .alertTink:
            path = "\(FinderSoundPaths.alerts)/Tink.aiff"
        case .invitation:
            path = "\(FinderSoundPaths.finderBundle)/Invitation.aiff"
        }
        return URL(fileURLWithPath: path)
    }
}

@MainActor
final class FinderSoundEffects {
    static let shared = FinderSoundEffects()

    private var soundIDs: [FinderSoundEffect: SystemSoundID] = [:]
    private let fileManager = FileManager.default
    private let lock = NSLock()

    func play(_ effect: FinderSoundEffect) {
        guard AppSettings.shared.soundEffectsEnabled else { return }
        guard let soundID = soundID(for: effect) else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    private func soundID(for effect: FinderSoundEffect) -> SystemSoundID? {
        lock.lock()
        defer { lock.unlock() }

        if let existing = soundIDs[effect] {
            return existing
        }

        guard let url = effect.fileURL, fileManager.fileExists(atPath: url.path) else { return nil }

        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else { return nil }

        soundIDs[effect] = soundID
        return soundID
    }

    deinit {
        lock.lock()
        let ids = Array(soundIDs.values)
        soundIDs.removeAll()
        lock.unlock()

        for soundID in ids {
            AudioServicesDisposeSystemSoundID(soundID)
        }
    }
}

/// Plays the mount/unmount sounds — but only for volumes the user can actually see (the ones the
/// sidebar shows). NSWorkspace reports every mount on the system: hidden disk images mounted by
/// installers, updaters and developer tools, Time Machine snapshots, simulator runtimes. Playing a
/// sound for those made the app chime "for no reason".
@MainActor
final class FinderSoundEffectsMonitor: ObservableObject {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    /// Standardized paths of mounted, user-visible volumes (captured at mount time, since an
    /// unmounted volume can no longer be asked whether it was visible).
    private var visibleVolumePaths: Set<String> = []
    private var lastSoundDate = Date.distantPast
    /// Mounting a multi-partition disk or reconnecting several shares posts a burst of notifications
    private let minimumSoundInterval: TimeInterval = 1.0

    init(workspace: NSWorkspace = .shared) {
        notificationCenter = workspace.notificationCenter
        visibleVolumePaths = Set(
            (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? [])
                .filter { Self.isUserVisibleVolume($0) }
                .map { $0.standardizedFileURL.path }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Delivered on the main queue.
                MainActor.assumeIsolated {
                    guard let self, let url = Self.volumeURL(from: notification), Self.isUserVisibleVolume(url) else { return }
                    self.visibleVolumePaths.insert(url.standardizedFileURL.path)
                    self.playThrottled(.volumeMount)
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Delivered on the main queue. This is also the eject sound for the sidebar's Eject command:
                // it only fires once the unmount has succeeded.
                MainActor.assumeIsolated {
                    guard let self, let url = Self.volumeURL(from: notification),
                          self.visibleVolumePaths.remove(url.standardizedFileURL.path) != nil else { return }
                    self.playThrottled(.volumeUnmount)
                }
            }
        )
    }

    private func playThrottled(_ effect: FinderSoundEffect) {
        let now = Date()
        guard now.timeIntervalSince(lastSoundDate) >= minimumSoundInterval else { return }
        lastSoundDate = now
        FinderSoundEffects.shared.play(effect)
    }

    nonisolated private static func volumeURL(from notification: Notification) -> URL? {
        if let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            return url
        }
        if let path = notification.userInfo?["NSDevicePath"] as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// A volume Finder would show: browsable (not mounted with nobrowse) and not one of the
    /// system's own internal or Time Machine snapshot mounts.
    nonisolated static func isUserVisibleVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" { return true }
        let hiddenPrefixes = ["/System/Volumes/", "/private/var/", "/Library/Developer/", "/Volumes/com.apple.TimeMachine", "/Volumes/.timemachine"]
        if hiddenPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { return false }
        let values = try? url.resourceValues(forKeys: [.volumeIsBrowsableKey])
        return values?.volumeIsBrowsable ?? false
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}

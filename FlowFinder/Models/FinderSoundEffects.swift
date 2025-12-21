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

final class FinderSoundEffectsMonitor: ObservableObject {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(workspace: NSWorkspace = .shared) {
        notificationCenter = workspace.notificationCenter

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didMountNotification,
                object: nil,
                queue: .main
            ) { _ in
                FinderSoundEffects.shared.play(.volumeMount)
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { _ in
                FinderSoundEffects.shared.play(.volumeUnmount)
            }
        )
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}

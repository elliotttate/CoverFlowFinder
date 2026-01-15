import Foundation
import AppKit
import SwiftUI

/// Represents the iCloud sync status of a file
enum CloudSyncStatus: Equatable, Hashable {
    case local                          // Not in iCloud
    case downloaded                     // Fully downloaded and up-to-date
    case notDownloaded                  // In iCloud but not downloaded locally
    case downloading(progress: Double?) // Currently downloading
    case uploading(progress: Double?)   // Currently uploading
    case waitingForUpload               // Queued for upload
    case hasConflict                    // Has unresolved version conflict
    case error                          // Sync error occurred

    /// SF Symbol name for badge display
    var systemImage: String {
        switch self {
        case .local:
            return ""  // No badge for local files
        case .downloaded:
            return "checkmark.icloud"
        case .notDownloaded:
            return "icloud.and.arrow.down"
        case .downloading:
            return "arrow.down.circle"
        case .uploading:
            return "arrow.up.circle"
        case .waitingForUpload:
            return "clock.arrow.circlepath"
        case .hasConflict:
            return "exclamationmark.icloud"
        case .error:
            return "xmark.icloud"
        }
    }

    /// Color for the badge (NSColor for AppKit compatibility)
    var color: NSColor {
        switch self {
        case .local, .downloaded:
            return .systemGreen
        case .notDownloaded:
            return .systemGray
        case .downloading, .uploading, .waitingForUpload:
            return .systemBlue
        case .hasConflict, .error:
            return .systemOrange
        }
    }

    /// SwiftUI Color for the badge
    var swiftUIColor: Color {
        Color(nsColor: color)
    }

    /// Human-readable description for tooltips
    var description: String {
        switch self {
        case .local:
            return "Local file"
        case .downloaded:
            return "Downloaded"
        case .notDownloaded:
            return "Available in iCloud"
        case .downloading(let progress):
            if let p = progress {
                return "Downloading (\(Int(p * 100))%)"
            }
            return "Downloading..."
        case .uploading(let progress):
            if let p = progress {
                return "Uploading (\(Int(p * 100))%)"
            }
            return "Uploading..."
        case .waitingForUpload:
            return "Waiting to upload"
        case .hasConflict:
            return "Sync conflict"
        case .error:
            return "Sync error"
        }
    }

    /// Whether this item can be downloaded
    var canDownload: Bool {
        self == .notDownloaded
    }

    /// Whether this item can be evicted (removed from local storage)
    var canEvict: Bool {
        self == .downloaded
    }

    /// Whether this item is currently transferring
    var isTransferring: Bool {
        switch self {
        case .downloading, .uploading:
            return true
        default:
            return false
        }
    }

    /// Whether a badge should be shown for this status
    var shouldShowBadge: Bool {
        self != .local && !systemImage.isEmpty
    }

    // Custom Equatable to handle progress values
    static func == (lhs: CloudSyncStatus, rhs: CloudSyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local),
             (.downloaded, .downloaded),
             (.notDownloaded, .notDownloaded),
             (.waitingForUpload, .waitingForUpload),
             (.hasConflict, .hasConflict),
             (.error, .error):
            return true
        case (.downloading(let lhsProgress), .downloading(let rhsProgress)):
            return lhsProgress == rhsProgress
        case (.uploading(let lhsProgress), .uploading(let rhsProgress)):
            return lhsProgress == rhsProgress
        default:
            return false
        }
    }

    // Custom hash to handle progress values
    func hash(into hasher: inout Hasher) {
        switch self {
        case .local:
            hasher.combine(0)
        case .downloaded:
            hasher.combine(1)
        case .notDownloaded:
            hasher.combine(2)
        case .downloading(let progress):
            hasher.combine(3)
            hasher.combine(progress)
        case .uploading(let progress):
            hasher.combine(4)
            hasher.combine(progress)
        case .waitingForUpload:
            hasher.combine(5)
        case .hasConflict:
            hasher.combine(6)
        case .error:
            hasher.combine(7)
        }
    }
}

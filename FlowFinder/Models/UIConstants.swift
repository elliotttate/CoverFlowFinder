import SwiftUI

// MARK: - UI Constants
// Centralized constants for consistent UI styling across the app

enum UI {
    // MARK: - Opacity
    enum Opacity {
        static let selectedItem: Double = 0.2
        static let selectedItemStrong: Double = 0.3
        static let dropTarget: Double = 0.4
        static let cutItem: Double = 0.5
        static let hover: Double = 0.1
        static let activePane: Double = 0.1
        static let activePaneStrong: Double = 0.15
        static let textBackground: Double = 0.5
        static let textBackgroundStrong: Double = 0.6
        static let inactivePane: Double = 0.5
        static let tagBadge: Double = 0.3
        static let labelBackground: Double = 0.9
        static let hitTestMinimum: Double = 0.001
        static let secondary: Double = 0.7
    }

    // MARK: - Corner Radius
    enum CornerRadius {
        static let small: CGFloat = 3
        static let medium: CGFloat = 4
        static let standard: CGFloat = 6
        static let large: CGFloat = 8
        static let extraLarge: CGFloat = 10
        static let tile: CGFloat = 12
    }

    // MARK: - Line Width
    enum LineWidth {
        static let thin: CGFloat = 0.5
        static let standard: CGFloat = 2
        static let thick: CGFloat = 3
        static let extraThick: CGFloat = 5
    }

    // MARK: - Spacing
    enum Spacing {
        static let tiny: CGFloat = 2
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let standard: CGFloat = 8
        static let large: CGFloat = 12
        static let extraLarge: CGFloat = 16
        static let padding: CGFloat = 20
    }

    // MARK: - Animation
    enum Animation {
        static let quickDuration: Double = 0.1
        static let standardDuration: Double = 0.2
        static let slowDuration: Double = 0.3
    }
}

// MARK: - Type Identifiers
enum TypeIdentifiers {
    static let fileURL = "public.file-url"
}

// MARK: - App Notifications
extension Notification.Name {
    static let newTab = Notification.Name("newTab")
    static let closeTab = Notification.Name("closeTab")
    static let nextTab = Notification.Name("nextTab")
    static let previousTab = Notification.Name("previousTab")
    static let showGetInfo = Notification.Name("showGetInfo")
    static let metadataHydrationCompleted = Notification.Name("metadataHydrationCompleted")
    static let cloudStatusHydrationCompleted = Notification.Name("cloudStatusHydrationCompleted")
    static let focusSearch = Notification.Name("focusSearch")
    static let focusFileList = Notification.Name("focusFileList")

    /// A volume is about to be unmounted: posted by the sidebar right before it asks the system to eject one, and
    /// forwarded from `NSWorkspace.willUnmountNotification` for ejects started elsewhere. `object` is nil,
    /// `userInfo[AppNotificationKey.url]` is the volume's root URL. Panes showing that volume should navigate away
    /// (and stop watching it) so the eject isn't refused as "in use". Can arrive more than once per unmount.
    static let volumeWillUnmount = Notification.Name("volumeWillUnmount")
    /// A volume was unmounted (forwarded from `NSWorkspace.didUnmountNotification`). Same payload as `volumeWillUnmount`.
    static let volumeDidUnmount = Notification.Name("volumeDidUnmount")
    /// Something outside the window shell (e.g. the sidebar's Photos Library item) wants a view mode change.
    /// `object` is the `FileBrowserViewModel` it applies to, `userInfo[AppNotificationKey.viewMode]` the `ViewMode`.
    static let requestViewModeChange = Notification.Name("requestViewModeChange")
}

/// `userInfo` keys for the app notifications above.
enum AppNotificationKey {
    static let url = "url"
    static let viewMode = "viewMode"
}

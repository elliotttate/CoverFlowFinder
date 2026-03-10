import AppKit
import UniformTypeIdentifiers

/// Builds "Open With" submenus and handles opening files with specific applications.
/// Used by both AppKit NSMenu-based context menus and SwiftUI context menus.
enum OpenWithMenuBuilder {

    // MARK: - App Discovery

    /// Resolved app info for display in menus
    struct AppInfo {
        let url: URL
        let name: String
        let icon: NSImage
        let isDefault: Bool
    }

    /// Get all compatible apps for file URLs, sorted with default app first then alphabetically.
    /// For multiple files, returns only apps that can open ALL of them.
    static func compatibleApps(for fileURLs: [URL]) -> [AppInfo] {
        guard let firstURL = fileURLs.first else { return [] }

        // Get the default app
        let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: firstURL)

        // Get compatible apps — intersect if multiple files
        let appURLs: [URL]
        if fileURLs.count > 1 {
            var intersection = Set(NSWorkspace.shared.urlsForApplications(toOpen: firstURL))
            for url in fileURLs.dropFirst() {
                intersection.formIntersection(NSWorkspace.shared.urlsForApplications(toOpen: url))
            }
            appURLs = Array(intersection)
        } else {
            appURLs = NSWorkspace.shared.urlsForApplications(toOpen: firstURL)
        }

        // Resolve names and icons
        let resolved = appURLs.compactMap { url -> AppInfo? in
            guard let bundle = Bundle(url: url) else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            let isDefault = (url == defaultAppURL)
            return AppInfo(url: url, name: name, icon: icon, isDefault: isDefault)
        }

        // Deduplicate by name — if multiple versions, append version string
        let nameGroups = Dictionary(grouping: resolved, by: { $0.name })
        let deduped: [AppInfo] = resolved.map { app in
            if let group = nameGroups[app.name], group.count > 1 {
                let version = Bundle(url: app.url)?
                    .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let disambiguatedName = version.isEmpty ? app.name : "\(app.name) (\(version))"
                return AppInfo(url: app.url, name: disambiguatedName, icon: app.icon, isDefault: app.isDefault)
            }
            return app
        }

        // Sort: default first, then alphabetical
        return deduped.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - NSMenu Construction

    /// Build an "Open With" NSMenu submenu for the given file URLs.
    /// The `target` receives the action selectors.
    static func buildNSMenu(for fileURLs: [URL], target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Open With")

        guard !fileURLs.isEmpty else { return menu }

        let apps = compatibleApps(for: fileURLs)

        if apps.isEmpty {
            let noAppsItem = NSMenuItem(title: "No Applications Found", action: nil, keyEquivalent: "")
            noAppsItem.isEnabled = false
            menu.addItem(noAppsItem)
        } else {
            for app in apps {
                let item = NSMenuItem(
                    title: app.name,
                    action: #selector(OpenWithActionTarget.openWithApp(_:)),
                    keyEquivalent: ""
                )
                item.target = target
                item.representedObject = OpenWithAction(appURL: app.url, fileURLs: fileURLs)
                item.image = app.icon

                // Bold the default app
                if app.isDefault {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                    ]
                    item.attributedTitle = NSAttributedString(string: app.name, attributes: attrs)
                }

                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let otherItem = NSMenuItem(
            title: "Other...",
            action: #selector(OpenWithActionTarget.openWithOther(_:)),
            keyEquivalent: ""
        )
        otherItem.target = target
        otherItem.representedObject = fileURLs
        menu.addItem(otherItem)

        return menu
    }

    // MARK: - Open Actions

    /// Open file URLs with a specific application.
    static func openFiles(_ fileURLs: [URL], withAppAt appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = true
        NSWorkspace.shared.open(fileURLs, withApplicationAt: appURL, configuration: config)
    }

    /// Show an NSOpenPanel to choose an application, then open the files with it.
    static func showOpenWithPanel(for fileURLs: [URL], relativeTo window: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Choose an application to open the selected item."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let appURL = panel.url else { return }
            openFiles(fileURLs, withAppAt: appURL)
        }

        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            let response = panel.runModal()
            handler(response)
        }
    }
}

/// Payload attached to each "Open With" menu item via representedObject.
struct OpenWithAction {
    let appURL: URL
    let fileURLs: [URL]
}

/// Protocol for objects that handle Open With menu actions.
/// Both FileTableCoordinator and CoverFlowNSView can conform to this.
@MainActor @objc protocol OpenWithActionTarget: AnyObject {
    @objc func openWithApp(_ sender: NSMenuItem)
    @objc func openWithOther(_ sender: NSMenuItem)
}

// MARK: - SwiftUI "Open With" Submenu

import SwiftUI

/// A SwiftUI Menu that shows all compatible apps for the given file URLs.
/// Used inside SwiftUI .contextMenu { } blocks.
struct OpenWithSubmenu: View {
    let fileURLs: [URL]

    var body: some View {
        Menu("Open With") {
            let apps = OpenWithMenuBuilder.compatibleApps(for: fileURLs)

            if apps.isEmpty {
                Text("No Applications Found")
            }

            ForEach(apps, id: \.url) { app in
                Button {
                    OpenWithMenuBuilder.openFiles(fileURLs, withAppAt: app.url)
                } label: {
                    if app.isDefault {
                        Label {
                            Text(app.name).bold()
                        } icon: {
                            Image(nsImage: app.icon)
                        }
                    } else {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: app.icon)
                        }
                    }
                }
            }

            Divider()

            Button("Other...") {
                OpenWithMenuBuilder.showOpenWithPanel(for: fileURLs)
            }
        }
    }
}

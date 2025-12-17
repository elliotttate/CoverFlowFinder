import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @State private var expandedSections: Set<String> = ["Favorites", "iCloud", "Locations"]

    var body: some View {
        List(selection: Binding(
            get: { viewModel.currentPath },
            set: { if let url = $0 { viewModel.navigateTo(url) } }
        )) {
            // Favorites Section
            Section(isExpanded: Binding(
                get: { expandedSections.contains("Favorites") },
                set: { if $0 { expandedSections.insert("Favorites") } else { expandedSections.remove("Favorites") } }
            )) {
                ForEach(favoriteLocations, id: \.url) { location in
                    SidebarRow(icon: location.icon, title: location.name, url: location.url)
                        .tag(location.url)
                }
            } header: {
                Text("Favorites")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // iCloud Section
            Section(isExpanded: Binding(
                get: { expandedSections.contains("iCloud") },
                set: { if $0 { expandedSections.insert("iCloud") } else { expandedSections.remove("iCloud") } }
            )) {
                if let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents") {
                    SidebarRow(icon: "icloud", title: "iCloud Drive", url: iCloudURL)
                        .tag(iCloudURL)
                } else {
                    SidebarRow(icon: "icloud", title: "iCloud Drive", url: FileManager.default.homeDirectoryForCurrentUser)
                        .disabled(true)
                }
            } header: {
                Text("iCloud")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Locations Section
            Section(isExpanded: Binding(
                get: { expandedSections.contains("Locations") },
                set: { if $0 { expandedSections.insert("Locations") } else { expandedSections.remove("Locations") } }
            )) {
                ForEach(volumeLocations, id: \.url) { location in
                    SidebarRow(icon: location.icon, title: location.name, url: location.url)
                        .tag(location.url)
                }
            } header: {
                Text("Locations")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Tags Section (placeholder)
            Section(isExpanded: .constant(false)) {
                EmptyView()
            } header: {
                Text("Tags")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }

    private var favoriteLocations: [SidebarLocation] {
        var locations: [SidebarLocation] = []
        let fm = FileManager.default

        // AirDrop (placeholder)
        locations.append(SidebarLocation(name: "AirDrop", icon: "antenna.radiowaves.left.and.right", url: fm.homeDirectoryForCurrentUser))

        // Recents
        if let recentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Recents", icon: "clock", url: recentsURL))
        }

        // Applications
        if let appsURL = fm.urls(for: .applicationDirectory, in: .localDomainMask).first {
            locations.append(SidebarLocation(name: "Applications", icon: "square.grid.2x2", url: appsURL))
        }

        // Desktop
        if let desktopURL = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Desktop", icon: "menubar.dock.rectangle", url: desktopURL))
        }

        // Documents
        if let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Documents", icon: "doc", url: docsURL))
        }

        // Downloads
        if let downloadsURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Downloads", icon: "arrow.down.circle", url: downloadsURL))
        }

        // Movies
        if let moviesURL = fm.urls(for: .moviesDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Movies", icon: "film", url: moviesURL))
        }

        // Music
        if let musicURL = fm.urls(for: .musicDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Music", icon: "music.note", url: musicURL))
        }

        // Pictures
        if let picturesURL = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            locations.append(SidebarLocation(name: "Pictures", icon: "photo", url: picturesURL))
        }

        // Home
        locations.append(SidebarLocation(name: NSUserName(), icon: "house", url: fm.homeDirectoryForCurrentUser))

        return locations
    }

    private var volumeLocations: [SidebarLocation] {
        var locations: [SidebarLocation] = []

        // Main disk
        locations.append(SidebarLocation(name: Host.current().localizedName ?? "Macintosh HD", icon: "desktopcomputer", url: URL(fileURLWithPath: "/")))

        // External volumes
        let volumesURL = URL(fileURLWithPath: "/Volumes")
        if let volumes = try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for volume in volumes {
                let name = volume.lastPathComponent
                if name != "Macintosh HD" {
                    locations.append(SidebarLocation(name: name, icon: "externaldrive", url: volume))
                }
            }
        }

        // Network
        locations.append(SidebarLocation(name: "Network", icon: "network", url: URL(fileURLWithPath: "/Network")))

        return locations
    }
}

struct SidebarLocation {
    let name: String
    let icon: String
    let url: URL
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let url: URL

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
        }
        .contentShape(Rectangle())
    }
}

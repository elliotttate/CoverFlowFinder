import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            listTab
                .tabItem {
                    Label("List", systemImage: "list.bullet")
                }

            iconsTab
                .tabItem {
                    Label("Icons", systemImage: "square.grid.2x2")
                }

            masonryTab
                .tabItem {
                    Label("Masonry", systemImage: "square.grid.3x2")
                }

            columnsTab
                .tabItem {
                    Label("Columns", systemImage: "rectangle.split.3x1")
                }

            coverFlowTab
                .tabItem {
                    Label("Cover Flow", systemImage: "square.stack.3d.forward.dottedline")
                }

            sidebarTab
                .tabItem {
                    Label("Sidebar", systemImage: "sidebar.left")
                }

            searchTab
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }

    private var searchTab: some View {
        Form {
            Section("Everything Search") {
                Toggle("Enable Everything Search", isOn: $settings.everythingSearchEnabled)
                    .help("Everything Search indexes your entire filesystem for instant searches. Requires initial indexing time.")

                if settings.everythingSearchEnabled {
                    EverythingSearchStatusView()
                }
            }

            if settings.everythingSearchEnabled {
                Section("Index Management") {
                    Button("Rebuild Index") {
                        SearchIndexManager.shared.rebuildIndex()
                    }
                    .disabled(SearchIndexManager.shared.isIndexing)

                    Button("Clear Index") {
                        SearchIndexManager.shared.clearIndex()
                        settings.everythingSearchEnabled = false
                    }
                }
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section("Visibility") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
                Toggle("Show file extensions", isOn: $settings.showFileExtensions)
                Toggle("Show item tags", isOn: $settings.showItemTags)
                Toggle("Show path bar", isOn: $settings.showPathBar)
                Toggle("Show status bar", isOn: $settings.showStatusBar)
            }

            Section("Sorting") {
                Toggle("Keep folders on top", isOn: $settings.foldersFirst)
                Toggle("Remember column settings per folder", isOn: $settings.usePerFolderColumnState)
                    .help("When enabled, column widths, order, and sort settings are saved per folder (Finder behavior). When disabled, settings are global.")
            }

            Section("Thumbnails") {
                SettingsSliderRow(
                    title: "Thumbnail quality",
                    value: $settings.thumbnailQuality,
                    range: 0.75...1.6,
                    step: 0.05,
                    format: "%.2fx"
                )
            }

            Section("Sound") {
                Toggle("Play sound effects", isOn: $settings.soundEffectsEnabled)
            }

            Section {
                Button("Reset to Defaults") {
                    settings.resetToDefaults()
                }
            }
        }
    }

    private var listTab: some View {
        Form {
            Section("Text") {
                SettingsSliderRow(
                    title: "Font size",
                    value: $settings.listFontSize,
                    range: 10...18,
                    step: 1,
                    format: "%.0f pt"
                )
            }

            Section("Icons") {
                SettingsSliderRow(
                    title: "Icon size",
                    value: $settings.listIconSize,
                    range: 14...32,
                    step: 1,
                    format: "%.0f pt"
                )
            }
        }
    }

    private var iconsTab: some View {
        Form {
            Section("Icons") {
                SettingsSliderRow(
                    title: "Icon size",
                    value: $settings.iconGridIconSize,
                    range: 48...160,
                    step: 4,
                    format: "%.0f pt"
                )
                SettingsSliderRow(
                    title: "Grid spacing",
                    value: $settings.iconGridSpacing,
                    range: 12...40,
                    step: 2,
                    format: "%.0f pt"
                )
            }

            Section("Text") {
                SettingsSliderRow(
                    title: "Label size",
                    value: $settings.iconGridFontSize,
                    range: 9...16,
                    step: 1,
                    format: "%.0f pt"
                )
            }
        }
    }

    private var masonryTab: some View {
        Form {
            Section("Labels") {
                Toggle("Show filenames", isOn: $settings.masonryShowFilenames)
            }
        }
    }

    private var columnsTab: some View {
        Form {
            Section("Layout") {
                SettingsSliderRow(
                    title: "Column width",
                    value: $settings.columnWidth,
                    range: 160...360,
                    step: 10,
                    format: "%.0f pt"
                )
                Toggle("Show preview column", isOn: $settings.columnShowPreview)
                SettingsSliderRow(
                    title: "Preview width",
                    value: $settings.columnPreviewWidth,
                    range: 200...420,
                    step: 10,
                    format: "%.0f pt"
                )
                .disabled(!settings.columnShowPreview)
            }

            Section("Text") {
                SettingsSliderRow(
                    title: "Font size",
                    value: $settings.columnFontSize,
                    range: 10...18,
                    step: 1,
                    format: "%.0f pt"
                )
            }

            Section("Icons") {
                SettingsSliderRow(
                    title: "Icon size",
                    value: $settings.columnIconSize,
                    range: 12...28,
                    step: 1,
                    format: "%.0f pt"
                )
            }
        }
    }

    private var coverFlowTab: some View {
        Form {
            Section("Layout") {
                SettingsSliderRow(
                    title: "Cover scale",
                    value: $settings.coverFlowScale,
                    range: 0.8...2.0,
                    step: 0.05,
                    format: "%.2fx"
                )
                Toggle("Show info panel", isOn: $settings.coverFlowShowInfo)
            }

            Section("Motion") {
                SettingsSliderRow(
                    title: "Swipe speed",
                    value: $settings.coverFlowSwipeSpeed,
                    range: 0.5...2.0,
                    step: 0.05,
                    format: "%.2fx"
                )
            }

            Section("Text") {
                SettingsSliderRow(
                    title: "Title size",
                    value: $settings.coverFlowTitleFontSize,
                    range: 12...22,
                    step: 1,
                    format: "%.0f pt"
                )
            }
        }
    }

    private var sidebarTab: some View {
        Form {
            Section("Sections") {
                Toggle("Favorites", isOn: $settings.sidebarShowFavorites)
                Toggle("iCloud", isOn: $settings.sidebarShowICloud)
                Toggle("Locations", isOn: $settings.sidebarShowLocations)
                Toggle("Tags", isOn: $settings.sidebarShowTags)
            }
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text(String(format: format, value))
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.secondary)
        }
    }
}

struct EverythingSearchStatusView: View {
    @ObservedObject private var indexManager = SearchIndexManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if indexManager.isIndexing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Indexing...")
                        .foregroundColor(.secondary)
                }

                ProgressView(value: indexManager.indexProgress)
                    .progressViewStyle(.linear)

                Text("\(formatNumber(indexManager.indexedFileCount)) files indexed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if indexManager.indexedFileCount > 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Index ready")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("\(formatNumber(indexManager.indexedFileCount)) files")
                    Text("•")
                        .foregroundColor(.secondary)
                    Text("\(formatNumber(indexManager.uniqueNameCount)) unique names")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let lastIndexTime = indexManager.lastIndexTime {
                    Text("Last indexed: \(lastIndexTime, formatter: relativeDateFormatter)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Index not built")
                        .foregroundColor(.secondary)
                }

                Text("Enable to start indexing your filesystem")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private var relativeDateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }
}

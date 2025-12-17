import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = FileBrowserViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        } detail: {
            VStack(spacing: 0) {
                // Path bar
                PathBarView(viewModel: viewModel)

                Divider()

                // Main content area
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredItems.isEmpty {
                    EmptyFolderView()
                } else {
                    switch viewModel.viewMode {
                    case .coverFlow:
                        CoverFlowView(viewModel: viewModel, items: viewModel.filteredItems)
                    case .icons:
                        IconGridView(viewModel: viewModel, items: viewModel.filteredItems)
                    case .list:
                        FileListView(viewModel: viewModel, items: viewModel.filteredItems)
                    case .columns:
                        ColumnView(viewModel: viewModel, items: viewModel.filteredItems)
                    }
                }

                // Status bar
                StatusBarView(viewModel: viewModel)
            }
            .frame(minWidth: 500, minHeight: 400)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Back/Forward buttons
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)
                .help("Back")

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)
                .help("Forward")
            }

            ToolbarItem(placement: .principal) {
                // View mode picker
                Picker("View", selection: $viewModel.viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Change view mode")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Sort menu
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button(action: {
                            if viewModel.sortOption == option {
                                viewModel.sortAscending.toggle()
                            } else {
                                viewModel.sortOption = option
                                viewModel.sortAscending = true
                            }
                        }) {
                            HStack {
                                Text(option.rawValue)
                                if viewModel.sortOption == option {
                                    Image(systemName: viewModel.sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("Sort by")

                // Action menu
                Menu {
                    Button("New Folder") {
                        createNewFolder()
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])

                    Divider()

                    Button("Get Info") {
                        if let selected = viewModel.selectedItems.first {
                            showInfo(for: selected)
                        }
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(viewModel.selectedItems.isEmpty)

                    Divider()

                    Button("Show in Finder") {
                        showInFinder()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Actions")

                // Search field
                TextField("Search", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
        .navigationTitle(viewModel.currentPath.lastPathComponent)
        .focusedSceneValue(\.viewModel, viewModel)
    }

    private func createNewFolder() {
        let newFolderURL = viewModel.currentPath.appendingPathComponent("untitled folder")
        do {
            try FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: false)
            viewModel.refresh()
        } catch {
            // Handle error
        }
    }

    private func showInfo(for item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([viewModel.currentPath])
    }
}

struct PathBarView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(pathComponents.enumerated()), id: \.offset) { index, component in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    navigateToComponent(at: index)
                }) {
                    HStack(spacing: 4) {
                        if index == 0 {
                            Image(systemName: "desktopcomputer")
                                .font(.caption)
                        }
                        Text(component.name)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(index == pathComponents.count - 1 ? .primary : .secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var pathComponents: [(name: String, url: URL)] {
        var components: [(String, URL)] = []
        var url = viewModel.currentPath

        while url.path != "/" {
            components.insert((url.lastPathComponent, url), at: 0)
            url = url.deletingLastPathComponent()
        }
        components.insert(("Macintosh HD", URL(fileURLWithPath: "/")), at: 0)

        return components
    }

    private func navigateToComponent(at index: Int) {
        let url = pathComponents[index].url
        viewModel.navigateTo(url)
    }
}

struct StatusBarView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        HStack {
            Text("\(viewModel.filteredItems.count) items")
                .font(.caption)
                .foregroundColor(.secondary)

            if !viewModel.selectedItems.isEmpty {
                Text("• \(viewModel.selectedItems.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let totalSize = calculateTotalSize() {
                Text(totalSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func calculateTotalSize() -> String? {
        let files = viewModel.filteredItems.filter { !$0.isDirectory }
        guard !files.isEmpty else { return nil }

        let total = files.reduce(0) { $0 + $1.size }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }
}

struct EmptyFolderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("This folder is empty")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// Focus value for keyboard shortcuts
struct ViewModelKey: FocusedValueKey {
    typealias Value = FileBrowserViewModel
}

extension FocusedValues {
    var viewModel: FileBrowserViewModel? {
        get { self[ViewModelKey.self] }
        set { self[ViewModelKey.self] = newValue }
    }
}

#Preview {
    ContentView()
}

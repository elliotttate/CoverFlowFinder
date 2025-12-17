import SwiftUI
import UniformTypeIdentifiers

struct DualPaneView: View {
    @ObservedObject var leftViewModel: FileBrowserViewModel
    @ObservedObject var rightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane

    enum Pane {
        case left, right
    }

    var body: some View {
        HSplitView {
            // Left pane
            PaneView(
                viewModel: leftViewModel,
                otherViewModel: rightViewModel,
                isActive: activePane == .left,
                onActivate: { activePane = .left }
            )

            // Right pane
            PaneView(
                viewModel: rightViewModel,
                otherViewModel: leftViewModel,
                isActive: activePane == .right,
                onActivate: { activePane = .right }
            )
        }
    }
}

struct PaneView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var otherViewModel: FileBrowserViewModel
    let isActive: Bool
    let onActivate: () -> Void
    @State private var paneViewMode: PaneViewMode = .list
    @State private var isDropTargeted = false

    enum PaneViewMode: String, CaseIterable {
        case list = "List"
        case icons = "Icons"

        var systemImage: String {
            switch self {
            case .list: return "list.bullet"
            case .icons: return "square.grid.2x2"
            }
        }
    }

    // Cache path components
    private var pathComponents: [URL] {
        var components: [URL] = []
        var current = viewModel.currentPath

        while current.path != "/" {
            components.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        components.insert(URL(fileURLWithPath: "/"), at: 0)

        return components
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane toolbar
            HStack(spacing: 8) {
                // Back/Forward buttons
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!viewModel.canGoBack)
                .buttonStyle(.borderless)

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!viewModel.canGoForward)
                .buttonStyle(.borderless)

                // Path display
                Text(viewModel.currentPath.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // View mode picker
                Picker("", selection: $paneViewMode) {
                    ForEach(PaneViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 80)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))

            Divider()

            // Path bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(pathComponents, id: \.self) { component in
                        Button(action: {
                            viewModel.navigateTo(component)
                            onActivate()
                        }) {
                            Text(component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)

                        if component != viewModel.currentPath {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))

            Divider()

            // Content with drop support
            Group {
                switch paneViewMode {
                case .list:
                    PaneListView(viewModel: viewModel)
                case .icons:
                    PaneIconView(viewModel: viewModel)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                    .padding(4)
            )

            Divider()

            // Status bar
            HStack {
                Text("\(viewModel.items.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if !viewModel.selectedItems.isEmpty {
                    Text("\(viewModel.selectedItems.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(isActive ? Color.clear : Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture {
            onActivate()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        let destPath = viewModel.currentPath
        let shouldMove = NSEvent.modifierFlags.contains(.option)

        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, error in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                // Skip if dropping onto the same directory
                if sourceURL.deletingLastPathComponent() == destPath {
                    return
                }

                let destURL = destPath.appendingPathComponent(sourceURL.lastPathComponent)

                // Check if we need to make a unique name
                var finalURL = destURL
                var counter = 1
                while FileManager.default.fileExists(atPath: finalURL.path) {
                    let name = sourceURL.deletingPathExtension().lastPathComponent
                    let ext = sourceURL.pathExtension
                    if ext.isEmpty {
                        finalURL = destPath.appendingPathComponent("\(name) \(counter)")
                    } else {
                        finalURL = destPath.appendingPathComponent("\(name) \(counter).\(ext)")
                    }
                    counter += 1
                }

                do {
                    if shouldMove {
                        try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                    } else {
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                    }
                    DispatchQueue.main.async {
                        viewModel.refresh()
                        otherViewModel.refresh()
                    }
                } catch {
                    print("Failed to \(shouldMove ? "move" : "copy") \(sourceURL.lastPathComponent): \(error)")
                }
            }
        }
    }
}

struct PaneListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        List {
            ForEach(viewModel.items) { item in
                let isSelected = viewModel.selectedItems.contains(item)
                HStack(spacing: 8) {
                    Image(nsImage: item.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)

                    Text(item.name)
                        .lineLimit(1)

                    Spacer()

                    Text(item.formattedSize)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)

                    Text(item.formattedDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .trailing)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onDrag {
                    NSItemProvider(object: item.url as NSURL)
                }
                .onTapGesture(count: 2) {
                    viewModel.openItem(item)
                }
                .onTapGesture(count: 1) {
                    viewModel.selectItem(item, extend: NSEvent.modifierFlags.contains(.command))
                }
                .contextMenu {
                    FileItemContextMenu(item: item, viewModel: viewModel) { _ in }
                }
            }
        }
        .listStyle(.plain)
    }
}

struct PaneIconView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(viewModel.items) { item in
                    VStack(spacing: 4) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)

                        Text(item.name)
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 80)
                    }
                    .padding(8)
                    .background(
                        viewModel.selectedItems.contains(item)
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                    .onDrag {
                        NSItemProvider(object: item.url as NSURL)
                    }
                    .onTapGesture(count: 2) {
                        viewModel.openItem(item)
                    }
                    .onTapGesture(count: 1) {
                        viewModel.selectItem(item, extend: NSEvent.modifierFlags.contains(.command))
                    }
                    .contextMenu {
                        FileItemContextMenu(item: item, viewModel: viewModel) { _ in }
                    }
                }
            }
            .padding()
        }
    }
}

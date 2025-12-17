import SwiftUI

struct DualPaneView: View {
    @ObservedObject var leftViewModel: FileBrowserViewModel
    @ObservedObject var rightViewModel: FileBrowserViewModel
    @State private var activePane: Pane = .left

    enum Pane {
        case left, right
    }

    var body: some View {
        HSplitView {
            // Left pane
            PaneView(
                viewModel: leftViewModel,
                isActive: activePane == .left,
                onActivate: { activePane = .left }
            )

            // Right pane
            PaneView(
                viewModel: rightViewModel,
                isActive: activePane == .right,
                onActivate: { activePane = .right }
            )
        }
    }
}

struct PaneView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let isActive: Bool
    let onActivate: () -> Void
    @State private var paneViewMode: PaneViewMode = .list

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
                    ForEach(pathComponents(), id: \.self) { component in
                        Button(action: {
                            navigateToComponent(component)
                        }) {
                            Text(component.lastPathComponent)
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

            // Content
            Group {
                switch paneViewMode {
                case .list:
                    PaneListView(viewModel: viewModel)
                case .icons:
                    PaneIconView(viewModel: viewModel)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onActivate()
            }

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
    }

    private func pathComponents() -> [URL] {
        var components: [URL] = []
        var current = viewModel.currentPath

        while current.path != "/" {
            components.insert(current, at: 0)
            current = current.deletingLastPathComponent()
        }
        components.insert(URL(fileURLWithPath: "/"), at: 0)

        return components
    }

    private func navigateToComponent(_ url: URL) {
        viewModel.navigateTo(url)
        onActivate()
    }
}

struct PaneListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel

    var body: some View {
        List(selection: Binding(
            get: { Set(viewModel.selectedItems.map { $0.id }) },
            set: { ids in
                viewModel.selectedItems = Set(viewModel.items.filter { ids.contains($0.id) })
            }
        )) {
            ForEach(viewModel.items) { item in
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
                .tag(item.id)
                .contentShape(Rectangle())
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
        .listStyle(.inset(alternatesRowBackgrounds: true))
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

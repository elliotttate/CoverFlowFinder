import SwiftUI
import UniformTypeIdentifiers
import Quartz

struct QuadPaneView: View {
    @ObservedObject var topLeftViewModel: FileBrowserViewModel
    @ObservedObject var topRightViewModel: FileBrowserViewModel
    @ObservedObject var bottomLeftViewModel: FileBrowserViewModel
    @ObservedObject var bottomRightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane

    @State private var topLeftViewMode: PaneViewMode = .list
    @State private var topRightViewMode: PaneViewMode = .list
    @State private var bottomLeftViewMode: PaneViewMode = .list
    @State private var bottomRightViewMode: PaneViewMode = .list

    enum Pane {
        case topLeft, topRight, bottomLeft, bottomRight
    }

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

    private var activeViewModel: FileBrowserViewModel {
        switch activePane {
        case .topLeft: return topLeftViewModel
        case .topRight: return topRightViewModel
        case .bottomLeft: return bottomLeftViewModel
        case .bottomRight: return bottomRightViewModel
        }
    }

    private func otherViewModels(for pane: Pane) -> [FileBrowserViewModel] {
        let all = [topLeftViewModel, topRightViewModel, bottomLeftViewModel, bottomRightViewModel]
        let current: FileBrowserViewModel
        switch pane {
        case .topLeft: current = topLeftViewModel
        case .topRight: current = topRightViewModel
        case .bottomLeft: current = bottomLeftViewModel
        case .bottomRight: current = bottomRightViewModel
        }
        return all.filter { $0 !== current }
    }

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                HSplitView {
                    QuadPaneCell(
                        viewModel: topLeftViewModel,
                        otherViewModels: otherViewModels(for: .topLeft),
                        isActive: activePane == .topLeft,
                        paneViewMode: $topLeftViewMode,
                        onActivate: { activePane = .topLeft }
                    )

                    QuadPaneCell(
                        viewModel: topRightViewModel,
                        otherViewModels: otherViewModels(for: .topRight),
                        isActive: activePane == .topRight,
                        paneViewMode: $topRightViewMode,
                        onActivate: { activePane = .topRight }
                    )
                }

                HSplitView {
                    QuadPaneCell(
                        viewModel: bottomLeftViewModel,
                        otherViewModels: otherViewModels(for: .bottomLeft),
                        isActive: activePane == .bottomLeft,
                        paneViewMode: $bottomLeftViewMode,
                        onActivate: { activePane = .bottomLeft }
                    )

                    QuadPaneCell(
                        viewModel: bottomRightViewModel,
                        otherViewModels: otherViewModels(for: .bottomRight),
                        isActive: activePane == .bottomRight,
                        paneViewMode: $bottomRightViewMode,
                        onActivate: { activePane = .bottomRight }
                    )
                }
            }
        }
        .background(QuickLookHost())
        .onAppear {
            if topLeftViewModel.selectedItems.isEmpty && !topLeftViewModel.items.isEmpty {
                topLeftViewModel.selectItem(topLeftViewModel.items[0])
            }
            registerKeyboardHandler()
        }
        .onChange(of: activePane) { _ in
            registerKeyboardHandler()
        }
    }

    private func registerKeyboardHandler() {
        let vm = activeViewModel

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            KeyboardManager.shared.setHandler {
                guard let event = NSApp.currentEvent else { return false }

                switch event.keyCode {
                case 126: // Up arrow
                    navigateInViewModel(vm, by: -1)
                    return true
                case 125: // Down arrow
                    navigateInViewModel(vm, by: 1)
                    return true
                case 123: // Left arrow
                    navigateInViewModel(vm, by: -1)
                    return true
                case 124: // Right arrow
                    navigateInViewModel(vm, by: 1)
                    return true
                case 36: // Return
                    if let item = vm.selectedItems.first {
                        vm.openItem(item)
                    }
                    return true
                case 49: // Space
                    if let selectedItem = vm.selectedItems.first {
                        QuickLookControllerView.shared.togglePreview(for: selectedItem.url) { offset in
                            self.navigateInViewModel(vm, by: offset)
                        }
                    }
                    return true
                default:
                    return false
                }
            }
        }
    }

    private func navigateInViewModel(_ vm: FileBrowserViewModel, by offset: Int) {
        guard !vm.items.isEmpty else { return }

        var currentIndex: Int
        if let selectedItem = vm.selectedItems.first,
           let index = vm.items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(vm.items.count - 1, currentIndex + offset))
        let newItem = vm.items[newIndex]
        vm.selectItem(newItem)
        QuickLookControllerView.shared.updatePreview(for: newItem.url)
    }
}

struct QuadPaneCell: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let otherViewModels: [FileBrowserViewModel]
    let isActive: Bool
    @Binding var paneViewMode: QuadPaneView.PaneViewMode
    let onActivate: () -> Void
    @State private var isDropTargeted = false

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
            HStack(spacing: 6) {
                Button(action: { viewModel.goBack() }) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                }
                .disabled(viewModel.historyIndex <= 0)
                .buttonStyle(.borderless)

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .disabled(viewModel.historyIndex >= viewModel.navigationHistory.count - 1)
                .buttonStyle(.borderless)

                Text(viewModel.currentPath.lastPathComponent)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Picker("", selection: $paneViewMode) {
                    ForEach(QuadPaneView.PaneViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 70)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(pathComponents, id: \.self) { component in
                        Button(action: {
                            viewModel.navigateToAndSelectCurrent(component)
                            onActivate()
                        }) {
                            Text(component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)

                        if component != viewModel.currentPath {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))

            Divider()

            Group {
                switch paneViewMode {
                case .list:
                    QuadPaneListView(viewModel: viewModel, onActivate: onActivate)
                case .icons:
                    QuadPaneIconView(viewModel: viewModel, onActivate: onActivate)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    .padding(2)
            )

            Divider()

            HStack {
                Text("\(viewModel.items.count) items")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                if !viewModel.selectedItems.isEmpty {
                    Text("\(viewModel.selectedItems.count) selected")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(isActive ? Color.clear : Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [sourceURL])
                    for other in otherViewModels {
                        other.refresh()
                    }
                }
            }
        }
    }
}

struct QuadPaneListView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                ForEach(viewModel.items) { item in
                    QuadPaneListRow(item: item, viewModel: viewModel, onActivate: onActivate)
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.selectedItems) { newSelection in
                if let firstSelected = newSelection.first {
                    withAnimation {
                        scrollProxy.scrollTo(firstSelected.id)
                    }
                }
            }
        }
    }
}

struct QuadPaneListRow: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void

    var body: some View {
        let isSelected = viewModel.selectedItems.contains(item)
        HStack(spacing: 6) {
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)

            InlineRenameField(item: item, viewModel: viewModel, font: .caption, alignment: .leading, lineLimit: 1)

            Spacer()

            Text(item.formattedSize)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        .cornerRadius(3)
        .contentShape(Rectangle())
        .id(item.id)
        .draggable(item.url)
        .instantTap(
            id: item.id,
            onSingleClick: {
                handleClick()
            },
            onDoubleClick: {
                viewModel.openItem(item)
            }
        )
        .contextMenu {
            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                viewModel.renamingURL = item.url
            }
        }
    }

    private func handleClick() {
        if let index = viewModel.items.firstIndex(of: item) {
            let modifiers = NSEvent.modifierFlags
            viewModel.handleSelection(
                item: item,
                index: index,
                in: viewModel.items,
                withShift: modifiers.contains(.shift),
                withCommand: modifiers.contains(.command)
            )
        }
        onActivate()
    }
}

struct QuadPaneIconView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void

    @State private var thumbnails: [URL: NSImage] = [:]
    private let thumbnailCache = ThumbnailCacheManager.shared

    private let columns = [
        GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 8)
    ]

    private func loadThumbnail(for item: FileItem) {
        let url = item.url
        guard thumbnails[url] == nil else { return }

        if thumbnailCache.hasFailed(url: url) {
            DispatchQueue.main.async { thumbnails[url] = item.icon }
            return
        }

        if let cached = thumbnailCache.getCachedThumbnail(for: url) {
            DispatchQueue.main.async { thumbnails[url] = cached }
            return
        }

        thumbnailCache.generateThumbnail(for: item) { url, image in
            DispatchQueue.main.async {
                thumbnails[url] = image ?? item.icon
            }
        }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(viewModel.items) { item in
                        QuadPaneIconCell(item: item, viewModel: viewModel, onActivate: onActivate, thumbnail: thumbnails[item.url])
                            .onAppear { loadThumbnail(for: item) }
                    }
                }
                .padding(8)
            }
            .onChange(of: viewModel.selectedItems) { newSelection in
                if let firstSelected = newSelection.first {
                    withAnimation {
                        scrollProxy.scrollTo(firstSelected.id)
                    }
                }
            }
        }
    }
}

struct QuadPaneIconCell: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let thumbnail: NSImage?

    var body: some View {
        let isSelected = viewModel.selectedItems.contains(item)
        VStack(spacing: 2) {
            Image(nsImage: thumbnail ?? item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)

            InlineRenameField(item: item, viewModel: viewModel, font: .caption2, alignment: .center, lineLimit: 2)
                .frame(width: 70, height: 28)
        }
        .frame(width: 70)
        .padding(4)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .id(item.id)
        .draggable(item.url)
        .instantTap(
            id: item.id,
            onSingleClick: {
                handleClick()
            },
            onDoubleClick: {
                viewModel.openItem(item)
            }
        )
        .contextMenu {
            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                viewModel.renamingURL = item.url
            }
        }
    }

    private func handleClick() {
        if let index = viewModel.items.firstIndex(of: item) {
            let modifiers = NSEvent.modifierFlags
            viewModel.handleSelection(
                item: item,
                index: index,
                in: viewModel.items,
                withShift: modifiers.contains(.shift),
                withCommand: modifiers.contains(.command)
            )
        }
        onActivate()
    }
}

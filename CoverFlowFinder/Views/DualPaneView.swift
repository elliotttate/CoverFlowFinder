import SwiftUI
import UniformTypeIdentifiers
import Quartz

struct DualPaneView: View {
    @ObservedObject var leftViewModel: FileBrowserViewModel
    @ObservedObject var rightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane
    @State private var leftPaneViewMode: PaneViewMode = .list
    @State private var rightPaneViewMode: PaneViewMode = .list
    @State private var leftPaneColumns: Int = 4
    @State private var rightPaneColumns: Int = 4

    enum Pane {
        case left, right
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

    // The active viewModel based on current pane
    private var activeViewModel: FileBrowserViewModel {
        activePane == .left ? leftViewModel : rightViewModel
    }

    // Column count for active pane's view mode
    private var activeColumnsCount: Int {
        let mode = activePane == .left ? leftPaneViewMode : rightPaneViewMode
        if mode == .icons {
            return activePane == .left ? leftPaneColumns : rightPaneColumns
        }
        return 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left pane
                PaneView(
                    viewModel: leftViewModel,
                    otherViewModel: rightViewModel,
                    isActive: activePane == .left,
                    paneViewMode: $leftPaneViewMode,
                    onActivate: { activePane = .left },
                    onColumnsCalculated: { cols in leftPaneColumns = cols }
                )

                // Right pane
                PaneView(
                    viewModel: rightViewModel,
                    otherViewModel: leftViewModel,
                    isActive: activePane == .right,
                    paneViewMode: $rightPaneViewMode,
                    onActivate: { activePane = .right },
                    onColumnsCalculated: { cols in rightPaneColumns = cols }
                )
            }
        }
        .background(QuickLookHost())
        .onAppear {
            // Select first item in left pane if nothing selected
            if leftViewModel.selectedItems.isEmpty && !leftViewModel.items.isEmpty {
                leftViewModel.selectItem(leftViewModel.items[0])
            }
            registerKeyboardHandler(forPane: activePane)
        }
        .onChange(of: activePane) { newPane in
            registerKeyboardHandler(forPane: newPane)
        }
        .onChange(of: leftPaneViewMode) { _ in
            registerKeyboardHandler(forPane: activePane)
        }
        .onChange(of: rightPaneViewMode) { _ in
            registerKeyboardHandler(forPane: activePane)
        }
        .onChange(of: leftPaneColumns) { _ in
            if activePane == .left {
                registerKeyboardHandler(forPane: activePane)
            }
        }
        .onChange(of: rightPaneColumns) { _ in
            if activePane == .right {
                registerKeyboardHandler(forPane: activePane)
            }
        }
    }

    private func registerKeyboardHandler(forPane pane: Pane) {
        // Use explicit pane parameter to avoid race conditions
        let leftMode = leftPaneViewMode
        let rightMode = rightPaneViewMode
        let leftVM = leftViewModel
        let rightVM = rightViewModel
        let leftCols = leftPaneColumns
        let rightCols = rightPaneColumns

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            KeyboardManager.shared.setHandler {
                guard let event = NSApp.currentEvent else { return false }

                let vm = pane == .left ? leftVM : rightVM
                let mode = pane == .left ? leftMode : rightMode
                let columnsCount = mode == .icons ? (pane == .left ? leftCols : rightCols) : 1

                switch event.keyCode {
                case 126: // Up arrow
                    navigateInViewModel(vm, by: -columnsCount)
                    return true
                case 125: // Down arrow
                    navigateInViewModel(vm, by: columnsCount)
                    return true
                case 123: // Left arrow
                    if mode == .icons { navigateInViewModel(vm, by: -1) }
                    return true
                case 124: // Right arrow
                    if mode == .icons { navigateInViewModel(vm, by: 1) }
                    return true
                case 36: // Return
                    if let item = vm.selectedItems.first {
                        vm.openItem(item)
                    }
                    return true
                case 49: // Space
                    if let selectedItem = vm.selectedItems.first {
                        let paneViewMode = self.activePane == .left ? self.leftPaneViewMode : self.rightPaneViewMode
                        let columnsCount = self.activePane == .left ? self.leftPaneColumns : self.rightPaneColumns

                        QuickLookControllerView.shared.togglePreview(for: selectedItem.url) { offset in
                            if paneViewMode == .icons {
                                // Grid: left/right = ±1, up/down = ±columns
                                self.navigateInViewModel(vm, by: offset)
                            } else {
                                // List: up/down only
                                self.navigateInViewModel(vm, by: offset)
                            }
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

        let currentIndex: Int
        if let selectedItem = vm.selectedItems.first,
           let index = vm.items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(vm.items.count - 1, currentIndex + offset))
        let newItem = vm.items[newIndex]
        vm.selectItem(newItem)

        // Refresh Quick Look if visible
        QuickLookControllerView.shared.updatePreview(for: newItem.url)
    }

}

struct PaneView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var otherViewModel: FileBrowserViewModel
    let isActive: Bool
    @Binding var paneViewMode: DualPaneView.PaneViewMode
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void
    @State private var isDropTargeted = false

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
                .disabled(viewModel.historyIndex <= 0)
                .buttonStyle(.borderless)

                Button(action: { viewModel.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(viewModel.historyIndex >= viewModel.navigationHistory.count - 1)
                .buttonStyle(.borderless)

                // Path display
                Text(viewModel.currentPath.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // View mode picker
                Picker("", selection: $paneViewMode) {
                    ForEach(DualPaneView.PaneViewMode.allCases, id: \.self) { mode in
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
                            viewModel.navigateToAndSelectCurrent(component)
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
                    PaneListView(viewModel: viewModel, onActivate: onActivate)
                case .icons:
                    PaneIconView(viewModel: viewModel, onActivate: onActivate, onColumnsCalculated: onColumnsCalculated)
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
        .contentShape(Rectangle())
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
    let onActivate: () -> Void

    var body: some View {
        ScrollViewReader { scrollProxy in
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
                    .id(item.id)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                    .contentShape(Rectangle())
                    .onDrag {
                        NSItemProvider(object: item.url as NSURL)
                    }
                    .instantTap(
                        id: item.id,
                        onSingleClick: {
                            onActivate()
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
                        },
                        onDoubleClick: {
                            onActivate()
                            viewModel.openItem(item)
                        }
                    )
                    .contextMenu {
                        FileItemContextMenu(item: item, viewModel: viewModel) { _ in }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
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

struct PaneIconView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 16)
    ]

    private func calculateColumns(width: CGFloat) -> Int {
        // Grid uses adaptive(minimum: 80, maximum: 100) with spacing: 16
        // Plus padding of 16 on each side (from .padding())
        let availableWidth = width - 32 // Subtract padding (16 each side)
        // Each column needs minimum 80px + 16px spacing = 96px
        let cols = Int((availableWidth + 16) / 96)
        return max(1, cols)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
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
                            .id(item.id)
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
                            .instantTap(
                                id: item.id,
                                onSingleClick: {
                                    onActivate()
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
                                },
                                onDoubleClick: {
                                    onActivate()
                                    viewModel.openItem(item)
                                }
                            )
                            .contextMenu {
                                FileItemContextMenu(item: item, viewModel: viewModel) { _ in }
                            }
                        }
                    }
                    .padding()
                }
                .onAppear {
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: geometry.size.width) { newWidth in
                    onColumnsCalculated(calculateColumns(width: newWidth))
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
}

import SwiftUI
import Quartz

struct IconGridView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]
    @State private var renamingItem: FileItem?
    @State private var isDropTargeted = false
    @State private var calculatedColumns: Int = 6

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 20)
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(items) { item in
                            IconGridItem(
                                item: item,
                                isSelected: viewModel.selectedItems.contains(item)
                            )
                            .id(item.id)
                            .onDrag {
                                NSItemProvider(object: item.url as NSURL)
                            }
                            .instantTap(
                                id: item.id,
                                onSingleClick: {
                                    viewModel.selectItem(item, extend: NSEvent.modifierFlags.contains(.command))
                                },
                                onDoubleClick: {
                                    viewModel.openItem(item)
                                }
                            )
                            .contextMenu {
                                FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                    renamingItem = item
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    updateColumnCount(width: geometry.size.width)
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    updateColumnCount(width: newWidth)
                }
                .onChange(of: viewModel.selectedItems) { _, newSelection in
                    if let firstSelected = newSelection.first {
                        withAnimation {
                            scrollProxy.scrollTo(firstSelected.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(QuickLookHost())
        .background(Color(nsColor: .controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(8)
        )
        .contextMenu {
            Button("New Folder") {
                viewModel.createNewFolder()
            }

            if viewModel.canPaste {
                Divider()
                Button("Paste") {
                    viewModel.paste()
                }
            }

            Divider()

            Button("Refresh") {
                viewModel.refresh()
            }

            Button("Show in Finder") {
                viewModel.showInFinder()
            }
        }
        .sheet(item: $renamingItem) { item in
            RenameSheet(item: item, viewModel: viewModel, isPresented: $renamingItem)
        }
        .keyboardNavigable(
            onUpArrow: { navigateSelection(by: -calculatedColumns) },
            onDownArrow: { navigateSelection(by: calculatedColumns) },
            onLeftArrow: { navigateSelection(by: -1) },
            onRightArrow: { navigateSelection(by: 1) },
            onReturn: { openSelectedItem() },
            onSpace: { toggleQuickLook() }
        )
    }

    // Calculate columns based on actual available width
    // Grid uses adaptive(minimum: 100, maximum: 120) with spacing: 20
    private func updateColumnCount(width: CGFloat) {
        let availableWidth = width - 40 // Subtract padding (20 each side)
        // Each column needs minimum 100px + spacing
        // Formula: how many 100px items fit with 20px spacing between them
        // N items need: N * 100 + (N-1) * 20 = N * 120 - 20 pixels
        // So N = (availableWidth + 20) / 120
        let cols = Int((availableWidth + 20) / 120)
        calculatedColumns = max(1, cols)
    }

    private func navigateSelection(by offset: Int) {
        guard !items.isEmpty else { return }

        let currentIndex: Int
        if let selectedItem = viewModel.selectedItems.first,
           let index = items.firstIndex(of: selectedItem) {
            currentIndex = index
        } else {
            currentIndex = -1
        }

        let newIndex = max(0, min(items.count - 1, currentIndex + offset))
        let newItem = items[newIndex]
        viewModel.selectItem(newItem)

        // Refresh Quick Look if visible
        QuickLookControllerView.shared.updatePreview(for: newItem.url)
    }

    private func openSelectedItem() {
        if let selectedItem = viewModel.selectedItems.first {
            viewModel.openItem(selectedItem)
        }
    }

    private func toggleQuickLook() {
        guard let selectedItem = viewModel.selectedItems.first else { return }

        let cols = calculatedColumns
        QuickLookControllerView.shared.togglePreview(for: selectedItem.url) { [self] offset in
            // Map offset for grid: 1/-1 for horizontal, cols/-cols for vertical
            navigateSelection(by: offset)
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

                if sourceURL.deletingLastPathComponent() == destPath {
                    return
                }

                let destURL = destPath.appendingPathComponent(sourceURL.lastPathComponent)

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
                    }
                } catch {
                    print("Failed to \(shouldMove ? "move" : "copy") \(sourceURL.lastPathComponent): \(error)")
                }
            }
        }
    }
}

struct IconGridItem: View {
    let item: FileItem
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Always have the background frame to prevent size changes on selection
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                    .frame(width: 90, height: 90)

                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            }

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 100)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering && !isSelected ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

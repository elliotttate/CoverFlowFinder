import SwiftUI

@MainActor
struct BrowserTab: Identifiable {
    let id: UUID
    let viewModel: FileBrowserViewModel

    init(initialPath: URL? = nil) {
        self.id = UUID()
        if let path = initialPath {
            self.viewModel = FileBrowserViewModel(initialPath: path)
        } else {
            self.viewModel = FileBrowserViewModel()
        }
    }

}

struct TabBarView: View {
    @Binding var tabs: [BrowserTab]
    @Binding var selectedTabId: UUID
    let onNewTab: () -> Void
    let onCloseTab: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        TabItemView(
                            tab: tab,
                            isSelected: tab.id == selectedTabId,
                            canClose: tabs.count > 1,
                            onSelect: { selectedTabId = tab.id },
                            onClose: { onCloseTab(tab.id) }
                        )
                    }
                }
                .padding(.leading, 4)
            }

            // New tab button
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (Cmd+T)")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabItemView: View {
    let tab: BrowserTab
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accentColor : .secondary)

            Text(tab.viewModel.currentPath.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 120)

            if canClose && (isHovering || isSelected) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .opacity(isHovering ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
                .help("Close Tab")
            } else {
                Spacer()
                    .frame(width: 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

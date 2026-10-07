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

/// The tabs of one browser window. Held in a `@StateObject` so the initial tab (and its view model,
/// which starts a directory listing and a folder watcher) is created exactly once per window, not on
/// every `ContentView` initialization.
@MainActor
final class BrowserTabStore: ObservableObject {
    @Published var tabs: [BrowserTab]
    @Published var selectedTabId: UUID

    convenience init() {
        self.init(initialTab: BrowserTab())
    }

    init(initialTab: BrowserTab) {
        tabs = [initialTab]
        selectedTabId = initialTab.id
    }

    var selectedTab: BrowserTab {
        tabs.first(where: { $0.id == selectedTabId }) ?? tabs[0]
    }

    func addTab(_ tab: BrowserTab) {
        tabs.append(tab)
        selectedTabId = tab.id
    }

    /// Removes a tab (never the last one) and selects a neighbour if it was selected.
    /// Returns the removed tab so its view model can be shut down.
    @discardableResult
    func closeTab(_ tabId: UUID) -> BrowserTab? {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let removed = tabs.remove(at: index)
        if selectedTabId == tabId {
            selectedTabId = tabs[min(index, tabs.count - 1)].id
        }
        return removed
    }

    func selectNextTab() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        selectedTabId = tabs[(currentIndex + 1) % tabs.count].id
    }

    func selectPreviousTab() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabId }) else { return }
        selectedTabId = tabs[currentIndex == 0 ? tabs.count - 1 : currentIndex - 1].id
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
    // Observed so the title follows the tab's navigation.
    @ObservedObject private var viewModel: FileBrowserViewModel
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    init(tab: BrowserTab, isSelected: Bool, canClose: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.tab = tab
        self.viewModel = tab.viewModel
        self.isSelected = isSelected
        self.canClose = canClose
        self.onSelect = onSelect
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accentColor : .secondary)

            Text(viewModel.locationTitle)
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

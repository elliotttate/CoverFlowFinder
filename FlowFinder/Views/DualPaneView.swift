import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

struct DualPaneView: View {
    @Environment(\.browserWindow) private var browserWindow
    @ObservedObject var leftViewModel: FileBrowserViewModel
    @ObservedObject var rightViewModel: FileBrowserViewModel
    @Binding var activePane: Pane
    /// Owned by ContentView so the pane modes survive navigation and leaving dual mode.
    @Binding var paneModes: PaneModes
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

    struct PaneModes: Equatable {
        var left: PaneViewMode = .list
        var right: PaneViewMode = .list
    }

    // The active viewModel based on current pane
    private var activeViewModel: FileBrowserViewModel {
        activePane == .left ? leftViewModel : rightViewModel
    }

    private var activeMode: PaneViewMode {
        activePane == .left ? paneModes.left : paneModes.right
    }

    // Column count for active pane's view mode
    private var activeColumnsCount: Int {
        guard activeMode == .icons else { return 1 }
        return max(1, activePane == .left ? leftPaneColumns : rightPaneColumns)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Left pane
                PaneView(
                    viewModel: leftViewModel,
                    otherViewModel: rightViewModel,
                    isActive: activePane == .left,
                    paneViewMode: $paneModes.left,
                    onActivate: { activePane = .left },
                    onColumnsCalculated: { cols in leftPaneColumns = cols }
                )

                // Right pane
                PaneView(
                    viewModel: rightViewModel,
                    otherViewModel: leftViewModel,
                    isActive: activePane == .right,
                    paneViewMode: $paneModes.right,
                    onActivate: { activePane = .right },
                    onColumnsCalculated: { cols in rightPaneColumns = cols }
                )
            }
        }
        .onAppear {
            // Give keyboard navigation a starting point in the active pane only.
            let viewModel = activeViewModel
            if viewModel.selectedItems.isEmpty, let first = viewModel.filteredItems.first {
                viewModel.selectItem(first)
            }
        }
        .background(PaneFocusRequestHandler(activeViewModel: activeViewModel))
        // Same guarded, per-window handling as the single-pane views; keys go to the active pane.
        // The closures read the active pane, its mode and column count when the key is pressed.
        .keyboardNavigable(
            onUpArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: -activeColumnsCount, extend: shift, window: browserWindow?.window) },
            onDownArrow: { shift in PaneKeyboardNavigation.move(activeViewModel, by: activeColumnsCount, extend: shift, window: browserWindow?.window) },
            onLeftArrow: { shift in
                if activeMode == .icons { PaneKeyboardNavigation.move(activeViewModel, by: -1, extend: shift, window: browserWindow?.window) }
            },
            onRightArrow: { shift in
                if activeMode == .icons { PaneKeyboardNavigation.move(activeViewModel, by: 1, extend: shift, window: browserWindow?.window) }
            },
            onReturn: { PaneKeyboardNavigation.openSelection(in: activeViewModel) },
            onSpace: { PaneKeyboardNavigation.toggleQuickLook(in: activeViewModel, window: browserWindow?.window) },
            onDelete: { activeViewModel.deleteSelectedItems() },
            onCopy: { activeViewModel.copySelectedItems() },
            onCut: { activeViewModel.cutSelectedItems() },
            onPaste: { activeViewModel.paste() },
            onTypeAhead: { prefix in PaneKeyboardNavigation.jumpToMatch(prefix, in: activeViewModel, window: browserWindow?.window) }
        )
    }
}

// MARK: - Pane path bar

/// Which components a pane's breadcrumb shows when they don't all fit (Finder-like): the root and
/// the current folder always, then as many of the components just above the current folder as fit;
/// everything in between collapses into one "…" item.
enum BreadcrumbCollapse {
    enum Element: Equatable {
        case component(Int)
        /// Stands for these components (in path order).
        case ellipsis(hidden: [Int])
    }

    /// - Parameters:
    ///   - widths: Each component's natural width, padding included.
    ///   - available: The width the breadcrumb may use.
    ///   - separatorWidth: What a chevron between two items adds, spacing included.
    ///   - ellipsisWidth: The width of the "…" item.
    static func layout(widths: [CGFloat], available: CGFloat, separatorWidth: CGFloat, ellipsisWidth: CGFloat) -> [Element] {
        let count = widths.count
        let all = (0..<count).map(Element.component)
        guard count > 2 else { return all }
        let fullWidth = widths.reduce(0, +) + CGFloat(count - 1) * separatorWidth
        guard fullWidth > available else { return all }

        // Root, "…" and the current folder, then the components above the current folder while they fit.
        var used = widths[0] + ellipsisWidth + widths[count - 1] + 2 * separatorWidth
        var firstTrailing = count - 1
        while firstTrailing - 1 > 1 {
            let extra = widths[firstTrailing - 1] + separatorWidth
            guard used + extra <= available else { break }
            used += extra
            firstTrailing -= 1
        }
        // Hiding a single component no wider than "…" saves nothing.
        if firstTrailing == 2 && widths[1] <= ellipsisWidth {
            return all
        }
        return [.component(0), .ellipsis(hidden: Array(1..<firstTrailing))]
            + (firstTrailing..<count).map(Element.component)
    }
}

/// A dual/quad pane's path bar: a breadcrumb (archive-aware, like the main path bar) that keeps the
/// current folder readable and collapses the middle of long paths into "…", or, after a
/// double-click on its empty part, a field to type a path.
struct PanePathBar: View {
    struct Style {
        let font: NSFont
        let chevronSize: CGFloat
        let itemSpacing: CGFloat
        let itemPadding: CGFloat
        let horizontalPadding: CGFloat
        let height: CGFloat

        /// A truncated component (other than the current folder) stays at least this wide.
        var minimumItemWidth: CGFloat { 44 }

        static let dual = Style(font: .preferredFont(forTextStyle: .caption1), chevronSize: 9, itemSpacing: 4,
                                itemPadding: 6, horizontalPadding: 12, height: 24)
        static let quad = Style(font: .preferredFont(forTextStyle: .caption2), chevronSize: 8, itemSpacing: 2,
                                itemPadding: 4, horizontalPadding: 8, height: 20)
    }

    @ObservedObject var viewModel: FileBrowserViewModel
    let style: Style
    let onActivate: () -> Void

    @State private var isEditingPath = false
    @State private var editPathText = ""
    @FocusState private var isPathFieldFocused: Bool

    var body: some View {
        HStack(spacing: style.itemSpacing) {
            if isEditingPath {
                TextField("Path", text: $editPathText)
                    .textFieldStyle(.plain)
                    .font(Font(style.font))
                    .focused($isPathFieldFocused)
                    .onSubmit { navigateToEditedPath() }
                    .onExitCommand { cancelPathEditing() }
                    .onAppear {
                        editPathText = viewModel.currentPath.path
                        isPathFieldFocused = true
                    }

                Button(action: { navigateToEditedPath() }) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(Font(style.font))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                Button(action: { cancelPathEditing() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font(style.font))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                GeometryReader { geometry in
                    breadcrumbs(availableWidth: geometry.size.width)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                        .clipped()
                }
            }
        }
        .padding(.horizontal, style.horizontalPadding)
        .frame(height: style.height)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func breadcrumbs(availableWidth: CGFloat) -> some View {
        let components = viewModel.pathComponents
        let names = components.map { $0.name.finderDisplayName }
        let widths = names.map { textWidth($0) + 2 * style.itemPadding }
        let layout = BreadcrumbCollapse.layout(
            widths: widths,
            available: availableWidth,
            separatorWidth: ceil(style.chevronSize * 0.6) + 2 * style.itemSpacing,
            ellipsisWidth: textWidth("…") + 2 * style.itemPadding
        )
        let lastIndex = components.count - 1

        return HStack(spacing: style.itemSpacing) {
            ForEach(Array(layout.enumerated()), id: \.offset) { position, element in
                if position > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: style.chevronSize))
                        .foregroundColor(.secondary)
                }
                switch element {
                case .component(let index):
                    componentLabel(names[index], index: index, isCurrent: index == lastIndex, naturalWidth: widths[index])
                case .ellipsis(let hidden):
                    hiddenComponentsMenu(hidden, names: names)
                }
            }

            // The empty part: double-click to type a path
            Rectangle()
                .fill(Color.primary.opacity(0.001))
                .contentShape(Rectangle())
                .frame(minWidth: 0, maxWidth: .infinity)
                .onTapGesture(count: 2) {
                    startPathEditing()
                }
        }
    }

    /// The current folder gets its full width first and only truncates when it can't fit on its
    /// own; the others truncate in the middle down to `minimumItemWidth`.
    private func componentLabel(_ name: String, index: Int, isCurrent: Bool, naturalWidth: CGFloat) -> some View {
        Text(name)
            .font(Font(style.font))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundColor(isCurrent ? .primary : .secondary)
            .padding(.horizontal, style.itemPadding)
            .padding(.vertical, 1)
            .frame(minWidth: isCurrent ? nil : min(naturalWidth, style.minimumItemWidth))
            .layoutPriority(isCurrent ? 2 : 1)
            .contentShape(Rectangle())
            .help(name)
            .onTapGesture {
                navigateToComponent(at: index)
            }
    }

    private func hiddenComponentsMenu(_ hidden: [Int], names: [String]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { index in
                Button(names[index]) {
                    navigateToComponent(at: index)
                }
            }
        } label: {
            Text("…")
                .font(Font(style.font))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, style.itemPadding)
        .layoutPriority(1)
        .help(hidden.map { names[$0] }.joined(separator: " › "))
    }

    private func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: style.font]).width)
    }

    private func navigateToComponent(at index: Int) {
        let components = viewModel.pathComponents
        guard components.indices.contains(index) else { return }
        let component = components[index]
        if let url = component.url {
            // Also leaves an archive, in one history step
            viewModel.navigateToAndSelectCurrent(url)
        } else if let archivePath = component.archivePath {
            viewModel.navigateInArchive(to: archivePath)
        }
        onActivate()
    }

    private func startPathEditing() {
        editPathText = viewModel.currentPath.path
        isEditingPath = true
    }

    private func cancelPathEditing() {
        isEditingPath = false
        isPathFieldFocused = false
    }

    private func navigateToEditedPath() {
        if PathEntryResolver.navigate(viewModel, to: editPathText) {
            cancelPathEditing()
            onActivate()
        } else {
            NSSound.beep()
        }
    }
}

/// A pane's status row: item and selection counts, and a slow copy out of an archive (shown even
/// when the status bar is hidden, like the single-pane status bar).
struct PaneStatusBar: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    var body: some View {
        if appSettings.showStatusBar {
            HStack {
                Text("\(viewModel.filteredItems.count) items")
                    .font(appSettings.compactListDetailFont)
                    .foregroundColor(.secondary)

                Spacer()

                archiveCopyProgress

                if !viewModel.selectedItems.isEmpty {
                    Text("\(viewModel.selectedItems.count) selected")
                        .font(appSettings.compactListDetailFont)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Color(nsColor: .controlBackgroundColor))
        } else if viewModel.archiveCopyProgress != nil {
            HStack {
                Spacer()
                archiveCopyProgress
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private var archiveCopyProgress: some View {
        if let activity = viewModel.archiveCopyProgress {
            ArchiveCopyProgressView(activity: activity) {
                viewModel.cancelArchiveCopy()
            }
        }
    }
}

/// Dual/quad panes have no list view of their own to focus: a `.focusFileList` request (Escape in
/// the search field) naming the active pane's view model, or this window, hands keyboard focus back
/// to the file area, where the window's key handling acts on the active pane. A request naming
/// another pane's view model is ignored.
struct PaneFocusRequestHandler: NSViewRepresentable {
    let activeViewModel: FileBrowserViewModel

    func makeNSView(context: Context) -> PaneFocusRequestView {
        let view = PaneFocusRequestView()
        view.activeViewModel = activeViewModel
        return view
    }

    func updateNSView(_ nsView: PaneFocusRequestView, context: Context) {
        nsView.activeViewModel = activeViewModel
    }
}

final class PaneFocusRequestView: NSView {
    weak var activeViewModel: FileBrowserViewModel?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: .focusFileList, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(handleFocusFileList(_:)), name: .focusFileList, object: nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func handleFocusFileList(_ notification: Notification) {
        guard let window, window.isKeyWindow else { return }
        if let targetWindow = notification.object as? NSWindow, targetWindow !== window { return }
        if let targetViewModel = notification.object as? FileBrowserViewModel, targetViewModel !== activeViewModel { return }
        // The window itself as first responder counts as the file area (see KeyboardResponderKind)
        window.makeFirstResponder(nil)
    }
}

// MARK: - Pane tags

/// Reads the Finder tags of a pane's items off the main thread (the first read of a file's tags
/// hits its extended attributes, slow on network volumes) into `tags`: again when the items, the
/// Show Tags setting or the view model's tags change. Same reader as the icon grid.
struct PaneTagReading: ViewModifier {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    @Binding var tags: [URL: [String]]
    @StateObject private var reader = GridTagReader()

    func body(content: Content) -> some View {
        content
            .onAppear { read() }
            .onDisappear { reader.cancel() }
            .onChange(of: viewModel.filteredItems) { _, _ in read() }
            .onChange(of: appSettings.showItemTags) { _, _ in read() }
            // Tags edited here or elsewhere (the cache entries were dropped): read them again
            .onChange(of: viewModel.tagRefreshToken) { _, _ in read() }
    }

    private func read() {
        guard appSettings.showItemTags else { return }
        reader.read(viewModel.filteredItems) { newTags in
            if newTags != tags {
                tags = newTags
            }
        }
    }
}

extension View {
    /// Keeps `tags` (URL → tags, for the items that have any) current for `viewModel`'s items.
    func paneTagReading(for viewModel: FileBrowserViewModel, into tags: Binding<[URL: [String]]>) -> some View {
        modifier(PaneTagReading(viewModel: viewModel, tags: tags))
    }
}

// MARK: - Dual pane

struct PaneView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject var viewModel: FileBrowserViewModel
    @ObservedObject var otherViewModel: FileBrowserViewModel
    let isActive: Bool
    @Binding var paneViewMode: DualPaneView.PaneViewMode
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void
    @State private var isDropTargeted = false

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

                // Location name (the archive or the folder in it while inside an archive)
                Text(viewModel.locationTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // View mode picker
                Picker("", selection: $paneViewMode) {
                    ForEach(DualPaneView.PaneViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                            .help(mode.rawValue)
                            .accessibilityLabel(mode.rawValue)
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
            if appSettings.showPathBar {
                PanePathBar(viewModel: viewModel, style: .dual, onActivate: onActivate)

                Divider()
            }

            // Content with drop support
            Group {
                switch paneViewMode {
                case .list:
                    PaneListView(viewModel: viewModel, onActivate: onActivate)
                case .icons:
                    PaneIconView(viewModel: viewModel, onActivate: onActivate, onColumnsCalculated: onColumnsCalculated)
                }
            }
            // A delegate (not a perform closure) so the cursor shows move vs. copy correctly and
            // drags from the other pane are accepted while drags within this pane are refused.
            .onDrop(of: DropHelper.acceptedDropTypes, delegate: ContainerDropDelegate(
                viewModel: viewModel,
                isDropTargeted: $isDropTargeted,
                containerHeight: 0,
                items: [],
                autoScroll: false,
                onComplete: { otherViewModel.refresh() }
            ))
            .dropTargetOverlay(isTargeted: isDropTargeted, cornerRadius: UI.CornerRadius.medium)

            Divider()

            // Status bar (an archive copy-out in progress shows even when it's hidden)
            PaneStatusBar(viewModel: viewModel, horizontalPadding: 12, verticalPadding: 4)
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
}

struct PaneListView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.browserWindow) private var browserWindow
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    @State private var dropTargetedItemID: UUID?
    /// Finder tags of the items that have any, read off the main thread
    @State private var tagsByURL: [URL: [String]] = [:]

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredItems) { item in
                        let isSelected = viewModel.selectedItems.contains(item)
                        let isCut = viewModel.isItemCut(item)
                        HStack(spacing: 8) {
                            AsyncListIconView(item: item, size: appSettings.compactListIconSize)
                                .opacity(item.iconOpacity(isCut: isCut))

                            InlineRenameField(item: item, viewModel: viewModel, font: appSettings.compactListFont, alignment: .leading, lineLimit: 1)
                                .opacity(item.nameOpacity(isCut: isCut, isSelected: isSelected))

                            if appSettings.showItemTags, let tags = tagsByURL[item.url] {
                                TagDotsView(tags: tags)
                            }

                            Spacer()

                            Text(item.formattedSize)
                                .font(appSettings.compactListDetailFont)
                                .foregroundColor(.secondary)
                                .frame(width: 60, alignment: .trailing)

                            Text(item.formattedDate)
                                .font(appSettings.compactListDetailFont)
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .trailing)
                        }
                        .id(item.id)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(dropTargetedItemID == item.id
                                    ? Color.accentColor.opacity(0.4)
                                    : (isSelected ? Color.accentColor.opacity(0.3) : Color.clear))
                                .padding(.horizontal, 4)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor, lineWidth: 2)
                                .opacity(dropTargetedItemID == item.id ? 1 : 0)
                                .padding(.horizontal, 4)
                        )
                        .contentShape(Rectangle())
                        .opacity(isCut ? 0.5 : 1.0)
                        .fileDragItem(item)
                        .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
                            item: item,
                            viewModel: viewModel,
                            dropTargetedItemID: $dropTargetedItemID
                        ))
                        .instantTap(
                            id: item.id,
                            onSingleClick: {
                                onActivate()
                                if let index = viewModel.filteredItems.firstIndex(of: item) {
                                    let modifiers = NSEvent.modifierFlags
                                    viewModel.handleSelection(
                                        item: item,
                                        index: index,
                                        in: viewModel.filteredItems,
                                        withShift: modifiers.contains(.shift),
                                        withCommand: modifiers.contains(.command)
                                    )
                                    viewModel.updateQuickLookPreview(for: item, in: browserWindow?.window)
                                }
                            },
                            onDoubleClick: {
                                onActivate()
                                viewModel.openItem(item)
                            }
                        )
                        .contextMenu {
                            FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                viewModel.renamingURL = item.url
                            }
                        }
                    }
                }
                .fileDragContainer(for: viewModel)
            }
            .paneTagReading(for: viewModel, into: $tagsByURL)
            // Every row shows its size (folders' and packages' are calculated)
            .showsItemSizes(.allItems, of: viewModel)
            .onAppear {
                if let lead = viewModel.primarySelectedItem {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollProxy.scrollTo(lead.id, anchor: .center)
                    }
                }
            }
            .onChange(of: viewModel.selectedItems) { _, _ in
                if let lead = viewModel.primarySelectedItem {
                    withAnimation {
                        scrollProxy.scrollTo(lead.id)
                    }
                }
            }
        }
    }
}

/// Per-pane thumbnail bookkeeping for the pane icon views: which cells are on screen and which
/// requests are in flight. Plain reference storage so cell appear/disappear doesn't re-render the
/// grid. Owns the pane's thumbnail requests (cancelled on folder change and when the pane goes away).
final class PaneThumbnailState {
    let owner = ThumbnailRequestOwner()
    var visibleURLs: Set<URL> = []
    /// The request in flight for each URL, by number: the answer to a cancelled request arrives
    /// later and must not clear the mark of a newer request for the same URL.
    private(set) var requestIDs: [URL: Int] = [:]
    private var lastRequestID = 0
    /// What each stored thumbnail was made from (an in-place edit or a download needs a new one)
    var loadedVersions: [URL: GridThumbnailLoader.SourceVersion] = [:]

    func cancelAll() {
        ThumbnailCacheManager.shared.cancelRequests(for: owner)
        requestIDs.removeAll()
        loadedVersions.removeAll()
    }

    /// What a thumbnail of `item` is made from now: its file version once its metadata is loaded
    /// (loading it isn't a change), and whether its contents are on disk (iCloud).
    static func sourceVersion(of item: FileItem) -> GridThumbnailLoader.SourceVersion {
        let file = item.hasMetadata && item.modificationDate != nil ? ThumbnailCacheManager.shared.fileVersion(for: item) : nil
        return GridThumbnailLoader.SourceVersion(file: file, isDownloaded: GridThumbnailLoader.SourceVersion.isDownloaded(item.cloudStatus))
    }

    /// Shared loader for the dual and quad pane icon views. `store` receives the image (or the
    /// item's placeholder when it has no thumbnail) on the main queue. `current` is kept when it's
    /// big enough and wasn't made from an older version of the file (or before it was downloaded).
    func load(_ item: FileItem, maxPixelSize: CGFloat, current: NSImage?, store: @escaping (NSImage, URL) -> Void) {
        let url = item.url
        let version = Self.sourceVersion(of: item)
        if let current, PaneThumbnailState.image(current, satisfies: maxPixelSize),
           loadedVersions[url].map({ !$0.isOutdated(comparedTo: version) }) ?? true {
            return
        }
        let cache = ThumbnailCacheManager.shared
        if let cached = cache.cachedThumbnail(for: item, maxPixelSize: maxPixelSize) {
            DispatchQueue.main.async { [weak self] in
                self?.loadedVersions[url] = version
                store(cached, url)
            }
            return
        }
        guard requestIDs[url] == nil else { return }
        lastRequestID += 1
        let requestID = lastRequestID
        requestIDs[url] = requestID
        cache.requestThumbnail(for: item, maxPixelSize: maxPixelSize, owner: owner) { [weak self] result in
            DispatchQueue.main.async {
                if self?.requestIDs[url] == requestID {
                    self?.requestIDs.removeValue(forKey: url)
                }
                switch result {
                case .loaded(let image):
                    self?.loadedVersions[url] = version
                    store(image, url)
                case .failed:
                    self?.loadedVersions[url] = version
                    store(item.placeholderIcon, url)
                case .cancelled:
                    break
                }
            }
        }
    }

    static func image(_ image: NSImage, satisfies minPixelSize: CGFloat) -> Bool {
        max(image.size.width, image.size.height) >= minPixelSize * 0.9
    }
}

struct PaneIconView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.browserWindow) private var browserWindow
    @ObservedObject var viewModel: FileBrowserViewModel
    let onActivate: () -> Void
    let onColumnsCalculated: (Int) -> Void

    // Display copies of on-screen thumbnails; ThumbnailCacheManager holds the real cache.
    @State private var thumbnails: [URL: NSImage] = [:]
    @State private var thumbnailState = PaneThumbnailState()
    @State private var dropTargetedItemID: UUID?
    /// Finder tags of the items that have any, read off the main thread
    @State private var tagsByURL: [URL: [String]] = [:]
    private static let maxDisplayedThumbnails = 300

    private var cellWidth: CGFloat {
        appSettings.dualPaneIconSize + 32
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: appSettings.dualPaneGridSpacing)]
    }

    private var thumbnailPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let baseTarget = max(192, appSettings.dualPaneIconSize * scale)
        let target = baseTarget * appSettings.thumbnailQualityValue
        let bucket = (target / 64).rounded() * 64
        return min(1024, max(96, bucket))
    }

    private func calculateColumns(width: CGFloat) -> Int {
        let availableWidth = max(0, width - 32)
        let spacing = appSettings.dualPaneGridSpacing
        let columns = Int((availableWidth + spacing) / (cellWidth + spacing))
        return max(1, columns)
    }

    private func loadThumbnail(for item: FileItem) {
        thumbnailState.load(item, maxPixelSize: thumbnailPixelSize, current: thumbnails[item.url]) { image, url in
            storeThumbnail(image, for: url)
        }
    }

    /// Keeps the display dictionary bounded: past the limit only the cells on screen are kept
    /// (the rest come back from ThumbnailCacheManager's memory cache when they reappear).
    private func storeThumbnail(_ image: NSImage, for url: URL) {
        thumbnails[url] = image
        if thumbnails.count > Self.maxDisplayedThumbnails {
            let visible = thumbnailState.visibleURLs
            thumbnails = thumbnails.filter { visible.contains($0.key) }
        }
    }

    private func refreshThumbnails() {
        DispatchQueue.main.async {
            for item in viewModel.filteredItems where thumbnailState.visibleURLs.contains(item.url) {
                loadThumbnail(for: item)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: appSettings.dualPaneGridSpacing) {
                        ForEach(viewModel.filteredItems) { item in
                            let isSelected = viewModel.selectedItems.contains(item)
                            let isCut = viewModel.isItemCut(item)
                            VStack(spacing: 4) {
                                Image(nsImage: thumbnails[item.url] ?? item.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: appSettings.dualPaneIconSize, height: appSettings.dualPaneIconSize)
                                    .opacity(item.iconOpacity(isCut: isCut))

                                InlineRenameField(item: item, viewModel: viewModel, font: appSettings.dualPaneFont, alignment: .center, lineLimit: 2)
                                    .opacity(item.nameOpacity(isCut: isCut, isSelected: isSelected))
                                    .frame(width: cellWidth - 16)

                                if appSettings.showItemTags, let tags = tagsByURL[item.url] {
                                    TagDotsView(tags: tags)
                                }
                            }
                            .id(item.id)
                            .onAppear {
                                thumbnailState.visibleURLs.insert(item.url)
                                loadThumbnail(for: item)
                            }
                            .onDisappear {
                                thumbnailState.visibleURLs.remove(item.url)
                            }
                            .padding(8)
                            .background(
                                dropTargetedItemID == item.id
                                    ? Color.accentColor.opacity(0.4)
                                    : (isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 3)
                                    .opacity(dropTargetedItemID == item.id ? 1 : 0)
                            )
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .opacity(isCut ? 0.5 : 1.0)
                            .fileDragItem(item)
                            .onDrop(of: DropHelper.acceptedDropTypes, delegate: UnifiedFolderDropDelegate(
                                item: item,
                                viewModel: viewModel,
                                dropTargetedItemID: $dropTargetedItemID
                            ))
                            .instantTap(
                                id: item.id,
                                onSingleClick: {
                                    onActivate()
                                    if let index = viewModel.filteredItems.firstIndex(of: item) {
                                        let modifiers = NSEvent.modifierFlags
                                        viewModel.handleSelection(
                                            item: item,
                                            index: index,
                                            in: viewModel.filteredItems,
                                            withShift: modifiers.contains(.shift),
                                            withCommand: modifiers.contains(.command)
                                        )
                                        viewModel.updateQuickLookPreview(for: item, in: browserWindow?.window)
                                    }
                                },
                                onDoubleClick: {
                                    onActivate()
                                    viewModel.openItem(item)
                                }
                            )
                            .contextMenu {
                                FileItemContextMenu(item: item, viewModel: viewModel) { item in
                                    viewModel.renamingURL = item.url
                                }
                            }
                        }
                    }
                    .fileDragContainer(for: viewModel)
                    .padding()
                }
                .paneTagReading(for: viewModel, into: $tagsByURL)
                .onAppear {
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                    // Scroll to selected item when view appears (e.g., when switching view modes)
                    if let lead = viewModel.primarySelectedItem {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollProxy.scrollTo(lead.id, anchor: .center)
                        }
                    }
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    onColumnsCalculated(calculateColumns(width: newWidth))
                }
                .onChange(of: appSettings.iconGridIconSize) { _, _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                    refreshThumbnails()
                }
                .onChange(of: appSettings.iconGridSpacing) { _, _ in
                    onColumnsCalculated(calculateColumns(width: geometry.size.width))
                }
                .onChange(of: appSettings.thumbnailQuality) { _, _ in
                    refreshThumbnails()
                }
                // Edited in place: reload the thumbnails of changed files
                .onChange(of: viewModel.filteredItems.map(\.contentVersion)) { _, _ in
                    refreshThumbnails()
                }
                .onChange(of: viewModel.currentPath) { _, _ in
                    // A new folder: cancel this pane's requests and drop its thumbnails.
                    thumbnailState.cancelAll()
                    thumbnails.removeAll()
                }
                .onChange(of: viewModel.selectedItems) { _, _ in
                    if let lead = viewModel.primarySelectedItem {
                        withAnimation {
                            scrollProxy.scrollTo(lead.id)
                        }
                    }
                }
                .onDisappear {
                    thumbnailState.cancelAll()
                }
            }
        }
    }
}

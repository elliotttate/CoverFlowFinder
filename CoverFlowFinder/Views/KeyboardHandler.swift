import SwiftUI
import Quartz

// Global keyboard manager - singleton with single event monitor
class KeyboardManager {
    static let shared = KeyboardManager()

    private var eventMonitor: Any?
    private var activeHandler: (() -> Bool)?

    private init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  let window = NSApp.keyWindow,
                  window.isKeyWindow,
                  let handler = self.activeHandler else {
                return event
            }

            if handler() {
                return nil // Consume event
            }
            return event
        }
    }

    func setHandler(_ handler: @escaping () -> Bool) {
        activeHandler = handler
    }

    func clearHandler() {
        activeHandler = nil
    }
}

// View modifier for keyboard handling - doesn't wrap the view
struct KeyboardNavigable: ViewModifier {
    let isActive: Bool
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    let onReturn: () -> Void
    let onSpace: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isActive {
                    // Delay registration to ensure window is ready
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        registerHandler()
                    }
                }
            }
            .onChange(of: isActive) { newValue in
                if newValue {
                    registerHandler()
                }
            }
        // No .onDisappear clear - new view's handler will overwrite
    }

    private func registerHandler() {
        KeyboardManager.shared.setHandler { [onUpArrow, onDownArrow, onLeftArrow, onRightArrow, onReturn, onSpace] in
            guard let event = NSApp.currentEvent else { return false }

            switch event.keyCode {
            case 126: // Up arrow
                onUpArrow()
                return true
            case 125: // Down arrow
                onDownArrow()
                return true
            case 123: // Left arrow
                onLeftArrow()
                return true
            case 124: // Right arrow
                onRightArrow()
                return true
            case 36: // Return
                onReturn()
                return true
            case 49: // Space
                onSpace()
                return true
            default:
                return false
            }
        }
    }
}

extension View {
    func keyboardNavigable(
        isActive: Bool = true,
        onUpArrow: @escaping () -> Void = {},
        onDownArrow: @escaping () -> Void = {},
        onLeftArrow: @escaping () -> Void = {},
        onRightArrow: @escaping () -> Void = {},
        onReturn: @escaping () -> Void = {},
        onSpace: @escaping () -> Void = {}
    ) -> some View {
        modifier(KeyboardNavigable(
            isActive: isActive,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onReturn: onReturn,
            onSpace: onSpace
        ))
    }
}

// MARK: - Instant Click Handler
// Provides instant single-click with time-based double-click detection
// This avoids SwiftUI's ~300ms delay when both single and double tap gestures are present

class ClickState: ObservableObject {
    var lastClickTime: Date?
    var lastClickId: AnyHashable?
}

struct InstantTapModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    @StateObject private var clickState = ClickState()
    private let doubleClickThreshold: TimeInterval = 0.3

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                let now = Date()

                // Check if this is a double-click
                if let lastTime = clickState.lastClickTime,
                   let lastId = clickState.lastClickId,
                   lastId == AnyHashable(id),
                   now.timeIntervalSince(lastTime) < doubleClickThreshold {
                    // Double-click detected
                    clickState.lastClickTime = nil
                    clickState.lastClickId = nil
                    onDoubleClick()
                } else {
                    // Single click - fire immediately
                    clickState.lastClickTime = now
                    clickState.lastClickId = AnyHashable(id)
                    onSingleClick()
                }
            }
    }
}

extension View {
    /// Instant tap gesture that fires single-click immediately and detects double-click via timing.
    /// This avoids SwiftUI's gesture disambiguation delay.
    func instantTap<ID: Hashable>(
        id: ID,
        onSingleClick: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void
    ) -> some View {
        modifier(InstantTapModifier(
            id: id,
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick
        ))
    }
}

struct InlineRenameField: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let font: Font
    let alignment: TextAlignment
    let lineLimit: Int

    @State private var editText: String = ""
    @FocusState private var isFocused: Bool
    @State private var hasCommitted: Bool = false
    @State private var clickMonitor: Any?

    init(item: FileItem, viewModel: FileBrowserViewModel, font: Font = .body, alignment: TextAlignment = .leading, lineLimit: Int = 1) {
        self.item = item
        self.viewModel = viewModel
        self.font = font
        self.alignment = alignment
        self.lineLimit = lineLimit
    }

    var body: some View {
        if viewModel.renamingURL == item.url {
            TextField("", text: $editText)
                .textFieldStyle(.plain)
                .font(font)
                .multilineTextAlignment(alignment)
                .focused($isFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .onAppear {
                    hasCommitted = false
                    editText = item.nameWithoutExtension
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isFocused = true
                        selectAllText()
                        setupClickMonitor()
                    }
                }
                .onDisappear {
                    removeClickMonitor()
                    if !hasCommitted {
                        commitRename()
                    }
                }
                .onChange(of: isFocused) { focused in
                    if !focused && !hasCommitted {
                        commitRename()
                    }
                }
        } else {
            Text(item.name)
                .font(font)
                .lineLimit(lineLimit)
                .multilineTextAlignment(alignment)
        }
    }

    private func setupClickMonitor() {
        // Monitor for clicks outside the text field to commit rename
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Check if click is outside our text field by checking if the first responder changed
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow,
                   let firstResponder = window.firstResponder,
                   !(firstResponder is NSTextView) {
                    // Click was outside text field
                    if !hasCommitted {
                        commitRename()
                    }
                }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func commitRename() {
        guard !hasCommitted else { return }
        hasCommitted = true
        removeClickMonitor()

        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != item.nameWithoutExtension {
            let ext = item.url.pathExtension
            let newName = ext.isEmpty ? trimmed : "\(trimmed).\(ext)"
            viewModel.renameItem(item, to: newName)
        }
        viewModel.renamingURL = nil
    }

    private func cancelRename() {
        hasCommitted = true
        removeClickMonitor()
        viewModel.renamingURL = nil
    }

    private func selectAllText() {
        if let window = NSApp.keyWindow,
           let fieldEditor = window.fieldEditor(false, for: nil) as? NSTextView {
            fieldEditor.selectAll(nil)
        }
    }
}

extension FileItem {
    var nameWithoutExtension: String {
        if isDirectory { return name }
        let ext = url.pathExtension
        if ext.isEmpty { return name }
        return String(name.dropLast(ext.count + 1))
    }
}

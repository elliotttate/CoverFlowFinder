import SwiftUI
import AppKit
import Quartz

// Global keyboard manager - singleton with single event monitor
class KeyboardManager {
    static let shared = KeyboardManager()

    private var eventMonitor: Any?
    private var activeHandler: (() -> Bool)?

    // Type-ahead state (shared across views)
    var typeAheadBuffer: String = ""
    var typeAheadTimer: Timer?
    let typeAheadTimeout: TimeInterval = 1.0

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

    func appendTypeAhead(_ char: Character) {
        typeAheadBuffer.append(char)
        resetTypeAheadTimer()
    }

    func clearTypeAhead() {
        typeAheadBuffer = ""
        typeAheadTimer?.invalidate()
        typeAheadTimer = nil
    }

    private func resetTypeAheadTimer() {
        typeAheadTimer?.invalidate()
        typeAheadTimer = Timer.scheduledTimer(withTimeInterval: typeAheadTimeout, repeats: false) { [weak self] _ in
            self?.typeAheadBuffer = ""
        }
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
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onCut: () -> Void
    let onPaste: () -> Void
    let onTypeAhead: ((String) -> Void)?

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
        KeyboardManager.shared.setHandler { [onUpArrow, onDownArrow, onLeftArrow, onRightArrow, onReturn, onSpace, onDelete, onCopy, onCut, onPaste, onTypeAhead] in
            guard let event = NSApp.currentEvent else { return false }
            let modifiers = event.modifierFlags

            // Don't intercept if command key is held (except for specific shortcuts)
            let hasCommand = modifiers.contains(.command)

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
            case 53: // Escape - clear type-ahead
                KeyboardManager.shared.clearTypeAhead()
                return true
            case 51: // Backspace/Delete
                if hasCommand {
                    onDelete()
                    return true
                }
                return false
            case 8: // C key
                if hasCommand && !modifiers.contains(.shift) {
                    onCopy()
                    return true
                }
                // Fall through to type-ahead
            case 7: // X key
                if hasCommand && !modifiers.contains(.shift) {
                    onCut()
                    return true
                }
                // Fall through to type-ahead
            case 9: // V key
                if hasCommand && !modifiers.contains(.shift) {
                    onPaste()
                    return true
                }
                // Fall through to type-ahead
            default:
                break
            }

            // Type-ahead: handle printable characters without modifiers
            if let typeAhead = onTypeAhead,
               !hasCommand,
               !modifiers.contains(.control),
               let characters = event.characters,
               !characters.isEmpty {
                let char = characters.first!
                if char.isLetter || char.isNumber || char == " " || char == "." || char == "-" || char == "_" {
                    KeyboardManager.shared.appendTypeAhead(char)
                    typeAhead(KeyboardManager.shared.typeAheadBuffer)
                    return true
                }
            }

            return false
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
        onSpace: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {},
        onCut: @escaping () -> Void = {},
        onPaste: @escaping () -> Void = {},
        onTypeAhead: ((String) -> Void)? = nil
    ) -> some View {
        modifier(KeyboardNavigable(
            isActive: isActive,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onReturn: onReturn,
            onSpace: onSpace,
            onDelete: onDelete,
            onCopy: onCopy,
            onCut: onCut,
            onPaste: onPaste,
            onTypeAhead: onTypeAhead
        ))
    }
}

// MARK: - Unified Folder Drop Delegate

/// A unified drop delegate for folder targeting that can be used across all views.
/// This replaces the duplicated IconFolderDropDelegate, FolderDropDelegate,
/// ColumnFolderDropDelegate, DualPaneFolderDropDelegate, and QuadPaneFolderDropDelegate.
struct UnifiedFolderDropDelegate: DropDelegate {
    let item: FileItem
    let viewModel: FileBrowserViewModel
    @Binding var dropTargetedItemID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        return item.isDirectory && !item.isFromArchive && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        if item.isDirectory {
            dropTargetedItemID = item.id
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetedItemID == item.id {
            dropTargetedItemID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard item.isDirectory && !item.isFromArchive else { return DropProposal(operation: .forbidden) }
        let operation: DropOperation = NSEvent.modifierFlags.contains(.option) ? .copy : .move
        return DropProposal(operation: operation)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard item.isDirectory && !item.isFromArchive else { return false }

        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.handleDrop(urls: [url], to: item.url)
                }
            }
        }
        return true
    }
}

// MARK: - QuickLook Helper Extension

extension FileBrowserViewModel {
    /// Updates QuickLook preview for the given item, or clears it if nil
    func updateQuickLookPreview(for item: FileItem?) {
        guard let item else {
            QuickLookControllerView.shared.updatePreview(for: nil)
            return
        }

        // Use async version to avoid blocking during archive extraction
        previewURL(for: item) { previewURL in
            if let previewURL = previewURL {
                QuickLookControllerView.shared.updatePreview(for: previewURL)
            } else {
                QuickLookControllerView.shared.updatePreview(for: nil)
            }
        }
    }

    /// Toggles QuickLook for the selected item with navigation callback
    func toggleQuickLookForSelection(onNavigate: @escaping (Int) -> Void) {
        guard let selectedItem = selectedItems.first else { return }

        // Use async version to avoid blocking during archive extraction
        previewURL(for: selectedItem) { previewURL in
            guard let previewURL = previewURL else {
                NSSound.beep()
                return
            }
            QuickLookControllerView.shared.togglePreview(for: previewURL, navigate: onNavigate)
        }
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
    private let doubleClickThreshold: TimeInterval = NSEvent.doubleClickInterval

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
    @EnvironmentObject private var settings: AppSettings
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
            Text(item.displayName(showFileExtensions: settings.showFileExtensions))
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

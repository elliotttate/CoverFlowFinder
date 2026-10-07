import SwiftUI
import AppKit
import Combine
import Quartz

// MARK: - Keyboard Routing (pure decision logic)

/// What has keyboard focus in a window, as far as file-area key handling is concerned.
enum KeyboardResponderKind: Equatable {
    /// The window itself, the SwiftUI hosting view, the file table, or another non-control view in the file area.
    case fileArea
    /// A text view or field editor: rename, search, path and Go to Folder fields, any text field.
    case textEditing
    /// The sidebar's outline view.
    case sidebar
    /// Any other control (button, segmented control, slider, ...).
    case otherControl

    @MainActor
    static func classify(_ responder: NSResponder?) -> KeyboardResponderKind {
        guard let responder else { return .fileArea }
        if responder is NSText { return .textEditing }
        if responder is NSOutlineView { return .sidebar }
        if responder is NSTableView { return .fileArea }
        if responder is NSControl { return .otherControl }
        return .fileArea
    }

    /// Clicking SwiftUI content doesn't take first responder, so the sidebar (or a focused control)
    /// can stay first responder after the user moved on to the file area, or be first responder
    /// right after launch. It only keeps the keys while the user is actually working in it: the
    /// last click in the window landed on it, or Tab moved focus to it.
    func resolved(isFocusEngaged: Bool) -> KeyboardResponderKind {
        switch self {
        case .sidebar, .otherControl:
            return isFocusEngaged ? self : .fileArea
        case .fileArea, .textEditing:
            return self
        }
    }

    /// Where a mouse-down landed, as far as keyboard focus is concerned.
    enum ClickTarget: Equatable {
        /// The sidebar's outline view: it keeps the keys.
        case sidebar
        /// The file list's table (AppKit makes it first responder itself).
        case fileTable
        /// SwiftUI file views, Cover Flow, empty space: the file area takes the keys back.
        case fileContent
        /// A text view or field editor.
        case text
        /// A button, picker, scroll bar or other control. Clicking one leaves keyboard focus where
        /// it was (Finder's toolbar buttons, view picker and scroll bars never take it).
        case control
        /// Outside the window's content view: title bar and toolbar.
        case windowChrome
    }

    @MainActor
    static func clickTarget(of view: NSView, contentView: NSView?) -> ClickTarget {
        var ancestors: [NSView] = []
        var current: NSView? = view
        while let candidate = current {
            ancestors.append(candidate)
            current = candidate.superview
        }
        // Inside a table: the sidebar or the file list (their cells contain controls). A table's
        // scroll bars are outside it, so they count as controls.
        for candidate in ancestors {
            if candidate is NSOutlineView { return .sidebar }
            if candidate is NSTableView { return .fileTable }
        }
        if ancestors.contains(where: { $0 is NSText }) { return .text }
        if let contentView, !ancestors.contains(where: { $0 === contentView }) { return .windowChrome }
        if ancestors.contains(where: { $0 is NSControl }) { return .control }
        return .fileContent
    }

    /// Whether a control that took first responder when clicked (Full Keyboard Access, a slider)
    /// keeps the keys. Buttons, pickers and scroll bars never do.
    @MainActor
    static func controlKeepsKeysWhenFocused(_ control: NSControl) -> Bool {
        !(control is NSButton || control is NSSegmentedControl || control is NSScroller)
    }
}

/// A key press the file area acts on.
enum FileAreaKeyCommand: Equatable {
    case moveUp(extend: Bool)
    case moveDown(extend: Bool)
    case moveLeft(extend: Bool)
    case moveRight(extend: Bool)
    case open
    case quickLook
    case typeAhead(Character)
    case cancelTypeAhead
    case closeQuickLook
}

/// Everything the routing decision depends on, captured from a key event and its window.
struct KeyRoutingContext {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags
    var characters: String?
    var isBrowserWindow: Bool
    var hasAttachedSheet: Bool
    var isModalSessionActive: Bool
    var responder: KeyboardResponderKind
    var isTypeAheadActive: Bool
    var isQuickLookVisible: Bool = false
}

enum KeyboardRouting {
    enum KeyCode {
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    /// Decides whether a key press is handled by the file area (non-nil) or passed on (nil) to the
    /// menus, the focused control or the system.
    ///
    /// ⌘-shortcuts are never taken here: the menus own them (Copy/Paste/Move to Trash, ⌘↑ Enclosing
    /// Folder, ⌘Q, ...), except ⌘↓ (Open), which has no menu item. Matching never uses the physical
    /// key code of a letter, so other keyboard layouts (Dvorak, AZERTY) behave.
    static func command(for context: KeyRoutingContext) -> FileAreaKeyCommand? {
        guard context.isBrowserWindow,
              !context.hasAttachedSheet,
              !context.isModalSessionActive else {
            return nil
        }

        let flags = context.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        // Escape closes an open Quick Look panel (Finder) wherever the browser window's focus is,
        // except in a text field, whose own Escape (cancel rename, clear search) comes first. When
        // the panel itself is key the event isn't from a browser window and the panel handles it.
        if context.keyCode == KeyCode.escape, context.isQuickLookVisible,
           context.responder != .textEditing, !command, !option, !control, !shift {
            return .closeQuickLook
        }

        guard context.responder == .fileArea else { return nil }

        switch context.keyCode {
        case KeyCode.upArrow, KeyCode.downArrow, KeyCode.leftArrow, KeyCode.rightArrow:
            if command {
                if context.keyCode == KeyCode.downArrow && !option && !control && !shift {
                    return .open
                }
                return nil
            }
            if option || control { return nil }
            switch context.keyCode {
            case KeyCode.upArrow: return .moveUp(extend: shift)
            case KeyCode.downArrow: return .moveDown(extend: shift)
            case KeyCode.leftArrow: return .moveLeft(extend: shift)
            default: return .moveRight(extend: shift)
            }
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return (command || option || control || shift) ? nil : .open
        case KeyCode.space:
            if command || option || control { return nil }
            // A space typed while a type-ahead is in progress continues the name ("My Doc").
            return context.isTypeAheadActive ? .typeAhead(" ") : .quickLook
        case KeyCode.escape:
            // Only swallow Escape when it has something to cancel; otherwise sheets, Quick Look
            // and .onExitCommand handlers must see it.
            return (context.isTypeAheadActive && !command && !option && !control) ? .cancelTypeAhead : nil
        default:
            break
        }

        if command || control { return nil }

        guard let characters = context.characters,
              characters.count == 1,
              let char = characters.first else {
            return nil
        }
        if char.isLetter || char.isNumber || char == "." || char == "-" || char == "_" {
            return .typeAhead(char)
        }
        return nil
    }
}

// MARK: - Edit / Go Menu Routing

/// Menu commands whose key equivalents collide with text editing.
enum EditCommand: Equatable {
    case copy
    case cut
    case paste
    case selectAll
    case duplicate
    case moveToTrash
    case deleteImmediately
    case enclosingFolder
}

enum EditCommandRoute: Equatable {
    /// Send this standard action up the responder chain (text field, Settings, sheet, ...).
    case forward(Selector)
    /// Perform the file operation on the active browser pane.
    case files
    /// Do nothing.
    case ignore
}

enum EditCommandRouting {
    /// Menu key equivalents fire before the field editor sees the key, so a replaced Edit menu must
    /// hand text-editing shortcuts back to the text view (⌘C/⌘V in the rename field, ⌘⌫ = delete to
    /// the start of the line, ⌘↑ = move to the beginning) and must behave like the standard Edit menu
    /// in windows that aren't file browsers (Settings, Get Info sheet, update window, alerts).
    static func route(_ command: EditCommand,
                      isBrowserWindow: Bool,
                      responder: KeyboardResponderKind,
                      isKeyEquivalent: Bool) -> EditCommandRoute {
        if responder == .textEditing {
            switch command {
            case .copy, .cut, .paste, .selectAll:
                return .forward(standardSelector(for: command)!)
            case .moveToTrash:
                return isKeyEquivalent ? .forward(#selector(NSResponder.deleteToBeginningOfLine(_:))) : .ignore
            case .enclosingFolder:
                return isKeyEquivalent ? .forward(#selector(NSResponder.moveToBeginningOfDocument(_:))) : .files
            case .duplicate, .deleteImmediately:
                return .ignore
            }
        }

        guard isBrowserWindow else {
            if let selector = standardSelector(for: command) {
                return .forward(selector)
            }
            return .ignore
        }
        return .files
    }

    static func standardSelector(for command: EditCommand) -> Selector? {
        switch command {
        case .copy: return #selector(NSText.copy(_:))
        case .cut: return #selector(NSText.cut(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        case .duplicate, .moveToTrash, .deleteImmediately, .enclosingFolder: return nil
        }
    }
}

// MARK: - Keyboard Handlers

/// The actions a file view performs for keys routed to it, and for the Edit menu's file commands.
struct KeyboardHandlers {
    var onUpArrow: (_ shift: Bool) -> Void = { _ in }
    var onDownArrow: (_ shift: Bool) -> Void = { _ in }
    var onLeftArrow: (_ shift: Bool) -> Void = { _ in }
    var onRightArrow: (_ shift: Bool) -> Void = { _ in }
    var onReturn: () -> Void = {}
    var onSpace: () -> Void = {}
    var onDelete: () -> Void = {}
    var onCopy: () -> Void = {}
    var onCut: () -> Void = {}
    var onPaste: () -> Void = {}
    var onTypeAhead: ((String) -> Void)?
}

/// Something that owns keyboard handlers inside a specific window (the probe view of `keyboardNavigable`).
@MainActor
protocol KeyboardHandlerHost: AnyObject {
    var keyboardHostWindow: NSWindow? { get }
    var isKeyboardHandlerActive: Bool { get }
    var keyboardHandlers: KeyboardHandlers { get }
}

// MARK: - Keyboard Manager

/// Routes key presses to the file view of the window they were typed in.
///
/// Handlers are registered per window by the views that use `keyboardNavigable` and are held weakly,
/// so a closed tab or a view that left the window never receives keys. A key is only dispatched when
/// it was typed in a browser window without a sheet, nothing modal is running, and the first
/// responder is the file area (not a text field, the sidebar or another control).
@MainActor
final class KeyboardManager {
    static let shared = KeyboardManager()

    private struct Registration {
        weak var host: KeyboardHandlerHost?
        var stamp: Int
        var isSuspended: Bool
    }

    private var eventMonitor: Any?
    private var mouseMonitor: Any?
    private var registrations: [Registration] = []
    private var nextStamp = 0
    private let browserWindows = NSHashTable<NSWindow>.weakObjects()
    /// Browser windows whose sidebar / focused control the user is working in (see `KeyboardResponderKind.resolved`).
    private let focusEngagedWindows = NSHashTable<NSWindow>.weakObjects()

    // Type-ahead state (per window: typing in another window starts a new buffer)
    private(set) var typeAheadBuffer: String = ""
    private var typeAheadTimer: Timer?
    private weak var typeAheadWindow: NSWindow?
    let typeAheadTimeout: TimeInterval = 1.0

    private init() {
        // Local monitors run on the main thread.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.noteMouseDown(event)
            return event
        }
    }

    // MARK: Focus engagement

    private func noteMouseDown(_ event: NSEvent) {
        guard let window = event.window,
              isBrowserWindow(window),
              let frameView = window.contentView?.superview ?? window.contentView else {
            return
        }
        let point = frameView.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
        guard let hitView = frameView.hitTest(point) else { return }
        switch KeyboardResponderKind.clickTarget(of: hitView, contentView: window.contentView) {
        case .sidebar:
            focusEngagedWindows.add(window)
        case .fileTable:
            focusEngagedWindows.remove(window)
        case .fileContent:
            focusEngagedWindows.remove(window)
            endTextEditing(in: window)
        case .control:
            engageIfClickedControlTakesFocus(hitView, in: window)
        case .text, .windowChrome:
            break
        }
    }

    /// Clicking SwiftUI file content doesn't take first responder, so a search field, a path field
    /// or an inline rename would keep the keys (arrows and Space would edit text). Like clicking a
    /// Finder file view, the click ends the editing: the search keeps its text, a rename commits.
    private func endTextEditing(in window: NSWindow) {
        guard KeyboardResponderKind.classify(window.firstResponder) == .textEditing else { return }
        window.makeFirstResponder(nil)
    }

    /// A clicked control that took first responder keeps the keys if it uses them (a slider with
    /// Full Keyboard Access on); checked once AppKit has handled the click.
    private func engageIfClickedControlTakesFocus(_ hitView: NSView, in window: NSWindow) {
        var current: NSView? = hitView
        while let view = current, !(view is NSControl) {
            current = view.superview
        }
        guard let control = current as? NSControl,
              KeyboardResponderKind.controlKeepsKeysWhenFocused(control) else { return }
        DispatchQueue.main.async { [weak self, weak window, weak control] in
            guard let self, let window, let control,
                  let responder = window.firstResponder as? NSView,
                  responder === control || responder.isDescendant(of: control) else { return }
            self.focusEngagedWindows.add(window)
        }
    }

    /// Tab / Shift-Tab moved keyboard focus: honour it if it landed on the sidebar or a control.
    private func noteFocusMovedByKeyboard(in window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            switch KeyboardResponderKind.classify(window.firstResponder) {
            case .sidebar, .otherControl:
                self.focusEngagedWindows.add(window)
            case .fileArea, .textEditing:
                break
            }
        }
    }

    /// What has focus in `window`, after discounting a sidebar/control the user has left.
    func effectiveResponderKind(in window: NSWindow?) -> KeyboardResponderKind {
        guard let window else { return .fileArea }
        return KeyboardResponderKind.classify(window.firstResponder)
            .resolved(isFocusEngaged: focusEngagedWindows.contains(window))
    }

    // MARK: Browser windows

    func registerBrowserWindow(_ window: NSWindow) {
        browserWindows.add(window)
    }

    func isBrowserWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return browserWindows.contains(window)
    }

    /// The browser window menu commands should act on: the key window, or the main window when a
    /// panel (Quick Look) is key. Nil while a sheet is up or a non-browser window is in front.
    func keyBrowserWindow() -> NSWindow? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let window = candidate, isBrowserWindow(window) {
                return window.attachedSheet == nil ? window : nil
            }
        }
        return nil
    }

    /// The window the Edit and Go menus act on: the key window, or the browser window behind the
    /// Quick Look panel while the panel is key (Copy, Paste, Enclosing Folder, Duplicate and Move
    /// to Trash still apply to the files it previews).
    func commandTargetWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if keyWindow is QLPreviewPanel, let mainWindow = NSApp.mainWindow, isBrowserWindow(mainWindow) {
            return mainWindow
        }
        return keyWindow
    }

    // MARK: Handler registration

    func register(_ host: KeyboardHandlerHost) {
        registrations.removeAll { $0.host == nil || $0.host === host }
        nextStamp += 1
        registrations.append(Registration(host: host, stamp: nextStamp, isSuspended: false))
    }

    func unregister(_ host: KeyboardHandlerHost) {
        registrations.removeAll { $0.host == nil || $0.host === host }
    }

    /// The handlers of the most recently registered active view in `window`.
    func activeHandlers(for window: NSWindow) -> KeyboardHandlers? {
        registrations.removeAll { $0.host == nil }
        let candidates = registrations.filter { registration in
            guard !registration.isSuspended, let host = registration.host else { return false }
            return host.keyboardHostWindow === window && host.isKeyboardHandlerActive
        }
        return candidates.max(by: { $0.stamp < $1.stamp })?.host?.keyboardHandlers
    }

    /// Suspends every handler currently registered in `window`. A suspended handler resumes when
    /// its view registers again or is updated (`resumeHandlers(of:)`): a view SwiftUI still updates
    /// is live, only one that is on its way out stays suspended.
    func suspendHandlers(in window: NSWindow?) {
        guard let window else { return }
        for index in registrations.indices where registrations[index].host?.keyboardHostWindow === window {
            registrations[index].isSuspended = true
        }
    }

    /// Lifts a suspension of `host`'s handlers (its view was updated).
    func resumeHandlers(of host: KeyboardHandlerHost) {
        for index in registrations.indices where registrations[index].isSuspended && registrations[index].host === host {
            registrations[index].isSuspended = false
        }
    }

    /// Used by views with their own `keyDown` handling (Cover Flow) when they appear in `window`,
    /// so a handler registered there by the view they replace can't take their keys.
    func clearHandler(in window: NSWindow?) {
        suspendHandlers(in: window)
    }

    /// Older form of `clearHandler(in:)` for callers that don't know their window: assumes the key window.
    func clearHandler() {
        clearHandler(in: NSApp.keyWindow)
    }

    // MARK: Event handling

    /// Returns true when the event was dispatched to a file view and must be consumed.
    /// Internal (not private) so tests can drive it without depending on monitor order.
    func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        if event.keyCode == KeyboardRouting.KeyCode.tab {
            noteFocusMovedByKeyboard(in: window)
            return false
        }
        let context = KeyRoutingContext(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            characters: event.characters,
            isBrowserWindow: isBrowserWindow(window),
            hasAttachedSheet: window.attachedSheet != nil,
            isModalSessionActive: NSApp.modalWindow != nil,
            responder: effectiveResponderKind(in: window),
            isTypeAheadActive: isTypeAheadActive(in: window),
            isQuickLookVisible: QuickLookControllerView.isPanelVisible
        )
        guard let command = KeyboardRouting.command(for: context) else { return false }
        // Closing Quick Look needs no file view (Cover Flow handles its own keys)
        if command == .closeQuickLook {
            return perform(command, with: KeyboardHandlers(), in: window)
        }
        guard let handlers = activeHandlers(for: window) else { return false }
        return perform(command, with: handlers, in: window)
    }

    func perform(_ command: FileAreaKeyCommand, with handlers: KeyboardHandlers, in window: NSWindow?) -> Bool {
        switch command {
        case .moveUp(let extend): handlers.onUpArrow(extend)
        case .moveDown(let extend): handlers.onDownArrow(extend)
        case .moveLeft(let extend): handlers.onLeftArrow(extend)
        case .moveRight(let extend): handlers.onRightArrow(extend)
        case .open: handlers.onReturn()
        case .quickLook: handlers.onSpace()
        case .typeAhead(let char):
            guard let onTypeAhead = handlers.onTypeAhead else { return false }
            appendTypeAhead(char, in: window)
            onTypeAhead(typeAheadBuffer)
        case .cancelTypeAhead:
            clearTypeAhead()
        case .closeQuickLook:
            clearTypeAhead()
            QuickLookControllerView.shared.hidePreview()
        }
        return true
    }

    // MARK: Edit menu

    /// Runs an Edit/Go menu command: forwards it to text editing or the standard responder chain
    /// when appropriate, otherwise performs the file action. Returns the route that was taken.
    @discardableResult
    func performMenuCommand(_ command: EditCommand, viewModel: FileBrowserViewModel?, fileAction: (() -> Void)? = nil) -> EditCommandRoute {
        let window = commandTargetWindow()
        let route = EditCommandRouting.route(
            command,
            isBrowserWindow: isBrowserWindow(window) && window?.attachedSheet == nil,
            responder: effectiveResponderKind(in: window),
            isKeyEquivalent: NSApp.currentEvent?.type == .keyDown
        )
        switch route {
        case .forward(let selector):
            // Behind the Quick Look panel: to that window's text field, not the panel.
            let target = (window == nil || window === NSApp.keyWindow) ? nil : window?.firstResponder
            NSApp.sendAction(selector, to: target, from: nil)
        case .ignore:
            break
        case .files:
            if let fileAction {
                fileAction()
            } else {
                performFileCommand(command, viewModel: viewModel, in: window)
            }
        }
        return route
    }

    /// File side of Copy/Cut/Paste/Select All/Duplicate/Move to Trash/Delete Immediately. Prefers
    /// the handlers of the window's file view (e.g. Column view pastes into the active column),
    /// falling back to the view model.
    private func performFileCommand(_ command: EditCommand, viewModel: FileBrowserViewModel?, in window: NSWindow?) {
        let handlers = window.flatMap { activeHandlers(for: $0) }
        guard let viewModel else {
            NSSound.beep()
            return
        }
        switch command {
        case .copy, .cut:
            guard !viewModel.selectedItems.isEmpty else {
                NSSound.beep()
                return
            }
            if command == .copy {
                if let handlers { handlers.onCopy() } else { viewModel.copySelectedItems() }
            } else {
                if let handlers { handlers.onCut() } else { viewModel.cutSelectedItems() }
            }
        case .paste:
            guard viewModel.canPaste else {
                NSSound.beep()
                return
            }
            if let handlers { handlers.onPaste() } else { viewModel.paste() }
        case .selectAll:
            viewModel.selectAll()
        case .duplicate:
            viewModel.duplicateSelectedItems()
        case .moveToTrash:
            if let handlers { handlers.onDelete() } else { viewModel.deleteSelectedItems() }
        case .deleteImmediately:
            viewModel.deleteSelectionImmediately()
        case .enclosingFolder:
            viewModel.navigateUp()
        }
    }

    // MARK: Type-ahead

    func isTypeAheadActive(in window: NSWindow?) -> Bool {
        !typeAheadBuffer.isEmpty && typeAheadWindow === window
    }

    func appendTypeAhead(_ char: Character, in window: NSWindow? = nil) {
        if typeAheadWindow !== window {
            typeAheadBuffer = ""
            typeAheadWindow = window
        }
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
        typeAheadTimer = Timer.scheduledTimer(withTimeInterval: typeAheadTimeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                KeyboardManager.shared.typeAheadBuffer = ""
            }
        }
    }
}

// MARK: - Browser Window Commands

extension Notification.Name {
    /// Posted with `object:` the target browser window; `userInfo[BrowserWindowCommand.viewModeKey]` is a `ViewMode` raw value.
    static let browserSetViewMode = Notification.Name("browserSetViewMode")
    /// Go ▸ Go to Folder…: posted with `object:` the target browser window, which asks for a path
    /// for its active pane.
    static let browserGoToFolder = Notification.Name("browserGoToFolder")
}

/// Window-scoped menu commands. Notifications are posted with the target window as `object` and
/// each `ContentView` only reacts to its own window.
@MainActor
enum BrowserWindowCommand {
    static let viewModeKey = "viewMode"

    static func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        guard let window = KeyboardManager.shared.keyBrowserWindow() else {
            NSSound.beep()
            return
        }
        NotificationCenter.default.post(name: name, object: window, userInfo: userInfo)
    }

    /// ⌘W: closes the current tab of a browser window with several tabs; otherwise closes the key
    /// window itself (a browser window with one tab, Settings, Quick Look, ...). A sheet keeps its
    /// own ⌘W (Get Info's Close button).
    static func closeTabOrWindow() {
        guard let keyWindow = NSApp.keyWindow else { return }
        if keyWindow.sheetParent != nil || keyWindow.attachedSheet != nil {
            if let event = NSApp.currentEvent, event.type == .keyDown,
               let sheet = keyWindow.attachedSheet ?? (keyWindow.sheetParent != nil ? keyWindow : nil),
               sheet.performKeyEquivalent(with: event) {
                return
            }
            NSSound.beep()
            return
        }
        if KeyboardManager.shared.isBrowserWindow(keyWindow) {
            NotificationCenter.default.post(name: .closeTab, object: keyWindow)
        } else {
            keyWindow.performClose(nil)
        }
    }
}

/// View ▸ as …: ⌘1–⌘4 are Finder's (Icons, List, Columns, Gallery — here Cover Flow); the layouts
/// Finder doesn't have follow on ⌘5–⌘7.
enum ViewModeShortcuts {
    static let menuOrder: [ViewMode] = {
        let finderOrder: [ViewMode] = [.icons, .list, .columns, .coverFlow, .masonry, .dualPane, .quadPane]
        return finderOrder + ViewMode.allCases.filter { !finderOrder.contains($0) }
    }()

    /// The digit of `mode`'s ⌘-shortcut (nil past ⌘9).
    static func digit(for mode: ViewMode) -> Character? {
        guard let index = menuOrder.firstIndex(of: mode), index < 9 else { return nil }
        return Character(String(index + 1))
    }
}

/// What the menu bar needs from one browser window: its active pane's view model and the few facts
/// the enabled states depend on, republished only when one of them changes. (Observing the view
/// model itself rebuilt the whole menu bar, reading the pasteboard each time, on every listing
/// batch, metadata update and thumbnail.)
@MainActor
final class BrowserCommandContext: ObservableObject {
    private(set) weak var viewModel: FileBrowserViewModel?
    @Published private(set) var hasSelection = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var canPaste = false
    /// Tabs in the window (⌘W closes the window when there is one).
    @Published private(set) var tabCount = 1

    /// What `canPaste` was computed from: the pasteboard is read again only when this changes.
    private struct PasteInputs: Equatable {
        let clipboardRevision: Int
        let isInsideArchive: Bool
        let activation: Int
    }

    private var pasteInputs: PasteInputs?
    private var activationCount = 0
    private var viewModelSubscription: AnyCancellable?
    private var activationSubscription: AnyCancellable?
    private var isUpdateScheduled = false

    init() {
        // Another app may have changed the pasteboard while we were in the background.
        activationSubscription = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.activationCount &+= 1
                    self.update()
                }
            }
    }

    func bind(to viewModel: FileBrowserViewModel) {
        guard self.viewModel !== viewModel else { return }
        self.viewModel = viewModel
        pasteInputs = nil
        // A copy or cut in any window or pane then reaches us through the view model.
        FileClipboard.shared.addObserver(viewModel)
        // objectWillChange fires before the change: read the new values once the burst is over.
        viewModelSubscription = viewModel.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleUpdate()
            }
        }
        update()
    }

    func setTabCount(_ count: Int) {
        if tabCount != count { tabCount = count }
    }

    private func scheduleUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isUpdateScheduled = false
            self.update()
        }
    }

    /// Re-reads the facts from the view model, publishing only the ones that changed.
    func update() {
        guard let viewModel else {
            assign(\.hasSelection, false)
            assign(\.canGoBack, false)
            assign(\.canGoForward, false)
            assign(\.canPaste, false)
            return
        }
        assign(\.hasSelection, !viewModel.selectedItems.isEmpty)
        assign(\.canGoBack, viewModel.canGoBack)
        assign(\.canGoForward, viewModel.canGoForward)
        let inputs = PasteInputs(
            clipboardRevision: FileClipboard.shared.revision,
            isInsideArchive: viewModel.isInsideArchive,
            activation: activationCount
        )
        if inputs != pasteInputs {
            pasteInputs = inputs
            assign(\.canPaste, viewModel.canPaste)
        }
    }

    private func assign(_ keyPath: ReferenceWritableKeyPath<BrowserCommandContext, Bool>, _ value: Bool) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

/// Key-window state the menu bar's enabled states depend on but SwiftUI can't observe: whether a
/// text field is being edited (or a non-browser window is key), whether a sheet is up, and the
/// command context of the browser window the menus act on. Updated from key-window changes and KVO
/// on that window's first responder.
@MainActor
final class MenuValidationState: ObservableObject {
    static let shared = MenuValidationState()

    /// Edit commands should act as standard text/edit commands (text field focused, or the key
    /// window is Settings, a sheet, an alert, the update window, ...).
    @Published private(set) var usesStandardEditing = true
    /// A sheet is attached to, or is, the key window.
    @Published private(set) var isSheetActive = false
    /// The key window is a browser window (⌘W closes a tab or that window, not a panel).
    @Published private(set) var isKeyWindowBrowser = false
    /// The command context of the browser window the menus act on (the one behind the Quick Look
    /// panel while the panel is key); nil when that isn't a browser window. Its changes are
    /// republished as changes of this object.
    @Published private(set) var commandContext: BrowserCommandContext?

    private var firstResponderObservation: NSKeyValueObservation?
    private var contextSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private let contexts = NSMapTable<NSWindow, BrowserCommandContext>.weakToWeakObjects()

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.keyWindowChanged()
                }
            })
        }
        keyWindowChanged()
    }

    /// Registers the command context of a browser window (its `ContentView`'s).
    func setCommandContext(_ context: BrowserCommandContext, for window: NSWindow) {
        if contexts.object(forKey: window) !== context {
            contexts.setObject(context, forKey: window)
        }
        refresh()
    }

    private func keyWindowChanged() {
        firstResponderObservation = KeyboardManager.shared.commandTargetWindow()?.observe(\.firstResponder, options: []) { [weak self] _, _ in
            // Deferred: first-responder changes can happen inside a SwiftUI update.
            DispatchQueue.main.async {
                self?.update()
            }
        }
        update()
    }

    /// Re-reads the state (e.g. after a window registered as a browser window).
    func refresh() {
        keyWindowChanged()
    }

    private func update() {
        let manager = KeyboardManager.shared
        let keyWindow = NSApp.keyWindow
        let targetWindow = manager.commandTargetWindow()
        let isTargetBrowser = manager.isBrowserWindow(targetWindow)
        let sheetActive = keyWindow.map { $0.sheetParent != nil || $0.attachedSheet != nil } ?? false
        let standardEditing = !isTargetBrowser
            || sheetActive
            || targetWindow?.attachedSheet != nil
            || KeyboardResponderKind.classify(targetWindow?.firstResponder) == .textEditing
        let keyIsBrowser = manager.isBrowserWindow(keyWindow)
        let context = isTargetBrowser ? targetWindow.flatMap { contexts.object(forKey: $0) } : nil
        if usesStandardEditing != standardEditing { usesStandardEditing = standardEditing }
        if isSheetActive != sheetActive { isSheetActive = sheetActive }
        if isKeyWindowBrowser != keyIsBrowser { isKeyWindowBrowser = keyIsBrowser }
        if commandContext !== context {
            commandContext = context
            contextSubscription = context?.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                }
            }
        }
    }
}

// MARK: - Keyboard Navigable Modifier

/// Invisible view that ties a view's keyboard handlers to the window hosting it.
final class KeyboardHandlerProbeView: NSView, KeyboardHandlerHost {
    /// Set on every update of the owning view, which also lifts a suspension (the view is live).
    var handlers = KeyboardHandlers() {
        didSet {
            if window != nil {
                KeyboardManager.shared.resumeHandlers(of: self)
            }
        }
    }
    var isActive = true {
        didSet {
            if isActive && !oldValue && window != nil {
                KeyboardManager.shared.register(self)
            }
        }
    }

    var keyboardHostWindow: NSWindow? { window }
    var isKeyboardHandlerActive: Bool { isActive }
    var keyboardHandlers: KeyboardHandlers { handlers }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            KeyboardManager.shared.register(self)
        } else {
            KeyboardManager.shared.unregister(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

private struct KeyboardHandlerProbe: NSViewRepresentable {
    let isActive: Bool
    let handlers: KeyboardHandlers

    func makeNSView(context: Context) -> KeyboardHandlerProbeView {
        let view = KeyboardHandlerProbeView()
        view.handlers = handlers
        view.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: KeyboardHandlerProbeView, context: Context) {
        // Refreshed on every update of the owning view, so the handlers always see its current
        // state (items after a sort/filter, the active pane, column counts).
        nsView.handlers = handlers
        nsView.isActive = isActive
    }

    static func dismantleNSView(_ nsView: KeyboardHandlerProbeView, coordinator: ()) {
        KeyboardManager.shared.unregister(nsView)
    }
}

struct KeyboardNavigable: ViewModifier {
    let isActive: Bool
    let handlers: KeyboardHandlers

    func body(content: Content) -> some View {
        content.background(KeyboardHandlerProbe(isActive: isActive, handlers: handlers))
    }
}

extension View {
    /// Routes arrow keys, Return/⌘↓, Space and type-ahead typed in this view's window to these
    /// closures (only while the file area has focus), and lets the Edit menu use `onCopy`/`onCut`/
    /// `onPaste`/`onDelete` for this view. The closures are refreshed on every update of the view.
    func keyboardNavigable(
        isActive: Bool = true,
        onUpArrow: @escaping (_ shift: Bool) -> Void = { _ in },
        onDownArrow: @escaping (_ shift: Bool) -> Void = { _ in },
        onLeftArrow: @escaping (_ shift: Bool) -> Void = { _ in },
        onRightArrow: @escaping (_ shift: Bool) -> Void = { _ in },
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
            handlers: KeyboardHandlers(
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
            )
        ))
    }
}

// MARK: - Hosting Window Reader

/// Reports the window a view is hosted in (and when it leaves it).
struct HostingWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> HostingWindowReaderView {
        let view = HostingWindowReaderView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: HostingWindowReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }
}

final class HostingWindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Pane Keyboard Navigation

/// Keyboard actions shared by the dual and quad pane views.
@MainActor
enum PaneKeyboardNavigation {
    /// Moves the selection by `offset` items (±1, or ± the column count for ↑/↓ in icon mode), like
    /// the list view: with nothing (visible) selected, a forward arrow selects the first item and a
    /// backward one the last; a plain arrow moves past the end of a multi-selection it points to;
    /// ⇧ extends from the anchor.
    static func move(_ viewModel: FileBrowserViewModel, by offset: Int, extend: Bool = false) {
        let items = viewModel.filteredItems
        guard !items.isEmpty, offset != 0 else { return }
        let maxIndex = items.count - 1
        let selection = viewModel.selectedItems

        var selectedIndices: [Int] = []
        if selection.count == 1, let only = selection.first, let index = items.firstIndex(of: only) {
            selectedIndices = [index]
        } else if !selection.isEmpty {
            selectedIndices = items.indices.filter { selection.contains(items[$0]) }
        }

        guard let lowest = selectedIndices.first, let highest = selectedIndices.last else {
            select(offset > 0 ? 0 : maxIndex, in: items, viewModel: viewModel)
            return
        }

        if extend {
            // lastSelectedIndex tracks the moving end of the range.
            var anchor = viewModel.selectionAnchorIndex
            var cursor = viewModel.lastSelectedIndex
            if !items.indices.contains(cursor) || !selection.contains(items[cursor]) {
                // Stale cursor (filter or sort changed): extend from the end in the arrow's direction
                cursor = offset > 0 ? highest : lowest
                anchor = offset > 0 ? lowest : highest
            } else if !items.indices.contains(anchor) {
                anchor = cursor
            }
            let newIndex = max(0, min(maxIndex, cursor + offset))
            guard newIndex != cursor else { return }
            viewModel.selectionAnchorIndex = anchor
            viewModel.selectRange(to: newIndex, in: items)
            viewModel.updateQuickLookPreview(for: items[newIndex])
            return
        }

        let newIndex = offset > 0 ? min(highest + offset, maxIndex) : max(lowest + offset, 0)
        if selectedIndices.count == 1 && newIndex == lowest { return }  // already at the end
        select(newIndex, in: items, viewModel: viewModel)
    }

    private static func select(_ index: Int, in items: [FileItem], viewModel: FileBrowserViewModel) {
        viewModel.selectItem(items[index])
        viewModel.lastSelectedIndex = index
        viewModel.selectionAnchorIndex = index
        viewModel.updateQuickLookPreview(for: items[index])
    }

    static func openSelection(in viewModel: FileBrowserViewModel) {
        if let item = viewModel.primarySelectedItem {
            viewModel.openItem(item)
        }
    }

    static func toggleQuickLook(in viewModel: FileBrowserViewModel) {
        viewModel.toggleQuickLookForSelection { offset in
            move(viewModel, by: offset)
        }
    }

    static func jumpToMatch(_ prefix: String, in viewModel: FileBrowserViewModel) {
        guard !prefix.isEmpty else { return }
        let lowercased = prefix.lowercased()
        let items = viewModel.filteredItems
        guard let index = items.firstIndex(where: { $0.displayName.lowercased().hasPrefix(lowercased) }) else { return }
        viewModel.selectItem(items[index])
        viewModel.lastSelectedIndex = index
        viewModel.selectionAnchorIndex = index
        viewModel.updateQuickLookPreview(for: items[index])
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

    /// Toggles QuickLook for the selection's lead item with navigation callback
    func toggleQuickLookForSelection(onNavigate: @escaping (Int) -> Void) {
        guard let selectedItem = primarySelectedItem else { return }

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

struct ClickStateData {
    var lastClickTime: Date?
    var lastClickId: AnyHashable?
}

struct InstantTapModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    @State private var clickState = ClickStateData()
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
    @State private var keyMonitor: Any?

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
                    editText = item.editingName
                    // Install synchronously so a rename that ends before the field takes focus
                    // still removes them (no monitors installed after the field is gone).
                    installMonitors()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard !hasCommitted else { return }
                        isFocused = true
                        selectAllText()
                    }
                }
                .onDisappear {
                    removeMonitors()
                    if !hasCommitted {
                        commitRename()
                    }
                }
                .onChange(of: isFocused) { _, focused in
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

    private func installMonitors() {
        removeMonitors()

        // Commit when a click lands outside the text field
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Check if click is outside our text field by checking if the first responder changed
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow,
                   let firstResponder = window.firstResponder,
                   !(firstResponder is NSTextView) {
                    if !hasCommitted {
                        commitRename()
                    }
                }
            }
            return event
        }

        // Tab / Shift+Tab: commit and move to the next / previous item
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !hasCommitted,
                  event.keyCode == 48,
                  event.window?.firstResponder is NSTextView else {
                return event
            }
            if event.modifierFlags.contains(.shift) {
                commitRenameAndPrevious()
            } else {
                commitRenameAndNext()
            }
            return nil
        }
    }

    private func removeMonitors() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func commitRename() {
        guard !hasCommitted else { return }
        hasCommitted = true
        removeMonitors()

        if let newName = Self.newName(forEditedText: editText, of: item) {
            viewModel.renameItem(item, to: newName)
        }
        viewModel.renamingURL = nil
    }

    /// The full new name for the text typed in the field (see `FileItem.newName(forEditedText:)`).
    static func newName(forEditedText text: String, of item: FileItem) -> String? {
        item.newName(forEditedText: text)
    }

    private func commitRenameAndNext() {
        guard !hasCommitted else { return }
        hasCommitted = true
        removeMonitors()
        viewModel.commitRenameAndNext(currentItem: item, newName: editText)
    }

    private func commitRenameAndPrevious() {
        guard !hasCommitted else { return }
        hasCommitted = true
        removeMonitors()
        viewModel.commitRenameAndPrevious(currentItem: item, newName: editText)
    }

    private func cancelRename() {
        hasCommitted = true
        removeMonitors()
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

    /// The text a rename field starts with: files without their extension, folders and packages
    /// with their full name; ":" on disk shown as "/".
    var editingName: String {
        nameWithoutExtension.finderDisplayName
    }

    /// The full new name for `text` typed in a rename field (inline field, list, Tab/⇧Tab), or nil
    /// when nothing should change. A file's extension is re-appended unless the user typed it
    /// (any case: "Notes.TXT" changes the extension's case); folders and packages are edited with
    /// their full name, so nothing is appended ("my.folder" → "x" stays "x", "Foo.app" stays
    /// "Foo.app"). Whitespace is kept, as in Finder; "/" is stored as ":" by the rename itself.
    func newName(forEditedText text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hiddenExtension = isDirectory ? "" : url.pathExtension
        var newName = text
        if !hiddenExtension.isEmpty && !text.lowercased().hasSuffix("." + hiddenExtension.lowercased()) {
            newName += "." + hiddenExtension
        }
        return FileOperationEngine.fileSystemName(forDisplayName: newName) == name ? nil : newName
    }
}

// MARK: - Display Names

extension String {
    /// This file-system name as Finder shows it: ":" on disk is displayed as "/".
    var finderDisplayName: String {
        contains(":") ? replacingOccurrences(of: ":", with: "/") : self
    }
}

extension URL {
    /// The last path component as Finder shows it (":" on disk is displayed as "/"). For display
    /// only; paths keep the on-disk name.
    var finderDisplayName: String {
        lastPathComponent.finderDisplayName
    }
}

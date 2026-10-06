import SwiftUI
import AppKit
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

    /// Whether a click on `view` engages the sidebar / a control (true), leaves it for the file area
    /// (false), or doesn't matter (nil: text views).
    @MainActor
    static func clickEngagesFocus(on view: NSView) -> Bool? {
        var ancestors: [NSView] = []
        var current: NSView? = view
        while let candidate = current {
            ancestors.append(candidate)
            current = candidate.superview
        }
        // Inside a table: the sidebar engages, the file list doesn't (its cells contain controls).
        for candidate in ancestors {
            if candidate is NSOutlineView { return true }
            if candidate is NSTableView { return false }
        }
        if ancestors.contains(where: { $0 is NSText }) { return nil }
        if ancestors.contains(where: { $0 is NSControl }) { return true }
        return false
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
              !context.isModalSessionActive,
              context.responder == .fileArea else {
            return nil
        }

        let flags = context.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

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
            case .duplicate:
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
        case .duplicate, .moveToTrash, .enclosingFolder: return nil
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
        guard let hitView = frameView.hitTest(point),
              let engages = KeyboardResponderKind.clickEngagesFocus(on: hitView) else {
            return
        }
        if engages {
            focusEngagedWindows.add(window)
        } else {
            focusEngagedWindows.remove(window)
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

    /// Suspends every handler currently registered in `window` (they resume when they re-register).
    func suspendHandlers(in window: NSWindow?) {
        guard let window else { return }
        for index in registrations.indices where registrations[index].host?.keyboardHostWindow === window {
            registrations[index].isSuspended = true
        }
    }

    /// Used by views with their own `keyDown` handling (Cover Flow) so a handler registered by the
    /// view they replace can't take their keys.
    func clearHandler() {
        suspendHandlers(in: NSApp.keyWindow)
    }

    // MARK: Event handling

    private func handle(_ event: NSEvent) -> Bool {
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
            isTypeAheadActive: isTypeAheadActive(in: window)
        )
        guard let command = KeyboardRouting.command(for: context),
              let handlers = activeHandlers(for: window) else {
            return false
        }
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
        }
        return true
    }

    // MARK: Edit menu

    /// Runs an Edit/Go menu command: forwards it to text editing or the standard responder chain
    /// when appropriate, otherwise performs the file action. Returns the route that was taken.
    @discardableResult
    func performMenuCommand(_ command: EditCommand, viewModel: FileBrowserViewModel?, fileAction: (() -> Void)? = nil) -> EditCommandRoute {
        let keyWindow = NSApp.keyWindow
        let route = EditCommandRouting.route(
            command,
            isBrowserWindow: isBrowserWindow(keyWindow) && keyWindow?.attachedSheet == nil,
            responder: effectiveResponderKind(in: keyWindow),
            isKeyEquivalent: NSApp.currentEvent?.type == .keyDown
        )
        switch route {
        case .forward(let selector):
            NSApp.sendAction(selector, to: nil, from: nil)
        case .ignore:
            break
        case .files:
            if let fileAction {
                fileAction()
            } else {
                performFileCommand(command, viewModel: viewModel, in: keyWindow)
            }
        }
        return route
    }

    /// File side of Copy/Cut/Paste/Select All/Duplicate/Move to Trash. Prefers the handlers of the
    /// window's file view (e.g. Column view pastes into the active column), falling back to the view model.
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

/// Key-window state the menu bar's enabled states depend on but SwiftUI can't observe: whether a
/// text field is being edited (or a non-browser window is key), and whether a sheet is up.
/// Updated from key-window changes and KVO on the key window's first responder.
@MainActor
final class MenuValidationState: ObservableObject {
    static let shared = MenuValidationState()

    /// Edit commands should act as standard text/edit commands (text field focused, or the key
    /// window is Settings, a sheet, an alert, the update window, ...).
    @Published private(set) var usesStandardEditing = true
    /// A sheet is attached to, or is, the key window.
    @Published private(set) var isSheetActive = false
    /// Bumped when the app becomes active, so pasteboard-dependent states are re-read.
    @Published private(set) var pasteboardGeneration = 0

    private var firstResponderObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

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
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pasteboardGeneration &+= 1
                self?.update()
            }
        })
        keyWindowChanged()
    }

    private func keyWindowChanged() {
        firstResponderObservation = NSApp.keyWindow?.observe(\.firstResponder, options: []) { [weak self] _, _ in
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
        let keyWindow = NSApp.keyWindow
        let manager = KeyboardManager.shared
        let sheetActive = keyWindow.map { $0.sheetParent != nil || $0.attachedSheet != nil } ?? false
        let standardEditing = !manager.isBrowserWindow(keyWindow)
            || sheetActive
            || KeyboardResponderKind.classify(keyWindow?.firstResponder) == .textEditing
        if usesStandardEditing != standardEditing { usesStandardEditing = standardEditing }
        if isSheetActive != sheetActive { isSheetActive = sheetActive }
    }
}

// MARK: - Keyboard Navigable Modifier

/// Invisible view that ties a view's keyboard handlers to the window hosting it.
final class KeyboardHandlerProbeView: NSView, KeyboardHandlerHost {
    var handlers = KeyboardHandlers()
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
    static func move(_ viewModel: FileBrowserViewModel, by offset: Int, extend: Bool = false) {
        let items = viewModel.filteredItems
        guard !items.isEmpty else { return }

        // When extending, lastSelectedIndex tracks the moving end of the range; otherwise start
        // from the lead item (a Set has no order).
        let currentIndex: Int
        if extend {
            currentIndex = viewModel.lastSelectedIndex
        } else if let lead = viewModel.primarySelectedItem,
                  let index = items.firstIndex(of: lead) {
            currentIndex = index
        } else {
            currentIndex = viewModel.lastSelectedIndex
        }
        let clampedCurrentIndex = max(0, min(items.count - 1, currentIndex))
        let newIndex = max(0, min(items.count - 1, clampedCurrentIndex + offset))
        guard newIndex != clampedCurrentIndex || viewModel.selectedItems.isEmpty else { return }

        if extend {
            viewModel.selectRange(to: newIndex, in: items)
        } else {
            viewModel.selectItem(items[newIndex])
            viewModel.lastSelectedIndex = newIndex
            viewModel.selectionAnchorIndex = newIndex
        }
        viewModel.updateQuickLookPreview(for: items[newIndex])
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
        guard let index = items.firstIndex(where: { $0.name.lowercased().hasPrefix(lowercased) }) else { return }
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
                    editText = item.nameWithoutExtension
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

    /// The full new name for the text typed in the field, or nil when nothing should change.
    /// Files are edited without their extension, which is re-appended unless the user typed it;
    /// folders and packages are edited with their full name, so nothing is appended ("my.folder"
    /// → "x" stays "x", "Foo.app" stays "Foo.app"). Whitespace is kept, as in Finder.
    static func newName(forEditedText text: String, of item: FileItem) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let hiddenExtension = item.isDirectory ? "" : item.url.pathExtension
        var name = text
        if !hiddenExtension.isEmpty && !text.lowercased().hasSuffix("." + hiddenExtension.lowercased()) {
            name += "." + hiddenExtension
        }
        return name == item.name ? nil : name
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
}

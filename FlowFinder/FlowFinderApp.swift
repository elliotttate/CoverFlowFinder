import SwiftUI
import Sparkle

@main
struct FlowFinderApp: App {
    // Not observed here: observing it would rebuild the whole App body (and every window's
    // ContentView initializer) on any settings change. Views observe it through the environment.
    private let settings = AppSettings.shared
    @StateObject private var soundEffectsMonitor = FinderSoundEffectsMonitor()
    @NSApplicationDelegateAdaptor(FlowFinderAppDelegate.self) private var appDelegate

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // One tab system: the browser windows' own tabs, not AppKit's window tabs as well
        // (View ▸ Show Tab Bar, Window ▸ Merge All Windows).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

            SidebarCommands()
            ToolbarCommands()

            BrowserCommands(settings: settings, menuState: .shared)
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

/// File, Edit, View, Window and Go menu commands. They act on the active pane of the browser
/// window in front (its `BrowserCommandContext`, tracked by `MenuValidationState`), and hand
/// text-editing shortcuts back to text fields and non-browser windows.
struct BrowserCommands: Commands {
    @ObservedObject var settings: AppSettings
    @ObservedObject var menuState: MenuValidationState

    private var context: BrowserCommandContext? {
        menuState.commandContext
    }

    /// The active pane's view model; nil while a sheet is up, so no command acts on the window
    /// behind it.
    private var viewModel: FileBrowserViewModel? {
        menuState.isSheetActive ? nil : context?.viewModel
    }

    private var hasSelection: Bool {
        viewModel != nil && (context?.hasSelection ?? false)
    }

    /// Text fields and non-browser windows get the standard Copy/Cut/Paste, so those stay enabled.
    private var standardEditing: Bool {
        menuState.usesStandardEditing || viewModel == nil
    }

    private var canPasteFiles: Bool {
        viewModel != nil && (context?.canPaste ?? false)
    }

    /// ⌘W closes the tab of a browser window with several tabs, otherwise the window in front.
    private var closesTab: Bool {
        menuState.isKeyWindowBrowser && (context?.tabCount ?? 1) > 1
    }

    var body: some Commands {
        // File menu commands
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                BrowserWindowCommand.post(.newTab)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(menuState.isSheetActive)

            // Disabled while a sheet is up so ⌘W reaches the sheet (Get Info's Close).
            Button(closesTab ? "Close Tab" : "Close Window") {
                BrowserWindowCommand.closeTabOrWindow()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(menuState.isSheetActive)

            Divider()

            Button("New Folder") {
                viewModel?.createNewFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Button("Get Info") {
                viewModel?.presentInfo(for: viewModel?.primarySelectedItem)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!hasSelection)

            Divider()
        }

        // Window menu - tab switching
        CommandGroup(after: .windowList) {
            Button("Show Next Tab") {
                BrowserWindowCommand.post(.nextTab)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(menuState.isSheetActive)

            Button("Show Previous Tab") {
                BrowserWindowCommand.post(.previousTab)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(menuState.isSheetActive)
        }

        // Edit menu commands. While a text field is edited (or a non-browser window is key) they
        // act as the standard text commands, so the file-based enabled states don't apply.
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                perform(.copy)
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!standardEditing && !hasSelection)

            Button("Cut") {
                perform(.cut)
            }
            .keyboardShortcut("x", modifiers: .command)
            .disabled(!standardEditing && !hasSelection)

            Button("Paste") {
                perform(.paste)
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!standardEditing && !canPasteFiles)
            // Finder's ⌥⌘V, shown in Paste's place while Option is held: moves the clipboard's
            // items here, also when they were copied (a cut is moved by Paste as well)
            .modifierKeyAlternate(.option) {
                Button("Move Item Here") {
                    performFileOnly {
                        guard let viewModel, viewModel.canPaste else {
                            NSSound.beep()
                            return
                        }
                        viewModel.pasteMovingItems()
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!canPasteFiles || menuState.usesStandardEditing)
            }

            Divider()

            Button("Select All") {
                perform(.selectAll)
            }
            .keyboardShortcut("a", modifiers: .command)

            Divider()

            // Disabled while editing text so ⌘⌫ reaches the field (delete to start of line). If that
            // state is ever stale, the action still forwards to the field instead of trashing.
            Button("Duplicate") {
                perform(.duplicate)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!hasSelection || menuState.usesStandardEditing)

            Button("Move to Trash") {
                perform(.moveToTrash)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!hasSelection || menuState.usesStandardEditing)

            // Asks for confirmation; can't be undone.
            Button("Delete Immediately…") {
                perform(.deleteImmediately)
            }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(!hasSelection || menuState.usesStandardEditing)
        }

        // View menu commands
        CommandGroup(after: .toolbar) {
            Divider()

            // Finder's ⌘1–⌘4 (Icons, List, Columns, Gallery = Cover Flow), then the extra layouts
            ForEach(ViewModeShortcuts.menuOrder, id: \.self) { mode in
                let button = Button("as \(mode.rawValue)") {
                    BrowserWindowCommand.post(.browserSetViewMode, userInfo: [BrowserWindowCommand.viewModeKey: mode.rawValue])
                }
                .disabled(menuState.isSheetActive)
                if let digit = ViewModeShortcuts.digit(for: mode) {
                    button.keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                } else {
                    button
                }
            }

            Divider()

            Toggle("Show Hidden Files", isOn: $settings.showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button("Find") {
                BrowserWindowCommand.post(.focusSearch)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(menuState.isSheetActive)

            Button("Refresh") {
                viewModel?.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(viewModel == nil)

            Button("Show in Finder") {
                viewModel?.showInFinder()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(viewModel == nil)
        }

        // Go menu
        CommandMenu("Go") {
            Button("Back") {
                viewModel?.goBack()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(viewModel == nil || !(context?.canGoBack ?? false))

            Button("Forward") {
                viewModel?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(viewModel == nil || !(context?.canGoForward ?? false))

            Button("Enclosing Folder") {
                perform(.enclosingFolder)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Divider()

            Button("Home") {
                viewModel?.navigateTo(FileManager.default.homeDirectoryForCurrentUser)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Button("Desktop") {
                if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                    viewModel?.navigateTo(desktop)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Button("Documents") {
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    viewModel?.navigateTo(docs)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Button("Downloads") {
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    viewModel?.navigateTo(downloads)
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Button("Applications") {
                viewModel?.navigateTo(URL(fileURLWithPath: "/Applications"))
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(viewModel == nil)

            Divider()

            // Always the sheet, for the key window's active pane (that window resolves the pane)
            Button("Go to Folder…") {
                BrowserWindowCommand.post(.browserGoToFolder)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(menuState.isSheetActive)
        }
    }

    private func perform(_ command: EditCommand) {
        KeyboardManager.shared.performMenuCommand(command, viewModel: viewModel)
    }

    /// A file command with no text-editing counterpart: routed like Duplicate, so it does nothing
    /// while a text field is edited or a window other than a browser is in front.
    private func performFileOnly(_ action: @escaping () -> Void) {
        KeyboardManager.shared.performMenuCommand(.duplicate, viewModel: viewModel, fileAction: action)
    }
}

// MARK: - Quitting

/// Asks before quitting while file operations run: quitting would cut a copy or move short.
final class FlowFinderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitGuard.terminateReply(confirm: QuitGuard.confirmStoppingOperations) {
            sender.reply(toApplicationShouldTerminate: true)
        }
    }
}

/// The quit decision while file operations may be queued or running in any window.
@MainActor
enum QuitGuard {
    /// Waiting for stopped operations to end before quitting.
    private(set) static var isWaitingToQuit = false

    /// The answer to `applicationShouldTerminate`: quit now when no file operation is pending
    /// (also for Sparkle's install and relaunch). Otherwise `confirm` asks; stopping cancels every
    /// operation — each keeps what it finished, an item copied part-way is removed — and answers
    /// `.terminateLater`, and `quit` runs once they have all ended. Cancel keeps the app running.
    static func terminateReply(confirm: () -> Bool, quit: @escaping () -> Void) -> NSApplication.TerminateReply {
        // Asked again while the stopped operations wind down: that quit is still coming
        if isWaitingToQuit { return .terminateCancel }
        guard FileOperationEngine.hasPendingOperations else { return .terminateNow }
        guard confirm() else { return .terminateCancel }
        isWaitingToQuit = true
        FileOperationEngine.cancelAllOperations()
        FileOperationEngine.whenIdle {
            // After the last operation's own completion, never before this returns
            DispatchQueue.main.async {
                isWaitingToQuit = false
                quit()
            }
        }
        return .terminateLater
    }

    /// Asks whether to stop the file operations and quit: true for Quit.
    static func confirmStoppingOperations() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File operations are in progress."
        alert.informativeText = "Stop them and quit? What’s done stays done; an item copied part-way is removed."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

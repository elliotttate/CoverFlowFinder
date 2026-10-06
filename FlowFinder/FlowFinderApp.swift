import SwiftUI
import Sparkle

@main
struct FlowFinderApp: App {
    // Not observed here: observing it would rebuild the whole App body (and every window's
    // ContentView initializer) on any settings change. Views observe it through the environment.
    private let settings = AppSettings.shared
    @StateObject private var soundEffectsMonitor = FinderSoundEffectsMonitor()

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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

/// File, Edit, View, Window and Go menu commands. They act on the active pane of the key browser
/// window (published by ContentView with `focusedSceneObject`), and hand text-editing shortcuts
/// back to text fields and non-browser windows.
struct BrowserCommands: Commands {
    @FocusedObject private var viewModel: FileBrowserViewModel?
    @ObservedObject var settings: AppSettings
    @ObservedObject var menuState: MenuValidationState

    private var hasSelection: Bool {
        !(viewModel?.selectedItems.isEmpty ?? true)
    }

    /// Text fields and non-browser windows get the standard Copy/Cut/Paste, so those stay enabled.
    private var standardEditing: Bool {
        menuState.usesStandardEditing || viewModel == nil
    }

    private var canPasteFiles: Bool {
        _ = menuState.pasteboardGeneration  // re-read after another app changed the pasteboard
        return viewModel?.canPaste ?? false
    }

    var body: some Commands {
        // File menu commands
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                BrowserWindowCommand.post(.newTab)
            }
            .keyboardShortcut("t", modifiers: .command)

            // Disabled while a sheet is up so ⌘W reaches the sheet (Get Info's Close).
            Button("Close Tab") {
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

            Button("Show Previous Tab") {
                BrowserWindowCommand.post(.previousTab)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
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
        }

        // View menu commands
        CommandGroup(after: .toolbar) {
            Divider()

            ForEach(Array(ViewMode.allCases.prefix(9).enumerated()), id: \.element) { index, mode in
                Button("as \(mode.rawValue)") {
                    BrowserWindowCommand.post(.browserSetViewMode, userInfo: [BrowserWindowCommand.viewModeKey: mode.rawValue])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }

            Divider()

            Toggle("Show Hidden Files", isOn: $settings.showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button("Find") {
                BrowserWindowCommand.post(.focusSearch)
            }
            .keyboardShortcut("f", modifiers: .command)

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
            .disabled(!(viewModel?.canGoBack ?? false))

            Button("Forward") {
                viewModel?.goForward()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!(viewModel?.canGoForward ?? false))

            Button("Enclosing Folder") {
                perform(.enclosingFolder)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Divider()

            Button("Home") {
                viewModel?.navigateTo(FileManager.default.homeDirectoryForCurrentUser)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button("Desktop") {
                if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                    viewModel?.navigateTo(desktop)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Documents") {
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    viewModel?.navigateTo(docs)
                }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Downloads") {
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    viewModel?.navigateTo(downloads)
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Applications") {
                viewModel?.navigateTo(URL(fileURLWithPath: "/Applications"))
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Divider()

            Button("Go to Folder…") {
                guard let viewModel, let window = KeyboardManager.shared.keyBrowserWindow() else {
                    NSSound.beep()
                    return
                }
                GoToFolderPrompt.present(for: viewModel, in: window)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }

    private func perform(_ command: EditCommand) {
        KeyboardManager.shared.performMenuCommand(command, viewModel: viewModel)
    }
}

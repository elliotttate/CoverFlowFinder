import SwiftUI

@main
struct FlowFinderApp: App {
    @FocusedValue(\.viewModel) var viewModel
    @StateObject private var settings = AppSettings.shared
    @StateObject private var soundEffectsMonitor = FinderSoundEffectsMonitor()

    init() {
        // Start building the search index in the background
        Task { @MainActor in
            SearchIndexManager.shared.startIndexing()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            ToolbarCommands()

            // File menu commands
            CommandGroup(after: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: .newTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(name: .closeTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("New Folder") {
                    viewModel?.createNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()
            }

            // Window menu - tab switching
            CommandGroup(after: .windowList) {
                Button("Show Next Tab") {
                    NotificationCenter.default.post(name: .nextTab, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Show Previous Tab") {
                    NotificationCenter.default.post(name: .previousTab, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }

            // Edit menu commands
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    viewModel?.copySelectedItems()
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(viewModel?.selectedItems.isEmpty ?? true)

                Button("Cut") {
                    viewModel?.cutSelectedItems()
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(viewModel?.selectedItems.isEmpty ?? true)

                Button("Paste") {
                    viewModel?.paste()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!(viewModel?.canPaste ?? false))

                Divider()

                Button("Select All") {
                    viewModel?.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)

                Divider()

                Button("Duplicate") {
                    viewModel?.duplicateSelectedItems()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(viewModel?.selectedItems.isEmpty ?? true)

                Button("Move to Trash") {
                    viewModel?.deleteSelectedItems()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(viewModel?.selectedItems.isEmpty ?? true)
            }

            // View menu commands
            CommandGroup(after: .toolbar) {
                Divider()

                Button("Refresh") {
                    viewModel?.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Show in Finder") {
                    viewModel?.showInFinder()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            // Go menu
            CommandMenu("Go") {
                Button("Back") {
                    viewModel?.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled((viewModel?.historyIndex ?? 0) <= 0)

                Button("Forward") {
                    viewModel?.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled((viewModel?.historyIndex ?? 0) >= (viewModel?.navigationHistory.count ?? 1) - 1)

                Button("Enclosing Folder") {
                    viewModel?.navigateToParent()
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
            }
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

import SwiftUI

@main
struct CoverFlowFinderApp: App {
    @FocusedValue(\.viewModel) var viewModel

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            ToolbarCommands()

            // File menu commands
            CommandGroup(after: .newItem) {
                Button("New Folder") {
                    viewModel?.createNewFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()
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
                .disabled(!(viewModel?.canGoBack ?? false))

                Button("Forward") {
                    viewModel?.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(viewModel?.canGoForward ?? false))

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
    }
}

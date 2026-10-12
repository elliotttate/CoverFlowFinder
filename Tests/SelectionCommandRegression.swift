import AppKit
import SwiftUI

@main
struct SelectionCommandRegression {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    private static func run() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowfinder-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["first.jpg", "second.jpg", "other.png"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }

        let model = FileBrowserViewModel(initialPath: folder)
        model.items = ["first.jpg", "second.jpg", "other.png"].map {
            FileItem(url: folder.appendingPathComponent($0))
        }
        model.searchText = ".jpg"
        let context = BrowserCommandContext()
        context.bind(to: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        KeyboardManager.shared.registerBrowserWindow(window)
        MenuValidationState.shared.setCommandContext(context, for: window)

        // There is no key window: published menu state has no active context, while the
        // window's registered context still exists. A focus transition can leave this snapshot
        // stale when a menu action arrives; dispatch must use the target window's context.
        precondition(MenuValidationState.shared.commandContext == nil)
        KeyboardManager.shared.performFileCommand(.selectAll, viewModel: nil, in: window)
        precondition(Set(model.selectedItems.map(\.name)) == ["first.jpg", "second.jpg"],
                     "Select All must resolve the registered browser even with stale menu state")

        // A view model captured for another pane/window must not override the actual target.
        let staleModel = FileBrowserViewModel(initialPath: folder)
        staleModel.items = [FileItem(url: folder.appendingPathComponent("other.png"))]
        model.selectedItems.removeAll()
        KeyboardManager.shared.performFileCommand(.selectAll, viewModel: staleModel, in: window)
        precondition(Set(model.selectedItems.map(\.name)) == ["first.jpg", "second.jpg"])
        precondition(staleModel.selectedItems.isEmpty, "Select All must not affect another pane")

        // Existing callers without a registered command context retain their explicit target.
        let unregisteredWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        KeyboardManager.shared.performFileCommand(.selectAll, viewModel: staleModel, in: unregisteredWindow)
        precondition(staleModel.selectedItems.count == 1)

        // Editing the filter or rename field continues to select text through the responder chain.
        precondition(EditCommandRouting.route(.selectAll, isBrowserWindow: true,
                     responder: .textEditing, isKeyEquivalent: true)
                     == .forward(#selector(NSText.selectAll(_:))))
        precondition(EditCommandRouting.route(.selectAll, isBrowserWindow: true,
                     responder: .fileArea, isKeyEquivalent: true) == .files)
        print("PASS: filtered Select All, stale menu state, window/pane targeting, text editing")

        // The File menu can compress files while a filter field has focus. The resulting
        // archive must be selected with file commands enabled, without an extra click.
        let compressionFolder = folder.appendingPathComponent("compression", isDirectory: true)
        let privateTrash = folder.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: compressionFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: privateTrash, withIntermediateDirectories: true)
        let source = compressionFolder.appendingPathComponent("source.txt")
        let sourceData = Data("Compression focus regression\n".utf8)
        try sourceData.write(to: source)
        let compressionModel = FileBrowserViewModel(initialPath: compressionFolder)
        try await wait { !compressionModel.isLoading && compressionModel.items.contains { $0.url == source } }
        context.bind(to: compressionModel)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        field.stringValue = "source"
        window.contentView?.addSubview(field)
        NSApp.activate(ignoringOtherApps: true)
        try await wait { NSApp.isActive }
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        precondition(NSApp.keyWindow === window)

        let realTrash = FileOperationEngine.trashItem
        FileOperationEngine.trashItem = { url in
            let destination = privateTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        defer { FileOperationEngine.trashItem = realTrash }

        for format in ArchiveCompressionFormat.allCases {
            compressionModel.searchText = "source"
            compressionModel.selectedItems = [compressionModel.items.first { $0.url == source }!]
            field.selectText(nil)
            MenuValidationState.shared.refresh()
            precondition(KeyboardResponderKind.classify(window.firstResponder) == .textEditing)
            precondition(MenuValidationState.shared.usesStandardEditing,
                         "Delete must be disabled while editing a filter")
            compressionModel.compressItems(format: format)
            precondition(KeyboardResponderKind.classify(window.firstResponder) == .fileArea,
                         "Compression must return keyboard focus to the file area")
            precondition(!MenuValidationState.shared.usesStandardEditing)
            precondition(field.stringValue == "source" && compressionModel.searchText == "source",
                         "Leaving filter focus must preserve the query")
            let archive = compressionFolder.appendingPathComponent("source.txt." + format.rawValue)
            try await wait {
                !FileOperationEngine.hasPendingOperations && compressionModel.primarySelectedItem?.url == archive
            }
            precondition(context.hasSelection && MenuValidationState.shared.commandContext === context)
            KeyboardManager.shared.performFileCommand(.moveToTrash, viewModel: nil, in: window)
            try await wait {
                !FileOperationEngine.hasPendingOperations && !FileManager.default.fileExists(atPath: archive.path)
            }
            precondition(FileManager.default.fileExists(atPath: privateTrash.appendingPathComponent(archive.lastPathComponent).path))
            let remainingSource = try Data(contentsOf: source)
            precondition(remainingSource == sourceData,
                         "Deleting the created archive must preserve the source")
        }
        print("PASS: ZIP / 7z from focused filter, archive selection, immediate Trash command, original preservation")
        withExtendedLifetime([context, model, staleModel, window, unregisteredWindow]) {}
    }

    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            precondition(Date() < deadline, "Timed out waiting for the production command")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

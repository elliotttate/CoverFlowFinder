import AppKit
import CryptoKit
import SevenZipKit

private struct TestFailure: Error, CustomStringConvertible { let description: String }

@main
struct ArchiveRegression {
    static var passed = 0
    static let manager = ArchiveManager.shared
    static let expected = Data("archive regression\n".utf8)

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw TestFailure(description: message) }
    }
    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw TestFailure(description: "Expected rejection: " + message)
    }
    static func pass(_ name: String) { passed += 1; print("PASS: \(name)"); fflush(stdout) }
    static func bytes(_ path: String, _ archive: URL) throws -> Data {
        try Data(contentsOf: manager.extractByPath(path, from: archive))
    }
    @MainActor
    static func wait(_ message: String, until ready: () -> Bool) async throws {
        for _ in 0..<500 {
            if ready() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestFailure(description: "Timed out: " + message)
    }

    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func fixture(_ name: String) -> URL { root.appendingPathComponent(name) }
        SevenZipArchiveBackend.shared.setPasswordProvider { _ in "secret" }
        defer { SevenZipArchiveBackend.shared.setPasswordProvider(nil) }

        for name in ["stored.zip", "deflate.zip", "bzip2.zip", "lzma.zip", "solid.7z", "deflate64.zip", "ppmd.zip", "links.tar"] {
            let url = fixture(name)
            let entries = try manager.readContents(of: url)
            let path = name == "solid.7z" || name == "deflate64.zip" || name == "ppmd.zip" ? "hello.txt" : "folder/hello.txt"
            try expect(try bytes(path, url) == expected, "Wrong data: \(name)")
            let native = name == "stored.zip" || name == "deflate.zip"
            try expect(entries.first(where: { $0.path == path })?.engineIndex == nil ? native : !native,
                       "ZIP fast path / engine selection: \(name)")
            let empty = path.replacingOccurrences(of: "hello.txt", with: "empty.txt")
            try expect(try bytes(empty, url).isEmpty, "Empty file: \(name)")
            if name != "links.tar" { try manager.testArchive(at: url, progress: Progress(totalUnitCount: 1)) }
            pass("browse, selected-file extraction and integrity: \(name)")
        }
        for name in ["password.7z", "headers.7z", "aes.zip", "zipcrypto.zip"] {
            let url = fixture(name)
            try expect(try bytes("hello.txt", url) == expected, "Encrypted extraction: \(name)")
            try manager.testArchive(at: url, progress: Progress(totalUnitCount: 1))
            pass("passwords: \(name)")
        }
        let rar4 = fixture("test_read_format_rar.rar")
        let rar5 = fixture("test_read_format_rar5_compressed.rar")
        try expect(try bytes("test.txt", rar4).count == 20, "RAR4 data")
        try expect(try bytes("testlink", rar4) == bytes("test.txt", rar4), "RAR4 symlink preview")
        try expect(try bytes("test.bin", rar5).count == 1200, "RAR5 compressed data")
        for url in [rar4, rar5] { try manager.testArchive(at: url, progress: Progress(totalUnitCount: 1)) }
        pass("RAR4, RAR5, compressed data, and RAR symlinks")

        SevenZipArchiveBackend.shared.setPasswordProvider { _ in "password" }
        for name in ["test_read_format_rar5_encrypted.rar", "test_read_format_rar5_encrypted_filenames.rar"] {
            try expect(try bytes("b.txt", fixture(name)) == Data("This is from b.txt".utf8), "RAR5 password: \(name)")
        }
        pass("RAR5 encrypted data and encrypted filenames")

        try FileManager.default.copyItem(at: fixture("aes.zip"), to: fixture("wrong-password.zip"))
        try FileManager.default.copyItem(at: fixture("headers.7z"), to: fixture("cancel-password.7z"))
        SevenZipArchiveBackend.shared.setPasswordProvider { _ in "incorrect" }
        try rejects("wrong password") { _ = try bytes("hello.txt", fixture("wrong-password.zip")) }
        SevenZipArchiveBackend.shared.setPasswordProvider({ _ in "secret" }, resetSessions: false)
        try expect(try bytes("hello.txt", fixture("wrong-password.zip")) == expected, "Recovery after wrong password")
        SevenZipArchiveBackend.shared.setPasswordProvider { _ in nil }
        do {
            _ = try manager.readContents(of: fixture("cancel-password.7z"), progress: Progress(totalUnitCount: 1))
            throw TestFailure(description: "Password cancellation must stop opening")
        } catch let error as NSError {
            try expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue,
                       "Password Cancel must be Cocoa userCancelled: \(error)")
        }
        pass("wrong-password recovery and password cancellation")
        var passwordAsked = false
        SevenZipArchiveBackend.shared.setPasswordProvider { _ in passwordAsked = true; return "secret" }
        try rejects("silent encrypted thumbnail") {
            _ = try manager.extractByPath("pixel.png", from: fixture("password.7z"), allowPasswordPrompt: false)
        }
        try expect(!passwordAsked, "Background thumbnails must not prompt for passwords")
        pass("background previews never prompt for passwords")

        let large = try Data(contentsOf: root.appendingPathComponent("input/big.bin"))
        for name in ["multi.7z.001", "multi.zip.001", "spanned.zip"] {
            try expect(try bytes("big.bin", fixture(name)) == large, "Multipart: \(name)")
            try manager.testArchive(at: fixture(name), progress: Progress(totalUnitCount: 1))
            pass("multipart: \(name)")
        }
        let multipartRar = fixture("test_rar_multivolume_single_file.part1.rar")
        try expect(try bytes("LibarchiveAddingTest.html", multipartRar).count == 20111, "Multipart RAR")
        try manager.testArchive(at: multipartRar, progress: Progress(totalUnitCount: 1))
        pass("multipart RAR")
        let before = manager.revision(for: multipartRar)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                             ofItemAtPath: fixture("test_rar_multivolume_single_file.part3.rar").path)
        try expect(before != manager.revision(for: multipartRar), "Later-volume cache invalidation")
        pass("cache revision includes later volumes")

        let nested = try manager.openNestedArchive(at: "folder/inner.7z", in: fixture("nested.zip"))
        try expect(try bytes("hello.txt", nested) == expected, "Nested ZIP -> 7z")
        try expect(manager.parentArchive(of: nested)?.memberPath == "folder/inner.7z", "Nested parent")
        try expect(manager.archiveChain(for: nested) == [fixture("nested.zip"), nested], "Nested breadcrumb chain")
        let encryptedNested = try manager.openNestedArchive(at: "encrypted.7z", in: fixture("nested.zip"))
        try expect(try bytes("hello.txt", encryptedNested) == expected, "Nested password")
        pass("nested archives, passwords, and parent navigation metadata")
        for name in ["bundle.tar.gz", "bundle.tar.xz", "bundle.tar.bz2"] {
            let url = fixture(name)
            let entries = try manager.readContents(of: url)
            let tar = try manager.openNestedArchive(at: entries.first!.path, in: url)
            try expect(try bytes("folder/hello.txt", tar) == expected, "Compressed TAR: \(name)")
            pass("compressed TAR: \(name)")
        }

        let links = fixture("links.tar")
        try expect(try bytes("folder/hard", links) == expected, "Hardlink must copy target data")
        try expect(try bytes("folder/relative", links) == expected, "Safe symlink preview")
        try rejects("escaping symlink") { _ = try bytes("folder/escape", links) }
        try rejects("escaping hardlink") { _ = try bytes("folder/brokenhard", links) }
        let linkCopy = try manager.extractItemForCopy(archivePath: "folder/", from: links)
        defer { manager.discardCopyExtraction( linkCopy.url) }
        try expect(try Data(contentsOf: linkCopy.url.appendingPathComponent("hard")) == expected, "Hardlink copy-out")
        var info = stat(); try expect(lstat(linkCopy.url.appendingPathComponent("hard").path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG,
                                     "Hardlink must be a regular safe copy")
        try expect(!linkCopy.failures.isEmpty, "Unsafe links must report failures")
        try expect(try Data(contentsOf: linkCopy.url.appendingPathComponent("escape")) == Data("../../outside".utf8), "Unsafe header link preserved as inert target text")
        pass("safe symlink and hardlink handling, partial extraction reporting")
        let unsafe = fixture("unsafe.zip")
        let entries = try manager.readContents(of: unsafe)
        try expect(!entries.contains { $0.path.hasPrefix("/") || $0.path.contains("..") || $0.path.contains("//") }, "Unsafe listing")
        let copy = try manager.extractItemForCopy(archivePath: "folder/", from: unsafe)
        defer { manager.discardCopyExtraction( copy.url) }
        try expect(try Data(contentsOf: copy.url.appendingPathComponent("safe.txt")) == expected, "Safe sibling must copy")
        try expect(copy.failures.count >= 2, "Collisions and escaping links must be reported")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path), "No path escape")
        pass("traversal, case collisions, and symlink-parent attacks")
        for archive in [fixture("stored.zip"), fixture("solid.7z")] {
            let path = archive.pathExtension == "zip" ? "folder/hello.txt" : "hello.txt"
            try rejects("per-entry limit") { _ = try manager.extractItemForCopy(archivePath: path, from: archive,
                    limits: ArchiveExtractionLimits(maxEntryBytes: 5, maxTotalBytes: 100)) }
            try rejects("total limit on a single file") { _ = try manager.extractItemForCopy(archivePath: path, from: archive,
                    limits: ArchiveExtractionLimits(maxEntryBytes: 100, maxTotalBytes: 5)) }
            let progress = Progress(totalUnitCount: 1); progress.cancel()
            try rejects("cancelled extraction") { _ = try manager.extractItemForCopy(archivePath: path, from: archive, progress: progress) }
        }
        try rejects("huge declared size") { _ = try bytes("folder/hello.txt", fixture("huge.zip")) }
        pass("entry limits, aggregate limits, malicious declared size, and cancellation")
        try rejects("CRC failure on stream") { _ = try bytes("folder/hello.txt", fixture("corrupt.zip")) }
        try rejects("CRC failure on integrity test") { try manager.testArchive(at: fixture("corrupt.zip"), progress: Progress(totalUnitCount: 1)) }
        try expect(manager.cachedPreviewURL(for: "folder/hello.txt", in: fixture("corrupt.zip")) == nil, "Failed extraction must not publish preview")
        let partial = try manager.extractItemForCopy(archivePath: "folder/", from: fixture("corrupt.zip"))
        try expect(!partial.failures.isEmpty && !FileManager.default.fileExists(atPath: partial.url.appendingPathComponent("hello.txt").path), "Failed member must be reported and removed")
        manager.discardCopyExtraction(partial.url)
        pass("engine per-item CRC errors and atomic cleanup")
        try rejects("open succeeded with damaged headers") { try manager.testArchive(at: fixture("bad-headers.zip"), progress: Progress(totalUnitCount: 1)) }
        pass("integrity testing rejects header errors even when opening succeeds")
        let rawArchive = try SZArchiveOpener.openArchive(atPath: fixture("multi.7z.001").path, formatHint: nil, passwordDelegate: nil, progress: nil)
        let rawEntries = try rawArchive.streamEntries(limit: 250_000, progress: nil)
        let rawIndex = (rawEntries.first!["index"] as! NSNumber).uint32Value
        try rejects("stream output cap") {
            try rawArchive.streamItem(at: rawIndex, maxBytes: 1, memoryLimit: 512 << 20, progress: nil) { _ in true }
        }
        var sawChunk = false
        try rejects("consumer cancels during streaming") {
            try rawArchive.streamItem(at: rawIndex, maxBytes: 1 << 20, memoryLimit: 512 << 20, progress: nil) { _ in sawChunk = true; return false }
        }
        try expect(sawChunk, "Streaming cancellation must happen during decoder output")
        let cancelledTest = Progress(totalUnitCount: 1); cancelledTest.cancel()
        try rejects("cancel integrity test") { try manager.testArchive(at: fixture("multi.7z.001"), progress: cancelledTest) }
        pass("bridge byte cap, mid-stream consumer cancellation, and integrity cancellation")

        let quarantine = Data("0081;00000000;ArchiveRegression;".utf8)
        let quarantineSet = quarantine.withUnsafeBytes { setxattr(fixture("nested.zip").path, "com.apple.quarantine", $0.baseAddress, quarantine.count, 0, 0) }
        try expect(quarantineSet == 0, "Fixture quarantine setup")
        // Invalidate the parent so a previously unquarantined cache entry cannot hide this check.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(8)], ofItemAtPath: fixture("nested.zip").path)
        let preview = try manager.extractByPath("hello.txt", from: nested)
        let valueSize = getxattr(preview.path, "com.apple.quarantine", nil, 0, 0, 0)
        try expect(valueSize == quarantine.count, "Nested source quarantine propagation")
        var previewInfo = stat(); _ = stat(preview.path, &previewInfo)
        try expect(previewInfo.st_mode & 0o222 == 0, "Preview must be read-only")
        let leased = try manager.extractItemForCopy(archivePath: "hello.txt", from: nested)
        try expect(getxattr(leased.url.path, "com.apple.quarantine", nil, 0, 0, 0) == quarantine.count, "Copy-out quarantine")
        let lease = manager.leaseCopyExtractions( [leased.url]); lease?.release()
        manager.discardCopyExtraction( leased.url)
        pass("read-only previews, nested quarantine, and copy leases")

        let model = FileBrowserViewModel(initialPath: root)
        model.enterArchive(at: fixture("nested.zip"))
        try await wait("open outer archive") { model.isInsideArchive && model.currentArchiveURL == fixture("nested.zip") && !model.isLoading }
        model.navigateInArchive(to: "folder")
        try await wait("list parent member") { model.items.contains { $0.name == "inner.7z" } && !model.isLoading }
        let member = model.items.first { $0.name == "inner.7z" }!
        try expect(member.isBrowsableArchive && model.canAddItemsToCurrentLocation == false, "Nested file candidate / archive write protection")
        model.openAsArchive(member)
        try await wait("open nested archive") { model.currentArchiveURL == nested && !model.isLoading }
        model.navigateUp()
        try await wait("return to parent") { model.currentArchiveURL == fixture("nested.zip") && model.currentArchivePath == "folder" && !model.isLoading }
        try expect(model.selectedItems.contains { $0.name == "inner.7z" }, "Up must select nested archive")
        model.goBack()
        try await wait("nested history") { model.currentArchiveURL == nested && !model.isLoading }
        let image = model.items.first { $0.name == "pixel.png" }!
        var previewResult: URL?
        model.previewURL(for: image) { previewResult = $0 }
        try await wait("Quick Look member extraction") { previewResult != nil }
        try expect(try Data(contentsOf: previewResult!) == Data(contentsOf: root.appendingPathComponent("input/pixel.png")), "Quick Look receives selected original image")
        // Updating a selection with Quick Look closed must not extract or prompt.
        let unprepared = model.items.first { $0.name == "empty.txt" }!
        try expect(manager.cachedPreviewURL(for: "empty.txt", in: nested) == nil, "Unprepared preview fixture")
        model.updateQuickLookPreview(for: unprepared)
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(manager.cachedPreviewURL(for: "empty.txt", in: nested) == nil, "Closed Quick Look must remain idle")
        pass("production navigation, Up, Back, selection, and Quick Look")

        let thumbnails = ThumbnailCacheManager(diskCacheDirectory: root.appendingPathComponent("thumb-cache"), legacyDiskCacheDirectories: [])
        let owner = ThumbnailRequestOwner()
        var thumbnailsDone = 0
        var thumbnailsLoaded = 0
        for _ in 0..<2 {
            thumbnails.requestThumbnail(for: image, maxPixelSize: 64, owner: owner) { result in
                thumbnailsDone += 1
                if case .loaded = result { thumbnailsLoaded += 1 }
            }
        }
        try await wait("archive thumbnails") { thumbnailsDone == 2 }
        try expect(thumbnailsLoaded == 2 && thumbnails.cachedThumbnail(for: image, maxPixelSize: 64) != nil, "Deduplicated archive thumbnails")
        let ownerToCancel = ThumbnailRequestOwner()
        var didCancel = false
        thumbnails.requestThumbnail(for: image, maxPixelSize: 128, owner: ownerToCancel) { result in
            if case .cancelled = result { didCancel = true }
        }
        thumbnails.cancelRequests(for: ownerToCancel)
        try await wait("thumbnail cancellation") { didCancel }
        pass("archive thumbnails, deduplication, caching, and owner cancellation")

        SevenZipArchiveBackend.shared.setPasswordProvider { _ in "secret" }
        for (name, path) in [("stored.zip", "folder/hello.txt"), ("solid.7z", "hello.txt"), ("aes.zip", "hello.txt"), ("bundle.tar.gz", "folder/hello.txt")] {
            let whole = try manager.extractArchiveForCopy(from: fixture(name))
            try expect(try Data(contentsOf: whole.url.appendingPathComponent(path)) == expected, "Whole archive: \(name)")
            manager.discardCopyExtraction(whole.url)
        }
        let empty = try manager.extractArchiveForCopy(from: fixture("empty.zip"))
        try expect(try FileManager.default.contentsOfDirectory(atPath: empty.url.path).isEmpty, "Empty archive must produce an empty folder")
        manager.discardCopyExtraction(empty.url)
        try rejects("whole archive size limit") {
            _ = try manager.extractArchiveForCopy(from: fixture("stored.zip"), limits: ArchiveExtractionLimits(maxEntryBytes: 100, maxTotalBytes: 5))
        }
        pass("whole archives, encrypted ZIP, compressed TAR contents, empty archives, and limits")

        for (name, stem) in [("bundle.tar.gz", "bundle"), ("bundle.tgz", "bundle"), ("multi.7z.001", "multi"), ("example.part1.rar", "example"), ("photos.v2.zip", "photos.v2")] {
            try expect(ArchiveManager.extractionFolderName(for: fixture(name)) == stem, "Extraction folder name: \(name)")
        }
        let first = FileItem(url: fixture("first.zip"))
        let second = FileItem(url: fixture("second.zip"))
        let firstBytes = Data("first archive\n".utf8), secondBytes = Data("second archive\n".utf8)
        let firstArchiveBytes = try Data(contentsOf: first.url)
        let secondArchiveBytes = try Data(contentsOf: second.url)
        try expect(ArchiveExtractionMode.eligibleItems([first, second]).count == 2, "Batch archive selection")
        try expect(ArchiveExtractionMode.eligibleItems([first, image]).isEmpty, "Mixed selection must not extract unrelated items")
        try expect(ArchiveExtractionMode.chosenFolder.title(for: [first, second]) == "Extract All to One Folder…", "Batch destination label")
        try expect(ArchiveExtractionMode.separateFolders.title(for: [first]) == "Extract to “first” Folder", "Single folder label")
        pass("folder names and single / multiple selection commands")

        func outputFolder(_ name: String) throws -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return folder
        }
        let separate = try outputFolder("separate-output")
        let separateJournal = FileOperationJournal()
        let separateResult = ArchiveExtractionEngine.extract([first, second], mode: .separateFolders, destination: separate,
                                                              journal: separateJournal, progress: Progress(totalUnitCount: 1))
        try expect(separateResult.failures.isEmpty && !separateResult.wasCancelled, "Separate-folder batch must succeed")
        try expect(try Data(contentsOf: separate.appendingPathComponent("first/hello.txt")) == firstBytes, "First separate folder")
        try expect(try Data(contentsOf: separate.appendingPathComponent("second/hello.txt")) == secondBytes, "Second separate folder")
        try Data("keep me".utf8).write(to: separate.appendingPathComponent("first/marker.txt"))
        let again = ArchiveExtractionEngine.extract([first], mode: .separateFolders, destination: separate,
                                                    journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(again.failures.isEmpty, "Repeated extraction must keep both folders")
        try expect(try Data(contentsOf: separate.appendingPathComponent("first 2/hello.txt")) == firstBytes, "Folder collision suffix")
        try expect(try Data(contentsOf: separate.appendingPathComponent("first/marker.txt")) == Data("keep me".utf8), "Existing folder must stay intact")
        pass("batch extraction to separate folders and repeat-name collisions")

        let shared = try outputFolder("shared-output")
        try Data("existing file".utf8).write(to: shared.appendingPathComponent("hello.txt"))
        let sharedJournal = FileOperationJournal()
        let sharedResult = ArchiveExtractionEngine.extract([first, second], mode: .chosenFolder, destination: shared,
                                                            journal: sharedJournal, progress: Progress(totalUnitCount: 1))
        try expect(sharedResult.failures.isEmpty && !sharedResult.wasCancelled, "Shared-folder batch must succeed")
        try expect(try Data(contentsOf: shared.appendingPathComponent("hello.txt")) == Data("existing file".utf8), "Existing shared file stays intact")
        try expect(try Data(contentsOf: shared.appendingPathComponent("hello 2.txt")) == firstBytes, "First shared archive must keep both")
        try expect(try Data(contentsOf: shared.appendingPathComponent("hello 3.txt")) == secondBytes, "Second shared archive must keep both")
        try expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).count == 3, "Shared output must not wrap archives in individual folders")
        pass("all archives to one folder, preserved existing files, and inter-archive collisions")

        let here = try outputFolder("here-output")
        let hereArchive = here.appendingPathComponent("first.zip")
        try FileManager.default.copyItem(at: first.url, to: hereArchive)
        let originalArchive = try Data(contentsOf: hereArchive)
        let hereResult = ArchiveExtractionEngine.extract([FileItem(url: hereArchive)], mode: .here,
                                                          journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(try hereResult.failures.isEmpty && Data(contentsOf: here.appendingPathComponent("hello.txt")) == firstBytes, "Extract Here uses the source's parent")
        try expect(try Data(contentsOf: hereArchive) == originalArchive, "Extraction must leave the source archive unchanged")
        let nestedOutput = try outputFolder("nested-output")
        let nestedResult = ArchiveExtractionEngine.extract([member], mode: .separateFolders, destination: nestedOutput,
                                                            journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(try nestedResult.failures.isEmpty && Data(contentsOf: nestedOutput.appendingPathComponent("inner/hello.txt")) == expected, "Extract a selected nested archive")
        pass("Extract Here, unchanged source archives, and nested archive extraction")

        let privateTrash = try outputFolder("undo-trash")
        let realTrash = FileOperationEngine.trashItem
        FileOperationEngine.trashItem = { url in
            let destination = privateTrash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        defer { FileOperationEngine.trashItem = realTrash }
        let undone = FileOperationJournal()
        let undoResult = FileOperationEngine.reverse(sharedJournal.steps, journal: undone)
        try expect(try undoResult.failures.isEmpty && FileManager.default.contentsOfDirectory(atPath: shared.path) == ["hello.txt"], "Undo removes only extracted output")
        let redoResult = FileOperationEngine.reverse(undone.steps, journal: FileOperationJournal())
        try expect(try redoResult.failures.isEmpty && Data(contentsOf: shared.appendingPathComponent("hello 2.txt")) == firstBytes, "Redo restores extracted output after staging cleanup")
        try expect(try Data(contentsOf: first.url) == firstArchiveBytes && Data(contentsOf: second.url) == secondArchiveBytes, "Undo / Redo must not alter source archives")
        pass("extraction journal Undo / Redo without source or staging dependence")

        let cancelledOutput = try outputFolder("cancelled-output")
        let cancelled = Progress(totalUnitCount: 1); cancelled.cancel()
        let cancelledResult = ArchiveExtractionEngine.extract([first, second], mode: .separateFolders, destination: cancelledOutput,
                                                               journal: FileOperationJournal(), progress: cancelled)
        try expect(try cancelledResult.wasCancelled && FileManager.default.contentsOfDirectory(atPath: cancelledOutput.path).isEmpty, "Cancelled extraction leaves no output")
        let failedResult = ArchiveExtractionEngine.extract([FileItem(url: fixture("missing.zip")), second], mode: .separateFolders,
                                                            destination: cancelledOutput, journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(try failedResult.failures.count == 1 && Data(contentsOf: cancelledOutput.appendingPathComponent("second/hello.txt")) == secondBytes, "A failed archive must not prevent later extraction")
        pass("batch cancellation and continuation after an archive fails")

        let commandOutput = try outputFolder("command-output")
        let extractionModel = FileBrowserViewModel(initialPath: commandOutput)
        extractionModel.items = [first, second]
        extractionModel.selectedItems = [first, second]
        try expect(extractionModel.selectedArchivesForExtraction.count == 2 && extractionModel.archivesForExtraction(clicked: first).count == 2,
                   "Context menu on a selected archive must target the whole selection")
        extractionModel.extractArchives([first, second], mode: .separateFolders, destination: commandOutput)
        extractionModel.selectedItems = []
        try await wait("batch extraction command") {
            !FileOperationEngine.hasPendingOperations && FileManager.default.fileExists(atPath: commandOutput.appendingPathComponent("second/hello.txt").path)
        }
        try expect(try Data(contentsOf: commandOutput.appendingPathComponent("first/hello.txt")) == firstBytes, "Command must retain its original targets")
        pass("production batch command and frozen multi-selection targets")
        let compressionSource = try outputFolder("compression-source")
        let compressionOutput = try outputFolder("compression-output")
        let reportURL = compressionSource.appendingPathComponent("résumé [?]*.txt")
        let reportData = Data(String(repeating: "compression payload\n", count: 1000).utf8)
        try reportData.write(to: reportURL)
        let treeURL = compressionSource.appendingPathComponent("Project.folder", isDirectory: true)
        try FileManager.default.createDirectory(at: treeURL.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        try expected.write(to: treeURL.appendingPathComponent("nested/hello.txt"))
        try FileManager.default.createSymbolicLink(atPath: treeURL.appendingPathComponent("link.txt").path, withDestinationPath: "nested/hello.txt")
        try FileManager.default.createSymbolicLink(atPath: treeURL.appendingPathComponent("dangling.txt").path, withDestinationPath: "missing.txt")
        let report = FileItem(url: reportURL), tree = FileItem(url: treeURL)
        var compressionJournal: FileOperationJournal?
        for format in ArchiveCompressionFormat.allCases {
            let journal = FileOperationJournal()
            let result = ArchiveCompressionEngine.compress([report, tree], format: format, destination: compressionOutput,
                                                             journal: journal, progress: Progress(totalUnitCount: 1))
            try expect(result.failures.isEmpty && !result.wasCancelled, "Create \(format): \(result.failures.map { $0.error.localizedDescription })")
            let archive = compressionOutput.appendingPathComponent("Archive." + format.rawValue)
            let entries = try manager.readContents(of: archive)
            try expect(entries.contains { $0.path == "Project.folder/nested/empty/" }, "Empty folders retained: \(format)")
            try expect(!entries.contains { $0.path.hasPrefix("/") || $0.path.contains("compression-source") }, "Only selected roots, with relative paths: \(format)")
            try expect(try bytes(report.name, archive) == reportData && bytes("Project.folder/nested/hello.txt", archive) == expected, "File and recursive folder round trip: \(format)")
            try expect(entries.contains { $0.path == "Project.folder/dangling.txt" && $0.uncompressedSize == UInt64("missing.txt".utf8.count) }, "Dangling link retained without following: \(format)")
            let copied = try manager.extractArchiveForCopy(from: archive)
            try expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.url.appendingPathComponent("Project.folder/link.txt").path) == "nested/hello.txt", "Relative symbolic link round trip: \(format)")
            manager.discardCopyExtraction(copied.url)
            try manager.testArchive(at: archive, progress: Progress(totalUnitCount: 1))
            if format == .zip { compressionJournal = journal }
            pass("\(format.rawValue) creation: Unicode / literal names, recursive and empty folders, links, contents and integrity")
        }
        try expect(try Data(contentsOf: reportURL) == reportData && Data(contentsOf: treeURL.appendingPathComponent("nested/hello.txt")) == expected, "Compression preserves originals")
        let existingZip = try Data(contentsOf: compressionOutput.appendingPathComponent("Archive.zip"))
        let repeated = ArchiveCompressionEngine.compress([report, tree], format: .zip, destination: compressionOutput,
                                                          journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(repeated.failures.isEmpty && FileManager.default.fileExists(atPath: compressionOutput.appendingPathComponent("Archive 2.zip").path), "Existing archive receives a keep-both suffix")
        try expect(try Data(contentsOf: compressionOutput.appendingPathComponent("Archive.zip")) == existingZip, "Existing archive is never updated or overwritten")
        for (item, name) in [(report, report.name + ".zip"), (tree, "Project.folder.zip")] {
            let result = ArchiveCompressionEngine.compress([item], format: .zip, destination: compressionOutput,
                                                            journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
            try expect(result.failures.isEmpty && FileManager.default.fileExists(atPath: compressionOutput.appendingPathComponent(name).path), "Single-item archive name")
        }
        pass("single-file and folder archive names, preserved originals and numbered archive collisions")

        let compressionUndo = FileOperationJournal()
        let compressionUndoResult = FileOperationEngine.reverse(compressionJournal!.steps, journal: compressionUndo)
        try expect(compressionUndoResult.failures.isEmpty && !FileManager.default.fileExists(atPath: compressionOutput.appendingPathComponent("Archive.zip").path), "Undo removes only the new archive")
        let compressionRedoResult = FileOperationEngine.reverse(compressionUndo.steps, journal: FileOperationJournal())
        try expect(try compressionRedoResult.failures.isEmpty && Data(contentsOf: compressionOutput.appendingPathComponent("Archive.zip")) == existingZip, "Redo restores the complete archive after staging cleanup")
        try expect(try Data(contentsOf: reportURL) == reportData && Data(contentsOf: treeURL.appendingPathComponent("nested/hello.txt")) == expected, "Compression Undo / Redo preserves sources")
        pass("compression Undo / Redo independent of staging and unchanged sources")

        let rejectedOutput = try outputFolder("compression-rejected")
        let cancelledCompression = Progress(totalUnitCount: 1); cancelledCompression.cancel()
        let stopped = ArchiveCompressionEngine.compress([report], format: .sevenZip, destination: rejectedOutput,
                                                         journal: FileOperationJournal(), progress: cancelledCompression)
        try expect(stopped.wasCancelled, "Compression cancellation")
        let missingCompression = ArchiveCompressionEngine.compress([report, FileItem(url: compressionSource.appendingPathComponent("missing.txt"))],
                                                                   format: .zip, destination: rejectedOutput,
                                                                   journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(missingCompression.failures.count == 1, "Missing source must fail, rather than produce an incomplete archive")
        let duplicateRoot = try outputFolder("compression-duplicate")
        try expected.write(to: duplicateRoot.appendingPathComponent(report.name))
        let duplicateName = ArchiveCompressionEngine.compress([report, FileItem(url: duplicateRoot.appendingPathComponent(report.name))],
                                                               format: .zip, destination: rejectedOutput,
                                                               journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(!duplicateName.failures.isEmpty, "Ambiguous top-level names must not silently lose files")
        let selfIncluded = ArchiveCompressionEngine.compress([tree], format: .zip, destination: treeURL,
                                                              journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(!selfIncluded.failures.isEmpty, "Staging must never be included in a selected source folder")
        try expect(try FileManager.default.contentsOfDirectory(atPath: rejectedOutput.path).isEmpty, "Rejected operations leave no archive or staging")
        pass("compression cancellation, missing sources, duplicate roots and self-inclusion protection")

        let unreadableURL = treeURL.appendingPathComponent("unreadable.txt")
        try expected.write(to: unreadableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)
        let unreadableResult = ArchiveCompressionEngine.compress([tree], format: .zip, destination: rejectedOutput,
                                                                 journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path)
        try FileManager.default.removeItem(at: unreadableURL)
        try expect(!unreadableResult.failures.isEmpty, "Unreadable nested source must reject the archive, rather than skip data")
        try expect(try FileManager.default.contentsOfDirectory(atPath: rejectedOutput.path).isEmpty, "Read failure must remove temporary archive and staging")
        pass("unreadable nested files reject incomplete archives and clean staging")

        let largeURL = compressionSource.appendingPathComponent("large.bin")
        try Data(repeating: 0x5a, count: 32 << 20).write(to: largeURL)
        let runningCancellation = Progress(totalUnitCount: 1)
        let cancelObserver = DispatchGroup()
        cancelObserver.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { cancelObserver.leave() }
            for _ in 0..<5000 {
                let stages = (try? FileManager.default.contentsOfDirectory(at: rejectedOutput, includingPropertiesForKeys: nil)) ?? []
                let writingArchive = stages.filter { $0.lastPathComponent.hasPrefix(".FlowFinder-compress-") }.contains { stage in
                    ((try? FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.fileSizeKey])) ?? []).contains {
                        ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
                    }
                }
                if writingArchive {
                    runningCancellation.cancel()
                    return
                }
                usleep(1000)
            }
        }
        let runningCancelled = ArchiveCompressionEngine.compress([FileItem(url: largeURL)], format: .sevenZip, destination: rejectedOutput,
                                                                 journal: FileOperationJournal(), progress: runningCancellation)
        cancelObserver.wait()
        try expect(runningCancelled.wasCancelled && runningCancelled.failures.isEmpty, "Cancellation during archive staging")
        try expect(try FileManager.default.contentsOfDirectory(atPath: rejectedOutput.path).isEmpty, "Cancelled staged compression removes all output")
        try expect(try Data(contentsOf: largeURL).count == 32 << 20, "Cancelled compression preserves the source")
        pass("in-progress compression cancellation cleans staging and preserves originals")

        let overlapOutput = try outputFolder("compression-overlap")
        let overlap = ArchiveCompressionEngine.compress([tree, FileItem(url: treeURL.appendingPathComponent("nested/hello.txt"))],
                                                         format: .sevenZip, destination: overlapOutput,
                                                         journal: FileOperationJournal(), progress: Progress(totalUnitCount: 1))
        try expect(overlap.failures.isEmpty, "A selected child is included by its selected parent")
        let overlapEntries = try manager.readContents(of: overlapOutput.appendingPathComponent("Archive.7z"))
        try expect(overlapEntries.filter { $0.path.hasSuffix("hello.txt") }.count == 1, "Overlapping selections must not duplicate a child")
        pass("overlapping folder / child compression selection")

        let compressionCommandOutput = try outputFolder("compression-command")
        let compressionModel = FileBrowserViewModel(initialPath: compressionCommandOutput)
        compressionModel.items = [report, tree]
        compressionModel.selectedItems = [report, tree]
        try expect(compressionModel.selectedItemsForCompression.count == 2 && compressionModel.itemsForCompression(clicked: report).count == 2, "Compression context command acts on all selected items")
        try expect(compressionModel.itemsForCompression([image]).isEmpty, "Archive virtual members must not be compressed as physical paths")
        compressionModel.compressItems(format: .sevenZip)
        compressionModel.selectedItems = []
        try await wait("production compression command") {
            !FileOperationEngine.hasPendingOperations && FileManager.default.fileExists(atPath: compressionCommandOutput.appendingPathComponent("Archive.7z").path)
        }
        try expect(try bytes(report.name, compressionCommandOutput.appendingPathComponent("Archive.7z")) == reportData, "Compression command retains its original multi-selection")
        pass("production ZIP / 7z commands with frozen multi-selection targets")
        print("PASS: \(passed) archive regression groups")
    }
}

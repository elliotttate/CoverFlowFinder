# Local regressions

Run from the repository root:

```sh
Tests/run-archive-regression.sh
Tests/run-selection-command-regression.sh
```

The scripts build the checked-in SevenZipKit project, then compile the production Swift sources with a command-line test entry point. They require Xcode and `rg`; archive fixture generation also requires `python3` and `7zz` (`brew install sevenzip`). The shipping app does not require an external archive utility. Set `DEVELOPER_DIR` for a particular Xcode installation and optionally `CFF_ARCHIVE_BUILD_DIR` to reuse an existing Xcode derived-data directory.

The archive regression uses generated fixtures plus the attributed RAR fixtures in `ArchiveFixtures`. It exercises native and engine ZIP codecs, solid 7z, TAR and compressed TAR, RAR4/5, encrypted data and headers, multipart 7z/ZIP/RAR, nested navigation and passwords, partial copy-out failures, links, traversal and collision attacks, size caps, cancellation, corruption, quarantine, read-only preview files, copy leases, production navigation/Quick Look, and deduplicated cancellable thumbnails. Whole-archive tests cover single and batch commands, separate folders and shared output, preserved existing files, unchanged source archives, cancellation, partial batch failures, and Undo / Redo after staging cleanup.

Creation tests cover ZIP and 7z round trips, literal wildcard / Unicode names, recursive and empty folders, stored links, single and multiple selections, numbered existing-archive collisions, overlapping selections, rejection and cancellation cleanup, original-file preservation, Undo / Redo, and frozen production command targets.

The command regression protects existing selection and menu routing behavior, plus compression from a focused filter field followed by an immediate Trash command for both ZIP and 7z. It briefly opens a private test window and redirects Trash operations to a temporary directory. Neither script launches the shipping SwiftUI app, publishes a release, or manipulates user files; generated fixture and thumbnail directories are private temporary directories.

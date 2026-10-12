# CoverFlowFinder bridge changes (2026-10-11)

- Add `SZArchiveStreams.h/.mm`: enumerate raw handler indices and stream selected members into a caller-owned byte sink. Output is bounded, decoder memory requests are limited, cancellation is honored, and every per-item result is checked. No extraction path, file, symlink, or hard link is created by this API. Add archive testing through the same checked callback, and reject archive-level header error flags even when opening succeeded.
- Apply decoder `memuse`/`memx` properties before extraction and testing, in addition to the memory-request callback. Clear cached extraction passwords after any failed encrypted operation, including formats that report a CRC/DataError for an incorrect password.
- Limit 7z stored and decoded metadata headers to 128 MiB, and header decoder memory to 512 MiB (`CPP/7zip/Archive/7z/7zIn.cpp`).
- Expose the raw `IInArchive` internally from `SZArchive`; its lifetime remains owned by the archive and its serial queue.
- Fix `SZTempOpen`'s disk fallback to reject per-item failures even when the extraction returned a non-nil summary.
- Use a standalone engine/bridge project and macOS 15 deployment target. The project is built and embedded as a dynamic framework by CoverFlowFinder.

All bridge modifications retain LGPL 2.1-or-later licensing. Original sources and upstream Mac compatibility patches are included.

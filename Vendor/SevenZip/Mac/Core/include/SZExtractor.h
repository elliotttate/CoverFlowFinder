// SZExtractor.h -- the ExtractGUI equivalent: extract or test one or many archives into one
// output directory through the engine's own driver, `Extract()` in
// CPP/7zip/UI/Common/Extract.cpp. That is the function 7zG runs (GUI/ExtractGUI.cpp), so
// behaviour (path modes, overwrite modes, duplicate-root elimination, multi-volume handling,
// open-error texts, the test statistics) is the Windows product's behaviour, not a
// reimplementation.
//
// Parity: 01-fm-feature-inventory.md 8.1-8.4, 01b-fm-dialogs-settings.md 4.25,
// 02-engine-api.md 2.3/2.5.2, 03-shell-integration-inventory.md 1.6.
//
// THREADING: +extractArchives... BLOCKS for the whole operation and must run off the main
// thread. While it blocks, the id<SZProgressDelegate> is called on that worker thread
// (see SZProgressDelegate.h and ai/api/opsinfra.md). Drive it from Swift with
// OperationRunner, which is itself the delegate.

#ifndef SZ_EXTRACTOR_H
#define SZ_EXTRACTOR_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>
#import <SevenZipKit/SZHasher.h>
#import <SevenZipKit/SZProgressDelegate.h>
#import <SevenZipKit/SZTypes.h>

NS_ASSUME_NONNULL_BEGIN

/// NExtractOutDirMode (UI/Common/Extract.h:17-24): how the archive name enters the output path.
typedef NS_ENUM(NSInteger, SZExtractOutDirMode) {
    /// Everything lands in `outputDirectory` as given (7zG `x -o<dir>`).
    SZExtractOutDirModeDirect = 0,
    /// `<outputDirectory>/<archive default name>/` per archive.
    SZExtractOutDirModeAddArchiveName,
    /// `*` inside `outputDirectory` is replaced by each archive's default name. This is the
    /// engine default and what 7zFM's "Extract" on several archives passes (`-o"<dir>/*/"`).
    SZExtractOutDirModeReplaceAsterisk
};

/// NExtract::NZoneIdMode (UI/Common/ExtractMode.h:32-40). On macOS the Zone.Identifier
/// alternate stream is the `com.apple.quarantine` extended attribute (01 §9 #23).
typedef NS_ENUM(NSInteger, SZZoneIDMode) {
    SZZoneIDModeNone = 0,
    SZZoneIDModeAll,
    SZZoneIDModeOffice
};

// ---------------------------------------------------------------------------

/// Everything the Extract dialog and the command line (`-o -spe -snl -snh -sni -snz -spd -spf`)
/// can set. Defaults match CExtractOptionsBase / CExtractOptions.
@interface SZExtractOptions : NSObject <NSCopying>

/// `-o`: the output directory. Empty means the process's current directory, like 7zG.
/// Normalised (and `*`-substituted per `outDirMode`) by the engine.
@property (nonatomic, copy) NSString *outputDirectory;
/// The Extract dialog's "Path mode" combo (IDC_EXTRACT_PATH_MODE 102).
@property (nonatomic) SZExtractPathMode pathMode;
/// PathMode_Force: the value came from the settings, not from the caller.
@property (nonatomic) BOOL pathModeForced;
/// The Extract dialog's "Overwrite mode" combo (IDC_EXTRACT_OVERWRITE_MODE 103).
@property (nonatomic) SZOverwriteMode overwriteMode;
@property (nonatomic) BOOL overwriteModeForced;
@property (nonatomic) SZExtractOutDirMode outDirMode;
/// `-spe`, IDX_EXTRACT_ELIM_DUP 3430, a CBoolPair: nil = not defined (engine default false;
/// the FM's own default is true, see Settings.extractElimDupValue).
@property (nonatomic, copy, nullable) NSNumber *eliminateDuplicateRoot;
/// `-snz`: quarantine propagation.
@property (nonatomic) SZZoneIDMode zoneIDMode;
/// Test only: nothing is written (7zG `t`, "Test archive").
@property (nonatomic) BOOL testMode;
/// `-spd` / `-spf` counterparts of CExtractOptionsBase::ExcludeDirItems / ExcludeFileItems.
@property (nonatomic) BOOL excludeDirectoryItems;
@property (nonatomic) BOOL excludeFileItems;
/// `-p`: pre-seeded password; the delegate is not asked while this is set.
@property (nonatomic, copy, nullable) NSString *password;
/// `-t<type>`: handler name, "*" (any handler) or "#" (parser mode). nil = detect.
@property (nonatomic, copy, nullable) NSString *formatHint;
/// `-sni` "Restore file security" (IDX_EXTRACT_NT_SECUR 3431). Accepted and stored for
/// parity; NT security descriptors do not exist on macOS (01 §9 #7), so the engine ignores it.
@property (nonatomic, copy, nullable) NSNumber *restoreFileSecurity;
/// `-snl` / `-snh` / `-sns`: CExtractNtOptions SymLinks / HardLinks / AltStreams bool pairs.
/// SymLinks defaults to true, the other two to false, exactly like CExtractNtOptions.
@property (nonatomic, copy, nullable) NSNumber *extractSymbolicLinks;
@property (nonatomic, copy, nullable) NSNumber *extractHardLinks;
@property (nonatomic, copy, nullable) NSNumber *extractAlternateStreams;
@property (nonatomic) BOOL preAllocateOutputFile;
@property (nonatomic) BOOL preserveAccessTime;
/// CExtractNtOptions::MemLimit; UINT64_MAX (the default) means "no limit", which is what
/// Extraction.MemLimit == -1 means (01b §4.12).
@property (nonatomic) uint64_t memoryLimit;

/// `-scrc<M>`: checksums of the *extracted* data, computed while extracting or testing
/// (03-shell-integration-inventory.md §2.6; the `IHashCalc` argument of `Extract()`, which is a
/// `CHashBundle`). Engine method names as `SZHasher.availableMethods` reports them, or `@"*"` for
/// every method. **Empty — the default — means off**, so nothing changes for a caller that does
/// not ask. The digests appear in `SZExtractResult.hashResults`.
@property (nonatomic, copy) NSArray<NSString *> *hashMethods;

@end

// ---------------------------------------------------------------------------

/// CDecompressStat (UI/Common/Extract.h:85-99): what the run processed. These are the numbers
/// the Windows test summary prints.
@interface SZExtractStatistics : NSObject
@property (nonatomic, readonly) uint64_t archiveCount;
@property (nonatomic, readonly) uint64_t unpackSize;
@property (nonatomic, readonly) uint64_t alternateStreamsUnpackSize;
@property (nonatomic, readonly) uint64_t packSize;
@property (nonatomic, readonly) uint64_t folderCount;
@property (nonatomic, readonly) uint64_t fileCount;
@property (nonatomic, readonly) uint64_t alternateStreamCount;
@end

/// The outcome of one `Extract()` run.
@interface SZExtractResult : NSObject

@property (nonatomic, readonly) SZExtractStatistics *statistics;
/// Items whose SetOperationResult arrived (the progress dialog's "Files" counter).
@property (nonatomic, readonly) uint64_t filesProcessed;
/// Messages + per-item failures, i.e. the "Errors" counter (CExtractCallbackImp::IsOK() is
/// `errorCount == 0`).
@property (nonatomic, readonly) NSUInteger errorCount;
/// NumArchiveErrors: archives that could not be opened or whose extraction failed.
@property (nonatomic, readonly) NSUInteger archiveErrorCount;
/// First non-OK per-item result (CRC error, wrong password, ...).
@property (nonatomic, readonly) SZOperationResult firstFailure;
/// The engine asked for a password (7zFM remembers it on the CFolderLink afterwards).
@property (nonatomic, readonly) BOOL passwordWasAsked;
/// The password in use after the run (the delegate's answer, or the pre-seeded one).
@property (nonatomic, readonly, copy, nullable) NSString *password;
/// Every message the run produced, in order — the same texts the delegate received.
@property (nonatomic, readonly, copy) NSArray<NSString *> *messages;
/// YES when nothing failed, i.e. CExtractCallbackImp::IsOK().
@property (nonatomic, readonly) BOOL isOK;

/// The multi-line statistics block Windows shows after a successful **test**
/// (GUI/ExtractGUI.cpp:137-158): "Archives: N", packed size, folders, files, size, the two
/// alternate-stream rows when non-zero, then "There are no errors". nil unless the run was a
/// test that finished with `isOK`. Pass it to OperationRunner.Options.okMessage.
/// Also nil when `hashMethods` was set: Windows shows the hash list *instead* of this box
/// (the `else if (Options->TestMode)` of GUI/ExtractGUI.cpp:131-152).
@property (nonatomic, readonly, copy, nullable) NSString *testSummary;

/// `-scrc<M>`: the checksums of the extracted data, ready for `HashResultsDialog`. The rows are
/// the ones 7zG builds (GUI/ExtractGUI.cpp:129-136): "Archives:" = `statistics.archiveCount` and
/// "Packed Size" = `statistics.packSize`, then `AddHashBundleRes` of the bundle. nil unless
/// `options.hashMethods` was non-empty and the run finished with `isOK`, which is exactly when
/// Windows shows the dialog.
@property (nonatomic, readonly, nullable) SZHashResults *hashResults;

@end

// ---------------------------------------------------------------------------

/// NOTE ON THE NAME: the obvious `SZExtractor` clashes with a private Objective-C class of
/// Apple's StreamingZip.framework, which the runtime reports as a duplicate ("may cause spurious
/// casting failures and mysterious crashes"). The class is therefore `SZArchiveExtractor`; the
/// header keeps the file name `SZExtractor.h` that the architecture document uses.
@interface SZArchiveExtractor : NSObject

/// `Extract()` over `archivePaths`. Blocks; call off the main thread.
/// Returns nil with `error` set only for a *fatal* failure (cancellation gives
/// SZErrorCodeCancelled). Per-archive and per-item errors are reported through the delegate
/// and counted in the result, exactly like 7zG, which still returns S_OK.
+ (nullable SZExtractResult *)extractArchivesAtPaths:(NSArray<NSString *> *)archivePaths
                                             options:(SZExtractOptions *)options
                                            progress:(nullable id<SZProgressDelegate>)progress
                                               error:(NSError **)error
    NS_SWIFT_NAME(extractArchives(at:options:progress:));

/// Test (`7zG t`): the same driver with `testMode`, so the caller gets `testSummary`.
/// `options.testMode` is set for you.
+ (nullable SZExtractResult *)testArchivesAtPaths:(NSArray<NSString *> *)archivePaths
                                          options:(SZExtractOptions *)options
                                         progress:(nullable id<SZProgressDelegate>)progress
                                            error:(NSError **)error
    NS_SWIFT_NAME(testArchives(at:options:progress:));

/// GetSubFolderNameForExtract (Explorer/ContextMenu.cpp:448): the folder name the
/// Extract to "<name>/" command uses — the archive name without its extension, with the
/// inner extension also removed for `.tar.gz`-style and `.part01.rar`/`.001` volume names,
/// `~` appended when there is no extension at all, run through Get_Correct_FsFile_Name.
+ (NSString *)subfolderNameForArchiveNamed:(NSString *)archiveName
    NS_SWIFT_NAME(subfolderName(forArchiveNamed:));

/// CreateComplexDir + the IDS_CANNOT_CREATE_FOLDER 3003 message ("Cannot create folder '{0}'"),
/// which is what ExtractGUI reports before starting (01 §8.3 step 2).
+ (BOOL)createOutputDirectory:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(createOutputDirectory(_:));

/// Get_Correct_FsFile_Name: the engine's file-name sanitiser, used for the sub-folder name.
+ (NSString *)correctFileName:(NSString *)name NS_SWIFT_NAME(correctFileName(_:));

@end

// ---------------------------------------------------------------------------

/// CTempFileInfo (FileManager/Panel.h): what was extracted to a temp folder so an external
/// application can open it, and what the watcher compares against to notice a change.
@interface SZTempFile : NSObject

/// The `7zO<hex>` directory that holds the copy; delete it when the item is closed.
@property (nonatomic, readonly, copy) NSString *directoryPath;
/// The extracted file (or directory) inside `directoryPath`.
@property (nonatomic, readonly, copy) NSString *filePath;
/// Path of the item relative to the archive folder it came from (CTempFileInfo::RelPath).
@property (nonatomic, readonly, copy) NSString *relativePath;
@property (nonatomic, readonly, copy) NSString *itemName;
@property (nonatomic, readonly) NSInteger itemIndex;
@property (nonatomic, readonly) BOOL isDirectory;
/// YES when the item went through the in-memory path (CVirtFileSystem) before being written.
@property (nonatomic, readonly) BOOL wasHeldInMemory;
/// Size and modification date recorded right after the extraction (CTempFileInfo::FileInfo).
@property (nonatomic, readonly) uint64_t size;
@property (nonatomic, readonly, copy, nullable) NSDate *modificationDate;

/// The file on disk no longer matches `size` / `modificationDate`, i.e. the application saved
/// it (PanelItemOpen.cpp: the watcher's "was it modified?" test).
@property (nonatomic, readonly) BOOL wasModified;
/// Re-reads size and modification date, so a second edit round is noticed too.
- (void)refreshRecordedAttributes;

@end

/// The temp-folder machinery behind "open / view / edit an item that is inside an archive"
/// (01 §3.9, §3.11) and behind dragging archive members out to Finder (01 §3.15).
@interface SZTempOpen : NSObject

/// kTempDirPrefix of PanelItemOpen.cpp ("7zO") and of PanelCopy/PanelDrag ("7zE").
@property (class, nonatomic, readonly) NSString *openDirectoryPrefix;
@property (class, nonatomic, readonly) NSString *extractDirectoryPrefix;

/// A fresh `<temp>/<prefix><8 hex>` directory, mode 0700 (CTempDir::Create, "7zO1A2B3C4D"). nil
/// with `error` set on failure.
+ (nullable NSString *)createTemporaryDirectoryWithPrefix:(NSString *)prefix
                                                    error:(NSError **)error
    NS_SWIFT_NAME(createTemporaryDirectory(prefix:));

/// The size below which extraction goes through memory first:
/// `RAM >> max(levels + 1, 8)` when the RAM size is known, else 4 MiB
/// (PanelItemOpen.cpp:1613-1615).
+ (uint64_t)inMemoryLimitForArchiveLevelCount:(NSInteger)levels
    NS_SWIFT_NAME(inMemoryLimit(archiveLevelCount:));

/// Extracts item `index` of an archive folder into a fresh `7zO` directory and returns the
/// bookkeeping the watcher needs. Small items are collected in memory and flushed afterwards,
/// like CVirtFileSystem; bigger ones are written straight to disk. `archiveFilePath` is the
/// file whose `com.apple.quarantine` attribute is propagated when `zoneMode` asks for it.
/// BLOCKS; run on the queue that owns `folder`.
+ (nullable SZTempFile *)extractItemAtIndex:(NSInteger)index
                                   ofFolder:(SZFolder *)folder
                            archiveFilePath:(nullable NSString *)archiveFilePath
                          archiveLevelCount:(NSInteger)levels
                                   zoneMode:(SZZoneIDMode)zoneMode
                                   progress:(nullable id<SZProgressDelegate>)progress
                                      error:(NSError **)error
    NS_SWIFT_NAME(extractItem(at:of:archiveFilePath:archiveLevelCount:zoneMode:progress:));

/// IFolderOperations::CopyFromFile: replaces one item's data with a file from disk, keeping the
/// item's name -- how a modified temp file gets back into the archive
/// (CAgentFolder::CopyFromFile -> UpdateOneFile, 01 §3.9 step 5, §6.7). BLOCKS.
+ (BOOL)updateItemAtIndex:(NSInteger)index
                 ofFolder:(SZFolder *)folder
             fromFilePath:(NSString *)filePath
                 progress:(nullable id<SZProgressDelegate>)progress
                    error:(NSError **)error
    NS_SWIFT_NAME(updateItem(at:of:fromFilePath:progress:));

/// Every `7zO*` / `7zE*` directory currently in the temp folder, for Tools > Delete Temporary
/// Files and for a startup sweep (01 §9 #11: Windows never sweeps, so this is an addition).
+ (NSArray<NSString *> *)temporaryDirectories;
+ (BOOL)removeTemporaryDirectoryAtPath:(NSString *)path;

/// Copies the `com.apple.quarantine` attribute of `archivePath` onto `path` when `mode` asks
/// for it: `.all` always, `.office` only for Office documents (01 §9 #23).
+ (void)applyQuarantineFromArchiveAtPath:(nullable NSString *)archivePath
                                  toPath:(NSString *)path
                                    mode:(SZZoneIDMode)mode
    NS_SWIFT_NAME(applyQuarantine(fromArchiveAt:to:mode:));

@end

NS_ASSUME_NONNULL_END

#endif

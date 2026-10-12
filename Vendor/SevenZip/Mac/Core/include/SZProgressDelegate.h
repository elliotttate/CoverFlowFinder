// SZProgressDelegate.h -- the callback surface of every long operation (extract, update,
// copy, hash, test). Methods are invoked on the engine's worker thread; the implementation
// must be thread-safe and must not touch AppKit directly. Questions (askOverwrite,
// askPassword) block the worker until answered. checkBreak returning YES cancels
// (the engine receives E_ABORT); pausing is implemented by blocking inside checkBreak.
// Driven by SZFolderOperations (this scope) and by SZExtractor/SZUpdater/SZHasher
// (later waves) through Mac/Core/Internal/SZCallbackAdapters.h.
//
// Parity: CProgressSync / CExtractCallbackImp / CUpdateCallbackGUI
// (01-fm-feature-inventory.md 8.4, 8.5, 8.7; 01b-fm-dialogs-settings.md 4.17).

#ifndef SZ_PROGRESS_DELEGATE_H
#define SZ_PROGRESS_DELEGATE_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZTypes.h>

NS_ASSUME_NONNULL_BEGIN

/// The progress dialog status line (IDT_PROGRESS_STATUS 103). The raw value **is** the
/// 7-Zip lang string ID, so the UI can render it with SZLang/Lang.get(status.rawValue, ...).
/// Texts (en.ttt): 3300 "Extracting", 3301 "Compressing", 3302 "Testing", 3303 "Opening...",
/// 3304 "Scanning...", 3305 "Removing", 3320 "Adding", 3321 "Updating", 3322 "Analyzing",
/// 3323 "Replicating", 3324 "Repacking", 3325 "Skipping", 3326 "Deleting",
/// 3327 "Header creating", 6004 "Copying...", 6005 "Moving...", 6006 "Renaming...",
/// 6106 "Deleting...", 7500 "Checksum calculating...".
typedef NS_ENUM(uint32_t, SZProgressStatus) {
    SZProgressStatusNone = 0,
    SZProgressStatusExtracting = 3300,      ///< IDS_PROGRESS_EXTRACTING
    SZProgressStatusCompressing = 3301,     ///< IDS_PROGRESS_COMPRESSING
    SZProgressStatusTesting = 3302,         ///< IDS_PROGRESS_TESTING
    SZProgressStatusOpening = 3303,         ///< IDS_OPENNING
    SZProgressStatusScanning = 3304,        ///< IDS_SCANNING
    SZProgressStatusRemoving = 3305,        ///< IDS_PROGRESS_REMOVE
    SZProgressStatusAdd = 3320,             ///< IDS_PROGRESS_ADD
    SZProgressStatusUpdate = 3321,          ///< IDS_PROGRESS_UPDATE
    SZProgressStatusAnalyze = 3322,         ///< IDS_PROGRESS_ANALYZE
    SZProgressStatusReplicate = 3323,       ///< IDS_PROGRESS_REPLICATE
    SZProgressStatusRepack = 3324,          ///< IDS_PROGRESS_REPACK
    SZProgressStatusSkipping = 3325,        ///< IDS_PROGRESS_SKIPPING
    SZProgressStatusDelete = 3326,          ///< IDS_PROGRESS_DELETE
    SZProgressStatusHeader = 3327,          ///< IDS_PROGRESS_HEADER
    SZProgressStatusCopying = 6004,         ///< IDS_COPYING
    SZProgressStatusMoving = 6005,          ///< IDS_MOVING
    SZProgressStatusRenaming = 6006,        ///< IDS_RENAMING
    SZProgressStatusDeleting = 6106,        ///< IDS_DELETING
    SZProgressStatusChecksum = 7500         ///< IDS_CHECKSUM_CALCULATING
};

/// Answer of the Memory usage request dialog (IDD_MEM 7800, 01b 4.12) mapped onto
/// NRequestMemoryAnswerFlags: k_Allow / k_SkipArc / k_Stop.
typedef NS_ENUM(NSInteger, SZMemoryUseAnswer) {
    SZMemoryUseAnswerAllow = 0,        ///< k_Allow: unpack anyway
    SZMemoryUseAnswerSkipArchive = 1,  ///< k_SkipArc: skip this archive
    SZMemoryUseAnswerStop = 2          ///< k_Stop: cancel the operation (E_ABORT)
};

@protocol SZProgressDelegate <NSObject>

/// IProgress::SetTotal
- (void)progressSetTotal:(uint64_t)total;
/// IProgress::SetCompleted (may be called concurrently from several engine threads)
- (void)progressSetCompleted:(uint64_t)completed;
/// ICompressProgressInfo::SetRatioInfo
- (void)progressSetRatioInfoInSize:(uint64_t)inSize outSize:(uint64_t)outSize;
/// Current item (PrepareOperation / SetCurrentFilePath)
- (void)progressSetCurrentFile:(NSString *)path isDirectory:(BOOL)isDirectory;
/// SetNumFiles / files processed so far
- (void)progressSetNumFilesProcessed:(uint64_t)numFiles;
/// IFolderArchiveExtractCallback::AskOverwrite. `suggestedName` may receive a new name for SZOverwriteAnswerAutoRename.
- (SZOverwriteAnswer)progressAskOverwriteExisting:(NSString *)existName
                                        existTime:(nullable NSDate *)existTime
                                        existSize:(nullable NSNumber *)existSize
                                          newName:(NSString *)newName
                                          newTime:(nullable NSDate *)newTime
                                          newSize:(nullable NSNumber *)newSize
                                    suggestedName:(NSString * _Nullable * _Nullable)suggestedName;
/// ICryptoGetTextPassword; nil = cancel.
- (nullable NSString *)progressAskPasswordForPath:(NSString *)path;
/// MessageError / ShowMessage
- (void)progressShowMessage:(NSString *)message;
/// SetOperationResult / ReportExtractResult for one item
- (void)progressSetOperationResult:(SZOperationResult)result path:(NSString *)path isEncrypted:(BOOL)encrypted;
/// Polled from every callback; YES = cancel. Block here to pause.
- (BOOL)progressCheckBreak;

@optional

/// IFolderOperationsExtractCallback::SetNumFiles / IFolderArchiveUpdateCallback::SetNumFiles:
/// the **total** number of files of the operation (CProgressSync::Set_NumFilesTotal).
/// The running count arrives through progressSetNumFilesProcessed:.
- (void)progressSetTotalFiles:(uint64_t)totalFiles;

/// Status line (CProgressSync::Set_Status, IDT_PROGRESS_STATUS 103).
- (void)progressSetStatus:(SZProgressStatus)status;

/// CProgressSync::Set_TitleFileName: the archive (or destination) shown in the window title.
- (void)progressSetTitleFileName:(NSString *)name;

/// IFolderScanProgress::ScanProgress (update/add: counting the files to compress).
- (void)progressScanFolders:(uint64_t)numFolders
                      files:(uint64_t)numFiles
                  totalSize:(uint64_t)totalSize
                       path:(NSString *)path
                isDirectory:(BOOL)isDirectory;

/// ICryptoGetTextPassword2 (compress side): the password to *encrypt* with.
/// Return nil and leave *cancelled == NO for "no password"; set *cancelled = YES to abort
/// (the engine then receives E_ABORT). CUpdateCallbackGUI2::ShowAskPasswordDialog.
- (nullable NSString *)progressAskPasswordForEncryptionCancelled:(BOOL *)cancelled;

/// IArchiveRequestMemoryUseCallback::RequestMemoryUse -> CMemDialog (IDD_MEM 7800, 01b 4.12).
/// `allowedSize` is in/out: the current limit on entry, on return the limit the user allows.
/// `allowSkipArchive` mirrors NRequestMemoryUseFlags::k_SkipArc_IsExpected.
- (SZMemoryUseAnswer)progressRequestMemoryUseForPath:(nullable NSString *)path
                                        requiredSize:(uint64_t)requiredSize
                                         allowedSize:(uint64_t *)allowedSize
                                            testMode:(BOOL)testMode
                                    allowSkipArchive:(BOOL)allowSkipArchive;

/// IFolderArchiveUpdateCallback_MoveArc: the finished temp archive is moved over the original.
- (void)progressMoveArchiveFrom:(NSString *)sourcePath toPath:(NSString *)destinationPath size:(uint64_t)size;
- (void)progressMoveArchiveCompleted:(uint64_t)current total:(uint64_t)total;
- (void)progressMoveArchiveFinished;
/// Before_ArcReopen: the delegate must clear its cancel flag so the re-open can run
/// (CUpdateCallback100Imp -> Sync.Clear_Stop_Status()).
- (void)progressClearCancelState;

@end

NS_ASSUME_NONNULL_END

#endif

// SZFolderOperations.h -- the operations 7zFM drives through IFolderOperations and
// IArchiveFolder, as synchronous Objective-C methods on SZFolder.
//
// Every method here BLOCKS while the engine works and reports through the
// id<SZProgressDelegate> it is given (progress, messages, overwrite and password
// questions, cancellation). Call them **off the main thread**, on the same queue that
// owns the SZFolder (the engine's COM refcounts are not atomic), and drive them from
// Swift with OperationRunner (Mac/App/Support/OperationRunner.swift), which owns the
// Progress dialog and answers the questions.
//
// Parity: CPanel::CopyTo / OnCopy (01-fm-feature-inventory.md 3.10, 3.11), the Agent's
// CommonUpdateOperation (02-engine-api.md 2.2) and IArchiveFolder::Extract, which is the
// path 7zFM uses for panel copy-out, drag-out and Test inside an archive (01 8.1, 8.4).

#ifndef SZ_FOLDER_OPERATIONS_H
#define SZ_FOLDER_OPERATIONS_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>
#import <SevenZipKit/SZProgressDelegate.h>
#import <SevenZipKit/SZTypes.h>
#import <SevenZipKit/SZExtractor.h>

NS_ASSUME_NONNULL_BEGIN

/// What a finished operation counted (the FM's progress-dialog totals).
@interface SZOperationSummary : NSObject
/// Items whose SetOperationResult/OperationResult arrived (7zFM's "Files" counter).
@property (nonatomic, readonly) uint64_t filesProcessed;
/// Messages + per-item failures collected (7zFM's "Errors" counter).
@property (nonatomic, readonly) NSUInteger errorCount;
/// First non-OK per-item result, SZOperationResultOK when everything worked.
@property (nonatomic, readonly) SZOperationResult firstFailure;
/// YES when the engine asked the delegate for a password during the operation
/// (7zFM remembers it on the CFolderLink afterwards).
@property (nonatomic, readonly) BOOL passwordWasAsked;
@end

@interface SZFolder (SZFolderOperations)

#pragma mark Capabilities

/// IFolderOperations (copy/move/delete/rename/create/comment) is implemented.
/// The *file-system* folder declares it but its methods are being implemented by the
/// `fsfolder` scope; until then they fail with SZErrorCodeNotImplemented.
@property (nonatomic, readonly) BOOL supportsOperations;
/// IArchiveFolder: this folder is inside an archive and can extract/test its items.
@property (nonatomic, readonly) BOOL supportsArchiveExtract;
/// IFolderCalcItemFullSize / IFolderGetItemFullSize: the folder computes recursive sizes
/// itself. When NO, calcSize walks the folder tree through BindToFolder instead.
@property (nonatomic, readonly) BOOL supportsCalcItemFullSize;

#pragma mark Copy / move (IFolderOperations::CopyTo, IArchiveFolder path for archives)

/// CPanel::CopyTo with an explicit zone policy (opsgaps): `zoneMode` goes to
/// IFolderSetZoneIdMode and, when `zoneSourcePath` names a file carrying
/// `com.apple.quarantine`, its bytes go to IFolderSetZoneIdFile -- pass the *outermost*
/// archive on disk for a nested archive (Get_ZoneId_Stream_from_ParentFolders,
/// PanelCopy.cpp:156). nil = the archive folder reads its own archive file. A file-system
/// folder ignores both (it has no IFolderSetZoneIdMode).
- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  zoneMode:(SZZoneIDMode)zoneMode
            zoneSourcePath:(nullable NSString *)zoneSourcePath
                  progress:(nullable id<SZProgressDelegate>)progress
                     error:(NSError **)error
    NS_SWIFT_NAME(copyItems(at:toPath:zoneMode:zoneSourcePath:progress:));

/// `Options.WriteZoneIdExtract` as an SZZoneIDMode: 0 is None, -1 (unset, sec113) and 1 All,
/// 2 Office files only (CContextMenuInfo::WriteZone).
@property (class, nonatomic, readonly) SZZoneIDMode registryZoneMode;

/// Copies the items to `destinationPath` (a directory; created if missing).
/// Inside an archive this is CAgentFolder::CopyTo: always "ask" overwrite mode and the
/// panel's current paths, which is what F5 in 7zFM does (01 3.10).
/// Quarantine: like CPanel::CopyTo with NeedRegistryZone (PanelCopy.cpp:188-198), the mode is
/// `Options.WriteZoneIdExtract` and the archive's own `com.apple.quarantine` bytes are
/// propagated to the copied files (01 9 #23); use the `zoneMode:` variant to choose.
- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  progress:(nullable id<SZProgressDelegate>)progress
                     error:(NSError **)error NS_SWIFT_NAME(copyItems(at:toPath:progress:));

/// Same with moveMode = 1 (F6). Archive folders answer E_NOTIMPL (ArchiveFolder.cpp:56):
/// 7zFM copies out and then deletes, it never asks the Agent to move.
- (BOOL)moveItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  progress:(nullable id<SZProgressDelegate>)progress
                     error:(NSError **)error NS_SWIFT_NAME(moveItems(at:toPath:progress:));

/// IFolderOperations::CopyFrom: brings `itemNames` (names relative to `folderPath`) *into*
/// this folder — adding files to an archive folder (k_ActionSet_Add) or pasting into a
/// directory. `moveMode` deletes the sources afterwards.
- (BOOL)copyItemsNamed:(NSArray<NSString *> *)itemNames
        fromFolderPath:(NSString *)folderPath
              moveMode:(BOOL)moveMode
              progress:(nullable id<SZProgressDelegate>)progress
                 error:(NSError **)error NS_SWIFT_NAME(copyItems(named:fromFolderPath:moveMode:progress:));

#pragma mark Item operations (IFolderOperations)

- (BOOL)deleteItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    progress:(nullable id<SZProgressDelegate>)progress
                       error:(NSError **)error NS_SWIFT_NAME(deleteItems(at:progress:));

- (BOOL)renameItemAtIndex:(NSInteger)index
                   toName:(NSString *)newName
                 progress:(nullable id<SZProgressDelegate>)progress
                    error:(NSError **)error NS_SWIFT_NAME(renameItem(at:to:progress:));

- (BOOL)createFolderNamed:(NSString *)name
                 progress:(nullable id<SZProgressDelegate>)progress
                    error:(NSError **)error NS_SWIFT_NAME(createFolder(named:progress:));

/// CreateFile: an empty file. The Agent answers E_NOTIMPL inside archives
/// (ArchiveFolderOut.cpp:440-443), like 7zFM.
- (BOOL)createFileNamed:(NSString *)name
               progress:(nullable id<SZProgressDelegate>)progress
                  error:(NSError **)error NS_SWIFT_NAME(createFile(named:progress:));

/// SetProperty(kpidComment): the zip item comment (the only property the Agent writes,
/// ArchiveFolderOut.cpp:445-457) or the file-system descript.ion entry.
- (BOOL)setComment:(NSString *)comment
    forItemAtIndex:(NSInteger)index
          progress:(nullable id<SZProgressDelegate>)progress
             error:(NSError **)error NS_SWIFT_NAME(setComment(_:forItemAt:progress:));

#pragma mark Sizes

/// Recursive size of the items, like the panel's folder-size calculation: through
/// IFolderCalcItemFullSize / IFolderGetItemFullSize when the folder provides them,
/// otherwise by walking sub-folders with BindToFolder (works for archives and
/// directories alike). nil on error / cancellation.
- (nullable NSNumber *)calculateFullSizeOfItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                                                progress:(nullable id<SZProgressDelegate>)progress
                                                   error:(NSError **)error NS_SWIFT_NAME(calcSize(at:progress:));

#pragma mark Extract / test (IArchiveFolder::Extract)

/// Extracts (or tests) items of this archive folder into `destinationPath`.
/// `indexes` may be nil / empty to take every item of the folder. `pathMode` and
/// `overwriteMode` are the Extract dialog's two combos (01b 4.25); `testMode` writes
/// nothing (7zG t / "Test archive" inside a panel, 01 8.1).
/// Returns the summary, or nil with `error` set (SZErrorCodeCancelled on Cancel).
- (nullable SZOperationSummary *)extractItemsAtIndexes:(nullable NSArray<NSNumber *> *)indexes
                                                toPath:(NSString *)destinationPath
                                              pathMode:(SZExtractPathMode)pathMode
                                         overwriteMode:(SZOverwriteMode)overwriteMode
                                              testMode:(BOOL)testMode
                                              progress:(nullable id<SZProgressDelegate>)progress
                                                 error:(NSError **)error
    NS_SWIFT_NAME(extractItems(at:toPath:pathMode:overwriteMode:testMode:progress:));

/// The same with a quarantine policy (opsgaps, 01 9 #23): `zoneMode` / `zoneSourcePath` as for
/// `copyItems(at:toPath:zoneMode:zoneSourcePath:progress:)`. The plain variant above passes
/// None, which is what 7zFM does for drag-out and temp-open; Extract inside an archive is
/// CPanel::CopyTo and passes `SZFolder.registryZoneMode`. Ignored in test mode.
- (nullable SZOperationSummary *)extractItemsAtIndexes:(nullable NSArray<NSNumber *> *)indexes
                                                toPath:(NSString *)destinationPath
                                              pathMode:(SZExtractPathMode)pathMode
                                         overwriteMode:(SZOverwriteMode)overwriteMode
                                              testMode:(BOOL)testMode
                                              zoneMode:(SZZoneIDMode)zoneMode
                                        zoneSourcePath:(nullable NSString *)zoneSourcePath
                                              progress:(nullable id<SZProgressDelegate>)progress
                                                 error:(NSError **)error
    NS_SWIFT_NAME(extractItems(at:toPath:pathMode:overwriteMode:testMode:zoneMode:zoneSourcePath:progress:));

@end

NS_ASSUME_NONNULL_END

#endif

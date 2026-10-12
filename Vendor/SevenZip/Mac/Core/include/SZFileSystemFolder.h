// SZFileSystemFolder.h -- a directory: the macOS replacement for FSFolder / FSFolderCopy.
// C++ implementation: Mac/Core/Internal/FSFolderMac.cpp (IFolderFolder, IFolderGetItemName,
// IFolderWasChanged via FSEvents, IFolderOperations, IFolderCalcItemFullSize,
// IFolderGetItemFullSize, IFolderSetFlatMode, IFolderClone, IFolderCompare).
//
// Columns (01-fm-feature-inventory.md section 3.2, FSFolder.cpp kProps): Name, Size,
// Modified, Created (birth time), Accessed, Metadata Changed, Attributes, Packed Size
// (physical size on disk), Mode, User, Group, Link (symlink target), iNode, Links, Comment,
// Folders, Files, and Path Prefix in flat view only.
//
// Every long operation is synchronous and must be called off the main thread; progress,
// messages and the overwrite question arrive on the calling thread through
// SZProgressDelegate, and returning YES from progressCheckBreak aborts with
// SZErrorCodeCancelled.

#ifndef SZ_FILE_SYSTEM_FOLDER_H
#define SZ_FILE_SYSTEM_FOLDER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>
#import <SevenZipKit/SZProgressDelegate.h>

NS_ASSUME_NONNULL_BEGIN

/// Preferences key for `showHiddenFiles` ("FM.ShowHiddenFiles"). Windows 7zFM has no such
/// option (FindFirstFile always returns hidden files), so the default is YES.
FOUNDATION_EXPORT NSString * const SZFileSystemFolderShowHiddenFilesKey;

@interface SZFileSystemFolder : SZFolder

/// Binds and loads a directory. Fails with SZErrorCodeNotFolder / SZErrorCodeFileNotFound.
+ (nullable SZFileSystemFolder *)folderWithPath:(NSString *)directoryPath error:(NSError **)error NS_SWIFT_NAME(folder(withPath:));

#pragma mark Listing

/// Absolute directory path with a trailing "/".
@property (nonatomic, readonly, copy) NSString *directoryPath;
/// Absolute path of an item (includes the flat-view prefix).
- (NSString *)fullPathOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(fullPathOfItem(at:));
/// Columns hidden by default in 7zFM for file-system folders (GetColumnVisible,
/// PanelItems.cpp:25-51) plus the macOS-only Mode / User / Group columns.
@property (class, nonatomic, readonly) NSSet<NSNumber *> *defaultHiddenPropIDs;

/// List dotfiles and UF_HIDDEN entries. Defaults to SZFileSystemFolderShowHiddenFilesKey
/// (YES). Changing it requires `loadItems:` again.
@property (nonatomic) BOOL showHiddenFiles;

/// A bundle / package (.app, .rtfd ...). Packages are listed and navigated as directories.
- (BOOL)isPackageAtIndex:(NSInteger)index NS_SWIFT_NAME(isPackage(at:));
/// YES when the item itself is a symbolic link (the listing never follows links).
- (BOOL)isSymbolicLinkAtIndex:(NSInteger)index NS_SWIFT_NAME(isSymbolicLink(at:));
/// readlink() target, or nil. Same value as the "Link" column (kpidNtReparse / kpidSymLink).
- (nullable NSString *)linkTargetOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(linkTargetOfItem(at:));

#pragma mark Change notification (01 section 3.17)

/// The watched directory itself was deleted, renamed or moved: the panel must navigate up.
/// Sticky once set; only meaningful after `wasChanged` has been polled at least once.
@property (nonatomic, readonly) BOOL directoryWasRemoved;

#pragma mark Operations (IFolderOperations, 01 section 6.4)

/// Delete moves items to the Trash (the macOS recycle bin, 01 section 9 #9). Default YES;
/// set to NO for the permanent delete that Windows binds to Shift+Delete.
@property (nonatomic) BOOL deleteToTrash;

/// Copy (or move) items to `destinationPath`. A path with a trailing "/" is a destination
/// directory; without one it is the exact target path and exactly one index is allowed.
- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                      move:(BOOL)move
                  delegate:(nullable id<SZProgressDelegate>)delegate
                     error:(NSError **)error NS_SWIFT_NAME(copyItems(at:toPath:move:delegate:));

/// The CopyFrom direction: copy (or move) absolute external paths into this folder.
- (BOOL)copyPaths:(NSArray<NSString *> *)sourcePaths
             move:(BOOL)move
         delegate:(nullable id<SZProgressDelegate>)delegate
            error:(NSError **)error NS_SWIFT_NAME(copy(paths:move:delegate:));

/// Drag & drop / clipboard entry point (FSFolderCopy.cpp CopyFileSystemItems).
+ (BOOL)copyPaths:(NSArray<NSString *> *)sourcePaths
      toDirectory:(NSString *)destinationDirectory
             move:(BOOL)move
         delegate:(nullable id<SZProgressDelegate>)delegate
            error:(NSError **)error NS_SWIFT_NAME(copy(paths:toDirectory:move:delegate:));

/// Delete items to the Trash or permanently, whatever `deleteToTrash` says.
- (BOOL)deleteItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                     toTrash:(BOOL)toTrash
                    delegate:(nullable id<SZProgressDelegate>)delegate
                       error:(NSError **)error NS_SWIFT_NAME(deleteItems(at:toTrash:delegate:));

/// Rename inside the folder; "sub/name" moves the item into a sub-folder. An existing name
/// fails with the EEXIST HRESULT, like Windows' MoveFile (ERROR_ALREADY_EXISTS).
- (BOOL)renameItemAtIndex:(NSInteger)index toName:(NSString *)newName error:(NSError **)error NS_SWIFT_NAME(renameItem(at:to:));
/// Creates "a/b/c" as well; fails when the leaf already exists.
- (BOOL)createFolderNamed:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(createFolder(named:));
/// Empty file, O_EXCL: fails when the name exists (Windows CREATE_NEW).
- (BOOL)createFileNamed:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(createFile(named:));

/// IFolderCalcItemFullSize: recursive size / Folders / Files for a directory item, stored on
/// the item (F3 in 7zFM). Cancellable through the delegate.
- (BOOL)calculateFullSizeOfItemAtIndex:(NSInteger)index
                              delegate:(nullable id<SZProgressDelegate>)delegate
                                 error:(NSError **)error NS_SWIFT_NAME(calculateFullSize(at:delegate:));

/// kpidComment through descript.ion in this folder (01 section 6.4, section 9 #19).
/// nil removes the entry.
- (BOOL)setComment:(nullable NSString *)comment forItemAtIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(setComment(_:forItem:));

@end

NS_ASSUME_NONNULL_END

#endif

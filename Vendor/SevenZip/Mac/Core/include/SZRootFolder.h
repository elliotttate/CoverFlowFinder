// SZRootFolder.h -- the virtual root (Windows RootFolder + FSDrives): Computer ("/"),
// Volumes (mounted volumes from /Volumes with total/free space), Home, Documents.
// C++ implementation: Mac/Core/Internal/RootFolderMac.cpp.

#ifndef SZ_ROOT_FOLDER_H
#define SZ_ROOT_FOLDER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZRootFolder : SZFolder

/// A fresh root folder with items loaded. folderType "RootFolder", path "".
+ (SZRootFolder *)rootFolder NS_SWIFT_NAME(makeRootFolder());
/// The volumes list (folderType "FSDrives", kept for column persistence): columns kpidName,
/// kpidTotalSize, kpidFreeSpace, kpidType ("Fixed"/"Removable"/"Remote"/"CD-ROM"),
/// kpidVolumeName (the localized label), kpidFileSystem, kpidClusterSize; item values
/// kpidPath (the mount point) and kpidOutName. Implements IFolderWasChanged, so `wasChanged`
/// reports volumes appearing and disappearing; `loadItems:` refreshes the list.
+ (SZRootFolder *)volumesFolder NS_SWIFT_NAME(makeVolumesFolder());

/// Names of the root entries in the current language (index 0..3).
@property (class, nonatomic, readonly) NSArray<NSString *> *rootEntryNames;

/// YES for the volumes list (folderType "FSDrives").
@property (nonatomic, readonly) BOOL isVolumesFolder;
/// Mount point of a volume item, with a trailing "/". nil outside the volumes folder.
/// Binding to the item lands in the SZFileSystemFolder for this path.
- (nullable NSString *)mountPathOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(mountPathOfItem(at:));

@end

NS_ASSUME_NONNULL_END

#endif

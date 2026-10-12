// MacFileOps.h -- the Cocoa-only pieces the file-system folder needs: Trash (the macOS
// replacement for the recycle bin, 01 section 9 #9), metadata/xattr/resource-fork copying,
// bundle detection and the mounted-volume list (01 section 9 #5).
//
// Engine-free on purpose (no 7-Zip headers): the implementation is Objective-C++
// (MacFileOps.mm) and MyWindows.h's `typedef int BOOL` must not reach it, while
// FSFolderMac.cpp / RootFolderMac.cpp are plain C++ and must not see Foundation.

#ifndef SZ_MAC_FILE_OPS_H
#define SZ_MAC_FILE_OPS_H

#include <string>
#include <vector>

namespace NMacFileOps {

// NSFileManager.trashItemAtURL: moves `path` to the user's Trash.
// On success `resultPath` receives the new location inside .Trash (may be empty).
// On failure `errorMessage` receives the localized description and `errnoValue` the POSIX
// error when one can be derived (0 otherwise).
bool TrashItem(const char *path, std::string &resultPath, std::string &errorMessage, int &errnoValue);

// copyfile(3) with COPYFILE_SECURITY | COPYFILE_XATTR (+ COPYFILE_NOFOLLOW for links):
// POSIX mode, owner where permitted, ACLs, extended attributes and therefore the resource
// fork (com.apple.ResourceFork). Data is copied by the caller, so this runs afterwards.
bool CopyMetadata(const char *srcPath, const char *destPath, bool isSymLink);

// NSWorkspace.isFilePackage: a directory the Finder shows as one document (.app, .rtfd...).
bool IsPackage(const char *path);

struct CVolumeInfo
{
  std::string Name;         // entry name ("Macintosh HD"); Windows shows the drive letter
  std::string MountPath;    // mount point with a trailing '/'
  std::string Label;        // localized volume name (kpidVolumeName / "Label")
  std::string FileSystem;   // statfs f_fstypename ("apfs", "hfs", "exfat", "smbfs"...)
  std::string Type;         // "Fixed" / "Removable" / "Remote" / "CD-ROM" (kDriveTypes)
  unsigned long long TotalSize;
  unsigned long long FreeSpace;
  unsigned long long ClusterSize;
  CVolumeInfo(): TotalSize(0), FreeSpace(0), ClusterSize(0) {}
};

// FileManager.mountedVolumeURLs (skipping the hidden system volumes the Finder hides) plus
// statfs() for the file-system name and the allocation block size.
void GetMountedVolumes(std::vector<CVolumeInfo> &volumes);

// Cheap fingerprint of the mount table (getfsstat, no allocation of volume metadata):
// changes when a volume is mounted or unmounted. Used by IFolderWasChanged.
unsigned long long MountsFingerprint();

// realpath(3) into `result` (symlinks resolved, no trailing '/'). false if the path is gone.
bool RealPath(const char *path, std::string &result);

}

#endif

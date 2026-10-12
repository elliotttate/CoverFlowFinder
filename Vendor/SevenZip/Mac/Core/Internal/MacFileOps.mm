// MacFileOps.mm -- see MacFileOps.h

#import "MacFileOps.h"

#import <Foundation/Foundation.h>

#include <copyfile.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>

namespace NMacFileOps {

static std::string CppString(NSString *s)
{
  if (!s)
    return std::string();
  const char *u = [s UTF8String];
  return std::string(u ? u : "");
}

bool TrashItem(const char *path, std::string &resultPath, std::string &errorMessage, int &errnoValue)
{
  resultPath.clear();
  errorMessage.clear();
  errnoValue = 0;
  if (!path || !*path)
  {
    errnoValue = EINVAL;
    errorMessage = "Invalid path";
    return false;
  }
  @autoreleasepool
  {
    NSString *p = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
    NSURL *url = [NSURL fileURLWithPath:p];
    NSURL *newURL = nil;
    NSError *error = nil;
    if ([[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:&newURL error:&error])
    {
      if (newURL)
        resultPath = CppString(newURL.path);
      return true;
    }
    errorMessage = CppString(error.localizedDescription);
    if (errorMessage.empty())
      errorMessage = "Cannot move the item to the Trash";
    // NSCocoaErrorDomain wraps the POSIX error in NSUnderlyingError when there is one.
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying.domain isEqualToString:NSPOSIXErrorDomain])
      errnoValue = (int)underlying.code;
    else if ([error.domain isEqualToString:NSPOSIXErrorDomain])
      errnoValue = (int)error.code;
    return false;
  }
}

bool CopyMetadata(const char *srcPath, const char *destPath, bool isSymLink)
{
  copyfile_flags_t flags = (copyfile_flags_t)(COPYFILE_SECURITY | COPYFILE_XATTR);
  if (isSymLink)
    flags |= (copyfile_flags_t)COPYFILE_NOFOLLOW;
  return copyfile(srcPath, destPath, NULL, flags) == 0;
}

bool IsPackage(const char *path)
{
  if (!path || !*path)
    return false;
  @autoreleasepool
  {
    // NSURLIsPackageKey is the Foundation equivalent of NSWorkspace.isFilePackage
    // (SevenZipKit links Foundation and CoreServices only, never AppKit).
    NSString *p = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
    NSNumber *isPackage = nil;
    if (![[NSURL fileURLWithPath:p] getResourceValue:&isPackage forKey:NSURLIsPackageKey error:NULL])
      return false;
    return isPackage != nil && isPackage.boolValue;
  }
}

static void FillFromStatfs(CVolumeInfo &v, const char *mountPath)
{
  struct statfs fs;
  if (statfs(mountPath, &fs) != 0)
    return;
  v.FileSystem = fs.f_fstypename;
  if (v.ClusterSize == 0)
    v.ClusterSize = (unsigned long long)fs.f_bsize;
  if (v.TotalSize == 0)
    v.TotalSize = (unsigned long long)fs.f_blocks * fs.f_bsize;
  if (v.FreeSpace == 0)
    v.FreeSpace = (unsigned long long)fs.f_bavail * fs.f_bsize;
  const bool isLocal = (fs.f_flags & MNT_LOCAL) != 0;
  if (v.Type.empty())
  {
    if (!isLocal)
      v.Type = "Remote";
    else if (strcmp(fs.f_fstypename, "cd9660") == 0 || strcmp(fs.f_fstypename, "udf") == 0)
      v.Type = "CD-ROM";
    else if ((fs.f_flags & MNT_REMOVABLE) != 0)
      v.Type = "Removable";
    else
      v.Type = "Fixed";
  }
}

void GetMountedVolumes(std::vector<CVolumeInfo> &volumes)
{
  volumes.clear();
  @autoreleasepool
  {
    NSArray<NSURLResourceKey> *keys = @[
      NSURLVolumeNameKey, NSURLVolumeLocalizedNameKey,
      NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityKey,
      NSURLVolumeIsRemovableKey, NSURLVolumeIsEjectableKey,
      NSURLVolumeIsInternalKey, NSURLVolumeIsLocalKey
    ];
    // Windows lists every drive letter; the Finder-visible volumes are the macOS equivalent
    // (the System/Volumes/* firmlink helpers are noise, 01 section 9 #5).
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:keys
                                                options:NSVolumeEnumerationSkipHiddenVolumes];
    for (NSURL *url in urls)
    {
      NSString *mount = url.path;
      if (mount.length == 0)
        continue;
      CVolumeInfo v;
      v.MountPath = CppString(mount);
      if (v.MountPath.empty())
        continue;
      if (v.MountPath[v.MountPath.size() - 1] != '/')
        v.MountPath += '/';

      NSDictionary<NSURLResourceKey, id> *vals = [url resourceValuesForKeys:keys error:NULL];
      NSString *localized = vals[NSURLVolumeLocalizedNameKey];
      if (localized.length == 0)
        localized = vals[NSURLVolumeNameKey];
      v.Label = CppString(localized);

      // Name = the /Volumes entry (what the user sees in the sidebar); "/" has none.
      NSString *last = mount.lastPathComponent;
      v.Name = CppString([last isEqualToString:@"/"] ? nil : last);
      if (v.Name.empty())
        v.Name = v.Label.empty() ? std::string("/") : v.Label;

      NSNumber *total = vals[NSURLVolumeTotalCapacityKey];
      NSNumber *avail = vals[NSURLVolumeAvailableCapacityKey];
      if (total)
        v.TotalSize = total.unsignedLongLongValue;
      if (avail)
        v.FreeSpace = avail.unsignedLongLongValue;

      NSNumber *isLocal = vals[NSURLVolumeIsLocalKey];
      NSNumber *isRemovable = vals[NSURLVolumeIsRemovableKey];
      NSNumber *isEjectable = vals[NSURLVolumeIsEjectableKey];
      if (isLocal && !isLocal.boolValue)
        v.Type = "Remote";
      else if ((isRemovable && isRemovable.boolValue) || (isEjectable && isEjectable.boolValue))
        v.Type = "Removable";

      FillFromStatfs(v, v.MountPath.c_str());
      if (v.Type == "Removable" && (v.FileSystem == "cd9660" || v.FileSystem == "udf"))
        v.Type = "CD-ROM";
      volumes.push_back(v);
    }
  }
}

unsigned long long MountsFingerprint()
{
  const int num = getfsstat(NULL, 0, MNT_NOWAIT);
  if (num <= 0)
    return 0;
  std::vector<struct statfs> buf((size_t)num);
  const int got = getfsstat(&buf[0], (int)(sizeof(struct statfs) * (size_t)num), MNT_NOWAIT);
  if (got <= 0)
    return 0;
  unsigned long long h = 1469598103934665603ULL;   // FNV-1a offset basis
  h ^= (unsigned long long)got;
  h *= 1099511628211ULL;
  for (int i = 0; i < got && i < num; i++)
  {
    const struct statfs &fs = buf[(size_t)i];
    const char *p = fs.f_mntonname;
    for (; *p; p++)
    {
      h ^= (unsigned long long)(unsigned char)*p;
      h *= 1099511628211ULL;
    }
    h ^= (unsigned long long)fs.f_fsid.val[0];
    h *= 1099511628211ULL;
    h ^= (unsigned long long)fs.f_fsid.val[1];
    h *= 1099511628211ULL;
  }
  return h;
}

bool RealPath(const char *path, std::string &result)
{
  result.clear();
  if (!path || !*path)
    return false;
  char buf[PATH_MAX + 1];
  if (!realpath(path, buf))
    return false;
  result = buf;
  return true;
}

}

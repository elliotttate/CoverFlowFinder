// MacVolume.cpp -- what GetWorkDir (CPP/7zip/UI/Common/WorkDir.cpp) needs to know about the volume
// an archive is on. Windows asks GetDriveType for DRIVE_REMOVABLE / DRIVE_CDROM (01b §4.8, the
// Options > Folders "Use for removable drives only" box); the macOS answer is the volume's
// removable-media or ejectable flag (a USB stick, an SD card, an optical disc, a mounted image),
// read from CoreFoundation's URL resource values. Called through the guarded hunk in WorkDir.cpp
// (Mac/docs/upstream-patches.md).

#include <CoreFoundation/CoreFoundation.h>

#include "../../../CPP/Common/MyString.h"

bool MacPath_IsOnRemovableVolume(const FString &path);

static bool CopyBoolResource(CFURLRef url, CFStringRef key)
{
  CFTypeRef value = NULL;
  bool result = false;
  if (CFURLCopyResourcePropertyForKey(url, key, &value, NULL) && value)
  {
    if (CFGetTypeID(value) == CFBooleanGetTypeID())
      result = CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
  }
  return result;
}

bool MacPath_IsOnRemovableVolume(const FString &path)
{
  // The archive itself may not exist yet (a new archive): its folder decides.
  AString p ((const char *)path);
  while (p.Len() > 1)
  {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        (const UInt8 *)p.Ptr(), (CFIndex)p.Len(), false);
    if (url)
    {
      CFTypeRef reachable = NULL;
      const bool exists = CFURLCopyResourcePropertyForKey(url, kCFURLVolumeIdentifierKey, &reachable, NULL) && reachable;
      if (reachable)
        CFRelease(reachable);
      if (exists)
      {
        const bool removable = CopyBoolResource(url, kCFURLVolumeIsRemovableKey);
        const bool ejectable = CopyBoolResource(url, kCFURLVolumeIsEjectableKey);
        const bool internal = CopyBoolResource(url, kCFURLVolumeIsInternalKey);
        CFRelease(url);
        return removable || (ejectable && !internal);
      }
      CFRelease(url);
    }
    const int slash = p.ReverseFind('/');
    if (slash <= 0)
      break;
    p.DeleteFrom((unsigned)slash);
  }
  return false;
}

// RootFolderMac.cpp -- see RootFolderMac.h

#include "RootFolderMac.h"

#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <dirent.h>
#include <pwd.h>
#include <unistd.h>

#include <vector>

#include <errno.h>
#include <string.h>
#include "../../../CPP/Common/ComTry.h"
#include "../../../CPP/Common/Defs.h"
#include "../../../CPP/Windows/FileIO.h"
#include "../../../CPP/Common/StringConvert.h"
#include "../../../CPP/Windows/FileName.h"
#include "../../../CPP/Windows/PropVariant.h"
#include "../../../CPP/Windows/ResourceString.h"
#include "../../../CPP/7zip/PropID.h"

#include "FSFolderMac.h"
#include "MacFileOps.h"

using namespace NWindows;
using namespace NFile;

namespace NMacFolders {

static FString HomeDir()
{
  const char *h = getenv("HOME");
  if (!h || !*h)
  {
    const struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir)
      h = pw->pw_dir;
  }
  FString s(h ? h : "/");
  NName::NormalizeDirPathPrefix(s);
  return s;
}

void RootFolder_GetNames(UString names[kNumRootFolderItems])
{
  names[ROOT_INDEX_COMPUTER] = MyLoadString(7100);     // IDS_COMPUTER
  if (names[ROOT_INDEX_COMPUTER].IsEmpty())
    names[ROOT_INDEX_COMPUTER] = "Computer";
  names[ROOT_INDEX_VOLUMES] = "Volumes";
  names[ROOT_INDEX_HOME] = "Home";
  names[ROOT_INDEX_DOCUMENTS] = MyLoadString(7102);    // IDS_DOCUMENTS
  if (names[ROOT_INDEX_DOCUMENTS].IsEmpty())
    names[ROOT_INDEX_DOCUMENTS] = "Documents";
}

static HRESULT MakeFsFolder(const FString &path, IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CFSFolderMac *spec = new CFSFolderMac;
  CMyComPtr<IFolderFolder> folder = spec;
  RINOK(spec->Init(path))
  *resultFolder = folder.Detach();
  return S_OK;
}

static HRESULT MakeVolumesFolder(IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CVolumesFolderMac *spec = new CVolumesFolderMac;
  CMyComPtr<IFolderFolder> folder = spec;
  RINOK(folder->LoadItems())
  *resultFolder = folder.Detach();
  return S_OK;
}

static HRESULT MakeRootFolder(IFolderFolder **resultFolder)
{
  *resultFolder = NULL;
  CRootFolderMac *spec = new CRootFolderMac;
  CMyComPtr<IFolderFolder> folder = spec;
  spec->Init();
  *resultFolder = folder.Detach();
  return S_OK;
}

// ---- CRootFolderMac ----------------------------------------------------------------

static const Byte kRootProps[] = { kpidName };

void CRootFolderMac::Init()
{
  RootFolder_GetNames(_names);
}

Z7_COM7F_IMF(CRootFolderMac::LoadItems())
{
  Init();
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = kNumRootFolderItems;
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetProperty(UInt32 itemIndex, PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  if (itemIndex >= kNumRootFolderItems)
    return E_INVALIDARG;
  switch (propID)
  {
    case kpidIsDir: prop = true; break;
    case kpidName: prop = _names[itemIndex]; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::BindToFolder(UInt32 index, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  switch (index)
  {
    case ROOT_INDEX_COMPUTER: return MakeFsFolder(FString("/"), resultFolder);
    case ROOT_INDEX_VOLUMES: return MakeVolumesFolder(resultFolder);
    case ROOT_INDEX_HOME: return MakeFsFolder(HomeDir(), resultFolder);
    case ROOT_INDEX_DOCUMENTS: return MakeFsFolder(HomeDir() + "Documents/", resultFolder);
    default: return E_INVALIDARG;
  }
  COM_TRY_END
}

static bool AreEqualNames(const UString &path, const UString &name)
{
  const unsigned len = name.Len();
  if (len > path.Len() || len + 1 < path.Len())
    return false;
  if (len + 1 == path.Len() && !IS_PATH_SEPAR(path[len]))
    return false;
  return path.IsPrefixedBy_NoCase(name);
}

Z7_COM7F_IMF(CRootFolderMac::BindToFolder(const wchar_t *name, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  UString name2 = name;
  name2.Trim();

  if (name2.IsEmpty())
    return MakeRootFolder(resultFolder);

  for (unsigned i = 0; i < kNumRootFolderItems; i++)
    if (AreEqualNames(name2, _names[i]))
      return BindToFolder((UInt32)i, resultFolder);

  if (AreEqualNames(name2, UString("Computer")) || AreEqualNames(name2, UString("My Computer")))
    return BindToFolder((UInt32)ROOT_INDEX_COMPUTER, resultFolder);
  if (AreEqualNames(name2, UString("Documents")) || AreEqualNames(name2, UString("My Documents")))
    return BindToFolder((UInt32)ROOT_INDEX_DOCUMENTS, resultFolder);

  if (name2[0] == L'~')
  {
    UString rest = name2.Ptr(1);
    if (rest.IsEmpty() || IS_PATH_SEPAR(rest[0]))
    {
      FString p = HomeDir();
      if (!rest.IsEmpty())
        p += us2fs(rest.Ptr(1));
      NName::NormalizeDirPathPrefix(p);
      return MakeFsFolder(p, resultFolder);
    }
  }

  if (!NName::IsAbsolutePath(name2))
    return E_INVALIDARG;
  FString p = us2fs(name2);
  NName::NormalizeDirPathPrefix(p);
  return MakeFsFolder(p, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CRootFolderMac::BindToParentFolder(IFolderFolder **resultFolder))
{
  *resultFolder = NULL;
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetNumberOfProperties(UInt32 *numProperties))
{
  *numProperties = Z7_ARRAY_SIZE(kRootProps);
  return S_OK;
}

IMP_IFolderFolder_GetProp(CRootFolderMac::GetPropertyInfo, kRootProps)

Z7_COM7F_IMF(CRootFolderMac::GetFolderProperty(PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidType: prop = "RootFolder"; break;
    case kpidPath: prop = ""; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetItemName(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= kNumRootFolderItems)
    return E_INVALIDARG;
  *name = _names[index].Ptr();
  *len = _names[index].Len();
  return S_OK;
}

Z7_COM7F_IMF(CRootFolderMac::GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len))
{
  UNUSED_VAR(index)
  *name = NULL;
  *len = 0;
  return S_OK;
}

Z7_COM7F_IMF2(UInt64, CRootFolderMac::GetItemSize(UInt32 index))
{
  UNUSED_VAR(index)
  return 0;
}

// ---- CVolumesFolderMac (FSDrives) ----------------------------------------------------

static const Byte kVolProps[] =
{
  kpidName,
  kpidTotalSize,
  kpidFreeSpace,
  kpidType,
  kpidVolumeName,
  kpidFileSystem,
  kpidClusterSize
};

Z7_COM7F_IMF(CVolumesFolderMac::LoadItems())
{
  COM_TRY_BEGIN
  _volumes.Clear();
  _mountsFingerprint = NMacFileOps::MountsFingerprint();
  std::vector<NMacFileOps::CVolumeInfo> volumes;
  NMacFileOps::GetMountedVolumes(volumes);
  for (size_t i = 0; i < volumes.size(); i++)
  {
    const NMacFileOps::CVolumeInfo &src = volumes[i];
    CVolumeItem v;
    v.Name = MultiByteToUnicodeString(AString(src.Name.c_str()), CP_UTF8);
    v.MountPath = src.MountPath.c_str();
    NName::NormalizeDirPathPrefix(v.MountPath);
    v.Label = MultiByteToUnicodeString(AString(src.Label.c_str()), CP_UTF8);
    v.FileSystem = MultiByteToUnicodeString(AString(src.FileSystem.c_str()), CP_UTF8);
    v.Type = MultiByteToUnicodeString(AString(src.Type.c_str()), CP_UTF8);
    v.TotalSize = src.TotalSize;
    v.FreeSpace = src.FreeSpace;
    v.ClusterSize = src.ClusterSize;
    _volumes.Add(v);
  }
  return S_OK;
  COM_TRY_END
}

// IFolderWasChanged: the FSDrives equivalent of "poll the drive mask" (01 section 6.3).
Z7_COM7F_IMF(CVolumesFolderMac::WasChanged(Int32 *wasChanged))
{
  const UInt64 fingerprint = NMacFileOps::MountsFingerprint();
  *wasChanged = BoolToInt(fingerprint != _mountsFingerprint);
  _mountsFingerprint = fingerprint;
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = _volumes.Size();
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetProperty(UInt32 itemIndex, PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  if (itemIndex >= _volumes.Size())
    return E_INVALIDARG;
  const CVolumeItem &v = _volumes[itemIndex];
  switch (propID)
  {
    case kpidIsDir: prop = true; break;
    case kpidName: prop = v.Name; break;
    case kpidVolumeName: prop = v.Label.IsEmpty() ? v.Name : v.Label; break;
    case kpidTotalSize: prop = v.TotalSize; break;
    case kpidFreeSpace: prop = v.FreeSpace; break;
    case kpidClusterSize: prop = (UInt32)v.ClusterSize; break;
    case kpidType: prop = v.Type; break;
    case kpidFileSystem: prop = v.FileSystem; break;
    // The name to use when copying the volume out (FSDrives.cpp uses "<drive>.<fs>").
    case kpidOutName: prop = v.Name; break;
    // The mount point, so the panel can show and navigate to it.
    case kpidPath: prop = fs2us(v.MountPath); break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::BindToFolder(UInt32 index, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  if (index >= _volumes.Size())
    return E_INVALIDARG;
  return MakeFsFolder(_volumes[index].MountPath, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::BindToFolder(const wchar_t *name, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  UString name2 = name;
  name2.Trim();
  FOR_VECTOR (i, _volumes)
    if (AreEqualNames(name2, _volumes[i].Name))
      return BindToFolder((UInt32)i, resultFolder);
  if (!NName::IsAbsolutePath(name2))
    return E_INVALIDARG;
  FString p = us2fs(name2);
  NName::NormalizeDirPathPrefix(p);
  return MakeFsFolder(p, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::BindToParentFolder(IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  return MakeRootFolder(resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CVolumesFolderMac::GetNumberOfProperties(UInt32 *numProperties))
{
  *numProperties = Z7_ARRAY_SIZE(kVolProps);
  return S_OK;
}

IMP_IFolderFolder_GetProp(CVolumesFolderMac::GetPropertyInfo, kVolProps)

Z7_COM7F_IMF(CVolumesFolderMac::GetFolderProperty(PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidType: prop = "FSDrives"; break;
    case kpidPath: prop = "Volumes"; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetItemName(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= _volumes.Size())
    return E_INVALIDARG;
  *name = _volumes[index].Name.Ptr();
  *len = _volumes[index].Name.Len();
  return S_OK;
}

Z7_COM7F_IMF(CVolumesFolderMac::GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len))
{
  UNUSED_VAR(index)
  *name = NULL;
  *len = 0;
  return S_OK;
}

Z7_COM7F_IMF2(UInt64, CVolumesFolderMac::GetItemSize(UInt32 index))
{
  UNUSED_VAR(index)
  return 0;
}

}

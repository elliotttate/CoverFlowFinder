// RootFolderMac.h -- the virtual root (RootFolder.cpp) and the volumes list (FSDrives.cpp)
// for macOS (01-fm-feature-inventory.md sections 6.2 / 6.3, section 9 #5).
// Root items: Computer ("/"), Volumes, Home, Documents.

#ifndef ZIP7_INC_MAC_ROOT_FOLDER_H
#define ZIP7_INC_MAC_ROOT_FOLDER_H

#include "../../../CPP/Common/Common.h"
#include "../../../CPP/Common/MyCom.h"
#include "../../../CPP/Common/MyString.h"
#include "../../../CPP/7zip/UI/FileManager/IFolder.h"

namespace NMacFolders {

enum
{
  ROOT_INDEX_COMPUTER = 0,
  ROOT_INDEX_VOLUMES,
  ROOT_INDEX_HOME,
  ROOT_INDEX_DOCUMENTS,
  kNumRootFolderItems
};

// Localized names of the root entries (7100 Computer, 7102 Documents; "Volumes", "Home").
void RootFolder_GetNames(UString names[kNumRootFolderItems]);

class CRootFolderMac Z7_final:
  public IFolderFolder,
  public IFolderGetItemName,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderFolder)
    Z7_COM_QI_ENTRY(IFolderGetItemName)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IFolderFolder)
  Z7_IFACE_COM7_IMP(IFolderGetItemName)

  UString _names[kNumRootFolderItems];
public:
  void Init();
};

struct CVolumeItem
{
  UString Name;         // /Volumes entry name ("Macintosh HD" for "/")
  FString MountPath;    // mount point, trailing '/'
  UString Label;        // localized volume name (kpidVolumeName)
  UString FileSystem;   // statfs f_fstypename
  UString Type;         // "Fixed", "Removable", "Remote", "CD-ROM"
  UInt64 TotalSize;
  UInt64 FreeSpace;
  UInt64 ClusterSize;
  CVolumeItem(): TotalSize(0), FreeSpace(0), ClusterSize(0) {}
};

class CVolumesFolderMac Z7_final:
  public IFolderFolder,
  public IFolderGetItemName,
  public IFolderWasChanged,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderFolder)
    Z7_COM_QI_ENTRY(IFolderGetItemName)
    Z7_COM_QI_ENTRY(IFolderWasChanged)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IFolderFolder)
  Z7_IFACE_COM7_IMP(IFolderGetItemName)
  Z7_IFACE_COM7_IMP(IFolderWasChanged)

  CObjectVector<CVolumeItem> _volumes;
  UInt64 _mountsFingerprint;    // getfsstat digest; changes on mount / unmount
public:
  CVolumesFolderMac(): _mountsFingerprint(0) {}
  const CObjectVector<CVolumeItem> &Volumes() const { return _volumes; }
};

}

#endif

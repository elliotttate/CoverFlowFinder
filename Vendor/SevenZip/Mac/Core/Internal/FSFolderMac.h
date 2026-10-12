// FSFolderMac.h -- IFolderFolder for a directory: the macOS FSFolder (upstream
// UI/FileManager/FSFolder.cpp + FSFolderCopy.cpp), built on the portable NWindows::NFile
// layer plus the Cocoa helpers in MacFileOps.h. Implements the full 7zFM contract for a
// file-system folder (01-fm-feature-inventory.md section 6.4):
//
//   IFolderFolder            columns and navigation
//   IFolderGetItemName       zero-copy name/prefix/size for the list view
//   IFolderWasChanged        FSEvents (section 3.17, section 9 #20)
//   IFolderOperations        copy / move / delete / rename / mkdir / create file / comment
//   IFolderCalcItemFullSize  F3 on a folder (section 3.11)
//   IFolderGetItemFullSize   same, as a value
//   IFolderSetFlatMode       recursive listing with kpidPrefix (section 3.4)
//   IFolderClone             used by the copy threads and the drag data object
//   IFolderCompare           sorting rules of PanelSort.cpp

#ifndef ZIP7_INC_MAC_FS_FOLDER_H
#define ZIP7_INC_MAC_FS_FOLDER_H

#include "../../../CPP/Common/Common.h"
#include "../../../CPP/Common/MyCom.h"
#include "../../../CPP/Common/MyString.h"
#include "../../../CPP/Windows/FileFind.h"
#include "../../../CPP/Windows/TimeUtils.h"
#include "../../../CPP/7zip/UI/FileManager/IFolder.h"
#include "../../../CPP/7zip/UI/FileManager/TextPairs.h"

namespace NMacFolders {

class CFSEventsWatcher;

struct CFSItem
{
  NWindows::NFile::NFind::CFileInfo Info;  // lstat of the entry (Info.CTime = st_ctimespec)
  CFiTime BirthTime;                       // st_birthtimespec -> kpidCTime ("Created")
  UString Name;                            // Info.Name as UString
  UString LinkTarget;                      // readlink() target ("Link" column), empty if none
  UString User;                            // getpwuid, resolved lazily
  UString Group;                           // getgrgid, resolved lazily
  bool OwnerResolved;                      // User / Group were looked up
  int Parent;                              // index in _folders (flat mode), -1 = top level
  UInt64 PackSize;                         // st_blocks * 512 (physical size on disk)
  UInt64 NumFolders;                       // valid when FolderStat_Defined
  UInt64 NumFiles;                         // valid when FolderStat_Defined
  UInt32 WinAttrib;                        // Windows attribute bits mapped from mode + st_flags
  UInt32 BsdFlags;                         // st_flags
  bool FolderStat_Defined;                 // CalcItemFullSize() was run for this dir
  bool IsDir;                              // navigable as a directory (dir, or symlink to dir)
  bool IsRealDir;                          // lstat says directory (never a symlink)
  bool IsLink;                             // S_ISLNK
  CFSItem():
      OwnerResolved(false), Parent(-1), PackSize(0), NumFolders(0), NumFiles(0),
      WinAttrib(0), BsdFlags(0),
      FolderStat_Defined(false), IsDir(false), IsRealDir(false), IsLink(false)
    { FiTime_Clear(BirthTime); }
};

class CFSFolderMac Z7_final:
  public IFolderFolder,
  public IFolderGetItemName,
  public IFolderWasChanged,
  public IFolderOperations,
  public IFolderCalcItemFullSize,
  public IFolderGetItemFullSize,
  public IFolderSetFlatMode,
  public IFolderClone,
  public IFolderCompare,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderFolder)
    Z7_COM_QI_ENTRY(IFolderGetItemName)
    Z7_COM_QI_ENTRY(IFolderWasChanged)
    Z7_COM_QI_ENTRY(IFolderOperations)
    Z7_COM_QI_ENTRY(IFolderCalcItemFullSize)
    Z7_COM_QI_ENTRY(IFolderGetItemFullSize)
    Z7_COM_QI_ENTRY(IFolderSetFlatMode)
    Z7_COM_QI_ENTRY(IFolderClone)
    Z7_COM_QI_ENTRY(IFolderCompare)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IFolderFolder)
  Z7_IFACE_COM7_IMP(IFolderGetItemName)
  Z7_IFACE_COM7_IMP(IFolderWasChanged)
  Z7_IFACE_COM7_IMP(IFolderOperations)
  Z7_IFACE_COM7_IMP(IFolderCalcItemFullSize)
  Z7_IFACE_COM7_IMP(IFolderGetItemFullSize)
  Z7_IFACE_COM7_IMP(IFolderSetFlatMode)
  Z7_IFACE_COM7_IMP(IFolderClone)
  Z7_IFACE_COM7_IMP(IFolderCompare)

  FString _path;                    // absolute, trailing '/'
  CObjectVector<CFSItem> _items;
  FStringVector _folders;           // flat mode: relative dir prefixes with trailing '/'
  UStringVector _prefixesU;         // the same prefixes as UString, for IFolderGetItemName
  CFSEventsWatcher *_watcher;
  CPairsStorage _comments;          // descript.ion (01 section 6.4, section 9 #19)
  bool _commentsAreLoaded;
  bool _flatMode;
  bool _showHidden;                 // list dotfiles / UF_HIDDEN entries (Windows: always)
  bool _deleteToTrash;              // IFolderOperations::Delete -> Trash (section 9 #9)

  HRESULT BindToFolderSpec(const FString &path, IFolderFolder **resultFolder) const;
  HRESULT LoadSubItems(int dirItem, const FString &relPrefix);
  void FillItem(CFSItem &item, const FString &fullPath, const struct stat &st) const;
  bool LoadComments();
  bool SaveComments();
  void GetAbsPath(const wchar_t *name, FString &absPath) const;
  void ResetWatcher();

public:
  CFSFolderMac();
  ~CFSFolderMac();

  // Fails with E_INVALIDARG when `path` is not a directory.
  HRESULT Init(const FString &path);
  const FString &GetPath() const { return _path; }
  // Relative path of an item (flat-mode prefix + name).
  FString GetRelPath(const CFSItem &item) const;
  FString GetItemPath(UInt32 index) const;
  unsigned NumItems() const { return _items.Size(); }
  const CFSItem &Item(unsigned i) const { return _items[i]; }

  bool GetShowHidden() const { return _showHidden; }
  void SetShowHidden(bool show) { _showHidden = show; }
  bool GetDeleteToTrash() const { return _deleteToTrash; }
  void SetDeleteToTrash(bool toTrash) { _deleteToTrash = toTrash; }
  bool GetFlatMode() const { return _flatMode; }

  // The watched directory was deleted or renamed: the panel must navigate up.
  bool WatchedDirectoryIsGone() const;

  // Delete with an explicit destination (Trash or permanent), whatever _deleteToTrash says.
  HRESULT DeleteItems(const UInt32 *indices, UInt32 numItems, bool toTrash, IProgress *progress);

  static bool IsDirectory(const FString &path);
};

// FSFolderCopy.cpp's exported entry point, for drag & drop and for CopyFrom():
// copies (or moves) a list of absolute source paths into destDirPrefix.
HRESULT CopyFileSystemItems(const UStringVector &itemsPaths, const FString &destDirPrefix,
    bool moveMode, IFolderOperationsExtractCallback *callback);

}

#endif

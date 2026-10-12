// FSFolderMac.cpp -- see FSFolderMac.h.
// Modelled on UI/FileManager/FSFolder.cpp and FSFolderCopy.cpp (Windows); every deliberate
// difference is listed in ai/api/fsfolder.md.

#include "FSFolderMac.h"

#include <dirent.h>
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

#include "../../../CPP/Common/ComTry.h"
#include "../../../CPP/Common/Defs.h"
#include "../../../CPP/Common/MyBuffer.h"
#include "../../../CPP/Common/StringConvert.h"
#include "../../../CPP/Common/UTFConvert.h"
#include "../../../CPP/Common/Wildcard.h"
#include "../../../CPP/Windows/ErrorMsg.h"
#include "../../../CPP/Windows/FileDir.h"
#include "../../../CPP/Windows/FileIO.h"
#include "../../../CPP/Windows/FileName.h"
#include "../../../CPP/Windows/PropVariant.h"
#include "../../../CPP/Windows/TimeUtils.h"
#include "../../../CPP/7zip/PropID.h"
#include "../../../CPP/7zip/Common/FilePathAutoRename.h"

#include "FSEventsWatcher.h"
#include "MacFileOps.h"
#include "RootFolderMac.h"

using namespace NWindows;
using namespace NFile;
using namespace NFind;

namespace NMacFolders {

// Column order as 7zFM shows them for FSFolder (FSFolder.cpp kProps, 01 section 3.2), which is
// also the order of the header's column menu (ShowColumnsContextMenu lists `_columns`). 7zFM 26.03
// with FS_SHOW_LINKS_INFO lists "Name, Size, Modified, Created, Accessed, Metadata Changed,
// Attributes, Packed Size, iNode, Links, Comment, Folders, Files, Link" -- Link being the
// kpidNtReparse raw property, which comes after the regular ones (listfeel.md section 5). The
// macOS-only kpidPosixAttrib / kpidUser / kpidGroup (in place of the Windows security column,
// 01 section 9 #7, #8) follow Link. kpidPrefix must stay last because GetNumberOfProperties()
// drops it outside flat mode, exactly like Windows.
static const Byte kProps[] =
{
  kpidName,          //  4
  kpidSize,          //  7
  kpidMTime,         // 12
  kpidCTime,         // 10  (birth time on macOS)
  kpidATime,         // 11
  kpidChangeTime,    // 98  (st_ctimespec, "Metadata Changed")
  kpidAttrib,        //  9
  kpidPackSize,      //  8  (physical size on disk)
  kpidINode,         // 91
  kpidLinks,         // 37
  kpidComment,       // 28  (descript.ion)
  kpidNumSubDirs,    // 31  (after CalcItemFullSize)
  kpidNumSubFiles,   // 32
  kpidNtReparse,     // 89  ("Link": the symlink target)
  kpidPosixAttrib,   // 53  ("Mode")
  kpidUser,          // 25
  kpidGroup,         // 26
  kpidPrefix         // 30  (flat mode only)
};

static CFSTR const kDescriptionFileName = FTEXT("descript.ion");

static const size_t kCopyBufSize = 1 << 16;

// ---- helpers ---------------------------------------------------------------------

static bool LStat(const FString &path, struct stat &st)
{
  return lstat(path, &st) == 0;
}

static UString ReadLinkTarget(const FString &path)
{
  char buf[4096];
  const ssize_t len = readlink(path, buf, sizeof(buf) - 1);
  if (len <= 0)
    return UString();
  buf[len] = 0;
  return MultiByteToUnicodeString(AString(buf), CP_UTF8);
}

/* Windows attribute bits from the POSIX mode + the BSD flags, so the Attributes column
   ("RHS8DAdNTsLCOIEV" + the mode string, PropIDUtils.cpp ConvertWinAttribToString) shows
   something meaningful on macOS (01 section 9 #7):
     D  directory                  S_ISDIR
     A  archive                    every non-directory (engine convention)
     R  read only                  no write bit, or UF_IMMUTABLE / SF_IMMUTABLE (Finder "Locked")
     L  reparse point              S_ISLNK
     H  hidden                     leading '.' or UF_HIDDEN
     C  compressed                 UF_COMPRESSED (HFS+/APFS transparent compression)
     O  offline                    SF_DATALESS (iCloud / dataless placeholder)
     S  system                     SF_RESTRICTED (SIP) or SF_NOUNLINK
     T  temporary                  UF_TRACKED is not that; unused
   plus FILE_ATTRIBUTE_UNIX_EXTENSION and (mode << 16) from the engine's own mapping. */
static UInt32 WinAttribFromPosix(const struct stat &st, const FString &name)
{
  UInt32 attrib = Get_WinAttribPosix_From_PosixMode((UInt32)st.st_mode);
  if (S_ISLNK(st.st_mode))
    attrib |= FILE_ATTRIBUTE_REPARSE_POINT;
  if (!name.IsEmpty() && name[0] == '.')
    attrib |= FILE_ATTRIBUTE_HIDDEN;
  const UInt32 flags = (UInt32)st.st_flags;
  if (flags & UF_HIDDEN)
    attrib |= FILE_ATTRIBUTE_HIDDEN;
  if (flags & (UF_IMMUTABLE | SF_IMMUTABLE))
    attrib |= FILE_ATTRIBUTE_READONLY;
  if (flags & UF_COMPRESSED)
    attrib |= FILE_ATTRIBUTE_COMPRESSED;
#ifdef SF_DATALESS
  if (flags & SF_DATALESS)
    attrib |= FILE_ATTRIBUTE_OFFLINE;
#endif
#ifdef SF_RESTRICTED
  if (flags & SF_RESTRICTED)
    attrib |= FILE_ATTRIBUTE_SYSTEM;
#endif
  if (flags & SF_NOUNLINK)
    attrib |= FILE_ATTRIBUTE_SYSTEM;
  return attrib;
}

static bool IsHiddenEntry(const FString &name, const struct stat &st)
{
  if (!name.IsEmpty() && name[0] == '.')
    return true;
  return (st.st_flags & UF_HIDDEN) != 0;
}

// remove() refuses locked / read-only items; clear the flags first, like Windows'
// DeleteFileAlways clears FILE_ATTRIBUTE_READONLY (01 section 6.4).
static void ClearProtection(const FString &path)
{
  struct stat st;
  if (lstat(path, &st) != 0)
    return;
  if (st.st_flags & (UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND))
    chflags(path, st.st_flags & ~(unsigned)(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND));
  if (!S_ISLNK(st.st_mode) && (st.st_mode & 0222) == 0)
    chmod(path, st.st_mode | 0200);
}

static bool DeleteFileForced(const FString &path)
{
  if (remove(path) == 0)
    return true;
  const int e = errno;
  ClearProtection(path);
  errno = e;
  return remove(path) == 0;
}

static bool RemoveDirForced(const FString &path)
{
  if (rmdir(path) == 0)
    return true;
  const int e = errno;
  ClearProtection(path);
  errno = e;
  return rmdir(path) == 0;
}

// The POSIX build of Windows/FileDir.cpp has no RemoveDirWithSubItems (it is inside
// #ifdef _WIN32), so the recursive delete lives here.
static bool RemoveDirWithSubItemsMac(const FString &path)
{
  struct stat st;
  if (lstat(path, &st) != 0)
    return false;
  if (!S_ISDIR(st.st_mode))
  {
    // a symlink to a directory is unlinked, never followed
    return DeleteFileForced(path);
  }
  {
    FString prefix(path);
    prefix.Add_PathSepar();
    const unsigned prefixLen = prefix.Len();
    CEnumerator enumerator;
    enumerator.SetDirPrefix(prefix);
    CDirEntry de;
    bool isError = false;
    int lastErrno = 0;
    for (;;)
    {
      bool found;
      if (!enumerator.Next(de, found))
      {
        lastErrno = errno;
        isError = true;
        break;
      }
      if (!found)
        break;
      prefix.DeleteFrom(prefixLen);
      prefix += de.Name;
      struct stat st2;
      if (lstat(prefix, &st2) != 0)
      {
        lastErrno = errno;
        isError = true;
        continue;
      }
      const bool ok = S_ISDIR(st2.st_mode) ? RemoveDirWithSubItemsMac(prefix) : DeleteFileForced(prefix);
      if (!ok)
      {
        lastErrno = errno;
        isError = true;
      }
    }
    if (isError)
    {
      errno = lastErrno;
      return false;
    }
  }
  return RemoveDirForced(path);
}

// Recursive size / file / folder counter (upstream CFsFolderStat).
struct CFsStatMac
{
  UInt64 NumFolders;
  UInt64 NumFiles;
  UInt64 Size;
  UInt64 PackSize;
  IProgress *Progress;

  CFsStatMac(): NumFolders(0), NumFiles(0), Size(0), PackSize(0), Progress(NULL) {}

  HRESULT Enumerate(const FString &path)   // path without a trailing separator
  {
    if (Progress)
      RINOK(Progress->SetCompleted(NULL))
    FString prefix(path);
    prefix.Add_PathSepar();
    const unsigned prefixLen = prefix.Len();
    CEnumerator enumerator;
    enumerator.SetDirPrefix(prefix);
    for (;;)
    {
      CDirEntry de;
      bool found;
      if (!enumerator.Next(de, found))
        return S_OK;      // unreadable directory: counted as empty, like upstream
      if (!found)
        break;
      prefix.DeleteFrom(prefixLen);
      prefix += de.Name;
      struct stat st;
      if (!LStat(prefix, st))
        continue;
      if (S_ISDIR(st.st_mode))
      {
        NumFolders++;
        PackSize += (UInt64)st.st_blocks * 512;
        RINOK(Enumerate(prefix))
      }
      else
      {
        NumFiles++;
        Size += (UInt64)st.st_size;
        PackSize += (UInt64)st.st_blocks * 512;
      }
    }
    return S_OK;
  }
};

// ---- copy engine (FSFolderCopy.cpp) ----------------------------------------------

static HRESULT SendMessageError(IFolderOperationsExtractCallback *callback,
    const UString &message, const FString &fileName)
{
  UString s(message);
  s += " : ";
  s += fs2us(fileName);
  return callback->ShowMessage(s);
}

static HRESULT SendMessageError(IFolderOperationsExtractCallback *callback,
    const char *message, const FString &fileName)
{
  return SendMessageError(callback, MultiByteToUnicodeString(message), fileName);
}

static UString LastErrorMessage()
{
  DWORD code = (DWORD)errno;
  if (code == 0)
    code = (DWORD)E_FAIL;
  return NError::MyFormatMessage(HRESULT_FROM_WIN32(code));
}

static HRESULT SendLastErrorMessage(IFolderOperationsExtractCallback *callback, const FString &fileName)
{
  return SendMessageError(callback, LastErrorMessage(), fileName);
}

struct CCopyStateMac
{
  UInt64 TotalSize;
  UInt64 StartPos;     // bytes already reported as completed
  IFolderOperationsExtractCallback *Callback;
  bool MoveMode;

  CCopyStateMac(): TotalSize(0), StartPos(0), Callback(NULL), MoveMode(false) {}
  HRESULT CallProgress() { return Callback->SetCompleted(&StartPos); }
};

// Restores the source's metadata on the destination: mode / owner / ACL / xattrs (and with
// them the resource fork), then the timestamps, then the BSD flags (last, because
// UF_IMMUTABLE would block the other two).
static void CopyAttributes(const FString &src, const FString &dest, const struct stat &st)
{
  const bool isLink = S_ISLNK(st.st_mode);
  NMacFileOps::CopyMetadata((const char *)src, (const char *)dest, isLink);
  CFiTime aTime = st.st_atimespec;
  CFiTime mTime = st.st_mtimespec;
  if (isLink)
    NDir::SetLinkFileTime(dest, NULL, &aTime, &mTime);
  else
    NDir::SetDirTime(dest, NULL, &aTime, &mTime);
  const UInt32 userFlags = (UInt32)st.st_flags & (UInt32)(UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_HIDDEN);
  if (userFlags != 0)
    chflags(dest, userFlags);
}

static HRESULT CopySymLink(CCopyStateMac &state, const FString &srcPath, const FString &destPath,
    const struct stat &st)
{
  const UString target = ReadLinkTarget(srcPath);
  if (target.IsEmpty())
  {
    RINOK(SendLastErrorMessage(state.Callback, srcPath))
    return E_ABORT;
  }
  const AString targetUtf = UnicodeStringToMultiByte(target, CP_UTF8);
  remove(destPath);   // symlink() fails on an existing name
  if (symlink((const char *)targetUtf, (const char *)destPath) != 0)
  {
    RINOK(SendLastErrorMessage(state.Callback, destPath))
    return E_ABORT;
  }
  CopyAttributes(srcPath, destPath, st);
  return S_OK;
}

static HRESULT CopyFileData(CCopyStateMac &state, const FString &srcPath, const FString &destPath,
    const struct stat &st)
{
  HRESULT failure = S_OK;
  FString errorPath;
  bool errorIsErrno = true;
  {
    NIO::CInFile inFile;
    if (!inFile.Open((const char *)srcPath))
    {
      RINOK(SendLastErrorMessage(state.Callback, srcPath))
      return E_ABORT;
    }
    NIO::COutFile outFile;
    outFile.mode_for_Create = (mode_t)(st.st_mode & 07777);
    if (!outFile.Create_ALWAYS(destPath))
    {
      RINOK(SendLastErrorMessage(state.Callback, destPath))
      return E_ABORT;
    }
    CByteArr buf(kCopyBufSize);
    UInt64 done = 0;
    for (;;)
    {
      const ssize_t num = inFile.read_part(buf, kCopyBufSize);
      if (num == 0)
        break;
      if (num < 0)
      {
        failure = E_ABORT;
        errorPath = srcPath;
        break;
      }
      size_t processed = 0;
      const ssize_t written = outFile.write_full(buf, (size_t)num, processed);
      if (written != num || processed != (size_t)num)
      {
        failure = E_ABORT;
        errorPath = destPath;
        break;
      }
      done += (UInt64)num;
      const UInt64 completed = state.StartPos + done;
      // The only cancellation channel: a callback returning != S_OK means "break".
      const HRESULT hr = state.Callback->SetCompleted(&completed);
      if (hr != S_OK)
      {
        failure = hr;
        errorIsErrno = false;
        break;
      }
    }
  }
  if (failure != S_OK)
  {
    // Never leave a truncated destination behind (CopyFileEx does the same on
    // PROGRESS_CANCEL / error).
    remove(destPath);
    if (errorIsErrno)
    {
      RINOK(SendLastErrorMessage(state.Callback, errorPath))
    }
    return failure;
  }
  CopyAttributes(srcPath, destPath, st);
  return S_OK;
}

// CompareFileNames for two paths on the volume of `onVolume` (01 §9 #24): Windows compares paths
// without case (g_CaseSensitive is false, and on macOS too); a case-sensitive volume holds "a" and
// "A" as two files, so copying one onto the other is not a copy onto itself there.
static bool VolumeIsCaseSensitive(const FString &onVolume)
{
  FString p = onVolume;
  struct stat st;
  while (!p.IsEmpty() && lstat((const char *)p, &st) != 0)
  {
    const int slash = p.ReverseFind_PathSepar();
    if (slash <= 0)
    {
      p = "/";
      break;
    }
    p.DeleteFrom((unsigned)slash);
  }
  if (p.IsEmpty())
    p = "/";
  return pathconf((const char *)p, _PC_CASE_SENSITIVE) == 1;
}

static int ComparePathsOnVolume(const FString &a, const FString &b)
{
  if (VolumeIsCaseSensitive(b))
    return MyStringCompare(fs2us(a), fs2us(b));
  return CompareFileNames(fs2us(a), fs2us(b));
}

static HRESULT CopyFile_Ask(CCopyStateMac &state, const FString &srcPath, const struct stat &st,
    const FString &destPath)
{
  if (ComparePathsOnVolume(destPath, srcPath) == 0)
  {
    RINOK(SendMessageError(state.Callback,
        state.MoveMode ? "Cannot move file onto itself"
                       : "Cannot copy file onto itself", destPath))
    return E_ABORT;
  }

  const UInt64 srcSize = (UInt64)st.st_size;
  FILETIME srcTime;
  {
    CFiTime mTime = st.st_mtimespec;
    FiTime_To_FILETIME(mTime, srcTime);
  }

  Int32 writeAskResult = 0;
  CMyComBSTR destPathResult;
  RINOK(state.Callback->AskWrite(
      fs2us(srcPath),
      BoolToInt(false),
      &srcTime, &srcSize,
      fs2us(destPath),
      &destPathResult,
      &writeAskResult))

  if (!IntToBool(writeAskResult))
  {
    if (state.TotalSize >= srcSize)
    {
      state.TotalSize -= srcSize;
      RINOK(state.Callback->SetTotal(state.TotalSize))
    }
    return state.CallProgress();
  }

  const FString destPathNew = destPathResult
      ? us2fs((LPCOLESTR)destPathResult)
      : destPath;
  RINOK(state.Callback->SetCurrentFilePath(fs2us(srcPath)))

  if (state.MoveMode)
  {
    if (rename((const char *)srcPath, (const char *)destPathNew) == 0)
    {
      state.StartPos += srcSize;
      return state.CallProgress();
    }
    if (errno != EXDEV)
    {
      RINOK(SendLastErrorMessage(state.Callback, destPathNew))
      return E_ABORT;
    }
    // different volume: copy + delete, like MOVEFILE_COPY_ALLOWED
  }

  if (S_ISLNK(st.st_mode))
    RINOK(CopySymLink(state, srcPath, destPathNew, st))
  else
    RINOK(CopyFileData(state, srcPath, destPathNew, st))

  if (state.MoveMode)
  {
    if (!DeleteFileForced(srcPath))
    {
      RINOK(SendLastErrorMessage(state.Callback, srcPath))
      return E_ABORT;
    }
  }
  state.StartPos += srcSize;
  return state.CallProgress();
}

static FString CombinePath(const FString &folderPath, const FString &fileName)
{
  FString s(folderPath);
  s.Add_PathSepar();
  s += fileName;
  return s;
}

static bool IsDestChild(const FString &src, const FString &dest)
{
  const unsigned len = src.Len();
  if (dest.Len() < len)
    return false;
  if (dest.Len() != len && dest[len] != FCHAR_PATH_SEPARATOR)
    return false;
  return ComparePathsOnVolume(dest.Left(len), src) == 0;
}

static HRESULT CopyFolder(CCopyStateMac &state,
    const FString &srcPath,    // without a trailing separator
    const FString &destPath)   // without a trailing separator
{
  RINOK(state.CallProgress())

  if (IsDestChild(srcPath, destPath))
  {
    RINOK(SendMessageError(state.Callback,
        state.MoveMode ? "Cannot move folder onto itself"
                       : "Cannot copy folder onto itself", destPath))
    return E_ABORT;
  }

  struct stat srcStat;
  if (!LStat(srcPath, srcStat))
  {
    RINOK(SendLastErrorMessage(state.Callback, srcPath))
    return E_ABORT;
  }

  if (state.MoveMode)
  {
    // Same volume (and no existing non-empty destination): one rename moves the subtree.
    if (rename((const char *)srcPath, (const char *)destPath) == 0)
      return S_OK;
  }

  if (!NDir::CreateComplexDir(destPath))
  {
    RINOK(SendMessageError(state.Callback, "Cannot create folder", destPath))
    return E_ABORT;
  }

  {
    CEnumerator enumerator;
    enumerator.SetDirPrefix(CombinePath(srcPath, FString()));
    for (;;)
    {
      CDirEntry de;
      bool found;
      if (!enumerator.Next(de, found))
      {
        RINOK(SendLastErrorMessage(state.Callback, srcPath))
        return S_OK;
      }
      if (!found)
        break;
      const FString srcPath2 = CombinePath(srcPath, de.Name);
      const FString destPath2 = CombinePath(destPath, de.Name);
      struct stat st;
      if (!LStat(srcPath2, st))
      {
        RINOK(SendLastErrorMessage(state.Callback, srcPath2))
        continue;
      }
      if (S_ISDIR(st.st_mode))
        RINOK(CopyFolder(state, srcPath2, destPath2))
      else
        RINOK(CopyFile_Ask(state, srcPath2, st, destPath2))
    }
  }

  CopyAttributes(srcPath, destPath, srcStat);

  if (state.MoveMode)
  {
    if (!RemoveDirForced(srcPath))
    {
      RINOK(SendMessageError(state.Callback, "Cannot remove folder", srcPath))
      return E_ABORT;
    }
  }
  return S_OK;
}

HRESULT CopyFileSystemItems(const UStringVector &itemsPaths, const FString &destDirPrefix,
    bool moveMode, IFolderOperationsExtractCallback *callback)
{
  if (itemsPaths.IsEmpty())
    return S_OK;
  if (destDirPrefix.IsEmpty() || !callback)
    return E_INVALIDARG;

  CFsStatMac fsStat;
  fsStat.Progress = callback;
  FOR_VECTOR (i, itemsPaths)
  {
    const FString path = us2fs(itemsPaths[i]);
    struct stat st;
    if (!LStat(path, st))
      continue;
    if (S_ISDIR(st.st_mode))
    {
      fsStat.NumFolders++;
      RINOK(fsStat.Enumerate(path))
    }
    else
    {
      fsStat.NumFiles++;
      fsStat.Size += (UInt64)st.st_size;
    }
  }

  RINOK(callback->SetTotal(fsStat.Size))
  RINOK(callback->SetNumFiles(fsStat.NumFiles))
  UInt64 completedSize = 0;
  RINOK(callback->SetCompleted(&completedSize))

  CCopyStateMac state;
  state.TotalSize = fsStat.Size;
  state.StartPos = 0;
  state.Callback = callback;
  state.MoveMode = moveMode;

  FString destPrefix(destDirPrefix);
  NName::NormalizeDirPathPrefix(destPrefix);

  FOR_VECTOR (i, itemsPaths)
  {
    const FString path = us2fs(itemsPaths[i]);
    struct stat st;
    if (!LStat(path, st))
    {
      RINOK(SendMessageError(callback, "Cannot find the file", path))
      continue;
    }
    FString name;
    {
      FString p(path);
      if (p.Len() > 1 && IsPathSepar(p.Back()))
        p.DeleteBack();
      const int pos = p.ReverseFind_PathSepar();
      name = (pos < 0) ? p : p.Ptr((unsigned)pos + 1);
    }
    if (name.IsEmpty())
    {
      RINOK(SendMessageError(callback, "Cannot copy the volume root", path))
      continue;
    }
    FString destPath(destPrefix);
    destPath += name;
    if (S_ISDIR(st.st_mode))
    {
      FString destNoSepar(destPath);
      if (destNoSepar.Len() > 1 && IsPathSepar(destNoSepar.Back()))
        destNoSepar.DeleteBack();
      FString srcNoSepar(path);
      if (srcNoSepar.Len() > 1 && IsPathSepar(srcNoSepar.Back()))
        srcNoSepar.DeleteBack();
      RINOK(CopyFolder(state, srcNoSepar, destNoSepar))
    }
    else
      RINOK(CopyFile_Ask(state, path, st, destPath))
  }
  // A same-volume rename moves a whole subtree without per-byte progress; make sure the
  // progress bar ends full.
  completedSize = state.TotalSize;
  return callback->SetCompleted(&completedSize);
}

// ---- CFSFolderMac ----------------------------------------------------------------

CFSFolderMac::CFSFolderMac():
    _watcher(NULL),
    _commentsAreLoaded(false),
    _flatMode(false),
    _showHidden(true),      // Windows lists hidden files too (FindFirstFile has no filter)
    _deleteToTrash(true)    // macOS Delete -> Trash (01 section 9 #9)
{}

CFSFolderMac::~CFSFolderMac()
{
  delete _watcher;
}

bool CFSFolderMac::IsDirectory(const FString &path)
{
  struct stat st;
  if (stat(path, &st) != 0)
    return false;
  return S_ISDIR(st.st_mode);
}

HRESULT CFSFolderMac::Init(const FString &path)
{
  FString p = path;
  if (p.IsEmpty())
    return E_INVALIDARG;
  if (!NName::IsAbsolutePath(fs2us(p)))
  {
    FString full;
    if (!NDir::MyGetFullPathName(p, full))
      return GetLastError_noZero_HRESULT();
    p = full;
  }
  NName::NormalizeDirPathPrefix(p);
  if (!IsDirectory(p))
    return E_INVALIDARG;
  _path = p;
  _items.Clear();
  _folders.Clear();
  _prefixesU.Clear();
  _comments.Clear();
  _commentsAreLoaded = false;
  ResetWatcher();
  return S_OK;
}

void CFSFolderMac::ResetWatcher()
{
  delete _watcher;
  _watcher = NULL;
}

FString CFSFolderMac::GetRelPath(const CFSItem &item) const
{
  if (item.Parent >= 0)
    return _folders[(unsigned)item.Parent] + item.Info.Name;
  return item.Info.Name;
}

FString CFSFolderMac::GetItemPath(UInt32 index) const
{
  if (index >= _items.Size())
    return _path;
  return _path + GetRelPath(_items[index]);
}

bool CFSFolderMac::WatchedDirectoryIsGone() const
{
  return _watcher != NULL && _watcher->RootChanged();
}

void CFSFolderMac::FillItem(CFSItem &item, const FString &fullPath, const struct stat &st) const
{
  item.Info.SetFrom_stat(st);
  // "Created" = birth time on macOS; st_ctimespec stays as kpidChangeTime.
  item.BirthTime = st.st_birthtimespec;
  item.BsdFlags = (UInt32)st.st_flags;
  item.WinAttrib = WinAttribFromPosix(st, item.Info.Name);
  item.IsRealDir = S_ISDIR(st.st_mode) != 0;
  item.IsLink = S_ISLNK(st.st_mode) != 0;
  item.IsDir = item.IsRealDir;
  item.PackSize = (UInt64)st.st_blocks * 512;
  if (item.IsLink)
  {
    item.LinkTarget = ReadLinkTarget(fullPath);
    struct stat st2;
    if (stat(fullPath, &st2) == 0 && S_ISDIR(st2.st_mode))
      item.IsDir = true;   // a symlink to a directory navigates like a directory
  }
}

HRESULT CFSFolderMac::LoadSubItems(int dirItem, const FString &relPrefix)
{
  const unsigned startIndex = _folders.Size();
  {
    CEnumerator enumerator;
    enumerator.SetDirPrefix(_path + relPrefix);
    for (;;)
    {
      CDirEntry de;
      bool found;
      if (!enumerator.Next(de, found))
      {
        if (dirItem < 0)
          return GetLastError_noZero_HRESULT();
        break;   // an unreadable sub-directory must not kill the whole flat listing
      }
      if (!found)
        break;
      const FString full = _path + relPrefix + de.Name;
      struct stat st;
      if (!LStat(full, st))
        continue;
      if (!_showHidden && IsHiddenEntry(de.Name, st))
        continue;
      CFSItem item;
      item.Info.ClearBase();
      item.Info.Name = de.Name;
      item.Parent = dirItem;
      FillItem(item, full, st);
      item.Name = fs2us(de.Name);
      if (_flatMode && item.IsRealDir)
      {
        // Symlinked directories are never followed, so flat mode cannot loop.
        FString sub(relPrefix);
        sub += de.Name;
        sub.Add_PathSepar();
        _folders.Add(sub);
        _prefixesU.Add(fs2us(sub));
      }
      _items.Add(item);
    }
  }
  if (!_flatMode)
    return S_OK;
  const unsigned endIndex = _folders.Size();
  for (unsigned i = startIndex; i < endIndex; i++)
    RINOK(LoadSubItems((int)i, _folders[i]))
  return S_OK;
}

Z7_COM7F_IMF(CFSFolderMac::LoadItems())
{
  COM_TRY_BEGIN
  {
    Int32 dummy;   // drain pending notifications, like CFSFolder::LoadItems
    WasChanged(&dummy);
  }
  _items.Clear();
  _folders.Clear();
  _prefixesU.Clear();
  _commentsAreLoaded = false;
  return LoadSubItems(-1, FString());
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = _items.Size();
  return S_OK;
}

bool CFSFolderMac::LoadComments()
{
  _comments.Clear();
  _commentsAreLoaded = true;
  NIO::CInFile file;
  if (!file.Open((const char *)(_path + kDescriptionFileName)))
    return false;
  UInt64 len;
  if (!file.GetLength(len) || len >= (1 << 28))
    return false;
  AString s;
  char *p = s.GetBuf((unsigned)(size_t)len);
  size_t processedSize;
  if (!file.ReadFull(p, (size_t)len, processedSize))
    return false;
  s.ReleaseBuf_CalcLen((unsigned)(size_t)len);
  if (processedSize != len)
    return false;
  file.Close();
  UString unicodeString;
  if (!ConvertUTF8ToUnicode(s, unicodeString))
    return false;
  return _comments.ReadFromString(unicodeString);
}

bool CFSFolderMac::SaveComments()
{
  AString utf;
  {
    UString unicode;
    _comments.SaveToString(unicode);
    ConvertUnicodeToUTF8(unicode, utf);
  }
  if (!utf.IsAscii())
    utf.Insert(0, "\xEF\xBB\xBF" "\r\n");
  NIO::COutFile file;
  if (!file.Create_ALWAYS(_path + kDescriptionFileName))
    return false;
  const bool res = file.WriteFull(utf.Ptr(), utf.Len());
  _commentsAreLoaded = false;
  return res;
}

Z7_COM7F_IMF(CFSFolderMac::GetProperty(UInt32 itemIndex, PROPID propID, PROPVARIANT *value))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  if (itemIndex >= _items.Size())
    return E_INVALIDARG;
  CFSItem &item = _items[itemIndex];
  const CFileInfo &fi = item.Info;
  switch (propID)
  {
    case kpidIsDir: prop = item.IsDir; break;
    case kpidIsAltStream: prop = false; break;
    case kpidName: prop = item.Name; break;
    case kpidExtension:
    {
      // not a column on Windows either, but the panel sorts by it (PanelSort.cpp)
      const int dot = item.Name.ReverseFind_Dot();
      if (dot >= 0)
        prop = item.Name.Ptr((unsigned)dot + 1);
      break;
    }
    case kpidSize: if (!item.IsDir || item.FolderStat_Defined) prop = fi.Size; break;
    case kpidPackSize: if (!item.IsDir || item.FolderStat_Defined) prop = item.PackSize; break;
    case kpidAttrib: prop = item.WinAttrib; break;
    case kpidPosixAttrib: prop = (UInt32)fi.mode; break;
    case kpidCTime: PropVariant_SetFrom_FiTime(prop, item.BirthTime); break;
    case kpidATime: PropVariant_SetFrom_FiTime(prop, fi.ATime); break;
    case kpidMTime: PropVariant_SetFrom_FiTime(prop, fi.MTime); break;
    case kpidChangeTime: PropVariant_SetFrom_FiTime(prop, fi.CTime); break;
    case kpidINode: prop = (UInt64)fi.ino; break;
    case kpidLinks: prop = (UInt64)fi.nlink; break;
    case kpidUserId: prop = (UInt32)fi.uid; break;
    case kpidGroupId: prop = (UInt32)fi.gid; break;
    case kpidUser:
    case kpidGroup:
    {
      if (!item.OwnerResolved)
      {
        item.OwnerResolved = true;
        const struct passwd *pw = getpwuid(fi.uid);
        if (pw && pw->pw_name)
          item.User = MultiByteToUnicodeString(AString(pw->pw_name), CP_UTF8);
        const struct group *gr = getgrgid(fi.gid);
        if (gr && gr->gr_name)
          item.Group = MultiByteToUnicodeString(AString(gr->gr_name), CP_UTF8);
      }
      const UString &s = (propID == kpidUser) ? item.User : item.Group;
      if (!s.IsEmpty())
        prop = s;
      break;
    }
    // The symlink target, in the Windows "Link" column slot (IDS_PROP_NT_REPARSE 1089)
    // and as kpidSymLink for callers that ask by name (01 section 9 #8).
    case kpidNtReparse:
    case kpidSymLink:
      if (item.IsLink && !item.LinkTarget.IsEmpty())
        prop = item.LinkTarget;
      break;
    case kpidComment:
    {
      if (!_commentsAreLoaded)
        LoadComments();
      UString comment;
      if (_comments.GetValue(fs2us(GetRelPath(item)), comment))
      {
        const int pos = comment.Find((wchar_t)4);
        if (pos >= 0)
          comment.DeleteFrom((unsigned)pos);
        prop = comment;
      }
      break;
    }
    case kpidPrefix:
      if (item.Parent >= 0)
        prop = fs2us(_folders[(unsigned)item.Parent]);
      break;
    case kpidNumSubDirs: if (item.IsDir && item.FolderStat_Defined) prop = item.NumFolders; break;
    case kpidNumSubFiles: if (item.IsDir && item.FolderStat_Defined) prop = item.NumFiles; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

HRESULT CFSFolderMac::BindToFolderSpec(const FString &path, IFolderFolder **resultFolder) const
{
  *resultFolder = NULL;
  CFSFolderMac *folderSpec = new CFSFolderMac;
  CMyComPtr<IFolderFolder> subFolder = folderSpec;
  folderSpec->_showHidden = _showHidden;
  folderSpec->_deleteToTrash = _deleteToTrash;
  folderSpec->_flatMode = _flatMode;
  RINOK(folderSpec->Init(path))
  *resultFolder = subFolder.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CFSFolderMac::BindToFolder(UInt32 index, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  if (index >= _items.Size())
    return E_INVALIDARG;
  if (!_items[index].IsDir)
    return E_INVALIDARG;   // files (archives) are opened by SZArchiveOpener
  return BindToFolderSpec(GetItemPath(index), resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::BindToFolder(const wchar_t *name, IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  const UString u = name;
  FString path;
  if (NName::IsAbsolutePath(u))
    path = us2fs(u);
  else
    path = _path + us2fs(u);
  return BindToFolderSpec(path, resultFolder);
  COM_TRY_END
}

// A directory is a mount point when its device differs from its parent's: the macOS
// equivalent of Windows' "drive root", where BindToParentFolder goes to CFSDrives.
static bool IsMountPoint(const FString &dirWithSepar)
{
  FString p(dirWithSepar);
  if (p.Len() > 1 && IsPathSepar(p.Back()))
    p.DeleteBack();
  if (p.IsEmpty())
    return true;
  struct stat st;
  if (stat(p, &st) != 0)
    return false;
  FString parent(p);
  const int pos = parent.ReverseFind_PathSepar();
  if (pos < 0)
    return false;
  parent.DeleteFrom((unsigned)pos + 1);
  struct stat pst;
  if (stat(parent, &pst) != 0)
    return false;
  return st.st_dev != pst.st_dev;
}

Z7_COM7F_IMF(CFSFolderMac::BindToParentFolder(IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  *resultFolder = NULL;
  if (_path.Len() <= 1)
    return S_OK;   // "/" has no parent here; the caller falls back to the root folder
  if (IsMountPoint(_path))
  {
    // Windows: a drive root goes up to Computer (CFSDrives); macOS: to the volumes folder.
    CVolumesFolderMac *spec = new CVolumesFolderMac;
    CMyComPtr<IFolderFolder> folder = spec;
    RINOK(folder->LoadItems())
    *resultFolder = folder.Detach();
    return S_OK;
  }
  FString parent = _path;
  parent.DeleteBack();   // trailing '/'
  const int pos = parent.ReverseFind_PathSepar();
  if (pos < 0)
    return S_OK;
  parent.DeleteFrom((unsigned)pos + 1);
  return BindToFolderSpec(parent, resultFolder);
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::GetNumberOfProperties(UInt32 *numProperties))
{
  *numProperties = Z7_ARRAY_SIZE(kProps);
  if (!_flatMode)
    (*numProperties)--;   // kpidPrefix is last and only shown in flat view
  return S_OK;
}

IMP_IFolderFolder_GetProp(CFSFolderMac::GetPropertyInfo, kProps)

Z7_COM7F_IMF(CFSFolderMac::GetFolderProperty(PROPID propID, PROPVARIANT *value))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidType: prop = "FSFolder"; break;
    case kpidPath: prop = fs2us(_path); break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

// ---- IFolderGetItemName --------------------------------------------------------

Z7_COM7F_IMF(CFSFolderMac::GetItemName(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= _items.Size())
    return E_INVALIDARG;
  const UString &s = _items[index].Name;
  *name = s.Ptr();
  *len = s.Len();
  return S_OK;
}

Z7_COM7F_IMF(CFSFolderMac::GetItemPrefix(UInt32 index, const wchar_t **name, unsigned *len))
{
  *name = NULL;
  *len = 0;
  if (index >= _items.Size())
    return E_INVALIDARG;
  const int parent = _items[index].Parent;
  if (parent < 0)
    return S_OK;
  // _folders holds FString (FChar == char on macOS), so the caller needs the UString copy
  // kept alive next to it.
  const UString &s = _prefixesU[(unsigned)parent];
  *name = s.Ptr();
  *len = s.Len();
  return S_OK;
}

Z7_COM7F_IMF2(UInt64, CFSFolderMac::GetItemSize(UInt32 index))
{
  if (index >= _items.Size())
    return 0;
  const CFSItem &item = _items[index];
  return item.IsDir ? 0 : item.Info.Size;
}

// ---- IFolderWasChanged (FSEvents, 01 section 3.17) --------------------------------

Z7_COM7F_IMF(CFSFolderMac::WasChanged(Int32 *wasChanged))
{
  *wasChanged = BoolToInt(false);
  if (!_watcher)
  {
    // lazily started on the first poll so folders nobody watches cost nothing
    _watcher = new CFSEventsWatcher((const char *)_path, _flatMode);
    return S_OK;
  }
  *wasChanged = BoolToInt(_watcher->ConsumeChanged());
  return S_OK;
}

// ---- IFolderClone ----------------------------------------------------------------

Z7_COM7F_IMF(CFSFolderMac::Clone(IFolderFolder **resultFolder))
{
  COM_TRY_BEGIN
  return BindToFolderSpec(_path, resultFolder);
  COM_TRY_END
}

// ---- IFolderSetFlatMode (01 section 3.4) -----------------------------------------

Z7_COM7F_IMF(CFSFolderMac::SetFlatMode(Int32 flatMode))
{
  const bool flat = IntToBool(flatMode);
  if (flat != _flatMode)
  {
    _flatMode = flat;
    ResetWatcher();   // flat view needs the whole subtree watched
  }
  return S_OK;
}

// ---- IFolderCompare (PanelSort.cpp CompareItems2 property rules) -------------------

static int CompareExtensions(const UString &a, const UString &b)
{
  const int pa = a.ReverseFind_Dot();
  const int pb = b.ReverseFind_Dot();
  const wchar_t *ea = pa < 0 ? L"" : a.Ptr((unsigned)pa + 1);
  const wchar_t *eb = pb < 0 ? L"" : b.Ptr((unsigned)pb + 1);
  return CompareFileNames_ForFolderList(ea, eb);
}

Z7_COM7F_IMF2(Int32, CFSFolderMac::CompareItems(UInt32 index1, UInt32 index2, PROPID propID, Int32 propIsRaw))
{
  UNUSED_VAR(propIsRaw)
  if (index1 >= _items.Size() || index2 >= _items.Size())
    return 0;
  const CFSItem &a = _items[index1];
  const CFSItem &b = _items[index2];
  switch (propID)
  {
    case kpidName: return CompareFileNames_ForFolderList(a.Name, b.Name);
    case kpidExtension: return CompareExtensions(a.Name, b.Name);
    case kpidIsDir: return MyCompare((int)a.IsDir, (int)b.IsDir);
    case kpidSize: return MyCompare(a.IsDir ? 0 : a.Info.Size, b.IsDir ? 0 : b.Info.Size);
    case kpidPackSize: return MyCompare(a.IsDir ? 0 : a.PackSize, b.IsDir ? 0 : b.PackSize);
    case kpidAttrib: return MyCompare(a.WinAttrib, b.WinAttrib);
    case kpidPosixAttrib: return MyCompare((UInt32)a.Info.mode, (UInt32)b.Info.mode);
    case kpidCTime: return Compare_FiTime(&a.BirthTime, &b.BirthTime);
    case kpidATime: return Compare_FiTime(&a.Info.ATime, &b.Info.ATime);
    case kpidMTime: return Compare_FiTime(&a.Info.MTime, &b.Info.MTime);
    case kpidChangeTime: return Compare_FiTime(&a.Info.CTime, &b.Info.CTime);
    case kpidINode: return MyCompare((UInt64)a.Info.ino, (UInt64)b.Info.ino);
    case kpidLinks: return MyCompare((UInt64)a.Info.nlink, (UInt64)b.Info.nlink);
    case kpidUserId: return MyCompare((UInt32)a.Info.uid, (UInt32)b.Info.uid);
    case kpidGroupId: return MyCompare((UInt32)a.Info.gid, (UInt32)b.Info.gid);
    case kpidNtReparse:
    case kpidSymLink: return CompareFileNames_ForFolderList(a.LinkTarget, b.LinkTarget);
    case kpidNumSubDirs: return MyCompare(a.NumFolders, b.NumFolders);
    case kpidNumSubFiles: return MyCompare(a.NumFiles, b.NumFiles);
    case kpidPrefix:
    {
      const UString pa = a.Parent >= 0 ? fs2us(_folders[(unsigned)a.Parent]) : UString();
      const UString pb = b.Parent >= 0 ? fs2us(_folders[(unsigned)b.Parent]) : UString();
      return CompareFileNames_ForFolderList(pa, pb);
    }
    default: return 0;
  }
}

// ---- IFolderCalcItemFullSize / IFolderGetItemFullSize (01 section 3.11) -----------

Z7_COM7F_IMF(CFSFolderMac::CalcItemFullSize(UInt32 index, IProgress *progress))
{
  COM_TRY_BEGIN
  if (index >= _items.Size())
    return S_OK;
  CFSItem &item = _items[index];
  if (!item.IsDir)
    return S_OK;
  CFsStatMac fsStat;
  fsStat.Progress = progress;
  FString path = GetItemPath(index);
  if (path.Len() > 1 && IsPathSepar(path.Back()))
    path.DeleteBack();
  RINOK(fsStat.Enumerate(path))
  item.Info.Size = fsStat.Size;
  item.PackSize = fsStat.PackSize;
  item.NumFolders = fsStat.NumFolders;
  item.NumFiles = fsStat.NumFiles;
  item.FolderStat_Defined = true;
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::GetItemFullSize(UInt32 index, PROPVARIANT *value, IProgress *progress))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  if (index >= _items.Size())
    return E_INVALIDARG;
  if (_items[index].IsDir)
  {
    RINOK(CalcItemFullSize(index, progress))
  }
  prop = _items[index].Info.Size;
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

// ---- IFolderOperations (01 section 6.4) ------------------------------------------

void CFSFolderMac::GetAbsPath(const wchar_t *name, FString &absPath) const
{
  absPath.Empty();
  if (!NName::IsAbsolutePath(name))
    absPath += _path;
  absPath += us2fs(name);
}

Z7_COM7F_IMF(CFSFolderMac::CreateFolder(const wchar_t *name, IProgress *progress))
{
  COM_TRY_BEGIN
  UNUSED_VAR(progress)
  FString absPath;
  GetAbsPath(name, absPath);
  if (NDir::CreateDir(absPath))
    return S_OK;
  if (errno != EEXIST)
    if (NDir::CreateComplexDir(absPath))
      return S_OK;
  return GetLastError_noZero_HRESULT();
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::CreateFile(const wchar_t *name, IProgress *progress))
{
  COM_TRY_BEGIN
  UNUSED_VAR(progress)
  FString absPath;
  GetAbsPath(name, absPath);
  NIO::COutFile outFile;
  if (!outFile.Create_NEW(absPath))   // O_EXCL: fails with EEXIST, like CREATE_NEW
    return GetLastError_noZero_HRESULT();
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::Rename(UInt32 index, const wchar_t *newName, IProgress *progress))
{
  COM_TRY_BEGIN
  UNUSED_VAR(progress)
  if (index >= _items.Size())
    return E_NOTIMPL;
  const CFSItem &item = _items[index];
  FString fullPrefix = _path;
  if (item.Parent >= 0)
    fullPrefix += _folders[(unsigned)item.Parent];
  const FString oldPath = fullPrefix + item.Info.Name;
  const FString newPath = fullPrefix + us2fs(newName);
  // rename(2) silently replaces the destination; Windows' MoveFile fails with
  // ERROR_ALREADY_EXISTS, so renamex_np(RENAME_EXCL) keeps the Windows behaviour.
  if (renamex_np((const char *)oldPath, (const char *)newPath, RENAME_EXCL) == 0)
    return S_OK;
  if (errno == ENOTSUP)
  {
    struct stat st;
    if (LStat(newPath, st))
    {
      errno = EEXIST;
      return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);
    }
    if (rename((const char *)oldPath, (const char *)newPath) == 0)
      return S_OK;
  }
  return GetLastError_noZero_HRESULT();
  COM_TRY_END
}

HRESULT CFSFolderMac::DeleteItems(const UInt32 *indices, UInt32 numItems, bool toTrash, IProgress *progress)
{
  COM_TRY_BEGIN
  if (progress)
    RINOK(progress->SetTotal(numItems))
  CMyComPtr<IFolderOperationsExtractCallback> messages;
  if (progress)
    progress->QueryInterface(IID_IFolderOperationsExtractCallback, (void **)&messages);
  HRESULT firstError = S_OK;
  for (UInt32 i = 0; i < numItems; i++)
  {
    const UInt32 index = indices[i];
    if (index >= _items.Size())
      continue;
    const CFSItem &item = _items[index];
    const FString fullPath = GetItemPath(index);
    HRESULT itemError = S_OK;
    if (toTrash)
    {
      std::string resultPath, errorMessage;
      int errnoValue = 0;
      if (!NMacFileOps::TrashItem((const char *)fullPath, resultPath, errorMessage, errnoValue))
      {
        itemError = errnoValue != 0 ? HRESULT_FROM_WIN32((DWORD)errnoValue) : E_FAIL;
        if (messages)
          RINOK(SendMessageError(messages, MultiByteToUnicodeString(AString(errorMessage.c_str()), CP_UTF8), fullPath))
      }
    }
    else
    {
      // a symlink is unlinked, never followed (item.IsRealDir, not item.IsDir)
      const bool ok = item.IsRealDir ? RemoveDirWithSubItemsMac(fullPath) : DeleteFileForced(fullPath);
      if (!ok)
      {
        itemError = GetLastError_noZero_HRESULT();
        if (messages)
          RINOK(SendLastErrorMessage(messages, fullPath))
      }
    }
    if (itemError != S_OK)
    {
      if (firstError == S_OK)
        firstError = itemError;
      if (!messages)
        return itemError;   // no message sink: abort on the first error, like Windows
    }
    if (progress)
    {
      const UInt64 completed = i + 1;
      RINOK(progress->SetCompleted(&completed))
    }
  }
  return firstError;
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::Delete(const UInt32 *indices, UInt32 numItems, IProgress *progress))
{
  return DeleteItems(indices, numItems, _deleteToTrash, progress);
}

Z7_COM7F_IMF(CFSFolderMac::CopyTo(Int32 moveMode, const UInt32 *indices, UInt32 numItems,
    Int32 includeAltStreams, Int32 replaceAltStreamCharsMode,
    const wchar_t *path, IFolderOperationsExtractCallback *callback))
{
  COM_TRY_BEGIN
  UNUSED_VAR(includeAltStreams)
  UNUSED_VAR(replaceAltStreamCharsMode)
  if (numItems == 0)
    return S_OK;
  if (!callback)
    return E_INVALIDARG;

  const FString destPath = us2fs(path);
  if (destPath.IsEmpty())
    return E_INVALIDARG;
  // A destination without a trailing separator is one exact target path (Windows rule).
  const bool isDirectPath = !IsPathSepar(destPath.Back());
  if (isDirectPath && numItems > 1)
    return E_INVALIDARG;

  CFsStatMac fsStat;
  fsStat.Progress = callback;
  UInt32 i;
  for (i = 0; i < numItems; i++)
  {
    const UInt32 index = indices[i];
    if (index >= _items.Size())
      continue;
    const CFSItem &item = _items[index];
    if (item.IsRealDir)
    {
      FString p = GetItemPath(index);
      if (p.Len() > 1 && IsPathSepar(p.Back()))
        p.DeleteBack();
      RINOK(fsStat.Enumerate(p))
      fsStat.NumFolders++;
    }
    else
    {
      fsStat.NumFiles++;
      fsStat.Size += item.Info.Size;
    }
  }

  RINOK(callback->SetTotal(fsStat.Size))
  RINOK(callback->SetNumFiles(fsStat.NumFiles))
  UInt64 completedSize = 0;
  RINOK(callback->SetCompleted(&completedSize))

  CCopyStateMac state;
  state.TotalSize = fsStat.Size;
  state.StartPos = 0;
  state.Callback = callback;
  state.MoveMode = IntToBool(moveMode);

  for (i = 0; i < numItems; i++)
  {
    const UInt32 index = indices[i];
    if (index >= _items.Size())
      continue;
    const CFSItem &item = _items[index];
    const FString srcPath = GetItemPath(index);
    FString destPath2 = destPath;
    if (!isDirectPath)
      destPath2 += item.Info.Name;
    struct stat st;
    if (!LStat(srcPath, st))
    {
      RINOK(SendMessageError(callback, "Cannot find the file", srcPath))
      continue;
    }
    // A symlink is copied as a link even when it points at a directory.
    if (S_ISDIR(st.st_mode))
    {
      FString srcNoSepar(srcPath);
      if (srcNoSepar.Len() > 1 && IsPathSepar(srcNoSepar.Back()))
        srcNoSepar.DeleteBack();
      FString destNoSepar(destPath2);
      if (destNoSepar.Len() > 1 && IsPathSepar(destNoSepar.Back()))
        destNoSepar.DeleteBack();
      RINOK(CopyFolder(state, srcNoSepar, destNoSepar))
    }
    else
      RINOK(CopyFile_Ask(state, srcPath, st, destPath2))
  }
  completedSize = state.TotalSize;
  return callback->SetCompleted(&completedSize);
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::CopyFrom(Int32 moveMode, const wchar_t *fromFolderPath,
    const wchar_t * const *itemsPaths, UInt32 numItems, IProgress *progress))
{
  COM_TRY_BEGIN
  if (numItems == 0)
    return S_OK;
  if (!progress)
    return E_NOTIMPL;
  // Windows returns E_NOTIMPL here because the FM always calls CopyFileSystemItems()
  // directly; we accept the call when the caller's progress object is the copy callback.
  CMyComPtr<IFolderOperationsExtractCallback> callback;
  progress->QueryInterface(IID_IFolderOperationsExtractCallback, (void **)&callback);
  if (!callback)
    return E_NOTIMPL;
  UString fromPrefix = fromFolderPath ? UString(fromFolderPath) : UString();
  if (!fromPrefix.IsEmpty() && !IsPathSepar(fromPrefix.Back()))
    fromPrefix.Add_PathSepar();
  UStringVector paths;
  for (UInt32 i = 0; i < numItems; i++)
  {
    UString p = itemsPaths[i];
    if (!NName::IsAbsolutePath(p))
    {
      UString full(fromPrefix);
      full += p;
      p = full;
    }
    paths.Add(p);
  }
  return CopyFileSystemItems(paths, _path, IntToBool(moveMode), callback);
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::SetProperty(UInt32 index, PROPID propID, const PROPVARIANT *value, IProgress *progress))
{
  COM_TRY_BEGIN
  UNUSED_VAR(progress)
  if (index >= _items.Size())
    return E_INVALIDARG;
  const CFSItem &item = _items[index];
  if (item.Parent >= 0)
    return E_NOTIMPL;   // descript.ion only describes the folder's own entries
  switch (propID)
  {
    case kpidComment:
    {
      if (!_commentsAreLoaded)
        LoadComments();
      UString filename = fs2us(item.Info.Name);
      filename.Trim();
      if (value->vt == VT_EMPTY)
        _comments.DeletePair(filename);
      else if (value->vt == VT_BSTR)
      {
        CTextPair pair;
        pair.ID = filename;
        pair.ID.Trim();
        pair.Value.SetFromBstr(value->bstrVal);
        pair.Value.Trim();
        if (pair.Value.IsEmpty())
          _comments.DeletePair(filename);
        else
          _comments.AddPair(pair);
      }
      else
        return E_INVALIDARG;
      if (!SaveComments())
        return GetLastError_noZero_HRESULT();
      break;
    }
    default:
      return E_NOTIMPL;
  }
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CFSFolderMac::CopyFromFile(UInt32 index, const wchar_t *fullFilePath, IProgress *progress))
{
  UNUSED_VAR(index) UNUSED_VAR(fullFilePath) UNUSED_VAR(progress)
  return E_NOTIMPL;   // like Windows: file-system items are edited in place
}

}

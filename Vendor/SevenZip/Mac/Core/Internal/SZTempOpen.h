// SZTempOpen.h -- the C++ half of "open an item that lives inside an archive": the in-memory
// extraction target and the temp-folder helpers 7zFM's CPanel::OpenItemInArchive uses
// (FileManager/PanelItemOpen.cpp:1484-1803, CVirtFileSystem in
// FileManager/ExtractCallback.cpp:840-1200). Objective-C++ only; the public API is SZTempOpen
// in Mac/Core/include/SZExtractor.h.
//
// Parity: 01-fm-feature-inventory.md §3.9, §8.4; PROGRESS.md §2.4, §4.3, §4.6.
//
// Ownership rule (same as SZCallbackAdapters.h): CMyUnknownImp refcounts are not atomic, so
// one of these objects belongs to exactly one thread.

#ifndef SZ_TEMP_OPEN_H
#define SZ_TEMP_OPEN_H

#import <Foundation/Foundation.h>
#import "SZCallbackAdapters.h"

// Engine headers SZEngine.h does not pull in (same BOOL rename trick).
#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL
#include "../../../CPP/Common/MyBuffer.h"
#include "../../../CPP/7zip/Common/StreamObjects.h"
#include "../../../CPP/7zip/UI/Common/IFileExtractCallback.h"
#pragma pop_macro("BOOL")

/// One file (or directory) held in memory, i.e. CVirtFile (ExtractCallback.h).
struct CSZVirtFile
{
  UString Name;           ///< path relative to the output directory, after path-mode processing
  bool IsDir;
  CByteBuffer Data;
  UInt32 Attrib;
  bool AttribDefined;
  FILETIME MTime;
  bool MTimeDefined;
  Int32 OpRes;            ///< NArchive::NExtract::NOperationResult

  CSZVirtFile(): IsDir(false), Attrib(0), AttribDefined(false), MTimeDefined(false), OpRes(0)
  {
    MTime.dwLowDateTime = 0;
    MTime.dwHighDateTime = 0;
  }
};

/// CVirtFileSystem: an IFolderArchiveExtractCallback that also answers
/// IFolderExtractToStreamCallback, so CArchiveExtractCallback writes into memory instead of
/// into files (ArchiveExtractCallback.cpp:366-374, 1930-1947). FlushToDisk() then writes the
/// collected files under DirPrefix, restoring times and attributes and writing the quarantine
/// attribute according to ZoneMode -- the macOS stand-in for :Zone.Identifier (01 §9 #23).
class CSZVirtFileSystem Z7_final:
  public IFolderArchiveExtractCallback,
  public IFolderArchiveExtractCallback2,
  public IFolderOperationsExtractCallback,
  public IFolderExtractToStreamCallback,
  public ICryptoGetTextPassword,
  public ICompressProgressInfo,
  public CMyUnknownImp,
  public CSZCallbackBase
{
  Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
    Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
    Z7_COM_QI_ENTRY(IFolderOperationsExtractCallback)
    Z7_COM_QI_ENTRY(IFolderExtractToStreamCallback)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_ENTRY(ICompressProgressInfo)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
  Z7_IFACE_COM7_IMP(IFolderOperationsExtractCallback)
  Z7_IFACE_COM7_IMP(IFolderExtractToStreamCallback)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(ICompressProgressInfo)

public:
  CObjectVector<CSZVirtFile> Files;
  /// CVirtFileSystem::MaxTotalAllocSize: above this the run gives up on memory and fails with
  /// E_OUTOFMEMORY, and the caller retries straight to disk.
  UInt64 MaxTotalAllocSize;
  UInt64 TotalAllocSize;
  UInt32 NumErrors;
  Int32 FirstBadOpRes;
  /// Where FlushToDisk writes (slash-terminated).
  FString DirPrefix;
  /// NExtract::NZoneIdMode.
  int ZoneMode;
  /// The archive file whose quarantine attribute is propagated (empty = none).
  FString ZoneSourcePath;
  /// The item PrepareOperation / SetCurrentFilePath last announced, reported with each result
  /// (CExtractCallbackImp::_currentFilePath).
  UString CurrentPath;

  CSZVirtFileSystem():
      MaxTotalAllocSize((UInt64)1 << 22),
      TotalAllocSize(0),
      NumErrors(0),
      FirstBadOpRes(NArchive::NExtract::NOperationResult::kOK),
      ZoneMode(0),
      _curSpec(NULL) {}

  IProgress *AsProgress() { return static_cast<IFolderArchiveExtractCallback *>(this); }

  /// Writes every collected file under DirPrefix. Returns the first failure.
  HRESULT FlushToDisk();

private:
  CDynBufSeqOutStream *_curSpec;
  CMyComPtr<ISequentialOutStream> _curStream;
};

/// com.apple.quarantine propagation: copies the attribute of `source` onto `destination` when
/// `zoneMode` asks for it (kAll = always, kOffice = only Office documents, 01 §9 #23, 03 §6.2).
void SZApplyQuarantine(const FString &source, const FString &destination, int zoneMode);

/// NFile::NDir::CreateComplexDir for the parent of `path`.
bool SZCreateParentDirectories(const FString &path);

#endif

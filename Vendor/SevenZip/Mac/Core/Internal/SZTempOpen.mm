// SZTempOpen.mm -- see SZTempOpen.h (the C++ half) and SZExtractor.h (the SZTempOpen /
// SZTempFile Objective-C API).
//
// Port of CPanel::OpenItemInArchive's extraction steps (FileManager/PanelItemOpen.cpp:1484-1803)
// and of CVirtFileSystem (FileManager/ExtractCallback.cpp:840-1200).

#import "SZTempOpen.h"

#import "SZExtractor.h"
#import "SZError.h"
#import "SZSettings.h"          // SZSettings.temporaryDirectory (SZ_STATE_DIR)
#import "SZFolderOperations.h"
#import "SZBridgeUtils.h"
#import "SZFolder+Internal.h"

#include <sys/sysctl.h>
#include <sys/xattr.h>
#include <vector>

using namespace NWindows;
using namespace NWindows::NFile;

// ---------------------------------------------------------------------------
#pragma mark - quarantine (the macOS Zone.Identifier, 01 §9 #23)

static const char * const kQuarantineAttribute = "com.apple.quarantine";

/// kOfficeExtensions: the documents ZoneIdMode kOffice covers (03 §6.2 / MenuPage's
/// "For Office files" option). Windows uses the same list the shell uses for MOTW.
static bool SZIsOfficeDocument(const FString &path)
{
  static const char * const kExts[] = {
    "doc", "dot", "docx", "docm", "dotx", "dotm",
    "xls", "xlt", "xlsx", "xlsm", "xltx", "xltm", "xlsb", "xlam",
    "ppt", "pot", "pps", "pptx", "pptm", "potx", "potm", "ppam", "ppsx", "ppsm",
    "rtf", "pdf", "vsd", "vsdx", "mpp", "one", "odt", "ods", "odp"
  };
  const int dot = path.ReverseFind_Dot();
  if (dot < 0)
    return false;
  const AString ext(path.Ptr((unsigned)(dot + 1)));
  for (unsigned i = 0; i < Z7_ARRAY_SIZE(kExts); i++)
    if (ext.IsEqualTo_Ascii_NoCase(kExts[i]))
      return true;
  return false;
}

void SZApplyQuarantine(const FString &source, const FString &destination, int zoneMode)
{
  if (zoneMode == NExtract::NZoneIdMode::kNone || source.IsEmpty())
    return;
  if (zoneMode == NExtract::NZoneIdMode::kOffice && !SZIsOfficeDocument(destination))
    return;
  // Windows copies the archive's :Zone.Identifier stream onto every extracted file
  // (ReadZoneFile / WriteZoneFile_To_FS). The xattr is the macOS equivalent, so the archive's
  // own quarantine flag is what gets propagated -- nothing is invented when the archive is
  // not quarantined.
  const ssize_t size = getxattr(source.Ptr(), kQuarantineAttribute, NULL, 0, 0, XATTR_NOFOLLOW);
  if (size <= 0)
    return;
  CByteBuffer buf((size_t)size);
  if (getxattr(source.Ptr(), kQuarantineAttribute, buf, (size_t)size, 0, XATTR_NOFOLLOW) != size)
    return;
  setxattr(destination.Ptr(), kQuarantineAttribute, buf, (size_t)size, 0, XATTR_NOFOLLOW);
}

bool SZCreateParentDirectories(const FString &path)
{
  const int slash = path.ReverseFind_PathSepar();
  if (slash <= 0)
    return true;
  return NDir::CreateComplexDir(path.Left((unsigned)slash));
}

// ---------------------------------------------------------------------------
#pragma mark - CSZVirtFileSystem

Z7_COM7F_IMF(CSZVirtFileSystem::SetTotal(UInt64 total))
{
  RINOK(CheckBreak())
  if (Delegate)
    [Delegate progressSetTotal:total];
  return S_OK;
}

Z7_COM7F_IMF(CSZVirtFileSystem::SetCompleted(const UInt64 *value))
{
  RINOK(CheckBreak())
  if (value && Delegate)
    [Delegate progressSetCompleted:*value];
  return S_OK;
}

Z7_COM7F_IMF(CSZVirtFileSystem::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize))
{
  RINOK(CheckBreak())
  if (Delegate)
    [Delegate progressSetRatioInfoInSize:(inSize ? *inSize : 0) outSize:(outSize ? *outSize : 0)];
  return S_OK;
}

Z7_COM7F_IMF(CSZVirtFileSystem::AskOverwrite(
    const wchar_t * /* existName */, const FILETIME * /* existTime */, const UInt64 * /* existSize */,
    const wchar_t * /* newName */, const FILETIME * /* newTime */, const UInt64 * /* newSize */,
    Int32 *answer))
{
  // The destination is a private temp folder, so there is nothing to overwrite; 7zFM's
  // OpenItemInArchive also never shows the dialog for it.
  *answer = NOverwriteAnswer::kYes;
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::PrepareOperation(const wchar_t *name, Int32 isFolder,
                                                Int32 /* askExtractMode */, const UInt64 * /* position */))
{
  CurrentPath = name ? name : L"";
  SetCurrentFile(name, IntToBool(isFolder));
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::MessageError(const wchar_t *message))
{
  CSZCallbackBase::ShowMessage(message);
  NumErrors++;
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::SetOperationResult(Int32 opRes, Int32 encrypted))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    NumErrors++;
    if (FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
      FirstBadOpRes = opRes;
  }
  if (!Files.IsEmpty())
    Files.Back().OpRes = opRes;
  ReportOperationResult(opRes, encrypted, CurrentPath.Ptr());
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    NumErrors++;
    if (FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
      FirstBadOpRes = opRes;
  }
  ReportOperationResult(opRes, encrypted, name);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::AskWrite(
    const wchar_t * /* srcPath */, Int32 /* srcIsFolder */, const FILETIME * /* srcTime */,
    const UInt64 * /* srcSize */, const wchar_t *destPathRequest, BSTR *destPathResult,
    Int32 *writeAnswer))
{
  *writeAnswer = BoolToInt(true);
  *destPathResult = NULL;
  RINOK(StringToBstr(destPathRequest ? destPathRequest : L"", destPathResult))
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::ShowMessage(const wchar_t *message))
{
  CSZCallbackBase::ShowMessage(message);
  NumErrors++;
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::SetCurrentFilePath(const wchar_t *filePath))
{
  CurrentPath = filePath ? filePath : L"";
  SetCurrentFile(filePath, false);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::SetNumFiles(UInt64 numFiles))
{
  SetTotalFiles(numFiles);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::CryptoGetTextPassword(BSTR *password))
{
  return AskPassword(password);
}

// IFolderExtractToStreamCallback: this is what makes CArchiveExtractCallback write into memory.

Z7_COM7F_IMF(CSZVirtFileSystem::UseExtractToStream(Int32 *res))
{
  *res = BoolToInt(true);
  return S_OK;
}

Z7_COM7F_IMF(CSZVirtFileSystem::GetStream7(const wchar_t *name, Int32 isDir,
                                          ISequentialOutStream **outStream, Int32 askExtractMode,
                                          IGetProp *getProp))
{
  *outStream = NULL;
  _curStream.Release();
  _curSpec = NULL;
  RINOK(CheckBreak())
  if (askExtractMode != NArchive::NExtract::NAskMode::kExtract)
    return S_OK;

  CSZVirtFile &file = Files.AddNew();
  file.Name = name ? name : L"";
  file.IsDir = IntToBool(isDir);

  UInt64 size = 0;
  if (getProp)
  {
    NCOM::CPropVariant prop;
    if (getProp->GetProp(kpidAttrib, &prop) == S_OK && prop.vt == VT_UI4)
    {
      file.Attrib = prop.ulVal;
      file.AttribDefined = true;
    }
    prop.Clear();
    if (getProp->GetProp(kpidMTime, &prop) == S_OK && prop.vt == VT_FILETIME)
    {
      file.MTime = prop.filetime;
      file.MTimeDefined = true;
    }
    prop.Clear();
    if (getProp->GetProp(kpidSize, &prop) == S_OK)
      ConvertPropVariantToUInt64(prop, size);
  }
  if (file.IsDir)
    return S_OK;

  // CVirtFileSystem gives up when the total would exceed MaxTotalAllocSize; the caller then
  // retries straight to disk.
  if (TotalAllocSize + size > MaxTotalAllocSize)
    return E_OUTOFMEMORY;
  TotalAllocSize += size;

  _curSpec = new CDynBufSeqOutStream;
  CMyComPtr<ISequentialOutStream> stream(_curSpec);
  _curStream = stream;
  *outStream = stream.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CSZVirtFileSystem::PrepareOperation7(Int32 /* askExtractMode */))
{
  return CheckBreak();
}

Z7_COM7F_IMF(CSZVirtFileSystem::SetOperationResult8(Int32 opRes, Int32 encrypted, UInt64 /* size */))
{
  if (_curSpec && !Files.IsEmpty())
  {
    _curSpec->CopyToBuffer(Files.Back().Data);
    _curSpec = NULL;
    _curStream.Release();
  }
  return SetOperationResult(opRes, encrypted);
}

HRESULT CSZVirtFileSystem::FlushToDisk()
{
  // CVirtFileSystem::FlushToDisk (ExtractCallback.cpp:1175): write the collected items under
  // DirPrefix, restoring times and attributes, then the quarantine attribute.
  FOR_VECTOR (i, Files)
  {
    const CSZVirtFile &file = Files[i];
    FString path = DirPrefix;
    path += us2fs(file.Name);
    if (file.IsDir)
    {
      if (!NDir::CreateComplexDir(path))
        return GetLastError_noZero_HRESULT();
      continue;
    }
    if (!SZCreateParentDirectories(path))
      return GetLastError_noZero_HRESULT();
    NIO::COutFile out;
    if (!out.Create_ALWAYS(path))
      return GetLastError_noZero_HRESULT();
    if (file.Data.Size() != 0)
      if (!out.WriteFull(file.Data, file.Data.Size()))
        return GetLastError_noZero_HRESULT();
    if (file.MTimeDefined)
    {
      CFiTime mtime;
      if (FILETIME_To_timespec(file.MTime, mtime))
        out.SetMTime(&mtime);
    }
    out.Close();
    if (file.AttribDefined)
      NDir::SetFileAttrib_PosixHighDetect(path, file.Attrib);
    SZApplyQuarantine(ZoneSourcePath, path, ZoneMode);
  }
  return S_OK;
}

// ---------------------------------------------------------------------------
#pragma mark - SZTempFile

@implementation SZTempFile {
@public
  NSString *_directoryPath;
  NSString *_filePath;
  NSString *_relativePath;
  NSString *_itemName;
  NSInteger _itemIndex;
  BOOL _isDirectory;
  BOOL _wasHeldInMemory;
  uint64_t _size;
  NSDate *_modificationDate;
}

- (NSString *)directoryPath { return _directoryPath; }
- (NSString *)filePath { return _filePath; }
- (NSString *)relativePath { return _relativePath; }
- (NSString *)itemName { return _itemName; }
- (NSInteger)itemIndex { return _itemIndex; }
- (BOOL)isDirectory { return _isDirectory; }
- (BOOL)wasHeldInMemory { return _wasHeldInMemory; }
- (uint64_t)size { return _size; }
- (NSDate *)modificationDate { return _modificationDate; }

- (void)refreshRecordedAttributes
{
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:NULL];
  _size = [attrs[NSFileSize] unsignedLongLongValue];
  _modificationDate = attrs[NSFileModificationDate];
}

- (BOOL)wasModified
{
  // The watcher's test: 7zFM compares CTempFileInfo::FileInfo (size + mtime) with the file on
  // disk after the editor exited (PanelItemOpen.cpp ~1110-1330).
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:NULL];
  if (!attrs)
    return NO;
  if ([attrs[NSFileSize] unsignedLongLongValue] != _size)
    return YES;
  NSDate *mtime = attrs[NSFileModificationDate];
  if (!mtime || !_modificationDate)
    return mtime != _modificationDate;
  return fabs([mtime timeIntervalSinceDate:_modificationDate]) > 0.0001;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZTempFile %@ size=%llu%@>", _filePath, _size,
          _wasHeldInMemory ? @" (memory)" : @""];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - SZTempOpen

@implementation SZTempOpen

+ (NSString *)openDirectoryPrefix { return @"7zO"; }        // kTempDirPrefix, PanelItemOpen.cpp
+ (NSString *)extractDirectoryPrefix { return @"7zE"; }     // kTempDirPrefix, PanelCopy/PanelDrag

+ (nullable NSString *)createTemporaryDirectoryWithPrefix:(NSString *)prefix error:(NSError **)error
{
  // CTempDir::Create(prefix) -> CreateTempFile2(addRandom) (Windows/FileDir.cpp:880-935): the
  // prefix plus eight upper-case hex digits, "7zO1A2B3C4D", retried on a name that exists.
  NSString *root = SZSettings.temporaryDirectory;
  for (unsigned attempt = 0; attempt < 100; attempt++)
  {
    NSString *path = [root stringByAppendingPathComponent:
                      [prefix stringByAppendingFormat:@"%08X", arc4random()]];
    if (mkdir(path.fileSystemRepresentation, 0700) == 0)
      return path;
    if (errno != EEXIST)
      break;
  }
  if (error)
    *error = [SZErrors errorWithCode:SZErrorCodeEngine
                            message:[NSString stringWithFormat:@"cannot create a temp folder in %@", root]];
  return nil;
}

+ (uint64_t)inMemoryLimitForArchiveLevelCount:(NSInteger)levels
{
  // fileLimit = g_RAM_Size >> max(numLevels + 1, 8), else 4 MiB (PanelItemOpen.cpp:1613-1615).
  uint64_t ram = 0;
  size_t size = sizeof(ram);
  int mib[2] = { CTL_HW, HW_MEMSIZE };
  if (sysctl(mib, 2, &ram, &size, NULL, 0) != 0 || ram == 0)
    return (uint64_t)4 << 20;
  NSInteger shift = levels + 1;
  if (shift < 8)
    shift = 8;
  if (shift > 63)
    shift = 63;
  return ram >> shift;
}

+ (void)applyQuarantineFromArchiveAtPath:(NSString *)archivePath
                                  toPath:(NSString *)path
                                    mode:(SZZoneIDMode)mode
{
  SZApplyQuarantine(SZFStringFromNSString(archivePath), SZFStringFromNSString(path), (int)mode);
}

+ (NSArray<NSString *> *)temporaryDirectories
{
  // DeleteOldTempFiles (PanelItemOpen.cpp:1815) enumerates "7zO*" and "7zE*"; Windows never
  // calls it, only Tools > Delete Temporary Files does (01 §3.9, §9 #11).
  NSString *temp = SZSettings.temporaryDirectory;
  NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:temp error:NULL];
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *name in entries)
  {
    if (![name hasPrefix:SZTempOpen.openDirectoryPrefix] && ![name hasPrefix:SZTempOpen.extractDirectoryPrefix])
      continue;
    NSString *path = [temp stringByAppendingPathComponent:name];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory)
      [out addObject:path];
  }
  return out;
}

+ (BOOL)removeTemporaryDirectoryAtPath:(NSString *)path
{
  NSString *temp = [SZSettings.temporaryDirectory stringByStandardizingPath];
  NSString *candidate = [path stringByStandardizingPath];
  // Never remove anything outside the temp folder, and only our own prefixes.
  if (![candidate hasPrefix:temp])
    return NO;
  NSString *name = candidate.lastPathComponent;
  if (![name hasPrefix:SZTempOpen.openDirectoryPrefix] && ![name hasPrefix:SZTempOpen.extractDirectoryPrefix])
    return NO;
  return [[NSFileManager defaultManager] removeItemAtPath:candidate error:NULL];
}

+ (nullable SZTempFile *)extractItemAtIndex:(NSInteger)index
                                   ofFolder:(SZFolder *)folder
                            archiveFilePath:(NSString *)archiveFilePath
                          archiveLevelCount:(NSInteger)levels
                                   zoneMode:(SZZoneIDMode)zoneMode
                                   progress:(id<SZProgressDelegate>)progress
                                      error:(NSError **)error
{
  if (index < 0 || index >= folder.itemCount)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"item index out of range"];
    return nil;
  }
  NSString *directory = [self createTemporaryDirectoryWithPrefix:SZTempOpen.openDirectoryPrefix error:error];
  if (!directory)
    return nil;

  const BOOL isDirectory = [folder isDirectoryAtIndex:index];
  NSString *name = [folder nameOfItemAtIndex:index];
  const uint64_t itemSize = [folder sizeOfItemAtIndex:index];
  const uint64_t limit = [self inMemoryLimitForArchiveLevelCount:levels];

  // Step 2 of OpenItemInArchive: a small file goes through memory first, everything else
  // (and every folder) straight to disk.
  BOOL heldInMemory = NO;
  if (!isDirectory && itemSize <= limit)
  {
    NSError *memoryError = nil;
    if ([self sz_extractItemInMemory:index ofFolder:folder toDirectory:directory
                     archiveFilePath:archiveFilePath zoneMode:zoneMode progress:progress
                               error:&memoryError])
    {
      heldInMemory = YES;
    }
    else if (memoryError.code == SZErrorCodeCancelled)
    {
      [self removeTemporaryDirectoryAtPath:directory];
      if (error) *error = memoryError;
      return nil;
    }
    // any other failure: fall through to the disk path, like CVirtFileSystem does when it
    // exceeds MaxTotalAllocSize.
  }

  if (!heldInMemory)
  {
    NSError *diskError = nil;
    SZOperationSummary *summary =
        [folder extractItemsAtIndexes:@[ @(index) ] toPath:directory
                            pathMode:SZExtractPathModeCurPaths
                       overwriteMode:SZOverwriteModeOverwrite
                            testMode:NO progress:progress error:&diskError];
    // CoverFlowFinder fix, 2026-10-11: S_OK can still contain failed members.
    if (!summary || summary.errorCount != 0)
    {
      [self removeTemporaryDirectoryAtPath:directory];
      if (error) *error = diskError ?: [SZErrors errorWithCode:SZErrorCodeEngine message:@"Archive member failed verification"];
      return nil;
    }
    if (zoneMode != SZZoneIDModeNone && archiveFilePath)
      [self applyQuarantineFromArchiveAtPath:archiveFilePath
                                      toPath:[directory stringByAppendingPathComponent:name]
                                        mode:zoneMode];
  }

  SZTempFile *result = [[SZTempFile alloc] init];
  result->_directoryPath = [directory copy];
  result->_filePath = [[directory stringByAppendingPathComponent:name] copy];
  result->_itemName = [name copy];
  result->_relativePath = [[folder prefixOfItemAtIndex:index] stringByAppendingString:name];
  result->_itemIndex = index;
  result->_isDirectory = isDirectory;
  result->_wasHeldInMemory = heldInMemory;
  [result refreshRecordedAttributes];

  if (![[NSFileManager defaultManager] fileExistsAtPath:result.filePath])
  {
    [self removeTemporaryDirectoryAtPath:directory];
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound
                              message:[NSString stringWithFormat:@"'%@' was not extracted", name]];
    return nil;
  }
  return result;
}

/// The CVirtFileSystem path: extract into memory, then flush.
+ (BOOL)sz_extractItemInMemory:(NSInteger)index
                      ofFolder:(SZFolder *)folder
                   toDirectory:(NSString *)directory
               archiveFilePath:(NSString *)archiveFilePath
                      zoneMode:(SZZoneIDMode)zoneMode
                      progress:(id<SZProgressDelegate>)progress
                         error:(NSError **)error
{
  CMyComPtr<IArchiveFolder> archiveFolder;
  folder.rawFolder->QueryInterface(IID_IArchiveFolder, (void **)&archiveFolder);
  if (!archiveFolder)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnsupported message:@"not an archive folder"];
    return NO;
  }

  NSString *message = nil;
  Int32 firstBadOpRes = NArchive::NExtract::NOperationResult::kOK;
  const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
    CMyComPtr2<IFolderArchiveExtractCallback, CSZVirtFileSystem> cb;
    cb.Create_if_Empty();
    cb->Delegate = progress;
    cb->ArchivePath = archiveFilePath ?: folder.fullPath;
    cb->DirPrefix = SZFStringFromNSString(directory);
    NName::NormalizeDirPathPrefix(cb->DirPrefix);
    cb->ZoneMode = (int)zoneMode;
    cb->ZoneSourcePath = SZFStringFromNSString(archiveFilePath);
    cb->MaxTotalAllocSize = [SZTempOpen inMemoryLimitForArchiveLevelCount:0];

    const UInt32 one = (UInt32)index;
    const HRESULT res = archiveFolder->Extract(&one, 1, BoolToInt(false), 0,
        NExtract::NPathMode::kCurPaths, NExtract::NOverwriteMode::kOverwrite,
        SZUStringFromNSString(directory).Ptr(), BoolToInt(false), cb.Interface());
    firstBadOpRes = cb->FirstBadOpRes;
    if (res != S_OK)
      return res;
    return cb->FlushToDisk();
  });

  if (hr == S_OK && firstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
    return YES;
  if (error)
  {
    if (hr == S_OK)
      *error = [SZErrors errorWithCode:SZErrorCodeEngine message:message ?: @"extraction failed"];
    else
      *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:message];
  }
  return NO;
}

+ (BOOL)updateItemAtIndex:(NSInteger)index
                 ofFolder:(SZFolder *)folder
             fromFilePath:(NSString *)filePath
                 progress:(id<SZProgressDelegate>)progress
                    error:(NSError **)error
{
  CMyComPtr<IFolderOperations> operations;
  folder.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&operations);
  if (!operations)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnsupported
                              message:@"IFolderOperations::CopyFromFile is not supported for this folder"];
    return NO;
  }

  NSString *message = nil;
  const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
    // CThreadCopyFrom hands CopyFromFile a CUpdateCallback100Imp (PanelItemOpen.cpp), and
    // CAgentFolder::CommonUpdateOperation QI's IFolderArchiveUpdateCallback out of it: with a bare
    // IProgress the engine reports nothing and never asks the delegate whether to cancel
    // (mac/archgaps: a Cancel in the progress dialog had no effect).
    CMyComPtr2<IProgress, CSZUpdateCallbackAdapter> cb;
    cb.Create_if_Empty();
    cb->Delegate = progress;
    cb->ArchivePath = folder.fullPath;
    return operations->CopyFromFile((UInt32)index, SZUStringFromNSString(filePath).Ptr(), cb.Interface());
  });
  if (hr == S_OK)
    return YES;
  if (error)
  {
    if (hr == E_NOTIMPL)
      *error = [SZErrors errorWithCode:SZErrorCodeNotImplemented
                              message:@"IFolderOperations::CopyFromFile is not implemented for this folder"];
    else
      *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:message];
  }
  return NO;
}

@end

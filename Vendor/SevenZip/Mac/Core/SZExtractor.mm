// SZExtractor.mm -- see SZExtractor.h.
//
// This is a thin shell around the engine's own extract driver: `Extract()`
// (CPP/7zip/UI/Common/Extract.cpp), the function GUI/ExtractGUI.cpp runs on its worker
// thread. Everything that decides *what* happens -- path modes, overwrite modes, the
// duplicate-root elimination (-spe), `*` substitution in the output directory, multi-volume
// detection and the pack-size accounting, the per-item error texts -- stays in the engine, so
// the macOS app behaves exactly like 7zG.
//
// What this file adds is the two callback objects `Extract()` needs and the bridge does not
// have yet:
//   * CSZExtractCallbackAdapter (Internal/SZCallbackAdapters.h, owned by `opsinfra`) is the
//     COM IFolderArchiveExtractCallback: progress, overwrite, password, per-item results.
//   * CSZExtractUICallback (here) is the non-COM IExtractCallbackUI + IOpenCallbackUI pair:
//     BeforeOpen / OpenResult / ExtractResult and the open-time password and progress. On
//     Windows both are one object (CExtractCallbackImp); here they share the password and the
//     error counters through a pointer.

#import "SZExtractor.h"

#import "SZCodecs.h"
#import "SZError.h"
#import "SZLang.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZCallbackAdapters.h"

// Engine headers that SZEngine.h does not pull in. Same BOOL rename trick as SZEngine.h:
// MyWindows.h typedefs BOOL, which would clash with Objective-C's BOOL.
#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL
#include "../../CPP/Common/Wildcard.h"
#include "../../CPP/7zip/UI/Common/Extract.h"
#include "../../CPP/7zip/UI/Common/ExtractingFilePath.h"
#include "../../CPP/7zip/UI/Common/HashCalc.h"
#pragma pop_macro("BOOL")

#import "Internal/SZHashBundleBridge.h"

using namespace NWindows;
using namespace NWindows::NFile;

// Lang IDs (GUI/ExtractRes.h, FileManager/PropertyNameRes.h, FileManager/resourceGui.h)
static const UInt32 kLangID_MemError = 3000;             // IDS_MEM_ERROR
static const UInt32 kLangID_CannotCreateFolder = 3003;   // IDS_CANNOT_CREATE_FOLDER "Cannot create folder '{0}'"
static const UInt32 kLangID_CantOpenArchive = 3005;      // IDS_CANT_OPEN_ARCHIVE
static const UInt32 kLangID_CantOpenEncrypted = 3006;    // IDS_CANT_OPEN_ENCRYPTED_ARCHIVE
static const UInt32 kLangID_CantOpenAsType = 3017;       // IDS_CANT_OPEN_AS_TYPE
static const UInt32 kLangID_IsOpenAsType = 3018;         // IDS_IS_OPEN_AS_TYPE
static const UInt32 kLangID_IsOpenWithOffset = 3019;     // IDS_IS_OPEN_WITH_OFFSET
static const UInt32 kLangID_WrongPswGuess = 3710;        // IDS_EXTRACT_MSG_WRONG_PSW_GUESS
static const UInt32 kLangID_WrongPswClaim = 3729;        // IDS_EXTRACT_MSG_WRONG_PSW_CLAIM
static const UInt32 kLangID_NoErrors = 3001;             // IDS_MESSAGE_NO_ERRORS "There are no errors"
static const UInt32 kLangID_ArchivesColon = 3907;        // IDS_ARCHIVES_COLON "Archives:"
static const UInt32 kLangID_FileSize = 3504;             // IDS_FILE_SIZE "{0} bytes"
static const UInt32 kLangID_PropSize = 1007;             // IDS_PROP_SIZE
static const UInt32 kLangID_PropPackedSize = 1008;       // IDS_PROP_PACKED_SIZE
static const UInt32 kLangID_PropFolders = 1031;          // IDS_PROP_FOLDERS
static const UInt32 kLangID_PropFiles = 1032;            // IDS_PROP_FILES
static const UInt32 kLangID_PropNumAltStreams = 1075;    // IDS_PROP_NUM_ALT_STREAMS
static const UInt32 kLangID_PropAltStreamsSize = 1076;   // IDS_PROP_ALT_STREAMS_SIZE
static const UInt32 kLangID_PropWarning = 1086;          // IDS_PROP_WARNING (1000 + kpidWarning)
static const UInt32 kLangID_PropWarningFlags = 1085;     // IDS_PROP_WARNING_FLAGS (1000 + kpidWarningFlags)

/// k_ErrorFlagsIds (FileManager/ExtractCallback.cpp:452-465), indexed by the
/// kpv_ErrorFlags_* bit position.
static const UInt32 k_ErrorFlagsLangIDs[] = {
  3727,  // IDS_EXTRACT_MSG_IS_NOT_ARC
  3728,  // IDS_EXTRACT_MSG_HEADERS_ERROR
  3728,  // IDS_EXTRACT_MSG_HEADERS_ERROR (encrypted headers)
  3763,  // IDS_OPEN_MSG_UNAVAILABLE_START
  3764,  // IDS_OPEN_MSG_UNCONFIRMED_START
  3725,  // IDS_EXTRACT_MSG_UEXPECTED_END
  3726,  // IDS_EXTRACT_MSG_DATA_AFTER_END
  3721,  // IDS_EXTRACT_MSG_UNSUPPORTED_METHOD
  3768,  // IDS_OPEN_MSG_UNSUPPORTED_FEATURE
  3722,  // IDS_EXTRACT_MSG_DATA_ERROR
  3723   // IDS_EXTRACT_MSG_CRC_ERROR
};

static NSString *SZLangText(UInt32 id, NSString *fallback)
{
  return [SZLang.shared stringForID:id fallback:fallback];
}

// ---------------------------------------------------------------------------
#pragma mark - SZExtractOptions

@implementation SZExtractOptions

- (instancetype)init
{
  self = [super init];
  if (!self)
    return nil;
  // CExtractOptionsBase() / CExtractNtOptions()
  _outputDirectory = @"";
  _pathMode = SZExtractPathModeFullPaths;
  _overwriteMode = SZOverwriteModeAsk;
  _outDirMode = SZExtractOutDirModeReplaceAsterisk;
  _zoneIDMode = SZZoneIDModeNone;
  _extractSymbolicLinks = @YES;          // CExtractNtOptions: SymLinks.Val = true
  _memoryLimit = UINT64_MAX;
  _hashMethods = @[];                    // -scrc off (CHashOptions::Methods empty)
  return self;
}

- (id)copyWithZone:(NSZone *)zone
{
  SZExtractOptions *copy = [[SZExtractOptions allocWithZone:zone] init];
  copy.outputDirectory = self.outputDirectory;
  copy.pathMode = self.pathMode;
  copy.pathModeForced = self.pathModeForced;
  copy.overwriteMode = self.overwriteMode;
  copy.overwriteModeForced = self.overwriteModeForced;
  copy.outDirMode = self.outDirMode;
  copy.eliminateDuplicateRoot = self.eliminateDuplicateRoot;
  copy.zoneIDMode = self.zoneIDMode;
  copy.testMode = self.testMode;
  copy.excludeDirectoryItems = self.excludeDirectoryItems;
  copy.excludeFileItems = self.excludeFileItems;
  copy.password = self.password;
  copy.formatHint = self.formatHint;
  copy.restoreFileSecurity = self.restoreFileSecurity;
  copy.extractSymbolicLinks = self.extractSymbolicLinks;
  copy.extractHardLinks = self.extractHardLinks;
  copy.extractAlternateStreams = self.extractAlternateStreams;
  copy.preAllocateOutputFile = self.preAllocateOutputFile;
  copy.preserveAccessTime = self.preserveAccessTime;
  copy.memoryLimit = self.memoryLimit;
  copy.hashMethods = self.hashMethods;
  return copy;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZExtractOptions out=%@ path=%ld overwrite=%ld%@>",
          _outputDirectory, (long)_pathMode, (long)_overwriteMode, _testMode ? @" test" : @""];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - SZExtractStatistics / SZExtractResult

@implementation SZExtractStatistics {
@public
  uint64_t _archiveCount, _unpackSize, _alternateStreamsUnpackSize, _packSize;
  uint64_t _folderCount, _fileCount, _alternateStreamCount;
}
- (uint64_t)archiveCount { return _archiveCount; }
- (uint64_t)unpackSize { return _unpackSize; }
- (uint64_t)alternateStreamsUnpackSize { return _alternateStreamsUnpackSize; }
- (uint64_t)packSize { return _packSize; }
- (uint64_t)folderCount { return _folderCount; }
- (uint64_t)fileCount { return _fileCount; }
- (uint64_t)alternateStreamCount { return _alternateStreamCount; }

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZExtractStatistics archives=%llu files=%llu folders=%llu size=%llu packed=%llu>",
          _archiveCount, _fileCount, _folderCount, _unpackSize, _packSize];
}
@end

@implementation SZExtractResult {
@public
  SZExtractStatistics *_statistics;
  uint64_t _filesProcessed;
  NSUInteger _errorCount;
  NSUInteger _archiveErrorCount;
  SZOperationResult _firstFailure;
  BOOL _passwordWasAsked;
  NSString *_password;
  NSMutableArray<NSString *> *_messages;
  BOOL _testMode;
  SZHashResults *_hashResults;
}

- (instancetype)init
{
  self = [super init];
  if (!self)
    return nil;
  _statistics = [[SZExtractStatistics alloc] init];
  _messages = [NSMutableArray array];
  _firstFailure = SZOperationResultOK;
  return self;
}

- (SZExtractStatistics *)statistics { return _statistics; }
- (uint64_t)filesProcessed { return _filesProcessed; }
- (NSUInteger)errorCount { return _errorCount; }
- (NSUInteger)archiveErrorCount { return _archiveErrorCount; }
- (SZOperationResult)firstFailure { return _firstFailure; }
- (BOOL)passwordWasAsked { return _passwordWasAsked; }
- (NSString *)password { return _password; }
- (NSArray<NSString *> *)messages { return [_messages copy]; }
- (BOOL)isOK { return _errorCount == 0 && _archiveErrorCount == 0; }
- (SZHashResults *)hashResults { return _hashResults; }

/// AddSizeValue (FileManager/OverwriteDialog.cpp:68): "<digits> bytes" plus " : <N> KiB/MiB/GiB".
static NSString *SZSizeValueText(uint64_t value)
{
  NSString *s = [SZLangText(kLangID_FileSize, @"{0} bytes")
                 stringByReplacingOccurrencesOfString:@"{0}"
                 withString:[NSString stringWithFormat:@"%llu", value]];
  if (value >= (1 << 10))
  {
    char unit;
    uint64_t v = value;
    if (v >= ((uint64_t)10 << 30)) { v >>= 30; unit = 'G'; }
    else if (v >= (10 << 20))      { v >>= 20; unit = 'M'; }
    else                           { v >>= 10; unit = 'K'; }
    s = [s stringByAppendingFormat:@" : %llu %ciB", v, unit];
  }
  return s;
}

- (NSString *)testSummary
{
  // GUI/ExtractGUI.cpp:137-158 (AddValuePair / AddSizePair from :41-57). With -scrc the hash
  // list replaces this box: the Windows code is `if (HashBundle) ... else if (TestMode) ...`.
  if (!_testMode || !self.isOK || _hashResults)
    return nil;
  NSMutableString *s = [NSMutableString string];
  // "Archives:" already carries the colon (addColon = false in the Windows call).
  [s appendFormat:@"%@ %llu\n", SZLangText(kLangID_ArchivesColon, @"Archives:"), _statistics->_archiveCount];
  [s appendFormat:@"%@: %@\n", SZLangText(kLangID_PropPackedSize, @"Packed Size"),
                  SZSizeValueText(_statistics->_packSize)];
  if (_statistics->_folderCount != 0)
    [s appendFormat:@"%@: %llu\n", SZLangText(kLangID_PropFolders, @"Folders"), _statistics->_folderCount];
  [s appendFormat:@"%@: %llu\n", SZLangText(kLangID_PropFiles, @"Files"), _statistics->_fileCount];
  [s appendFormat:@"%@: %@\n", SZLangText(kLangID_PropSize, @"Size"), SZSizeValueText(_statistics->_unpackSize)];
  if (_statistics->_alternateStreamCount != 0)
  {
    [s appendString:@"\n"];
    [s appendFormat:@"%@: %llu\n", SZLangText(kLangID_PropNumAltStreams, @"Alternate Streams"),
                    _statistics->_alternateStreamCount];
    [s appendFormat:@"%@: %@\n", SZLangText(kLangID_PropAltStreamsSize, @"Alternate Streams Size"),
                    SZSizeValueText(_statistics->_alternateStreamsUnpackSize)];
  }
  [s appendString:@"\n"];
  [s appendString:SZLangText(kLangID_NoErrors, @"There are no errors")];
  return s;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZExtractResult %@ files=%llu errors=%lu arcErrors=%lu>",
          _statistics, _filesProcessed, (unsigned long)_errorCount, (unsigned long)_archiveErrorCount];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - progress tap (records every message the run produced)

/// Forwards SZProgressDelegate to the caller's delegate and keeps a copy of every message, so
/// a caller without a delegate (the unit tests, the Finder side) still gets the diagnostics.
/// Required methods always answer; optional ones mirror the wrapped delegate, because the
/// adapters decide what the engine may report by asking -respondsToSelector:.
@interface SZExtractProgressTap : NSObject <SZProgressDelegate>
@property (nonatomic, weak) id<SZProgressDelegate> inner;
@property (nonatomic, readonly) NSMutableArray<NSString *> *recorded;
@end

@implementation SZExtractProgressTap

- (instancetype)initWithDelegate:(id<SZProgressDelegate>)inner
{
  self = [super init];
  if (!self)
    return nil;
  _inner = inner;
  _recorded = [NSMutableArray array];
  return self;
}

- (BOOL)respondsToSelector:(SEL)selector
{
  // The optional part of the protocol is only "available" when the real delegate has it.
  static NSArray<NSString *> *optional = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    optional = @[@"progressSetTotalFiles:",
                 @"progressSetStatus:",
                 @"progressSetTitleFileName:",
                 @"progressScanFolders:files:totalSize:path:isDirectory:",
                 @"progressAskPasswordForEncryptionCancelled:",
                 @"progressRequestMemoryUseForPath:requiredSize:allowedSize:testMode:allowSkipArchive:",
                 @"progressMoveArchiveFrom:toPath:size:",
                 @"progressMoveArchiveCompleted:total:",
                 @"progressMoveArchiveFinished",
                 @"progressClearCancelState"];
  });
  if ([optional containsObject:NSStringFromSelector(selector)])
    return [self.inner respondsToSelector:selector];
  return [super respondsToSelector:selector];
}

- (void)progressShowMessage:(NSString *)message
{
  @synchronized (self) { [_recorded addObject:message ?: @""]; }
  [self.inner progressShowMessage:message];
}

- (void)progressSetTotal:(uint64_t)total { [self.inner progressSetTotal:total]; }
- (void)progressSetCompleted:(uint64_t)completed { [self.inner progressSetCompleted:completed]; }
- (void)progressSetRatioInfoInSize:(uint64_t)inSize outSize:(uint64_t)outSize
{
  [self.inner progressSetRatioInfoInSize:inSize outSize:outSize];
}
- (void)progressSetCurrentFile:(NSString *)path isDirectory:(BOOL)isDirectory
{
  [self.inner progressSetCurrentFile:path isDirectory:isDirectory];
}
- (void)progressSetNumFilesProcessed:(uint64_t)numFiles { [self.inner progressSetNumFilesProcessed:numFiles]; }

- (SZOverwriteAnswer)progressAskOverwriteExisting:(NSString *)existName
                                        existTime:(NSDate *)existTime
                                        existSize:(NSNumber *)existSize
                                          newName:(NSString *)newName
                                          newTime:(NSDate *)newTime
                                          newSize:(NSNumber *)newSize
                                    suggestedName:(NSString * _Nullable *)suggestedName
{
  if (!self.inner)
    return SZOverwriteAnswerYes;          // no UI: 7zG's -y behaviour
  return [self.inner progressAskOverwriteExisting:existName existTime:existTime existSize:existSize
                                          newName:newName newTime:newTime newSize:newSize
                                    suggestedName:suggestedName];
}

- (NSString *)progressAskPasswordForPath:(NSString *)path
{
  return [self.inner progressAskPasswordForPath:path];
}

- (void)progressSetOperationResult:(SZOperationResult)result path:(NSString *)path isEncrypted:(BOOL)encrypted
{
  [self.inner progressSetOperationResult:result path:path isEncrypted:encrypted];
}

- (BOOL)progressCheckBreak
{
  return self.inner ? [self.inner progressCheckBreak] : NO;
}

// Optional: only reached when the wrapped delegate implements them (see respondsToSelector:).
- (void)progressSetTotalFiles:(uint64_t)totalFiles
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressSetTotalFiles:totalFiles];
}
- (void)progressSetStatus:(SZProgressStatus)status
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressSetStatus:status];
}
- (void)progressSetTitleFileName:(NSString *)name
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressSetTitleFileName:name];
}
- (void)progressScanFolders:(uint64_t)numFolders files:(uint64_t)numFiles totalSize:(uint64_t)totalSize
                       path:(NSString *)path isDirectory:(BOOL)isDirectory
{
  if ([self.inner respondsToSelector:_cmd])
    [self.inner progressScanFolders:numFolders files:numFiles totalSize:totalSize path:path isDirectory:isDirectory];
}
- (NSString *)progressAskPasswordForEncryptionCancelled:(BOOL *)cancelled
{
  if (![self.inner respondsToSelector:_cmd])
    return nil;
  return [self.inner progressAskPasswordForEncryptionCancelled:cancelled];
}
- (SZMemoryUseAnswer)progressRequestMemoryUseForPath:(NSString *)path
                                        requiredSize:(uint64_t)requiredSize
                                         allowedSize:(uint64_t *)allowedSize
                                            testMode:(BOOL)testMode
                                    allowSkipArchive:(BOOL)allowSkipArchive
{
  if (![self.inner respondsToSelector:_cmd])
    return SZMemoryUseAnswerAllow;
  return [self.inner progressRequestMemoryUseForPath:path requiredSize:requiredSize
                                        allowedSize:allowedSize testMode:testMode
                                    allowSkipArchive:allowSkipArchive];
}
- (void)progressMoveArchiveFrom:(NSString *)s toPath:(NSString *)d size:(uint64_t)size
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressMoveArchiveFrom:s toPath:d size:size];
}
- (void)progressMoveArchiveCompleted:(uint64_t)current total:(uint64_t)total
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressMoveArchiveCompleted:current total:total];
}
- (void)progressMoveArchiveFinished
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressMoveArchiveFinished];
}
- (void)progressClearCancelState
{
  if ([self.inner respondsToSelector:_cmd]) [self.inner progressClearCancelState];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - IExtractCallbackUI + IOpenCallbackUI

/// The non-COM half of CExtractCallbackImp: the per-archive callbacks `Extract()` makes
/// directly (IExtractCallbackUI) and the ones the open goes through (IOpenCallbackUI).
/// Plain C++ object, created and destroyed on the worker thread; the COM half is `Fae`.
class CSZExtractUICallback Z7_final:
  public IExtractCallbackUI,
  public IOpenCallbackUI
{
public:
  Z7_IFACE_IMP(IExtractCallbackUI)
  Z7_IFACE_IMP(IOpenCallbackUI)

  /// The COM callback of the same run; password, delegate and error counters are shared.
  CSZExtractCallbackAdapter *Fae;
  bool TestMode;
  bool MultiArcMode;
  /// NumArchiveErrors (CExtractCallbackImp): archives that failed to open or to extract.
  UInt32 NumArchiveErrors;

  CSZExtractUICallback():
      Fae(NULL), TestMode(false), MultiArcMode(false), NumArchiveErrors(0),
      _needWriteArchivePath(true) {}

private:
  UString _currentArchivePath;
  bool _needWriteArchivePath;

  void AddMessage(const UString &s) const
  {
    if (Fae)
    {
      // Qualified: CSZExtractCallbackAdapter also declares the COM
      // IFolderOperationsExtractCallback::ShowMessage(const wchar_t *), which hides the
      // base-class helper.
      Fae->CSZCallbackBase::ShowMessage(SZStringFromUString(s));
      Fae->NumErrors++;
    }
  }
  void Add_ArchiveName_Error()
  {
    if (_needWriteArchivePath)
    {
      if (!_currentArchivePath.IsEmpty())
        AddMessage(_currentArchivePath);
      _needWriteArchivePath = false;
    }
  }
};

// GetOpenArcErrorMessage (FileManager/ExtractCallback.cpp:474-509)
static UString SZOpenArcErrorMessage(UInt32 errorFlags)
{
  UString s;
  for (unsigned i = 0; i < Z7_ARRAY_SIZE(k_ErrorFlagsLangIDs); i++)
  {
    const UInt32 f = (UInt32)1 << i;
    if ((errorFlags & f) == 0)
      continue;
    UString m = MyLoadString(k_ErrorFlagsLangIDs[i]);
    if (m.IsEmpty())
      continue;
    if (f == kpv_ErrorFlags_EncryptedHeadersError)
    {
      m += " : ";
      m += MyLoadString(kLangID_WrongPswGuess);
    }
    if (!s.IsEmpty())
      s.Add_LF();
    s += m;
    errorFlags &= ~f;
  }
  if (errorFlags != 0)
  {
    char sz[16];
    sz[0] = '0';
    sz[1] = 'x';
    ConvertUInt32ToHex(errorFlags, sz + 2);
    if (!s.IsEmpty())
      s.Add_LF();
    s += sz;
  }
  return s;
}

static void SZAddNewLineString(UString &s, const UString &m)
{
  s += m;
  s.Add_LF();
}

// ErrorInfo_Print (FileManager/ExtractCallback.cpp:511-537)
static void SZErrorInfoPrint(UString &s, const CArcErrorInfo &er)
{
  const UInt32 errorFlags = er.GetErrorFlags();
  const UInt32 warningFlags = er.GetWarningFlags();
  if (errorFlags != 0)
    SZAddNewLineString(s, SZOpenArcErrorMessage(errorFlags));
  if (!er.ErrorMessage.IsEmpty())
    SZAddNewLineString(s, er.ErrorMessage);
  if (warningFlags != 0)
  {
    s += MyLoadString(kLangID_PropWarningFlags);
    s.Add_Colon();
    s.Add_LF();
    SZAddNewLineString(s, SZOpenArcErrorMessage(warningFlags));
  }
  if (!er.WarningMessage.IsEmpty())
  {
    s += MyLoadString(kLangID_PropWarning);
    s += ": ";
    s += er.WarningMessage;
    s.Add_LF();
  }
}

static UString SZBracedType(const wchar_t *type)
{
  UString s('[');
  s += type ? type : L"";
  s.Add_Char(']');
  return s;
}

static UString SZFormatLang(UInt32 langID, const UString &argument)
{
  UString s = MyLoadString(langID);
  s.Replace(UString("{0}"), argument);
  return s;
}

// OpenResult_GUI (FileManager/ExtractCallback.cpp:548-619)
static void SZOpenResultText(UString &s, const CCodecs *codecs, const CArchiveLink &arcLink,
                             const wchar_t *name, HRESULT result)
{
  FOR_VECTOR (level, arcLink.Arcs)
  {
    const CArc &arc = arcLink.Arcs[level];
    const CArcErrorInfo &er = arc.ErrorInfo;
    if (!er.IsThereErrorOrWarning() && er.ErrorFormatIndex < 0)
      continue;
    if (s.IsEmpty())
    {
      s += name;
      s.Add_LF();
    }
    if (level != 0)
      SZAddNewLineString(s, arc.Path);
    SZErrorInfoPrint(s, er);
    if (er.ErrorFormatIndex >= 0)
    {
      SZAddNewLineString(s, MyLoadString(kLangID_PropWarning));
      if (arc.FormatIndex == er.ErrorFormatIndex)
        SZAddNewLineString(s, MyLoadString(kLangID_IsOpenWithOffset));
      else
      {
        SZAddNewLineString(s, SZFormatLang(kLangID_CantOpenAsType,
            SZBracedType(codecs->GetFormatNamePtr(er.ErrorFormatIndex))));
        SZAddNewLineString(s, SZFormatLang(kLangID_IsOpenAsType,
            SZBracedType(codecs->GetFormatNamePtr(arc.FormatIndex))));
      }
    }
  }

  if (arcLink.NonOpen_ErrorInfo.ErrorFormatIndex >= 0 || result != S_OK)
  {
    s += name;
    s.Add_LF();
    if (!arcLink.Arcs.IsEmpty())
      SZAddNewLineString(s, arcLink.NonOpen_ArcPath);

    if (arcLink.NonOpen_ErrorInfo.ErrorFormatIndex >= 0 || result == S_FALSE)
    {
      UInt32 id = kLangID_CantOpenArchive;
      UString param;
      if (arcLink.PasswordWasAsked)
        id = kLangID_CantOpenEncrypted;
      else if (arcLink.NonOpen_ErrorInfo.ErrorFormatIndex >= 0)
      {
        id = kLangID_CantOpenAsType;
        param = SZBracedType(codecs->GetFormatNamePtr(arcLink.NonOpen_ErrorInfo.ErrorFormatIndex));
      }
      UString s2 = SZFormatLang(id, param);
      s2.Replace(UString(" ''"), UString());
      s2.Replace(UString("''"), UString());
      s += s2;
    }
    else
      s += NError::MyFormatMessage(result);

    s.Add_LF();
    SZErrorInfoPrint(s, arcLink.NonOpen_ErrorInfo);
  }

  if (!s.IsEmpty() && s.Back() == '\n')
    s.DeleteBack();
}

HRESULT CSZExtractUICallback::BeforeOpen(const wchar_t *name, bool /* testMode */)
{
  // CExtractCallbackImp::BeforeOpen (ExtractCallback.cpp:415-424)
  _currentArchivePath = name ? name : L"";
  _needWriteArchivePath = true;
  if (!Fae)
    return S_OK;
  RINOK(Fae->CheckBreak())
  Fae->ArchivePath = SZStringFromUString(_currentArchivePath);
  if (Fae->Delegate && [Fae->Delegate respondsToSelector:@selector(progressSetTitleFileName:)])
    [Fae->Delegate progressSetTitleFileName:Fae->ArchivePath];
  Fae->SetStatus(SZProgressStatusOpening);
  return S_OK;
}

HRESULT CSZExtractUICallback::OpenResult(const CCodecs *codecs, const CArchiveLink &arcLink,
                                        const wchar_t *name, HRESULT result)
{
  // CExtractCallbackImp::OpenResult (ExtractCallback.cpp:621-636)
  _currentArchivePath = name ? name : L"";
  _needWriteArchivePath = true;
  UString s;
  SZOpenResultText(s, codecs, arcLink, _currentArchivePath.Ptr(), result);
  if (!s.IsEmpty())
  {
    NumArchiveErrors++;
    AddMessage(s);
    _needWriteArchivePath = false;
  }
  if (Fae)
    Fae->SetStatus(TestMode ? SZProgressStatusTesting : SZProgressStatusExtracting);
  return S_OK;
}

HRESULT CSZExtractUICallback::ThereAreNoFiles()
{
  return S_OK;   // no-op in the GUI (ExtractCallback.cpp:638)
}

HRESULT CSZExtractUICallback::ExtractResult(HRESULT result)
{
  // CExtractCallbackImp::ExtractResult (ExtractCallback.cpp:653-672)
  if (Fae)
    Fae->SetCurrentFile(L"", false);
  if (result == S_OK)
    return result;
  NumArchiveErrors++;
  if (result == E_ABORT)
    return result;
  Add_ArchiveName_Error();
  if (Fae && !Fae->CurrentFilePath.IsEmpty())
    AddMessage(Fae->CurrentFilePath);
  AddMessage(NError::MyFormatMessage(result));
  return S_OK;
}

HRESULT CSZExtractUICallback::SetPassword(const UString &password)
{
  if (Fae)
  {
    Fae->Password = password;
    Fae->PasswordIsDefined = true;
  }
  return S_OK;
}

HRESULT CSZExtractUICallback::Open_CheckBreak()
{
  return Fae ? Fae->CheckBreak() : S_OK;
}

HRESULT CSZExtractUICallback::Open_SetTotal(const UInt64 * /* files */, const UInt64 *bytes)
{
  // CExtractCallbackImp::Open_SetTotal (:102-124): only in single-archive mode.
  if (!MultiArcMode && bytes && Fae && Fae->Delegate)
    [Fae->Delegate progressSetTotal:*bytes];
  return S_OK;
}

HRESULT CSZExtractUICallback::Open_SetCompleted(const UInt64 *files, const UInt64 * /* bytes */)
{
  if (!MultiArcMode && files && Fae && Fae->Delegate)
    [Fae->Delegate progressSetNumFilesProcessed:*files];
  return Fae ? Fae->CheckBreak() : S_OK;
}

HRESULT CSZExtractUICallback::Open_Finished()
{
  return Fae ? Fae->CheckBreak() : S_OK;
}

HRESULT CSZExtractUICallback::Open_CryptoGetTextPassword(BSTR *password)
{
  // Same body as the extract-side CryptoGetTextPassword (ExtractCallback.cpp:551).
  if (!Fae)
    return E_ABORT;
  return Fae->AskPassword(password);
}

// ---------------------------------------------------------------------------
#pragma mark - SZArchiveExtractor

@implementation SZArchiveExtractor

+ (NSString *)correctFileName:(NSString *)name
{
  return SZStringFromUString(Get_Correct_FsFile_Name(SZUStringFromNSString(name)));
}

+ (NSString *)subfolderNameForArchiveNamed:(NSString *)archiveName
{
  // GetSubFolderNameForExtract (Explorer/ContextMenu.cpp:448-470), which is Windows-only code
  // and therefore reimplemented here verbatim.
  static const char * const kArcExts[] = { "7z", "zip", "tar", "wim" };
  const UString arcName = SZUStringFromNSString(archiveName);
  int dotPos = arcName.ReverseFind_Dot();
  if (dotPos < 0)
    return SZStringFromUString(Get_Correct_FsFile_Name(arcName) + L'~');

  const UString ext = arcName.Ptr((unsigned)(dotPos + 1));
  UString res = arcName.Left((unsigned)dotPos);
  res.TrimRight();
  dotPos = res.ReverseFind_Dot();
  if (dotPos > 0)
  {
    const UString ext2 = res.Ptr((unsigned)(dotPos + 1));
    bool ext2IsArc = false;
    for (unsigned i = 0; i < Z7_ARRAY_SIZE(kArcExts); i++)
      if (ext2.IsEqualTo_Ascii_NoCase(kArcExts[i]))
      {
        ext2IsArc = true;
        break;
      }
    if ((ext.IsEqualTo_Ascii_NoCase("001") && ext2IsArc)
        || (ext.IsEqualTo_Ascii_NoCase("rar")
            && (ext2.IsEqualTo_Ascii_NoCase("part001")
             || ext2.IsEqualTo_Ascii_NoCase("part01")
             || ext2.IsEqualTo_Ascii_NoCase("part1"))))
      res.DeleteFrom((unsigned)dotPos);
    res.TrimRight();
  }
  return SZStringFromUString(Get_Correct_FsFile_Name(res));
}

+ (BOOL)createOutputDirectory:(NSString *)path error:(NSError **)error
{
  if (path.length == 0)
    return YES;
  FString dir = SZFStringFromNSString(path);
  NName::NormalizeDirPathPrefix(dir);
  if (NDir::CreateComplexDir(dir))
    return YES;
  if (error)
  {
    // IDS_CANNOT_CREATE_FOLDER 3003 "Cannot create folder '{0}'" (01 8.3 step 2)
    NSString *text = [SZLangText(kLangID_CannotCreateFolder, @"Cannot create folder '{0}'")
                      stringByReplacingOccurrencesOfString:@"{0}" withString:path];
    *error = [SZErrors errorWithCode:SZErrorCodeEngine message:text];
  }
  return NO;
}

+ (nullable SZExtractResult *)testArchivesAtPaths:(NSArray<NSString *> *)archivePaths
                                          options:(SZExtractOptions *)options
                                         progress:(id<SZProgressDelegate>)progress
                                            error:(NSError **)error
{
  SZExtractOptions *copy = [options copy];
  copy.testMode = YES;
  return [self extractArchivesAtPaths:archivePaths options:copy progress:progress error:error];
}

+ (nullable SZExtractResult *)extractArchivesAtPaths:(NSArray<NSString *> *)archivePaths
                                             options:(SZExtractOptions *)options
                                            progress:(id<SZProgressDelegate>)progress
                                               error:(NSError **)error
{
  if (archivePaths.count == 0)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"no archives given"];
    return nil;
  }
  if (![SZCodecs loadCodecs:error])
    return nil;

  SZExtractProgressTap *tap = [[SZExtractProgressTap alloc] initWithDelegate:progress];
  SZExtractResult *result = [[SZExtractResult alloc] init];
  result->_testMode = options.testMode;

  NSString *message = nil;
  UString fatalMessage;
  const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
    CExtractOptions eo;
    eo.TestMode = options.testMode != NO;
    eo.PathMode = (NExtract::NPathMode::EEnum)options.pathMode;
    eo.PathMode_Force = options.pathModeForced != NO;
    eo.OverwriteMode = (NExtract::NOverwriteMode::EEnum)options.overwriteMode;
    eo.OverwriteMode_Force = options.overwriteModeForced != NO;
    eo.OutDirMode = (NExtractOutDirMode::EEnum)options.outDirMode;
    eo.ZoneMode = (NExtract::NZoneIdMode::EEnum)options.zoneIDMode;
    eo.ExcludeDirItems = options.excludeDirectoryItems != NO;
    eo.ExcludeFileItems = options.excludeFileItems != NO;
    if (options.eliminateDuplicateRoot)
    {
      eo.ElimDup.Def = true;
      eo.ElimDup.Val = options.eliminateDuplicateRoot.boolValue;
    }
    if (options.restoreFileSecurity)
    {
      eo.NtOptions.NtSecurity.Def = true;
      eo.NtOptions.NtSecurity.Val = options.restoreFileSecurity.boolValue;
    }
    if (options.extractSymbolicLinks)
    {
      eo.NtOptions.SymLinks.Def = true;
      eo.NtOptions.SymLinks.Val = options.extractSymbolicLinks.boolValue;
    }
    if (options.extractHardLinks)
    {
      eo.NtOptions.HardLinks.Def = true;
      eo.NtOptions.HardLinks.Val = options.extractHardLinks.boolValue;
    }
    if (options.extractAlternateStreams)
    {
      eo.NtOptions.AltStreams.Def = true;
      eo.NtOptions.AltStreams.Val = options.extractAlternateStreams.boolValue;
    }
    eo.NtOptions.PreAllocateOutFile = options.preAllocateOutputFile != NO;
    eo.NtOptions.PreserveATime = options.preserveAccessTime != NO;
    eo.NtOptions.MemLimit = options.memoryLimit;

    if (!options.testMode)
    {
      // ExtractGUI.cpp:188-247: the output dir is made absolute and slash-terminated.
      FString outputDir = SZFStringFromNSString(options.outputDirectory);
      if (outputDir.IsEmpty())
        NDir::GetCurrentDir(outputDir);
      FString full;
      if (!NDir::MyGetFullPathName(outputDir, full))
        full = outputDir;
      NName::NormalizeDirPathPrefix(full);
      eo.OutputDir = full;
    }

    // -t<type>: COpenType list for every archive of the batch.
    CObjectVector<COpenType> types;
    if (options.formatHint.length != 0)
      if (!ParseOpenTypes(*g_CodecsObj, SZUStringFromNSString(options.formatHint), types))
        return E_INVALIDARG;
    CIntVector excludedFormats;

    // "everything inside the archive": one include item "*", which makes
    // CCensorNode::AreAllAllowed() true so DecompressArchive skips per-item filtering.
    NWildcard::CCensor censor;
    censor.AddPreItem_Wildcard();
    censor.AddPathsToCensor(NWildcard::k_RelatPath);
    censor.ExtendExclude();

    UStringVector arcPaths, arcPathsFull;
    for (NSString *path in archivePaths)
    {
      const UString u = SZUStringFromNSString(path);
      arcPaths.Add(u);
      FString full;
      if (!NDir::MyGetFullPathName(us2fs(u), full))
        full = us2fs(u);
      arcPathsFull.Add(fs2us(full));
    }

    CMyComPtr2<IFolderArchiveExtractCallback, CSZExtractCallbackAdapter> fae;
    fae.Create_if_Empty();
    fae->Delegate = tap;
    fae->TestMode = options.testMode != NO;
    fae->OverwriteMode = eo.OverwriteMode;
    fae->ArchivePath = archivePaths.firstObject;
    if (options.password)
    {
      fae->Password = SZUStringFromNSString(options.password);
      fae->PasswordIsDefined = true;
    }

    CSZExtractUICallback ui;
    ui.Fae = fae.ClsPtr();
    ui.TestMode = eo.TestMode;
    ui.MultiArcMode = (archivePaths.count > 1);

    [tap progressSetStatus:eo.TestMode ? SZProgressStatusTesting : SZProgressStatusExtracting];
    if (archivePaths.count == 1)
      [tap progressSetTitleFileName:archivePaths.firstObject];

    // -scrc<M> (03 2.6): the same CHashBundle GUI.cpp:275-281 builds, handed to Extract() as its
    // IHashCalc so CArchiveExtractCallback::SetHashMethods wraps every output stream in a
    // COutStreamWithHash. No methods -> NULL, exactly as before.
    CHashBundle hb;
    CHashBundle *hbPtr = NULL;
    if (options.hashMethods.count != 0)
    {
      UStringVector methods;
      for (NSString *m in options.hashMethods)
        methods.Add(SZUStringFromNSString(m));
      RINOK(hb.SetMethods(methods))
      hbPtr = &hb;
      // MainName / FirstFileName stay empty, as in GUI.cpp:275-281: the extract path shows
      // "Files" + "Size" + the per-method sums, never a single "Name" row.
    }

    CDecompressStat stat;
    const HRESULT res = Extract(g_CodecsObj, types, excludedFormats,
                                arcPaths, arcPathsFull, censor.Pairs.Front().Head, eo,
                                &ui, &ui, fae.Interface(),
                                hbPtr,
                                fatalMessage, stat);

    result->_statistics->_archiveCount = stat.NumArchives;
    result->_statistics->_unpackSize = stat.UnpackSize;
    result->_statistics->_alternateStreamsUnpackSize = stat.AltStreams_UnpackSize;
    result->_statistics->_packSize = stat.PackSize;
    result->_statistics->_folderCount = stat.NumFolders;
    result->_statistics->_fileCount = stat.NumFiles;
    result->_statistics->_alternateStreamCount = stat.NumAltStreams;
    result->_filesProcessed = fae->NumFilesProcessed;
    result->_errorCount = fae->NumErrors;
    result->_archiveErrorCount = ui.NumArchiveErrors;
    result->_firstFailure = (SZOperationResult)fae->FirstBadOpRes;
    result->_passwordWasAsked = fae->PasswordWasAsked ? YES : NO;
    result->_password = fae->PasswordIsDefined ? SZStringFromUString(fae->Password) : nil;

    // ExtractGUI.cpp:129-136: with a hash bundle and a clean run, the results dialog gets
    // "Archives:" + "Packed Size" and then AddHashBundleRes, and it replaces the test summary.
    if (hbPtr && res == S_OK && fae->NumErrors == 0 && ui.NumArchiveErrors == 0)
    {
      NSArray<SZHashResultRow *> *leading = @[
        SZMakeHashResultRow(SZLangText(kLangID_ArchivesColon, @"Archives:"),
                            [NSString stringWithFormat:@"%llu", (unsigned long long)stat.NumArchives]),
        SZMakeHashResultRow(SZLangText(kLangID_PropPackedSize, @"Packed Size"),
                            SZHashSizeValueString(stat.PackSize))
      ];
      result->_hashResults = SZHashResultsFromBundle(hb, nil, leading);
    }
    return res;
  });

  [result->_messages addObjectsFromArray:tap.recorded];

  if (hr == S_OK)
  {
    // 7zG shows a non-empty errorMessage as the final error box even when Extract returned
    // S_OK (CProgressThreadVirt::Process, 01 8.7).
    if (!fatalMessage.IsEmpty())
    {
      NSString *text = SZStringFromUString(fatalMessage);
      [result->_messages addObject:text];
      result->_archiveErrorCount++;
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeEngine message:text];
      return nil;
    }
    return result;
  }

  if (error)
  {
    NSString *text = !fatalMessage.IsEmpty() ? SZStringFromUString(fatalMessage) : message;
    // HResultToMessage (ProgressDialog2.cpp:1477-1483): E_OUTOFMEMORY is IDS_MEM_ERROR 3000, not
    // the errno text -- the same four lines SZUpdaterError / SZHasherError carry (opsgaps).
    if (hr == (HRESULT)E_OUTOFMEMORY && text.length == 0)
      text = SZLangText(kLangID_MemError, @"The system cannot allocate the required amount of memory");
    if (result.firstFailure == SZOperationResultWrongPassword && hr != (HRESULT)E_ABORT)
      *error = [SZErrors errorWithCode:SZErrorCodeWrongPassword
                               message:SZLangText(kLangID_WrongPswClaim, @"Wrong password")];
    else
      *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:text];
  }
  return nil;
}

@end

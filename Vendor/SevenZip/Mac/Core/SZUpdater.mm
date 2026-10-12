// SZUpdater.mm -- see include/SZUpdater.h.
//
// The port of CPP/7zip/UI/GUI/UpdateGUI.cpp (+ UpdateCallbackGUI.cpp,
// UpdateCallbackGUI2.cpp) on top of the engine's own UpdateArchive()
// (CPP/7zip/UI/Common/Update.cpp). Everything the Windows product does after the Compress
// dialog closes happens here; the dialog itself is Swift (Mac/App/Dialogs/Compress*.swift).

#import "SZUpdater.h"

#import "Internal/SZBridgeUtils.h"
#import "Internal/SZCallbackAdapters.h"
#import "SZCodecs.h"
#import "SZError.h"
#import "SZLang.h"

// Engine headers this file needs beyond Internal/SZEngine.h, with the same BOOL rename
// discipline (MyWindows.h `typedef int BOOL` clashes with Objective-C's BOOL).
#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL
#include "../../CPP/Common/Wildcard.h"
#include "../../CPP/7zip/UI/Common/ArchiveName.h"
#include "../../CPP/7zip/UI/Common/DirItem.h"
#include "../../CPP/7zip/UI/Common/EnumDirItems.h"
#include "../../CPP/7zip/UI/Common/Update.h"
#include "../../CPP/7zip/UI/Common/UpdateAction.h"
#include "../../CPP/7zip/UI/Common/WorkDir.h"
#pragma pop_macro("BOOL")

using namespace NWindows;

NSErrorUserInfoKey const SZPathExceptionUserInfoKey = @"SZPathException";

static NSError *SZUpdaterError(HRESULT hr, NSString *engineMessage);

/// `SZRunCatching` plus the one distinction an HRESULT cannot carry: `CMessagePathException` derives
/// from `UString`, so the generic handler flattens it into E_FAIL, while `WinMain` maps it to exit
/// code 7 (GUI.cpp:452-456). Catching it first and flagging the error keeps that arm reachable.
/// `engineMessageInOut` may already hold a message the lambda produced (`CUpdateErrorInfo::Message`);
/// it wins over the one the catch handler derives.
template <class F>
static NSError *SZRunCatchingPathException(NSString * _Nullable * _Nullable engineMessageInOut, F &&f)
{
  NSString *pathMessage = nil;
  NSString *caught = nil;
  HRESULT hr = S_OK;
  try
  {
    hr = f();
  }
  catch (const CMessagePathException &e)
  {
    pathMessage = SZStringFromUString(e);
    hr = E_FAIL;
  }
  catch (...)
  {
    hr = SZHandleCurrentException(&caught);
  }
  if (hr == S_OK)
    return nil;
  if (pathMessage)
    return [NSError errorWithDomain:SZErrorDomain
                              code:SZErrorCodeInvalidArgument
                          userInfo:@{ NSLocalizedDescriptionKey: pathMessage,
                                      SZPathExceptionUserInfoKey: @YES }];
  NSString *message = (engineMessageInOut && (*engineMessageInOut).length != 0)
      ? *engineMessageInOut : caught;
  return SZUpdaterError(hr, message);
}

// ---------------------------------------------------------------------------
#pragma mark - SZPathSpec

@implementation SZPathSpec

+ (instancetype)specWithPath:(NSString *)path
                     include:(BOOL)include
                recursedType:(SZRecursedType)recursedType
            wildcardMatching:(BOOL)wildcardMatching
                    markMode:(SZWildcardMarkMode)markMode
{
  SZPathSpec *spec = [[SZPathSpec alloc] init];
  if (spec)
  {
    spec->_path = [(path ?: @"") copy];
    spec->_include = include;
    spec->_recursedType = recursedType;
    spec->_wildcardMatching = wildcardMatching;
    spec->_markMode = markMode;
  }
  return spec;
}

+ (instancetype)literalSpecWithPath:(NSString *)path
{
  // AddPreItem_NoWildcard (Wildcard.h:211-218): include, no wildcard matching, kMark_FileOrDir.
  return [self specWithPath:path
                    include:YES
               recursedType:SZRecursedTypeNonRecursed
           wildcardMatching:NO
                   markMode:SZWildcardMarkModeFileOrDir];
}

- (id)copyWithZone:(NSZone *)zone
{
  (void)zone;
  return [SZPathSpec specWithPath:_path include:_include recursedType:_recursedType
                wildcardMatching:_wildcardMatching markMode:_markMode];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZPathSpec %@%@%@>", _include ? @"" : @"!",
          _path, _wildcardMatching ? @"" : @" (literal)"];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - SZRenamePair

@implementation SZRenamePair

+ (instancetype)pairWithOldName:(NSString *)oldName
                        newName:(NSString *)newName
                wildcardParsing:(BOOL)wildcardParsing
{
  SZRenamePair *pair = [[SZRenamePair alloc] init];
  if (pair)
  {
    pair->_oldName = [(oldName ?: @"") copy];
    pair->_newName = [(newName ?: @"") copy];
    pair->_wildcardParsing = wildcardParsing;
  }
  return pair;
}

- (id)copyWithZone:(NSZone *)zone
{
  (void)zone;
  return [SZRenamePair pairWithOldName:_oldName newName:_newName wildcardParsing:_wildcardParsing];
}

- (BOOL)isSupported
{
  // CRenamePair::Prepare (Update.cpp:288-295). RecursedType is always kNonRecursed here, so only
  // the wildcard test is left; DoesNameContainWildcard is the engine's own predicate.
  if (!_wildcardParsing)
    return YES;
  return DoesNameContainWildcard(SZUStringFromNSString(_oldName)) ? NO : YES;
}

- (nullable NSString *)unsupportedDetail
{
  if (self.isSupported)
    return nil;
  // AddRenamePair (ArchiveCommandLine.cpp:511-522): old name, new name, then the recursion switch.
  // RecursedType is kNonRecursed, which contributes no third line.
  return [NSString stringWithFormat:@"%@\n%@\n", _oldName, _newName];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZRenamePair %@ -> %@>", _oldName, _newName];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - SZUpdateProperty

@implementation SZUpdateProperty

+ (instancetype)propertyWithName:(NSString *)name value:(NSString *)value
{
  SZUpdateProperty *p = [[SZUpdateProperty alloc] init];
  if (p)
  {
    p->_name = [name copy];
    p->_value = [(value ?: @"") copy];
  }
  return p;
}

- (id)copyWithZone:(NSZone *)zone
{
  (void)zone;
  return [SZUpdateProperty propertyWithName:_name value:_value];
}

- (NSString *)switchText
{
  return _value.length == 0 ? _name : [NSString stringWithFormat:@"%@=%@", _name, _value];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZUpdateProperty %@>", self.switchText];
}

- (BOOL)isEqual:(id)object
{
  if (![object isKindOfClass:[SZUpdateProperty class]])
    return NO;
  SZUpdateProperty *o = object;
  return [_name isEqualToString:o.name] && [_value isEqualToString:o.value];
}

- (NSUInteger)hash { return _name.hash ^ _value.hash; }

@end

// ---------------------------------------------------------------------------
#pragma mark - SZUpdateOptions

@implementation SZUpdateOptions

- (instancetype)initWithArchivePath:(NSString *)archivePath
{
  if ((self = [super init]))
  {
    _archivePath = [archivePath copy];
    _formatIndex = -1;
    _properties = @[];
    _volumeSizes = @[];
    _updateMode = SZUpdateModeAdd;
    _pathMode = SZCompressPathModeRelative;
    _nameMode = SZArchiveNameModeSmart;
  }
  return self;
}

- (instancetype)init { return [self initWithArchivePath:@""]; }

+ (instancetype)optionsWithArchivePath:(NSString *)archivePath
{
  return [[self alloc] initWithArchivePath:archivePath];
}

- (id)copyWithZone:(NSZone *)zone
{
  (void)zone;
  SZUpdateOptions *o = [[SZUpdateOptions alloc] initWithArchivePath:_archivePath];
  o.formatName = _formatName;
  o.formatIndex = _formatIndex;
  o.properties = _properties;
  o.updateMode = _updateMode;
  o.pathMode = _pathMode;
  o.nameMode = _nameMode;
  o.sfxMode = _sfxMode;
  o.sfxModulePath = _sfxModulePath;
  o.volumeSizes = _volumeSizes;
  o.password = _password;
  o.asksPassword = _asksPassword;
  o.deleteAfterCompressing = _deleteAfterCompressing;
  o.setArchiveMTime = _setArchiveMTime;
  o.openShareForWrite = _openShareForWrite;
  o.stopAfterOpenError = _stopAfterOpenError;
  o.preserveATime = _preserveATime;
  o.storeSymLinks = _storeSymLinks;
  o.storeHardLinks = _storeHardLinks;
  o.storeAltStreams = _storeAltStreams;
  o.storeNtSecurity = _storeNtSecurity;
  o.workingDirectory = _workingDirectory;
  o.emailMode = _emailMode;
  o.emailRemoveAfter = _emailRemoveAfter;
  o.emailAddress = _emailAddress;
  return o;
}

@end

// ---------------------------------------------------------------------------
#pragma mark - SZUpdateResult

@interface SZUpdateResult ()
@property (nonatomic, copy) NSString *archivePath;
@property (nonatomic) uint64_t archiveSize;
@property (nonatomic) NSUInteger volumeCount;
@property (nonatomic) BOOL isMultiVolume;
@property (nonatomic) uint64_t filesProcessed;
@property (nonatomic) uint64_t scannedFileCount;
@property (nonatomic) uint64_t scannedTotalSize;
@property (nonatomic) NSUInteger errorCount;
@property (nonatomic, copy) NSArray<NSString *> *failedPaths;
@property (nonatomic) BOOL passwordWasAsked;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy) NSArray<NSString *> *deletedPaths;
@end

@implementation SZUpdateResult

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZUpdateResult %@ size=%llu volumes=%lu files=%llu errors=%lu>",
                                    _archivePath, (unsigned long long)_archiveSize,
                                    (unsigned long)_volumeCount, (unsigned long long)_filesProcessed,
                                    (unsigned long)_errorCount];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - The IUpdateCallbackUI2 adapter

/// CUpdateCallbackGUI / CUpdateCallbackGUI2 (7zG) forwarding to an id<SZProgressDelegate>.
/// Plain C++ object, not COM: IUpdateCallbackUI2 and IOpenCallbackUI are non-COM pure
/// interfaces. Lives on the worker thread only, like every other adapter
/// (Internal/SZCallbackAdapters.h "OWNERSHIP RULE").
namespace {

// The status IDs k_UpdNotifyLangs maps NUpdateNotifyOp onto (UpdateCallbackGUI2.cpp:17-27).
const SZProgressStatus kUpdateNotifyStatus[] =
{
  SZProgressStatusAdd,        // NUpdateNotifyOp::kAdd
  SZProgressStatusUpdate,     // kUpdate
  SZProgressStatusAnalyze,    // kAnalyze
  SZProgressStatusReplicate,  // kReplicate
  SZProgressStatusRepack,     // kRepack
  SZProgressStatusSkipping,   // kSkip
  SZProgressStatusDelete,     // kDelete
  SZProgressStatusHeader      // kHeader
};

class CSZUpdateUICallback Z7_final:
  public IOpenCallbackUI,
  public IUpdateCallbackUI2,
  public CSZCallbackBase
{
  Z7_IFACE_IMP(IOpenCallbackUI)
  Z7_IFACE_IMP(IUpdateCallbackUI)
  Z7_IFACE_IMP(IDirItemsCallback)
  Z7_IFACE_IMP(IUpdateCallbackUI2)

public:
  /// `-p` without a value: ask the delegate for the encryption password
  /// (CUpdateCallbackGUI::AskPassword -> ShowAskPasswordDialog). Named differently from the
  /// base class's AskPassword(BSTR*) helper so the helper stays reachable.
  bool AskPasswordForEncryption = false;
  UInt64 NumFiles = 0;
  UInt32 NumErrors = 0;
  /// CUpdateCallbackGUI::FailedFiles: scan / open / read failures (7zG exit code 1).
  __strong NSMutableArray<NSString *> *FailedFiles = [NSMutableArray array];
  /// The sources `-sdel` removed, in order.
  __strong NSMutableArray<NSString *> *DeletedFiles = [NSMutableArray array];
  UInt64 ScannedFiles = 0;
  UInt64 ScannedBytes = 0;
  CFinishArchiveStat FinishStat;

private:
  // MoveArc_* status line (CUpdateCallbackGUI2::MoveArc_UpdateStatus).
  UInt64 _moveTotal = 0;
  UInt64 _moveCurrent = 0;
  UInt64 _movePercents = 0;

  HRESULT SetOperationStatus(UInt32 notifyOp, const wchar_t *name, bool isDir)
  {
    if (notifyOp < Z7_ARRAY_SIZE(kUpdateNotifyStatus))
      SetStatus(kUpdateNotifyStatus[notifyOp]);
    SetCurrentFile(name, isDir);
    return CheckBreak();
  }
};

// ---- IUpdateCallbackUI ----

HRESULT CSZUpdateUICallback::WriteSfx(const wchar_t *name, UInt64 size)
{
  (void)size;
  // CUpdateCallbackGUI::WriteSfx sets the literal (unlocalized) status "WriteSfx"; there is no
  // lang ID for it, so the port shows the stub as the current file instead.
  SetCurrentFile(name, false);
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::SetTotal(UInt64 size)
{
  if (Delegate)
    [Delegate progressSetTotal:size];
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::SetCompleted(const UInt64 *completeValue)
{
  if (completeValue && Delegate)
    [Delegate progressSetCompleted:*completeValue];
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize)
{
  if (Delegate)
    [Delegate progressSetRatioInfoInSize:(inSize ? *inSize : 0) outSize:(outSize ? *outSize : 0)];
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::CheckBreak()
{
  return CSZCallbackBase::CheckBreak();
}

HRESULT CSZUpdateUICallback::SetNumItems(const CArcToDoStat &stat)
{
  SetTotalFiles(stat.Get_NumDataItems_Total());
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::GetStream(const wchar_t *name, bool isDir, bool /* isAnti */, UInt32 mode)
{
  return SetOperationStatus(mode, name, isDir);
}

HRESULT CSZUpdateUICallback::OpenFileError(const FString &path, DWORD systemError)
{
  // CUpdateCallbackGUI::OpenFileError returns S_FALSE: list the error and skip the file.
  [FailedFiles addObject:SZStringFromFString(path)];
  NumErrors++;
  ShowErrorCodeWithName(HRESULT_FROM_WIN32(systemError), fs2us(path).Ptr());
  return S_FALSE;
}

HRESULT CSZUpdateUICallback::ReadingFileError(const FString &path, DWORD systemError)
{
  [FailedFiles addObject:SZStringFromFString(path)];
  NumErrors++;
  ShowErrorCodeWithName(HRESULT_FROM_WIN32(systemError), fs2us(path).Ptr());
  return S_OK;
}

HRESULT CSZUpdateUICallback::SetOperationResult(Int32 /* operationResult */)
{
  NumFiles++;
  if (Delegate)
    [Delegate progressSetNumFilesProcessed:NumFiles];
  return S_OK;
}

HRESULT CSZUpdateUICallback::ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t *name)
{
  // Re-packing existing items: SetExtractErrorMessage + the error list.
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
    NumErrors++;
  ReportOperationResult(opRes, isEncrypted, name);
  return S_OK;
}

HRESULT CSZUpdateUICallback::ReportUpdateOperation(UInt32 op, const wchar_t *name, bool isDir)
{
  return SetOperationStatus(op, name, isDir);
}

HRESULT CSZUpdateUICallback::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password)
{
  *password = NULL;
  if (passwordIsDefined)
    *passwordIsDefined = BoolToInt(PasswordIsDefined);
  if (!PasswordIsDefined && AskPasswordForEncryption)
  {
    // CUpdateCallbackGUI2::ShowAskPasswordDialog: ICryptoGetTextPassword2 semantics —
    // nil + cancelled == false means "no password", cancelled == YES means E_ABORT.
    BOOL cancelled = NO;
    NSString *answer = nil;
    if (Delegate && [Delegate respondsToSelector:@selector(progressAskPasswordForEncryptionCancelled:)])
      answer = [Delegate progressAskPasswordForEncryptionCancelled:&cancelled];
    if (cancelled)
      return E_ABORT;
    PasswordWasAsked = true;
    if (answer)
    {
      Password = SZUStringFromNSString(answer);
      PasswordIsDefined = true;
    }
  }
  if (passwordIsDefined)
    *passwordIsDefined = BoolToInt(PasswordIsDefined);
  return StringToBstr(Password, password);
}

HRESULT CSZUpdateUICallback::CryptoGetTextPassword(BSTR *password)
{
  return CryptoGetTextPassword2(NULL, password);
}

HRESULT CSZUpdateUICallback::ShowDeleteFile(const wchar_t *name, bool isDir)
{
  return SetOperationStatus(NUpdateNotifyOp::kDelete, name, isDir);
}

// ---- IDirItemsCallback ----

HRESULT CSZUpdateUICallback::ScanError(const FString &path, DWORD systemError)
{
  [FailedFiles addObject:SZStringFromFString(path)];
  NumErrors++;
  ShowErrorCodeWithName(HRESULT_FROM_WIN32(systemError), fs2us(path).Ptr());
  return S_OK;
}

HRESULT CSZUpdateUICallback::ScanProgress(const CDirItemsStat &st, const FString &path, bool isDir)
{
  if (Delegate && [Delegate respondsToSelector:@selector(progressScanFolders:files:totalSize:path:isDirectory:)])
    [Delegate progressScanFolders:st.NumDirs
                            files:st.NumFiles + st.NumAltStreams
                        totalSize:st.GetTotalBytes()
                             path:SZStringFromFString(path)
                      isDirectory:isDir ? YES : NO];
  return CheckBreak();
}

// ---- IUpdateCallbackUI2 ----

HRESULT CSZUpdateUICallback::OpenResult(const CCodecs *codecs, const CArchiveLink &arcLink,
                                        const wchar_t *name, HRESULT result)
{
  // OpenResult_GUI lives in the Windows FileManager; what matters for the port is the
  // IDS_CANT_OPEN_ARCHIVE 3002 / IDS_UPDATE_NOT_SUPPORTED case when an existing archive is
  // being updated (01 8.5 step 3).
  (void)codecs;
  (void)arcLink;
  if (result == S_OK)
    return S_OK;
  NSString *text = (result == S_FALSE) ? @"Cannot open file as archive"
                                       : [SZErrors messageForHRESULT:(uint32_t)result];
  NumErrors++;
  ShowMessageWithName(text, name);
  return S_OK;
}

HRESULT CSZUpdateUICallback::StartScanning()
{
  SetStatus(SZProgressStatusScanning);
  return S_OK;
}

HRESULT CSZUpdateUICallback::FinishScanning(const CDirItemsStat &st)
{
  ScannedFiles = st.NumFiles + st.NumAltStreams;
  ScannedBytes = st.GetTotalBytes();
  if (Delegate && [Delegate respondsToSelector:@selector(progressScanFolders:files:totalSize:path:isDirectory:)])
    [Delegate progressScanFolders:st.NumDirs
                            files:ScannedFiles
                        totalSize:ScannedBytes
                             path:@""
                      isDirectory:YES];
  SetStatus(SZProgressStatusNone);
  return S_OK;
}

HRESULT CSZUpdateUICallback::StartOpenArchive(const wchar_t * /* name */) { return S_OK; }

HRESULT CSZUpdateUICallback::StartArchive(const wchar_t *name, bool /* updating */)
{
  SetStatus(SZProgressStatusCompressing);
  if (Delegate && [Delegate respondsToSelector:@selector(progressSetTitleFileName:)])
    [Delegate progressSetTitleFileName:SZStringFromWChars(name, name ? (unsigned)MyStringLen(name) : 0)];
  return S_OK;
}

HRESULT CSZUpdateUICallback::FinishArchive(const CFinishArchiveStat &st)
{
  FinishStat = st;
  SetStatus(SZProgressStatusNone);
  return S_OK;
}

HRESULT CSZUpdateUICallback::DeletingAfterArchiving(const FString &path, bool isDir)
{
  [DeletedFiles addObject:SZStringFromFString(path)];
  SetStatus(SZProgressStatusRemoving);
  SetCurrentFile(fs2us(path).Ptr(), isDir);
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::FinishDeletingAfterArchiving()
{
  SetStatus(SZProgressStatusNone);
  return S_OK;
}

HRESULT CSZUpdateUICallback::MoveArc_Start(const wchar_t *srcTempPath, const wchar_t *destFinalPath,
                                           UInt64 totalSize, Int32 /* updateMode */)
{
  _movePercents = 0;
  _moveTotal = totalSize;
  _moveCurrent = 0;
  if (Delegate && [Delegate respondsToSelector:@selector(progressMoveArchiveFrom:toPath:size:)])
    [Delegate progressMoveArchiveFrom:SZStringFromWChars(srcTempPath, srcTempPath ? (unsigned)MyStringLen(srcTempPath) : 0)
                              toPath:SZStringFromWChars(destFinalPath, destFinalPath ? (unsigned)MyStringLen(destFinalPath) : 0)
                                size:totalSize];
  SetStatus(SZProgressStatusMoving);
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::MoveArc_Progress(UInt64 totalSize, UInt64 currentSize)
{
  _moveTotal = totalSize;
  _moveCurrent = currentSize;
  UInt64 percents = 0;
  if (totalSize != 0)
    percents = (totalSize < ((UInt64)1 << 57)) ? currentSize * 100 / totalSize
                                              : currentSize / (totalSize / 100);
  if (percents == _movePercents)
    return CheckBreak();
  _movePercents = percents;
  if (Delegate && [Delegate respondsToSelector:@selector(progressMoveArchiveCompleted:total:)])
    [Delegate progressMoveArchiveCompleted:currentSize total:totalSize];
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::MoveArc_Finish()
{
  if (Delegate && [Delegate respondsToSelector:@selector(progressMoveArchiveFinished)])
    [Delegate progressMoveArchiveFinished];
  SetStatus(SZProgressStatusNone);
  return S_OK;
}

// ---- IOpenCallbackUI (opening the archive that is being updated) ----

HRESULT CSZUpdateUICallback::Open_CheckBreak() { return CheckBreak(); }

HRESULT CSZUpdateUICallback::Open_SetTotal(const UInt64 * /* files */, const UInt64 * /* bytes */)
{
  return S_OK;
}

HRESULT CSZUpdateUICallback::Open_SetCompleted(const UInt64 * /* files */, const UInt64 * /* bytes */)
{
  return CheckBreak();
}

HRESULT CSZUpdateUICallback::Open_Finished() { return S_OK; }

HRESULT CSZUpdateUICallback::Open_CryptoGetTextPassword(BSTR *password)
{
  // Re-opening an encrypted archive to update it: this is the *decryption* password, asked
  // like everywhere else (ICryptoGetTextPassword).
  PasswordWasAsked = true;
  if (PasswordIsDefined)
    return StringToBstr(Password, password);
  return CSZCallbackBase::AskPassword(password);
}

}  // namespace

// ---------------------------------------------------------------------------
#pragma mark - Option translation

static const NUpdateArchive::CActionSet *SZActionSetForUpdateMode(SZUpdateMode mode)
{
  // g_UpdateMode_Pairs (UpdateGUI.cpp:290-296) + the console `d` command.
  switch (mode)
  {
    case SZUpdateModeAdd:    return &NUpdateArchive::k_ActionSet_Add;
    case SZUpdateModeUpdate: return &NUpdateArchive::k_ActionSet_Update;
    case SZUpdateModeFresh:  return &NUpdateArchive::k_ActionSet_Fresh;
    case SZUpdateModeSync:   return &NUpdateArchive::k_ActionSet_Sync;
    case SZUpdateModeDelete: return &NUpdateArchive::k_ActionSet_Delete;
  }
  return &NUpdateArchive::k_ActionSet_Add;
}

static NWildcard::ECensorPathMode SZCensorPathMode(SZCompressPathMode mode)
{
  switch (mode)
  {
    case SZCompressPathModeRelative: return NWildcard::k_RelatPath;
    case SZCompressPathModeFull:     return NWildcard::k_FullPath;
    case SZCompressPathModeAbsolute: return NWildcard::k_AbsPath;
  }
  return NWildcard::k_RelatPath;
}

static EArcNameMode SZEngineArcNameMode(SZArchiveNameMode mode)
{
  switch (mode)
  {
    case SZArchiveNameModeSmart: return k_ArcNameMode_Smart;
    case SZArchiveNameModeExact: return k_ArcNameMode_Exact;
    case SZArchiveNameModeAdd:   return k_ArcNameMode_Add;
  }
  return k_ArcNameMode_Smart;
}

static void SZSetBoolPair(CBoolPair &pair, NSNumber *value)
{
  if (!value)
  {
    pair.Def = false;
    pair.Val = false;
    return;
  }
  pair.Def = true;
  pair.Val = value.boolValue ? true : false;
}

/// The format index to compress with: explicit index, then the name, then the path
/// (`CCodecs::FindFormatForArchiveName`, what `7z a x.zip` does). -1 when nothing matches.
/// `AddNameToCensor` (ArchiveCommandLine.cpp:474-495): the `r` modifier decides `Recursive`, and
/// for `-r0` it does so per name, from whether that name contains a wildcard.
static void SZAddSpecToCensor(NWildcard::CCensor &censor, SZPathSpec *spec)
{
  const UString name = SZUStringFromNSString(spec.path);
  bool recursed = false;
  switch (spec.recursedType)
  {
    case SZRecursedTypeWildcardOnlyRecursed: recursed = DoesNameContainWildcard(name); break;
    case SZRecursedTypeRecursed:             recursed = true; break;
    default: break;
  }
  NWildcard::CCensorPathProps props;
  props.Recursive = recursed;
  props.WildcardMatching = spec.wildcardMatching ? true : false;
  props.MarkMode = (Byte)spec.markMode;
  censor.AddPreItem(spec.include ? true : false, name, props);
}

/// `HResultToMessage` (FileManager/ProgressDialog2.cpp:1477-1483): E_OUTOFMEMORY has its own lang
/// string, IDS_MEM_ERROR 3000, rather than `MyFormatMessage`'s errno text. Applied here so the
/// Progress dialog's final message and the command-mode box both say what Windows says.
static NSError *SZUpdaterError(HRESULT hr, NSString *engineMessage)
{
  if (hr == E_OUTOFMEMORY && engineMessage.length == 0)
    engineMessage = [SZLang.shared stringForID:3000
                                      fallback:@"The system cannot allocate the required amount of memory"];
  return [SZErrors errorWithHRESULT:(uint32_t)hr message:engineMessage];
}

static int SZResolveFormatIndex(CCodecs *codecs, SZUpdateOptions *options)
{
  if (options.formatIndex >= 0 && options.formatIndex < (NSInteger)codecs->Formats.Size())
    return (int)options.formatIndex;
  if (options.formatName.length != 0)
  {
    const int i = codecs->FindFormatForArchiveType(SZUStringFromNSString(options.formatName));
    if (i >= 0)
      return i;
  }
  return codecs->FindFormatForArchiveName(SZUStringFromNSString(options.archivePath));
}

// ---------------------------------------------------------------------------
#pragma mark - SZUpdater

@implementation SZUpdater

+ (nullable NSString *)sfxModulePathNamed:(NSString *)fileName
{
  // The stubs live in the app bundle's Resources/SFX (Mac/project.yml). A dev/test override
  // through SEVENZIP_SFX_DIR comes first so the unit tests can find them without the app.
  NSMutableArray<NSString *> *candidates = [NSMutableArray array];
  const char *env = getenv("SEVENZIP_SFX_DIR");
  if (env && *env)
    [candidates addObject:[@(env) stringByAppendingPathComponent:fileName]];
  NSString *rel = [@"SFX" stringByAppendingPathComponent:fileName];
  for (NSBundle *bundle in @[ [NSBundle mainBundle], [NSBundle bundleForClass:[SZUpdater class]] ])
  {
    NSString *r = bundle.resourcePath;
    if (r)
    {
      [candidates addObject:[r stringByAppendingPathComponent:rel]];
      [candidates addObject:[r stringByAppendingPathComponent:fileName]];
    }
  }
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *candidate in candidates)
    if ([fm fileExistsAtPath:candidate])
      return candidate;
  return nil;
}

+ (nullable NSString *)defaultSFXModulePath
{
  // kDefaultSfxModule = "7z.sfx" (UpdateGUI.cpp:31).
  return [self sfxModulePathNamed:@"7z.sfx"];
}

+ (BOOL)formatSupportsUpdate:(NSString *)formatName
{
  SZFormatInfo *info = [SZCodecs formatNamed:formatName];
  return info ? info.updateEnabled : NO;
}

+ (BOOL)formatSupportsSFX:(NSString *)formatName
{
  // g_Formats (CompressDialog.cpp:364): 7z is the only row with kFF_SFX.
  return [formatName caseInsensitiveCompare:@"7z"] == NSOrderedSame;
}

/// A stub has to be an executable image, or `Compress()` would happily prefix an archive with
/// arbitrary bytes and produce something that cannot run. The Windows stubs 7-Zip ships are PE
/// files (`MZ`); a native stub would be Mach-O or a universal binary.
static BOOL SZLooksLikeSFXStub(NSString *path)
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:path error:NULL];
  if (!attrs || ![attrs[NSFileType] isEqual:NSFileTypeRegular])
    return NO;
  if ([attrs[NSFileSize] unsignedLongLongValue] < 1024)
    return NO;
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!handle)
    return NO;
  NSData *head = [handle readDataOfLength:4];
  [handle closeFile];
  if (head.length < 4)
    return NO;
  const uint8_t *b = (const uint8_t *)head.bytes;
  if (b[0] == 'M' && b[1] == 'Z')                       // PE / MS-DOS image: the shipped stubs
    return YES;
  uint32_t magic = 0;
  memcpy(&magic, b, 4);
  switch (magic)
  {
    case 0xFEEDFACEu: case 0xCEFAEDFEu:                 // Mach-O 32, both byte orders
    case 0xFEEDFACFu: case 0xCFFAEDFEu:                 // Mach-O 64
    case 0xCAFEBABEu: case 0xBEBAFECAu:                 // universal binary
      return YES;
    default:
      return NO;
  }
}

+ (nullable NSString *)resolvedSFXModulePath:(nullable NSString *)nameOrPath
                                       error:(NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *candidate = nil;

  if (nameOrPath.length == 0)
  {
    // UpdateGUI.cpp:561-565: a bare -sfx (and the dialog checkbox) mean kDefaultSfxModule.
    candidate = [self defaultSFXModulePath];
    if (candidate.length == 0)
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound
                                message:@"SFX file is not specified"];
      return nil;
    }
  }
  else if ([nameOrPath rangeOfString:@"/"].location == NSNotFound)
  {
    // Update.cpp:1178-1184: no separator -> next to the program first. Here that is the bundle's
    // Resources/SFX, which is where `sfxModulePathNamed:` looks.
    candidate = [self sfxModulePathNamed:nameOrPath];
    if (candidate.length == 0)
      candidate = [[fm currentDirectoryPath] stringByAppendingPathComponent:nameOrPath];
  }
  else
  {
    candidate = nameOrPath.stringByExpandingTildeInPath;
  }

  if (![fm fileExistsAtPath:candidate])
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound
                              message:[NSString stringWithFormat:@"cannot find specified SFX module\n%@",
                                       nameOrPath.length ? nameOrPath : candidate]];
    return nil;
  }
  if (!SZLooksLikeSFXStub(candidate))
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument
                              message:[NSString stringWithFormat:@"cannot open SFX module\n%@",
                                       candidate]];
    return nil;
  }
  return candidate;
}

+ (nullable NSArray<NSString *> *)expandPathSpecs:(NSArray<SZPathSpec *> *)specs
                                sortedArchiveList:(BOOL)sortedArchiveList
                                            error:(NSError **)error
{
  BOOL thereIsInclude = NO;
  for (SZPathSpec *spec in specs)
    if (spec.include)
      thereIsInclude = YES;
  if (!thereIsInclude)
    return @[];

  NSMutableArray<NSString *> *out = [NSMutableArray array];
  NSError *failure = SZRunCatchingPathException(NULL, [&]() -> HRESULT {
    NWildcard::CCensor censor;
    for (SZPathSpec *spec in specs)
      SZAddSpecToCensor(censor, spec);
    // ArchiveCommandLine.cpp:1695-1701, then GUI.cpp:285-304 / Update.cpp:1159-1161.
    censor.AddPathsToCensor(NWildcard::k_RelatPath);
    censor.ExtendExclude();
    if (sortedArchiveList)
    {
      UStringVector sortedPaths, sortedFullPaths;
      CDirItemsStat stat;
      const HRESULT res = EnumerateDirItemsAndSort(censor, NWildcard::k_RelatPath, UString(),
                                                   sortedPaths, sortedFullPaths, stat, NULL);
      if (res != S_OK)
        return res;
      for (unsigned i = 0; i < sortedFullPaths.Size(); i++)
        [out addObject:SZStringFromUString(sortedFullPaths[i])];
      return S_OK;
    }
    // The item-censor walk: `EnumerateItems`, what UpdateArchive and HashCalc run. Files only,
    // like EnumDirItems.cpp:1488-1493.
    CDirItems dirItems;
    const HRESULT res = EnumerateItems(censor, NWildcard::k_RelatPath, UString(), dirItems);
    if (res != S_OK)
      return res;
    for (unsigned i = 0; i < dirItems.Items.Size(); i++)
      if (!dirItems.Items[i].IsDir())
        [out addObject:SZStringFromFString(dirItems.GetPhyPath(i))];
    return S_OK;
  });
  if (failure)
  {
    if (error)
      *error = failure;
    return nil;
  }
  return out;
}

+ (NSString *)archiveBaseNameForItemPaths:(NSArray<NSString *> *)itemPaths
                                   isHash:(BOOL)isHash
                                 baseName:(NSString **)baseNameOut
{
  UStringVector paths;
  for (NSString *p in itemPaths)
    paths.Add(SZUStringFromNSString(p));
  UString baseName;
  UString name;
  const HRESULT hr = SZRunCatching(NULL, [&]() -> HRESULT {
    name = CreateArchiveName(paths, isHash ? true : false, NULL, baseName);
    return S_OK;
  });
  NSString *result = (hr == S_OK) ? SZStringFromUString(name) : @"Archive";
  if (baseNameOut)
    *baseNameOut = (hr == S_OK) ? SZStringFromUString(baseName) : result;
  return result;
}

/// The one implementation behind `updateWithOptions:sourcePaths:`,
/// `updateWithOptions:pathSpecs:` and `renameItemsWithPairs:...`. `renamePairs` non-empty puts
/// `UpdateArchive` into rename mode (Update.cpp:1140-1145, :477-520).
+ (nullable SZUpdateResult *)runUpdateWithOptions:(SZUpdateOptions *)options
                                        pathSpecs:(NSArray<SZPathSpec *> *)pathSpecs
                                      renamePairs:(NSArray<SZRenamePair *> *)renamePairs
                                         progress:(nullable id<SZProgressDelegate>)progress
                                            error:(NSError **)error
{
  if (![SZCodecs loadCodecs:error])
    return nil;
  if (options.archivePath.length == 0)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"No archive path given"];
    return nil;
  }
  // Update.cpp:1164 rejects volumes + email; 01 8.5 step 4.
  if (options.emailMode && options.volumeSizes.count > 0)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotImplemented
                              message:@"Splitting to volumes is not supported in email mode"];
    return nil;
  }

  CCodecs *codecs = g_CodecsObj;
  const int formatIndex = SZResolveFormatIndex(codecs, options);
  if (formatIndex < 0 || !codecs->Formats[(unsigned)formatIndex].UpdateEnabled)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnsupported
                              message:@"Update operations are not supported for this archive."];
    return nil;
  }
  const CArcInfoEx &arcInfo = codecs->Formats[(unsigned)formatIndex];

  NSString *sfxModule = nil;
  if (options.sfxMode)
  {
    // Update.cpp:1167-1191, but up front: a missing or non-executable module is an error before
    // any byte is written, never a quietly plain archive.
    if (![SZUpdater formatSupportsSFX:SZStringFromUString(arcInfo.Name)])
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeNotImplemented
                                message:[NSString stringWithFormat:
                                         @"Self-extracting archives are not supported for this format\n%@",
                                         SZStringFromUString(arcInfo.Name)]];
      return nil;
    }
    sfxModule = [SZUpdater resolvedSFXModulePath:options.sfxModulePath error:error];
    if (sfxModule.length == 0)
      return nil;
  }

  SZUpdateResult *result = [[SZUpdateResult alloc] init];
  NSString *finalPath = options.archivePath;
  NSString *engineMessage = nil;

  NSError *failure = SZRunCatchingPathException(&engineMessage, [&]() -> HRESULT {
    CUpdateOptions uo;

    // ---- the action set (the "Update mode:" combo) ----
    uo.Commands.Clear();
    {
      CUpdateArchiveCommand command;
      command.ActionSet = *SZActionSetForUpdateMode(options.updateMode);
      uo.Commands.Add(command);
    }

    // ---- format + -m properties (already in the documented emission order) ----
    uo.MethodMode.Type = COpenType();
    uo.MethodMode.Type.FormatIndex = formatIndex;
    uo.MethodMode.Type_Defined = true;
    for (SZUpdateProperty *p in options.properties)
    {
      CProperty property;
      property.Name = SZUStringFromNSString(p.name);
      property.Value = SZUStringFromNSString(p.value);
      uo.MethodMode.Properties.Add(property);
    }

    // ---- archive path (UpdateGUI.cpp:519-525) ----
    uo.ArcNameMode = SZEngineArcNameMode(options.nameMode);
    uo.ArchivePath.VolExtension = arcInfo.GetMainExt();
    // kSFXExtension is "" in Update.cpp on non-Windows; the port keeps the Windows stubs and
    // therefore the Windows ".exe" name (00-orchestration "Windows-only").
    uo.ArchivePath.BaseExtension = options.sfxMode ? UString("exe") : uo.ArchivePath.VolExtension;
    uo.ArchivePath.ParseFromPath(SZUStringFromNSString(options.archivePath), uo.ArcNameMode);

    uo.PathMode = SZCensorPathMode(options.pathMode);
    uo.SfxMode = options.sfxMode ? true : false;
    if (options.sfxMode)
      uo.SfxModule = SZFStringFromNSString(sfxModule);

    for (NSNumber *size in options.volumeSizes)
      uo.VolumesSizes.Add(size.unsignedLongLongValue);

    uo.DeleteAfterCompressing = options.deleteAfterCompressing ? true : false;
    uo.SetArcMTime = options.setArchiveMTime ? true : false;
    uo.OpenShareForWrite = options.openShareForWrite ? true : false;
    uo.StopAfterOpenError = options.stopAfterOpenError ? true : false;
    if (options.preserveATime)
      uo.PreserveATime = options.preserveATime.boolValue ? true : false;
    SZSetBoolPair(uo.SymLinks, options.storeSymLinks);
    SZSetBoolPair(uo.HardLinks, options.storeHardLinks);
    SZSetBoolPair(uo.AltStreams, options.storeAltStreams);
    SZSetBoolPair(uo.NtSecurity, options.storeNtSecurity);

    uo.EMailMode = options.emailMode ? true : false;
    uo.EMailRemoveAfter = options.emailRemoveAfter ? true : false;
    uo.EMailAddress = SZUStringFromNSString(options.emailAddress);

    // ---- working directory: the Options > Folders policy (01b 4.8), UpdateGUI.cpp:527-539 ----
    if (options.workingDirectory)
      uo.WorkingDir = SZFStringFromNSString(options.workingDirectory);
    else
    {
      NWorkDir::CInfo workDirInfo;
      workDirInfo.Load();
      if (workDirInfo.Mode != NWorkDir::NMode::kCurrent)
      {
        FString fullPath;
        NFile::NDir::MyGetFullPathName(SZFStringFromNSString(options.archivePath), fullPath);
        FString namePart;
        uo.WorkingDir = GetWorkDir(workDirInfo, fullPath, namePart);
        NFile::NDir::CreateComplexDir(uo.WorkingDir);
      }
    }

    // ---- rename pairs (Update.cpp:477-520): rename mode rewrites archive item names ----
    uo.RenameMode = renamePairs.count != 0;
    for (SZRenamePair *pair in renamePairs)
    {
      CRenamePair rp;
      rp.OldName = SZUStringFromNSString(pair.oldName);
      rp.NewName = SZUStringFromNSString(pair.newName);
      rp.WildcardParsing = pair.wildcardParsing ? true : false;
      rp.RecursedType = NRecursedType::kNonRecursed;
      uo.RenamePairs.Add(rp);
    }

    // ---- the item list: one censor pre-item per spec, wildcards and all. `UpdateArchive` then
    // calls AddPathsToCensor + ExtendExclude itself (Update.cpp:1159-1161) and the engine's
    // EnumerateItems walk is what expands a wildcard (03 section 2.2, `-i`/`-x`). ----
    NWildcard::CCensor censor;
    BOOL thereIsInclude = NO;
    for (SZPathSpec *spec in pathSpecs)
    {
      SZAddSpecToCensor(censor, spec);
      if (spec.include)
        thereIsInclude = YES;
    }
    if (!thereIsInclude)
      censor.AddPreItem_Wildcard();

    // ---- the callback ----
    CSZUpdateUICallback callback;
    callback.Delegate = progress;
    callback.ArchivePath = options.archivePath;
    callback.AskPasswordForEncryption = options.asksPassword ? true : false;
    if (options.password.length != 0)
    {
      callback.Password = SZUStringFromNSString(options.password);
      callback.PasswordIsDefined = true;
    }

    CObjectVector<COpenType> types;
    types.Add(uo.MethodMode.Type);

    CUpdateErrorInfo errorInfo;
    const HRESULT res = UpdateArchive(codecs, types,
                                      SZUStringFromNSString(options.archivePath),
                                      censor, uo, errorInfo, &callback, &callback,
                                      false);  // needSetPath: the path is already prepared

    result.filesProcessed = callback.NumFiles;
    result.errorCount = callback.NumErrors;
    result.failedPaths = callback.FailedFiles;
    result.deletedPaths = callback.DeletedFiles;
    result.passwordWasAsked = callback.PasswordWasAsked ? YES : NO;
    result.password = callback.PasswordIsDefined ? SZStringFromUString(callback.Password) : nil;
    result.scannedFileCount = callback.ScannedFiles;
    result.scannedTotalSize = callback.ScannedBytes;
    result.archiveSize = callback.FinishStat.OutArcFileSize;
    result.volumeCount = callback.FinishStat.NumVolumes;
    result.isMultiVolume = callback.FinishStat.IsMultiVolMode ? YES : NO;
    finalPath = SZStringFromUString(uo.VolumesSizes.IsEmpty() ? uo.ArchivePath.GetFinalPath()
                                                             : uo.ArchivePath.GetFinalVolPath());

    if (res != S_OK)
      return res;
    if (errorInfo.ThereIsError())
    {
      for (unsigned i = 0; i < errorInfo.FileNames.Size(); i++)
        [callback.FailedFiles addObject:SZStringFromFString(errorInfo.FileNames[i])];
      result.failedPaths = callback.FailedFiles;
      if (!errorInfo.Message.IsEmpty())
        engineMessage = [NSString stringWithUTF8String:errorInfo.Message.Ptr()];
      return errorInfo.Get_HRESULT_Error();
    }
    return S_OK;
  });

  if (failure)
  {
    if (error)
      *error = failure;
    return nil;
  }
  result.archivePath = finalPath;
  return result;
}

+ (nullable SZUpdateResult *)updateWithOptions:(SZUpdateOptions *)options
                                   sourcePaths:(NSArray<NSString *> *)sourcePaths
                                      progress:(nullable id<SZProgressDelegate>)progress
                                         error:(NSError **)error
{
  NSMutableArray<SZPathSpec *> *specs = [NSMutableArray arrayWithCapacity:sourcePaths.count];
  for (NSString *path in sourcePaths)
    [specs addObject:[SZPathSpec literalSpecWithPath:path]];
  return [self runUpdateWithOptions:options pathSpecs:specs renamePairs:@[]
                           progress:progress error:error];
}

+ (nullable SZUpdateResult *)updateWithOptions:(SZUpdateOptions *)options
                                     pathSpecs:(NSArray<SZPathSpec *> *)pathSpecs
                                      progress:(nullable id<SZProgressDelegate>)progress
                                         error:(NSError **)error
{
  return [self runUpdateWithOptions:options pathSpecs:pathSpecs renamePairs:@[]
                           progress:progress error:error];
}

+ (nullable SZUpdateResult *)renameItemsWithPairs:(NSArray<SZRenamePair *> *)pairs
                                  inArchiveAtPath:(NSString *)archivePath
                                        itemSpecs:(NSArray<SZPathSpec *> *)itemSpecs
                                          options:(nullable SZUpdateOptions *)options
                                         progress:(nullable id<SZProgressDelegate>)progress
                                            error:(NSError **)error
{
  if (pairs.count == 0)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument
                              message:@"There is no second file name for rename pair:"];
    return nil;
  }
  for (SZRenamePair *pair in pairs)
    if (!pair.isSupported)
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument
                                message:[NSString stringWithFormat:@"Unsupported rename command:\n%@",
                                         pair.unsupportedDetail ?: @""]];
      return nil;
    }

  SZUpdateOptions *o = [(options ?: [SZUpdateOptions optionsWithArchivePath:archivePath]) copy];
  o.archivePath = archivePath;
  o.formatIndex = -1;
  o.formatName = nil;                    // taken from the existing archive's name
  o.nameMode = SZArchiveNameModeExact;   // never rewrite the extension of an existing archive
  // ParseArchiveCommand: `rn` falls into SetAddCommandOptions' default branch, which is
  // k_ActionSet_Update (ArchiveCommandLine.cpp:956-966).
  o.updateMode = SZUpdateModeUpdate;
  o.deleteAfterCompressing = NO;
  o.sfxMode = NO;
  o.volumeSizes = @[];
  return [self runUpdateWithOptions:o pathSpecs:itemSpecs renamePairs:pairs
                           progress:progress error:error];
}

+ (nullable SZUpdateResult *)addPaths:(NSArray<NSString *> *)sourcePaths
                      toArchiveAtPath:(NSString *)archivePath
                              options:(nullable SZUpdateOptions *)options
                             progress:(nullable id<SZProgressDelegate>)progress
                                error:(NSError **)error
{
  SZUpdateOptions *o = [(options ?: [SZUpdateOptions optionsWithArchivePath:archivePath]) copy];
  o.archivePath = archivePath;
  o.formatIndex = -1;
  o.formatName = nil;                    // taken from the existing archive's name
  o.nameMode = SZArchiveNameModeExact;   // never rewrite the extension of an existing archive
  o.updateMode = SZUpdateModeAdd;
  o.volumeSizes = @[];                   // "Splitting to volumes is not supported" when updating
  return [self updateWithOptions:o sourcePaths:sourcePaths progress:progress error:error];
}

+ (nullable SZUpdateResult *)deleteItemsWithSpecs:(NSArray<SZPathSpec *> *)itemSpecs
                                fromArchiveAtPath:(NSString *)archivePath
                                          options:(nullable SZUpdateOptions *)options
                                         progress:(nullable id<SZProgressDelegate>)progress
                                            error:(NSError **)error
{
  // Without this the update core would add AddPreItem_Wildcard(), i.e. delete every item.
  BOOL thereIsInclude = NO;
  for (SZPathSpec *spec in itemSpecs)
    if (spec.include)
      thereIsInclude = YES;
  if (!thereIsInclude)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument
                              message:@"You must select one or more files"];
    return nil;
  }

  SZUpdateOptions *o = [(options ?: [SZUpdateOptions optionsWithArchivePath:archivePath]) copy];
  o.archivePath = archivePath;
  o.formatIndex = -1;
  o.formatName = nil;
  o.nameMode = SZArchiveNameModeExact;
  o.updateMode = SZUpdateModeDelete;
  o.deleteAfterCompressing = NO;
  o.sfxMode = NO;
  o.volumeSizes = @[];
  return [self runUpdateWithOptions:o pathSpecs:itemSpecs renamePairs:@[]
                           progress:progress error:error];
}

+ (nullable SZUpdateResult *)deleteItemsNamed:(NSArray<NSString *> *)itemNames
                            fromArchiveAtPath:(NSString *)archivePath
                                      options:(nullable SZUpdateOptions *)options
                                     progress:(nullable id<SZProgressDelegate>)progress
                                        error:(NSError **)error
{
  SZUpdateOptions *o = [(options ?: [SZUpdateOptions optionsWithArchivePath:archivePath]) copy];
  o.archivePath = archivePath;
  o.formatIndex = -1;
  o.formatName = nil;
  o.nameMode = SZArchiveNameModeExact;
  o.updateMode = SZUpdateModeDelete;
  o.deleteAfterCompressing = NO;
  o.volumeSizes = @[];
  return [self updateWithOptions:o sourcePaths:itemNames progress:progress error:error];
}

@end

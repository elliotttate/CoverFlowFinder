// SZArchiveOpener.mm -- see SZArchiveOpener.h. Mirrors the smoke test in
// 02-engine-api.md Appendix A: CAgent::Open with an IArchiveOpenCallback that also
// implements ICryptoGetTextPassword, then BindToRootFolder.

#import "SZArchiveOpener.h"
#import "SZFileSystemFolder.h"
#import "SZCodecs.h"
#import "SZError.h"
#import "SZExtractor.h"         // SZTempOpen.updateItemAtIndex (CopyFromFile)
#import "SZSettings.h"          // SZSettings.temporaryDirectory (SZ_STATE_DIR)
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

#include <sys/stat.h>

// ---------------------------------------------------------------------------
// The open callback handed to CAgent::Open is the engine's own COpenCallbackImp, exactly as 7zFM
// builds it (FileFolderPluginOpen.cpp:317-330, 02-engine-api.md 2.5.1). It implements
// IArchiveOpenVolumeCallback, which is what the Split / RAR / zip handlers query to find the
// `.002`, `.003`, `.r00`, `.z01` ... siblings of a multi-volume set
// (COpenCallbackImp::GetStream, ArchiveOpenCallback.cpp:284-367) — so opening the first volume
// lists the whole archive. Without it the Split handler sees one truncated volume and CAgent::Open
// answers S_FALSE, i.e. SZErrorCodeNotArchive.
//
// COpenCallbackImp is `final` and does the volume bookkeeping itself; the app-side half it
// delegates to is the non-COM IOpenCallbackUI below, which answers the password. Upstream keeps
// that as a *raw* pointer (`Callback`) and uses it only during the open stage, so SZArchive owns
// the object and clears the pointer before releasing it.
class CSZOpenCallbackUI Z7_final: public IOpenCallbackUI
{
public:
  id<SZPasswordDelegate> Delegate;
  /// COpenArchiveCallback's ProgressDialog half (OpenCallback.cpp:20-60): only set while the
  /// open runs, cleared afterwards so a later ReOpen does not report to a finished operation.
  id<SZProgressDelegate> Progress;
  NSString *Path;
  UString Password;
  bool PasswordIsDefined;
  bool PasswordWasAsked;
  bool Cancelled;

  CSZOpenCallbackUI(): Delegate(nil), Progress(nil), Path(nil), PasswordIsDefined(false),
      PasswordWasAsked(false), Cancelled(false) {}

  /// ProgressDialog.Sync.CheckStop(): the Cancel button of the "Opening" progress.
  HRESULT CheckStop()
  {
    if (Progress && [Progress progressCheckBreak])
    {
      Cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }

  Z7_IFACE_IMP(IOpenCallbackUI)
};

HRESULT CSZOpenCallbackUI::Open_CheckBreak() { return CheckStop(); }

// COpenArchiveCallback::Open_SetTotal: Set_NumFilesTotal + Set_NumBytesTotal, after CheckStop.
HRESULT CSZOpenCallbackUI::Open_SetTotal(const UInt64 *files, const UInt64 *bytes)
{
  RINOK(CheckStop())
  if (Progress)
  {
    if (files && [Progress respondsToSelector:@selector(progressSetTotalFiles:)])
      [Progress progressSetTotalFiles:*files];
    if (bytes)
      [Progress progressSetTotal:*bytes];
  }
  return S_OK;
}

// COpenArchiveCallback::Open_SetCompleted: Set_NumFilesCur + Set_NumBytesCur, then CheckStop.
HRESULT CSZOpenCallbackUI::Open_SetCompleted(const UInt64 *files, const UInt64 *bytes)
{
  if (Progress)
  {
    if (files)
      [Progress progressSetNumFilesProcessed:*files];
    if (bytes)
      [Progress progressSetCompleted:*bytes];
  }
  return CheckStop();
}

HRESULT CSZOpenCallbackUI::Open_Finished() { return CheckStop(); }

HRESULT CSZOpenCallbackUI::Open_CryptoGetTextPassword(BSTR *password)
{
  *password = NULL;
  PasswordWasAsked = true;
  if (!PasswordIsDefined)
  {
    if (!Delegate)
      return E_ABORT;
    NSString *p = [Delegate passwordForArchiveAtPath:Path];
    if (!p)
    {
      Cancelled = true;
      return E_ABORT;
    }
    Password = SZUStringFromNSString(p);
    PasswordIsDefined = true;
  }
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
// Minimal IFolderArchiveExtractCallback for extracting one nested archive to a temp
// folder: overwrite silently, remember the first failure, answer passwords via the delegate.
class CExtractToTempCallback Z7_final:
  public IFolderArchiveExtractCallback,
  public ICryptoGetTextPassword,
  public CMyUnknownImp
{
  Z7_COM_UNKNOWN_IMP_2(IFolderArchiveExtractCallback, ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
public:
  id<SZPasswordDelegate> Delegate;
  /// The open's progress: the copy of a nested archive is part of opening it (7zFM runs it
  /// under its own progress dialog, PanelItemOpen.cpp:1650-1666).
  id<SZProgressDelegate> Progress;
  NSString *Path;
  UString Password;
  bool PasswordIsDefined;
  bool PasswordWasAsked;
  bool Cancelled;
  Int32 FirstBadOpRes;
  NSString *ErrorMessage;

  CExtractToTempCallback(): Delegate(nil), Progress(nil), Path(nil), PasswordIsDefined(false), PasswordWasAsked(false),
      Cancelled(false), FirstBadOpRes(NArchive::NExtract::NOperationResult::kOK), ErrorMessage(nil) {}

  HRESULT CheckStop()
  {
    if (Progress && [Progress progressCheckBreak])
    {
      Cancelled = true;
      return E_ABORT;
    }
    return S_OK;
  }
};

Z7_COM7F_IMF(CExtractToTempCallback::SetTotal(UInt64 total))
{
  if (Progress)
    [Progress progressSetTotal:total];
  return CheckStop();
}

Z7_COM7F_IMF(CExtractToTempCallback::SetCompleted(const UInt64 *completeValue))
{
  if (Progress && completeValue)
    [Progress progressSetCompleted:*completeValue];
  return CheckStop();
}

Z7_COM7F_IMF(CExtractToTempCallback::AskOverwrite(
    const wchar_t * /* existName */, const FILETIME * /* existTime */, const UInt64 * /* existSize */,
    const wchar_t * /* newName */, const FILETIME * /* newTime */, const UInt64 * /* newSize */,
    Int32 *answer))
{
  *answer = NOverwriteAnswer::kYesToAll;
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::PrepareOperation(const wchar_t * /* name */, Int32 /* isFolder */, Int32 /* askExtractMode */, const UInt64 * /* position */))
{
  return CheckStop();
}

Z7_COM7F_IMF(CExtractToTempCallback::MessageError(const wchar_t *message))
{
  if (!ErrorMessage)
    ErrorMessage = SZStringFromUString(UString(message));
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::SetOperationResult(Int32 opRes, Int32 encrypted))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK && FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
  {
    FirstBadOpRes = opRes;
    if (!ErrorMessage)
    {
      UString s;
      SetExtractErrorMessage(opRes, encrypted, Path ? SZUStringFromNSString(Path).Ptr() : L"", s);
      ErrorMessage = SZStringFromUString(s);
    }
  }
  return S_OK;
}

Z7_COM7F_IMF(CExtractToTempCallback::CryptoGetTextPassword(BSTR *password))
{
  *password = NULL;
  PasswordWasAsked = true;
  if (!PasswordIsDefined)
  {
    if (!Delegate)
      return E_ABORT;
    NSString *p = [Delegate passwordForArchiveAtPath:Path];
    if (!p)
    {
      Cancelled = true;
      return E_ABORT;
    }
    Password = SZUStringFromNSString(p);
    PasswordIsDefined = true;
  }
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
// The per-level open error text: GetFolderLevels + GetFolderError (FileFolderPluginOpen.cpp:
// 96-217), read through the agent's IFolderArcProps exactly as 7zFM reads it through the
// folder's IGetFolderArcProps. Level `numLevels` is the level that could not be opened
// (CAgent::GetArcProp answers NonOpen_ArcPath / NonOpen_ErrorInfo for it).

NSErrorUserInfoKey const SZArchiveOpenEncryptedKey = @"SZArchiveOpenEncrypted";
NSErrorUserInfoKey const SZArchiveOpenErrorMessageKey = @"SZArchiveOpenErrorMessage";
NSErrorUserInfoKey const SZArchiveOpenPathKey = @"SZArchiveOpenPath";

static const UInt32 kLangID_CantOpenArchive_Open = 3005;     // IDS_CANT_OPEN_ARCHIVE
static const UInt32 kLangID_CantOpenEncrypted_Open = 3006;   // IDS_CANT_OPEN_ENCRYPTED_ARCHIVE
static const UInt32 kLangID_CantOpenAsType_Open = 3017;      // IDS_CANT_OPEN_AS_TYPE
static const UInt32 kLangID_IsOpenAsType_Open = 3018;        // IDS_IS_OPEN_AS_TYPE
static const UInt32 kLangID_WrongPswGuess_Open = 3710;       // IDS_EXTRACT_MSG_WRONG_PSW_GUESS

/// k_ErrorFlagsIds (FileManager/ExtractCallback.cpp:452-465), by kpv_ErrorFlags_* bit position.
static const UInt32 k_OpenErrorFlagsLangIDs[] = {
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

static UString SZFormatLangOpen(UInt32 langID, const UString &argument)
{
  UString s = NWindows::MyLoadString(langID);
  s.Replace(UString("{0}"), argument);
  return s;
}

/// GetOpenArcErrorMessage (FileManager/ExtractCallback.cpp:474-509).
UString SZOpenArcErrorFlagsMessage(UInt32 errorFlags);   // also used by SZFolder.mm (Properties)
UString SZOpenArcErrorFlagsMessage(UInt32 errorFlags)
{
  UString s;
  for (unsigned i = 0; i < Z7_ARRAY_SIZE(k_OpenErrorFlagsLangIDs); i++)
  {
    const UInt32 f = (UInt32)1 << i;
    if ((errorFlags & f) == 0)
      continue;
    UString m = NWindows::MyLoadString(k_OpenErrorFlagsLangIDs[i]);
    if (m.IsEmpty())
      continue;
    if (f == kpv_ErrorFlags_EncryptedHeadersError)
    {
      m += " : ";
      m += NWindows::MyLoadString(kLangID_WrongPswGuess_Open);
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

static UString SZBracedTypeOpen(const UString &type)
{
  UString s ('[');
  s += type;
  s.Add_Char(']');
  return s;
}

/// GetFolderError: `nonOpenErrors` is the text of the level that failed to open (what 7zFM
/// shows), `openErrors` that of the levels that opened (computed by 7zFM and not shown).
static void SZGetFolderError(IFolderArcProps *arcProps, UString &openErrors, UString &nonOpenErrors)
{
  openErrors.Empty();
  nonOpenErrors.Empty();
  if (!arcProps)
    return;
  UInt32 numLevels = 0;
  if (arcProps->GetArcNumLevels(&numLevels) != S_OK)
    numLevels = 0;
  // GetFolderLevels: levels 0 .. numLevels, the last one being the non-open level.
  for (Int32 level = (Int32)numLevels; level >= 0; level--)
  {
    const bool isNonOpenLevel = (level == (Int32)numLevels);
    UString error, path, type, errorType, errorFlags;
    const PROPID propIDs[] = { kpidError, kpidPath, kpidType, kpidErrorType };
    UString *targets[] = { &error, &path, &type, &errorType };
    for (unsigned i = 0; i < 4; i++)
    {
      NWindows::NCOM::CPropVariant prop;
      if (arcProps->GetArcProp((UInt32)level, propIDs[i], &prop) != S_OK)
        continue;
      if (prop.vt != VT_EMPTY)
        *targets[i] = (prop.vt == VT_BSTR) ? UString(prop.bstrVal) : UString("?");
    }
    {
      NWindows::NCOM::CPropVariant prop;
      if (arcProps->GetArcProp((UInt32)level, kpidErrorFlags, &prop) == S_OK)
      {
        const UInt32 flags = GetOpenArcErrorFlags(prop);
        if (flags != 0)
          errorFlags = SZOpenArcErrorFlagsMessage(flags);
      }
    }

    UString m;
    if (!errorType.IsEmpty())
    {
      m = SZFormatLangOpen(kLangID_CantOpenAsType_Open, SZBracedTypeOpen(errorType));
      if (!isNonOpenLevel)
      {
        m.Add_LF();
        m += SZFormatLangOpen(kLangID_IsOpenAsType_Open, SZBracedTypeOpen(type));
      }
    }
    if (!error.IsEmpty())
    {
      if (!m.IsEmpty())
        m.Add_LF();
      m += SZBracedTypeOpen(type);
      m += " : ";
      m += GetNameOfProperty(kpidError, L"Error");
      m += " : ";
      m += error;
    }
    if (!errorFlags.IsEmpty())
    {
      if (!m.IsEmpty())
        m.Add_LF();
      m += GetNameOfProperty(kpidErrorFlags, L"Errors");
      m += ": ";
      m += errorFlags;
    }
    if (m.IsEmpty())
      continue;
    UString &target = isNonOpenLevel ? nonOpenErrors : openErrors;
    if (!isNonOpenLevel && !target.IsEmpty())
      target += "--------------------\n";
    target += path;
    target.Add_LF();
    target += m;
  }
}

/// The non-open level's text for an agent, or nil.
static NSString *SZNonOpenErrors(IInFolderArchive *agent)
{
  CMyComPtr<IFolderArcProps> props;
  if (agent)
    agent->QueryInterface(IID_IFolderArcProps, (void **)&props);
  UString openErrors, nonOpenErrors;
  SZGetFolderError(props, openErrors, nonOpenErrors);
  return nonOpenErrors.IsEmpty() ? nil : SZStringFromUString(nonOpenErrors);
}

/// The open-callback pair is private to this file, so it is declared here rather than in the
/// shared Internal/SZFolder+Internal.h (which the other bridge files include).
@interface SZArchive ()
- (void)adoptOpenCallbackImp:(COpenCallbackImp *)spec ui:(CSZOpenCallbackUI *)ui;
- (void)recordTempFile:(NSString *)path;
@property (nonatomic, readwrite, copy, nullable) NSString *openErrorMessage;
@end

/// Size and modification time of a file (CTempFileInfo::FileInfo); NO when it cannot be read.
static BOOL SZStatFile(NSString *path, uint64_t *size, struct timespec *mtime)
{
  struct stat st;
  if (!path || stat(path.fileSystemRepresentation, &st) != 0)
    return NO;
  *size = (uint64_t)st.st_size;
  *mtime = st.st_mtimespec;
  return YES;
}

@implementation SZArchive
{
  CMyComPtr<IInFolderArchive> _agent;
  CAgent *_agentSpec;
  CMyComPtr<IArchiveOpenCallback> _openCallback;
  /// The same object as _openCallback; kept typed so `Callback` can be cleared before the
  /// IOpenCallbackUI it points at is destroyed (the pointer is not reference counted).
  COpenCallbackImp *_openCallbackSpec;
  /// Owned by this archive: the app-side half of the open callback. For a multi-volume set
  /// COpenCallbackImp outlives the open stage, so this must outlive it too.
  CSZOpenCallbackUI *_openCallbackUI;
  CMyComPtr<IInStream> _inStream;
  BOOL _closed;
  NSString *_tempFilePath;
  uint64_t _tempFileSize;
  struct timespec _tempFileMTime;
  BOOL _keepTempDirectory;
}

- (instancetype)initWithAgent:(IInFolderArchive *)agent
                    agentSpec:(CAgent *)agentSpec
                 openCallback:(IArchiveOpenCallback *)openCallback
                     inStream:(IInStream *)inStream
                         path:(NSString *)path
                         type:(NSString *)type
                  outerFolder:(SZFolder *)outerFolder
               outerItemIndex:(NSInteger)outerItemIndex
                tempDirectory:(NSString *)tempDirectory
{
  self = [super init];
  if (!self)
    return nil;
  _agent = agent;
  _agentSpec = agentSpec;
  _openCallback = openCallback;
  _inStream = inStream;
  _path = [path copy];
  _type = [type copy];
  _outerFolder = outerFolder;
  _outerItemIndex = outerItemIndex;
  _tempDirectory = [tempDirectory copy];
  return self;
}

- (void)adoptOpenCallbackImp:(COpenCallbackImp *)spec ui:(CSZOpenCallbackUI *)ui
{
  _openCallbackSpec = spec;
  _openCallbackUI = ui;
}

- (void)recordTempFile:(NSString *)path
{
  _tempFilePath = [path copy];
  [self refreshTempFileAttributes];
}

- (NSString *)tempFilePath
{
  return _tempFilePath;
}

- (void)refreshTempFileAttributes
{
  if (!SZStatFile(_tempFilePath, &_tempFileSize, &_tempFileMTime))
  {
    _tempFileSize = 0;
    _tempFileMTime.tv_sec = 0;
    _tempFileMTime.tv_nsec = 0;
  }
}

- (BOOL)tempFileWasChanged
{
  uint64_t size = 0;
  struct timespec mtime;
  if (!SZStatFile(_tempFilePath, &size, &mtime))
    return NO;                // NFind::CFileInfo::Find failed: nothing to write back
  return size != _tempFileSize || mtime.tv_sec != _tempFileMTime.tv_sec || mtime.tv_nsec != _tempFileMTime.tv_nsec;
}

- (void)keepTempDirectory
{
  _keepTempDirectory = YES;
}

- (BOOL)keepsTempDirectory
{
  return _keepTempDirectory;
}

- (BOOL)writeBackIntoOuterFolderWithProgress:(id<SZProgressDelegate>)progress error:(NSError **)error
{
  SZFolder *outer = _outerFolder;
  if (!_tempFilePath || !outer || !outer.isArchive)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnsupported message:@"This archive was not opened from a copy inside another archive"];
    return NO;
  }
  NSString *name = _path.lastPathComponent;
  if (outer.isReadOnly)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotImplemented
                              message:[NSString stringWithFormat:@"The archive that holds %@ cannot be updated", name]];
    return NO;
  }
  // CFolderLink::FileIndex; looked up again by name if the parent listing moved meanwhile.
  NSInteger index = _outerItemIndex;
  if (index < 0 || index >= outer.itemCount || ![[outer nameOfItemAtIndex:index] isEqualToString:name])
  {
    index = NSNotFound;
    for (NSInteger i = 0; i < outer.itemCount; i++)
      if ([[outer nameOfItemAtIndex:i] isEqualToString:name] && ![outer isDirectoryAtIndex:i]) { index = i; break; }
    if (index == NSNotFound)
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"%@ is no longer in its archive", name]];
      return NO;
    }
  }
  if (![SZTempOpen updateItemAtIndex:index ofFolder:outer fromFilePath:_tempFilePath progress:progress error:error])
    return NO;
  [self refreshTempFileAttributes];
  _outerItemIndex = index;
  NSError *reloadError = nil;
  if (![outer loadItems:&reloadError])
    NSLog(@"7-Zip: reloading %@ after the write-back failed: %@", outer.fullPath, reloadError);
  // the reload may reorder the parent: point at the item again
  for (NSInteger i = 0; i < outer.itemCount; i++)
    if ([[outer nameOfItemAtIndex:i] isEqualToString:name]) { _outerItemIndex = i; break; }
  return YES;
}

- (void)removeTempDirectory
{
  if (_keepTempDirectory)
    return;
  if (_tempDirectory)
  {
    [[NSFileManager defaultManager] removeItemAtPath:_tempDirectory error:NULL];
    _tempDirectory = nil;
  }
}

- (void)dealloc
{
  if (_agent && !_closed)
    _agent->Close();                    // releases the volume streams that hold _openCallback
  [self releaseOpenCallbackUI];
  [self removeTempDirectory];
}

/// The IOpenCallbackUI is reachable from COpenCallbackImp through a raw pointer, so the pointer
/// goes first. Called only when the archive is gone for good, never from -close, because
/// -reopen still needs the password answer.
- (void)releaseOpenCallbackUI
{
  if (_openCallbackSpec)
    _openCallbackSpec->Callback = NULL;
  delete _openCallbackUI;
  _openCallbackUI = NULL;
}

- (NSString *)errorMessage
{
  const UString s = _agentSpec->GetErrorMessage();
  return s.IsEmpty() ? nil : SZStringFromUString(s);
}

- (BOOL)isReadOnly
{
  return _agentSpec->IsThere_ReadOnlyArc() || _agentSpec->Is_Attrib_ReadOnly();
}

- (SZArcProps *)arcProps
{
  CMyComPtr<IFolderArcProps> props;
  _agent.QueryInterface(IID_IFolderArcProps, &props);
  if (!props)
    return nil;
  return [[SZArcProps alloc] initWithRawProps:props];
}

// CoverFlowFinder addition, 2026-10-11: used only by the bounded byte-stream adapter.
- (IInArchive *)rawArchive { return _closed || !_agentSpec ? NULL : _agentSpec->GetArchive(); }

- (SZFolder *)rootFolder:(NSError **)error
{
  IInFolderArchive *agent = _agent;
  CMyComPtr<IFolderFolder> raw;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return agent->BindToRootFolder(&raw); });
  if (SZFail(hr, error, msg))
    return nil;
  if (!raw)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnknown message:@"BindToRootFolder returned no folder"];
    return nil;
  }
  SZFolder *folder = [SZFolder folderWithRawFolder:raw archive:self];
  if (![folder loadItems:error])
    return nil;
  return folder;
}

- (BOOL)reopen:(NSError **)error
{
  IInFolderArchive *agent = _agent;
  IArchiveOpenCallback *cb = _openCallback;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return agent->ReOpen(cb); });
  if (hr != S_OK && msg == nil)
    msg = self.errorMessage;
  return !SZFail(hr, error, msg);
}

- (void)close
{
  if (_agent && !_closed)
  {
    _agent->Close();
    _closed = YES;
  }
  [self removeTempDirectory];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZArchive %@ type=%@>", _path, _type];
}

@end

// ---------------------------------------------------------------------------
@implementation SZArchiveOpener

/// Extracts one item of an archive folder into a fresh "7zO" temp directory (kNoPaths, so the
/// file lands directly in it). Returns the file path; tempDirectory receives the directory.
+ (NSString *)extractItem:(NSInteger)index
                       of:(SZFolder *)folder
                    named:(NSString *)name
         passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                 progress:(id<SZProgressDelegate>)progress
            tempDirectory:(NSString **)tempDirectory
                    error:(NSError **)error
{
  CMyComPtr<IArchiveFolder> archiveFolder;
  folder.rawFolder->QueryInterface(IID_IArchiveFolder, (void **)&archiveFolder);
  if (!archiveFolder)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeUnsupported message:@"The folder cannot extract items"];
    return nil;
  }
  // 7zO<8 hex> (kTempDirPrefix, PanelItemOpen.cpp:1490), like every other temp folder.
  NSString *tempDir = [SZTempOpen createTemporaryDirectoryWithPrefix:[SZTempOpen openDirectoryPrefix] error:error];
  if (!tempDir)
    return nil;

  CExtractToTempCallback *cbSpec = new CExtractToTempCallback;
  CMyComPtr<IFolderArchiveExtractCallback> callback = cbSpec;
  cbSpec->Delegate = passwordDelegate;
  cbSpec->Progress = progress;
  cbSpec->Path = [folder.fullPath stringByAppendingString:name];
  // OpenItemInArchive (PanelItemOpen.cpp:1566-1571, 1653-1658): the copy uses the password of
  // the level it comes from, and a password asked for during the copy is remembered there.
  SZArchive *level = folder.archive;
  NSString *levelPassword = level.password;
  if (levelPassword)
  {
    cbSpec->Password = SZUStringFromNSString(levelPassword);
    cbSpec->PasswordIsDefined = true;
  }

  const UString uTemp = MultiByteToUnicodeString(SZFStringFromNSString(tempDir), CP_UTF8);
  const UInt32 idx = (UInt32)index;
  IArchiveFolder *af = archiveFolder;
  IFolderArchiveExtractCallback *cb = callback;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return af->Extract(&idx, 1, BoolToInt(false), 0, NExtract::NPathMode::kNoPaths,
        NExtract::NOverwriteMode::kOverwrite, uTemp.Ptr(), BoolToInt(false), cb);
  });
  NSString *file = [tempDir stringByAppendingPathComponent:name];
  const BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:file];
  if (hr != S_OK || cbSpec->FirstBadOpRes != NArchive::NExtract::NOperationResult::kOK || !exists)
  {
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:NULL];
    if (error)
    {
      NSString *m = cbSpec->ErrorMessage ?: msg;
      if (cbSpec->PasswordWasAsked && !passwordDelegate)
        *error = [SZErrors errorWithCode:SZErrorCodePasswordRequired message:[NSString stringWithFormat:@"A password is required to extract %@", name]];
      else if (cbSpec->Cancelled || hr == E_ABORT)
        *error = [SZErrors errorWithCode:SZErrorCodeCancelled message:@"Cancelled"];
      else if (cbSpec->FirstBadOpRes == NArchive::NExtract::NOperationResult::kWrongPassword)
        *error = [SZErrors errorWithCode:SZErrorCodeWrongPassword message:m ?: @"Wrong password"];
      else if (hr != S_OK)
        *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:m];
      else
        *error = [SZErrors errorWithCode:SZErrorCodeEngine message:m ?: [NSString stringWithFormat:@"Cannot extract %@", name]];
    }
    return nil;
  }
  // CFolderLink::Password of the level the copy came from (OpenItemInArchive writes it back).
  if (cbSpec->PasswordIsDefined && level)
    level.password = SZStringFromUString(cbSpec->Password);
  *tempDirectory = tempDir;
  return file;
}

+ (SZArchive *)openWithStream:(IInStream *)inStream
                     openPath:(NSString *)openPath
                  displayPath:(NSString *)displayPath
                   formatHint:(NSString *)formatHint
             passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                     progress:(id<SZProgressDelegate>)progress
                  outerFolder:(SZFolder *)outerFolder
               outerItemIndex:(NSInteger)outerItemIndex
                tempDirectory:(NSString *)tempDirectory
                        error:(NSError **)error
{
  if (![SZCodecs loadCodecs:error])
    return nil;

  CAgent *agentSpec = new CAgent;
  CMyComPtr<IInFolderArchive> agent = agentSpec;

  // FileFolderPluginOpen.cpp:317-330: a COpenCallbackImp whose Callback is the app-side
  // IOpenCallbackUI, then Init2(dirPrefix, fileName) for a real file (this is what gives
  // multi-volume support: _folderPrefix is where GetStream looks for the sibling volumes) or
  // SetSubArchiveName for an archive opened from a stream inside another archive.
  CSZOpenCallbackUI *uiSpec = new CSZOpenCallbackUI;
  uiSpec->Delegate = passwordDelegate;
  uiSpec->Progress = progress;
  uiSpec->Path = displayPath;
  if (progress)
  {
    // CFfpOpen: the progress is titled IDS_OPENNING and names the archive.
    if ([progress respondsToSelector:@selector(progressSetStatus:)])
      [progress progressSetStatus:SZProgressStatusOpening];
    if ([progress respondsToSelector:@selector(progressSetTitleFileName:)])
      [progress progressSetTitleFileName:displayPath.lastPathComponent];
  }
  COpenCallbackImp *cbSpec = new COpenCallbackImp;
  CMyComPtr<IArchiveOpenCallback> callback = cbSpec;
  cbSpec->Callback = uiSpec;

  // For a file open the engine needs the file-system spelling of the path (UTF-8 bytes as
  // the kernel has them); for a stream open the path only feeds extension detection.
  const UString uPath = inStream
      ? SZUStringFromNSString(openPath)
      : MultiByteToUnicodeString(SZFStringFromNSString(openPath), CP_UTF8);
  const UString uHint = SZUStringFromNSString(formatHint ?: @"");   // must not be NULL (Appendix A)

  if (inStream)
  {
    cbSpec->SetSubArchiveName(SZUStringFromNSString([openPath lastPathComponent]).Ptr());
  }
  else
  {
    FString dirPrefix, fileName;
    if (NWindows::NFile::NDir::GetFullPathAndSplit(us2fs(uPath), dirPrefix, fileName))
    {
      NWindows::NFile::NName::NormalizeDirPathPrefix(dirPrefix);
      const HRESULT initRes = cbSpec->Init2(dirPrefix, fileName);
      if (initRes != S_OK)
      {
        cbSpec->Callback = NULL;
        delete uiSpec;
        if (error)
          *error = [SZErrors errorWithHRESULT:(uint32_t)initRes
                                      message:[NSString stringWithFormat:@"Cannot stat %@", displayPath]];
        return nil;
      }
    }
  }

  CMyComBSTR type;
  NSString *msg = nil;
  IInFolderArchive *agentPtr = agent;
  IArchiveOpenCallback *cbPtr = callback;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return agentPtr->Open(inStream, uPath.Ptr(), uHint.Ptr(), &type, cbPtr);
  });

  uiSpec->Progress = nil;            // the open stage is over; a ReOpen reports nowhere

  if (hr != S_OK)
  {
    NSString *engineMsg = msg;
    const UString em = agentSpec->GetErrorMessage();
    if (!em.IsEmpty())
      engineMsg = SZStringFromUString(em);
    const bool passwordWasAsked = uiSpec->PasswordWasAsked;
    const bool cancelled = uiSpec->Cancelled;
    // CFfpOpen::Encrypted is PasswordIsDefined after an S_FALSE (FileFolderPluginOpen.cpp:358-362).
    const bool encrypted = (hr == S_FALSE) && uiSpec->PasswordIsDefined;
    // 20.01: the agent keeps NonOpen_ErrorInfo for an S_FALSE; GetFolderError reads it.
    NSString *nonOpenErrors = (hr == S_FALSE) ? SZNonOpenErrors(agent) : nil;
    cbSpec->Callback = NULL;
    delete uiSpec;
    if (error)
    {
      if (passwordWasAsked && !passwordDelegate)
        *error = [SZErrors errorWithCode:SZErrorCodePasswordRequired
                                message:[NSString stringWithFormat:@"A password is required to open %@", displayPath]];
      else if (cancelled || hr == E_ABORT)
        *error = [SZErrors errorWithCode:SZErrorCodeCancelled message:@"Cancelled"];
      else if (hr == S_FALSE)
      {
        // OpenAsArc_Msg / FM.cpp:999-1013: IDS_CANT_OPEN_ARCHIVE or, with a password in use,
        // IDS_CANT_OPEN_ENCRYPTED_ARCHIVE, then the non-open level's text on the next line.
        const UString path = SZUStringFromNSString(displayPath);
        UString m = SZFormatLangOpen(encrypted ? kLangID_CantOpenEncrypted_Open : kLangID_CantOpenArchive_Open, path);
        if (m.IsEmpty())
          m = SZUStringFromNSString([NSString stringWithFormat:@"Cannot open %@ as archive", displayPath]);
        NSString *text = SZStringFromUString(m);
        if (nonOpenErrors.length)
          text = [text stringByAppendingFormat:@"\n%@", nonOpenErrors];
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[NSLocalizedDescriptionKey] = text;
        info[SZArchiveOpenEncryptedKey] = @(encrypted);
        info[SZArchiveOpenPathKey] = displayPath;
        if (nonOpenErrors.length)
          info[SZArchiveOpenErrorMessageKey] = nonOpenErrors;
        if (engineMsg.length)
          info[SZErrorEngineMessageKey] = engineMsg;
        *error = [NSError errorWithDomain:SZErrorDomain code:SZErrorCodeNotArchive userInfo:info];
      }
      else
        *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:engineMsg];
    }
    return nil;
  }

  NSString *typeString = @"";
  if ((LPCOLESTR)type)
    typeString = SZStringFromWChars((LPCOLESTR)type, SysStringLen((BSTR)(LPCOLESTR)type));
  SZArchive *archive = [[SZArchive alloc] initWithAgent:agent agentSpec:agentSpec openCallback:callback
                                              inStream:inStream path:displayPath type:typeString
                                           outerFolder:outerFolder outerItemIndex:outerItemIndex
                                         tempDirectory:tempDirectory];
  // The open callback survives the open stage for a multi-volume set, and it holds a raw pointer
  // to the IOpenCallbackUI, so the archive takes ownership of both.
  [archive adoptOpenCallbackImp:cbSpec ui:uiSpec];
  // folderLink.Password / UsePassword = ffp.Password / ffp.Encrypted (PanelItemOpen.cpp:489-490).
  if (uiSpec->PasswordIsDefined)
    archive.password = SZStringFromUString(uiSpec->Password);
  // ffp.ErrorMessage: a level that could not be opened inside an archive that did open.
  archive.openErrorMessage = SZNonOpenErrors(agent);
  return archive;
}

+ (SZArchive *)openArchiveAtPath:(NSString *)path
                      formatHint:(NSString *)formatHint
                passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                           error:(NSError **)error
{
  return [self openArchiveAtPath:path formatHint:formatHint passwordDelegate:passwordDelegate progress:nil error:error];
}

+ (SZArchive *)openArchiveAtPath:(NSString *)path
                      formatHint:(NSString *)formatHint
                passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                        progress:(id<SZProgressDelegate>)progress
                           error:(NSError **)error
{
  NSString *p = [[path stringByExpandingTildeInPath] stringByStandardizingPath];
  BOOL isDir = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir])
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"File not found: %@", path]];
    return nil;
  }
  if (isDir)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotArchive message:[NSString stringWithFormat:@"%@ is a directory", path]];
    return nil;
  }
  // The containing directory becomes the archive's "outside" for Up-navigation.
  SZFolder *outer = [SZFileSystemFolder folderWithPath:[p stringByDeletingLastPathComponent] error:NULL];
  NSInteger outerIndex = NSNotFound;
  if (outer)
  {
    NSString *name = [p lastPathComponent];
    for (NSInteger i = 0; i < outer.itemCount; i++)
      if ([[outer nameOfItemAtIndex:i] isEqualToString:name]) { outerIndex = i; break; }
  }
  return [self openWithStream:NULL openPath:p displayPath:p formatHint:formatHint passwordDelegate:passwordDelegate
                     progress:progress outerFolder:outer outerItemIndex:outerIndex tempDirectory:nil error:error];
}

+ (SZArchive *)openArchiveInFolder:(SZFolder *)folder
                         itemIndex:(NSInteger)index
                        formatHint:(NSString *)formatHint
                  passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                             error:(NSError **)error
{
  return [self openArchiveInFolder:folder itemIndex:index formatHint:formatHint
                  passwordDelegate:passwordDelegate progress:nil error:error];
}

+ (SZArchive *)openArchiveInFolder:(SZFolder *)folder
                         itemIndex:(NSInteger)index
                        formatHint:(NSString *)formatHint
                  passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                          progress:(id<SZProgressDelegate>)progress
                             error:(NSError **)error
{
  if (index >= folder.itemCount)
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"Item index out of range"];
    return nil;
  }
  if (!folder.isArchive)
  {
    // file system (or a virtual folder that maps to paths): open the file itself
    NSString *path = [folder isKindOfClass:[SZFileSystemFolder class]]
        ? [(SZFileSystemFolder *)folder fullPathOfItemAtIndex:index]
        : [folder.fullPath stringByAppendingString:[folder nameOfItemAtIndex:index]];
    // A directory (an app bundle, a package) is never an archive: the engine would open it as a
    // file and fail with E_FAIL. Answer as Open does for any other non-archive (S_FALSE), as
    // openArchiveAtPath does (fix111).
    BOOL isDir = NO;
    if ([folder isDirectoryAtIndex:index]
        || ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir))
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeNotArchive message:[NSString stringWithFormat:@"%@ is a directory", path]];
      return nil;
    }
    return [self openWithStream:NULL openPath:path displayPath:path formatHint:formatHint passwordDelegate:passwordDelegate
                       progress:progress outerFolder:folder outerItemIndex:index tempDirectory:nil error:error];
  }

  // Inside an archive: use the item's stream (PanelItemOpen.cpp:1526-1541).
  CMyComPtr<IInArchiveGetStream> getStream;
  IFolderFolder *raw = folder.rawFolder;
  raw->QueryInterface(IID_IInArchiveGetStream, (void **)&getStream);
  CMyComPtr<IInStream> inStream;
  if (getStream)
  {
    CMyComPtr<ISequentialInStream> seq;
    NSString *msg = nil;
    IInArchiveGetStream *gs = getStream;
    SZRunCatching(&msg, [&]() { return gs->GetStream((UInt32)index, &seq); });
    if (seq)
      seq.QueryInterface(IID_IInStream, &inStream);
  }
  NSString *name = [folder nameOfItemAtIndex:index];
  NSString *virtualPath = [folder.fullPath stringByAppendingString:name];
  if (inStream)
    return [self openWithStream:inStream openPath:virtualPath displayPath:virtualPath formatHint:formatHint
               passwordDelegate:passwordDelegate progress:progress outerFolder:folder outerItemIndex:index
                  tempDirectory:nil error:error];

  // No seekable stream: extract the item to a temp folder and open the copy (7zFM does the
  // same through CPanel::OpenItemAsArchive with a 7zO temp dir).
  NSString *tempDir = nil;
  NSString *tempFile = [self extractItem:index of:folder named:name passwordDelegate:passwordDelegate progress:progress
                           tempDirectory:&tempDir error:error];
  if (!tempFile)
    return nil;
  SZArchive *archive = [self openWithStream:NULL openPath:tempFile displayPath:virtualPath formatHint:formatHint
                           passwordDelegate:passwordDelegate progress:progress outerFolder:folder outerItemIndex:index
                              tempDirectory:tempDir error:error];
  if (!archive)
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:NULL];
  else
    [archive recordTempFile:tempFile];
  return archive;
}

@end

// SZFileSystemFolder.mm -- see SZFileSystemFolder.h

#import "SZFileSystemFolder.h"
#import "SZError.h"
#import "SZSettings.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"
#import "Internal/MacFileOps.h"

using namespace NMacFolders;

// CPP/7zip/Common/FilePathAutoRename.h (deliberately not pulled into the shared SZEngine.h).
bool AutoRenamePath(FString &fullProcessedPath);

NSString * const SZFileSystemFolderShowHiddenFilesKey = @"FM.ShowHiddenFiles";

// -stringByExpandingTildeInPath also normalizes the path and drops a trailing "/", which is
// exactly the character CopyTo() uses to tell "into this directory" from "to this name".
static NSString *SZExpandTildeKeepingSeparator(NSString *path)
{
  if (![path hasPrefix:@"~"])
    return path;
  NSString *expanded = [path stringByExpandingTildeInPath];
  if ([path hasSuffix:@"/"] && ![expanded hasSuffix:@"/"])
    expanded = [expanded stringByAppendingString:@"/"];
  return expanded;
}

// ---------------------------------------------------------------------------------------
// The IFolderOperationsExtractCallback the copy engine needs, backed by an SZProgressDelegate.
// AskWrite mirrors CExtractCallbackImp::AskWrite (ExtractCallback.cpp:710-807): it only asks
// when the destination exists, remembers YesToAll / NoToAll for the rest of the operation and
// performs the auto-rename itself with AutoRenamePath() (FilePathAutoRename.cpp).
// With no delegate it answers "overwrite" and never breaks.
// ---------------------------------------------------------------------------------------

namespace {

enum EOverwriteMode { kAsk, kOverwrite, kSkip, kRename };

class CDelegateCopyCallback Z7_final:
  public IFolderOperationsExtractCallback,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IProgress)
    Z7_COM_QI_ENTRY(IFolderOperationsExtractCallback)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderOperationsExtractCallback)

  __strong id<SZProgressDelegate> _delegate;
  EOverwriteMode _mode;
public:
  explicit CDelegateCopyCallback(id<SZProgressDelegate> delegate):
      _delegate(delegate), _mode(kAsk) {}

  HRESULT CheckBreak()
  {
    id<SZProgressDelegate> d = _delegate;
    if (d && [d progressCheckBreak])
      return E_ABORT;
    return S_OK;
  }
};

Z7_COM7F_IMF(CDelegateCopyCallback::SetTotal(UInt64 total))
{
  id<SZProgressDelegate> d = _delegate;
  if (d)
    [d progressSetTotal:total];
  return CheckBreak();
}

Z7_COM7F_IMF(CDelegateCopyCallback::SetCompleted(const UInt64 *completeValue))
{
  id<SZProgressDelegate> d = _delegate;
  if (d && completeValue)
    [d progressSetCompleted:*completeValue];
  return CheckBreak();
}

Z7_COM7F_IMF(CDelegateCopyCallback::ShowMessage(const wchar_t *message))
{
  id<SZProgressDelegate> d = _delegate;
  if (d)
    [d progressShowMessage:SZStringFromWChars(message, message ? (unsigned)wcslen(message) : 0)];
  return CheckBreak();
}

Z7_COM7F_IMF(CDelegateCopyCallback::SetCurrentFilePath(const wchar_t *filePath))
{
  id<SZProgressDelegate> d = _delegate;
  if (d)
    [d progressSetCurrentFile:SZStringFromWChars(filePath, filePath ? (unsigned)wcslen(filePath) : 0)
                  isDirectory:NO];
  return CheckBreak();
}

Z7_COM7F_IMF(CDelegateCopyCallback::SetNumFiles(UInt64 numFiles))
{
  id<SZProgressDelegate> d = _delegate;
  if (d)
    [d progressSetNumFilesProcessed:numFiles];
  return CheckBreak();
}

Z7_COM7F_IMF(CDelegateCopyCallback::AskWrite(
    const wchar_t *srcPath, Int32 srcIsFolder,
    const FILETIME *srcTime, const UInt64 *srcSize,
    const wchar_t *destPath, BSTR *destPathResult, Int32 *writeAnswer))
{
  *destPathResult = NULL;
  *writeAnswer = BoolToInt(false);
  UString destPathResultTemp = destPath;
  FString destPathSys = us2fs(destPathResultTemp);

  NWindows::NFile::NFind::CFileInfo destInfo;
  if (destInfo.Find(destPathSys))
  {
    if (IntToBool(srcIsFolder))
    {
      if (!destInfo.IsDir())
      {
        RINOK(ShowMessage(L"Cannot replace file with folder with same name"))
        return E_ABORT;
      }
      return S_OK;   // the folder already exists: nothing to ask
    }
    if (destInfo.IsDir())
    {
      RINOK(ShowMessage(L"Cannot replace folder with file with same name"))
      return S_OK;
    }

    if (_mode == kSkip)
      return S_OK;

    if (_mode == kAsk)
    {
      id<SZProgressDelegate> d = _delegate;
      SZOverwriteAnswer answer = SZOverwriteAnswerYes;
      NSString *suggested = nil;
      if (d)
      {
        NSDate *existTime = nil;
        {
          FILETIME ft;
          FiTime_To_FILETIME(destInfo.MTime, ft);
          NWindows::NCOM::CPropVariant prop;
          prop = ft;
          existTime = SZDateFromPropVariant(prop);
        }
        NSDate *newTime = nil;
        if (srcTime)
        {
          NWindows::NCOM::CPropVariant prop;
          prop = *srcTime;
          newTime = SZDateFromPropVariant(prop);
        }
        answer = [d progressAskOverwriteExisting:SZStringFromUString(destPathResultTemp)
                                       existTime:existTime
                                       existSize:@(destInfo.Size)
                                         newName:SZStringFromWChars(srcPath, srcPath ? (unsigned)wcslen(srcPath) : 0)
                                         newTime:newTime
                                         newSize:srcSize ? @(*srcSize) : nil
                                   suggestedName:&suggested];
      }
      switch (answer)
      {
        case SZOverwriteAnswerCancel: return E_ABORT;
        case SZOverwriteAnswerNo: return S_OK;
        case SZOverwriteAnswerNoToAll: _mode = kSkip; return S_OK;
        case SZOverwriteAnswerYes: break;
        case SZOverwriteAnswerYesToAll: _mode = kOverwrite; break;
        case SZOverwriteAnswerAutoRename:
          _mode = kRename;
          if (suggested.length)
            destPathSys = SZFStringFromNSString(suggested);
          break;
        default: return E_FAIL;
      }
    }

    if (_mode == kRename)
    {
      if (!AutoRenamePath(destPathSys))
      {
        RINOK(ShowMessage(L"Cannot create name for file"))
        return E_ABORT;
      }
      destPathResultTemp = fs2us(destPathSys);
    }
    else
    {
      if (NWindows::NFile::NFind::DoesFileExist_Raw(destPathSys))
        if (!NWindows::NFile::NDir::DeleteFileAlways(destPathSys))
        {
          RINOK(ShowMessage(L"Cannot delete output file"))
          return E_ABORT;
        }
    }
  }
  *writeAnswer = BoolToInt(true);
  return StringToBstr(destPathResultTemp, destPathResult);
}

}  // namespace

// ---------------------------------------------------------------------------------------

@implementation SZFileSystemFolder

+ (SZFileSystemFolder *)folderWithPath:(NSString *)directoryPath error:(NSError **)error
{
  const FString path = SZFStringFromNSString(SZExpandTildeKeepingSeparator(directoryPath));
  CFSFolderMac *spec = new CFSFolderMac;
  CMyComPtr<IFolderFolder> raw = spec;
  spec->SetShowHidden([SZSettings boolForKey:SZFileSystemFolderShowHiddenFilesKey defaultValue:YES] ? true : false);
  const HRESULT hr = spec->Init(path);
  if (hr == E_INVALIDARG)
  {
    if (error)
    {
      const BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:directoryPath];
      *error = [SZErrors errorWithCode:exists ? SZErrorCodeNotFolder : SZErrorCodeFileNotFound
                              message:[NSString stringWithFormat:exists ? @"Not a folder: %@" : @"Folder not found: %@", directoryPath]];
    }
    return nil;
  }
  if (SZFail(hr, error, nil))
    return nil;
  SZFileSystemFolder *folder = [[SZFileSystemFolder alloc] initWithRawFolder:raw archive:nil];
  if (![folder loadItems:error])
    return nil;
  return folder;
}

- (CFSFolderMac *)spec
{
  // The raw folder of an SZFileSystemFolder is always a CFSFolderMac (folderWithRawFolder:
  // dispatches on kpidType == "FSFolder").
  return (CFSFolderMac *)(IFolderFolder *)self.rawFolder;
}

// The Z7_ COM macros declare the interface methods private, so they are always reached
// through an interface pointer.
- (HRESULT)withOperations:(HRESULT (^)(IFolderOperations *ops))block
{
  CMyComPtr<IFolderOperations> ops;
  self.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&ops);
  if (!ops)
    return E_NOTIMPL;
  return block(ops);
}

- (NSString *)directoryPath
{
  return self.path;
}

- (NSString *)fullPathOfItemAtIndex:(NSInteger)index
{
  CFSFolderMac *spec = [self spec];
  if (index < 0 || (unsigned)index >= spec->NumItems())
    return self.path;
  return SZStringFromFString(spec->GetItemPath((UInt32)index));
}

+ (NSSet<NSNumber *> *)defaultHiddenPropIDs
{
  // GetColumnVisible (PanelItems.cpp:25-51) + the macOS-only Mode / User / Group columns.
  return [NSSet setWithArray:@[ @(SZPropIDATime), @(SZPropIDChangeTime), @(SZPropIDAttrib), @(SZPropIDPackSize),
                                @(SZPropIDINode), @(SZPropIDLinks), @(SZPropIDNtReparse),
                                @(SZPropIDPosixAttrib), @(SZPropIDUser), @(SZPropIDGroup) ]];
}

#pragma mark - Listing

- (BOOL)showHiddenFiles
{
  return [self spec]->GetShowHidden() ? YES : NO;
}

- (void)setShowHiddenFiles:(BOOL)showHiddenFiles
{
  [self spec]->SetShowHidden(showHiddenFiles ? true : false);
}

- (BOOL)isPackageAtIndex:(NSInteger)index
{
  CFSFolderMac *spec = [self spec];
  if (index < 0 || (unsigned)index >= spec->NumItems())
    return NO;
  if (!spec->Item((unsigned)index).IsDir)
    return NO;
  const FString path = spec->GetItemPath((UInt32)index);
  return NMacFileOps::IsPackage((const char *)path) ? YES : NO;
}

- (BOOL)isSymbolicLinkAtIndex:(NSInteger)index
{
  CFSFolderMac *spec = [self spec];
  if (index < 0 || (unsigned)index >= spec->NumItems())
    return NO;
  return spec->Item((unsigned)index).IsLink ? YES : NO;
}

- (NSString *)linkTargetOfItemAtIndex:(NSInteger)index
{
  CFSFolderMac *spec = [self spec];
  if (index < 0 || (unsigned)index >= spec->NumItems())
    return nil;
  const CFSItem &item = spec->Item((unsigned)index);
  if (!item.IsLink || item.LinkTarget.IsEmpty())
    return nil;
  return SZStringFromUString(item.LinkTarget);
}

- (BOOL)directoryWasRemoved
{
  return [self spec]->WatchedDirectoryIsGone() ? YES : NO;
}

#pragma mark - Operations

- (BOOL)deleteToTrash
{
  return [self spec]->GetDeleteToTrash() ? YES : NO;
}

- (void)setDeleteToTrash:(BOOL)deleteToTrash
{
  [self spec]->SetDeleteToTrash(deleteToTrash ? true : false);
}

static CRecordVector<UInt32> SZIndexVector(NSArray<NSNumber *> *indexes)
{
  CRecordVector<UInt32> v;
  for (NSNumber *n in indexes)
  {
    const NSInteger i = n.integerValue;
    if (i >= 0)
      v.Add((UInt32)i);
  }
  return v;
}

- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                      move:(BOOL)move
                  delegate:(nullable id<SZProgressDelegate>)delegate
                     error:(NSError **)error
{
  CFSFolderMac *spec = [self spec];
  CRecordVector<UInt32> v = SZIndexVector(indexes);
  if (v.IsEmpty())
    return YES;
  const UString dest = SZUStringFromNSString(SZExpandTildeKeepingSeparator(destinationPath));
  CMyComPtr<IFolderOperationsExtractCallback> callback = new CDelegateCopyCallback(delegate);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return [self withOperations:^HRESULT (IFolderOperations *ops) {
      return ops->CopyTo(BoolToInt(move ? true : false), v.ConstData(), v.Size(),
          BoolToInt(false), 0, dest, callback);
    }];
  });
  (void)spec;
  return !SZFail(hr, error, msg);
}

- (BOOL)copyPaths:(NSArray<NSString *> *)sourcePaths
             move:(BOOL)move
         delegate:(nullable id<SZProgressDelegate>)delegate
            error:(NSError **)error
{
  return [SZFileSystemFolder copyPaths:sourcePaths
                           toDirectory:self.directoryPath
                                  move:move
                              delegate:delegate
                                 error:error];
}

+ (BOOL)copyPaths:(NSArray<NSString *> *)sourcePaths
      toDirectory:(NSString *)destinationDirectory
             move:(BOOL)move
         delegate:(nullable id<SZProgressDelegate>)delegate
            error:(NSError **)error
{
  if (sourcePaths.count == 0)
    return YES;
  UStringVector paths;
  for (NSString *p in sourcePaths)
    paths.Add(SZUStringFromNSString(SZExpandTildeKeepingSeparator(p)));
  FString destPrefix = SZFStringFromNSString(SZExpandTildeKeepingSeparator(destinationDirectory));
  NWindows::NFile::NName::NormalizeDirPathPrefix(destPrefix);
  CMyComPtr<IFolderOperationsExtractCallback> callback = new CDelegateCopyCallback(delegate);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return CopyFileSystemItems(paths, destPrefix, move ? true : false, callback);
  });
  return !SZFail(hr, error, msg);
}

- (BOOL)deleteItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                     toTrash:(BOOL)toTrash
                    delegate:(nullable id<SZProgressDelegate>)delegate
                       error:(NSError **)error
{
  CFSFolderMac *spec = [self spec];
  CRecordVector<UInt32> v = SZIndexVector(indexes);
  if (v.IsEmpty())
    return YES;
  CMyComPtr<IFolderOperationsExtractCallback> callback = new CDelegateCopyCallback(delegate);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return spec->DeleteItems(v.ConstData(), v.Size(), toTrash ? true : false, callback);
  });
  return !SZFail(hr, error, msg);
}

- (BOOL)renameItemAtIndex:(NSInteger)index toName:(NSString *)newName error:(NSError **)error
{
  const UString name = SZUStringFromNSString(newName);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return [self withOperations:^HRESULT (IFolderOperations *ops) {
      return ops->Rename((UInt32)index, name, NULL);
    }];
  });
  return !SZFail(hr, error, msg);
}

- (BOOL)createFolderNamed:(NSString *)name error:(NSError **)error
{
  const UString n = SZUStringFromNSString(name);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return [self withOperations:^HRESULT (IFolderOperations *ops) { return ops->CreateFolder(n, NULL); }];
  });
  return !SZFail(hr, error, msg);
}

- (BOOL)createFileNamed:(NSString *)name error:(NSError **)error
{
  const UString n = SZUStringFromNSString(name);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return [self withOperations:^HRESULT (IFolderOperations *ops) { return ops->CreateFile(n, NULL); }];
  });
  return !SZFail(hr, error, msg);
}

- (BOOL)calculateFullSizeOfItemAtIndex:(NSInteger)index
                              delegate:(nullable id<SZProgressDelegate>)delegate
                                 error:(NSError **)error
{
  CMyComPtr<IFolderCalcItemFullSize> calc;
  self.rawFolder->QueryInterface(IID_IFolderCalcItemFullSize, (void **)&calc);
  if (!calc)
    return !SZFail(E_NOTIMPL, error, nil);
  CMyComPtr<IFolderOperationsExtractCallback> callback = new CDelegateCopyCallback(delegate);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return calc->CalcItemFullSize((UInt32)index, callback); });
  return !SZFail(hr, error, msg);
}

- (BOOL)setComment:(nullable NSString *)comment forItemAtIndex:(NSInteger)index error:(NSError **)error
{
  NWindows::NCOM::CPropVariant prop;
  if (comment)
    prop = SZUStringFromNSString(comment);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() {
    return [self withOperations:^HRESULT (IFolderOperations *ops) {
      return ops->SetProperty((UInt32)index, kpidComment, &prop, NULL);
    }];
  });
  return !SZFail(hr, error, msg);
}

@end

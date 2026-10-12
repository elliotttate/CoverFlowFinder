// SZFolder.mm -- see SZFolder.h

#import "SZFolder.h"
#import "SZFileSystemFolder.h"
#import "SZRootFolder.h"
#import "SZArchiveOpener.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

#include <vector>

static_assert((uint32_t)SZPropIDNumDefined == (uint32_t)kpid_NUM_DEFINED, "SZPropID is out of sync with PropID.h");
static_assert((uint32_t)SZPropIDPath == kpidPath && (uint32_t)SZPropIDName == kpidName &&
              (uint32_t)SZPropIDIsDir == kpidIsDir && (uint32_t)SZPropIDSize == kpidSize &&
              (uint32_t)SZPropIDMTime == kpidMTime && (uint32_t)SZPropIDAttrib == kpidAttrib &&
              (uint32_t)SZPropIDType == kpidType && (uint32_t)SZPropIDReadOnly == kpidReadOnly &&
              (uint32_t)SZPropIDDevMinor == kpidDevMinor, "SZPropID values drifted");
static_assert((int)SZTimestampLevelMin == kTimestampPrintLevel_MIN && (int)SZTimestampLevelDay == kTimestampPrintLevel_DAY &&
              (int)SZTimestampLevelNS == kTimestampPrintLevel_NS, "SZTimestampLevel drifted");

// ---------------------------------------------------------------------------
@implementation SZPropertyInfo
{
  NSString *_localizedName;
}

- (instancetype)initWithPropID:(SZPropID)propID varType:(SZVarType)varType handlerName:(NSString *)name
{
  return [self initWithPropID:propID varType:varType handlerName:name isRaw:NO];
}

- (instancetype)initWithPropID:(SZPropID)propID varType:(SZVarType)varType handlerName:(NSString *)name isRaw:(BOOL)isRaw
{
  self = [super init];
  if (!self)
    return nil;
  _propID = propID;
  _varType = varType;
  _handlerName = [name copy];
  _isRawProperty = isRaw;
  return self;
}

- (NSString *)localizedName
{
  if (!_localizedName)
  {
    const UString handlerName = SZUStringFromNSString(_handlerName);
    _localizedName = SZStringFromUString(GetNameOfProperty((PROPID)_propID, _handlerName ? handlerName.Ptr() : NULL));
  }
  return _localizedName;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZPropertyInfo %u '%@' vt=%u%@>", (unsigned)_propID, self.localizedName, (unsigned)_varType,
      _isRawProperty ? @" raw" : @""];
}

@end

// ---------------------------------------------------------------------------
// GetOpenArcErrorMessage (FileManager/ExtractCallback.cpp:474-509), defined in SZArchiveOpener.mm.
UString SZOpenArcErrorFlagsMessage(UInt32 errorFlags);

/// AddPropertyString's value (PanelMenu.cpp:110-148) without the size grouping, which the Swift
/// side applies (PanelProperties.sizeGrouped): error / warning flags as their message, nothing for
/// no flag, everything else at level 9.
static NSString *SZPropertiesDialogString(const NWindows::NCOM::CPropVariant &prop, PROPID propID)
{
  if (prop.vt == VT_EMPTY)
    return @"";
  UString val;
  if (propID == kpidErrorFlags || propID == kpidWarningFlags)
  {
    const UInt32 flags = GetOpenArcErrorFlags(prop);
    if (flags == 0)
      return @"";
    val = SZOpenArcErrorFlagsMessage(flags);
  }
  if (val.IsEmpty())
    ConvertPropertyToString2(val, prop, propID, 9);   // "we send 9 - is ns precision"
  return SZStringFromUString(val);
}

// ---------------------------------------------------------------------------
static NSArray<SZPropertyInfo *> *SZReadPropertyInfos(UInt32 count, HRESULT (^getInfo)(UInt32, BSTR *, PROPID *, VARTYPE *))
{
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
  for (UInt32 i = 0; i < count; i++)
  {
    CMyComBSTR name;
    PROPID propID = 0;
    VARTYPE vt = VT_EMPTY;
    if (getInfo(i, &name, &propID, &vt) != S_OK)
      continue;
    NSString *handlerName = nil;
    if ((LPCOLESTR)name)
      handlerName = SZStringFromWChars((LPCOLESTR)name, SysStringLen((BSTR)(LPCOLESTR)name));
    [result addObject:[[SZPropertyInfo alloc] initWithPropID:(SZPropID)propID varType:(SZVarType)vt handlerName:handlerName]];
  }
  return result;
}

// ---------------------------------------------------------------------------
// Raw property text (IArchiveGetRawProps). Two upstream renderers that differ on purpose:
// the list cell (CPanel::SetItemText, PanelListNotify.cpp:265-349) and the Properties dialog
// (CPanel::Properties, PanelMenu.cpp:212-246).
static NSString *SZRawPropertyString(const void *data, UInt32 dataSize, PROPID propID, bool forDialog)
{
  if (dataSize == 0 || !data)
    return @"";
  if (propID == kpidNtSecure)
  {
    // Never listed (NT security is hidden on macOS, 01 §9 #7); kept for completeness.
    AString s;
    ConvertNtSecureToString((const Byte *)data, dataSize, s);
    return SZStringFromUString(MultiByteToUnicodeString(s, CP_UTF8));
  }
  if (!forDialog && propID == kpidNtReparse)
  {
    UString s;
    ConvertNtReparseToString((const Byte *)data, dataSize, s);
    if (!s.IsEmpty())
      return SZStringFromUString(s);
  }
  const UInt32 maxDataSize = forDialog ? (1u << 8) : 64;   // kMaxDataSize of each renderer
  if (dataSize > maxDataSize)
    return [NSString stringWithFormat:@"data:%u", (unsigned)dataSize];
  // ConvertDataToHex_Upper for a CRC / checksum of at most 8 bytes, lower case otherwise.
  const bool upper = dataSize <= 8 && (propID == kpidCRC || propID == kpidChecksum);
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  NSMutableString *hex = [NSMutableString stringWithCapacity:dataSize * 2];
  const Byte *p = (const Byte *)data;
  for (UInt32 i = 0; i < dataSize; i++)
    [hex appendFormat:@"%c%c", digits[p[i] >> 4], digits[p[i] & 15]];
  return hex;
}

@implementation SZArcProps
{
  CMyComPtr<IFolderArcProps> _props;
}

- (instancetype)initWithRawProps:(IFolderArcProps *)props
{
  self = [super init];
  if (!self)
    return nil;
  _props = props;
  return self;
}

- (NSInteger)levelCount
{
  UInt32 n = 0;
  if (_props->GetArcNumLevels(&n) != S_OK)
    return 0;
  return n;
}

- (NSArray<SZPropertyInfo *> *)propertiesAtLevel:(NSInteger)level
{
  if (level < 0 || level >= self.levelCount)     // CAgent indexes Arcs[level] unchecked
    return @[];
  UInt32 n = 0;
  if (_props->GetArcNumProps((UInt32)level, &n) != S_OK)
    return @[];
  IFolderArcProps *p = _props;
  return SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
    return p->GetArcPropInfo((UInt32)level, i, name, propID, vt);
  });
}

- (id)propertyAtLevel:(NSInteger)level propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

- (NSString *)displayStringAtLevel:(NSInteger)level propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return @"";
  return SZDisplayStringFromPropVariant(prop, (PROPID)propID, kTimestampPrintLevel_SEC);
}

- (NSString *)propertiesDialogStringAtLevel:(NSInteger)level propID:(SZPropID)propID answered:(BOOL *)answered
{
  if (answered)
    *answered = NO;
  if (level < 0 || level > self.levelCount)        // CAgent: E_INVALIDARG past the NonOpen level
    return @"";
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return @"";
  if (answered)
    *answered = YES;
  return SZPropertiesDialogString(prop, (PROPID)propID);
}

- (NSString *)propertiesDialogString2AtLevel:(NSInteger)level propID:(SZPropID)propID
{
  if (level < 1 || level >= self.levelCount)
    return @"";
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp2((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return @"";
  return SZPropertiesDialogString(prop, (PROPID)propID);
}

- (NSArray<SZPropertyInfo *> *)properties2AtLevel:(NSInteger)level
{
  // GetArcNumProps2 / GetArcPropInfo2 read Arcs[level - 1]: only levels 1 ..< levelCount exist.
  if (level < 1 || level >= self.levelCount)
    return @[];
  UInt32 n = 0;
  if (_props->GetArcNumProps2((UInt32)level, &n) != S_OK)
    return @[];
  IFolderArcProps *p = _props;
  return SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
    return p->GetArcPropInfo2((UInt32)level, i, name, propID, vt);
  });
}

- (id)property2AtLevel:(NSInteger)level propID:(SZPropID)propID
{
  if (level < 1 || level >= self.levelCount)
    return nil;
  NWindows::NCOM::CPropVariant prop;
  if (_props->GetArcProp2((UInt32)level, (PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

@end

// ---------------------------------------------------------------------------
@implementation SZFolder
{
  CMyComPtr<IFolderFolder> _folder;
  CMyComPtr<IFolderGetItemName> _getItemName;
  CMyComPtr<IFolderWasChanged> _wasChangedIface;
  CMyComPtr<IFolderSetFlatMode> _setFlatMode;
  CMyComPtr<IFolderCompare> _compare;
  CMyComPtr<IGetFolderArcProps> _getArcProps;
  CMyComPtr<IArchiveGetRawProps> _rawProps;
  /// PROPIDs of the raw columns in `properties` (filled with it).
  std::vector<PROPID> _rawPropIDs;
  SZArchive *_archive;
  NSInteger _itemCount;
  BOOL _flatMode;
  NSString *_folderType;
  NSString *_path;
  NSArray<SZPropertyInfo *> *_properties;
}

+ (SZFolder *)folderWithRawFolder:(IFolderFolder *)folder archive:(SZArchive *)archive
{
  NWindows::NCOM::CPropVariant prop;
  NSString *type = @"";
  if (folder->GetFolderProperty(kpidType, &prop) == S_OK && prop.vt == VT_BSTR)
    type = SZObjectFromPropVariant(prop);
  Class cls = [SZFolder class];
  if ([type isEqualToString:@"FSFolder"])
    cls = [SZFileSystemFolder class];
  else if ([type isEqualToString:@"RootFolder"] || [type isEqualToString:@"FSDrives"])
    cls = [SZRootFolder class];
  return [[cls alloc] initWithRawFolder:folder archive:archive];
}

- (instancetype)initWithRawFolder:(IFolderFolder *)folder archive:(SZArchive *)archive
{
  self = [super init];
  if (!self)
    return nil;
  _folder = folder;
  _archive = archive;
  _folder.QueryInterface(IID_IFolderGetItemName, &_getItemName);
  _folder.QueryInterface(IID_IFolderWasChanged, &_wasChangedIface);
  _folder.QueryInterface(IID_IFolderSetFlatMode, &_setFlatMode);
  _folder.QueryInterface(IID_IFolderCompare, &_compare);
  _folder.QueryInterface(IID_IGetFolderArcProps, &_getArcProps);
  _folder.QueryInterface(IID_IArchiveGetRawProps, &_rawProps);
  return self;
}

- (IFolderFolder *)rawFolder
{
  return _folder;
}

- (SZArchive *)archive
{
  return _archive;
}

// Mac/Core/Platform/MacVolume.cpp (SevenZipCore), also used by the WorkDir.cpp patch.
bool MacPath_IsOnRemovableVolume(const FString &path);

#pragma mark - Opening by path

+ (SZFolder *)folderForPath:(NSString *)path
           passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                      error:(NSError **)error
{
  return [self folderForPath:path formatHint:nil passwordDelegate:passwordDelegate error:error];
}

+ (SZFolder *)folderForPath:(NSString *)path
                 formatHint:(NSString *)formatHint
           passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                      error:(NSError **)error
{
  return [self folderForPath:path formatHint:formatHint passwordDelegate:passwordDelegate progress:nil error:error];
}

+ (BOOL)volumeIsCaseSensitiveAtPath:(NSString *)path
{
  // pathconf answers for an existing path only: walk up to the nearest one (a destination that
  // is about to be created lives on its parent's volume).
  NSString *p = path.length ? path.stringByStandardizingPath : @"/";
  NSFileManager *fm = [NSFileManager defaultManager];
  while (p.length > 1 && ![fm fileExistsAtPath:p])
    p = p.stringByDeletingLastPathComponent;
  if (p.length == 0)
    p = @"/";
  const long v = pathconf(p.fileSystemRepresentation, _PC_CASE_SENSITIVE);
  return v == 1;
}

+ (BOOL)volumeIsRemovableAtPath:(NSString *)path
{
  return MacPath_IsOnRemovableVolume(SZFStringFromNSString(path));
}

+ (SZFolder *)folderForPath:(NSString *)path
                 formatHint:(NSString *)formatHint
           passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                   progress:(id<SZProgressDelegate>)progress
                      error:(NSError **)error
{
  NSString *p = path ?: @"";
  if ([p hasPrefix:@"~"])
    p = [p stringByExpandingTildeInPath];
  if (p.length == 0)
    return [SZRootFolder rootFolder];

  if (![p hasPrefix:@"/"])
  {
    // "Computer", "Volumes", "Home", "Documents" (any language) or "Volumes/<name>"
    SZFolder *root = [SZRootFolder rootFolder];
    NSArray<NSString *> *parts = [p componentsSeparatedByString:@"/"];
    NSError *e = nil;
    SZFolder *f = [root bindToFolderNamed:parts[0] error:&e];
    if (!f)
    {
      if (error)
        *error = e ?: [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Folder not found: %@", path]];
      return nil;
    }
    NSString *rest = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"];
    if (rest.length == 0)
      return f;
    return [f bindToPath:rest passwordDelegate:passwordDelegate progress:progress error:error];
  }

  NSFileManager *fm = [NSFileManager defaultManager];
  BOOL isDir = NO;
  if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir)
    return [SZFileSystemFolder folderWithPath:p error:error];

  // Walk down until a component is a file (archive) or missing.
  NSArray<NSString *> *comps = [p pathComponents];   // "/" first
  NSString *prefix = @"/";
  NSUInteger i = 1;
  for (; i < comps.count; i++)
  {
    NSString *next = [prefix stringByAppendingPathComponent:comps[i]];
    if (![fm fileExistsAtPath:next isDirectory:&isDir])
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Path not found: %@", next]];
      return nil;
    }
    prefix = next;
    if (!isDir)
      break;
  }
  // prefix is a file: open it as an archive, continue inside
  SZArchive *archive = [SZArchiveOpener openArchiveAtPath:prefix formatHint:(formatHint.length ? formatHint : nil)
                                         passwordDelegate:passwordDelegate progress:progress error:error];
  if (!archive)
    return nil;
  SZFolder *folder = [archive rootFolder:error];
  if (!folder)
    return nil;
  if (i + 1 >= comps.count)
    return folder;
  NSString *rest = [[comps subarrayWithRange:NSMakeRange(i + 1, comps.count - i - 1)] componentsJoinedByString:@"/"];
  return [folder bindToPath:rest passwordDelegate:passwordDelegate progress:progress error:error];
}

#pragma mark - Items

- (BOOL)loadItems:(NSError **)error
{
  IFolderFolder *f = _folder;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->LoadItems(); });
  if (SZFail(hr, error, msg))
    return NO;
  UInt32 n = 0;
  if (SZFail(_folder->GetNumberOfItems(&n), error, nil))
    return NO;
  _itemCount = n;
  _properties = nil;
  _rawPropIDs.clear();
  return YES;
}

- (NSInteger)itemCount
{
  return _itemCount;
}

- (NSString *)nameOfItemAtIndex:(NSInteger)index
{
  if (_getItemName)
  {
    const wchar_t *name = NULL;
    unsigned len = 0;
    if (_getItemName->GetItemName((UInt32)index, &name, &len) == S_OK)
      return SZStringFromWChars(name, len);
  }
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDName];
  return [v isKindOfClass:[NSString class]] ? v : @"";
}

- (NSString *)prefixOfItemAtIndex:(NSInteger)index
{
  if (_getItemName)
  {
    const wchar_t *name = NULL;
    unsigned len = 0;
    if (_getItemName->GetItemPrefix((UInt32)index, &name, &len) == S_OK)
      return SZStringFromWChars(name, len);
  }
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDPrefix];
  return [v isKindOfClass:[NSString class]] ? v : @"";
}

- (uint64_t)sizeOfItemAtIndex:(NSInteger)index
{
  if (_getItemName)
    return _getItemName->GetItemSize((UInt32)index);
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDSize];
  return [v isKindOfClass:[NSNumber class]] ? [v unsignedLongLongValue] : 0;
}

- (BOOL)isDirectoryAtIndex:(NSInteger)index
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, kpidIsDir, &prop) != S_OK)
    return NO;
  return prop.vt == VT_BOOL && prop.boolVal != VARIANT_FALSE;
}

- (id)propertyOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, (PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

- (SZVarType)varTypeOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, (PROPID)propID, &prop) != S_OK)
    return SZVarTypeEmpty;
  return (SZVarType)prop.vt;
}

- (NSString *)displayStringOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID timestampLevel:(SZTimestampLevel)level
{
  if ([self isRawPropID:(PROPID)propID])
    return [self rawPropertyStringOfItemAtIndex:index propID:propID forPropertiesDialog:NO];
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetProperty((UInt32)index, (PROPID)propID, &prop) != S_OK)
    return @"";
  return SZDisplayStringFromPropVariant(prop, (PROPID)propID, (int)level);
}

- (NSArray<SZPropertyInfo *> *)properties
{
  if (!_properties)
  {
    UInt32 n = 0;
    if (_folder->GetNumberOfProperties(&n) != S_OK)
      return @[];
    IFolderFolder *f = _folder;
    NSArray<SZPropertyInfo *> *plain = SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
      return f->GetPropertyInfo(i, name, propID, vt);
    });
    _rawPropIDs.clear();
    NSMutableArray<SZPropertyInfo *> *all = [plain mutableCopy];
    UInt32 numRaw = 0;
    if (_rawProps && _rawProps->GetNumRawProps(&numRaw) == S_OK)
    {
      // CPanel::InitColumns (PanelItems.cpp:177-199): raw columns follow the folder's own.
      for (UInt32 i = 0; i < numRaw; i++)
      {
        CMyComBSTR name;
        PROPID propID = 0;
        if (_rawProps->GetRawPropInfo(i, &name, &propID) != S_OK)
          continue;
        if (propID == kpidNtSecure)
          continue;      // locked decision: NT security descriptors are hidden (01 §9 #7)
        BOOL duplicate = NO;    // FindItem_for_PropID would only ever reach the first one
        for (SZPropertyInfo *info in all)
          if ((PROPID)info.propID == propID) { duplicate = YES; break; }
        if (duplicate)
          continue;
        NSString *handlerName = nil;
        if ((LPCOLESTR)name)
          handlerName = SZStringFromWChars((LPCOLESTR)name, SysStringLen((BSTR)(LPCOLESTR)name));
        [all addObject:[[SZPropertyInfo alloc] initWithPropID:(SZPropID)propID varType:SZVarTypeEmpty
                                                  handlerName:handlerName isRaw:YES]];
        _rawPropIDs.push_back(propID);
      }
    }
    _properties = all;
  }
  return _properties;
}

- (BOOL)isRawPropID:(PROPID)propID
{
  if (!_rawProps)
    return NO;
  (void)self.properties;
  for (PROPID p : _rawPropIDs)
    if (p == propID)
      return YES;
  return NO;
}

- (BOOL)getRaw:(NSInteger)index propID:(PROPID)propID data:(const void **)data size:(UInt32 *)size type:(UInt32 *)type
{
  *data = NULL;
  *size = 0;
  *type = 0;
  if (![self isRawPropID:propID] || index < 0 || index >= _itemCount)
    return NO;
  return _rawProps->GetRawProp((UInt32)index, propID, data, size, type) == S_OK;
}

- (NSData *)rawPropertyOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID
{
  const void *data;
  UInt32 size, type;
  if (![self getRaw:index propID:(PROPID)propID data:&data size:&size type:&type] || size == 0 || !data)
    return nil;
  return [NSData dataWithBytes:data length:size];
}

+ (NSString *)stringForRawPropertyData:(NSData *)data propID:(SZPropID)propID forPropertiesDialog:(BOOL)forDialog
{
  return SZRawPropertyString(data.bytes, (UInt32)data.length, (PROPID)propID, forDialog);
}

- (NSString *)rawPropertyStringOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID forPropertiesDialog:(BOOL)forDialog
{
  const void *data;
  UInt32 size, type;
  if (![self getRaw:index propID:(PROPID)propID data:&data size:&size type:&type])
    return @"";
  return SZRawPropertyString(data, size, (PROPID)propID, forDialog);
}

#pragma mark - Folder properties

- (id)folderPropertyForID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetFolderProperty((PROPID)propID, &prop) != S_OK)
    return nil;
  return SZObjectFromPropVariant(prop);
}

- (NSArray<SZPropertyInfo *> *)folderPropertyInfos
{
  CMyComPtr<IFolderProperties> folderProperties;
  _folder.QueryInterface(IID_IFolderProperties, &folderProperties);
  if (!folderProperties)
    return @[];
  UInt32 n = 0;
  if (folderProperties->GetNumberOfFolderProperties(&n) != S_OK)
    return @[];
  IFolderProperties *p = folderProperties;
  return SZReadPropertyInfos(n, ^HRESULT(UInt32 i, BSTR *name, PROPID *propID, VARTYPE *vt) {
    return p->GetFolderPropertyInfo(i, name, propID, vt);
  });
}

- (NSString *)propertiesDialogStringForFolderPropertyID:(SZPropID)propID
{
  NWindows::NCOM::CPropVariant prop;
  if (_folder->GetFolderProperty((PROPID)propID, &prop) != S_OK)
    return @"";
  return SZPropertiesDialogString(prop, (PROPID)propID);
}

- (NSString *)folderType
{
  if (!_folderType)
  {
    id v = [self folderPropertyForID:SZPropIDType];
    _folderType = [v isKindOfClass:[NSString class]] ? v : @"";
  }
  return _folderType;
}

- (NSString *)path
{
  if (!_path)
  {
    id v = [self folderPropertyForID:SZPropIDPath];
    _path = [v isKindOfClass:[NSString class]] ? v : @"";
  }
  return _path;
}

- (NSString *)fullPath
{
  if (_archive)
  {
    NSString *inner = self.path;
    NSString *base = [_archive.path stringByAppendingString:@"/"];
    return inner.length ? [base stringByAppendingString:inner] : base;
  }
  return self.path;
}

- (BOOL)isArchive
{
  return _archive != nil || [self.folderType hasPrefix:@"7-Zip."];
}

- (BOOL)isFileSystem
{
  return [self.folderType isEqualToString:@"FSFolder"];
}

- (BOOL)isRootFolder
{
  return [self.folderType isEqualToString:@"RootFolder"];
}

- (BOOL)isReadOnly
{
  id v = [self folderPropertyForID:SZPropIDReadOnly];
  return [v isKindOfClass:[NSNumber class]] && [v boolValue];
}

- (SZArcProps *)arcProps
{
  if (!_getArcProps)
    return nil;
  CMyComPtr<IFolderArcProps> props;
  if (_getArcProps->GetFolderArcProps(&props) != S_OK || !props)
    return nil;
  return [[SZArcProps alloc] initWithRawProps:props];
}

#pragma mark - Navigation

- (SZFolder *)wrapBound:(IFolderFolder *)raw error:(NSError **)error
{
  SZFolder *sub = [SZFolder folderWithRawFolder:raw archive:_archive];
  if (![sub loadItems:error])
    return nil;
  return sub;
}

- (SZFolder *)bindToFolderAtIndex:(NSInteger)index error:(NSError **)error
{
  IFolderFolder *f = _folder;
  CMyComPtr<IFolderFolder> sub;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->BindToFolder((UInt32)index, &sub); });
  if (hr == E_INVALIDARG || (hr == S_OK && !sub))
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotFolder
                              message:[NSString stringWithFormat:@"'%@' is not a folder", [self nameOfItemAtIndex:index]]];
    return nil;
  }
  if (SZFail(hr, error, msg))
    return nil;
  return [self wrapBound:sub error:error];
}

- (SZFolder *)bindToFolderNamed:(NSString *)name error:(NSError **)error
{
  IFolderFolder *f = _folder;
  CMyComPtr<IFolderFolder> sub;
  const UString uname = SZUStringFromNSString(name);
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->BindToFolder(uname.Ptr(), &sub); });
  if (hr == E_INVALIDARG || (hr == S_OK && !sub))
  {
    if (error)
      *error = [SZErrors errorWithCode:SZErrorCodeNotFolder message:[NSString stringWithFormat:@"Folder not found: %@", name]];
    return nil;
  }
  if (SZFail(hr, error, msg))
    return nil;
  return [self wrapBound:sub error:error];
}

- (NSInteger)indexOfItemNamed:(NSString *)name
{
  const NSInteger n = self.itemCount;
  for (NSInteger i = 0; i < n; i++)
    if ([[self nameOfItemAtIndex:i] isEqualToString:name])
      return i;
  // A name typed in another case still finds its item -- except in a directory on a
  // case-sensitive volume, where "A" and "a" are two different files (01 §9 #24).
  if (self.isFileSystem && [SZFolder volumeIsCaseSensitiveAtPath:self.fullPath])
    return NSNotFound;
  for (NSInteger i = 0; i < n; i++)
    if ([[self nameOfItemAtIndex:i] caseInsensitiveCompare:name] == NSOrderedSame)
      return i;
  return NSNotFound;
}

- (SZFolder *)bindToPath:(NSString *)relativePath
        passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                   error:(NSError **)error
{
  return [self bindToPath:relativePath passwordDelegate:passwordDelegate progress:nil error:error];
}

- (SZFolder *)bindToPath:(NSString *)relativePath
        passwordDelegate:(id<SZPasswordDelegate>)passwordDelegate
                progress:(id<SZProgressDelegate>)progress
                   error:(NSError **)error
{
  SZFolder *current = self;
  for (NSString *component in [relativePath componentsSeparatedByString:@"/"])
  {
    if (component.length == 0 || [component isEqualToString:@"."])
      continue;
    if ([component isEqualToString:@".."])
    {
      SZFolder *parent = [current bindToParentFolder:error];
      if (!parent)
        return nil;
      current = parent;
      continue;
    }
    NSError *bindError = nil;
    SZFolder *next = [current bindToFolderNamed:component error:&bindError];
    if (next)
    {
      current = next;
      continue;
    }
    const NSInteger index = [current indexOfItemNamed:component];
    if (index == NSNotFound || [current isDirectoryAtIndex:index])
    {
      if (error)
        *error = bindError ?: [SZErrors errorWithCode:SZErrorCodeFileNotFound message:[NSString stringWithFormat:@"Not found: %@", component]];
      return nil;
    }
    SZArchive *archive = [SZArchiveOpener openArchiveInFolder:current itemIndex:index formatHint:nil
                                             passwordDelegate:passwordDelegate progress:progress error:error];
    if (!archive)
      return nil;
    SZFolder *root = [archive rootFolder:error];
    if (!root)
      return nil;
    current = root;
  }
  return current;
}

- (SZFolder *)bindToParentFolder:(NSError **)error
{
  IFolderFolder *f = _folder;
  CMyComPtr<IFolderFolder> parent;
  NSString *msg = nil;
  const HRESULT hr = SZRunCatching(&msg, [&]() { return f->BindToParentFolder(&parent); });
  if (SZFail(hr, error, msg))
    return nil;
  if (parent)
    return [self wrapBound:parent error:error];
  if (_archive)
  {
    SZFolder *outer = _archive.outerFolder;
    if (outer)
    {
      if (![outer loadItems:error])
        return nil;
      return outer;
    }
      // opened by path but the directory could not be listed: fall back to the root
    return [SZRootFolder rootFolder];
  }
  return [SZRootFolder rootFolder];   // "/", virtual folders and the root itself go up to the root
}

#pragma mark - Optional interfaces

- (BOOL)supportsFlatMode
{
  return _setFlatMode != NULL;
}

- (BOOL)flatMode
{
  return _flatMode;
}

- (void)setFlatMode:(BOOL)flatMode
{
  _flatMode = flatMode;
  if (_setFlatMode)
    _setFlatMode->SetFlatMode(BoolToInt(flatMode));
}

- (BOOL)supportsChangeNotification
{
  return _wasChangedIface != NULL;
}

- (BOOL)wasChanged
{
  if (!_wasChangedIface)
    return NO;
  Int32 changed = 0;
  if (_wasChangedIface->WasChanged(&changed) != S_OK)
    return NO;
  return changed != 0;
}

- (BOOL)supportsCompare
{
  return _compare != NULL;
}

- (NSInteger)compareItemAtIndex:(NSInteger)index1 withItemAtIndex:(NSInteger)index2 propID:(SZPropID)propID
{
  if ([self isRawPropID:(PROPID)propID])
  {
    // CompareItems2 with isRawProp (PanelSort.cpp:99-132): empty values first, only kRaw data is
    // ordered, reparse data by its target text, the rest by the folder's raw comparison.
    const void *d1, *d2;
    UInt32 s1, s2, t1, t2;
    if (![self getRaw:index1 propID:(PROPID)propID data:&d1 size:&s1 type:&t1]) return 0;
    if (![self getRaw:index2 propID:(PROPID)propID data:&d2 size:&s2 type:&t2]) return 0;
    if (s1 == 0)
      return s2 == 0 ? 0 : -1;
    if (s2 == 0)
      return 1;
    if (t1 != NPropDataType::kRaw || t2 != NPropDataType::kRaw)
      return 0;
    if (propID == SZPropIDNtReparse)
      return [SZFolder compareFileName:SZRawPropertyString(d1, s1, kpidNtReparse, false)
                          withFileName:SZRawPropertyString(d2, s2, kpidNtReparse, false)];
    if (_compare)
      return _compare->CompareItems((UInt32)index1, (UInt32)index2, (PROPID)propID, 1);
    const int c = memcmp(d1, d2, MyMin(s1, s2));
    return c != 0 ? (c < 0 ? -1 : 1) : (s1 < s2 ? -1 : (s1 > s2 ? 1 : 0));
  }
  if (_compare)
    return _compare->CompareItems((UInt32)index1, (UInt32)index2, (PROPID)propID, 0);
  if (propID == SZPropIDName || propID == SZPropIDPath || propID == SZPropIDExtension)
    return [SZFolder compareFileName:[self nameOfItemAtIndex:index1] withFileName:[self nameOfItemAtIndex:index2]];
  id a = [self propertyOfItemAtIndex:index1 propID:propID];
  id b = [self propertyOfItemAtIndex:index2 propID:propID];
  if (!a && !b) return 0;
  if (!a) return -1;
  if (!b) return 1;
  if ([a isKindOfClass:[NSNumber class]] && [b isKindOfClass:[NSNumber class]])
    return [(NSNumber *)a compare:b];
  if ([a isKindOfClass:[NSDate class]] && [b isKindOfClass:[NSDate class]])
    return [(NSDate *)a compare:b];
  if ([a isKindOfClass:[NSString class]] && [b isKindOfClass:[NSString class]])
    return [SZFolder compareFileName:a withFileName:b];
  return 0;
}

+ (BOOL)timestampShowUTC
{
  return g_Timestamp_Show_UTC;
}

+ (void)setTimestampShowUTC:(BOOL)show
{
  g_Timestamp_Show_UTC = show;
}

+ (NSInteger)compareFileName:(NSString *)name1 withFileName:(NSString *)name2
{
  const UString a = SZUStringFromNSString(name1);
  const UString b = SZUStringFromNSString(name2);
  return CompareFileNames_ForFolderList(a.Ptr(), b.Ptr());
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@ %@ '%@' items=%lu>", NSStringFromClass([self class]), self.folderType, self.fullPath, (unsigned long)_itemCount];
}

@end

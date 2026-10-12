// SZCodecs.mm -- see SZCodecs.h

#import "SZCodecs.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"

@interface SZFormatInfo ()
- (instancetype)initWithArcInfo:(const CArcInfoEx &)info index:(NSInteger)index;
@end

@implementation SZFormatInfo

- (instancetype)initWithArcInfo:(const CArcInfoEx &)info index:(NSInteger)index
{
  self = [super init];
  if (!self)
    return nil;
  _index = index;
  _name = SZStringFromUString(info.Name);
  NSMutableArray *exts = [NSMutableArray array];
  NSMutableArray *addExts = [NSMutableArray array];
  FOR_VECTOR (i, info.Exts)
  {
    [exts addObject:[SZStringFromUString(info.Exts[i].Ext) lowercaseString]];
    [addExts addObject:[SZStringFromUString(info.Exts[i].AddExt) lowercaseString]];
  }
  _extensions = exts;
  _addExtensions = addExts;
  _mainExtension = exts.count ? exts[0] : @"";
  _updateEnabled = info.UpdateEnabled;
  _isHashHandler = info.Flags_HashHandler();
  _keepName = info.Flags_KeepName();
  _findSignature = info.Flags_FindSignature();
  _supportsAltStreams = info.Flags_AltStreams();
  _supportsNtSecurity = info.Flags_NtSecurity();
  _supportsSymLinks = info.Flags_SymLinks();
  _supportsHardLinks = info.Flags_HardLinks();
  _useGlobalOffset = info.Flags_UseGlobalOffset();
  _startOpen = info.Flags_StartOpen();
  _backwardOpen = info.Flags_BackwardOpen();
  _preArc = info.Flags_PreArc();
  _pureStartOpen = info.Flags_PureStartOpen();
  _byExtOnlyOpen = info.Flags_ByExtOnlyOpen();
  _supportsCTime = info.Flags_CTime();
  _supportsATime = info.Flags_ATime();
  _supportsMTime = info.Flags_MTime();
  _flags = info.Flags;
  _timeFlags = info.TimeFlags;
  _signatureCount = info.Signatures.Size();
  _signatureOffset = info.SignatureOffset;
  NSMutableArray<NSData *> *signatures = [NSMutableArray arrayWithCapacity:info.Signatures.Size()];
  FOR_VECTOR (i, info.Signatures)
    [signatures addObject:[NSData dataWithBytes:(const Byte *)info.Signatures[i] length:info.Signatures[i].Size()]];
  _signatures = signatures;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<SZFormatInfo %@ [%@]%@>", _name,
          [_extensions componentsJoinedByString:@" "], _updateEnabled ? @" update" : @""];
}

@end

static NSArray<SZFormatInfo *> *g_formats = nil;

@implementation SZCodecs

+ (BOOL)loadCodecs:(NSError **)error
{
  @synchronized (self)
  {
    if (g_CodecsObj)
      return YES;
    NSString *msg = nil;
    const HRESULT hr = SZRunCatching(&msg, [&]() { return LoadGlobalCodecs(); });
    if (hr != S_OK)
    {
      if (error)
        *error = [SZErrors errorWithCode:SZErrorCodeCodecsNotLoaded
                                message:msg ?: [NSString stringWithFormat:@"LoadGlobalCodecs failed: %@", [SZErrors messageForHRESULT:(uint32_t)hr]]];
      return NO;
    }
    NSMutableArray *formats = [NSMutableArray arrayWithCapacity:g_CodecsObj->Formats.Size()];
    FOR_VECTOR (i, g_CodecsObj->Formats)
      [formats addObject:[[SZFormatInfo alloc] initWithArcInfo:g_CodecsObj->Formats[i] index:i]];
    g_formats = formats;
    return YES;
  }
}

+ (BOOL)isLoaded
{
  return g_CodecsObj != NULL;
}

+ (void)unload
{
  @synchronized (self)
  {
    FreeGlobalCodecs();
    g_formats = nil;
  }
}

+ (NSArray<SZFormatInfo *> *)formats
{
  // Through the lock even when loaded: the codecs are built on a worker at launch, and a reader
  // that saw g_CodecsObj set before g_formats was assigned would get an empty list.
  if (![self loadCodecs:NULL])
    return @[];
  return g_formats ?: @[];
}

+ (NSInteger)formatCount
{
  return [self formats].count;
}

+ (SZFormatInfo *)formatAtEngineIndex:(int)index
{
  NSArray *formats = [self formats];
  if (index < 0 || (NSUInteger)index >= formats.count)
    return nil;
  return formats[(NSUInteger)index];
}

+ (SZFormatInfo *)formatForExtension:(NSString *)extension
{
  if (![self loadCodecs:NULL])
    return nil;
  return [self formatAtEngineIndex:g_CodecsObj->FindFormatForExtension(SZUStringFromNSString(extension))];
}

+ (SZFormatInfo *)formatForArchiveName:(NSString *)path
{
  if (![self loadCodecs:NULL])
    return nil;
  return [self formatAtEngineIndex:g_CodecsObj->FindFormatForArchiveName(SZUStringFromNSString(path))];
}

+ (SZFormatInfo *)formatNamed:(NSString *)name
{
  if (![self loadCodecs:NULL])
    return nil;
  return [self formatAtEngineIndex:g_CodecsObj->FindFormatForArchiveType(SZUStringFromNSString(name))];
}

+ (NSArray<SZFormatInfo *> *)formatsMatchingHeader:(NSData *)header
{
  // The signature test of OpenStream's first pass (OpenArchive.cpp, `IsSignatureMatched`): a
  // handler matches when one of its signatures sits at its SignatureOffset in the header bytes.
  NSMutableArray<SZFormatInfo *> *out = [NSMutableArray array];
  const Byte *bytes = (const Byte *)header.bytes;
  const NSUInteger length = header.length;
  for (SZFormatInfo *format in [self formats])
  {
    const NSUInteger offset = format.signatureOffset;
    for (NSData *signature in format.signatures)
    {
      if (signature.length == 0 || offset > length || signature.length > length - offset)
        continue;
      if (memcmp(bytes + offset, signature.bytes, signature.length) == 0)
      {
        [out addObject:format];
        break;
      }
    }
  }
  return out;
}

+ (NSSet<NSString *> *)allExtensions
{
  NSMutableSet *set = [NSMutableSet set];
  for (SZFormatInfo *f in [self formats])
    [set addObjectsFromArray:f.extensions];
  return set;
}

@end

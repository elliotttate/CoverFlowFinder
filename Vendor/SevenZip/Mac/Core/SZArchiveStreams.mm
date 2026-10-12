// CoverFlowFinder addition, 2026-10-11. LGPL-2.1-or-later.
#import "SZArchiveStreams.h"
#import "SZError.h"
#import "Internal/SZFolder+Internal.h"
#import "Internal/SZBridgeUtils.h"

class CFFByteStream final: public ISequentialOutStream, public CMyUnknownImp {
  Z7_COM_UNKNOWN_IMP_1(ISequentialOutStream)
public:
  BOOL (^Consumer)(NSData *);
  id<SZProgressDelegate> Progress;
  UInt64 Limit, Written;
  bool LimitExceeded;
  CFFByteStream(): Consumer(nil), Progress(nil), Limit(0), Written(0), LimitExceeded(false) {}
  Z7_COM7F_IMF(Write(const void *data, UInt32 size, UInt32 *processedSize)) override {
    if (processedSize) *processedSize = 0;
    if (size > Limit - Written) { LimitExceeded = true; return E_ABORT; }
    const Byte *p = (const Byte *)data;
    UInt32 offset = 0;
    while (offset < size) {
      @autoreleasepool {
        if (Progress && [Progress progressCheckBreak]) return E_ABORT;
        UInt32 n = size - offset;
        if (n > 262144) n = 262144;
        if (!Consumer([NSData dataWithBytes:p + offset length:n])) return E_ABORT;
        offset += n;
        Written += n;
        if (processedSize) *processedSize = offset;
      }
    }
    return S_OK;
  }
};

class CFFExtractCallback final: public IArchiveExtractCallback, public ICryptoGetTextPassword,
    public IArchiveRequestMemoryUseCallback, public CMyUnknownImp {
  Z7_COM_QI_BEGIN2(IArchiveExtractCallback)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_ENTRY(IArchiveRequestMemoryUseCallback)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE
public:
  CMyComPtr<ISequentialOutStream> Stream;
  id<SZProgressDelegate> Progress;
  SZArchive *Archive;
  UInt32 Selected;
  UInt64 MemoryLimit;
  Int32 Failure;
  bool Test, MemoryExceeded, AskedPassword, SawResult;
  CFFExtractCallback(): Progress(nil), Archive(nil), Selected(0), MemoryLimit(0),
    Failure(0), Test(false), MemoryExceeded(false), AskedPassword(false), SawResult(false) {}
  HRESULT Check() { return Progress && [Progress progressCheckBreak] ? E_ABORT : S_OK; }
  Z7_COM7F_IMF(SetTotal(UInt64 total)) override {
    if (Progress) [Progress progressSetTotal:total];
    return Check();
  }
  Z7_COM7F_IMF(SetCompleted(const UInt64 *completed)) override {
    if (Progress && completed) [Progress progressSetCompleted:*completed];
    return Check();
  }
  Z7_COM7F_IMF(GetStream(UInt32 index, ISequentialOutStream **out, Int32 mode)) override {
    *out = NULL;
    if (!Test && index == Selected && mode == NArchive::NExtract::NAskMode::kExtract) {
      *out = Stream; if (*out) (*out)->AddRef();
    }
    return Check();
  }
  Z7_COM7F_IMF(PrepareOperation(Int32)) override { return Check(); }
  Z7_COM7F_IMF(SetOperationResult(Int32 result)) override {
    SawResult = true;
    if (result != NArchive::NExtract::NOperationResult::kOK && Failure == 0) Failure = result;
    if (Progress) [Progress progressSetOperationResult:(SZOperationResult)result path:Archive.path isEncrypted:NO];
    return Check();
  }
  Z7_COM7F_IMF(CryptoGetTextPassword(BSTR *password)) override {
    *password = NULL;
    AskedPassword = true;
    NSString *value = Archive.password;
    if (!value && Progress) value = [Progress progressAskPasswordForPath:Archive.path];
    if (!value) return E_ABORT;
    Archive.password = value;
    return StringToBstr(SZUStringFromNSString(value), password);
  }
  Z7_COM7F_IMF(RequestMemoryUse(UInt32, UInt32, UInt32, const wchar_t *, UInt64 required,
                               UInt64 *allowed, UInt32 *answer)) override {
    *allowed = MemoryLimit;
    if (required > MemoryLimit) {
      MemoryExceeded = true;
      *answer = NRequestMemoryAnswerFlags::k_Stop | NRequestMemoryAnswerFlags::k_Limit_Exceeded;
      return E_ABORT;
    }
    *answer = NRequestMemoryAnswerFlags::k_Allow;
    return Check();
  }
};

static BOOL CFFRunExtract(SZArchive *archive, UInt32 index, UInt64 maxBytes, UInt64 memoryLimit,
                         id<SZProgressDelegate> progress, BOOL (^consumer)(NSData *), bool test,
                         NSError **error) {
  IInArchive *raw = archive.rawArchive;
  if (!raw) { if (error) *error = [SZErrors errorWithCode:SZErrorCodeNotArchive message:@"Archive is closed"]; return NO; }
  CFFByteStream *stream = new CFFByteStream;
  CMyComPtr<ISequentialOutStream> streamOwner = stream;
  stream->Consumer = consumer; stream->Progress = progress; stream->Limit = maxBytes;
  CFFExtractCallback *cb = new CFFExtractCallback;
  CMyComPtr<IArchiveExtractCallback> callback = cb;
  cb->Stream = streamOwner; cb->Archive = archive; cb->Progress = progress;
  cb->Selected = index; cb->MemoryLimit = memoryLimit; cb->Test = test;
  NSString *message = nil;
  HRESULT hr = SZRunCatching(&message, [&]() {
    if (test) {
      NWindows::NCOM::CPropVariant flags;
      RINOK(raw->GetArchiveProperty(kpidErrorFlags, &flags))
      if ((flags.vt == VT_UI4 && flags.ulVal != 0) || archive.openErrorMessage.length != 0) {
        message = archive.openErrorMessage.length ? archive.openErrorMessage : @"Archive has damaged or missing headers";
        return (HRESULT)E_FAIL;
      }
    }
    // 7z/ZIP decoder properties and RAR5's memory request callback use different APIs.
    CMyComPtr<ISetProperties> properties;
    raw->QueryInterface(IID_ISetProperties, (void **)&properties);
    if (properties) {
      NWindows::NCOM::CPropVariant limit(memoryLimit);
      const wchar_t *name = L"memuse";
      if (properties->SetProperties(&name, &limit, 1) != S_OK) {
        name = L"memx";
        properties->SetProperties(&name, &limit, 1);
      }
    }
    UInt32 count = 0;
    RINOK(raw->GetNumberOfItems(&count))
    if (!test && index >= count) return (HRESULT)E_INVALIDARG;
    return raw->Extract(test ? NULL : &index, test ? (UInt32)-1 : 1, test ? 1 : 0, callback);
  });
  if (hr == S_OK && cb->Failure == 0 && (test || cb->SawResult)) return YES;
  if (error) {
    if (stream->LimitExceeded || cb->MemoryExceeded)
      *error = [SZErrors errorWithCode:SZErrorCodeOutOfMemory message:@"Archive extraction exceeds its byte or decoder memory limit"];
    else if (cb->Failure != 0) {
      UString text; SetExtractErrorMessage(cb->Failure, cb->AskedPassword, L"", text);
      SZErrorCode code = cb->Failure == NArchive::NExtract::NOperationResult::kWrongPassword ? SZErrorCodeWrongPassword : SZErrorCodeEngine;
      // Several formats report bad decrypted data as CRC/DataError rather than WrongPassword.
      if (cb->AskedPassword) archive.password = nil;
      *error = [SZErrors errorWithCode:code message:SZStringFromUString(text)];
    } else
      *error = [SZErrors errorWithHRESULT:(uint32_t)(hr == S_OK ? E_FAIL : hr) message:message];
  }
  return NO;
}

@implementation SZArchive (SafeStreams)
- (NSArray<NSDictionary<NSString *, id> *> *)streamEntriesWithLimit:(NSUInteger)limit
                                                        progress:(id<SZProgressDelegate>)progress error:(NSError **)error {
  IInArchive *raw = self.rawArchive;
  if (!raw) { if (error) *error = [SZErrors errorWithCode:SZErrorCodeNotArchive message:@"Archive is closed"]; return nil; }
  NSMutableArray *entries = [NSMutableArray array];
  NSString *message = nil;
  HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
    UInt32 count = 0; RINOK(raw->GetNumberOfItems(&count))
    if (count > limit) { message = @"Archive contains too many entries"; return E_OUTOFMEMORY; }
    const PROPID props[] = { kpidPath, kpidIsDir, kpidSize, kpidPackSize, kpidMTime, kpidCRC,
                            kpidPosixAttrib, kpidAttrib, kpidEncrypted, kpidSymLink, kpidHardLink };
    NSString *keys[] = { @"path", @"directory", @"size", @"packedSize", @"modified", @"crc",
                         @"mode", @"attributes", @"encrypted", @"symlink", @"hardlink" };
    for (UInt32 i = 0; i < count; ++i) {
      @autoreleasepool {
        if (progress && [progress progressCheckBreak]) return E_ABORT;
        NSMutableDictionary *item = [NSMutableDictionary dictionaryWithObject:@(i) forKey:@"index"];
        for (unsigned p = 0; p < sizeof(props) / sizeof(props[0]); ++p) {
          NWindows::NCOM::CPropVariant value;
          RINOK(raw->GetProperty(i, props[p], &value))
          id obj = SZObjectFromPropVariant(value);
          if (obj) item[keys[p]] = obj;
        }
        [entries addObject:item];
      }
    }
    return S_OK;
  });
  return SZFail(hr, error, message) ? nil : entries;
}
- (BOOL)streamItemAtIndex:(uint32_t)index maxBytes:(uint64_t)maxBytes memoryLimit:(uint64_t)memoryLimit
                progress:(id<SZProgressDelegate>)progress consumer:(BOOL (^)(NSData *))consumer error:(NSError **)error {
  return CFFRunExtract(self, index, maxBytes, memoryLimit, progress, consumer, false, error);
}
- (BOOL)testWithMemoryLimit:(uint64_t)memoryLimit progress:(id<SZProgressDelegate>)progress error:(NSError **)error {
  return CFFRunExtract(self, 0, 0, memoryLimit, progress, nil, true, error);
}
@end

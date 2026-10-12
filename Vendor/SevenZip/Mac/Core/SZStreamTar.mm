// SZStreamTar.mm -- see SZStreamTar.h (quicklook scope).
//
//   caller thread                          worker thread
//   -------------                          -------------
//   outer = CreateInArchive(gzip ...)
//   outer->Open(file)
//   tar = CreateInArchive(tar)
//   tar->OpenSeq(binder.in)    <--pipe--   outer->Extract(item 0) -> GetStream() = binder.out
//   tar->GetProperty(i, ...)  (reads one header, skipping the previous item's data)
//   ... until E_INVALIDARG (end of archive), an error, `entry` says stop, or checkBreak
//   release binder.in  -> CloseRead: the writer's next Write returns "writing was cut"
//                                          Extract returns; the callback drops binder.out
//   join
//
// Nothing touches the disk but the read of `path`.

#import "SZStreamTar.h"

#import "SZCodecs.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"

#include <atomic>
#include <thread>

#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL
#include "../../CPP/7zip/Common/FileStreams.h"
#include "../../CPP/7zip/Common/StreamBinder.h"
#pragma pop_macro("BOOL")

@interface SZStreamTarEntry ()
- (instancetype)initWithPath:(NSString *)path isDirectory:(BOOL)isDirectory size:(uint64_t)size
                    modified:(nullable NSDate *)modified modifiedText:(NSString *)modifiedText;
@end

@implementation SZStreamTarEntry
- (instancetype)initWithPath:(NSString *)path isDirectory:(BOOL)isDirectory size:(uint64_t)size
                    modified:(NSDate *)modified modifiedText:(NSString *)modifiedText
{
  if ((self = [super init]))
  {
    _path = [path copy];
    _isDirectory = isDirectory;
    _size = size;
    _modified = modified;
    _modifiedText = [modifiedText copy];
  }
  return self;
}
@end

namespace {

/// The worker's extract callback: item 0's data goes into the pipe; progress polls checkBreak.
class CPipeExtractCallback Z7_final:
  public IArchiveExtractCallback,
  public CMyUnknownImp
{
  Z7_COM_UNKNOWN_IMP_1(IArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IArchiveExtractCallback)
public:
  CMyComPtr<ISequentialOutStream> OutStream;
  BOOL (^CheckBreak)(void);
  std::atomic<bool> *Stop;

  CPipeExtractCallback(): CheckBreak(nil), Stop(NULL) {}

  HRESULT Poll()
  {
    if (Stop->load())
      return E_ABORT;
    if (CheckBreak && CheckBreak())
    {
      Stop->store(true);
      return E_ABORT;
    }
    return S_OK;
  }
};

Z7_COM7F_IMF(CPipeExtractCallback::SetTotal(UInt64))
{
  return Poll();
}

Z7_COM7F_IMF(CPipeExtractCallback::SetCompleted(const UInt64 *))
{
  return Poll();
}

Z7_COM7F_IMF(CPipeExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askExtractMode))
{
  *outStream = NULL;
  if (index != 0 || askExtractMode != NArchive::NExtract::NAskMode::kExtract || !OutStream)
    return S_OK;
  // The one reference the writer side holds: dropping it (here or in SetOperationResult) closes
  // the pipe for writing, which is the reader's end of stream.
  *outStream = OutStream.Detach();
  return S_OK;
}

Z7_COM7F_IMF(CPipeExtractCallback::PrepareOperation(Int32))
{
  return S_OK;
}

Z7_COM7F_IMF(CPipeExtractCallback::SetOperationResult(Int32))
{
  return S_OK;
}

int FormatIndexNamed(NSString *name)
{
  if (!g_CodecsObj || name.length == 0)
    return -1;
  return g_CodecsObj->FindFormatForArchiveType(SZUStringFromNSString(name));
}

} // namespace

@implementation SZStreamTar

+ (BOOL)listTarInsideFileAtPath:(NSString *)path
                    outerFormat:(NSString *)outerFormat
                 timestampLevel:(SZTimestampLevel)level
                     checkBreak:(BOOL (^)(void))checkBreak
                          entry:(BOOL (NS_NOESCAPE ^)(SZStreamTarEntry *))entry
                          error:(NSError **)error
{
  NSError *loadError = nil;
  if (![SZCodecs loadCodecs:&loadError])
  {
    if (error) *error = loadError;
    return NO;
  }
  const int outerIndex = FormatIndexNamed(outerFormat);
  const int tarIndex = FormatIndexNamed(@"tar");
  if (outerIndex < 0 || tarIndex < 0)
  {
    if (error) *error = [SZErrors errorWithCode:SZErrorCodeUnsupported
                                        message:[NSString stringWithFormat:@"no handler for %@", outerFormat]];
    return NO;
  }

  BOOL sawTar = NO;
  NSString *message = nil;
  const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT
  {
    // The outer level, opened by its own handler on this thread.
    CMyComPtr<IInArchive> outer;
    RINOK(g_CodecsObj->CreateInArchive((unsigned)outerIndex, outer))
    if (!outer)
      return E_NOTIMPL;
    CInFileStream *fileSpec = new CInFileStream;
    CMyComPtr<IInStream> file = fileSpec;
    if (!fileSpec->Open(SZFStringFromNSString(path)))
      return GetLastError_noZero_HRESULT();
    const UInt64 maxCheck = (UInt64)1 << 20;
    const HRESULT openRes = outer->Open(file, &maxCheck, NULL);
    if (openRes != S_OK)
      return openRes == S_FALSE ? S_FALSE : openRes;
    UInt32 numItems = 0;
    RINOK(outer->GetNumberOfItems(&numItems))
    if (numItems < 1)
      return S_FALSE;

    // The tar level, reading sequentially from the pipe.
    CMyComPtr<IInArchive> tar;
    RINOK(g_CodecsObj->CreateInArchive((unsigned)tarIndex, tar))
    CMyComPtr<IArchiveOpenSeq> tarSeq;
    tar.QueryInterface(IID_IArchiveOpenSeq, &tarSeq);
    if (!tarSeq)
      return E_NOTIMPL;

    CStreamBinder binder;
    RINOK(binder.Create_ReInit())
    CMyComPtr<ISequentialInStream> pipeIn;
    CMyComPtr<ISequentialOutStream> pipeOut;
    binder.CreateStreams2(pipeIn, pipeOut);

    std::atomic<bool> stop(false);
    CPipeExtractCallback *callbackSpec = new CPipeExtractCallback;
    CMyComPtr<IArchiveExtractCallback> callback = callbackSpec;
    callbackSpec->OutStream = pipeOut;
    pipeOut.Release();
    callbackSpec->CheckBreak = checkBreak;
    callbackSpec->Stop = &stop;

    IInArchive *outerRaw = outer;
    std::thread writer([outerRaw, callbackSpec]()
    {
      try
      {
        const UInt32 index = 0;
        outerRaw->Extract(&index, 1, 0, callbackSpec);
      }
      catch (...) {}
      // However Extract ended, the pipe is closed for writing, so the reader sees its end.
      callbackSpec->OutStream.Release();
    });

    HRESULT res = S_OK;
    try
    {
      res = tarSeq->OpenSeq(pipeIn);
      for (UInt32 i = 0; res == S_OK; i++)
      {
        if (stop.load() || (checkBreak && checkBreak()))
        {
          stop.store(true);
          break;
        }
        NWindows::NCOM::CPropVariant pathProp;
        const HRESULT r = tar->GetProperty(i, kpidPath, &pathProp);
        if (r == E_INVALIDARG)          // CHandler::SkipTo: no more headers
          break;
        if (r != S_OK)
        {
          res = (i == 0) ? S_FALSE : S_OK; // a stream that is not tar, or a truncated one
          break;
        }
        sawTar = YES;
        NWindows::NCOM::CPropVariant dirProp, sizeProp, timeProp;
        tar->GetProperty(i, kpidIsDir, &dirProp);
        tar->GetProperty(i, kpidSize, &sizeProp);
        tar->GetProperty(i, kpidMTime, &timeProp);
        NSString *itemPath = pathProp.vt == VT_BSTR ? SZStringFromWChars(pathProp.bstrVal,
                                                      (unsigned)wcslen(pathProp.bstrVal)) : @"";
        const BOOL isDir = dirProp.vt == VT_BOOL && dirProp.boolVal != VARIANT_FALSE;
        UInt64 size = 0;
        if (sizeProp.vt == VT_UI8) size = sizeProp.uhVal.QuadPart;
        else if (sizeProp.vt == VT_UI4) size = sizeProp.ulVal;
        SZStreamTarEntry *item = [[SZStreamTarEntry alloc]
            initWithPath:itemPath isDirectory:isDir size:size
                modified:SZDateFromPropVariant(timeProp)
            modifiedText:SZDisplayStringFromPropVariant(timeProp, kpidMTime, (int)level)];
        if (!entry(item))
        {
          stop.store(true);
          break;
        }
      }
    }
    catch (...)
    {
      stop.store(true);
      tar->Close();
      tar.Release();
      tarSeq.Release();
      pipeIn.Release();
      writer.join();
      throw;
    }
    stop.store(true);
    // Close the read side: the tar handler holds the pipe through _seqStream, and our reference
    // is the other; with both gone CBinderInStream's destructor unblocks the writer.
    tar->Close();
    tarSeq.Release();
    tar.Release();
    pipeIn.Release();
    writer.join();
    outer->Close();
    return sawTar ? S_OK : res;
  });

  if (hr == S_OK)
    return YES;
  if (error)
  {
    if (hr == S_FALSE)
      *error = [SZErrors errorWithCode:SZErrorCodeNotArchive message:@"the stream is not a tar archive"];
    else
      *error = SZErrorFromHRESULT(hr, message);
  }
  return NO;
}

@end

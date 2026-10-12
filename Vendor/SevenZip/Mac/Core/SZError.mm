// SZError.mm -- see SZError.h

#import "SZError.h"
#import "Internal/SZBridgeUtils.h"

NSErrorDomain const SZErrorDomain = @"com.yrambler2001.7zip.SevenZipKit";
NSErrorUserInfoKey const SZErrorHRESULTKey = @"SZErrorHRESULT";
NSErrorUserInfoKey const SZErrorEngineMessageKey = @"SZErrorEngineMessage";

@implementation SZErrors

+ (NSError *)errorWithCode:(SZErrorCode)code message:(NSString *)message
{
  return [NSError errorWithDomain:SZErrorDomain code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}

+ (NSString *)messageForHRESULT:(uint32_t)hresult
{
  return SZStringFromUString(NWindows::NError::MyFormatMessage((HRESULT)hresult));
}

+ (NSError *)errorWithHRESULT:(uint32_t)hresult message:(NSString *)engineMessage
{
  SZErrorCode code = SZErrorCodeEngine;
  switch ((HRESULT)hresult)
  {
    case E_ABORT: code = SZErrorCodeCancelled; break;
    case E_OUTOFMEMORY: code = SZErrorCodeOutOfMemory; break;
    case E_NOTIMPL: code = SZErrorCodeNotImplemented; break;
    case E_INVALIDARG: code = SZErrorCodeInvalidArgument; break;
    case S_FALSE: code = SZErrorCodeNotArchive; break;
    default: break;
  }
  NSString *formatted = [self messageForHRESULT:hresult];
  NSString *description = (engineMessage.length > 0) ? engineMessage : formatted;
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[NSLocalizedDescriptionKey] = description;
  info[SZErrorHRESULTKey] = @(hresult);
  if (engineMessage.length > 0)
    info[SZErrorEngineMessageKey] = engineMessage;
  if (formatted.length > 0 && engineMessage.length > 0)
    info[NSLocalizedFailureReasonErrorKey] = formatted;
  return [NSError errorWithDomain:SZErrorDomain code:code userInfo:info];
}

@end

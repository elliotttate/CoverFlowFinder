// SZError.h -- NSError mapping for engine HRESULTs and bridge failures.

#ifndef SZ_ERROR_H
#define SZ_ERROR_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SZErrorDomain;

/// userInfo: NSNumber (uint32) with the raw HRESULT, when the error came from the engine.
FOUNDATION_EXPORT NSErrorUserInfoKey const SZErrorHRESULTKey;
/// userInfo: NSString with the engine's own message (e.g. CAgent::GetErrorMessage()), if any.
FOUNDATION_EXPORT NSErrorUserInfoKey const SZErrorEngineMessageKey;

typedef NS_ERROR_ENUM(SZErrorDomain, SZErrorCode) {
    SZErrorCodeUnknown = 1,
    /// Generic engine failure; SZErrorHRESULTKey carries the HRESULT.
    SZErrorCodeEngine = 2,
    SZErrorCodeCancelled = 3,            ///< E_ABORT
    SZErrorCodeOutOfMemory = 4,          ///< E_OUTOFMEMORY
    SZErrorCodeNotImplemented = 5,       ///< E_NOTIMPL
    SZErrorCodeInvalidArgument = 6,      ///< E_INVALIDARG
    SZErrorCodeNotArchive = 10,          ///< Open returned S_FALSE: no handler accepted the file
    SZErrorCodePasswordRequired = 11,    ///< the archive asked for a password and no delegate was given
    SZErrorCodeWrongPassword = 12,
    SZErrorCodeCodecsNotLoaded = 13,
    SZErrorCodeFileNotFound = 14,
    SZErrorCodeNotFolder = 15,           ///< bind target is not a folder / archive
    SZErrorCodeUnsupported = 16          ///< the folder does not implement the requested interface
};

/// Helpers (named SZErrors because NS_ERROR_ENUM gives Swift a struct called SZError).
@interface SZErrors : NSObject

+ (NSError *)errorWithCode:(SZErrorCode)code message:(NSString *)message;
/// Maps well-known HRESULTs (E_ABORT, E_OUTOFMEMORY, E_NOTIMPL, E_INVALIDARG) to their codes,
/// everything else to SZErrorCodeEngine; the description is NWindows::NError::MyFormatMessage.
+ (NSError *)errorWithHRESULT:(uint32_t)hresult message:(nullable NSString *)engineMessage;
+ (NSString *)messageForHRESULT:(uint32_t)hresult;

@end

NS_ASSUME_NONNULL_END

#endif

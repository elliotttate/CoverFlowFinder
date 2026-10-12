// SZBridgeUtils.h -- string / PROPVARIANT / HRESULT conversions shared by the .mm files.
// Objective-C++ only.

#ifndef SZ_BRIDGE_UTILS_H
#define SZ_BRIDGE_UTILS_H

#import <Foundation/Foundation.h>
#import "SZTypes.h"
#include "SZEngine.h"

NS_ASSUME_NONNULL_BEGIN

// UString (UTF-32 wchar_t) <-> NSString
NSString *SZStringFromUString(const UString &s);
NSString *SZStringFromWChars(const wchar_t * _Nullable s, unsigned len);
UString SZUStringFromNSString(NSString * _Nullable s);
// FString (UTF-8 file-system bytes) <-> NSString
NSString *SZStringFromFString(const FString &s);
FString SZFStringFromNSString(NSString * _Nullable s);

// PROPVARIANT -> NSString / NSNumber / NSDate / nil
id _Nullable SZObjectFromPropVariant(const PROPVARIANT &prop);
NSDate * _Nullable SZDateFromPropVariant(const PROPVARIANT &prop);
// Formatted like 7zFM cells (ConvertPropertyToString2)
NSString *SZDisplayStringFromPropVariant(const PROPVARIANT &prop, PROPID propID, int timestampLevel);

// HRESULT -> NSError (nil for S_OK)
NSError * _Nullable SZErrorFromHRESULT(HRESULT hr, NSString * _Nullable engineMessage);
BOOL SZFail(HRESULT hr, NSError * _Nullable * _Nullable error, NSString * _Nullable engineMessage);

// Exception ladder of 02-engine-api.md 4.6: call from inside `catch (...)`; rethrows the
// current exception, classifies it and returns the HRESULT (+ message).
HRESULT SZHandleCurrentException(NSString * _Nullable * _Nullable message);

// Runs `f` (a lambda returning HRESULT) and turns every C++ exception into an HRESULT.
// Never lets an exception reach Objective-C/Swift.
template <class F>
inline HRESULT SZRunCatching(NSString * _Nullable * _Nullable message, F &&f)
{
  if (message)
    *message = nil;
  try
  {
    return f();
  }
  catch (...)
  {
    return SZHandleCurrentException(message);
  }
}

NS_ASSUME_NONNULL_END

#endif

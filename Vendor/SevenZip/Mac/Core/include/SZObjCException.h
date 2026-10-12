// SZObjCException.h -- lets Swift survive an Objective-C exception raised inside a block.
//
// Swift cannot catch an NSException. The app needs to in exactly one place: around
// `NSApp.runModal(for:)` (`DialogKit.runModal`, ai/reports/okcancel.md). An exception
// raised by any event handler inside a dialog's modal loop unwinds `runModal` itself; AppKit then
// catches it further out (the context menu's tracking session, or `-[NSApplication run]`), logs
// it and carries on -- with the dialog still on screen and no modal session, so its OK / Cancel
// (`NSApp.stopModal()`) do nothing.

#ifndef SZ_OBJC_EXCEPTION_H
#define SZ_OBJC_EXCEPTION_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns the Objective-C exception it raised (the stack is unwound to here), or nil.
FOUNDATION_EXPORT NSException *_Nullable SZCatchException(NS_NOESCAPE void (^block)(void));

/// Raises an NSException with `name` and `reason` (for tests: Swift has no `@throw`).
FOUNDATION_EXPORT void SZRaiseException(NSString *name, NSString *reason) NS_SWIFT_NAME(SZRaiseException(name:reason:));

NS_ASSUME_NONNULL_END

#endif

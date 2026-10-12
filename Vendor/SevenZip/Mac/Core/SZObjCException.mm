// SZObjCException.mm -- see SZObjCException.h.

#import "SZObjCException.h"

NSException *SZCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

void SZRaiseException(NSString *name, NSString *reason) {
    @throw [NSException exceptionWithName:name reason:reason userInfo:nil];
}

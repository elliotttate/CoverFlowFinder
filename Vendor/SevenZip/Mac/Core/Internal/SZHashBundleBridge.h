// SZHashBundleBridge.h -- the CHashBundle -> SZHashResults conversion that SZHasher.mm owns,
// shared with SZExtractor.mm so `-scrc` on extract / test produces the same rows the File > CRC
// command shows. That is what Windows does: ExtractGUI.cpp:129-136 fills the same
// CPropNameValPairs with AddHashBundleRes and hands them to ShowHashResults
// (03-shell-integration-inventory.md 2.6).
//
// Objective-C++ only. Include after a header that pulls in HashCalc.h (Internal/SZToolsEngine.h);
// CHashBundle is only forward-declared here so a file that does not need the engine headers can
// still see these declarations.

#ifndef SZ_HASH_BUNDLE_BRIDGE_H
#define SZ_HASH_BUNDLE_BRIDGE_H

#import <Foundation/Foundation.h>
#import "SZHasher.h"

struct CHashBundle;

NS_ASSUME_NONNULL_BEGIN

/// AddHashBundleRes (GUI/HashGUI.cpp:179-254) plus the per-file digests. `leadingRows` are placed
/// before the bundle's own rows, which is how ExtractGUI prepends "Archives:" and "Packed Size".
SZHashResults *SZHashResultsFromBundle(const CHashBundle &bundle,
                                       NSArray<SZHashFileResult *> *_Nullable fileResults,
                                       NSArray<SZHashResultRow *> *_Nullable leadingRows);

/// One name/value row (a CProperty of CPropNameValPairs).
SZHashResultRow *SZMakeHashResultRow(NSString *name, NSString *value);

/// AddSizeValuePair's value: MyFormatNew(IDS_FILE_SIZE 3504, ConvertSizeToString(size)), i.e.
/// "<space-grouped digits> bytes".
NSString *SZHashSizeValueString(uint64_t size);

NS_ASSUME_NONNULL_END

#endif

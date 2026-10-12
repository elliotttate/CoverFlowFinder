// CoverFlowFinder addition, 2026-10-11. LGPL-2.1-or-later; see Vendor/SevenZip/LICENSE.
// Decode to a caller-owned writer. The engine never chooses or writes output paths.
#import <SevenZipKit/SZArchiveOpener.h>

NS_ASSUME_NONNULL_BEGIN
@interface SZArchive (SafeStreams)
/// Raw handler entries, preserving indices and duplicate names. Owned by the archive's serial queue.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)streamEntriesWithLimit:(NSUInteger)limit
                                                                 progress:(nullable id<SZProgressDelegate>)progress
                                                                    error:(NSError **)error
    NS_SWIFT_NAME(streamEntries(limit:progress:));
/// Consumer chunks are bounded to 256 KiB. Returning NO aborts. Success requires a successful
/// per-item result, not just S_OK from Extract. Does not create files, symlinks, or hard links.
- (BOOL)streamItemAtIndex:(uint32_t)index
                maxBytes:(uint64_t)maxBytes
             memoryLimit:(uint64_t)memoryLimit
                progress:(nullable id<SZProgressDelegate>)progress
                consumer:(BOOL (^)(NSData *))consumer
                   error:(NSError **)error
    NS_SWIFT_NAME(streamItem(at:maxBytes:memoryLimit:progress:consumer:));
- (BOOL)testWithMemoryLimit:(uint64_t)memoryLimit
                  progress:(nullable id<SZProgressDelegate>)progress
                     error:(NSError **)error NS_SWIFT_NAME(test(memoryLimit:progress:));
@end
NS_ASSUME_NONNULL_END

// SZCodecs.h -- the format table (CCodecs / g_CodecsObj->Formats).

#ifndef SZ_CODECS_H
#define SZ_CODECS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One archive handler (CArcInfoEx). Flags mirror NArcInfoFlags.
@interface SZFormatInfo : NSObject

@property (nonatomic, readonly) NSInteger index;            ///< index in the engine's format table
@property (nonatomic, readonly, copy) NSString *name;        ///< "7z", "zip", "tar", "gzip", ...
@property (nonatomic, readonly, copy) NSArray<NSString *> *extensions;     ///< lowercase, without dot
@property (nonatomic, readonly, copy) NSArray<NSString *> *addExtensions;  ///< parallel: inner name ext ("tar" for tgz), "" if none
@property (nonatomic, readonly, copy) NSString *mainExtension;
@property (nonatomic, readonly) BOOL updateEnabled;          ///< can create/update archives of this type
@property (nonatomic, readonly) BOOL isHashHandler;          ///< the virtual "hash file" handler
@property (nonatomic, readonly) BOOL keepName;
@property (nonatomic, readonly) BOOL findSignature;
@property (nonatomic, readonly) BOOL supportsAltStreams;
@property (nonatomic, readonly) BOOL supportsNtSecurity;
@property (nonatomic, readonly) BOOL supportsSymLinks;
@property (nonatomic, readonly) BOOL supportsHardLinks;
@property (nonatomic, readonly) BOOL useGlobalOffset;
@property (nonatomic, readonly) BOOL startOpen;
@property (nonatomic, readonly) BOOL backwardOpen;
@property (nonatomic, readonly) BOOL preArc;
@property (nonatomic, readonly) BOOL pureStartOpen;
@property (nonatomic, readonly) BOOL byExtOnlyOpen;
@property (nonatomic, readonly) BOOL supportsCTime;
@property (nonatomic, readonly) BOOL supportsATime;
@property (nonatomic, readonly) BOOL supportsMTime;
@property (nonatomic, readonly) uint32_t flags;               ///< raw NArcInfoFlags
@property (nonatomic, readonly) uint32_t timeFlags;
@property (nonatomic, readonly) NSInteger signatureCount;
/// CArcInfoEx::Signatures and SignatureOffset: the byte strings that identify the format.
@property (nonatomic, readonly, copy) NSArray<NSData *> *signatures;
@property (nonatomic, readonly) NSUInteger signatureOffset;

@end

@interface SZCodecs : NSObject

/// LoadGlobalCodecs(). Idempotent; call once at startup (off the main thread is fine, it is fast).
+ (BOOL)loadCodecs:(NSError **)error NS_SWIFT_NAME(loadCodecs());
@property (class, nonatomic, readonly) BOOL isLoaded;
/// FreeGlobalCodecs(). Only when no archive is open.
+ (void)unload;

/// All formats in engine order (61 handlers + the hash handler in the 7zz build).
@property (class, nonatomic, readonly) NSArray<SZFormatInfo *> *formats;
@property (class, nonatomic, readonly) NSInteger formatCount;
+ (nullable SZFormatInfo *)formatForExtension:(NSString *)extension NS_SWIFT_NAME(format(forExtension:));   ///< CCodecs::FindFormatForExtension
+ (nullable SZFormatInfo *)formatForArchiveName:(NSString *)path NS_SWIFT_NAME(format(forArchiveName:));      ///< CCodecs::FindFormatForArchiveName
+ (nullable SZFormatInfo *)formatNamed:(NSString *)name NS_SWIFT_NAME(format(named:));               ///< CCodecs::FindFormatForArchiveType
/// The formats whose signature matches `header` (the first bytes of a file) at the format's
/// signature offset, in engine order. Lookup by signature, as the open's first pass does it.
+ (NSArray<SZFormatInfo *> *)formatsMatchingHeader:(NSData *)header NS_SWIFT_NAME(formats(matchingHeader:));
/// Every extension of every format, lowercase.
@property (class, nonatomic, readonly) NSSet<NSString *> *allExtensions;

@end

NS_ASSUME_NONNULL_END

#endif

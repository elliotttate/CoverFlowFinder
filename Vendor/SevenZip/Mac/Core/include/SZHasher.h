// SZHasher.h -- checksum calculation over files, folders and archive members, plus the
// checksum-file (`.sha256`-style) writer and verifier.
//
// Wraps the engine's HashCalc (CPP/7zip/UI/Common/HashCalc.{h,cpp}) the way 7zFM does:
//   * file-system items   -> HashCalc() over a NWildcard::CCensor built from the operated
//                           items (what `7zz h` runs; 7zFM's own CThreadCrc is the same
//                           enumeration without the panel coupling, 02-engine-api.md 3.5)
//   * items in an archive -> IFolderOperations::CopyTo in *stream mode* with an
//                           IFolderExtractToStreamCallback that hands the Agent a hashing
//                           stream, so nothing is written to disk (01 3.13, PanelCopy.cpp:239)
//
// Every call BLOCKS and must run off the main thread (drive it with OperationRunner);
// progress, the current file, scan/open errors and cancellation all go through
// id<SZProgressDelegate>.
//
// Parity: 01-fm-feature-inventory.md 2.1, 3.13, 8.6; 01b-fm-dialogs-settings.md 4.27;
// 02-engine-api.md 2.3 (HashCalc.h), 2.5.

#ifndef SZ_HASHER_H
#define SZ_HASHER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZFolder.h>
#import <SevenZipKit/SZProgressDelegate.h>

NS_ASSUME_NONNULL_BEGIN

/// One hasher the loaded codecs expose (IHashers / GetHashMethods), enumerated, never
/// hard-coded. `name` is the engine name that SZHasher takes ("CRC32", "SHA3-256", ...);
/// `menuTitle` is the wording the Windows CRC submenu uses ("CRC-32", "SHA3-256").
@interface SZHashMethod : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *menuTitle;
@property (nonatomic, readonly) NSUInteger digestSize;   ///< IHasher::GetDigestSize, bytes
@end

/// One ordered name/value row of the results dialog (GUI/HashGUI.cpp CPropNameValPairs).
@interface SZHashResultRow : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *value;
@end

/// Per-file digests, in the order the files were hashed (what a checksum file is built from
/// and what `-scrc` shows for each extracted item).
@interface SZHashFileResult : NSObject
@property (nonatomic, readonly) NSString *path;       ///< path as reported to the callback
@property (nonatomic, readonly) uint64_t size;
@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) BOOL isAlternateStream;
/// engine method name -> digest hex (HashHexToString: upper case + reversed bytes for
/// digests <= 8 bytes, lower case big-endian above that).
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *digests;
@end

/// Everything CHashBundle ends up holding, in the exact presentation order 7zG builds.
@interface SZHashResults : NSObject

/// AddHashBundleRes(CPropNameValPairs&, hb): Errors (only when > 0), Name (single file) or
/// Name + Folders (> 0) + Files, Size, Alternate Streams (+ size) when > 0, then per method
/// either "<Method>" = hex (one file, no folders) or "<Method> checksum for data" and
/// "<Method> checksum for data and names", plus "... for streams and names" with alt streams.
@property (nonatomic, readonly) NSArray<SZHashResultRow *> *rows;
/// AddHashBundleRes(UString&, hb): the same rows as "name: value" lines, plus
/// IDS_MESSAGE_NO_ERRORS "There are no errors" when there were neither errors nor hashers.
@property (nonatomic, readonly) NSString *text;
/// "<name>: <value>" for the rows the user selected -- what Ctrl+C copies.
- (NSString *)clipboardTextForRowsAtIndexes:(NSIndexSet *)indexes
    NS_SWIFT_NAME(clipboardText(forRowsAt:));

@property (nonatomic, readonly) uint64_t numFolders;      ///< CHashBundle::NumDirs
@property (nonatomic, readonly) uint64_t numFiles;
@property (nonatomic, readonly) uint64_t numAlternateStreams;
@property (nonatomic, readonly) uint64_t filesSize;
@property (nonatomic, readonly) uint64_t alternateStreamsSize;
@property (nonatomic, readonly) uint64_t numErrors;
/// CHashBundle::MainName (the single operated item) and FirstFileName (first file hashed).
@property (nonatomic, readonly) NSString *mainName;
@property (nonatomic, readonly) NSString *firstFileName;

/// The methods that ran, in engine order.
@property (nonatomic, readonly) NSArray<NSString *> *methodNames;
/// k_HashCalc_Index_DataSum: for a single file this is that file's digest.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *dataDigests;
/// k_HashCalc_Index_NamesSum.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *dataAndNamesDigests;
/// k_HashCalc_Index_StreamsSum.
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *streamsAndNamesDigests;
/// Per file, in hashing order.
@property (nonatomic, readonly) NSArray<SZHashFileResult *> *fileResults;
@end

/// Result of testing a checksum file (`t -thash`, "Test archive : Checksum").
@interface SZChecksumVerification : NSObject
@property (nonatomic, readonly) NSUInteger numOK;
@property (nonatomic, readonly) NSUInteger numFailed;         ///< digest mismatch
@property (nonatomic, readonly) NSUInteger numMissing;        ///< listed file not found
@property (nonatomic, readonly) NSUInteger numUnsupported;    ///< line not understood
@property (nonatomic, readonly) NSArray<NSString *> *messages;///< "<name> : <reason>" lines
@property (nonatomic, readonly) NSArray<NSString *> *methodNames;
/// Message-box text: the counters, then IDS_MESSAGE_NO_ERRORS when nothing failed.
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) BOOL succeeded;
@end

@interface SZHasher : NSObject

#pragma mark Methods

/// Every hasher the loaded codecs expose, in engine order (GetHashMethods + CreateHasher).
/// Loads the codecs if needed.
@property (class, nonatomic, readonly) NSArray<SZHashMethod *> *availableMethods;
/// The engine name for a CRC-submenu resource id (IDM_CRC32 102 ... IDM_BLAKE2SP 121,
/// IDM_HASH_ALL 101 -> "*"); nil for anything else.
+ (nullable NSString *)methodNameForMenuID:(NSInteger)menuID;
/// "*" (all methods) or one engine method name; returns NO when no hasher matches.
+ (BOOL)isMethodSupported:(NSString *)method;

#pragma mark Hashing

/// HashCalc() over file-system paths. `paths` are absolute, or relative to `basePath`
/// (the panel folder), which is also what the reported names are relative to -- so the
/// "data and names" sums match 7zFM's. `recursive` = !flatMode (CDirEnumerator::EnterToDirs).
/// `methods` may be @[@"*"] for every method; an empty array means CRC32 (the engine default).
+ (nullable SZHashResults *)hashPaths:(NSArray<NSString *> *)paths
                       relativeToPath:(nullable NSString *)basePath
                              methods:(NSArray<NSString *> *)methods
                            recursive:(BOOL)recursive
                             progress:(nullable id<SZProgressDelegate>)progress
                                error:(NSError **)error
    NS_SWIFT_NAME(hash(paths:relativeTo:methods:recursive:progress:));

/// Hashes items *inside* an archive folder without extracting them: CopyTo in stream mode
/// with hash methods (01 3.13). `indexes` nil / empty takes every item of the folder.
/// The folder must be used from this thread only (engine refcounts are not atomic).
+ (nullable SZHashResults *)hashItemsInFolder:(SZFolder *)folder
                                    atIndexes:(nullable NSArray<NSNumber *> *)indexes
                                      methods:(NSArray<NSString *> *)methods
                                     progress:(nullable id<SZProgressDelegate>)progress
                                        error:(NSError **)error
    NS_SWIFT_NAME(hash(itemsIn:at:methods:progress:));

#pragma mark Checksum files

/// `<hname>.sha256`: the name `a -thash -sae` would pick (CreateArchiveName with isHash),
/// i.e. `<single item name>.<lowercased method>` or `<folder name>.<method>`.
+ (NSString *)checksumFileNameForPaths:(NSArray<NSString *> *)paths
                        relativeToPath:(nullable NSString *)basePath
                                method:(NSString *)method;

/// Writes a GNU-coreutils-style checksum file (`<hex>  <name>` per line, LF), which is
/// exactly what the hash pseudo-format writes for a plain `-thash` update.
+ (BOOL)writeChecksumFileAtPath:(NSString *)destinationPath
                       forPaths:(NSArray<NSString *> *)paths
                 relativeToPath:(nullable NSString *)basePath
                         method:(NSString *)method
                      recursive:(BOOL)recursive
                       progress:(nullable id<SZProgressDelegate>)progress
                          error:(NSError **)error
    NS_SWIFT_NAME(writeChecksumFile(at:forPaths:relativeTo:method:recursive:progress:));

/// Verifies a checksum file: every listed file is hashed with the method the file (or its
/// extension, or the digest length) names and compared. Relative names resolve against the
/// checksum file's own directory.
+ (nullable SZChecksumVerification *)verifyChecksumFileAtPath:(NSString *)path
                                                     progress:(nullable id<SZProgressDelegate>)progress
                                                        error:(NSError **)error
    NS_SWIFT_NAME(verifyChecksumFile(at:progress:));

@end

NS_ASSUME_NONNULL_END

#endif

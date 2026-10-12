// SZStreamTar.h -- list the tar inside a single-stream compressed file (x.tar.gz, .tgz, .tar.bz2,
// .tar.xz, .tar.zst, .tar.lzma, .tar.Z) by reading the decompressed stream sequentially, without
// writing anything anywhere (quicklook scope).
//
// 7zFM opens such a file as two levels only when the inner stream is seekable (CArchiveLink::Open
// needs IInStream for the sub-archive); for gzip / bzip2 / zstd it shows the one ".tar" item and
// opens it from a temp copy (01 §3.9, PanelItemOpen.cpp). A Quick Look preview may not write a
// temp copy, so this reads the tar the way `7z x -si -ttar` does: the outer handler decompresses
// into an in-memory pipe (CStreamBinder) on a worker thread while the tar handler, opened with
// IArchiveOpenSeq::OpenSeq, reads its headers from the pipe and skips the file data. Memory is
// bounded by the pipe (the decoder's own buffer); time by `checkBreak`, which both threads poll.

#ifndef SZ_STREAM_TAR_H
#define SZ_STREAM_TAR_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZTypes.h>

NS_ASSUME_NONNULL_BEGIN

/// One tar entry as the tar handler reports it.
@interface SZStreamTarEntry : NSObject
/// kpidPath with '/' separators ("sub/deep/inner.txt"; a folder without its trailing slash).
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) BOOL isDirectory;
/// kpidSize.
@property (nonatomic, readonly) uint64_t size;
/// kpidMTime.
@property (nonatomic, readonly, nullable) NSDate *modified;
/// kpidMTime as the list shows it (ConvertPropertyToString2 at the requested level).
@property (nonatomic, readonly, copy) NSString *modifiedText;
@end

@interface SZStreamTar : NSObject

/// Lists the tar inside the file at `path`, whose outer format is `outerFormat` (an engine handler
/// name: "gzip", "bzip2", "xz", "zstd", "lzma", "Z"). `entry` receives each entry in archive order
/// and returns NO to stop; `checkBreak` is polled by both threads and returns YES to stop.
/// Returns YES when at least the stream could be read as tar (stopping early included); NO with
/// an error when the outer file cannot be opened or the inner stream is not a tar.
/// BLOCKS; call off the main thread.
+ (BOOL)listTarInsideFileAtPath:(NSString *)path
                    outerFormat:(NSString *)outerFormat
                 timestampLevel:(SZTimestampLevel)level
                     checkBreak:(BOOL (^)(void))checkBreak
                          entry:(BOOL (NS_NOESCAPE ^)(SZStreamTarEntry *entry))entry
                          error:(NSError **)error
    NS_SWIFT_NAME(listTarInsideFile(atPath:outerFormat:timestampLevel:checkBreak:entry:));

@end

NS_ASSUME_NONNULL_END

#endif

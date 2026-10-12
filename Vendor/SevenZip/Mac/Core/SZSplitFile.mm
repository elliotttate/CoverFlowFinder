// SZSplitFile.mm -- see SZSplitFile.h. CThreadSplit / CThreadCombine and SplitUtils.cpp
// ported to POSIX file I/O.

#import "SZSplitFile.h"
#import "SZError.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const uint32_t kSplitBufferSize = 1 << 20;   // PanelSplitFile.cpp:139

NSArray<NSString *> *SZSplitVolumePresets(void)
{
    // SplitUtils.cpp:62-73 k_Sizes
    return @[ @"10M", @"100M", @"1000M", @"650M - CD", @"700M - CD",
              @"4092M - FAT", @"4480M - DVD", @"8128M - DVD DL", @"23040M - BD" ];
}

// ---------------------------------------------------------------------------
#pragma mark - helpers

static NSError *SZPosixError(int code, NSString *path)
{
    NSString *text = [NSString stringWithUTF8String:strerror(code)] ?: @"I/O error";
    if (path.length != 0)
        text = [NSString stringWithFormat:@"%@ : %@", text, path];
    return [SZErrors errorWithCode:SZErrorCodeEngine message:text];
}

static NSError *SZCancelledError(void)
{
    return [SZErrors errorWithCode:SZErrorCodeCancelled message:@"cancelled"];
}

static BOOL SZCheckBreak(id<SZProgressDelegate> progress)
{
    return progress != nil && [progress progressCheckBreak];
}

/// CVolSeqName: the "000" counter, widened so that `numVolumes` fits.
@interface SZVolSeqName : NSObject
@property (nonatomic, copy) NSString *unchangedPart;
@property (nonatomic, copy) NSString *changedPart;
@end

@implementation SZVolSeqName

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _unchangedPart = @"";
        _changedPart = @"000";
    }
    return self;
}

- (void)setNumberOfDigitsForVolumes:(uint64_t)numVolumes
{
    NSMutableString *s = [NSMutableString stringWithString:@"000"];
    while (numVolumes > 999)
    {
        numVolumes /= 10;
        [s appendString:@"0"];
    }
    _changedPart = s;
}

/// CVolSeqName::GetNextName (PanelSplitFile.cpp:63-78)
- (NSString *)nextName
{
    NSMutableString *changed = [NSMutableString stringWithString:_changedPart];
    for (NSInteger i = (NSInteger)changed.length - 1; i >= 0; i--)
    {
        const unichar c = [changed characterAtIndex:(NSUInteger)i];
        if (c != '9')
        {
            [changed replaceCharactersInRange:NSMakeRange((NSUInteger)i, 1)
                                   withString:[NSString stringWithFormat:@"%C", (unichar)(c + 1)]];
            break;
        }
        [changed replaceCharactersInRange:NSMakeRange((NSUInteger)i, 1) withString:@"0"];
        if (i == 0)
            [changed insertString:@"1" atIndex:0];
    }
    _changedPart = changed;
    return [_unchangedPart stringByAppendingString:changed];
}

@end

// ---------------------------------------------------------------------------

@implementation SZSplitFile

+ (nullable NSArray<NSNumber *> *)parseVolumeSizes:(NSString *)text
{
    // ParseVolumeSizes (SplitUtils.cpp:9-58)
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    BOOL prevIsNumber = NO;
    const NSUInteger len = text.length;
    NSUInteger i = 0;
    while (i < len)
    {
        const unichar c = [text characterAtIndex:i++];
        if (c == ' ')
            continue;
        if (c == '-')
            break;                          // the display suffix after "-" is ignored
        if (prevIsNumber)
        {
            prevIsNumber = NO;
            unsigned numBits = 0;
            switch (tolower((int)c))
            {
                case 'b': continue;
                case 'k': numBits = 10; break;
                case 'm': numBits = 20; break;
                case 'g': numBits = 30; break;
                case 't': numBits = 40; break;
                default: break;
            }
            if (numBits != 0)
            {
                uint64_t val = values.lastObject.unsignedLongLongValue;
                if (val >= ((uint64_t)1 << (64 - numBits)))
                    return nil;             // overflow
                val <<= numBits;
                values[values.count - 1] = @(val);
                for (; i < len; i++)
                    if ([text characterAtIndex:i] == ' ')
                        break;
                continue;
            }
        }
        i--;
        uint64_t val = 0;
        NSUInteger start = i;
        while (i < len)
        {
            const unichar d = [text characterAtIndex:i];
            if (d < '0' || d > '9')
                break;
            if (val > (UINT64_MAX - (uint64_t)(d - '0')) / 10)
                return nil;
            val = val * 10 + (uint64_t)(d - '0');
            i++;
        }
        if (i == start)
            return nil;
        if (val == 0)
            return nil;
        [values addObject:@(val)];
        prevIsNumber = YES;
    }
    return values.count != 0 ? values : nil;
}

+ (uint64_t)numberOfVolumesForSize:(uint64_t)size volumeSizes:(NSArray<NSNumber *> *)volumeSizes
{
    // GetNumberOfVolumes (SplitUtils.cpp:83-98)
    if (size == 0 || volumeSizes.count == 0)
        return 1;
    uint64_t rest = size;
    for (NSUInteger i = 0; i < volumeSizes.count; i++)
    {
        const uint64_t volSize = volumeSizes[i].unsignedLongLongValue;
        if (volSize >= rest)
            return i + 1;
        rest -= volSize;
    }
    const uint64_t volSize = volumeSizes.lastObject.unsignedLongLongValue;
    if (volSize == 0)
        return NSNotFound;
    return volumeSizes.count + (rest - 1) / volSize + 1;
}

+ (BOOL)splitFileAtPath:(NSString *)filePath
         volumeBasePath:(NSString *)volumeBasePath
            volumeSizes:(NSArray<NSNumber *> *)volumeSizes
               progress:(nullable id<SZProgressDelegate>)progress
                  error:(NSError **)error
{
    if (volumeSizes.count == 0)
    {
        if (error)
            *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"No volume size"];
        return NO;
    }

    const int in = open(filePath.fileSystemRepresentation, O_RDONLY);
    if (in < 0)
    {
        if (error)
            *error = SZPosixError(errno, filePath);
        return NO;
    }

    struct stat st;
    if (fstat(in, &st) != 0)
    {
        const int e = errno;
        close(in);
        if (error)
            *error = SZPosixError(e, filePath);
        return NO;
    }
    const uint64_t length = (uint64_t)st.st_size;
    const uint64_t numVolumes = [self numberOfVolumesForSize:length volumeSizes:volumeSizes];

    if (progress)
    {
        [progress progressSetTotal:length];
        if ([progress respondsToSelector:@selector(progressSetStatus:)])
            [progress progressSetStatus:(SZProgressStatus)7303];   // IDS_SPLITTING
    }

    SZVolSeqName *seq = [SZVolSeqName new];
    [seq setNumberOfDigitsForVolumes:numVolumes == NSNotFound ? 1000 : numVolumes];

    void *buffer = malloc(kSplitBufferSize);
    if (!buffer)
    {
        close(in);
        if (error)
            *error = [SZErrors errorWithCode:SZErrorCodeOutOfMemory message:@"Cannot allocate the split buffer"];
        return NO;
    }

    int out = -1;
    NSString *outPath = nil;
    uint64_t written = 0, pos = 0, prev = 0, numFiles = 0;
    NSUInteger volIndex = 0;
    BOOL ok = YES;
    NSError *failure = nil;

    for (;;)
    {
        if (SZCheckBreak(progress))
        {
            failure = SZCancelledError();
            ok = NO;
            break;
        }
        const uint64_t volSize = (volIndex < volumeSizes.count ? volumeSizes[volIndex]
                                                               : volumeSizes.lastObject).unsignedLongLongValue;
        uint32_t needSize = kSplitBufferSize;
        const uint64_t rem = volSize - written;
        if (needSize > rem)
            needSize = (uint32_t)rem;

        const ssize_t got = read(in, buffer, needSize);
        if (got < 0)
        {
            failure = SZPosixError(errno, filePath);
            ok = NO;
            break;
        }
        if (got == 0)
            break;                          // done

        if (written == 0)
        {
            outPath = [volumeBasePath stringByAppendingFormat:@".%@", [seq nextName]];
            if (progress)
                [progress progressSetCurrentFile:outPath isDirectory:NO];
            out = open(outPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0666);
            if (out < 0)
            {
                failure = SZPosixError(errno, outPath);
                ok = NO;
                break;
            }
            // CPreAllocOutFile::PreAlloc: reserve the volume, shrink it at Close.
            uint64_t expect = volSize;
            if (pos < length && expect > length - pos)
                expect = length - pos;
            (void)ftruncate(out, (off_t)expect);
            (void)lseek(out, 0, SEEK_SET);
        }

        ssize_t put = write(out, buffer, (size_t)got);
        if (put < 0)
        {
            failure = SZPosixError(errno, outPath);
            ok = NO;
            break;
        }
        if (put != got)
        {
            failure = [SZErrors errorWithCode:SZErrorCodeEngine message:@"File write error"];
            ok = NO;
            break;
        }
        written += (uint64_t)put;
        pos += (uint64_t)put;

        if (written == volSize)
        {
            (void)ftruncate(out, (off_t)written);
            close(out);
            out = -1;
            written = 0;
            numFiles++;
            if (progress)
                [progress progressSetNumFilesProcessed:numFiles];
            if (volIndex < volumeSizes.count)
                volIndex++;
        }

        if (pos - prev >= ((uint64_t)1 << 22) || written == 0)
        {
            if (progress)
                [progress progressSetCompleted:pos];
            prev = pos;
        }
    }

    if (out >= 0)
    {
        (void)ftruncate(out, (off_t)written);
        close(out);
        if (ok && written != 0)
        {
            numFiles++;
            if (progress)
                [progress progressSetNumFilesProcessed:numFiles];
        }
    }
    free(buffer);
    close(in);
    if (progress && ok)
        [progress progressSetCompleted:pos];

    if (!ok)
    {
        // CThreadSplit leaves the volumes that were already written on disk.
        if (progress && failure && failure.code != SZErrorCodeCancelled)
            [progress progressShowMessage:failure.localizedDescription];
        if (error)
            *error = failure;
        return NO;
    }
    return YES;
}

+ (BOOL)parseFirstVolumeName:(NSString *)name
               unchangedPart:(NSString * _Nullable * _Nullable)unchangedPart
{
    // CVolSeqName::ParseName (PanelSplitFile.cpp:45-58)
    if (name.length < 2)
        return NO;
    if ([name characterAtIndex:name.length - 1] != '1')
        return NO;
    if ([name characterAtIndex:name.length - 2] != '0')
        return NO;
    NSUInteger pos = name.length - 2;
    while (pos > 0 && [name characterAtIndex:pos - 1] == '0')
        pos--;
    if (unchangedPart)
        *unchangedPart = [name substringToIndex:pos];
    return YES;
}

+ (NSArray<NSString *> *)volumeNamesForFirstVolume:(NSString *)firstName
                                       inDirectory:(NSString *)directory
{
    NSString *unchanged = nil;
    if (![self parseFirstVolumeName:firstName unchangedPart:&unchanged])
        return @[];
    SZVolSeqName *seq = [SZVolSeqName new];
    seq.unchangedPart = unchanged ?: @"";
    seq.changedPart = [firstName substringFromIndex:(unchanged ?: @"").length];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSString *next = firstName;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (;;)
    {
        NSString *full = [directory stringByAppendingPathComponent:next];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&isDir] || isDir)
            break;
        [names addObject:next];
        next = [seq nextName];
    }
    return names;
}

+ (NSString *)combinedNameForFirstVolume:(NSString *)firstName
{
    NSString *unchanged = nil;
    if (![self parseFirstVolumeName:firstName unchangedPart:&unchanged])
        unchanged = firstName;
    NSMutableString *out = [NSMutableString stringWithString:unchanged ?: @""];
    while (out.length != 0 && [out characterAtIndex:out.length - 1] == '.')
        [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    if (out.length == 0)
        return @"file";
    return out;
}

+ (BOOL)combineVolumes:(NSArray<NSString *> *)names
           inDirectory:(NSString *)directory
        toFileAtPath:(NSString *)destinationPath
              progress:(nullable id<SZProgressDelegate>)progress
                 error:(NSError **)error
{
    const int out = open(destinationPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0666);
    if (out < 0)
    {
        if (error)
            *error = SZPosixError(errno, destinationPath);
        return NO;
    }

    uint64_t total = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in names)
    {
        NSDictionary *attrs = [fm attributesOfItemAtPath:[directory stringByAppendingPathComponent:name] error:nil];
        total += [attrs[NSFileSize] unsignedLongLongValue];
    }
    if (progress)
    {
        [progress progressSetTotal:total];
        if ([progress respondsToSelector:@selector(progressSetStatus:)])
            [progress progressSetStatus:(SZProgressStatus)7402];   // IDS_COMBINING
        if ([progress respondsToSelector:@selector(progressSetTotalFiles:)])
            [progress progressSetTotalFiles:names.count];
    }

    void *buffer = malloc(kSplitBufferSize);
    if (!buffer)
    {
        close(out);
        if (error)
            *error = [SZErrors errorWithCode:SZErrorCodeOutOfMemory message:@"Cannot allocate the combine buffer"];
        return NO;
    }

    uint64_t pos = 0;
    uint64_t done = 0;
    NSError *failure = nil;
    for (NSString *name in names)
    {
        NSString *full = [directory stringByAppendingPathComponent:name];
        const int in = open(full.fileSystemRepresentation, O_RDONLY);
        if (in < 0)
        {
            failure = SZPosixError(errno, full);
            break;
        }
        if (progress)
            [progress progressSetCurrentFile:full isDirectory:NO];
        for (;;)
        {
            if (SZCheckBreak(progress))
            {
                failure = SZCancelledError();
                break;
            }
            const ssize_t got = read(in, buffer, kSplitBufferSize);
            if (got < 0)
            {
                failure = SZPosixError(errno, full);
                break;
            }
            if (got == 0)
                break;
            const ssize_t put = write(out, buffer, (size_t)got);
            if (put < 0)
            {
                failure = SZPosixError(errno, destinationPath);
                break;
            }
            if (put != got)
            {
                failure = [SZErrors errorWithCode:SZErrorCodeEngine message:@"File write error"];
                break;
            }
            pos += (uint64_t)put;
            if (progress)
                [progress progressSetCompleted:pos];
        }
        close(in);
        if (failure)
            break;
        done++;
        if (progress)
            [progress progressSetNumFilesProcessed:done];
    }

    free(buffer);
    close(out);
    if (failure)
    {
        if (error)
            *error = failure;
        return NO;
    }
    return YES;
}

@end

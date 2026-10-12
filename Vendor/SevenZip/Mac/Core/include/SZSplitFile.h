// SZSplitFile.h -- File > Split file / Combine files (IDM_SPLIT 549, IDM_COMBINE 550).
//
// The engine has no split/combine coder: 7zFM does it with plain file I/O in
// CThreadSplit / CThreadCombine (FileManager/PanelSplitFile.cpp:80-137, :345-411) plus
// ParseVolumeSizes / GetNumberOfVolumes (SplitUtils.cpp). This is the same code with the
// same buffer size, volume naming, pre-allocation and progress, reported through
// id<SZProgressDelegate> so the shared Progress dialog drives it.
//
// Both calls BLOCK and must run off the main thread.
//
// Parity: 01-fm-feature-inventory.md 3.14; 01b-fm-dialogs-settings.md 4.20.

#ifndef SZ_SPLIT_FILE_H
#define SZ_SPLIT_FILE_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZProgressDelegate.h>

NS_ASSUME_NONNULL_BEGIN

/// The volume presets of the Split dialog's combo (SplitUtils.cpp k_Sizes), in order;
/// the first one is selected. The text after " - " is a label ParseVolumeSizes ignores.
FOUNDATION_EXPORT NSArray<NSString *> *SZSplitVolumePresets(void);

@interface SZSplitFile : NSObject

/// ParseVolumeSizes (SplitUtils.cpp:9-58): a space-separated list of `<number>[b|k|m|g|t]`
/// (1024-based, case-insensitive). A `-` ends parsing, so "650M - CD" yields 650 MiB.
/// Returns nil when the text does not parse or yields no size.
+ (nullable NSArray<NSNumber *> *)parseVolumeSizes:(NSString *)text
    NS_SWIFT_NAME(parseVolumeSizes(_:));

/// GetNumberOfVolumes(size, volSizes); `0` sizes give NSNotFound.
+ (uint64_t)numberOfVolumesForSize:(uint64_t)size volumeSizes:(NSArray<NSNumber *> *)volumeSizes
    NS_SWIFT_NAME(numberOfVolumes(forSize:volumeSizes:));

/// Writes `<volumeBasePath>.001`, `.002`, … (CVolSeqName, at least 3 digits, growing).
/// `volumeSizes` are used in order, the last one repeating. 1 MiB buffer, each volume
/// pre-allocated then truncated, progress in bytes with the volume path as current file.
+ (BOOL)splitFileAtPath:(NSString *)filePath
         volumeBasePath:(NSString *)volumeBasePath
            volumeSizes:(NSArray<NSNumber *> *)volumeSizes
               progress:(nullable id<SZProgressDelegate>)progress
                  error:(NSError **)error
    NS_SWIFT_NAME(split(at:volumeBasePath:volumeSizes:progress:));

/// CVolSeqName::ParseName: YES when `name` ends in `0…01` (digits only, value 1), i.e. it
/// is the first volume of a series. `unchangedPart` receives the name without the number.
+ (BOOL)parseFirstVolumeName:(NSString *)name
               unchangedPart:(NSString * _Nullable * _Nullable)unchangedPart
    NS_SWIFT_NAME(parseFirstVolumeName(_:unchangedPart:));

/// The consecutive volumes of the series starting at `firstName` inside `directory`, in
/// order, stopping at the first gap (CApp::Combine, PanelSplitFile.cpp:455-470).
+ (NSArray<NSString *> *)volumeNamesForFirstVolume:(NSString *)firstName
                                       inDirectory:(NSString *)directory
    NS_SWIFT_NAME(volumeNames(forFirstVolume:in:));

/// The output name Combine proposes: the first volume's name without the numeric extension,
/// trailing dots trimmed, "file" when nothing is left.
+ (NSString *)combinedNameForFirstVolume:(NSString *)firstName
    NS_SWIFT_NAME(combinedName(forFirstVolume:));

/// Concatenates `names` (relative to `directory`) into `destinationPath`, which must not
/// exist. 1 MiB buffer, progress in bytes.
+ (BOOL)combineVolumes:(NSArray<NSString *> *)names
           inDirectory:(NSString *)directory
        toFileAtPath:(NSString *)destinationPath
              progress:(nullable id<SZProgressDelegate>)progress
                 error:(NSError **)error
    NS_SWIFT_NAME(combine(_:in:to:progress:));

@end

NS_ASSUME_NONNULL_END

#endif

// SZBenchmark.h -- the engine benchmark (CPP/7zip/UI/Common/Bench.{h,cpp}) behind a
// delegate-driven Objective-C object, plus the CPU / OS / memory strings the Benchmark
// dialog shows.
//
// 7zFM spawns `7zG b` for Tools > Benchmark; the macOS port runs it in-process
// (01-fm-feature-inventory.md 2.5, 8.1, 9 #1). SZBenchmark owns the worker thread and is
// the exact equivalent of BenchmarkDialog.cpp's CThreadBenchmark + CBenchProgressSync:
// one Bench() call per pass, results pushed to the delegate as they arrive.
//
// Parity: 01b-fm-dialogs-settings.md 4.26; 02-engine-api.md 2.3 (Bench.h), 4.4.

#ifndef SZ_BENCHMARK_H
#define SZ_BENCHMARK_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One CTotalBenchRes2 snapshot, already divided by NumIterations2 and converted the way
/// PrintBenchRes (BenchmarkDialog.cpp:1139-1170) does.
@interface SZBenchmarkResult : NSObject
@property (nonatomic, readonly) BOOL isDefined;      ///< NO while the field shows "..."
@property (nonatomic, readonly) uint64_t speed;      ///< bytes/s
@property (nonatomic, readonly) uint64_t rating;     ///< ips
@property (nonatomic, readonly) uint64_t ratingPerUsage;
@property (nonatomic, readonly) uint64_t usage;      ///< raw usage; percents = usagePercent
@property (nonatomic, readonly) uint64_t unpackSize; ///< total bytes of the pass
/// Benchmark_GetUsage_Percents(usage)
@property (nonatomic, readonly) uint64_t usagePercent;
/// (rating + 500000) / 1000000, i.e. the MIPS value printed as "<n>.<mmm> GIPS"
@property (nonatomic, readonly) uint64_t ratingMIPS;
@property (nonatomic, readonly) uint64_t ratingPerUsageMIPS;
/// "12.345 GIPS" / "1 234 KB/s" style strings, exactly as the dialog prints them.
@property (nonatomic, readonly) NSString *speedString;      ///< "<n> KB/s"
@property (nonatomic, readonly) NSString *ratingString;     ///< "<n>.<mmm> GIPS"
@property (nonatomic, readonly) NSString *ratingPerUsageString;
@property (nonatomic, readonly) NSString *usageString;      ///< "<n>%"
@property (nonatomic, readonly) NSString *sizeString;       ///< "<n> MB" / "<n> GB"
@end

/// One finished pass: the compressing and decompressing results of that iteration.
@interface SZBenchmarkPass : NSObject
@property (nonatomic, readonly) SZBenchmarkResult *encode;
@property (nonatomic, readonly) SZBenchmarkResult *decode;
/// "Compr Decompr Total   CPU" line of the log (AddRatingsLine, :1091-1121).
@property (nonatomic, readonly) NSString *logLine;
@end

@protocol SZBenchmarkDelegate <NSObject>
/// Something changed; read the snapshot properties. Called on the worker thread (or one of
/// Bench()'s own threads), so marshal to the main thread yourself.
- (void)benchmarkDidUpdate;
/// The worker thread has ended. `error` is nil on a clean stop / finish. After this the
/// object may be started again.
- (void)benchmarkDidFinishWithError:(nullable NSError *)error
    NS_SWIFT_NAME(benchmarkDidFinish(error:));
@optional
/// CFreqCallback: one measured CPU frequency line.
- (void)benchmarkDidAddFrequencyLine:(NSString *)line;
/// IBenchPrintCallback::Print in `-mm=*` total mode (console-style text).
- (void)benchmarkDidPrintText:(NSString *)text;
@end

@interface SZBenchmark : NSObject

/// -md: dictionary size in bytes. Must be set before `start`.
@property (nonatomic) uint64_t dictionarySize;
/// -mmt: worker threads.
@property (nonatomic) uint32_t numberOfThreads;
/// -mm pass limit: the worker stops after this many passes.
@property (nonatomic) uint32_t numberOfPasses;
/// `-mm=*` total mode: Bench() prints every method as text instead of reporting results.
@property (nonatomic) BOOL totalMode;
/// -mx level, or -1 for the default (used only for the memory estimate).
@property (nonatomic) int level;

@property (nonatomic, weak, nullable) id<SZBenchmarkDelegate> delegate;

#pragma mark Snapshot (safe to read from any thread)

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) uint32_t passesFinished;
@property (nonatomic, readonly) BOOL didFinishAllPasses;
@property (nonatomic, readonly) SZBenchmarkResult *currentEncode;     ///< "Current" row
@property (nonatomic, readonly) SZBenchmarkResult *resultingEncode;   ///< "Resulting" row
@property (nonatomic, readonly) SZBenchmarkResult *currentDecode;
@property (nonatomic, readonly) SZBenchmarkResult *resultingDecode;
/// Encode + decode combined; only meaningful once didFinishAllPasses.
@property (nonatomic, readonly) SZBenchmarkResult *totalRating;
/// Up to kRatingVector_NumBundlesMax (20) passes; older ones are dropped.
@property (nonatomic, readonly) NSArray<SZBenchmarkPass *> *passes;
/// YES when older passes were dropped, so the log prints "..." before the kept ones.
@property (nonatomic, readonly) NSInteger droppedPassIndex;
/// The frequency lines collected by IBenchFreqCallback, joined with newlines.
@property (nonatomic, readonly) NSString *frequencyText;
/// Total-mode console text collected so far.
@property (nonatomic, readonly) NSString *totalModeText;
/// The full IDT_BENCH_LOG text: frequency lines, the header, one line per pass, "..." for
/// dropped passes, then "-------------" and the averages once finished.
@property (nonatomic, readonly) NSString *logText;

#pragma mark Control

/// Starts the worker thread. Returns NO (with `error`) when a thread cannot be created.
- (BOOL)start:(NSError **)error;
/// CBenchProgressSync::SendExit: asks the worker to leave at the next callback. The delegate
/// gets benchmarkDidFinishWithError: once the thread has really ended.
- (void)requestStop;
/// Blocks until the worker thread has ended (Cancel must not close before that).
- (void)waitUntilFinished;

#pragma mark Static information

/// GetBenchMemoryUsage(numThreads, level, dictionary, totalBench)
+ (uint64_t)memoryUsageForThreads:(uint32_t)threads level:(int)level
                       dictionary:(uint64_t)dictionary totalMode:(BOOL)totalMode;
/// NSystem::GetRamSize; 0 when unknown.
@property (class, nonatomic, readonly) uint64_t ramSize;
/// RamSize / 16 * 15 (BenchmarkDialog.cpp:565)
@property (class, nonatomic, readonly) uint64_t ramSizeLimit;
/// IsMemoryUsageOK: usage + 1 MB <= ramSizeLimit
+ (BOOL)isMemoryUsageOK:(uint64_t)usage;
/// kMinDicSize 256 KB .. kMaxDicSize 4 GB (64-bit)
@property (class, nonatomic, readonly) uint64_t minimumDictionarySize;
@property (class, nonatomic, readonly) uint64_t maximumDictionarySize;
/// kBenchMinDicLogSize (18)
@property (class, nonatomic, readonly) NSUInteger minimumDictionaryLog;

/// Threads available to this process / to the system (Get_and_return_NumProcessThreads_and_SysThreads).
@property (class, nonatomic, readonly) uint32_t processThreadCount;
@property (class, nonatomic, readonly) uint32_t systemThreadCount;
/// "/ <process threads>" + GetProcessThreadsInfo(affinity) -- IDT_BENCH_HARDWARE_THREADS 104.
@property (class, nonatomic, readonly) NSString *hardwareThreadsText;
/// GetCpuName_MultiLine -- IDT_BENCH_CPU 106.
@property (class, nonatomic, readonly) NSString *cpuName;
/// GetOsInfoText + " : " + AddCpuFeatures -- IDT_BENCH_CPU_FEATURE 109.
@property (class, nonatomic, readonly) NSString *cpuFeaturesText;
/// GetSysInfo -- IDT_BENCH_SYS1 107 / IDT_BENCH_SYS2 108. **Both are empty on macOS**:
/// upstream GetSysInfo (Windows/SystemInfo.cpp:490-520) only fills them under _WIN32. The
/// Darwin version and the page size are part of cpuFeaturesText instead.
@property (class, nonatomic, readonly) NSString *systemInfoLine1;
@property (class, nonatomic, readonly) NSString *systemInfoLine2;
/// "7-Zip " MY_VERSION_CPU -- IDT_BENCH_VER 105, and also what About shows.
@property (class, nonatomic, readonly) NSString *versionWithCPUText;
/// MY_DATE, for the About dialog's date line (IDT_ABOUT_DATE 102).
@property (class, nonatomic, readonly) NSString *engineDateText;
/// MY_COPYRIGHT with USE_COPYRIGHT_CR, i.e. "Copyright (c) 1999-2026 Igor Pavlov" -- the
/// static LTEXT of IDD_ABOUT. (SZEngineCopyrightString() is built without USE_COPYRIGHT_CR
/// and therefore reads "Igor Pavlov : Public domain : <date>".)
@property (class, nonatomic, readonly) NSString *engineCopyrightText;

@end

NS_ASSUME_NONNULL_END

#endif

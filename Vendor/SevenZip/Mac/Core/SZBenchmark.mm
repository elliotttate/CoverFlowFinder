// SZBenchmark.mm -- see SZBenchmark.h. CThreadBenchmark + CBenchProgressSync
// (GUI/BenchmarkDialog.cpp) without the Win32 dialog: one Bench() call per pass on a
// dedicated thread, results copied under a lock and pushed to the delegate.

#import "SZBenchmark.h"
#import "SZCodecs.h"
#import "SZError.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZToolsEngine.h"

#include <pthread.h>

#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL
#include "../../C/CpuArch.h"
#include "../../CPP/7zip/MyVersion.h"
#pragma pop_macro("BOOL")

static const unsigned kRatingVector_NumBundlesMax = 20;   // BenchmarkDialog.cpp:45
static const unsigned kMinDicLogSize = 18;                // :427
static const uint64_t kMinDicSize = (uint64_t)1 << kMinDicLogSize;
static const uint64_t kMaxDicSize = (uint64_t)1 << (22 + sizeof(size_t) / 4 * 5);

// ---------------------------------------------------------------------------
#pragma mark - formatting helpers (BenchmarkDialog.cpp:700-1170)

static uint64_t SZGetMips(uint64_t ips) { return (ips + 500000) / 1000000; }

/// NumberToDot3: "<n>.<mmm>"
static NSString *SZDot3String(uint64_t value)
{
    return [NSString stringWithFormat:@"%llu.%03llu",
            (unsigned long long)(value / 1000), (unsigned long long)(value % 1000)];
}


/// Get_and_return_NumProcessThreads_and_SysThreads (Windows/System.h:109) -- the POSIX
/// CProcessAffinity does not have it, so the same normalisation is done here.
static void SZGetThreadCounts(NWindows::NSystem::CProcessAffinity &affinity,
                              UInt32 &numProcessThreads, UInt32 &numSysThreads)
{
    UInt32 num1 = 0, num2 = 0;
    if (affinity.Get())
    {
        num1 = affinity.GetNumProcessThreads();
        num2 = affinity.GetNumSystemThreads();
    }
    if (num1 == 0)
        num1 = NWindows::NSystem::GetNumberOfProcessors();
    if (num1 == 0)
        num1 = 1;
    if (num2 < num1)
        num2 = num1;
    numProcessThreads = num1;
    numSysThreads = num2;
}

// ---------------------------------------------------------------------------
#pragma mark - result value objects

@implementation SZBenchmarkResult {
@public
    BOOL _isDefined;
    uint64_t _speed, _rating, _ratingPerUsage, _usage, _unpackSize;
}
- (BOOL)isDefined { return _isDefined; }
- (uint64_t)speed { return _speed; }
- (uint64_t)rating { return _rating; }
- (uint64_t)ratingPerUsage { return _ratingPerUsage; }
- (uint64_t)usage { return _usage; }
- (uint64_t)unpackSize { return _unpackSize; }
- (uint64_t)usagePercent { return Benchmark_GetUsage_Percents(_usage); }
- (uint64_t)ratingMIPS { return SZGetMips(_rating); }
- (uint64_t)ratingPerUsageMIPS { return SZGetMips(_ratingPerUsage); }

- (NSString *)speedString
{
    // SetItemText_Number(ids[1], (Speed >> 10) / NumIterations2, " KB/s")
    return [NSString stringWithFormat:@"%llu KB/s", (unsigned long long)(_speed >> 10)];
}
- (NSString *)ratingString { return [SZDot3String(self.ratingMIPS) stringByAppendingString:@" GIPS"]; }
- (NSString *)ratingPerUsageString { return [SZDot3String(self.ratingPerUsageMIPS) stringByAppendingString:@" GIPS"]; }
- (NSString *)usageString { return [NSString stringWithFormat:@"%llu%%", (unsigned long long)self.usagePercent]; }

- (NSString *)sizeString
{
    uint64_t v = _unpackSize;
    if (v >= ((uint64_t)1 << 40))
        return [NSString stringWithFormat:@"%llu GB", (unsigned long long)(v >> 30)];
    return [NSString stringWithFormat:@"%llu MB", (unsigned long long)(v >> 20)];
}
@end

@implementation SZBenchmarkPass {
@public
    SZBenchmarkResult *_encode;
    SZBenchmarkResult *_decode;
    NSString *_logLine;
}
- (SZBenchmarkResult *)encode { return _encode; }
- (SZBenchmarkResult *)decode { return _decode; }
- (NSString *)logLine { return _logLine; }
@end

// ---------------------------------------------------------------------------
#pragma mark - engine-side sync data

namespace {

struct CSZTotalRes: public CTotalBenchRes
{
    UInt64 UnpackSize = 0;

    void InitAll() { CTotalBenchRes::Init(); UnpackSize = 0; }

    void SetFrom_BenchInfo(const CBenchInfo &info)
    {
        NumIterations2 = 1;
        Generate_From_BenchInfo(info);
        UnpackSize = info.Get_UnpackSize_Full();
    }

    void Update_With_Res2(const CSZTotalRes &r)
    {
        Update_With_Res(r);
        UnpackSize += r.UnpackSize;
    }
};

struct CSZBenchPass
{
    CSZTotalRes Enc;
    CSZTotalRes Dec;
};

/// CBenchProgressSync
struct CSZBenchSync
{
    pthread_mutex_t Mutex;
    bool Exit = false;
    UInt32 NumThreads = 1;
    UInt64 DictSize = (UInt64)1 << 25;
    UInt32 NumPasses_Limit = 1;
    int Level = -1;
    bool TotalMode = false;

    UInt32 NumPasses_Finished = 0;
    bool BenchWasFinished = false;
    int RatingVector_DeletedIndex = -1;

    CSZTotalRes Enc_1, Enc, Dec_1, Dec;
    CObjectVector<CSZBenchPass> RatingVector;

    HRESULT Task_HRESULT = S_OK;
    HRESULT Thread_HRESULT = S_OK;

    UInt32 NumFreqThreadsPrev = 0;
    UString FreqString;
    AString Text;

    CSZBenchSync() { pthread_mutex_init(&Mutex, NULL); }
    ~CSZBenchSync() { pthread_mutex_destroy(&Mutex); }

    void Lock() { pthread_mutex_lock(&Mutex); }
    void Unlock() { pthread_mutex_unlock(&Mutex); }

    void InitRun()
    {
        Lock();
        Exit = false;
        NumPasses_Finished = 0;
        BenchWasFinished = false;
        RatingVector_DeletedIndex = -1;
        Enc_1.InitAll(); Enc.InitAll(); Dec_1.InitAll(); Dec.InitAll();
        RatingVector.Clear();
        Task_HRESULT = S_OK;
        Thread_HRESULT = S_OK;
        NumFreqThreadsPrev = 0;
        FreqString.Empty();
        Text.Empty();
        Unlock();
    }
};

struct CSZLock
{
    CSZBenchSync *S;
    explicit CSZLock(CSZBenchSync *s): S(s) { S->Lock(); }
    ~CSZLock() { S->Unlock(); }
};

}  // namespace

// ---------------------------------------------------------------------------

@interface SZBenchmark ()
+ (void)threadCounts:(uint32_t *)process system:(uint32_t *)system;
- (void)notifyUpdate;
- (void)notifyFrequencyLine:(NSString *)line;
- (void)notifyText:(NSString *)text;
- (void)workerThread;
@end

namespace {

/// CBenchCallback (BenchmarkDialog.cpp:1417-1490)
struct CSZBenchCallback Z7_final: public IBenchCallback
{
    CSZBenchSync *Sync = NULL;
    __weak SZBenchmark *Owner = nil;

    HRESULT SetEncodeResult(const CBenchInfo &info, bool final) Z7_override
    {
        bool needPost = false;
        {
            CSZLock lock(Sync);
            if (Sync->Exit)
                return E_ABORT;
            CSZTotalRes &br = Sync->Enc_1;
            UInt64 dictSize = Sync->DictSize;
            if (!final && dictSize > info.UnpackSize)
                dictSize = info.UnpackSize;
            const UInt64 rating = info.GetRating_LzmaEnc(dictSize);
            br.SetFrom_BenchInfo(info);
            br.Rating = rating;
            if (final)
            {
                Sync->Enc.Update_With_Res2(br);
                needPost = true;
            }
        }
        [Owner notifyUpdate];
        (void)needPost;
        return S_OK;
    }

    HRESULT SetDecodeResult(const CBenchInfo &info, bool final) Z7_override
    {
        {
            CSZLock lock(Sync);
            if (Sync->Exit)
                return E_ABORT;
            CSZTotalRes &br = Sync->Dec_1;
            const UInt64 rating = info.GetRating_LzmaDec();
            br.SetFrom_BenchInfo(info);
            br.Rating = rating;
            if (final)
                Sync->Dec.Update_With_Res2(br);
        }
        [Owner notifyUpdate];
        return S_OK;
    }
};

/// CBenchCallback2: the console-style printer used in `-mm=*` total mode.
struct CSZBenchPrintCallback Z7_final: public IBenchPrintCallback
{
    CSZBenchSync *Sync = NULL;
    __weak SZBenchmark *Owner = nil;

    void Print(const char *s) Z7_override
    {
        if (!s || !*s)
            return;
        {
            CSZLock lock(Sync);
            Sync->Text += s;
        }
        [Owner notifyText:[NSString stringWithUTF8String:s] ?: @""];
    }

    void NewLine() Z7_override { Print("\n"); }

    HRESULT CheckBreak() Z7_override
    {
        CSZLock lock(Sync);
        return Sync->Exit ? E_ABORT : S_OK;
    }
};

/// CFreqCallback (BenchmarkDialog.cpp:1526-1570)
struct CSZFreqCallback Z7_final: public IBenchFreqCallback
{
    CSZBenchSync *Sync = NULL;
    __weak SZBenchmark *Owner = nil;

    HRESULT AddCpuFreq(unsigned numThreads, UInt64 freq, UInt64 usage) Z7_override
    {
        HRESULT res;
        {
            CSZLock lock(Sync);
            UString &s = Sync->FreqString;
            if (Sync->NumFreqThreadsPrev != numThreads)
            {
                Sync->NumFreqThreadsPrev = numThreads;
                if (!s.IsEmpty())
                    s.Add_LF();
                s.Add_UInt32(numThreads);
                s += "T Frequency (MHz):";
                s.Add_LF();
            }
            s.Add_Space();
            if (numThreads != 1)
            {
                s.Add_UInt64(Benchmark_GetUsage_Percents(usage));
                s.Add_Char('%');
                s.Add_Space();
            }
            s.Add_UInt64(SZGetMips(freq));
            res = Sync->Exit ? E_ABORT : S_OK;
        }
        return res;
    }

    HRESULT FreqsFinished(unsigned /* numThreads */) Z7_override
    {
        NSString *line = nil;
        HRESULT res;
        {
            CSZLock lock(Sync);
            line = SZStringFromUString(Sync->FreqString);
            res = Sync->Exit ? E_ABORT : S_OK;
        }
        [Owner notifyFrequencyLine:line ?: @""];
        [Owner notifyUpdate];
        return res;
    }
};

}  // namespace

// ---------------------------------------------------------------------------

static SZBenchmarkResult *SZMakeResult(const CSZTotalRes &r)
{
    SZBenchmarkResult *out = [SZBenchmarkResult new];
    if (r.NumIterations2 == 0)
    {
        out->_isDefined = NO;
        return out;
    }
    out->_isDefined = YES;
    out->_speed = r.Speed / r.NumIterations2;
    out->_rating = r.Rating / r.NumIterations2;
    out->_ratingPerUsage = r.RPU / r.NumIterations2;
    out->_usage = r.Usage / r.NumIterations2;
    out->_unpackSize = r.UnpackSize;
    return out;
}

/// AddRatingString / AddUsageString / AddRatingsLine (BenchmarkDialog.cpp:1050-1121)
static NSString *SZRatingsLine(const CSZTotalRes &enc, const CSZTotalRes &dec)
{
    auto ratingText = [](const CTotalBenchRes &info) -> NSString * {
        UInt64 numIter = info.NumIterations2;
        if (numIter == 0)
            numIter = 1000000;
        return SZDot3String(SZGetMips(info.Rating / numIter));
    };
    auto usageText = [](const CTotalBenchRes &info) -> NSString * {
        UInt64 numIter = info.NumIterations2;
        if (numIter == 0)
            numIter = 1000000;
        NSString *s = [NSString stringWithFormat:@"%llu%%",
                       (unsigned long long)Benchmark_GetUsage_Percents(info.Usage / numIter)];
        while (s.length < 5)
            s = [@" " stringByAppendingString:s];
        return s;
    };
    CTotalBenchRes total;
    total.SetSum(enc, dec);
    return [NSString stringWithFormat:@"%@  %@  %@ %@",
            ratingText(enc), ratingText(dec), ratingText(total), usageText(total)];
}

@implementation SZBenchmark {
    CSZBenchSync _sync;
    NSThread *_thread;
    NSMutableArray<NSString *> *_freqLines;
    NSMutableString *_totalText;
    dispatch_semaphore_t _finished;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _dictionarySize = (uint64_t)1 << 25;
        _numberOfThreads = SZBenchmark.processThreadCount;
        _numberOfPasses = 1;
        _level = -1;
        _freqLines = [NSMutableArray array];
        _totalText = [NSMutableString string];
        _finished = dispatch_semaphore_create(0);
    }
    return self;
}

// MARK: - control

- (BOOL)start:(NSError **)error
{
    if (_thread && !_thread.isFinished)
    {
        if (error)
            *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"The benchmark is already running"];
        return NO;
    }
    if (![SZCodecs loadCodecs:error])
        return NO;

    _sync.InitRun();
    _sync.Lock();
    _sync.NumThreads = _numberOfThreads ?: 1;
    _sync.DictSize = _dictionarySize;
    _sync.NumPasses_Limit = _numberOfPasses ?: 1;
    _sync.Level = _level;
    _sync.TotalMode = _totalMode ? true : false;
    _sync.Unlock();
    [_freqLines removeAllObjects];
    [_totalText setString:@""];
    _finished = dispatch_semaphore_create(0);

    NSThread *thread = [[NSThread alloc] initWithTarget:self selector:@selector(workerThread) object:nil];
    thread.name = @"7-Zip benchmark";
    thread.stackSize = 8 << 20;
    _thread = thread;
    [thread start];
    return YES;
}

- (void)requestStop
{
    CSZLock lock(&_sync);
    _sync.Exit = true;
}

- (void)waitUntilFinished
{
    if (!_thread)
        return;
    dispatch_semaphore_wait(_finished, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(_finished);
}

- (BOOL)isRunning
{
    return _thread != nil && !_thread.isFinished;
}

// MARK: - worker (CThreadBenchmark::Process, :1599-1800)

- (void)workerThread
{
    HRESULT finishHRESULT = S_OK;
    @autoreleasepool
    {
        NSString *message = nil;
        finishHRESULT = SZRunCatching(&message, [&]() -> HRESULT {
            for (;;)
            {
                UInt64 dictionarySize;
                UInt32 numThreads;
                bool totalMode;
                {
                    CSZLock lock(&_sync);
                    if (_sync.Exit)
                        break;
                    dictionarySize = _sync.DictSize;
                    numThreads = _sync.NumThreads;
                    totalMode = _sync.TotalMode;
                }

                CSZBenchCallback callback;
                callback.Sync = &_sync;
                callback.Owner = self;
                CSZBenchPrintCallback printCallback;
                printCallback.Sync = &_sync;
                printCallback.Owner = self;
                CSZFreqCallback freqCallback;
                freqCallback.Sync = &_sync;
                freqCallback.Owner = self;

                CObjectVector<CProperty> props;
                if (!totalMode)
                {
                    {
                        CProperty prop;
                        prop.Name = "mt";
                        prop.Value.Add_UInt32(numThreads);
                        props.Add(prop);
                    }
                    {
                        CProperty prop;
                        prop.Name = 'd';
                        prop.Name.Add_UInt32((UInt32)(dictionarySize >> 10));
                        prop.Name.Add_Char('k');
                        props.Add(prop);
                    }
                }
                else
                {
                    CProperty prop;
                    prop.Name = "m";
                    prop.Value = "*";
                    props.Add(prop);
                }

                bool isFirstPass;
                {
                    CSZLock lock(&_sync);
                    isFirstPass = (_sync.NumPasses_Finished == 0);
                }

                HRESULT result;
                try
                {
                    result = Bench(totalMode ? (IBenchPrintCallback *)&printCallback : NULL,
                                   totalMode ? NULL : (IBenchCallback *)&callback,
                                   props, 1, false,
                                   (!totalMode && isFirstPass) ? (IBenchFreqCallback *)&freqCallback : NULL);
                }
                catch (...)
                {
                    result = E_FAIL;
                }

                bool finished = true;
                {
                    CSZLock lock(&_sync);
                    if (result != S_OK)
                    {
                        _sync.Task_HRESULT = result;
                        break;
                    }
                    _sync.NumPasses_Finished++;
                    if (totalMode)
                        break;

                    CSZBenchPass &pass = _sync.RatingVector.AddNew();
                    pass.Enc = _sync.Enc_1;
                    pass.Dec = _sync.Dec_1;

                    if (_sync.RatingVector.Size() > kRatingVector_NumBundlesMax)
                    {
                        _sync.RatingVector_DeletedIndex = (int)(kRatingVector_NumBundlesMax / 4);
                        _sync.RatingVector.Delete((unsigned)_sync.RatingVector_DeletedIndex);
                    }
                    if (_sync.NumPasses_Finished < _sync.NumPasses_Limit)
                        finished = false;
                    else
                        _sync.BenchWasFinished = true;
                }
                [self notifyUpdate];
                if (finished)
                    break;
            }
            return S_OK;
        });
        if (finishHRESULT != S_OK)
        {
            CSZLock lock(&_sync);
            _sync.Thread_HRESULT = finishHRESULT;
        }
    }

    HRESULT taskResult, threadResult;
    {
        CSZLock lock(&_sync);
        taskResult = _sync.Task_HRESULT;
        threadResult = _sync.Thread_HRESULT;
    }
    NSError *error = nil;
    if (threadResult != S_OK)
        error = [SZErrors errorWithHRESULT:(uint32_t)threadResult message:nil];
    else if (taskResult != S_OK && taskResult != E_ABORT)
    {
        // OnMessage (:1200-1215): S_FALSE means "Decoding error".
        NSString *text = (taskResult == S_FALSE) ? @"Decoding error" : nil;
        error = text ? [SZErrors errorWithCode:SZErrorCodeEngine message:text]
                     : [SZErrors errorWithHRESULT:(uint32_t)taskResult message:nil];
    }
    dispatch_semaphore_signal(_finished);
    id<SZBenchmarkDelegate> delegate = self.delegate;
    if (delegate)
        [delegate benchmarkDidFinishWithError:error];
}

// MARK: - delegate plumbing

- (void)notifyUpdate
{
    id<SZBenchmarkDelegate> delegate = self.delegate;
    if (delegate)
        [delegate benchmarkDidUpdate];
}

- (void)notifyFrequencyLine:(NSString *)line
{
    @synchronized (self)
    {
        [_freqLines removeAllObjects];
        if (line.length != 0)
            [_freqLines addObject:line];
    }
    id<SZBenchmarkDelegate> delegate = self.delegate;
    if (delegate && [delegate respondsToSelector:@selector(benchmarkDidAddFrequencyLine:)])
        [delegate benchmarkDidAddFrequencyLine:line];
}

- (void)notifyText:(NSString *)text
{
    @synchronized (self)
    {
        [_totalText appendString:text];
    }
    id<SZBenchmarkDelegate> delegate = self.delegate;
    if (delegate && [delegate respondsToSelector:@selector(benchmarkDidPrintText:)])
        [delegate benchmarkDidPrintText:text];
}

// MARK: - snapshot

- (uint32_t)passesFinished
{
    CSZLock lock(&_sync);
    return _sync.NumPasses_Finished;
}

- (BOOL)didFinishAllPasses
{
    CSZLock lock(&_sync);
    return _sync.BenchWasFinished ? YES : NO;
}

- (SZBenchmarkResult *)currentEncode { CSZLock lock(&_sync); return SZMakeResult(_sync.Enc_1); }
- (SZBenchmarkResult *)resultingEncode { CSZLock lock(&_sync); return SZMakeResult(_sync.Enc); }
- (SZBenchmarkResult *)currentDecode { CSZLock lock(&_sync); return SZMakeResult(_sync.Dec_1); }
- (SZBenchmarkResult *)resultingDecode { CSZLock lock(&_sync); return SZMakeResult(_sync.Dec); }

- (SZBenchmarkResult *)totalRating
{
    CSZLock lock(&_sync);
    CSZTotalRes total = _sync.Enc;
    total.Update_With_Res2(_sync.Dec);
    return SZMakeResult(total);
}

- (NSArray<SZBenchmarkPass *> *)passes
{
    CSZLock lock(&_sync);
    NSMutableArray<SZBenchmarkPass *> *out = [NSMutableArray array];
    FOR_VECTOR (i, _sync.RatingVector)
    {
        const CSZBenchPass &p = _sync.RatingVector[i];
        SZBenchmarkPass *pass = [SZBenchmarkPass new];
        pass->_encode = SZMakeResult(p.Enc);
        pass->_decode = SZMakeResult(p.Dec);
        pass->_logLine = SZRatingsLine(p.Enc, p.Dec);
        [out addObject:pass];
    }
    return out;
}

- (NSInteger)droppedPassIndex
{
    CSZLock lock(&_sync);
    return _sync.RatingVector_DeletedIndex;
}

- (NSString *)frequencyText
{
    @synchronized (self)
    {
        return [_freqLines componentsJoinedByString:@"\n"];
    }
}

- (NSString *)totalModeText
{
    @synchronized (self)
    {
        return [_totalText copy];
    }
}

- (NSString *)logText
{
    // UpdateGui (:1315-1380)
    NSMutableString *s = [NSMutableString string];
    NSString *freq = self.frequencyText;
    if (freq.length != 0)
        [s appendString:freq];
    NSArray<SZBenchmarkPass *> *passes = self.passes;
    const NSInteger dropped = self.droppedPassIndex;
    if (passes.count != 0)
    {
        if (s.length != 0)
            [s appendString:@"\n"];
        [s appendString:@"Compr Decompr Total   CPU\n"];
    }
    for (NSUInteger i = 0; i < passes.count; i++)
    {
        if (i != 0)
            [s appendString:@"\n"];
        if ((NSInteger)i == dropped)
            [s appendString:@"...\n"];
        [s appendString:passes[i].logLine];
    }
    if (self.didFinishAllPasses)
    {
        CSZLock lock(&_sync);
        [s appendString:@"\n-------------\n"];
        [s appendString:SZRatingsLine(_sync.Enc, _sync.Dec)];
    }
    return s;
}

// MARK: - static information

+ (uint64_t)memoryUsageForThreads:(uint32_t)threads level:(int)level
                       dictionary:(uint64_t)dictionary totalMode:(BOOL)totalMode
{
    return GetBenchMemoryUsage(threads ?: 1, level, dictionary, totalMode ? true : false);
}

+ (uint64_t)ramSize
{
    size_t size = 0;
    if (!NWindows::NSystem::GetRamSize(size))
        return 0;
    return size;
}

+ (uint64_t)ramSizeLimit
{
    const uint64_t ram = self.ramSize;
    if (ram == 0)
        return 0;
    return ram / 16 * 15;
}

+ (BOOL)isMemoryUsageOK:(uint64_t)usage
{
    const uint64_t limit = self.ramSizeLimit;
    if (limit == 0)
        return YES;          // RamSize unknown: BenchmarkDialog does not block the run
    return usage + (1 << 20) <= limit;
}

+ (uint64_t)minimumDictionarySize { return kMinDicSize; }
+ (uint64_t)maximumDictionarySize { return kMaxDicSize; }
+ (NSUInteger)minimumDictionaryLog { return kBenchMinDicLogSize; }

+ (void)threadCounts:(uint32_t *)process system:(uint32_t *)system
{
    UInt32 numProcess = 1, numSys = 1;
    NWindows::NSystem::CProcessAffinity affinity;
    affinity.InitST();
    SZGetThreadCounts(affinity, numProcess, numSys);
    if (numProcess == 0) numProcess = 1;
    if (numSys == 0) numSys = 1;
    if (process) *process = numProcess;
    if (system) *system = numSys;
}

+ (uint32_t)processThreadCount
{
    uint32_t p = 1, s = 1;
    [self threadCounts:&p system:&s];
    return p;
}

+ (uint32_t)systemThreadCount
{
    uint32_t p = 1, s = 1;
    [self threadCounts:&p system:&s];
    return s;
}

+ (NSString *)hardwareThreadsText
{
    UInt32 numProcess = 1, numSys = 1;
    NWindows::NSystem::CProcessAffinity affinity;
    affinity.InitST();
    SZGetThreadCounts(affinity, numProcess, numSys);
    AString s("/ ");
    s.Add_UInt32(numProcess ? numProcess : 1);
    s += GetProcessThreadsInfo(affinity);
    return [NSString stringWithUTF8String:s.Ptr()] ?: @"";
}

+ (NSString *)cpuName
{
    AString s, registers;
    GetCpuName_MultiLine(s, registers);
    return [NSString stringWithUTF8String:s.Ptr()] ?: @"";
}

+ (NSString *)cpuFeaturesText
{
    AString s;
    GetOsInfoText(s);
    s += " : ";
    AddCpuFeatures(s);
    return [NSString stringWithUTF8String:s.Ptr()] ?: @"";
}

+ (NSString *)systemInfoLine1
{
    AString s1, s2;
    GetSysInfo(s1, s2);
    return [NSString stringWithUTF8String:s1.Ptr()] ?: @"";
}

+ (NSString *)systemInfoLine2
{
    AString s1, s2;
    GetSysInfo(s1, s2);
    if (s1 == s2)
        return @"";
    return [NSString stringWithUTF8String:s2.Ptr()] ?: @"";
}

+ (NSString *)versionWithCPUText { return @"7-Zip " MY_VERSION_CPU; }
+ (NSString *)engineDateText { return @MY_DATE; }
+ (NSString *)engineCopyrightText { return @MY_COPYRIGHT; }

@end

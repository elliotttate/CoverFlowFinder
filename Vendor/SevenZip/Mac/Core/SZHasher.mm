// SZHasher.mm -- see SZHasher.h. HashCalc() for file-system items, CopyTo in stream mode
// for archive members, and the checksum-file writer / verifier.

#import "SZHasher.h"
#import "SZCodecs.h"
#import "SZError.h"
#import "SZLang.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"
#import "Internal/SZToolsEngine.h"
#import "Internal/SZHashBundleBridge.h"

/// `HResultToMessage` (FileManager/ProgressDialog2.cpp:1477-1483): E_OUTOFMEMORY has its own lang
/// string, IDS_MEM_ERROR 3000, not `MyFormatMessage`'s errno text. Command mode maps that message
/// to exit code 8 (03-shell-integration-inventory.md section 2.7).
static NSError *SZHasherError(HRESULT hr, NSString *engineMessage)
{
  if (hr == E_OUTOFMEMORY && engineMessage.length == 0)
    engineMessage = [SZLang.shared stringForID:3000
                                      fallback:@"The system cannot allocate the required amount of memory"];
  return [SZErrors errorWithHRESULT:(uint32_t)hr message:engineMessage];
}

// Lang IDs (FileManager/PropertyNameRes.h, resourceGui.h, OverwriteDialogRes.h)
enum {
    kLangID_MessageNoErrors = 3001,      // IDS_MESSAGE_NO_ERRORS  "There are no errors"
    kLangID_FileSize = 3504,             // IDS_FILE_SIZE          "{0} bytes"
    kLangID_PropName = 1004,             // IDS_PROP_NAME          "Name"
    kLangID_PropSize = 1007,             // IDS_PROP_SIZE          "Size"
    kLangID_PropFolders = 1031,          // IDS_PROP_FOLDERS       "Folders"
    kLangID_PropFiles = 1032,            // IDS_PROP_FILES         "Files"
    kLangID_PropNumErrors = 1070,        // IDS_PROP_NUM_ERRORS    "Errors"
    kLangID_PropNumAltStreams = 1075,    // IDS_PROP_NUM_ALT_STREAMS
    kLangID_PropAltStreamsSize = 1076,   // IDS_PROP_ALT_STREAMS_SIZE
    kLangID_ChecksumCrcData = 7502,      // IDS_CHECKSUM_CRC_DATA          "CRC checksum for data:"
    kLangID_ChecksumCrcDataNames = 7503, // IDS_CHECKSUM_CRC_DATA_NAMES
    kLangID_ChecksumCrcStreamsNames = 7504
};

// ---------------------------------------------------------------------------
#pragma mark - small helpers

static NSString *SZLangText(uint32_t id, NSString *fallback)
{
    return [SZLang.shared stringForID:id fallback:fallback];
}

/// AddSizeValue as HashGUI.cpp's AddSizeValuePair links it: the non-static one of
/// OverwriteDialog.cpp:68-88 (App.cpp's is file-local), i.e. IDS_FILE_SIZE around the *plain*
/// number, then " : N KiB" from 1 KiB (MiB from 10 MiB, GiB from 10 GiB). 7zFM 25.01 shows
/// "1234 bytes : 1 KiB" for a 1 234-byte file (ai/reports/wincompare.md).
static NSString *SZSizeValueString(uint64_t size)
{
    NSString *tmpl = SZLangText(kLangID_FileSize, @"{0} bytes");
    NSMutableString *s = [[tmpl stringByReplacingOccurrencesOfString:@"{0}"
                                                          withString:[NSString stringWithFormat:@"%llu", size]] mutableCopy];
    if (size >= (1 << 10))
    {
        uint64_t v = size;
        char c;
        if (v >= ((uint64_t)10 << 30)) { v >>= 30; c = 'G'; }
        else if (v >= ((uint64_t)10 << 20)) { v >>= 20; c = 'M'; }
        else { v >>= 10; c = 'K'; }
        [s appendFormat:@" : %llu %ciB", v, c];
    }
    return s;
}

NSString *SZHashSizeValueString(uint64_t size) { return SZSizeValueString(size); }

static NSString *SZStringFromAString(const AString &s)
{
    return [[NSString alloc] initWithBytes:s.Ptr() length:s.Len() encoding:NSUTF8StringEncoding] ?: @"";
}

/// CHasherState::WriteToString: hex of one digest group (+ "-<extra>" for a sum of several).
static NSString *SZDigestString(const CHasherState &h, unsigned groupIndex)
{
    char temp[k_HashCalc_DigestSize_Max * 2 + k_HashCalc_ExtraSize * 2 + 16];
    temp[0] = 0;
    h.WriteToString(groupIndex, temp);
    return [NSString stringWithUTF8String:temp] ?: @"";
}

// ---------------------------------------------------------------------------
#pragma mark - value objects

@implementation SZHashMethod {
@public
    NSString *_name;
    NSUInteger _digestSize;
}
- (NSString *)name { return _name; }
- (NSUInteger)digestSize { return _digestSize; }

/// The CRC submenu wording (resource.rc:56-69) for the names the engine registers.
- (NSString *)menuTitle
{
    static NSDictionary<NSString *, NSString *> *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        titles = @{ @"CRC32": @"CRC-32", @"CRC64": @"CRC-64", @"SHA1": @"SHA-1",
                    @"SHA256": @"SHA-256", @"SHA384": @"SHA-384", @"SHA512": @"SHA-512" };
    });
    return titles[_name] ?: _name;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<SZHashMethod %@ %lu>", _name, (unsigned long)_digestSize];
}
@end

@implementation SZHashResultRow {
@public
    NSString *_name;
    NSString *_value;
}
- (NSString *)name { return _name; }
- (NSString *)value { return _value; }
- (NSString *)description { return [NSString stringWithFormat:@"%@: %@", _name, _value]; }
@end

static SZHashResultRow *SZMakeRow(NSString *name, NSString *value)
{
    SZHashResultRow *row = [SZHashResultRow new];
    row->_name = name ?: @"";
    row->_value = value ?: @"";
    return row;
}

// Internal/SZHashBundleBridge.h: the same helpers for SZExtractor.mm (`-scrc`).
SZHashResultRow *SZMakeHashResultRow(NSString *name, NSString *value) { return SZMakeRow(name, value); }

@implementation SZHashFileResult {
@public
    NSString *_path;
    uint64_t _size;
    BOOL _isDirectory;
    BOOL _isAlternateStream;
    NSDictionary<NSString *, NSString *> *_digests;
}
- (NSString *)path { return _path; }
- (uint64_t)size { return _size; }
- (BOOL)isDirectory { return _isDirectory; }
- (BOOL)isAlternateStream { return _isAlternateStream; }
- (NSDictionary<NSString *, NSString *> *)digests { return _digests; }
@end

@implementation SZHashResults {
@public
    NSArray<SZHashResultRow *> *_rows;
    NSString *_text;
    uint64_t _numFolders, _numFiles, _numAlternateStreams, _filesSize, _alternateStreamsSize, _numErrors;
    NSString *_mainName, *_firstFileName;
    NSArray<NSString *> *_methodNames;
    NSDictionary<NSString *, NSString *> *_dataDigests, *_dataAndNamesDigests, *_streamsAndNamesDigests;
    NSArray<SZHashFileResult *> *_fileResults;
}
- (NSArray<SZHashResultRow *> *)rows { return _rows; }
- (NSString *)text { return _text; }
- (uint64_t)numFolders { return _numFolders; }
- (uint64_t)numFiles { return _numFiles; }
- (uint64_t)numAlternateStreams { return _numAlternateStreams; }
- (uint64_t)filesSize { return _filesSize; }
- (uint64_t)alternateStreamsSize { return _alternateStreamsSize; }
- (uint64_t)numErrors { return _numErrors; }
- (NSString *)mainName { return _mainName; }
- (NSString *)firstFileName { return _firstFileName; }
- (NSArray<NSString *> *)methodNames { return _methodNames; }
- (NSDictionary<NSString *, NSString *> *)dataDigests { return _dataDigests; }
- (NSDictionary<NSString *, NSString *> *)dataAndNamesDigests { return _dataAndNamesDigests; }
- (NSDictionary<NSString *, NSString *> *)streamsAndNamesDigests { return _streamsAndNamesDigests; }
- (NSArray<SZHashFileResult *> *)fileResults { return _fileResults; }

- (NSString *)clipboardTextForRowsAtIndexes:(NSIndexSet *)indexes
{
    // CListViewDialog::CopyToClipboard (ListViewDialog.cpp:164-195): "<name>: <value>" lines.
    NSMutableString *out = [NSMutableString string];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        (void)stop;
        if (i >= self->_rows.count)
            return;
        SZHashResultRow *row = self->_rows[i];
        [out appendFormat:@"%@: %@\n", row.name, row.value];
    }];
    return out;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<SZHashResults files=%llu folders=%llu size=%llu errors=%llu>",
            (unsigned long long)_numFiles, (unsigned long long)_numFolders,
            (unsigned long long)_filesSize, (unsigned long long)_numErrors];
}
@end

@implementation SZChecksumVerification {
@public
    NSUInteger _numOK, _numFailed, _numMissing, _numUnsupported;
    NSArray<NSString *> *_messages;
    NSArray<NSString *> *_methodNames;
    NSString *_text;
}
- (NSUInteger)numOK { return _numOK; }
- (NSUInteger)numFailed { return _numFailed; }
- (NSUInteger)numMissing { return _numMissing; }
- (NSUInteger)numUnsupported { return _numUnsupported; }
- (NSArray<NSString *> *)messages { return _messages; }
- (NSArray<NSString *> *)methodNames { return _methodNames; }
- (NSString *)text { return _text; }
- (BOOL)succeeded { return _numFailed == 0 && _numMissing == 0 && _numUnsupported == 0; }
@end

// ---------------------------------------------------------------------------
#pragma mark - CHashBundle -> SZHashResults

/// AddHashResString (HashGUI.cpp:167): the lang string with "CRC" replaced by the method
/// name and the colon removed.
static NSString *SZHashResName(uint32_t langID, NSString *fallback, NSString *method)
{
    NSString *s = SZLangText(langID, fallback);
    s = [s stringByReplacingOccurrencesOfString:@"CRC" withString:method];
    return [s stringByReplacingOccurrencesOfString:@":" withString:@""];
}

/// AddHashBundleRes (HashGUI.cpp:179-254) -- both the pair list and the text form.
/// `leadingRows` is how ExtractGUI prepends "Archives:" / "Packed Size" for `-scrc`
/// (declared in Internal/SZHashBundleBridge.h).
SZHashResults *SZHashResultsFromBundle(const CHashBundle &hb,
                                       NSArray<SZHashFileResult *> *fileResults,
                                       NSArray<SZHashResultRow *> *leadingRows)
{
    SZHashResults *r = [SZHashResults new];
    r->_numFolders = hb.NumDirs;
    r->_numFiles = hb.NumFiles;
    r->_numAlternateStreams = hb.NumAltStreams;
    r->_filesSize = hb.FilesSize;
    r->_alternateStreamsSize = hb.AltStreamsSize;
    r->_numErrors = hb.NumErrors;
    r->_mainName = SZStringFromUString(hb.MainName);
    r->_firstFileName = SZStringFromUString(hb.FirstFileName);
    r->_fileResults = fileResults ?: @[];

    NSMutableArray<SZHashResultRow *> *rows = [NSMutableArray array];
    if (leadingRows.count != 0)
        [rows addObjectsFromArray:leadingRows];
    NSMutableArray<NSString *> *methodNames = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *dataDigests = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *namesDigests = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *streamsDigests = [NSMutableDictionary dictionary];

    if (hb.NumErrors != 0)
        [rows addObject:SZMakeRow(SZLangText(kLangID_PropNumErrors, @"Errors"),
                                  [NSString stringWithFormat:@"%llu", (unsigned long long)hb.NumErrors])];

    const BOOL singleFile = (hb.NumFiles == 1 && hb.NumDirs == 0);
    if (singleFile && !hb.FirstFileName.IsEmpty())
    {
        [rows addObject:SZMakeRow(SZLangText(kLangID_PropName, @"Name"), r->_firstFileName)];
    }
    else
    {
        if (!hb.MainName.IsEmpty())
            [rows addObject:SZMakeRow(SZLangText(kLangID_PropName, @"Name"), r->_mainName)];
        if (hb.NumDirs != 0)
            [rows addObject:SZMakeRow(SZLangText(kLangID_PropFolders, @"Folders"),
                                      [NSString stringWithFormat:@"%llu", (unsigned long long)hb.NumDirs])];
        [rows addObject:SZMakeRow(SZLangText(kLangID_PropFiles, @"Files"),
                                  [NSString stringWithFormat:@"%llu", (unsigned long long)hb.NumFiles])];
    }

    [rows addObject:SZMakeRow(SZLangText(kLangID_PropSize, @"Size"), SZSizeValueString(hb.FilesSize))];

    if (hb.NumAltStreams != 0)
    {
        [rows addObject:SZMakeRow(SZLangText(kLangID_PropNumAltStreams, @"Alternate Streams"),
                                  [NSString stringWithFormat:@"%llu", (unsigned long long)hb.NumAltStreams])];
        [rows addObject:SZMakeRow(SZLangText(kLangID_PropAltStreamsSize, @"Alternate Streams Size"),
                                  SZSizeValueString(hb.AltStreamsSize))];
    }

    FOR_VECTOR (i, hb.Hashers)
    {
        const CHasherState &h = hb.Hashers[i];
        NSString *method = SZStringFromAString(h.Name);
        [methodNames addObject:method];
        NSString *data = SZDigestString(h, k_HashCalc_Index_DataSum);
        NSString *names = SZDigestString(h, k_HashCalc_Index_NamesSum);
        NSString *streams = SZDigestString(h, k_HashCalc_Index_StreamsSum);
        dataDigests[method] = data;
        namesDigests[method] = names;
        streamsDigests[method] = streams;

        if (singleFile)
        {
            [rows addObject:SZMakeRow(method, data)];
        }
        else
        {
            [rows addObject:SZMakeRow(SZHashResName(kLangID_ChecksumCrcData, @"CRC checksum for data:", method), data)];
            [rows addObject:SZMakeRow(SZHashResName(kLangID_ChecksumCrcDataNames, @"CRC checksum for data and names:", method), names)];
        }
        if (hb.NumAltStreams != 0)
            [rows addObject:SZMakeRow(SZHashResName(kLangID_ChecksumCrcStreamsNames, @"CRC checksum for streams and names:", method), streams)];
    }

    r->_rows = rows;
    r->_methodNames = methodNames;
    r->_dataDigests = dataDigests;
    r->_dataAndNamesDigests = namesDigests;
    r->_streamsAndNamesDigests = streamsDigests;

    NSMutableString *text = [NSMutableString string];
    for (SZHashResultRow *row in rows)
        [text appendFormat:@"%@: %@\n", row.name, row.value];
    if (hb.NumErrors == 0 && hb.Hashers.IsEmpty())
    {
        [text appendString:@"\n"];
        [text appendString:SZLangText(kLangID_MessageNoErrors, @"There are no errors")];
        [text appendString:@"\n"];
    }
    r->_text = text;
    return r;
}

/// The digests of the file that was just finished (k_HashCalc_Index_Current).
static SZHashFileResult *SZFileResultFromBundle(const CHashBundle &hb, NSString *path,
                                                uint64_t size, BOOL isDir, BOOL isAltStream)
{
    SZHashFileResult *f = [SZHashFileResult new];
    f->_path = path ?: @"";
    f->_size = size;
    f->_isDirectory = isDir;
    f->_isAlternateStream = isAltStream;
    NSMutableDictionary<NSString *, NSString *> *digests = [NSMutableDictionary dictionary];
    FOR_VECTOR (i, hb.Hashers)
    {
        const CHasherState &h = hb.Hashers[i];
        digests[SZStringFromAString(h.Name)] = SZDigestString(h, k_HashCalc_Index_Current);
    }
    f->_digests = digests;
    return f;
}

// ---------------------------------------------------------------------------
#pragma mark - IHashCallbackUI adapter (the 7zG CHashCallbackGUI equivalent)

namespace {

class CSZHashCallback Z7_final: public IHashCallbackUI
{
public:
    __strong id<SZProgressDelegate> Delegate = nil;
    __strong NSMutableArray<SZHashFileResult *> *FileResults = nil;
    /// Filled in AfterLastFile: HashCalc owns the CHashBundle, this is the only hook.
    __strong SZHashResults *Results = nil;
    UString FirstFileName;
    UString MainName;
    UInt64 NumFiles = 0;
    bool CurIsFolder = false;
    bool CurIsAltStream = false;
    UString CurPath;
    UInt64 NumErrors = 0;

    // --- IDirItemsCallback
    HRESULT ScanError(const FString &path, DWORD systemError) Z7_override
    {
        NumErrors++;
        ShowErrorCode(HRESULT_FROM_WIN32(systemError), fs2us(path));
        return CheckBreak();
    }

    HRESULT ScanProgress(const CDirItemsStat &st, const FString &path, bool isDir) Z7_override
    {
        if (Delegate && [Delegate respondsToSelector:@selector(progressScanFolders:files:totalSize:path:isDirectory:)])
            [Delegate progressScanFolders:st.NumDirs
                                    files:st.NumFiles
                                totalSize:st.GetTotalBytes()
                                     path:SZStringFromFString(path)
                              isDirectory:isDir ? YES : NO];
        return CheckBreak();
    }

    // --- IHashCallbackUI
    HRESULT StartScanning() Z7_override
    {
        SetStatus(SZProgressStatusScanning);
        return CheckBreak();
    }

    HRESULT FinishScanning(const CDirItemsStat &st) Z7_override
    {
        return ScanProgress(st, FString(), false);
    }

    HRESULT SetNumFiles(UInt64 numFiles) Z7_override
    {
        if (Delegate && [Delegate respondsToSelector:@selector(progressSetTotalFiles:)])
            [Delegate progressSetTotalFiles:numFiles];
        return CheckBreak();
    }

    HRESULT SetTotal(UInt64 size) Z7_override
    {
        if (Delegate)
            [Delegate progressSetTotal:size];
        return CheckBreak();
    }

    HRESULT SetCompleted(const UInt64 *completeValue) Z7_override
    {
        if (Delegate && completeValue)
            [Delegate progressSetCompleted:*completeValue];
        return CheckBreak();
    }

    HRESULT CheckBreak() Z7_override
    {
        if (Delegate && [Delegate progressCheckBreak])
            return E_ABORT;
        return S_OK;
    }

    HRESULT BeforeFirstFile(const CHashBundle &) Z7_override
    {
        SetStatus(SZProgressStatusChecksum);
        return S_OK;
    }

    HRESULT GetStream(const wchar_t *name, bool isFolder) Z7_override
    {
        if (NumFiles == 0)
            FirstFileName = name;
        CurIsFolder = isFolder;
        CurIsAltStream = false;
        CurPath = name;
        if (Delegate)
            [Delegate progressSetCurrentFile:SZStringFromUString(CurPath) isDirectory:isFolder ? YES : NO];
        return CheckBreak();
    }

    HRESULT OpenFileError(const FString &path, DWORD systemError) Z7_override
    {
        NumErrors++;
        ShowErrorCode(HRESULT_FROM_WIN32(systemError), fs2us(path));
        return S_FALSE;   // HashCalc counts the error and continues (HashCalc.cpp:591)
    }

    HRESULT SetOperationResult(UInt64 fileSize, const CHashBundle &hb, bool /* showHash */) Z7_override
    {
        if (!CurIsFolder)
            NumFiles++;
        if (Delegate)
            [Delegate progressSetNumFilesProcessed:NumFiles];
        if (FileResults)
            [FileResults addObject:SZFileResultFromBundle(hb, SZStringFromUString(CurPath), fileSize,
                                                          CurIsFolder ? YES : NO,
                                                          CurIsAltStream ? YES : NO)];
        return CheckBreak();
    }

    HRESULT AfterLastFile(CHashBundle &hb) Z7_override
    {
        hb.FirstFileName = FirstFileName;
        if (!MainName.IsEmpty())
            hb.MainName = MainName;
        hb.NumErrors += NumErrors;
        Results = SZHashResultsFromBundle(hb, FileResults, nil);
        return S_OK;
    }

private:
    void SetStatus(SZProgressStatus status)
    {
        if (Delegate && [Delegate respondsToSelector:@selector(progressSetStatus:)])
            [Delegate progressSetStatus:status];
    }

    void ShowErrorCode(HRESULT code, const UString &name)
    {
        if (!Delegate)
            return;
        // CProgressSync::AddError_Code_Name (ProgressDialog2.cpp:244)
        UString s = NWindows::NError::MyFormatMessage(code);
        s += " : ";
        s += name;
        [Delegate progressShowMessage:SZStringFromUString(s)];
    }
};

/// An ISequentialOutStream that only feeds the hash bundle -- the stream-mode replacement
/// for COutStreamWithHash (ArchiveExtractCallback.h:27) without the disk stream.
class CSZHashOutStream Z7_final:
    public ISequentialOutStream,
    public CMyUnknownImp
{
    Z7_COM_UNKNOWN_IMP_1(ISequentialOutStream)
public:
    IHashCalc *Hash = NULL;
    UInt64 Size = 0;

    void Init() { Size = 0; if (Hash) Hash->InitForNewFile(); }

    Z7_COM7F_IMF(Write(const void *data, UInt32 size, UInt32 *processedSize)) Z7_override
    {
        if (Hash)
            Hash->Update(data, size);
        Size += size;
        if (processedSize)
            *processedSize = size;
        return S_OK;
    }
};

/// The stream-mode extract callback 7zFM uses to hash archive members (CExtractCallbackImp
/// with StreamMode = true and SetHashMethods, ExtractCallback.cpp:809-1005): CopyTo asks
/// UseExtractToStream, then GetStream7 hands back a hashing stream, so nothing is written.
class CSZHashStreamCallback Z7_final:
    public IFolderOperationsExtractCallback,
    public IFolderArchiveExtractCallback,
    public IFolderArchiveExtractCallback2,
    public IFolderExtractToStreamCallback,
    public ICryptoGetTextPassword,
    public ICompressProgressInfo,
    public CMyUnknownImp
{
    Z7_COM_QI_BEGIN2(IFolderOperationsExtractCallback)
        Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback)
        Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
        Z7_COM_QI_ENTRY(IFolderExtractToStreamCallback)
        Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
        Z7_COM_QI_ENTRY(ICompressProgressInfo)
    Z7_COM_QI_END
    Z7_COM_ADDREF_RELEASE

    Z7_IFACE_COM7_IMP(IProgress)
    Z7_IFACE_COM7_IMP(IFolderOperationsExtractCallback)
    Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
    Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
    Z7_IFACE_COM7_IMP(IFolderExtractToStreamCallback)
    Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(ICompressProgressInfo)

public:
    __strong id<SZProgressDelegate> Delegate = nil;
    __strong NSString *ArchivePath = nil;
    __strong NSMutableArray<SZHashFileResult *> *FileResults = nil;
    CHashBundle *Hash = NULL;
    CMyComPtr2<ISequentialOutStream, CSZHashOutStream> HashStream;
    UString Password;
    bool PasswordIsDefined = false;
    bool PasswordWasAsked = false;
    UInt64 NumFilesProcessed = 0;
    UInt32 NumErrors = 0;
    UString CurPath;
    bool CurIsFolder = false;
    bool CurIsAltStream = false;
    bool StreamWasUsed = false;

    IProgress *AsProgress() { return static_cast<IFolderOperationsExtractCallback *>(this); }

    HRESULT CheckBreak() const
    {
        if (Delegate && [Delegate progressCheckBreak])
            return E_ABORT;
        return S_OK;
    }
};

// ---- IProgress
Z7_COM7F_IMF(CSZHashStreamCallback::SetTotal(UInt64 total))
{
    if (Delegate)
        [Delegate progressSetTotal:total];
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::SetCompleted(const UInt64 *completeValue))
{
    if (Delegate && completeValue)
        [Delegate progressSetCompleted:*completeValue];
    return CheckBreak();
}

// ---- ICompressProgressInfo
Z7_COM7F_IMF(CSZHashStreamCallback::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize))
{
    if (Delegate)
        [Delegate progressSetRatioInfoInSize:inSize ? *inSize : 0 outSize:outSize ? *outSize : 0];
    return CheckBreak();
}

// ---- IFolderOperationsExtractCallback
Z7_COM7F_IMF(CSZHashStreamCallback::AskWrite(const wchar_t *srcPath, Int32 /* srcIsFolder */,
    const FILETIME * /* srcTime */, const UInt64 * /* srcSize */,
    const wchar_t * /* destPathRequest */, BSTR *destPathResult, Int32 *writeAnswer))
{
    // Nothing is written in stream mode, but CopyTo still asks.
    if (destPathResult)
        *destPathResult = NULL;
    if (writeAnswer)
        *writeAnswer = BoolToInt(true);
    (void)srcPath;
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::ShowMessage(const wchar_t *message))
{
    NumErrors++;
    if (Delegate)
        [Delegate progressShowMessage:SZStringFromWChars(message, message ? (unsigned)MyStringLen(message) : 0)];
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::SetCurrentFilePath(const wchar_t *filePath))
{
    CurPath = filePath ? filePath : L"";
    if (Delegate)
        [Delegate progressSetCurrentFile:SZStringFromUString(CurPath) isDirectory:CurIsFolder ? YES : NO];
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::SetNumFiles(UInt64 numFiles))
{
    if (Delegate && [Delegate respondsToSelector:@selector(progressSetTotalFiles:)])
        [Delegate progressSetTotalFiles:numFiles];
    return CheckBreak();
}

// ---- IFolderArchiveExtractCallback
Z7_COM7F_IMF(CSZHashStreamCallback::AskOverwrite(
    const wchar_t * /* existName */, const FILETIME *, const UInt64 *,
    const wchar_t * /* newName */, const FILETIME *, const UInt64 *, Int32 *answer))
{
    if (answer)
        *answer = NOverwriteAnswer::kYes;
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::PrepareOperation(const wchar_t *name, Int32 isFolder,
    Int32 /* askExtractMode */, const UInt64 * /* position */))
{
    CurIsFolder = IntToBool(isFolder);
    CurPath = name ? name : L"";
    if (Delegate)
        [Delegate progressSetCurrentFile:SZStringFromUString(CurPath) isDirectory:CurIsFolder ? YES : NO];
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::MessageError(const wchar_t *message))
{
    return ShowMessage(message);
}

Z7_COM7F_IMF(CSZHashStreamCallback::SetOperationResult(Int32 opRes, Int32 encrypted))
{
    NumFilesProcessed++;
    if (Delegate)
    {
        [Delegate progressSetNumFilesProcessed:NumFilesProcessed];
        [Delegate progressSetOperationResult:(SZOperationResult)opRes
                                       path:SZStringFromUString(CurPath)
                                isEncrypted:IntToBool(encrypted) ? YES : NO];
    }
    if (opRes != NArchive::NExtract::NOperationResult::kOK)
    {
        NumErrors++;
        if (Delegate)
        {
            UString s;
            SetExtractErrorMessage(opRes, encrypted, CurPath.Ptr(), s);
            if (!s.IsEmpty())
                [Delegate progressShowMessage:SZStringFromUString(s)];
        }
    }
    return CheckBreak();
}

// ---- IFolderArchiveExtractCallback2
Z7_COM7F_IMF(CSZHashStreamCallback::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name))
{
    CurPath = name ? name : L"";
    return SetOperationResult(opRes, encrypted);
}

// ---- IFolderExtractToStreamCallback (the stream-mode hashing path)
Z7_COM7F_IMF(CSZHashStreamCallback::UseExtractToStream(Int32 *res))
{
    if (res)
        *res = BoolToInt(true);
    return S_OK;
}

Z7_COM7F_IMF(CSZHashStreamCallback::GetStream7(const wchar_t *name, Int32 isDir,
    ISequentialOutStream **outStream, Int32 askExtractMode, IGetProp *getProp))
{
    *outStream = NULL;
    StreamWasUsed = false;
    CurIsFolder = IntToBool(isDir);
    CurIsAltStream = false;
    CurPath = name ? name : L"";

    if (getProp)
    {
        NWindows::NCOM::CPropVariant prop;
        if (getProp->GetProp(kpidIsAltStream, &prop) == S_OK && prop.vt == VT_BOOL)
            CurIsAltStream = VARIANT_BOOLToBool(prop.boolVal);
    }
    // 7-Zip 26.04 (ExtractCallback.cpp GetStream7): a folder item no longer returns here, so it
    // gets the hash stream too and SetOperationResult8 calls Final(isDir) for it -- the folder
    // count and the folder names in "checksum for data and names". 24.09-26.03 returned early
    // for folders, and the archive's names sum disagreed with the same tree on disk.
    if (askExtractMode != NArchive::NExtract::NAskMode::kExtract &&
        askExtractMode != NArchive::NExtract::NAskMode::kTest)
        return S_OK;

    HashStream.Create_if_Empty();
    HashStream->Hash = Hash;
    HashStream->Init();
    StreamWasUsed = true;
    CMyComPtr<ISequentialOutStream> s = HashStream.Interface();
    *outStream = s.Detach();
    return S_OK;
}

Z7_COM7F_IMF(CSZHashStreamCallback::PrepareOperation7(Int32 /* askExtractMode */))
{
    if (Delegate)
        [Delegate progressSetCurrentFile:SZStringFromUString(CurPath) isDirectory:CurIsFolder ? YES : NO];
    return CheckBreak();
}

Z7_COM7F_IMF(CSZHashStreamCallback::SetOperationResult8(Int32 opRes, Int32 encrypted, UInt64 size))
{
    if (Hash && StreamWasUsed)
    {
        Hash->Final(CurIsFolder, CurIsAltStream, CurPath);
        if (FileResults)
            [FileResults addObject:SZFileResultFromBundle(*Hash, SZStringFromUString(CurPath),
                                                          HashStream.IsDefined() ? HashStream->Size : size,
                                                          CurIsFolder ? YES : NO,
                                                          CurIsAltStream ? YES : NO)];
        StreamWasUsed = false;
    }
    return SetOperationResult(opRes, encrypted);
}

// ---- ICryptoGetTextPassword
Z7_COM7F_IMF(CSZHashStreamCallback::CryptoGetTextPassword(BSTR *password))
{
    PasswordWasAsked = true;
    if (!PasswordIsDefined)
    {
        if (!Delegate)
            return E_ABORT;
        NSString *answer = [Delegate progressAskPasswordForPath:ArchivePath ?: @""];
        if (!answer)
            return E_ABORT;
        Password = SZUStringFromNSString(answer);
        PasswordIsDefined = true;
    }
    return StringToBstr(Password, password);
}

}  // namespace

// ---------------------------------------------------------------------------
#pragma mark - method enumeration

static NSArray<SZHashMethod *> *SZEnumerateHashMethods(void)
{
    NSMutableArray<SZHashMethod *> *out = [NSMutableArray array];
    CRecordVector<CMethodId> ids;
    GetHashMethods(ids);
    FOR_VECTOR (i, ids)
    {
        CMyComPtr<IHasher> hasher;
        AString name;
        if (CreateHasher(ids[i], name, hasher) != S_OK || !hasher)
            continue;
        SZHashMethod *m = [SZHashMethod new];
        m->_name = SZStringFromAString(name);
        m->_digestSize = hasher->GetDigestSize();
        [out addObject:m];
    }
    return out;
}

// ---------------------------------------------------------------------------

@interface SZHasher ()
+ (NSString *)methodForDigestLength:(NSUInteger)hexLength extensionHint:(NSString *)extension;
@end

@implementation SZHasher

+ (NSArray<SZHashMethod *> *)availableMethods
{
    static NSArray<SZHashMethod *> *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [SZCodecs loadCodecs:NULL];
        NSString *message = nil;
        NSArray<SZHashMethod *> *list = @[];
        SZRunCatching(&message, [&]() -> HRESULT {
            list = SZEnumerateHashMethods();
            return S_OK;
        });
        cached = list;
    });
    return cached;
}

+ (nullable NSString *)methodNameForMenuID:(NSInteger)menuID
{
    // resource.rc:56-69 / MyLoadMenu.cpp:763-773
    switch (menuID)
    {
        case 101: return @"*";          // IDM_HASH_ALL
        case 102: return @"CRC32";      // IDM_CRC32
        case 103: return @"CRC64";      // IDM_CRC64
        case 104: return @"SHA1";       // IDM_SHA1
        case 105: return @"SHA256";     // IDM_SHA256
        case 106: return @"SHA384";     // IDM_SHA384
        case 107: return @"SHA512";     // IDM_SHA512
        case 108: return @"SHA3-256";   // IDM_SHA3_256
        case 120: return @"XXH64";      // IDM_XXH64
        case 121: return @"BLAKE2sp";   // IDM_BLAKE2SP
        case 122: return @"MD5";        // IDM_MD5
        default: return nil;
    }
}

+ (BOOL)isMethodSupported:(NSString *)method
{
    if ([method isEqualToString:@"*"])
        return self.availableMethods.count != 0;
    for (SZHashMethod *m in self.availableMethods)
        if ([m.name caseInsensitiveCompare:method] == NSOrderedSame)
            return YES;
    return NO;
}

// MARK: - file-system hashing

+ (nullable SZHashResults *)hashPaths:(NSArray<NSString *> *)paths
                       relativeToPath:(nullable NSString *)basePath
                              methods:(NSArray<NSString *> *)methods
                            recursive:(BOOL)recursive
                             progress:(nullable id<SZProgressDelegate>)progress
                                error:(NSError **)error
{
    if (paths.count == 0)
    {
        if (error)
            *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"No items to hash"];
        return nil;
    }
    if (![SZCodecs loadCodecs:error])
        return nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *fullPaths = [NSMutableArray array];
    for (NSString *path in paths)
    {
        NSString *full = path;
        if (![full hasPrefix:@"/"] && basePath.length != 0)
            full = [basePath stringByAppendingPathComponent:path];
        if (!recursive)
        {
            // CDirEnumerator::EnterToDirs = !flatMode: in a flat view the listing already
            // holds every file, so a selected folder must not be walked again.
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir)
                continue;
        }
        [fullPaths addObject:full];
    }
    if (fullPaths.count == 0)
    {
        if (error)
            *error = [SZErrors errorWithCode:SZErrorCodeInvalidArgument message:@"No items to hash"];
        return nil;
    }

    NSString *mainName = nil;
    if (paths.count == 1)
    {
        mainName = paths.firstObject;
        if (basePath.length != 0 && [mainName hasPrefix:basePath])
        {
            mainName = [mainName substringFromIndex:basePath.length];
            while ([mainName hasPrefix:@"/"])
                mainName = [mainName substringFromIndex:1];
        }
    }

    SZHashResults *results = nil;
    NSString *message = nil;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CSZHashCallback callback;
        callback.Delegate = progress;
        callback.FileResults = [NSMutableArray array];
        if (mainName)
            callback.MainName = SZUStringFromNSString(mainName);

        NWildcard::CCensor censor;
        for (NSString *full in fullPaths)
            censor.AddPreItem_NoWildcard(SZUStringFromNSString(full));
        censor.AddPathsToCensor(NWildcard::k_RelatPath);

        CHashOptions options;
        for (NSString *m in methods)
            options.Methods.Add(SZUStringFromNSString(m));
        options.PathMode = NWildcard::k_RelatPath;

        AString errorInfo;
        const HRESULT res = HashCalc(censor, options, errorInfo, &callback);
        if (res != S_OK)
            return res;
        results = callback.Results;
        if (!errorInfo.IsEmpty() && !results)
            return E_FAIL;
        return S_OK;
    });

    if (hr != S_OK || !results)
    {
        if (error)
            *error = SZHasherError(hr == S_OK ? E_FAIL : hr, message);
        return nil;
    }
    return results;
}

// MARK: - archive-member hashing (stream mode)

+ (nullable SZHashResults *)hashItemsInFolder:(SZFolder *)folder
                                    atIndexes:(nullable NSArray<NSNumber *> *)indexes
                                      methods:(NSArray<NSString *> *)methods
                                     progress:(nullable id<SZProgressDelegate>)progress
                                        error:(NSError **)error
{
    if (![SZCodecs loadCodecs:error])
        return nil;

    CMyComPtr<IFolderOperations> ops;
    folder.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&ops);
    if (!ops)
    {
        if (error)
        {
            NSString *base = [SZLang.shared stringForID:6008
                                               fallback:@"The operation is not supported for this folder."];
            *error = [SZErrors errorWithCode:SZErrorCodeNotImplemented
                                     message:[NSString stringWithFormat:@"%@ (%@: CopyTo)", base, folder.folderType]];
        }
        return nil;
    }

    NSMutableArray<NSNumber *> *effective = [NSMutableArray array];
    if (indexes.count == 0)
    {
        const NSInteger n = folder.itemCount;
        for (NSInteger i = 0; i < n; i++)
            [effective addObject:@(i)];
    }
    else
    {
        [effective addObjectsFromArray:indexes];
    }

    NSString *mainName = nil;
    if (effective.count == 1)
    {
        const NSInteger index = effective.firstObject.integerValue;
        mainName = [folder prefixOfItemAtIndex:index] ?: @"";
        mainName = [mainName stringByAppendingString:[folder nameOfItemAtIndex:index] ?: @""];
    }

    SZHashResults *results = nil;
    NSString *message = nil;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CHashBundle hb;
        UStringVector methodNames;
        for (NSString *m in methods)
            methodNames.Add(SZUStringFromNSString(m));
        RINOK(hb.SetMethods(methodNames))
        if (mainName)
            hb.MainName = SZUStringFromNSString(mainName);

        CMyComPtr2<IFolderOperationsExtractCallback, CSZHashStreamCallback> cb;
        cb.Create_if_Empty();
        cb->Delegate = progress;
        cb->ArchivePath = folder.fullPath;
        cb->Hash = &hb;
        cb->FileResults = [NSMutableArray array];
        if (progress && [progress respondsToSelector:@selector(progressSetStatus:)])
            [progress progressSetStatus:SZProgressStatusChecksum];

        CRecordVector<UInt32> indices;
        for (NSNumber *n in effective)
            indices.Add((UInt32)n.unsignedIntegerValue);

        // PanelCopy.cpp:239-266: CopyTo with StreamMode + SetHashMethods, destination unused.
        const HRESULT res = ops->CopyTo(BoolToInt(false), indices.ConstData(), indices.Size(),
            BoolToInt(false), 0, L"", cb.Interface());
        if (res != S_OK)
            return res;
        hb.NumErrors += cb->NumErrors;
        if (hb.NumFiles == 1 && hb.NumDirs == 0 && cb->FileResults.count == 1)
            hb.FirstFileName = SZUStringFromNSString(cb->FileResults.firstObject.path);
        results = SZHashResultsFromBundle(hb, cb->FileResults, nil);
        return S_OK;
    });

    if (hr != S_OK || !results)
    {
        if (error)
            *error = SZHasherError(hr, message);
        return nil;
    }
    return results;
}

// MARK: - checksum files

+ (NSString *)checksumFileNameForPaths:(NSArray<NSString *> *)paths
                        relativeToPath:(nullable NSString *)basePath
                                method:(NSString *)method
{
    // CreateArchiveName(isHash = true): the single item's name, or the folder's name, plus
    // the lower-cased method as extension (03 1.4 C12).
    NSString *extension = [[method stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    NSString *name;
    if (paths.count == 1)
        name = paths.firstObject.lastPathComponent;
    else
        name = (basePath.length != 0 ? basePath.lastPathComponent : @"files");
    if (name.length == 0)
        name = @"files";
    return [name stringByAppendingFormat:@".%@", extension];
}

+ (BOOL)writeChecksumFileAtPath:(NSString *)destinationPath
                       forPaths:(NSArray<NSString *> *)paths
                 relativeToPath:(nullable NSString *)basePath
                         method:(NSString *)method
                      recursive:(BOOL)recursive
                       progress:(nullable id<SZProgressDelegate>)progress
                          error:(NSError **)error
{
    SZHashResults *results = [self hashPaths:paths relativeToPath:basePath methods:@[method]
                                   recursive:recursive progress:progress error:error];
    if (!results)
        return NO;

    // NHash::CHandler::UpdateItems -> WriteLine (HashCalc.cpp:364-431) in the default
    // (no tag, no zero) mode: "<hex>  <name>\n", i.e. GNU coreutils text format.
    NSMutableString *text = [NSMutableString string];
    for (SZHashFileResult *file in results.fileResults)
    {
        if (file.isDirectory)
            continue;
        NSString *digest = file.digests[method];
        if (digest.length == 0)
        {
            for (NSString *key in file.digests)
                if ([key caseInsensitiveCompare:method] == NSOrderedSame)
                    digest = file.digests[key];
        }
        if (digest.length == 0)
            continue;
        NSString *name = [file.path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        name = [name stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        if (![name isEqualToString:file.path])
            [text appendString:@"\\"];
        [text appendFormat:@"%@  %@\n", digest, name];
    }

    NSError *writeError = nil;
    if (![text writeToFile:destinationPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError])
    {
        if (error)
            *error = writeError ?: [SZErrors errorWithCode:SZErrorCodeEngine message:@"Cannot write the checksum file"];
        return NO;
    }
    return YES;
}

+ (nullable SZChecksumVerification *)verifyChecksumFileAtPath:(NSString *)path
                                                     progress:(nullable id<SZProgressDelegate>)progress
                                                        error:(NSError **)error
{
    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content)
    {
        if (error)
            *error = readError ?: [SZErrors errorWithCode:SZErrorCodeFileNotFound message:path];
        return nil;
    }
    if (![SZCodecs loadCodecs:error])
        return nil;

    NSString *directory = path.stringByDeletingLastPathComponent;
    NSString *extensionMethod = path.pathExtension;
    NSMutableArray<NSString *> *messages = [NSMutableArray array];
    NSMutableSet<NSString *> *methodsUsed = [NSMutableSet set];
    NSUInteger numOK = 0, numFailed = 0, numMissing = 0, numUnsupported = 0;

    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet characterSetWithCharactersInString:@"\n\r\0"]];
    uint64_t totalLines = 0;
    for (NSString *raw in lines)
        if (raw.length != 0)
            totalLines++;
    if (progress)
        [progress progressSetTotal:totalLines];
    uint64_t done = 0;

    for (NSString *raw in lines)
    {
        NSString *line = raw;
        if (line.length == 0)
            continue;
        if (progress)
        {
            if ([progress progressCheckBreak])
            {
                if (error)
                    *error = [SZErrors errorWithCode:SZErrorCodeCancelled message:@"cancelled"];
                return nil;
            }
            [progress progressSetCompleted:done++];
        }
        if ([line hasPrefix:@"#"] || [line hasPrefix:@";"])
            continue;

        NSString *digest = nil, *name = nil, *method = nil;
        BOOL escaped = NO;
        if ([line hasPrefix:@"\\"])
        {
            escaped = YES;
            line = [line substringFromIndex:1];
        }
        const NSRange equals = [line rangeOfString:@") = "];
        const NSRange paren = [line rangeOfString:@" ("];
        if (equals.location != NSNotFound && paren.location != NSNotFound && paren.location < equals.location)
        {
            // BSD tag form: "SHA256 (name) = <hex>"
            method = [line substringToIndex:paren.location];
            name = [line substringWithRange:NSMakeRange(paren.location + 2,
                                                        equals.location - (paren.location + 2))];
            digest = [line substringFromIndex:equals.location + equals.length];
            method = [method stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        }
        else
        {
            // "<hex>  <name>" / "<hex> *<name>"
            const NSRange space = [line rangeOfString:@" "];
            if (space.location == NSNotFound)
            {
                numUnsupported++;
                [messages addObject:[NSString stringWithFormat:@"%@ : %@", line, @"Unsupported line"]];
                continue;
            }
            digest = [line substringToIndex:space.location];
            NSString *rest = [line substringFromIndex:space.location];
            while ([rest hasPrefix:@" "])
                rest = [rest substringFromIndex:1];
            if ([rest hasPrefix:@"*"])
                rest = [rest substringFromIndex:1];
            name = rest;
        }
        if (escaped)
        {
            name = [name stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
            name = [name stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
        }
        if (name.length == 0 || digest.length == 0 || [name hasSuffix:@"/"])
            continue;

        if (method.length == 0)
            method = [self methodForDigestLength:digest.length extensionHint:extensionMethod];
        if (method.length == 0 || ![self isMethodSupported:method])
        {
            numUnsupported++;
            [messages addObject:[NSString stringWithFormat:@"%@ : Unsupported hash method", name]];
            continue;
        }
        [methodsUsed addObject:method];

        NSString *full = [name hasPrefix:@"/"] ? name : [directory stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:full])
        {
            numMissing++;
            // CExtractCallbackImp wording for a missing item.
            [messages addObject:[NSString stringWithFormat:@"%@ : %@", name,
                                 @"Cannot find the file"]];
            continue;
        }
        SZHashResults *one = [self hashPaths:@[full] relativeToPath:directory methods:@[method]
                                   recursive:NO progress:nil error:nil];
        NSString *actual = one.fileResults.firstObject.digests[method];
        if (actual.length == 0)
            actual = one.dataDigests[method];
        if (actual.length != 0 && [actual caseInsensitiveCompare:digest] == NSOrderedSame)
        {
            numOK++;
        }
        else
        {
            numFailed++;
            [messages addObject:[NSString stringWithFormat:@"%@ : %@", name,
                                 // IDS_EXTRACT_MSG_CRC_ERROR 3723
                                 [SZLang.shared stringForID:3723 fallback:@"CRC failed"]]];
        }
    }

    SZChecksumVerification *v = [SZChecksumVerification new];
    v->_numOK = numOK;
    v->_numFailed = numFailed;
    v->_numMissing = numMissing;
    v->_numUnsupported = numUnsupported;
    v->_messages = messages;
    v->_methodNames = methodsUsed.allObjects;
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"%@: %lu\n", SZLangText(kLangID_PropFiles, @"Files"), (unsigned long)(numOK + numFailed)];
    if (numFailed + numMissing + numUnsupported != 0)
        [text appendFormat:@"%@: %lu\n", SZLangText(kLangID_PropNumErrors, @"Errors"),
         (unsigned long)(numFailed + numMissing + numUnsupported)];
    else
        [text appendFormat:@"\n%@\n", SZLangText(kLangID_MessageNoErrors, @"There are no errors")];
    v->_text = text;
    return v;
}

/// Method for a bare "<hex> name" line: the file's extension when it names a hasher,
/// otherwise the only registered hasher with that digest length.
+ (NSString *)methodForDigestLength:(NSUInteger)hexLength extensionHint:(NSString *)extension
{
    if (extension.length != 0)
        for (SZHashMethod *m in self.availableMethods)
        {
            NSString *bare = [m.name stringByReplacingOccurrencesOfString:@"-" withString:@""];
            if ([bare caseInsensitiveCompare:extension] == NSOrderedSame && m.digestSize * 2 == hexLength)
                return m.name;
        }
    NSString *found = nil;
    for (SZHashMethod *m in self.availableMethods)
        if (m.digestSize * 2 == hexLength)
        {
            if (found)
                continue;             // ambiguous; the first registered one wins, like the engine
            found = m.name;
        }
    return found ?: @"";
}

@end

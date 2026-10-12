// SZCallbackAdapters.mm -- see SZCallbackAdapters.h.
// Ported from FileManager/ExtractCallback.cpp (CExtractCallbackImp) and
// FileManager/UpdateCallback100.cpp + GUI/UpdateCallbackGUI2.cpp (CUpdateCallback100Imp),
// with the CProgressSync/CProgressDialog pair replaced by an id<SZProgressDelegate>.

#import "SZCallbackAdapters.h"
#import "SZBridgeUtils.h"
#import "SZError.h"

// CPP/7zip/Common/FilePathAutoRename.cpp (not pulled in by SZEngine.h):
// "name.ext" -> "name (2).ext" ... used for the Auto Rename answer.
bool AutoRenamePath(FString &fullProcessedPath);

using namespace NWindows;
using namespace NWindows::NFile;

// SZOverwriteAnswer must mirror NOverwriteAnswer (IFileExtractCallback.h:22-34) one-to-one,
// and SZOperationResult must mirror NArchive::NExtract::NOperationResult.
static_assert((int)SZOverwriteAnswerYes == (int)NOverwriteAnswer::kYes, "answer order");
static_assert((int)SZOverwriteAnswerYesToAll == (int)NOverwriteAnswer::kYesToAll, "answer order");
static_assert((int)SZOverwriteAnswerNo == (int)NOverwriteAnswer::kNo, "answer order");
static_assert((int)SZOverwriteAnswerNoToAll == (int)NOverwriteAnswer::kNoToAll, "answer order");
static_assert((int)SZOverwriteAnswerAutoRename == (int)NOverwriteAnswer::kAutoRename, "answer order");
static_assert((int)SZOverwriteAnswerCancel == (int)NOverwriteAnswer::kCancel, "answer order");
static_assert((int)SZOperationResultWrongPassword == (int)NArchive::NExtract::NOperationResult::kWrongPassword, "opRes order");

/// FILETIME -> NSDate (same conversion as SZDateFromPropVariant, without the PROPVARIANT).
static NSDate *SZDateFromFileTime(const FILETIME *ft)
{
  if (!ft || (ft->dwLowDateTime == 0 && ft->dwHighDateTime == 0))
    return nil;
  UInt32 quantums = 0;
  const Int64 sec = NTime::FileTime_To_UnixTime64_and_Quantums(*ft, quantums);
  return [NSDate dateWithTimeIntervalSince1970:(double)sec + (double)quantums / 10000000.0];
}

// ---------------------------------------------------------------------------
// CSZCallbackBase
// ---------------------------------------------------------------------------

void CSZCallbackBase::ShowMessage(NSString *message) const
{
  if (Delegate && message)
    [Delegate progressShowMessage:message];
}

void CSZCallbackBase::ShowMessage(const wchar_t *message) const
{
  if (!message)
    return;
  ShowMessage(SZStringFromUString(UString(message)));
}

void CSZCallbackBase::ShowMessageWithName(NSString *message, const wchar_t *name) const
{
  // CProgressSync::AddError_Message_Name (ProgressDialog2.cpp:228): "<msg> : <name>"
  if (!message)
    return;
  if (name && *name)
    message = [NSString stringWithFormat:@"%@ : %@", message, SZStringFromUString(UString(name))];
  ShowMessage(message);
}

void CSZCallbackBase::ShowErrorCodeWithName(HRESULT errorCode, const wchar_t *name) const
{
  // CProgressSync::AddError_Code_Name (ProgressDialog2.cpp:244) + HResultToMessage
  ShowMessageWithName([SZErrors messageForHRESULT:(uint32_t)errorCode], name);
}

void CSZCallbackBase::SetStatus(SZProgressStatus status) const
{
  if (Delegate && [Delegate respondsToSelector:@selector(progressSetStatus:)])
    [Delegate progressSetStatus:status];
}

void CSZCallbackBase::SetTotalFiles(UInt64 numFiles) const
{
  if (Delegate && [Delegate respondsToSelector:@selector(progressSetTotalFiles:)])
    [Delegate progressSetTotalFiles:numFiles];
}

void CSZCallbackBase::SetCurrentFile(const wchar_t *path, bool isDir) const
{
  if (Delegate)
    [Delegate progressSetCurrentFile:(path ? SZStringFromUString(UString(path)) : @"")
                        isDirectory:isDir ? YES : NO];
}

void CSZCallbackBase::ReportOperationResult(Int32 opRes, Int32 encrypted, const wchar_t *name) const
{
  NSString *path = name ? SZStringFromUString(UString(name)) : @"";
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    // SetExtractErrorMessage (ExtractCallback.cpp:277-413, lang IDs 3721-3729 + 3710)
    UString s;
    SetExtractErrorMessage(opRes, encrypted, name ? name : L"", s);
    if (!s.IsEmpty())
      ShowMessage(SZStringFromUString(s));
  }
  if (Delegate)
    [Delegate progressSetOperationResult:(SZOperationResult)opRes path:path isEncrypted:encrypted ? YES : NO];
}

HRESULT CSZCallbackBase::AskPassword(BSTR *password)
{
  // CExtractCallbackImp::CryptoGetTextPassword (ExtractCallback.cpp:683-708): ask once,
  // then reuse the answer for the rest of the run.
  *password = NULL;
  PasswordWasAsked = true;
  if (!PasswordIsDefined)
  {
    if (!Delegate)
      return E_ABORT;
    NSString *p = [Delegate progressAskPasswordForPath:(ArchivePath ?: @"")];
    if (!p)
      return E_ABORT;
    Password = SZUStringFromNSString(p);
    PasswordIsDefined = true;
  }
  return StringToBstr(Password, password);
}

// ---------------------------------------------------------------------------
// CSZExtractCallbackAdapter -- IProgress
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetTotal(UInt64 total))
{
  RINOK(CheckBreak())
  if (Delegate)
    [Delegate progressSetTotal:total];
  return S_OK;
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetCompleted(const UInt64 *completeValue))
{
  RINOK(CheckBreak())
  if (completeValue && Delegate)
    [Delegate progressSetCompleted:*completeValue];
  return S_OK;
}

// ---------------------------------------------------------------------------
// CSZExtractCallbackAdapter -- IFolderArchiveExtractCallback
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZExtractCallbackAdapter::AskOverwrite(
    const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
    const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
    Int32 *answer))
{
  // ExtractCallback.cpp:201-233. Only kAsk reaches the dialog; the other modes answer
  // silently, and "to all" answers switch the mode for the rest of the operation.
  RINOK(CheckBreak())
  switch ((int)OverwriteMode)
  {
    case NExtract::NOverwriteMode::kOverwrite: *answer = NOverwriteAnswer::kYes; return S_OK;
    case NExtract::NOverwriteMode::kSkip:      *answer = NOverwriteAnswer::kNo; return S_OK;
    case NExtract::NOverwriteMode::kRename:    *answer = NOverwriteAnswer::kAutoRename; return S_OK;
    case NExtract::NOverwriteMode::kRenameExisting: *answer = NOverwriteAnswer::kAutoRename; return S_OK;
    default: break;
  }
  if (!Delegate)
  {
    *answer = NOverwriteAnswer::kYes;
    return S_OK;
  }

  NSString *suggested = nil;
  SuggestedName.Empty();
  const SZOverwriteAnswer a = [Delegate
      progressAskOverwriteExisting:(existName ? SZStringFromUString(UString(existName)) : @"")
                        existTime:SZDateFromFileTime(existTime)
                        existSize:(existSize ? @(*existSize) : nil)
                          newName:(newName ? SZStringFromUString(UString(newName)) : @"")
                          newTime:SZDateFromFileTime(newTime)
                          newSize:(newSize ? @(*newSize) : nil)
                    suggestedName:&suggested];

  switch (a)
  {
    case SZOverwriteAnswerCancel:    return E_ABORT;
    case SZOverwriteAnswerYesToAll:  OverwriteMode = NExtract::NOverwriteMode::kOverwrite; break;
    case SZOverwriteAnswerNoToAll:   OverwriteMode = NExtract::NOverwriteMode::kSkip; break;
    case SZOverwriteAnswerAutoRename:
      OverwriteMode = NExtract::NOverwriteMode::kRename;
      if (suggested.length != 0)
        SuggestedName = SZUStringFromNSString(suggested);
      break;
    default: break;
  }
  *answer = (Int32)a;   // SZOverwriteAnswer mirrors NOverwriteAnswer one-to-one
  return S_OK;
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::PrepareOperation(
    const wchar_t *name, Int32 isFolder, Int32 askExtractMode, const UInt64 *position))
{
  // ExtractCallback.cpp:235: status line + current file.
  UNUSED_VAR(position)
  RINOK(CheckBreak())
  _isFolder = IntToBool(isFolder);
  SZProgressStatus status = TestMode ? SZProgressStatusTesting : SZProgressStatusExtracting;
  switch (askExtractMode)
  {
    case NArchive::NExtract::NAskMode::kExtract: break;
    case NArchive::NExtract::NAskMode::kTest:    status = SZProgressStatusTesting; break;
    case NArchive::NExtract::NAskMode::kSkip:    status = SZProgressStatusSkipping; break;
    default: break;
  }
  SetStatus(status);
  CurrentFilePath = name ? UString(name) : UString();
  SetCurrentFile(name, _isFolder);
  return S_OK;
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::MessageError(const wchar_t *message))
{
  NumErrors++;
  CSZCallbackBase::ShowMessage(message);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetOperationResult(Int32 opRes, Int32 encrypted))
{
  // ExtractCallback.cpp:375-413: count the file, turn a bad result into a message.
  NumFilesProcessed++;
  if (Delegate)
    [Delegate progressSetNumFilesProcessed:NumFilesProcessed];
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    NumErrors++;
    if (FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
      FirstBadOpRes = opRes;
  }
  ReportOperationResult(opRes, encrypted, CurrentFilePath.IsEmpty() ? NULL : CurrentFilePath.Ptr());
  return CheckBreak();
}

// IFolderArchiveExtractCallback2
Z7_COM7F_IMF(CSZExtractCallbackAdapter::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    NumErrors++;
    if (FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
      FirstBadOpRes = opRes;
  }
  ReportOperationResult(opRes, encrypted, name);
  return CheckBreak();
}

// ---------------------------------------------------------------------------
// CSZExtractCallbackAdapter -- IFolderOperationsExtractCallback (file-system copy path)
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZExtractCallbackAdapter::AskWrite(
    const wchar_t *srcPath, Int32 srcIsFolder,
    const FILETIME *srcTime, const UInt64 *srcSize,
    const wchar_t *destPath, BSTR *destPathResult, Int32 *writeAnswer))
{
  // Verbatim port of CExtractCallbackImp::AskWrite (ExtractCallback.cpp:710-800).
  RINOK(CheckBreak())
  UString destPathResultTemp = destPath;
  *destPathResult = NULL;
  *writeAnswer = BoolToInt(false);

  FString destPathSys = us2fs(destPath);
  const bool srcIsFolderSpec = IntToBool(srcIsFolder);
  NFind::CFileInfo destFileInfo;

  if (destFileInfo.Find(destPathSys))
  {
    if (srcIsFolderSpec)
    {
      if (!destFileInfo.IsDir())
      {
        ShowMessageWithName(@"Cannot replace file with folder with same name", destPath);
        return E_ABORT;
      }
      *writeAnswer = BoolToInt(false);
      return S_OK;
    }

    if (destFileInfo.IsDir())
    {
      ShowMessageWithName(@"Cannot replace folder with file with same name", destPath);
      *writeAnswer = BoolToInt(false);
      return S_OK;
    }

    switch ((int)OverwriteMode)
    {
      case NExtract::NOverwriteMode::kSkip:
        return S_OK;
      case NExtract::NOverwriteMode::kAsk:
      {
        Int32 overwriteResult;
        UString destPathSpec = destPath;
        const int slashPos = destPathSpec.ReverseFind_PathSepar();
        destPathSpec.DeleteFrom((unsigned)(slashPos + 1));
        destPathSpec += fs2us(destFileInfo.Name);

        // CFileInfo::MTime is a CFiTime (timespec) on macOS; the callback speaks FILETIME.
        FILETIME destMTime;
        ::FiTime_To_FILETIME(destFileInfo.MTime, destMTime);
        RINOK(AskOverwrite(destPathSpec, &destMTime, &destFileInfo.Size,
            srcPath, srcTime, srcSize, &overwriteResult))

        switch (overwriteResult)
        {
          case NOverwriteAnswer::kCancel: return E_ABORT;
          case NOverwriteAnswer::kNo: return S_OK;
          case NOverwriteAnswer::kNoToAll: OverwriteMode = NExtract::NOverwriteMode::kSkip; return S_OK;
          case NOverwriteAnswer::kYes: break;
          case NOverwriteAnswer::kYesToAll: OverwriteMode = NExtract::NOverwriteMode::kOverwrite; break;
          case NOverwriteAnswer::kAutoRename: OverwriteMode = NExtract::NOverwriteMode::kRename; break;
          default: return E_FAIL;
        }
        break;
      }
      default: break;
    }

    if (OverwriteMode == NExtract::NOverwriteMode::kRename)
    {
      // The Overwrite dialog may hand back the name it showed for "Auto Rename"; a bare
      // name replaces the last path component, a full path is taken as is.
      if (!SuggestedName.IsEmpty())
      {
        UString s = SuggestedName;
        if (s.ReverseFind_PathSepar() < 0)
        {
          UString dir (destPath);
          dir.DeleteFrom((unsigned)(dir.ReverseFind_PathSepar() + 1));
          s.Insert(0, dir);
        }
        destPathSys = us2fs(s);
        SuggestedName.Empty();
      }
      else if (!AutoRenamePath(destPathSys))
      {
        ShowMessageWithName(@"Cannot create name for file", destPath);
        return E_ABORT;
      }
      destPathResultTemp = fs2us(destPathSys);
    }
    else
    {
      if (NFind::DoesFileExist_Raw(destPathSys))
        if (!NDir::DeleteFileAlways(destPathSys))
          if (errno != ENOENT)
          {
            ShowMessageWithName(@"Cannot delete output file", destPath);
            return E_ABORT;
          }
    }
  }
  *writeAnswer = BoolToInt(true);
  return StringToBstr(destPathResultTemp, destPathResult);
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::ShowMessage(const wchar_t *message))
{
  NumErrors++;
  CSZCallbackBase::ShowMessage(message);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetCurrentFilePath(const wchar_t *filePath))
{
  RINOK(CheckBreak())
  CurrentFilePath = filePath ? UString(filePath) : UString();
  SetCurrentFile(filePath, false);
  return S_OK;
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetNumFiles(UInt64 numFiles))
{
  RINOK(CheckBreak())
  SetTotalFiles(numFiles);
  return S_OK;
}

// ---------------------------------------------------------------------------
// CSZExtractCallbackAdapter -- ICryptoGetTextPassword / ICompressProgressInfo
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZExtractCallbackAdapter::CryptoGetTextPassword(BSTR *password))
{
  RINOK(CheckBreak())
  return AskPassword(password);
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize))
{
  RINOK(CheckBreak())
  if (Delegate && (inSize || outSize))
    [Delegate progressSetRatioInfoInSize:(inSize ? *inSize : 0) outSize:(outSize ? *outSize : 0)];
  return S_OK;
}

// ---------------------------------------------------------------------------
// CSZExtractCallbackAdapter -- IArchiveRequestMemoryUseCallback (IDD_MEM 7800, 01b 4.12)
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZExtractCallbackAdapter::RequestMemoryUse(
    UInt32 flags, UInt32 indexType, UInt32 index, const wchar_t *path,
    UInt64 requiredSize, UInt64 *allowedSize, UInt32 *answerFlags))
{
  // Port of CExtractCallbackImp::RequestMemoryUse (ExtractCallback.cpp:1012-1120).
  UNUSED_VAR(index)
  const bool isReport = (flags & NRequestMemoryUseFlags::k_IsReport) != 0;
  UInt32 limit_GB = (UInt32)((*allowedSize + ((1u << 30) - 1)) >> 30);

  if (!isReport)
  {
    UInt64 limit_bytes = *allowedSize;
    const UInt32 limit_GB_Registry = NExtract::Read_LimitGB();   // settings key Extraction/MemLimit
    if (limit_GB_Registry != 0 && limit_GB_Registry != (UInt32)(Int32)-1)
    {
      const UInt64 limit_bytes_Registry = (UInt64)limit_GB_Registry << 30;
      if ((flags & NRequestMemoryUseFlags::k_AllowedSize_WasForced) == 0
          || limit_bytes < limit_bytes_Registry)
      {
        limit_bytes = limit_bytes_Registry;
        limit_GB = limit_GB_Registry;
      }
    }
    *allowedSize = limit_bytes;
    if (requiredSize <= limit_bytes)
    {
      *answerFlags = NRequestMemoryAnswerFlags::k_Allow;
      return S_OK;
    }
    *answerFlags = NRequestMemoryAnswerFlags::k_Limit_Exceeded;
    if (flags & NRequestMemoryUseFlags::k_SkipArc_IsExpected)
      *answerFlags |= NRequestMemoryAnswerFlags::k_SkipArc;
  }

  bool skipArc = false;
  if (!isReport && Delegate
      && [Delegate respondsToSelector:@selector(progressRequestMemoryUseForPath:requiredSize:allowedSize:testMode:allowSkipArchive:)])
  {
    SZMemoryUseAnswer answer;
    if (MemoryUseRemembered)
      answer = MemoryUseRememberedAnswer;
    else
    {
      uint64_t allowed = (uint64_t)limit_GB << 30;
      answer = [Delegate progressRequestMemoryUseForPath:(path ? SZStringFromUString(UString(path)) : ArchivePath)
                                           requiredSize:requiredSize
                                            allowedSize:&allowed
                                               testMode:TestMode ? YES : NO
                                       allowSkipArchive:((flags & NRequestMemoryUseFlags::k_SkipArc_IsExpected) != 0
                                                          || indexType != NArchive::NEventIndexType::kNoIndex
                                                          || path != NULL) ? YES : NO];
      *allowedSize = allowed;
    }
    if (answer == SZMemoryUseAnswerStop)
    {
      *answerFlags = NRequestMemoryAnswerFlags::k_Stop;
      return E_ABORT;
    }
    skipArc = (answer == SZMemoryUseAnswerSkipArchive);
    if (!skipArc)
    {
      *answerFlags = NRequestMemoryAnswerFlags::k_Allow;
      return S_OK;
    }
    *answerFlags = NRequestMemoryAnswerFlags::k_SkipArc | NRequestMemoryAnswerFlags::k_Limit_Exceeded;
    flags |= NRequestMemoryUseFlags::k_Report_SkipArc;
  }

  if ((flags & NRequestMemoryUseFlags::k_NoErrorMessage) == 0)
  {
    // CMemDialog::AddInfoMessage_To_String equivalent (lang 7811/7812/7813 + 7822)
    UString s;
    MyLoadString(7811, s);                                  // IDS_MEM_REQUIRES_BIG_MEM
    NSMutableString *text = [NSMutableString stringWithFormat:@"ERROR: %@", SZStringFromUString(s)];
    MyLoadString(7812, s);                                  // IDS_MEM_REQUIRED_MEM_SIZE
    [text appendFormat:@"\n    %llu GB : %@",
        (unsigned long long)((requiredSize + ((1u << 30) - 1)) >> 30), SZStringFromUString(s)];
    MyLoadString(7813, s);                                  // IDS_MEM_CURRENT_MEM_LIMIT
    [text appendFormat:@"\n    %u GB : %@", (unsigned)limit_GB, SZStringFromUString(s)];
    if (path)
      [text appendFormat:@"\nFile: %@", SZStringFromUString(UString(path))];
    if ((flags & NRequestMemoryUseFlags::k_SkipArc_IsExpected)
        || (flags & NRequestMemoryUseFlags::k_Report_SkipArc))
    {
      MyLoadString(7822, s);                                // IDS_MSG_ARC_UNPACKING_WAS_SKIPPED
      [text appendFormat:@"\n%@", SZStringFromUString(s)];
    }
    NumErrors++;
    CSZCallbackBase::ShowMessage((NSString *)text);
  }
  return S_OK;
}

// ---------------------------------------------------------------------------
// CSZExtractCallbackAdapter -- IArchiveOpenCallback (nested / re-open)
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetTotal(const UInt64 * /* files */, const UInt64 * /* bytes */))
{
  return CheckBreak();
}

Z7_COM7F_IMF(CSZExtractCallbackAdapter::SetCompleted(const UInt64 * /* files */, const UInt64 * /* bytes */))
{
  return CheckBreak();
}

// ---------------------------------------------------------------------------
// CSZUpdateCallbackAdapter
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::SetTotal(UInt64 total))
{
  RINOK(CheckBreak())
  if (Delegate)
    [Delegate progressSetTotal:total];
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::SetCompleted(const UInt64 *completeValue))
{
  RINOK(CheckBreak())
  if (completeValue && Delegate)
    [Delegate progressSetCompleted:*completeValue];
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::CompressOperation(const wchar_t *name))
{
  // CUpdateCallbackAgent::CompressOperation -> "Compressing <name>"
  RINOK(CheckBreak())
  SetStatus(SZProgressStatusCompressing);
  SetCurrentFile(name, false);
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::DeleteOperation(const wchar_t *name))
{
  RINOK(CheckBreak())
  SetStatus(SZProgressStatusDelete);
  SetCurrentFile(name, false);
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::OperationResult(Int32 opRes))
{
  NumFilesProcessed++;
  if (Delegate)
    [Delegate progressSetNumFilesProcessed:NumFilesProcessed];
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    NumErrors++;
    if (FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
      FirstBadOpRes = opRes;
    ReportOperationResult(opRes, 0, NULL);
  }
  return CheckBreak();
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::UpdateErrorMessage(const wchar_t *message))
{
  NumErrors++;
  CSZCallbackBase::ShowMessage(message);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::SetNumFiles(UInt64 numFiles))
{
  RINOK(CheckBreak())
  SetTotalFiles(numFiles);
  return S_OK;
}

// IFolderArchiveUpdateCallback2
Z7_COM7F_IMF(CSZUpdateCallbackAdapter::OpenFileError(const wchar_t *path, HRESULT errorCode))
{
  // UpdateCallbackGUI2: non-fatal, the file is skipped (S_FALSE) and counted.
  NumErrors++;
  ShowErrorCodeWithName(errorCode, path);
  RINOK(CheckBreak())
  return S_FALSE;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::ReadingFileError(const wchar_t *path, HRESULT errorCode))
{
  NumErrors++;
  ShowErrorCodeWithName(errorCode, path);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t *path))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    NumErrors++;
    if (FirstBadOpRes == NArchive::NExtract::NOperationResult::kOK)
      FirstBadOpRes = opRes;
  }
  ReportOperationResult(opRes, isEncrypted, path);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::ReportUpdateOperation(UInt32 notifyOp, const wchar_t *path, Int32 isDir))
{
  // k_UpdNotifyLangs (UpdateCallbackGUI2.cpp:17-27) mapped onto SZProgressStatus.
  RINOK(CheckBreak())
  SZProgressStatus status = SZProgressStatusCompressing;
  switch (notifyOp)
  {
    case NUpdateNotifyOp::kAdd:        status = SZProgressStatusAdd; break;
    case NUpdateNotifyOp::kUpdate:     status = SZProgressStatusUpdate; break;
    case NUpdateNotifyOp::kAnalyze:    status = SZProgressStatusAnalyze; break;
    case NUpdateNotifyOp::kReplicate:  status = SZProgressStatusReplicate; break;
    case NUpdateNotifyOp::kRepack:     status = SZProgressStatusRepack; break;
    case NUpdateNotifyOp::kSkip:       status = SZProgressStatusSkipping; break;
    case NUpdateNotifyOp::kDelete:     status = SZProgressStatusDelete; break;
    case NUpdateNotifyOp::kHeader:     status = SZProgressStatusHeader; break;
    default: break;
  }
  SetStatus(status);
  SetCurrentFile(path, IntToBool(isDir));
  return S_OK;
}

// IFolderScanProgress
Z7_COM7F_IMF(CSZUpdateCallbackAdapter::ScanError(const wchar_t *path, HRESULT errorCode))
{
  NumErrors++;
  ShowErrorCodeWithName(errorCode, path);
  return CheckBreak();
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::ScanProgress(UInt64 numFolders, UInt64 numFiles,
    UInt64 totalSize, const wchar_t *path, Int32 isDir))
{
  RINOK(CheckBreak())
  SetStatus(SZProgressStatusScanning);
  if (Delegate && [Delegate respondsToSelector:@selector(progressScanFolders:files:totalSize:path:isDirectory:)])
    [Delegate progressScanFolders:numFolders
                            files:numFiles
                        totalSize:totalSize
                             path:(path ? SZStringFromUString(UString(path)) : @"")
                      isDirectory:IntToBool(isDir) ? YES : NO];
  else
    SetCurrentFile(path, IntToBool(isDir));
  return S_OK;
}

// IFolderArchiveUpdateCallback_MoveArc (ArchiveFolderOut.cpp:195-241)
Z7_COM7F_IMF(CSZUpdateCallbackAdapter::MoveArc_Start(const wchar_t *srcTempPath,
    const wchar_t *destFinalPath, UInt64 size, Int32 updateMode))
{
  UNUSED_VAR(updateMode)
  RINOK(CheckBreak())
  SetStatus(SZProgressStatusMoving);
  if (Delegate && [Delegate respondsToSelector:@selector(progressMoveArchiveFrom:toPath:size:)])
    [Delegate progressMoveArchiveFrom:(srcTempPath ? SZStringFromUString(UString(srcTempPath)) : @"")
                              toPath:(destFinalPath ? SZStringFromUString(UString(destFinalPath)) : @"")
                                size:size];
  else
    SetCurrentFile(destFinalPath, false);
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::MoveArc_Progress(UInt64 totalSize, UInt64 currentSize))
{
  RINOK(CheckBreak())
  if (Delegate && [Delegate respondsToSelector:@selector(progressMoveArchiveCompleted:total:)])
    [Delegate progressMoveArchiveCompleted:currentSize total:totalSize];
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::MoveArc_Finish())
{
  if (Delegate && [Delegate respondsToSelector:@selector(progressMoveArchiveFinished)])
    [Delegate progressMoveArchiveFinished];
  return S_OK;
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::Before_ArcReopen())
{
  // The caller wants to re-open the archive, so the user-break state must be cleared
  // (UpdateCallback100.cpp:124-128 -> Sync.Clear_Stop_Status()).
  if (Delegate && [Delegate respondsToSelector:@selector(progressClearCancelState)])
    [Delegate progressClearCancelState];
  return S_OK;
}

// ICryptoGetTextPassword / 2
Z7_COM7F_IMF(CSZUpdateCallbackAdapter::CryptoGetTextPassword(BSTR *password))
{
  RINOK(CheckBreak())
  return AskPassword(password);
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password))
{
  // CUpdateCallbackGUI2::CryptoGetTextPassword2: ask only when the caller asked us to
  // (-p without a value); otherwise hand over the password we already have.
  RINOK(CheckBreak())
  *password = NULL;
  *passwordIsDefined = BoolToInt(false);
  if (!PasswordIsDefined && AskPasswordForEncryption && Delegate
      && [Delegate respondsToSelector:@selector(progressAskPasswordForEncryptionCancelled:)])
  {
    BOOL cancelled = NO;
    NSString *p = [Delegate progressAskPasswordForEncryptionCancelled:&cancelled];
    if (cancelled)
      return E_ABORT;
    PasswordWasAsked = true;
    if (p)
    {
      Password = SZUStringFromNSString(p);
      PasswordIsDefined = true;
    }
  }
  if (!PasswordIsDefined)
    return S_OK;
  *passwordIsDefined = BoolToInt(true);
  return StringToBstr(Password, password);
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize))
{
  RINOK(CheckBreak())
  if (Delegate && (inSize || outSize))
    [Delegate progressSetRatioInfoInSize:(inSize ? *inSize : 0) outSize:(outSize ? *outSize : 0)];
  return S_OK;
}

// IArchiveOpenCallback (the ReOpen that CommonUpdateOperation performs)
Z7_COM7F_IMF(CSZUpdateCallbackAdapter::SetTotal(const UInt64 * /* files */, const UInt64 * /* bytes */))
{
  return CheckBreak();
}

Z7_COM7F_IMF(CSZUpdateCallbackAdapter::SetCompleted(const UInt64 * /* files */, const UInt64 * /* bytes */))
{
  return CheckBreak();
}

// ---------------------------------------------------------------------------
// CSZProgressAdapter
// ---------------------------------------------------------------------------

Z7_COM7F_IMF(CSZProgressAdapter::SetTotal(UInt64 total))
{
  RINOK(CheckBreak())
  if (Delegate)
    [Delegate progressSetTotal:total];
  return S_OK;
}

Z7_COM7F_IMF(CSZProgressAdapter::SetCompleted(const UInt64 *completeValue))
{
  RINOK(CheckBreak())
  if (completeValue && Delegate)
    [Delegate progressSetCompleted:*completeValue];
  return S_OK;
}

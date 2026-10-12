// SZCallbackAdapters.h -- C++ (COM) callback objects that forward the engine's operation
// callbacks to an `id<SZProgressDelegate>`. Objective-C++ only; never visible to Swift.
//
// They replace the Windows CExtractCallbackImp (FileManager/ExtractCallback.cpp) and
// CUpdateCallback100Imp / CUpdateCallbackGUI (FileManager/UpdateCallback100.cpp,
// GUI/UpdateCallbackGUI*.cpp) — see 01-fm-feature-inventory.md 8.4/8.5/8.7 and
// 02-engine-api.md 2.5.
//
// OWNERSHIP RULE (important): CMyUnknownImp reference counts are plain `++`/`--`
// (MyCom.h:380, Z7_COM_USE_ATOMIC is *not* defined), so an adapter must be created,
// used and released on ONE thread — the worker thread that runs the operation. Always
// hold it in a `CMyComPtr<>` local to that thread and never hand it to another thread
// or to Objective-C code that might outlive the call. The delegate itself is retained
// (ARC `__strong`) for the lifetime of the adapter and is called on that same thread.
//
// Every entry point first polls the delegate's `progressCheckBreak` (CheckBreak()), so
// cancelling returns E_ABORT everywhere and pausing blocks inside the delegate exactly
// like CProgressSync::CheckStop (ProgressDialog2.cpp:100-110).

#ifndef SZ_CALLBACK_ADAPTERS_H
#define SZ_CALLBACK_ADAPTERS_H

#import <Foundation/Foundation.h>
#import "SZProgressDelegate.h"
#include "SZEngine.h"

// ---------------------------------------------------------------------------
/// Delegate holder + the pieces every adapter shares.
class CSZCallbackBase
{
public:
  __strong id<SZProgressDelegate> Delegate;

  CSZCallbackBase(): Delegate(nil) {}

  /// CProgressSync::CheckStop: E_ABORT when the delegate asked to stop. The delegate
  /// blocks inside progressCheckBreak while paused.
  HRESULT CheckBreak() const
  {
    if (Delegate && [Delegate progressCheckBreak])
      return E_ABORT;
    return S_OK;
  }

  void ShowMessage(const wchar_t *message) const;
  void ShowMessage(NSString *message) const;
  /// "<message> : <path>" (CProgressSync::AddError_Message_Name, ProgressDialog2.cpp:228).
  void ShowMessageWithName(NSString *message, const wchar_t *name) const;
  /// HResultToMessage + name (AddError_Code_Name, ProgressDialog2.cpp:244).
  void ShowErrorCodeWithName(HRESULT errorCode, const wchar_t *name) const;
  void SetStatus(SZProgressStatus status) const;
  void SetTotalFiles(UInt64 numFiles) const;
  void SetCurrentFile(const wchar_t *path, bool isDir) const;
  /// SetExtractErrorMessage + progressSetOperationResult (ExtractCallback.cpp:375-413).
  void ReportOperationResult(Int32 opRes, Int32 encrypted, const wchar_t *name) const;
  /// ICryptoGetTextPassword body shared by extract/open/update.
  HRESULT AskPassword(BSTR *password);

  /// The password, once asked (so nested opens and re-opens do not ask again).
  UString Password;
  bool PasswordIsDefined = false;
  bool PasswordWasAsked = false;
  /// Path shown in the password dialog (the archive being processed).
  __strong NSString *ArchivePath = nil;
};

// ---------------------------------------------------------------------------
/// Everything an extract / copy-out / test operation needs:
/// `IArchiveFolder::Extract`, `IInFolderArchive::Extract` and `IFolderOperations::CopyTo`
/// all take one of these (CopyTo QI's IFolderArchiveExtractCallback out of the
/// IFolderOperationsExtractCallback it is given, ArchiveFolder.cpp:37-41).
class CSZExtractCallbackAdapter Z7_final:
  public IFolderArchiveExtractCallback,
  public IFolderArchiveExtractCallback2,
  public IFolderOperationsExtractCallback,
  public ICryptoGetTextPassword,
  public ICompressProgressInfo,
  public IArchiveRequestMemoryUseCallback,
  public IArchiveOpenCallback,
  public CMyUnknownImp,
  public CSZCallbackBase
{
  Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
    Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
    Z7_COM_QI_ENTRY(IFolderOperationsExtractCallback)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_ENTRY(ICompressProgressInfo)
    Z7_COM_QI_ENTRY(IArchiveRequestMemoryUseCallback)
    Z7_COM_QI_ENTRY(IArchiveOpenCallback)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  // IProgress is inherited twice (IFolderArchiveExtractCallback and
  // IFolderOperationsExtractCallback both derive from it); one implementation overrides
  // both, exactly like CExtractCallbackImp.
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
  Z7_IFACE_COM7_IMP(IFolderOperationsExtractCallback)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(ICompressProgressInfo)
  Z7_IFACE_COM7_IMP(IArchiveRequestMemoryUseCallback)
  Z7_IFACE_COM7_IMP(IArchiveOpenCallback)

public:
  /// NExtract::NOverwriteMode; kAsk drives the Overwrite dialog. Answers may switch it
  /// for the rest of the run (kYesToAll -> kOverwrite, kNoToAll -> kSkip,
  /// kAutoRename -> kRename), ExtractCallback.cpp:201-233.
  NExtract::NOverwriteMode::EEnum OverwriteMode;
  bool TestMode;                  ///< status line shows "Testing" instead of "Extracting"
  UInt64 NumFilesProcessed;       ///< counted from SetOperationResult, like the FM
  UInt32 NumErrors;               ///< messages + per-item failures seen so far
  Int32 FirstBadOpRes;            ///< first non-kOK per-item result (for the final NSError)
  /// Name the Overwrite dialog suggested for the last "Auto Rename" answer (may be empty).
  UString SuggestedName;
  /// The memory-use answer the user asked to repeat for the rest of the operation.
  bool MemoryUseRemembered;
  SZMemoryUseAnswer MemoryUseRememberedAnswer;

  CSZExtractCallbackAdapter():
      OverwriteMode(NExtract::NOverwriteMode::kAsk),
      TestMode(false),
      NumFilesProcessed(0),
      NumErrors(0),
      FirstBadOpRes(NArchive::NExtract::NOperationResult::kOK),
      MemoryUseRemembered(false),
      MemoryUseRememberedAnswer(SZMemoryUseAnswerAllow),
      _isFolder(false)
  {}

  /// An unambiguous IProgress for the interfaces that want one (IFolderOperations).
  IProgress *AsProgress() { return static_cast<IFolderArchiveExtractCallback *>(this); }

  /// Path of the item PrepareOperation/SetCurrentFilePath last announced
  /// (CExtractCallbackImp::_currentFilePath): reported with each operation result.
  UString CurrentFilePath;

private:
  bool _isFolder;   // last PrepareOperation item kind
};

// ---------------------------------------------------------------------------
/// Everything an update operation needs: `IFolderOperations::CopyFrom/Delete/Rename/
/// CreateFolder/SetProperty` on an archive folder run through
/// CAgentFolder::CommonUpdateOperation, which QI's IFolderArchiveUpdateCallback (and the
/// optional interfaces below) out of the plain `IProgress *` it is handed
/// (ArchiveFolderOut.cpp:107-109, 195-266).
class CSZUpdateCallbackAdapter Z7_final:
  public IFolderArchiveUpdateCallback,
  public IFolderArchiveUpdateCallback2,
  public IFolderArchiveUpdateCallback_MoveArc,
  public IFolderScanProgress,
  public ICryptoGetTextPassword,
  public ICryptoGetTextPassword2,
  public ICompressProgressInfo,
  public IArchiveOpenCallback,
  public CMyUnknownImp,
  public CSZCallbackBase
{
  Z7_COM_QI_BEGIN2(IFolderArchiveUpdateCallback)
    Z7_COM_QI_ENTRY(IFolderArchiveUpdateCallback2)
    Z7_COM_QI_ENTRY(IFolderArchiveUpdateCallback_MoveArc)
    Z7_COM_QI_ENTRY(IFolderScanProgress)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
    Z7_COM_QI_ENTRY(ICryptoGetTextPassword2)
    Z7_COM_QI_ENTRY(ICompressProgressInfo)
    Z7_COM_QI_ENTRY(IArchiveOpenCallback)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveUpdateCallback)
  Z7_IFACE_COM7_IMP(IFolderArchiveUpdateCallback2)
  Z7_IFACE_COM7_IMP(IFolderArchiveUpdateCallback_MoveArc)
  Z7_IFACE_COM7_IMP(IFolderScanProgress)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword2)
  Z7_IFACE_COM7_IMP(ICompressProgressInfo)
  Z7_IFACE_COM7_IMP(IArchiveOpenCallback)

public:
  UInt64 NumFilesProcessed;
  UInt32 NumErrors;
  Int32 FirstBadOpRes;
  /// Set when the operation may encrypt (ICryptoGetTextPassword2). When
  /// PasswordIsDefined is already true the stored password is used without asking.
  bool AskPasswordForEncryption;

  CSZUpdateCallbackAdapter():
      NumFilesProcessed(0),
      NumErrors(0),
      FirstBadOpRes(NArchive::NExtract::NOperationResult::kOK),
      AskPasswordForEncryption(false)
  {}

  IProgress *AsProgress() { return static_cast<IFolderArchiveUpdateCallback *>(this); }
};

// ---------------------------------------------------------------------------
/// The bare `IProgress` for operations that report nothing else
/// (IFolderCalcItemFullSize, file-system Delete/Rename/CreateFolder).
class CSZProgressAdapter Z7_final:
  public IProgress,
  public CMyUnknownImp,
  public CSZCallbackBase
{
  Z7_COM_UNKNOWN_IMP_1(IProgress)
  Z7_IFACE_COM7_IMP(IProgress)
};

#endif

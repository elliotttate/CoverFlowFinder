// SevenZipCoreMac.cpp -- macOS implementations of the symbols the engine and the
// patched Agent expect from the "application" (02-engine-api.md section 4.3):
//   * the IID_* GUID definitions (MyInitGuid.h, exactly once per binary),
//   * CompareFileNames_ForFolderList (FileManager/PanelSort.cpp:14-51 verbatim),
//   * SetExtractErrorMessage (FileManager/ExtractCallback.cpp:277-373, lang IDs),
//   * NWindows::MyLoadString(UINT) (Windows/ResourceString.cpp) -> SZLang hook.

#include "../../../CPP/Common/Common.h"

#include "../../../CPP/Common/MyInitGuid.h"

#include "../../../CPP/Common/MyString.h"
#include "../../../CPP/Windows/ResourceString.h"

// Every header that declares an interface GUID must be included here so that
// MyInitGuid.h turns the declarations into definitions (one TU per binary):
#include "../../../CPP/7zip/IDecl.h"
#include "../../../CPP/7zip/IProgress.h"
#include "../../../CPP/7zip/IStream.h"
#include "../../../CPP/7zip/IPassword.h"
#include "../../../CPP/7zip/ICoder.h"
#include "../../../CPP/7zip/Archive/IArchive.h"
#include "../../../CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "../../../CPP/7zip/UI/FileManager/IFolder.h"
#include "../../../CPP/7zip/UI/Agent/IFolderArchive.h"
#include "../../../CPP/7zip/UI/Agent/Agent.h"

#include "PlatformHooks.h"

SZ_LoadStringFunc g_SZ_LoadStringHook = NULL;

// ---- Windows/ResourceString.cpp replacement ----------------------------------

namespace NWindows {

void MyLoadString(UINT resourceID, UString &dest)
{
  dest.Empty();
  if (g_SZ_LoadStringHook)
  {
    const wchar_t *s = g_SZ_LoadStringHook((UInt32)resourceID);
    if (s)
      dest = s;
  }
}

UString MyLoadString(UINT resourceID)
{
  UString s;
  MyLoadString(resourceID, s);
  return s;
}

}

// ---- FileManager/PanelSort.cpp:14-51 ------------------------------------------
// Case-insensitive, numeric-aware ("file2" < "file10") comparison used by the
// Agent's IFolderCompare and by the panel's name sort.

int CompareFileNames_ForFolderList(const wchar_t *s1, const wchar_t *s2)
{
  for (;;)
  {
    wchar_t c1 = *s1;
    wchar_t c2 = *s2;
    if ((c1 >= '0' && c1 <= '9') &&
        (c2 >= '0' && c2 <= '9'))
    {
      for (; *s1 == '0'; s1++);
      for (; *s2 == '0'; s2++);
      size_t len1 = 0;
      size_t len2 = 0;
      for (; (s1[len1] >= '0' && s1[len1] <= '9'); len1++);
      for (; (s2[len2] >= '0' && s2[len2] <= '9'); len2++);
      if (len1 < len2) return -1;
      if (len1 > len2) return 1;
      for (; len1 > 0; s1++, s2++, len1--)
      {
        if (*s1 == *s2) continue;
        return (*s1 < *s2) ? -1 : 1;
      }
      c1 = *s1;
      c2 = *s2;
    }
    s1++;
    s2++;
    if (c1 != c2)
    {
      const wchar_t u1 = MyCharUpper(c1);
      const wchar_t u2 = MyCharUpper(c2);
      if (u1 < u2) return -1;
      if (u1 > u2) return 1;
    }
    if (c1 == 0) return 0;
  }
}

// ---- FileManager/ExtractCallback.cpp:277-373 ----------------------------------
// GUI/ExtractRes.h IDs (the lang file carries the same numbers):
//   3721 IDS_EXTRACT_MSG_UNSUPPORTED_METHOD  3722 ..._DATA_ERROR  3723 ..._CRC_ERROR
//   3724 ..._UNAVAILABLE_DATA  3725 ..._UEXPECTED_END  3726 ..._DATA_AFTER_END
//   3727 ..._IS_NOT_ARC  3728 ..._HEADERS_ERROR  3729 ..._WRONG_PSW_CLAIM
//   3710 IDS_EXTRACT_MSG_WRONG_PSW_GUESS

void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s);
void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s)
{
  s.Empty();
  if (opRes == NArchive::NExtract::NOperationResult::kOK)
    return;

  UINT id = 0;
  switch (opRes)
  {
    case NArchive::NExtract::NOperationResult::kUnsupportedMethod: id = 3721; break;
    case NArchive::NExtract::NOperationResult::kDataError:         id = 3722; break;
    case NArchive::NExtract::NOperationResult::kCRCError:          id = 3723; break;
    case NArchive::NExtract::NOperationResult::kUnavailable:       id = 3724; break;
    case NArchive::NExtract::NOperationResult::kUnexpectedEnd:     id = 3725; break;
    case NArchive::NExtract::NOperationResult::kDataAfterEnd:      id = 3726; break;
    case NArchive::NExtract::NOperationResult::kIsNotArc:          id = 3727; break;
    case NArchive::NExtract::NOperationResult::kHeadersError:      id = 3728; break;
    case NArchive::NExtract::NOperationResult::kWrongPassword:     id = 3729; break;
    default: break;
  }

  UString msg;
  if (id != 0)
    NWindows::MyLoadString(id, msg);
  if (!msg.IsEmpty())
    s += msg;
  else
  {
    s += "Error #";
    s.Add_UInt32((UInt32)opRes);
  }

  if (encrypted && opRes != NArchive::NExtract::NOperationResult::kWrongPassword)
  {
    s += " : ";
    s += NWindows::MyLoadString(3710);
  }
  s += " : ";
  s += fileName;
}

// SZEngine.h -- the ONE place where Objective-C++ bridge files include engine headers.
// MyWindows.h declares `typedef int BOOL;` which clashes with Objective-C's BOOL, so the
// engine is included with BOOL macro-renamed to SZ_ENGINE_BOOL (also `int`, ABI-identical).
// Include this after Foundation, never include engine headers directly from a .mm file.

#ifndef SZ_ENGINE_H
#define SZ_ENGINE_H

#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL

#include "../../../CPP/Common/Common.h"
#include "../../../CPP/Common/MyString.h"
#include "../../../CPP/Common/MyCom.h"
#include "../../../CPP/Common/MyWindows.h"
#include "../../../CPP/Common/StringConvert.h"
#include "../../../CPP/Common/IntToString.h"
#include "../../../CPP/Common/MyException.h"
#include "../../../CPP/Common/Lang.h"
#include "../../../CPP/Windows/PropVariant.h"
#include "../../../CPP/Windows/PropVariantConv.h"
#include "../../../CPP/Windows/TimeUtils.h"
#include "../../../CPP/Windows/FileFind.h"
#include "../../../CPP/Windows/FileDir.h"
#include "../../../CPP/Windows/FileName.h"
#include "../../../CPP/Windows/ErrorMsg.h"
#include "../../../CPP/Windows/ResourceString.h"
#include "../../../CPP/7zip/PropID.h"
#include "../../../CPP/7zip/IStream.h"
#include "../../../CPP/7zip/IPassword.h"
#include "../../../CPP/7zip/Archive/IArchive.h"
#include "../../../CPP/7zip/UI/Common/LoadCodecs.h"
#include "../../../CPP/7zip/UI/Common/OpenArchive.h"
#include "../../../CPP/7zip/UI/Common/PropIDUtils.h"
#include "../../../CPP/7zip/UI/Common/ZipRegistry.h"
#include "../../../CPP/7zip/UI/FileManager/IFolder.h"
#include "../../../CPP/7zip/UI/FileManager/PropertyName.h"
#include "../../../CPP/7zip/UI/Agent/IFolderArchive.h"
#include "../../../CPP/7zip/UI/Agent/Agent.h"

#include "../Platform/PlatformHooks.h"
#include "../Platform/MacPrefs.h"
#include "FSFolderMac.h"
#include "RootFolderMac.h"

// Mac/Core/Platform/SevenZipCoreMac.cpp
void SetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s);

#pragma pop_macro("BOOL")

#endif

// PlatformHooks.h -- seams between the SevenZipCore platform layer (plain C++)
// and the SevenZipKit Objective-C++ bridge. No Objective-C here.

#ifndef ZIP7_INC_MAC_PLATFORM_HOOKS_H
#define ZIP7_INC_MAC_PLATFORM_HOOKS_H

#include "../../../CPP/Common/MyTypes.h"

// Installed by SZLang (SevenZipKit) at image load. Returns the UI string for a
// 7-Zip resource / lang ID (current language first, then the built-in English
// table from en.ttt) or NULL when the ID is unknown. The pointer must stay valid
// until the language is switched. NWindows::MyLoadString(UINT) routes here, so
// FormatUtils.cpp / PropertyName.cpp / SetExtractErrorMessage are localized.
typedef const wchar_t *(*SZ_LoadStringFunc)(UInt32 id);
extern SZ_LoadStringFunc g_SZ_LoadStringHook;

#endif

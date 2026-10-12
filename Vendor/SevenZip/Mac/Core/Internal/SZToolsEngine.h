// SZToolsEngine.h -- the engine headers the `tools` scope needs on top of SZEngine.h
// (hashing, benchmark, directory enumeration, file streams, system info).
// Objective-C++ only, same BOOL rename trick as SZEngine.h; include it instead of
// reaching into CPP/ from SZHasher.mm / SZBenchmark.mm / SZSplitFile.mm.

#ifndef SZ_TOOLS_ENGINE_H
#define SZ_TOOLS_ENGINE_H

#include "SZEngine.h"

#pragma push_macro("BOOL")
#undef BOOL
#define BOOL SZ_ENGINE_BOOL

#include "../../../CPP/Common/Wildcard.h"
#include "../../../CPP/Windows/System.h"
#include "../../../CPP/Windows/SystemInfo.h"
#include "../../../CPP/7zip/Common/FileStreams.h"
#include "../../../CPP/7zip/Common/CreateCoder.h"
#include "../../../CPP/7zip/Common/MethodProps.h"
#include "../../../CPP/7zip/UI/Common/Property.h"
#include "../../../CPP/7zip/UI/Common/EnumDirItems.h"
#include "../../../CPP/7zip/UI/Common/HashCalc.h"
#include "../../../CPP/7zip/UI/Common/IFileExtractCallback.h"
#include "../../../CPP/7zip/UI/Common/Bench.h"

#pragma pop_macro("BOOL")

#endif

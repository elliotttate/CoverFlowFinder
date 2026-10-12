// ZipRegistryMac.cpp -- macOS implementation of CPP/7zip/UI/Common/ZipRegistry.h
// (the Windows original, ZipRegistry.cpp, talks to HKCU\Software\7-Zip). Values are
// stored through NMacPrefs (CFPreferences, app domain) under keys named after the
// registry values: 01b-fm-dialogs-settings.md section 5.4 / 5.5 / 5.7.
//
//   HKCU\Software\7-Zip\Extraction\ExtractMode     -> "Extraction.ExtractMode"
//   HKCU\Software\7-Zip\Compression\Options\7z\Level -> "Compression.Options.7z.Level"
//   HKCU\Software\7-Zip\Options\WorkDirType        -> "Options.WorkDirType"
//
// CBoolPair semantics are kept: absent key = Def false.

#include "../../../CPP/Common/Common.h"

#include "../../../CPP/Common/StringConvert.h"
#include "../../../CPP/Common/StringToInt.h"

#include "../../../CPP/7zip/UI/Common/ZipRegistry.h"

#include "MacPrefs.h"

using namespace NMacPrefs;

static void Key_Get_BoolPair(const char *key, CBoolPair &b)
{
  b.Val = false;
  b.Def = GetBool(key, b.Val);
}

static void Key_Get_BoolPair_true(const char *key, CBoolPair &b)
{
  b.Val = true;
  b.Def = GetBool(key, b.Val);
}

static void Key_Set_BoolPair(const char *key, const CBoolPair &b)
{
  if (b.Def)
    SetBool(key, b.Val);
}

static void Key_Set_BoolPair_Delete_IfNotDef(const char *key, const CBoolPair &b)
{
  if (b.Def)
    SetBool(key, b.Val);
  else
    Remove(key);
}

static void Key_Set_UInt32(const char *key, UInt32 value)
{
  if (value == (UInt32)(Int32)-1)
    Remove(key);
  else
    SetUInt32(key, value);
}

static void Key_Get_UInt32(const char *key, UInt32 &value)
{
  value = (UInt32)(Int32)-1;
  GetUInt32(key, value);
}

static AString Join(const char *a, const char *b)
{
  AString s(a);
  s += b;
  return s;
}

// ---------------------------------------------------------------------------
namespace NExtract {

static const char * const kPrefix = "Extraction.";

void CInfo::Save() const
{
  if (PathMode_Force)
    SetUInt32(Join(kPrefix, "ExtractMode"), (UInt32)PathMode);
  if (OverwriteMode_Force)
    SetUInt32(Join(kPrefix, "OverwriteMode"), (UInt32)OverwriteMode);

  Key_Set_BoolPair(Join(kPrefix, "SplitDest"), SplitDest);
  Key_Set_BoolPair(Join(kPrefix, "ElimDup"), ElimDup);
  Key_Set_BoolPair(Join(kPrefix, "Security"), NtSecurity);
  Key_Set_BoolPair(Join(kPrefix, "ShowPassword"), ShowPassword);

  SetStrings(Join(kPrefix, "PathHistory"), Paths);
  Sync();
}

void Save_ShowPassword(bool showPassword)
{
  SetBool(Join(kPrefix, "ShowPassword"), showPassword);
  Sync();
}

void Save_LimitGB(UInt32 limit_GB)
{
  Key_Set_UInt32(Join(kPrefix, "MemLimit"), limit_GB);
  Sync();
}

void CInfo::Load()
{
  PathMode = NPathMode::kCurPaths;
  PathMode_Force = false;
  OverwriteMode = NOverwriteMode::kAsk;
  OverwriteMode_Force = false;

  SplitDest.Val = true;

  Paths.Clear();

  GetStrings(Join(kPrefix, "PathHistory"), Paths);
  UInt32 v;
  if (GetUInt32(Join(kPrefix, "ExtractMode"), v) && v <= NPathMode::kAbsPaths)
  {
    PathMode = (NPathMode::EEnum)v;
    PathMode_Force = true;
  }
  if (GetUInt32(Join(kPrefix, "OverwriteMode"), v) && v <= NOverwriteMode::kRenameExisting)
  {
    OverwriteMode = (NOverwriteMode::EEnum)v;
    OverwriteMode_Force = true;
  }

  Key_Get_BoolPair_true(Join(kPrefix, "SplitDest"), SplitDest);
  Key_Get_BoolPair(Join(kPrefix, "ElimDup"), ElimDup);
  Key_Get_BoolPair(Join(kPrefix, "Security"), NtSecurity);
  Key_Get_BoolPair(Join(kPrefix, "ShowPassword"), ShowPassword);
}

bool Read_ShowPassword()
{
  bool showPassword = false;
  GetBool(Join(kPrefix, "ShowPassword"), showPassword);
  return showPassword;
}

UInt32 Read_LimitGB()
{
  UInt32 v = (UInt32)(Int32)-1;
  GetUInt32(Join(kPrefix, "MemLimit"), v);
  return v;
}

}

// ---------------------------------------------------------------------------
namespace NCompression {

static const char * const kPrefix = "Compression.";
static const char * const kOptionsPrefix = "Compression.Options.";

// MemUse32 / MemUse64 are separate registry values on Windows; this port is 64-bit only.
static const char * const kMemUse = "MemUse64";

static AString FormatKey(const CSysString &formatID, const char *name)
{
  AString s(kOptionsPrefix);
  s += formatID;
  s.Add_Dot();
  s += name;
  return s;
}

static void SetRegString(const AString &key, const UString &value)
{
  if (value.IsEmpty())
    Remove(key);
  else
    SetString(key, value);
}

static void GetRegString(const AString &key, UString &value)
{
  if (!GetString(key, value))
    value.Empty();
}

static void RemoveAllFormatOptions()
{
  AStringVector keys;
  ListKeys(kOptionsPrefix, keys);
  FOR_VECTOR (i, keys)
    Remove(keys[i]);
}

void CInfo::Save() const
{
  Key_Set_BoolPair_Delete_IfNotDef(Join(kPrefix, "Security"), NtSecurity);
  Key_Set_BoolPair_Delete_IfNotDef(Join(kPrefix, "AltStreams"), AltStreams);
  Key_Set_BoolPair_Delete_IfNotDef(Join(kPrefix, "HardLinks"), HardLinks);
  Key_Set_BoolPair_Delete_IfNotDef(Join(kPrefix, "SymLinks"), SymLinks);
  Key_Set_BoolPair_Delete_IfNotDef(Join(kPrefix, "PreserveATime"), PreserveATime);

  SetBool(Join(kPrefix, "ShowPassword"), ShowPassword);
  SetUInt32(Join(kPrefix, "Level"), (UInt32)Level);
  SetString(Join(kPrefix, "Archiver"), ArcType);
  SetBool(Join(kPrefix, "EncryptHeaders"), EncryptHeaders);
  SetStrings(Join(kPrefix, "ArcHistory"), ArcPaths);

  RemoveAllFormatOptions();
  FOR_VECTOR (i, Formats)
  {
    const CFormatOptions &fo = Formats[i];
    SetRegString(FormatKey(fo.FormatID, "Method"), fo.Method);
    SetRegString(FormatKey(fo.FormatID, "Options"), fo.Options);
    SetRegString(FormatKey(fo.FormatID, "EncryptionMethod"), fo.EncryptionMethod);
    SetRegString(FormatKey(fo.FormatID, kMemUse), fo.MemUse);

    Key_Set_UInt32(FormatKey(fo.FormatID, "Level"), fo.Level);
    Key_Set_UInt32(FormatKey(fo.FormatID, "Dictionary"), fo.Dictionary);
    Key_Set_UInt32(FormatKey(fo.FormatID, "Order"), fo.Order);
    Key_Set_UInt32(FormatKey(fo.FormatID, "BlockSize"), fo.BlockLogSize);
    Key_Set_UInt32(FormatKey(fo.FormatID, "NumThreads"), fo.NumThreads);

    Key_Set_UInt32(FormatKey(fo.FormatID, "TimePrec"), fo.TimePrec);
    Key_Set_BoolPair_Delete_IfNotDef(FormatKey(fo.FormatID, "MTime"), fo.MTime);
    Key_Set_BoolPair_Delete_IfNotDef(FormatKey(fo.FormatID, "ATime"), fo.ATime);
    Key_Set_BoolPair_Delete_IfNotDef(FormatKey(fo.FormatID, "CTime"), fo.CTime);
    Key_Set_BoolPair_Delete_IfNotDef(FormatKey(fo.FormatID, "SetArcMTime"), fo.SetArcMTime);
  }
  Sync();
}

void CInfo::Load()
{
  ArcPaths.Clear();
  Formats.Clear();

  Level = 5;
  ArcType = L"7z";
  ShowPassword = false;
  EncryptHeaders = false;

  Key_Get_BoolPair(Join(kPrefix, "Security"), NtSecurity);
  Key_Get_BoolPair(Join(kPrefix, "AltStreams"), AltStreams);
  Key_Get_BoolPair(Join(kPrefix, "HardLinks"), HardLinks);
  Key_Get_BoolPair(Join(kPrefix, "SymLinks"), SymLinks);
  Key_Get_BoolPair(Join(kPrefix, "PreserveATime"), PreserveATime);

  GetStrings(Join(kPrefix, "ArcHistory"), ArcPaths);

  {
    // enumerate "Compression.Options.<FormatID>.<value>" -> distinct FormatIDs
    AStringVector keys;
    ListKeys(kOptionsPrefix, keys);
    AStringVector formatIDs;
    const unsigned prefixLen = (unsigned)strlen(kOptionsPrefix);
    FOR_VECTOR (i, keys)
    {
      const AString &k = keys[i];
      if (k.Len() <= prefixLen)
        continue;
      const int dot = k.Find('.', prefixLen);
      if (dot <= (int)prefixLen)
        continue;
      const AString id = k.Mid(prefixLen, (unsigned)dot - prefixLen);
      bool found = false;
      FOR_VECTOR (j, formatIDs)
        if (formatIDs[j].IsEqualTo(id.Ptr()))
          { found = true; break; }
      if (!found)
        formatIDs.Add(id);
    }
    FOR_VECTOR (i, formatIDs)
    {
      CFormatOptions fo;
      fo.FormatID = formatIDs[i];
      GetRegString(FormatKey(fo.FormatID, "Method"), fo.Method);
      GetRegString(FormatKey(fo.FormatID, "Options"), fo.Options);
      GetRegString(FormatKey(fo.FormatID, "EncryptionMethod"), fo.EncryptionMethod);
      GetRegString(FormatKey(fo.FormatID, kMemUse), fo.MemUse);

      Key_Get_UInt32(FormatKey(fo.FormatID, "Level"), fo.Level);
      Key_Get_UInt32(FormatKey(fo.FormatID, "Dictionary"), fo.Dictionary);
      Key_Get_UInt32(FormatKey(fo.FormatID, "Order"), fo.Order);
      Key_Get_UInt32(FormatKey(fo.FormatID, "BlockSize"), fo.BlockLogSize);
      Key_Get_UInt32(FormatKey(fo.FormatID, "NumThreads"), fo.NumThreads);

      Key_Get_UInt32(FormatKey(fo.FormatID, "TimePrec"), fo.TimePrec);
      Key_Get_BoolPair(FormatKey(fo.FormatID, "MTime"), fo.MTime);
      Key_Get_BoolPair(FormatKey(fo.FormatID, "ATime"), fo.ATime);
      Key_Get_BoolPair(FormatKey(fo.FormatID, "CTime"), fo.CTime);
      Key_Get_BoolPair(FormatKey(fo.FormatID, "SetArcMTime"), fo.SetArcMTime);

      Formats.Add(fo);
    }
  }

  UString a;
  if (GetString(Join(kPrefix, "Archiver"), a) && !a.IsEmpty())
    ArcType = a;
  GetUInt32(Join(kPrefix, "Level"), Level);
  GetBool(Join(kPrefix, "ShowPassword"), ShowPassword);
  GetBool(Join(kPrefix, "EncryptHeaders"), EncryptHeaders);
}

// ZipRegistry.cpp:369-451 verbatim (pure parser, no registry access)
static bool ParseMemUse(const wchar_t *s, CMemUse &mu)
{
  mu.Clear();

  bool percentMode = false;
  {
    const wchar_t c = *s;
    if (MyCharLower_Ascii(c) == 'p')
    {
      percentMode = true;
      s++;
    }
  }
  const wchar_t *end;
  UInt64 number = ConvertStringToUInt64(s, &end);
  if (end == s)
    return false;

  wchar_t c = *end;

  if (percentMode)
  {
    if (c != 0)
      return false;
    mu.IsPercent = true;
    mu.Val = number;
    return true;
  }

  if (c == 0)
  {
    mu.Val = number;
    return true;
  }

  c = MyCharLower_Ascii(c);

  const wchar_t c1 = end[1];

  if (c == '%')
  {
    if (c1 != 0)
      return false;
    mu.IsPercent = true;
    mu.Val = number;
    return true;
  }

  if (c == 'b')
  {
    if (c1 != 0)
      return false;
    mu.Val = number;
    return true;
  }

  if (c1 != 0)
    if (MyCharLower_Ascii(c1) != 'b' || end[2] != 0)
      return false;

  unsigned numBits;
  switch (c)
  {
    case 'k': numBits = 10; break;
    case 'm': numBits = 20; break;
    case 'g': numBits = 30; break;
    case 't': numBits = 40; break;
    default: return false;
  }
  if (number >= ((UInt64)1 << (64 - numBits)))
    return false;
  mu.Val = number << numBits;
  return true;
}

void CMemUse::Parse(const UString &s)
{
  IsDefined = ParseMemUse(s, *this);
}

}

// ---------------------------------------------------------------------------
namespace NWorkDir {

static const char * const kWorkDirType = "Options.WorkDirType";
static const char * const kWorkDirPath = "Options.WorkDirPath";
static const char * const kTempRemovableOnly = "Options.TempRemovableOnly";

void CInfo::Save() const
{
  SetUInt32(kWorkDirType, (UInt32)Mode);
  SetString(kWorkDirPath, fs2us(Path));
  SetBool(kTempRemovableOnly, ForRemovableOnly);
  Sync();
}

void CInfo::Load()
{
  SetDefault();

  UInt32 dirType;
  if (!GetUInt32(kWorkDirType, dirType))
    return;
  switch (dirType)
  {
    case NMode::kSystem:
    case NMode::kCurrent:
    case NMode::kSpecified:
      Mode = (NMode::EEnum)dirType;
  }
  UString pathU;
  if (GetString(kWorkDirPath, pathU))
    Path = us2fs(pathU);
  else
  {
    Path.Empty();
    if (Mode == NMode::kSpecified)
      Mode = NMode::kSystem;
  }
  GetBool(kTempRemovableOnly, ForRemovableOnly);
}

}

// ---------------------------------------------------------------------------
static const char * const kCascadedMenu = "Options.CascadedMenu";
static const char * const kContextMenu = "Options.ContextMenu";
static const char * const kMenuIcons = "Options.MenuIcons";
static const char * const kElimDup = "Options.ElimDupExtract";
static const char * const kWriteZoneId = "Options.WriteZoneIdExtract";

void CContextMenuInfo::Save() const
{
  Key_Set_BoolPair(kCascadedMenu, Cascaded);
  Key_Set_BoolPair(kMenuIcons, MenuIcons);
  Key_Set_BoolPair(kElimDup, ElimDup);
  if (Flags_Def)
    SetUInt32(kContextMenu, Flags);
  Key_Set_UInt32(kWriteZoneId, WriteZone);
  Sync();
}

void CContextMenuInfo::Load()
{
  Cascaded.Val = true;
  Cascaded.Def = false;

  MenuIcons.Val = false;
  MenuIcons.Def = false;

  ElimDup.Val = true;
  ElimDup.Def = false;

  WriteZone = (UInt32)(Int32)-1;

  Flags = (UInt32)(Int32)-1;
  Flags_Def = false;

  Key_Get_BoolPair_true(kCascadedMenu, Cascaded);
  Key_Get_BoolPair_true(kElimDup, ElimDup);
  Key_Get_BoolPair(kMenuIcons, MenuIcons);
  Key_Get_UInt32(kWriteZoneId, WriteZone);
  Flags_Def = GetUInt32(kContextMenu, Flags);
}

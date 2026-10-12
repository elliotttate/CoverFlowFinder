// MacPrefs.h -- CFPreferences-backed key/value store used by the ZipRegistry
// accessors (ZipRegistryMac.cpp) and by SZSettings. Domain: the app bundle id
// (com.yrambler2001.7zip), current user, any host -- the same domain
// NSUserDefaults.standard uses inside the app, so Swift and the engine read the
// same values. Keys mirror the Windows registry value names, prefixed by the
// registry key path with dots: "Options.WorkDirType", "Extraction.ExtractMode",
// "Compression.Options.7z.Level" (01b-fm-dialogs-settings.md section 5.7).

#ifndef ZIP7_INC_MAC_PREFS_H
#define ZIP7_INC_MAC_PREFS_H

#include "../../../CPP/Common/MyString.h"

namespace NMacPrefs {

extern const char * const kAppID;   // "com.yrambler2001.7zip" (the default domain)

// Environment variable that replaces the preferences domain for the whole process, so that
// concurrent agents and UI tests get an isolated settings domain instead of the user's real one:
//
//   SEVENZIP_DEFAULTS_SUITE=7zip-uitests  Mac/build/Debug/7-Zip.app/Contents/MacOS/7-Zip
//
// It is read on every access (cached by value), so a test can set it with setenv() at any time.
// Empty or unset means kAppID. Everything that stores settings -- SZSettings, the Swift Settings
// facade and the engine-side ZipRegistry accessors (Extraction.*, Compression.*, Options.*,
// the work directory) -- goes through this one domain.
extern const char * const kSuiteEnvVar;   // "SEVENZIP_DEFAULTS_SUITE"

// The domain used when the environment variable is not set: the running application's own
// bundle identifier, so two copies built with different PRODUCT_BUNDLE_IDENTIFIERs keep separate
// settings (ai/test-support-contract.md, "nothing keyed on a hard-coded bundle identifier").
// kAppID when the main bundle is not an application (the xctest runner, an .appex) or has no
// identifier, so the unit tests and the extensions keep the shipping domain.
AString DefaultApplicationID();

// The domain actually in use (DefaultApplicationID() unless the environment variable is set).
AString ApplicationID();

bool GetUInt32(const char *key, UInt32 &value);
bool GetBool(const char *key, bool &value);
bool GetString(const char *key, UString &value);
bool GetStrings(const char *key, UStringVector &values);

void SetUInt32(const char *key, UInt32 value);
void SetBool(const char *key, bool value);
void SetString(const char *key, const UString &value);
void SetStrings(const char *key, const UStringVector &values);

bool Exists(const char *key);
void Remove(const char *key);
// All keys of the domain that start with prefix (prefix is not stripped).
void ListKeys(const char *prefix, AStringVector &keys);
void Sync();

// fix112: while suspended, every Set*, Remove and Sync is a no-op (Reset All Settings: the quitting
// instance must not save its state into the emptied domain). Reads still work.
void SetWritesSuspended(bool suspended);
bool WritesSuspended();

}

#endif

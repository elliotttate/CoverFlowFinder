// SZSettings.h -- typed access to the shared preferences domain (com.yrambler2001.7zip, or the
// domain named by the SEVENZIP_DEFAULTS_SUITE environment variable).
// Keys mirror the Windows registry value names with the key path as a dotted prefix
// (01b-fm-dialogs-settings.md section 5.7): "Lang", "FM.PanelPath0", "Extraction.ExtractMode",
// "Compression.Options.7z.Level", "Options.WorkDirType". The engine-side ZipRegistry accessors
// (Mac/Core/Platform/ZipRegistryMac.cpp) read and write the same keys.

#ifndef SZ_SETTINGS_H
#define SZ_SETTINGS_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// HKCU\Software\7-Zip
FOUNDATION_EXPORT NSString * const SZSettingsKeyLang;                 // "Lang"
// HKCU\Software\7-Zip\FM
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMPosition;           // "FM.Position" (window frame string)
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMMaximized;          // "FM.Maximized"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMNumPanels;          // "FM.Panels.numPanels"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMCurrentPanel;       // "FM.Panels.currentPanel"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMSplitterPos;        // "FM.Panels.splitterPos" (ratio 0..1)
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMToolbars;           // "FM.Toolbars"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMListMode0;          // "FM.ListMode0"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMListMode1;          // "FM.ListMode1"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMPanelPath0;         // "FM.PanelPath0"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMPanelPath1;         // "FM.PanelPath1"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFlatViewArc0;       // "FM.FlatViewArc0"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFlatViewArc1;       // "FM.FlatViewArc1"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFolderHistory;      // "FM.FolderHistory"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFolderShortcuts;    // "FM.FolderShortcuts"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMCopyHistory;        // "FM.CopyHistory"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowDots;           // "FM.ShowDots"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowRealFileIcons;  // "FM.ShowRealFileIcons"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMFullRow;            // "FM.FullRow"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowGrid;           // "FM.ShowGrid"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMSingleClick;        // "FM.SingleClick"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMAlternativeSelection; // "FM.AlternativeSelection"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMShowSystemMenu;     // "FM.ShowSystemMenu"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMViewer;             // "FM.Viewer"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMEditor;             // "FM.Editor"
FOUNDATION_EXPORT NSString * const SZSettingsKeyFMDiff;               // "FM.Diff"
// HKCU\Software\7-Zip\Options
FOUNDATION_EXPORT NSString * const SZSettingsKeyWorkDirType;          // "Options.WorkDirType"
FOUNDATION_EXPORT NSString * const SZSettingsKeyWorkDirPath;          // "Options.WorkDirPath"
FOUNDATION_EXPORT NSString * const SZSettingsKeyTempRemovableOnly;    // "Options.TempRemovableOnly"

/// Environment variable that replaces the preferences domain for the whole process:
///
///     SEVENZIP_DEFAULTS_SUITE=7zip-uitests  open -a 7-Zip
///
/// Unset or empty means the default domain. It is honoured by everything that stores settings:
/// this class, the Swift `Settings` facade built on it, and the engine-side ZipRegistry accessors
/// (`Extraction.*`, `Compression.*`, `Options.*`, the work directory). The value is re-read on
/// every access, so a test can switch domains with `setenv()` at any point.
FOUNDATION_EXPORT NSString * const SZSettingsSuiteEnvironmentVariable;   // "SEVENZIP_DEFAULTS_SUITE"

/// The default domain, used when the environment variable is not set.
FOUNDATION_EXPORT NSString * const SZSettingsDefaultApplicationID;       // "com.yrambler2001.7zip"

/// Test support (ai/test-support-contract.md, ai/api/resetcmd.md).
///
/// `SZ_TEST_SUPPORT=1` is the master switch: with it unset nothing below exists and the app
/// behaves exactly as it always has. `SZ_STATE_DIR` is an absolute directory this instance uses
/// for everything it would otherwise put in a shared location, so that two instances -- possibly
/// built with different bundle identifiers -- never touch the same file.
FOUNDATION_EXPORT NSString * const SZSettingsTestSupportEnvironmentVariable;    // "SZ_TEST_SUPPORT"
FOUNDATION_EXPORT NSString * const SZSettingsStateDirectoryEnvironmentVariable; // "SZ_STATE_DIR"

@interface SZSettings : NSObject

/// The domain actually in use right now.
@property (class, nonatomic, readonly) NSString *applicationID;

/// The domain used when SEVENZIP_DEFAULTS_SUITE is not set: the running application's bundle
/// identifier, or SZSettingsDefaultApplicationID outside an application bundle (the unit-test
/// runner, the extensions). `NMacPrefs::DefaultApplicationID()`.
@property (class, nonatomic, readonly) NSString *defaultApplicationID;

/// YES when SEVENZIP_DEFAULTS_SUITE names a domain other than the default one.
@property (class, nonatomic, readonly) BOOL usesOverrideSuite;

/// YES when `SZ_TEST_SUPPORT` is `1`. Re-read on every access, like the suite variable.
@property (class, nonatomic, readonly) BOOL testSupportEnabled;

/// `SZ_STATE_DIR` when test support is on and the variable names an absolute path, else nil.
@property (class, nonatomic, readonly, nullable) NSString *stateDirectory;

/// The temporary directory this instance must use: `<SZ_STATE_DIR>/tmp/` when a state directory
/// is active (created on first use), otherwise `NSTemporaryDirectory()` unchanged. Every place
/// that would call `NSTemporaryDirectory()` goes through here so two instances cannot enumerate,
/// purge or overwrite each other's `7zO*` / `7zE*` / `7zL-*` items.
@property (class, nonatomic, readonly) NSString *temporaryDirectory;

+ (nullable NSString *)stringForKey:(NSString *)key NS_SWIFT_NAME(string(forKey:));
+ (void)setString:(nullable NSString *)value forKey:(NSString *)key;   ///< nil removes

+ (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue NS_SWIFT_NAME(integer(forKey:defaultValue:));
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key;

+ (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue NS_SWIFT_NAME(double(forKey:defaultValue:));
+ (void)setDouble:(double)value forKey:(NSString *)key;

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;

/// CBoolPair: nil = undefined (registry value absent).
+ (nullable NSNumber *)boolPairForKey:(NSString *)key NS_SWIFT_NAME(boolPair(forKey:));
+ (void)setBoolPair:(nullable NSNumber *)value forKey:(NSString *)key;

+ (nullable NSArray<NSString *> *)stringArrayForKey:(NSString *)key NS_SWIFT_NAME(stringArray(forKey:));
+ (void)setStringArray:(nullable NSArray<NSString *> *)value forKey:(NSString *)key;

+ (BOOL)hasKey:(NSString *)key NS_SWIFT_NAME(hasKey(_:));
+ (void)removeKey:(NSString *)key NS_SWIFT_NAME(removeKey(_:));
+ (NSArray<NSString *> *)keysWithPrefix:(NSString *)prefix NS_SWIFT_NAME(keys(withPrefix:));

/// Untyped access, for the one job the typed accessors cannot do: replacing the whole domain
/// with the contents of a property list without flattening its value types
/// (`sevenzip://test/reset?defaults=<plist>`, ai/api/resetcmd.md section 4).
+ (nullable id)propertyListValueForKey:(NSString *)key NS_SWIFT_NAME(propertyListValue(forKey:));
+ (void)setPropertyListValue:(nullable id)value forKey:(NSString *)key;
+ (void)synchronize;

/// fix112 (Reset All Settings): YES drops every write -- the typed setters, the untyped one, the
/// engine's ZipRegistry accessors and synchronize -- until it is set back to NO. Reads still work.
@property (class, nonatomic) BOOL writesSuspended;

@end

/// NWorkDir::CInfo (the one engine setting read implicitly by every Agent update).
typedef NS_ENUM(NSInteger, SZWorkDirMode) {
    SZWorkDirModeSystem = 0,
    SZWorkDirModeCurrent = 1,
    SZWorkDirModeSpecified = 2
};

@interface SZWorkDirSettings : NSObject
@property (nonatomic) SZWorkDirMode mode;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL forRemovableOnly;
/// NWorkDir::CInfo::Load() / Save() through the engine's own accessor.
+ (SZWorkDirSettings *)loadFromSettings NS_SWIFT_NAME(loadFromSettings());
- (void)save;
@end

NS_ASSUME_NONNULL_END

#endif

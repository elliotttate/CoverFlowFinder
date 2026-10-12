// SZUpdater.h -- creating and updating archives: the macOS stand-in for 7zG's
// `UpdateGUI` (CPP/7zip/UI/GUI/UpdateGUI.cpp) on top of the engine's own
// `UpdateArchive()` (CPP/7zip/UI/Common/Update.cpp), which is the code the Windows
// product runs. Nothing about the update logic is reimplemented here: the bridge fills a
// `CUpdateOptions`, builds the censor from the source paths and forwards every callback to
// an `id<SZProgressDelegate>`, exactly like `CUpdateCallbackGUI`.
//
// Every method BLOCKS while the engine works. Call it **off the main thread** and drive it
// from Swift with `OperationRunner` (Mac/App/Support/OperationRunner.swift), which owns the
// Progress dialog and answers the password question.
//
// Parity: 01-fm-feature-inventory.md section 8.5 (the Add flow), section 8.7 (errors,
// pause, password), 01b-fm-dialogs-settings.md section 4.23 ("Parameter generation",
// "OnOK validation") and section 4.24 (the Options sheet), 02-engine-api.md section 2.3.

#ifndef SZ_UPDATER_H
#define SZ_UPDATER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZProgressDelegate.h>
#import <SevenZipKit/SZTypes.h>

NS_ASSUME_NONNULL_BEGIN

/// Set on an `NSError` whose cause was the engine's `CMessagePathException` — a censor path that
/// named nothing, or a duplicate archive path. `WinMain` maps that exception to exit code 7
/// (`NExitCode::kUserError`, GUI.cpp:452-456) rather than the generic 2, and a `UString`-derived
/// exception cannot be told apart from any other once it is an HRESULT, so it is flagged here.
FOUNDATION_EXPORT NSErrorUserInfoKey const SZPathExceptionUserInfoKey;

/// The "Update mode:" combo (IDC_COMPRESS_UPDATE_MODE 103) mapped onto the engine's action
/// sets (`NUpdateArchive::k_ActionSet_*`, `g_UpdateMode_Pairs` in UpdateGUI.cpp:290-296).
/// `SZUpdateModeDelete` is not in the dialog: it is the console `d` command, used by
/// "delete items from an archive".
typedef NS_ENUM(NSInteger, SZUpdateMode) {
    SZUpdateModeAdd = 0,     ///< IDS_COMPRESS_UPDATE_MODE_ADD 4060 "Add and replace files"
    SZUpdateModeUpdate = 1,  ///< IDS_COMPRESS_UPDATE_MODE_UPDATE 4061 "Update and add files"
    SZUpdateModeFresh = 2,   ///< IDS_COMPRESS_UPDATE_MODE_FRESH 4062 "Freshen existing files"
    SZUpdateModeSync = 3,    ///< IDS_COMPRESS_UPDATE_MODE_SYNC 4063 "Synchronize files"
    SZUpdateModeDelete = 4   ///< k_ActionSet_Delete (`7z d`), no dialog item
};

/// The "Path mode:" combo (IDC_COMPRESS_PATH_MODE 116) = `NWildcard::ECensorPathMode`.
typedef NS_ENUM(NSInteger, SZCompressPathMode) {
    SZCompressPathModeRelative = 0,  ///< k_RelatPath, IDS_PATH_MODE_RELAT
    SZCompressPathModeFull = 1,      ///< k_FullPath,  IDS_EXTRACT_PATHS_FULL
    SZCompressPathModeAbsolute = 2   ///< k_AbsPath,   IDS_EXTRACT_PATHS_ABS
};

/// `EArcNameMode` (Update.h:15-20): how the archive path given is turned into a name plus
/// extension. `-saa` / `-sae` on the command line.
typedef NS_ENUM(NSInteger, SZArchiveNameMode) {
    SZArchiveNameModeSmart = 0,  ///< k_ArcNameMode_Smart: replace a known archive extension
    SZArchiveNameModeExact = 1,  ///< k_ArcNameMode_Exact: use the name as given
    SZArchiveNameModeAdd = 2     ///< k_ArcNameMode_Add: always append the format extension
};

// ---------------------------------------------------------------------------

/// `NRecursedType::EEnum` (Update.h:59-65) — the `r` modifier of an `-i`/`-x` switch, or the
/// global `-r`.
typedef NS_ENUM(NSInteger, SZRecursedType) {
    SZRecursedTypeRecursed = 0,               ///< `-r`  / `-ir!…`
    SZRecursedTypeWildcardOnlyRecursed = 1,   ///< `-r0` / `-ir0!…`: recurse only a wildcard name
    SZRecursedTypeNonRecursed = 2             ///< `-r-`, and the default
};

/// `NWildcard::kMark_*` (Common/Wildcard.h:56-58) — the `m` modifier of an `-i`/`-x` switch, or
/// the global `-spm`.
typedef NS_ENUM(NSInteger, SZWildcardMarkMode) {
    SZWildcardMarkModeFileOrDir = 0,             ///< kMark_FileOrDir, the default (`m-`)
    SZWildcardMarkModeStrictFile = 1,            ///< kMark_StrictFile (`m`)
    SZWildcardMarkModeStrictFileIfWildcard = 2   ///< kMark_StrictFile_IfWildcard (`m2`)
};

/// One include or exclude entry of a censor, i.e. one resolved `-i…` / `-x…` name with the
/// modifiers that switch carried — `CNameOption` + the name `AddNameToCensor` receives
/// (ArchiveCommandLine.cpp:459-495, :707-850).
///
/// The point of passing these to the bridge instead of a plain path list is that the **engine**
/// then expands the wildcards, in `EnumerateItems` / `EnumerateDirItemsAndSort`, with its own
/// directory walk and its own matcher. Nothing in the port matches a pattern itself.
@interface SZPathSpec : NSObject <NSCopying>

/// The name as it was written, wildcards and all (`-i!*.txt` -> `*.txt`).
@property (nonatomic, readonly, copy) NSString *path;
/// NO for an `-x` / `-ax` entry (`CNameOption::Include`).
@property (nonatomic, readonly) BOOL include;
@property (nonatomic, readonly) SZRecursedType recursedType;
/// NO for the `w-` postfix, which is what a Finder selection uses (`-aiw-!<path>`) so a real file
/// name containing `*`, `?` or `[` is not read as a pattern.
@property (nonatomic, readonly) BOOL wildcardMatching;
@property (nonatomic, readonly) SZWildcardMarkMode markMode;

+ (instancetype)specWithPath:(NSString *)path
                     include:(BOOL)include
                recursedType:(SZRecursedType)recursedType
            wildcardMatching:(BOOL)wildcardMatching
                    markMode:(SZWildcardMarkMode)markMode
    NS_SWIFT_NAME(spec(path:include:recursedType:wildcardMatching:markMode:));

/// An include entry with wildcard matching **off** — exactly `AddPreItem_NoWildcard`, which is
/// what every selection-transport path (`-aiw-!`, `-iw-@`) and every caller that hands over real
/// file-system paths wants.
+ (instancetype)literalSpecWithPath:(NSString *)path NS_SWIFT_NAME(literal(_:));

@end

// ---------------------------------------------------------------------------

/// One `rn` old/new pair (`CRenamePair`, Update.h:67-78). `RecursedType` is always
/// `kNonRecursed`, the only value `CRenamePair::Prepare` accepts for a rename
/// (ArchiveCommandLine.cpp:616, Update.cpp:288-295).
@interface SZRenamePair : NSObject <NSCopying>

@property (nonatomic, readonly, copy) NSString *oldName;
@property (nonatomic, readonly, copy) NSString *newName;
/// Explicit getter: a `new…` selector would otherwise be read as a Cocoa "returns owned" family.
- (NSString *)newName __attribute__((objc_method_family(none)));
/// `CRenamePair::WildcardParsing` — off with `-spd` or a `w-` postfix.
@property (nonatomic, readonly) BOOL wildcardParsing;

+ (instancetype)pairWithOldName:(NSString *)oldName
                       newName:(NSString *)newName
               wildcardParsing:(BOOL)wildcardParsing
    NS_SWIFT_NAME(pair(oldName:newName:wildcardParsing:));

/// `CRenamePair::Prepare()` (Update.cpp:288-295): with wildcard parsing on, the **old** name must
/// not contain a wildcard. A pair that fails this is 7-Zip's "Unsupported rename command:".
@property (nonatomic, readonly) BOOL isSupported;

/// The text `AddRenamePair` throws with (ArchiveCommandLine.cpp:511-522): old name, new name and
/// the recursion switch, one per line. nil when `isSupported`.
@property (nonatomic, readonly, copy, nullable) NSString *unsupportedDetail;

@end

// ---------------------------------------------------------------------------

/// One `-m` name/value pair (`CProperty`, UI/Common/Property.h). `value` may be empty for a
/// bare switch name.
@interface SZUpdateProperty : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *value;
+ (instancetype)propertyWithName:(NSString *)name value:(nullable NSString *)value;
/// "name=value" (or just "name"), the way `7z -m…` spells it. For logs and tests.
@property (nonatomic, readonly) NSString *switchText;
@end

// ---------------------------------------------------------------------------

/// Everything the Compress dialog (01b section 4.23) and the Compress Options sheet
/// (section 4.24) can decide, plus the command-line-only knobs. One-to-one with
/// `CUpdateOptions` (Update.h:80-157) and the `-m` property list.
///
/// Tri-state options are `NSNumber *`: nil = "not specified, leave the handler default"
/// (`CBoolPair::Def == false`), else the boolean value.
@interface SZUpdateOptions : NSObject <NSCopying>

/// Full path of the archive **with** its extension. `nameMode` decides how the extension is
/// re-derived (`CArchivePath::ParseFromPath`).
@property (nonatomic, copy) NSString *archivePath;
/// Engine format name ("7z", "zip", "tar", …). Empty/nil = derive it from `archivePath`
/// (`CCodecs::FindFormatForArchiveName`, which is what `7z a x.zip` does).
@property (nonatomic, copy, nullable) NSString *formatName;
/// Engine format index, or -1 to use `formatName` / `archivePath`. Wins over `formatName`.
@property (nonatomic) NSInteger formatIndex;
/// `-m` properties in the order 01b section 4.23 "Parameter generation" prescribes.
@property (nonatomic, copy) NSArray<SZUpdateProperty *> *properties;

@property (nonatomic) SZUpdateMode updateMode;              ///< IDC_COMPRESS_UPDATE_MODE 103
@property (nonatomic) SZCompressPathMode pathMode;          ///< IDC_COMPRESS_PATH_MODE 116 (-spf)
@property (nonatomic) SZArchiveNameMode nameMode;           ///< -saa / -sae

/// "Create SFX archive" IDX_COMPRESS_SFX 4012 (-sfx). The stub defaults to the bundled
/// `7z.sfx` (`SZUpdater.defaultSFXModulePath`); `BaseExtension` becomes "exe".
@property (nonatomic) BOOL sfxMode;
@property (nonatomic, copy, nullable) NSString *sfxModulePath;

/// "Split to volumes, bytes:" IDC_COMPRESS_VOLUME 105 (-v). Empty = one archive.
@property (nonatomic, copy) NSArray<NSNumber *> *volumeSizes;

/// Encryption. `password` nil/empty = no encryption. `asksPassword` mirrors `-p` with no
/// value: the delegate is asked through `progressAskPasswordForEncryptionCancelled:`.
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic) BOOL asksPassword;

@property (nonatomic) BOOL deleteAfterCompressing;   ///< IDX_COMPRESS_DEL 4019 (-sdel)
@property (nonatomic) BOOL setArchiveMTime;          ///< IDX_COMPRESS_ZTIME 4085 (-stl)
@property (nonatomic) BOOL openShareForWrite;       ///< IDX_COMPRESS_SHARED 4013 (-ssw)
@property (nonatomic) BOOL stopAfterOpenError;      ///< -sse

/// Compress Options sheet, tri-state (CBoolPair).
@property (nonatomic, copy, nullable) NSNumber *preserveATime;  ///< IDX_COMPRESS_PRESERVE_ATIME 4086 (-ssp)
@property (nonatomic, copy, nullable) NSNumber *storeSymLinks;  ///< IDX_COMPRESS_NT_SYM_LINKS 4040 (-snl)
@property (nonatomic, copy, nullable) NSNumber *storeHardLinks; ///< IDX_COMPRESS_NT_HARD_LINKS 4041 (-snh)
@property (nonatomic, copy, nullable) NSNumber *storeAltStreams;///< IDX_COMPRESS_NT_ALT_STREAMS 4042 (-sns), hidden on macOS
@property (nonatomic, copy, nullable) NSNumber *storeNtSecurity;///< IDX_COMPRESS_NT_SECUR 4043 (-sni), hidden on macOS

/// Where the temporary archive is built. nil = the work-directory policy from the settings
/// (`NWorkDir::CInfo`, Options > Folders, 01b section 4.8); pass "" to force the archive's
/// own folder (`NWorkDir::NMode::kCurrent`).
@property (nonatomic, copy, nullable) NSString *workingDirectory;

/// "Compress and email" (-seml). The bridge only *creates* the archive; handing it to
/// `NSSharingService` is the app's job (01 section 9 #22). `emailRemoveAfter` records `-seml.`
/// so the caller can purge the temp copy afterwards. Volumes + email is rejected, as on
/// Windows (`Update.cpp:1164`).
@property (nonatomic) BOOL emailMode;
@property (nonatomic) BOOL emailRemoveAfter;
@property (nonatomic, copy, nullable) NSString *emailAddress;

/// `archivePath` and nothing else set. `updateMode` = add, `pathMode` = relative,
/// `nameMode` = smart, no properties.
- (instancetype)initWithArchivePath:(NSString *)archivePath;
+ (instancetype)optionsWithArchivePath:(NSString *)archivePath NS_SWIFT_NAME(options(archivePath:));

@end

// ---------------------------------------------------------------------------

/// What a finished update produced (`CFinishArchiveStat` + the callback counters).
@interface SZUpdateResult : NSObject
/// Final archive path as the engine resolved it (`CArchivePath::GetFinalPath`, or
/// `GetFinalVolPath` + ".001" for a volume set).
@property (nonatomic, readonly, copy) NSString *archivePath;
@property (nonatomic, readonly) uint64_t archiveSize;      ///< CFinishArchiveStat::OutArcFileSize
@property (nonatomic, readonly) NSUInteger volumeCount;    ///< CFinishArchiveStat::NumVolumes
@property (nonatomic, readonly) BOOL isMultiVolume;        ///< CFinishArchiveStat::IsMultiVolMode
/// Items whose SetOperationResult arrived (7zFM's "Files" counter).
@property (nonatomic, readonly) uint64_t filesProcessed;
/// Scanned totals reported by FinishScanning.
@property (nonatomic, readonly) uint64_t scannedFileCount;
@property (nonatomic, readonly) uint64_t scannedTotalSize;
/// Messages + per-item failures collected (7zFM's "Errors" counter).
@property (nonatomic, readonly) NSUInteger errorCount;
/// Files that could not be opened/read/scanned (`CUpdateCallbackGUI::FailedFiles`). A
/// non-empty list is 7zG's exit code 1 / `kWarning` (03 section 2.3).
@property (nonatomic, readonly, copy) NSArray<NSString *> *failedPaths;
/// YES when the engine asked the delegate for a password during the run.
@property (nonatomic, readonly) BOOL passwordWasAsked;
/// The password finally used (asked or pre-set), so the caller can remember it.
@property (nonatomic, readonly, copy, nullable) NSString *password;
/// Paths the engine deleted because of `-sdel`.
@property (nonatomic, readonly, copy) NSArray<NSString *> *deletedPaths;
@end

// ---------------------------------------------------------------------------

@interface SZUpdater : NSObject

/// Creates or updates `options.archivePath` from `sourcePaths` (absolute file-system paths;
/// directories are recursed). Blocks; returns nil with `error` set
/// (`SZErrorCodeCancelled` when the delegate cancelled).
///
/// This is `UpdateGUI` minus the dialog: the censor gets one `AddPreItem_NoWildcard` per
/// path (7zG's `-i#<map>` list), the format/`ArchivePath` are prepared the way
/// `ShowDialog` prepares them, and the engine's `UpdateArchive()` does the rest.
+ (nullable SZUpdateResult *)updateWithOptions:(SZUpdateOptions *)options
                                   sourcePaths:(NSArray<NSString *> *)sourcePaths
                                      progress:(nullable id<SZProgressDelegate>)progress
                                         error:(NSError **)error
    NS_SWIFT_NAME(update(with:sourcePaths:progress:));

/// Adds `sourcePaths` to the **existing** archive at `archivePath`, in place, keeping its
/// format (`CCodecs::FindFormatForArchiveName`) — what the panel does when it is inside an
/// open archive and the user adds files. `options` may be nil for the defaults; its
/// `archivePath`, `formatName`/`formatIndex` and `updateMode` are overridden.
+ (nullable SZUpdateResult *)addPaths:(NSArray<NSString *> *)sourcePaths
                  toArchiveAtPath:(NSString *)archivePath
                          options:(nullable SZUpdateOptions *)options
                         progress:(nullable id<SZProgressDelegate>)progress
                            error:(NSError **)error
    NS_SWIFT_NAME(addPaths(_:toArchiveAt:options:progress:));

/// `deleteItemsNamed:` with the censor entries spelled out, so `d -x!…` and a wildcard in a
/// positional name reach the engine unexpanded. `itemSpecs` with **no include entry** is refused
/// with `SZErrorCodeInvalidArgument`: the update core would otherwise fall back to the universal
/// wildcard `*`, which for a delete means "every item".
+ (nullable SZUpdateResult *)deleteItemsWithSpecs:(NSArray<SZPathSpec *> *)itemSpecs
                                fromArchiveAtPath:(NSString *)archivePath
                                          options:(nullable SZUpdateOptions *)options
                                         progress:(nullable id<SZProgressDelegate>)progress
                                            error:(NSError **)error
    NS_SWIFT_NAME(deleteItems(specs:fromArchiveAt:options:progress:));

/// Deletes `itemNames` (archive-relative paths, taken literally — use
/// `deleteItemsWithSpecs:` for wildcards) from the archive at `archivePath` — the console `d`
/// command, `k_ActionSet_Delete`.
+ (nullable SZUpdateResult *)deleteItemsNamed:(NSArray<NSString *> *)itemNames
                          fromArchiveAtPath:(NSString *)archivePath
                                    options:(nullable SZUpdateOptions *)options
                                   progress:(nullable id<SZProgressDelegate>)progress
                                      error:(NSError **)error
    NS_SWIFT_NAME(deleteItems(named:fromArchiveAt:options:progress:));

/// `Mac/Resources/SFX/7z.sfx` inside the bundle (the GUI stub, `kDefaultSfxModule`), nil
/// when it is missing. `7zCon.sfx` is `sfxModulePathNamed:@"7zCon.sfx"`.
@property (class, nonatomic, readonly, nullable) NSString *defaultSFXModulePath;
+ (nullable NSString *)sfxModulePathNamed:(NSString *)fileName NS_SWIFT_NAME(sfxModulePath(named:));

/// The archive name 7zFM's `CreateArchiveName` (UI/Common/ArchiveName.cpp) produces for
/// `itemPaths`, without an extension (03 section 1.6): one item -> its name with a
/// single-dot extension removed (folders keep the name), several -> the common parent
/// folder's name (a volume root -> the volume name), else "Archive", passed through
/// `Get_Correct_FsFile_Name`. When one of `itemPaths` already *is* `<name>.7z` / `.zip` /
/// `.tar` / `.wim` (`.sha256` when `isHash`), the smallest free `<name>_<N>`, N >= 2, is
/// returned instead; `baseName` always receives the plain name without that suffix.
+ (NSString *)archiveBaseNameForItemPaths:(NSArray<NSString *> *)itemPaths
                                   isHash:(BOOL)isHash
                                 baseName:(NSString * _Nullable * _Nullable)baseName
    NS_SWIFT_NAME(archiveBaseName(forItemPaths:isHash:baseName:));

/// YES when this format can be used to create archives at all (`CArcInfoEx::UpdateEnabled`).
+ (BOOL)formatSupportsUpdate:(NSString *)formatName NS_SWIFT_NAME(formatSupportsUpdate(_:));

/// `kFF_SFX` of the Compress dialog's format table (01b section 4.23, `CompressDialog.cpp:236-248`
/// and the per-format rows at `:364`): only **7z** can carry a stub. `-sfx` with any other `-t` is
/// refused rather than quietly producing a plain archive.
+ (BOOL)formatSupportsSFX:(NSString *)formatName NS_SWIFT_NAME(formatSupportsSFX(_:));

/// `-sfx<module>` resolved the way `UpdateArchive` resolves it (Update.cpp:1167-1191):
///
///  * nil or `""` -> the bundled GUI stub (`kDefaultSfxModule` = `7z.sfx`, UpdateGUI.cpp:31,
///    `:561-565`), which is what a bare `-sfx` and the Compress dialog's checkbox mean;
///  * a bare name with **no** path separator -> looked up next to the program first, i.e. in the
///    bundle's `Resources/SFX` (`NDLL::GetModuleDirPrefix()` on Windows), then as a relative path;
///  * anything else -> used as given.
///
/// The file must exist and must look like a stub: a regular file of at least 1 KiB whose first
/// bytes are an executable magic — `MZ` for the Windows stubs 7-Zip ships, or one of the Mach-O /
/// universal-binary magics for a native one. Failures come back as
/// `SZErrorCodeFileNotFound` with 7-Zip's own "cannot find specified SFX module", or
/// `SZErrorCodeInvalidArgument` when the file is there but is not an executable.
+ (nullable NSString *)resolvedSFXModulePath:(nullable NSString *)nameOrPath
                                       error:(NSError **)error
    NS_SWIFT_NAME(resolvedSFXModulePath(_:));

/// `EnumerateDirItemsAndSort` (UI/Common/EnumDirItems.cpp) driven by a censor built from `specs`
/// exactly as `AddNameToCensor` builds it — the call `GUI.cpp:285-304` makes to turn `-ai`/`-ax`
/// plus the archive name into its sorted archive list. **This is how a wildcard in an `-i!` or
/// `-x!` switch gets expanded**: by the engine's own directory walk, not by a matcher of our own.
///
/// Returns absolute paths, files only (a matched directory is walked, never reported). `specs` with
/// no include entry returns an empty array without touching the disk.
///
/// `sortedArchiveList` picks which of the engine's two walks runs, because they differ in one way
/// that matters:
///  * **YES** — `EnumerateDirItemsAndSort`, the extract group's archive list: the result is sorted
///    the way 7zG sorts it, a duplicate is "Duplicate archive path:" and **nothing matched is
///    "Cannot find archive"** (EnumDirItems.cpp:1496-1500), a `CMessagePathException`, which
///    `WinMain` turns into exit code **7**;
///  * **NO** — `EnumerateItems`, the walk `UpdateArchive` and `HashCalc` do for the item censor,
///    where an empty result is a legitimate "nothing to add".
///
/// A `CMessagePathException` comes back as an `NSError` carrying `SZPathExceptionUserInfoKey`, so
/// the caller can put it on `WinMain`'s exit-7 arm instead of the generic exit-2 one.
+ (nullable NSArray<NSString *> *)expandPathSpecs:(NSArray<SZPathSpec *> *)specs
                                sortedArchiveList:(BOOL)sortedArchiveList
                                            error:(NSError **)error
    NS_SWIFT_NAME(expandPathSpecs(_:sortedArchiveList:));

/// `updateWithOptions:sourcePaths:` with the censor entries spelled out, so include and exclude
/// wildcards reach `UpdateArchive` unexpanded and the engine walks the directories itself — which
/// is what keeps `a arc.7z -ir!src/*.c` storing `sub/x.c` rather than `x.c`.
/// `sourcePaths:` is this method with one `SZPathSpec.literal` per path.
+ (nullable SZUpdateResult *)updateWithOptions:(SZUpdateOptions *)options
                                     pathSpecs:(NSArray<SZPathSpec *> *)pathSpecs
                                      progress:(nullable id<SZProgressDelegate>)progress
                                         error:(NSError **)error
    NS_SWIFT_NAME(update(with:pathSpecs:progress:));

/// The console `rn` command (`GUI.cpp:328-375` update group, `Update.cpp:477-520`): renames the
/// archive's own items according to `pairs`, rewriting the archive in place. `itemSpecs` is the
/// `-i` mask that decides which archive items are considered at all; an empty list means `*`
/// (`AddToCensorFromNonSwitchesStrings`'s universal wildcard, ArchiveCommandLine.cpp:574-591).
/// A pair whose `isSupported` is NO is rejected with "Unsupported rename command:".
+ (nullable SZUpdateResult *)renameItemsWithPairs:(NSArray<SZRenamePair *> *)pairs
                                  inArchiveAtPath:(NSString *)archivePath
                                        itemSpecs:(NSArray<SZPathSpec *> *)itemSpecs
                                          options:(nullable SZUpdateOptions *)options
                                         progress:(nullable id<SZProgressDelegate>)progress
                                            error:(NSError **)error
    NS_SWIFT_NAME(renameItems(pairs:inArchiveAt:itemSpecs:options:progress:));

@end

NS_ASSUME_NONNULL_END

#endif

// SZFolder.h -- the browsing model: one IFolderFolder plus its optional interfaces.
// Instances are owned by one serial queue (the engine's COM refcounts are not atomic);
// never share a folder between threads.

#ifndef SZ_FOLDER_H
#define SZ_FOLDER_H

#import <Foundation/Foundation.h>
#import <SevenZipKit/SZTypes.h>

NS_ASSUME_NONNULL_BEGIN

@class SZArchive;
@class SZArcProps;
@protocol SZPasswordDelegate;
@protocol SZProgressDelegate;

/// A column declared by the folder (IFolderFolder::GetPropertyInfo).
@interface SZPropertyInfo : NSObject
@property (nonatomic, readonly) SZPropID propID;
@property (nonatomic, readonly) SZVarType varType;
/// Name supplied by the handler (rare; usually nil, meaning "use the standard name").
@property (nonatomic, readonly, copy, nullable) NSString *handlerName;
/// GetNameOfProperty(): lang string 1000 + propID, else the handler name, else the number.
@property (nonatomic, readonly, copy) NSString *localizedName;
/// YES for a column that comes from IArchiveGetRawProps (CPropColumn::IsRawProp,
/// PanelItems.cpp:177-199): WIM's SHA-1 and reparse data, XAR's checksum, the file-system image
/// handlers' raw fields. Its varType is SZVarTypeEmpty and its cells are rendered by the bridge
/// from the raw bytes (01 §3.2). kpidNtSecure is never listed (NT security is hidden, 01 §9 #7).
@property (nonatomic, readonly) BOOL isRawProperty;
@end

@interface SZFolder : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

#pragma mark Opening by path

/// Resolves a file-system path, walking into archives when a path component is an archive
/// file ("/Users/me/a.zip/dir" or "/Users/me/outer.zip/inner.7z/x"). Empty path = the root
/// folder (Computer/Volumes/Home/Documents). Runs the engine: call off the main thread.
+ (nullable SZFolder *)folderForPath:(NSString *)path
                    passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                               error:(NSError **)error NS_SWIFT_NAME(folder(forPath:passwordDelegate:));
/// The same, opening the first archive file on the path with `formatHint` (the 7zFM command
/// line's `-t<type>`, BindToPath's arcFormat: "7z", "*", "#", "zip:tar" ...; nil = detect).
+ (nullable SZFolder *)folderForPath:(NSString *)path
                          formatHint:(nullable NSString *)formatHint
                    passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                               error:(NSError **)error NS_SWIFT_NAME(folder(forPath:formatHint:passwordDelegate:));
/// The same with a progress delegate for every archive opened on the way
/// (SZArchiveOpener's `progress:` variants: the 7zFM "Opening" progress, IDS_OPENNING 3303).
+ (nullable SZFolder *)folderForPath:(NSString *)path
                          formatHint:(nullable NSString *)formatHint
                    passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                            progress:(nullable id<SZProgressDelegate>)progress
                               error:(NSError **)error NS_SWIFT_NAME(folder(forPath:formatHint:passwordDelegate:progress:));
/// YES when the volume that holds `path` (or its nearest existing ancestor) compares names
/// case-sensitively (pathconf _PC_CASE_SENSITIVE; URLResourceKey.volumeSupportsCaseSensitiveNames).
/// 01 §9 #24: Windows compares every path without case; on macOS it depends on the volume.
+ (BOOL)volumeIsCaseSensitiveAtPath:(NSString *)path NS_SWIFT_NAME(volumeIsCaseSensitive(atPath:));
/// GetWorkDir's "removable drive" test on macOS (DRIVE_REMOVABLE / DRIVE_CDROM on Windows): the
/// volume of `path` (or of its nearest existing ancestor) has removable media, or is ejectable and
/// not internal. Options > Folders "for removable drives only" uses it (01b §4.8).
+ (BOOL)volumeIsRemovableAtPath:(NSString *)path NS_SWIFT_NAME(volumeIsRemovable(atPath:));

#pragma mark Items

/// IFolderFolder::LoadItems. Must be called before reading items (folderForPath does it).
- (BOOL)loadItems:(NSError **)error;
@property (nonatomic, readonly) NSInteger itemCount;

- (NSString *)nameOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(nameOfItem(at:));
/// Flat-mode path prefix of the item (empty otherwise).
- (NSString *)prefixOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(prefixOfItem(at:));
- (uint64_t)sizeOfItemAtIndex:(NSInteger)index NS_SWIFT_NAME(sizeOfItem(at:));
- (BOOL)isDirectoryAtIndex:(NSInteger)index NS_SWIFT_NAME(isDirectory(at:));

/// Typed value: NSString (BSTR), NSNumber (integers/bool), NSDate (FILETIME) or nil (VT_EMPTY).
- (nullable id)propertyOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID NS_SWIFT_NAME(propertyOfItem(at:propID:));
/// Raw VARTYPE of the value returned by the handler for this item/property.
- (SZVarType)varTypeOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID NS_SWIFT_NAME(varTypeOfItem(at:propID:));
/// Text as 7zFM renders the cell (ConvertPropertyToString2): attributes as "D...", times at the
/// given precision, booleans as "+", numbers unformatted (size grouping is the caller's job).
- (NSString *)displayStringOfItemAtIndex:(NSInteger)index
                                  propID:(SZPropID)propID
                          timestampLevel:(SZTimestampLevel)level NS_SWIFT_NAME(displayStringOfItem(at:propID:timestampLevel:));

/// Columns declared by the folder, in the folder's order (includes kpidIsDir if declared),
/// followed by the raw properties (isRawProperty) when the folder implements
/// IArchiveGetRawProps -- the order CPanel::InitColumns builds them in.
@property (nonatomic, readonly, copy) NSArray<SZPropertyInfo *> *properties;

#pragma mark Raw properties (IArchiveGetRawProps, 01 §3.2, §3.11)

/// The raw bytes of a raw property (IArchiveGetRawProps::GetRawProp), nil when the item has none
/// or the property is not a raw one of this folder.
- (nullable NSData *)rawPropertyOfItemAtIndex:(NSInteger)index propID:(SZPropID)propID NS_SWIFT_NAME(rawPropertyOfItem(at:propID:));
/// A raw property as text. List form (PanelListNotify.cpp:265-349): reparse data decoded,
/// more than 64 bytes as "data:<size>", otherwise hex -- upper case for a CRC / checksum of at
/// most 8 bytes, lower case otherwise. Properties-dialog form (PanelMenu.cpp:212-246): the same
/// with a 256-byte limit and no reparse decoding. "" when the item has no value.
/// `displayStringOfItemAtIndex:` already returns the list form for raw columns.
- (NSString *)rawPropertyStringOfItemAtIndex:(NSInteger)index
                                      propID:(SZPropID)propID
                           forPropertiesDialog:(BOOL)forDialog NS_SWIFT_NAME(rawPropertyString(at:propID:forPropertiesDialog:));
/// The formatter behind rawPropertyStringOfItemAtIndex:, for bytes obtained elsewhere.
+ (NSString *)stringForRawPropertyData:(NSData *)data
                                propID:(SZPropID)propID
                   forPropertiesDialog:(BOOL)forDialog NS_SWIFT_NAME(rawPropertyString(data:propID:forPropertiesDialog:));

#pragma mark Folder properties

/// IFolderFolder::GetFolderProperty, typed like propertyOfItemAtIndex:.
- (nullable id)folderPropertyForID:(SZPropID)propID NS_SWIFT_NAME(folderProperty(forID:));
/// IFolderProperties (GetNumberOfFolderProperties / GetFolderPropertyInfo): the folder-level
/// properties the Properties dialog lists after the item block (CPanel::Properties,
/// PanelMenu.cpp:296-315). Empty when the folder does not implement the interface.
@property (nonatomic, readonly) NSArray<SZPropertyInfo *> *folderPropertyInfos;
/// A folder property as the Properties dialog shows it (AddPropertyString, PanelMenu.cpp:110-148):
/// kpidErrorFlags / kpidWarningFlags as their message ("" when no flag is set), everything else
/// through ConvertPropertyToString2 at level 9 (ns precision). "" for an empty value. Sizes come
/// back as plain digits; the caller groups them (ConvertSizeToString).
- (NSString *)propertiesDialogStringForFolderPropertyID:(SZPropID)propID NS_SWIFT_NAME(propertiesDialogString(forFolderProperty:));
/// kpidType: "RootFolder", "FSDrives", "FSFolder", "7-Zip.<ArcType>".
@property (nonatomic, readonly, copy) NSString *folderType;
/// kpidPath as reported by the folder: absolute dir with trailing "/" for the file system,
/// "" for the root, the in-archive prefix ("sub/") for archive folders.
@property (nonatomic, readonly, copy) NSString *path;
/// Address-bar path: file-system path, or "<archive path>/<inner prefix>" inside archives.
@property (nonatomic, readonly, copy) NSString *fullPath;
@property (nonatomic, readonly) BOOL isArchive;          ///< folder lives inside an archive
@property (nonatomic, readonly) BOOL isFileSystem;       ///< plain directory
@property (nonatomic, readonly) BOOL isRootFolder;       ///< the virtual root
@property (nonatomic, readonly) BOOL isReadOnly;         ///< kpidReadOnly
@property (nonatomic, readonly, nullable) SZArchive *archive;
/// IFolderArcProps via IGetFolderArcProps (archive folders only).
@property (nonatomic, readonly, nullable) SZArcProps *arcProps;

#pragma mark Navigation (each returns a new folder; items are already loaded)

- (nullable SZFolder *)bindToFolderAtIndex:(NSInteger)index error:(NSError **)error NS_SWIFT_NAME(bindToFolder(at:));
- (nullable SZFolder *)bindToFolderNamed:(NSString *)name error:(NSError **)error NS_SWIFT_NAME(bindToFolder(named:));
/// Walks a relative path component by component, opening archive files on the way.
- (nullable SZFolder *)bindToPath:(NSString *)relativePath
                 passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                            error:(NSError **)error NS_SWIFT_NAME(bindToPath(_:passwordDelegate:));
- (nullable SZFolder *)bindToPath:(NSString *)relativePath
                 passwordDelegate:(nullable id<SZPasswordDelegate>)passwordDelegate
                         progress:(nullable id<SZProgressDelegate>)progress
                            error:(NSError **)error NS_SWIFT_NAME(bindToPath(_:passwordDelegate:progress:));
/// The parent: BindToParentFolder, or for an archive root the folder the archive was opened
/// from. At the virtual root returns a fresh root folder (check isRootFolder before going up).
- (nullable SZFolder *)bindToParentFolder:(NSError **)error NS_SWIFT_NAME(bindToParentFolder());

#pragma mark Optional interfaces

@property (nonatomic, readonly) BOOL supportsFlatMode;     ///< IFolderSetFlatMode
/// Setting it requires loadItems: again.
@property (nonatomic) BOOL flatMode;
@property (nonatomic, readonly) BOOL supportsChangeNotification;   ///< IFolderWasChanged
/// IFolderWasChanged::WasChanged (resets the flag). File-system folders watch via FSEvents.
@property (nonatomic, readonly) BOOL wasChanged;
@property (nonatomic, readonly) BOOL supportsCompare;       ///< IFolderCompare
/// IFolderCompare::CompareItems (<0, 0, >0). Falls back to comparing typed values.
- (NSInteger)compareItemAtIndex:(NSInteger)index1 withItemAtIndex:(NSInteger)index2 propID:(SZPropID)propID NS_SWIFT_NAME(compareItem(at:with:propID:));
/// g_Timestamp_Show_UTC (Windows/PropVariantConv.h): display times as UTC instead of local.
@property (class, nonatomic) BOOL timestampShowUTC;
/// CompareFileNames_ForFolderList: case-insensitive, numeric-aware ("file2" < "file10").
+ (NSInteger)compareFileName:(NSString *)name1 withFileName:(NSString *)name2 NS_SWIFT_NAME(compareFileName(_:with:));

@end

/// Archive-level properties (IFolderArcProps): one level per nested handler
/// (e.g. level 0 = gzip, level 1 = tar for a .tar.gz).
@interface SZArcProps : NSObject
@property (nonatomic, readonly) NSInteger levelCount;
- (NSArray<SZPropertyInfo *> *)propertiesAtLevel:(NSInteger)level NS_SWIFT_NAME(properties(atLevel:));
- (nullable id)propertyAtLevel:(NSInteger)level propID:(SZPropID)propID NS_SWIFT_NAME(property(atLevel:propID:));
- (NSString *)displayStringAtLevel:(NSInteger)level propID:(SZPropID)propID NS_SWIFT_NAME(displayString(atLevel:propID:));
/// GetArcProp(level) as the Properties dialog shows it (AddPropertyString, see
/// -[SZFolder propertiesDialogStringForFolderPropertyID:]). `answered` is NO when GetArcProp did
/// not return S_OK (the dialog's separators depend on that, PanelMenu.cpp:389-410). Level
/// `levelCount` is the level that failed to open (NonOpen_ErrorInfo).
- (NSString *)propertiesDialogStringAtLevel:(NSInteger)level propID:(SZPropID)propID answered:(nullable BOOL *)answered NS_SWIFT_NAME(propertiesDialogString(atLevel:propID:answered:));
/// GetArcProp2 as the Properties dialog shows it; levels 1 ..< levelCount only, "" otherwise.
- (NSString *)propertiesDialogString2AtLevel:(NSInteger)level propID:(SZPropID)propID NS_SWIFT_NAME(propertiesDialogString2(atLevel:propID:));
/// The "2" variants (GetArcNumProps2 / GetArcProp2): the properties the level below (level - 1)
/// reports for the item this level was opened from. Only levels 1 ..< levelCount have them;
/// any other level answers empty / nil (CAgent itself would index Arcs[-1]).
- (NSArray<SZPropertyInfo *> *)properties2AtLevel:(NSInteger)level NS_SWIFT_NAME(properties2(atLevel:));
- (nullable id)property2AtLevel:(NSInteger)level propID:(SZPropID)propID NS_SWIFT_NAME(property2(atLevel:propID:));
@end

NS_ASSUME_NONNULL_END

#endif

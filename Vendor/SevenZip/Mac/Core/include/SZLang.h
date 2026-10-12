// SZLang.h -- 7-Zip Lang/*.txt localisation (CPP/Common/Lang.cpp rules, see
// 01-fm-feature-inventory.md section 7 and 04-toolchain.md section 4). String IDs are the
// Windows resource IDs. The built-in English table is Lang/en.ttt from the framework bundle.

#ifndef SZ_LANG_H
#define SZ_LANG_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SZLanguageInfo : NSObject
@property (nonatomic, readonly, copy) NSString *code;          ///< file name without .txt ("de", "pt-br")
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *englishName;   ///< string 1
@property (nonatomic, readonly, copy) NSString *nativeName;    ///< string 2
@property (nonatomic, readonly) NSInteger stringCount;
/// The file's comment lines (translator credits), as `CLang::Comments` holds them.
@property (nonatomic, readonly, copy) NSArray<NSString *> *comments;
/// The ids en.ttt has and this file lacks, as "<id> : <English text>", in id order
/// (`CLangInfo::MissingLines`, LangPage.cpp:197-245). Empty when en.ttt is not available.
@property (nonatomic, readonly, copy) NSArray<NSString *> *missingLines;
/// The ids this file has and en.ttt does not, as "<id> : <text>" (`CLangInfo::ExtraLines`).
@property (nonatomic, readonly, copy) NSArray<NSString *> *extraLines;
@end

@interface SZLang : NSObject

@property (class, nonatomic, readonly) SZLang *shared;

/// Lang string for an ID: current language file, else the English of 7zFM's own .rc resources
/// (what Windows shows with no language file; Mac/scripts/make-rc-strings.py), else en.ttt, else "".
- (NSString *)stringForID:(uint32_t)langID NS_SWIFT_NAME(string(forID:));
/// Same, with an explicit fallback when neither table has the ID.
- (NSString *)stringForID:(uint32_t)langID fallback:(NSString *)fallback NS_SWIFT_NAME(string(forID:fallback:));
/// A dialog control's text (LangSetDlgItems): the language file, else the control's text in that
/// dialog's .rc resource (`dialogID` = the IDD, e.g. 3800 for IDD_PASSWORD), else as above.
/// `colon` = LangSetDlgItems_Colon: a translated text gets ":" appended, the .rc text has it.
- (NSString *)stringForID:(uint32_t)langID inDialog:(uint32_t)dialogID colon:(BOOL)colon fallback:(NSString *)fallback
    NS_SWIFT_NAME(string(forID:inDialog:colon:fallback:));
/// Only from the loaded language file (LangString_OnlyFromLangFile); nil if absent or no file.
- (nullable NSString *)translatedStringForID:(uint32_t)langID NS_SWIFT_NAME(translatedString(forID:));
/// Built-in English (MyLoadString equivalent): en.ttt, then the few Windows resource-only
/// strings (PropertyName.rc names missing from en.ttt); "" if unknown.
- (NSString *)englishStringForID:(uint32_t)langID NS_SWIFT_NAME(englishString(forID:));

/// Loads Lang/<code>.txt. code nil or "" = pick from the system UI language; "-" = built-in
/// English only. A bad file leaves English active and returns NO.
- (BOOL)loadLanguageWithCode:(nullable NSString *)code error:(NSError **)error NS_SWIFT_NAME(loadLanguage(code:));
/// Loads a specific file (for tests / custom locations).
- (BOOL)loadLanguageFile:(NSString *)path error:(NSError **)error NS_SWIFT_NAME(loadLanguageFile(_:));
/// The code currently active ("" = none / built-in English).
@property (nonatomic, readonly, copy) NSString *currentLanguageCode;
/// Header comments of the loaded file (translator credits), as 7zFM's Language page shows them.
@property (nonatomic, readonly, copy) NSArray<NSString *> *comments;

/// Every Lang/*.txt in the bundle that loads, sorted by code.
@property (nonatomic, readonly, copy) NSArray<SZLanguageInfo *> *availableLanguages;
/// The Lang/*.txt file names that did **not** load (LangPage.cpp:118-123 collects them for the
/// "Error in Lang file" box). Computed together with `availableLanguages`.
@property (nonatomic, readonly, copy) NSArray<NSString *> *failedLanguageFiles;
/// The scan behind `availableLanguages`, for any directory (tests, custom locations): every
/// `*.txt` that opens as a 7-Zip lang file, compared id by id with the built-in English table;
/// the names of the files that do not open go to `failedFiles`.
- (NSArray<SZLanguageInfo *> *)languagesInDirectory:(NSString *)directory
                                        failedFiles:(NSArray<NSString *> * _Nullable * _Nullable)failedFiles
    NS_SWIFT_NAME(languages(inDirectory:failedFiles:));
@property (class, nonatomic, readonly) NSString *langDirectoryPath;
/// Number of strings in the English template (k_NumLangLines_EN, for completeness %).
@property (nonatomic, readonly) NSInteger englishStringCount;

/// Candidate codes for the system language, most specific first ("pt-br", "pt").
@property (class, nonatomic, readonly) NSArray<NSString *> *systemLanguageCandidates;

@end

NS_ASSUME_NONNULL_END

#endif

// SZSettings.mm -- see SZSettings.h

#import "SZSettings.h"
#import "Internal/SZBridgeUtils.h"

NSString * const SZSettingsSuiteEnvironmentVariable = @"SEVENZIP_DEFAULTS_SUITE";
NSString * const SZSettingsDefaultApplicationID = @"com.yrambler2001.7zip";
NSString * const SZSettingsTestSupportEnvironmentVariable = @"SZ_TEST_SUPPORT";
NSString * const SZSettingsStateDirectoryEnvironmentVariable = @"SZ_STATE_DIR";

NSString * const SZSettingsKeyLang = @"Lang";
NSString * const SZSettingsKeyFMPosition = @"FM.Position";
NSString * const SZSettingsKeyFMMaximized = @"FM.Maximized";
NSString * const SZSettingsKeyFMNumPanels = @"FM.Panels.numPanels";
NSString * const SZSettingsKeyFMCurrentPanel = @"FM.Panels.currentPanel";
NSString * const SZSettingsKeyFMSplitterPos = @"FM.Panels.splitterPos";
NSString * const SZSettingsKeyFMToolbars = @"FM.Toolbars";
NSString * const SZSettingsKeyFMListMode0 = @"FM.ListMode0";
NSString * const SZSettingsKeyFMListMode1 = @"FM.ListMode1";
NSString * const SZSettingsKeyFMPanelPath0 = @"FM.PanelPath0";
NSString * const SZSettingsKeyFMPanelPath1 = @"FM.PanelPath1";
NSString * const SZSettingsKeyFMFlatViewArc0 = @"FM.FlatViewArc0";
NSString * const SZSettingsKeyFMFlatViewArc1 = @"FM.FlatViewArc1";
NSString * const SZSettingsKeyFMFolderHistory = @"FM.FolderHistory";
NSString * const SZSettingsKeyFMFolderShortcuts = @"FM.FolderShortcuts";
NSString * const SZSettingsKeyFMCopyHistory = @"FM.CopyHistory";
NSString * const SZSettingsKeyFMShowDots = @"FM.ShowDots";
NSString * const SZSettingsKeyFMShowRealFileIcons = @"FM.ShowRealFileIcons";
NSString * const SZSettingsKeyFMFullRow = @"FM.FullRow";
NSString * const SZSettingsKeyFMShowGrid = @"FM.ShowGrid";
NSString * const SZSettingsKeyFMSingleClick = @"FM.SingleClick";
NSString * const SZSettingsKeyFMAlternativeSelection = @"FM.AlternativeSelection";
NSString * const SZSettingsKeyFMShowSystemMenu = @"FM.ShowSystemMenu";
NSString * const SZSettingsKeyFMViewer = @"FM.Viewer";
NSString * const SZSettingsKeyFMEditor = @"FM.Editor";
NSString * const SZSettingsKeyFMDiff = @"FM.Diff";
NSString * const SZSettingsKeyWorkDirType = @"Options.WorkDirType";
NSString * const SZSettingsKeyWorkDirPath = @"Options.WorkDirPath";
NSString * const SZSettingsKeyTempRemovableOnly = @"Options.TempRemovableOnly";

using namespace NMacPrefs;

@implementation SZSettings

+ (NSString *)applicationID
{
  return @(ApplicationID().Ptr());
}

+ (NSString *)defaultApplicationID
{
  return @(DefaultApplicationID().Ptr());
}

+ (BOOL)usesOverrideSuite
{
  return ![[self applicationID] isEqualToString:[self defaultApplicationID]];
}

// Read from the environment on every call, exactly as ApplicationID() does, so a test may set
// them with setenv() at any point in the process's life.
static NSString *SZEnvironmentValue(NSString *name)
{
  const char *value = getenv(name.UTF8String);
  if (!value || !*value)
    return nil;
  return @(value);
}

+ (BOOL)testSupportEnabled
{
  return [SZEnvironmentValue(SZSettingsTestSupportEnvironmentVariable) isEqualToString:@"1"];
}

+ (nullable NSString *)stateDirectory
{
  if (![self testSupportEnabled])
    return nil;
  NSString *dir = SZEnvironmentValue(SZSettingsStateDirectoryEnvironmentVariable);
  if (!dir.isAbsolutePath)
    return nil;
  return dir.stringByStandardizingPath;
}

+ (NSString *)temporaryDirectory
{
  NSString *state = [self stateDirectory];
  if (!state)
    return NSTemporaryDirectory();
  // A trailing separator, like NSTemporaryDirectory(), because callers concatenate and compare
  // prefixes against it (SZTempOpen's containment guard, PanelDragDrop's AreThereNamesFromTemp).
  NSString *temp = [[state stringByAppendingPathComponent:@"tmp"] stringByAppendingString:@"/"];
  // Created here rather than at launch: mkdtemp() and the list-file writers need it to exist, and
  // the cost of one cached stat is nothing next to the operation that follows.
  static NSString *created = nil;
  static NSObject *lock = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  @synchronized (lock) {
    if (![created isEqualToString:temp]) {
      [[NSFileManager defaultManager] createDirectoryAtPath:temp
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
      created = temp;
    }
  }
  return temp;
}

+ (NSString *)stringForKey:(NSString *)key
{
  UString s;
  if (!GetString(key.UTF8String, s))
    return nil;
  return SZStringFromUString(s);
}

+ (void)setString:(NSString *)value forKey:(NSString *)key
{
  if (value)
    SetString(key.UTF8String, SZUStringFromNSString(value));
  else
    Remove(key.UTF8String);
  Sync();
}

+ (NSInteger)integerForKey:(NSString *)key defaultValue:(NSInteger)defaultValue
{
  UInt32 v = 0;
  if (!GetUInt32(key.UTF8String, v))
    return defaultValue;
  return (NSInteger)(Int32)v;
}

+ (void)setInteger:(NSInteger)value forKey:(NSString *)key
{
  SetUInt32(key.UTF8String, (UInt32)(Int32)value);
  Sync();
}

+ (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue
{
  // doubles are stored as strings so that NMacPrefs stays integer/string only
  NSString *s = [self stringForKey:key];
  if (!s)
    return defaultValue;
  return [s doubleValue];
}

+ (void)setDouble:(double)value forKey:(NSString *)key
{
  [self setString:[NSString stringWithFormat:@"%.6f", value] forKey:key];
}

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue
{
  bool v = false;
  if (!GetBool(key.UTF8String, v))
    return defaultValue;
  return v;
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key
{
  SetBool(key.UTF8String, value);
  Sync();
}

+ (NSNumber *)boolPairForKey:(NSString *)key
{
  bool v = false;
  if (!GetBool(key.UTF8String, v))
    return nil;
  return @(v);
}

+ (void)setBoolPair:(NSNumber *)value forKey:(NSString *)key
{
  if (value)
    SetBool(key.UTF8String, value.boolValue);
  else
    Remove(key.UTF8String);
  Sync();
}

+ (NSArray<NSString *> *)stringArrayForKey:(NSString *)key
{
  UStringVector v;
  if (!GetStrings(key.UTF8String, v))
    return nil;
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:v.Size()];
  FOR_VECTOR (i, v)
    [result addObject:SZStringFromUString(v[i])];
  return result;
}

+ (void)setStringArray:(NSArray<NSString *> *)value forKey:(NSString *)key
{
  if (!value)
  {
    Remove(key.UTF8String);
  }
  else
  {
    UStringVector v;
    for (NSString *s in value)
      v.Add(SZUStringFromNSString(s));
    SetStrings(key.UTF8String, v);
  }
  Sync();
}

+ (BOOL)hasKey:(NSString *)key
{
  return Exists(key.UTF8String);
}

+ (void)removeKey:(NSString *)key
{
  Remove(key.UTF8String);
  Sync();
}

+ (NSArray<NSString *> *)keysWithPrefix:(NSString *)prefix
{
  AStringVector keys;
  ListKeys(prefix.UTF8String, keys);
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:keys.Size()];
  FOR_VECTOR (i, keys)
    [result addObject:[NSString stringWithUTF8String:keys[i].Ptr()] ?: @""];
  return result;
}

+ (nullable id)propertyListValueForKey:(NSString *)key
{
  CFStringRef k = (__bridge CFStringRef)key;
  CFStringRef domain = (__bridge CFStringRef)[self applicationID];
  CFPropertyListRef v = CFPreferencesCopyAppValue(k, domain);
  if (!v)
    return nil;
  id value = (__bridge_transfer id)v;
  return value;
}

+ (void)setPropertyListValue:(nullable id)value forKey:(NSString *)key
{
  if (WritesSuspended())
    return;
  CFStringRef k = (__bridge CFStringRef)key;
  CFStringRef domain = (__bridge CFStringRef)[self applicationID];
  CFPreferencesSetAppValue(k, (__bridge CFPropertyListRef)value, domain);
}

+ (void)synchronize
{
  Sync();
}

+ (BOOL)writesSuspended
{
  return WritesSuspended();
}

+ (void)setWritesSuspended:(BOOL)writesSuspended
{
  SetWritesSuspended(writesSuspended);
}

@end

@implementation SZWorkDirSettings

- (instancetype)init
{
  self = [super init];
  if (!self)
    return nil;
  _mode = SZWorkDirModeSystem;
  _path = @"";
  _forRemovableOnly = YES;
  return self;
}

+ (SZWorkDirSettings *)loadFromSettings
{
  NWorkDir::CInfo info;
  info.Load();
  SZWorkDirSettings *s = [[SZWorkDirSettings alloc] init];
  s.mode = (SZWorkDirMode)info.Mode;
  s.path = SZStringFromFString(info.Path);
  s.forRemovableOnly = info.ForRemovableOnly;
  return s;
}

- (void)save
{
  NWorkDir::CInfo info;
  info.Mode = (NWorkDir::NMode::EEnum)_mode;
  info.Path = SZFStringFromNSString(_path);
  info.ForRemovableOnly = _forRemovableOnly;
  info.Save();
}

@end

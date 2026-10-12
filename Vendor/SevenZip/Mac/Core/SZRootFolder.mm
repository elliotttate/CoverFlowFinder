// SZRootFolder.mm -- see SZRootFolder.h

#import "SZRootFolder.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZFolder+Internal.h"

using namespace NMacFolders;

@implementation SZRootFolder

+ (SZRootFolder *)rootFolder
{
  CRootFolderMac *spec = new CRootFolderMac;
  CMyComPtr<IFolderFolder> raw = spec;
  spec->Init();
  SZRootFolder *folder = [[SZRootFolder alloc] initWithRawFolder:raw archive:nil];
  [folder loadItems:NULL];
  return folder;
}

+ (SZRootFolder *)volumesFolder
{
  CVolumesFolderMac *spec = new CVolumesFolderMac;
  CMyComPtr<IFolderFolder> raw = spec;
  SZRootFolder *folder = [[SZRootFolder alloc] initWithRawFolder:raw archive:nil];
  [folder loadItems:NULL];
  return folder;
}

- (BOOL)isVolumesFolder
{
  return [self.folderType isEqualToString:@"FSDrives"];
}

- (NSString *)mountPathOfItemAtIndex:(NSInteger)index
{
  if (!self.isVolumesFolder || index < 0 || index >= self.itemCount)
    return nil;
  id v = [self propertyOfItemAtIndex:index propID:SZPropIDPath];
  return [v isKindOfClass:[NSString class]] && ((NSString *)v).length ? v : nil;
}

+ (NSArray<NSString *> *)rootEntryNames
{
  UString names[kNumRootFolderItems];
  RootFolder_GetNames(names);
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:kNumRootFolderItems];
  for (unsigned i = 0; i < kNumRootFolderItems; i++)
    [result addObject:SZStringFromUString(names[i])];
  return result;
}

- (NSString *)fullPath
{
  NSString *p = self.path;
  return p.length ? [p stringByAppendingString:@"/"] : @"";
}

@end

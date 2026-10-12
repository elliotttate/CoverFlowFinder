// SZFolder+Internal.h -- ObjC++-only constructors and raw access shared by the bridge.

#ifndef SZ_FOLDER_INTERNAL_H
#define SZ_FOLDER_INTERNAL_H

#import "SZFolder.h"
#import "SZArchiveOpener.h"
#include "SZEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFolder ()
/// Wraps a raw folder in the right subclass (by kpidType). Does not load items.
+ (SZFolder *)folderWithRawFolder:(IFolderFolder *)folder archive:(nullable SZArchive *)archive;
- (instancetype)initWithRawFolder:(IFolderFolder *)folder archive:(nullable SZArchive *)archive NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly) IFolderFolder *rawFolder;
@end

@interface SZArcProps ()
- (instancetype)initWithRawProps:(IFolderArcProps *)props;
@end

@interface SZPropertyInfo ()
- (instancetype)initWithPropID:(SZPropID)propID varType:(SZVarType)varType handlerName:(nullable NSString *)name;
- (instancetype)initWithPropID:(SZPropID)propID varType:(SZVarType)varType handlerName:(nullable NSString *)name isRaw:(BOOL)isRaw;
@end

@interface SZArchive ()
@property (nonatomic, readonly, nullable) IInArchive *rawArchive;
- (instancetype)initWithAgent:(IInFolderArchive *)agent
                    agentSpec:(CAgent *)agentSpec
                 openCallback:(IArchiveOpenCallback *)openCallback
                     inStream:(nullable IInStream *)inStream
                         path:(NSString *)path
                         type:(NSString *)type
                  outerFolder:(nullable SZFolder *)outerFolder
               outerItemIndex:(NSInteger)outerItemIndex
                tempDirectory:(nullable NSString *)tempDirectory;
@end

NS_ASSUME_NONNULL_END

#endif

// SZFolderOperations.mm -- see SZFolderOperations.h. Thin, faithful wrappers around
// IFolderOperations / IArchiveFolder with the SZCallbackAdapters in between.

#import "SZFolderOperations.h"
#import "SZError.h"
#import "SZLang.h"
#import "Internal/SZBridgeUtils.h"
#import "Internal/SZCallbackAdapters.h"
#import "Internal/SZFolder+Internal.h"

#include <sys/xattr.h>

@implementation SZOperationSummary {
@public
    uint64_t _filesProcessed;
    NSUInteger _errorCount;
    SZOperationResult _firstFailure;
    BOOL _passwordWasAsked;
}
- (uint64_t)filesProcessed { return _filesProcessed; }
- (NSUInteger)errorCount { return _errorCount; }
- (SZOperationResult)firstFailure { return _firstFailure; }
- (BOOL)passwordWasAsked { return _passwordWasAsked; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<SZOperationSummary files=%llu errors=%lu firstFailure=%ld>",
            (unsigned long long)_filesProcessed, (unsigned long)_errorCount, (long)_firstFailure];
}
@end

// ---------------------------------------------------------------------------
// helpers

/// IFolderSetZoneIdMode + IFolderSetZoneIdFile (PanelCopy.cpp:76-92): the quarantine policy
/// for the next CopyTo / Extract of an archive folder. `source` is the file whose
/// `com.apple.quarantine` bytes are propagated (Get_ZoneId_Stream_from_ParentFolders); nil
/// leaves the agent to read its own archive file. A folder without the interfaces is a no-op.
static HRESULT SZSetFolderZone(IUnknown *folder, SZZoneIDMode zoneMode, NSString *source)
{
    {
        CMyComPtr<IFolderSetZoneIdMode> setZoneMode;
        folder->QueryInterface(IID_IFolderSetZoneIdMode, (void **)&setZoneMode);
        if (setZoneMode)
            RINOK(setZoneMode->SetZoneIdMode((NExtract::NZoneIdMode::EEnum)zoneMode))
    }
    CMyComPtr<IFolderSetZoneIdFile> setZoneFile;
    folder->QueryInterface(IID_IFolderSetZoneIdFile, (void **)&setZoneFile);
    if (!setZoneFile)
        return S_OK;
    CByteBuffer zoneBuf;
    if (zoneMode != SZZoneIDModeNone && source.length != 0)
    {
        const char *path = source.fileSystemRepresentation;
        const ssize_t size = getxattr(path, "com.apple.quarantine", NULL, 0, 0, 0);
        if (size > 0 && size < (1 << 15))
        {
            zoneBuf.Alloc((size_t)size);
            if (getxattr(path, "com.apple.quarantine", zoneBuf, (size_t)size, 0, 0) != size)
                zoneBuf.Free();
        }
    }
    return setZoneFile->SetZoneIdFile(zoneBuf, (UInt32)zoneBuf.Size());
}

/// Directory paths handed to the engine must end with a separator: CArchiveExtractCallback
/// and FSFolderCopy append the item names straight onto them.
static NSString *SZDirPathWithSeparator(NSString *path)
{
    if (path.length == 0)
        return @"/";
    return [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
}

static void SZIndexVector(NSArray<NSNumber *> *indexes, CRecordVector<UInt32> &out)
{
    out.Clear();
    for (NSNumber *n in indexes)
        out.Add((UInt32)n.unsignedIntegerValue);
}

/// E_NOTIMPL / "the folder has no such interface" as a readable SZError. Lang 6008 is
/// 7zFM's own text (MessageBox_Error_UnsupportOperation, Panel.cpp).
static NSError *SZUnsupportedOperationError(NSString *operation, SZFolder *folder)
{
    NSString *base = [SZLang.shared stringForID:6008 fallback:@"The operation is not supported for this folder."];
    return [SZErrors errorWithCode:SZErrorCodeNotImplemented
                           message:[NSString stringWithFormat:@"%@ (%@: %@)", base, folder.folderType, operation]];
}

static BOOL SZFinishOperation(HRESULT hr, NSString *message, NSString *operation,
                              SZFolder *folder, NSError **error)
{
    if (hr == S_OK)
        return YES;
    if (hr == E_NOTIMPL)
    {
        if (error)
            *error = SZUnsupportedOperationError(operation, folder);
        return NO;
    }
    if (error)
        *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:message];
    return NO;
}

@implementation SZFolder (SZFolderOperations)

#pragma mark Capabilities

- (BOOL)supportsOperations
{
    CMyComPtr<IFolderOperations> ops;
    self.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&ops);
    return ops != NULL;
}

- (BOOL)supportsArchiveExtract
{
    CMyComPtr<IArchiveFolder> af;
    self.rawFolder->QueryInterface(IID_IArchiveFolder, (void **)&af);
    return af != NULL;
}

- (BOOL)supportsCalcItemFullSize
{
    CMyComPtr<IFolderCalcItemFullSize> calc;
    self.rawFolder->QueryInterface(IID_IFolderCalcItemFullSize, (void **)&calc);
    if (calc)
        return YES;
    CMyComPtr<IFolderGetItemFullSize> get;
    self.rawFolder->QueryInterface(IID_IFolderGetItemFullSize, (void **)&get);
    return get != NULL;
}

#pragma mark Copy / move

- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  moveMode:(BOOL)moveMode
                  zoneMode:(SZZoneIDMode)zoneMode
            zoneSourcePath:(NSString *)zoneSourcePath
                  progress:(id<SZProgressDelegate>)progress
                     error:(NSError **)error
{
    CMyComPtr<IFolderOperations> ops;
    self.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&ops);
    if (!ops)
    {
        if (error)
            *error = SZUnsupportedOperationError(moveMode ? @"CopyTo (move)" : @"CopyTo", self);
        return NO;
    }

    NSString *dest = SZDirPathWithSeparator(destinationPath);
    NSString *message = nil;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CMyComPtr2<IFolderOperationsExtractCallback, CSZExtractCallbackAdapter> cb;
        cb.Create_if_Empty();
        cb->Delegate = progress;
        cb->ArchivePath = self.fullPath;
        // 7zFM always copies with "ask" overwrite mode (ArchiveFolder.cpp:47).
        cb->OverwriteMode = NExtract::NOverwriteMode::kAsk;
        if ([progress respondsToSelector:@selector(progressSetStatus:)])
            [progress progressSetStatus:moveMode ? SZProgressStatusMoving : SZProgressStatusCopying];
        // PanelCopy.cpp:76-92: the zone mode and the zone bytes are set before every CopyTo,
        // so an earlier call's policy never leaks into this one.
        RINOK(SZSetFolderZone(ops, zoneMode, zoneSourcePath))
        CRecordVector<UInt32> indices;
        SZIndexVector(indexes, indices);
        return ops->CopyTo(BoolToInt(moveMode != NO), indices.ConstData(), indices.Size(),
            BoolToInt(false), 0, SZUStringFromNSString(dest).Ptr(), cb.Interface());
    });
    return SZFinishOperation(hr, message, moveMode ? @"CopyTo (move)" : @"CopyTo", self, error);
}

- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  progress:(id<SZProgressDelegate>)progress
                     error:(NSError **)error
{
    return [self copyItemsAtIndexes:indexes toPath:destinationPath moveMode:NO
                           zoneMode:SZFolder.registryZoneMode zoneSourcePath:nil
                           progress:progress error:error];
}

- (BOOL)copyItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  zoneMode:(SZZoneIDMode)zoneMode
            zoneSourcePath:(NSString *)zoneSourcePath
                  progress:(id<SZProgressDelegate>)progress
                     error:(NSError **)error
{
    return [self copyItemsAtIndexes:indexes toPath:destinationPath moveMode:NO
                           zoneMode:zoneMode zoneSourcePath:zoneSourcePath
                           progress:progress error:error];
}

+ (SZZoneIDMode)registryZoneMode
{
    // CPanel::CopyTo: `if (ci.WriteZone != (UInt32)(Int32)-1) options.ZoneIdMode = ci.WriteZone`
    CContextMenuInfo ci;
    ci.Load();
    // sec113: an unset value (-1) is All on macOS, not None as on Windows, so a copy out of a
    // quarantined archive stays quarantined (Settings.writeZoneIdExtract, docs/parity.md).
    switch ((Int32)ci.WriteZone)
    {
        case -1:
        case 1: return SZZoneIDModeAll;
        case 2: return SZZoneIDModeOffice;
        default: return SZZoneIDModeNone;
    }
}

- (BOOL)moveItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    toPath:(NSString *)destinationPath
                  progress:(id<SZProgressDelegate>)progress
                     error:(NSError **)error
{
    return [self copyItemsAtIndexes:indexes toPath:destinationPath moveMode:YES
                           zoneMode:SZFolder.registryZoneMode zoneSourcePath:nil
                           progress:progress error:error];
}

- (BOOL)copyItemsNamed:(NSArray<NSString *> *)itemNames
        fromFolderPath:(NSString *)folderPath
              moveMode:(BOOL)moveMode
              progress:(id<SZProgressDelegate>)progress
                 error:(NSError **)error
{
    CMyComPtr<IFolderOperations> ops;
    self.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&ops);
    if (!ops)
    {
        if (error)
            *error = SZUnsupportedOperationError(@"CopyFrom", self);
        return NO;
    }

    NSString *message = nil;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CMyComPtr2<IProgress, CSZUpdateCallbackAdapter> cb;
        cb.Create_if_Empty();
        cb->Delegate = progress;
        cb->ArchivePath = self.fullPath;
        // The engine wants an array of wchar_t* that outlives the call.
        UStringVector names;
        for (NSString *name in itemNames)
            names.Add(SZUStringFromNSString(name));
        CRecordVector<const wchar_t *> pointers;
        FOR_VECTOR (i, names)
            pointers.Add(names[i].Ptr());
        return ops->CopyFrom(BoolToInt(moveMode != NO),
            SZUStringFromNSString(SZDirPathWithSeparator(folderPath)).Ptr(),
            pointers.ConstData(), pointers.Size(), cb.Interface());
    });
    return SZFinishOperation(hr, message, @"CopyFrom", self, error);
}

#pragma mark Item operations

/// Runs one IFolderOperations method that only takes an IProgress.
- (BOOL)sz_runUpdateOperationNamed:(NSString *)name
                          progress:(id<SZProgressDelegate>)progress
                            status:(SZProgressStatus)status
                             error:(NSError **)error
                             block:(HRESULT (^)(IFolderOperations *ops, IProgress *cb))block
{
    CMyComPtr<IFolderOperations> ops;
    self.rawFolder->QueryInterface(IID_IFolderOperations, (void **)&ops);
    if (!ops)
    {
        if (error)
            *error = SZUnsupportedOperationError(name, self);
        return NO;
    }
    NSString *message = nil;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CMyComPtr2<IProgress, CSZUpdateCallbackAdapter> cb;
        cb.Create_if_Empty();
        cb->Delegate = progress;
        cb->ArchivePath = self.fullPath;
        if (status != SZProgressStatusNone && [progress respondsToSelector:@selector(progressSetStatus:)])
            [progress progressSetStatus:status];
        return block(ops, cb.Interface());
    });
    return SZFinishOperation(hr, message, name, self, error);
}

- (BOOL)deleteItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                    progress:(id<SZProgressDelegate>)progress
                       error:(NSError **)error
{
    return [self sz_runUpdateOperationNamed:@"Delete" progress:progress status:SZProgressStatusDeleting
                                      error:error block:^HRESULT(IFolderOperations *ops, IProgress *cb) {
        CRecordVector<UInt32> indices;
        SZIndexVector(indexes, indices);
        return ops->Delete(indices.ConstData(), indices.Size(), cb);
    }];
}

- (BOOL)renameItemAtIndex:(NSInteger)index
                   toName:(NSString *)newName
                 progress:(id<SZProgressDelegate>)progress
                    error:(NSError **)error
{
    return [self sz_runUpdateOperationNamed:@"Rename" progress:progress status:SZProgressStatusRenaming
                                      error:error block:^HRESULT(IFolderOperations *ops, IProgress *cb) {
        return ops->Rename((UInt32)index, SZUStringFromNSString(newName).Ptr(), cb);
    }];
}

- (BOOL)createFolderNamed:(NSString *)name
                 progress:(id<SZProgressDelegate>)progress
                    error:(NSError **)error
{
    return [self sz_runUpdateOperationNamed:@"CreateFolder" progress:progress status:SZProgressStatusNone
                                      error:error block:^HRESULT(IFolderOperations *ops, IProgress *cb) {
        return ops->CreateFolder(SZUStringFromNSString(name).Ptr(), cb);
    }];
}

- (BOOL)createFileNamed:(NSString *)name
               progress:(id<SZProgressDelegate>)progress
                  error:(NSError **)error
{
    return [self sz_runUpdateOperationNamed:@"CreateFile" progress:progress status:SZProgressStatusNone
                                      error:error block:^HRESULT(IFolderOperations *ops, IProgress *cb) {
        return ops->CreateFile(SZUStringFromNSString(name).Ptr(), cb);
    }];
}

- (BOOL)setComment:(NSString *)comment
    forItemAtIndex:(NSInteger)index
          progress:(id<SZProgressDelegate>)progress
             error:(NSError **)error
{
    return [self sz_runUpdateOperationNamed:@"SetProperty(kpidComment)" progress:progress
                                     status:SZProgressStatusNone error:error
                                      block:^HRESULT(IFolderOperations *ops, IProgress *cb) {
        NWindows::NCOM::CPropVariant prop;
        if (comment.length != 0)
            prop = SZUStringFromNSString(comment);
        return ops->SetProperty((UInt32)index, kpidComment, &prop, cb);
    }];
}

#pragma mark Sizes

- (nullable NSNumber *)calculateFullSizeOfItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                                                progress:(id<SZProgressDelegate>)progress
                                                   error:(NSError **)error
{
    NSString *message = nil;
    uint64_t total = 0;
    BOOL cancelled = NO;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CMyComPtr2<IProgress, CSZProgressAdapter> cb;
        cb.Create_if_Empty();
        cb->Delegate = progress;

        CMyComPtr<IFolderCalcItemFullSize> calc;
        self.rawFolder->QueryInterface(IID_IFolderCalcItemFullSize, (void **)&calc);
        CMyComPtr<IFolderGetItemFullSize> get;
        self.rawFolder->QueryInterface(IID_IFolderGetItemFullSize, (void **)&get);

        for (NSNumber *n in indexes)
        {
            if (progress && [progress progressCheckBreak])
            {
                cancelled = YES;
                return E_ABORT;
            }
            const NSInteger index = (NSInteger)n.unsignedIntegerValue;
            if (get)
            {
                NWindows::NCOM::CPropVariant prop;
                RINOK(get->GetItemFullSize((UInt32)index, &prop, cb.Interface()))
                UInt64 v = 0;
                if (ConvertPropVariantToUInt64(prop, v))
                {
                    total += v;
                    continue;
                }
            }
            else if (calc)
            {
                RINOK(calc->CalcItemFullSize((UInt32)index, cb.Interface()))
                // CalcItemFullSize caches the value; kpidSize then answers it.
                NSNumber *size = (NSNumber *)[self propertyOfItemAtIndex:index propID:SZPropIDSize];
                if ([size isKindOfClass:[NSNumber class]])
                {
                    total += size.unsignedLongLongValue;
                    continue;
                }
            }
            // Fallback: the folder's own numbers, recursing into sub-folders.
            uint64_t sub = 0;
            if (![self sz_fullSizeOfItemAtIndex:index into:&sub progress:progress error:error])
                return E_ABORT;
            total += sub;
            if (progress)
                [progress progressSetCompleted:total];
        }
        return S_OK;
    });

    if (hr == S_OK)
        return @(total);
    if (cancelled && error)
        *error = [SZErrors errorWithHRESULT:(uint32_t)E_ABORT message:nil];
    else if (error && !*error)
        *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:message];
    return nil;
}

/// Recursive size of one item without any optional interface: the folder's kpidSize for
/// files and archive directories (CProxyDir::Size), a BindToFolder walk otherwise.
- (BOOL)sz_fullSizeOfItemAtIndex:(NSInteger)index
                            into:(uint64_t *)outSize
                        progress:(id<SZProgressDelegate>)progress
                           error:(NSError **)error
{
    if (progress && [progress progressCheckBreak])
    {
        if (error)
            *error = [SZErrors errorWithHRESULT:(uint32_t)E_ABORT message:nil];
        return NO;
    }
    if (![self isDirectoryAtIndex:index])
    {
        *outSize += [self sizeOfItemAtIndex:index];
        return YES;
    }
    // Archive folders know a directory's recursive size already (kpidSize on the item).
    id size = [self propertyOfItemAtIndex:index propID:SZPropIDSize];
    if (self.isArchive && [size isKindOfClass:[NSNumber class]])
    {
        *outSize += ((NSNumber *)size).unsignedLongLongValue;
        return YES;
    }
    NSError *bindError = nil;
    SZFolder *sub = [self bindToFolderAtIndex:index error:&bindError];
    if (!sub)
    {
        // An unreadable sub-folder is reported, not fatal (7zFM skips it too).
        if (progress)
            [progress progressShowMessage:bindError.localizedDescription ?: @"Cannot open folder"];
        return YES;
    }
    for (NSInteger i = 0; i < sub.itemCount; i++)
        if (![sub sz_fullSizeOfItemAtIndex:i into:outSize progress:progress error:error])
            return NO;
    return YES;
}

#pragma mark Extract / test

- (nullable SZOperationSummary *)extractItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                                                toPath:(NSString *)destinationPath
                                              pathMode:(SZExtractPathMode)pathMode
                                         overwriteMode:(SZOverwriteMode)overwriteMode
                                              testMode:(BOOL)testMode
                                              progress:(id<SZProgressDelegate>)progress
                                                 error:(NSError **)error
{
    // Drag-out, temp-open and Test pass kNone, as PanelDrag.cpp:2887 / PanelItemOpen.cpp do.
    return [self extractItemsAtIndexes:indexes toPath:destinationPath pathMode:pathMode
                         overwriteMode:overwriteMode testMode:testMode
                              zoneMode:SZZoneIDModeNone zoneSourcePath:nil
                              progress:progress error:error];
}

- (nullable SZOperationSummary *)extractItemsAtIndexes:(NSArray<NSNumber *> *)indexes
                                                toPath:(NSString *)destinationPath
                                              pathMode:(SZExtractPathMode)pathMode
                                         overwriteMode:(SZOverwriteMode)overwriteMode
                                              testMode:(BOOL)testMode
                                              zoneMode:(SZZoneIDMode)zoneMode
                                        zoneSourcePath:(NSString *)zoneSourcePath
                                              progress:(id<SZProgressDelegate>)progress
                                                 error:(NSError **)error
{
    CMyComPtr<IArchiveFolder> archiveFolder;
    self.rawFolder->QueryInterface(IID_IArchiveFolder, (void **)&archiveFolder);
    if (!archiveFolder)
    {
        if (error)
            *error = SZUnsupportedOperationError(@"IArchiveFolder::Extract", self);
        return nil;
    }

    SZOperationSummary *summary = [[SZOperationSummary alloc] init];
    NSString *dest = SZDirPathWithSeparator(destinationPath);
    NSString *message = nil;
    const HRESULT hr = SZRunCatching(&message, [&]() -> HRESULT {
        CMyComPtr2<IFolderArchiveExtractCallback, CSZExtractCallbackAdapter> cb;
        cb.Create_if_Empty();
        cb->Delegate = progress;
        cb->ArchivePath = self.fullPath;
        cb->TestMode = testMode != NO;
        cb->OverwriteMode = (NExtract::NOverwriteMode::EEnum)overwriteMode;
        if ([progress respondsToSelector:@selector(progressSetStatus:)])
            [progress progressSetStatus:testMode ? SZProgressStatusTesting : SZProgressStatusExtracting];
        if ([progress respondsToSelector:@selector(progressSetTitleFileName:)])
            [progress progressSetTitleFileName:self.fullPath];

        // CPanel::CopyTo: no zone in test mode (PanelCopy.cpp:188).
        RINOK(SZSetFolderZone(archiveFolder, testMode ? SZZoneIDModeNone : zoneMode, zoneSourcePath))
        CRecordVector<UInt32> indices;
        SZIndexVector(indexes, indices);
        if (indices.IsEmpty())
        {
            const NSInteger count = self.itemCount;
            for (NSInteger i = 0; i < count; i++)
                indices.Add((UInt32)i);
        }
        // IArchiveFolder::Extract has no SetNumFiles; a total is only meaningful when the
        // selection contains no directories (their contents are counted too).
        if ([progress respondsToSelector:@selector(progressSetTotalFiles:)])
        {
            bool anyDir = false;
            FOR_VECTOR (i, indices)
                if ([self isDirectoryAtIndex:(NSInteger)indices[i]])
                {
                    anyDir = true;
                    break;
                }
            if (!anyDir)
                [progress progressSetTotalFiles:(uint64_t)indices.Size()];
        }

        const HRESULT res = archiveFolder->Extract(indices.ConstData(), indices.Size(),
            BoolToInt(false), 0,
            (NExtract::NPathMode::EEnum)pathMode,
            (NExtract::NOverwriteMode::EEnum)overwriteMode,
            SZUStringFromNSString(dest).Ptr(),
            BoolToInt(testMode != NO),
            cb.Interface());

        summary->_filesProcessed = cb->NumFilesProcessed;
        summary->_errorCount = cb->NumErrors;
        summary->_firstFailure = (SZOperationResult)cb->FirstBadOpRes;
        summary->_passwordWasAsked = cb->PasswordWasAsked ? YES : NO;
        return res;
    });

    if (hr == S_OK)
        return summary;
    if (error)
    {
        if (hr == E_NOTIMPL)
            *error = SZUnsupportedOperationError(@"IArchiveFolder::Extract", self);
        else if (summary.firstFailure == SZOperationResultWrongPassword && hr != (HRESULT)E_ABORT)
            *error = [SZErrors errorWithCode:SZErrorCodeWrongPassword
                                     message:[SZLang.shared stringForID:3729 fallback:@"Wrong password"]];
        else
            *error = [SZErrors errorWithHRESULT:(uint32_t)hr message:message];
    }
    return nil;
}

@end

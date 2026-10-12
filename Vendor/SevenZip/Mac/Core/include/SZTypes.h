// SZTypes.h -- plain C enums shared by the SevenZipKit bridge and Swift.
// SZPropID mirrors the engine's PROPID enum in CPP/7zip/PropID.h one-to-one
// (checked with static_assert in SZFolder.mm). Property names for columns are
// lang IDs 1000 + propID (01-fm-feature-inventory.md section 7.2).

#ifndef SZ_TYPES_H
#define SZ_TYPES_H

#import <Foundation/Foundation.h>

/// Engine property IDs (PROPID). Values are identical to CPP/7zip/PropID.h.
typedef NS_ENUM(uint32_t, SZPropID) {
    SZPropIDNoProperty NS_SWIFT_NAME(noProperty) = 0,
    SZPropIDMainSubfile NS_SWIFT_NAME(mainSubfile),
    SZPropIDHandlerItemIndex NS_SWIFT_NAME(handlerItemIndex),
    SZPropIDPath NS_SWIFT_NAME(path),
    SZPropIDName NS_SWIFT_NAME(name),
    SZPropIDExtension NS_SWIFT_NAME(extension),
    SZPropIDIsDir NS_SWIFT_NAME(isDir),
    SZPropIDSize NS_SWIFT_NAME(size),
    SZPropIDPackSize NS_SWIFT_NAME(packSize),
    SZPropIDAttrib NS_SWIFT_NAME(attrib),
    SZPropIDCTime NS_SWIFT_NAME(ctime),
    SZPropIDATime NS_SWIFT_NAME(atime),
    SZPropIDMTime NS_SWIFT_NAME(mtime),
    SZPropIDSolid NS_SWIFT_NAME(solid),
    SZPropIDCommented NS_SWIFT_NAME(commented),
    SZPropIDEncrypted NS_SWIFT_NAME(encrypted),
    SZPropIDSplitBefore NS_SWIFT_NAME(splitBefore),
    SZPropIDSplitAfter NS_SWIFT_NAME(splitAfter),
    SZPropIDDictionarySize NS_SWIFT_NAME(dictionarySize),
    SZPropIDCRC NS_SWIFT_NAME(crc),
    SZPropIDType NS_SWIFT_NAME(type),
    SZPropIDIsAnti NS_SWIFT_NAME(isAnti),
    SZPropIDMethod NS_SWIFT_NAME(method),
    SZPropIDHostOS NS_SWIFT_NAME(hostOS),
    SZPropIDFileSystem NS_SWIFT_NAME(fileSystem),
    SZPropIDUser NS_SWIFT_NAME(user),
    SZPropIDGroup NS_SWIFT_NAME(group),
    SZPropIDBlock NS_SWIFT_NAME(block),
    SZPropIDComment NS_SWIFT_NAME(comment),
    SZPropIDPosition NS_SWIFT_NAME(position),
    SZPropIDPrefix NS_SWIFT_NAME(prefix),
    SZPropIDNumSubDirs NS_SWIFT_NAME(numSubDirs),
    SZPropIDNumSubFiles NS_SWIFT_NAME(numSubFiles),
    SZPropIDUnpackVer NS_SWIFT_NAME(unpackVer),
    SZPropIDVolume NS_SWIFT_NAME(volume),
    SZPropIDIsVolume NS_SWIFT_NAME(isVolume),
    SZPropIDOffset NS_SWIFT_NAME(offset),
    SZPropIDLinks NS_SWIFT_NAME(links),
    SZPropIDNumBlocks NS_SWIFT_NAME(numBlocks),
    SZPropIDNumVolumes NS_SWIFT_NAME(numVolumes),
    SZPropIDTimeType NS_SWIFT_NAME(timeType),
    SZPropIDBit64 NS_SWIFT_NAME(bit64),
    SZPropIDBigEndian NS_SWIFT_NAME(bigEndian),
    SZPropIDCpu NS_SWIFT_NAME(cpu),
    SZPropIDPhySize NS_SWIFT_NAME(phySize),
    SZPropIDHeadersSize NS_SWIFT_NAME(headersSize),
    SZPropIDChecksum NS_SWIFT_NAME(checksum),
    SZPropIDCharacts NS_SWIFT_NAME(characts),
    SZPropIDVa NS_SWIFT_NAME(va),
    SZPropIDId NS_SWIFT_NAME(id),
    SZPropIDShortName NS_SWIFT_NAME(shortName),
    SZPropIDCreatorApp NS_SWIFT_NAME(creatorApp),
    SZPropIDSectorSize NS_SWIFT_NAME(sectorSize),
    SZPropIDPosixAttrib NS_SWIFT_NAME(posixAttrib),
    SZPropIDSymLink NS_SWIFT_NAME(symLink),
    SZPropIDError NS_SWIFT_NAME(error),
    SZPropIDTotalSize NS_SWIFT_NAME(totalSize),
    SZPropIDFreeSpace NS_SWIFT_NAME(freeSpace),
    SZPropIDClusterSize NS_SWIFT_NAME(clusterSize),
    SZPropIDVolumeName NS_SWIFT_NAME(volumeName),
    SZPropIDLocalName NS_SWIFT_NAME(localName),
    SZPropIDProvider NS_SWIFT_NAME(provider),
    SZPropIDNtSecure NS_SWIFT_NAME(ntSecure),
    SZPropIDIsAltStream NS_SWIFT_NAME(isAltStream),
    SZPropIDIsAux NS_SWIFT_NAME(isAux),
    SZPropIDIsDeleted NS_SWIFT_NAME(isDeleted),
    SZPropIDIsTree NS_SWIFT_NAME(isTree),
    SZPropIDSha1 NS_SWIFT_NAME(sha1),
    SZPropIDSha256 NS_SWIFT_NAME(sha256),
    SZPropIDErrorType NS_SWIFT_NAME(errorType),
    SZPropIDNumErrors NS_SWIFT_NAME(numErrors),
    SZPropIDErrorFlags NS_SWIFT_NAME(errorFlags),
    SZPropIDWarningFlags NS_SWIFT_NAME(warningFlags),
    SZPropIDWarning NS_SWIFT_NAME(warning),
    SZPropIDNumStreams NS_SWIFT_NAME(numStreams),
    SZPropIDNumAltStreams NS_SWIFT_NAME(numAltStreams),
    SZPropIDAltStreamsSize NS_SWIFT_NAME(altStreamsSize),
    SZPropIDVirtualSize NS_SWIFT_NAME(virtualSize),
    SZPropIDUnpackSize NS_SWIFT_NAME(unpackSize),
    SZPropIDTotalPhySize NS_SWIFT_NAME(totalPhySize),
    SZPropIDVolumeIndex NS_SWIFT_NAME(volumeIndex),
    SZPropIDSubType NS_SWIFT_NAME(subType),
    SZPropIDShortComment NS_SWIFT_NAME(shortComment),
    SZPropIDCodePage NS_SWIFT_NAME(codePage),
    SZPropIDIsNotArcType NS_SWIFT_NAME(isNotArcType),
    SZPropIDPhySizeCantBeDetected NS_SWIFT_NAME(phySizeCantBeDetected),
    SZPropIDZerosTailIsAllowed NS_SWIFT_NAME(zerosTailIsAllowed),
    SZPropIDTailSize NS_SWIFT_NAME(tailSize),
    SZPropIDEmbeddedStubSize NS_SWIFT_NAME(embeddedStubSize),
    SZPropIDNtReparse NS_SWIFT_NAME(ntReparse),
    SZPropIDHardLink NS_SWIFT_NAME(hardLink),
    SZPropIDINode NS_SWIFT_NAME(inode),
    SZPropIDStreamId NS_SWIFT_NAME(streamId),
    SZPropIDReadOnly NS_SWIFT_NAME(readOnly),
    SZPropIDOutName NS_SWIFT_NAME(outName),
    SZPropIDCopyLink NS_SWIFT_NAME(copyLink),
    SZPropIDArcFileName NS_SWIFT_NAME(arcFileName),
    SZPropIDIsHash NS_SWIFT_NAME(isHash),
    SZPropIDChangeTime NS_SWIFT_NAME(changeTime),
    SZPropIDUserId NS_SWIFT_NAME(userId),
    SZPropIDGroupId NS_SWIFT_NAME(groupId),
    SZPropIDDeviceMajor NS_SWIFT_NAME(deviceMajor),
    SZPropIDDeviceMinor NS_SWIFT_NAME(deviceMinor),
    SZPropIDDevMajor NS_SWIFT_NAME(devMajor),
    SZPropIDDevMinor NS_SWIFT_NAME(devMinor),
    SZPropIDNumDefined NS_SWIFT_NAME(numDefined),
    SZPropIDUserDefined NS_SWIFT_NAME(userDefined) = 0x10000
};

/// VARTYPE of a property value (subset used by 7-Zip).
typedef NS_ENUM(uint16_t, SZVarType) {
    SZVarTypeEmpty = 0,
    SZVarTypeI2 = 2,
    SZVarTypeI4 = 3,
    SZVarTypeBSTR = 8,
    SZVarTypeBool = 11,
    SZVarTypeUI1 = 17,
    SZVarTypeUI2 = 18,
    SZVarTypeUI4 = 19,
    SZVarTypeI8 = 20,
    SZVarTypeUI8 = 21,
    SZVarTypeFileTime = 64
};

/// Timestamp display precision (Windows/PropVariantConv.h kTimestampPrintLevel_*).
typedef NS_ENUM(NSInteger, SZTimestampLevel) {
    SZTimestampLevelDay = -3,
    SZTimestampLevelMin = -1,      ///< 7zFM default
    SZTimestampLevelSec = 0,
    SZTimestampLevelNTFS = 7,
    SZTimestampLevelNS = 9
};

/// NExtract::NPathMode (UI/Common/ExtractMode.h).
typedef NS_ENUM(NSInteger, SZExtractPathMode) {
    SZExtractPathModeFullPaths = 0,
    SZExtractPathModeCurPaths,
    SZExtractPathModeNoPaths,
    SZExtractPathModeAbsPaths,
    SZExtractPathModeNoPathsAlt
};

/// NExtract::NOverwriteMode.
typedef NS_ENUM(NSInteger, SZOverwriteMode) {
    SZOverwriteModeAsk = 0,
    SZOverwriteModeOverwrite,
    SZOverwriteModeSkip,
    SZOverwriteModeRename,
    SZOverwriteModeRenameExisting
};

/// NOverwriteAnswer (UI/Common/IFileExtractCallback.h).
typedef NS_ENUM(NSInteger, SZOverwriteAnswer) {
    SZOverwriteAnswerYes = 0,
    SZOverwriteAnswerYesToAll,
    SZOverwriteAnswerNo,
    SZOverwriteAnswerNoToAll,
    SZOverwriteAnswerAutoRename,
    SZOverwriteAnswerCancel
};

/// NArchive::NExtract::NOperationResult (Archive/IArchive.h); per-item results.
typedef NS_ENUM(NSInteger, SZOperationResult) {
    SZOperationResultOK = 0,
    SZOperationResultUnsupportedMethod,
    SZOperationResultDataError,
    SZOperationResultCRCError,
    SZOperationResultUnavailable,
    SZOperationResultUnexpectedEnd,
    SZOperationResultDataAfterEnd,
    SZOperationResultIsNotArc,
    SZOperationResultHeadersError,
    SZOperationResultWrongPassword
};

/// NArchive::NExtract::NAskMode (what PrepareOperation announces).
typedef NS_ENUM(NSInteger, SZAskMode) {
    SZAskModeExtract = 0,
    SZAskModeTest,
    SZAskModeSkip,
    SZAskModeReadExternal
};

#endif

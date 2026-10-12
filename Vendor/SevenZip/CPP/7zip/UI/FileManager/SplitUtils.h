// SplitUtils.h

#ifndef ZIP7_INC_SPLIT_UTILS_H
#define ZIP7_INC_SPLIT_UTILS_H

#include "../../../Common/MyTypes.h"
#include "../../../Common/MyString.h"

#ifdef _WIN32
#include "../../../Windows/Control/ComboBox.h"
#endif

bool ParseVolumeSizes(const UString &s, CRecordVector<UInt64> &values);
#ifdef _WIN32
void AddVolumeItems(NWindows::NControl::CComboBox &volumeCombo);
#endif
UInt64 GetNumberOfVolumes(UInt64 size, const CRecordVector<UInt64> &volSizes);

#endif

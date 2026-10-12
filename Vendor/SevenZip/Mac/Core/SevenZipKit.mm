// SevenZipKit.mm -- engine version strings.

#import "SevenZipKit.h"
#include "../../C/7zVersion.h"

NSString *SZEngineVersionString(void)
{
  return @MY_VERSION;
}

NSString *SZEngineCopyrightString(void)
{
  return @MY_COPYRIGHT_DATE;
}

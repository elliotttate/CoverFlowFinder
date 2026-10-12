// FSEventsWatcher.h -- "did anything change in this directory?" flag driven by FSEvents.
// The macOS replacement for FindFirstChangeNotification (01 section 3.17, section 9 #20):
// CFSFolderMac::WasChanged() polls it from the panel's refresh timer.
// Engine-free (no 7-Zip headers) so it can include CoreServices without typedef clashes.

#ifndef SZ_FSEVENTS_WATCHER_H
#define SZ_FSEVENTS_WATCHER_H

namespace NMacFolders {

class CFSEventsWatcher
{
  struct Impl;
  Impl *_impl;
public:
  // Starts watching `dirPath` (UTF-8, absolute). With recursive == false only events for the
  // directory itself are reported (what FindFirstChangeNotification does, and what the panel
  // needs); flat view passes recursive == true because it lists the whole subtree.
  CFSEventsWatcher(const char *dirPath, bool recursive);
  ~CFSEventsWatcher();
  bool IsActive() const;
  // True once per coalesced burst of changes; clears the flag.
  bool ConsumeChanged();
  // Sticky: the watched directory was deleted, renamed or moved (kFSEventStreamEventFlagRootChanged).
  // Never cleared, so the panel can navigate up at any later poll.
  bool RootChanged() const;
private:
  CFSEventsWatcher(const CFSEventsWatcher &);
  CFSEventsWatcher &operator=(const CFSEventsWatcher &);
};

}

#endif

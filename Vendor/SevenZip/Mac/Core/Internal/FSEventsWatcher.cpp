// FSEventsWatcher.cpp -- see FSEventsWatcher.h

#include "FSEventsWatcher.h"
#include "MacFileOps.h"

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>

#include <string.h>

#include <atomic>
#include <memory>
#include <string>

namespace NMacFolders {

// Shared with the running stream: the stream keeps its own reference through the context
// release callback, so a callback in flight is safe even after the owner is gone.
struct CWatchState
{
  std::atomic<bool> Changed;
  std::atomic<bool> RootChanged;
  bool Recursive;
  std::string Path;      // as given, no trailing '/' (except "/")
  std::string RealPath;  // realpath() of Path: FSEvents reports canonical paths
  CWatchState(): Changed(false), RootChanged(false), Recursive(false) {}
};

typedef std::shared_ptr<CWatchState> CStatePtr;

struct CFSEventsWatcher::Impl
{
  FSEventStreamRef stream;
  CStatePtr state;
  Impl(): stream(NULL) {}
};

static dispatch_queue_t WatcherQueue()
{
  static dispatch_queue_t q = dispatch_queue_create("com.yrambler2001.7zip.fsevents", DISPATCH_QUEUE_SERIAL);
  return q;
}

static std::string NormalizeDir(const char *p)
{
  std::string s(p ? p : "");
  while (s.size() > 1 && s[s.size() - 1] == '/')
    s.erase(s.size() - 1);
  return s;
}

// The stream owns one heap-allocated shared_ptr (context info), freed by the release callback
// when the stream is invalidated. No retain callback (FSEvents stores the original info
// pointer regardless of what a retain callback returns).
static void ReleaseState(const void *info)
{
  delete (const CStatePtr *)info;
}

static bool SameDir(const std::string &dir, const char *eventPath)
{
  if (dir.empty() || !eventPath)
    return false;
  size_t len = strlen(eventPath);
  while (len > 1 && eventPath[len - 1] == '/')
    len--;
  return len == dir.size() && memcmp(eventPath, dir.c_str(), len) == 0;
}

static void Callback(ConstFSEventStreamRef, void *info, size_t numEvents,
    void *eventPaths, const FSEventStreamEventFlags flags[], const FSEventStreamEventId[])
{
  CWatchState &st = **(CStatePtr *)info;
  const char * const *paths = (const char * const *)eventPaths;
  for (size_t i = 0; i < numEvents; i++)
  {
    const FSEventStreamEventFlags f = flags[i];
    if (f & kFSEventStreamEventFlagRootChanged)
    {
      // The watched directory itself was deleted, renamed or moved.
      st.RootChanged.store(true);
      st.Changed.store(true);
      continue;
    }
    if (f & (kFSEventStreamEventFlagMustScanSubDirs
           | kFSEventStreamEventFlagKernelDropped
           | kFSEventStreamEventFlagUserDropped
           | kFSEventStreamEventFlagMount
           | kFSEventStreamEventFlagUnmount))
    {
      st.Changed.store(true);
      continue;
    }
    if (st.Recursive)
    {
      st.Changed.store(true);
      continue;
    }
    // Without kFSEventStreamCreateFlagFileEvents there is one event per changed directory,
    // so "the current directory only" == the event path is our own directory
    // (FindFirstChangeNotification(bWatchSubtree = false) semantics, 01 section 6.4).
    const char *p = paths[i];
    if (SameDir(st.Path, p) || SameDir(st.RealPath, p))
      st.Changed.store(true);
  }
}

CFSEventsWatcher::CFSEventsWatcher(const char *dirPath, bool recursive): _impl(new Impl)
{
  _impl->state = CStatePtr(new CWatchState);
  CWatchState &st = *_impl->state;
  st.Recursive = recursive;
  st.Path = NormalizeDir(dirPath);
  if (!NMacFileOps::RealPath(st.Path.c_str(), st.RealPath))
    st.RealPath = st.Path;
  else
    st.RealPath = NormalizeDir(st.RealPath.c_str());

  CFStringRef cfPath = CFStringCreateWithCString(kCFAllocatorDefault, st.Path.c_str(), kCFStringEncodingUTF8);
  if (!cfPath)
    return;
  const void *paths[1] = { cfPath };
  CFArrayRef pathArray = CFArrayCreate(kCFAllocatorDefault, paths, 1, &kCFTypeArrayCallBacks);
  CFRelease(cfPath);
  if (!pathArray)
    return;

  CStatePtr *ctxInfo = new CStatePtr(_impl->state);
  FSEventStreamContext ctx;
  ctx.version = 0;
  ctx.info = ctxInfo;
  ctx.retain = NULL;
  ctx.release = ReleaseState;
  ctx.copyDescription = NULL;

  // Latency 0.5 s coalesces bursts into one flag (the panel polls once per second);
  // WatchRoot reports deletion / renaming of the watched directory itself.
  FSEventStreamRef stream = FSEventStreamCreate(kCFAllocatorDefault, Callback, &ctx,
      pathArray, kFSEventStreamEventIdSinceNow, 0.5,
      kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot);
  CFRelease(pathArray);
  if (!stream)
  {
    delete ctxInfo;
    return;
  }
  FSEventStreamSetDispatchQueue(stream, WatcherQueue());
  if (!FSEventStreamStart(stream))
  {
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    return;
  }
  _impl->stream = stream;
}

CFSEventsWatcher::~CFSEventsWatcher()
{
  if (_impl->stream)
  {
    // Tear down on the callback queue itself so that no callback can be running while the
    // context info is released (the destructor never runs on that queue).
    FSEventStreamRef stream = _impl->stream;
    dispatch_sync(WatcherQueue(), ^{
      FSEventStreamStop(stream);
      FSEventStreamInvalidate(stream);
      FSEventStreamRelease(stream);
    });
  }
  delete _impl;
}

bool CFSEventsWatcher::IsActive() const
{
  return _impl->stream != NULL;
}

bool CFSEventsWatcher::ConsumeChanged()
{
  return _impl->state->Changed.exchange(false);
}

bool CFSEventsWatcher::RootChanged() const
{
  return _impl->state->RootChanged.load();
}

}

// satori C interop — single source of truth for every C struct layout.
//
// WHY THIS FILE EXISTS
// --------------------
// Struct layouts are never hand-written in Zig. Hand-written `extern struct`
// declarations produce *silently wrong data* rather than compile errors: two of
// two attempts were wrong during prototyping (struct statfs, and
// vm_statistics64_data_t). test/layout.zig pins every layout against
// clang-measured ground truth so that class of bug cannot survive.
//
// Regenerate (see plan §6 — output is COMMITTED, never fetched at build time):
//     zig translate-c src/c.h -lc -target <triple> > src/c.zig
//
// CI regenerates per target and diffs. A mismatch fails the build.

#pragma once

// --- Always available -------------------------------------------------------
#include <fcntl.h>     // open, O_RDONLY
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h> // getenv
#include <string.h> // memchr
#include <time.h>   // clock_gettime
#include <unistd.h> // gethostname, sysconf, read, close
#include <sys/utsname.h>

// --- macOS ------------------------------------------------------------------
#ifdef __APPLE__
#include <sys/sysctl.h>       // sysctlbyname
#include <sys/mount.h>        // getmntinfo, struct statfs
#include <sys/param.h>        // MAXPATHLEN
#include <mach/vm_statistics.h> // vm_statistics64_data_t
// NOTE: mach/mach.h is deliberately NOT included. translate-c fails on it
// (asserts mach_msg_type_descriptor_t is 12 bytes; the type is opaque {}).
// The three functions we need from it are declared in src/platform/macos.zig —
// they take and return integers, so a hand-written signature cannot be subtly
// wrong the way a struct layout can.
#endif

// --- Linux ------------------------------------------------------------------
#ifdef __linux__
#include <sys/statvfs.h>  // statvfs, struct statvfs
#include <sys/sysinfo.h>  // sysinfo, struct sysinfo
#include <dirent.h>       // opendir/readdir
#endif
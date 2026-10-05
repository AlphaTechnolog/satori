/* satori layout ground truth — measured by the platform C compiler, not written
 * by hand.
 *
 * WHY THIS FILE HAS TO EXIST
 * --------------------------
 * A hand-written `extern struct` with the wrong layout compiles cleanly and
 * returns garbage. It is not a crash; it is a plausible wrong number on screen.
 * Two of two attempts were wrong during prototyping:
 *
 *   struct statfs          assumed 1,104 bytes with f_fsid last.
 *                          actually 2,168, with f_fsid@48, f_flags@64,
 *                          f_fstypename@72.
 *   vm_statistics64_data_t assumed 15 x u64.
 *                          actually 416 bytes and 57 named fields of mixed
 *                          width, so HOST_VM_INFO64_COUNT is 104 (416/4), not
 *                          15 and not 52.
 *
 * The second one returned KERN_INVALID_ARGUMENT and went unnoticed for a day
 * because the return code was not checked. test/layout.zig exists to pin every
 * layout at comptime; THIS file is where those pinned numbers come from.
 *
 * The rule that makes it work: every number printed below comes from the
 * platform C compiler's own `sizeof` and `offsetof`. Nothing here is inferred,
 * carried over from another target, or typed in from a header. If you cannot
 * measure it, do not assert it.
 *
 * HOW TO RUN
 * ----------
 *   cc -O2 tools/gt.c -o gt && ./gt
 *
 * That is the exact command test/layout.zig names. The output is the switch
 * arm body for the host it was compiled on: copy the `.macos => { ... }` or the
 * `.linux => { ... }` block into the corresponding branch of the switch in
 * test/layout.zig.
 *
 * Then run `zig build check`. That is the other half of the proof: this program
 * says what the *system* headers say, and the test asserts that the *translated*
 * declarations in src/c.zig (@sizeOf / @offsetOf) agree. The two agree only if
 * the Zig-side struct is a faithful translation of the C one, which is the
 * actual thing being tested. If a libc ever changes a layout, one of the two
 * sides fails loudly instead of the program printing a wrong number.
 *
 * PER TARGET, NOT PER OS
 * ---------------------
 * Ground truth in test/layout.zig is per target, and its `else` branch is a
 * @compileError, so adding a struct means adding truth for BOTH macOS and Linux.
 * This file is therefore split by target: the shared structs are unconditional,
 * and the platform-specific ones are behind the same `#ifdef` guards src/c.h
 * uses. Running it on one platform prints that platform's arm only — which is
 * correct, not incomplete. Run it on the other platform too.
 *
 * Note the two arms are genuinely different shapes, not the same struct with
 * different numbers. `struct utsname` is 5 x 256 bytes on Darwin (1,280 total)
 * and 6 x 65 on glibc (390 total, with a __domainname field macOS does not
 * have). That difference is the clearest argument in the project against ever
 * hand-writing a cross-platform struct.
 *
 * ADDING A STRUCT
 * ---------------
 * In this order, always:
 *   1. add the #include to src/c.h, which is the source of truth;
 *   2. add the assertions below, in the guard for that platform;
 *   3. measure with `cc -O2 tools/gt.c -o gt && ./gt` on EACH platform;
 *   4. paste into test/layout.zig, both arms;
 *   5. `zig build check` on macOS, on Linux, and in CI.
 *
 * Skipping step 1 breaks the property this file relies on: it includes
 * ../src/c.h, so it can only ever see exactly the headers the bindings were
 * translated from. A struct measured from a header src/c.h does not include is
 * ground truth for a struct satori does not have.
 *
 * COVERAGE IS DELIBERATE AND COMPLETE
 * ----------------------------------
 * Every declared field of every struct is printed, not a hand-picked subset.
 * The judgement call about which fields "matter" is exactly the judgement call
 * that produced both silent failures above; printing all of them costs nothing
 * and means the next struct cannot inherit an omission. (For
 * vm_statistics64_data_t that is 57 lines, and the gaps between them are the
 * interesting part: the offsets are not a uniform stride, so neither the field
 * count nor the size can be computed from the other.)
 *
 * Printing more than test/layout.zig asserts is intentional. The tool is the
 * measurement; the test is a chosen subset of what the program depends on. When
 * a struct is added, paste all of it here first, then decide what to assert.
 *
 * NOT PART OF ANY GATE, DELIBERATELY
 * ----------------------------------
 * Nothing in `zig build` compiles this, and `zig build check` does not run it:
 * it is a maintainer tool, like tools/regen-c.sh. Making it a gate would tie
 * every push to whatever `cc` and libc version the CI runner image happens to
 * ship, which is a different measurement from the pinned Zig toolchain the rest
 * of the suite is verified against. The procedure above is the gate: paste,
 * commit, then let both sides prove each other on every host.
 */

#include <stddef.h> /* offsetof */
#include <stdio.h>  /* printf */

/* src/c.h is the source of truth for the C surface; see the header comment
 * above for why this include is the whole point of the file. Relative to this
 * file's own directory, so the command works from the repo root. */
#include "../src/c.h"

/* One line per assertion, in exactly the form test/layout.zig uses, so the
 * output pastes without editing.
 *
 * The Zig type name is passed explicitly rather than derived from the C name.
 * `translate-c` renames things (`struct utsname` -> `struct_utsname`, and
 * `vm_statistics64_data_t` is a typedef of `struct vm_statistics64`), and a
 * derived rule would be a rule that can be wrong — the same failure mode as a
 * derived layout, only smaller. Typed in, it is checked by the compiler. */
#define GT_SIZE(c_type, zig_name, label) \
    printf("            expectSize(c.%s, %zu, \"%s\");\n", #zig_name, sizeof(c_type), label)

#define GT_OFF(zig_name, c_type, field) \
    printf("            expectOffset(c.%s, \"%s\", %zu);\n", #zig_name, #field, offsetof(c_type, field))

/* For the one field whose C name and translated name differ.
 *
 * glibc's struct sysinfo ends in a flexible array member named `_f`, and
 * translate-c renames it `__f` in the generated Zig because it wants that name
 * for the accessor method it synthesises alongside the field. So the C compiler
 * and the Zig declaration genuinely disagree on the name while agreeing
 * perfectly on the layout — worth pinning explicitly rather than papering over,
 * because the two-field form cannot silently accept a mismatch the way a
 * one-field derivation would. */
#define GT_OFF_RENAMED(zig_name, zfield, c_type, cfield) \
    printf("            expectOffset(c.%s, \"%s\", %zu);\n", #zig_name, #zfield, offsetof(c_type, cfield))

/* ---- target identification, printed into the output -------------------------
 *
 * Ground truth is per target, and "macOS" is not a target: aarch64 and x86_64
 * differ (the pointers inside struct statfs change width, so the offsets after
 * f_fsid all move). Anyone pasting an arm needs to know which one they measured,
 * and __VERSION__ puts the compiler that measured it in the file too. */
static const char *target_name(void) {
#if defined(__APPLE__) && defined(__aarch64__)
    return "macOS arm64 (Darwin)";
#elif defined(__APPLE__) && defined(__x86_64__)
    return "macOS x86_64 (Darwin)";
#elif defined(__linux__) && defined(__aarch64__)
    return "Linux aarch64";
#elif defined(__linux__) && defined(__x86_64__)
    return "Linux x86_64";
#else
    return "unknown";
#endif
}

int main(void) {
#if !defined(__APPLE__) && !defined(__linux__)
    /* Emitting an empty arm would paste an empty branch over a working one and
     * look like a successful measurement. Fail instead — the same reasoning as
     * regen-c.sh refusing to accept an empty translation. */
    fprintf(stderr,
            "FAIL: no ground truth for this platform. tools/gt.c covers the\n"
            "      targets src/c.h guards for (__APPLE__ / __linux__). Adding a\n"
            "      new one means adding an arm to test/layout.zig too, or its\n"
            "      `else` branch @compileErrors.\n");
    return 1;
#else
    printf("// Layout ground truth, measured by tools/gt.c -- do not hand-edit.\n");
    printf("//   target:    %s\n", target_name());
    printf("//   compiler:  %s\n",
#if defined(__clang__)
           "clang " __clang_version__
#elif defined(__GNUC__)
           "gcc " __VERSION__
#else
           "unknown"
#endif
    );
    printf("//\n");
    printf("// Paste into the matching branch of the switch in test/layout.zig.\n");
    printf("// Every number below is this compiler's own sizeof/offsetof.\n");

    /* ---- both platforms ------------------------------------------------- */
#if defined(__APPLE__)
    printf("\n        .macos => {\n");
#elif defined(__linux__)
    printf("\n        .linux => {\n");
#endif

    printf("\n            // <sys/utsname.h>. Darwin: 5 fields of 256 bytes. glibc: 6\n");
    printf("            // fields of 65, including a __domainname macOS does not have.\n");
    GT_SIZE(struct utsname, struct_utsname, "struct utsname");
    GT_OFF(struct_utsname, struct utsname, sysname);
    GT_OFF(struct_utsname, struct utsname, nodename);
    GT_OFF(struct_utsname, struct utsname, release);
    GT_OFF(struct_utsname, struct utsname, version);
    GT_OFF(struct_utsname, struct utsname, machine);
#ifdef __GLIBC__
    GT_OFF(struct_utsname, struct utsname, __domainname);
#endif

    printf("\n            // <time.h>. Also the premise behind posix.zig's musl\n");
    printf("            // fallback, which asserts sizeof(time_t) == sizeof(long);\n");
    printf("            // the time_t line below is how that premise gets checked.\n");
    GT_SIZE(struct timespec, struct_timespec, "struct timespec");
    GT_OFF(struct_timespec, struct timespec, tv_sec);
    GT_OFF(struct_timespec, struct timespec, tv_nsec);
    GT_SIZE(time_t, time_t, "time_t");
    GT_SIZE(clock_t, clock_t, "clock_t");

#ifdef __APPLE__
    /* ---- macOS ----------------------------------------------------------
     *
     * struct statfs is the one this project got wrong by hand: the fields are
     * NOT in declaration order in the header's own layout — f_fsid and f_flags
     * come before f_fstypename — so reading the declaration and adding up sizes
     * produces offsets that are wrong with no indication. That is why the whole
     * struct is printed rather than the fields satori happens to use. */
    printf("\n            // <sys/mount.h>. Offsets are NOT in declaration order; this\n");
    printf("            // struct is why layouts here are never written by hand.\n");
    GT_SIZE(struct statfs, struct_statfs, "struct statfs");
    GT_OFF(struct_statfs, struct statfs, f_bsize);
    GT_OFF(struct_statfs, struct statfs, f_iosize);
    GT_OFF(struct_statfs, struct statfs, f_blocks);
    GT_OFF(struct_statfs, struct statfs, f_bfree);
    GT_OFF(struct_statfs, struct statfs, f_bavail);
    GT_OFF(struct_statfs, struct statfs, f_files);
    GT_OFF(struct_statfs, struct statfs, f_ffree);
    GT_OFF(struct_statfs, struct statfs, f_fsid);
    GT_OFF(struct_statfs, struct statfs, f_owner);
    GT_OFF(struct_statfs, struct statfs, f_type);
    GT_OFF(struct_statfs, struct statfs, f_flags);
    GT_OFF(struct_statfs, struct statfs, f_fssubtype);
    GT_OFF(struct_statfs, struct statfs, f_fstypename);
    GT_OFF(struct_statfs, struct statfs, f_mntonname);
    GT_OFF(struct_statfs, struct statfs, f_mntfromname);
    GT_OFF(struct_statfs, struct statfs, f_flags_ext);
    GT_OFF(struct_statfs, struct statfs, f_reserved);
    GT_SIZE(fsid_t, fsid_t, "fsid_t");
    GT_SIZE(fsblkcnt_t, fsblkcnt_t, "fsblkcnt_t");
    GT_SIZE(fsfilcnt_t, fsfilcnt_t, "fsfilcnt_t");
    /* Not a layout, but the same class of assumption: a hardcoded buffer size in
     * macos.zig, where a silent change would truncate or over-read rather than
     * fail a build. */
    printf("\n            // <sys/param.h> MAXPATHLEN = %d\n", MAXPATHLEN);

    printf("\n            // <mach/vm_statistics.h>. 416 bytes and 57 named fields of MIXED\n");
    printf("            // width: the first five are natural_t (u32, 4-byte stride), the\n");
    printf("            // rest are 64-bit (8-byte stride), with reserved gaps at 20, 100\n");
    printf("            // and 148. So neither the size nor the field count can be derived\n");
    printf("            // from the other — which is how this struct was miscounted by hand.\n");
    printf("            //\n");
    printf("            // HOST_VM_INFO64_COUNT must be @sizeOf/@sizeOf(natural_t) == 104;\n");
    printf("            // a wrong value returns KERN_INVALID_ARGUMENT and renders as\n");
    printf("            // \"0 MiB used\" rather than crashing.\n");
    GT_SIZE(natural_t, natural_t, "natural_t");
    GT_SIZE(vm_statistics64_data_t, vm_statistics64_data_t, "vm_statistics64_data_t");
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, free_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, active_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, inactive_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, wire_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, zero_fill_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, reactivations);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, pageins);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, pageouts);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, faults);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, cow_faults);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, lookups);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, hits);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, purges);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, purgeable_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, speculative_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, decompressions);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, compressions);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, swapins);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, swapouts);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, compressor_page_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, throttled_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, external_page_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, internal_page_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, total_uncompressed_pages_in_compressor);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, swapped_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, total_tag_storage_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, nontag_pageable_tag_storage_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, nontag_wired_tag_storage_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, free_tag_storage_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, tag_storing_tag_storage_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, total_tagged_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, resident_tagged_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, compressed_tagged_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, tagged_compressions);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, tagged_decompressions);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, compressed_tag_storage_bytes);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, speculative_pages_created);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, speculative_pages_activated);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, swap_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, empty_tag_storing_tag_storage_pages);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, executable_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, shared_region_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, boot_stolen_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, secluded_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, active_internal_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, inactive_internal_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, active_external_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, inactive_external_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, purgeable_pageable_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, purgeable_wired_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, background_internal_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, background_external_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, donated_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, realtime_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, max_mem_count);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, phantom_ghosts_found);
    GT_OFF(vm_statistics64_data_t, vm_statistics64_data_t, phantom_ghosts_added);
#endif /* __APPLE__ */

#ifdef __linux__
    /* ---- Linux ---------------------------------------------------------- */
    printf("\n            // <sys/statvfs.h>\n");
    GT_SIZE(struct statvfs, struct_statvfs, "struct statvfs");
    GT_OFF(struct_statvfs, struct statvfs, f_bsize);
    GT_OFF(struct_statvfs, struct statvfs, f_frsize);
    GT_OFF(struct_statvfs, struct statvfs, f_blocks);
    GT_OFF(struct_statvfs, struct statvfs, f_bfree);
    GT_OFF(struct_statvfs, struct statvfs, f_bavail);
    GT_OFF(struct_statvfs, struct statvfs, f_files);
    GT_OFF(struct_statvfs, struct statvfs, f_ffree);
    GT_OFF(struct_statvfs, struct statvfs, f_favail);
    GT_OFF(struct_statvfs, struct statvfs, f_fsid);
    GT_OFF(struct_statvfs, struct statvfs, f_flag);
    GT_OFF(struct_statvfs, struct statvfs, f_namemax);
    GT_SIZE(fsblkcnt_t, fsblkcnt_t, "fsblkcnt_t");
    GT_SIZE(fsfilcnt_t, fsfilcnt_t, "fsfilcnt_t");

    printf("\n            // <sys/sysinfo.h>. `mem_unit` is the load-bearing field: it\n");
    printf("            // scales every byte count, and reading it without checking the\n");
    printf("            // return code is how a broken build renders as \"0 MiB used\".\n");
    GT_SIZE(struct sysinfo, struct_sysinfo, "struct sysinfo");
    GT_OFF(struct_sysinfo, struct sysinfo, uptime);
    GT_OFF(struct_sysinfo, struct sysinfo, loads);
    GT_OFF(struct_sysinfo, struct sysinfo, totalram);
    GT_OFF(struct_sysinfo, struct sysinfo, freeram);
    GT_OFF(struct_sysinfo, struct sysinfo, sharedram);
    GT_OFF(struct_sysinfo, struct sysinfo, bufferram);
    GT_OFF(struct_sysinfo, struct sysinfo, totalswap);
    GT_OFF(struct_sysinfo, struct sysinfo, freeswap);
    GT_OFF(struct_sysinfo, struct sysinfo, procs);
    GT_OFF(struct_sysinfo, struct sysinfo, pad);
    GT_OFF(struct_sysinfo, struct sysinfo, totalhigh);
    GT_OFF(struct_sysinfo, struct sysinfo, freehigh);
    GT_OFF(struct_sysinfo, struct sysinfo, mem_unit);
    // Renamed by translate-c: `_f` in C, `__f` in the bindings.
    GT_OFF_RENAMED(struct_sysinfo, __f, struct sysinfo, _f);

    printf("\n            // <dirent.h>. d_name is 256 here but only 32 on musl, and\n");
    printf("            // it is not NUL-terminated by the ABI -- another reason not to\n");
    printf("            // assume a size when reading a directory entry.\n");
    GT_SIZE(struct dirent, struct_dirent, "struct dirent");
    GT_OFF(struct_dirent, struct dirent, d_ino);
    GT_OFF(struct_dirent, struct dirent, d_off);
    GT_OFF(struct_dirent, struct dirent, d_reclen);
    GT_OFF(struct_dirent, struct dirent, d_type);
    GT_OFF(struct_dirent, struct dirent, d_name);
#endif /* __linux__ */

    printf("        },\n");
    printf("\n// Not asserted here: a raw ioctl request number such as TIOCGWINSZ is a\n");
    printf("// value rather than a layout, but it is just as platform-defined, and\n");
    printf("// reading one wrong over-reads the stack instead of failing. Measure it\n");
    printf("// against <termios.h> / <sys/ioctl.h> and add a Zig-side assertion when\n");
    printf("// struct winsize lands in src/c.h for Resolution.\n");
    return 0;
#endif
}
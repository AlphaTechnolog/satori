# satori — neofetch rewrite, zero-fork native implementation

Status: planning complete, ready to build. No code written yet.
Source of truth for scope: neofetch 7.1.0 at `/Users/alpha/repo/neofetch` (11,592-line bash script, archived upstream).
Reference implementation studied: cutefetch at `/Users/alpha/repo/cutefetch` (939 lines of C89, 4.96 ms).

## 1. Decisions locked

| decision | choice | rationale |
|---|---|---|
| Language | **Zig 0.17.0** | 1.98 ms median (vs 2.26 ms for 0.16). `@cImport` was removed in 0.17; use `zig translate-c` to generate a committed `src/c.zig` — see §5 and §6 |
| Config | **TOML subset**, no deps | ~20 µs hand-rolled parser; comments supported; Lua rejected (would add 2–4 ms + 2 MB) |
| Platforms | **Linux + macOS first** | exotic OSes (Solaris/AIX/IRIX/Haiku/FreeMiNT) cannot be tested here |
| Identity | **new name `satori`, new CLI** | not a drop-in `neofetch` replacement |
| Concurrency | **single-threaded** | measured: all data gathering < 0.3 ms, buried under 2 ms process startup. See §11 |

## 2. Goal / success criteria

Keep every user-visible neofetch feature. Target **median < 3 ms** end to end.

Measured baselines on the dev machine (macOS 26.6.2, arm64, best-of-N interleaved):

| binary | size | min | median |
|---|---|---|---|
| Zig, writes 1 byte | 53 KB | 2.05 ms | 2.30 ms |
| Zig, full zero-fork data gather | 53 KB | 1.85 ms | 2.03 ms |
| cutefetch | 52 KB | 4.58 ms | 4.96 ms |
| **neofetch** | 12 KB bash | **522 ms** | **600 ms** |

Non-goals:
- Not a drop-in `neofetch` replacement. Flags and output format are new.
- No Lua / embedded scripting. Custom user logic in config is dropped by design.
- No Windows/Cygwin, Solaris, AIX, IRIX, Haiku, FreeMiNT, iOS in v1.

## 3. Where neofetch's 522 ms goes (measured)

Per-field timing, `neofetch <field>`, macOS:

| field | total | net of 28 ms baseline |
|---|---|---|
| Host (`model`) | 234 ms | **~205 ms** — `kextstat \| grep` |
| Resolution | 208 ms | **~180 ms** — `system_profiler` |
| GPU | 198 ms | **~170 ms** — `system_profiler SPDisplaysDataType` |
| Packages | 65 ms | ~37 ms — `brew --cellar` ×2 |
| WM | 61 ms | ~33 ms — `ps -e \| grep` |
| Battery | 47 ms | ~19 ms — `pmset -g batt` ×2 |
| Memory | 41 ms | ~13 ms — `sysctl` ×3 + `vm_stat` ×2 |
| Local IP | 39 ms | ~11 ms |
| Disk | 34 ms | ~6 ms |
| everything else | ~30 ms | ~2–4 ms each |
| **bash parse of 11,592 lines** | **19 ms** | irreducible bash floor (`neofetch --version` = 26 ms) |

Raw costs of the individual culprits:

| command | cost |
|---|---|
| `kextstat \| grep` | 279 ms |
| `system_profiler SPDisplaysDataType` | 206 ms |
| `ps -e` | 32 ms |
| `brew --cellar` | 17 ms |
| `pmset -g batt` | 8 ms |
| `sw_vers` | 8 ms |
| `vm_stat` | 2 ms |
| `sysctl -n hw.model` | 2–3 ms |
| `date +%s`, `tty`, `who`, `id -un` | 2–3 ms each |

Structural causes in the bash source:
- `get_distro_ascii()` spans lines 5524–11540 — 6,017 lines, 52% of the file. bash must parse all 269 logos on every invocation. **19 ms.**
- `$(trim …)` is a command substitution subshell, called 40–60× per run.
- `exec 2>/dev/null` hides all missing-command noise, so failures are invisible.
- `prin=1` early-return protocol for multi-value fields (GPU, Disk, Battery, Local IP, Song).
- 3-tier config precedence where the config is **executable bash**, so `source`ing a user config re-parses arbitrary code.

**The rewrite's speed comes from deleting work, not from doing the same work faster.** ~250x improvement from removing ~300 forks, the 19 ms bash parse, and the three multi-hundred-millisecond `system_profiler`/`kextstat` calls.

## 4. Architecture

```
argv ─────► cli.zig ─────┐
                         ├─► config.zig ──► Config (immutable, on stack)
shared.zig ─────────────┤
                         ├──► modules/mod.zig ──► Module[] (comptime table of fn ptrs)
logos/ (comptime) ──────┘            │
                                      ▼
                                render.zig ──► Buf (16 KB stack buffer)
                                      │
                                      ▼
                              single write(2) at exit
```

Three layers, strictly separated, so the fast path cannot regress:

1. **`shared.zig`** — the cutefetch pattern, and the reason nothing is recomputed. `uname()`, boottime, page size, hostname, and an env snapshot are fetched **once** and passed by pointer to every module.
2. **modules** — one file per field, each `fn (*Shared, *Out) bool`. Returns false when it has nothing to say; never exits.
3. **render** — alignment, colours, bars, underline, colour blocks. Writes into one stack buffer.

Two invariants make the speed guarantee structural rather than aspirational:

- **Rule 1: a module may not fork.** No `posix_spawn`, no `system()`. Anything needing an external binary is either reimplemented against libc or moved behind an explicit opt-in flag.
- **Rule 2: one `write(2)` at the end.** No interleaving with subprocess pipes, no partial-line writes.

## 5. Zig 0.17 landmines (hit while prototyping — these are design constraints)

### C interop: generate, never hand-write

`@cImport` was deprecated in 0.16 and **removed in 0.17**. C translation moved to an external package with "an independent release cadence from the main Zig toolchain."

`zig translate-c <header.h>` still works as a standalone CLI with no package fetch. Strategy:

1. `src/c.h` — one header listing only the C headers satori needs.
2. `zig translate-c src/c.h -lc` → `src/c.zig`. **Commit the output.**
3. CI regenerates and fails if the result differs, so toolchain drift is caught without a network dependency at build time.

Keeps the zero-dependency property (matters for distro packaging and air-gapped CI) while getting struct layouts right.

### Why hand-written externs are forbidden

Attempted first; **2 of 2 structs were wrong, silently** — wrong layouts produce garbage, not compile errors:

| struct | assumed | actual (clang ground truth) |
|---|---|---|
| `struct statfs` | 1104 bytes, `f_fsid` last | **2168 bytes**; `f_fsid`@48, `f_fstypename`@72, `f_mntonname`@88, `f_flags`@64, `f_fssubtype`@68 |
| `vm_statistics64_data_t` | 15 × `u64` | **416 bytes = 52 × `natural_t` (u32)**; `HOST_VM_INFO64_COUNT` = 104 |

A wrong `HOST_VM_INFO64_COUNT` made `host_statistics64` return `KERN_INVALID_ARGUMENT` (`268435459`), unnoticed because the return code was not checked. **An earlier draft of this plan carried memory figures from that broken prototype; they were wrong.** Correct values now verified against `top`: `wired_count` × 16384 = 1970 MB vs `top`'s 1969M.

satori needs ~20 structs (`statfs`, `statvfs`, `utsname`, `kinfo_proc`, the `ifaddrs` chain, `dirent`, `utmpx`, `vm_statistics64`, X11 wire structs, per-OS variants). Hand-writing them is a silent-wrong-answer minefield.

**Layout assertions are mandatory.** `test/layout.zig` pins every struct's `@sizeOf` and critical `@offsetOf` against values measured from clang, at comptime. A negative control is included in CI so the assertions are known to fire. This is the check that would have caught both errors above, and it costs nothing at runtime.

**One permitted exception.** `@cInclude("mach/mach.h")` fails in translate-c (asserts `mach_msg_type_descriptor_t` is 12 bytes; the type is `opaque {}`), but `@cInclude("mach/vm_statistics.h")` **alone is fine**. So take `vm_statistics64_data_t` from generated `c.zig` and hand-declare only integer typedefs plus three functions:

```zig
const mach_port_t = u32;              // integer typedef — cannot be subtly wrong
const mach_msg_type_number_t = u32;   // integer typedef
extern fn mach_host_self() mach_port_t;
extern fn host_statistics64(h: mach_port_t, flavor: c_int, info: *anyopaque, count: *mach_msg_type_number_t) c_int;
extern fn host_page_size(h: mach_port_t, out: *usize) c_int;
```

`mach_host_self()` **must be called** — hardcoding the host port as `1` returns an error.

Hand-writing *signatures* is still useful where we own the declaration: `statvfs` takes `[*]const u8` rather than `[*:0]const u8`, avoiding sentinel-array friction.

### Language and stdlib gotchas

| gotcha | symptom | rule |
|---|---|---|
| `@cImport` removed in 0.17 | `invalid builtin function: '@cImport'` | use generated `src/c.zig` |
| `anytype` removed | `expected return type expression` | `inline fn zeroed(comptime T: type) T` |
| `std.io`, `std.fs.File` gone | stdlib mid-rework | **libc only**; `std` solely for `std.mem` / `std.fmt` |
| `std.fmt.bufPrint` return type changed in 0.17 | returns the written slice, not `.n` | `n += (std.fmt.bufPrint(buf[n..], …) catch …).len;` |
| `std.posix.write` removed | `no member named 'write'` | own `extern fn write` |
| `c_int`, `c_long`, `c_ulong` already exist | `name shadows primitive` | do not redefine them |
| capture shadows outer local | `capture 'u' shadows local variable` | distinct capture names |
| `@memcpy` on `.ptr` | `unknown copy length` | `@memcpy(dst_slice, src_slice)` |
| indexing a C array pointer | `type '*statfs' does not support indexing` | `const items: [*]const statfs = @ptrCast(p);` then `items[0]` |
| `&u.machine` over-reads | `utsname` fields are `[*:0]u8`; `&field` coerces to the whole struct | always `std.mem.sliceTo(&field, 0)` |
| `sysctlbyname` length **includes the NUL** | printed `26.6.2^@` | trim trailing `0` |
| method named `u64` | `name shadows primitive 'u64'` | name it `uint` |
| function params are `const` | `v /= 10` → `cannot assign to constant` | copy to a local `var` first |
| sentinel arrays for optional C strings | `expected '[*:0]const u8', found '[*]const u8'` | **design around C strings entirely** — see `buf.zig` |
| libc link | link error | build.zig sets `.link_libc = true` |

Verified reference build: `zig translate-c src/c.h -lc` then `zig build-exe -lc -OReleaseFast` (52 KB, 1.98 ms median).

## 6. Build & toolchain

`build.zig` emits a single binary. **Zero package dependencies** — `build.zig.zon` has an empty dependency set, and CI defends that.

```
zig build -Doptimize=ReleaseFast --summary none
```

Release profile: `ReleaseFast` + `strip`. Not `ReleaseSmall` — size is noise here and embedded data is already proven free (§9).

CI cross-compile matrix: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-linux-musl`, `aarch64-macos`, `x86_64-macos`.

### Pin the toolchain: 0.17.0 exactly

`zig` releases are point releases with no compatibility promise, and 0.16 → 0.17 already removed `@cImport` and changed `std.fmt.bufPrint`'s return type. satori pins `0.17.0` and CI fails on anything else, rather than tracking a moving target.

`src/c.zig` is regenerated per target (struct layouts differ per OS/arch), so cross-compilation regenerates it for each matrix entry. `mach/vm_statistics.h` is macOS-only and must be conditionally included in `src/c.h`.

### Generated `c.zig` is committed, not fetched

`@cImport` is gone and translate-c is now a separately-versioned external package. The chosen escape hatch:

```
src/c.h   --hand-written, ~40 @cInclude lines, the single source of truth
src/c.zig --generated, COMMITTED
```

```
zig translate-c src/c.h -lc -target <triple> > src/c.zig
```

Committing the output is what preserves the zero-dependency property — no network at build time, which matters for distro packaging and air-gapped CI. CI regenerates per target and diffs; a mismatch is a build failure, so toolchain drift is caught loudly instead of silently corrupting a struct layout.

## 7. Repo layout

```
satori/
  build.zig            build + cross-compile matrix
  build.zig.zon        (no dependencies)
  src/
    c.h                @cInclude list — the single source of truth for C interop
    c.zig              GENERATED by `zig translate-c src/c.h`, committed
    main.zig           entry: shared → config → modules → render → write
    shared.zig         uname, boottime, page size, hostname, env snapshot
    buf.zig            slice-based output buffer (no sentinels, no malloc)
    cli.zig            argv parser
    config.zig         TOML-subset parser (~400 lines, no deps)
    render.zig         alignment, colours, bars, underline, colour blocks
    fmt.zig            bytes / duration / percent formatters
    modules/
      mod.zig          Module interface + comptime registry
      os.zig host.zig kernel.zig uptime.zig packages.zig shell.zig
      term.zig termfont.zig cpu.zig gpu.zig memory.zig disk.zig
      battery.zig localip.zig users.zig locale.zig resolution.zig
      de.zig wm.zig theme.zig icons.zig font.zig song.zig publicip.zig
    platform/
      macos.zig        sysctlbyname, IOKit, statvfs, kinfo_proc + the 3 mach externs
      linux.zig        /proc, /sys, statvfs, getifaddrs, getutxent
      posix.zig        shared libc surface (signatures only — layouts come from c.zig)
    logos/
      gen.zig          comptime: parses logos/*.art → Logo{lines,width,height}
  logos/data/*.art     one file per distro (migrated from get_distro_ascii)
  tools/
    migrate_logos.py   one-shot: neofetch bash → logos/*.art
  test/
    golden/            expected output per field
    layout.zig          comptime struct layout assertions (see §16)
    bench.zig          startup + per-field timing
```

## 8. Data layer — macOS (zero forks)

Verified replacements. Every row below was measured on the dev machine.

| field | implementation | forks | neofetch cost |
|---|---|---|---|
| os | `sysctlbyname kern.osproductversion` + `uname().release/machine` | 0 | 30 ms |
| host | `sysctlbyname hw.model`; Hackintosh via IOKit `IOServiceMatching("AppleSMC")` | 0 | **234 ms** |
| kernel | `uname().release` | 0 | 30 ms |
| uptime | `sysctlbyname kern.boottime` + `clock_gettime(CLOCK_MONOTONIC)` | 0 | 34 ms |
| packages | `readdir` on `$HOMEBREW_PREFIX/Cellar` + `/Caskroom`; `/opt/local/var/macports/software` | 0 | 65 ms |
| shell | `$SHELL` basename; version read from the binary's embedded banner | 0 | 32 ms |
| resolution | IOKit framebuffer, or `CGDisplayPixelsWide/High` | 0 | **208 ms** |
| wm | `sysctl KERN_PROC_PID` walk over `kinfo_proc.kp_eproc.e_ppid` | 0 | 61 ms |
| term | same targeted ppid walk up the ancestor chain | 0 | 29 ms |
| termfont | read iTerm2 plist (needs a small **binary**-plist parser) | 0 | 29 ms |
| cpu | `sysctlbyname` ×4 (`machdep.cpu.brand_string`, `hw.logicalcpu`, `hw.physicalcpu`, `hw.cpufrequency`) | 0 | 33 ms |
| gpu | IOKit `IOServiceMatching("IOAccelerator")` → `model` | 0 | **198 ms** |
| memory | `host_statistics64(HOST_VM_INFO64)` + `hw.memsize` | 0 | 41 ms |
| title | `getenv("USER")` → `getpwuid` → `getlogin`; `gethostname` | 0 | — |
| disk | `getmntinfo(MNT_NOWAIT)` + `statvfs` | 0 | 34 ms |
| battery | IOKit power-source client | 0 | 47 ms |
| localip | `getifaddrs` | 0 | 39 ms |
| users | `getutxent` | 0 | 34 ms |
| locale | `$LANG` | 0 | 30 ms |

Measured IOKit prototype: `IOServiceMatching("IOAccelerator")` returns the GPU model string in **0.164–0.226 ms** vs 206 ms for `system_profiler`. **~1000x.**

### The `getpwuid` trap (cutefetch's biggest cost)

`getpwuid()` costs **1–3 ms** because it round-trips through `directoryd`. cutefetch calls it unconditionally — that is where most of its 4.96 ms goes.

Resolution order:
1. `getenv("USER")` — free, correct in an interactive shell.
2. `getpwuid(geteuid())` if `USER` is unset.
3. Cache uid→name at `$XDG_CACHE_HOME/satori/uidcache`, keyed on uid. Username-for-a-uid effectively never changes, so this is safe.

## 9. Data layer — Linux (zero forks)

| field | implementation | forks |
|---|---|---|
| os | `/etc/os-release`, `/usr/lib/os-release`, `/etc/*-release` — small `KEY=value` parser | 0 |
| host | `/sys/devices/virtual/dmi/id/{board_vendor,board_name}`, `/sys/firmware/devicetree/base/model` (NUL-trimmed) | 0 |
| uptime | `/proc/uptime` | 0 |
| packages | see §11 — `mmap` + `MADV_SEQUENTIAL` scan of `/var/lib/dpkg/status`; `readdir` for pacman/flatpak/snap; opt-in fork for rpm/nix | 0* |
| resolution | **hand-rolled X11 protocol** over `/tmp/.X11-unix/XN`: `QueryExtension RANDR` + `GetScreenResources` + `GetOutputInfo`. ~250 lines | 0 |
| de / wm | same socket: `_NET_SUPPORTING_WM_CHECK` + `_NET_WM_NAME`. Wayland: `$XDG_CURRENT_DESKTOP` + `stat` on known socket paths in `$XDG_RUNTIME_DIR`; fallback scan of `/proc/*/comm` | 0 |
| theme/icons/font | read `~/.config/gtk-3.0/settings.ini`, `~/.gtkrc-2.0`, `/etc/gtk-3.0/settings.ini` directly — **no `gsettings`**, which was 100–300 ms per call over D-Bus | 0 |
| term / termfont | `/proc/<pid>/stat` + `/proc/<pid>/comm` walk; then direct reads of `kitty.conf`, `alacritty.toml`, `konsolerc`, iTerm2 plist | 0 |
| cpu | `/proc/cpuinfo` **once**, `sysconf(_SC_NPROCESSORS_*)`, `/sys/class/hwmon/*/temp1_input` | 0 |
| gpu | `/sys/class/drm/*/device/{vendor,device}` + lookup in `/usr/share/hwdata/pci.ids`. **No `lspci`** (was ~200 ms) | 0 |
| memory | `/proc/meminfo` once | 0 |
| disk | `statvfs` | 0 |
| battery | `/sys/class/power_supply/*` via `readdir` | 0 |
| localip / users | `getifaddrs` / `getutxent` | 0 |

\* packages is the one field with opt-in forks; see §11.

**Embedded data is free.** Measured: a C binary with 512 KB of never-touched embedded string data starts in 1.89 ms, identical to a 33 KB one. Degradation only appears past ~1 MB. So all 269 logos can live in the binary at zero cost — but **total binary must stay under ~1 MB**, which is a release gate.

## 10. Logo system (269 logos, ~5,200 lines of art)

The largest single chunk of migration work and the easiest to get wrong.

**Storage:** one `.art` file per logo in `logos/data/`, `includeBytes`d at comptime. Replaces `get_distro_ascii()`'s 6,017-line bash `case`, which cost 19 ms of parse per run.

**Format** — header plus art, so colour and geometry are declarative instead of escaped into the text:

```
# name: Arch Linux
# match: "Arch Linux"*, "Arch"*
# colors: [blue, cyan, white, blue, white, blue]
# small:  false -`/ arch  |o+o |`
```

**Why not `${c1}` placeholders.** neofetch does six whole-string substitutions over the art at runtime plus a `while read` loop that byte-iterates every line just to compute width. At comptime that becomes a constant:

```zig
pub const Logo = struct {
    name: []const u8,
    matches: []const []const u8,
    colors: [6][]const u8,
    lines: []const Line,   // Line = []const Segment{ color: u3, text: []const u8 }
    width: u16,            // display cells, computed at comptime
    height: u16,
};
```

Width must be **display cells, not bytes**. neofetch uses `${#line}` under `LC_ALL=C` and strips `█` to a space as a workaround because that block char is 3 bytes there — so neofetch's alignment is already wrong for any logo with box-drawing or block characters. At comptime we decode UTF-8 properly and sum `char_width()`, which is strictly more correct than neofetch today.

**Matching:** longest-prefix glob on the normalised distro string, case-insensitive, first-match-wins, with `_small` / `_old` variants reachable only via explicit `--logo <name>`. Same semantics as neofetch's `case` + `nocasematch`, but the table is comptime-built instead of 6,000 lines of bash.

`tools/migrate_logos.py` does the one-shot extraction from `get_distro_ascii()`.

## 11. Performance techniques (measured, not speculative)

### Why single-threaded

Decisive measurement:

```
Zig: write 1 byte, nothing else     2.30 ms median
Zig: full zero-fork data gather     2.03 ms median
```

The binary that gathers everything is indistinguishable from the one that writes a single byte. **All data gathering costs less than the run-to-run noise (~0.3 ms).** The `-0.27 ms` delta is noise; the honest reading is "zero".

| quantity | value | share |
|---|---|---|
| process startup (exec + dyld + libc init) | ~2.0–2.3 ms | **~100%** |
| all data gathering combined | < 0.3 ms | ~0% |
| perfect 4-way parallelism would save | ~0.2 ms | ~8% |
| measured spawn+join cost, 4 threads | 0.048 ms | eats 25% of the gain |

Amdahl's law makes this structurally hopeless, not merely currently unhelpful. Even reducing data gathering to literally zero buys ~10%.

Memory is also not the binding constraint: thread stacks are virtual, ~4 KB resident each. The expensive half of the trade is nondeterminism and extra code paths needing tests.

**Rule: build single-threaded, and let `--benchmark` gate any future concurrency work.** If no field ever exceeds ~1 ms, we never write a thread.

### What actually helps — caching, batching, algorithms

| technique | measured effect | where |
|---|---|---|
| Targeted `KERN_PROC_PID` walk instead of `KERN_PROC_ALL` | 0.014–0.048 ms vs 0.266–0.365 ms — **10x** | macOS wm / term |
| Skip `getpwuid`, resolve `USER` from env | saves **1–3 ms** | macOS title |
| IOKit instead of `system_profiler` | 206 ms → 0.17 ms — **1000x** | macOS gpu / host |
| `mmap` + `MADV_SEQUENTIAL` | ~2x on large file scans | linux packages |
| mtime+size-keyed cache | 1–8 ms → ~5 µs | packages, gpu-from-pci.ids, shell version |
| Batched X11 requests (one `write()`, then one `read()`) | ~6 round-trips → 1–2 | linux resolution / wm |

The X11 case is the one place latency genuinely dominates, and **threads cannot help** because the replies are sequentially dependent on a single socket. Batching removes the latency instead.

### The `packages` field — the only genuinely expensive one

Realistic dpkg simulation (1600 packages, 1.6 MB `status`):

```
read from page cache      0.47–0.66 ms   (2.5–3.5 GB/s)
scan for "install ok"     0.44–0.58 ms   (2.9–3.8 GB/s)
                          ─────────────
sequential total          0.91–1.24 ms
on 1 worker thread        0.54–0.66 ms   (thread itself costs 0.09–0.12 ms)
```

Real systems have 5–15 MB status files → **3–8 ms**, which genuinely would dominate on Linux.

Plan, in priority order:
1. **`mmap` + `MADV_SEQUENTIAL`** + newline-anchored `memchr` scan. ~2x, no concurrency.
2. **mtime+size-keyed cache** at `$XDG_CACHE_HOME/satori/packages`. Validated by one `stat()` (~2 µs). Package counts don't change between runs, so caching beats parallelism by three orders of magnitude — it doesn't make the work faster, it makes it not happen.
3. Opt-in forks only for managers with no readable database: `rpm -qa`, `nix-store --query --requisites`, MacPorts' SQLite registry.

**Rejected alternative, measured:** `readdir`-counting `/var/lib/dpkg/info/` is **slower** — 1.7–2.3 ms for 1500 entries vs 1.0–1.2 ms to scan the file. The initial hypothesis was backwards; measuring avoided a pessimisation.

### The one justified thread

`--publicip` has a 2-second network timeout and `--song` does a D-Bus round-trip that can block. Those dwarf everything else, so when either is enabled, kick it off on a worker at startup so it overlaps everything else. That is exactly "spend memory for a flash second" and is the single trade worth making. Both are off by default, so the headline number is unaffected.

## 12. Config — TOML subset

No dependencies, so a hand-rolled parser for exactly the syntax we need. TOML over JSON because comments matter in a file users are expected to edit.

```toml
# ~/.config/satori/config.toml
info = ["title", "os", "host", "kernel", "uptime", "packages",
        "shell", "resolution", "de", "wm", "theme", "icons",
        "terminal", "terminal_font", "cpu", "gpu", "memory", "blocks"]

[logo]
kind = "auto"      # auto | distro | builtin | none | file
name = "auto"
gap  = 3

[colors]
label = "distro"   # or 0-7, or "R;G;B" / "#rrggbb"
value = "reset"
bold  = true

[display]
separator     = ":"
underline     = true
memory_unit   = "mib"    # kib | mib | gib
disk_show     = ["/"]
local_network = ["en0"]
```

Precedence: built-in defaults → user config → CLI flags. `--print-config` dumps resolved defaults as TOML; first run writes the file, matching neofetch's behaviour. `--no-config` skips it.

Parser scope: ~400 lines covering tables, strings, integers, booleans, string arrays, comments. Anything else is a clear error with a line number. ~20 µs, so effectively free.

## 13. CLI

```
satori                          # default profile
satori os cpu memory            # only these fields, in this order
satori --minimal                # os, kernel, shell, terminal
satori --logo                   # logo only
satori --logo off
satori --logo ubuntu            # force a specific logo
satori --logo ./mylogo.txt      # custom file
satori --plain                  # no colour, no logo, no cursor tricks (for pipes)
satori --json                   # machine-readable
satori --benchmark              # per-field wall time + total
satori --print-config           # dump default TOML
satori --no-config
satori --config path.toml
satori --version / --help
```

Positional arguments are fields, so `satori uptime` still works from muscle memory.

Two neofetch behaviours to keep, because they are correct:
- Hide cursor + disable line wrap (`\e[?25l\e[?7l`) with restore on exit.
- Emit enough trailing newlines that the shell prompt lands below the taller of logo and info (neofetch's `dynamic_prompt`).

`--benchmark` is a first-class feature, not a debug flag — it is the mechanism that gates any future concurrency work and it keeps the perf claim honest.

## 14. Code style

- **Zig 0.17.0, pinned exactly, libc only.** `std` imported solely for `std.mem` / `std.fmt` helpers. No `std.io`, no `std.fs`, no `std.heap` on the default path. Rationale: `anytype`, `std.io`, `std.fs.File`, `std.posix.write` and `@cImport` have all been removed or changed shape in recent releases.
- **No C strings, ever.** `Buf` is a slice-based writer. Any unavoidable `[*:0]` libc field is wrapped with `std.mem.sliceTo(&field, 0)`. This eliminates the off-by-one class of bugs and is why the prototype needed no `strdup`.
- **No allocation on the default path.** Every module writes into caller-provided stack buffers. An allocator exists only for config/JSON. `--benchmark` asserts zero allocations on the fast path.
- **Modules return `bool`, never exit.** `fn (*Shared, *Out) bool` — false means print nothing. neofetch dies on a missing source; we degrade.
- **Struct layouts come from generated `c.zig`, never from hand-written `extern struct`.** Hand-written *signatures* are fine and preferred where we own the declaration. See §5 — a wrong hand-written layout produces silently wrong output, not a compile error, and two of two attempts were wrong.
- **One `Buf` per layer**, passed down. No globals. Module registry is a comptime array of `{ name, fn, needs }`.
- **Naming:** `snake_case` functions/locals, `PascalCase` types, module files named after the field (`gpu.zig` exposes `pub fn get`).
- **CI gates:** `zig fmt --check`, zero compiler warnings, **startup-time regression test** failing the build if median exceeds 3.5 ms, and a binary-size gate at 1 MB. A perf claim nobody measures rots within a month.

## 15. Milestones

> **SUPERSEDED IN PART — see `satori-phase-2.md` (2026-10-05).** The ordering
> below is out of date: the renderer now comes *before* the remaining fields, and
> Linux parity before logos. M1's target is the **17** defaults `print_info`
> actually prints, not "20" as stated in row 1. The licence is settled as MIT
> with attribution to neofetch. Read `satori-phase-2.md` for the current
> sequence; this table is kept for the research and rationale behind it.

| # | milestone | done when |
|---|---|---|
| 0 | Skeleton: `build.zig`, `buf.zig`, `shared.zig`, bench harness | **DONE** — 5 targets build; 12 tests pass; gates run from `zig build check` |
| 1 | **macOS data layer** | all 20 default fields populated, **median < 3 ms**, zero forks verified |
| 2 | Renderer: colours, bars, colour blocks, alignment | output visually comparable to neofetch |
| 3 | Logo engine + `migrate_logos.py` + 269 logos migrated | `--logo <any distro>` renders with correct alignment |
| 4 | CLI + `--json` + `--plain` | flag surface frozen |
| 5 | **Linux parity** | full field set, zero forks, X11 resolution + WM working |
| 6 | TOML config + `--print-config` | config round-trips; first-run file creation |
| 7 | Opt-in paths: disk, battery, package edge cases, `song`, `publicip` | each behind a flag, off by default |
| 8 | Golden tests | PRs cannot regress field values |

### Milestone 0 results (measured, 2026-10-04)

Startup median, `zig build startup`, ReleaseFast, measured natively:

| platform | satori | neofetch | ratio |
|---|---|---|---|
| macOS arm64 | 1.58 ms | — | — |
| Linux x86_64 (Debian sid) | 0.71 ms | 138 ms | **194x** |

Data gathering is **17 µs** total (`zig build bench`): shared 11, sysctl 2,
host_statistics64 4. This settles the single-threaded question in §11 — a thread
would cost more to create than the work it could hide.

Binary size, stripped ReleaseFast, all under the 1 MB gate: aarch64-linux-gnu
13,624 · x86_64-linux-gnu 15,176 · x86_64-macos 29,814 · aarch64-macos 51,064 ·
x86_64-linux-musl 104,616 (static).

**Zero-fork is now proven structurally, not observed.** The shipped binary's
entire libc surface is 18 symbols and cannot fork. `tools/check-no-fork.sh`
checks the symbol table rather than tracing syscalls, because it proves absence
(no code path, no input, no environment), needs no root, and so runs on a stock
CI runner — `dtruss` requires root and cannot. §16's `dtruss` item is superseded.

### Changes to earlier sections, decided during milestone 0

- **§16 zero-fork check is now static, not traced.** As above.
- **§6 committed `c.zig` is native-target-only; the matrix generates its own.**
  `src/c.zig` is committed for the native target only. `zig build matrix` runs
  `tools/regen-c.sh --gen` per target into `zig-out/bindings/` and builds against
  that, because a committed file cannot be correct for five targets at once.
- **`translate-c` must be given `-target`.** Without it, translate-c resolves the
  native target and reads the *Xcode SDK* headers instead of Zig's bundled libc
  headers. The output is functionally identical but every embedded header path in
  a diagnostic comment changes, so the committed file stops being reproducible.
- **`zig fmt` is in-place and prints nothing in 0.17**; `--stdin` hangs on input
  of ~12k lines. Use `zig fmt --check`, which does not write.
- **musl's `struct timespec` is opaque after translation.** musl declares it with
  zero-width anonymous bitfields that translate-c cannot represent. The layout is
  still *derived* rather than guessed — each bitfield is
  `8 * (sizeof(time_t) - sizeof(long))` bits, zero exactly when those are equal —
  and `posix.zig` asserts that premise at comptime, so a target where it does not
  hold fails to build rather than reading the clock at wrong offsets.
- **Linux `regen-c.sh` default target is gnu, not musl.** Defaulting an unknown
  Linux arch to musl produced bindings that disagreed with the libc actually
  linked against (1292 vs 2743 lines) and failed `test/layout.zig`.

Milestones 1 and 3 are the risky ones. 1 because IOKit property paths differ per Mac model. 3 because 269 logos need visual verification — automate width/height assertions and spot-check renders, since they cannot all be eyeballed.

## 16. Testing

neofetch has no test framework, only a Travis smoke test (`time ./neofetch --travis -v` + shellcheck + a 100-column grep). Replace with:

- **Golden tests** — per-field expected output, diffed. Catches regressions a smoke test cannot.
- **`test/layout.zig` — comptime struct layout assertions.** Pins `@sizeOf` and critical `@offsetOf` for every struct in `c.zig` against values measured from clang. **This is the most important test in the project:** the failure mode it guards against is silent garbage, not a crash, so nothing else would catch it. Ground truth already captured for the two structs that were hand-written wrong:
  - `struct statfs` → size 2168; `f_fsid`@48, `f_flags`@64, `f_fstypename`@72, `f_mntonname`@88
  - `vm_statistics64_data_t` → size 416; `HOST_VM_INFO64_COUNT` = 104
  - Includes a **negative control** (deliberately wrong expected value) so CI proves the assertions actually fire.
  - Values are per-target; the Linux set is filled in during milestone 5.
- **`--benchmark` in CI** — startup median gate at 3.5 ms.
- **Zero-fork assertion** — `dtruss`/`strace` check that no `execve` occurs on the default path. This is the invariant that protects everything in §11.
- **Allocation assertion** — `--benchmark` fails if the fast path allocates.
- **Logo geometry tests** — every logo's comptime width/height is asserted nonzero and self-consistent.
- Drop the public `--travis` flag; the exhaustive profile was neofetch's test harness, not a user feature.

## 17. Risks

| risk | severity | mitigation |
|---|---|---|
| IOKit property paths vary per Mac model / Intel vs Apple Silicon | high | `hw.model`-keyed property tables; fall back to `vendor-id`+`device-id`, then to `unavailable`; test on both architectures |
| 269 logos migrated with alignment bugs | high | comptime width assertions + visual spot-checks + `--logo <name>` CI matrix sample |
| X11 protocol implementation is subtle (setup handshake, atom interning, RANDR version negotiation) | high | ~250 lines, but only two query paths needed; fall back to a `xrandr` fork behind a flag if it misbehaves |
| Zig 0.17 stdlib churn (`@cImport` removed, `bufPrint` signature changed, `std.posix.write` gone) | high | libc-only design sidesteps nearly all of it; pin `0.17.0` exactly and refuse to track master |
| Generated `src/c.zig` drifts from the toolchain or the host SDK | high | CI regenerates per target and diffs — a mismatch fails the build. Layout assertions in `test/layout.zig` independently pin every struct against clang-measured ground truth |
| `mach/mach.h` cannot go through translate-c (`mach_msg_type_descriptor_t` is `opaque {}`) | medium | take `vm_statistics64_data_t` from generated `c.zig` (safe: `mach/vm_statistics.h` alone translates cleanly); hand-declare only 2 integer typedefs + 3 functions. Typedefs cannot be subtly wrong |
| Linux `/proc` and `/sys` layouts vary across kernels and vendors | medium | defensive parsing, `unavailable` fallback rather than failure |
| rpm / nix / MacPorts package counts need forks | low | opt-in flags, documented |
| Binary grows past the 1 MB embedded-data cliff | low | size gate in CI; split rarely-used tables into lazily-mapped data if hit |

## 18. Open questions

1. **Keep `--ascii_distro` as a hidden alias for `--logo`?** Proposed: yes, for muscle memory.
2. **Logo art fidelity** — migrate byte-for-byte (safe, inherits neofetch's `\`-escaping and width bugs) or re-normalise all 269 into the new format while verifying alignment? Leaning: migrate first, fix alignment later.
3. **Cross-compiled release binaries?** The 1 MB size gate and the `-lc` requirement make static musl builds attractive for Linux, but that is a release-engineering question, not a v1 blocker.
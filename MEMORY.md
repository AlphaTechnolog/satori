# MEMORY.md

Durable memory for satori. Read this before the plan and before the code.
Update it in the same change that produces a finding.

Two plan files, both under `/Users/alpha/.opencode/plan/`:

- `satori-rewrite.md` — the master plan. Research, measurements, rationale,
  neofetch's cost breakdown, Zig landmines. Still authoritative for all of that.
- `satori-phase-2.md` (2026-10-05) — **the current execution order.** It
  supersedes §15 of the master plan's milestone ordering.

Entries are dated. When a number moves, replace it — do not leave two figures.
Delete claims that stopped being true rather than annotating them.

---

## Status: 2026-10-05

Milestone 0 complete and verified on macOS arm64 and Linux x86_64. Commits
`9ce02b4` (skeleton + invariants), `62985a6` (all gates reachable from one
command). Feature work not started. As of this entry `AGENTS.md`, `MEMORY.md` and
`LICENSE` are new and uncommitted, alongside a `build.zig.zon` `.paths` change.

### Measured (re-verify with the commands before quoting)

`$ZIG build startup` — 200 runs after 20 discarded warm-up, stripped ReleaseFast,
median of end-to-end `fork`+`exec`+`exit`:

| platform | median | min | p95 | max |
|---|---|---|---|---|
| macOS arm64 (this machine) | 1.611 ms | 1.521 | 2.006 | 2.177 |
| Linux x86_64 Debian sid (`ssh clementine`) | 1.400 ms | 1.297 | 1.475 | 1.619 |

Gate is median < 3.5 ms. neofetch measured 138 ms on the Linux box (~194×).
The plan records 0.71 ms for Linux from the milestone-0 session; that did not
reproduce on 2026-10-05. Treat sub-millisecond figures as machine- and
load-dependent and re-measure before publishing any of them.

`$ZIG build bench` — 1000 warm iterations, microseconds: `shared.load()` 4,
`sysctl osprodversion` 1, `host_statistics64` 3, **total 8**. The plan records
17 µs. Either way it is buried under ~1.5 ms of process startup.

`$ZIG build matrix` — stripped ReleaseFast bytes, all under the 1 MB gate:
aarch64-linux-gnu 13,624 · x86_64-linux-gnu 15,176 · x86_64-macos 29,814 ·
aarch64-macos 51,064 · x86_64-linux-musl 104,616 (static).

`tools/check-no-fork.sh` — the macOS binary's entire dynamic libc surface is
**18 symbols**: `__error __tlv_bootstrap _bzero _clock_gettime _getenv
_gethostname _getpagesize _host_page_size _host_statistics64 _mach_host_self
_memcpy _memmove _sigaltstack _strlen _sysctlbyname _uname _write
dyld_stub_binder`. None can fork or allocate.

C binding line counts per target (from `tools/regen-c.sh --matrix`): x86_64-linux-gnu
2,743 · aarch64-linux-gnu 2,760 · x86_64-linux-musl 1,451 · aarch64-macos 12,061 ·
x86_64-macos 12,094. The macOS/Linux gap is why one committed file cannot serve
every target.

Tests: 12 across 5 binaries — buf 4, fmt 3, shared 2, layout 2, platform 1.

### CI feasibility (verified 2026-10-05, not assumed)

**One Linux runner can run the entire gate suite — no macOS runner needed.**
`zig build check` exits 0 on clementine, which includes `regen-c.sh --matrix`
generating macOS bindings from a Linux host. Separately confirmed: a trivial
program built with `-target aarch64-macos` on clementine links successfully and
`file` reports `Mach-O 64-bit arm64 executable`. This removes the macOS-minute
multiplier, which is why "is CI free" is a non-question for a public repo.

`gh` is authenticated as `AlphaTechnolog` with `repo` + `workflow` scopes. There
is **no git remote on this repo yet**, which is why step 0 exists.

### Next steps

The current sequence is in `/Users/alpha/.opencode/plan/satori-phase-2.md`. In
short: **renderer before fields**, and **Linux parity before logos** — both
reversals of the master plan's §15 ordering, both reasoned in the phase-2 file.

1. Step 0 — public GitHub repo, push, `zig build check` in CI. Two design calls
   still need a yes: whether CI blocks on the 3.5 ms perf gate or only reports it
   (recommended: report always, block on a higher CI-only threshold — shared
   runners are not dedicated hardware), and Zig install by pinned official
   tarball + SHA256 rather than the third-party `setup-zig` action.
2. Step 1 — write `tools/gt.c`; delete `--no-color` from `usage`.
3. Step 2 — field registry + renderer, golden-tested, against the existing 6.
   `--no-color` gets implemented here (`color: bool` on `Buf`, early return in
   `sgr()`).
4. Step 3 — macOS fields through the registry to the **17** neofetch defaults.
   Start by wiring `cpuBrand`/`coreCount`/`threadCount`/`hwModel` — already
   implemented and unused, ~30 lines, 6 → 10 fields.
5. Step 4 — Linux parity. Step 5 — logos. Step 6 — CLI/`--json` freeze, config,
   opt-in, e2e golden.

Note M1 is not small: Packages alone is 1.0–1.2 ms against a total data-gathering
cost of 8 µs, and Resolution needs new structs. Neither breaks the 3.5 ms gate,
but both are the expensive ones.

### Deferred by decision, 2026-10-05

- **GPU's inclusion in M1.** The one field that forces a design decision rather
  than just code — IOKit runs through CoreFoundation types `translate-c` handles
  poorly, and `mach/mach.h` already fails translation outright. Allowed to slip
  rather than stall the milestone.
- **CI, repo, push** — authorised, not yet built (step 0).
- **`README.md`** — deferred until the CLI surface freezes. One written now
  would claim parity (false) or be an apology.

---

## Decisions and why

- **Zig 0.17.0, pinned exactly.** Chosen on merit (1.98 ms median vs 2.26 for
  0.16 vs 4.80 for cutefetch), not on speed alone. Refuse to track master.
- **libc only.** `std` is used solely for `std.mem` and `std.fmt`. 0.17 removed
  or reshaped `anytype`, `std.io`, `std.fs.File`, `std.posix.write` and
  `@cImport`; going libc-only sidesteps nearly all of that churn.
- **`@cImport` is gone in 0.17**; C translation is the `zig translate-c` CLI.
  Generated `src/c.zig` is committed, never fetched at build time — a package
  fetch would break distro packaging and air-gapped CI.
- **Zero-fork is proven statically, not traced.** `dtruss` needs root and cannot
  run on stock CI, and a trace only shows absence on one run under one input.
  An absent symbol proves absence of the capability outright. This supersedes
  plan §16's dtruss item.
- **Every negative check carries a proof it can fail**, plus guards against
  vacuous passes (empty symbol list, wrong object format, unexpected compile
  error). A check that cannot fail is worse than no check.
- **Single-threaded.** All data gathering is under 0.3 ms, so by Amdahl's law a
  thread costs more to create than the work it could hide.
- **New name and CLI.** Explicitly not a drop-in neofetch replacement.
- **MIT licence, with attribution to neofetch.** Settled 2026-10-05. The premise
  was verified, not recalled: neofetch is **MIT, not GPL** — its `LICENSE.md` is
  21 lines of "The MIT License (MIT), Copyright (c) 2015-2021 Dylan Araps", the
  README badge agrees, and the 11,592-line script carries the same header at
  lines 9–26. So all ~6,000 lines of logo art are MIT and carry no copyleft
  obligation; there is no GPL-2.0-vs-3.0 compatibility question. MIT was chosen
  because fastfetch is MIT (licence compatibility with the tool being replaced is
  worth more than voluntary copyleft) and it matches the hermetic,
  zero-dependency posture. Apache-2.0 rejected: NOTICE propagation is compliance
  surface for no gain in a 2,000-line CLI. Attribution is a licence
  *obligation*, not courtesy — it is in `LICENSE` and must be repeated in the
  README when that exists. Trademark is **not** covered by MIT; several logos are
  registered marks, so `LICENSE` says so explicitly.
- **Renderer before fields, and Linux parity before logos.** Both reverse §15 of
  the master plan. The renderer is field-count-agnostic, so building it against
  the 6 working fields makes fields 7–17 mechanical rather than a second pass at
  ad-hoc rendering; and Linux parity is the real risk while logos are bulk that a
  layout change would force a redo of. Reasoning in `satori-phase-2.md`.
- **M1 is measured against the 17 defaults `print_info` actually prints**, not
  the "20" in §15 — the plan contradicted itself and anyone counting to 20 would
  think they were finished.
- **Config will be a TOML subset, no deps.**

## Rejected, with the measurement that rejected it

- **Lua for config** — +2–4 ms startup. Unacceptable against a 1.6 ms total.
- **Counting `/var/lib/dpkg/info/` with `readdir` for Packages** — 1.7–2.3 ms
  for 1,500 entries, *slower* than scanning `/var/lib/dpkg/status` at 1.0–1.2 ms.
  Do not retry the readdir version.
- **`dtruss`/`strace` for the no-fork gate** — requires root; fails on CI.
- **Counting packages by forking `brew --cellar` etc.** — 37 ms in neofetch.
- **A thread for any default-path work** — total gathering is 8–17 µs.

## Landmines

Operational:

- **`zig` on PATH is 0.16.0 and the build fails with it.** Use
  `$HOME/.local/opt/zig-aarch64-macos-0.17.0/zig`. On clementine it is
  `~/.local/opt/zig-x86_64-linux-0.17.0/zig`.
- **`tools/regen-c.sh` with no mode flag overwrites `src/c.zig`**, inferring the
  target from `uname`. It has already replaced the macOS bindings with glibc
  ones in `~/satori` on clementine. Always pass `--check` or `--gen`.
- **`translate-c` must be given `-target`.** Without it it resolves native and
  reads the *Xcode SDK* rather than Zig's bundled libc, embedding SDK paths in
  comments and breaking reproducibility.
- **Never pipe `translate-c` stdout** — it spins at 100% CPU forever. Redirect
  to a file. This burned 7 CPU-minutes once.
- **`translate-c` has no output-file flag, and rejects `/dev/stdin` as input**
  ("unrecognized file extension of parameter"). So it always needs a real input
  path *and* a redirected stdout — there is no flag combination that avoids both
  halves of that rule. Confirmed 2026-10-05 by trying.
- **Never `zig fmt --stdin`** on generated files — hangs on ~12k lines. Use
  `zig fmt --check`. (`zig fmt` is in-place and silent in 0.17.)
- **`~/satori` on clementine is an rsync copy, not a git clone.** Commit locally
  before syncing.
- **No `~/.ssh/config` entry for `clementine`**; it resolves by other means.
  Don't go looking for one.

Correctness, all of which shipped as silent wrong answers rather than crashes:

- **A wrong hand-written `extern struct` compiles fine and returns garbage.** 2
  of 2 attempts were wrong: `struct statfs` (assumed 1,104 bytes with `f_fsid`
  last; actually 2,168 with `f_fsid`@48, `f_flags`@64, `f_fstypename`@72) and
  `vm_statistics64_data_t` (assumed 15×`u64`; actually 416 bytes = 52×`natural_t`,
  so `HOST_VM_INFO64_COUNT` = 104).
- **That wrong count made `host_statistics64` return `KERN_INVALID_ARGUMENT`**
  (268435459) and go unnoticed because the return code was not checked. It now
  renders as a plausible "0 MiB used". Always check the return code.
- **`&utsname.machine` over-reads** — the field is `[*:0]u8`, so `&field` coerces
  to the whole struct. Use `posix.strFromC` / `buf.Str.setZ`.
- **`sysctlbyname`'s returned length includes the NUL** — every string gains a
  trailing `\0` unless trimmed.
- **Reading the monotonic clock before boot time and subtracting gives a
  negative delta.** It shipped once as an empty Uptime field. Boot time is
  converted from the wall-clock domain into the monotonic domain instead.
- **macOS memory is not `total - free`.** `free_count` counts only untouched
  pages, so the naive subtraction reported ~79 GiB of an 8 GiB machine in use.
  Activity Monitor's definition is active+inactive+wired+compressed.
- **Capture names shadowing outer locals is an error** in 0.17.
- **musl's `struct timespec` arrives opaque** from translate-c (zero-width
  anonymous bitfields it cannot represent). The fallback in `posix.zig` is
  derived, not guessed, and asserts its premise at comptime.

Tooling:

- **Zig 0.17 does not collect `test` blocks from a separately declared
  module.** An aggregate root doing `_ = @import("buf")` passes while running
  one test. Hence one test binary per module.
- **`sh -c SCRIPT ARG...` sets `$0` to the first argument**, not the script
  name. Build steps need a leading placeholder.
- **A step's `dest_dir` is relative to the install prefix.** `zig-out/release`
  written literally gives `zig-out/zig-out/release`, and the size gate then
  measures nothing while reporting success.
- **Matrix labels must be the full triple.** `x86_64-linux` is ambiguous between
  gnu and musl; both installed to the same directory and one silently overwrote
  the other. Five targets built, four artifacts.
- **The Compile step must depend on binding generation, not the Install step**,
  or a clean CI runner races on files left over from a previous run.
- **`regen-c.sh` defaults Linux to gnu, not musl.** Defaulting to musl produced
  bindings that disagreed with the linked libc (1,292 vs 2,743 lines) and failed
  `test/layout.zig` with `struct_statvfs` missing.

## Open

- **`tools/gt.c` does not exist.** `test/layout.zig` tells you to
  `cc -O2 tools/gt.c -o gt && ./gt` to regenerate layout ground truth, but the
  file is missing. It is step 1 of `satori-phase-2.md` and is a prerequisite for
  every new struct — which means for milestone 1 (Resolution needs
  `struct winsize`) and all of Linux parity.
- **`--no-color` is advertised in `usage` but not honored.** `render()` ignores
  `opts.disable_color`. Verified: `./satori --no-color | cat -v` still emits
  escapes. Delete it from `usage` now, implement in step 2.
- **`README.md` does not exist**; deferred to step 6 so it does not have to claim
  parity it does not have. `LICENSE` now exists (MIT + attribution).
- **No CI workflow and no git remote.** Both step 0. Two design calls still open:
  whether CI blocks on the 3.5 ms perf gate or only reports it, and Zig install
  by pinned tarball + SHA256 vs the third-party `setup-zig` action.
- Plan §18 open questions are still open: whether to keep `--ascii_distro` as a
  hidden `--logo` alias, logo art fidelity (byte-for-byte migration vs
  re-normalising all 269 — settle at step 5, not now), and whether to ship
  cross-compiled release binaries.
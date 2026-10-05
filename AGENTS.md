# AGENTS.md

satori is a native, zero-fork rewrite of neofetch. Zig 0.17.0, libc only, zero
package dependencies. Licensed MIT, with attribution to neofetch for the logo art
— see `LICENSE`.

Public repo: <https://github.com/AlphaTechnolog/satori>, default branch `main`,
remote `origin`. `zig build check` runs in CI on **one** Linux runner
(`.github/workflows/ci.yml`) — exactly that command, no split jobs — and was
green on 2026-10-05, three runs in a row — most recent:
<https://github.com/AlphaTechnolog/satori/actions/runs/37344885729>. Runner
medians: 0.729 / 0.540 / 0.433 ms.

The design plan is at `/Users/alpha/.opencode/plan/`, in two files:
`satori-rewrite.md` (research, measurements, rationale; §5 landmines, §14 style)
and `satori-phase-2.md` (**current execution order**, supersedes §15 of the
first). Code comments cite them as "plan §N". Durable findings live in
`MEMORY.md` in this repo; read it before the plan.

## Commands

**The toolchain is pinned and `zig` on PATH is the wrong one** (0.16.0, and the
build genuinely fails with it):

```sh
ZIG=$HOME/.local/opt/zig-aarch64-macos-0.17.0/zig    # this is the one
```

| command | what it does |
|---|---|
| `$ZIG build check` | **the only command CI runs.** fmt + 12 tests + C-binding matrix + no-fork + negative control + startup gate |
| `$ZIG build test` | just the test binaries |
| `$ZIG build matrix` | generates per-target bindings, builds all 5 targets stripped ReleaseFast, enforces the 1 MB size gate |
| `$ZIG build startup` | startup median gate alone (< 3.5 ms; see below for CI) |
| `$ZIG build bench` | per-phase data-gathering timings |
| `$ZIG build fmt` | `zig fmt --check`; already the default. `-Dcheck-fmt=false` rewrites |

`zig build run -- --flag` does **not** forward args (`b.args` removed in 0.17).
Run `./zig-out/release/satori` — that is the stripped ReleaseFast binary the
perf and no-fork gates measure. `zig-out/bin/satori` is whatever `-Doptimize`
you passed, Debug by default.

There is no per-test step. For a single module, `zig test` directly:

```sh
zig test -lc src/buf.zig                                  # needs no imports
zig test -lc --dep c --dep buf -Mroot=src/fmt.zig -Mc=src/c.zig -Mbuf=src/buf.zig
zig test -lc --dep c -Mroot=test/layout.zig -Mc=src/c.zig
```

Linux (`ssh clementine` — Debian, zig at
`~/.local/opt/zig-x86_64-linux-0.17.0/zig`, source rsynced to `~/satori`, which
is **not** a git repo so commit locally before syncing):

```sh
ssh clementine 'cd ~/satori && ~/.local/opt/zig-x86_64-linux-0.17.0/zig build check'
```

Both boxes are necessary and neither is sufficient. Four landmines passed on
macOS *and* on clementine and failed only on the GitHub runner; a green check on
one laptop, or even on two, proves nothing about CI. Run it on a second host, or
simulate the hostile condition, before believing a check.

## CI

`.github/workflows/ci.yml`: one job on `ubuntu-latest`, 4 steps — `checkout`,
install the official `zig-x86_64-linux-0.17.0.tar.xz` at a pinned sha256 (never
`ziglang/setup-zig`; the scripts read `${ZIG:-zig}`, so it is put on `PATH` and
exported via `GITHUB_ENV`), print the toolchain, then **one** step running
`zig build check`. No macOS runner: a Linux host cross-builds Mach-O and
generates macOS bindings correctly (verified on clementine and on the runner).

Two env vars matter, both set at job level:

- `SATORI_TARGET: aarch64-macos` — the target `src/c.zig` is committed for.
  Note this is **not** what makes the suite pass on Linux; see the `src/c.zig`
  section.
- `SATORI_STARTUP_GATE_US: "25000"` — a second, **higher** startup threshold
  that only CI uses, because a shared runner's tail is not reproducible. It can
  only raise the local gate; `test/startup.zig` clamps it, so the escape hatch
  can never become a way to delete the gate. Both verdicts are always printed.
  25 ms is a placeholder chosen before any runner data, not a measurement —
  retune it against a spread of runs. Three runs on identical code gave medians
  0.729 / 0.540 / 0.433 ms and maxes of 3.067 / 0.812 / 0.876 ms: the median
  moves a little, the tail moves 4×, and the tail is what a blocking gate trips
  on. That is why the gate reports.

## Invariants

Two, both enforced by `zig build check`. Breaking either fails the build:

1. **A module may never fork.** No subprocess, ever. `tools/check-no-fork.sh`
   inspects the shipped binary's undefined-symbol table and fails on
   `fork/exec*/posix_spawn/system/popen/dlopen/wait*` and on
   `malloc/calloc/realloc/free`. An absent symbol proves an absent *capability* —
   no input, env or code path can reach it — which is why this replaced dtruss.
2. **Exactly one `write(2)`, at exit.** Compose into `stdout_buf`, flush once,
   in `main.zig` only.

Keeping them true:

- No allocation on the default path; every module writes into caller-provided
  stack buffers.
- libc only. `std` is imported solely for `std.mem` and `std.fmt`. No `std.fs`,
  `std.heap`, `std.io`, `std.posix`.
- **Never hand-write a struct layout.** 2 of 2 attempts were silently wrong
  (`struct statfs`, `vm_statistics64_data_t`) — a wrong layout returns garbage,
  not a compile error. Hand-written *signatures* are fine when they take and
  return integers. The one sanctioned layout exception is musl's
  `struct timespec` in `posix.zig`, guarded by a comptime assertion that its
  premise (`sizeof(time_t) == sizeof(long)`) holds.
- Modules return `bool`, never exit. A missing source prints `unavailable`.
- **Check `host_statistics64`'s return code.** A wrong `HOST_VM_INFO64_COUNT`
  does not crash — it returns `KERN_INVALID_ARGUMENT` and leaves the struct
  zeroed, which renders as "0 MiB used".
- `mach_host_self()` must actually be called; hardcoding the host port fails.

## `src/c.zig` is generated, committed, and valid for ONE target

`src/c.h` is the source of truth. `src/c.zig` is committed for **aarch64-macos
only** (12,061 lines), and that target is *declared*, not inferred:
`COMMITTED_C_TARGET` in `build.zig`. Every other target needs its own.

**A build on any other host must generate host bindings instead of using the
committed file.** `build.zig` does this automatically when the resolved build
host is not `COMMITTED_C_TARGET`, writing `zig-out/bindings/c.<triple>.zig` and
pointing `-Dc-file` at it. Override with
`-Dc-file=zig-out/bindings/c.<full-triple>.zig` for a one-off cross-build.

This is not an optimisation. The macOS bindings contain no `struct_sysinfo`, no
`struct_statvfs` and no `CLOCK_BOOTTIME`, so on a Linux host the committed file
cannot compile `src/platform/linux.zig`, `test/layout.zig`'s Linux branch, or
the negative control. `SATORI_TARGET` does **not** fix this — it only tells
`regen-c.sh` which target to diff against; it cannot change which file the build
compiles. That premise failed silently for four build steps before it was found.

`zig build matrix` never touches the committed file (it passes
`--gen --out zig-out/bindings/c.<full-triple>.zig`).

**The footgun: `tools/regen-c.sh` with no mode flag overwrites `src/c.zig`**,
inferring the target from `uname`. Running it bare on Linux silently replaces the
macOS bindings with Linux ones. (That already happened in `~/satori` on
clementine — that file is 2,743 lines of glibc bindings, not the committed
12,061.) Always pass a mode:

```sh
tools/regen-c.sh --check                    # verify the committed file is current
tools/regen-c.sh --gen aarch64-macos        # verify translation, write nothing
tools/regen-c.sh aarch64-macos              # OVERWRITES src/c.zig — only if you mean to commit it
```

Rules encoded in the script, each learned the hard way:

- **`-target` is mandatory.** Without it translate-c reads the *Xcode SDK*
  rather than Zig's bundled libc, and every embedded header path in the output
  changes, so the file stops being reproducible per-developer.
- **The generating machine's paths must not survive into a committed file.**
  `translate-c` stamps the absolute path of the Zig installation into its
  diagnostic comments — 1,384 of them in the aarch64-macos file. `regen-c.sh`
  rewrites that prefix to `<zig-install>` on `//` comment lines **only**. Without
  it `--check` reports the committed file stale on every host but the author's,
  on a diff of provenance rather than declarations. Do not drop the step, and do
  not widen it past comments, where a path could be load-bearing.
- **Never pipe `translate-c` stdout.** Given a pipe it spins at 100% CPU forever.
  Redirect to a file. It also rejects `/dev/stdin` as input and has no
  output-file flag, so a real input path *and* a redirected stdout are both
  required.
- **Never `zig fmt --stdin`** — hangs on ~12k lines. Use `zig fmt --check`.
- Matrix labels must be the **full triple**. `x86_64-linux` is ambiguous between
  gnu and musl; they silently overwrite each other.
- The Compile step depends on binding generation, not the Install step, or a
  clean CI runner races on leftover files.

## Layout ground truth

`test/layout.zig` pins every `@sizeOf`/`@offsetOf` at comptime against values
measured by the platform C compiler. It is the most important test in the repo:
the failure it prevents is silently wrong output, not a crash.

Values are **per-target**; adding a struct means adding ground truth for both
macOS and Linux or the `else` branch `@compileError`s. `test/layout.zig` tells you
to run `cc -O2 tools/gt.c` — **`tools/gt.c` does not exist yet**, so write it
before adding a struct.

`test/negative_control.zig` must never compile, and
`tools/check-negative-control.sh` fails if it does. Keep the failure *reason*
right: the script greps for the marker `NEGATIVE CONTROL TRIGGERED`, and a
compile error for any other reason is a failed gate. That already happened when
the control named `struct_statfs` outright and so failed on Linux for the wrong
reason.

The script takes the bindings path as `$1` and `build.zig` passes the *resolved*
`c_file`, so it compiles the control against the same bindings `test/layout.zig`
used. It also builds with its own `zig build-obj` rather than consuming a
build-graph artifact, so nothing in the graph implied it had to wait for
`zig-out/bindings/` — and on a clean tree it lost that race. The build step
therefore declares an explicit dependency.

## Zig 0.17 traps

Already paid for. Plan §5 has the full table.

- `anytype` is **removed** → `inline fn zeroed(comptime T: type) T`.
- `std.fmt.bufPrint` returns the written **slice**, not a count.
- `std.time.Timer`, `std.process.argsAlloc`, `std.posix.write`, `std.fs.File`,
  `@cImport` are all gone. Timers are `posix.monotonicNs()`; argv arrives as
  `main(init: std.process.Init.Minimal)`.
- Function params are `const`, so `v /= 10` fails — copy to a `var` local.
- A method or capture named `u64`/`u8`/… gives "shadows primitive"; name it
  `uint`. `c_int`, `c_long`, `c_ulong` already exist in `c.zig`; don't redefine.
- In a build step, `sh -c SCRIPT ARG...` sets `$0` to the **first** argument.
  Add a leading placeholder or the binary path lands in `$0`.
- **Invoke the gate scripts as `bash`, never `sh`.** They declare
  `#!/usr/bin/env bash` and use `set -o pipefail`, which is not POSIX; calling
  them as `sh` overrides their own shebang. Whether the suite then works is
  decided by the runner image: macOS `/bin/sh` is bash, clementine's dash grew
  `pipefail` in 2022, and the GitHub runner's dash did not —
  `set: Illegal option -o pipefail`, failing four steps at once.
- `zig build` does **not** collect `test` blocks from a separately declared
  module. An aggregate root doing `_ = @import("buf")` passes while running one
  test. This is why `build.zig` builds one test binary per module — do not
  "simplify" it back.
- `addExecutable`/`addTest` take `root_module`. `strip` is a `Module` field, not
  an `ExecutableOptions` field.
- A step's `dest_dir` is relative to the install prefix: writing
  `zig-out/release` yields `zig-out/zig-out/release`, and the size gate then
  silently measures nothing.

## Source layout

- `src/main.zig` — entry, arg parsing, `render()`. **This is where fields get
  wired in.**
- `src/shared.zig` — `uname`, boot time, hostname, env, gathered once in
  `load()` and passed as `*Shared`. A module wanting the kernel version does not
  call `uname()` again.
- `src/buf.zig` — slice writer + `Str`. Every C-string boundary goes through
  `posix.strFromC` / `buf.Str.setZ`. No `strdup`, no sentinels, no allocator.
- `src/fmt.zig` — formatters that write into a caller's `Buf` and return the
  sub-slice.
- `src/platform/{posix,macos,linux}.zig` — data sources. `shared.zig` picks one
  by comptime switch on `builtin.os.tag`; `build.zig` wires both so the unused
  one is never instantiated.
- All modules are created with `b.createModule` (private), never `b.addModule`.

Rendering gotcha: **format into a separate buffer before calling
`out.field(...)`.** Passing `out` to both `fmt.*` and `field` evaluates in the
wrong order and prints `50sUptime: 50s`. Same for `render()`'s
`value_storage` — that buffer exists for exactly this reason.

## Known gaps

Verified, so you don't waste time rediscovering them:

- Field parity is 6 of neofetch's 17 defaults (OS, Kernel, Arch, Shell, Uptime,
  Memory). `macos.zig` already implements `cpuBrand`, `coreCount`,
  `threadCount`, `hwModel` — implemented and *unused*, not yet rendered.
- `--no-color` is advertised in `usage` but **not honored**; `render()` ignores
  `opts.disable_color`. Verified: `./satori --no-color | cat -v` still emits
  escapes. Delete it from `usage`; implement it in the renderer step.
- `tools/gt.c` is referenced by `test/layout.zig` but **does not exist**, so
  regenerating layout ground truth has no documented working procedure. It is
  step 1 of `satori-phase-2.md` and a prerequisite for every new struct.
- No README. Deferred to step 6 so it does not have to claim parity it does not
  have; `LICENSE` plus this file carry anyone arriving cold for now. The MIT
  attribution to neofetch must be repeated in it when it is written.
- `logos/data/` is empty and unreferenced by the build (only `build.zig.zon`'s
  `.paths` mentions it). The logo engine is not started.

## MEMORY.md

`MEMORY.md` at the repo root is this project's durable memory. Read it before
the plan and before the code, and **update it in the same change that produces
the finding** — not later, not from memory.

Record, with the hardware and the exact command where relevant:

- **Measured numbers**, dated. Startup median, data-gathering cost, binary sizes.
  Re-measure rather than quoting a stale figure; if a number moved, replace it.
- **Milestones reached**, and the current milestone with its next concrete steps.
- **Decisions and their reasons**, especially ones that reversed earlier ones.
- **Rejected approaches, with the measurement that rejected them.** A rejected
  hypothesis recorded without its number gets retried.
- **Landmines** — the trap, the symptom, and what to do instead.

Keep it factual and dated. Delete anything that stopped being true instead of
annotating it: a stale claim here is worse than a missing one, because the next
agent will trust it. If you find a wrong claim in `MEMORY.md`, fix it in the same
change that noticed it.
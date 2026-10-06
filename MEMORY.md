# MEMORY.md

Durable memory for satori. Read this before the plan and before the code.
Update it in the same change that produces a finding.

Two plan files, both in `docs/plan/` **in this repo** (moved from
`~/.opencode/plan/` on 2026-10-06, so every reader — including ones who are
not me — can follow a citation to them):

- `satori-rewrite.md` — the master plan. Research, measurements, rationale,
  neofetch's cost breakdown, Zig landmines. Still authoritative for all of that.
- `satori-phase-2.md` (2026-10-05) — **the current execution order.** It
  supersedes §15 of the master plan's milestone ordering.

Work is dispatched as OpenSpec changes under `openspec/` (AGENTS.md
§Workflow): specs state intent, tests pin bytes, this file keeps what was
measured.

Entries are dated. When a number moves, replace it — do not leave two figures.
Delete claims that stopped being true rather than annotating them.

---

## Status

**2026-10-06 — dispatch migrated to OpenSpec.** `openspec init --tools opencode`;
four capability specs seeded and strict-green (`core-invariants`, `rendering`,
`bindings`, `cli`); the brief format retired (`agent-brief-spec.md` deleted),
its contracts moved into `openspec/config.yaml` as injected `context:`/`rules:`;
plan files moved into `docs/plan/` in-repo; report + memory inflow now enforced
by the Handoff task group every `tasks.md` must end with. CI unchanged: still
exactly `zig build check`, no Node. Commits `c9d96dc` (spec tree + config
contracts) and `4e8e94f` (plan in-repo, workflow docs); green run
<https://github.com/AlphaTechnolog/satori/actions/runs/37473438573>.

**Public repo live and CI green.** <https://github.com/AlphaTechnolog/satori>
(`AlphaTechnolog/satori`, public, default branch `main`). Milestone 0 complete
and verified on macOS arm64, Linux x86_64, and a GitHub Actions
`ubuntu-latest` runner. Commits `9ce02b4` (skeleton + invariants), `62985a6`
(one command for every gate), `c8e2923` (docs + licence), `06d1062` + `950c7ec`
+ `e992d3e` (run the gates on any host, and CI), `13f0c5e` (record CI in
AGENTS.md), `a11ca8f` + `77d146d` (runner measurements 2 and 3), `fd8a40f`
(correct three stale records in these two files), `52edab2` (step 1: write
`tools/gt.c`, drop the `--no-color` lie), then step 2 in four commits:
`898534c` (renderer into its own module, the two live syscalls into `load()`),
`b84943c` (comptime field registry, alignment, label colour, `unavailable`),
`7a65371` (`--no-color` honoured and re-advertised), `702387a` (fix the Linux
golden arm — see Landmines, it is the most reusable finding here).

CI runs exactly `zig build check` on **one** Linux runner. Green runs at 2m52s,
2m03s, 1m58s, 1m51s and (step 2) 2m05s of actual build time. First:
<https://github.com/AlphaTechnolog/satori/actions/runs/37343357084> (commit
`e992d3e`); then <https://github.com/AlphaTechnolog/satori/actions/runs/37344427595>
(`13f0c5e`), <https://github.com/AlphaTechnolog/satori/actions/runs/37344885729>
(`a11ca8f`), <https://github.com/AlphaTechnolog/satori/actions/runs/37345446554>
(`77d146d`), and <https://github.com/AlphaTechnolog/satori/actions/runs/37364533178>
(`702387a`). Also green, build times not recorded:
<https://github.com/AlphaTechnolog/satori/actions/runs/37351507171> (`52edab2`),
<https://github.com/AlphaTechnolog/satori/actions/runs/37366942574> (`f525f31`),
<https://github.com/AlphaTechnolog/satori/actions/runs/37473438573> (the
OpenSpec migration, `4e8e94f`). Eight of eight; the one cancelled run is the
`cancel-in-progress` story below.

**`concurrency: cancel-in-progress` will cancel a run you are watching, and
`gh` reports a cancelled run as a red `failure` with no log.** Step 2's first
runner attempt looked like a red build for this reason: pushing a second commit
mid-run cancelled the run for the first, and the run for the second was then
cancelled too. Two runs in a row, both `conclusion: cancelled`, no job steps at
all and `gh run view --log` returning "log not found". A cancelled job has **no
steps**, which is the tell: a real failure has a step with a failing conclusion.
Re-run (`gh run rerun`) and watch to completion. Two hours were lost to reading
`gh run watch`'s `exit 0` — it exits 0 on cancel — as a pass.

The Linux verification host was rebuilt on 2026-10-05 and is no longer
trustworthy-by-accident: `~/satori` on clementine is now a clean `git clone` of
the public repo, not the stale rsync tree that had been silently certifying
pre-fix code. See Landmines. Both Linux figures in this file that predate that
refresh were re-measured on the clone.

### The two verification hosts

Quoting a number without saying where it came from is how the 1.400 ms figure
below survived in this file for a day.

- **macOS arm64** — this machine, Darwin 26.6.2, Apple clang, Zig
  `~/.local/opt/zig-aarch64-macos-0.17.0/zig`. Build host matches
  `COMMITTED_C_TARGET`, so it compiles the committed `src/c.zig`.
- **Linux x86_64** — `ssh clementine`, Intel i5-6500 @ 3.20 GHz, 4 cores,
  Debian forky/sid, glibc 2.43, gcc 16.2.0, kernel 7.1.13, Zig
  `~/.local/opt/zig-x86_64-linux-0.17.0/zig`. Build host is *not*
  `COMMITTED_C_TARGET`, so it generates its own bindings into
  `zig-out/bindings/` — the path that makes the Linux result equivalent to CI's.

Getting there took four fixes that none of the local testing could have found,
because every one of them only bites on a host that is not the maintainer's
laptop. They are recorded under Landmines below, and all four are the kind of
thing that will be re-introduced by a well-meaning refactor.

### Measured (re-verify with the commands before quoting)

`$ZIG build startup` — 200 runs after 20 discarded warm-up, stripped ReleaseFast,
median of end-to-end `fork`+`exec`+`exit`.

**Read the caveat under the table before quoting any single cell. Every figure in
it is a property of the machine and its load, not of satori.** The same binary on
the same idle box moved from a 0.675 ms median to 0.978 ms with a 4.226 ms max
when eight spinners were put on it. Both of the "Linux" figures this table used
to carry — 1.400 ms, then 0.845 ms — fail to reproduce under stated conditions,
one from each of the two failure modes: the stale rsync tree, and a loaded
session on the correct commit. A cell is a fact about one run, not a constant.

| platform | median | min | p95 | max |
|---|---|---|---|---|
| macOS arm64 (this machine) | 1.603 ms | 1.511 | 1.836 | 2.316 |
| Linux x86_64 Debian forky/sid (`ssh clementine`) | **0.674 ms** | 0.605 | 0.779 | 0.820 |
| **GitHub Actions `ubuntu-latest`** (8 runs) | **0.729 / 0.540 / 0.433 / 0.480 / 0.552 / 0.693 / 0.687 / 1.004 ms** | 0.680 / 0.511 / 0.407 / 0.466 / 0.515 / 0.651 / 0.653 / 0.690 | 0.964 / 0.680 / 0.575 / 0.548 / 0.766 / 0.818 / 0.762 / 1.985 | **3.067** / 0.812 / 0.876 / 0.594 / 1.139 / 1.821 / 0.861 / **4.032** |

The macOS and clementine rows are step 2's, re-measured at `702387a` on an idle
box (`zig build check`, which prints the same 200-run figures as `zig build
startup`). They are in the same band as the pre-step-2 figures — 1.603 vs 1.611
ms on macOS, 0.674 vs 0.672–0.682 ms on clementine — so **the field registry
and the `--no-color` work cost nothing measurable end to end.** Given the
load-sensitivity documented below, "no change" is the honest reading and not
"measured identical": these are single samples from different sessions, and the
spread between the two is well inside the noise.

The Linux row's pre-step-2 history, kept because it is what makes the row a
measurement rather than a single lucky sample: five samples of `77d146d` from a
**clean `git clone`** in `~/satori` on an idle box (load average 0.02), all with
20 discarded warm-up runs and 200 measured: medians 0.682 / 0.673 / 0.677 ms from
three `zig build startup` runs and 0.672 / 0.675 ms from two `zig build check`
runs. The two entry points agree and the whole spread is 1.5%. Step 2's single
`0.674 ms` sits inside it.

It **replaces 1.400 ms**, which was measured on the stale rsync tree described
under Landmines and is not a measurement of this commit at all. An earlier
session on this very same commit reported 0.845 ms; that did not reproduce in
five samples spanning 0.672–0.682 ms, so it was almost certainly a loaded
session — the 8-way-load numbers below are the size of that effect. The general
lesson is the one already written at the top of this file: a sub-millisecond
figure is not a constant, and quoting one without its conditions is how 1.400 ms
survived here for a day.

The macOS row is a single figure and equally load-sensitive: re-measuring on
2026-10-05 across sessions gave 1.560, 1.603, 1.701, 1.741 and 1.769 ms
depending on background load — a 1.13x spread on identical code.

The 8-way-load measurement is the mechanism behind the caveat above, on the same
binary and the same idle box immediately afterwards: min 0.618, **median 0.978**,
p95 2.719, **max 4.226 ms**. That max is *over* the 3.5 ms local gate, from CPU
load alone on hardware that is fine. This is what a shared runner looks like, and
it is why CI reports the median at a 25 ms gate instead of blocking at 3.5 ms.

**The shared CI runner's medians sit in the same band as the dedicated boxes**
— 0.433–1.004 ms across eight runs, against 0.674 ms on clementine and 1.603 ms
on the Mac. The first four runs were each faster than either dedicated box;
run 8 (1.004 ms) was slower than clementine. Runner: `Linux
6.17.0-1022-azure x86_64`, 4 cores. Do not read either direction as a
hardware fact; read it as the numbers tracking the runner's load.

The useful detail is the **spread across the runs**. Runs 1–4 are identical
code (0.729 / 0.540 / 0.433 / 0.480 ms, spanning 1.7× on one job definition);
runs 5–7 straddle steps 1 and 2 (0.552 / 0.693 / 0.687 ms — the renderer work
again lands inside the original spread, so it cost nothing there either); and
run 8, the OpenSpec migration whose commits leave `src/` untouched, came in at
**1.004 ms — 2.3× above the 0.433 floor on the same code**. The tails are
sharper: run 1 reached **max 3.067 ms** — a 4.2× tail, close enough to the
3.5 ms local gate to have failed it on luck — and run 8 reached **max
4.032 ms, over the local gate from runner load alone**, while runs 2–7 stayed
between 0.594 and 1.821 ms. So the median is stable to within a small factor
and the tail is not, and the tail is exactly what a blocking gate trips on.
That is the measured justification for reporting rather than blocking (see
Decisions).

Gate is median < 3.5 ms. neofetch measured 138 ms on the Linux box (~205×).
The plan records 0.71 ms for Linux from the milestone-0 session; that did not
reproduce on 2026-10-05 either (0.672–0.682 ms), though sub-millisecond figures
*did* reproduce on clementine and on the CI runner within the same session.
Treat every sub-millisecond figure as machine- and load-dependent, quote it with
its conditions, and re-measure before publishing one.

`$ZIG build bench` — 1000 warm iterations, microseconds, macOS arm64. The
renderer is now measured too, and `load()` has changed meaning — see below.

| phase | before (step 1) | after (step 2, `702387a`) |
|---|---|---|
| `shared.load()` | 4 (once), 6–10 (across sessions) | **6** (5 samples: 6, 6, 6, 7, 18) |
| `sysctl osprodversion` | 1 | 1 (inside `load()`) |
| `host_statistics64` | 3 | 1 (inside `load()`) |
| `render()` | not measured | **1** |
| total data gathering | 8 | **6** |

Three things changed in this harness and one number moved:

- **`total` no longer double-counts.** `sysctl osprodversion` and
  `host_statistics64` used to be timed separately *and* added into the total,
  which was only honest while `render()` called them itself. Since step 2 they
  are components of `load()`, so `total` is `load_us` alone. The old figure of 8
  µs therefore described two different things than the new 6 µs; do not compare
  them as a trend.
- **`load()` absorbed those two syscalls** (they moved out of `render()`), which
  is why its before/after figures overlap rather than the after being larger by
  the sum of the other two. `load()` did not get slower; the work just moved
  across the boundary between "gathering" and "rendering", and the renderer is
  now measurable at 1 µs because it is pure formatting.
- **The single 18 µs sample is a real outlier** on an otherwise 6–7 µs run, and
  is left in the table rather than dropped. A single sample of a sub-10 µs
  quantity on a machine whose load swings 1.13x is not a measurement of the
  code.

**The renderer costs 1 µs against a ~1.6 ms startup — 0.06% of the process.**
That is the number step 2 was supposed to produce, and it is why nothing in the
field count is going to become a performance problem. The plan records 17 µs for
the old total; either way all of it is buried under process startup.

`$ZIG build matrix` — stripped ReleaseFast bytes, all under the 1 MB gate:
aarch64-linux-gnu 13,624 · x86_64-linux-gnu 15,176 · x86_64-macos 29,814 ·
aarch64-macos 51,064 · x86_64-linux-musl 104,616 (static).

`tools/check-no-fork.sh` — the macOS binary's entire dynamic libc surface is
**18 symbols**: `__error __tlv_bootstrap _bzero _clock_gettime _getenv
_gethostname _getpagesize _host_page_size _host_statistics64 _mach_host_self
_memcpy _memmove _sigaltstack _strlen _sysctlbyname _uname _write
dyld_stub_binder`. None can fork or allocate. The Linux ELF has **22**, all
`@GLIBC_*`-versioned: `clock_gettime close __errno_location getauxval getenv
gethostname getrlimit64 __gmon_start__ _ITM_deregisterTMCloneTable
_ITM_registerTMCloneTable __libc_start_main memcpy memmove open read
setrlimit64 sigaltstack strlen sysconf __tls_get_addr uname write`. The extra
four are `open`/`read`/`close` (boot time from `/proc/uptime`) and the CRT/IFUNC
entries, not forks. Verified on CI, not only locally.

C binding line counts per target (from `tools/regen-c.sh --matrix`): x86_64-linux-gnu
2,743 · aarch64-linux-gnu 2,760 · x86_64-linux-musl 1,451 · aarch64-macos 12,061 ·
x86_64-macos 12,094. **Reproduced byte-for-byte on the GitHub runner**, which is
the real proof that the generated file is toolchain-determined and not
machine-determined. The macOS/Linux gap is why one committed file cannot serve
every target.

Tests: **19 across 6 binaries** — buf 5, fmt 3, shared 2, **render 6**, layout 2,
platform 1. Was 12 across 5 (buf 4, fmt 3, shared 2, layout 2, platform 1).
The six new ones are all in `src/render.zig`, which is a new module with its own
test binary, plus one in `buf.zig`.

Count them with `$ZIG build test --summary all`, which prints
`run test render 6 pass (6 total)`. `zig build test` alone prints nothing, and
counting `^test "` with grep does not tell you whether the tests *ran* — the
one-binary-per-module rule exists precisely because a `test` block in a
separately declared module does not get collected.

### CI feasibility (verified 2026-10-05, not assumed)

**One Linux runner can run the entire gate suite — no macOS runner needed.**
`zig build check` exits 0 on clementine, which includes `regen-c.sh --matrix`
generating macOS bindings from a Linux host. Separately confirmed: a trivial
program built with `-target aarch64-macos` on clementine links successfully and
`file` reports `Mach-O 64-bit arm64 executable`. This removes the macOS-minute
multiplier, which is why "is CI free" is a non-question for a public repo.
Now also verified on `ubuntu-latest` itself.

Zig in CI is the **official `zig-x86_64-linux-0.17.0.tar.xz` at a pinned
sha256**, `1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026`
(57,332,648 bytes). The digest was taken from ziglang.org's `index.json` and
then confirmed by downloading the tarball and checksumming it locally — do not
quote it from memory.

`gh` is authenticated as `AlphaTechnolog` with `repo` + `workflow` + `delete_repo`
scopes.

### Next steps

The current sequence is in `docs/plan/satori-phase-2.md`.

1. **Step 1 — done 2026-10-05.** `tools/gt.c` written and verified on both
   hosts; `--no-color` out of `usage`.
2. **Step 2 — done 2026-10-05** (`898534c`, `b84943c`, `7a65371`, `702387a`).
   `src/render.zig` owns a comptime `Field` registry; `render()` is a pure
   function of `*const shared.Shared`; golden tests pin the exact bytes on both
   platform arms; `--no-color` is real. All 6 fields render, aligned, with
   `unavailable` for a missing source. See §Open for what was deliberately not
   built.
3. Step 3 — macOS fields through the registry to the **17** neofetch defaults.
   The registry already exists, so this is one line and one `fn` per field.
   Start by wiring `cpuBrand`/`coreCount`/`threadCount`/`hwModel` — already
   implemented and unused, ~30 lines, 6 → 10 fields.
4. Step 4 — Linux parity. Step 5 — logos. Step 6 — CLI/`--json` freeze, config,
   opt-in, e2e golden.

`tools/gt.c` is what unblocks step 3 and step 4: Resolution needs
`struct winsize`, and step 4 is Linux parity, so between them every remaining
field needs measured ground truth for at least one new struct. Verified there on
2026-10-05: it emits the switch arm body for whichever platform it is compiled
on, and all 21 values `test/layout.zig` asserts per arm come out of it verbatim,
so no asserted number is hand-entered.

Also worth doing soon, cheap and now unblocked:

- **Set a real blocking CI perf threshold.** 25 ms was chosen before there was
  any runner data, and the eight observed medians now span 0.433–1.004 ms (the
  table above), so the current gate only catches catastrophic regressions.
  `SATORI_STARTUP_GATE_US` exists for exactly this retune. Eight runs is still
  not much of a distribution; collect more. Whatever the threshold ends up
  being, the tail has to be accounted for: run 1 produced a 3.067 ms max
  against a 0.729 ms median, and run 8 (the OpenSpec migration, identical
  `src/`) a **4.032 ms max against 1.004 ms — over the 3.5 ms local gate from
  runner load alone** — while 8-way CPU load on an idle dedicated box put a
  **4.226 ms max** on the same binary, same gate.
- **Pin `ubuntu-24.04` instead of `ubuntu-latest`.** The runner log warns that
  `ubuntu-latest` migrates to Ubuntu 26 on 2026-10-19, which will move `/bin/sh`
  and the libc under the gates. Deliberately left as `ubuntu-latest` so a moving
  base gets noticed rather than silently pinned over; revisit if it turns noisy.

Note M1 is not small: Packages alone is 1.0–1.2 ms against a total data-gathering
cost of 8 µs, and Resolution needs new structs. Neither breaks the 3.5 ms gate,
but both are the expensive ones.

### Deferred by decision, 2026-10-05

- **GPU's inclusion in M1.** The one field that forces a design decision rather
  than just code — IOKit runs through CoreFoundation types `translate-c` handles
  poorly, and `mach/mach.h` already fails translation outright. Allowed to slip
  rather than stall the milestone.
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
  Step 2 is the evidence for the first half of that: adding a field is now one
  line in the registry plus one formatter.
- **The renderer is a separate module, not a private function in `main.zig`.**
  `zig build` compiles one test binary per source module, so a function private
  to the entry point is unreachable from every test. This is not a preference
  for tidiness; it is the only arrangement under which the golden tests could
  exist at all.
- **`render()` calls no syscall.** `macos.osVersion` and `macos.vmStats` were
  called from the renderer until step 2, which meant a golden test of it would
  have baked in whatever machine ran it. They now live in `Shared.load()`.
- **`Buf.field` was deleted rather than wrapped.** A second row emitter that
  knows nothing about colour or alignment is a row emitter that can be
  forgotten — and it *was* forgotten: the Memory row was already hand-writing
  `"Memory: "` next to it. One function emits rows, so that is the only way a row
  gets printed.
- **`--no-color` is one `color` bool on `Buf` with an early return in `sgr()`.**
  That only works because `sgr` is the *total* set of escape-producing calls,
  which is now stated as an invariant on `sgr` rather than left implicit. The
  alternatives (a parameter on every write method, filtering at flush time, an
  enum instead of a bool) are recorded in `7a65371`'s message.
- **Label width is derived from the registry at comptime**, not hardcoded, so
  step 3's longer labels cannot silently break the alignment.
- **A missing source prints `unavailable`, everywhere, including Linux.**
  Today a Linux `Memory` row reads `unavailable` rather than vanishing, so the
  gap is visible rather than silent. Same for a blank `Uptime`, which is the
  exact symptom of the boot-time source failing — a bug that shipped once.
- **M1 is measured against the 17 defaults `print_info` actually prints**, not
  the "20" in §15 — the plan contradicted itself and anyone counting to 20 would
  think they were finished.
- **Config will be a TOML subset, no deps.**
- **Public repo, one Linux runner, no macOS runner.** Public repos get free
  Actions on any plan, which settles the "unless it's paid" question. A macOS
  runner would multiply the minutes for no coverage gain, because a Linux host
  cross-builds Mach-O and generates macOS bindings correctly (verified). Flip
  this if a macOS-only gate ever appears.
- **Zig installed from the official tarball at a pinned sha256**, not
  `ziglang/setup-zig`. The action is convenient and would have saved ten lines;
  it is a third party resolving the version, which is precisely the thing this
  project argues against. The digest is verified twice, once against
  ziglang.org's `index.json` and once by checksumming a real download.
- **CI runs the perf gate but does not block on it at 3.5 ms.** `zig build
  startup` always prints the median and now prints *both* verdicts: the local
  3.5 ms gate and a CI-only gate set by `SATORI_STARTUP_GATE_US`. The override
  can only **raise** the threshold — `test/startup.zig` clamps it to the local
  gate — so the escape hatch cannot turn into a way to delete the gate. Measured
  justification: under 8-way CPU load the median reaches 4.030 ms and under
  32-way it reaches 5.242 ms, both on a box that is fine, which is what a shared
  runner looks like; and of four real CI runs on identical code, one had a
  **max** of 3.067 ms against a 0.729 ms median while the other three ran at
  0.540 / 0.433 / 0.480 ms with 0.812 / 0.876 / 0.594 ms maxes. A gate at
  3.5 ms on that hardware would be a coin flip.
  A flaky red build teaches everyone to ignore CI, which costs more than the
  regression this stands in for.
- **The committed bindings' target is a declared constant**
  (`COMMITTED_C_TARGET` in build.zig), and `regen-c.sh` receives it explicitly
  instead of inferring it from `uname`. This supersedes the plan's suggestion
  that `SATORI_TARGET` in the workflow would be enough — it is not, and
  see Landmines.
- **Dispatch runs on OpenSpec; the brief format retired (2026-10-06).** The
  brief's contracts (D-decisions with checkable Why, cite-don't-duplicate,
  verify-with-passing-meaning, budget) moved into `openspec/config.yaml` as
  `context:`/`rules:` so they are injected into every artifact instead of
  drifting beside it as a second format document. Plan files moved into
  `docs/plan/` in-repo because their citations in these two files were dead
  for anyone but this machine. OpenSpec has no report artifact (artifacts are
  the built-in four), so the report contract is the final **Handoff** task
  group — checkboxes apply cannot finish without, which is how the memory
  inflow survives the migration. **`openspec validate` is a local gate only,
  never CI**: it needs Node, which collides with the pinned-tarball hermetic
  posture and with CI running exactly one command; validation runs at propose
  and before archive instead. Specs/tests split: specs state intent, tests pin
  bytes — a spec scenario that restates a golden test buys nothing.

## Rejected, with the measurement that rejected it

- **Lua for config** — +2–4 ms startup. Unacceptable against a 1.6 ms total.
- **Counting `/var/lib/dpkg/info/` with `readdir` for Packages** — 1.7–2.3 ms
  for 1,500 entries, *slower* than scanning `/var/lib/dpkg/status` at 1.0–1.2 ms.
  Do not retry the readdir version.
- **`dtruss`/`strace` for the no-fork gate** — requires root; fails on CI.
- **Counting packages by forking `brew --cellar` etc.** — 37 ms in neofetch.
- **A thread for any default-path work** — total gathering is 6–18 µs on
  macOS arm64, and the renderer itself is 1 µs of that. Even a thousand
  additional fields at 1 µs each would not reach the 3.5 ms gate.
- **Streaming rows to stdout as they are produced, to save the 64 KiB
  composition buffer.** Rejected: it breaks the "exactly one `write(2)`" project
  invariant, which is worth more than the 64 KiB of stack, and the buffer is
  fixed-size and never allocated.
- **A `Scratch` type wrapping the value buffer, instead of `buf.Buf.init` over a
  local array at each use site.** Rejected in step 2 as speculative: there are
  two call sites (the renderer, the bench harness) and one of them is a test.
  If a third appears, that is when the type earns itself.
- **A `Comptime-configurable field set** (a build option selecting which fields
  render). Rejected in step 2: it would make the golden tests target-dependent
  and the output non-deterministic for a saving nobody has asked for.

## Landmines

Operational:

- **`zig` on PATH is 0.16.0 and the build fails with it.** Use
  `$HOME/.local/opt/zig-aarch64-macos-0.17.0/zig`. On clementine it is
  `~/.local/opt/zig-x86_64-linux-0.17.0/zig`.
- **`SATORI_TARGET=aarch64-macos` does NOT make `zig build check` pass on a
  Linux host.** This was believed to be verified and was not; it is the most
  expensive landmine here, because it costs four build steps and looks like a
  real regression. `SATORI_TARGET` only tells `regen-c.sh` which target to diff
  the committed file against — it cannot change which file the *build* compiles.
  The aarch64-macos bindings contain no `struct_sysinfo`, no `struct_statvfs`
  and no `CLOCK_BOOTTIME`, so a Linux host cannot build the Linux platform
  layer, `test/layout.zig`'s Linux branch, or the negative control against
  them. `build.zig` now generates host bindings into `zig-out/bindings/` when
  the build host is not `COMMITTED_C_TARGET`. **Test on a foreign host; a green
  `zig build check` on one laptop proves nothing about CI.**
- **`build.zig` must invoke the gate scripts with `bash`, not `sh`.** The
  scripts declare `#!/usr/bin/env bash` and use `set -o pipefail`, which is not
  POSIX; calling them as `sh` overrides their own shebang. Whether the suite
  then works is decided by the runner image: macOS `/bin/sh` is bash, clementine
  has dash 0.5.12 which *grew* `pipefail` in 2022, and the GitHub runner's dash
  rejected it — `set: Illegal option -o pipefail` — failing four steps at once.
  Reproduce the class of bug with a stand-in `sh` on PATH that reads its script
  argument and rejects `pipefail`; the suite must pass, and reverting the five
  call sites to `sh` must make it fail.
- **A generated file that gets committed must not carry the generating machine's
  paths.** `translate-c` stamps the absolute path of the Zig installation into
  its diagnostic comments — 1,384 of them in the aarch64-macos file — so
  `regen-c.sh --check` reported src/c.zig "stale" on every host but the
  author's, on a diff of provenance rather than declarations. Same class as the
  missing `-target` (Xcode SDK paths), one level further out. `regen-c.sh` now
  rewrites the toolchain prefix to `<zig-install>` on `//` comment lines only;
  do not let a future "simplify" drop that step, and do not widen it past
  comments, where a path could turn out to be load-bearing.
- **`run: "$ZIG" build check` is a YAML syntax error, not a shell one.** A
  `run:` value starting with a double quote parses as a quoted scalar and fails
  on the next token. GitHub then rejects the workflow *before scheduling
  anything*: zero jobs, no log, check suite `failure` in 0s — which reads like a
  permissions or billing problem and cost a debugging round. Single-quote the
  whole value: `run: '"$ZIG" build check'`.
- **`tools/regen-c.sh` with no mode flag overwrites `src/c.zig`**, inferring the
  target from `uname`. It replaced the macOS bindings with glibc ones in the
  old rsync `~/satori` on clementine; that tree is gone (see below). Always pass
  `--check` or `--gen`.
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
- **An rsync scratch tree on a verification host is a trap, because it goes
  stale silently and then certifies the wrong code.** `~/satori` on clementine
  was rsynced and documented as "commit locally before syncing". It was last
  synced before `COMMITTED_C_TARGET` existed and before `AGENTS.md`/`MEMORY.md`
  did, so it held a 2,743-line glibc `src/c.zig` instead of the committed
  12,061-line aarch64-macos one — and every "green check on Linux" quote from it
  was vacuous: pre-fix code, wrong bindings, and no way to tell, because a
  scratch tree has no commit to compare against. **`~/satori` is now a plain
  `git clone` of the public repo** (which is also what CI does, so the local and
  CI Linux results are the same measurement), and unpushed work goes to a
  *separate* `~/satori-wip` by rsync so the trustworthy tree stays trustworthy.
  Generalisation: a verification host must be pinned to a **commit**, and
  `git status` on it must be clean before a green result means anything.
  `~/satori-rsync-stale` (the old tree) and `~/satori-citest` /
  `~/satori-ci-dryrun` also exist there as scratch; ignore all three.
- **No `~/.ssh/config` entry for `clementine`**; it resolves by other means.
  Don't go looking for one.

OpenSpec tooling:

- **Never hand-edit `.opencode/skills/` or `.opencode/commands/`** — they are
  generated, and `openspec update` (or a re-init) regenerates them, silently
  discarding edits. Project contracts belong in `openspec/config.yaml`
  (`context:` and `rules:`), which is the only file init writes once and never
  owns again. Same species as letting `regen-c.sh` infer its target.
- **`openspec validate --strict` alone validates nothing and exits 1** in a
  non-interactive terminal: it prints "Nothing to validate" and the usage
  hint, which reads like a failed validation. Always name the target —
  `openspec validate --all --strict` (or `--specs` / `--changes`).
- **`context:`/`rules:` in `openspec/config.yaml` are injected prose, not
  enforced rules.** `--strict` validates artifact *structure* (headers,
  scenario form); the cite-don't-duplicate rule, the budgets, and the
  verify-with-passing-meaning contract are honored only if the artifact
  author follows them — a reviewer still checks them at propose time. A rule
  that looks enforced because it sits next to a validator is the same
  failure mode as a check that cannot fail.

Correctness, all of which shipped as silent wrong answers rather than crashes:

- **A wrong hand-written `extern struct` compiles fine and returns garbage.** 2
  of 2 attempts were wrong: `struct statfs` (assumed 1,104 bytes with `f_fsid`
  last; actually 2,168 with `f_fsid`@48, `f_flags`@64, `f_fstypename`@72) and
  `vm_statistics64_data_t` (assumed 15×`u64`; actually 416 bytes).
- **"416 bytes = 52×`natural_t`" was itself wrong, and this file said so for a
  day.** Measured with `tools/gt.c` on 2026-10-05: 52×`natural_t` is 208, not
  416. The truth is 416 bytes = 104×`natural_t` = 52×8-byte slots, holding **57
  named fields of mixed width** — the first five are `natural_t` (u32, 4-byte
  stride: offsets 0, 4, 8, 12, 16) and the remaining 52 are 64-bit (8-byte
  stride, from `reactivations`@24 to `phantom_ghosts_added`@408), with
  *unnamed reserved gaps at 20, 100 and 148*. So neither the size nor the field
  count can be derived from the other, which is why the hand-written version was
  wrong twice over. `HOST_VM_INFO64_COUNT` = 416/4 = **104** was right all along;
  only the explanation attached to it was not.
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
  or a clean CI runner races on files left over from a previous run. The same
  rule caught the negative control: it runs its own `zig build-obj` rather than
  consuming a build-graph artifact, so nothing in the graph implied it had to
  wait for `zig-out/bindings/`, and it lost the race on a clean tree.
- **`regen-c.sh` defaults Linux to gnu, not musl.** Defaulting to musl produced
  bindings that disagreed with the linked libc (1,292 vs 2,743 lines) and failed
  `test/layout.zig` with `struct_statvfs` missing.
- **A CI check that has only ever run on the author's machine has not been
  tested.** Every one of the four host-dependent landmines above passed on
  macOS *and* on clementine and failed only on the runner. Run the gate on a
  second machine — or simulate the hostile condition — before believing it.
- **A golden test must not let its fixture impersonate a platform.**
  Step 2's Linux arm claimed `Memory: unavailable`, reasoning that "Linux has no
  memory source yet", so the fixture should look like a real Linux `load()`.
  That was wrong and **only clementine found it** — 15/19 there, 19/19 on macOS,
  because on macOS the `.macos` arm is the only one that exists to disagree.
  `render()` is a pure function of its argument, so if the argument carries
  memory it prints memory, on every platform; "Linux gathers no memory" is a
  claim about `load()`. The fixture now feeds identical data to both arms and
  they differ only where a field's *source* differs by platform (the OS row).
  A platform-dependent expectation is a place to hide a fact about the wrong
  layer. Fixed in `702387a`.
- **`gh run watch` exits 0 on a cancelled run.** `concurrency:
  cancel-in-progress: true` cancels the run for a push when a second push
  arrives, and GitHub reports the cancelled run as a red `failure`. There is no
  log to read, and a cancelled job has **no steps at all**, which is how to tell
  it from a real failure (a real failure has one step with a failing
  conclusion). Re-run with `gh run rerun` and watch the conclusion, not the
  watcher's exit code.

## Open

- **Colour blocks and bars were deliberately not built in step 2, and are step
  5's problem.** The plan line ("label colouring, colour blocks, alignment/
  padding, bars") predates the fields, and no field today can justify a bar: the
  only row with a ratio is Memory, and on Linux it has no source yet (step 4), so
  a bar would appear on one platform only — decoration that changes output for no
  field's benefit. Colour blocks belong with the logo engine: in neofetch they
  are part of the logo art, so building them before `logos/data/` has anything in
  it means choosing a palette step 5 will replace. Alignment and label colouring
  *were* built, and both are in. Recorded so this reads as a decision.
- **The golden tests pin both platform arms from one fixture, and that has a
  limit.** `Shared` is filled with synthetic values, so the arms differ only in
  the OS row. This is deliberate — the point is to pin `render()`, not
  `load()` — but it means no test covers whether the two platforms' `load()`
  produce a `Shared` the renderer can actually use. Step 4's Linux parity is
  where that becomes observable, and the honest test for it is running the
  binary, not a unit test. `tools/gt.c` does not help here; there is no new
  struct involved.
- **`test/layout.zig` asserts a subset of what `tools/gt.c` now measures.** The
  tool is complete; the test is a chosen subset of what satori depends on.
  Unasserted but already measured, and read by `linux.zig`: `struct sysinfo`
  (112 bytes, `mem_unit`@104, `__f`@108) and `struct dirent` (280 bytes,
  `d_name`@19). Also unasserted: `time_t`/`clock_t` on both platforms, and
  `fsid_t`/`fsblkcnt_t`/`fsfilcnt_t` on macOS. Adding them is cheap and is the
  obvious next use of the tool.

- **`README.md` does not exist**; deferred to step 6 so it does not have to claim
  parity it does not have. Its absence on a public repo is expected.
  `LICENSE` exists (MIT + attribution) and `AGENTS.md` is the entry point for
  anyone arriving cold — the MIT attribution obligation is currently satisfied
  by `LICENSE` alone and must be repeated in the README when it is written.
- **The CI perf threshold is a placeholder, not a measurement.** 25 ms was chosen
  with zero runner data; eight runs later the medians span 0.433–1.004 ms and
  the maxes reach 4.032 ms, so it still catches only catastrophic regressions.
  `SATORI_STARTUP_GATE_US` is the knob.
- **`tools/gt.c` is not wired into `zig build check`, on purpose.** It is a
  maintainer tool like `tools/regen-c.sh`. Making it a gate would tie every push
  to whatever `cc` and libc the CI runner image ships, which is a different
  measurement from the pinned Zig toolchain everything else is verified against.
  Worth revisiting *if* the runner image is pinned (`ubuntu-24.04`), at which
  point the gate is against a known libc rather than whatever is newest.
- **`tools/check-no-fork.sh`'s embedded probe still hardcodes `-Mc=src/c.zig`.**
  Harmless today — it is macOS-only, and on the declared target that file is
  correct — but an x86_64-macos host would build the probe against the wrong
  bindings. Pass the resolved bindings path if that host ever matters.
- Plan §18 open questions are still open: whether to keep `--ascii_distro` as a
  hidden `--logo` alias, logo art fidelity (byte-for-byte migration vs
  re-normalising all 269 — settle at step 5, not now), and whether to ship
  cross-compiled release binaries.
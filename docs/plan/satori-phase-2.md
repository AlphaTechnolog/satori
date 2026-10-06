# satori — phase 2: repo, CI, and the renderer-first order

**Written 2026-10-05.** This supersedes the *ordering* in
`satori-rewrite.md` §15. All the research, measurements and rationale in
`satori-rewrite.md` (in this directory) still stand; only the sequence
changes, plus three decisions that were not in it.

Read that first, then this. Durable findings live in `MEMORY.md` in the repo.

---

## 1. Decisions taken 2026-10-05

### 1.1 Renderer first, then fields

The master plan ordered *all macOS fields → renderer*. Reversed.

The renderer is field-count-agnostic. The registry, colour blocks, alignment,
label colouring, bars and the logo column are all independent of how many fields
exist. Building it against the 6 fields that already work means fields 7–17 are
mechanical additions instead of a second round of ad-hoc inline rendering.

The shape is already proven — plan §14 specifies `fn (*Shared, *Out) bool` and 6
fields use it. The risk of building the renderer first is low and the cost of
building it last is a rewrite.

Corollary: **`render()` currently has no test at all.** The renderer's golden
tests are pure-function work and ship *with* the renderer, not at the end.

### 1.2 Linux parity before logos

Also a deviation from §15, which put logos at milestone 3.

Logos are bulk and mechanical, and a renderer change forces a redo of all 269.
Linux parity is the actual risk — `/proc` variance across kernels, and a
hand-rolled X11 protocol for Resolution — and it is what makes the central claim
("fast on both platforms") true rather than half-true. Risk and momentum first,
bulk last.

### 1.3 Licence: MIT, with attribution

**Verified 2026-10-05 from the neofetch checkout:** neofetch is MIT, not GPL.
`LICENSE.md` is 21 lines of "The MIT License (MIT), Copyright (c) 2015-2021
Dylan Araps", the README badge agrees, and the 11,592-line `neofetch` script
carries the same header inline at lines 9–26.

That matters because all ~6,000 lines of logo art live inside that MIT-licensed
script. There is no inherited copyleft obligation and no GPL-2.0-vs-3.0
compatibility question.

MIT chosen because: nothing forces copyleft; it is what the successor ecosystem
uses (fastfetch is MIT) and being license-compatible with the tool satori
replaces is worth more than voluntary copyleft; and it matches the project's
existing zero-dependency, hermetic posture. Apache-2.0 was considered and
rejected — NOTICE propagation is compliance surface for no gain in a 2,000-line
CLI.

Two obligations, both now carried in `LICENSE`:

- **Attribution is required by MIT**, not optional courtesy. The art's origin is
  credited explicitly. Repeat the credit in `README.md` when that is written.
- **MIT does not license trademarks.** Several logos are registered marks of
  their owners. This is the same exposure neofetch and fastfetch both carry
  unaddressed; a README note is the cheap honest mitigation.

Also included: a non-affiliation line, so satori does not imply neofetch's author
endorses it.

Not legal advice. Low-stakes for a solo project, but get a real opinion before
accepting outside contributions or relicensing.

### 1.4 Milestone 1 target: the 17 neofetch defaults

§15 said "all 20 default fields", which conflicts with the 17 that
`print_info` actually prints. M1 is measured against the **17**. Anyone counting
to 20 will think they are done when they are not.

### 1.5 Deferred

- **GPU in/out of M1's 17.** Deferred by decision, because GPU is the one field
  that forces a design decision rather than just code (below).
- **CI workflow, GitHub repo, push** — authorised by the user, not yet built.
  Step 0 below.
- **`README.md`** — deferred until the CLI surface freezes. A README written
  now would either claim parity (false) or be an apology.

---

## 2. Verified facts that shaped this plan

All re-verified 2026-10-05, not recalled.

**A single Linux runner can run the entire gate suite.** `zig build check` exits 0
on clementine, which includes `regen-c.sh --matrix` generating macOS bindings
from a Linux host. Separately confirmed: a Linux host links Mach-O — a trivial
program built with `-target aarch64-macos` on clementine reports
`Mach-O 64-bit arm64 executable` from `file`.

So CI needs **no macOS runner**. That removes the macOS-minute multiplier
entirely and makes the "unless it's paid" concern moot; public repos get free
Actions on any plan.

**`gh` is authenticated** as `AlphaTechnolog` with `repo` + `workflow` scopes, so
creating a public repo, pushing and adding a workflow are all writable.

**`zig` on PATH is 0.16.0 and the build fails with it.** CI must install
0.17.0 explicitly, not "whatever is latest".

**New landmine:** `translate-c` has no output-file flag *and* rejects
`/dev/stdin` ("unrecognized file extension"). It always needs a real input path
and a redirected stdout. Confirms the existing rule in both directions.

---

## 3. Steps

### Step 0 — repository, licence, CI

Create a public GitHub repo, push, add `.github/workflows/ci.yml` running
`zig build check`.

- **Decide visibility before the first push.** Publishing is the irreversible
  step. With the licence now decided this is no longer a blocker.
- **Install Zig 0.17.0 in CI by pinned official tarball + SHA256**, not the
  third-party `ziglang/setup-zig` action. A digest pin is more consistent with
  the hermetic thesis and `build.zig.zon` already pins `minimum_zig_version`.
  Obtain the real SHA256 from ziglang.org; do not invent it.
- **Perf gate threshold is the one genuinely flaky step.** We measure 1.400 ms on
  Linux against a 3.5 ms gate — 2.5× headroom — but a shared 2-core runner's
  median-of-200 is not the same measurement as dedicated hardware. Recommended:
  keep 3.5 ms as the *local* gate, and on CI report the number always while
  blocking only on a much higher CI-only threshold. Plan §14's concern is that a
  perf claim nobody measures rots; reporting always satisfies that without
  producing flaky red builds. Tighten to a real blocking gate once a distribution
  of runner numbers exists.
- Once CI exists, `build.zig.zon`'s `.paths` should list whatever is added.

### Step 1 — unblock the layout test, drop the fake flag

Small, and both items are prerequisites for step 3.

- **Write `tools/gt.c`.** `test/layout.zig` — the most important test in the
  project — documents its ground-truth procedure as `cc -O2 tools/gt.c -o gt &&
  ./gt`, and that file does not exist. Every new struct needs measured ground
  truth; without the tool each one means an ad-hoc throwaway C file. Needs to
  print `@sizeOf` and `@offsetOf` for every struct in `src/c.h`, per target.
- **Remove `--no-color` from `usage`.** It is advertised and silently does
  nothing; `render()` ignores `opts.disable_color`. Delete the flag from the help
  text now, implement it properly in step 2. Do not thread a boolean through
  `render()` in this step — that function is about to be rewritten.

### Step 2 — field registry + renderer, golden-tested

The core of the reordering. Driven by the existing 6 fields.

- Comptime field registry: an array of `{ name, fn, needs }` per plan §14.
- Label colouring, colour blocks, alignment/padding, bars.
- **Implement `--no-color` here**: a `color: bool` on `buf.Buf` with an early
  return in `sgr()`. One field, no call-site changes, one predictable branch,
  and the flag becomes real for free.
- **Golden tests land here, not at the end** — the formatter/alignment layer is
  pure functions and is cheap to test now.

### Step 3 — macOS fields through the registry, to 17

- **First, the free win:** `cpuBrand`, `coreCount`, `threadCount`, `hwModel` are
  already implemented in `src/platform/macos.zig` and unused. Wire them into
  `render()`. ~30 lines, near-zero risk, 6 → 10 fields.
- Then: Terminal, Terminal Font, Resolution, DE, WM, Theme, Icons, Host, GPU.

**M1 is bigger than it looks.** Two of the 17 are known to be expensive or
risky:

- **Packages** — a `dpkg status` scan measured 1.0–1.2 ms. Fits inside 3.5 ms
  but is the single largest data-gathering cost by an order of magnitude over
  everything else measured so far (total is 8 µs). Needs the
  `$XDG_CACHE_HOME/satori/packages` cache keyed on mtime+size.
- **Resolution** — needs a new struct (`struct winsize` for the terminal column
  via `TIOCGWINSZ`, and whatever the macOS display route turns out to require).
  Hence step 1's `gt.c`.
- **GPU — the design-decision field.** IOKit runs through CoreFoundation types
  that `translate-c` handles poorly, and `mach/mach.h` is already known to fail
  translation outright. Plan §17 rates it high risk. This is why GPU's inclusion
  is deferred rather than assumed: if it forces a design decision, M1 should be
  allowed to ship without it rather than stall.

### Step 4 — Linux parity

`/proc` readers already exist (`cpuModel`, `totalMemory`, `freeMemory`). Needs
Packages, Resolution via hand-rolled X11 over `/tmp/.X11-unix/XN`, DE, WM.

Layout ground truth for every new struct, measured on clementine, using
`tools/gt.c` from step 1. **This is the step `gt.c` exists for.**

### Step 5 — logos

`migrate_logos.py` + 269 `.art` files, `includeBytes`d at comptime.

Highest-volume, highest-risk-by-volume step, and it cannot all be eyeballed.
Requires automated comptime width/height assertions per logo plus `--logo`
spot-check renders. Plan §18 question 2 (byte-for-byte migration vs
re-normalising all 269) is still open and should be settled here, not now.

### Step 6 — surface freeze

CLI flags + `--json` + `--plain` (§13), TOML config subset (§12), opt-in
paths (disk, battery, package edge cases, song, publicip), end-to-end golden
tests, then `README.md`.

`--json` defines the field registry's output contract, so it belongs *after*
the field set is known — freezing the contract first would mean freezing it
twice.

---

## 4. Still open

- **CI perf-gate threshold** and **Zig install method** — recommended above,
  needs a yes.
- **Logo art fidelity** (master plan §18.2): migrate byte-for-byte (inherits
  neofetch's `\`-escaping and width bugs) or re-normalise all 269 while verifying
  alignment? Settle at step 5.
- **GPU** — deferred (1.5).
- **Cross-compiled release binaries** (master plan §18.3) — still a release
  question, not a blocker.
# Design — wire-macos-free-win

## Context

The registry is a comptime array of `{ label, color, fmtFn }` (`src/render.zig:99`)
and is the only code that emits rows, in array order. `render()` is a pure
function of `*const shared.Shared` by invariant (`src/render.zig:9`), and every
live syscall was moved into `Shared.load()` for exactly that reason
(`src/shared.zig:98`). The four macOS sources already exist and are unused
(`src/platform/macos.zig:136,141,146,153`). Goldens pin exact bytes on both
platform arms (`src/render.zig:293,347,376,402,417`). The plan's target is
neofetch's 17 defaults in phase-2 order (plan §Step 3). `MEMORY.md` §Measured
holds the startup figures this change's gate run is compared against.

## Goals / Non-Goals

**Goals:** render `Host` and `CPU` from already-gathered data, with the same
alignment, colour and `unavailable` semantics as every other row, and seed the
`fields` capability.

**Non-Goals:** every other row, row relocations, CPU speed, and Linux sources —
the proposal's Out list.

## Decisions

### D1 — Where do the two new rows sit in the registry order?

**Recommend:** `Host` immediately after `OS`; `CPU` in the trailing hardware
group, immediately before `Memory` (`src/render.zig:99`).

**Why:** the target order is `OS, Host, Kernel, ...` and `..., CPU, GPU, Memory`
(plan §Step 3). `Host`'s final neighbour is `OS`, so it never moves again; `CPU`
before `Memory` is the order later changes preserve by inserting `GPU` between
them, so neither row is reordered twice.

**If you disagree:** append both at the end — smallest diff now, but every later
change then moves both and churns the goldens a second time.

### D2 — What does the CPU row print, and from which of the two core counts?

**Recommend:** `"<brand> (<logical cores>)"` — `machdep.cpu.brand_string`
(`src/platform/macos.zig:141`) plus `hw.logicalcpu` (`:153`). No clock speed.

**Why:** neofetch's default is `cpu_cores="logical"` (`~/repo/neofetch/neofetch:286`)
and its macOS row is `brand (cores)`. On this Apple Silicon host physical equals
logical (measured 2026-10-06: `sysctl hw.physicalcpu hw.logicalcpu` → `8 8`), so
the choice is unobservable here and differs only on Intel Macs with SMT, where
neofetch itself prints logical. Speed is a fifth sysctl, not among the four
sources the plan lists (plan §Step 3).

**If you disagree:** print physical (`coreCount`) — identical output on Apple
Silicon, but diverges from neofetch on Intel.

### D3 — Is the Host value the raw `hw.model` or a marketing name?

**Recommend:** the raw identifier, e.g. `MacBookAir10,1`.

**Why:** `hwModel` returns exactly `hw.model` (`src/platform/macos.zig:136`).
neofetch maps identifiers to marketing names with a lookup table satori does not
ship, and feature-compliance allows the identifier (plan §Step 3 asks only to
wire the function).

**If you disagree:** add a lookup table — its own change, with its own data to
source, version and keep current.

### D4 — How is absence encoded for the two rows?

**Recommend:** `Host` → `unavailable` when the model string is empty; `CPU` →
`unavailable` when the brand is empty; otherwise `CPU` is the brand alone when
the logical count is 0, else `"brand (n)"`.

**Why:** `core-invariants` makes `unavailable` the encoding for a missing source,
and the fixture-fed renderer must produce identical bytes on both arms
(`openspec/config.yaml` §specs). A bare `(0)` would fabricate a count, which the
same capability forbids.

**If you disagree:** omit the row — rejected, because it hides that the row
exists rather than reporting the absence (`openspec/specs/core-invariants/spec.md`).

### D5 — Does row-set/order intent live in a new `fields` capability or in `rendering`?

**Recommend:** a new `fields` capability; leave `rendering` untouched.

**Why:** `openspec/specs/rendering/spec.md:11` specifies the *mechanism* — one
emitter, padding derived from the registry. Which rows exist is a different
question on a different cadence (four changes grow it), so mixing them means each
row addition MODIFIES the spec that describes the emitter.

**If you disagree:** add the requirements to `rendering` — one fewer file, but row
churn then rewrites the mechanism spec every time.

### D6 — Where do the gathered values live, and when are they read?

**Recommend:** three fields on `Shared` (`hw_model: Str`, `cpu_brand: Str`,
`cpu_threads: u64`), filled in `load()`'s macOS branch beside `os_version`
(`src/shared.zig:109`); `render()` reads only `Shared`.

**Why:** `src/shared.zig:98` records that `osVersion` and `vmStats` were moved
out of `render()` precisely because a live syscall bakes the machine into a
golden test. A second read site would reintroduce that, and `MEMORY.md` §Measured
records the cost of a sysctl on the startup path.

**If you disagree:** call the sources inside the formatters — breaks golden
determinism, which is the invariant `src/render.zig:9` states.

### D7 — Is `coreCount()` (physical) wired in this change?

**Recommend:** no; it stays implemented-but-unused.

**Why:** the row prints logical (D2), so gathering physical would be a sysctl per
run for no consumer. The function already exists and costs nothing unwired
(`src/platform/macos.zig:146`); a later topology row can use it.

**If you disagree:** gather it and print `(4c/8t)` — notation no neofetch user
expects and no source for it in this change.

## Risks / Trade-offs

- The Linux golden gains two `unavailable` rows → expected and stated in the
  proposal's Out list; both arms' literals are updated in the same commit.
- `LABEL_COLON_WIDTH` must stay 7 (`Kernel`/`Memory`/`Uptime` remain longest), so
  existing rows' padding is untouched → asserted by the derived-width test at
  `src/render.zig:410`.

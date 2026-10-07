# wire-macos-free-win

Wire the four already-implemented-but-unused macOS data sources (`hwModel`,
`cpuBrand`, `coreCount`, `threadCount`) into two registry rows — `Host` and
`CPU` — starting from commit `e5717a3`.

## Read first

1. `docs/plan/satori-phase-2.md` §Step 3 — the "free win" this change is, the
   17-row target, and the row list it splits from.
2. `src/platform/macos.zig` §hwModel–threadCount — the four sources; already
   implemented, currently rendered by nothing.
3. `src/shared.zig` §Shared/load — where a gathered value is carried and filled
   once; `os_version` is the shape to copy.
4. `src/render.zig` §fields, §fixture, §golden tests — the comptime registry that
   is the only row emitter, and the literals that move with it.
5. `openspec/specs/rendering/spec.md` — the mechanism this change must leave
   intact.

## Why

The four macOS data sources already exist and compile, but no formatter reads
them, so the report stops at 6 rows and omits the hardware identity (`hw.model`)
and the CPU description a user opens a fetch tool for. This is the plan's free
win: ~30 lines, no new dependency, no new C binding, both invariants untouched —
and it is the seam the remaining M1 rows hang off, so the `fields` capability it
seeds is what later changes extend.

## What Changes

- [N] Two registry rows: `Host`, immediately after `OS`; `CPU`, in the trailing
  hardware group immediately before `Memory` (`src/render.zig:99`).
- [N] `Host` value = the hardware model identifier (`src/platform/macos.zig:136`).
- [N] `CPU` value = `"<brand> (<logical core count>)"` from
  `machdep.cpu.brand_string` and `hw.logicalcpu` (`:141`, `:153`).
- [N] Three fields carried on `Shared` and filled once in `load()`'s macOS
  branch (`src/shared.zig:31`, `:109`); `render()` stays a pure function.
- [N] New capability `fields`: which rows exist, their order, and each row's
  source; its requirement set grows in later changes.
- [O] The plan's "6 → 10 fields" overcounts: four sources feed two rows, so this
  change lands at 8; `coreCount()` (physical) stays unused (design D2/D7).
- [O] On Linux both rows read `unavailable` until step 4 gathers sources; the
  fixture-fed renderer still produces identical bytes on both platform arms.
- **BREAKING**: none.

## Non-Goals

**In:** the two rows, the `fields` capability, and updated goldens on both arms.

**Out:**
- The other M1 rows — `Terminal`, `Terminal Font`, `Resolution`, `DE`, `WM`,
  `Theme`, `Icons`, `GPU` (plan §Step 3 "Then: ...").
- Relocating `Shell` and inserting `Packages` (plan §Step 3; its own change).
- CPU clock speed — not among the four sources (plan §Step 3).
- Linux sources (plan §Step 4); logos (plan §Step 5); CLI/`--json` (plan §Step 6).

## Capabilities

### New Capabilities
- `fields`: the report's row set, their order, and the source each draws from —
  the surface later M1 changes add rows to.

### Modified Capabilities
- None: `rendering` describes the registry mechanism, which is unchanged; row
  emission and `unavailable` stay as `rendering` and `core-invariants` define
  them.

## Impact

`src/render.zig` (two formatters, two registry entries, fixture, four goldens),
`src/shared.zig` (three fields, one fill site). `src/platform/macos.zig` is read
only. New spec `openspec/specs/fields/spec.md`. No dependency, framework,
allocation, fork, or C binding is added, so the size and no-fork gates are
unaffected apart from the rows' bytes.

## 1. Baseline and safety

- [x] 1.1 `git rev-parse --short HEAD` prints `e5717a3` and `git status --short` shows nothing under `src/`; stop otherwise.
- [x] 1.2 `$ZIG build check` exits 0 on macOS before any edit, so a later failure is this change's.

## 2. Specification

- [x] 2.1 `openspec validate wire-macos-free-win --strict` exits 0, and `specs/fields/spec.md` names the 8-row order the registry will hold.
- [x] 2.2 Re-read the delta: every scenario's THEN is an exact string or byte observation, none says "correctly", and none restates a golden literal verbatim.

## 3. Implementation

- [x] 3.1 `src/shared.zig`: add `hw_model: Str`, `cpu_brand: Str`, `cpu_threads: u64 = 0` to `Shared` (`:31`), documenting `cpu_threads == 0` as the absence encoding, as `mem.total` is at `:48`.
- [x] 3.2 `src/shared.zig` `load()` macOS arm (`:110`): fill the three from `macos.hwModel`, `macos.cpuBrand`, `macos.threadCount`, reusing the existing `scratch` (`Str.set` copies, so one buffer is enough).
- [x] 3.3 `src/render.zig`: add `host` and `cpu` formatters; each writes into the passed `scratch` and never touches `out` (the ordering hazard at `:22`).
- [x] 3.4 `src/render.zig:99`: insert `.label = "Host"` after `OS` and `.label = "CPU"` immediately before `Memory`, both `.color = palette.identity`.
- [x] 3.5 Leave `coreCount()` unwired and `src/platform/macos.zig` unedited (D7).

## 4. Verification

- [x] 4.1 `src/render.zig` fixture (`:270`) sets the three new fields; update the label-order test (`:402`) to the 8-label array and fix its "6 labels" comment.
- [x] 4.2 Update by hand, not by copying program output, the four byte literals: default golden (`:293`, both arms), missing-memory (`:347`), every-source-absent (`:376`), `--no-color` (`:417`, both arms); `--no-color`'s escape count stays 0.
- [x] 4.3 `$ZIG build check` exits 0 on macOS, startup gate included; the derived-width assertion (`:410`) still passes with `LABEL_COLON_WIDTH` unchanged at 7.
- [x] 4.4 On clementine, clone the pushed SHA into a clean `~/satori` per AGENTS.md §Commands (never rsync over it) and run `~/.local/opt/zig-x86_64-linux-0.17.0/zig build check`; exits 0, with `Host: unavailable` and `CPU: unavailable` in the Linux golden.
- [ ] 4.5 Push to `main`, watch the CI run to its conclusion, and report the run URL and conclusion (not `gh run watch`'s exit code).

## 5. Handoff

- [ ] 5.1 Report per contract: commits and the decision each embodies; D1-D7 answers with every override flagged; verify table with both hosts' exit codes and the CI run URL; bench/test-count before-and-after where applicable; anything no D asked about
- [ ] 5.2 MEMORY.md updated in this change for every new measurement, landmine, decision, or rejected approach — dated, with conditions; claims that stopped being true are deleted, not annotated
- [ ] 5.3 `openspec validate --all --strict` exits 0
- [ ] 5.4 Archive only after both hosts were green, or the report says explicitly why not; then replace the generated `fields` Purpose stub with the capability's purpose

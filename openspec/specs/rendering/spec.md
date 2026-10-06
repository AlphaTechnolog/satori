# Rendering Specification

## Purpose

How satori turns gathered data into output: one comptime field registry is the
only code that emits rows, `render()` is a pure function of its argument so the
exact bytes are golden-tested on both platforms, and colour is all-or-nothing.

## Requirements

### Requirement: The field registry is the only code that emits rows

Every output row SHALL be emitted through the comptime field registry in
`src/render.zig` (via `Buf.field`), and the label column width SHALL be derived
at comptime from the registry rather than hardcoded. There is exactly one row
emitter in the program.

#### Scenario: Every row has the registry's shape and alignment

- **WHEN** satori renders with default arguments
- **THEN** every row reads `Label: value` with labels aligned to one column
  whose width is the widest registered label, and no row is composed by hand
  outside `Buf.field`

#### Scenario: Adding a field is a registry entry plus a formatter

- **WHEN** a new field is added to the registry
- **THEN** no new row-emission code exists, and labels longer than today's
  still align because the column width derives from the registry at comptime

### Requirement: `render()` is a pure function of `Shared`

`render()` SHALL perform no system calls and read nothing but its
`*const shared.Shared` argument; all live gathering happens in
`Shared.load()`. This is what makes the golden tests portable: a golden test of
a renderer that calls syscalls would bake in whichever machine ran it.

#### Scenario: Golden tests pass on both platform arms from one fixture

- **WHEN** the golden tests run on macOS and on Linux
- **THEN** both arms pass, fed identical synthetic `Shared` data, and the arms
  differ only where a field's source differs by platform (the OS row) — platform
  variance belongs to `load()`, not to the renderer

### Requirement: A value never renders before its own label

Formatters SHALL write into a separate buffer before the registry emits the
row, so evaluation order cannot place a value ahead of its label.

#### Scenario: No value fragment precedes its label

- **WHEN** any rendered output is read
- **THEN** every row reads `Label: value` with no fragment of a value appearing
  before its label — the `50sUptime: 50s` failure class cannot occur

### Requirement: `--no-color` suppresses every escape sequence

When `--no-color` is given, satori SHALL emit zero ANSI escape sequences over
the entire output. `Buf.sgr()` is the only code in the program permitted to
produce an escape sequence, which is what makes the flag total.

#### Scenario: No escapes reach the output, anywhere

- **WHEN** `satori --no-color` is piped through `grep -c $'\033'`
- **THEN** it prints `0` over the whole output, not a fragment of it

#### Scenario: Colour remains the default

- **WHEN** satori runs without `--no-color`
- **THEN** label colouring is present, verified by `satori | cat -v` showing
  escape sequences around labels

### Requirement: Golden expectations pin intended output, not produced output

Golden expectations SHALL be inline literals in the test file, annotated with
each line's origin, and never generated from the program's own previous output
or read from disk at test time.

#### Scenario: A golden expectation cannot ratify a bug

- **WHEN** the golden tests are read
- **THEN** expectations are hand-reconciled literals describing the intended
  text, so wrong output fails the test instead of silently updating it

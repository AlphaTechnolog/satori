# Fields Specification

## Purpose

Which rows satori's report contains: their order, the data source behind each,
and how absence is expressed per row. How a row is emitted — alignment, colour,
the single label writer — is `rendering`'s; what `unavailable` means for a
missing source is `core-invariants`'. The target is neofetch's 17 defaults in
phase-2 order (plan §Step 3); the requirements below state only the rows that
exist as each change lands.

## ADDED Requirements

### Requirement: The report renders a fixed row set in a fixed order

satori SHALL render exactly the rows `OS`, `Host`, `Kernel`, `Arch`, `Shell`,
`Uptime`, `CPU`, `Memory`, in that order, one `Label: value` line each, and SHALL
add rows only through the comptime registry (`src/render.zig:99`).

#### Scenario: Rows appear in the registered order

- **WHEN** the report renders
- **THEN** reading the label column top to bottom yields exactly
  `OS`, `Host`, `Kernel`, `Arch`, `Shell`, `Uptime`, `CPU`, `Memory`

### Requirement: The Host row reports the hardware model

satori SHALL render a `Host` row, immediately after `OS`, whose value is the
hardware model identifier carried on `Shared`. On macOS the platform layer fills
it from `hw.model` (`src/platform/macos.zig:136`); Linux carries no value until
step 4.

#### Scenario: Host carries the gathered model identifier

- **WHEN** the report renders with a hardware model identifier on `Shared`
- **THEN** the line immediately after `OS` is the `Host` row and its value is
  exactly that identifier

#### Scenario: A missing hardware model is reported

- **WHEN** `Shared` carries no hardware model identifier
- **THEN** the `Host` row's value is `unavailable` and no other row changes

### Requirement: The CPU row folds brand and logical core count into one value

satori SHALL render one `CPU` row, in the trailing hardware group before
`Memory`, whose value is the CPU brand string followed by the logical core count
in parentheses. On macOS the platform layer fills both from
`machdep.cpu.brand_string` and `hw.logicalcpu` (`src/platform/macos.zig:141`,
`:153`). A zero logical count SHALL omit the parenthetical rather than print
`(0)`; an absent brand SHALL render `unavailable`.

#### Scenario: Brand and core count fold into one value

- **WHEN** the report renders with a CPU brand and a non-zero logical core count
- **THEN** the `CPU` value is the brand, a space, and the count in parentheses

#### Scenario: A zero core count is not printed

- **WHEN** a CPU brand is present but the logical core count is zero
- **THEN** the `CPU` value is the brand alone, with no parentheses

#### Scenario: A missing CPU brand is reported

- **WHEN** `Shared` carries no CPU brand
- **THEN** the `CPU` value is `unavailable`

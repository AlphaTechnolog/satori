# CLI Specification

## Purpose

satori's user-visible surface: the flags it accepts, what usage prints, and the
guarantee that an advertised flag is a working flag. The founding example is
`--no-color`, which was removed from usage while inert and re-advertised only
once it did something.

## Requirements

### Requirement: Usage advertises only flags that work

A flag SHALL appear in `satori --help` only if `parseArgs` handles it and its
effect is observable in the output. A flag that parses and does nothing is
worse than a flag that is rejected: a script passing it keeps running and
silently gets the wrong output.

#### Scenario: Every advertised flag has an observable effect

- **WHEN** usage is printed (`satori --help`) and each advertised flag is run
- **THEN** each is recognized by `parseArgs` and changes the output it promises
  — `--no-color` yields zero escapes, `--benchmark` yields the timing trailer,
  `-h`/`--help` yields the usage text

#### Scenario: `--no-color` is advertised and exit stays 0

- **WHEN** `satori --no-color; echo $?` runs
- **THEN** the exit code is `0`, so a passing script does not start failing

### Requirement: `--help` prints usage and renders nothing

`-h` and `--help` SHALL print the usage text and exit 0 without gathering data
or rendering fields.

#### Scenario: Help short-circuits the render pipeline

- **WHEN** `satori --help` or `satori -h` runs
- **THEN** the usage text is printed, no field rows appear, and the exit code
  is `0`

### Requirement: `--benchmark` appends timing diagnostics to normal output

`--benchmark` SHALL render the normal field rows unchanged and append the
timing trailer; it is diagnostic output, not a different render mode.

#### Scenario: Normal output plus trailer

- **WHEN** `satori --benchmark` runs
- **THEN** every normal field row is present, the timing trailer follows them,
  and the exit code is `0`

### Requirement: Unknown arguments are ignored

Arguments not listed in usage SHALL be ignored, producing normal output and
exit 0. Pinning this as behavior means changing it (rejecting unknown flags)
is a deliberate spec change rather than a side effect of an argument-parser
rewrite.

#### Scenario: An unrecognized flag does not disturb the output

- **WHEN** `satori --bogus` runs
- **THEN** the normal field rows render and the exit code is `0`

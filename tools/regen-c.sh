#!/usr/bin/env bash
# Regenerate or verify the C interop bindings for one target.
#
# WHY A SCRIPT AND NOT A BUILD STEP
#
# Zig 0.17 removed @cImport; C translation moved to an external package with "an
# independent release cadence". `zig translate-c` survives as a CLI and needs no
# package fetch, so it is used here as a maintainer tool.
#
# src/c.zig is COMMITTED, one file, for the native target, and is NOT generated
# during `zig build`, because a package-manager fetch at build time breaks distro
# packaging and air-gapped CI. CI runs this script with --check once per matrix
# target and fails if the pinned toolchain would produce anything different.
#
# FOUR NON-OBVIOUS RULES, EACH LEARNED THE HARD WAY
#
# 1. -target IS MANDATORY. Without it translate-c resolves the native target and
#    reads the *Xcode SDK* headers instead of Zig's bundled libc headers. The
#    generated code is functionally identical but every embedded header path in
#    a diagnostic comment changes, so the file stops being reproducible: it would
#    embed "/Applications/Xcode.app/.../MacOSX27.0.sdk" and differ per developer.
#
# 2. NEVER PIPE translate-c's STDOUT. Given a pipe it spins at 100% CPU forever
#    instead of exiting. Redirect to a file. (A `translate-c | fmt` pipeline
#    burned seven CPU-minutes before it was noticed.)
#
# 3. NEVER pipe through `zig fmt --stdin`. It hangs on input this large. Output
#    from translate-c is already canonically formatted, so verify with
#    `zig fmt --check`, which does not write and therefore cannot do damage.
#
# 4. THE TOOLCHAIN'S OWN ABSOLUTE PATH MUST BE NORMALISED OUT. translate-c
#    stamps the path of the Zig installation into its diagnostic comments, so the
#    raw output differs per machine. See the normalisation block below; without
#    it a committed src/c.zig can only ever be verified on one laptop.
set -euo pipefail

cd "$(dirname "$0")/.."

ZIG="${ZIG:-zig}"
HEADER="src/c.h"
COMMITTED="src/c.zig"

# Created before argument handling because --matrix re-enters this script and
# needs somewhere to put per-target logs.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

MODE="write"
TARGET="${SATORI_TARGET:-}"
OUT=""

# Resolve a default native triple from uname, never from zig's own native
# detection, for the reason in rule 1 above.
#
# Linux defaults to *gnu*, not musl. The host libc is the one whose headers the
# generated code must describe, and defaulting an unknown architecture to musl
# produced bindings that disagreed with the very libc the binary would link
# against — x86_64 Linux silently got musl's 1292-line bindings instead of
# glibc's 2743, which then failed test/layout.zig with struct_statvfs missing.
if [ -z "$TARGET" ]; then
  case "$(uname -s)" in
    Darwin)
      TARGET="aarch64-macos"
      [ "$(uname -m)" = "x86_64" ] && TARGET="x86_64-macos"
      ;;
    Linux)
      TARGET="x86_64-linux-gnu"
      case "$(uname -m)" in
        aarch64|arm64) TARGET="aarch64-linux-gnu" ;;
      esac
      ;;
    *)
      echo "FAIL: cannot infer a target for host $(uname -s); pass one explicitly" >&2
      exit 1
      ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --gen) MODE="gen"; shift ;;
    --matrix) MODE="matrix"; shift ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    --out) OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --target) TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done

# The matrix mode answers a different question from --check, and conflating them
# makes CI useless:
#
#   --check  "does the committed src/c.zig still match what this toolchain
#             generates?"  Only meaningful for the ONE target it was committed
#             for. Run on every target it reports "stale" every time, which is
#             correct but says nothing.
#
#   --matrix "does every supported target still translate cleanly and produce the
#             symbols we need?"  This is the real cross-compilation gate, and it
#             is the one CI runs on every push.
if [ "$MODE" = "matrix" ]; then
  matrix="${SATORI_MATRIX:-x86_64-linux-gnu aarch64-linux-gnu x86_64-linux-musl aarch64-macos x86_64-macos}"
  rc=0
  for t in $matrix; do
    printf '  %-20s ' "$t"
    if "$0" --gen "$t" >"$tmp/gen.log" 2>&1; then
      printf 'ok   %s\n' "$(grep -m1 '^generated' "$tmp/gen.log" | cut -d' ' -f2-)"
    else
      printf 'FAIL\n'; sed 's/^/      /' "$tmp/gen.log" | head -8; rc=1
    fi
  done
  echo
  echo "checking committed src/c.zig against its own target ($TARGET):"
  if "$0" --check "$TARGET" >"$tmp/chk.log" 2>&1; then
    echo "  ok: committed file is current"
  else
    sed 's/^/  /' "$tmp/chk.log"; rc=1
  fi
  exit $rc
fi

[ -f "$HEADER" ] || { echo "FAIL: $HEADER not found"; exit 1; }

# Rule 2: file redirection, not a pipe.
if ! "$ZIG" translate-c "$HEADER" -lc -target "$TARGET" >"$tmp/c.zig" 2>"$tmp/err"; then
  echo "FAIL: translate-c failed for $TARGET"
  sed 's/^/    /' "$tmp/err"
  exit 1
fi

# An empty file with exit status 0 is the exact failure mode of getting this
# script wrong, so check for it explicitly rather than trusting the exit code.
if [ ! -s "$tmp/c.zig" ]; then
  echo "FAIL: translate-c produced an empty file for $TARGET"
  exit 1
fi

# ---- normalise the toolchain's install path ----------------------------------
#
# translate-c annotates each warning it emits with the absolute path of the
# header responsible, inside a `//` comment. Those paths embed the *generating
# machine's* Zig installation directory — 1,384 of them in the aarch64-macos
# file, every one of the form `<zig-dir>/lib/libc/include/...`.
#
# Left in, the committed src/c.zig is byte-identical only on a machine whose Zig
# lives at the same absolute path, so `--check` calls the file "stale" everywhere
# else. That is not staleness: the diff is `/Users/.../lib/libc` versus
# `/opt/hostedtoolcache/.../lib/libc`, i.e. identical declarations with different
# provenance. It is the same class of leak as the missing -target in rule 1 (Xcode
# SDK paths) one level further out, and it is why a file that must be committed
# has to be normalised before it is committed.
#
# Only `//` comment lines are rewritten, deliberately. The path is diagnostic
# provenance rather than content; if it ever appeared in a declaration, replacing
# it would change the build instead of making it portable.
zig_exe="$ZIG"
case "$zig_exe" in
  */*) ;;
  *) zig_exe="$(command -v "$zig_exe")" ;;
esac
zig_dir="$(cd "$(dirname "$zig_exe")" && pwd -P)"
zig_dir_esc="$(printf '%s' "$zig_dir" | sed -e 's/[\\&|]/\\&/g')"
if ! sed "/^[[:space:]]*\/\// s|${zig_dir_esc}|<zig-install>|g" "$tmp/c.zig" >"$tmp/c.norm"; then
  echo "FAIL: could not normalise the toolchain path in the $TARGET bindings"
  exit 1
fi
mv "$tmp/c.norm" "$tmp/c.zig"

lines="$(wc -l <"$tmp/c.zig" | tr -d ' ')"
echo "generated $lines lines for $TARGET"

# Rule 3: verify formatting without writing.
if ! "$ZIG" fmt --check "$tmp/c.zig" >/dev/null 2>"$tmp/fmt.err"; then
  echo "FAIL: translate-c output for $TARGET is not canonically formatted:"
  sed 's/^/    /' "$tmp/fmt.err" | head -5
  exit 1
fi

# A silently truncated translation would compile on every target that does not
# reference the missing symbols and fail later, on someone else's machine.
missing=""
case "$TARGET" in
  *linux*)  req="struct_utsname struct_statvfs uname gethostname getenv clock_gettime sysconf write CLOCK_BOOTTIME" ;;
  *)        req="struct_utsname struct_statfs uname gethostname getenv clock_gettime sysconf write sysctlbyname" ;;
esac
for sym in $req; do
  grep -q "\b$sym\b" "$tmp/c.zig" || missing="$missing $sym"
done
if [ -n "$missing" ]; then
  echo "FAIL: bindings for $TARGET are missing required symbols:$missing"
  exit 1
fi
echo "ok: all required symbols present"

# --gen: generation succeeded and is usable. Stop before any diff or write,
# unless an explicit destination was requested — `zig build matrix` generates
# each target's bindings into zig-out/ so the cross-compile can run against them
# without the committed src/c.zig ever being touched.
if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$tmp/c.zig" "$OUT"
  echo "wrote $OUT ($TARGET)"
  exit 0
fi

if [ "$MODE" = "gen" ]; then
  exit 0
fi

if [ "$MODE" = "check" ]; then
  [ -f "$COMMITTED" ] || { echo "FAIL: $COMMITTED does not exist"; exit 1; }
  if diff -u "$COMMITTED" "$tmp/c.zig" >"$tmp/diff"; then
    echo "ok: $COMMITTED matches the pinned toolchain for $TARGET"
    exit 0
  fi
  echo "FAIL: $COMMITTED is stale for $TARGET"
  echo "      regenerate with:  ZIG=<pinned-zig> tools/regen-c.sh $TARGET"
  echo "      diff:"
  head -20 "$tmp/diff" | sed 's/^/      /'
  exit 1
fi

cp "$tmp/c.zig" "$COMMITTED"
echo "wrote $COMMITTED ($TARGET)"
echo "NOTE: this file is for $TARGET only. Before committing, confirm the"
echo "      layout assertions in test/layout.zig match this target."
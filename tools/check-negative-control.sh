#!/usr/bin/env bash
# Verify the layout assertions are not vacuous.
#
# test/negative_control.zig asserts a deliberately wrong struct size and MUST
# fail to compile. If it compiles, the @compileError plumbing in
# test/layout.zig is broken and every layout check in the project is passing
# for the wrong reason — the exact silent-garbage failure mode the file exists
# to prevent.
set -euo pipefail

cd "$(dirname "$0")/.."

ZIG="${ZIG:-zig}"
out="$("$ZIG" build-obj --dep c -Mroot=test/negative_control.zig -Mc=src/c.zig \
      -lc --cache-dir .zig-cache -femit-bin=/dev/null 2>&1 || true)"

if [ -z "$out" ]; then
  echo "FAIL: test/negative_control.zig compiled successfully."
  echo "      The layout assertions in test/layout.zig are vacuous."
  exit 1
fi

if ! printf '%s' "$out" | grep -q "NEGATIVE CONTROL TRIGGERED"; then
  echo "FAIL: negative control failed for the wrong reason:"
  printf '%s\n' "$out" | head -10
  exit 1
fi

echo "ok: negative control fails to compile as expected"

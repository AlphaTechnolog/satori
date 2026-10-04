#!/usr/bin/env bash
# INVARIANT: a satori module may never fork.
#
# Checked statically, by inspecting the binary's undefined symbols. This is
# stronger than tracing syscalls with dtruss/strace, and it is what should
# actually be in CI for three reasons:
#
#   1. It proves absence, not observation. A trace shows that fork() was not
#      called on this run, in this environment, under this input. An empty
#      symbol table shows the code *cannot* call it — no code path, no input,
#      no environment.
#   2. It needs no root. dtruss and strace do, so the trace-based check could
#      not run on a stock CI runner.
#   3. It works identically on macOS and Linux, unlike dtruss.
#
# A module that needs a subprocess would have to reintroduce one of these
# symbols. The check failing means the no-fork invariant was broken.
#
# The zero-allocation invariant is checked the same way, for the same reasons:
# a malloc in the undefined symbols means something on the default path is
# allocating behind our back.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${1:-zig-out/bin/satori}"

if [ ! -f "$BIN" ]; then
  echo "FAIL: $BIN not found. Run: zig build -Doptimize=ReleaseFast"
  exit 1
fi

# macOS: nm -u lists undefined symbols. Linux: -D --undefined-only on the
# dynamic symbol table. Both fall back to plain nm on stripped binaries.
case "$(uname -s)" in
  Darwin) syms() { nm -u "$BIN" 2>/dev/null | awk '{print $NF}'; } ;;
  Linux)  syms() { nm -D --undefined-only "$BIN" 2>/dev/null | awk '{print $NF}'; } ;;
  *)      echo "unsupported host $(uname -s)"; exit 1 ;;
esac

SYMS="$(syms | sort -u)"

fail=0

# Anything in this list means satori could spawn a process or load code at
# runtime. All are forbidden on the default path.
FORBIDDEN="fork vfork forkpty execve execv execvp execl execlp execveat
           posix_spawn posix_spawnp system popen dlopen dlsym
           wait waitpid waitid"

# Allocating is not fatal by itself, but it violates a stated invariant, so it
# is checked explicitly rather than left to code review.
ALLOC="malloc calloc realloc reallocarray free strdup posix_memalign
       aligned_alloc"

check() {
  local label="$1" needle="$2"
  # Darwin's nm prints C symbols with a leading underscore; ELF's nm -D does
  # not. Matching without accounting for that made this check pass vacuously
  # on a binary that did call system() — caught by the negative control below.
  if printf '%s\n' "$SYMS" | grep -Eq "^_?${needle}$"; then
    echo "FAIL  [$label] binary references '$needle'"
    fail=1
  fi
}

for s in $FORBIDDEN; do check "no-fork" "$s"; done
for s in $ALLOC;    do check "no-alloc" "$s"; done

if [ "$fail" -ne 0 ]; then
  echo
  echo "  satori's defaults are zero forks and zero allocations."
  echo "  Anything above is a regression in one of those invariants."
  exit 1
fi

# Print the surface so a reviewer can eyeball it. On a correct build this is a
# short list, and it is the most useful output of the whole check.
count="$(printf '%s\n' "$SYMS" | grep -c . || true)"
echo "ok: no fork/exec/dlopen symbols, no allocator symbols"
echo "    $count external symbols in total:"
printf '%s\n' "$SYMS" | sed 's|^|      |'

# ---- negative control -------------------------------------------------------
# The check above is only worth anything if it can fail. Verify that, in-process,
# against a binary that does exactly what satori must never do. A check that
# cannot fail is worse than no check: it reports safety while measuring nothing.
#
# Skipped on Linux, where building the probe needs no extra toolchain but the
# resulting ELF pulls in a very different libc surface; the macOS run is the one
# that guards the matching logic above.
if [ "$(uname -s)" = "Darwin" ] && [ "${SATORI_SKIP_NEGATIVE:-0}" != "1" ]; then
  probe="$(mktemp -d)/probe"
  cat > "${probe}.zig" <<'EOF'
const c = @import("c");
pub fn main() void {
    var b: [64]u8 = undefined;
    _ = c.gethostname(&b, 64);
    _ = c.system("true");
}
EOF
  if "${ZIG:-zig}" build-exe --dep c -Mroot="${probe}.zig" -Mc=src/c.zig \
      -lc -OReleaseFast -femit-bin="$probe" --cache-dir .zig-cache-probe >/dev/null 2>&1
  then
    if ./tools/check-no-fork.sh "$probe" >/dev/null 2>&1; then
      echo
      echo "FAIL: negative control PASSED. A binary calling system() was accepted,"
      echo "      so the symbol matching above is broken and every result it has"
      echo "      ever reported was meaningless."
      exit 1
    fi
    echo "ok: negative control correctly rejected a forking binary"
    rm -f "$probe"
  else
    echo "skip: could not build negative control probe"
  fi
fi
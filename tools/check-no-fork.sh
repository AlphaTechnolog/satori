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

# --- can this host's nm even read this binary? -------------------------------
#
# Every assertion in this script is a "symbol X is absent" test, so they all pass
# trivially when SYMS is empty. That makes "could nm read the file?" the most
# important question in the script, and the answer is not always yes:
#
#   * macOS nm given an ELF prints "no symbols" to stderr and exits 0 — exactly
#     what it prints for a genuinely symbol-less binary. Exit status alone cannot
#     tell "wrong format" from "statically linked".
#   * A statically linked binary really does have no undefined symbols, because
#     libc is inside it.
#
# So the object format is read directly from the file header and matched against
# the host, rather than inferred from nm's behaviour. A mismatch is reported as
# the broken check it is, instead of being allowed to look like a clean binary.
host="$(uname -s)"
magic="$(od -An -tx1 -N4 "$BIN" 2>/dev/null | tr -d ' \n')"

case "$magic" in
  7f454c46)                                                        fmt=elf   ;;
  cffaedfe|cefaedfe|feedface|feedfacf|cafebabe|bebafeca|cefaedfe)   fmt=macho ;;
  *)
    echo "FAIL: $BIN is not a recognised Mach-O or ELF binary (magic '$magic')."
    echo "      Nothing was inspected, so nothing was proven."
    exit 1
    ;;
esac

case "$fmt/$host" in
  macho/Darwin) syms() { nm -u "$BIN" 2>/dev/null | awk '{print $NF}'; } ;;
  elf/Linux)    syms() { nm -D --undefined-only "$BIN" 2>/dev/null | awk '{print $NF}'; } ;;
  *)
    echo "FAIL: $BIN is a $fmt binary but this host is $host, whose nm cannot read it."
    echo "      Run this check on a matching host. Checking here would report a"
    echo "      pass having measured nothing at all."
    exit 1
    ;;
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

# Guard against the check succeeding because it read nothing at all.
#
# The format check above rules out the two ways this could happen by accident, so
# an empty list here means a statically linked binary, which is a genuine result
# and not a clean bill of health: with libc linked in, fork and malloc are
# internal symbols, not undefined ones, so "no undefined fork" is vacuously true
# and proves nothing. It is reported as inconclusive rather than as a pass.
if [ "$count" -eq 0 ]; then
  echo "INCONCLUSIVE: $BIN exposes no dynamic symbols."
  if [ "${SATORI_ALLOW_STATIC:-0}" = "1" ]; then
    echo "  SATORI_ALLOW_STATIC=1 set, so treating this as acceptable."
  else
    echo "  This is what a statically linked binary looks like: libc is inside"
    echo "  it, so there is nothing undefined left to inspect and the checks"
    echo "  above are vacuously true."
    echo "  No-fork is not disproven, but it is also not proven. Verify a static"
    echo "  build by other means, or set SATORI_ALLOW_STATIC=1 to accept it."
    exit 1
  fi
fi

# satori links libc and calls it for uname, gethostname, getenv, write and a few
# more, so a real dynamic binary always has some undefined symbols. A floor well
# below the observed 17-20 tolerates platforms and link modes while still
# catching a partially-read symbol table.
if [ "$count" -lt 5 ]; then
  echo "FAIL: found only $count external symbols in $BIN."
  echo "      Too few to be a real dynamically linked satori; the symbol table"
  echo "      was probably only partly read, which would make the checks above"
  echo "      unreliable in the other direction."
  exit 1
fi

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
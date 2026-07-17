#!/usr/bin/env bash
# CLI end-to-end smoke test (spec §16): create tiny meson + cmake C++ projects
# and drive them through the `lw` CLI — configure/build, run the built binary,
# run tests, and clean — asserting the expected output. Runs in CI on Linux,
# macOS, and Windows.
#
# The CLI invocation is `$LW` (default: the local dev build). CI sets it to a
# luvi host over the checkout, e.g.:
#   export LOOMWORKS_LUA="$PWD/lua"
#   LW="./luvi $PWD/lua" scripts/ci/cli-e2e.sh
#
# Exits non-zero if any step fails.
set -u

LW="${LW:-lw --dev}"

# The runner drives each project from inside its own temp workspace (cd below),
# so a relative binary like `./lw` would stop resolving. Make the binary
# absolute up front; a bare command found on PATH (e.g. `lw`) is left as-is.
set -- $LW
_bin="$1"; shift
if [ -e "$_bin" ]; then
    _bin="$(cd "$(dirname "$_bin")" && pwd)/$(basename "$_bin")"
fi
LW="$_bin${*:+ $*}"

PASS=0
FAIL=0

say() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf '  ok  : %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

# Non-interactive lw.
run_lw() { $LW --no-input "$@"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Pick a toolchain key for the given module from `run_lw tools`, preferring a
# self-contained gcc/clang over MSVC (which needs a dev environment), then the
# first available.
pick_tool() {
    local list="$TMP/tools.txt" keys="$TMP/keys.txt"
    run_lw tools > "$list" 2>/dev/null
    # Tool keys are the first token of each indented line (module headers, the
    # trailing hint, and blank lines are flush-left / empty).
    awk 'NF>0 && /^[[:space:]]/ {print $1}' "$list" > "$keys"
    local t
    # Prefer a self-contained gcc/clang toolchain (msvc and clang-cl need a VS
    # dev environment); take the full key so e.g. "ninja-appleclang-15" survives.
    t=$(grep -viE 'msvc|clang-cl' "$keys" | grep -iE 'gcc|clang' | head -1)
    [ -z "$t" ] && t=$(head -1 "$keys")
    printf '%s' "$t"
}

# Record a failure: print the captured output ($TMP/out.txt) and, under GitHub
# Actions, emit an ::error:: annotation (readable via the API without the
# repo-admin rights that downloading job logs requires).
note_fail() { # $1 = description   $2 = exit code
    bad "$1 (exit $2)"
    { echo "  --- output of the failing step ---"; tail -n 25 "$TMP/out.txt" | sed 's/^/  | /'; } >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error title=cli-e2e: %s::%s\n' "$1" \
            "$(tail -n 10 "$TMP/out.txt" | tr '\n\r' '  ' | sed 's/%/%25/g' | cut -c1-500)"
    fi
}

# Drive one module's project through the full CLI flow.
#   $1 = module (meson|cmake)   $2 = workspace dir with app/ inside
run_case() {
    local mod="$1" ws="$2" out="$TMP/out.txt" rc
    say "$mod project"
    cd "$ws" || { bad "$mod: cd"; return; }

    run_lw init > "$out" 2>&1 || { note_fail "$mod init" $?; return; }
    run_lw project add ./app "$mod" > "$out" 2>&1 || { note_fail "$mod project add" $?; return; }

    local tool
    tool=$(pick_tool)
    if [ -z "$tool" ]; then
        run_lw tools > "$out" 2>&1 # capture what was (not) detected
        note_fail "$mod: no toolchain detected" 0
        return
    fi
    ok "$mod toolchain: $tool"

    run_lw configuration-set create Debug app=variant:Debug > "$out" 2>&1 \
        || { note_fail "$mod configuration-set create" $?; return; }
    run_lw profile create Debug "$tool" > "$out" 2>&1 \
        || { note_fail "$mod profile create" $?; return; }
    local prof="Debug:$tool"

    run_lw build "$prof" > "$out" 2>&1; rc=$?
    if grep -q "BUILD OK" "$out"; then ok "$mod build"; else note_fail "$mod build" "$rc"; return; fi
    run_lw run "$prof" app > "$out" 2>&1; rc=$?
    if grep -q "APP-RAN-$mod" "$out"; then ok "$mod run"; else note_fail "$mod run" "$rc"; fi
    run_lw test "$prof" > "$out" 2>&1; rc=$?
    if grep -q "TESTS OK" "$out"; then ok "$mod test"; else note_fail "$mod test" "$rc"; fi
    run_lw clean "$prof" > "$out" 2>&1; rc=$?
    if grep -q "CLEAN OK" "$out"; then ok "$mod clean"; else note_fail "$mod clean" "$rc"; fi
}

# --- meson project ---------------------------------------------------------
mkdir -p "$TMP/meson/app"
cat > "$TMP/meson/app/meson.build" <<'MB'
project('app', 'cpp')
exe = executable('app', 'main.cpp')
test('t', exe)
MB
cat > "$TMP/meson/app/main.cpp" <<'CPP'
#include <cstdio>
int main() { printf("APP-RAN-meson\n"); return 0; }
CPP
run_case meson "$TMP/meson"

# --- cmake project ---------------------------------------------------------
mkdir -p "$TMP/cmake/app"
cat > "$TMP/cmake/app/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(app CXX)
enable_testing()
add_executable(app main.cpp)
add_test(NAME t COMMAND app)
CM
cat > "$TMP/cmake/app/main.cpp" <<'CPP'
#include <cstdio>
int main() { printf("APP-RAN-cmake\n"); return 0; }
CPP
run_case cmake "$TMP/cmake"

printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

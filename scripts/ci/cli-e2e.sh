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

# Drive one module's project through the full CLI flow.
#   $1 = module (meson|cmake)   $2 = workspace dir with app/ inside
run_case() {
    local mod="$1" ws="$2"
    say "$mod project"
    cd "$ws" || { bad "$mod: cd"; return; }

    run_lw init >/dev/null 2>&1 || { bad "$mod init"; return; }
    run_lw project add ./app "$mod" >/dev/null 2>&1 || { bad "$mod project add"; return; }

    local tool
    tool=$(pick_tool)
    if [ -z "$tool" ]; then bad "$mod: no toolchain detected"; return; fi
    ok "$mod toolchain: $tool"

    run_lw configuration-set create Debug app=variant:Debug >/dev/null 2>&1 \
        || { bad "$mod configuration-set create"; return; }
    run_lw profile create Debug "$tool" >/dev/null 2>&1 \
        || { bad "$mod profile create"; return; }
    local prof="Debug:$tool"

    if run_lw build "$prof" 2>&1 | grep -q "BUILD OK"; then ok "$mod build"; else bad "$mod build"; return; fi
    if run_lw run "$prof" app 2>&1 | grep -q "APP-RAN-$mod"; then ok "$mod run"; else bad "$mod run"; fi
    if run_lw test "$prof" 2>&1 | grep -q "TESTS OK"; then ok "$mod test"; else bad "$mod test"; fi
    if run_lw clean "$prof" 2>&1 | grep -q "CLEAN OK"; then ok "$mod clean"; else bad "$mod clean"; fi
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

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
    # Real tool keys start with a letter/digit; a "(none detected)" placeholder
    # line does not, so it's filtered out (leaving an empty pick → clean error).
    awk 'NF>0 && /^[[:space:]]/ && $1 ~ /^[A-Za-z0-9]/ {print $1}' "$list" > "$keys"
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

# Root discovery must not cross a git working-tree boundary (spec §16.2): `lw`
# in a fresh git worktree (a `.git` file, no `.nvim/` of its own) must NOT
# silently bind to a parent checkout's workspace. Toolchain-independent.
test_worktree_boundary() {
    say "worktree boundary"
    local base="$TMP/wt" out="$TMP/out.txt"
    mkdir -p "$base/parent/wt-agent"
    ( cd "$base/parent" && run_lw init --name parent-ws ) > "$out" 2>&1 \
        || { note_fail "worktree: parent init" $?; return; }
    # Simulate a linked git worktree root: a `.git` FILE, no workspace of its own.
    printf 'gitdir: %s/.git/worktrees/wt-agent\n' "$base/parent" > "$base/parent/wt-agent/.git"
    ( cd "$base/parent/wt-agent" && run_lw workspace ) > "$out" 2>&1
    if grep -q "parent-ws" "$out"; then
        note_fail "worktree: lw bound to the parent checkout across a git boundary" 0
    else
        ok "worktree: lw refuses to bind across a git boundary"
    fi
}

# Drive one module's project through the full CLI flow.
#   $1 = label (for messages)   $2 = module (meson|cmake)
#   $3 = workspace dir with app/ inside   $4 = marker to grep in `lw run` output
run_case() {
    local label="$1" mod="$2" ws="$3" marker="$4" out="$TMP/out.txt" rc
    say "$label project"
    cd "$ws" || { bad "$label: cd"; return; }

    run_lw init > "$out" 2>&1 || { note_fail "$label init" $?; return; }

    # Workspace name: rename, then read it back (name doesn't affect the build).
    run_lw workspace rename "e2e-$mod" > "$out" 2>&1 || { note_fail "$label workspace rename" $?; return; }
    run_lw workspace > "$out" 2>&1
    grep -q "e2e-$mod" "$out" || { note_fail "$label workspace name not set" 0; return; }

    run_lw project add ./app "$mod" > "$out" 2>&1 || { note_fail "$label project add" $?; return; }

    # Rename round-trip: app -> app2 -> app, asserting the new key lists and the
    # old one restores, so downstream `app=...` mappings are undisturbed.
    run_lw project rename app app2 > "$out" 2>&1 || { note_fail "$label project rename" $?; return; }
    run_lw project list > "$out" 2>&1
    grep -q "app2" "$out" || { note_fail "$label rename (app2 not listed)" 0; return; }
    run_lw project rename app2 app > "$out" 2>&1 || { note_fail "$label rename back" $?; return; }

    local tool
    tool=$(pick_tool)
    if [ -z "$tool" ]; then
        run_lw tools > "$out" 2>&1 # capture what was (not) detected
        note_fail "$label: no toolchain detected" 0
        return
    fi
    ok "$label toolchain: $tool"

    run_lw configuration-set create Debug app=variant:Debug > "$out" 2>&1 \
        || { note_fail "$label configuration-set create" $?; return; }
    run_lw profile create Debug "$tool" > "$out" 2>&1 \
        || { note_fail "$label profile create" $?; return; }
    local prof="Debug:$tool"

    run_lw build "$prof" > "$out" 2>&1; rc=$?
    if grep -q "BUILD OK" "$out"; then ok "$label build"; else note_fail "$label build" "$rc"; return; fi
    run_lw run "$prof" app > "$out" 2>&1; rc=$?
    if grep -q "$marker" "$out"; then ok "$label run"; else note_fail "$label run" "$rc"; fi
    run_lw test "$prof" > "$out" 2>&1; rc=$?
    if grep -q "TESTS OK" "$out"; then ok "$label test"; else note_fail "$label test" "$rc"; fi
    run_lw clean "$prof" > "$out" 2>&1; rc=$?
    if grep -q "CLEAN OK" "$out"; then ok "$label clean"; else note_fail "$label clean" "$rc"; fi
}

# A shared library's exported symbol. Exported on Windows via __declspec;
# default-visible everywhere else. Guarded so the same source builds under
# MSVC, mingw-gcc, gcc and clang.
greet_lib_source() {
    cat <<'CPP'
#ifdef _WIN32
#  define GREET_API __declspec(dllexport)
#else
#  define GREET_API
#endif
extern "C" GREET_API const char *greet() { return "LINKED-OK"; }
CPP
}

# main.cpp for a multi-lib app: calls into the shared library in ../lib.
# Prints LINKED-OK only if the .dll/.so was found and loaded at runtime,
# which on Windows depends on `lw run` putting the lib dir on PATH.
multilib_main_source() {
    cat <<'CPP'
#include <cstdio>
#ifdef _WIN32
#  define GREET_API __declspec(dllimport)
#else
#  define GREET_API
#endif
extern "C" GREET_API const char *greet();
int main() { printf("greeting=%s\n", greet()); return 0; }
CPP
}

# --- meson project (single executable) -------------------------------------
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
run_case meson meson "$TMP/meson" "APP-RAN-meson"

# --- cmake project (single executable) -------------------------------------
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
run_case cmake cmake "$TMP/cmake" "APP-RAN-cmake"

# --- meson multi-lib (shared library in a subfolder) -----------------------
# The exe links a shared library built under app/lib/, so its .dll/.so lands
# in a build subdir, NOT next to the exe. Exercises the run-environment:
# Windows needs the lib dir on PATH (`lw run`); POSIX relies on rpath.
mkdir -p "$TMP/meson-ml/app/lib"
cat > "$TMP/meson-ml/app/meson.build" <<'MB'
project('app', 'cpp')
subdir('lib')
exe = executable('app', 'main.cpp', link_with: greetlib)
test('t', exe)
MB
cat > "$TMP/meson-ml/app/lib/meson.build" <<'MB'
greetlib = shared_library('greet', 'greet.cpp')
MB
greet_lib_source   > "$TMP/meson-ml/app/lib/greet.cpp"
multilib_main_source > "$TMP/meson-ml/app/main.cpp"
run_case meson-multilib meson "$TMP/meson-ml" "LINKED-OK"

# --- cmake multi-lib (shared library in a subfolder) -----------------------
mkdir -p "$TMP/cmake-ml/app/lib"
cat > "$TMP/cmake-ml/app/CMakeLists.txt" <<'CM'
cmake_minimum_required(VERSION 3.16)
project(app CXX)
enable_testing()
add_subdirectory(lib)
add_executable(app main.cpp)
target_link_libraries(app PRIVATE greet)
add_test(NAME t COMMAND app)
CM
cat > "$TMP/cmake-ml/app/lib/CMakeLists.txt" <<'CM'
add_library(greet SHARED greet.cpp)
CM
greet_lib_source   > "$TMP/cmake-ml/app/lib/greet.cpp"
multilib_main_source > "$TMP/cmake-ml/app/main.cpp"
run_case cmake-multilib cmake "$TMP/cmake-ml" "LINKED-OK"

# Toolchain-independent root-discovery regression.
test_worktree_boundary

printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

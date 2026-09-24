# meson module

How the meson module implements the core module contract
(`specification.md` §8). Section numbers in this file are local.

## 1. Detection and identity

- **Marker file**: `meson.build`.
- **Keyed tools**: yes. Cache keys are `"<variant>:<tool_key>"`
  where `tool_key` identifies the compiler (e.g., `"gcc-14.2.0"`).
  Each compiler produces different build output.
- **Languages**: `"c++"`.

## 2. Variant mapping

| Variant type | Configuration |
|--------------|---------------|
| `"debug"` | `"Debug"` (maps to meson `buildtype=debug`) |
| `"release"` | `"Release"` (maps to `buildtype=release`) |
| `"release_debug"` | `"RelWithDebInfo"` (maps to `buildtype=debugoptimized`) |

Single-config fallback applies.

## 3. Default configurations

Debug, Release, RelWithDebInfo — each mapping to the corresponding
meson `buildtype` value. Generated when no user configs are declared.

## 4. Tasks

- **Setup**: `meson setup <build_dir> --buildtype <variant> [--cross-file <machine>]`
- **Compile**: `meson compile -C <build_dir>`
- **Clean**: `meson compile -C <build_dir> --clean`

Machine file paths are resolved from the tool selection and prepended
to the setup command when cross-compiling.

## 5. Per-compiler kits

Tools are keyed per compiler. Each tool pins CC/CXX and prepends the
compiler's `bin` directory to `PATH` so subprocess invocations resolve
the right toolchain.

On Windows, MSVC (`cl.exe`) and clang-cl tools are discovered from the
shared **`loomworks.msvc` module** — the single source of truth for VS
installs + clang-cl across all modules. One `cl.exe` tool and one
clang-cl tool are emitted **per detected MSVC install** (previously a
single clang-cl tool pinned to the newest install). clang-cl reuses the
paired install's STL / Windows SDK / linker via `vcvarsall`, so each
clang-cl tool carries that install's `vcvarsall`/`arch`; its driver is
the VS-bundled clang-cl when present, otherwise a standalone / PATH
clang-cl. The tool's `compiler_id` is per-install
(`clang-cl-<version>-<major>-<product>`) so installs that fall back to
the *same* standalone driver remain distinct tools — `tools_match`
disambiguates on `vcvarsall` for the same reason. Any sibling
`clangd.exe` next to the clang-cl driver is carried as `clangd_path` and
forwarded to clangd (§ LSP integration).

The tool owns the compiler: a configuration's `env` may not override the
tool's pinned `CC`/`CXX`. The compiler-driver variables (`CC`, `CXX`,
`FC`, `CUDACXX`, `CUDAHOSTCXX`, `OBJC`, `OBJCXX`, `ISPC`) are reserved —
rejected at config-edit time and stripped when the task environment is
composed (with a non-blocking inline diagnostic) — so the compiler stays
consistent with the `compiler_id` that keys the build directory. The
`*FLAGS` variables are not reserved. A meson machine/cross file
(`machine_file`) is the analog of a cmake toolchain file and is out of
scope (see core §15, invariant "The tool owns the compiler").

## 5a. Compiler cache launcher

Core resolves a compiler-cache launcher from the effective `cache` policy
(core §1.3.2) and the active tool's compiler family and hands it to the module as
`ctx.compiler_cache = { tool, path }` (or `nil`). For `auto`, the concrete
launcher is `ccache` for a gcc / clang family tool (`sccache` the fallback), and
**none** for an MSVC-style tool (MSVC `cl`, clang-cl) — caching those requires an
explicit `ccache` / `sccache` policy, for the reason given in
[`cmake.md` §5d](cmake.md) (sccache fails a PDB-writing `/Zi` / `/ZI` compile;
core §1.3.2). An explicit `ccache` / `sccache` policy uses that tool on any
family. The launcher is applied only when core actually resolved one (present on
the toolchain search path).

**Post-configure PDB-flag scan (`cache_compat_scan`, core §8).** After a
successful setup that applied a launcher to an MSVC-style tool, the module scans
the per-target compile parameters of its target introspection data (§6) for the
same PDB-writing flags as cmake (`/Zi`, `/ZI`, `-Zi`, `-ZI`) and reports findings
per target with the same severities (`"error"` for sccache, `"warning"` for
ccache) and remedies (switch those targets to `/Z7`, or `cache=off`). The module
injects no debug-info-format adjustment of its own; a subproject or user option
that requests `/Zi` is surfaced by the scan, never silently rewritten. When no
introspection data exists for the build, the scan returns `scanned = false` and
health reports it as skipped (core §16.31).

**Explicit compiler pinning via a generated native file — and deliberate
suppression of meson's auto-detect.** meson has its own implicit behavior: when
it finds `ccache` on `PATH` it silently prepends it to compiler invocations.
loomworks does **not** rely on that. Instead, where §5 pins `CC` / `CXX`, the
module takes **explicit control** by writing a generated **native file** whose
`[binaries]` section pins the compiler as a LIST — `cpp = ['<launcher>',
'<compiler>']` and `c = ['<launcher>', '<compiler>']` when a launcher is
resolved, or the bare `cpp = ['<compiler>']` / `c = ['<compiler>']` when the
policy resolves to no launcher (`off`, or a tool not found) — passed to
`meson setup` via `--native-file`. The `CC` / `CXX` environment string is **not**
used to carry the compiler command: meson `shlex`-splits it on whitespace, so a
compiler path (or a `<launcher> <path>` wrapper) that contains a **space** — e.g.
`C:/Program Files/LLVM/bin/clang++.exe` — would shatter into broken tokens. A
native-file list is not split, so spaces are safe; the module therefore drops
`CC` / `CXX` from the setup environment and relies on the native file. The bare
pinning (no launcher) means meson's implicit PATH auto-detect cannot layer a
cache back on. This is a deliberate divergence from meson's default: loomworks
owns the caching decision end to end so that (a) meson and cmake behave
identically under the same `cache` policy, and (b) the staleness fingerprint
(§11) stays coherent — the launcher is a resolved input loomworks records, not a
hidden PATH-sensitive choice meson makes on its own. The compiler identity that
keys the build directory is unchanged: the launcher wraps the same pinned
driver, it does not select a different compiler (§5, core §15 "the tool owns the
compiler").

**Applying a launcher change requires `meson setup --wipe`, not
`--reconfigure`.** meson fixes the compiler command at first setup and does not
re-evaluate it on a plain `meson setup --reconfigure` — the normal reconfigure
loomworks issues for an option change. So a launcher that changed since the build
dir was configured (the cache tool appeared/disappeared, or the policy was
edited) would be **silently ignored** by an in-place reconfigure. When the
resolved launcher differs from the one the build dir was configured with, the
module therefore reconfigures with `meson setup --wipe`: it wipes and rebuilds
the build tree, re-reading the now-wrapped (or now-unwrapped) compiler from the
`--native-file`, while **preserving the existing `-D` options** (meson re-reads
them from the wiped directory). This `--wipe` is the general mechanism for **any** compiler-command
change on the same build directory; the compiler-cache toggle is simply its
first routine case. This diverges from cmake, whose launcher is a mutable cache
variable that a plain in-place reconfigure applies (see [`cmake.md` §5d](cmake.md)).

**Removed options need a full reconfigure (core §5.1 *Faithful reconfigure*).**
meson persists every `-D` option in the build directory: `--reconfigure` keeps an
option that is no longer passed, and `--wipe` deliberately **replays** the
previous command line (`meson-private/cmd_line.txt`) before applying the new one,
so neither can retract an option, and meson has no flag to unset one. The module
therefore records the `-D` options it passed (name → value) in
`module_info.passed_options`, and on the next setup of an already-configured
build directory compares that record (`recorded_module_info`, core §8.1; for a
unit configured before the record existed, the keys of core's
`recorded_options` snapshot) with what it passes now. An option **added or
changed** is applied by the normal `--reconfigure` (or the `--wipe` above when
the launcher also changed). An option loomworks passed before and **no longer
passes** triggers a **full reconfigure**: the configure task names
`meson-private/cmd_line.txt` in `pre_configure_reset` (core §8.1), so core
removes the stored command line under the deletion-safety rules, and the module
runs `meson setup --wipe` with the complete current option set — meson then
rebuilds the tree from exactly the options loomworks passes, and the removed
option returns to its `meson.options` default. Only options in loomworks' own
record trigger this; an option the user set with `meson configure` by hand is
not loomworks-passed and is left alone by a plain `--reconfigure`.

## 6. Target discovery (`parse_targets`)

Uses `meson introspect --targets` + `meson introspect --target-sources`
to enumerate project-owned targets and their source files.

## 7. Build options (`get_options`)

Uses `meson introspect --buildoptions` to surface user-facing options.

### 7c. Variable expansion in options

`-D` option values are expanded before they reach the `meson setup`
command: built-in variables, environment variables, and user-declared
project variables (core §1.3.1) — including the configuration's
compiler-specific `overrides`, resolved against the active tool's compiler
family. This mirrors the cmake module (see [`cmake.md` §5c](cmake.md)); the
variable value is an opaque passthrough (meson never parses the flag string).
A reference to an undeclared variable is a diagnostic, not a silent empty
string. Because the expanded value is what lands on the `-D` line, a change to
a variable `default` or a compiler `override` alters the resolved setup
command and so participates in `ConfigUnit:is_stale()` (§11), whose fingerprint
is taken over the *resolved* option values.

## 7a. Launch runtime path (`runtime_path`)

Returns the pinned compiler's `bin` directory (from the kit's
`compiler_bin_dir` in `tool_data`) so build-target launches find the toolchain
runtime DLLs (libstdc++, libgcc, libwinpthread). Core adds the build tree's own
shared-library dirs generically (core §8.7), so only the toolchain dir is
reported here.

## 8. Test integration

Implements the generic test interface (core §8.9) through a single
`MesonTestUnit` per `ConfigUnit`.

### 8.1 MesonTestUnit

Wraps `meson introspect --tests` to enumerate tests. For each test
whose command points at a gtest binary, the shared GTest helper (see
[`cmake.md` §8.2](cmake.md#82-gtest-helper)) probes the binary to
enumerate individual test cases and maps them to source locations.

File/line is populated from `target_sources`, enabling jump-to-test
from the test explorer.

## 9. LSP integration

Emits `lsp_configs` entries for clangd.

`compile_commands_dir` resolves to the ConfigUnit's build directory —
meson auto-generates `compile_commands.json` there on setup.

`binary` / `binary_required` follow the generic rule: if the active
profile's SDK provides a clangd, use it with `binary_required = true`;
otherwise fall back to PATH.

## 10. Debug integration

Module language is `"c++"`. Default adapter is `codelldb`.

## 11. Staleness (`inspect`)

Not implemented as file-mtime staleness. meson under Ninja installs a
regeneration rule: Ninja re-runs `meson` automatically at build time when
`meson.build` / `meson.options` / `meson_options.txt` (and the files they
`subdir()` into) change. loomworks does not stat those files or emit a
"modified since last configure" refresh. The sole loomworks-driven
reconfigure triggers are `unconfigured` / `configure_failed` and option-level
staleness via `ConfigUnit:is_stale()`.

The **resolved compiler-cache launcher** (§5a) is an additional `is_stale()`
input on the same footing as resolved option values: core records the launcher
it resolved into the setup task's `module_info`, and `is_stale()` recomputes it
(current `cache` policy + compiler family + live toolchain-path presence) and
compares. A launcher that appears, disappears, or changes — because the tool was
installed/removed or the policy was edited — marks the unit stale, and the build
gate reconfigures so the wrapped (or un-wrapped) native-file compiler takes
effect. That reconfigure is a **`meson setup --wipe`** (§5a), not a plain
`meson setup --reconfigure`: meson fixes the compiler command at setup and would
otherwise ignore the changed launcher. `--wipe` re-detects the compiler while
preserving the `-D` options, so the caching change is applied without losing
configuration. Because loomworks pins the driver explicitly rather than leaning
on meson's PATH auto-detect (§5a), this recompute fully captures the caching
state.

Option-level staleness covers an option **added, changed or removed**; the
resulting reconfigure is faithful (§5a *Removed options need a full
reconfigure*): a removed option is dropped from the build directory by a
`--wipe` setup after core clears the stored command line.

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

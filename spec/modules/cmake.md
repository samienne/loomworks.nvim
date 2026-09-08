# cmake module

How the cmake module implements the core module contract
(`specification.md` §8). Section numbers in this file are local.

## 1. Detection and identity

- **Marker file**: `CMakeLists.txt`. `detect()` reports `{ marker =
  "CMakeLists.txt" }` when present.
- **Keyed tools**: yes. Cache keys are `"<variant>:<tool_key>"` where
  `tool_key` combines generator and compiler (e.g.
  `"Debug:ninja-gcc-12"`). Different generator/compiler combinations
  produce distinct build artifacts.
- **Languages**: `"c++"`.

## 1a. Kit (tool) detection

`detect_tools` enumerates build kits from `cmake_kits`, which combines
PATH-scanned GCC/Clang toolchains with Visual Studio installations. MSVC
and clang-cl discovery is **owned by the shared `loomworks.msvc` module**
(the single source of truth for VS installs + clang-cl across all
modules — cmake no longer duplicates the `vswhere` scan). Per detected VS
install, the following kits are produced:

- **`Visual Studio <major> <line>` generator kit** — always. Builds via
  MSBuild in the install's `vcvarsall` environment.
- **`Ninja - <install>` (cl.exe) kit** — when `ninja` is on PATH.
- **`Ninja - clang-cl (<install>)` kit** — when `ninja` is on PATH and a
  clang-cl paired to that install exists. clang-cl is Clang's
  MSVC-compatible driver: it has no STL / Windows SDK / linker of its own
  and reuses the paired install's via `vcvarsall`, so there is **exactly
  one clang-cl kit per install**. The driver is taken from the VS-bundled
  clang-cl (`<install>/VC/Tools/Llvm/x64/bin/clang-cl.exe`, the "C++ Clang
  tools for Windows" component) when present, otherwise a standalone /
  PATH clang-cl. Kit id `ninja-clang-cl-<major>-<product>`; compiler id
  `clang-cl-<version>`. Any sibling `clangd.exe` is forwarded to clangd
  (§9). At configure time clang-cl is passed as **both**
  `-DCMAKE_C_COMPILER` and `-DCMAKE_CXX_COMPILER` (it is a single driver
  for C and C++), the build runs Ninja inside the paired `vcvarsall`
  environment, and `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` is set.

## 2. Variant mapping

| Variant type | Configuration name |
|--------------|-------------------|
| `"debug"` | `"Debug"` (case-insensitive match) |
| `"release"` | `"Release"` |
| `"release_debug"` | `"RelWithDebInfo"` |

Single-config fallback applies: when the project has exactly one
configuration, it is returned for any variant type.

## 3. CMakePresets integration

The module reads `CMakePresets.json` + `CMakeUserPresets.json` with
full preset inheritance:

- Each non-hidden configure preset becomes a loomworks configuration.
- A directly mapped preset is configured with `cmake --preset <name>`
  using the bare preset name (not the internal `preset:<name>` key).
  cmake reads `CMakePresets.json` and applies the preset's generator,
  `binaryDir`, toolchain, and cache variables itself; loomworks adds
  none of the manual `-G` / `-S` / `-B` / `-D…` flags for a preset. For
  a multi-config preset that declares no `CMAKE_BUILD_TYPE`, the build
  step omits `--config` (cmake builds the generator's default) rather
  than pass a name it cannot resolve.
- Preset's `binaryDir` is used as the build directory for a directly
  mapped preset (wins over defaults). It is NOT propagated to
  configurations that inherit from the preset — build directories are
  per-configuration, so a base and its derived configs never share one.
  A mapped preset MUST declare `binaryDir`: cmake configures into its own
  directory, and loomworks builds that directory separately, so without it
  loomworks cannot locate the build. A preset that omits `binaryDir` is
  refused with a clear error rather than built into a mismatched directory.
- Preset's `cacheVariables.CMAKE_BUILD_TYPE`, when present, provides the
  configuration's variant. All other `cacheVariables` are applied by
  cmake itself when the preset is configured via `--preset`; the module
  never re-passes them on the command line. Each `cacheVariables` entry is
  read tolerant of both CMakePresets forms — a bare string or an object
  `{ "type": …, "value": … }`.
- Preset's `toolchainFile` / `CMAKE_TOOLCHAIN_FILE` maps to
  `toolchain_locked = true`.
- A configuration whose `inherits` names a `preset:*` configuration
  produces a validation warning (non-blocking): presets are
  self-contained units invoked via `cmake --preset`, whereas an
  inheriting configuration is built through the manual configure path
  and silently drops the preset's `cacheVariables` and `binaryDir`. The
  warning directs the user to add a derived preset in
  `CMakeUserPresets.json` (full fidelity) or to inherit from a
  `variant:*` configuration instead.
- Debug/Release/RelWithDebInfo are auto-generated **only if no presets
  exist and no configurations are declared in the workspace config**.
- Overrides in the `configurations` block of the workspace config add
  to or override preset-derived configurations.
- A preset owns its own toolchain. loomworks never reads or re-passes a
  preset's compiler settings (`cacheVariables.CMAKE_<LANG>_COMPILER`,
  `toolchainFile`, or the preset's `environment`), and does not offer
  tool-compiler selection for a `from_preset` configuration — the
  compiler is preset-defined (or CMake-detected when the preset pins
  none). §5b governs only loomworks-managed `options`/`env`, never the
  preset file itself.

## 4. CMake File API integration

The module uses CMake's file-based API (codemodel v2) to discover
build targets after configure.

### 4.1 Query setup

The query files

```
<build_dir>/.cmake/api/v1/query/codemodel-v2
<build_dir>/.cmake/api/v1/query/cache-v2
```

are created before the configure task runs (in the task builder).
These are empty markers — their presence tells CMake to write reply
data on every configure. The codemodel reply provides targets; the
cache reply provides build options.

### 4.2 Reply parsing

After a successful configure, core calls `parse_targets(ctx)` on the
module. The cmake module reads the codemodel reply from
`<build_dir>/.cmake/api/v1/reply/`, extracts project-owned targets,
and returns them. On startup, existing build directories are scanned
asynchronously via `parse_targets_async`.

### 4.3 Target filtering

Only project-owned build targets are included:

- Executables (`EXECUTABLE`)
- Static libraries (`STATIC_LIBRARY`)
- Shared libraries (`SHARED_LIBRARY`)
- Module libraries (`MODULE_LIBRARY`)
- Object libraries (`OBJECT_LIBRARY`)
- Interface libraries (`INTERFACE_LIBRARY`)

Imported targets, alias targets, and utility targets (e.g.,
`install`, `uninstall`) are excluded.

### 4.4 Dependencies

Link dependencies between project-owned targets are recorded.
Dependencies on imported or external targets are excluded.

### 4.5 Storage

Targets are runtime-only data stored on `ConfigUnit.targets` as
`Target` objects (not persisted in cache). They are re-parsed from
the file-api reply on startup (async) and after each successful
configure (sync). The entire targets dict is replaced on every parse
(not merged). Each `Target` object holds the target id, type,
dependencies, artifact path, and a back-reference to its owning
`ConfigUnit`.

## 5. Build options (`get_options`)

The module returns a tree of groups and options derived from the
cache reply. It supports `option_groups` in its `type_config` to map
variable name prefixes to group paths (e.g., `"GFX": ["Media",
"Graphics"]`). `CMAKE_`-prefixed variables are automatically
separated into a "CMake Options" group.

## 5a. Launch runtime path (`runtime_path`)

Returns the directory of the kit's `compiler_path` (from `tool_data`) so
build-target launches find the toolchain runtime DLLs for gcc/clang toolchains.
Core adds the build tree's own shared-library dirs generically (core §8.7).

## 5b. Reserved compiler keys (the tool owns the compiler)

The profile's tool (kit) is the single source of truth for the C/C++
compiler — its identity keys the build directory and selects the clangd
binary. A project configuration therefore may not select a compiler
through its own `options` or `env`. Two reserved sets are enforced (see
core §15, invariant "The tool owns the compiler"):

- **Option keys** — any CMake cache key matching `^CMAKE_<LANG>_COMPILER$`
  (`CMAKE_C_COMPILER`, `CMAKE_CXX_COMPILER`, `CMAKE_Fortran_COMPILER`,
  `CMAKE_CUDA_COMPILER`, …). The `_COMPILER` anchor excludes neighbours
  that only start the same way — `CMAKE_<LANG>_COMPILER_LAUNCHER`,
  `..._COMPILER_ID`, `..._COMPILER_TARGET`, `..._COMPILER_WORKS` are NOT
  reserved. Compiler flags (`CFLAGS`, `CXXFLAGS`, …) are allowed.
- **Env driver vars** — exactly `CC`, `CXX`, `FC`, `CUDACXX`,
  `CUDAHOSTCXX`, `OBJC`, `OBJCXX`, `ISPC`. The `*FLAGS` variables and
  compiler launchers are not reserved.

Enforcement is twofold:

1. **Reject at edit time.** Configuration mutation paths
   (`Project:save_configuration`) refuse a config whose `options` carries
   a reserved cache key or whose `env` carries a reserved driver var,
   returning an error that names the key and directs the user to pick a
   tool instead (mirrors the reserved-variable-name rule). The reserved
   key never reaches the working copy.
2. **Strip at build time.** When assembling the configure command and
   composing the task environment, loomworks drops any reserved key that
   is present from a hand-edited file: reserved `-D…` options are not
   emitted and reserved env vars are removed before the tool's compiler
   is layered on. The build proceeds with the tool's compiler, and the
   affected configuration surfaces a non-blocking inline diagnostic
   (`⚠ ignored compiler override (<KEY>)`) alongside the Diagnostics
   section. This applies even to a `from_preset` configuration, because
   loomworks still appends its own `-D…`/env on top of `cmake --preset`;
   the strip governs only those loomworks-managed additions and never the
   preset file's own `cacheVariables`/`environment`.

Toolchain files (`CMAKE_TOOLCHAIN_FILE`, whether kit- or user-supplied)
are out of scope — they select a whole toolchain, not a bare compiler
driver, and are handled by the toolchain path (§1a / §6), not §5b.

## 5c. Variable expansion in options

Option values are expanded before they reach the configure command:
built-in variables, environment variables, and user-declared project
variables (core §1.3.1) — including the configuration's compiler-specific
`overrides`, resolved against the active tool's compiler family. This is how
a compiler-conditional flag reaches the build without editing project files,
e.g. `"CMAKE_CXX_FLAGS": "${warn_flags}"` with `warn_flags` overridden for
`clang`. loomworks never parses the flag string — the variable value is an
opaque passthrough. A reference to an undeclared variable is a diagnostic,
not a silent empty string (core §1.3.1). Flag options remain allowed under
§5b; only compiler *selection* is reserved, and variable expansion never
introduces a reserved key.

Because the expanded value is what lands on the `-D` line, a change to a
variable `default` or a compiler `override` alters the resolved configure
command and so participates in `ConfigUnit:is_stale()` (§11) — the staleness
fingerprint is taken over the *resolved* option values, not the raw `${…}`
templates.

## 6. Inheritance model

Custom configurations inherit from one or more bases. Variant
(`CMAKE_BUILD_TYPE`) is derived from the first base with a variant.
Options merge depth-first left-to-right: project-wide → bases → own
(later values override). Configs without a variant-providing base are
abstract mixins — not directly buildable, only usable as bases.
Presets are not intended as inheritance bases: inheriting from a
`preset:*` configuration is permitted but warned (see §3), because the
derived configuration bypasses `--preset` and loses the preset's
cache variables and binary directory.

**Variant flows through to the build tool.** For multi-config
generators (Visual Studio, Ninja Multi-Config), the cmake `--build`
invocation passes `--config <variant>` — never the user-facing
configuration name. msbuild/Xcode only know about the underlying
variants (Debug, Release, RelWithDebInfo, MinSizeRel); a user
configuration like `debug-with-addon` that inherits Debug must build
with `--config Debug`, otherwise msbuild rejects the combination
("This project doesn't contain the Configuration and Platform
combination of debug-with-addon|x64..."). Display names, cache keys,
and `configuration_key` retain the user-facing identity. The same
rule applies to clean and target-specific build invocations.

## 7. Default configurations

Always present, auto-generated from `CMAKE_CONFIGURATION_TYPES` in
`CMakeLists.txt` or the standard cmake defaults (Debug, Release,
RelWithDebInfo, MinSizeRel). User entries in the workspace config
extend defaults (add options) rather than replace them.

## 8. Test integration

The cmake module wires into the generic test interface (core §8.9)
through a single `CTestUnit` per `ConfigUnit`, plus a shared `GTest`
helper.

### 8.1 CTestUnit

Wraps `ctest` for cmake projects. Contains all ctest test targets —
each target may have a different framework.

**Discovery flow:**

1. Run `ctest --test-dir <dir> -C <config> --show-only=json-v1`.
2. Parse JSON into test target entries.
3. For targets with `gtest_discover_tests()`: individual tests
   already present in ctest output.
4. For `add_test()` targets: probe with the GTest helper
   (`--gtest_list_tests`) to detect framework and enumerate
   individual tests.
5. Map tests to source locations via the GTest helper + cmake
   file-api data (target → source files from codemodel reply).

**`CTestTestfile.cmake` search**: When `CTestTestfile.cmake` is not
at the build root (e.g., `enable_testing()` in a subdirectory),
CTestUnit searches subdirectories depth-first (max depth 5, skipping
`_deps`, `CMakeFiles`, `.cmake`).

**`-C` flag**: Always passed (required for multi-config generators
like MSVC, harmless for single-config like Ninja).

**Execution**: Always through ctest to preserve test properties
(env, timeout, working directory, fixtures):

| Scenario | Command |
|----------|---------|
| Run all tests | `ctest --test-dir <dir> -C <cfg> --output-on-failure --output-junit <path>` |
| Run specific test | `ctest --test-dir <dir> -C <cfg> -R ^<name>$ --output-on-failure --output-junit <path>` |
| Individual gtest case (`add_test`) | Same + `GTEST_FILTER=Suite.Test` in env |

### 8.2 GTest helper

`gtest.lua` is a shared utility containing all gtest-specific
functionality. Not a TestUnit — used by `CTestUnit` and any future
TestUnit that talks to gtest binaries.

**`parse_list_tests(output, executable, target_id) → TestEntry[]`**

Parse `--gtest_list_tests` output. Strips `#` parameter suffixes.

**`probe(executable, target_id, callback)`** /
**`probe_sync(executable, target_id) → framework, entries`**

Run `--gtest_list_tests` with 5s timeout. Validate output format
(first line must be a suite ending with `.`). Returns `"gtest"` +
entries, or nil.

**`find_source_locations(test_entries, source_files)`**

Scan source files for test macros to find file + line per test
entry. Matches in priority order:

1. **Exact match**: `suite.case` from macro matches test entry
   exactly.
2. **Parameterized (`by_base`)**: runtime name `Prefix/Suite.Case/N`
   → extract base `Suite.Case` → match `TEST_P(Suite, Case)` in
   source.
3. **Fuzzy (`by_case`)**: match by case name only. Handles typed
   tests (`TYPED_TEST` registers with different suite), fixture
   inheritance, and custom macros with suite name transformations.

**Macro patterns recognized**: Any identifier containing `TEST`
followed by `(args)`. Covers: `TEST`, `TEST_F`, `TEST_P`,
`UNIT_TEST`, `UNIT_TEST_F`, `UNIT_TEST_P`, `TYPED_TEST`, etc.

**Multi-line support**: When `TEST_P(\n  suite, name, ...)`, the
scanner accumulates lines until the first two arguments are found
(max 5 lines). Handles both `TEST_P(suite, name)` on one line and
`TEST_P(\nsuite, name)` across lines.

**Source files**: Come from cmake file-api target detail (`sources`
array with paths relative to codemodel `paths.source`). Paths are
normalized via `vim.fn.fnamemodify(:p)` for consistent neotest
matching.

**`parse_xml_results(output_path) → TestResult[]|nil`**

Parse JUnit XML output (ctest `--output-junit` format). Handles
`<testcase>` with `<failure>`, `<skipped>`, `<error>` children.

**`build_filter(test_id) → string`**

Strip `test:` prefix from test ID for `--gtest_filter` value.

## 9. LSP integration

Emits two `lsp_configs` entries, both rooted at the project source path
and both keyed to the active ConfigUnit's build directory:

1. **clangd** — integration-specific fields (`binary`,
   `binary_required`, `compile_commands_dir`) documented in
   [`spec/integrations/lsp/clangd.md`](../integrations/lsp/clangd.md).
2. **qmlls** — emitted unconditionally (no QML detection); inert on
   non-QML projects since no `.qml` buffers exist to attach to.
   Integration-specific fields (`binary`, `binary_required`,
   `build_dir`, `import_paths`) documented in
   [`spec/integrations/lsp/qmlls.md`](../integrations/lsp/qmlls.md).

When the active profile carries an SDK-supplied clangd path (via the
SDK capability query for this module), the cmake module propagates it
as `binary` + `binary_required = true`. Otherwise `binary` is
unspecified and clangd falls back to stock PATH.

`compile_commands_dir` (clangd) and `build_dir` (qmlls) both resolve to
the active ConfigUnit's build directory. The qmlls integration pairs
that `build_dir` with `--no-cmake-calls` so qmlls never fires an
unsupervised CMake rebuild against the loomworks-managed tree (see
[`spec/integrations/lsp/qmlls.md`](../integrations/lsp/qmlls.md) §3). The qmlls `binary` comes from
`type_config.qmlls` (else stock PATH `qmlls`), `binary_required` from
`type_config.qmlls_required`, and optional extra QML import paths from
the `type_config.qml_import_paths` list.

## 10. Debug integration

Module language is `"c++"`. Default adapter is `codelldb`. See
[`spec/integrations/debug/codelldb.md`](../integrations/debug/codelldb.md)
for the adapter specifics.

## 11. Staleness (`inspect`)

Not implemented as file-mtime staleness. cmake under any generator (Ninja,
Make, Visual Studio) installs a regeneration rule: the generator re-runs
`cmake` automatically at build time whenever any file it read changes — the
top-level `CMakeLists.txt`, subdirectory `CMakeLists.txt`, `include()`d
`.cmake` files, and `CMakePresets.json`. loomworks therefore does not stat
those files or emit a "modified since last configure" refresh: it would be
redundant with the generator and, because it can only cheaply stat the
top-level file, strictly less accurate.

The sole loomworks-driven reconfigure triggers are the `unconfigured` /
`configure_failed` states and option-level staleness via
`ConfigUnit:is_stale()` (the configuration's `options` / `module_config`
changed since the cached configure). A plain build does not re-pass changed
`-D` cache variables, so that reconfigure is genuinely needed and is not
something the generator detects on its own.

Option values that reference project variables are fingerprinted **after**
expansion (§5c, core §1.3.1), so a change to a variable or a compiler-specific
override is caught here even though the raw `${…}` option template is
unchanged. A change of active compiler family is already covered by the build
directory being keyed on the tool, so it configures separately.

## 12. Owned `compile_commands.json` (all generators)

loomworks **owns** the clangd compilation database for every cmake
configuration, regardless of generator. It reconstructs
`compile_commands.json` from the CMake file-api and writes it into a
loomworks-owned directory under `.nvim/cache/cc/`; `lsp_configs` points
clangd at that directory. The project build directory's native
`compile_commands.json` (which the Ninja and Makefile generators emit, and
Visual Studio / Xcode do not) is **not** used for clangd by default.

Rationale:

1. **Uniform header support across generators.** Owning the database is a
   prerequisite for header-entry augmentation (§12.3), so headers get
   correct flags whether the project builds with Ninja, Make, Visual
   Studio, or Xcode.
2. **We never decode the native database.** A large project's monolithic
   `compile_commands.json` can exceed Neovim's `vim.json` decode limits.
   loomworks therefore never `vim.json.decode`s the native database — it
   decodes only the chunked, per-target file-api reply files (each small)
   and **stream-encodes** its own output (§12.2). Memory and time stay flat
   in the number of translation units.

### 12.1 The `compile_commands_generated` flag (escape hatch)

Each cmake configuration carries a module-config field
**`compile_commands_generated`** (boolean). The effective default is now
**`true` for every generator** — loomworks owns the database. The field is
the escape hatch:

- Setting it **`false`** per configuration falls back to the build
  directory's native `compile_commands.json`. This is only meaningful for
  an emitting generator (Ninja, Makefiles); on a non-emitting generator
  (Visual Studio, Xcode) there is no native database to fall back to, so
  `false` leaves clangd with nothing.
- The `compile_commands_from` redirect (§9, README) is preserved and takes
  precedence: a configuration that redirects to another configuration's
  database is never generated for — the redirect target owns its own.

When the generator is not yet known (a plain `variant:*` configuration
whose generator comes from the profile's kit at build time, not from the
configuration itself), the info-time default of the field is unresolved and
the effective decision is taken at LSP-wiring time — where it resolves to
`true` (generate) unless the configuration explicitly set the field to
`false`.

### 12.2 Reconstruction and the streaming writer

When generation is in effect, loomworks reads the file-api codemodel
(per-target `compileGroups`: `language`, `includes`, `defines`,
`compileCommandFragments`, `sourceIndexes`, plus the target `sources`) and
the resolved compiler (the file-api `toolchains` object, falling back to
the kit's compiler), then writes a `compile_commands.json`, one entry per
compiled source plus header entries (§12.3). Include and define flags are
synthesized in the compiler's native syntax: MSVC `/I`, `/D`, and
`/external:I` for system includes; GNU `-I`, `-isystem`, `-D`. For an MSVC
compiler `cl.exe` is emitted as `argv[0]` so clangd's cl-compatible driver
parses the flags. The project build directory is never written to.

The database is written **entry-by-entry** (a streaming writer): the file
is opened, `[` is written, then each entry is encoded on its own with
`vim.json.encode(entry)` and appended (comma-separated), then `]`. loomworks
never builds one giant Lua table and encodes it in a single call, and never
decodes the native database. This keeps memory and time flat for very large
projects.

### 12.3 Header entries — Tier-1 directory attribution

For each **header** that has no compiled entry of its own, loomworks
attributes it to a target and emits a `compile_commands.json` entry using
that target's flags, so clangd stops interpolating a header's flags from an
unrelated translation unit by filename proximity.

**Attribution rule (Tier-1 — no compiler, no include-scan):**

1. From the file-api, build the set of each target's **source directories**
   (the directories of the paths in its `sources`).
2. A header explicitly listed in a target's `sources` is attributed to that
   target directly.
3. Any other header is attributed to the target whose source directory is
   the **nearest ancestor** of the header's path — the longest directory
   prefix wins (compared on path boundaries, so `/a/src` is not an ancestor
   of `/a/srcfoo/x.h`). Ties (the same directory owned by more than one
   target) break deterministically: the target owning the most sources
   first, then the lexically-first target id.
4. A header no target's source directory contains is left unattributed and
   gets no entry (clangd falls back to interpolation for those only).

The entry uses the chosen target's compileGroup flags (compiler `argv[0]`,
includes, system includes, defines, compileCommandFragments) in the same
MSVC/GNU syntax as compiled sources (§12.2). The compileGroup is chosen at the
**target** level, independent of the individual header's extension: the
target's C++ group when it has one, else its C group, else its primary language
group. Preferring C++ is deliberate — headers are routinely included by C++
translation units, `.h` headers in C++ projects are common, and C++ flags are a
safe superset for clangd's purposes.

Each header entry additionally carries an explicit **language-forcing flag**
matching the chosen group's language and the compiler's flag style — MSVC
`/TP` (C++) / `/TC` (C), GNU `-x c++` / `-x c` — placed right after the
compiler (`argv[1]`), before the include/define flags and the input file.
clangd infers a `.h` (or other ambiguous extension) as C and then silently
drops C++-only flags such as `/std:c++17`; the forced flag stops it guessing
so the chosen group's flags actually apply. This applies to **header entries
only** — compiled translation units keep their own extension and are never
forced. The per-file query (§12.6) inherits the flag through the shared
renderer.

**Which headers are enumerated:** listed headers (from each target's
`sources`) are emitted directly. Headers that are merely `#include`d and not
listed — the common case — are discovered by a bounded **filesystem
directory listing** of the targets' source directories for header
extensions (this is a directory listing, **not** an include-scan and
**not** a compiler run — Tier-1), then attributed by the nearest-ancestor
rule. Enumeration is deterministic and bounded; each header is emitted once,
attributed to exactly one target.

### 12.4 Freshness

Regeneration is gated on a cheap mtime guard: the owned database is rebuilt
only when the file-api reply index is newer than the generated file (or the
generated file is absent). CMake rewrites the reply on every reconfigure —
exactly when flags can change — so this gate is both necessary and
sufficient, and makes every trigger below a no-op when nothing has advanced
(thrash-proof). clangd auto-reloads `compile_commands.json` on change, so no
server restart is needed.

Regeneration is triggered from three idempotent paths, so the owned database
refreshes whenever the native one would:

1. **LSP wiring** — `lsp_configs` runs the mtime-gated regeneration when it
   resolves the clangd entry.
2. **Configure / build task completion** — after a task that (re)configured
   the build directory completes, loomworks re-runs the mtime-gated
   regeneration for that build directory. This covers the case where the
   LSP-wiring result is memoized and `lsp_configs` is not re-invoked.
3. **File-api reply watch** — loomworks watches the file-api reply directory
   (via the workspace file tracker's `fs_poll`) and regenerates on change,
   catching reconfigures loomworks did not drive (e.g. a manual `cmake`).

All three funnel through the same mtime-gated, side-effect-idempotent
regeneration; the workspace drives them through the generic module hooks in
core §8.4 (`refresh_lsp_database` / `lsp_database_watch_path`).

### 12.5 Scope

This applies to the cmake module only. **meson gets the same owned-database
treatment in a follow-up** — for now meson still uses its native database:
meson always drives the Ninja backend, which emits `compile_commands.json`
for every compiler (including MSVC), so the field is not present on meson
configurations. Because meson does not build an owned database, it does **not**
implement `compile_command_for` (core §8.4); a per-file command query against a
meson project reports that loomworks does not own the command rather than
parsing meson's native database.

### 12.6 Per-file command query (`compile_command_for`)

cmake implements the core §8.4 `compile_command_for(ctx, file)` hook by
**redetermining** the entry from the file-api replies — the same inputs §12.2
and §12.3 build the database from — never by decoding the generated
`compile_commands.json` (which we only ever stream out, and which may exceed
`vim.json`'s decode ceiling). The result is byte-for-byte the entry the owned
database contains for that file. The own-vs-borrowed decision is made strictly
on **whether the file has its own compiled entry**, never on file type:

- **The file has its own compiled entry** — it is a path in some target's
  `compileGroup`. The command is that group's, selected by the file's source
  index — its exact per-file flags. `origin = { kind = "own" }`.
- **The file has no compiled entry** — the command is borrowed via
  `attribute_header` (§12.3): a listed file uses its listing target, otherwise
  the nearest-ancestor source directory's owning target, and the entry renders
  that target's `compileGroup` chosen at the target level (C++ group when
  present, else C, else its primary language — independent of extension, as in
  §12.3). `origin = { kind = "attributed", target, via, source }` where `via`
  is `"listed"` or `"directory"` and `source` is a representative compiled
  source of the borrowed group (or `nil`).

A header listed in `CMakeLists.txt` appears in the target's file-api `sources`
but **not** in any `compileGroup` (headers are not compiled), so it has no
compiled entry and is reported as `attributed` with `via = "listed"` — the
entry-presence gate, not a header test, is what classifies it. Files no target
claims — outside every target's source tree and not listed — yield `nil`
(unattributable). The query reuses `_target_attribution_index` and the
`cg_argv_prefix` rendering unchanged, so its command output cannot drift from
generated entries; the representative `source` is resolved from the borrowed
group's first source index in the same index.

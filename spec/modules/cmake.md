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

Emits `lsp_configs` entries for clangd. The integration-specific
fields (`binary`, `binary_required`, `compile_commands_dir`) are
documented in
[`spec/integrations/lsp/clangd.md`](../integrations/lsp/clangd.md).

When the active profile carries an SDK-supplied clangd path (via the
SDK capability query for this module), the cmake module propagates it
as `binary` + `binary_required = true`. Otherwise `binary` is
unspecified and clangd falls back to stock PATH.

`compile_commands_dir` resolves to the active ConfigUnit's build
directory.

## 10. Debug integration

Module language is `"c++"`. Default adapter is `codelldb`. See
[`spec/integrations/debug/codelldb.md`](../integrations/debug/codelldb.md)
for the adapter specifics.

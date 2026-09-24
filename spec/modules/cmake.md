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
  none of the managed `-G` / `-S` / `-B` / `-D…` flags for a preset —
  only the project's user-declared `options` are appended as `-D…`
  (and the configuration environment is set, core §1.3.3). For
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
`ConfigUnit`. This per-`Target` `artifact` is the primary output kept
build-dir-relative for test source mapping — distinct from the absolute
**resolved artifact set** used for output-conflict detection (§4.6).

### 4.6 Output artifact resolution (`resolve_artifacts`)

The cmake module implements the optional core capability
`resolve_artifacts(ctx)` (core §8) — the **resolved artifact set**: the
absolute on-disk output paths a build of this config unit produces. Core
uses it to detect and block output-artifact conflicts and to invalidate
overwritten builds; conflict granularity is **config unit** level (core
owns the caching and cross-unit indexing — see `specification.md` §8; this
section specifies only what the cmake side supplies).

`resolve_artifacts(ctx) → string[]|nil` reads the codemodel-v2 reply for
`ctx.build_dir`, sharing the same file-api reading machinery as
`parse_targets` (§4.2) but as its own documented entry point. It selects
the configuration for the context's variant via `select_codemodel_config`,
then walks the project-owned targets (the §4.3 filter) and:

1. Collects **every** entry of each target's `artifacts[]` — not just the
   primary `artifacts[1]`. A single target can emit several files (a shared
   library plus its import lib, an executable plus its `.pdb`); each is a
   distinct on-disk path that a colliding build would overwrite.
2. Resolves each artifact to an **absolute** path. file-api artifact paths
   are relative to the build directory when the artifact lands inside the
   tree, but a project that **hardcodes an output directory** outside the
   tree yields an out-of-tree path (a `..`-relative or absolute path that
   §4.2's extraction already preserves rather than discards). A relative
   path (including `..` segments) is resolved against `ctx.build_dir`;
   slashes are normalized.
3. Returns the absolute paths in **display** (original) casing. The
   compare-normalized form (lowercased on Windows via `deps.normalize`) is
   derived by core when it builds the artifact index.

When no codemodel reply exists (never configured), `resolve_artifacts`
returns `nil` — the resolved artifact set is **unknown until configure**
and is never guessed. Object/interface libraries and any target file-api
lists no `artifacts` for contribute nothing. This full absolute set is
distinct from a `Target`'s `artifact` field (§4.5), which is the single
primary path kept build-dir-relative for test source mapping.

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

## 5d. Compiler cache launcher

Core resolves a compiler-cache launcher from the effective `cache` policy
(core §1.3.2) and the active kit's compiler family, and hands it to the module
as `ctx.compiler_cache = { tool, path }` (or `nil`). The cmake module applies it
through CMake's own launcher mechanism — it never wraps the compiler driver
itself, which would collide with §5b:

- **Auto policy to tool (compiler-family-aware, core §1.3.2).** For a gcc /
  clang family kit, `auto` resolves to `ccache`, with `sccache` as the fallback
  when `ccache` is absent — both fall back to a plain compile for anything they
  cannot cache, so enabling them automatically is safe. For an **MSVC-style**
  kit (MSVC `cl`, and clang-cl), `auto` resolves to **no launcher**: sccache
  **fails** (rather than misses) a compile that writes debug info to a shared
  `.pdb` (`/Zi` / `/ZI`), and such flags can come from code loomworks does not
  control — an in-tree dependency pulled in with `FetchContent` /
  `add_subdirectory` that hardcodes `/Zi`, or a project whose policy settings
  keep CMake's `/Zi` default (below). Caching an MSVC-style build therefore
  requires an explicit `cache=sccache` or `cache=ccache` at any layer
  (configuration `variables`, `overrides.msvc` — `overrides.clang` for clang-cl —
  or the profile fill). Both named launchers are allowed on MSVC-style kits and
  get the same debug-info handling and post-configure scan below; they differ
  only in how a `/Zi` compile behaves (sccache fails it, ccache compiles it
  uncached). An explicit `ccache` / `sccache` policy uses exactly that tool on
  any family. Either way the launcher is applied only when core actually
  resolved one (present on the toolchain search path, via the shared
  `cpp_compilers` PATH index); when `ctx.compiler_cache` is `nil` the module
  adds no launcher (but see *Retraction* below).
- **Injection (Ninja / non-preset configure path).** On the manual configure
  path the module appends `-DCMAKE_C_COMPILER_LAUNCHER=<path>` and
  `-DCMAKE_CXX_COMPILER_LAUNCHER=<path>` (per language actually enabled). These
  keys are explicitly **not** reserved under §5b (only `CMAKE_<LANG>_COMPILER`
  is), so injection and the compiler-ownership rule do not conflict. CMake
  honors `CMAKE_<LANG>_COMPILER_LAUNCHER` only for the **Ninja** and
  **Makefile** generators, so injection happens only there (see the Visual
  Studio / Xcode non-goal below).
- **MSVC debug-info format.** A compile that writes debug info to a shared
  `.pdb` (`/Zi` / `/ZI`) is **failed** by sccache and compiled **uncached** by
  ccache. So when a launcher is applied to an MSVC-style kit (which, per the
  rule above, only happens on an explicit policy) **and** the generator is
  single-config **and** CMake is **>= 3.25**, the module also injects
  `-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded` (`/Z7`, per-object debug info)
  **and** `-DCMAKE_POLICY_DEFAULT_CMP0141=NEW`. The format variable only takes
  effect under policy CMP0141 `NEW`; a project whose `cmake_minimum_required` is
  below 3.25 leaves CMP0141 unset, and without the policy default CMake would
  keep putting `/Zi` in its default flags and ignore the format request. The
  policy default does not override a project that explicitly sets CMP0141 to
  `OLD` — the post-configure scan (below) reports the resulting `/Zi` compiles.
  This is applied only for MSVC-style kits and only when a launcher is applied —
  a cacheless build is left with CMake's defaults. If the user has pinned a
  conflicting value (their own `CMAKE_MSVC_DEBUG_INFORMATION_FORMAT` or
  `CMAKE_POLICY_DEFAULT_CMP0141`, or a `/Zi`-style option), the module does
  **not** silently override it: it keeps the user's value (injecting neither
  `-D`) and surfaces a non-blocking inline diagnostic that the compiler cache
  will fail (sccache) or miss (ccache) those compiles until the format is
  `Embedded`. Below CMake 3.25 (no such variable) the module skips the injection
  and notes that MSVC caching may fail (sccache) or be ineffective (ccache).
- **Post-configure PDB-flag scan (`cache_compat_scan`, core §8).** The `/Z7`
  request only changes CMake's *default* flags; a target that adds `/Zi` itself
  (e.g. a `FetchContent` / `add_subdirectory` dependency's
  `target_compile_options`) is unaffected. So after a successful configure that
  applied a launcher to an MSVC-style kit, the module scans the configuration's
  compile commands for PDB-writing debug flags — `/Zi`, `/ZI`, and the dash
  forms `-Zi`, `-ZI` — and returns one finding per affected **target** (the
  source's directory when no target is known), with the unit count and a few
  sample sources. Severity is `"error"` for sccache (those compiles will fail)
  and `"warning"` for ccache (those compiles will not be cached). The message
  says why and how to fix it: switch those targets to `/Z7` (e.g. the
  `MSVC_DEBUG_INFORMATION_FORMAT` target property set to `Embedded`, or
  replacing `/Zi` in their options), or set `cache=off` for the configuration.
  The explicit policy is never silently disabled. The scan reads the per-target
  compile commands the module already reconstructs for the owned compilation
  database (§12.2 — the file-api codemodel's `compileCommandFragments`), so it
  covers every generator and never decodes the native `compile_commands.json`
  (§12). When that data is unavailable (no codemodel reply for the build), the
  module returns `scanned = false` with the reason, and health reports the check
  as skipped (core §16.31). The scan is not run for gcc / clang family kits,
  whose launchers never fail an uncacheable compile.
  The MSVC driver also reads flags from the **`CL` and `_CL_` environment
  variables** (prepended / appended to every command line), which neither the
  file-api nor any compilation database shows. So the scan also checks the
  configuration's resolved environment (`configuration_env`, core §1.3.3 / §8
  — the variables loomworks sets for the configure and build) and reports a
  `/Zi`, `/ZI`, `-Zi` or `-ZI` token in `CL` or `_CL_` as one finding with
  `group = "environment"` (no unit count — it applies to every compile; the
  sample names the variable), with the same severities and the remedy to drop
  the flag from that variable (or use `/Z7`). Only the configuration's own
  environment is checked: a `CL` inherited from the shell that launched
  loomworks is outside loomworks' configuration and is not scanned.
- **Full reconfigure by default; in place only for the launcher keys (core §5.1
  *Faithful reconfigure*).** CMake persists configure state across reconfigures:
  cache variables stay in `CMakeCache.txt` when no longer passed, and much of it
  is computed **once**, at the first configure of a build tree, from the inputs
  in effect then — compiler detection, the default `CMAKE_<LANG>_FLAGS*` cache
  entries (which depend on policies such as CMP0141 and on environment variables
  such as `CFLAGS` / `CXXFLAGS`), `find_*` results, the toolchain file and the
  generator platform / toolset. A plain re-run of `cmake` with the new `-D` set
  therefore does not reliably apply a change. The module records every `-D` it
  passes, with its value, in `module_info.passed_options` (the configuration's
  resolved options, the launcher keys, the injected debug-info format and policy
  default, and the managed keys such as `CMAKE_BUILD_TYPE`,
  `CMAKE_<LANG>_COMPILER` and `CMAKE_TOOLCHAIN_FILE`), and on the next configure
  compares that record (`recorded_module_info`, core §8.1), the recorded
  generator (`module_info.generator`) and core's recorded configuration
  environment (`configure_env`) with what it passes now:
  - **Full reconfigure (the default).** Any difference — a `-D` added, changed
    or removed, a generator change, or a change of the configuration environment
    (core §1.3.3) — other than the in-place set below makes the module do a
    **full reconfigure**: on CMake **>= 3.24** it adds `--fresh` (CMake discards
    `CMakeCache.txt` and the `CMakeFiles/` configure state and configures from
    scratch); below 3.24 it gets the same effect by naming `CMakeCache.txt` and
    `CMakeFiles` in the configure task's `pre_configure_reset` (core §8.1), which
    core removes from the build directory under the deletion-safety rules before
    running the configure. loomworks re-passes every option it owns, so nothing
    configured through loomworks is lost; build outputs are kept, and the
    generator rebuilds only what the new configuration changes. A cache variable
    the user set by hand (`cmake -D…` outside loomworks, or `ccmake`) does not
    survive a full reconfigure — the same as `cmake --fresh`; values set in the
    project's own `CMakeLists.txt` are re-established by the configure itself.
  - **In place — the compiler-launcher keys only.** A change confined to
    `CMAKE_C_COMPILER_LAUNCHER` / `CMAKE_CXX_COMPILER_LAUNCHER` (added, changed
    or removed, and nothing else in the list above) is applied by an in-place
    reconfigure: a changed or added value is simply re-passed, and a removed one
    is retracted with `-U<key>` (placed before the `-D` flags), which removes the
    entry from `CMakeCache.txt`. This is the whole whitelist, and it is safe
    because these variables are consulted only to **initialize each target's
    `<LANG>_COMPILER_LAUNCHER` property when the target is created** — and
    targets are re-created from scratch on every configure run — while they take
    no part in compiler detection or in any first-configure-only computation. So
    an in-place reconfigure applies them exactly as a fresh configure would. The
    injected debug-info keys are deliberately **not** in the set: with policy
    CMP0141 `OLD` at the first configure, CMake wrote `/Zi` into the
    `CMAKE_<LANG>_FLAGS_<CONFIG>` cache defaults, which a later in-place
    `CMAKE_POLICY_DEFAULT_CMP0141=NEW` does not rewrite — so a cache toggle on an
    MSVC-style single-config kit (which changes those keys too) takes the full
    reconfigure. Only keys in loomworks' own record are ever retracted.
  - **No (current) record.** A unit that was configured but carries no
    `passed_options` record, or a record whose `record_version` differs from
    the module's `configure_record_version` (currently `1`; core §5.1
    *Configure record migration*, §8.1) — i.e. it was configured by an older
    loomworks, e.g. with an empty `module_info` — cannot be classified with
    certainty, so its next reconfigure is a full one (core also marks it
    stale, so the build gate runs it); it records normally from then on. This
    is what discards a compiler launcher (and the `Embedded` debug-info
    setting) an earlier version persisted in `CMakeCache.txt` but the current
    policy no longer applies. A never-configured build tree just configures.
  - **Forced.** With `force_full_reconfigure` (core §8.1, `lw build
    --reconfigure`) every configure is the full one.
  - **No change.** A reconfigure with nothing changed (e.g. a retry after a
    failed configure) runs in place with the same `-D` set.
- **Preset configurations take the full reconfigure too.** A `from_preset`
  configuration is configured with `cmake --preset <name>`; the preset supplies
  its own cache variables, and loomworks appends only the project's
  user-declared options (`-D…`, §3) and sets the configuration environment. The
  module records those appended `-D`s in `passed_options` as well, and a change
  to them (an option added, changed or **removed**) or to the configuration
  environment triggers the full reconfigure — `cmake --preset <name> --fresh` on
  CMake >= 3.24 (the `pre_configure_reset` fallback below it, the build
  directory being the preset's `binaryDir`). This re-applies the preset from
  scratch, so a removed option really disappears without any per-key `-U` that
  could clobber a value the preset itself sets. The launcher is never injected
  on the preset path (below), so the in-place set does not apply there.
- **Presets are a documented non-goal.** A `from_preset` configuration's cache
  variables — including any launcher — belong to the preset (§3), so loomworks
  does not inject the compiler-cache launcher there. The module emits a
  non-blocking warning that the compiler cache is not applied to preset
  configurations, and directs the user to set `CMAKE_<LANG>_COMPILER_LAUNCHER`
  in the preset's own `cacheVariables` if they want it. The module records
  "none" for such a configuration and reports it via `cache_launcher_applicable`
  (core §8, reason `preset`), so the preset is not launcher-stale merely because
  a cache is installed, and the profile's cache status reads
  `Cache: not applied (preset)` (ui.md) rather than naming a launcher the build
  does not use.
- **Visual Studio and Xcode generators are a documented non-goal.** CMake
  implements `CMAKE_<LANG>_COMPILER_LAUNCHER` only for the Makefile and Ninja
  generators; the Visual Studio and Xcode generators (and any other generator
  outside those two families) ignore it. So for a configuration whose resolved
  generator is not a Ninja or Makefile generator, the module injects no launcher
  (nor the MSVC debug-info keys, which exist only to serve a launcher), records
  "none", warns once that the compiler cache is not applied under that
  generator, and reports `cache_launcher_applicable = false` with reason
  `<generator> generator` and a hint that caching needs a Ninja or Makefile
  generator — so the unit is not launcher-stale on every build, the profile's
  cache status reads `Cache: not applied (<generator> generator)`, and health
  reports an informational item instead of claiming the cache is in use. A unit
  configured under such a generator by an earlier version recorded the launcher
  path; its record predates the current record version, so its next build
  takes one full reconfigure (above) that drops the launcher, after which it
  records "none" and stays stable. (Caching a Visual
  Studio build needs a different mechanism entirely; it is tracked in the
  backlog.)
- **Staleness.** The resolved launcher path is recorded in the configure task's
  `module_info` and participates in `ConfigUnit:is_stale()` (§11) on the same
  footing as resolved option values — see §11.
- **Migration from `auto`-enabled MSVC caching.** Before `auto` became
  family-aware, an MSVC-style kit with sccache (or ccache) on the path got the
  launcher under `auto`, and its configure recorded that launcher path. With the
  new rule `auto` resolves to none for that kit, so the launcher-staleness check
  (§11: recorded path ≠ expected "none") marks the unit stale and the build gate
  reconfigures it **without** the launcher on its next build. Because that
  change also drops the injected debug-info keys (single-config) — or the unit's
  record predates the current record version (which also covers a unit whose
  record is empty, so no launcher was recorded at all) — it is a full
  reconfigure (`--fresh`),
  which discards the persisted launcher and debug-info settings; the first
  build afterwards recompiles objects. Users who want to keep caching set
  `cache=sccache` explicitly.
- **A launcher-only change is applied in place (no `--fresh`).**
  `CMAKE_<LANG>_COMPILER_LAUNCHER` is the one input the module applies with an
  in-place reconfigure (re-passing the `-D`, or `-U` when it disappeared — the
  whitelist above). Because the reconfigure changes the compile command, the
  **first build after the change rebuilds objects** (repopulating the cache);
  this is expected, not a bug. This is the point of contrast with meson, which
  applies every configure-input change — the launcher included — with a full
  `meson setup --wipe` because it fixes the compiler command at setup (see
  [`meson.md` §5a](meson.md)).

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
`configure_failed` states, option-level staleness via
`ConfigUnit:is_stale()` (the configuration's resolved `options` /
`module_config` / `env` changed since the cached configure — an option or
environment variable **added, changed or removed** — or the unit's configure
record predates `configure_record_version`, §5d *No (current) record*), a
forced full reconfigure (`lw build --reconfigure`), and a **missing build
directory** — a
generic, core-driven reset (`specification.md` §3.1, rule 7) that applies to
every module, not just cmake: a `built` / `configured` unit whose build
directory has been deleted out of band reloads as `unconfigured` and
reconfigures from scratch. A plain build does not re-pass changed
`-D` cache variables, so that reconfigure is genuinely needed and is not
something the generator detects on its own. The reconfigure is **faithful**
(§5d *Full reconfigure by default*): any changed configure input is applied by a
full reconfigure (`--fresh`, or the `pre_configure_reset` fallback below CMake
3.24) — so a removed option is really gone from `CMakeCache.txt` and a changed
environment is really re-read — except a change confined to the compiler-launcher
keys, which is applied in place (re-passed, or retracted with `-U`).

Option values that reference project variables are fingerprinted **after**
expansion (§5c, core §1.3.1), so a change to a variable or a compiler-specific
override is caught here even though the raw `${…}` option template is
unchanged. A change of active compiler family is already covered by the build
directory being keyed on the tool, so it configures separately.

The **resolved compiler-cache launcher** (§5d) is fingerprinted here too: the
launcher path core resolved at configure time is stored in the configure task's
`module_info`, and `is_stale()` recomputes it (current `cache` policy + compiler
family + live toolchain-path presence) and compares. A launcher that appears,
disappears, or changes value — the cache tool was installed/removed, or the
policy was edited — marks the unit stale, and the build gate reconfigures so the
`-DCMAKE_<LANG>_COMPILER_LAUNCHER` line is re-passed in place (or retracted with
`-U` when the launcher disappeared) — unless the change also moves the MSVC
`/Z7` + CMP0141 adjustment, which takes the full reconfigure (§5d). A plain
build does not re-pass changed `-D` cache variables, so this reconfigure is
genuinely needed and is not something the generator detects on its own.

Output-artifact overwrite is a separate, **core-driven** staleness axis
(`specification.md` §5.9): it can mark a *built* unit stale when another
unit builds over a shared output, independent of this module's
option-level `is_stale()` check.

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

The writer runs **asynchronously off the main loop**: reconstruction — reading the per-target file-api replies, building the compiled-source entries and the header-attribution index, the header directory listing (§12.3), attributing the discovered headers, and the entry-by-entry stream — is sliced across scheduled turns (each phase processes a bounded, time-boxed batch of targets, headers, or entries) so a large project never freezes the UI mid-generation. Generation is **single-flight per build directory**: overlapping triggers for the same directory coalesce onto the in-flight run, and a trigger arriving mid-generation (e.g. a reconfigure landing while a run is active) marks the run *dirty* so it re-checks freshness on settle and regenerates exactly once more if still stale. The stream is written to a temporary file and atomically renamed into place only on completion, so clangd never observes a half-written database — the previous database stays readable until the new one is complete.

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

Regeneration is gated on a cheap, **synchronous** mtime guard: the owned database is rebuilt only when the file-api reply index is newer than the generated file (or the generated file is absent). CMake rewrites the reply on every reconfigure — exactly when flags can change — so this gate is both necessary and sufficient, and makes every trigger below a no-op when nothing has advanced (thrash-proof). The guard is a couple of `stat`s and one small directory scan; it stays on the calling path so a fresh database costs almost nothing. Only when the guard decides to rebuild is the reconstruction dispatched, and that work runs **asynchronously and single-flight** (§12.2), never blocking the UI. clangd auto-reloads `compile_commands.json` on change, so an in-place content update needs no server restart.

Regeneration is triggered from three idempotent paths, so the owned database refreshes whenever the native one would:

1. **LSP wiring** — when `lsp_configs` resolves the clangd entry it **schedules** the mtime-gated regeneration (it does not generate inline) and returns the generated directory immediately.
2. **Configure / build task completion** — after a task that (re)configured the build directory completes, loomworks schedules the mtime-gated regeneration for that build directory. This covers the case where the LSP-wiring result is memoized and `lsp_configs` is not re-invoked.
3. **File-api reply watch** — loomworks watches the file-api reply directory (via the workspace file tracker's `fs_poll`) and regenerates on change, catching reconfigures loomworks did not drive (e.g. a manual `cmake`).

All three funnel through the same mtime-gated, single-flight, side-effect-idempotent regeneration; the workspace drives them through the generic module hooks in core §8.4 (`refresh_lsp_database` / `lsp_database_watch_path`).

**Completion signal.** Because generation is asynchronous, the owned `compile_commands.json` may first appear *after* a clangd client is already wired for a build directory. When a regeneration actually writes the database, the module reports completion to core (§8.4 `refresh_lsp_database`'s `done` callback) and core forwards a targeted LSP re-resolution for the affected ConfigUnit's projects. In the common case the database already existed on disk (atomic-rename replacement, §12.2), so the client already started with `--compile-commands-dir` and clangd merely auto-reloads the new content — no re-resolution needed. The signal matters only when the database went from **absent to present** (e.g. a project's first-ever configure), letting clangd pick up the directory it previously had no file for without the user reopening the buffer.

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

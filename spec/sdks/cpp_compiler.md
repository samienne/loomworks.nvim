# Custom C/C++ Compiler SDK provider

Implements the core SDK provider contract (`specification.md` §10)
for **user-declared** C/C++ compiler installations — typically a
cross-compiler or a custom build that the auto-detection on `PATH`
(`lua/loomworks/cpp_compilers.lua`) wouldn't find. Lives at
`lua/loomworks/sdks/cpp_compiler.lua`. Section numbers in this file
are local.

## 1. Provider id

`P.id = "cpp_compiler"`. `P.display_name = "C/C++ Compiler"`.
`P.path_prompt = "Path to C/C++ compiler executable"` — overrides
the generic "SDK path" prompt in the Add-SDK dialog (the dialog
honours `provider.path_prompt` when present, otherwise falls back).

## 2. Detection (`detect_all`)

Returns `{}` unconditionally — these compilers are user-declared
only, never auto-scanned. The Add-SDK picker still surfaces a
`(browse for path...)` row for the provider via the generic UI
machinery.

The shared PATH scanner (`cpp_compilers.detect`) handles
auto-discovery of system compilers; this provider exists for
compilers the user explicitly opts in to (cross-compilers,
self-built toolchains, vendor builds).

## 3. Validation (`validate`)

Delegates to `cpp_compilers.probe_path(path)`. A valid result must
have:

- A working `--version` invocation
- A parseable version string

The validate return includes the fields the workspace needs for
key derivation:

| Field | Source |
|------|--------|
| `version` | parsed from `--version` |
| `family` | "clang" / "gcc" / nil (unknown) |
| `basename_token` | sanitized parent-dir name (e.g. `cross-clang` from `/opt/cross-clang/bin/clang++`), or the binary basename when no parent dir |

## 4. Key derivation (`derive_key`)

Override of the workspace default. Returns:

```
cpp_compiler-<family>-<version>-<basename_token>
```

e.g. `cpp_compiler-clang-19.0.0-cross-clang`. The path-derived
token ensures two custom builds of the same family and version
living at different paths produce distinct SDK keys — the profile
pins by key, so collisions would conflate them.

Unknown-family case: `family` becomes the literal `cpp`.

## 5. Capabilities (`query_capabilities`)

Re-probes the path at query time (so a compiler upgrade in-place
picks up the new version without manual re-registration).

Module support:

- `nil` → `{ "cmake" }` (only consumer right now)
- `"cmake"` → single-compiler caps shape (no `platforms` array)
- other → `nil`

cmake caps shape:

| Field | Purpose |
|------|---------|
| `compiler_path` | C++ driver — load-bearing |
| `cc_path` | C driver (sibling of cxx, or same as compiler_path when no C sibling) |
| `clangd_path` | Sibling clangd; **only set for Clang family** |
| `compiler_id` | "clang" / "gcc" / nil |
| `compiler_version` | dotted version string |
| `bin_dir` | directory containing the driver |
| `generator` | `"Ninja"` |

The `cmake` module's `kits_from_sdk` recognises this shape (no
`platforms` and no `toolchain_file`, but `compiler_path` set) and
emits exactly one kit. The kit's `env.CC` / `env.CXX` get set so
cmake selects the compiler at configure time; `clangd_path`
flows through to LSP via the existing routing.

## 6. Display label (`display_name_for`)

Overrides `SDK:display_name()` for resolved cpp_compiler SDKs.
Renders as `<family> <version> (custom)`:

- `Clang 19.0.0 (custom)`
- `GCC 13.2.0 (custom)`
- `C++ 7.1.2 (custom)` for unknown family

Unresolved SDKs (e.g. path removed since registration) fall back
to the default `SDK:display_name` chain.

## 7. Family knowledge containment

This provider intentionally calls only `cpp_compilers.probe_path`
for compiler identification; no `if family == "clang"` lives in
this file. The probe module is the single home for that knowledge,
shared with the PATH-scan detection. Adding a new compiler family
(Intel, IBM XL, vendor-specific) is one regex addition inside
`cpp_compilers.lua` and propagates here unchanged.

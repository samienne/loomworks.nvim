# harmony module

How the harmony module implements the core module contract
(`specification.md` §8). Section numbers in this file are local.

## 1. Detection and identity

- **Marker file**: `build-profile.json5`. `detect()` reports
  `{ marker = "build-profile.json5" }` when present.
- **Keyed tools**: no. Cache keys are `"<variant>"` only. The module
  has a single default tool whose identity does not affect the cache
  key.
- **Languages**: `"arkts"`. Native `"c++"` step-through debug is not
  yet implemented — see BACKLOG.md.
- **Device-capable**: `has_devices = true`.

## 2. Variant mapping

Harmony configurations are named `auto:<product>-<target>-<abi>` (see
§3). All variants map to the first available configuration:

| Variant type | Configuration |
|--------------|---------------|
| `"debug"` | First available config |
| `"release"` | — |
| `"release_debug"` | — |

Single-config fallback applies for the single-config case.

## 3. Configurations from build-profile.json5

Auto-generated from `build-profile.json5` as the cross product of
products × module targets × ABI filters. Each canonical name is
`auto:<product>-<target>-<abi>` (e.g., `auto:default-default-arm64-v8a`,
`auto:ohos-default-armeabi-v7a`). Products and targets come from the
build-profile; ABI filters come from the product's
`externalNativeOptions.abiFilters`. Non-native projects (no ABI
filters) use `auto:<product>-<target>` without the ABI suffix.

Each harmony configuration stores:

| Field | Description |
|-------|-------------|
| `product` | Product name |
| `target` | Build target name |
| `abi` | Architecture string (or nil) |
| `mode` | `debug` or `release` |
| `runtime_os` | `HarmonyOS` or `OpenHarmony` |
| `modules` | Hvigor module names |
| `module_name` | Primary module for build dir path |

When `build-profile.json5` changes (product added, removed, ABI
filters changed), configurations that no longer match get
`_source_missing` treatment — they remain visible but marked as
unavailable. New combinations appear as new configurations.

## 4. Build directory

Implements `resolve_build_dir` to return hvigor's cmake build
directory:

```
{workspace_root}/{project_path}/{module}/.cxx/{product}/{target}/{mode}/{abi}/
```

The path is outside the standard `.nvim/build/` tree because hvigor
owns it. It must still be under `workspace_root` for deletion safety.

## 5. Editable type_config fields

Implements `editable_type_config_fields()` to expose `cmake_env` as a
string→string dict editor:

```lua
function M.editable_type_config_fields()
    return {
        { name = "cmake_env", label = "Build environment",
          kind = "env_dict" },
    }
end
```

`cmake_env` values are passed to hvigor's cmake as environment
variables, with `${workspace_root}` expansion supported.

## 6. Device interface

Implements the full device interface (core device contract; see
`specification.md`). All device commands shell out to `hdc`, the
HarmonyOS device connector.

### 6.1 Commands

| Method | Command shape |
|--------|---------------|
| `list_devices` | `hdc list targets` |
| `device_install` | `hdc -t <serial> install <artifact>` |
| `device_launch` | `hdc -t <serial> shell aa start -a <ability> -b <bundle>` |
| `device_stop` | `hdc -t <serial> shell aa force-stop -b <bundle>` |
| `device_pid` | `hdc -t <serial> shell pidof <bundle>` |
| `device_log` | `hdc -t <serial> shell hilog -t app -L <level> [-P pid] [-T tag]` (streaming) |
| `device_log_clear` | `hdc -t <serial> shell hilog -r` |

The `device_log` command is invoked through `shell hilog` (not the
top-level `hdc hilog` passthrough, which ignores filter flags). Two
filters are applied **on the device** before lines reach the parser:

- `-t app` — restrict to app log type, dropping init / core / kmsg
  noise that dominates volume on busy devices. Always passed.
- `-L <level>` — minimum log level (`D`/`I`/`W`/`E`/`F`). Default
  `I`. The level is configurable at setup and at runtime (see §6.1.1
  below). On-device level filtering is treated as a *strict
  improvement when honoured*: if a hilog build silently ignores `-L`,
  the client-side soft filter still bounds what the user sees.

Optional `-P pid` and `-T tag` filters remain available to callers
but are not used by default — the client-side prefilter is more
permissive (matches `pid` OR `proc-contains-bundle`) and catches
helper processes that share the bundle name under different PIDs.

#### 6.1.1 Hard-level changes mid-stream

Switching the hard log level (`-L`) requires restarting the hilog
process: there is no control channel to retune a live process, and
hilog flags are command-line args read at startup. The session
tracker disposes the active stream and respawns it with the new
flag. The client-side ring buffer is preserved across the restart;
only the tail in flight during dispose/respawn (typically a few
hundred ms) is lost.

The change is asymmetric:

- **Stricter level** (e.g. `I` → `W`): instant — the new process
  drops the now-excluded levels going forward.
- **Looser level** (e.g. `W` → `I`): the new process picks up from
  "now"; lines emitted *before* the restart that didn't pass the
  old filter are not replayable. The user has to reproduce the
  action to see them.

The soft (client-side) filter is independent and operates on the
ring buffer at render time, so loosening it recovers anything the
hard filter let through.

`hdc` on Windows requires backslash-separated paths; the module
normalises `/` → `\` for install artifact paths.

### 6.2 Failure detection

`hdc` exits with status 0 even on failures. All device command specs
include a `check_output` hook that scans stdout lines for `[Fail]`
or `[F]` markers and surfaces a descriptive error.

### 6.3 `resolve_launch_info`

Extracts launch metadata from project files:

- `bundle_name` — from `app.json5`
- `ability_name` — from `module.json5`

Returned as a table passed to `device_launch()` as `launch_info`.

### 6.4 `resolve_artifact`

Locates the built HAP file within the hvigor output tree based on
the active product/target/mode.

## 7. LSP integration

Emits `lsp_configs` entries for clangd. Always sets
`binary_required = true` — stock PATH clangd cannot resolve
HarmonyOS platform headers, so falling back is actively wrong.

The clangd binary is provided by the active profile's SDK (see
[`spec/sdks/ohos.md`](../sdks/ohos.md)). The module queries the SDK
for native capabilities and propagates `clangd_path` + sysroot flags
into the `lsp_configs` entry. `compile_commands_dir` resolves to the
ConfigUnit's build directory (the hvigor-generated `.cxx` tree).

## 8. Debug integration

Module language is `"arkts"`. Native (`"c++"`) device debug via
lldb-server is designed in BACKLOG.md and not yet implemented.
ArkTS step-through debug is a larger effort also tracked in BACKLOG.

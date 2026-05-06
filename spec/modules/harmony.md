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

### 5.1 SDK env vars passed to hvigor

Every hvigor task invocation (configure / build / clean) carries
**both** SDK-path environment variables, set to the same SDK root:

- `DEVECO_SDK_HOME` — read by hvigor when targeting HarmonyOS
  (DevEco Studio's native target).
- `OHOS_BASE_SDK_HOME` — read by hvigor when targeting OpenHarmony.

The harmony module sets both unconditionally so the right one for
the active configuration's target gets picked up; the other is
harmlessly ignored. Setting them at task-time (rather than writing
`local.properties` into the project) keeps loomworks read-only
toward project files. Without `OHOS_BASE_SDK_HOME`, an
OpenHarmony-targeting profile fails hvigor sync with: *"Unable to
find 'sdk.dir' in 'local.properties' or 'OHOS_BASE_SDK_HOME' in
the system environment path."*

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
| `device_log` | `hdc -t <serial> shell hilog [-P pid] [-T tag] [-t type]` (streaming) |
| `device_log_clear` | `hdc -t <serial> shell hilog -r` |

The `device_log` command is invoked through `shell hilog` (not the
top-level `hdc hilog` passthrough, which ignores filter flags). The
filtering strategy mirrors what DevEco Studio surfaces as "All logs
of selected App":

- `-P <pid>` — passed by the session tracker once the app's PID has
  resolved. The primary volume reducer: it limits the stream to the
  app's own process across **all log types**, which is what the
  user actually wants when watching an app run. Native HarmonyOS
  code that logs through `OH_LOG_Print(LOG_CORE, ...)` comes through
  alongside ArkTS `LOG_APP` traffic, because both run in the same
  process.
- **No `-L <level>` at the device.** Hilog's `-L` flag interacts
  badly with native log paths in practice — some native lines users
  expect to see get suppressed even at `-L D`. Level filtering is
  done entirely client-side via the soft filter on the ring buffer,
  which is reliable, fast, and can be retuned live without
  restarting the stream.
- **No `-t <type>` filter by default**. Native log calls land on
  type `core`, not `app`, so restricting to `app` would silently
  drop half the stream. Callers may pass `opts.type` if they have a
  specific reason to filter.

The client-side prefilter (pid OR proc-contains-bundle) still runs
as defense-in-depth and to catch transient PID changes. When the
device honours `-P`, the prefilter is mostly redundant; when it
doesn't, the prefilter remains the correctness backstop.

#### 6.1.1 Soft-level changes mid-stream

Setting the level via `loomworks.set_device_log_level(...)` or
`:LoomworksDeviceLogLevel <D|I|W|E|F>` updates the **client-side
soft filter** on the live view. The ring buffer re-renders against
the new level; nothing is lost, no process is killed.

This makes loosening the level (`W` → `I`) genuinely recover
history — every record in the ring buffer is reconsidered. The
asymmetry that earlier hard-level filtering had is gone, since the
hilog stream is unfiltered by level and every line that ever came
through is in the buffer.

#### 6.1.2 Helper-process logs (`device_log_strict_pid = false`)

Some apps spawn helper processes that emit hilog lines under a
different PID but for the same bundle. With strict PID filtering
on (the default), those lines are dropped on the device. Setting
`device_log_strict_pid = false` at setup tells the session tracker
to omit `-P` from the hilog command; the client-side prefilter (pid
OR proc-contains-bundle) then becomes the only PID guard, and
helper-process logs flow through. Volume increases — measurably on
busy devices — so this is opt-in.

`hdc` on Windows requires backslash-separated paths; the module
normalises `/` → `\` for install artifact paths.

### 6.2 Failure detection

`hdc` exits with status 0 even on failures. Without output parsing,
the build → deploy → install → launch chain falls through silently
on a failed install and the device launches the previously-installed
version of the app — the most confusing failure mode for the user.

All device command specs include a `check_output` hook that scans
stdout lines. Each candidate line is normalised first by `clean()`
which strips a leading `[INFO]`/`[WARN]`/`[ERROR]`/`[DEBUG]`-style
log tag (3+ word chars between brackets, so legacy `[F]` survives)
and then, if a `msg:` field is present, takes only the value of that
field. The cleaned form is then matched against three failure shapes:

- **Legacy markers**: raw line contains `[Fail]` anywhere, or starts
  with `[F]`. Emitted by some older hdc subcommands.
- **Plain `error:` lines**: cleaned form starts (case-insensitively)
  with `error:`. Emitted by some hdc subcommands directly.
- **`hdc install` `[INFO]`/`msg:` shape**: the wire format wraps the
  bundle-manager rejection inside an [INFO]-tagged log line, e.g.
  `[INFO]App install path:/data/local/tmp/foo.hap msg:error: failed
  to install bundle.`. After `clean()` strips the tag and takes the
  `msg:` value, the result starts with `error:` — caught by the same
  rule as the plain shape.

When a failure line is found, the hook aggregates immediately-following
`code:<N>` and `error:` lines (also through `clean()`, so `[INFO]`-tagged
continuations work) until a blank line breaks the block. The pieces
are concatenated into the surfaced error — DevEco Studio's
"Install Failed:" presentation, condensed onto one line. Example:

> `error: failed to install bundle. code:9568320 error: no signature file.`

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

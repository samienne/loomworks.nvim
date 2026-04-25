# OpenHarmony / HarmonyOS SDK provider

Implements the core SDK provider contract (`specification.md` §11)
for the OpenHarmony / HarmonyOS toolchain shipped inside DevEco
Studio. Lives at `lua/loomworks/sdks/ohos.lua`. Section numbers in
this file are local.

## 1. Provider id

`P.id = "ohos"`. `P.display_name = "DevEco Studio"`.

## 2. Detection (`detect_all`)

Scans common DevEco Studio installation locations on the host:

- Windows: `C:\Program Files\Huawei\DevEco Studio*`,
  `C:\DevEco Studio*`
- macOS: `/Applications/DevEco-Studio.app`,
  `~/Applications/DevEco-Studio.app`
- Linux: `/opt/deveco-studio*`, `~/deveco-studio*`

Plus user-provided override path. Each candidate is realpath'd and
deduplicated case-insensitively.

For each candidate it reads `product-info.json` for the IDE version,
falling back to
`sdk/default/openharmony/oh-uni-package.json` for the SDK version.

Returns `{ path, version }[]` entries.

## 3. Validation (`validate`)

A path is valid when both the SDK root and the OpenHarmony tooling
shape exist:

- `<path>/sdk/default/openharmony/native/` — toolchain bundle
- One of `ohos.toolchain.cmake` or `hmos.toolchain.cmake` under the
  expected prefix

Validation does not require all tools to resolve — missing tools are
reported as `nil` capability fields rather than rejecting the SDK.

## 4. Capability query (`query_capabilities`)

`module_id == nil` returns the supported module ids:
`{ "cmake", "harmony" }`.

### 4.1 harmony module capabilities

```lua
{
    deveco_home  = path,
    node         = .../tools/node/node,
    hvigorw_js   = .../tools/hvigor/bin/hvigorw.js,
    ohpm         = .../tools/ohpm/bin/ohpm,
    hdc          = .../sdk/default/openharmony/toolchains/hdc,
    java         = .../jbr/bin/java,
}
```

The harmony module uses these to invoke hvigor, push/inspect
artifacts via hdc, and run scripts under the SDK's bundled Node.

### 4.2 cmake module capabilities

Offers one platform entry per available toolchain (HarmonyOS,
OpenHarmony, or both):

```lua
{
    platforms = { {
        name = "HarmonyOS",        -- or "OpenHarmony"
        toolchain_file = "...",
        archs = { "arm64-v8a", "armeabi-v7a" },
        arch_args = {
            ["arm64-v8a"] = { "-DOHOS_ARCH=...", "-DOHOS_SDK_NATIVE=...", ... },
            ...
        },
    }, ... },
    cmake_path = .../native/build-tools/cmake/bin/cmake,
    clangd_path = .../native/llvm/bin/clangd,
    clangd_required = true,
    sdk_display = "DevEco Studio <version>",
}
```

`clangd_required = true` because the SDK-bundled clangd knows
platform headers that stock PATH-clangd cannot locate. Falling back
would silently produce wrong index data.

### 4.3 No capability for unknown modules

Returns `nil` when queried with a `module_id` this provider doesn't
support. Core treats `nil` as "this SDK has nothing to offer this
module" and falls through to host-tool detection (or marks the
profile incomplete if no host tool selection exists).

## 5. Tool key derivation

When a profile selects this SDK, the cmake module derives keyed tools
from the `platforms` list: each `(platform, arch)` pair becomes a
distinct tool with key `"<platform>-<arch>"` (lower-cased, e.g.
`"harmonyos-arm64-v8a"`). Tool labels read `"<sdk_display> /
<platform> / <arch>"`.

## 6. SDK identity persistence

When the user pins this SDK to a profile, the profile stores
`sdk_key` in user.json. On reload, the SDK is resolved by `key`
against the workspace's known providers. If the SDK provider is no
longer detectable (DevEco moved, uninstalled), the profile renders as
incomplete with a rebase action.

## 7. Future direction

Profile-level SDK selection is documented as design-ready in
BACKLOG.md. The current shape resolves SDK-supplied tools lazily via
`Profile:tool_for(module)` rather than persisting them in the
profile's `tools` dict. That keeps SDK refresh cheap (re-query on
load) at the cost of slightly more code in the access path.

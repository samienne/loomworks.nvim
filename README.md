# loomworks.nvim

Workspace management for Neovim. Provides project structure, build
configurations, and toolchains to other plugins (LSP, overseer, DAP).

**Assistive, not authoritative** — loomworks reads your existing project files
(CMakeLists.txt, CMakePresets.json, etc.) and helps coordinate them. It never
modifies your project files and collaborators don't need to know it exists.

## Status

Early development (v0.0.1-dev). The cmake, harmony, and meson modules are fully
implemented; shell provides a generic command runner for self-managed builds;
typescript is a shim.

## Features

- **Multi-project workspaces** — manage cmake, meson, harmony, shell, and
  typescript projects from a single `loomworks.json`
- **CMake preset support** — reads `CMakePresets.json` and
  `CMakeUserPresets.json` with full inheritance
- **Automatic tool detection** — finds MSVC (via vswhere), GCC, and Clang
  compilers; generates profile combinations with Ninja/Visual Studio generators
- **Configuration sets** — group build variants across projects (e.g. "Debug"
  maps ProjectA to Debug and ProjectB to development)
- **Profiles** — fully resolved buildable units combining a configuration set
  with a toolchain. Activate, build, and manage profiles from the status page
- **Overseer integration** — auto-generates configure and build tasks, tracks
  completion, records state to cache
- **clangd integration** — auto-injects `--compile-commands-dir`, restarts
  clangd when switching profiles, OOM-adaptive `-j` step-down with nvim
  LSP log rotation, throttle 4 attempts / 5min, UI Reset action
- **Lualine component** — winbar showing active profile/project/configuration
- **Live file watching** — reloads automatically when config files change
- **Status page** — `:LoomworksInfo` shows workspace state with folding, status
  icons, spinner animations, and build progress

## Requirements

- Neovim >= 0.9
- [snacks.nvim](https://github.com/folke/snacks.nvim) (for window management)
- [overseer.nvim](https://github.com/stevearc/overseer.nvim) (for task running)
- Optional: [fidget.nvim](https://github.com/j-hui/fidget.nvim) (for progress
  notifications outside the status page)

## Setup

loomworks.nvim is loaded as a standard Neovim plugin. With lazy.nvim:

```lua
{
  "your-user/loomworks.nvim",
  event = "VeryLazy",
}
```

By default, loomworks auto-loads when you open Neovim in (or `:cd` to) a
directory containing `loomworks.json`. You can also initialize manually:

```vim
:LoomworksInit
:LoomworksInit /path/to/workspace
```

### Auto-load options

```lua
require("loomworks").setup({
  auto_load = "auto",  -- default: always load silently, notify via vim.notify
  keys = true,         -- default: register default keymaps (false to disable)
})
```

| Value | Behavior |
|-------|----------|
| `"auto"` | Load silently when `loomworks.json` is found in cwd |
| `"cached_only"` | Load silently only if the workspace has been used before |
| `"prompt"` | Load cached workspaces silently, prompt for new ones |
| `false` | Never auto-load, only manual `:LoomworksInit` |

### Default keymaps

`setup()` registers these keymaps by default (disable with `keys = false`):

| Key | Action |
|-----|--------|
| `<leader>ww` | Toggle loomworks status page |
| `<leader>wb` | Build default target |
| `<leader>wB` | Build active profile |
| `<leader>wr` | Debug target (build + deploy + nvim-dap) |
| `<leader>wR` | Launch target without debugger |
| `<leader>ws` | Select profile |
| `<F5>` | Debug target |
| `<S-F5>` | Stop running launch |
| `<leader>tt` | Debug nearest test |
| `<leader>tT` | Run nearest test |
| `<leader>tf` | Debug file tests |
| `<leader>tF` | Run file tests |

When nvim-dap is not installed, debug keymaps silently fall back to
launching/running without the debugger.

### Debug adapter configuration

DAP adapter selection is per module type. Configure in `user.json`:

```json
{
  "debug": {
    "adapters": {
      "cmake": "codelldb"
    }
  }
}
```

Defaults: cmake → `codelldb`, typescript → `pwa-node`. If omitted,
defaults apply. The adapter selection can also be changed from the
status page (Debug Adapters section).

When a debug adapter is not installed, loomworks shows a notification
with a Mason install hint and falls back to launching without the
debugger.

## Configuration

Create a `loomworks.json` at your workspace root:

```json
{
  "projects": {
    "MyApp": { "cmake": {} },
    "MyLib": { "cmake": {} },
    "Frontend": { "typescript": {} }
  },
  "configuration_sets": {
    "Debug":   { "MyApp": "Debug",   "MyLib": "Debug",   "Frontend": "development" },
    "Release": { "MyApp": "Release", "MyLib": "Release", "Frontend": "production" }
  }
}
```

### Project types

Projects are declared with their type as the inner key:

```json
{
  "MyProject": { "cmake": {} }
}
```

Available types: `cmake` (full), `meson` (full), `harmony` (full),
`shell` (generic runner — see `spec/modules/shell.md`), `typescript` (shim).

### Paths

By default, the project key is used as the relative path from the workspace
root. Override with `path` if the directory name differs:

```json
{
  "MyProject": {
    "path": "packages/my-project",
    "cmake": {}
  }
}
```

### CMake overrides

```json
{
  "MyProject": {
    "cmake": {
      "configurations": {
        "my-release": {
          "inherits": "variant:Release",
          "options": { "ENABLE_PROFILING": "ON" }
        },
        "ohos-debug": {
          "inherits": "variant:Debug",
          "toolchain": "${OHOS_NDK_HOME}/cmake/ohos.toolchain.cmake"
        }
      },
      "compile_commands_from": "ninja-debug"
    }
  }
}
```

- **Configuration name tiers**: module-emitted configs are canonical
  `prefix:name` (cmake built-ins as `variant:Debug`/`variant:Release`,
  CMakePresets entries as `preset:<name>`, harmony project configs as
  `auto:<product>-<target>-<abi>`). User-declared configs go under any
  name without `:` and typically use `inherits:` to extend an auto-gen.
  Configs sharing a project's type can freely reference each other by
  canonical name. The `:` ban on user names is enforced by validation.
- **Toolchain paths**: use `${ENV_VAR}/path` (expanded at runtime). Absolute
  paths are forbidden in `loomworks.json` to keep it portable.
- **`compile_commands_from`**: source `compile_commands.json` from another
  configuration (e.g. MSVC build + Ninja companion for clangd).

### Configuration sets

Map configuration names across projects:

```json
{
  "configuration_sets": {
    "Debug":   { "ProjectA": "variant:Debug",   "ProjectB": "variant:development" },
    "Release": { "ProjectA": "variant:Release", "ProjectB": "variant:production" }
  }
}
```

When combined with detected cmake tools, profiles are auto-generated:
`Debug:ninja-gcc-14.2.0`, `Debug:msvc-17-2022-enterprise`, etc.

Profiles store their toolchain as a **flat array of tool keys** in
user.json / loomworks.json:

```json
"profiles": {
  "Debug:ninja-gcc-14.2.0": {
    "configuration_set": "Debug",
    "tools": ["ninja-gcc-14.2.0"]
  },
  "Debug-harmony:ohos-harmonyos-arm64-v8a": {
    "configuration_set": "Debug-harmony",
    "tools": ["ohos-harmonyos-arm64-v8a"]
  }
}
```

The picker behind the profile's `Toolchain:` row offers every detected
host tool plus every kit each SDK exposes, and you add / remove
entries with `+ Add tool` / `D`. Multi-language profiles (e.g. cmake
+ rust) carry one tool per language family.

#### Custom C/C++ compilers

For compilers not on `PATH` — cross-compilers, snapshot builds,
vendor distributions — add them via the SDK section's `▸ Add SDK`
action. The picker includes a `C/C++ Compiler  (browse for path...)`
entry; selecting it prompts for the compiler executable path.

The probe identifies the compiler family (Clang / GCC) from
`--version`, finds the sibling C driver (e.g. `clang` next to
`clang++`), and — for Clang only — picks up the sibling `clangd`
binary for LSP. Everything else falls back to a generic
CC/CXX-passthrough kit.

The resulting kit appears in the toolchain picker like any other,
including its family in the label: `Clang 19.0.0 (custom)`, `GCC
13.2.0 (custom)`. Profile pinning, completeness checks, and the
diagnostic gates all work unchanged.

### Languages

Each cmake / meson configuration declares the languages it builds
(`{"c", "c++"}` by default; user override per configuration). The
language list drives which tool in `profile.tools` applies — a
profile is *complete* only when every language a configuration
declares has a tool in the array providing it. Tools declare their
language coverage at construction (host kits via
`detect_tools`, SDK kits via `kits_from_sdk`).

```json
"MyProject": {
  "cmake": {
    "configurations": {
      "cpp-only": {
        "inherits": "variant:Debug",
        "languages": ["c++"]
      }
    }
  }
}
```

After every cmake configure, the file-api codemodel is read and the
actual enabled languages are compared against the declaration. A
non-blocking "language drift" diagnostic surfaces if they disagree.

### Launch configurations

Define how to run a project after building:

```json
{
  "ScenePluginTest": {
    "typescript": {},
    "launch": {
      "debug": {
        "command": "node",
        "args": ["app.js"],
        "working_dir": "${workspace_root}/ScenePluginTest",
        "env": { "NODE_PATH": "${workspace_root}/ScenePluginTest/Debug" }
      }
    }
  }
}
```

Variables available: `${workspace_root}`, `${build_dir}`, `${variant}`,
`${config_set}`, `${project_path}`, plus user-defined project variables.

### Deploy steps

Copy build artifacts between projects before launch:

```json
"launch": {
  "debug": {
    "command": "node",
    "args": ["app.js"],
    "deploy": {
      "${build_dir}/native.node": {
        "project": "NativeLib",
        "target": "native_lib"
      }
    }
  }
}
```

Deploy steps ensure the correct file is present regardless of which
configuration was last built. Freshness is tracked per destination —
files are only copied when the source changes or the configuration switches.

Deploy can also be declared at the **project level** (applies to every
launch, build, and device target for that project), and individual steps
can set `"pre_build": true` to run **before** the target is built —
useful for bundling native libraries into a HAP or APK where the file
must be an input to the build:

```json
"NativeDemo": {
  "harmony": { ... },
  "deploy": {
    "${workspace_root}/NativeDemo/entry/libs/arm64-v8a/": {
      "project": "NativeLib",
      "target": "my_lib",
      "pre_build": true
    }
  }
}
```

When the same destination appears at both project and launch level,
directories union (both sets of files copied) and file destinations
override (launch wins).

### Device deployment (harmony)

For project types that deploy to physical or emulated devices (currently
harmony via `hdc`), the status page shows a **Device** line in the active
profile when the workspace has device-capable modules. Press `<CR>` to
scan and pick a connected device — the selection is persisted per profile
in `user.json`.

The launch target picker offers `[device: Run on device]` entries for
harmony projects. Selecting one changes the launch chain to:

```
build → deploy → install on device → launch on device
```

The harmony module parses `app.json5` for the bundle name and
`module.json5` for the ability name, locates the HAP output from hvigor,
and invokes `hdc install` and `hdc shell aa start` on the selected device.

No explicit configuration is needed — the device targets are generated
by the module from the active configuration.

After launch, a device-log view opens at the bottom of the frame
streaming `hdc hilog` output parsed and filtered to the running app
(default filter: app PID AND proc matches bundle; interactive keymaps
inside the view for level / regex / layout). `<S-F5>` force-stops the
app on the device (`hdc shell aa force-stop`). Toggle the log view
from anywhere with `<leader>wO`.

The hilog stream is invoked with `-P <pid>` so only the app's own
process emits, across all log types. This matches DevEco Studio's
"All logs of selected App" behaviour and brings native `LOG_CORE`
logs through alongside ArkTS `LOG_APP` traffic. Level filtering is
done client-side on the ring buffer rather than via hilog's `-L`
flag, because `-L` suppresses some native log paths in practice.

```lua
require("loomworks").setup({
  device_log_level = "W",          -- soft filter level: D | I | W | E | F (default: I)
  device_log_strict_pid = false,   -- omit -P pid; let helper-PID logs through (default: true)
})
```

```vim
:LoomworksDeviceLogLevel W   " retunes the live soft filter
:LoomworksDeviceLogLevel     " query current level
```

Changing the level re-renders the ring buffer against the new
threshold, so loosening (`W` → `I`) recovers history. The hilog
stream itself is not restarted.

Set `device_log_strict_pid = false` if your app spawns helper
processes whose logs you need; the client-side prefilter (pid OR
proc-contains-bundle) then becomes the only PID guard. Volume goes up.

### Progress notifications

When fidget.nvim is installed, build/configure progress shows up
as fidget popups. Two compaction passes keep the popup width
reasonable on real-world projects:

- Per-tool parsers compact known patterns. Ninja's `[N/M] Building
  CXX object src/some/very/deep/path/file.cpp.o` is rendered as
  `[N/M] Building CXX object file.cpp.o` — verb kept, path stripped
  to basename.
- All fidget messages are clipped to a max width as a safety net.
  Default is 60 chars; configure with `progress_max_width`:

```lua
require("loomworks").setup({
  progress_max_width = 80,   -- default: 60
})
```

Clipping appends a `…` so it's visually obvious the line was cut.

If a fidget popup gets stuck spinning after every overseer task has
already completed (typically because a dap session terminated before
initialising, or an adapter wasn't configured), `:LoomworksFidgetClear`
cancels every outstanding handle so you can recover without
restarting Neovim.

### Project variables

Declare typed variables with defaults, override per configuration:

```json
{
  "App": {
    "cmake": {
      "configurations": {
        "Debug":   { "variables": { "output_dir": "${project_path}/dist/debug" } },
        "Release": { "variables": { "output_dir": "${project_path}/dist/release" } }
      }
    },
    "variables": {
      "output_dir": { "type": "path", "default": "${project_path}/dist" }
    }
  }
}
```

Types: `string`, `path`. Variables are usable in launch configs and deploy
destinations as `${output_dir}`. Configuration overrides follow the
inheritance chain. Editable from the status page (Projects and Configuration
editors).

## Concepts

**Configuration set** — a cross-project mapping declared in `loomworks.json`.
Says "Debug means Debug for MyApp and development for Frontend."

**Profile** — a fully resolved buildable unit: configuration set + toolchain
selection. For example, `Debug:ninja-gcc-14.2.0` pairs the "Debug"
configuration set with the Ninja generator and GCC 14.2 compiler. Profiles
are what you activate, build, and delete.

**Tool** — a module-specific toolchain choice. For cmake this means a
generator + compiler combination (e.g., Ninja + GCC 14.2). Detected
automatically from your system.

## Commands

| Command | Description |
|---|---|
| `:LoomworksInit [path]` | Initialize workspace from directory (default: cwd) |
| `:LoomworksInfo` | Open workspace status page |

## Status Page

`:LoomworksInfo` opens a status page with the following sections:

1. **Header** — plugin version, workspace name, root path
2. **Diagnostics** — structural warnings/errors aggregated from across the
   workspace (incomplete profiles, source-missing configurations, stale
   `configuration_set` mappings, unresolved inherits chains,
   tool/configuration mismatches — e.g. a profile picking a HarmonyOS
   arm64-v8a kit while mapping a project to an OpenHarmony product).
   Hidden when everything is healthy. Pressing `<CR>` on an entry jumps to
   the relevant tree node, with `<C-o>`/`<C-i>` returning you back.
3. **Profiles** — all materialized profiles with build status
4. **Orphaned Items** — cached configs no longer referenced by any profile,
   plus stray build directories not tracked in cache (hidden when empty)
5. **Configuration Sets** — declared sets with available tool entries
6. **Projects** — all projects with their configurations and build state.
   CMake projects also show discovered build targets (grouped by type)
   after configure, including output paths and link dependencies.

### Keybindings

| Key | Action |
|---|---|
| `<Tab>` | Toggle fold on the current node |
| `<CR>` | Activate profile (materializes if needed) |
| `b` | Build profile or configuration |
| `c` | Configure (cmake configure) |
| `p` | Pin a configuration as a standalone profile |
| `o` | Show build options (cmake cache variables) |
| `R` | Clean + rebuild (destructive) |
| `C` | Clean — reset to unconfigured, delete build dir (destructive) |
| `D` | Delete profile or configuration (destructive, with confirmation) |
| `L` | Load workspace from cwd / rescan tools |
| `K` | Hover popup with the full content of the current line (paths, diagnostic messages, etc.) |
| `<C-n>` | Reset workspace: delete `.nvim/build/` + cache, reload (destructive) |
| `?` | Show help dialog |
| `q` | Close the status page |

Actions walk upward from the cursor to find the nearest actionable node.
Pressing `b` on a detail line triggers the build action of the parent
profile or configuration.

### v2 UI (preview, opt-in)

A redesigned three-pane workbench is available alongside the existing
status page. It runs in parallel — v1 (`<leader>ww`) is unchanged and
remains the default; v2 is opt-in.

| Key | Action |
|---|---|
| `<leader>wW` | Toggle the v2 workbench |
| `<leader>wp` | Open the v2 command palette (works from any buffer) |

The workbench has three panes — a workspace overview, a per-item
inspector, and an activity strip with both a live-task view and a
plan view of the active profile's execution chain. Editing happens
in place (no modal dialog chains): `<CR>` selects, `e` edits the
field at cursor, `E` opens wire mode for deploy steps, `D` deletes
with confirmation, `R` renames.

Layout configuration:

```lua
require("loomworks.ui.v2").setup({
    layout = "float",  -- or "tabpage"
    float = {
        margin = 2,
        overview_width = 0.4,
        activity_height = 0.25,
        pane_gap = 0,
        border = "rounded",
    },
})
```

See `spec/ui-v2.md` for the full design and key reference. v2 will be
promoted to default once it has been validated in real-world use.

## clangd / LSP Integration

loomworks ships a plugin-style LSP integration layer. By default, calling
`require("loomworks").setup({})` auto-installs a clangd config via the
native `vim.lsp.config` + `vim.lsp.enable` API — you don't need
`nvim-lspconfig` or any other LSP plumbing for the common case.

### Zero-config

```lua
require("loomworks").setup({})
-- clangd is now enabled with sensible defaults:
--   cmd = { "clangd", "--background-index", "--clang-tidy", "--header-insertion=iwyu" }
-- Inside a workspace project, the active profile's compile_commands_dir and
-- (if the profile uses an SDK) the SDK-bundled clangd binary are used.
-- Outside any workspace, the default cmd is used.
```

### Overriding the clangd config

```lua
require("loomworks").setup({
  lsp = {
    clangd = {
      cmd = { "clangd", "--background-index", "-j=12" },
      capabilities = require("blink.cmp").get_lsp_capabilities(),
      on_attach = my_on_attach,
      settings = { clangd = { fallbackFlags = { "-std=c++20" } } },
    },
  },
})
```

Your `cmd` is used as the base/fallback — **inside a workspace project,
the active profile's clangd binary (when the profile uses an SDK) still
wins over your cmd[1]** and `--compile-commands-dir` is appended
automatically. Outside the workspace, your cmd is used as-is.

### Opt-outs

```lua
require("loomworks").setup({
  lsp = false,                             -- disable LSP setup entirely
})

require("loomworks").setup({
  lsp = { clangd = false },                -- skip only clangd
})
```

### Buffer excludes

By default, loomworks skips LSP attachment to buffers that language
servers generally can't handle (diffview, fugitive, octo, gitsigns,
quickfix, help, nofile, terminal, …). Override:

```lua
-- Extend defaults:
require("loomworks").setup({
  lsp = {
    excludes = function(defaults)
      table.insert(defaults.bufname_patterns, "^my-plugin://")
      return defaults
    end,
  },
})

-- Replace defaults entirely:
require("loomworks").setup({
  lsp = {
    excludes = {
      bufname_patterns = { "^only-this://" },
      buftypes = {},
    },
  },
})

-- Disable entirely:
require("loomworks").setup({ lsp = { excludes = false } })
```

Read the defaults programmatically with `require("loomworks.lsp").default_excludes()` — it returns a fresh deep copy.

### lspconfig / legacy path

If you already use `nvim-lspconfig` and want to keep that flow:

```lua
require("loomworks").setup({ lsp = false })  -- don't let loomworks register clangd

local lsp = require("loomworks.lsp")
require("lspconfig").clangd.setup({
  cmd = lsp.clangd_cmd({ "clangd", "--background-index" }),
  root_dir = lsp.clangd_root_dir(),
})
```

### Adding a new LSP server

Drop a file into your runtime path at
`lua/loomworks/integrations/lsp/<server>.lua` following the integration
contract in [specification.md §9.3](specification.md). Every plugin on
`runtimepath` is scanned at startup, so no other wiring is needed.

### Behavior

- clangd restarts automatically when profile switches change the
  `compile_commands_dir` or resolved binary.
- SDK-provided clangd is required for SDK profiles (e.g. harmony); when
  its binary is missing, loomworks refuses to start clangd rather than
  falling back to a stock PATH clangd that can't find platform headers.

## Lualine Component

Show the active profile context in your winbar or statusline:

```lua
require("lualine").setup({
  winbar = {
    lualine_c = {
      { "loomworks" },
    },
  },
})
```

Default display: `Debug > MyApp/Debug [ninja-gcc-14.2.0]`

Customize which parts to show:

```lua
{ "loomworks", show = { "project", "configuration" } }
```

Available fields: `set_name`, `project`, `configuration`, `tool_key`,
`profile_key`, `status`.

## Workspace File Layout

```
workspace-root/
├── loomworks.json               Published snapshot. Optional. Commit or gitignore, your choice.
│                                Regenerated on :w from the working copy; never read at runtime.
└── .nvim/
    ├── loomworks.user.json      Always gitignored. Live working state and runtime
    │                            source of truth (projects, config sets, profiles,
    │                            active selection, intent overrides).
    ├── loomworks.cache.json     Always gitignored (build state).
    └── build/
        ├── ProjectA/
        │   ├── Debug/
        │   └── Release/
        └── ProjectB/
```

## API

```lua
local lw = require("loomworks")

-- Workspace
lw.setup({ root = "/path/to/workspace" })
lw.get_workspace()                          -- Workspace data
lw.get_active_configuration_set()           -- merged ActiveSet

-- Profiles
lw.get_profiles()                           -- all Profile objects
lw.get_active_profile()                     -- active Profile or nil

-- Configuration sets
local config_sets = lw.get_config_sets()    -- all ConfigurationSet objects
for _, cs in pairs(config_sets) do
  cs:activate()                             -- activate (materializes if new)
  cs:activate(tool_entry)                   -- activate with tool selection
end

-- Projects
lw.get_projects()                           -- all Project objects
lw.project_for_buf(bufnr)                   -- find project for buffer

-- Buffer status (for statusline/winbar)
lw.buf_status(bufnr)                        -- { project, configuration, status, ... }

-- Events
lw.on("active_set_changed", function(active_set)
  -- React to profile switches, task completions, file changes
end)
```

### Profile object

```lua
local profile = lw.get_profiles()["Debug:ninja-gcc-14.2.0"]

profile.key                   -- "Debug:ninja-gcc-14.2.0"
profile.configuration_set     -- "Debug"
profile.tool_key              -- "ninja-gcc-14.2.0"
profile.tool_label            -- "Ninja + GCC 14.2.0"
profile.mappings              -- { MyApp = "Debug", MyLib = "Debug" }

profile:status()              -- "built", "DiagnosticOk" (label + highlight)
profile:is_configured()       -- true if any cached entries exist
profile:is_running()          -- true if any tasks running
profile:projects()            -- ProfileProject[] sorted by key
profile:activate()
profile:build()
profile:configure()
profile:delete(on_done)
```

### Project object

```lua
local proj = lw.get_projects()["MyApp"]

proj.key                      -- "MyApp"
proj.type                     -- "cmake"
proj.configuration            -- "Debug" (from active profile)
proj.configuration_key        -- "Debug:ninja-gcc-14.2.0"
proj.status                   -- "built"
proj.orphaned                 -- false
proj.configurations           -- { Debug = {...}, Release = {...} }

proj:running_action()         -- "configure" | "build" | nil
```

## Build States

Each configuration tracks its build state:

| State | Meaning |
|---|---|
| `unconfigured` | Never configured |
| `configured` | Configure succeeded, not yet built |
| `built` | Build succeeded |
| `configure_failed` | Configure attempted and failed |
| `build_failed` | Build attempted and failed |
| `unknown` | Build directory may be partially deleted (cleanup interrupted) |

Orthogonal flags: `needs_refresh` (project files changed since last configure),
`orphaned` (project in cache but removed from loomworks.json).

Failed states are never auto-cleaned — only explicit user action (`C` or `D`)
removes them. Configs in `unknown` state block build/configure until cleaned
or deleted.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation architecture and
[specification.md](specification.md) for the full behavioral specification.

## License

TBD

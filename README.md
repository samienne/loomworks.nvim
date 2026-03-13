# loomworks.nvim

Workspace management for Neovim. Provides project structure, build
configurations, and toolchains to other plugins (LSP, overseer, DAP).

**Assistive, not authoritative** — loomworks reads your existing project files
(CMakeLists.txt, CMakePresets.json, etc.) and helps coordinate them. It never
modifies your project files and collaborators don't need to know it exists.

## Status

Early development (v0.0.1-dev). The cmake module is fully implemented; ets and
typescript modules are shims.

## Features

- **Multi-project workspaces** — manage cmake, ets, and typescript projects
  from a single `loomworks.json`
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
- **clangd integration** — auto-injects `--compile-commands-dir` and restarts
  clangd when switching profiles
- **Lualine component** — winbar showing active profile/project/configuration
- **Live file watching** — reloads automatically when config files change
- **Status page** — `:LoomworksInfo` shows workspace state with folding, status
  icons, spinner animations, and build progress

## Requirements

- Neovim >= 0.9
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
})
```

| Value | Behavior |
|-------|----------|
| `"auto"` | Load silently when `loomworks.json` is found in cwd |
| `"cached_only"` | Load silently only if the workspace has been used before |
| `"prompt"` | Load cached workspaces silently, prompt for new ones |
| `false` | Never auto-load, only manual `:LoomworksInit` |

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

Available types: `cmake` (full), `ets` (shim), `typescript` (shim).

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
        "Debug": {},
        "Release": {},
        "ohos-debug": {
          "toolchain": "${OHOS_NDK_HOME}/cmake/ohos.toolchain.cmake"
        }
      },
      "compile_commands_from": "ninja-debug"
    }
  }
}
```

- **Toolchain paths**: use `${ENV_VAR}/path` (expanded at runtime). Absolute
  paths are forbidden in `loomworks.json` to keep it portable.
- **`compile_commands_from`**: source `compile_commands.json` from another
  configuration (e.g. MSVC build + Ninja companion for clangd).

### Configuration sets

Map configuration names across projects:

```json
{
  "configuration_sets": {
    "Debug":   { "ProjectA": "Debug",   "ProjectB": "development" },
    "Release": { "ProjectA": "Release", "ProjectB": "production" }
  }
}
```

When combined with detected cmake tools, profiles are auto-generated:
`Debug:ninja-gcc-14.2.0`, `Debug:msvc-17-2022-enterprise`, etc.

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
2. **Profiles** — all materialized profiles with build status
3. **Orphaned Configurations** — cached configs no longer referenced by any
   profile (hidden when empty; common after switching git branches)
4. **Configuration Sets** — declared sets with available tool entries
5. **Projects** — all projects with their configurations and build state

### Keybindings

| Key | Action |
|---|---|
| `<Tab>` | Toggle fold on the current node |
| `<CR>` | Activate profile (materializes if needed) |
| `b` | Build profile or configuration |
| `c` | Configure (cmake configure) |
| `p` | Pin a configuration as a standalone profile |
| `R` | Clean + rebuild (destructive) |
| `C` | Clean — reset to unconfigured, delete build dir (destructive) |
| `D` | Delete profile or configuration (destructive, with confirmation) |
| `L` | Load workspace from cwd / rescan tools |
| `<C-n>` | Reset workspace: delete `.nvim/build/` + cache, reload (destructive) |
| `?` | Show help dialog |
| `q` | Close the status page |

Actions walk upward from the cursor to find the nearest actionable node.
Pressing `b` on a detail line triggers the build action of the parent
profile or configuration.

## clangd Integration

loomworks can automatically configure clangd with the correct
`compile_commands.json` directory for each project.

In your lspconfig setup:

```lua
local lsp = require("loomworks.lsp")

require("lspconfig").clangd.setup({
  cmd = lsp.clangd_cmd({ "clangd", "--background-index", "-j=12" }),
  root_dir = lsp.clangd_root_dir(),
})
```

- `clangd_cmd()` injects `--compile-commands-dir` based on the active
  profile's build directory. Also overrides the clangd binary if a
  project-specific one is configured.
- `clangd_root_dir()` scopes clangd to the correct project directory within
  the workspace.
- clangd is automatically restarted when switching profiles if the
  compile_commands_dir or binary has changed.

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
├── loomworks.json               Commit or gitignore, your choice
└── .nvim/
    ├── loomworks.user.json      Always gitignored (active profile)
    ├── loomworks.cache.json     Always gitignored (build state)
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
lw.get_profile("Debug:ninja-gcc-14.2.0")   -- single Profile
lw.activate_profile("Debug:ninja-gcc-14.2.0")
lw.activate_set("Debug")                   -- keep current tool, switch set

-- Projects
lw.get_projects()                           -- all Project objects
lw.get_project("MyApp")                     -- single Project
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
local profile = lw.get_profile("Debug:ninja-gcc-14.2.0")

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
local proj = lw.get_project("MyApp")

proj.key                      -- "MyApp"
proj.type                     -- "cmake"
proj.configuration            -- "Debug" (from active profile)
proj.configuration_key        -- "Debug:ninja-gcc-14.2.0"
proj.status                   -- "built"
proj.orphaned                 -- false
proj.configurations           -- { Debug = {...}, Release = {...} }

proj:running_action()         -- "configure" | "build" | nil
proj:is_stale()               -- true if Core has remerged since creation
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

Orthogonal flags: `needs_refresh` (project files changed since last configure),
`orphaned` (project in cache but removed from loomworks.json).

Failed states are never auto-cleaned — only explicit user action (`C` or `D`)
removes them.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation architecture and
[specification.md](specification.md) for the full behavioral specification.

## License

TBD

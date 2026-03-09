# loomworks.nvim

Workspace management for Neovim. Provides project structure, build
configurations, and compiler kits to other plugins (LSP, overseer, DAP).

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
- **Automatic kit detection** — finds MSVC (via vswhere), GCC, and Clang
  compilers; generates profile combinations
- **Configuration sets** — group build variants across projects (e.g. "debug"
  maps ProjectA to Debug and ProjectB to development)
- **Overseer integration** — auto-generates configure and build tasks, tracks
  completion, records state
- **Live file watching** — reloads automatically when config files change
- **Status page** — `:LoomworksInfo` shows workspace state with folding, status
  icons, and spinner animations for running tasks

## Requirements

- Neovim >= 0.9
- [overseer.nvim](https://github.com/stevearc/overseer.nvim) (for task running)

## Setup

loomworks.nvim is loaded as a standard Neovim plugin. With lazy.nvim:

```lua
{
  "your-user/loomworks.nvim",
  cmd = { "LoomworksInit", "LoomworksInfo" },
}
```

Then initialize a workspace:

```vim
:LoomworksInit
:LoomworksInit /path/to/workspace
```

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
    "debug":   { "MyApp": "Debug",   "MyLib": "Debug",   "Frontend": "development" },
    "release": { "MyApp": "Release", "MyLib": "Release", "Frontend": "production" }
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
    "debug":   { "ProjectA": "Debug",   "ProjectB": "development" },
    "release": { "ProjectA": "Release", "ProjectB": "production" }
  }
}
```

When combined with detected cmake kits, profiles are auto-generated:
`debug:ninja-gcc-14.2.0`, `debug:msvc-17-2022-enterprise`, etc.

## Commands

| Command | Description |
|---|---|
| `:LoomworksInit [path]` | Initialize workspace from directory (default: cwd) |
| `:LoomworksInfo` | Open workspace status page |

## API

```lua
local lw = require("loomworks")

-- Workspace
lw.setup({ root = "/path/to/workspace" })
lw.get_workspace()                          -- full Workspace data
lw.get_active_configuration_set()           -- merged ActiveSet

-- Profiles
lw.get_profiles()                           -- all Profile objects
lw.get_profile("debug:ninja-gcc-14.2.0")   -- single Profile
lw.activate_profile("debug:ninja-gcc-14.2.0")
lw.activate_set("debug")                   -- keep current kit, switch set

-- Projects
lw.get_projects()                           -- all Project objects
lw.get_project("MyApp")                     -- single Project
lw.project_for_buf(bufnr)                   -- find project for buffer

-- Events
lw.on("active_set_changed", function(active_set)
  -- React to profile switches, task completions, file changes
end)

-- Task tracking
lw.has_running_tasks()
lw.get_running_action("MyApp", "Debug:ninja-gcc-14.2.0")

-- Deletion
lw.delete_profile("debug:ninja-gcc-14.2.0", function() end)
lw.delete_config("MyApp", "Debug:ninja-gcc-14.2.0", function() end)
```

### Profile object

```lua
local profile = lw.get_profile("debug:ninja-gcc-14.2.0")

profile.key                   -- "debug:ninja-gcc-14.2.0"
profile.configuration_set     -- "debug"
profile.kit_id                -- "ninja-gcc-14.2.0"
profile.kit                   -- { generator = "Ninja", ... }
profile.mappings              -- { MyApp = "Debug", MyLib = "Debug" }

profile:status()              -- "built", "DiagnosticOk" (label + highlight)
profile:is_configured()       -- true if any cached entries exist
profile:is_running()          -- true if any tasks running
profile:projects()            -- ProfileProject[] sorted by key
profile:activate()
profile:delete(on_done)
```

### Project object

```lua
local proj = lw.get_project("MyApp")

proj.key                      -- "MyApp"
proj.type                     -- "cmake"
proj.configuration            -- "Debug"
proj.status                   -- "built"
proj.configurations           -- { Debug = {...}, Release = {...} }

proj:running_action()         -- "configure" | "build" | nil
proj:cached_config("Debug")   -- CachedConfig from cache.json
proj:is_stale()               -- true if Core has remerged since creation
proj:to_module_context(root)  -- table for module.tasks()
```

## File Layout

```
workspace-root/
+-- loomworks.json               Commit or gitignore, your choice
+-- .nvim/
    +-- loomworks.user.json      Always gitignored (user preferences)
    +-- loomworks.cache.json     Always gitignored (build state)
    +-- build/
        +-- ProjectA/
        |   +-- Debug/
        |   +-- Release/
        +-- ProjectB/
```

## Events

| Event | Data | When |
|---|---|---|
| `workspace_changed` | Workspace | Initial load or config file change |
| `active_set_changed` | ActiveSet | Any remerge (profile switch, build, file change) |
| `task_started` | info | Overseer task begins |
| `task_stopped` | info | Overseer task ends |
| `task_result` | TaskResult | Build result recorded to cache |
| `deletion_started` | items[] | Cache/build deletion begins |
| `deletion_completed` | items[] | Deletion finishes |

## Build States

Projects track build state per configuration:

- `unconfigured` — never configured
- `configured` — cmake configure succeeded
- `built` — build succeeded
- `failed_configure` — configure attempted and failed
- `failed_build` — build attempted and failed

Orthogonal flags: `needs_refresh` (project files changed since last configure),
`orphaned` (in cache but removed from loomworks.json).

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design documentation.

## License

TBD

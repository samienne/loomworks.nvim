# loomworks.nvim

The Neovim client of [loomworks](https://github.com/samienne/loomworks), a
workspace manager for multi-project native builds. loomworks reads your
existing project files (CMakeLists.txt, CMakePresets.json, meson.build, ...)
and turns their build variants into resolved, buildable **profiles**. It never
modifies your project files, and collaborators don't need to know it exists.

The workspace itself is run by `lw`, loomworks' command-line tool, as a
**workspace daemon**: it owns the workspace files (`loomworks.json`, and its own state under `.lw/`:
`.lw/user.json`, `.lw/cache.json`, …; `lw` releases before 0.2.0 used
`.nvim/loomworks.user.json` and so on, which `lw` 0.2.0 migrates), detects
toolchains, and configures, builds, cleans, launches and tests. This plugin
connects to that daemon and gives it an editor front end:

- a status page with the workspace's profiles, configuration sets, projects,
  build state and tasks, and editors for configurations, launch targets,
  deploy steps, variables and descriptions;
- builds, launches and debugging (nvim-dap) from keymaps, with progress in
  overseer and fidget;
- language servers (clangd, qmlls) configured for the active profile;
- loomtest, a test explorer fed by the daemon's tests;
- device logs and remote runs on devices the daemon knows;
- lualine components for the active profile and withheld language servers.

## Requirements

- Neovim >= 0.10
- [snacks.nvim](https://github.com/folke/snacks.nvim) and
  [overseer.nvim](https://github.com/stevearc/overseer.nvim) (required)
- Optional: [nvim-dap](https://github.com/mfussenegger/nvim-dap) (debugging),
  [fidget.nvim](https://github.com/j-hui/fidget.nvim) (progress),
  [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim)
- `lw`: the plugin provisions it (below), or uses one you installed (see
  [loomworks](https://github.com/samienne/loomworks) for installing `lw`).

## The `lw` the plugin runs

The editor launches the workspace daemon from the first of:

1. `$LOOMWORKS_LW`, then the setup option `binary.path` — explicit; never
   replaced by another `lw`;
2. `lw` on your `PATH` (absolute entries only), when it is compatible with
   the plugin;
3. the **managed `lw`**: the release this plugin pins, downloaded on first
   use, verified against the release's signed checksums and installed under
   Neovim's data directory (`<stdpath("data")>/loomworks/lw/`).

`binary.prefer = "managed"` puts 3 before 2. `:checkhealth loomworks` shows
which `lw` is used and why; `:LoomworksDaemon status` shows the daemon.

To run a development `lw`, build it in a loomworks checkout
(`make -C <loomworks> install`) and point `binary.path` at the installed
executable. (The former `binary.source` option is gone: setting it only
prints a warning.)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "samienne/loomworks.nvim",
  dependencies = { "folke/snacks.nvim", "stevearc/overseer.nvim" },
  event = "VeryLazy",
  opts = {},
}
```

By default the plugin loads a workspace when you open Neovim in (or `:cd` to)
a directory containing `loomworks.json` (or a not-yet-published working copy,
`.lw/user.json` or an earlier release's `.nvim/loomworks.user.json`), or any
directory below it. `:LoomworksInit
[path]` loads the workspace at `path` explicitly; where there is none, it runs
`lw init` there in a terminal window, with the same `lw` the plugin uses for
the workspace daemon (the plugin-managed one when no `lw` is installed), and
loads the new workspace when `lw init` succeeds (closing the terminal). To
create and edit workspaces from the command line, see `lw`'s documentation in
[loomworks](https://github.com/samienne/loomworks).

## Setup options

```lua
require("loomworks").setup({
  auto_load = "auto",      -- "auto" | "cached_only" | "prompt" | false
  keys = true,             -- false: register no default keymaps
  root = nil,              -- load this workspace root at setup
  lsp = {                  -- false: configure no language servers
    clangd = {             -- or false to skip clangd
      cmd = { "clangd", "--background-index", "-j=12" },
      capabilities = nil,
      on_attach = nil,
      settings = {},
    },
    qmlls = {},            -- or false to skip qmlls
  },
  binary = {               -- which lw to run (see above)
    path = nil,            -- an lw to use as is
    prefer = nil,          -- "managed" or "system"
    download = true,       -- false: never download the managed lw
    channel = nil,         -- "stable" or "unstable"
    release_url = nil,     -- a release mirror (URL or directory)
  },
  task_output_win = {},    -- window options for task output
  progress_max_width = nil, -- fidget: cap the progress message width
})
```

| `auto_load` | Behaviour |
|---|---|
| `"auto"` | Load silently when a workspace is found from the current directory |
| `"cached_only"` | Load silently only if the workspace was used before |
| `"prompt"` | Load used workspaces silently, ask for new ones |
| `false` | Never auto-load; only `:LoomworksInit` |

A user `cmd` for clangd is the fallback: inside a workspace project the active
profile's clangd (when its SDK provides one) wins, and the compile-commands
directory is added. The search for the workspace root walks up from the
current directory but stops at a git repository's or a linked worktree's root.

## Commands

| Command | What it does |
|---|---|
| `:LoomworksInfo` | Open the status page |
| `:LoomworksInit [path]` | Load the workspace at `path`, or run `lw init` there when it has none (default: cwd) |
| `:LoomworksDaemon [connect\|status]` | Connect to the workspace daemon (launching it when none runs), or show the runtime line and the `lw` a launch would use |
| `:LoomworksTrust` | Review a refused working copy, then trust (re-sign), discard or cancel |
| `:LoomworksCompileCommand [file]` | Not available with the workspace daemon: refuses and says so |
| `:LoomworksLog` | Open the workspace log |
| `:LoomworksFidgetClear` | Clear stuck fidget progress |
| `:LoomworksReload` | Development: tear down and reload the plugin (lazy.nvim) |
| `:LoomtestToggle`, `:LoomtestRun`, `:LoomtestRunFile`, `:LoomtestRunAll`, `:LoomtestRunAllNoBuild`, `:LoomtestRefresh`, `:LoomtestOutput` | The test explorer (see [LOOMTEST.md](LOOMTEST.md)) |

## Keymaps

`setup()` registers these unless `keys = false`:

| Key | Action |
|---|---|
| `<leader>ww` | Toggle the status page |
| `<leader>wb` | Build the default target |
| `<leader>wB` | Build the active profile |
| `<leader>wr` / `<F5>` | Debug the target |
| `<leader>wR` | Launch the target without the debugger |
| `<S-F5>` | Stop the running launch |
| `<leader>ws` | Select a profile |
| `<leader>wO` | Toggle the device log |
| `<leader>tt` / `<leader>tT` | Debug / run the nearest test (with loomtest) |
| `<leader>tf` / `<leader>tF` | Debug / run the file's tests (with loomtest) |

On the status page (`?` shows them all): `<Tab>`/`<S-Tab>` move, `l`/`h`
open/close a fold, `<CR>` activates a profile, `b` builds (`<C-b>` serially),
`c` configures, `R` rebuilds, `C` cleans, `D` deletes, `t` shows a task, `o`
shows build options, `e` edits a description, `P` cycles publish intent, `N`
runs `lw init` in a terminal where no workspace is, `L` loads, `<C-n>` resets the workspace, `U` discards the
working copy, `T` reviews trust, `K` hovers, `q` closes. `:w` publishes the
working copy to `loomworks.json`; `:e!` reverts it.

## Lualine

```lua
require("lualine").setup({
  winbar = { lualine_c = { { "loomworks" } } },             -- active profile
  sections = { lualine_x = { "lsp_status", "loomworks_lsp" } }, -- why clangd is withheld
})
```

`{ "loomworks", show = { "project", "configuration" } }` picks fields from
`set_name`, `project`, `configuration`, `tool_key`, `profile_key`, `status`.

## Links

- [loomworks](https://github.com/samienne/loomworks): `lw`, the workspace
  daemon, its protocol and the workspace file formats
- [spec/plugin.md](spec/plugin.md): the plugin's specification
- [ARCHITECTURE.md](ARCHITECTURE.md): how the plugin is built
- [LOOMTEST.md](LOOMTEST.md): the test explorer
- [CHANGELOG.md](CHANGELOG.md)

## License

TBD

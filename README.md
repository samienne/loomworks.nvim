# loomworks.nvim

Workspace management for Neovim. Provides project structure, build
configurations, and toolchains to other plugins (LSP, overseer, DAP).

**Assistive, not authoritative** — loomworks reads your existing project files
(CMakeLists.txt, CMakePresets.json, etc.) and helps coordinate them. It never
modifies your project files and collaborators don't need to know it exists.

## Status

Early development. The cmake and meson modules are fully implemented; shell
provides a generic command runner for self-managed builds; typescript is a
shim. The standalone `lw` runner ships as a signed release for Linux x86_64,
macOS arm64, and Windows x86_64 — see
[releases](https://github.com/samienne/loomworks.nvim/releases) for the
current version.

## Features

- **Multi-project workspaces** — manage cmake, meson, shell, and
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
  completion, records state to cache. On Linux, configure/build/clean/test
  tasks run under `ionice -c 3 nice -n 10` so the editor and clangd stay
  responsive during long builds
- **clangd integration** — auto-injects `--compile-commands-dir`,
  always-on `--pch-storage=disk`, user-toggleable `--clang-tidy` /
  `--background-index` / priority (low/normal/background) plus an
  `extra_args` escape hatch — all editable from the status page LSP
  section, persisted to user.json, clangd restarts on change. Restarts
  clangd on profile/SDK switch, OOM-adaptive `-j` step-down with nvim
  LSP log rotation, throttle 4 attempts / 5min, UI Reset action
- **Lualine component** — winbar showing active profile/project/configuration
- **Live file watching** — reloads automatically when config files change
- **Status page** — `:LoomworksInfo` shows workspace state with folding, status
  icons, spinner animations, and build progress. The action picker on running
  profile or configuration rows includes `Cancel running task(s)`. A Tasks
  section at the bottom surfaces active tasks and held build-dir locks with
  per-row cancel/force-release actions for recovering from stuck state

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

Available types: `cmake` (full), `meson` (full),
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
        "cross-debug": {
          "inherits": "variant:Debug",
          "toolchain": "${VENDOR_SDK_ROOT}/cmake/cross.toolchain.cmake"
        }
      },
      "compile_commands_from": "ninja-debug"
    }
  }
}
```

- **Configuration name tiers**: module-emitted configs are canonical
  `prefix:name` (cmake built-ins as `variant:Debug`/`variant:Release`,
  CMakePresets entries as `preset:<name>`, project-file-derived configs
  as `auto:<base>`). User-declared configs go under any
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
  "Debug:ninja-clang-18.0.0": {
    "configuration_set": "Debug",
    "tools": ["ninja-clang-18.0.0"]
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
useful for bundling native libraries into a package where the file
must be an input to the build:

```json
"NativeDemo": {
  "cmake": { ... },
  "deploy": {
    "${workspace_root}/NativeDemo/assets/native/": {
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
| `:LoomworksReload` | Tear down active workspace and reload plugin code (dev hatch — requires lazy.nvim) |

## Standalone `lw` runner

`lw` runs loomworks builds outside the editor — CI, a plain shell — from the
same `loomworks.json`. It is a single self-contained binary (a luvi host with
a small fused bootstrap); it needs no Neovim and no Lua install.

**Two sources of the runner's own code** (spec §16.11):

- **release** (default) — the runner uses a cryptographically **verified**
  release bundle it downloads and caches per user. `lw self-update` fetches
  and verifies the latest; a bundle whose signature or hash does not match is
  never executed (spec §16.12).
- **dev** — point the runner at a checked-out loomworks tree. Configure it
  once:

  ```
  lw config set dev-lua C:/src/nvim-plugins/loomworks.nvim/lua
  ```

  Then `lw --dev <command>` runs from that tree (verification skipped — it's
  your local checkout). `lw config set default-source dev` makes `--dev` the
  default, or use `LOOMWORKS_LUA=<dir>` for a one-off override.

Releases are cut from `master`; CI builds the host binary for Linux, macOS,
and Windows and publishes the signed bundle. See
[ARCHITECTURE.md](ARCHITECTURE.md#standalone-runner--distribution) for the
release layout and update flow.

### Installing `lw`

`lw` installs itself: download the binary for your platform, **verify it**,
then let the verified binary place itself on PATH and fetch the first bundle.
The commands show exactly what they do — nothing is piped from an unread
script.

A host binary cannot verify itself (the checker is inside it), so its
integrity is established before first execution: each release publishes a
`SHA256SUMS` list, **signed** with the loomworks release key. Verify that
signature with the public key below, then check the binary against the list.
Because the anchor is the key and not a digest, **these commands never change**
— copy them as-is, for any release.

Linux / macOS:

```sh
base=https://github.com/samienne/loomworks.nvim/releases/latest/download
bin=lw-linux-x86_64          # or lw-macos-arm64
d="$(mktemp -d)" && cd "$d"
curl -fsSLO "$base/$bin" && curl -fsSLO "$base/SHA256SUMS" \
  && curl -fsSLO "$base/SHA256SUMS.sig"
cat > lw.pub.pem <<'PEM'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8MhoZlT5ww82JmplPiRyta32R8HY
meq3+ZL1wAo7PHHBnHHzXIE+Kab49ClyLvDUGsOR3LG+kU1lH6nxunmO2A==
-----END PUBLIC KEY-----
PEM
# macOS ships `shasum`, not GNU `sha256sum`.
if command -v sha256sum >/dev/null; then check="sha256sum -c -"
else check="shasum -a 256 -c -"; fi
openssl dgst -sha256 -verify lw.pub.pem -signature SHA256SUMS.sig SHA256SUMS \
  && grep -E "[ *]$bin\$" SHA256SUMS | $check \
  && chmod +x "$bin" && "./$bin" install
```

Windows (PowerShell):

```powershell
$base = "https://github.com/samienne/loomworks.nvim/releases/latest/download"
$bin  = "lw-windows-x86_64.exe"
$d = New-Item -ItemType Directory (Join-Path $env:TEMP (New-Guid))
"$bin","SHA256SUMS","SHA256SUMS.sig" | ForEach-Object {
  Invoke-WebRequest "$base/$_" -OutFile (Join-Path $d $_)
}
$pub = @"
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8MhoZlT5ww82JmplPiRyta32R8HY
meq3+ZL1wAo7PHHBnHHzXIE+Kab49ClyLvDUGsOR3LG+kU1lH6nxunmO2A==
-----END PUBLIC KEY-----
"@
$ec = [System.Security.Cryptography.ECDsa]::Create()
$ec.ImportFromPem($pub)
$sums = [IO.File]::ReadAllBytes((Join-Path $d "SHA256SUMS"))
$sig  = [IO.File]::ReadAllBytes((Join-Path $d "SHA256SUMS.sig"))
if (-not $ec.VerifyData($sums, $sig,
      [Security.Cryptography.HashAlgorithmName]::SHA256,
      [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)) {
  throw "SHA256SUMS signature does not verify"
}
$want = ((Get-Content (Join-Path $d "SHA256SUMS") |
  Select-String " $bin$") -split '\s+')[0]
$got = (Get-FileHash (Join-Path $d $bin) -Algorithm SHA256).Hash
if ($got -ine $want) { throw "hash mismatch for $bin" }
& (Join-Path $d $bin) install
```

`ImportFromPem` needs PowerShell 7 / .NET 5+; Windows PowerShell 5.1 does not
have it. Run the block in `pwsh`, or use the `gh` route below — which is the
simpler choice on Windows generally.

**On GitHub Actions** (or anywhere `gh` is authenticated) the release is also
covered by build provenance recorded in Sigstore's public transparency log —
verification needs no key and no hashes, and the anchor is independent of this
repository:

```sh
gh release download --repo samienne/loomworks.nvim -p lw-linux-x86_64
gh attestation verify lw-linux-x86_64 --repo samienne/loomworks.nvim
chmod +x lw-linux-x86_64 && ./lw-linux-x86_64 install -y
```

Pin a release in CI by passing an explicit tag (`gh release download v0.1.0`,
or a versioned URL instead of `latest`) and not running `lw self-update`.
Signature and provenance both establish *who built this*; where the signing key
lives on the same platform that serves the artifacts, they are not a defense
against that platform itself.

`lw install` copies the binary to a per-user location — `~/.local/bin/lw`
(Unix) or `%LOCALAPPDATA%\Microsoft\WindowsApps\lw.exe` (Windows, already on
PATH) — ensures it is on PATH (prompting first; `-y` to apply non-interactively,
`--no-modify-path` to skip), and runs `lw self-update` to fetch the verified
release bundle. `--dry-run` shows what it would do; `--no-bundle` skips the
fetch. No admin required. Then enable completion with `lw completion bash`
(see [above](#standalone-lw-runner) / `lw help completion`).

### Repo-local launcher (`lw bootstrap`)

For a project where every contributor and CI runner should use the **same,
pinned** `lw` — with no prior global install — commit a repo-local launcher.
From the repo root:

```sh
lw bootstrap                 # pins this host's release; or: lw bootstrap --version 0.1.0
git add lw.sh lw.cmd lw.pin  # commit the three files
```

`bootstrap` writes three committed files and gitignores the machine-local cache:

| File | What it is |
|---|---|
| `lw.pin` | the pinned release **version** + the SHA-256 of every host binary and of the release bundle (plain `key = value`, no JSON) |
| `lw.sh` | POSIX launcher (Linux/macOS, and Git-Bash/MSYS on Windows) |
| `lw.cmd` | native Windows launcher (cmd/PowerShell) |

The hashes come from that release's **signed** `SHA256SUMS` (its signature is
verified against the key built into `lw` before any hash is trusted). Downloaded
binaries and the provisioned bundle live under `.nvim/cache/`, which `bootstrap`
appends to `.gitignore` idempotently.

Then anyone with a checkout runs the launcher — no global `lw` needed:

```sh
./lw.sh build Debug:ninja-gcc-14      # Linux/macOS/Git-Bash
lw.cmd build Debug:ninja-gcc-14       # Windows cmd/PowerShell
./lw.sh --no-interaction test --junit results.xml   # CI: forwards args verbatim
```

The launcher selects the host binary for the platform, downloads it from the
official release (**verifying its sha256 against the pin — always**), caches it
under `.nvim/cache/`, and execs it; that host then provisions the pinned bundle,
also into `.nvim/cache/`. So a clean checkout goes from `./lw.sh build` to
building, **reproducibly** — host and bundle are the exact pinned release, and
the machine-global install is left untouched.

- **Proxies / air-gapped.** The launcher honors `HTTPS_PROXY` / `HTTP_PROXY`.
  `--insecure` (or `LOOMWORKS_INSECURE=1`) relaxes TLS for an intercepting
  proxy — safe only because the sha256 check is independent and **always**
  enforced. Point `LOOMWORKS_RELEASE_URL` at a local mirror directory (holding
  the release assets + `SHA256SUMS`) for an offline runner.
- **Dev / test-at-head.** `LOOMWORKS_LW=<path>` makes the launcher run that
  binary and bypass the pin entirely — the override CI uses to test a freshly
  built `lw` against a pinned repo.
- **Optional stronger check.** `--verify` additionally runs
  `gh attestation verify` when `gh` is present; it is skipped with a note (never
  a failure) when `gh` is absent.

**A globally-installed `lw` also honors the pin.** Run inside a pinned repo, a
global `lw` resolves the pin for `build` / `run` / `test` / `clean`: if the pin
matches its own version it runs in-process (no download); otherwise it fetches +
verifies the pinned release and re-execs it, so you always get the pinned
behavior. Bypass with `--no-pin` (run the global as-is) or `LOOMWORKS_LW=<path>`.
Management commands (`version`, `self-update`, `install`, `bootstrap`, `update`)
never redirect. The global host never executes the repo's `lw.sh`/`lw.cmd` — it
resolves the pin declaratively and runs the official binary it fetched itself.

Move the pin forward with `lw update` (from a repo already bootstrapped):

```sh
lw update                 # repoint lw.pin at the latest release
lw update --version 0.2.0 # or a specific one
```

`update` rewrites `lw.pin` with the target release's signed hashes (failing
cleanly if that release isn't fetchable) and refreshes the launcher scripts. See
`lw help bootstrap` / `lw help update`.

### Commands

`lw` with no command prints workspace status and the active profile. Every
command has detail under `lw help <command>`.

| Command | Description |
|---|---|
| `lw init` | Initialize the workspace working copy (`--name` overrides the directory name) |
| `lw workspace <sub>` | Show / rename the workspace (alias `ws`) |
| `lw project <sub>` | `add` \| `remove` \| `rename` \| `list` \| `show` |
| `lw configuration <sub>` | `add` \| `set` \| `get` \| `show` project configurations |
| `lw configuration-set <sub>` | `create` \| `map` \| `show` (alias `cs`) |
| `lw profile <sub>` | `list` \| `select` \| `create` \| `remove` \| `publish` \| `target` \| `query` |
| `lw tools [--cached]` | List detected toolchains (`--cached` reads the cache instead of scanning) |
| `lw sdk <sub>` | Declare toolchains detection can't find: `types` \| `list` \| `add` \| `remove` |
| `lw build [profile]` | Configure if needed, then build. `lw build <profile> -- <args>` forwards args to the build tool |
| `lw test [profile]` | Build, then run tests; real exit code. `--junit <file>` writes a JUnit report |
| `lw run <profile> [target]` | Build, then execute a launch target (omit `target` for the profile default) |
| `lw launch <sub>` | `list` \| `add` \| `show` \| `remove` launch configurations |
| `lw publish` | Write `loomworks.json` from the working copy |
| `lw migrate [--check]` | Bring the workspace files up to current conventions (`--check` = CI lint) |
| `lw module <sub>` | `install` \| `update` \| `remove` \| `list` acquirable modules (alias `mod`) |
| `lw config <...>` | Get/set `lw`'s own configuration |
| `lw bootstrap [--version <x.y.z>]` | Install a repo-local launcher + version pin (`lw.sh`/`lw.cmd`/`lw.pin`) |
| `lw update [--version <x.y.z>]` | Repoint `lw.pin` at a target (or the latest) release |

A first run, from an empty directory:

```sh
lw init
lw project add ./app              # type auto-detected (cmake, meson, …)
lw cs create dev app=Debug        # map a configuration set
lw profile create dev ninja-gcc   # set + toolchain; `lw tools` lists them
lw build dev
lw publish                        # write the shared loomworks.json
```

Items you add default to `local+shared`, so `lw publish` writes them to the
committed `loomworks.json`; `--local` keeps one private. **Profiles are the
exception** — they default to `local`, because they pin toolchains resolved on
your machine. Share the configuration set instead and let each machine create
its own profile, or pass `--shared` when a profile really is portable. See
`lw help publish` for the intent model and
[Workspace File Layout](#workspace-file-layout).

### Installing modules

Core modules (cmake, meson, shell, typescript) ship inside `lw`. Modules for
other platforms — e.g. HarmonyOS / OpenHarmony (`harmony`) — are separate
plugins. In the editor they load through your plugin manager; for the
standalone `lw` binary, acquire them with `lw module`:

```sh
lw module list                 # available (from the index) + installed
lw module install harmony      # download, verify, install
lw module update --all         # update installed modules; skips incompatible ones
lw module remove harmony
```

Each release in the index pins the module archive's SHA-256; `lw` verifies the
download against it before installing, and refuses a module built for a
different plugin-interface version (telling you whether to update `lw` or wait
for a module release). Modules install under `lw`'s data dir, so `lw
self-update` never disturbs them. The index is fetched from the loomworks repo
over HTTPS — point it at a fork or an offline mirror with `lw config set
module-index <url-or-path>`. `lw help module` has the details. (Editor users
don't use this — install the module plugin the usual way.)

### Using `lw` in CI

`lw help ci` is the full guide. The essentials:

- **Pin `lw` itself** with a repo-local launcher (see
  [Repo-local launcher](#repo-local-launcher-lw-bootstrap)): commit `lw.sh` /
  `lw.cmd` / `lw.pin` with `lw bootstrap`, then run `./lw.sh --no-interaction
  build …` on the runner — it fetches + verifies the pinned host and bundle, so
  every cell runs the same reproducible `lw` with no separate install step.
- Pass `--no-input` (or set `CI=1`, which implies it) so a missing value errors
  instead of blocking on a prompt. In non-interactive mode `lw build` also
  ignores the active profile — name the profile explicitly.
- Commit `loomworks.json` — the projects and configuration sets are the
  portable unit. Keep `.nvim/` (working copy and cache) out of version control.
  Profiles are per-machine: each matrix cell creates its own with
  `lw --no-input profile create <set> <tool> --activate`.
- `lw test --junit results.xml` produces a report most CI systems ingest
  directly, and exits non-zero when tests fail.
- Profiles and toolchains resolve by a **truncated selector** matched at
  segment boundaries, so a job need not pin an exact version: `ninja-clang-18`
  picks the highest installed `18.x`, and `msvc-17` picks a VS 17 without
  naming the edition.
- `lw profile query <profile> <project> build-dir` prints one machine-readable
  fact — also `config`, `state`, `tool` — for archiving artifacts without
  parsing build output.

## Status Page

`:LoomworksInfo` opens a status page with the following sections:

1. **Header** — plugin version, workspace name, root path
2. **Diagnostics** — structural warnings/errors aggregated from across the
   workspace (incomplete profiles, source-missing configurations, stale
   `configuration_set` mappings, unresolved inherits chains,
   tool/configuration mismatches — e.g. a profile picking a kit whose
   platform/arch contradicts the configuration's declared target).
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

## clangd / LSP Integration

loomworks ships a plugin-style LSP integration layer. By default, calling
`require("loomworks").setup({})` auto-installs a clangd config via the
native `vim.lsp.config` + `vim.lsp.enable` API — you don't need
`nvim-lspconfig` or any other LSP plumbing for the common case.

### Zero-config

```lua
require("loomworks").setup({})
-- clangd is now enabled with sensible defaults:
--   cmd = { "clangd", "--background-index", "--header-insertion=iwyu" }
-- plus always-injected: --background-index-priority=low, --pch-storage=disk,
-- --clang-tidy (appended in cmd_factory, applies even when user overrides cmd)
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
contract in [specification.md §9.3](spec/core/integrations.md). Every plugin on
`runtimepath` is scanned at startup, so no other wiring is needed.

### Behavior

- clangd restarts automatically when profile switches change the
  `compile_commands_dir` or resolved binary.
- SDK-provided clangd is required for SDK profiles; when
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

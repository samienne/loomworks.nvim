# shell module

How the shell module implements the core module contract
(`specification.md` §8). Section numbers in this file are local.

The shell module is a generic runner around user-declared commands.
It exists for self-managed build systems (custom Python scripts,
Make-based projects, vendor toolchains) that loomworks would otherwise
need bespoke module code to integrate. The module owns no build-system
knowledge — every project-specific detail comes from `type_config`.

## 1. Detection and identity

- **Marker file**: none. `detect()` always returns `nil`. Shell
  projects are manually declared in `loomworks.json` — auto-detecting
  "any directory" would be meaningless.
- **Keyed tools**: no. Single default tool with empty `tool_data`. The
  user's script picks its own toolchain.
- **Languages**: `"c++"`. Most known use case; debug adapter resolution
  falls back to codelldb. Non-c++ projects can omit the launch config's
  `debug` field.
- **Has options**: no. Build options live entirely inside the user's
  script; loomworks doesn't introspect them.
- **Has devices**: no.

## 2. Project shape

Shell projects follow the standard loomworks.json shape — the type key
(`shell`) is the inner key under each project entry, and its value is
the type_config (see `config.lua` `_extract_type`). The non-type project
keys (`path`, `variables`, `launch`, `deploy`, `depends_on`) sit
alongside `shell` at the project level.

```jsonc
{
  "projects": {
    "myproj": {
      "path": "myproj",
      "variables": {
        "gn_args": { "type": "string", "default": "--release" }
      },
      "shell": {
        "build_dir":        "${workspace_root}/out/${variant}",
        "compile_commands": "${build_dir}/compile_commands.json",
        "configure_cmd":    ["./build_system.sh", "${gn_args}"],
        "build_cmd":        ["./build_system.sh", "--fast-rebuild", "${gn_args}"],
        "clean_cmd":        ["rm", "-rf", "${build_dir}"],
        "configurations": {
          "Debug":   { "variables": { "gn_args": "--debug" } },
          "Release": { "variables": { "gn_args": "--release" } }
        }
      }
    }
  }
}
```

All command / path fields accept `${var}` expansion. The context
includes the standard built-ins (`workspace_root`, `project_path`,
`config_set`, `variant`, `build_dir`) plus all resolved project
variables (see core spec §4.2 / `expand.lua`). `${build_dir}` resolves
to the expanded value of the `build_dir` template, so `compile_commands`
and `clean_cmd` can reference it without repeating the template.

Fields inside the `shell:` block:

| Field | Required | Notes |
|------|----------|------|
| `build_dir` | yes | Resolved per-configuration. Determines the cache key path and is checked by deletion safety. |
| `configure_cmd` | yes | First-build and explicit Configure invoke this. |
| `build_cmd` | yes | Default Build keymap invokes this. |
| `clean_cmd` | no | If omitted, Clean wipes the build dir directly (`rm -rf` equivalent). |
| `compile_commands` | no | Path to `compile_commands.json` or its containing directory. Forwarded to clangd via `lsp_configs`. |
| `env` | no | Dict of env vars merged into the task environment. Values expanded. |
| `clangd` | no | Override the clangd binary path. Otherwise pulled from the active profile's tool (`tool_data.clangd_path`) or PATH. |
| `configurations` | no | Map of configuration name → overrides (variables, inherits). |

## 3. Variant mapping

Single-config fallback: any variant type maps to the first available
configuration. Users who want Debug / Release behavior declare both
configurations explicitly and override variables per-config.

## 4. Default configurations

Single `default` configuration when the user declares none. Once the
user adds entries under `configurations`, the default is dropped.

## 5. Tasks

| Action | Command source | Notes |
|--------|---------------|-------|
| Configure | `shell.configure_cmd` after `${var}` expansion | Run in project directory. Auto-fires when state is `unconfigured` or unit is stale. |
| Build | `shell.build_cmd` after `${var}` expansion | Run in project directory. |
| Clean | `shell.clean_cmd` if declared, else direct `rm -rf <build_dir>` | Run in workspace root. |

`cwd` defaults to `<workspace_root>/<project.path>`. Task env is the
caller's env merged with `shell.env`.

### 5.1 Progress parsing

`progress_parser()` returns the ninja parser unconditionally. The
parser matches lines like `[3/10] Building CXX object foo.o` and
returns `nil` for everything else, so on shell projects that don't
run a ninja-flavored build underneath every output line returns nil
and fidget stays empty — the "try only" semantic, no config field
needed. Cost is one regex per line of build output.

The parser is shared with cmake and meson; see
[`lua/loomworks/progress/ninja.lua`](../../lua/loomworks/progress/ninja.lua)
for the matcher and the basename-shortening rule applied to the
trailing message.

## 6. Build directory (`resolve_build_dir`)

Resolves `shell.build_dir` with the standard expansion context for the
target configuration. The path must lie under `workspace_root` —
deletion safety (`_validate_build_dir`) enforces this regardless of
what the user declares.

## 7. LSP integration (`lsp_configs`)

Emits a single clangd entry when `shell.compile_commands` is set:

- `compile_commands_dir` → containing directory of the resolved path,
  or the path itself if it already ends in a directory.
- `binary` / `binary_required` → standard rule. Type_config `clangd`
  wins, then `tool_data.clangd_path` from the active profile's tool
  (typically supplied by the `cpp_compiler` SDK), then PATH.
- `root_dir` → project source directory.

When `compile_commands` is not declared, the module emits no
`lsp_configs` entry — clangd falls back to whatever it would do
without loomworks involvement.

## 8. Staleness (`inspect`)

Not implemented. The shell module never auto-reconfigures based on
file changes. The two remaining triggers for auto-configure
(`state == "unconfigured" / "configure_failed"` and `unit:is_stale()`,
i.e., variable values changed) suffice:

- First build runs the full configure script (correct — needed anyway).
- Changing `gn_args` re-runs configure (correct — script needs the new args).
- Editing project source files (BUILD.gn, headers, anything else) is
  the user's manual escalation: press Configure explicitly.

A future `reconfigure_triggers` field could read globs from
`type_config` and surface a soft hint when any matching file's mtime
exceeds `last_configured`. Tracked in BACKLOG.md, not implemented.

## 9. Targets

Not implemented. `parse_targets` returns `nil`. Users with a known
target list can declare a launch configuration with an explicit
`program` path; the shell module is not responsible for enumerating
build outputs.

## 10. Tests

Not implemented. `create_test_unit` returns `nil`. A future iteration
could accept `shell.test_cmd` and a parser hint, but the simplest
v1 path is to wire tests through neotest directly outside loomworks.

## 11. Debug integration

Module language `"c++"` resolves to the default codelldb adapter.
Users declare launch configurations the same way as any other module
(`debug = ["c++"]`, explicit `program`, `args`, etc.).

## 12. UI: in-place type_config editing

`editable_type_config_fields()` declares every field in the `shell:`
block to the generic status-page renderer (`ui/sections/projects.lua`).
Each field produces an inline row with an editor:

| Field | Editor kind | Notes |
|------|------------|------|
| `build_dir` | `string` | Single-value prompt. |
| `configure_cmd` | `cmd_array` | Joined on display; edits accept a whitespace-separated string and split. Quoted args / escapes require hand-editing JSON. |
| `build_cmd` | `cmd_array` | Same. |
| `clean_cmd` | `cmd_array` | Same. Empty value means "fall back to wiping build dir." |
| `compile_commands` | `string` | Single path. |
| `env` | `env_dict` | Dict-style env editor (per-entry rows + Add). |
| `clangd` | `string` | Single path override. |

Project-level `variables` and per-configuration variable overrides
use the existing variable editor (`ui/variable_editor.lua`) and
configuration dialog (`ui/config_editor_dialog.lua`) — shell projects
inherit those flows from the generic projects section.

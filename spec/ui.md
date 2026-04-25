# UI

Status page, highlight groups, and the winbar/statusline component.
Section numbers in this file are local. Cross-refs to core sections
use `specification.md §X.Y` form.

---

## 1. Status page

### 1.1 Layout

The status page opens as a floating window (default 100 columns, 90%
editor height). Window position and size can be configured via `setup()`
options or overridden per `open()` call — the `win` table is passed
directly to `Snacks.win`. The page contains these sections in order:

1. **Header** — plugin version, workspace name, workspace root
2. **Profiles** — all materialized and explicit profiles
3. **Orphaned Configurations** — unreferenced cached configs (hidden when empty)
4. **Configuration Sets** — declared sets with tool entries
5. **Projects** — all projects with their configurations

Sections are separated by blank lines. Each section has a title line.

### 1.2 Tree Structure

The status page uses a foldable tree widget with two-level nesting.

**Node types**:
- `leaf` — plain text line, no interaction. Accepts either `(text, hl)` or
  a list of `{text, hl}` chunks for mixed highlights on one line.
- `node` — foldable line with children, toggle via `<Tab>`
- `item` — interactive line with actions, no folding
- `group` — labeled sub-section that increases indentation. Accepts either
  `(label, hl, children_fn)` or `(chunks, children_fn)` for mixed highlights.
- `blank` — empty line for spacing

**Fold characters**: `▶` (folded), `▼` (unfolded)

**Spinner**: Braille animation (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) at 80ms interval,
shown when `spinning = true`. Replaces the status marker for running items.

**Status markers**:
| Status           | Marker |
|------------------|--------|
| unconfigured     | ○      |
| configured       | ◆      |
| built            | ✔      |
| configure_failed | ✘      |
| build_failed     | ✘      |
| running/deleting | (spinner) |

### 1.3 Keybindings

| Key     | Action      | Behavior |
|---------|-------------|----------|
| `<Tab>` | toggle_fold | Toggle fold on the current node |
| `<CR>`  | enter       | Open action picker on nearest actionable node |
| `b`     | build       | Build (walks up to nearest node with `on_build`) |
| `c`     | configure   | Configure (walks up to nearest node with `on_configure`) |
| `o`     | options     | Show build options float (on configured project nodes) |
| `t`     | task        | Open overseer task output for nearest config (float) |
| `R`     | rebuild     | Clean + build (destructive, with confirmation) |
| `C`     | clean       | Run module clean tasks, reset to configured (with confirmation) |
| `D`     | delete      | Delete profile or configuration (destructive, with confirmation) |
| `N`     | init_workspace | Initialize workspace: create user.json in cwd |
| `L`     | load        | Load workspace from cwd / rescan tools |
| `<C-n>` | nuke        | Reset workspace: delete `.nvim/build/` + cache, reload (destructive, with confirmation) |
| `P`     | publish     | Toggle publish flag on nearest publishable item |
| `U`     | delete_user | Delete user.json and reload (with confirmation) |
| `:w`    | (write)     | Publish: write published items to loomworks.json |
| `?`     | help        | Show help dialog |
| `q`     | (close)     | Close the status page |

**Action dispatch**: For `build`, `configure`, `rebuild`, `clean`, `delete`,
`pin`, and `options`, the tree walks upward from the cursor line to find the
nearest node that has the corresponding `on_<action>` callback. This means pressing
`b` on a child detail line triggers the build action of the parent node.

**Action picker (`<CR>`)**: The Enter key walks up to the nearest widget with
`on_*` callbacks, collects all available actions, and opens `vim.ui.select`
with the action list. The `enter` action label is context-dependent, set by
the section renderer via the `enter_label` field on the widget:
- Profile nodes: "Activate"
- Config set tool entries: "Activate"
- Project config/tool nodes: "Open task output"

The picker is skipped (direct invoke) when:
- The widget has `direct = true` (sentinel lines), OR
- Only one action exists on the widget (no other actions to discover)

**Sentinel lines**: Interactive `item` nodes that appear at the end of
sections to provide discoverable create/add flows. Sentinels have
`direct = true` on the widget, so Enter invokes `on_enter` immediately.
- **Profiles section**: `▸ Create new profile` — opens the profile creation
  multi-step picker (config set → tool → materialize). Shows "No projects
  yet." when no projects exist.
- **Projects section**: `▸ Add project` — opens the project browser float.

**Destructive action highlighting**: `R`, `C`, `D`, `U`, `<C-n>` keys are
highlighted with `DiagnosticWarn` in the help dialog.

### 1.4 Action Hints

Action hints show available keys close to the actionable items. Hints use
`Comment` highlight. Format: `[key] label  [key] label  ...` — keys in
brackets, separated by double spaces.

**Header hint**: After the Root line, a `Comment` leaf shows global actions:
`[?] help  [L] load  [<C-n>] reset`

**Group header hints with `[t]`**: Profile project groups also include `[t] task output`.

**Section title hints**: Some sections show a `Comment` hint line after the
title listing available actions for top-level nodes.

| Section | Hint line |
|---------|-----------|
| Profiles | `[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Orphaned Configurations | `[D] delete` (appended to title via chunks) |

**Group header hints**: Inner groups that contain actionable items append a
hint suffix to the group label. The label uses `LoomworksActionable` highlight
and the suffix uses `Comment` highlight (via `group` with chunks).

| Group label | Section | Hint suffix |
|-------------|---------|-------------|
| Projects: | Profiles | `[b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Tools: | Configuration Sets | `[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Configurations: | Projects | `[b] build  [c] configure  [p] pin  [o] options  [R] rebuild  [C] clean  [D] delete` |

### 1.5 Profiles Section

Shows all materialized (cached) and explicit profiles. Profiles only appear
here when they exist in the cache or are declared in the config.

**Profile node display** (all profiles use the same rendering):
```
{marker} {fold_char} {profile_key} [{tag}] ({status_label}) [{elapsed}] [— {op_message}]
```

Where:
- `{tag}` = `[stale]` for orphaned profiles, `[explicit]` for declared
  profiles, omitted otherwise
- `{status_label}` = aggregate status from `Profile:status()` (e.g., "built",
  "1 configuring, 1 failed build", "3 configured, 2 unconfigured")
- `{elapsed}` = shown only when running (e.g., "1m23s")
- `{op_message}` = last operation result (e.g., "built in 42s")

All profiles are displayed identically. A profile with key `"Debug:ninja-gcc"`
appears like any other profile; it simply has fewer projects when expanded.

**Profile highlight rules**:
| Condition | Highlight |
|-----------|-----------|
| Has active Operation + active | `LoomworksActive` |
| Has active Operation + not active | `LoomworksRunning` |
| Active (no operation) | `LoomworksActive` |
| Failed status | `LoomworksFailed` |
| Unconfigured | `LoomworksUnconfigured` |
| Otherwise | `LoomworksConfigured` |

Note: "Has active Operation" means this profile initiated the action.
Profiles that share ConfigUnits with the initiating profile show spinners
(from running ConfigUnit state) but not the orange highlight or timer.

**Profile children** (when unfolded):
- Set name (with warning if orphaned/stale) — only for set-based profiles
- Tool label (with generator/compiler details)
- Device selection (only when workspace has device-capable modules) —
  shows `Device: <name> (<serial>)` (online), `Device: <serial> (offline)`
  (offline/stale), or `Device: (none selected)`. `<CR>` opens device picker.
- Last operation message
- Projects sub-group:
  - Each project: `project_key [module_type] → variant {progress}` with status highlight
  - When unfolded: status, build dir, cmake details (generator, compiler)

**Profile actions**:

| Node type | `<CR>` | `b` | `c` | `t` | `R` | `C` | `D` |
|-----------|--------|-----|-----|-----|-----|-----|-----|
| Profile | activate | build all | configure all | — | clean+build all | clean all | delete with dialog |
| Project under profile | open task output | build config | configure config | open task output | clean+build config | clean config | delete config with dialog |

**Sentinel: Create new profile**

After the profile list (or as sole content when empty), an interactive item:
```
▸ Create new profile
```
Enter opens the profile creation multi-step picker:

1. **Pick configuration set**: Shows existing config sets from the
   workspace config, plus auto-detected options from
   `generate_default_config_sets()`. Auto-detected options are labeled
   `"Name (auto-detected)"` with a mapping summary. Selecting an
   auto-detected option writes it to user.json via
   `add_configuration_set()` before continuing.

2. **Pick tool** (skipped if module has no keyed tools, or only one tool
   detected): Shows available tools from `detect_tools()`.

3. **Materialize**: Calls `config_set:ensure_profile(tool_entry)` to
   create the profile in cache. Auto-activates only when this is the
   first profile in the workspace; otherwise just creates it.

When no projects exist, the sentinel is replaced with:
```
No projects yet. Add projects first.
```

### 1.6 Orphaned Items Section

Shows orphaned cached configurations and stray build directories. Visible
when either type exists (hidden otherwise — the common case).

**Title**: `Orphaned Items` with `Title` highlight.

**Orphaned configurations**: cached configs with build state not referenced
by any profile. Grouped by project key (sorted alphabetically). Each
project is a foldable node; each config within is a foldable node showing
the config key and its status.

**Stray build directories**: directories under `{root}/.nvim/build/` not
referenced by any cache entry. Detected via top-down pruning: the scan
reports the highest-level directory whose entire subtree contains no cache
entries. Directories that ARE cache entries (or parents of cache entries)
are skipped. Shown as flat items with `(stray)` suffix.

```
Orphaned Items  [D] delete

  ▶ App
    ▶ Debug:ninja-gcc-12 (built)
      Status: built
      Build dir: .nvim/build/App/Debug
  .nvim/build/OldProject (stray)
  ▸ Clean all
```

**Highlight**: Project nodes use `LoomworksUnconfigured`. Config nodes use
`resolve_config_status()` highlights. Stray dir items use
`LoomworksUnconfigured`.

**Actions**: `D` (delete) is mapped on config nodes and stray dir items.
All other action keys (`b`, `c`, `R`, `C`, `p`) are not bound — orphaned
items cannot be built or configured. Deletion shows the standard
confirmation dialog.

**Sentinel: Clean all**

After the last orphaned item:
```
▸ Clean all
```
Enter shows a confirmation dialog listing:
- All orphaned cached configurations (with state and build dirs)
- All stray build directories

On confirm: deletes orphaned cache entries + build dirs via `_run_deletion`,
then deletes stray build dirs. If nothing to clean, shows a notification.

### 1.7 Configuration Sets Section

Shows configuration sets from the merged config (loomworks.json + user.json).
Only appears when sets exist.

**Set node display**:
```
{fold_char} {modified_tag}{set_name}
```

Where `{modified_tag}` = "+" if the set is modified (see `specification.md` §2.4),
empty otherwise. Shared-only sets (not in user.json) are dimmed (`Comment`).

Highlighted with `LoomworksActive` if the active profile belongs to this set,
otherwise `LoomworksActionable` (or `Comment` if shared-only).

**Set node actions**:

| Action | Behavior |
|--------|----------|
| `<CR>` | Action picker: Edit mappings, Create profile from set, Delete |
| `D`    | Delete config set with confirmation dialog |

**Config set editing** (`<CR>` on a set node):

Opens a dedicated config set editor dialog. Shows each project in the
workspace with its current variant mapping and available configurations
(from module.info). The user can change each mapping via `vim.ui.select`
or set it to "None" to remove the mapping. Accept (`y`) applies changes
via `update_config_set_mapping()` for each changed mapping. Cancel (`q`)
discards changes.

Changed mappings may orphan existing cached configs (old variant no longer
referenced). This is intentional — orphans are cleaned explicitly via the
"Clean all orphaned items" action in the Orphaned Configurations section.

**Config set deletion** (`D` on a set node):

Shows a confirmation dialog listing:
- Profiles that reference this set (will become orphaned-set)
- Warning that cached configs will become orphaned

On confirm: `remove_configuration_set()`. Profiles that referenced the set
become orphaned_set. Cached configs for those profiles become orphaned. No
immediate deletion of cache entries — the user cleans via "Clean all orphaned
configs" in the Projects section.

**Set children** (when unfolded):
- Projects sub-group: `project_key → variant`
- Tools sub-group (if keyed tools detected): one item per detected tool

**Tool entry display**:
```
{marker} {tool_label} {suffix}
```

Where:
- `{marker}` = status marker for the corresponding profile (if materialized)
- `{suffix}` = status/progress info if materialized, empty if not
- Highlight follows same rules as full profiles

**Tool entry actions**:

| Action | Materialized profile exists | No materialized profile |
|--------|---------------------------|------------------------|
| `<CR>` | activate | activate (materializes first) |
| `b`    | build via profile | build via `run_profile_action` (materializes first) |
| `c`    | configure via profile | configure via `run_profile_action` (materializes first) |
| `R`    | rebuild via profile | nil (no-op) |
| `C`    | clean via profile | nil (no-op) |
| `D`    | delete profile with dialog | nil (no-op) |

**Sentinel: Create configuration set**

After the last config set, an interactive item:
```
▸ Create configuration set
```
Enter opens a picker with two kinds of options:

1. **Auto-detected templates** — generated by `generate_default_config_sets()`
   using `map_variant()` on all projects. Standard templates: "Debug" and
   "Release". Each template pre-fills project→configuration mappings by
   matching variant types across modules. Templates that match an existing
   config set name are excluded.
2. **Custom** — opens the config set editor dialog with empty mappings.
   User enters a name and manually selects variant per project.

Selecting a template creates the config set immediately with the
pre-computed mappings. No editor dialog — the mappings are deterministic.

This replaces the previous flow where all config sets started from the
editor dialog.

### 1.8 Projects Section

Shows all projects from the active set, including orphaned projects. Projects
are sorted alphabetically with orphaned projects at the end.

**Project node display**:
```
{fold_char} {modified_tag}{project_key} [{type}] {orphan_tag} {refresh_tag}
```

Where:
- `{modified_tag}` = "+" if any child or the project declaration is modified
  (see `specification.md` §2.4), empty otherwise
- `{orphan_tag}` = "(orphaned)" if in cache but not in config
- `{refresh_tag}` = "!" if `needs_refresh` is true

**Shared-only items** (exist only in loomworks.json, not in user.json) are
displayed with `Comment` highlight (dimmed). Module-generated default
configurations are also dimmed. Dimmed items become normal on first
interaction (auto-copied to user.json).

**Project children** (when unfolded):
- Path
- Refresh reasons (if any, with `!` prefix and `DiagnosticWarn` highlight)
- Configurations sub-group

**Configuration display** (keyed-tool modules):
Each configuration shows its available tools:
```
{fold_char} {config_name} {brief}
  {fold_char} {tool_label} {progress}     ← one per detected/cached tool
    Status: {status}
    Build dir: ...
    Last configured: ...
    Generator: ...
    {fold_char} Targets ({total_count})       ← only when targets exist
      {fold_char} {type_group} ({group_count})
        {fold_char} {target_name}
          Links: dep1, dep2
```

**Configuration display** (non-keyed modules):
```
{fold_char} {config_name} {brief}
  {fold_char} Status: {status} {progress}
    Build dir: ...
    ...
```

**Targets sub-tree** (post-configure only, modules with `parse_targets`):

When a configuration has cached targets, a foldable "Targets (N)" node
appears in the unfolded tool entry detail view, where N is the total
target count. Targets are grouped by type under foldable sub-headers
showing the group name and count (e.g., "Executables (2)"). Within each
group, targets are sorted alphabetically by name. Targets with link
dependencies can be unfolded to show `Links: dep1, dep2, ...` on a
single line. Targets without dependencies are leaf nodes (no fold arrow).

Type group labels and display order:
1. `Executables`
2. `Static Libraries`
3. `Shared Libraries`
4. `Module Libraries`
5. `Object Libraries`
6. `Interface Libraries`

Only groups containing at least one target are shown.

**Configuration actions** (at the tool/status level):

| Action | Behavior |
|--------|----------|
| `D`    | Delete config with dialog |

**Tool entry highlight rules** (keyed-tool modules):

| Condition                       | Highlight              |
|---------------------------------|------------------------|
| Running                         | `LoomworksRunning`     |
| Deleting                        | `LoomworksDeleting`    |
| Active (matches active profile) | `LoomworksActive`      |
| Failed                          | `LoomworksFailed`      |
| Configured/Built (not active)   | `LoomworksConfigured`  |
| Unconfigured                    | `LoomworksUnconfigured`|

A tool entry is "active" when the active profile's tool_key matches the
entry's tool_key and the configuration variant matches the project's active
configuration.

**Non-keyed module highlight rules** follow the same pattern but without
tool_key matching — the entry is active when its variant matches the
project's active configuration.

**Launch configurations sub-group**

After the configurations group, each non-orphaned project shows a
"Launch:" group listing its launch configurations.

Each launch config item shows `{name}  {command} {args}`. Actions:

| Action | Behavior |
|--------|----------|
| `<CR>` | Edit launch config (opens launch editor dialog) |
| `D`    | Delete launch config with confirmation |

A "Add launch config" sentinel opens the launch editor for a new config.

The **launch editor dialog** edits: name, command, args (space-separated),
working directory, and environment variables (key=value pairs). Env vars
can be added (`▸ Add variable`) and removed (`D`). Inline name validation
prevents duplicates. Accepts with `y`, cancels with `q`.

**Sentinel: Add project**

After the last project (or as sole content when no projects exist), an
interactive item:
```
▸ Add project
```
Enter opens the project browser float (§1.13). Replaces the former `A`
keybinding.


### 1.9 Deletion Confirmation Dialog

Shown for all delete operations (`D` key). Floating window centered in editor.

**Content**:
1. Title (e.g., "Delete profile: Debug:ninja-gcc-12")
2. Running tasks that will be stopped (if any)
3. Items that will be removed (`disposition = clean`)
4. Items that will be reset (`disposition = reset`)
5. Items that will be kept (`disposition = keep`, referenced by another
   profile)
6. Confirmation prompt

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

### 1.10 Nuke Confirmation Dialog

Shown when `<C-n>` is pressed. Floating window centered in editor.

**Content**:
1. Title: "Reset workspace cache"
2. List of paths that will be deleted:
   - `<root>/.nvim/build/`
   - `<root>/.nvim/loomworks.cache.json`
3. Confirmation prompt

**Root resolution**: Uses `ws.root` if a workspace is loaded, otherwise
resolves from cwd via `workspace.resolve_root()`.

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

**Safety checks** (in `nuke_cache(root)`):
1. Root must be an absolute path (rejects relative paths)
2. `loomworks.json` must exist at the root (confirms it is a real workspace)
3. Every path to delete is verified to be under `root/.nvim/` using
   normalized path prefix checking (prevents directory traversal)

If any check fails, the operation aborts with an error notification and
no files are deleted. These checks are specific to the nuke operation —
the general io layer does not restrict deletion paths, because normal
config/profile deletion may delete build directories anywhere.

### 1.11 Help Dialog

Floating window showing all keybindings. Destructive keys (`R`, `C`, `D`,
`<C-n>`) have their key character highlighted with `DiagnosticWarn`.

### 1.12 Options Float

Triggered by `o` on a configuration or tool entry node in the Projects
or Profiles section. Opens a floating window showing the project's build
options for that configuration. Only available for configured projects
with a cached build directory.

**`Core:get_project_options(project_key, config_key) → (OptionGroup|Option)[]|nil`**

Resolves the build directory from cache and delegates to the module's
`get_options()`. Returns nil if the project is not configured or the
module does not support options.

The float uses a Tree widget with foldable groups. The module returns a
tree of `OptionGroup` and `Option` nodes. Each group shows its label and
child count. Each option shows `key = value`. BOOL values are highlighted
(ON = green, OFF = dimmed). Options with helpstrings show them as
children when unfolded. Options with choices show them in parentheses
after the value. Fold/unfold with `<Tab>`.

The float is read-only. Close with `q` or `<Esc>`.

### 1.13 Project Browser

The project browser is a float opened from the "Add project" sentinel line.
It scans workspace subdirectories asynchronously and shows detected project
types using each module's `detect()` method.

**Layout**: Tree widget in a `Snacks.win` float. Title: "Add Project".

**Entry display**: Each directory entry shows its name followed by detected
type tags (e.g., `MyProj  [<module>: <marker>]`). Directories matching
multiple modules show all tags. Already-added projects show `✓` with
`DiagnosticOk`. Directories with no detection show `Comment` highlight.

**Async scanning**: On open, `modules.scan_directory_async()` scans the
workspace root. On fold open, subdirectories are scanned lazily. Results
are cached in a browser-local dict. Pending scans show "scanning...".

**Filtered directories**: `.git`, `.nvim`, `.cache`, `.vs`, `.vscode`,
`node_modules`, `build`, `out`, `__pycache__`, and all hidden directories
(starting with `.`) are excluded from scanning.

**Keybindings**:

| Key     | Action  | Behavior |
|---------|---------|----------|
| `<CR>`  | enter   | Picker with Add/Remove by module type (see below) |
| `d`     | remove  | Remove project from workspace (with confirmation) |
| `r`     | refresh | Clear scan cache and re-scan |
| `q`     | close   | Close the browser |

**Project key derivation**:
- Root-level directories: basename as key, `path` field omitted
- Nested directories: relative path (with `/` → `_`) as key, explicit `path`
  field

**Enter picker**: Each browser entry has a context-dependent picker:
- Unadded types show `Add [type]`
- Already-added types show `Remove [type]`
- Single add action: always shows picker (user confirms)
- Mixed state: both add and remove options appear

**Configuration mapping dialog**: When adding a project to a workspace
that already has configuration sets, a mapping dialog opens instead of
adding immediately.

The dialog layout depends on the module type and workspace state:

**Keyed module, no tool selected** — tool row first, no mappings:

```
  Add "<project>" [<module>]

  Tool:  None ▸

  Project will be added without configuration mappings.

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool selected** — tool row first, then mappings:

```
  Add "<project>" [<module>]

  Tool:  <tool label> ▸

  Debug     Debug ▸
  Release   Release ▸

  Profiles to upgrade:
    Debug → Debug:<tool_key>

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool inherited** — when existing profiles already have
a tool, the tool is inherited automatically. No tool row; mappings only:

```
  Add "<project>" [<module>] — Map configurations

  Debug     Debug ▸
  Release   Release ▸

  [Enter] change  [y] accept  [q] cancel
```

**Non-keyed module** — mappings only:

```
  Add "<project>" [<module>] — Map configurations

  Debug     <variant> ▸
  Release   <variant> ▸

  [Enter] change  [y] accept  [q] cancel
```

The profile upgrade preview shows only profiles whose config set has
a non-None mapping for the new project.

- Enter on a mapping row opens `vim.ui.select` with configurations + "None"
- Enter on the tool row opens `vim.ui.select` with detected tools
- `y` accepts: chains decomposed operations (see below)
- `q`/Esc cancels: project is NOT added
- Skipped when no config sets exist or project has no detectable configs
- No success notifications — UI state changes are sufficient. Only
  errors are shown via `vim.notify`.

**Tool detection gating**: When the module has keyed tools, the project
browser ensures tool detection has completed before opening the mapping
dialog. If detection is still running, the dialog opens in the callback
after detection completes.

**Decomposed add-project operations**: On accept, the mapping dialog
chains three atomic operations. Each operation saves to disk and
remerges independently. Each intermediate state is valid — if the
process crashes between steps, no data is lost or corrupted.

1. `ws:add_project(key, type, path)` — adds the project entry to
   user.json. Project shows as unmapped.
2. For each config set with a non-nil mapping:
   `ws:update_config_set_mapping(set, key, variant)` — adds one
   mapping to one config set.
3. If a tool was selected or inherited:
   `ws:upgrade_profiles_for_tool(tool_entry)` — upgrades cached
   no-tool profiles to keyed profiles (renames, adds tool fields,
   creates skeleton cache entries). Extends existing keyed profiles
   with skeleton entries for the new project.

**Cache cleanup on removal**: The removal confirmation dialog shows all
cached configurations for the project that will be deleted. Entries with
build state (configured/built/failed) are listed with their build
directories. Skeleton entries (unconfigured) are silently included.

**Profile downgrade on removal**: When removing a project whose module
has keyed tools, the project browser checks whether it is the last
project of that module type. If so, the removal confirmation dialog also
shows a profile rename preview.

After confirmation:
1. `ws:remove_project(key)` removes the project from config and config sets.
2. Cached configurations for the project are deleted (entries removed from
   cache, build directories deleted asynchronously via safe deletion).
3. `ws:downgrade_profiles_from_tool(mod_type)` strips tool suffixes from
   affected profiles when the last keyed-module project is removed.

This is not "auto-clean" — it is an explicit user action with a
confirmation dialog showing exactly what will be deleted.

**File mutation**: All changes write to `loomworks.user.json` via Workspace
mutation methods. Each method saves and remerges independently. Published
items are written to `loomworks.json` only on explicit `:w` (see
`specification.md` §2.4).

Available Workspace mutation methods:
- `add_project(key, type, path?)` — add a project entry
- `remove_project(key)` — remove project + clean up config sets
- `update_config_set_mapping(set_name, project_key, variant)` — update
  one mapping in a config set
- `add_configuration_set(name, mappings)` — add a config set
- `remove_configuration_set(name)` — remove a config set
- `upgrade_profiles_for_tool(tool_entry)` — upgrade no-tool profiles
  to keyed profiles; extend keyed profiles with new project entries
- `downgrade_profiles_from_tool(mod_type)` — strip tool from profiles
  when last project of a keyed-module type is removed
- `compute_downgrade_preview(project_key)` — compute profile renames
  that would occur if a project were removed (pure query, no mutation)

### 1.14 Auto-refresh

The status page refreshes automatically on these events:
- `task_started`, `task_stopped`, `task_result`, `task_progress`
- `deletion_started`, `deletion_completed`, `deletion_failed`
- `active_set_changed`
- `operation_started`, `operation_finished`

Refreshes are coalesced via `vim.schedule` to avoid redundant redraws.

An animation timer (80ms) runs when any node has `spinning = true`, providing
smooth spinner animation for running/deleting states. The timer stops
automatically when no spinners are active.

---

## 2. Highlight Groups

| Group                    | Default link      | Usage |
|--------------------------|-------------------|-------|
| `LoomworksActive`        | `DiagnosticOk`    | Active profile, active set |
| `LoomworksBuilt`         | `DiagnosticOk`    | Built configurations |
| `LoomworksConfigured`    | `DiagnosticInfo`  | Configured (not yet built) |
| `LoomworksUnconfigured`  | `Comment`         | Never configured |
| `LoomworksFailed`        | `DiagnosticError` | Failed configure or build |
| `LoomworksRunning`       | `DiagnosticWarn`  | Running tasks (non-active) |
| `LoomworksDeleting`      | `DiagnosticError` | Deletion in progress |
| `LoomworksUnknown`       | `DiagnosticWarn`  | Unknown state (partial deletion) |
| `LoomworksActionable`    | `Normal`          | Actionable items (sets, configs) |

Users can override these by defining the highlight groups before plugin load.

---

## 3. Winbar / Statusline Component

`lualine/components/loomworks.lua` provides a lualine component for
winbar display.

**Default display**: `{set_name} {join} {project}/{configuration}`

Where `{join}` defaults to `\u{e0b1}` (powerline thin right arrow) with
spaces.

**Configurable via `show` option**: array of parts to display:
- `"set_name"` — configuration set name
- `"project"` — project key for current buffer
- `"configuration"` — active configuration
- `"tool_key"` — tool key (e.g., the active profile's `tool_key`)

**Returns empty** when:
- No workspace loaded
- No active profile
- Current buffer is not in any project

> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 3. State Machine

### 3.1 ConfigUnit States

```
                ┌──────────────┐
                │ unconfigured │◄──── clean / initial
                └──────┬───────┘
                       │ configure started
                       ▼
                ┌─────────────┐
          ┌─────│ configuring │
          │     └──────┬──────┘
          │            │
    fail  │    success │
          │            ▼
          │     ┌────────────┐
          │     │ configured │◄──── successful configure
          │     └─────┬──────┘      (does not downgrade from built)
          │           │ build started
          │           ▼
          │     ┌──────────┐
          │     │ building │──────┐
          │     └────┬─────┘      │
          │          │            │ fail
          │  success │            │
          │          ▼            ▼
          │     ┌─────────┐  ┌────────────────┐
          │     │  built  │  │  build_failed  │
          │     └─────────┘  └────────────────┘
          ▼
   ┌──────────────────┐
   │ configure_failed │
   └──────────────────┘

   Any state ──── delete/clean ────► deleting ────► unconfigured (clean, success)
                                                    or removed (delete, success)
                                                    or unknown (failure)

   unknown ──── delete/clean ────► deleting ────► (same outcomes)
```

**State derivation priority**: `deleting > running > cached`

- If `_deleting` flag is set → `"deleting"`
- If `_action` is set → `"configuring"` or `"building"`
- Otherwise → read from `cached.state` (with name mapping)

**State transition rules**:

1. Successful configure does NOT downgrade from `built` to `configured`.
2. Failed states are never auto-cleaned (rebuilding large C++ is expensive).
3. Only explicit user action (clean/delete) removes failed state.
4. `last_configured` and `last_built` are stored separately — a failed build
   does not invalidate the configure timestamp.
5. The `deleting` state is transient — it exists only while a deletion
   operation is in flight. The UI displays "cleaning" when the action is
   a clean (reset state, keep cache skeleton) vs "deleting" when it is a
   full delete (remove cache entry entirely). ConfigUnit tracks the reason
   via `mark_deleting(flag, reason)`.
6. The `unknown` state means the build directory may be partially deleted
   (e.g., subprocess was killed, or files were locked on Windows). The only
   user actions available from `unknown` are delete and clean (retry).
   Build and configure are blocked.

### 3.2 Workspace Lifecycle

The workspace has three states:

| State | Meaning |
|-------|---------|
| `uninitialized` | No workspace loaded. All queries return nil. |
| `initializing` | Async file reads in progress. Queries return nil. |
| `initialized` | Files read, parsed, merged. Workspace is usable. |

**Initialization flow:**

1. `setup()` is called — workspace enters `initializing`.
2. Three files are read asynchronously (loomworks.json, user.json,
   cache.json) via libuv non-blocking I/O.
3. On completion: parse, validate, merge (without tool detection).
4. Workspace enters `initialized`. File watchers are started.
   `workspace_changed` event is emitted.
5. Tool detection starts as an independent background task (see §3.3).

`setup()` returns immediately. Callers must not assume the workspace
is available synchronously after `setup()` returns.

### 3.3 Tool Detection Lifecycle

Tool detection is orthogonal to workspace initialization. It has
three states:

| State | Meaning |
|-------|---------|
| `not_scanned` | Detection has not run. Tool entries unavailable. |
| `scanning` | Async detection in progress. |
| `scanned` | Detection complete. Tool entries available. |

Detection starts automatically after the workspace reaches
`initialized`. On completion, the system remerges and emits
`tools_detected`. The UI refreshes to show tool entries.

Manual re-scan (`rescan_tools()` / `L` key) transitions from
`scanned` → `scanning` → `scanned`, clearing and rebuilding the
in-memory tool cache.

During `scanning`, profile materialization (which requires detected
tools) waits for detection to complete before proceeding.

### 3.4 Cache state names vs ConfigUnit state names

| Cache state        | ConfigUnit state    |
|--------------------|---------------------|
| `unconfigured`     | `unconfigured`      |
| `configured`       | `configured`        |
| `built`            | `built`             |
| `failed_configure` | `configure_failed`  |
| `failed_build`     | `build_failed`      |
| `unknown`          | `unknown`           |
| (runtime only)     | `configuring`       |
| (runtime only)     | `building`          |
| (runtime only)     | `deleting`          |

---

## 4. Profile Lifecycle

### 4.1 Materialization

Materialization writes a profile to the cache so that build tasks can be
launched against it. A profile must be materialized before any task runs.

**Trigger**: `ConfigurationSet:activate()`, `build()`, `configure()`, `<CR>` in
UI.

**Process**:
1. Receive structured data: set_name and optional tool_entry (tool_key,
   tool_data, tool_label, tool_mod_type)
2. Look up set_name in `configuration_sets` → mappings
3. For each project in the mappings:
   - Compute config_key (variant + tool_key for keyed modules)
   - Create skeleton cache entry if absent
4. Write profile entry (with `configuration_set` and tool fields) to
   `cache.profiles`
5. Save user.json, trigger remerge

### 4.2 Activation

Activation makes a profile the "active" profile. The active profile determines:
- Which configurations are shown in `buf_status()`
- Which tool/config the LSP integration uses
- Which profile is highlighted with `LoomworksActive` in the status page

**Process**:
1. For new profiles: `ConfigurationSet:activate(tool_entry)` finds or
   materializes the profile, then activates it via the Profile object
2. For existing profiles: `Profile:activate()` writes `active_profile` to
   `loomworks.user.json` and triggers remerge (fires `active_set_changed`)

### 4.3 Set Name Migration

When configuration set names change in `loomworks.json` (e.g., "debug" →
"Debug"), the system performs case-insensitive migration:

1. Build a lowercase lookup of config set names from the new config
2. For each cached profile with a non-nil `configuration_set`, if it doesn't
   match any config set exactly but does match case-insensitively:
   - Rename the profile key in cache
   - Update `configuration_set` in the profile
   - Update `active_profile` in user.json if it pointed to the old key
3. Save cache

Pinned profiles (`configuration_set == nil`) are skipped — they have no set
to migrate. This runs on both initial setup and config hot-reload.

### 4.4 Orphaned Profiles (Stale)

When a configuration set is removed from `loomworks.json`:

1. The profile's `configuration_set` no longer matches any config set
2. `resolve_profile_mappings()` falls back to `_cached_projects` data
3. Profile is marked with `orphaned_set = true`
4. Profile remains fully functional — builds still work using cached mappings
5. UI shows `[stale]` tag and a warning about the removed set

### 4.5 Orphaned Configurations

A cached configuration is **orphaned** when it has build state
(configured/built/failed) but is not referenced by any profile's `projects`
entries. Common cause: switching git branches where a profile was built on
one branch but the configuration set that produced it no longer exists.

**On startup**:
- Cached configs with state but no profile reference → kept as orphans
  (shown in the Orphaned Configurations UI section)
- Cached configs without state (unconfigured skeletons) and no profile
  reference → silently dropped from cache

**Rules**:
1. Orphaned configs are never auto-deleted — the user must explicitly delete
2. Orphaned configs are never auto-adopted into profiles
3. The only action available on an orphaned config is delete (removes cache
   entry + build directory)
4. Orphaned configs do not affect profile resolution or the active set

### 4.6 Deletion

**Profile deletion** (`D` key):
1. Show confirmation dialog listing affected items
2. For each project in the profile:
   - If config is referenced by another profile → disposition = `keep`
   - If not → disposition = `clean` (remove cache entry + build dir)
3. Stop any running tasks for affected configs
4. Mark affected ConfigUnits as `deleting`
5. Remove profile entry from cache immediately (profile disappears from UI)
6. **Crash-safe cache update**: set cache state to `"unknown"` for all
   affected items and save cache to disk. This ensures that if Neovim
   crashes mid-deletion, the cache still tracks the build directories.
7. **Delete build directories asynchronously** via subprocess. Multiple
   directories are deleted in parallel (one subprocess per directory).
8. On success: remove/reset cache entries per disposition, save cache,
   flush deletion waiters, remerge
9. On failure: cache already has `"unknown"` state — notify user with
   subprocess error output, unmark ConfigUnits, remerge
10. On crash: cache has `"unknown"` entries on next startup, user can
    retry delete/clean

**Invariant**: every build directory on disk always has a corresponding
cache entry. Cache entries are only removed **after** the build directory
has been successfully deleted.

**Config deletion** (`D` key on a configuration):
1. Show confirmation dialog
2. If referenced by any profile → disposition = `reset`
   (clear state but keep skeleton; profile stays and shows "unconfigured")
3. If not referenced by any profile → disposition = `clean` (remove entry)
4. Same async stop/mark/execute/unmark cycle
5. No profiles are ever removed — profiles are only deleted via explicit
   profile deletion (`D` on the profile itself)

**Async build directory deletion**: Build directories are deleted via
`vim.system()` subprocess calls (`rm -rf` on Unix, `cmd /c rd /s /q` on
Windows). This prevents blocking Neovim's event loop during deletion of
large build directories. Subprocess stderr is captured and shown to the
user on failure.

**Build directory safety**: Build directories stored in the cache may reside
anywhere under the workspace root (e.g., `<root>/build/`, `<root>/.nvim/build/`,
a preset's `binaryDir`). Before deleting a build directory, the system
normalizes the path and verifies it is under the workspace root. Paths that
resolve outside the workspace (e.g., via `../` traversal, absolute paths
pointing elsewhere, or corrupted cache entries) are refused with an error
notification and left untouched. This check lives in core (at the
`execute_deletion` / clean level), not in the io layer — the io layer is a
general-purpose utility that deletes what it is told to.

**Case sensitivity**: On Windows (case-insensitive filesystem), all path
normalization lowercases the path to ensure reliable comparisons. This
affects build dir matching, prefix checks, stray detection, and the build
dir reverse index / operation locks. Cached build_dir values retain their
original casing for display, but all comparisons use the lowercased form.

**Case collision prevention**: Project keys and configuration set names that
differ only by case would produce the same build directory path on
case-insensitive filesystems. The system warns on parse (loomworks.json
load) and rejects at runtime (`add_project`, `add_configuration_set`) to
prevent silent directory collisions.

**Shared build directory protection**: Multi-config generators (e.g., Ninja
Multi-Config, Visual Studio) share a single build directory across multiple
configurations (Debug and Release produce output in the same directory,
selected at build time via `--config`). When deleting a configuration that
shares a build directory with other configurations:

1. A reverse index (`_build_dir_refs`) maps each normalized build directory
   to the set of cache keys that reference it. Rebuilt during every remerge.
2. Before adding a directory to the deletion queue, subtract the cache keys
   being deleted in the current batch from the ref set.
3. If remaining refs > 0 → skip the directory (don't rm -rf). The cache
   entry is still removed/reset, but the filesystem directory is preserved.
4. The user is notified: "Skipped deleting {dir} — still referenced by
   {N} config(s)".

**Invariant**: a build directory is only deleted from the filesystem when no
remaining cache entries reference it after the current deletion batch.

### 4.7 Cleaning

**Profile clean** (`C` key):
1. For each project in the profile:
   - Set cache state to `"unknown"` and save to disk (crash-safe)
   - Delete build directory asynchronously (same subprocess approach as
     deletion)
   - On success: reset cache entry to unconfigured (clear state, build_dir,
     timestamps, cmake data), keep skeleton (variant, tool_key, tool_data)
   - On failure: cache already has `"unknown"` state, notify user
2. Profile itself is NOT removed — it stays in the Profiles section

**Config clean** (`C` key on a configuration):
- Same as profile clean but for a single configuration

### 4.8 Configuration Rename Propagation

When a project configuration is renamed (old_name → new_name) via the
config editor, all references are updated atomically:

1. **Config**: rename in `type_config.configurations`, update `inherits`
   references in sibling configs, update `configuration_sets` mappings for
   this project (saved to user.json; published to loomworks.json on `:w`)
2. **Cache entries**: rekey `cache.configurations` entries matching
   `project_key + old variant` → new config_key, update `variant` and
   `config_key` fields. **Build directory is preserved as-is** (the old
   path stays in the cache — the system accepts any build_dir path)
3. **Profile configurations arrays**: replace old cache keys with new ones

On next configure after rename, the module resolves a fresh build directory
using the new name. If the computed path collides with an existing directory
on disk, a numeric suffix is appended (`-2`, `-3`, ...) to ensure uniqueness.

**Cached build dir preference**: When a cache entry already has a
`build_dir`, task generation uses the cached path instead of recomputing.
This preserves the existing build directory after rename until the user
explicitly deletes and reconfigures.

### 4.9 Project Rename Propagation

When a project key is renamed (old_key → new_key), all references are
updated atomically:

1. **Project**: update `key` and (when `path` defaulted to the key)
   `path` on the Project domain object.
2. **Profile mappings**: each profile's resolved mappings dict is
   keyed by project_key string; entries are rekeyed.
3. **ConfigUnit ids**: each ConfigUnit registered under the project
   has its `id` rekeyed from `old_key/config_key` to
   `new_key/config_key`. `_init_project_key` follows.
4. **ConfigurationSet mappings**: stored as `project_object → config_object`,
   so the Project identity is preserved and no map rebuild is required.
5. **user.json**: re-saved with the new key. **cache.json**: re-saved
   so the rekeyed ConfigUnit ids land on disk.

Build directories on disk are not renamed. Cache entries' `build_dir`
fields preserve their absolute paths after rename — the existing build
directory continues to be used. A subsequent delete + reconfigure
yields a fresh directory under the new key per the module's path
formula.

Rename is rejected when:
- The new key matches another existing project key (case-insensitive,
  matching the case-collision rules under §4.6).
- The new key fails `validate_path_name` (slashes, dots, sanitization
  collision).

On save failure, the rename rolls back: project.key, project.path,
profile mappings, and ConfigUnit ids are restored.

### 4.10 Configuration Set Rename Propagation

When a configuration set is renamed (old_name → new_name):

1. **Set**: update `cs.name`.
2. **Profiles**: each profile with `_configuration_set_name == old_name`
   is updated to `new_name`. The profile key (derived from
   `set_name:tool_keys`) is re-derived.
3. **user.json**: re-saved. **cache.json**: re-saved with the new
   profile keys.

Rename is rejected when the new name matches another existing set
(case-insensitive) or fails `validate_path_name`. Rolls back on save
failure.

**Profile rename**: profile keys are derived from configuration set
name + tool keys, not user-named. Profiles cannot be renamed
directly; renaming the underlying set or changing the tool selection
yields the equivalent re-derivation.

---

## 5. Task Execution

### 5.1 Task Readiness

Before launching a task, the system checks the ConfigUnit state:

| Action    | State              | Decision |
|-----------|--------------------|----------|
| configure | unconfigured       | launch   |
| configure | configure_failed   | launch   |
| configure | unknown            | block    |
| configure | any other          | skip     |
| build     | building           | skip     |
| build     | configuring        | defer    |
| build     | unknown            | block    |
| build     | any other          | launch   |

**Blocked tasks**: When a task is blocked due to `unknown` state, the user is
notified that the config must be cleaned or deleted first.

**Deferred tasks**: When a build task is deferred because its config is still
configuring, a listener is registered on the ConfigUnit. When configuring
finishes:
- If configure succeeded → launch the build task
- If configure failed → report failure, do not build

### 5.2 Auto-configure before build

When building a profile and some projects are unconfigured or in
`configure_failed` state:

1. Filter configure tasks to only those that need configuring
2. Launch configure tasks
3. On completion: if all succeeded → launch build tasks; if any failed →
   abort build

### 5.3 Build Directory Operation Queue

Multiple configurations may share a single build directory (multi-config
generators). Concurrent operations on the same build directory can corrupt
the build. The build dir operation queue prevents this:

**Lock types**:
- **Exclusive** (configure, delete, clean): only one at a time, blocks all
  other operations on that build directory
- **Shared** (build): concurrent with other builds, queues behind exclusive
  operations

**Behavior**:
1. Before starting a task, the system acquires a lock on the task's build
   directory (if it has one).
2. If the lock can be acquired immediately, the task starts.
3. If the lock cannot be acquired, the task is queued and starts
   automatically when the lock becomes available.
4. When a task completes or is disposed, the lock is released.
5. On release, the system dequeues and runs the next compatible
   operation(s). Multiple consecutive shared operations are batched.

**Queue ordering**: FIFO. Shared operations are batched (multiple shared ops
run concurrently when dequeued), but shared batching stops at an exclusive
boundary.

**Scope**: The build dir lock is a separate layer from task readiness
(section 5.1). Readiness checks ConfigUnit state; the build dir lock gates
actual task launching to prevent filesystem corruption.

**UI hint**: When an operation is queued (waiting for a build dir lock),
the configuration shows "(queued)" in the status display.

**Recovery from stuck state**: A task whose lifecycle never reaches the
release path (e.g., a crash before subscription wiring completes) can
leave a lock held with no live holder. The Tasks section of the status
page (`spec/ui.md` §1.9) surfaces the lock and per-task state, and
exposes a **force-release** action that drops the lock counts to zero
and replays the FIFO queue. The force-release is idempotent with
respect to the real holder's eventual release call — if the holder
ever does fire, it sees zeroed counts and no-ops.

**Cancel cascade**: A user-initiated cancel on a single task stops
that task's overseer process. Chained next-tasks (the build link of a
configure→build chain, or the next task in a multi-stage operation)
auto-abort because each `do_start` checks `token:is_cancelled()`
before launching and any subsequent `:next()` link rejects when the
cancelled Future propagates. Profile-level and project-level cancel
walk the matching units and cancel each running task individually —
the cascade then takes care of every dependent waiter.

### 5.4 Profile-level operations

All user-initiated actions (build, configure, clean, delete) are tracked
as Operation objects for progress reporting and UI scoping. An Operation
is a first-class object that:

1. Is created when a user initiates an action
2. Watches the affected ConfigUnits' state changes
3. Completes when ALL units reach their target state (or fail)
4. Produces a single result message (e.g., "built in 1m23s", "cleaned in 3s")

Operations have two completion modes:
- **Rank mode** (build/configure): uses a state hierarchy where higher
  states imply lower ones (e.g., "building" satisfies a "configured"
  target). Completes when units reach or exceed the target state.
- **Deletion mode** (clean/delete): completes when the `_deleting` flag
  clears on all affected units. Success if units return to "unconfigured",
  failure if they end up in "unknown" state (partial deletion).

Multiple Operations can coexist — they are independent objects, not a
single slot on Profile. This means overlapping actions on different
profiles don't clobber each other.

**Preemption rules**:
- Clean/delete **cancel** any active build/configure Operations on the
  same ConfigUnits (stopping their overseer tasks).
- Build/configure issued during a clean/delete are **deferred** via
  `after_deletions()` until the deletion Operation completes.

**UI scoping rules**:
- **Spinner**: shown on any profile with running ConfigUnits or an active
  Operation (including clean/delete Operations)
- **Orange highlight + timer/progress**: only on profiles with an active
  Operation (the profile that initiated the action)
- **Last operation message**: displayed after the profile name when no
  operation is active

Individual task completions produce no user-visible notifications.
Operation completion produces a single notification.

The `profile` field on an Operation is optional — config-level clean/delete
may not have a profile context. The `deletion_started`, `deletion_completed`,
and `deletion_failed` events are still emitted from `_run_deletion` for
external consumers, but fidget and the status page use Operation events
exclusively.

### 5.5 Progress tracking

- Each ConfigUnit tracks progress from a module-specific progress parser
  (e.g., ninja's `[n/m]` output)
- Profile-level progress is aggregated across all ProfileProjects:
  - Configure phase counts as 10% of total work
  - Build phase counts as 90% of total work
  - Percentage is averaged across all running projects
- Progress is displayed as `[n/m]` per-config and `N%` per-profile

### 5.6 Deletion waiter pattern

If a build/configure action is requested while a deletion Operation is
active:

1. `has_pending_deletions()` checks for active clean/delete Operations
2. Action is deferred via `after_deletions(fn)`
3. When the last deletion Operation completes, deferred actions are
   flushed in order

### 5.7 Task readiness: unknown state

Configs in `unknown` state block build and configure actions. The user must
issue a delete or clean first to resolve the unknown state. The UI should
indicate this restriction.

### 5.8 Process priority

Long-running tasks launched on behalf of the user — configure, build,
clean, and test runs — must yield CPU and I/O to the editor so the UI
and language server stay responsive while the build runs.

On platforms where the OS exposes a CLI mechanism to drop both CPU and
I/O priority for a spawned child (Linux: `nice` + `ionice`), the
implementation prepends that mechanism to the task's cmd. The
prepended wrapper must be:

- **Transparent to the cmd contract** — original args appear unchanged
  after the prefix; the cmd remains an exec-style argv array.
- **Best-effort** — if the wrapper binaries are missing, the task
  still launches with the original cmd. No errors raised.
- **Scoped to user-launched long tasks** — configure, build, clean,
  test. Short, user-blocking probes (target enumeration, option
  introspection, version checks) are excluded so the editor doesn't
  feel sluggish.
- **Excluded for debugger sessions** — debug-attached test runs go
  through the DAP path and must not be wrapped (would distort
  debugger timing and confuse the adapter).

Platforms without a clean CLI mechanism (Windows, macOS) skip the
wrap and rely on the OS scheduler's defaults. Whether to wrap is a
boolean decision per-task — there is no per-platform priority knob in
the spec.

---

## 6. UI

User-facing UI behavior — the status page, highlight groups, and
the winbar/statusline component — lives in
[`spec/ui.md`](spec/ui.md). Cross-refs from elsewhere in core to
specific UI behavior should target sections within that file.

---

## 7. Events

Events are the primary mechanism for cross-component communication.

| Event                  | Data | Trigger |
|------------------------|------|---------|
| `workspace_changed`    | `Workspace` | Workspace loaded |
| `active_set_changed`   | `ActiveSet` | Profile activated, remerge |
| `operation_started`    | `{ profile_key, action, operation }` | Profile-level action begins |
| `operation_finished`   | `{ profile_key, success, message, operation }` | Profile-level action ends |
| `task_result`          | `TaskResult` | Individual task completes |
| `task_started`         | (via ConfigUnit) | Task registered on a unit |
| `task_stopped`         | (via ConfigUnit) | Task unregistered |
| `task_progress`        | (via ConfigUnit) | Progress update |
| `deletion_started`     | `DeletionItem[]` | Deletion operation begins |
| `deletion_completed`   | `DeletionItem[]` | Deletion operation ends (success) |
| `deletion_failed`      | `{ items, errors }` | One or more build dir deletions failed |
| `tools_detected`       | `tools_by_type` | Tool detection completed |
| `devices_changed`      | `Device[]` | Device scan completed |

Events pass data directly to listeners — no need to re-query, no race
conditions.

---


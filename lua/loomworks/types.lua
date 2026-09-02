--- loomworks/types.lua — LuaCATS type definitions for LSP support.
--- This file is never required at runtime. LuaLS picks up the annotations
--- automatically because it lives in the workspace.
---
--- Domain object annotations (@class loomworks.Workspace, .ConfigUnit,
--- .Profile, .ProfileProject, .Project, .ConfigurationSet, .Configuration,
--- .Tool, .Module, .Target, .LaunchTarget, .Operation) live in their
--- respective implementation files. This file defines ONLY:
---   - Serialization data shapes (file formats)
---   - Interface/contract types (merge results, module interfaces, etc.)
---   - Shared aliases

--- @alias loomworks.Status
--- | "unconfigured"
--- | "configured"
--- | "built"
--- | "failed_configure"
--- | "failed_build"

--- @alias loomworks.ConfigUnitState
--- | "unconfigured"
--- | "configuring"
--- | "configured"
--- | "building"
--- | "built"
--- | "configure_failed"
--- | "build_failed"
--- | "deleting"
--- | "unknown"

--- @alias loomworks.DeletionDisposition "clean"|"reset"|"keep"

--- @alias loomworks.DiagnosticSeverity "warn"|"error"

--- A structural diagnostic surfaced by `Workspace:diagnostics()`.
--- Aggregated from per-domain-object `:diagnostic()` methods (Profile,
--- Configuration, ConfigurationSet, ...).
---
--- The status-page Diagnostics section renders one entry per item.
--- `target_fold_key` names a node elsewhere in the tree (typically
--- the source object's own fold_key, but for source-missing configs
--- it can be a referrer that uses the missing name) — the section's
--- on_enter resolves it to a line and jumps. Entries without a
--- target are informational only. The jump preserves `<C-o>`/`<C-i>`
--- navigation by setting `m'` before moving the cursor.
--- @class loomworks.Diagnostic
--- @field severity loomworks.DiagnosticSeverity
--- @field source string short label of where the diagnostic originates
---     (e.g. `"Profile/Debug"`, `"Project/App/variant:default"`,
---     `"ConfigurationSet/Debug"`)
--- @field message string human-readable description, action-oriented when possible
--- @field target_fold_key? string fold_key of the tree node to jump to on Enter

-- ========================== Serialization Data Shapes ==========================
-- These describe the JSON file formats (loomworks.json, cache.json, user.json).
-- At runtime, domain objects own all state. These shapes are only used at
-- the serialization boundary (parse on load, serialize on save).

--- Parsed loomworks.json structure.
--- @class loomworks.Config
--- @field name? string workspace name override (falls back to dir name)
--- @field projects table<string, loomworks.ConfigProject>
--- @field configuration_sets? table<string, table<string, string>> set_name -> { project_key -> variant }
--- @field profiles? table<string, loomworks.ConfigProfileDef>

--- Project entry in loomworks.json.
--- @class loomworks.ConfigProject
--- @field path string relative path from workspace root
--- @field type string module type ("cmake", "typescript")
--- @field type_config table module-specific configuration from loomworks.json
--- @field depends_on? string[]

--- Explicit profile definition in loomworks.json.
--- @class loomworks.ConfigProfileDef
--- @field configuration_set string
--- @field module_info? table opaque module-specific project-level info
--- @field default_target? table

--- Parsed loomworks.user.json structure.
--- @class loomworks.UserData
--- @field _meta { version: number }
--- @field name? string workspace name override (working copy wins)
--- @field active_profile? string
--- @field default_target? table<string, table> profile_key -> descriptor
--- @field lsp? table<string, table> per-server option overrides
---     (server name -> options; schema is server-specific).

--- Parsed loomworks.cache.json structure.
--- @class loomworks.CacheData
--- @field _meta loomworks.CacheMeta
--- @field configurations table<string, loomworks.CachedConfig> flat dict keyed by "project_key/config_key"
--- @field profiles? table<string, loomworks.CachedProfile>

--- Cache metadata.
--- @class loomworks.CacheMeta
--- @field version number
--- @field loomworks_hash string
--- @field cached_at string ISO 8601 timestamp

--- Cached profile entry in cache.json.
--- @class loomworks.CachedProfile
--- @field configuration_set? string nil for pinned profiles
--- @field mappings? table<string, string> project_key -> variant (stored for pinned, re-derived for set-based)
--- @field tools? table<string, { key: string, data?: table, label?: string }> tools dict keyed by module type
--- @field configurations? string[] array of cache keys ("project_key/config_key")

--- Cached configuration entry in cache.json.
--- Also the shape returned by ConfigUnit:serialize().
--- @class loomworks.CachedConfig
--- @field project_key string
--- @field config_key string
--- @field type string module type
--- @field state? loomworks.Status
--- @field variant? string
--- @field tool_key? string cache key suffix
--- @field tool_data? table opaque module-specific tool data
--- @field build_dir? string
--- @field last_configured? string ISO 8601 timestamp
--- @field last_built? string ISO 8601 timestamp
--- @field module_info? table opaque module-specific cached info (e.g. cmake generator/compiler)
--- Configuration snapshot (inline definition data for self-describing entries):
--- @field options? table user-defined options snapshot
--- @field module_config? table module-specific config data snapshot
--- @field is_user? boolean whether this was a user-defined configuration
--- @field inherits? string|string[] base configuration names

--- Cmake's per-configuration cached module_info shape (documented as example; core treats as opaque).
--- @class loomworks.CmakeCachedModuleInfo
--- @field generator? string cmake -G value used
--- @field compiler? string compiler identifier
--- @field multi_config? boolean
--- @field source_dir? string

-- ========================== Tool References ==========================

--- Bundled tool reference used in cache data and module contexts.
--- Domain objects use Tool object references instead; ToolRef is for serialization/matching.
--- @class loomworks.ToolRef
--- @field key? string cache key suffix (e.g. "ninja-gcc-12")
--- @field data? table opaque module-specific tool data
--- @field label? string display label (e.g. "Ninja + GCC 12")
--- @field mod_type? string which module type owns this tool (e.g. "cmake")

--- Detected tool from async tool scanning.
--- @class loomworks.DetectedTool
--- @field tool_data table opaque module-specific tool data
--- @field tool_key? string unique key for cache (nil for single-tool modules)
--- @field tool_label? string display label (nil for single-tool modules)

-- ========================== Merge Results ==========================

--- Result of merge.merge(): the resolved active configuration set.
--- @class loomworks.ActiveSet
--- @field name string|nil active profile key
--- @field tool_key? string cache key suffix from active profile
--- @field projects table<string, loomworks.MergedProjectData>

--- Profile definition from merge.get_all_profiles().
--- @class loomworks.ProfileDef
--- @field configuration_set? string nil for pinned profiles
--- @field tools? table<string, { key: string, data?: table, label?: string }>
--- @field _tool_objects? table<loomworks.Module, loomworks.Tool> pre-resolved tools
--- @field _config_set_ref? loomworks.ConfigurationSet pre-resolved reference

--- Tool entry for configuration sets UI.
--- @class loomworks.ToolEntry
--- @field profile_key string the profile key this tool would create
--- @field tool_key string
--- @field tool_data table
--- @field tool_label? string
--- @field tool_mod_type? string
--- @field cached boolean whether a materialized profile exists
--- @field profile? loomworks.Profile resolved profile object (if cached)

--- LSP config entry emitted by `module.lsp_configs(project)`.
--- Core only inspects `server` to route the entry to the right
--- integration; all other fields are server-specific and parsed by the
--- integration. Fields below are the common ones used by built-in
--- integrations — each integration documents its own additions.
--- @class loomworks.LspConfigEntry
--- @field server string                server name (e.g. "clangd")
--- @field root_dir? string             absolute project-root path for client scoping
--- @field binary? string               override server executable (env expansion supported)
--- @field binary_required? boolean     refuse to start when `binary` is missing — use when stock PATH server would be actively wrong
--- @field compile_commands_dir? string (clangd) directory containing compile_commands.json
--- @field build_dir? string            (qmlls) build directory passed via `-b` for QML import resolution
--- @field import_paths? string[]       (qmlls) extra QML import paths, each passed via `-I`

--- Merged project data from merge.merge().
--- @class loomworks.MergedProjectData
--- @field type string module type
--- @field path? string relative path
--- @field type_config? table module-specific configuration
--- @field configuration? string active configuration name
--- @field configuration_key? string cache key for active configuration
--- @field tool_key? string cache key suffix
--- @field tool_data? table opaque module-specific tool data
--- @field tool_label? string display label for the tool
--- @field tool_mod_type? string which module type owns this tool
--- @field status loomworks.Status
--- @field orphaned boolean
--- @field needs_refresh boolean
--- @field refresh_reasons string[]
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field cached? loomworks.CachedConfig active configuration's cached state
--- @field cached_configurations table<string, loomworks.CachedConfig>
--- @field module_info? table opaque module-specific project-level info
--- @field depends_on? string[]
--- @field launch? table<string, table>
--- @field deploy? table<string, table|table[]> project-level deploy steps

--- Configuration info from module.info().
--- @class loomworks.ConfigurationInfo
--- @field variant? string build variant (cmake CMAKE_BUILD_TYPE); for a preset, mined from cacheVariables.CMAKE_BUILD_TYPE
--- @field generator? string cmake -G value
--- @field binary_dir? string preset binaryDir
--- @field toolchain_locked? boolean
--- @field toolchain? string toolchain file path
--- @field from_preset? boolean derived from CMakePresets.json
--- @field role? string e.g. "compile_commands"

--- Cmake's project-level module_info shape (documented as an example; core treats it as opaque).
--- @class loomworks.CmakeProjectModuleInfo
--- @field compile_commands_from? string configuration to source compile_commands.json from
--- @field clangd? string project-level clangd binary override (supports ${ENV_VAR})

-- ========================== Module Interface ==========================

--- Context passed to module task generators.
--- @class loomworks.ModuleContext
--- @field name string project key
--- @field path string relative path from workspace root
--- @field type string module type
--- @field configuration string active configuration name
--- @field configuration_key string cache key
--- @field configurations table<string, loomworks.ConfigurationInfo> regular + preset configurations, keyed by canonical name (presets under `preset:<name>`)
--- @field tool_data? table opaque module-specific tool data
--- @field workspace_root string absolute path
--- @field env table<string, string>
--- @field cached_build_dir? string cached build directory, if known
--- @field type_config? table raw type_config from loomworks.json
--- @field resolved_variables? table<string, { value: string, type: string }> user-declared project variables resolved for the active configuration

--- Module info() return value.
--- @class loomworks.ModuleInfo
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field compile_commands_from? string
--- @field clangd? string

--- Module validation result.
--- @class loomworks.ModuleValidation
--- @field valid boolean
--- @field warnings string[]

--- Module inspection result.
--- @class loomworks.ModuleInspection
--- @field needs_refresh boolean
--- @field reasons string[]
--- @field notes string[]

-- ========================== Task Tracking ==========================

--- Result recorded after an overseer task completes.
--- @class loomworks.TaskResult
--- @field unit? loomworks.ConfigUnit the config unit that ran the task
--- @field project_key string
--- @field action string "configure" or "build"
--- @field configuration_key string
--- @field variant? string configuration variant name
--- @field tool? loomworks.ToolRef bundled tool reference
--- @field build_dir? string
--- @field module_info? table opaque module-specific info (e.g. cmake generator/compiler)
--- @field success boolean

--- Running task info for deletion conflict detection.
--- @class loomworks.RunningTaskInfo
--- @field project_key string
--- @field action string "configure" or "build"
--- @field configuration_key string

--- Snapshot of an active task for the status-page Tasks section.
--- @class loomworks.ActiveTaskInfo
--- @field task_id number overseer task id
--- @field project_key string
--- @field config_key string
--- @field action string "configure" or "build"
--- @field start_time number|nil clock seconds when the task was registered
--- @field progress { current: integer, total: integer, message: string|nil }|nil
--- @field build_dir string|nil resolved build directory (nil for tasks without one)

--- Snapshot of a build-dir lock entry for the status-page Tasks section.
--- @class loomworks.BuildDirLockInfo
--- @field dir string normalized build directory path
--- @field exclusive boolean
--- @field shared_count integer
--- @field queue_depth integer

-- ========================== Deletion ==========================

--- Plan for deleting a profile's cached configs.
--- @class loomworks.DeletionPlan
--- @field items loomworks.DeletionItem[]
--- @field profile? loomworks.Profile profile being deleted
--- @field defined_in_config boolean

--- Single item in a deletion plan.
--- @class loomworks.DeletionItem
--- @field unit? loomworks.ConfigUnit the config unit (nil for unmaterialized combos)
--- @field build_dir? string
--- @field disposition loomworks.DeletionDisposition "clean" removes entry, "reset" clears state, "keep" untouched

-- ========================== Orphaned Configs ==========================

--- Orphaned config returned by Workspace:get_orphaned_configs().
--- @class loomworks.OrphanedConfig
--- @field project_key string
--- @field config_key string
--- @field unit loomworks.ConfigUnit the config unit with state

-- ========================== UI Data ==========================

--- Buffer status info for statusline/LSP integration.
--- @class loomworks.BufStatus
--- @field profile_key? string full active profile key
--- @field set_name? string configuration set name
--- @field tool_key? string project-specific tool key
--- @field project string project key for the buffer
--- @field configuration? string active configuration name
--- @field status? loomworks.ConfigUnitState current state
--- @field profile_state? string icon-friendly aggregate over the active
---     profile's projects. One of: configuring, building, deleting,
---     failed_configure, failed_build, built, configured, unconfigured,
---     mixed. Nil when no active profile or no projects.
--- @field diagnostic_severity? "warn"|"error" highest severity active in
---     the workspace, nil when there are no diagnostics. Workspace-level
---     (not buffer-scoped) — same value for every buffer in the workspace.

--- Cached target info from module file-api parsing. Runtime-only.
--- @class loomworks.CachedTarget
--- @field type string "executable"|"static_library"|"shared_library" etc.
--- @field dependencies? string[] project-owned targets this links against
--- @field artifact? string primary output file path

-- ========================== Project Options ==========================

--- Option group in CMakeCache.
--- @class loomworks.OptionGroup
--- @field label string group display name
--- @field children (loomworks.OptionGroup | loomworks.Option)[]

--- Single option in CMakeCache.
--- @class loomworks.Option
--- @field key string variable name (e.g. "CORE3D_BUILD_ENGINE")
--- @field value string current value
--- @field value_type string "bool"|"string"|"path"|"filepath"
--- @field helpstring? string description from the build system
--- @field choices? string[] allowed values

-- ========================== Progress ==========================

--- Progress update from ninja/build output parsing.
--- @class loomworks.ProgressUpdate
--- @field current number
--- @field total number

-- ========================== Assembly ==========================

--- Result of workspace.assemble() — plain data, not a Workspace instance.
--- @class loomworks.WorkspaceData
--- @field root string
--- @field name string
--- @field config loomworks.Config
--- @field user loomworks.UserData
--- @field cache loomworks.CacheData
--- @field cache_version_mismatch boolean
--- @field cache_inconsistent boolean
--- @field user_version_mismatch boolean
--- @field user_projects_invalid string|nil structural error message, if any

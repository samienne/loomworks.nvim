--- loomworks/types.lua — LuaCATS type definitions for LSP support.
--- This file is never required at runtime. LuaLS picks up the annotations
--- automatically because it lives in the workspace.

--- @alias loomworks.Status
--- | "unconfigured"
--- | "configured"
--- | "built"
--- | "failed_configure"
--- | "failed_build"

-- ========================== Three-File Model ==========================

--- @class loomworks.Workspace
--- @field root string absolute path to workspace root
--- @field name string workspace display name
--- @field config loomworks.Config parsed loomworks.json
--- @field user loomworks.UserData user preferences (.nvim/loomworks.user.json)
--- @field cache loomworks.CacheData build state (.nvim/loomworks.cache.json)
--- @field cache_version_mismatch? boolean set during assembly, checked by Core.setup()

--- @class loomworks.Config
--- @field name? string workspace name override (falls back to dir name)
--- @field projects table<string, loomworks.ConfigProject>
--- @field configuration_sets? table<string, table<string, string>> set_name -> { project_key -> variant }
--- @field profiles? table<string, loomworks.ConfigProfileDef>

--- @class loomworks.ConfigProject
--- @field path string relative path from workspace root
--- @field type string module type ("cmake", "ets", "typescript")
--- @field type_config table module-specific configuration from loomworks.json
--- @field depends_on? string[]

--- @class loomworks.ConfigProfileDef
--- @field configuration_set string
--- @field cmake? table

--- @class loomworks.UserData
--- @field _meta { version: number }
--- @field active_profile? string

--- @class loomworks.CacheData
--- @field _meta loomworks.CacheMeta
--- @field profiles? table<string, loomworks.CachedProfile>
--- @field projects table<string, loomworks.CachedProject>

--- @class loomworks.CachedProfile
--- @field configuration_set? string nil for pinned profiles
--- @field mappings? table<string, string> project_key -> variant (stored for pinned, re-derived for set-based)
--- @field tool_key? string cache key suffix from the keyed module
--- @field tool_data? table opaque module-specific tool data
--- @field tool_label? string display label for the tool
--- @field tool_mod_type? string which module type owns this tool
--- @field projects table<string, loomworks.CachedProfileProject>

--- @class loomworks.CachedProfileProject
--- @field config_key string cache key reference into projects.<name>.configurations

--- @class loomworks.CacheMeta
--- @field version number
--- @field loomworks_hash string
--- @field cached_at string ISO 8601 timestamp

--- @class loomworks.CachedProject
--- @field type string module type
--- @field path? string relative path
--- @field configurations table<string, loomworks.CachedConfig>

--- @class loomworks.CachedConfig
--- @field state? loomworks.Status
--- @field variant? string
--- @field tool_key? string cache key suffix
--- @field tool_data? table opaque module-specific tool data
--- @field build_dir? string
--- @field last_configured? string ISO 8601 timestamp
--- @field last_built? string ISO 8601 timestamp
--- @field cmake? loomworks.CachedCmakeInfo

--- @class loomworks.CachedCmakeInfo
--- @field generator? string cmake -G value used
--- @field compiler? string compiler identifier
--- @field multi_config? boolean
--- @field source_dir? string
--- @field targets? table<string, loomworks.CachedTarget>

--- @class loomworks.CachedTarget
--- @field type string target type ("executable", "library", etc.)
--- @field built? boolean
--- @field last_built? string ISO 8601 timestamp

-- ========================== Detected Tools ==========================

--- @class loomworks.DetectedTool
--- @field tool_data table opaque module-specific tool data
--- @field tool_key? string unique key for cache (nil for single-tool modules)
--- @field tool_label? string display label (nil for single-tool modules)

--- @class loomworks.BufStatus
--- @field profile_key? string full active profile key (e.g. "debug:ninja-gcc-12")
--- @field set_name? string configuration set name parsed from profile key
--- @field tool_key? string project-specific tool key (e.g. "ninja-gcc-12" for cmake)
--- @field project string project key for the buffer
--- @field configuration? string active configuration name (e.g. "Debug")
--- @field status? loomworks.ConfigUnitState current ConfigUnit state

-- ========================== Merge Result ==========================

--- @class loomworks.ActiveSet
--- @field name string|nil active profile key
--- @field profile loomworks.ProfileDef|nil raw profile definition
--- @field all_profiles table<string, loomworks.ProfileDef>
--- @field tool_key? string cache key suffix from active profile
--- @field tool_data? table opaque tool data from active profile
--- @field tool_label? string display label from active profile
--- @field tool_mod_type? string module type owning the active tool
--- @field projects table<string, loomworks.MergedProjectData>
--- @field configuration_sets? table<string, table<string, string>>

--- @class loomworks.ProfileDef
--- @field configuration_set? string nil for pinned profiles
--- @field mappings? table<string, string> project_key -> variant (stored for pinned, re-derived for set-based)
--- @field tool_key? string cache key suffix from the keyed module
--- @field tool_data? table opaque module-specific tool data
--- @field tool_label? string display label for the tool
--- @field tool_mod_type? string which module type owns this tool
--- @field explicit? boolean
--- @field _removed? boolean true after profile removed from registry

--- @class loomworks.ToolEntry
--- @field profile_key string the profile key this tool would create
--- @field tool_key string
--- @field tool_data table
--- @field tool_label? string
--- @field tool_mod_type? string
--- @field cached boolean whether a materialized profile exists

--- @class loomworks.MergedProjectData
--- @field type string module type
--- @field path? string relative path
--- @field configuration? string active configuration name
--- @field configuration_key? string cache key for active configuration
--- @field tool_key? string cache key suffix
--- @field tool_data? table opaque module-specific tool data
--- @field status loomworks.Status
--- @field orphaned boolean
--- @field needs_refresh boolean
--- @field refresh_reasons string[]
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field cached? loomworks.CachedConfig active configuration's cached state
--- @field cached_configurations table<string, loomworks.CachedConfig>
--- @field cmake? loomworks.ProjectCmakeInfo

--- @class loomworks.ConfigurationInfo
--- @field generator? string cmake -G value
--- @field binary_dir? string preset binaryDir
--- @field toolchain_locked? boolean
--- @field toolchain? string toolchain file path
--- @field from_preset? boolean derived from CMakePresets.json
--- @field role? string e.g. "compile_commands"

--- @class loomworks.ProjectCmakeInfo
--- @field compile_commands_from? string configuration to source compile_commands.json from
--- @field clangd? string project-level clangd binary override (from loomworks.json, supports ${ENV_VAR})
--- @field targets? table<string, loomworks.CachedTarget>

-- ========================== Module Interface ==========================

--- @class loomworks.ModuleContext
--- @field name string project key
--- @field path string relative path from workspace root
--- @field type string module type
--- @field configuration string active configuration name
--- @field configuration_key string cache key
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field tool_data? table opaque module-specific tool data
--- @field workspace_root string absolute path
--- @field env table<string, string>

--- @class loomworks.ModuleInfo
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field compile_commands_from? string
--- @field clangd? string

--- @class loomworks.ModuleValidation
--- @field valid boolean
--- @field warnings string[]

--- @class loomworks.ModuleInspection
--- @field needs_refresh boolean
--- @field reasons string[]
--- @field notes string[]

-- ========================== Task Tracking ==========================

--- @class loomworks.TaskResult
--- @field project_key string
--- @field action string "configure" or "build"
--- @field configuration_key string
--- @field build_dir? string
--- @field tool_data? table opaque tool data to store in cache
--- @field cmake? loomworks.CachedCmakeInfo
--- @field success boolean

--- @class loomworks.RunningTaskInfo
--- @field project_key string
--- @field action string "configure" or "build"
--- @field configuration_key string

-- ========================== Deletion ==========================

--- @class loomworks.DeletionPlan
--- @field items loomworks.DeletionItem[]
--- @field profile_key? string profile being deleted
--- @field project_key? string single config deletion target
--- @field config_key? string single config deletion target
--- @field defined_in_config boolean

--- @alias loomworks.DeletionDisposition "clean"|"reset"|"keep"

--- @class loomworks.DeletionItem
--- @field project_key string
--- @field config_key string
--- @field build_dir? string
--- @field disposition loomworks.DeletionDisposition "clean" removes entry, "reset" clears state (keeps skeleton), "keep" untouched

-- ========================== File Tracking ==========================

--- @class loomworks.Operation
--- @field action? string "configure", "build", or "configure+build" (while running)
--- @field started_at? number hrtime seconds (while running)
--- @field message? string result message like "built in 2m10s" (after completion)
--- @field success? boolean (after completion)

--- @class loomworks.FileTrackerOpts
--- @field callback fun(path: string, content: string|nil)
--- @field interval? number poll interval in ms (default 2000)
--- @field read_file? fun(path: string): string|nil, string|nil
--- @field schedule? fun(fn: function)

-- ========================== Progress ==========================

--- @class loomworks.ProgressUpdate
--- @field current number
--- @field total number

-- ========================== ConfigUnit ==========================

--- @alias loomworks.ConfigUnitState
--- | "unconfigured"
--- | "configuring"
--- | "configured"
--- | "building"
--- | "built"
--- | "configure_failed"
--- | "build_failed"
--- | "deleting"

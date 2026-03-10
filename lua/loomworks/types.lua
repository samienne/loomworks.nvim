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
--- @field projects table<string, loomworks.CachedProject>

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
--- @field kit_id? string
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

-- ========================== Merge Result ==========================

--- @class loomworks.ActiveSet
--- @field name string|nil active profile key
--- @field profile loomworks.ProfileDef|nil raw profile definition
--- @field all_profiles table<string, loomworks.ProfileDef>
--- @field kit loomworks.CmakeKit|nil resolved kit for active profile
--- @field kit_id string|nil
--- @field projects table<string, loomworks.MergedProjectData>
--- @field configuration_sets? table<string, table<string, string>>
--- @field detected_kits loomworks.CmakeKit[]

--- @class loomworks.ProfileDef
--- @field configuration_set string
--- @field kit_id? string
--- @field cmake? table
--- @field auto_generated? boolean
--- @field explicit? boolean

--- @class loomworks.MergedProjectData
--- @field type string module type
--- @field path? string relative path
--- @field configuration? string active configuration name
--- @field configuration_key? string cache key for active configuration
--- @field kit_id? string
--- @field kit? loomworks.CmakeKit
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
--- @field targets? table<string, loomworks.CachedTarget>

-- ========================== Module Interface ==========================

--- @class loomworks.ModuleContext
--- @field name string project key
--- @field path string relative path from workspace root
--- @field type string module type
--- @field configuration string active configuration name
--- @field configuration_key string cache key
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field kit? loomworks.CmakeKit
--- @field workspace_root string absolute path
--- @field env table<string, string>

--- @class loomworks.ModuleInfo
--- @field configurations table<string, loomworks.ConfigurationInfo>
--- @field compile_commands_from? string

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
--- @field cmake? loomworks.CachedCmakeInfo
--- @field success boolean

--- @class loomworks.RunningTaskInfo
--- @field project_key string
--- @field action string "configure" or "build"
--- @field configuration_key string

-- ========================== Deletion ==========================

--- @class loomworks.DeletionPlan
--- @field items loomworks.DeletionItem[]
--- @field profile_key? string
--- @field project_key? string
--- @field config_key? string
--- @field defined_in_config boolean

--- @class loomworks.DeletionItem
--- @field project_key string
--- @field config_key string
--- @field build_dir? string
--- @field shared_by? string[] profile keys sharing this config
--- @field affected_profiles? string[] profiles affected by deletion

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

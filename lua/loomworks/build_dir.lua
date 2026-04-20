--- loomworks/build_dir.lua — BuildDir: cached build artifacts for a directory.
--- Represents a physical build directory with its state on disk.
--- Separate from ConfigUnit (user intent) — a ConfigUnit references a BuildDir.
--- Orphaned BuildDirs have state but no ConfigUnit pointing to them.

--- @class loomworks.BuildDir
--- @field rel_path string relative build dir path (cache key, e.g., "build/App/Debug")
--- @field path string absolute build directory path
--- @field state string|nil "configured" | "built" | "failed_configure" | "failed_build" | "unknown"
--- @field last_configured string|nil ISO 8601 timestamp
--- @field last_built string|nil ISO 8601 timestamp
--- @field module_info table|nil opaque module-specific cached data (e.g. cmake generator/compiler)
--- Snapshots at time of last configure (for stale detection):
--- @field options_snapshot table|nil configuration options when last configured
--- @field module_config_snapshot table|nil module_config when last configured
--- @field tool_snapshot table|nil { key, data } of tool when last configured
--- For serialization / orphan display:
--- @field project_key string|nil
--- @field variant string|nil variant name when last configured
--- @field config_key string|nil opaque cache key for display
--- @field mod_type string|nil module type (e.g., "cmake")
--- Lifecycle:
--- @field _removed boolean
local BuildDir = {}
BuildDir.__index = BuildDir

--- Create a new BuildDir from cache data.
--- @param rel_path string relative build dir path (cache key)
--- @param abs_path string absolute build directory path
--- @param cached? table raw cache entry data
--- @return loomworks.BuildDir
function BuildDir.new(rel_path, abs_path, cached)
    local self = setmetatable({}, BuildDir)
    self.rel_path = rel_path
    self.path = abs_path
    self._removed = false
    if cached then
        self.state = cached.state
        self.last_configured = cached.last_configured
        self.last_built = cached.last_built
        self.module_info = cached.module_info
        self.options_snapshot = cached.options
        self.module_config_snapshot = cached.module_config
        self.tool_snapshot = cached.tool_key and { key = cached.tool_key, data = cached.tool_data } or nil
        self.project_key = cached.project_key
        self.variant = cached.variant
        self.config_key = cached.config_key
        self.mod_type = cached.type
    else
        self.state = nil
        self.last_configured = nil
        self.last_built = nil
        self.module_info = nil
        self.options_snapshot = nil
        self.module_config_snapshot = nil
        self.tool_snapshot = nil
        self.project_key = nil
        self.variant = nil
        self.config_key = nil
        self.mod_type = nil
    end
    return self
end

--- Serialize this BuildDir to a cache entry for persistence.
--- @return table cache entry suitable for cache.build_dirs[rel_path]
function BuildDir:serialize()
    local entry = {
        project_key = self.project_key,
        config_key = self.config_key,
        type = self.mod_type,
        variant = self.variant,
        build_dir = self.path,
        state = self.state,
        last_configured = self.last_configured,
        last_built = self.last_built,
    }
    if self.tool_snapshot then
        entry.tool_key = self.tool_snapshot.key
        entry.tool_data = self.tool_snapshot.data
    end
    if self.module_info then entry.module_info = self.module_info end
    if self.options_snapshot then entry.options = self.options_snapshot end
    if self.module_config_snapshot then entry.module_config = self.module_config_snapshot end
    return entry
end

--- Check if this BuildDir has actual build state worth preserving.
--- @return boolean
function BuildDir:has_state()
    return self.state ~= nil and self.state ~= "unconfigured"
end

--- Update metadata after a successful configure/build.
--- Called by task_tracker when a task completes.
--- @param data { state?: string, last_configured?: string, last_built?: string, module_info?: table, options?: table, module_config?: table, tool?: table, project_key?: string, variant?: string, config_key?: string, mod_type?: string }
function BuildDir:update(data)
    if data.state then self.state = data.state end
    if data.last_configured then self.last_configured = data.last_configured end
    if data.last_built then self.last_built = data.last_built end
    if data.module_info then self.module_info = data.module_info end
    if data.options then self.options_snapshot = data.options end
    if data.module_config then self.module_config_snapshot = data.module_config end
    if data.tool then self.tool_snapshot = data.tool end
    if data.project_key then self.project_key = data.project_key end
    if data.variant then self.variant = data.variant end
    if data.config_key then self.config_key = data.config_key end
    if data.mod_type then self.mod_type = data.mod_type end
end

--- Clear build state (for delete/reset operations).
function BuildDir:clear_state()
    self.state = nil
    self.last_configured = nil
    self.last_built = nil
    self.module_info = nil
    self.options_snapshot = nil
    self.module_config_snapshot = nil
end

function BuildDir:__tostring()
    local status = self.state or "unconfigured"
    return "BuildDir(" .. self.rel_path .. ", " .. status .. ")"
end

return BuildDir

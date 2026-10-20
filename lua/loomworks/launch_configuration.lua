--- loomworks/launch_configuration.lua — LaunchConfiguration domain object
--- (spec §1.2.1). A named way to run something of a project (§8.7), declared
--- under the project's `"launch"` (name → table) and merged per name (§2.4).
--- Owned by `Project._launches` (name → object); identity-preserving across
--- refreshes (matched by name within the project) and across a rename.

local description_mod = require("loomworks.description")

--- @class loomworks.LaunchConfiguration
--- @field name string the launch name, unique within its project
--- @field _project loomworks.Project back-reference to the owning project
--- @field description string|nil normalised description (spec §1.10); the
---        declared value stays in the declaration, so the files keep it as written
--- @field _decl any the declared value as written in the files (normally a
---        table: target or command, args, working_dir, env, debug, deploy,
---        device_log, description, and any field this version does not know);
---        it is the object's data and serializes back unchanged
--- @field _removed boolean true once its declaration is gone (removed,
---        or dropped by a refresh)
local LaunchConfiguration = {}
LaunchConfiguration.__index = LaunchConfiguration

--- Create a LaunchConfiguration.
--- @param project loomworks.Project
--- @param name string
--- @param data any the declared value
--- @return loomworks.LaunchConfiguration
function LaunchConfiguration.new(project, name, data)
    local self = setmetatable({}, LaunchConfiguration)
    self._project = project
    self.name = name
    self._removed = false
    self:_apply(data)
    return self
end

--- Update the declared data in place (identity kept). Never touches the
--- runtime fields (`_project`, `name`, `_removed`).
--- @param data any the declared value
--- @param _ctx any unused (no references to resolve)
--- @return boolean
function LaunchConfiguration:_apply(data, _ctx)
    self._decl = data
    self.description = type(data) == "table" and description_mod.normalize(data.description) or nil
    return true
end

--- The declared value (the table callers read target / command / args /
--- working_dir / env / debug / deploy / device_log from). Not a copy.
--- @return any
function LaunchConfiguration:declaration()
    return self._decl
end

--- The declared value as written to the files (same shape as read).
--- @return any
function LaunchConfiguration:serialize()
    return self._decl
end

--- Set or clear the description (spec §1.10, §8.7): the `description` key of
--- the declaration, normalised; an empty text removes it. Implicit cascade on
--- use (the project is materialised in the working copy).
--- @param text string|nil
--- @return boolean|nil changed true when saved, false when unchanged, nil on refusal
--- @return string|nil err
function LaunchConfiguration:set_description(text)
    local project = self._project
    if self._removed or type(self._decl) ~= "table" then
        return nil, "no launch config '" .. tostring(self.name) .. "' on project '"
            .. tostring(project and project.key) .. "'"
    end
    local ok, value, err = description_mod.prepare(text)
    if not ok then return nil, err end
    local cfg = self._decl
    if value == cfg.description then return false end
    local ws = project._workspace
    local old = cfg.description
    local old_intent, old_source = project._intent, project._source
    project:_mark_user_owned()
    cfg.description = value
    self.description = description_mod.normalize(value)
    local saved, save_err = ws:_save_user()
    if not saved then
        cfg.description = old
        self.description = description_mod.normalize(old)
        project._intent, project._source = old_intent, old_source
        return nil, save_err
    end
    ws._core._deps.events.emit("active_set_changed", ws._active_set)
    return true
end

function LaunchConfiguration:__tostring()
    return "LaunchConfiguration(" .. tostring(self._project and self._project.key)
        .. ":" .. tostring(self.name) .. ")"
end

return LaunchConfiguration

--- loomworks/launch_configuration.lua — LaunchConfiguration domain object
--- (spec §1.2.1). A named way to run something of a project (§8.7), declared
--- under the project's `"launch"` (name → table) and merged per name (§2.4).
--- Owned by `Project._launches` (name → object); identity-preserving across
--- refreshes (matched by name within the project) and across a rename.
---
--- Every declared field is a field of the object; `serialize()` rebuilds the
--- declared table from them, so the files keep their shape. A key this
--- version does not know is kept, opaque, in `_extra` and written back as is.

local description_mod = require("loomworks.description")

--- The declared fields this version knows (spec §8.7, §18.9). Any other key
--- of a declaration goes to `_extra`.
local FIELDS = { "target", "command", "args", "working_dir", "env", "debug",
    "deploy", "device", "device_log" }
local KNOWN = { description = true }
for _, k in ipairs(FIELDS) do KNOWN[k] = true end

--- @class loomworks.LaunchConfiguration
--- @field name string the launch name, unique within its project
--- @field _project loomworks.Project back-reference to the owning project
--- @field target any the build target it runs (a target-backed launch), as declared
--- @field command any the command it runs (a command-type launch), as declared
--- @field args any the arguments (normally a string array), as declared
--- @field working_dir any the working directory template, as declared
--- @field env any environment overrides (name → value), as declared
--- @field debug any debug languages (first = primary), as declared
--- @field deploy any launch-level deploy steps (destination → source(s)), as declared
--- @field device any the remote-execution block (spec §18.9), as declared
--- @field device_log any device log settings, as declared
--- @field description string|nil normalised description (spec §1.10)
--- @field _description_invalid any a non-string `description` value, ignored
---        but written back unchanged until the description is set or cleared
--- @field _extra table|nil keys this version does not know (key → value),
---        opaque, written back unchanged
--- @field _invalid any a declaration that is not a table, written back
---        unchanged; such a launch has no fields and runs nothing
--- @field _removed boolean true once its declaration is gone (removed,
---        or dropped by a refresh), or its project is removed
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
    local is_table = type(data) == "table"
    for _, k in ipairs(FIELDS) do
        self[k] = is_table and data[k] or nil
    end
    self._invalid = (not is_table) and data or nil
    if is_table then
        self.description, self._description_invalid = description_mod.from_file(data.description)
    else
        self.description, self._description_invalid = nil, nil
    end
    local extra = nil
    if is_table then
        for k, v in pairs(data) do
            if not KNOWN[k] then
                extra = extra or {}
                extra[k] = v
            end
        end
    end
    self._extra = extra
    return true
end

--- The declared table as written to the files (same shape as read), built
--- from the fields: a fresh table (its nested values are the fields' own).
--- @return any
function LaunchConfiguration:serialize()
    if self._invalid ~= nil then return self._invalid end
    local out = {}
    for k, v in pairs(self._extra or {}) do out[k] = v end
    for _, k in ipairs(FIELDS) do out[k] = self[k] end
    if self.description ~= nil then
        out.description = self.description
    elseif self._description_invalid ~= nil then
        out.description = self._description_invalid
    end
    return out
end

--- Whether the declaration is not a table (kept, but it runs nothing).
--- @return boolean
function LaunchConfiguration:is_invalid()
    return self._invalid ~= nil
end

--- Whether it runs something: a command or a build target.
--- @return boolean
function LaunchConfiguration:is_runnable()
    return (self.command ~= nil or self.target ~= nil) and true or false
end

--- Whether it or its project has been removed (mutators refuse then).
--- @return boolean
function LaunchConfiguration:is_removed()
    return self._removed or (self._project ~= nil and self._project._removed) or false
end

--- Set or clear the description (spec §1.10, §8.7), normalised; an empty
--- text removes it. Implicit cascade on use (the project is materialised in
--- the working copy).
--- @param text string|nil
--- @return boolean|nil changed true when saved, false when unchanged, nil on refusal
--- @return string|nil err
function LaunchConfiguration:set_description(text)
    local project = self._project
    if self:is_removed() or self:is_invalid() then
        return nil, "no launch config '" .. tostring(self.name) .. "' on project '"
            .. tostring(project and project.key) .. "'"
    end
    local ok, value, err = description_mod.prepare(text)
    if not ok then return nil, err end
    if value == self.description and self._description_invalid == nil then return false end
    local ws = project._workspace
    local old, old_invalid = self.description, self._description_invalid
    local old_intent, old_source = project._intent, project._source
    project:_mark_user_owned()
    self.description, self._description_invalid = value, nil
    local saved, save_err = ws:_save_user()
    if not saved then
        self.description, self._description_invalid = old, old_invalid
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

--- loomworks/test_units/saved_targets.lua — core-owned SavedTargetsTestUnit
--- (spec §1.3.4, §8.9.1–§8.9.2).
---
--- Serves a configuration's saved test targets through generic seams only:
--- the module's `parse_targets` (executable targets and their artifacts,
--- via `ConfigUnit:ensure_targets`), `Target:resolve_run_spec` (run
--- environment), and the shared gtest helper. Knows no module's internals and
--- is never a batch runner (`run_command_all` is nil): a headless run executes
--- saved targets on the per-executable route (§16.16).
---
--- Entries: one `target:<name>` per saved entry in list order (`executable` =
--- the artifact, runnable), with gtest children when the framework is
--- recognised. A missing entry (no such target, or not an executable) is a
--- non-runnable `target:<name>` with `status = "errored"` and a message naming
--- the entry and its declaring level — shown, never hidden.

local TestUnit = require("loomworks.test_unit")
local gtest = require("loomworks.gtest")
local test_targets = require("loomworks.test_targets")

local uv = vim.uv or vim.loop

--- @class loomworks.SavedTargetsTestUnit : loomworks.TestUnit
--- @field is_saved_targets boolean always true (core's saved-targets TestUnit)
--- @field _targets_by_id table<string, loomworks.Target> resolved targets of the last discovery, by entry id
--- @field _args_by_id table<string, string[]> the saved entry's args, by target entry id
local SavedTargetsTestUnit = setmetatable({}, { __index = TestUnit })
SavedTargetsTestUnit.__index = SavedTargetsTestUnit

--- @param config_unit loomworks.ConfigUnit
--- @return loomworks.SavedTargetsTestUnit
function SavedTargetsTestUnit.new(config_unit)
    local self = setmetatable({}, SavedTargetsTestUnit)
    self._config_unit = config_unit
    self.is_saved_targets = true
    self._entries = nil
    self._framework_cache = {}
    self._targets_by_id = {}
    self._args_by_id = {}
    return self
end

--- The run spec (artifact, cwd, env) of a resolved target, with the
--- configuration environment underneath the target's run environment.
--- @param target loomworks.Target
--- @return table|nil spec, string|nil err
function SavedTargetsTestUnit:_run_spec(target)
    local spec, err = target:resolve_run_spec()
    if not spec then return nil, err end
    local env = {}
    local unit = self._config_unit
    if unit and type(unit.configuration_env) == "function" then
        local ok, cenv = pcall(unit.configuration_env, unit)
        if ok and type(cenv) == "table" then
            for k, v in pairs(cenv) do env[k] = v end
        end
    end
    for k, v in pairs(spec.env or {}) do env[k] = v end
    spec.env = next(env) and env or nil
    return spec
end

--- Resolve the saved list to top-level entries (no probing).
--- @return table[] entries, table[] runnable top-level entries
function SavedTargetsTestUnit:_resolve_entries()
    local unit = self._config_unit
    local saved = unit:saved_test_targets()
    local entries, runnable = {}, {}
    self._targets_by_id, self._args_by_id = {}, {}
    if not saved then return entries, runnable end
    local targets = unit:ensure_targets()
    local level = test_targets.level_label(saved.source)
    for _, se in ipairs(saved.entries) do
        local id = "target:" .. se.target
        local state, target = test_targets.resolve(targets, se.target)
        if state == "ok" then
            local spec = self:_run_spec(target)
            local e = {
                id = id, name = se.target, parent = nil, runnable = true,
                framework = nil, executable = spec and spec.cmd or nil,
                args = se.args, saved = true,
            }
            self._targets_by_id[id] = target
            self._args_by_id[id] = se.args
            entries[#entries + 1] = e
            if e.executable then runnable[#runnable + 1] = e end
        else
            local msg = state == "not executable"
                and ("not an executable target of " .. level)
                or ("not a target of " .. level .. " (removed or renamed?)")
            if state == "unknown" then
                msg = "targets of " .. level .. " are unknown (configure first)"
            end
            entries[#entries + 1] = {
                id = id, name = se.target, parent = nil, runnable = false,
                status = "errored", message = msg, saved = true,
            }
        end
    end
    return entries, runnable
end

--- Attach gtest children (with source locations) for a probed target entry.
local function add_children(self, entries, e, framework, list)
    self._framework_cache[e.executable] = framework or false
    if framework and list then
        e.framework = framework
        for _, t in ipairs(list) do entries[#entries + 1] = t end
        local target = self._targets_by_id[e.id]
        if target and target.sources and #target.sources > 0 then
            gtest.find_source_locations(list, target.sources)
        end
    end
end

--- @return table[]|nil
function SavedTargetsTestUnit:discover()
    if self._entries then return self._entries end
    local entries, runnable = self:_resolve_entries()
    for _, e in ipairs(runnable) do
        local cached = self._framework_cache[e.executable]
        if cached == nil then
            if uv.fs_stat(e.executable) then
                local fw, list = gtest.probe_sync(e.executable, e.id)
                add_children(self, entries, e, fw, list)
            end
        elseif cached then
            e.framework = cached
        end
    end
    if #entries == 0 then return nil end
    self._entries = entries
    return entries
end

--- @param callback fun(entries: table[]|nil)
function SavedTargetsTestUnit:discover_async(callback)
    if self._entries then callback(self._entries); return end
    local entries, runnable = self:_resolve_entries()
    local todo = {}
    for _, e in ipairs(runnable) do
        local cached = self._framework_cache[e.executable]
        if cached == nil and uv.fs_stat(e.executable) then
            todo[#todo + 1] = e
        elseif cached then
            e.framework = cached
        end
    end
    local function done()
        if #entries == 0 then callback(nil); return end
        self._entries = entries
        callback(entries)
    end
    if #todo == 0 then done(); return end
    local pending = #todo
    for _, e in ipairs(todo) do
        gtest.probe(e.executable, e.id, function(fw, list)
            add_children(self, entries, e, fw, list)
            pending = pending - 1
            if pending == 0 then done() end
        end)
    end
end

--- The entry for an id in the last discovery.
function SavedTargetsTestUnit:_entry(id)
    for _, e in ipairs(self._entries or {}) do
        if e.id == id then return e end
    end
    return nil
end

--- Target-, suite- or case-level command: the run spec from
--- `Target:resolve_run_spec`, the framework results option, the entry's
--- `args`, the framework filter (GTEST_FILTER, as the module runners do).
--- @param test_id string
--- @param opts? { gtest_filter?: string }
--- @return table|nil { cmd, env, cwd, output_path }
function SavedTargetsTestUnit:test_command(test_id, opts)
    opts = opts or {}
    local e = self:_entry(test_id)
    if not e then return nil end
    local top = e.parent and self:_entry(e.parent) or e
    if not top or not top.runnable then return nil end
    local target = self._targets_by_id[top.id]
    if not target then return nil end
    local spec = self:_run_spec(target)
    if not spec then return nil end
    local cmd = { spec.cmd }
    local env = spec.env and vim.deepcopy(spec.env) or {}
    local output_path
    if top.framework == "gtest" then
        local build_dir = self._config_unit:build_dir()
        local dir = (build_dir or uv.os_tmpdir():gsub("\\", "/")) .. "/.nvim"
        if not uv.fs_stat(dir) then uv.fs_mkdir(dir, 493) end
        output_path = dir .. "/saved_" .. (top.name:gsub("[^%w%._%-]", "_")) .. "_results.xml"
        cmd[#cmd + 1] = "--gtest_output=xml:" .. output_path
        if e.parent then
            env.GTEST_FILTER = opts.gtest_filter or (test_id:match("^test:(.+)$") or test_id)
        elseif opts.gtest_filter then
            env.GTEST_FILTER = opts.gtest_filter
        end
    end
    for _, a in ipairs(self._args_by_id[top.id] or {}) do cmd[#cmd + 1] = a end
    return { cmd = cmd, env = next(env) and env or nil, cwd = spec.cwd, output_path = output_path }
end

--- nil — run-all iterates the target entries (spec §8.9.4).
function SavedTargetsTestUnit:test_command_all(_) return nil end

--- nil — never a batch runner (spec §8.9.2).
function SavedTargetsTestUnit:run_command_all(_) return nil end

--- @param output_path string
--- @return table[]|nil
function SavedTargetsTestUnit:parse_results(output_path)
    return gtest.parse_xml_results(output_path)
end

function SavedTargetsTestUnit:invalidate()
    self._entries = nil
    self._framework_cache = {}
end

return SavedTargetsTestUnit

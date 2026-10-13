--- loomworks/test_units/saved_targets.lua — core-owned SavedTargetsTestUnit
--- (spec §1.3.4, §8.9.1–§8.9.2).
---
--- Serves a configuration's saved test entries through generic seams only:
--- the module's `parse_targets` (executable targets and their artifacts,
--- via `ConfigUnit:ensure_targets`), `Target:resolve_run_spec` (run
--- environment), a launch configuration's resolved run spec and deploy steps
--- (through `LaunchTarget`, the same code path `lw run <name>` uses), and the
--- shared gtest helper. Knows no module's internals and is never a batch
--- runner (`run_command_all` is nil): a headless run executes saved entries
--- on the per-executable route (§16.16).
---
--- Entries: one `<kind>:<name>` per saved entry in list order (`#<k>` for the
--- k-th occurrence, k ≥ 2, of a repeated name), `executable` = the program,
--- runnable. A build target's artifact (a `target` entry or a target-backed
--- `launch` entry) is probed for gtest and gets per-test children; any other
--- entry is judged on its exit status. A missing entry is a non-runnable entry
--- with `status = "errored"` and a message naming the entry and its declaring
--- level — shown, never hidden. Each entry runs in its `working_dir`
--- (expanded in its launch context, where `${target_dir}` is its build
--- target's artifact directory), else a launch entry in the launch's, else
--- the project directory (§1.3.4 "Working directory").

local TestUnit = require("loomworks.test_unit")
local gtest = require("loomworks.gtest")
local test_targets = require("loomworks.test_targets")

local uv = vim.uv or vim.loop

--- @class loomworks.SavedTargetsTestUnit : loomworks.TestUnit
--- @field is_saved_targets boolean always true (core's saved-targets TestUnit)
--- @field _top_by_id table<string, { entry: loomworks.SavedTestEntry, kind: "launch"|"target", target: loomworks.Target|nil, launch_target: loomworks.LaunchTarget|nil, args: string[], cwd: string|nil, lctx: table<string, string>|nil }> resolved top-level entries of the last discovery, by entry id (`cwd` = the entry's resolved working_dir; `lctx` = its launch context, only while discovery expands its args — cleared before it is stored)
--- @field _suffix_by_output table<string, string> child-id suffix by results file (repeated / launch entries)
--- A discovered tree entry of this TestUnit (beside the generic TestEntry
--- fields: id, name, parent, runnable, executable, args, status, message).
--- @class loomworks.SavedTestTreeEntry
--- @field saved true marks an entry of the saved-targets TestUnit
--- @field saved_kind "launch"|"target"|nil what the saved name resolved to (nil when unresolved)
--- @field saved_index integer|nil occurrence of the name in the list (1 = first; `#<k>` ids from 2)
--- @field saved_repeated boolean|nil the name occurs more than once in the list
--- @field saved_working_dir true|nil the entry declares its own `working_dir` (never merged into a module entry)
--- @field saved_args string[]|nil set on a module entry that a once-listed saved `target` entry merged into: the saved entry's args (ConfigUnit._merge_test_entries)

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
    self._top_by_id = {}
    self._suffix_by_output = {}
    return self
end

--- The profile this unit runs in: the active profile when it maps the unit,
--- else the first profile that does.
--- @return loomworks.Profile|nil
function SavedTargetsTestUnit:_profile()
    local unit = self._config_unit
    local ws = unit and unit._workspace
    local key = unit._project and unit._project.key
    local function maps(p)
        local pp = p and key and p.project and p:project(key)
        return pp and pp._config_unit == unit
    end
    local active = unit.context_profile and unit:context_profile() or nil
    if maps(active) then return active end
    for _, p in pairs(ws and ws._profiles or {}) do
        if maps(p) then return p end
    end
    return active
end

--- The run spec (artifact, cwd, env) of a resolved build target, with the
--- configuration environment underneath the target's run environment.
--- @param target loomworks.Target
--- @param cwd string|nil absolute working directory (nil: the project directory)
--- @return table|nil spec, string|nil err
function SavedTargetsTestUnit:_run_spec(target, cwd)
    local spec, err = target:resolve_run_spec(cwd and { working_dir = cwd } or nil)
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

--- The program, launch args, cwd and env of a resolved top-level entry. The
--- entry's own working directory (`top.cwd`) replaces the program's.
--- @param top table resolved top-level entry (`_top_by_id` value)
--- @return { cmd: string, args: string[], cwd: string|nil, env: table|nil }|nil spec, string|nil err
function SavedTargetsTestUnit:_program(top)
    if top.kind == "launch" then
        local spec, err = top.launch_target:resolve_launch_spec({})
        if not spec then return nil, err end
        return { cmd = spec.cmd, args = spec.args or {}, cwd = top.cwd or spec.cwd, env = spec.env }
    end
    local spec, err = self:_run_spec(top.target, top.cwd)
    if not spec then return nil, err end
    return { cmd = spec.cmd, args = {}, cwd = spec.cwd, env = spec.env }
end

--- Resolve the saved list to top-level entries (no probing).
--- @return table[] entries, table[] probe top-level entries whose program is a build artifact
function SavedTargetsTestUnit:_resolve_entries()
    local unit = self._config_unit
    local saved = unit:saved_test_targets()
    local entries, probe = {}, {}
    self._top_by_id = {}
    if not saved then return entries, probe end
    local project = unit._project
    local ws = unit._workspace
    local level = test_targets.level_label(saved.source)
    if saved.invalid then
        entries[1] = {
            id = "target:<invalid tests>", name = "tests", parent = nil, runnable = false,
            status = "errored", saved = true, source = "saved",
            message = "`tests` of " .. level .. " is not an array of saved test entries",
        }
        return entries, probe
    end
    local targets = unit:ensure_targets()
    local profile = self:_profile()
    local expand = require("loomworks.expand")
    local rctx = {
        launches = project and project.launch or nil,
        launch_ignored = function(n)
            return test_targets.launch_ignored(ws and ws._shared_ignored, project, n)
        end,
        targets = targets, level = level,
    }
    for _, se in ipairs(saved.entries) do
        local r = test_targets.resolve_entry(se, rctx)
        local id = test_targets.entry_id(se, r.kind)
        local label = test_targets.entry_label(se)
        local base = {
            id = id, name = label, parent = nil, saved = true, source = "saved",
            saved_kind = r.kind, saved_index = se.index, saved_repeated = se.repeated,
            saved_working_dir = se.working_dir ~= nil or nil,
        }
        local program, perr
        local top
        if r.state == "ok" and profile then
            -- Args and working_dir expand in the entry's launch context,
            -- with `${target_dir}` where a build target is resolved (§8.7).
            local lctx = expand.launch_context(ws, profile, project, { target = r.target })
            top = { entry = se, kind = r.kind, target = r.target, lctx = lctx,
                cwd = (require("loomworks.test_plan").resolve_working_dir(se.working_dir, lctx, ws and ws.root)) }
            if r.kind == "launch" then
                top.launch_target = require("loomworks.launch_target").new(ws, profile,
                    { project = project.key, launch = se.name })
            end
            program, perr = self:_program(top)
        end
        if program then
            top.args = require("loomworks.test_plan").expand_args(se.args, top.lctx)
            top.lctx = nil
            base.runnable = true
            base.executable = program.cmd
            base.args = top.args
            self._top_by_id[id] = top
            entries[#entries + 1] = base
            -- The results option applies only to a build target's artifact.
            if r.target then probe[#probe + 1] = base end
        else
            base.runnable = false
            base.status = "errored"
            if r.state == "unknown" then
                base.message = "targets of " .. level .. " are unknown (configure first)"
            elseif r.state == "missing" then
                base.message = r.reason or ("not a target or launch of " .. level)
            else
                base.message = "cannot resolve " .. label .. ": " .. tostring(perr or "no profile maps " .. level)
            end
            entries[#entries + 1] = base
        end
    end
    return entries, probe
end

--- The suffix of a top-level entry's children ids: none for a once-listed
--- (or first) `target` entry, `@<entry id>` otherwise, so the children of a
--- repeated or `launch` entry never collide with another entry's.
local function child_suffix(e)
    if e.saved_kind == "target" and (e.saved_index or 1) < 2 then return "" end
    return "@" .. e.id
end

--- Attach gtest children (with source locations) for a probed entry.
local function add_children(self, entries, e, framework, list)
    self._framework_cache[e.executable] = framework or false
    if framework and list then
        e.framework = framework
        local suffix = child_suffix(e)
        for _, t in ipairs(list) do
            t.id = t.id .. suffix
            t.parent = e.id
            entries[#entries + 1] = t
        end
        local top = self._top_by_id[e.id]
        local target = top and top.target
        if target and target.sources and #target.sources > 0 then
            gtest.find_source_locations(list, target.sources)
        end
    end
end

--- @return loomworks.SavedTestTreeEntry[]|nil
function SavedTargetsTestUnit:discover()
    if self._entries then return self._entries end
    local entries, probe = self:_resolve_entries()
    for _, e in ipairs(probe) do
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
    local entries, probe = self:_resolve_entries()
    local todo = {}
    for _, e in ipairs(probe) do
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

--- Entry-, suite- or case-level command (spec §8.9.2): the program (a
--- `target` entry's run spec, or a `launch` entry's resolved run spec), the
--- results option and framework filter when the program is a recognised
--- framework executable, the launch's own args, then the entry's args
--- (expanded), in the entry's working directory. A `launch` entry's deploy
--- steps are NOT run here: `prepare` runs them when the step executes (the
--- runner calls it first; `false, err` fails the step, never drops it).
--- @param test_id string
--- @param opts? { gtest_filter?: string }
--- @return table|nil { cmd, env, cwd, output_path, prepare?: fun(): boolean, string|nil, test_id: string }
function SavedTargetsTestUnit:test_command(test_id, opts)
    opts = opts or {}
    local e = self:_entry(test_id)
    if not e then return nil end
    local top_e = e.parent and self:_entry(e.parent) or e
    if not top_e or not top_e.runnable then return nil end
    local top = self._top_by_id[top_e.id]
    if not top then return nil end
    -- A launch entry's deploy steps run when the step executes, not while
    -- the command is built: the runner calls `prepare` first, and a failed
    -- deploy fails that step (spec §16.16, §8.8.4).
    local prepare
    if top.launch_target then
        local lt = top.launch_target
        prepare = function()
            local ok, err = lt:deploy_sync()
            if not ok then return false, "deploy failed: " .. tostring(err) end
            return true
        end
    end
    local spec = self:_program(top)
    if not spec then return nil end
    local cmd = { spec.cmd }
    local env = spec.env and vim.deepcopy(spec.env) or {}
    local output_path
    if top_e.framework == "gtest" then
        local build_dir = self._config_unit:build_dir()
        local dir = (build_dir or uv.os_tmpdir():gsub("\\", "/")) .. "/.nvim"
        if not uv.fs_stat(dir) then uv.fs_mkdir(dir, 493) end
        output_path = dir .. "/saved_" .. (top_e.id:gsub("[^%w%._%-]", "_")) .. "_results.xml"
        self._suffix_by_output[output_path] = child_suffix(top_e)
        cmd[#cmd + 1] = "--gtest_output=xml:" .. output_path
        if e.parent then
            env.GTEST_FILTER = opts.gtest_filter or (test_id:match("^test:([^@]+)") or test_id)
        elseif opts.gtest_filter then
            env.GTEST_FILTER = opts.gtest_filter
        end
    end
    for _, a in ipairs(spec.args or {}) do cmd[#cmd + 1] = a end
    for _, a in ipairs(top.args or {}) do cmd[#cmd + 1] = a end
    return { cmd = cmd, env = next(env) and env or nil, cwd = spec.cwd, output_path = output_path,
        prepare = prepare, test_id = top_e.id }
end

--- nil — run-all iterates the top-level entries (spec §8.9.4).
function SavedTargetsTestUnit:test_command_all(_) return nil end

--- nil — never a batch runner (spec §8.9.2).
function SavedTargetsTestUnit:run_command_all(_) return nil end

--- Parse a results file; the ids of a repeated or `launch` entry's cases
--- carry that entry's child suffix, so they land on its own children.
--- @param output_path string
--- @return table[]|nil
function SavedTargetsTestUnit:parse_results(output_path)
    local results = gtest.parse_xml_results(output_path)
    local suffix = self._suffix_by_output[output_path]
    if results and suffix and suffix ~= "" then
        for _, r in ipairs(results) do
            if type(r.test_id) == "string" then r.test_id = r.test_id .. suffix end
        end
    end
    return results
end

function SavedTargetsTestUnit:invalidate()
    self._entries = nil
    self._framework_cache = {}
end

return SavedTargetsTestUnit

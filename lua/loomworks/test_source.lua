--- loomworks/test_source.lua — where the editor's test adapters read tests
--- (daemon.md §19.16 "Tests", LOOMTEST.md §13; step 5m part A). The loomtest
--- adapter (loomworks/loomtest_adapter.lua) and the neotest adapter
--- (loomworks/neotest) read the test trees, the units' test commands and
--- results, and the tests view's state only through this module, never from
--- the workspace model.
---
--- One source per runtime mode (as loomworks/lsp_source.lua):
---   * `daemon` mode (the loaded workspace has an observer of the workspace
---     daemon, step 5m C1): **only** the daemon's `loomworks.view.Tests/1`
---     (`daemon_view`, the view store's table), where it stands
---     (`daemon_status`, the observer's `tests_status`), and discovery as a
---     `Tests/1.discover` call the editor owns (`daemon_discover`). Nothing is
---     discovered, parsed or run from the editor's model: the in-process
---     discovery entry points below refuse in this mode (no fallback). Runs
---     (`daemon_run`), debug preparations and their results
---     (`daemon_prepare_debug`, `daemon_collect`) and a node's output
---     (`daemon_result`) are `Tests/1` calls too (step 5m C2).
---   * `in-process` mode (transition, until step 6b): the editor's own model,
---     reached through the `loomworks` facade — ConfigUnit discovery, the
---     TestUnits' RunSpecs and results parsing, as the adapters did
---     themselves before, and `state()`, the `view.Tests/1` shape built by
---     loomworks/test_state.lua.
---
--- A configuration unit is passed around as an opaque handle (`unit`): the
--- adapters hand it back to this module and never read it.

local test_state = require("loomworks.test_state")

local M = {}

--- Test seam: the facade to read instead of `require("loomworks")`.
--- @type table|nil
M._facade = nil

--- The loomworks facade, or nil when it cannot be loaded.
--- @return table|nil
local function facade()
    if M._facade then return M._facade end
    local ok, lw = pcall(require, "loomworks")
    if not ok or type(lw) ~= "table" then return nil end
    return lw
end

--- The in-process workspace model (the one place the adapters' reads touch it).
--- @param lw table|nil
--- @return loomworks.Workspace|nil
local function model(lw)
    if not lw or type(lw.get_workspace) ~= "function" then return nil end
    return lw.get_workspace()
end

--- The editor's observer of the loaded workspace's daemon (daemon runtime
--- mode), or nil. Never loads the daemon modules: in in-process mode they
--- are not loaded and there is none.
--- @return loomworks.daemon.Observer|nil
local function observer()
    local mod = package.loaded["loomworks.daemon.observer"]
    local ws = model(facade())
    if not ws or type(mod) ~= "table" or type(mod.of) ~= "function" then return nil end
    local obs = mod.of(ws)
    if obs and obs.state ~= "stopped" then return obs end
    return nil
end

--- The runtime mode the tests follow: "daemon" while the loaded workspace
--- has an observer of the workspace daemon, else "in-process".
--- @return "daemon"|"in-process"
function M.mode()
    return observer() and "daemon" or "in-process"
end

--- Whether the editor is in `daemon` mode (in-process discovery refused).
--- @return boolean
local function daemon_mode()
    return observer() ~= nil
end

-- ---------------------------------------------------------------------------
-- The daemon form (step 5m C1)
-- ---------------------------------------------------------------------------

--- The daemon's tests view (`loomworks.view.Tests/1`) as the observer holds
--- it, or nil (in-process mode, not subscribed, the connection lost).
--- @return loomworks.TestsView|nil
function M.daemon_view()
    local obs = observer()
    if not obs then return nil end
    return require("loomworks.views").daemon_state(obs, "tests")
end

--- Where the daemon's tests stand (the observer's `tests_status`): nil while
--- the view is in use with nothing to say, else `{ text, level, blocked }`.
--- In-process mode: nil.
--- @return { text: string, level: string, blocked: boolean }|nil
function M.daemon_status()
    local obs = observer()
    if not obs then return nil end
    return obs:tests_status()
end

--- Send `Tests/1.discover` (an owned task, with the editor's environment).
--- False when it cannot be carried now (nothing is discovered in-process
--- instead); otherwise `cb(ok, err)` once it ended.
--- @param force boolean probe units whose tree is current too
--- @param cb fun(ok: boolean, err: any)
--- @return boolean sent
function M.daemon_discover(force, cb)
    local obs = observer()
    if not obs then return false end
    return require("loomworks.daemon.editor_ops").discover_tests(obs.ws, { force = force }, {
        resolve = function() cb(true) end,
        reject = function(err) cb(false, err) end,
    })
end

--- Run test nodes (`Tests/1.run_cases`, an owned task; step 5m C2): `select`
--- the nodes' view ids, nil for run-all. False when it cannot be carried
--- now (nothing is run in-process instead); otherwise true and its handle
--- (`cancel`), ending through `k` (loomworks.daemon.editor_ops.run_tests).
--- @param select string[]|nil
--- @param opts { no_build?: boolean }|nil
--- @param k { resolve: fun(done: table, err: string|nil), reject: fun(err: string) }
--- @return boolean sent
--- @return { cancel: fun(self) }|nil handle
function M.daemon_run(select, opts, k)
    local obs = observer()
    if not obs then return false end
    return require("loomworks.daemon.editor_ops").run_tests(obs.ws, select, opts, k)
end

--- Prepare debugging one node (`Tests/1.prepare_debug`, an owned task; step
--- 5m C2): as daemon_run, resolving with `{ debug, prepared }`.
--- @param id string
--- @param k { resolve: fun(done: table, err: string|nil), reject: fun(err: string) }
--- @return boolean sent
--- @return { cancel: fun(self) }|nil handle
function M.daemon_prepare_debug(id, k)
    local obs = observer()
    if not obs then return false end
    return require("loomworks.daemon.editor_ops").prepare_test_debug(obs.ws, id, k)
end

--- `Tests/1.collect { prepared }` after a prepared debug session: `cb(cases
--- |nil, err)`. False when not carried now.
--- @param prepared string
--- @param cb fun(cases: table[]|nil, err: string|nil)
--- @return boolean sent
function M.daemon_collect(prepared, cb)
    local obs = observer()
    if not obs then return false end
    return require("loomworks.daemon.editor_ops").collect_tests(obs.ws, prepared, cb)
end

--- A node's last result with its output and error locations
--- (`Tests/1.result { id }`): `cb(result|nil, err)`. False when not carried.
--- @param id string
--- @param cb fun(result: table|nil, err: string|nil)
--- @return boolean sent
function M.daemon_result(id, cb)
    local obs = observer()
    if not obs then return false end
    return require("loomworks.daemon.editor_ops").test_result(obs.ws, id, cb)
end

--- The active profile: the loaded model's, read as the view builder reads
--- it (`test_state.active_profile`), so the adapters and the view never
--- disagree on it.
--- @return loomworks.Profile|nil
local function profile()
    return test_state.active_profile(model(facade()))
end

--- Normalize a path for comparison: `/`-separated, no trailing `/`.
--- @param p string
--- @return string
local function norm(p)
    return (p:gsub("\\", "/"):gsub("/$", ""))
end

--- A unit of the active profile as the adapters see it.
--- @class loomworks.TestSourceUnit
--- @field unit table the configuration unit (opaque handle)
--- @field project string|nil the project key
--- @field dir string|nil the project's directory: absolute, `/`-separated, no trailing `/`

-- ---------------------------------------------------------------------------
-- Workspace and profile
-- ---------------------------------------------------------------------------

--- Whether a workspace with an active profile is loaded.
--- @return boolean
function M.ready()
    return model(facade()) ~= nil and profile() ~= nil
end

--- The loaded workspace's root, or nil.
--- @return string|nil
function M.root()
    local ws = model(facade())
    return ws and ws.root or nil
end

--- Whether there is an active profile.
--- @return boolean
function M.has_profile()
    return profile() ~= nil
end

--- The active profile's key, or nil.
--- @return string|nil
function M.profile_key()
    local p = profile()
    return p and p.key or nil
end

--- The active profile's units in its project order (units only; a profile
--- project without one is left out).
--- @return loomworks.TestSourceUnit[]
function M.units()
    local p = profile()
    if not p then return {} end
    local ws = model(facade())
    local out = {}
    for _, pp in ipairs(p:projects()) do
        local unit = pp._config_unit
        if unit then
            local project = pp._project or unit._project
            local dir
            if ws and project then
                dir = norm(ws.root .. "/" .. (project.path or project.key)):gsub("/%.$", "")
            end
            out[#out + 1] = { unit = unit, project = project and project.key or nil, dir = dir }
        end
    end
    return out
end

--- The active profile's unit whose project contains `file_path` (the
--- project with the longest matching directory among all of the
--- workspace's), and that project's key; nil when none.
--- @param file_path string absolute path
--- @return table|nil unit, string|nil project_key
function M.unit_for_file(file_path)
    local ws = model(facade())
    if not ws then return nil, nil end
    local p = profile()
    if not p then return nil, nil end

    local norm_path = norm(file_path):lower()
    local best_project, best_len = nil, 0
    for _, project in pairs(ws._projects) do
        local project_path = project.path or project.key
        local project_abs = norm(ws.root .. "/" .. project_path):lower()
        -- Normalize trailing /. (project path "." → root/.)
        project_abs = project_abs:gsub("/%.$", "")
        if norm_path == project_abs or norm_path:sub(1, #project_abs + 1) == project_abs .. "/" then
            if #project_abs > best_len then
                best_project = project
                best_len = #project_abs
            end
        end
    end
    if not best_project then return nil, nil end

    local pp = p:project(best_project.key)
    if not pp or not pp._config_unit then return nil, best_project.key end
    return pp._config_unit, best_project.key
end

--- The loomworks log, or nil.
--- @return table|nil
function M.log()
    local ws = model(facade())
    local core = ws and ws._core
    return core and core._deps and core._deps.log or nil
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

--- A unit's cached test tree (merged entries, §8.9.3), or nil. Never discovers.
--- @param unit table
--- @return table[]|nil
function M.cached_tree(unit)
    return unit:test_tree()
end

--- Discover a unit's tests synchronously (cached when discovered); nil in
--- `daemon` mode (never discovered in-process).
--- @param unit table
--- @return table[]|nil
function M.discover(unit)
    if daemon_mode() then return nil end
    return unit:discover_tests()
end

--- Discover a unit's tests asynchronously; `callback(nil)` in `daemon` mode.
--- @param unit table
--- @param callback fun(entries: table[]|nil)
function M.discover_async(unit, callback)
    if daemon_mode() then return callback(nil) end
    unit:discover_tests_async(callback)
end

--- Start discovery for every unit of the active profile without a cached
--- tree (results land in the units' caches). Nothing in `daemon` mode.
--- @param sync? boolean discover synchronously
function M.warm(sync)
    if daemon_mode() then return end
    for _, u in ipairs(M.units()) do
        if not M.cached_tree(u.unit) then
            if sync then M.discover(u.unit) else M.discover_async(u.unit, function() end) end
        end
    end
end

--- Drop every unit's cached tests (TestUnits, tree, results). Nothing in
--- `daemon` mode (the daemon's view is the tests' only source).
function M.invalidate()
    if daemon_mode() then return end
    for _, u in ipairs(M.units()) do
        u.unit:invalidate_tests()
    end
end

-- ---------------------------------------------------------------------------
-- Owners, commands and results (the RunSpec path, §8.9.4)
-- ---------------------------------------------------------------------------

--- The unit whose TestUnit owns `test_id` (an entry with that id), or nil —
--- never a fallback guess (spec §8.9.4).
--- @param test_id string
--- @return table|nil
function M.owning_unit(test_id)
    for _, u in ipairs(M.units()) do
        for _, tu in ipairs(u.unit:test_units()) do
            for _, e in ipairs(tu:entries() or {}) do
                if e.id == test_id then return u.unit end
            end
        end
    end
    return nil
end

--- The unit (and its TestUnit) for a test id: the owning unit, else the
--- first unit with a TestUnit (its first TestUnit).
--- @param test_id string
--- @return table|nil unit, table|nil test_unit
function M.find_test_unit(test_id)
    local owner = M.owning_unit(test_id)
    if owner then return owner, owner:_find_test_unit(test_id) end
    for _, u in ipairs(M.units()) do
        local tu = u.unit:_find_test_unit(test_id)
        if tu then return u.unit, tu end
    end
    return nil, nil
end

--- The command for one test, suite or target of a unit, and the TestUnit
--- that parses its results.
--- @param unit table
--- @param test_id string
--- @param opts? table
--- @return table|nil cmd, table|nil test_unit
function M.command_for(unit, test_id, opts)
    return unit:test_command_for(test_id, opts)
end

--- A unit's "run all" commands (§8.9.4), each with its TestUnit.
--- @param unit table
--- @param opts? table
--- @return { cmd: table, tu: table, id: string|nil }[]
function M.commands_all(unit, opts)
    return unit:test_commands_all(opts)
end

--- Run a step's own preparation (a saved launch entry's deploy) now; a
--- failure marks the entry failed.
--- @param unit table
--- @param name string
--- @param cmd table
--- @return boolean ok
function M.prepare_step(unit, name, cmd)
    return unit:_prepare_test_step(name, cmd)
end

--- A unit's state as gating decisions read it (state-lifecycle.md §3.4).
--- @param unit table
--- @return string
function M.local_state(unit)
    return unit:local_state()
end

--- Parse a results file with the TestUnit that produced it.
--- @param test_unit table
--- @param output_path string
--- @return table[]|nil
function M.parse_results(test_unit, output_path)
    return test_unit:parse_results(output_path)
end

--- Parse a results file with the first TestUnit of the active profile's
--- units that can (the producer unknown).
--- @param output_path string
--- @return table[]|nil
function M.parse_results_any(output_path)
    for _, u in ipairs(M.units()) do
        for _, tu in ipairs(u.unit:test_units()) do
            local results = tu:parse_results(output_path)
            if results then return results end
        end
    end
    return nil
end

--- Record parsed results on a unit's tree and announce them
--- (`test_results_changed`).
--- @param unit table
--- @param results table[]
function M.apply_results(unit, results)
    unit:_apply_test_results(results)
    local ws = model(facade())
    if ws then
        ws._core._deps.events.emit("test_results_changed", unit)
    end
end

--- The unit and build target a pre-test build of `test_ids` builds: the unit
--- that owns the first id (else the first unit), and the build target whose
--- name matches the executable of that id's tree entry (else of the first
--- top-level entry with a matching executable), or nil for the whole unit.
--- @param test_ids string[]|nil
--- @return table|nil unit, string|nil target_id
function M.build_target_for(test_ids)
    local owner = test_ids and test_ids[1] and M.owning_unit(test_ids[1]) or nil
    for _, u in ipairs(M.units()) do
        local unit = u.unit
        if not owner or unit == owner then
            local target_id = nil
            local tree = M.cached_tree(unit)
            if unit.targets and test_ids and #test_ids > 0 and tree then
                local function target_of(exe)
                    local exe_name = (exe:match("[/\\]([^/\\]+)$") or exe):gsub("%.exe$", "")
                    local target_obj = unit.targets[exe_name]
                    return target_obj and target_obj.id or nil
                end
                for _, e in ipairs(tree) do
                    if e.id == test_ids[1] and e.executable then
                        target_id = target_of(e.executable)
                        break
                    end
                end
                if not target_id then
                    for _, e in ipairs(tree) do
                        if e.executable and not e.parent then
                            target_id = target_of(e.executable)
                            if target_id then break end
                        end
                    end
                end
            end
            return unit, target_id
        end
    end
    return nil, nil
end

--- The build command of a unit (or one of its targets), as the editor's
--- build would run it.
--- @param unit table
--- @param target_id string|nil
--- @return table|nil spec { cmd, cwd, env }
function M.build_spec(unit, target_id)
    return require("loomworks.overseer").build_spec_for(unit, target_id)
end

-- ---------------------------------------------------------------------------
-- The tests view
-- ---------------------------------------------------------------------------

--- `loomworks.view.Tests/1`'s state from the in-process model (local keys
--- as node ids, no daemon-only ids): the units' cached trees, a unit not
--- discovered yet `pending`.
--- @param opts? loomworks.TestsViewOpts
--- @return loomworks.TestsView
function M.state(opts)
    return test_state.state(model(facade()), opts)
end

return M

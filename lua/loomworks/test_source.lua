--- loomworks/test_source.lua — where the editor's test adapters read tests
--- (daemon.md §19.16 "Tests", LOOMTEST.md §13). The loomtest adapter
--- (loomworks/loomtest_adapter.lua) reads the tests only through this module.
---
--- The source is **only** the workspace daemon the editor observes: its
--- `loomworks.view.Tests/1` (`daemon_view`, the view store's table), where it
--- stands (`daemon_status`, the observer's `tests_status`), and discovery as
--- a `Tests/1.discover` call the editor owns (`daemon_discover`). Runs
--- (`daemon_run`), debug preparations and their results
--- (`daemon_prepare_debug`, `daemon_collect`) and a node's output
--- (`daemon_result`) are `Tests/1` calls too. Nothing is discovered, parsed,
--- built or run in the editor: without an observer every call answers
--- "not sent" (no fallback). Node ids are the daemon's, passed back as they
--- are.

local M = {}

--- The editor's observer of the workspace daemon, or nil. Never loads the
--- daemon modules.
--- @return loomworks.daemon.Observer|nil
local function observer()
    local mod = package.loaded["loomworks.daemon.observer"]
    if type(mod) ~= "table" or type(mod.current) ~= "function" then return nil end
    return mod.current()
end

--- Whether the editor observes a workspace daemon (the tests have a source).
--- @return boolean
function M.attached()
    return observer() ~= nil
end

-- ---------------------------------------------------------------------------
-- The daemon form (step 5m C1)
-- ---------------------------------------------------------------------------

--- The daemon's tests view (`loomworks.view.Tests/1`) as the observer holds
--- it, or nil (not attached, not subscribed, the connection lost).
--- @return loomworks.TestsView|nil
function M.daemon_view()
    local obs = observer()
    if not obs then return nil end
    return require("loomworks.views").daemon_state(obs, "tests")
end

--- Where the daemon's tests stand (the observer's `tests_status`): nil while
--- the view is in use with nothing to say, else `{ text, level, blocked }`.
--- Not attached: nil.
--- @return { text: string, level: string, blocked: boolean }|nil
function M.daemon_status()
    local obs = observer()
    if not obs then return nil end
    return obs:tests_status()
end

--- Send `Tests/1.discover` (an owned task, with the editor's environment).
--- False when it cannot be carried now (nothing is discovered in the editor
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
--- now (nothing is run in the editor instead); otherwise true and its handle
--- (`cancel`), ending through `k` (loomworks.daemon.editor_ops.run_tests).
--- @param select string[]|nil
--- @param opts { no_build?: boolean }|nil
--- @param k { resolve: fun(done: table, err: string|nil), reject: fun(err: string), accepted?: fun(task_id: any) }
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

return M

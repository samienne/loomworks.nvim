--- loomworks/daemon/tests_view.lua — the workspace daemon's tests view
--- (`loomworks.view.Tests/1` on `/views`, spec §19.13 "The tests view"; step
--- 5m part B1): its state, built by loomworks.test_state (the builder the
--- editor uses in-process) from the session's test state — the one store,
--- loomworks.daemon.test_store (discovered trees, staleness, node ids, last
--- results, a running run's statuses) — with the daemon's opaque ids
--- (§19.12) and its session fields.

local test_state = require("loomworks.test_state")
local test_store = require("loomworks.daemon.test_store")

local M = {}

M.VIEW = { path = "/views", iface = "loomworks.view.Tests", v = 1 }

--- `loomworks.view.Tests/1`'s state. Never loads, never discovers.
--- `committed`: the node statuses as of the store's last commit (the state
--- loomworks.daemon.views decides an `update` on), else the current ones.
--- @param service loomworks.daemon.BuildService
--- @param o? { committed?: boolean }
--- @return loomworks.TestsView
function M.state(service, o)
    local ws, err = service:header_model()
    if not ws then
        local state = require("loomworks.view_state").base_header(nil, err).state
        return test_state.state(nil, { state = state, stale = false })
    end
    return test_state.state(ws, test_store.of(service):view_opts(ws, o))
end

return M

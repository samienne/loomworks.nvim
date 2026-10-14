--- loomworks/daemon/views.lua — the editor views the build service serves
--- on `/views` (spec §19.13 "Views", §19.20 "Interface catalogue", step 5j
--- part B):
---
---   /views   loomworks.view.Header/1          get (update)
---   /views   loomworks.view.ProjectsIndex/1   get (update)
---   /views   loomworks.view.Tests/1           get (update; loomworks.daemon.tests_view, step 5m)
---
--- Each view has one method, `get` (its full state; never loads the
--- workspace: an unloaded one is the unloaded state), and one signal,
--- `update`, declared `initial`: subscribing returns the full state, and every
--- `update` carries the full state again, never a delta. The state is built by
--- loomworks.view_state — the builder the editor uses in-process — with the
--- session fields and the opaque ids (§19.12) only the daemon fills.
---
--- `check` runs where `Workspace.header_changed` is checked
--- (core_interfaces.header_check: after every model segment and every
--- committed write, and before the acknowledgement of a request answered
--- inside its segment) and sends `update` to a subscription only when the
--- view's state differs from the one last sent on it (`initial` included).
--- The tests view compares its committed state (`{ committed = true }`,
--- loomworks.daemon.test_store: node statuses as of a run's start and end
--- and a collect), so a running run's per-case progress — which travels as
--- `Tests/1.results` — never causes an `update`; what it sends is the
--- current state.

local view_state = require("loomworks.view_state")

local M = {}

M.HEADER = { path = "/views", iface = "loomworks.view.Header", v = 1 }
M.PROJECTS = { path = "/views", iface = "loomworks.view.ProjectsIndex", v = 1 }
M.TESTS = { path = "/views", iface = "loomworks.view.Tests", v = 1 }

--- The builder options of the daemon: its session fields and its ids.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.ViewOpts
local function opts(service)
    local srv = service.server
    return { root = srv.root,
        session = { pid = srv.pid, lw_version = srv.identity, session_generation = srv.generation },
        id = function(obj) return service.ids:id(obj) end,
        version = require("loomworks.save_guard").version() }
end

--- `loomworks.view.Header/1`'s state. Never loads.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.ViewHeader
function M.header(service)
    local ws, err = service:header_model()
    return view_state.header(ws, err, opts(service))
end

--- `loomworks.view.ProjectsIndex/1`'s state. Never loads.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.ViewProjectsIndex
function M.projects_index(service)
    local ws = service:header_model()
    return view_state.projects_index(ws, opts(service))
end

--- `loomworks.view.Tests/1`'s state (§19.13 "The tests view"). Never loads,
--- never discovers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.TestsView
function M.tests(service)
    return require("loomworks.daemon.tests_view").state(service)
end

--- The signature `check` compares for the tests view: its committed state's.
--- @param service loomworks.daemon.BuildService
--- @return string
function M.tests_signature(service)
    return view_state.signature(require("loomworks.daemon.tests_view").state(service, { committed = true }))
end

--- The handlers of a view: `get` and the `initial` state, which records its
--- signature on the subscription (the baseline of `check`; `sig`: the
--- view's own signature, else the state's).
--- @param where { path: string, iface: string, v: integer }
--- @param build fun(service: loomworks.daemon.BuildService): table
--- @param service loomworks.daemon.BuildService
--- @param sig? fun(service: loomworks.daemon.BuildService): string
--- @return loomworks.daemon.InterfaceImpl
local function impl(where, build, service, sig)
    return {
        methods = { get = function() return build(service) end },
        initial = function(ctx, _, _, sub)
            local state = build(service)
            if sub then sub.view_sig = sig and sig(service) or view_state.signature(state) end
            local e = ctx.registry:resolve(where.path, where.iface, where.v)
            local sdoc = e and e.doc.signals and e.doc.signals.update
            return e and ctx.registry:_shape(e, sdoc and sdoc.args, state) or state
        end,
    }
end

--- The `loomworks.view.Header/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.header_impl(service) return impl(M.HEADER, M.header, service) end

--- The `loomworks.view.ProjectsIndex/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.projects_impl(service) return impl(M.PROJECTS, M.projects_index, service) end

--- The `loomworks.view.Tests/1` handlers.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
function M.tests_impl(service) return impl(M.TESTS, M.tests, service, M.tests_signature) end

--- The views and their handler factories, in mount order.
M.MOUNTS = {
    { M.HEADER, M.header_impl },
    { M.PROJECTS, M.projects_impl },
    { M.TESTS, M.tests_impl },
}

--- Send `update` to every subscription of a view whose state differs from
--- the one last sent on it. A view nobody subscribes to is not built.
--- @param service loomworks.daemon.BuildService
function M.check(service)
    local reg = service.server and service.server.interfaces
    if not reg then return end
    for _, v in ipairs({ { M.HEADER, M.header }, { M.PROJECTS, M.projects_index },
        { M.TESTS, M.tests, M.tests_signature } }) do
        local where, build, sig_of = v[1], v[2], v[3]
        if reg:has_subscribers(where.path, where.iface, where.v, "update") then
            local state, sig
            if sig_of then
                sig = sig_of(service)
            else
                state = build(service)
                sig = view_state.signature(state)
            end
            -- (The state is built once, for the first subscription sent to.)
            reg:emit(where.path, where.iface, where.v, "update", function()
                state = state or build(service)
                return state
            end, function(_, sub)
                if sub.view_sig == sig then return false end
                sub.view_sig = sig
                return true
            end)
        end
    end
end

return M

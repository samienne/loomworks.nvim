--- loomworks/daemon/views.lua — the editor views the build service serves
--- on `/views` (spec §19.13 "Views", §19.20 "Interface catalogue", step 5j
--- part B):
---
---   /views   loomworks.view.Header/1          get (update)
---   /views   loomworks.view.ProjectsIndex/1   get (update)
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

local view_state = require("loomworks.view_state")

local M = {}

M.HEADER = { path = "/views", iface = "loomworks.view.Header", v = 1 }
M.PROJECTS = { path = "/views", iface = "loomworks.view.ProjectsIndex", v = 1 }

--- The builder options of the daemon: its session fields and its ids.
--- @param service loomworks.daemon.BuildService
--- @return loomworks.ViewOpts
local function opts(service)
    local srv = service.server
    return { root = srv.root,
        session = { pid = srv.pid, lw_version = srv.identity, session_generation = srv.generation },
        id = function(obj) return service.ids:id(obj) end }
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

--- The handlers of a view: `get` and the `initial` state, which records its
--- signature on the subscription (the baseline of `check`).
--- @param where { path: string, iface: string, v: integer }
--- @param build fun(service: loomworks.daemon.BuildService): table
--- @param service loomworks.daemon.BuildService
--- @return loomworks.daemon.InterfaceImpl
local function impl(where, build, service)
    return {
        methods = { get = function() return build(service) end },
        initial = function(ctx, _, _, sub)
            local state = build(service)
            if sub then sub.view_sig = view_state.signature(state) end
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

--- The views and their handler factories, in mount order.
M.MOUNTS = {
    { M.HEADER, M.header_impl },
    { M.PROJECTS, M.projects_impl },
}

--- Send `update` to every subscription of a view whose state differs from
--- the one last sent on it. A view nobody subscribes to is not built.
--- @param service loomworks.daemon.BuildService
function M.check(service)
    local reg = service.server and service.server.interfaces
    if not reg then return end
    for _, v in ipairs({ { M.HEADER, M.header }, { M.PROJECTS, M.projects_index } }) do
        local where, build = v[1], v[2]
        if reg:has_subscribers(where.path, where.iface, where.v, "update") then
            local state = build(service)
            local sig = view_state.signature(state)
            reg:emit(where.path, where.iface, where.v, "update", state, function(_, sub)
                if sub.view_sig == sig then return false end
                sub.view_sig = sig
                return true
            end)
        end
    end
end

return M

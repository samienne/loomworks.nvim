--- loomworks/daemon/service.lua — bind the authoritative Workspace to a server.
---
--- The transport core (`server.lua`) is model-agnostic; this layer gives it a
--- live Workspace and registers the model-facing handlers on top of the handler
--- registry. Phase 3 serves the read path: a `snapshot` request returns the wire
--- payload (§2) a projection client hydrates from, and the handshake carries an
--- always-warm header (DAEMON.md §3.5). Commands and broadcasts layer on next.

local protocol = require("loomworks.daemon.protocol")
local snapshot = require("loomworks.daemon.snapshot")
local ids = require("loomworks.daemon.ids")
local commands = require("loomworks.daemon.commands")

local M = {}

--- The bounded, always-warm header delivered in `welcome` and kept fresh by
--- broadcasts — cheap enough for a winbar redraw that cannot query per-frame.
--- @param ws table
--- @return table
local function header_of(ws)
    if not ws then return { workspace = false } end
    return {
        workspace = true,
        name = ws.name,
        active_profile = ws._active_profile_key,
        error_state = ws._error_state and true or false,
    }
end

--- Attach a workspace to a server and register the model handlers.
---
--- Provide either a pre-built `opts.workspace` (+ optional `opts.core`), or an
--- `opts.load_workspace(root) -> ws, core` loader the service calls to bootstrap
--- one headlessly. The loaded workspace and core are stored on the server as
--- `server.workspace` / `server.core`.
---
--- @param server loomworks.daemon.Server
--- @param opts { workspace?: table, core?: table, load_workspace?: fun(root:string):table, table }
--- @return table|nil workspace, string|nil err
function M.attach(server, opts)
    opts = opts or {}
    local ws, core = opts.workspace, opts.core
    if not ws then
        if not opts.load_workspace then
            return nil, "service.attach needs a workspace or a load_workspace loader"
        end
        ws, core = opts.load_workspace(server.root)
        if not ws then return nil, "failed to load workspace at " .. tostring(server.root) end
    end
    server.workspace = ws
    server.core = core
    -- The opaque wire-identity registry for this daemon session (§3.2).
    server.ids = server.ids or ids.new()

    -- Warm header for the handshake (§3.5).
    server._header_snapshot = function(self) return header_of(self.workspace) end

    -- Read path: full model snapshot, seq-stamped for the cold-start hydration
    -- rule (§3.3), with the key→id index stamped in so the client can build its
    -- id-map (subscription set). The client rebuilds an identical Workspace.
    server:handle("snapshot", function(srv, conn, msg)
        local snap = snapshot.serialize(srv.workspace)
        snap.ids = srv.ids:index(srv.workspace)
        conn.reply({
            kind = protocol.KIND.ok,
            req_id = msg.req_id,
            snapshot = snap,
            seq = srv.seq,
            session_generation = srv.generation,
        })
    end)

    -- Command (mutation) path (§3.1). The daemon applies the mutation against
    -- its authoritative workspace and persists it; the mutation emits
    -- active_set_changed → a model_change broadcast (the effect), which is sent
    -- to all clients BEFORE this ack (broadcast is synchronous within apply, the
    -- reply follows). The reply is only ack/error.
    server:handle("command", function(srv, conn, msg)
        local outcome, err = commands.apply(srv.workspace, msg.name, msg.args)
        if err then
            conn.reply({ kind = protocol.KIND.error, req_id = msg.req_id, error = err })
        else
            conn.reply({ kind = protocol.KIND.ok, req_id = msg.req_id, outcome = outcome or "ok" })
        end
    end)

    -- Propagate the daemon's own model changes to every client. `active_set_changed`
    -- fires on every remerge (external file edit) and every activation/mutation,
    -- so a coarse `model_change` broadcast (→ client re-pull) keeps projections
    -- live. Subscribing through the workspace's OWN events dep keeps the daemon's
    -- stream isolated from any other in-process workspace (single-workspace in
    -- production; injected per-daemon in tests).
    if not opts.no_change_subscription and ws._core and ws._core._deps
        and ws._core._deps.events and ws._core._deps.events.on then
        ws._core._deps.events.on("active_set_changed", function()
            server:notify_model_change({ "active_set" })
        end)
    end

    return ws
end

return M

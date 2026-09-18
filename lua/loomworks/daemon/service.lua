--- loomworks/daemon/service.lua — bind the authoritative Workspace to a server.
---
--- The transport core (`server.lua`) is model-agnostic; this layer gives it a
--- live Workspace and registers the model-facing handlers on top of the handler
--- registry. Phase 3 serves the read path: a `snapshot` request returns the wire
--- payload (§2) a projection client hydrates from, and the handshake carries an
--- always-warm header (DAEMON.md §3.5). Commands and broadcasts layer on next.

local protocol = require("loomworks.daemon.protocol")
local snapshot = require("loomworks.daemon.snapshot")

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

    -- Warm header for the handshake (§3.5).
    server._header_snapshot = function(self) return header_of(self.workspace) end

    -- Read path: full model snapshot, seq-stamped for the cold-start hydration
    -- rule (§3.3). The client rebuilds an identical Workspace from this.
    server:handle("snapshot", function(srv, conn, msg)
        conn.reply({
            kind = protocol.KIND.ok,
            req_id = msg.req_id,
            snapshot = snapshot.serialize(srv.workspace),
            seq = srv.seq,
            session_generation = srv.generation,
        })
    end)

    return ws
end

return M

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
local tasks = require("loomworks.daemon.tasks")

local M = {}

--- Error-reply prefixes for a build the daemon does not accept. The client
--- falls back in-process on either, which reports the refusal itself.
M.ERR_WORKSPACE = "workspace_unavailable"
M.ERR_PROFILE = "profile_unresolved"

--- Resolve the build's profile argument at the wire boundary with the SAME
--- matcher the in-process `lw build <profile>` uses (exact key, else an
--- unambiguous boundary-anchored substring — `loomworks.merge.match_profile`).
--- A miss or an ambiguity is not built here: the client falls back in-process,
--- which reports it (or onboards a profile from a configuration set).
--- @return table|nil profile, string|nil err
local function resolve_profile(ws, name)
    local keys, by_key = {}, {}
    for _, p in ipairs(ws._profiles or {}) do keys[#keys + 1] = p.key; by_key[p.key] = p end
    local hit, ambiguous = require("loomworks.merge").match_profile(keys, tostring(name or ""))
    if hit then return by_key[hit] end
    if ambiguous then
        return nil, "'" .. tostring(name) .. "' matches multiple profiles: " .. table.concat(ambiguous, ", ")
    end
    return nil, "no profile matching '" .. tostring(name) .. "'"
end

--- The daemon's LIVE workspace, re-validated before a build acts on it. An
--- in-process `lw build` loads the workspace fresh from disk; the daemon's is
--- long-lived, so first apply every pending external change exactly as the
--- next file poll would (`FileTracker:sync` → `_on_file_changed`): an edited
--- working copy, a profile created by another `lw`, a discarded working copy
--- (`lw trust --discard`), a deleted cache (`lw nuke`), and a file that is no
--- longer trusted (§17.4 — which unloads the workspace). Then refuse unless
--- the core still holds a loaded workspace; adopt a reloaded one (re-trusted).
--- @param srv loomworks.daemon.Server
--- @return table|nil workspace, string|nil err
local function live_workspace(srv)
    local core = srv.core
    local has_core = core and core.get_workspace
    local ws = has_core and core:get_workspace() or srv.workspace
    if ws and ws._tracker and ws._tracker.sync then pcall(ws._tracker.sync, ws._tracker) end
    if not has_core then return ws end
    local cur = core:get_workspace()
    if not cur or core._state ~= "initialized" then
        local e = core.get_setup_error and core:get_setup_error()
        return nil, (e and e.message) or "the workspace is not loaded"
    end
    srv.workspace = cur
    return cur
end
M._live_workspace = live_workspace

--- The default build runner: the in-process build path (`daemon.runner` over
--- `loomworks.build_run`), streamed. Injectable via `opts.run_build` for tests.
--- @param srv loomworks.daemon.Server
--- @param args table { profile_key, extra_args? }
--- @param task_id integer
--- @param ctx { workspace: table, profile: table }
--- @return table|nil controller with `cancel(reason, code)`
local function default_run_build(srv, args, task_id, ctx)
    local runner = require("loomworks.daemon.runner")
    local ws, profile = ctx.workspace, ctx.profile
    return runner.run_build(ws, profile, srv.tasks, task_id, {
        extra_args = args.extra_args,
        -- Stop when the workspace is unloaded or the profile removed under it.
        is_current = function()
            if srv.core and srv.core.get_workspace and srv.core:get_workspace() ~= ws then
                return false, "the workspace was unloaded (refused or reloaded .nvim files)"
            end
            if profile._removed then return false, "profile '" .. profile.key .. "' was removed" end
            return true
        end,
    }, function(_code)
        -- Durable outcome: the build state changed on disk/cache.
        srv:notify_model_change({ "build_state" })
    end)
end

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
    -- The workspace task stream (§3.4) + the (injectable) build runner.
    server.tasks = server.tasks or tasks.new(server)
    server.run_build = opts.run_build or default_run_build
    -- Running builds by task id → { conn, ctl } (the launching client + the
    -- runner's controller), so they can be cancelled.
    server._builds = server._builds or {}
    server.tasks.on_task_done = function(task_id) server._builds[task_id] = nil end
    -- A build is owned by the client that launched it: when that connection
    -- goes away (Ctrl-C / kill of `lw build`, an editor closing) its builds
    -- are cancelled — the daemon equivalent of an interrupted in-process build
    -- (the child dies, the build-dir locks are released, nothing is recorded).
    server.on_conn_closed = function(srv, conn)
        for _, b in pairs(srv._builds) do
            if b.conn == conn then b.ctl.cancel("the client that started it disconnected") end
        end
    end
    -- A stopping daemon (`lw daemon stop`, idle, exit) stops its builds too.
    server.on_stopping = function(srv, reason)
        for _, b in pairs(srv._builds) do b.ctl.cancel("the daemon is stopping (" .. tostring(reason) .. ")") end
    end

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
        -- `build` is ASYNC (§3.4): ack acceptance with a task_id immediately, then
        -- stream via the task stream; the durable outcome follows as a
        -- build_state model_change. An outstanding task holds the daemon alive.
        if msg.name == "build" then
            srv:_touch()
            -- Validation touches the model (and maybe vim.fn): main loop.
            local function main(fn) if vim.schedule then vim.schedule(fn) else fn() end end
            main(function()
                local args = msg.args or {}
                local ws, werr = live_workspace(srv)
                if not ws then
                    conn.reply({ kind = protocol.KIND.error, req_id = msg.req_id,
                        error = M.ERR_WORKSPACE .. ": " .. tostring(werr) })
                    return
                end
                local profile, perr = resolve_profile(ws, args.profile_key)
                if not profile then
                    conn.reply({ kind = protocol.KIND.error, req_id = msg.req_id,
                        error = M.ERR_PROFILE .. ": " .. tostring(perr) })
                    return
                end
                local task_id = srv:next_task_id()
                conn.reply({ kind = protocol.KIND.ok, req_id = msg.req_id,
                    outcome = "accepted", task_id = task_id, profile_key = profile.key })
                local ctl = srv.run_build(srv, args, task_id, { workspace = ws, profile = profile })
                if type(ctl) == "table" and ctl.cancel then
                    -- The launching client owns the build: its disconnect
                    -- (Ctrl-C on `lw build`) cancels it (§19.12).
                    srv._builds[task_id] = { conn = conn, ctl = ctl }
                end
            end)
            return
        end
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

--- loomworks/daemon/commands.lua — the daemon COMMAND registry (DAEMON.md §3.1).
---
--- A client mutation becomes a `command{ name, args }` the daemon applies against
--- its authoritative Workspace and persists (the daemon holds the write-authority
--- lock, §17.7). Commands are **FIFO-serialized** by the single-threaded daemon
--- loop: a command's resulting `model_change` batch is broadcast before any later
--- command's. The *effect* returns as that broadcast (which re-renders the
--- projection); the reply is only an **ack** carrying an outcome
--- (`ok` / `rolled-back` / `partially-applied`) or an error.
---
--- Domain logic stays reference-based: each command RESOLVES its wire arguments
--- (semantic keys) to domain objects at this boundary — the same
--- deserialization-boundary resolution `data_model` performs — then calls the
--- object's own mutation method. No key lookups leak into domain logic.
---
--- This is a representative, extensible set (activate / deactivate / publish);
--- the remaining user.json/cache/publish mutations map the same way.

local M = {}

--- name -> fun(workspace, args) -> outcome:string|nil, err:string|nil
local registry = {}

--- Register a command handler.
--- @param name string
--- @param fn fun(workspace: table, args: table): string|nil, string|nil
function M.register(name, fn)
    registry[name] = fn
end

--- True when a command name is known.
--- @param name string
--- @return boolean
function M.has(name) return registry[name] ~= nil end

--- Apply a command. Returns `(outcome, nil)` or `(nil, err)`; a handler error is
--- caught and returned as an error string (never a crash).
--- @param workspace table
--- @param name string
--- @param args table|nil
--- @return string|nil outcome, string|nil err
function M.apply(workspace, name, args)
    local fn = registry[name]
    if not fn then return nil, "unknown command: " .. tostring(name) end
    local ok, outcome, err = pcall(fn, workspace, args or {})
    if not ok then return nil, "command error: " .. tostring(outcome) end
    return outcome, err
end

--- Resolve a profile by its semantic key at the wire boundary.
local function profile_by_key(workspace, key)
    for _, p in ipairs(workspace._profiles or {}) do
        if p.key == key then return p end
    end
    return nil
end

-- ---- built-in commands ------------------------------------------------------

M.register("profile.activate", function(ws, args)
    local p = profile_by_key(ws, args.profile_key)
    if not p then return nil, "no such profile: " .. tostring(args.profile_key) end
    p:activate()
    return "ok"
end)

M.register("profile.deactivate", function(ws, args)
    local key = args.profile_key or ws._active_profile_key
    local p = key and profile_by_key(ws, key) or nil
    if p and p.deactivate then
        p:deactivate()
    elseif ws._active_profile then
        ws._active_profile:deactivate()
    else
        return "ok" -- nothing active; idempotent
    end
    return "ok"
end)

M.register("publish", function(ws)
    ws:publish()
    return "ok"
end)

M._registry = registry
return M

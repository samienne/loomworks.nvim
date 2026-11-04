--- loomworks/lock_break.lua — `--break-locks` (spec §19.5): recover a lock
--- whose holder is hung, or live and responsive, on this host.
---
---   1. Ask   — the interrupt an `lw` holder handles (§16.6), then wait about
---              ASK_MS for it to let go (skipped by `--break-locks=now`, and on
---              Windows where another console's process cannot reliably be
---              interrupted).
---   2. Kill  — the holder's process tree, by force.
---   3. Verify that no process with the holder's id and start time remains.
--- The caller then acquires as usual: the record of a holder that is gone
--- classifies as dead and is reclaimed only if it still carries the observed
--- nonce (§19.5 step 4), and the reclaim's state recovery (step 5) runs.
---
--- Limits (§19.5): never another host, never an editor holder, never a holder
--- whose start time is unknown (a reused process id must never be signalled),
--- never this process. Every kill is reported through `opts.report`.

local lock_record = require("loomworks.lock_record")
local proc = require("loomworks.proc")

local M = {}

--- How long step 1 waits for an asked holder to let go.
M.ASK_MS = 5000

--- Process-wide request, set by the CLI from `--break-locks[=now]`: nil (not
--- requested), "ask" or "now". `command` names the running command for
--- recovery hints ("lw build"); `report` / `log` receive every ask and kill.
--- Acquisitions that do not thread options through (the device lock under a
--- remote run) read these.
M.requested = nil
M.command = nil
M.report = nil
M.log = nil

--- Parse a `--break-locks[=now]` argument: "ask" | "now" | nil (not this flag).
--- An unknown `=value` returns false.
--- @param arg string
--- @return "ask"|"now"|false|nil
function M.parse_flag(arg)
    if arg == "--break-locks" then return "ask" end
    local v = type(arg) == "string" and arg:match("^%-%-break%-locks=(.*)$")
    if v == nil then return nil end
    if v == "now" then return "now" end
    return false
end

--- Can this holder be broken from here? Returns true, or false + the reason
--- message (the refusal to print).
--- @param info table classified holder info
--- @param ctx table busy-message context (lock_record.busy_message)
--- @return boolean ok, string|nil refusal
function M.can_break(info, ctx)
    local bctx = setmetatable({ breaking = true }, { __index = ctx })
    if not lock_record.same_host(info) then
        return false, lock_record.busy_message(info, bctx)
    end
    if info.kind == "editor" then
        return false, lock_record.busy_message(info, bctx)
    end
    if info.state ~= "hung" and info.state ~= "live" then
        return false, lock_record.busy_message(info, bctx)
    end
    if type(info.pid) ~= "number" or proc.ancestors()[info.pid] then
        return false, (ctx.what or "the lock") .. " is held by this process or one that started it"
    end
    if type(info.start_time) ~= "string" or proc.alive(info.pid, info.start_time) == nil then
        return false, string.format("%s is held by %s (pid %s), whose process start time cannot be "
            .. "checked (an older loomworks, or no process information on this host) — it is never "
            .. "killed on a process id alone; wait for it, or remove the record without stopping it: %s",
            ctx.what or "the lock", lock_record.holder_text(info), tostring(info.pid),
            ctx.unlock and ("lw unlock --force " .. ctx.unlock) or "lw unlock --force")
    end
    return M.verify_identity(info, ctx)
end

--- Is the process a lock record names really such a holder (spec §19.5)?
--- A record is data from a shared directory: one naming an unrelated process
--- of this user (its id and start time are easy to read) must never get it
--- killed. The holder's command line must be an `lw` host — for a daemon
--- holder `lw … daemon run` (for `ctx.root` when it names one). A command
--- line that cannot be read refuses the kill. Returns true, or false + the
--- refusal.
--- @param info table classified holder info
--- @param ctx table busy-message context (+ `root`, `remedy`)
--- @return boolean ok, string|nil refusal
function M.verify_identity(info, ctx)
    local what = ctx.what or "the lock"
    local remedy = ctx.remedy or (ctx.unlock and ("lw unlock --force " .. ctx.unlock)) or "lw unlock --force"
    local args = proc.cmdline(info.pid, info.start_time)
    if not args then
        return false, string.format("%s is held by pid %s, whose command line cannot be read — it is never "
            .. "killed unchecked; wait for it, or remove the record without stopping it: %s",
            what, tostring(info.pid), remedy)
    end
    local daemon = info.kind == "daemon" or info.mode == "daemon"
    local ok
    if daemon then ok = proc.is_daemon_for(args, ctx.root) else ok = proc.is_lw(args) end
    if ok then return true end
    local exe = tostring(args[1] or "?"):gsub("\\", "/"):match("[^/]*$")
    return false, string.format("%s names pid %s (%s) as %s, but that process is not one — it is never "
        .. "killed; if the record is stale, remove it without stopping anything: %s",
        what, tostring(info.pid), exe, daemon and "an `lw daemon run`" or "an lw process", remedy)
end

--- Break the holder of a lock (steps 1–3). Returns true when the
--- holder let go or is gone; false + message otherwise.
--- opts:
---   mode    "ask" | "now"
---   report  fun(line: string) — every ask and kill is reported here
---   log     fun(line: string)|nil — and recorded here (the workspace log)
--- @param info table classified holder info (as observed)
--- @param ctx table busy-message context
--- @param opts table
--- @return boolean ok, string|nil err
function M.break_holder(info, ctx, opts)
    local ok, why = M.can_break(info, ctx)
    if not ok then return false, why end
    local report = opts.report or M.report or function() end
    local log = opts.log or M.log or function() end
    local function say(line) report(line); pcall(log, line) end
    local what = ctx.what or "the lock"
    local holder = string.format("%s (pid %d)", lock_record.holder_text(info), info.pid)

    -- Descendants enumerated before asking: an asked holder that exits on its
    -- own may leave its build tool running; those are stopped too.
    local before = proc.descendants(info.pid)
    if opts.mode ~= "now" and proc.interrupt(info.pid, info.start_time) then
        say(string.format("breaking %s: asked %s to stop", what, holder))
        vim.wait(M.ASK_MS, function()
            return proc.alive(info.pid, info.start_time) == false
        end, 50)
        if proc.alive(info.pid, info.start_time) == false then
            -- It let go and exited: stop what it left running.
            proc.kill_tree(info.pid, info.start_time, before)
            say(string.format("breaking %s: %s stopped", what, holder))
            return true
        end
    end
    say(string.format("breaking %s: killing %s and its child processes", what, holder))
    local gone, kerr = proc.kill_tree(info.pid, info.start_time, before)
    if not gone then
        return false, string.format("could not stop %s holding %s: %s", holder, what, tostring(kerr))
    end
    say(string.format("breaking %s: %s killed", what, holder))
    return true
end

--- Acquire a lock through `try()` (→ handle | nil, classified info). Under a
--- `--break-locks` request (`M.requested`) a hung or live holder on this host
--- is broken first and the acquisition retried once. Host-neutral: returns
--- the handle, or nil + the refusal message + the holder info.
--- @param try fun(): table|nil, table|nil
--- @param ctx table busy-message context (lock_record.busy_message)
--- @return table|nil handle, string|nil message, table|nil info
function M.acquire(try, ctx)
    local h, info = try()
    if h then return h end
    info = info or {}
    if M.requested and (info.state == "hung" or info.state == "live") then
        local ok, berr = M.break_holder(info, ctx, { mode = M.requested })
        if not ok then return nil, berr, info end
        h, info = try()
        if h then return h end
        info = info or {}
    end
    return nil, lock_record.busy_message(info, ctx), info
end

return M

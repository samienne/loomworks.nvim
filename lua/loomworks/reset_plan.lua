-- Headless reset (spec §16.30) — `lw reset [<profile> | --all]`, shared by the
-- in-process host (cli.lua `cmd_reset`) and the workspace daemon (§19.15
-- "Reset"): the plan (lock set, removal set, nothing-to-reset), its token, the
-- listing and every line the CLI prints, and the execution (the ONE deletion
-- path, Profile:reset / Workspace:reset_all, then the gone-from-disk check).
-- A host differs only in how it waits for the asynchronous execution (the
-- in-process host waits on it; the daemon keeps serving and passes its
-- cancellation as the stop predicate) and in who asks the confirmation.
--
-- Deletion safety (project CLAUDE.md): this module never removes anything
-- itself. Every removal goes through Workspace:execute_deletion /
-- delete_orphaned_build_dir (validated against the workspace root, cache
-- `unknown` on disk before a tree is removed and reset only after success,
-- shared directories kept by §4.6 identity). The caller holds the workspace
-- operation lock and the build-directory locks of `plan.lock_dirs` (the
-- deletion's own acquisition re-enters them).

local M = {}

local uv = vim.uv or vim.loop

--- How long the deletion may take (rm-rf subprocesses on large trees / slow
--- disks) before the reset is declared stuck.
M.TIMEOUT_MS = 120000
--- After the deletion settled, how long a directory may linger on disk
--- (Windows delete-pending: an antivirus/indexer handle keeps the entry in the
--- namespace until it closes) before it counts as not removed. Instant on a
--- healthy filesystem. Polled with a timer, never blocking.
M.VERIFY_MS = 30000

--- The reset's plan.
--- @class loomworks.ResetPlan
--- @field scope "profile"|"all"
--- @field profile loomworks.Profile|nil the profile reset (scope "profile")
--- @field scope_key string "all" or "profile:<key>" (what the token covers)
--- @field label string "profile '<key>'" or "the whole workspace"
--- @field lock_dirs string[] EVERY computed build dir of the scope (a loaded
---   profile carries a computed path even when never built, and another
---   process could be configuring it): all are held exclusive. A superset of
---   `removal_dirs`.
--- @field removal_dirs string[] the dirs that EXIST on disk and are targeted
---   for physical removal (disposition ~= "keep"): listed, and verified gone
---   after the deletion.
--- @field state_to_clear boolean a targeted unit (or orphan) carries build
---   state even with no dir on disk (e.g. deleted out of band): the reset
---   still clears it.
--- @field units loomworks.ConfigUnit[] the units the reset returns to
---   unconfigured (§19.15 `meta.units`; an orphan has no unit)
--- @field orphans string[] build-dir keys of the orphaned dirs (scope "all")
--- @field token string the plan token (`M.token`)

--- Plan a reset. Pure with respect to the workspace (nothing is changed); it
--- stats the build directories to tell which exist.
--- @param ws loomworks.Workspace
--- @param scope { profile?: loomworks.Profile, all?: boolean }
--- @return loomworks.ResetPlan
function M.plan(ws, scope)
    local lock_dirs, lock_seen = {}, {}
    local removal_dirs, removal_seen = {}, {}
    local state_to_clear = false
    local units, orphans = {}, {}
    local function add_lock(bd)
        if bd and not lock_seen[bd] then lock_seen[bd] = true; lock_dirs[#lock_dirs + 1] = bd end
    end
    local function add_removal(bd)
        if bd and not removal_seen[bd] and uv.fs_stat(bd) ~= nil then
            removal_seen[bd] = true; removal_dirs[#removal_dirs + 1] = bd
        end
    end

    local plan
    if scope.all then
        plan = { scope = "all", scope_key = "all", label = "the whole workspace" }
        for _, unit in pairs(ws._config_units or {}) do
            local bd = unit:build_dir()
            add_lock(bd)
            add_removal(bd) -- reset_all batches every unit; none are "keep"
            if unit.state_value ~= nil then state_to_clear = true end
            if bd then units[#units + 1] = unit end
        end
        for _, o in ipairs(ws:get_orphaned_configs()) do
            local p = o.build_dir_obj and o.build_dir_obj.path or nil
            add_lock(p)
            add_removal(p)
            orphans[#orphans + 1] = o.build_dir_key
            state_to_clear = true -- get_orphaned_configs only returns dirs WITH state
        end
    else
        local profile = assert(scope.profile, "reset_plan.plan: a profile or all")
        plan = {
            scope = "profile", profile = profile,
            scope_key = "profile:" .. profile.key,
            label = "profile '" .. profile.key .. "'",
        }
        -- plan_reset marks a unit shared with another profile as "keep" (its
        -- dir is retained); only non-keep items are physically removed.
        for _, item in ipairs(profile:plan_reset().items) do
            add_lock(item.build_dir)
            if item.disposition ~= "keep" then
                add_removal(item.build_dir)
                if item.unit and item.unit.state_value ~= nil then state_to_clear = true end
                if item.unit then units[#units + 1] = item.unit end
            end
        end
    end
    plan.lock_dirs = lock_dirs
    plan.removal_dirs = removal_dirs
    plan.state_to_clear = state_to_clear
    plan.units = units
    plan.orphans = orphans
    plan.token = M.token(plan.scope_key, lock_dirs, removal_dirs)
    return plan
end

local function sorted_copy(list)
    local c = {}
    for i, v in ipairs(list or {}) do c[i] = v end
    table.sort(c)
    return c
end

--- The plan token (§19.15 "Reset"): an opaque digest of the planned scope,
--- lock set and removal set, independent of their order. Equal for an equal
--- plan; different when the scope, a directory to lock or a directory to
--- remove differs. Pure (no filesystem access).
--- @param scope_key string "all" or "profile:<key>"
--- @param lock_dirs string[]
--- @param removal_dirs string[]
--- @return string token
function M.token(scope_key, lock_dirs, removal_dirs)
    local parts = { "reset-plan/1", "scope", tostring(scope_key) }
    parts[#parts + 1] = "lock"
    for _, d in ipairs(sorted_copy(lock_dirs)) do parts[#parts + 1] = d end
    parts[#parts + 1] = "remove"
    for _, d in ipairs(sorted_copy(removal_dirs)) do parts[#parts + 1] = d end
    -- NUL-separated: no path contains NUL, so the encoding is unambiguous.
    return vim.fn.sha256(table.concat(parts, "\0"))
end

--- Does the plan reset nothing (no directory to remove, no state to clear)?
--- @param plan loomworks.ResetPlan
--- @return boolean
function M.is_empty(plan)
    return #plan.removal_dirs == 0 and not plan.state_to_clear
end

--- The line of a reset with nothing to reset (stdout, exit 0).
--- @param plan loomworks.ResetPlan
--- @return string
function M.nothing_message(plan)
    return "nothing to reset for " .. plan.label .. " — no build directories to remove."
end

--- The listing printed before the confirmation (and before the deletion).
--- @param plan loomworks.ResetPlan
--- @return string[] lines
function M.listing(plan)
    local lines = {}
    local n = #plan.removal_dirs
    if n > 0 then
        lines[1] = string.format("Will remove %d build director%s and reset %s to unconfigured:",
            n, (n == 1) and "y" or "ies", plan.label)
        for _, d in ipairs(plan.removal_dirs) do lines[#lines + 1] = "  " .. d end
    else
        lines[1] = "Will reset " .. plan.label .. " to unconfigured "
            .. "(no build directories on disk; clearing cached state)."
    end
    return lines
end

--- The refusal of a non-interactive host without `-y` (exit 1).
--- @param plan loomworks.ResetPlan
--- @return string
function M.unconfirmed_message(plan)
    return "refusing to remove build directories without confirmation.\n"
        .. "  Re-run with -y to reset " .. plan.label .. "."
end

--- The confirmation question.
--- @param plan loomworks.ResetPlan
--- @return string
function M.prompt(plan)
    return "Reset " .. plan.label .. "? [y/N]"
end

--- A declined confirmation (exit 1).
M.ABORTED = "aborted — nothing was removed"

--- A confirmed plan that no longer matches (§19.15 "Reset", exit 1).
M.CHANGED = "the build directories to reset changed since they were listed — run lw reset again"

--- The success line.
--- @param plan loomworks.ResetPlan
--- @return string
function M.ok_line(plan)
    return "RESET OK: " .. plan.label
end

--- The failure of a deletion that did not complete in time (exit 1).
M.TIMED_OUT = "reset timed out — a build-directory deletion did not complete"

--- The failure of directories still on disk after the deletion (exit 1).
--- @param left string[] sorted
--- @return string
function M.failed_message(left)
    return string.format("reset failed — %d build director%s could not be removed:\n  %s",
        #left, (#left == 1) and "y" or "ies", table.concat(left, "\n  "))
end

--- Execute a planned reset (no prompt, no locks of its own beyond the
--- deletion's re-entrant ones: the caller holds the workspace operation lock
--- and the build-directory locks of `plan.lock_dirs`). Runs the deletion
--- (Profile:reset or Workspace:reset_all), then checks that every directory
--- of `plan.removal_dirs` is gone from disk, waiting out a delete-pending one
--- for `opts.verify_ms` — all without blocking (timers, never vim.wait).
--- `opts.stop` (the daemon's cancellation) is asked before each entry of the
--- removal; a stopped reset leaves the cache `unknown` for what it did not
--- finish (never reset after a partial removal, §4.7).
--- `done(code, message, stopped)` runs once: 0 on success; 1 and the line
--- the CLI prints (timed out / directories left); `stopped` when the removal
--- was stopped (nothing more to say). It runs from a scheduled callback or a
--- timer callback (fast context: hosts reschedule model work).
--- @param ws loomworks.Workspace
--- @param plan loomworks.ResetPlan
--- @param opts? { stop?: fun(): boolean, timeout_ms?: integer, verify_ms?: integer }
--- @param done fun(code: integer|nil, message: string|nil, stopped: boolean|nil)
function M.execute(ws, plan, opts, done)
    opts = opts or {}
    local stop = opts.stop
    local settled = false
    local function finish(code, msg, stopped)
        if settled then return end
        settled = true
        done(code, msg, stopped)
    end

    local timeout = uv.new_timer()
    local function close_timeout()
        if timeout and not timeout:is_closing() then timeout:stop(); timeout:close() end
    end
    timeout:start(opts.timeout_ms or M.TIMEOUT_MS, 0, function()
        close_timeout()
        finish(1, M.TIMED_OUT)
    end)

    local function verify()
        if stop and stop() then return finish(nil, nil, true) end
        local pending, any = {}, false
        for _, d in ipairs(plan.removal_dirs) do
            if uv.fs_stat(d) ~= nil then pending[d] = true; any = true end
        end
        local function report()
            local left = {}
            for d in pairs(pending) do left[#left + 1] = d end
            if #left == 0 then return finish(0) end
            table.sort(left)
            finish(1, M.failed_message(left))
        end
        if not any then return report() end
        -- Delete-pending: poll for genuine absence without blocking.
        local budget = opts.verify_ms or M.VERIFY_MS
        local waited, timer = 0, uv.new_timer()
        timer:start(20, 20, function()
            waited = waited + 20
            local left = false
            for d in pairs(pending) do
                if uv.fs_stat(d) == nil then pending[d] = nil else left = true end
            end
            if not left or waited >= budget then
                timer:stop()
                timer:close()
                report()
            end
        end)
    end

    local function on_settled()
        if settled then return end
        close_timeout()
        -- The disk decides, not the deletion's outcome (a removal can report
        -- success while the directory lingers, or fail having removed it).
        verify()
    end

    local f
    if plan.scope == "all" then
        f = ws:reset_all(nil, { stop = stop })
    else
        f = plan.profile:reset(nil, { stop = stop })
    end
    f:next(on_settled):catch(on_settled)
end

return M

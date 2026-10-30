-- Deletion plans (API.md §22 `Maintenance/1.execute_deletion`, spec §4.6,
-- §4.7, §19.3): what a deletion of one target would remove and which build
-- directories it must lock, the token a confirmation carries, the listing a
-- client shows, and the execution once the locks are held. Shared by the
-- command layer (loomworks.model_commands `execute_deletion`) and the
-- workspace daemon (step 5o part B5).
--
-- A target is exactly one of (objects resolved at the caller's input
-- boundary; never keys):
--   { profile = Profile }      the profile and the build dirs only it uses
--   { unit = ConfigUnit }      a unit's build dir and cached state
--   { build_dir = BuildDir }   an orphaned build directory
--   { stray_dir = string }     a stray build directory (a path)
--   { orphans = true }         every orphaned and stray build directory
--   { project = Project }      its build state, then its declaration, then
--                              its profiles' toolchain downgrade
--
-- Deletion safety (project CLAUDE.md): this module never removes anything
-- itself. The plan is computed after resolution and before any lock; the
-- caller takes the workspace operation lock, then the build-directory lock of
-- every directory of `plan.lock_dirs` (exclusive, canonical order:
-- `Workspace:_locked_deletion`), applies external changes (`M.resync`) and
-- plans again (`M.verify`): a different token is refused before anything is
-- removed, so a deletion never removes a directory the user was not shown
-- (never wider than the listing). The execution then goes through the
-- Workspace's deletion paths (`_execute_deletion_unlocked`, `_run_deletion`,
-- `_delete_orphan_unlocked`, `_delete_build_dirs_async`): every path
-- validated against the workspace root (separator-bounded), the cache
-- `unknown` on disk before a tree is removed and reset only after success,
-- shared directories and directories holding a live build dir kept.

local M = {}

local uv = vim.uv or vim.loop

--- The token family of a deletion plan (never equal to a reset token).
M.KIND = "delete-plan/1"

--- A confirmed plan that no longer matches (API.md §22, exit 1).
M.CHANGED = "the build directories to delete changed since they were listed"

--- A plan with nothing to delete (API.md §22: exit 0, `stream = "out"`).
M.NOTHING = "nothing to delete"

--- @class loomworks.DeletionTargetPlan
--- @field kind "profile"|"unit"|"build_dir"|"stray_dir"|"orphans"|"project"
--- @field target table the target as given (its objects)
--- @field scope_key string what the token covers besides the directories
--- @field label string the target as the listing names it
--- @field refusal string|nil why the target cannot be deleted (stale object,
---   a stray dir not in the current stray set or outside the workspace):
---   the caller refuses, nothing else in the plan is meaningful
--- @field deletion loomworks.DeletionPlan|nil the unit / profile plan
---   (`plan_deletion`) the execution runs
--- @field items table[] the deletion items (listing; project / orphans)
--- @field kept table[] items kept because another profile uses them
--- @field orphans table[] orphaned entries (kind "orphans"):
---   `{ project_key, config_key, state, build_dir, build_dir_obj }`
--- @field strays string[] stray directories (kinds "stray_dir", "orphans")
--- @field build_dir_obj loomworks.BuildDir|nil (kind "build_dir")
--- @field downgrade table[] the profile renames of a project removal
--- @field lock_dirs string[] normalized dirs the deletion locks: every
---   targeted dir under the workspace root (`_validate_build_dir`)
--- @field removal_dirs string[] the lock dirs present on disk
--- @field outside_dirs string[] targeted dirs on disk the deletion refuses
---   (outside the workspace root): never removed, listed as such
--- @field state_to_clear boolean cached state is cleared even with no dir
--- @field token string the plan token (`M.token`)

--- Under a deletion's locks: apply external changes to the workspace files
--- (`FileTracker:sync`) so the re-checks see what other processes wrote
--- since the deletion was planned. Applying a change can reload the
--- workspace (spec §17.4): returns false when this one is then gone — it
--- must delete nothing (its cache writes are no-ops, so the `unknown` marks
--- would never reach the disk, §5.7).
--- @param ws loomworks.Workspace
--- @return boolean alive
function M.resync(ws)
    if ws._tracker then ws._tracker:sync() end
    return not ws._torn_down
end

--- The directories among `dirs` that are STILL stray
--- (`Workspace:find_stray_build_dirs`). The list was computed before the
--- locks were taken, and another process may have configured into a
--- directory since; a directory no longer stray is kept (reported). Compared
--- by directory identity, not spelling (8.3 short vs long on Windows): exact
--- equality of canonical forms, never a prefix. Never a dir that IS,
--- CONTAINS or lies INSIDE a live build dir (#293).
--- @param ws loomworks.Workspace
--- @param dirs string[]
--- @return string[]
function M.recheck_stray(ws, dirs)
    if #dirs == 0 then return {} end
    local function canon(p) return ws:_canonicalize_boundary_path(p) end
    local current = {}
    for _, d in ipairs(ws:find_stray_build_dirs()) do current[canon(d)] = true end
    local known = ws:_live_build_dir_forms()
    local out = {}
    for _, d in ipairs(dirs) do
        if not current[canon(d)] then
            ws._core._deps.notify("loomworks: kept " .. d .. " — no longer a stray build directory",
                vim.log.levels.INFO)
        elseif ws:_overlaps_live_build_dir(d, known) then
            ws._core._deps.notify("loomworks: refusing to delete stray dir holding a live build dir: " .. d,
                vim.log.levels.ERROR)
        else
            out[#out + 1] = d
        end
    end
    return out
end

--- The orphaned configurations among `orphans` that are STILL orphaned
--- (`Workspace:get_orphaned_configs`, same BuildDir and directory). Another
--- process may have re-adopted one since the cleanup was planned; it is kept
--- (reported) — neither its tree nor its BuildDir is touched.
--- @param ws loomworks.Workspace
--- @param orphans table[]
--- @return table[]
function M.recheck_orphans(ws, orphans)
    if #orphans == 0 then return {} end
    local function canon(p) return ws:_canonicalize_boundary_path(p) end
    local current = {}
    for _, o in ipairs(ws:get_orphaned_configs()) do
        if o.build_dir_obj then current[o.build_dir_obj] = true end
    end
    local out = {}
    for _, item in ipairs(orphans) do
        local bd = item.build_dir_obj
        local same_dir = bd and (item.build_dir == nil or bd.path == nil
            or canon(bd.path) == canon(item.build_dir))
        if bd and current[bd] and same_dir then
            out[#out + 1] = item
        else
            ws._core._deps.notify("loomworks: kept " .. tostring(item.build_dir or item.config_key)
                .. " — no longer an orphaned configuration", vim.log.levels.INFO)
        end
    end
    return out
end

--- Whether no ConfigUnit references `bd` (it is still an orphan).
--- @param ws loomworks.Workspace
--- @param bd loomworks.BuildDir
--- @return boolean
local function still_orphaned(ws, bd)
    for _, unit in pairs(ws._config_units) do
        if unit._build_dir == bd then return false end
    end
    return true
end

--- Orphan cleanup without the locks (the caller holds them, and has applied
--- external changes, `M.resync`): delete the build dirs of the orphaned
--- configurations still orphaned now (`M.recheck_orphans`) and drop their
--- BuildDir objects, then delete the stray dirs still stray now
--- (`M.recheck_stray`).
--- The orphans go through `Workspace:_run_deletion` like every cache-backed
--- deletion (spec §4.6, §5.7): their entries are marked `unknown` on disk
--- before any tree is removed, a directory a live configuration still
--- references is kept (the shared-dir refs check, plus
--- `Workspace:_overlaps_live_build_dir`), and the entries are dropped only
--- when every removal succeeded — a failed removal keeps them (`unknown`,
--- reported). `opts.stop` is asked before each entry (no stray dir is
--- started once it says stop).
--- Returns a Future resolving `true` when everything was removed, `false`
--- when a removal failed or was stopped.
--- @param ws loomworks.Workspace
--- @param orphaned_configs table[]
--- @param stray_dirs string[]
--- @param opts? { stop?: fun(): boolean }
--- @return loomworks.Future
function M.orphan_cleanup_unlocked(ws, orphaned_configs, stray_dirs, opts)
    local stop = opts and opts.stop or nil
    local safe_prefix = ws._core._deps.normalize(ws.root)
    orphaned_configs = M.recheck_orphans(ws, orphaned_configs)
    stray_dirs = M.recheck_stray(ws, stray_dirs)

    local items = {}
    for _, item in ipairs(orphaned_configs) do
        items[#items + 1] = {
            project_key = item.project_key, config_key = item.config_key,
            build_dir = item.build_dir, build_dir_obj = item.build_dir_obj,
            disposition = "clean",
        }
    end

    local function remove_build_dir_objects()
        -- Remove BuildDir objects and clear their state — only those still
        -- orphaned (a unit may have adopted one while the removal ran).
        local deploy = require("loomworks.deploy")
        for _, item in ipairs(orphaned_configs) do
            local bd = item.build_dir_obj
            if bd and still_orphaned(ws, bd) then
                deploy.clean_deploy_records(ws._deploy_records, bd.rel_path)
                bd:clear_state()
                for i, b in ipairs(ws._build_dirs) do
                    if b == bd then
                        table.remove(ws._build_dirs, i)
                        break
                    end
                end
            end
        end
        ws:_save_cache()
        ws:_sync_build_dir_refs()
        ws._core._deps.events.emit("active_set_changed", ws._active_set)
    end

    local valid_stray = {}
    for _, dir in ipairs(stray_dirs) do
        if ws:_validate_build_dir(dir, safe_prefix) then
            valid_stray[#valid_stray + 1] = dir
        end
    end

    -- (No orphans: `_run_deletion` resolves `true` at once.)
    return ws:_run_deletion(items, remove_build_dir_objects, nil, nil, stop and { stop = stop } or nil)
        :next(function(orphans_ok)
            if stop and stop() then valid_stray = {} ; orphans_ok = false end
            return ws:_delete_build_dirs_async(valid_stray, nil, stop and { stop = stop } or nil)
                :next(function(results)
                    local ok = orphans_ok ~= false
                    for _, r in ipairs(results) do
                        if not r.ok then
                            ok = false
                            if not r.stopped then
                                ws._core._deps.notify("loomworks: failed to delete " .. r.dir .. ": "
                                    .. (r.err or "unknown"), vim.log.levels.ERROR)
                            end
                        end
                    end
                    return ok
                end)
        end)
end

--- The configurations of `project` with cached build state (the build state
--- a project removal deletes), sorted by configuration key.
--- @param ws loomworks.Workspace
--- @param project loomworks.Project
--- @return { config_key: string, state: string|nil, build_dir: string|nil, unit: loomworks.ConfigUnit }[]
function M.project_configs(ws, project)
    local items = {}
    for _, unit in pairs(ws._config_units) do
        if unit._project == project and unit._config_key then
            items[#items + 1] = {
                config_key = unit._config_key,
                state = unit.state_value,
                build_dir = unit.build_dir_value,
                unit = unit,
            }
        end
    end
    table.sort(items, function(a, b) return a.config_key < b.config_key end)
    return items
end

--- The orphaned configurations as the cleanup handles them.
--- @param ws loomworks.Workspace
--- @return table[]
function M.orphaned_entries(ws)
    local out = {}
    for _, o in ipairs(ws:get_orphaned_configs()) do
        local entry = o.cached_entry or {}
        out[#out + 1] = {
            project_key = o.project_key,
            config_key = o.config_key,
            state = entry.state or nil,
            build_dir = entry.build_dir or (o.build_dir_obj and o.build_dir_obj.path) or nil,
            build_dir_obj = o.build_dir_obj,
        }
    end
    return out
end

--- Whether `x` is one of the values of `list` (identity).
local function member(list, x)
    for _, v in pairs(list or {}) do if v == x then return true end end
    return false
end

local function unit_keys(unit)
    local pk = unit._project and unit._project.key or unit._init_project_key or "?"
    local ck = unit.config_key and unit:config_key() or unit._config_key or "?"
    return tostring(pk), tostring(ck)
end

--- The plan token: `reset_plan.token` (shared) in the deletion family.
--- @param scope_key string
--- @param lock_dirs string[]
--- @param removal_dirs string[]
--- @param outside_dirs? string[]
--- @return string
function M.token(scope_key, lock_dirs, removal_dirs, outside_dirs)
    return require("loomworks.reset_plan").token(scope_key, lock_dirs, removal_dirs, outside_dirs, M.KIND)
end

--- Plan the deletion of `target`. Pure with respect to the workspace
--- (nothing is changed, nothing locked); it stats the build directories to
--- tell which exist and scans `.nvim/build` for stray directories.
--- @param ws loomworks.Workspace
--- @param target table exactly one of the targets of the module header
--- @return loomworks.DeletionTargetPlan
function M.plan(ws, target)
    local norm = ws._core._deps.normalize
    local root_n = norm(ws.root)
    local plan = {
        target = target, items = {}, kept = {}, orphans = {}, strays = {}, downgrade = {},
        lock_dirs = {}, removal_dirs = {}, outside_dirs = {}, state_to_clear = false,
    }
    local seen = {}
    local function add_dir(d)
        if not d then return end
        local n = norm(d)
        if seen[n] then return end
        seen[n] = true
        if ws:_validate_build_dir(n, root_n, { quiet = true }) then
            plan.lock_dirs[#plan.lock_dirs + 1] = n
            if uv.fs_stat(n) ~= nil then plan.removal_dirs[#plan.removal_dirs + 1] = n end
        elseif uv.fs_stat(n) ~= nil then
            plan.outside_dirs[#plan.outside_dirs + 1] = n
        end
    end
    local function refuse(msg)
        plan.refusal = msg
        plan.token = M.token(plan.scope_key or "refused", {}, {}, {})
        return plan
    end
    -- A unit / profile deletion plan's items: kept ones listed, the others
    -- targeted (their dir locked, removed when present, state cleared).
    local function take_items(items)
        for _, item in ipairs(items) do
            if item.disposition == "keep" then
                plan.kept[#plan.kept + 1] = item
            else
                plan.items[#plan.items + 1] = item
                add_dir(item.build_dir)
                if item.unit and item.unit.state_value ~= nil then plan.state_to_clear = true end
            end
        end
    end

    local n_kinds = 0
    for _, k in ipairs({ "profile", "unit", "build_dir", "stray_dir", "orphans", "project" }) do
        if target[k] ~= nil and target[k] ~= false then n_kinds = n_kinds + 1; plan.kind = k end
    end
    if n_kinds ~= 1 then
        plan.kind = plan.kind or "none"
        return refuse("a deletion target is exactly one of profile, unit, build_dir, stray_dir, orphans, project")
    end

    if plan.kind == "profile" then
        local profile = target.profile
        plan.scope_key = "profile:" .. tostring(profile.key)
        plan.label = "profile '" .. tostring(profile.key) .. "'"
        if profile._removed or not member(ws._profiles, profile) then
            return refuse(plan.label .. " has been removed")
        end
        plan.deletion = profile:plan_deletion()
        take_items(plan.deletion.items)
        plan.state_to_clear = true -- the profile itself goes
    elseif plan.kind == "unit" then
        local unit = target.unit
        local pk, ck = unit_keys(unit)
        plan.scope_key = "unit:" .. pk .. "/" .. ck
        plan.label = "configuration '" .. pk .. " / " .. ck .. "'"
        if unit._removed or not member(ws._config_units, unit) then
            return refuse(plan.label .. " has been removed")
        end
        plan.deletion = unit:plan_deletion()
        take_items(plan.deletion.items)
    elseif plan.kind == "build_dir" then
        local bd = target.build_dir
        plan.scope_key = "build_dir:" .. tostring(bd.rel_path)
        plan.label = "orphaned build directory '" .. tostring(bd.project_key or "?") .. " / "
            .. tostring(bd.config_key or bd.variant or "?") .. "'"
        local orphaned = false
        for _, o in ipairs(ws:get_orphaned_configs()) do
            if o.build_dir_obj == bd then orphaned = true; break end
        end
        if not orphaned then return refuse(tostring(bd.path or bd.rel_path) .. " is not an orphaned build directory") end
        plan.build_dir_obj = bd
        add_dir(bd.path)
        plan.state_to_clear = true
    elseif plan.kind == "stray_dir" then
        local dir = norm(tostring(target.stray_dir))
        plan.scope_key = "stray_dir:" .. dir
        plan.label = "stray build directory " .. dir
        if not ws:_validate_build_dir(dir, root_n, { quiet = true }) then
            return refuse("path outside workspace: " .. dir)
        end
        -- The server's current stray set, by directory identity (exact
        -- canonical equality, never a prefix); the scan's spelling is the
        -- one deleted.
        local canon = ws:_canonicalize_boundary_path(dir)
        local found
        for _, d in ipairs(ws:find_stray_build_dirs()) do
            if ws:_canonicalize_boundary_path(d) == canon then found = d; break end
        end
        if not found then return refuse("not a stray build directory: " .. dir) end
        if ws:_overlaps_live_build_dir(found) then
            return refuse("directory holds a live build dir: " .. dir)
        end
        plan.strays = { found }
        add_dir(found)
    elseif plan.kind == "orphans" then
        plan.scope_key = "orphans"
        plan.label = "every orphaned and stray build directory"
        plan.orphans = M.orphaned_entries(ws)
        for _, o in ipairs(plan.orphans) do
            add_dir(o.build_dir)
            plan.state_to_clear = true
        end
        local known = ws:_live_build_dir_forms()
        for _, d in ipairs(ws:find_stray_build_dirs()) do
            if not ws:_overlaps_live_build_dir(d, known) then
                plan.strays[#plan.strays + 1] = d
                add_dir(d)
            end
        end
    else -- project
        local project = target.project
        plan.scope_key = "project:" .. tostring(project.key)
        plan.label = "project '" .. tostring(project.key) .. "'"
        if project._removed or not member(ws._projects, project) then
            return refuse(plan.label .. " has been removed")
        end
        for _, item in ipairs(M.project_configs(ws, project)) do
            item.disposition = "clean"
            plan.items[#plan.items + 1] = item
            add_dir(item.build_dir)
        end
        plan.downgrade = ws:compute_downgrade_preview(project) or {}
        plan.state_to_clear = true -- the declaration itself goes
    end

    plan.token = M.token(plan.scope_key, plan.lock_dirs, plan.removal_dirs, plan.outside_dirs)
    return plan
end

--- Does the plan delete nothing (no directory, no state, no declaration)?
--- @param plan loomworks.DeletionTargetPlan
--- @return boolean
function M.is_empty(plan)
    return #plan.removal_dirs == 0 and #plan.outside_dirs == 0 and not plan.state_to_clear
end

--- The configuration units whose build state `plan` removes: the live unit
--- of each targeted item, in item order, once each (a kept item is in
--- `plan.kept`, never here; none for an orphaned or stray directory or
--- `orphans`). A matcher for a client's own tasks only (the confirm's
--- `unit_ids`, API.md §22): what is deleted is decided by the plan alone.
--- @param plan loomworks.DeletionTargetPlan
--- @return loomworks.ConfigUnit[]
function M.units(plan)
    local out, seen = {}, {}
    for _, item in ipairs(plan.items or {}) do
        local u = item.unit
        if u and not u._removed and not seen[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    return out
end

--- Is `plan` still what a fresh plan of its target says? Called with the
--- operation lock and every build-directory lock of `plan.lock_dirs` held,
--- after `M.resync`, before anything is removed. Returns the fresh plan (the
--- one to execute: the same directories, the objects as they are now).
--- @param ws loomworks.Workspace
--- @param plan loomworks.DeletionTargetPlan
--- @return loomworks.DeletionTargetPlan|nil fresh, string|nil refusal
function M.verify(ws, plan)
    local fresh = M.plan(ws, plan.target)
    if fresh.refusal then return nil, fresh.refusal end
    if fresh.token ~= plan.token then return nil, M.CHANGED end
    return fresh
end

--- The path of `dir` relative to the workspace root, for the listing.
local function rel(ws, dir)
    if not dir then return nil end
    local norm = ws._core._deps.normalize
    local r, d = norm(ws.root), norm(dir)
    if d:sub(1, #r + 1) == r .. "/" then return d:sub(#r + 2) end
    return dir
end

--- The listing a client shows before the confirmation (and the task prints
--- first when no token was sent).
--- @param ws loomworks.Workspace
--- @param plan loomworks.DeletionTargetPlan
--- @return string[]
function M.listing(ws, plan)
    local lines = { "Delete " .. plan.label .. ":" }
    local function add(s) lines[#lines + 1] = s end
    local function unit_line(item)
        local pk, ck
        if item.unit then pk, ck = unit_keys(item.unit) end
        pk = pk or item.project_key or "?"
        ck = ck or item.config_key or "?"
        local d = item.build_dir and rel(ws, item.build_dir)
        return "  " .. pk .. " / " .. ck .. (d and ("  " .. d) or "")
    end
    local clean, reset = {}, {}
    for _, item in ipairs(plan.items) do
        if item.disposition == "reset" then reset[#reset + 1] = item else clean[#clean + 1] = item end
    end
    if #clean > 0 then
        add("Will remove:")
        for _, item in ipairs(clean) do add(unit_line(item)) end
    end
    if #reset > 0 then
        add("Will reset to unconfigured:")
        for _, item in ipairs(reset) do add(unit_line(item)) end
    end
    if #plan.kept > 0 then
        add("Will keep (referenced by another profile):")
        for _, item in ipairs(plan.kept) do add(unit_line(item)) end
    end
    if plan.build_dir_obj then
        add("Will remove:")
        add(unit_line({ project_key = plan.build_dir_obj.project_key,
            config_key = plan.build_dir_obj.config_key or plan.build_dir_obj.variant,
            build_dir = plan.build_dir_obj.path }))
    end
    if #plan.orphans > 0 then
        add("Orphaned configurations (" .. #plan.orphans .. "):")
        for _, o in ipairs(plan.orphans) do add(unit_line(o)) end
    end
    if #plan.strays > 0 then
        add("Stray build directories (" .. #plan.strays .. "):")
        for _, d in ipairs(plan.strays) do add("  " .. rel(ws, d)) end
    end
    if #plan.outside_dirs > 0 then
        add(string.format(
            "Not removed — %d build director%s outside the workspace (only the cached state is cleared):",
            #plan.outside_dirs, (#plan.outside_dirs == 1) and "y" or "ies"))
        for _, d in ipairs(plan.outside_dirs) do add("  " .. d) end
    end
    if plan.kind == "project" then
        add("Removes the project from the configuration.")
        if #plan.downgrade > 0 then
            add("Profiles to rename:")
            for _, r in ipairs(plan.downgrade) do add("  " .. r.old_key .. " → " .. r.new_key) end
        end
    end
    return lines
end

--- @class loomworks.DeletionResult
--- @field ok boolean every planned removal and write succeeded
--- @field stopped boolean|nil the stop predicate ended it between entries
--- @field message string|nil what failed (ok false, not stopped)
--- @field warn string|nil a later step of a composite that failed after the
---   deletion committed (a project's downgrade)

--- Execute a verified plan (`M.verify`'s fresh plan). The caller holds the
--- workspace operation lock and the build-directory locks of
--- `plan.lock_dirs`; the Workspace's deletion paths re-validate every path.
--- `opts.stop` is asked between entries. Returns a Future resolving to a
--- `loomworks.DeletionResult`.
--- @param ws loomworks.Workspace
--- @param plan loomworks.DeletionTargetPlan
--- @param opts? { stop?: fun(): boolean }
--- @return loomworks.Future
function M.execute(ws, plan, opts)
    local future_mod = require("loomworks.future")
    local stop = opts and opts.stop or nil
    local function result(ok, message)
        if not ok and stop and stop() then return { ok = false, stopped = true } end
        return { ok = ok == true, message = (not ok) and (message or "a build directory was not removed (see the log)") or nil }
    end
    local f
    if plan.kind == "profile" then
        f = ws:_execute_deletion_unlocked(plan.deletion,
            { deactivate_profile = plan.target.profile, stop = stop })
    elseif plan.kind == "unit" then
        f = ws:_execute_deletion_unlocked(plan.deletion, { stop = stop })
    elseif plan.kind == "build_dir" then
        f = ws:_delete_orphan_unlocked(plan.build_dir_obj, nil, { stop = stop })
    elseif plan.kind == "stray_dir" then
        local dir = plan.strays[1]
        if stop and stop() then return future_mod.resolved({ ok = false, stopped = true }) end
        if not ws:_validate_build_dir(dir, ws._core._deps.normalize(ws.root)) then
            return future_mod.resolved({ ok = false, message = "path outside workspace: " .. dir })
        end
        f = ws:_delete_build_dirs_async({ dir }, nil, stop and { stop = stop } or nil):next(function(results)
            local r = results[1]
            if r and r.ok then
                ws._core._deps.events.emit("deletion_completed", {})
                return true
            end
            -- The removal's own error reaches the log (as `_run_deletion`
            -- reports one); a stopped removal is the caller's to report.
            if r and not r.stopped then
                ws._core._deps.notify("loomworks: failed to delete " .. tostring(r.dir or dir) .. ": "
                    .. tostring(r.err or "unknown"), vim.log.levels.ERROR)
            end
            return false
        end)
    elseif plan.kind == "orphans" then
        f = M.orphan_cleanup_unlocked(ws, plan.orphans, plan.strays, { stop = stop })
    else -- project
        local project = plan.target.project
        local mod_type = project.type
        local items = plan.items
        f = ws:_run_deletion(items, function()
            ws:delete_cached_configs(items)
            ws:_save_cache()
            ws:remerge()
        end, nil, nil, stop and { stop = stop } or nil):next(function(deleted)
            -- The declaration goes only after its build state did: a failed or
            -- stopped removal keeps the project (its entries `unknown`).
            if deleted == false then return result(false) end
            local rok, rerr = ws:remove_project(project)
            if not rok then return { ok = false, message = tostring(rerr or "the project was not removed") } end
            if #plan.downgrade > 0 then
                local d_ok, d_err = ws:downgrade_profiles_from_tool(mod_type)
                if d_ok == false then
                    return { ok = true, warn = "project removed, but its profiles were not downgraded: "
                        .. tostring(d_err) }
                end
            end
            return { ok = true }
        end)
        return f
    end
    return f:next(function(v) return result(v ~= false) end)
end

return M

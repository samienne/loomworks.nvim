--- loomworks/model_commands.lua — the model's commands, host-neutral.
---
--- One function per user action that changes the model (spec §19.14 "As
--- interfaces", §19.16 "Model writes"; API.md §6, §11, §19–§21): the
--- in-process editor (through workspace_view) and the daemon's interface
--- handlers (step 5o parts B) call the same function. Each takes resolved
--- domain objects — never keys: a caller resolves a reference (an id, or a
--- name a user or a file supplied) once at its input boundary — plus plain
--- arguments, and answers an outcome (API.md §4.1):
---
---   { outcome = "ok", notes?, note_roles?, <created entity>? }
---   { outcome = "refused", message, exit_code }  -- nothing written
---
--- A composite action (one user action in several model writes) whose later
--- step fails after the first was committed is `ok` with a `warn` note
--- naming what was not done (decision D1). A removed object (a stale
--- reference the caller still holds) is refused before any write.
---
--- Deletions (`Maintenance/1.execute_deletion`, API.md §22) are planned
--- and confirmed with a token (loomworks.deletion_plan) and run under the
--- workspace operation lock and the build-directory locks
--- (`Workspace:_locked_deletion`). Locks: single-file working-copy writes take only the save
--- guard of `_save_user` (spec §2.7); the operation lock of publish and
--- propagating renames (spec §19.3) is taken where the Workspace methods
--- take it.

local M = {}

-- ---------------------------------------------------------------------------
-- Outcomes
-- ---------------------------------------------------------------------------

--- @class loomworks.CommandOutcome
--- @field outcome "ok"|"refused"
--- @field message string|nil the refusal (outcome "refused")
--- @field exit_code integer|nil 1 for a state refusal, 2 for a usage error
--- @field notes string[]|nil lines written for the call (outcome "ok")
--- @field note_roles string[]|nil each note's role by index ("warn", ...)

--- @param fields table|nil extra result fields (a created entity, ...)
--- @return loomworks.CommandOutcome
local function ok(fields)
    local r = { outcome = "ok" }
    for k, v in pairs(fields or {}) do r[k] = v end
    return r
end

--- @param message any
--- @param code integer|nil exit code (default 1)
--- @return loomworks.CommandOutcome
local function refused(message, code)
    return { outcome = "refused", message = tostring(message or "refused"), exit_code = code or 1 }
end
M.refused = refused

--- Add a `warn` note to an outcome.
--- @param r loomworks.CommandOutcome
--- @param line string
local function warn(r, line)
    r.notes = r.notes or {}
    r.note_roles = r.note_roles or {}
    r.notes[#r.notes + 1] = line
    r.note_roles[#r.notes] = "warn"
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

--- The kind of a domain object, as a message names it.
--- @param item table
--- @return string
local function kind_of(item)
    local mt = getmetatable(item)
    if mt == require("loomworks.profile").Profile then return "profile" end
    if mt == require("loomworks.configuration_set") then return "configuration set" end
    if mt == require("loomworks.project") then return "project" end
    if mt == require("loomworks.configuration") then return "configuration" end
    if mt == require("loomworks.launch_configuration") then return "launch configuration" end
    return "item"
end

--- Whether `item` is a LaunchConfiguration.
local function is_launch(item)
    return getmetatable(item) == require("loomworks.launch_configuration")
end

--- The display name of an item.
local function name_of(item)
    if is_launch(item) or getmetatable(item) == require("loomworks.configuration") then
        return (item._project and (item._project.key .. (is_launch(item) and ":" or "/")) or "")
            .. tostring(item.name)
    end
    return tostring(item.key or item.name)
end

--- Whether the object (or the project that owns it) has been removed.
local function removed(item)
    if item == nil then return true end
    if item._removed then return true end
    local owner = item._project
    return owner ~= nil and owner._removed == true
end

--- nil when `item` is live, else the refusal.
--- @param item table|nil
--- @param kind string|nil the expected kind, for a nil item
--- @return loomworks.CommandOutcome|nil
local function stale(item, kind)
    if item == nil then return refused("no " .. (kind or "item") .. " given", 2) end
    if removed(item) then
        return refused(kind_of(item) .. " '" .. name_of(item) .. "' has been removed")
    end
    return nil
end

--- nil when every Project and Configuration of `mappings` is live, else the
--- refusal: a set is never written with a mapping to a removed object.
--- @param mappings table<loomworks.Project, loomworks.Configuration|false|nil>|nil
--- @return loomworks.CommandOutcome|nil
local function stale_mappings(mappings)
    for project, cfg in pairs(mappings or {}) do
        local r = stale(project, "project") or (cfg and stale(cfg, "configuration")) or nil
        if r then return r end
    end
    return nil
end

--- The workspace an item belongs to.
local function workspace_of(item)
    if item._workspace then return item._workspace end
    local p = item._project
    return p and p._workspace or nil
end

--- The status page's re-render signal after a working-copy edit made here
--- (what the in-process paths emitted inline).
local function signal_changed(ws)
    local core = ws and ws._core
    local events = core and core._deps and core._deps.events
    if events then events.emit("active_set_changed", ws._active_set) end
end

-- ---------------------------------------------------------------------------
-- Workspace/1 (API.md §6)
-- ---------------------------------------------------------------------------

--- `publish {}` — regenerate loomworks.json from the working copy (`:w`).
--- @param ws loomworks.Workspace
--- @return loomworks.CommandOutcome
function M.publish(ws)
    local done, err = ws:publish()
    if not done then return refused("publish failed: " .. tostring(err or "unknown")) end
    return ok()
end

--- `revert_to_baseline {}` — the working copy back to the published
--- baseline (`:e!`).
--- @param ws loomworks.Workspace
--- @return loomworks.CommandOutcome
function M.revert_to_baseline(ws)
    local done, err = ws:revert_to_baseline()
    if not done then return refused("revert failed: " .. tostring(err or "unknown")) end
    return ok()
end

--- A launch configuration has no publish state of its own (API.md §6).
local function launch_publish_refusal(item)
    if not is_launch(item) then return nil end
    return refused("a launch configuration is published with its project "
        .. tostring(item._project and item._project.key))
end

--- `publish_one { item }` — publish one profile, configuration set, project
--- or configuration.
--- @param item table
--- @return loomworks.CommandOutcome
function M.publish_one(item)
    local r = stale(item) or launch_publish_refusal(item)
    if r then return r end
    local done, err = workspace_of(item):publish_one(item)
    if not done then return refused("publish failed: " .. tostring(err or "unknown")) end
    return ok()
end

--- `revert_one { item }` — one item back to its published baseline.
--- @param item table
--- @return loomworks.CommandOutcome
function M.revert_one(item)
    local r = stale(item) or launch_publish_refusal(item)
    if r then return r end
    local done, err = workspace_of(item):revert_one(item)
    if not done then return refused("revert failed: " .. tostring(err or "unknown")) end
    return ok()
end

local INTENTS = { ["local"] = true, shared = true, ["local+shared"] = true }

--- `set_intent { item, intent }` — the item's intent, recorded as the user's
--- choice (spec §2.4, sticky). A failed save restores it.
--- @param item table
--- @param intent "local"|"shared"|"local+shared"
--- @return loomworks.CommandOutcome
function M.set_intent(item, intent)
    local r = stale(item) or launch_publish_refusal(item)
    if r then return r end
    if not INTENTS[intent] then
        return refused("unknown intent '" .. tostring(intent) .. "' (local, shared or local+shared)", 2)
    end
    local ws = workspace_of(item)
    local old = item._intent
    item._intent = intent
    local saved, err, reason = ws:_save_user()
    if not saved then
        -- A stale refusal reloaded from disk: undoing would overwrite it.
        if reason ~= "stale" then item._intent = old end
        return refused(err or "user.json was not written")
    end
    signal_changed(ws)
    return ok()
end

--- `set_description { item, text? }` — the item's description (spec §1.10),
--- a launch configuration included; no text removes it. `changed` is false
--- when the description was already that.
--- @param item table
--- @param text string|nil
--- @return loomworks.CommandOutcome
function M.set_description(item, text)
    local r = stale(item)
    if r then return r end
    local changed, err = item:set_description(text)
    if changed == nil then return refused(err or "the description was not saved") end
    return ok({ changed = changed and true or false })
end

-- ---------------------------------------------------------------------------
-- Workspace/1: the working copy's trust (API.md §6; spec §17.4, §17.10)
-- ---------------------------------------------------------------------------

--- The refusal of a confirmation whose plan no longer matches the file.
M.PLAN_CHANGED = "the working copy changed since it was shown — review it again"

--- The token of what a confirmation showed: the working copy's path and
--- its exact content.
--- @param path string
--- @param content string
--- @return string
local function prefs_plan(path, content)
    return vim.fn.sha256(path .. "\0" .. content)
end

--- The review of a working copy this machine did not sign (spec §17.4), as
--- the trust prompt shows it: its path and status, then its program-bearing
--- fields first and its other contents.
--- @param review table `Core:review_user_prefs`'s `{ path, status, data }`
--- @return string[]
function M.trust_review_lines(review)
    local prog, other = require("loomworks.program_fields").review(review.data, require("loomworks.modules"))
    local lines = {
        review.path,
        review.status == "unsigned"
            and "is not signed by this machine (written by hand, or by an earlier loomworks)."
            or "was modified outside loomworks, or copied from another machine.",
        "",
        "Program settings — what loomworks may run on this file's word:",
    }
    if #prog == 0 then lines[#lines + 1] = "  (none)" end
    for _, l in ipairs(prog) do lines[#lines + 1] = "  " .. l end
    lines[#lines + 1] = "Other contents:"
    for _, l in ipairs(other) do lines[#lines + 1] = "  " .. l end
    return lines
end

--- `trust_accept { plan? }` — the review & trust of spec §17.4. Without
--- `plan`: `confirm` with the review and a token of exactly that content;
--- with it: the working copy is signed as shown (`Core:trust_user_prefs`,
--- which loads the workspace again), or refused when it changed since. An
--- already trusted working copy is `ok` with a note; none is refused.
--- `reloaded` in the result: the core was put through setup again (a host
--- serving the model adopts that load; it is not part of the reply).
--- @param core loomworks.Core
--- @param root string
--- @param plan string|nil
--- @return loomworks.CommandOutcome|{ outcome: "confirm", lines: string[], plan: string }
function M.trust_accept(core, root, plan)
    local review, rerr = core:review_user_prefs(root)
    if not review then return refused(rerr) end
    if review.status == "valid" then
        local r = ok()
        r.notes = { ".nvim/loomworks.user.json is already trusted (signed by this machine)" }
        r.note_roles = { "plain" }
        return r
    end
    local token = prefs_plan(review.path, review.content)
    if plan == nil then
        return { outcome = "confirm", lines = M.trust_review_lines(review), plan = token }
    end
    if plan ~= token then return refused(M.PLAN_CHANGED) end
    local done, err = core:trust_user_prefs(root, review.content)
    if not done then return refused(err or "the working copy was not signed") end
    return ok({ reloaded = true })
end

--- `delete_user_prefs { plan? }` — remove the working copy and its backup
--- (spec §17.10; `Core:delete_user_prefs`: the operation lock, the `.nvim`
--- path check, then a reload), confirmed as `trust_accept` is: the token
--- covers the file's exact text, so a file changed since it was shown is
--- refused.
--- @param core loomworks.Core
--- @param root string
--- @param plan string|nil
--- @return loomworks.CommandOutcome|{ outcome: "confirm", lines: string[], plan: string }
function M.delete_user_prefs(core, root, plan)
    local deps = core._deps
    local path = deps.user.filepath(deps.normalize(root))
    local text = deps.io.read_file(path)
    if not text then return refused("no working copy (" .. path .. ") — nothing to delete") end
    local token = prefs_plan(path, text)
    if plan == nil then
        return { outcome = "confirm", plan = token,
            lines = { "Will delete " .. path .. " (the working copy: profiles, local configuration, settings)." } }
    end
    if plan ~= token then return refused(M.PLAN_CHANGED) end
    -- The confirmed text is checked again under the operation lock (it may
    -- change between the check above and the lock); a held lock is refused
    -- naming its holder.
    local done, derr, kind = core:delete_user_prefs(root, text)
    if not done then
        return refused(kind == "changed" and M.PLAN_CHANGED or derr or "the working copy was not deleted")
    end
    if deps.io.read_file(path) ~= nil then return refused("the working copy was not deleted") end
    return ok({ reloaded = true })
end

-- ---------------------------------------------------------------------------
-- Profiles/1 (API.md §11)
-- ---------------------------------------------------------------------------

--- The intent (and source) of each item Profile:activate's cascade
--- materializes into the working copy (the profile, its set, the set's
--- projects and configurations), to put back when nothing was written
--- (API.md §11: a refused write changes neither user.json nor the model).
--- @param profile loomworks.Profile
--- @return table[] snapshot
local function activation_intents(profile)
    local items = { profile }
    local cs = profile._config_set_ref
    if cs then
        items[#items + 1] = cs
        for project, cfg in pairs(cs.mappings or {}) do
            if type(project) == "table" then items[#items + 1] = project end
            if type(cfg) == "table" then items[#items + 1] = cfg end
        end
    end
    local snapshot = {}
    for _, o in ipairs(items) do snapshot[#snapshot + 1] = { o, o._intent, o._source } end
    return snapshot
end

--- Put back the intents `activation_intents` recorded.
local function restore_intents(snapshot)
    for _, e in ipairs(snapshot) do e[1]._intent, e[1]._source = e[2], e[3] end
end

--- `set_active { profile }` — make it the active profile (spec §4.2).
--- @param profile loomworks.Profile
--- @return loomworks.CommandOutcome
function M.profile_set_active(profile)
    local r = stale(profile, "profile")
    if r then return r end
    local ws = profile._workspace
    local old_active, old_active_key = ws._active_profile, ws._active_profile_key
    local intents = activation_intents(profile)
    local saved, err, reason = profile:activate()
    if not saved then
        -- Nothing was written: the active profile and the intents its
        -- cascade changed stay (a stale refusal already reloaded from disk).
        if reason ~= "stale" then
            ws._active_profile, ws._active_profile_key = old_active, old_active_key
            restore_intents(intents)
            ws:remerge()
        end
        return refused(err or "user.json was not written")
    end
    return ok()
end

--- The token of an automatic configuration set: its name and mappings, so
--- a token outlives no change of the set it stands for.
--- @param name string
--- @param mappings table<string, string> project key → configuration name
--- @return string
function M.candidate_token(name, mappings)
    local keys = {}
    for k in pairs(mappings or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = { name }
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "\1" .. tostring(mappings[k]) end
    return "auto:" .. vim.fn.sha256(table.concat(parts, "\0")):sub(1, 16)
end

--- `ConfigSets/1.candidates {}` — the declared configuration sets and the
--- automatic ones the projects allow (each with its `candidate` token).
--- @param ws loomworks.Workspace
--- @return loomworks.CommandOutcome sets: { config_set?: loomworks.ConfigurationSet, name: string, auto: boolean, description?: string, candidate?: string, mappings?: table<string, string> }[]
function M.config_set_candidates(ws)
    local sets, declared = {}, {}
    for _, cs in pairs(ws._config_sets or {}) do
        if not cs._removed then
            declared[cs.name] = true
            sets[#sets + 1] = { config_set = cs, name = cs.name, auto = false, description = cs.description }
        end
    end
    table.sort(sets, function(a, b) return a.name < b.name end)
    local auto = {}
    for name, mappings in pairs(ws:generate_default_config_sets() or {}) do
        if not declared[name] then
            auto[#auto + 1] = { name = name, auto = true, mappings = mappings,
                candidate = M.candidate_token(name, mappings) }
        end
    end
    table.sort(auto, function(a, b) return a.name < b.name end)
    for _, a in ipairs(auto) do sets[#sets + 1] = a end
    return ok({ sets = sets })
end

--- The automatic set a candidate token stands for, or nil + the refusal.
local function candidate_of(ws, token)
    for _, s in ipairs(M.config_set_candidates(ws).sets) do
        if s.auto and s.candidate == token then return s end
    end
    return nil, refused("the automatic configuration set changed since it was listed — choose it again")
end

--- Whether `set` is a `{ candidate = token }` (not a ConfigurationSet).
local function is_candidate(set)
    return type(set) == "table" and set.candidate ~= nil and getmetatable(set) == nil
end

--- Add the automatic configuration set a candidate token stands for (the
--- first step of `Profiles/1.create { config_set = { candidate } }`; the
--- in-process template pick). A token whose set changed or was added since
--- is refused.
--- @param ws loomworks.Workspace
--- @param token string
--- @return loomworks.CommandOutcome config_set: loomworks.ConfigurationSet
function M.config_set_add_candidate(ws, token)
    local found, refusal = candidate_of(ws, token)
    if not found then return refusal end
    local cs, err = ws:add_configuration_set(found.name, found.mappings)
    if not cs then return refused(err or "failed to add config set") end
    return ok({ config_set = cs })
end

--- `create { config_set, tool?, activate? }` — materialize a profile of a
--- configuration set (spec §4.1): `set` the set, or `{ candidate = token }`
--- for an automatic one (added first). An existing profile of that set and
--- toolchain is returned. A new profile's intent is `local`. A failed save
--- is refused with the profile (and the active one) as before; an automatic
--- set added first stays, with a warn note.
--- @param ws loomworks.Workspace
--- @param set loomworks.ConfigurationSet|{ candidate: string }
--- @param tool_entry table|nil { tool_key, tool_data, tool_label, tool_mod_type }; nil: no toolchain
--- @param activate boolean|nil
--- @return loomworks.CommandOutcome profile: loomworks.Profile, config_set: loomworks.ConfigurationSet
function M.profile_create(ws, set, tool_entry, activate)
    local cs = set
    if is_candidate(set) then
        local r = M.config_set_add_candidate(ws, set.candidate)
        if r.outcome ~= "ok" then return r end
        cs = r.config_set
    else
        local r = stale(set, "configuration set")
        if r then return r end
    end
    local existing = cs:find_profile(tool_entry)
    local profile = cs:ensure_profile(tool_entry)
    if not profile then
        return refused("no profile could be made of configuration set '" .. cs.name .. "'")
    end
    local old_intent = profile._intent
    local old_active, old_active_key = ws._active_profile, ws._active_profile_key
    local intents = activate and activation_intents(profile) or {}
    if not existing then profile._intent = "local" end
    local saved, err, reason
    if activate then
        saved, err, reason = profile:activate()
    else
        saved, err, reason = ws:_save_user()
    end
    if not saved then
        -- Nothing was written: undo the in-memory change (a failed first
        -- save is refused, as set_intent) — unless the refusal was the stale
        -- one, which already reloaded from disk (the undo would put back
        -- pre-reload state, e.g. an active profile the reload removed).
        if reason ~= "stale" then
            restore_intents(intents)
            profile._intent = old_intent
            ws._active_profile, ws._active_profile_key = old_active, old_active_key
            if not existing then ws:_remove_profile(profile) end
            if activate then ws:remerge() end
        end
        err = err or "user.json was not written"
        if cs ~= set then
            -- The automatic set was added first (its own write): that
            -- stays, the profile is a warn note (D1).
            local r = ok({ config_set = cs })
            warn(r, "configuration set '" .. cs.name .. "' added, but no profile was made of it: " .. tostring(err))
            return r
        end
        return refused(err)
    end
    return ok({ profile = profile, config_set = cs })
end

--- The module types the projects of a mapping use (`projects`: the
--- Project objects mapped).
--- @param projects loomworks.Project[]
--- @return table<string, true>
local function module_types(projects)
    local types = {}
    for _, p in ipairs(projects) do
        if not p._removed and p.type then types[p.type] = true end
    end
    return types
end

--- `Profiles/1.tool_choices { config_set }` — the toolchains a profile of
--- the set can use (Workspace:tool_entries_for: the detected keyed host
--- tools of its projects' module types, then the relevant resolved SDKs);
--- `set` a ConfigurationSet, or `{ candidate = token }` for an automatic
--- set not added yet (its projects as the token's set maps them).
--- @param ws loomworks.Workspace
--- @param set loomworks.ConfigurationSet|{ candidate: string }
--- @return loomworks.CommandOutcome tools: loomworks.ToolEntry[]
function M.profile_tool_choices(ws, set)
    local name, projects = nil, {}
    if is_candidate(set) then
        local found, refusal = candidate_of(ws, set.candidate)
        if not found then return refusal end
        name = found.name
        -- The generated set names its projects by key (file data): matched
        -- once, here.
        for _, p in pairs(ws._projects or {}) do
            if found.mappings[p.key] ~= nil then projects[#projects + 1] = p end
        end
    else
        local r = stale(set, "configuration set")
        if r then return r end
        name = set.name
        for p in pairs(set.mappings or {}) do
            if type(p) == "table" then projects[#projects + 1] = p end
        end
    end
    return ok({ tools = ws:tool_entries_for(name, module_types(projects)) })
end

--- The toolchain state of a profile that a toolchain change alters.
local function profile_tools_snapshot(profile)
    return { tool_keys = profile._tool_keys and vim.deepcopy(profile._tool_keys) or nil,
        sdk = profile._sdk, sdk_key = profile._sdk_key }
end

--- Put the profile's toolchain back as `snapshot` had it (its key derived
--- again). False when it already is.
--- @return boolean restored
local function restore_profile_tools(profile, snapshot)
    if vim.deep_equal(profile._tool_keys, snapshot.tool_keys)
            and profile._sdk == snapshot.sdk and profile._sdk_key == snapshot.sdk_key then
        return false
    end
    local changed_key = profile.key
    profile._tool_keys = snapshot.tool_keys
    profile._sdk, profile._sdk_key = snapshot.sdk, snapshot.sdk_key
    profile:_derive_key()
    profile:_after_key_rename(changed_key)
    return true
end

--- Save after a toolchain change of a profile and re-derive; a failed save
--- restores the profile as `snapshot` had it (nothing was written).
local function save_profile_tools(profile, snapshot)
    local ws = profile._workspace
    local saved, err, reason = ws:_save_user()
    if not saved then
        -- A stale refusal reloaded from disk: nothing to undo.
        if reason == "stale" then return refused(err) end
        restore_profile_tools(profile, snapshot)
        return refused(err or "user.json was not written")
    end
    ws:remerge()
    return ok()
end

--- A profile's toolchain change, which re-derives its key and propagates
--- it as a profile rename does: run holding the workspace operation lock
--- (spec §19.3, API.md §11; op_lock.guard below). Answers an outcome; a
--- refused lock is `false, message` from the guard.
local Toolchain = {}

--- @param profile loomworks.Profile
--- @param change fun(profile: loomworks.Profile)
--- @return loomworks.CommandOutcome
function Toolchain.change(profile, change)
    local snapshot = profile_tools_snapshot(profile)
    change(profile)
    return save_profile_tools(profile, snapshot)
end

require("loomworks.op_lock").guard(Toolchain, "change", "rename", function(profile) return profile._workspace end)

--- Run a toolchain change of `profile` under the operation lock. The guard's
--- `false` is a held lock (nothing ran) or a commit that failed after the
--- change was saved (staged) and re-derived: the profile is put back as it
--- was, so no later save writes the change (API.md §11).
local function change_toolchain(profile, change)
    local ws = profile._workspace
    local snapshot = profile_tools_snapshot(profile)
    local base = ws._disk_baseline and ws._disk_baseline.user
    local r, msg = Toolchain.change(profile, change)
    if r == false then
        -- The aborted save recorded its staged text as the working copy's
        -- baseline: while the disk still holds the old text, the old
        -- baseline stands (else the next save is refused as stale).
        if base and ws._disk_baseline.user ~= base
                and ws:_read_disk(require("loomworks.user").filepath(ws.root)) == base.text then
            ws._disk_baseline.user = base
        end
        if restore_profile_tools(profile, snapshot) then ws:remerge() end
        return refused(msg or "the workspace operation lock is held")
    end
    return r
end

--- The Tool a toolchain key names in the workspace's module registries
--- (the exact key; API.md §1.2), or nil.
--- @param ws loomworks.Workspace
--- @param tool_key string
--- @return loomworks.Tool|nil
local function resolve_tool(ws, tool_key)
    for _, mod in pairs(ws._modules or {}) do
        local tool = mod._tools and mod._tools[tool_key]
        if tool and not tool._removed and tool.key then return tool end
    end
    return nil
end

--- Whether `profile` lists the toolchain `tool_key`.
local function has_tool(profile, tool_key)
    for _, k in ipairs(profile._tool_keys or {}) do
        if k == tool_key then return true end
    end
    return false
end

--- `add_tool { profile, tool }` — add a toolchain (its key, a value) to a
--- profile; its key is derived again (spec §1.6), under the workspace
--- operation lock.
--- @param profile loomworks.Profile
--- @param tool_key string
--- @return loomworks.CommandOutcome
function M.profile_add_tool(profile, tool_key)
    local r = stale(profile, "profile")
    if r then return r end
    if type(tool_key) ~= "string" or tool_key == "" then return refused("no toolchain given", 2) end
    -- An argument that does not resolve is refused (API.md §4.1).
    local tool = resolve_tool(profile._workspace, tool_key)
    if not tool then return refused("no toolchain '" .. tool_key .. "'") end
    return change_toolchain(profile, function(p) p:add_tool(tool.key) end)
end

--- `remove_tool { profile, tool }` — remove a toolchain from a profile, under
--- the workspace operation lock.
--- @param profile loomworks.Profile
--- @param tool_key string
--- @return loomworks.CommandOutcome
function M.profile_remove_tool(profile, tool_key)
    local r = stale(profile, "profile")
    if r then return r end
    if type(tool_key) ~= "string" or tool_key == "" then return refused("no toolchain given", 2) end
    if not has_tool(profile, tool_key) then
        return refused("no toolchain '" .. tool_key .. "' on profile '" .. tostring(profile.key) .. "'")
    end
    return change_toolchain(profile, function(p) p:remove_tool(tool_key) end)
end

-- ---------------------------------------------------------------------------
-- Projects/1 (API.md §19)
-- ---------------------------------------------------------------------------

--- `add { key, type, path?, mappings?, tool? }` — declare a project, map it
--- into each configuration set, and with a toolchain upgrade the affected
--- profiles to it. A keyed module's project without a toolchain is added
--- unmapped (it is mapped once a toolchain is chosen), with a `warn` note
--- naming the mappings not made; a mapping into an unknown set is a `warn`
--- note too. A failed upgrade after the project was added is a `warn` note (D1).
--- @param ws loomworks.Workspace
--- @param key string
--- @param mod_type string
--- @param path string|nil relative path
--- @param mappings table<string, string>|nil configuration set name → configuration name
--- @param tool_entry table|nil { tool_key, tool_data, tool_label, tool_mod_type }
--- @return loomworks.CommandOutcome project: loomworks.Project
function M.project_add(ws, key, mod_type, path, mappings, tool_entry)
    local project, err = ws:add_project(key, mod_type, path)
    if not project then return refused(err or "failed to add project") end
    local result = ok({ project = project })

    local mod = require("loomworks.modules").get(mod_type)
    local has_keyed = mod and mod.has_keyed_tools or false
    local names = {}
    for name in pairs(mappings or {}) do names[#names + 1] = tostring(name) end
    table.sort(names)
    if has_keyed and not tool_entry then
        -- Mapped once a toolchain is chosen: say which mappings were not made.
        if #names > 0 then
            warn(result, "project added unmapped (a " .. tostring(mod_type) .. " project has no toolchain);"
                .. " not mapped into '" .. table.concat(names, "', '") .. "'")
        end
        return result
    end

    local known = {}
    for _, cs in pairs(ws._config_sets) do
        known[cs.name] = true
        local variant = mappings and mappings[cs.name]
        if variant then
            local cfg = project:get_configuration(variant) or project:ensure_configuration(variant)
            cs:update_mapping(project, cfg)
        end
    end
    local unknown = {}
    for _, name in ipairs(names) do
        if not known[name] then unknown[#unknown + 1] = name end
    end
    if #unknown > 0 then
        warn(result, "project added, but there is no configuration set '" .. table.concat(unknown, "', '")
            .. "' to map it into")
    end

    if tool_entry then
        local up_ok, up_err = ws:upgrade_profiles_for_tool(tool_entry)
        if up_ok == false then
            warn(result, "project added, but its profiles were not upgraded to the tool: " .. tostring(up_err))
        end
    end
    return result
end

--- The configuration fields the configuration editor dialog edits. Saving
--- from the dialog replaces exactly these; every other declared field of the
--- configuration (env, overrides, description, role, other module fields, …)
--- is carried over unchanged.
M.CONFIG_DIALOG_FIELDS = {
    "inherits", "options", "variables", "languages", "toolchain", "generator",
}

--- `configuration_save { project, configuration?, name, fields }` — create a
--- user configuration (`cfg` nil) or update one, changing only the dialog's
--- fields; a new name renames it (propagated to configuration sets, the
--- cache and profiles, spec §4.8).
--- @param project loomworks.Project
--- @param cfg loomworks.Configuration|nil
--- @param name string
--- @param fields table { inherits?, options?, variables?, languages?, toolchain?, generator? }
--- @return loomworks.CommandOutcome configuration: loomworks.Configuration
function M.configuration_save(project, cfg, name, fields)
    local r = stale(project, "project") or (cfg and stale(cfg))
    if r then return r end
    if cfg and cfg._project ~= project then
        return refused("configuration '" .. cfg.name .. "' is not of project '" .. project.key .. "'")
    end
    local data = (cfg and cfg.is_user) and cfg:declared_data() or {}
    for _, field in ipairs(M.CONFIG_DIALOG_FIELDS) do
        data[field] = fields[field]
    end
    local done, err
    if cfg and cfg.is_user and cfg.name ~= name then
        done, err = project:rename_configuration(cfg.name, name, data)
    else
        done, err = project:save_configuration(name, data)
    end
    if not done then return refused(err or "failed to save configuration") end
    return ok({ configuration = project:get_configuration(name) })
end

--- `configuration_remove { project, configuration }` — remove the
--- declaration; its build state stays, orphaned (spec §4.5).
--- @param project loomworks.Project
--- @param cfg loomworks.Configuration
--- @return loomworks.CommandOutcome
function M.configuration_remove(project, cfg)
    local r = stale(project, "project") or stale(cfg, "configuration")
    if r then return r end
    if cfg._project ~= project then
        return refused("configuration '" .. cfg.name .. "' is not of project '" .. project.key .. "'")
    end
    local done, err = project:delete_configuration(cfg.name)
    if not done then return refused(err or "failed to delete configuration") end
    return ok()
end

--- Wrap a Project `ok, err` mutator as a command.
local function project_write(project, fn, fallback)
    local r = stale(project, "project")
    if r then return r end
    local done, err = fn()
    if not done then return refused(err or fallback) end
    return ok()
end

--- `options_save { project, options }` — the project's options.
--- @param project loomworks.Project
--- @param options table<string, string>
--- @return loomworks.CommandOutcome
function M.options_save(project, options)
    return project_write(project, function() return project:save_options(options) end,
        "failed to save project options")
end

--- The launch's declared table after the launch editor's fields replaced
--- its own: fields the editor does not show (the `device` block, spec
--- §18.9, …) are kept; empty fields are omitted.
--- @param launch loomworks.LaunchConfiguration|nil
--- @param data table
--- @return table
local function launch_declaration(launch, data)
    local config = (launch and not launch:is_invalid()) and vim.deepcopy(launch:serialize()) or {}
    -- An empty command means "no command": the key is absent, never `""` (a
    -- target-backed launch carries only `target`). A command makes this a
    -- command-type launch: it no longer runs a target (as `lw launch set
    -- --command`).
    if data.command and data.command ~= "" then
        config.command = data.command
        config.target = nil
    else
        config.command = nil
    end
    config.args = (data.args and #data.args > 0) and data.args or nil
    config.working_dir = (data.working_dir and data.working_dir ~= "") and data.working_dir or nil
    config.env = (data.env and next(data.env)) and data.env or nil
    config.deploy = (data.deploy and next(data.deploy)) and data.deploy or nil
    config.debug = (data.debug and #data.debug > 0) and data.debug or nil
    return config
end

--- `launch_save { project, launch?, name, data }` — create a launch
--- configuration (`launch` nil) or replace the editor's fields of one; a
--- name other than its own renames it (spec §8.7: profiles' default
--- targets, units' target entries and saved test entries follow), the
--- object — so its id — kept. Working copy only; no operation lock.
--- @param project loomworks.Project
--- @param launch loomworks.LaunchConfiguration|nil
--- @param name string
--- @param data { command?: string, args?: string[], working_dir?: string, env?: table<string, string>, deploy?: table, debug?: string[] }
--- @return loomworks.CommandOutcome launch: loomworks.LaunchConfiguration
function M.launch_save(project, launch, name, data)
    local r = stale(project, "project")
    if r then return r end
    if launch then
        if launch:is_removed() or launch._project ~= project then
            return refused("no launch config '" .. tostring(launch.name) .. "' on project '" .. project.key .. "'")
        end
    end
    local config = launch_declaration(launch, data)
    local renamed = false
    if launch and launch.name ~= name then
        -- A rename (spec §8.7): the atomic operation that moves the whole
        -- launch and re-points every default target — never a delete plus a
        -- re-create. The edited fields are then saved on the new name.
        local changed, err = project:rename_launch_config(launch, name)
        if changed == nil then return refused(err) end
        renamed = changed == true
    elseif not launch then
        local vok, verr = require("loomworks.project").validate_launch_name(name)
        if not vok then return refused("invalid launch name: " .. verr, 2) end
    end
    local done, err, saved = project:save_launch_config(name, config)
    if not done then
        if not renamed then return refused(err or "failed to save launch config") end
        -- The rename was committed: a composite's later step (D1).
        local r = ok({ launch = launch })
        warn(r, "launch config renamed to '" .. name .. "', but its fields were not saved: "
            .. tostring(err))
        return r
    end
    return ok({ launch = saved })
end

--- `launch_remove { project, launch }`.
--- @param project loomworks.Project
--- @param launch loomworks.LaunchConfiguration
--- @return loomworks.CommandOutcome
function M.launch_remove(project, launch)
    local r = stale(project, "project")
    if r then return r end
    if not launch or launch:is_removed() or launch._project ~= project then
        return refused("launch config '" .. tostring(launch and launch.name) .. "' not found")
    end
    local done, err = project:delete_launch_config(launch)
    if not done then return refused(err or "failed to delete launch config") end
    return ok()
end

--- `deploy_save { project, deploy? }` — the whole deploy declaration; nil or
--- an empty dict removes it.
--- @param project loomworks.Project
--- @param deploy table<string, table|table[]>|nil
--- @return loomworks.CommandOutcome
function M.deploy_save(project, deploy)
    if deploy ~= nil and next(deploy) == nil then deploy = nil end
    return project_write(project, function() return project:save_deploy(deploy) end,
        "failed to save deploy steps")
end

--- `variable_save { project, variable?, name, data }` — declare a variable
--- (`var_name` nil) or replace one; a different `name` renames it.
--- @param project loomworks.Project
--- @param var_name string|nil the variable's current name
--- @param name string
--- @param data { type: string, default: string }
--- @return loomworks.CommandOutcome
function M.variable_save(project, var_name, name, data)
    local r = stale(project, "project")
    if r then return r end
    local renamed = var_name ~= nil and var_name ~= name
    if renamed then
        local done, err = project:delete_variable(var_name)
        if not done then return refused(err or "failed to rename variable") end
    end
    local done, err = project:save_variable(name, { type = data.type, default = data.default })
    if not done then
        if not renamed then return refused(err or "failed to save variable") end
        -- The old name's removal was committed: a composite's later step (D1).
        r = ok()
        warn(r, "variable '" .. var_name .. "' removed, but '" .. name .. "' was not saved: " .. tostring(err))
        return r
    end
    return ok()
end

--- `variable_remove { project, variable }`.
--- @param project loomworks.Project
--- @param var_name string
--- @return loomworks.CommandOutcome
function M.variable_remove(project, var_name)
    return project_write(project, function() return project:delete_variable(var_name) end,
        "failed to delete variable")
end

--- `type_config_set { project, field, value? }` — one of the module's
--- editable `type_config` fields; nil clears it.
--- @param project loomworks.Project
--- @param field string
--- @param value any
--- @return loomworks.CommandOutcome
function M.type_config_set(project, field, value)
    return project_write(project, function() return project:save_type_config_field(field, value) end,
        "failed to save " .. tostring(field))
end

-- ---------------------------------------------------------------------------
-- Projects/1 reads (API.md §19): candidates, declaration, expand_preview
-- ---------------------------------------------------------------------------

--- The keyed toolchains detected for module type `mod_type`: the workspace's
--- detection when it has one for that type, else a detection now (in the
--- caller's environment; the model is not changed).
--- @param ws loomworks.Workspace
--- @param mod table the module
--- @param mod_type string
--- @return { tool_key: string, tool_label: string|nil, tool_data: table|nil }[]
local function keyed_tools(ws, mod, mod_type)
    local list = ws._tools_by_type and ws._tools_by_type[mod_type]
    if not list and mod.detect_tools then
        list = {}
        local dok, raw = pcall(mod.detect_tools)
        for _, t in ipairs(dok and raw or {}) do
            list[#list + 1] = { tool_data = t.tool_data,
                tool_key = mod.tool_key and mod.tool_key(t.tool_data) or nil,
                tool_label = mod.tool_label and mod.tool_label(t.tool_data) or nil }
        end
    end
    local out = {}
    for _, t in ipairs(list or {}) do
        if t.tool_key then out[#out + 1] = t end
    end
    return out
end

--- The relative path of a project directory a caller names (relative to the
--- root, or absolute under it), or nil + the refusal. The boundary is checked
--- on real paths (8.3 short names and case reconciled, links resolved), so a
--- short spelling of a path under the root is accepted and a junction or
--- symlink inside the root that resolves outside it is refused. A path that
--- does not resolve is refused as outside when its text leaves the root (a
--- `..` segment counts as leaving it), else as missing.
--- @param root string
--- @param path string
--- @return string|nil rel ("" for the root itself), loomworks.CommandOutcome|nil
local function project_dir(root, path)
    local p = tostring(path or ""):gsub("\\", "/")
    local r = root:gsub("\\", "/")
    local outside = refused("'" .. tostring(path) .. "' is not under the workspace root", 2)
    local abs
    if p:sub(1, 1) == "/" or p:match("^%a:/") then
        abs = p
    else
        local rel = p:gsub("/+$", ""):gsub("^%./", "")
        for seg in rel:gmatch("[^/]+") do
            if seg == ".." then return nil, outside end
        end
        abs = (rel == "" or rel == ".") and r or (r .. "/" .. rel)
    end
    local realpath = (vim.uv or vim.loop).fs_realpath
    local win = vim.fn.has("win32") == 1
    local function real(x)
        local rp = realpath(x)
        return rp and (rp:gsub("\\", "/"):gsub("/+$", "")) or nil
    end
    local rroot = real(r) or r
    local rabs = real(abs)
    if not rabs then
        -- Nothing to resolve: refused as outside when its text is, else as missing.
        local a, b = win and abs:lower() or abs, win and r:lower() or r
        if a ~= b and a:sub(1, #b + 1) ~= b .. "/" then return nil, outside end
        for seg in abs:gmatch("[^/]+") do
            if seg == ".." then return nil, outside end
        end
        return nil, refused("no directory '" .. tostring(path) .. "'")
    end
    local a, b = win and rabs:lower() or rabs, win and rroot:lower() or rroot
    if a ~= b and a:sub(1, #b + 1) ~= b .. "/" then return nil, outside end
    if vim.fn.isdirectory(rabs) ~= 1 then return nil, refused("no directory '" .. tostring(path) .. "'") end
    return a == b and "" or rabs:sub(#rroot + 2)
end
M.project_dir = project_dir

--- `candidates { path, type? }` — what adding the directory as a project
--- would declare (the project browser's add context): the derived key and
--- path, the module types that detect it, the configurations the module
--- (`mod_type`, else the first detected) offers, a proposed mapping into each
--- configuration set, the keyed toolchains (only the one the profiles
--- already use, `inherited`, when there is one), and the profiles each
--- toolchain would upgrade. Detection runs in the caller's environment;
--- nothing is written.
--- @param ws loomworks.Workspace
--- @param path string
--- @param mod_type string|nil
--- @return loomworks.CommandOutcome
function M.project_candidates(ws, path, mod_type)
    local modules = require("loomworks.modules")
    local wv = require("loomworks.workspace_view")
    local rel, r = M.project_dir(ws.root, path)
    if not rel then return r end
    local root = ws.root:gsub("\\", "/")
    local abs = rel == "" and root or (root .. "/" .. rel)
    local key, ppath = wv.derive_key_and_path(root, abs, vim.fn.fnamemodify(abs, ":t"))
    local types = modules.detect_all_types(abs)
    mod_type = mod_type or (types[1] and types[1].type)
    local mod = mod_type and modules.get(mod_type) or nil
    if mod_type and not mod then return refused("unknown project type '" .. tostring(mod_type) .. "'", 2) end
    local out = ok({ key = key, path = ppath or key, types = types, mappings = vim.empty_dict(),
        configurations = {} })
    if not mod then return out end

    if mod.info then
        local iok, info = pcall(mod.info, abs, {})
        for name in pairs(iok and type(info) == "table" and info.configurations or {}) do
            out.configurations[#out.configurations + 1] = name
        end
        table.sort(out.configurations)
    end
    local set_names = {}
    for _, cs in pairs(ws._config_sets) do set_names[#set_names + 1] = cs.name end
    table.sort(set_names)
    local mappings = {}
    if #set_names > 0 and #out.configurations > 0 then
        mappings = wv.compute_initial_mappings(mod, set_names, out.configurations)
        for set, cfg in pairs(mappings) do out.mappings[set] = cfg end
    end

    if mod.has_keyed_tools then
        local ctx = wv.compute_add_project_context(ws, mod_type)
        out.tools, out.upgrade_preview = {}, {}
        if ctx.inherited_tool then
            out.tools[1] = { key = ctx.inherited_tool.tool_key, label = ctx.inherited_tool.tool_label,
                inherited = true }
        else
            for _, t in ipairs(keyed_tools(ws, mod, mod_type)) do
                out.tools[#out.tools + 1] = { key = t.tool_key, label = t.tool_label }
                if #ctx.no_tool_profiles > 0 then
                    local entry = { tool_key = t.tool_key, tool_data = t.tool_data, tool_label = t.tool_label,
                        tool_mod_type = mod_type }
                    for _, rn in ipairs(wv.compute_upgrade_preview(ws, entry, mappings)) do
                        out.upgrade_preview[#out.upgrade_preview + 1] = { tool = t.tool_key, from = rn.old_key,
                            to = rn.new_key }
                    end
                end
            end
        end
    end
    return out
end

--- The toolchain entry `add { tool = { key } }` names for a project of
--- `mod_type`: the one the profiles already use, or a detected one (in the
--- caller's environment), or nil + the refusal.
--- @param ws loomworks.Workspace
--- @param mod_type string
--- @param key string
--- @return table|nil tool_entry { tool_key, tool_data, tool_label, tool_mod_type }, loomworks.CommandOutcome|nil
function M.project_tool_entry(ws, mod_type, key)
    local mod = require("loomworks.modules").get(mod_type)
    if mod and mod.has_keyed_tools then
        local inherited = require("loomworks.workspace_view").compute_add_project_context(ws, mod_type).inherited_tool
        if inherited and inherited.tool_key == key then return inherited end
        for _, t in ipairs(keyed_tools(ws, mod, mod_type)) do
            if t.tool_key == key then
                return { tool_key = t.tool_key, tool_data = t.tool_data, tool_label = t.tool_label,
                    tool_mod_type = mod_type }
            end
        end
    end
    return nil, refused("no toolchain '" .. tostring(key) .. "' for " .. tostring(mod_type) .. " projects")
end

--- An object for the wire: an empty table encodes as `{}`, not `[]`.
local function dict(t)
    if t == nil or next(t) == nil then return vim.empty_dict() end
    return t
end

--- The module's editable `type_config` fields of a project (§14.4), in the
--- module's order, each with the project's current value.
--- @param project loomworks.Project
--- @return { name: string, label?: string, kind?: string, placeholder?: string, value?: any }[]
local function type_config_fields(project)
    local impl = project._module and project._module.impl or nil
    local out = {}
    for _, f in ipairs(impl and impl.editable_type_config_fields and impl.editable_type_config_fields() or {}) do
        local v = project.type_config and project.type_config[f.name]
        out[#out + 1] = { name = f.name, label = f.label, kind = f.kind, placeholder = f.placeholder,
            value = type(v) == "table" and vim.deepcopy(v) or v }
    end
    return out
end

--- Whether `field` is one of the project's module's editable `type_config`
--- fields, the ones `type_config_set` writes.
--- @param project loomworks.Project
--- @param field string
--- @return boolean
function M.editable_type_config_field(project, field)
    for _, f in ipairs(type_config_fields(project)) do
        if f.name == field then return true end
    end
    return false
end

--- `declaration { project }` — the project's declaration as the working
--- copy holds it, for a client's editors: each configuration (by name;
--- `user` when it is a user configuration) and launch configuration (by
--- name; `invalid` when its declaration is not a table) with its id
--- (`id_of`) and declared fields, the deploy declaration, the variables, the
--- project options and the module's editable `type_config` fields.
--- @param project loomworks.Project
--- @param id_of fun(obj: table): string
--- @return loomworks.CommandOutcome
function M.project_declaration(project, id_of)
    local r = stale(project, "project")
    if r then return r end
    local out = ok({ configurations = {}, launches = {}, variables = vim.empty_dict() })
    for _, cfg in ipairs(project._configurations or {}) do
        if not cfg._removed then
            out.configurations[#out.configurations + 1] = { id = id_of(cfg), key = cfg.name,
                user = cfg.is_user or nil, fields = dict(cfg:declared_data()) }
        end
    end
    table.sort(out.configurations, function(a, b) return a.key < b.key end)
    for _, launch in ipairs(project:launch_configs()) do
        local l = { id = id_of(launch), key = launch.name }
        if launch:is_invalid() then l.invalid = true else l.fields = dict(vim.deepcopy(launch:serialize())) end
        out.launches[#out.launches + 1] = l
    end
    if project.deploy and next(project.deploy) then out.deploy = vim.deepcopy(project.deploy) end
    for name, decl in pairs(project.variables or {}) do
        out.variables[name] = { type = decl.type, default = decl.default }
    end
    out.options = dict(vim.deepcopy(project.type_config and project.type_config.options))
    out.type_config = { fields = type_config_fields(project) }
    return out
end

--- `expand_preview { project, profile?, templates }` — each template
--- expanded as a launch of `project` would expand it (spec §1.3.1, §8.7),
--- under `profile` or the active profile, in the caller's environment; an
--- unresolved reference stays as written.
--- @param project loomworks.Project
--- @param profile loomworks.Profile|nil
--- @param templates string[]
--- @return loomworks.CommandOutcome values: string[]
function M.expand_preview(project, profile, templates)
    local r = stale(project, "project") or (profile and stale(profile, "profile"))
    if r then return r end
    local ws = project._workspace
    profile = profile or ws:get_active_profile()
    if not profile then return refused("no active profile; name a profile") end
    local expand = require("loomworks.expand")
    local ctx = expand.launch_context(ws, profile, project)
    local values = {}
    for i, t in ipairs(templates or {}) do
        values[i] = (expand.expand_string(t, ctx))
    end
    return ok({ values = values })
end

-- ---------------------------------------------------------------------------
-- ConfigSets/1 (API.md §20)
-- ---------------------------------------------------------------------------

--- `add { name, mappings }`.
--- @param ws loomworks.Workspace
--- @param name string
--- @param mappings table<loomworks.Project, loomworks.Configuration|false|nil>
--- @return loomworks.CommandOutcome config_set: loomworks.ConfigurationSet
function M.config_set_add(ws, name, mappings)
    local r = stale_mappings(mappings)
    if r then return r end
    -- add_configuration_set takes the persisted form
    -- ({ project key → configuration name }).
    local raw = {}
    for project, cfg in pairs(mappings or {}) do
        if cfg then raw[project.key] = cfg.name end
    end
    local cs, err = ws:add_configuration_set(name, raw)
    if not cs then return refused(err or "failed to create config set") end
    return ok({ config_set = cs })
end

--- Rename a configuration set in place (Workspace:rename_configuration_set,
--- as `lw configset rename`): its mappings, description and intent are kept
--- and the profiles that reference it re-derive their keys; the active
--- profile follows the rename.
--- @param cs loomworks.ConfigurationSet
--- @param new_name string
--- @return boolean ok, string|nil err
local function rename_config_set(cs, new_name)
    local ws = cs._workspace
    local old_keys = {}
    for _, profile in pairs(ws._profiles) do old_keys[profile] = profile.key end
    local done, err = ws:rename_configuration_set(cs, new_name)
    if not done then return false, err end
    for profile, old_key in pairs(old_keys) do
        if ws._active_profile_key == old_key and profile.key ~= old_key then
            ws._active_profile_key = profile.key
            break
        end
    end
    return true
end

--- `update { config_set, name?, mappings }` — replace the set's mappings
--- (a project absent from `mappings`, or mapped to false, is unmapped); a
--- different name renames it first (spec §4.10).
--- @param cs loomworks.ConfigurationSet
--- @param name string|nil
--- @param mappings table<loomworks.Project, loomworks.Configuration|false|nil>
--- @return loomworks.CommandOutcome
function M.config_set_update(cs, name, mappings)
    local r = stale(cs, "configuration set") or stale_mappings(mappings)
    if r then return r end
    -- Each step commits on its own: a failure after the first is `ok` with a
    -- warn note naming what was not done (D1).
    local wrote = false
    if name and name ~= cs.name then
        local done, err = rename_config_set(cs, name)
        if not done then return refused(err) end
        wrote = true
    end
    local ws = cs._workspace
    mappings = mappings or {}
    for _, project in pairs(ws._projects) do
        local new_cfg = mappings[project] or nil
        if new_cfg ~= cs:configuration(project) then
            local done, err = cs:update_mapping(project, new_cfg)
            if not done then
                if not wrote then return refused(err) end
                local r = ok()
                warn(r, "configuration set '" .. cs.name .. "' updated, but its mapping of project '"
                    .. project.key .. "' was not: " .. tostring(err))
                return r
            end
            wrote = true
        end
    end
    return ok()
end

--- `remove { config_set }` — the declaration only; its profiles stay, shown
--- with a missing set (spec §4.4).
--- @param cs loomworks.ConfigurationSet
--- @return loomworks.CommandOutcome
function M.config_set_remove(cs)
    local r = stale(cs, "configuration set")
    if r then return r end
    local done, err = cs._workspace:remove_configuration_set(cs)
    if not done then return refused(err or "failed to delete config set") end
    return ok()
end

--- `generate_defaults {}` — add every set the projects' configurations
--- suggest that does not exist yet; the notes name the sets added.
--- @param ws loomworks.Workspace
--- @return loomworks.CommandOutcome
function M.config_set_generate_defaults(ws)
    local result = ok({ config_sets = {} })
    for _, s in ipairs(M.config_set_candidates(ws).sets) do
        if s.auto then
            local cs, err = ws:add_configuration_set(s.name, s.mappings)
            if not cs then
                if #result.config_sets == 0 then return refused(err or "failed to add config set") end
                warn(result, "configuration set '" .. s.name .. "' was not added: " .. tostring(err))
            else
                result.config_sets[#result.config_sets + 1] = cs
                result.notes = result.notes or {}
                result.note_roles = result.note_roles or {}
                result.notes[#result.notes + 1] = "added configuration set '" .. s.name .. "'"
                result.note_roles[#result.notes] = "plain"
            end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Toolchains/1.rescan (API.md §11)
-- ---------------------------------------------------------------------------

--- `rescan {}` — start detecting the toolchains again
--- (Workspace:rescan_tools, the status page's `L`). Detection is
--- asynchronous: the model takes the result in when `ws._tool_state` is
--- "scanned" again; the daemon waits for that before it replies.
--- @param ws loomworks.Workspace
--- @return loomworks.CommandOutcome
function M.tools_rescan(ws)
    ws:rescan_tools()
    return ok()
end

-- ---------------------------------------------------------------------------
-- Sdks/1 (API.md §21)
-- ---------------------------------------------------------------------------

--- `detect { provider? }` — the installed SDK providers (or the one named)
--- and the installation paths each detects, in the current environment.
--- Changes nothing. A provider whose detection raises finds none (as the
--- status page's SDK picker); an unknown provider is refused with
--- Workspace:add_sdk's message.
--- @param provider string|nil provider id
--- @return loomworks.CommandOutcome providers: { id: string, label: string, found: string[] }[]
function M.sdk_detect(provider)
    local registry = require("loomworks.sdks")
    local ids
    if provider ~= nil then
        if not registry.get(provider) then
            return refused("no provider for SDK type '" .. tostring(provider) .. "'")
        end
        ids = { provider }
    else
        ids = registry.list()
    end
    local providers = {}
    for _, id in ipairs(ids) do
        local p = registry.get(id)
        if p then
            local found = {}
            if type(p.detect_all) == "function" then
                local okd, res = pcall(p.detect_all)
                for _, inst in ipairs(okd and type(res) == "table" and res or {}) do
                    if type(inst) == "table" and type(inst.path) == "string" and inst.path ~= "" then
                        found[#found + 1] = inst.path
                    end
                end
            end
            providers[#providers + 1] = { id = id,
                label = type(p.display_name) == "string" and p.display_name or id, found = found }
        end
    end
    return ok({ providers = providers })
end

--- `add { provider, path }` — declare an SDK.
--- @param ws loomworks.Workspace
--- @param provider string provider id
--- @param path string|nil installation path (nil: the first detected)
--- @return loomworks.CommandOutcome sdk: loomworks.SDK
function M.sdk_add(ws, provider, path)
    local sdk, err = ws:add_sdk(provider, path)
    if not sdk then return refused(err or "failed to add SDK") end
    return ok({ sdk = sdk })
end

--- `remove { sdk }` — remove its declaration.
--- @param sdk loomworks.SDK
--- @return loomworks.CommandOutcome
function M.sdk_remove(ws, sdk)
    if sdk == nil or sdk._removed then return refused("no such SDK (a stale reference)") end
    if not ws:remove_sdk(sdk.key) then
        return refused("SDK '" .. tostring(sdk.key) .. "' is not declared")
    end
    return ok()
end


-- ---------------------------------------------------------------------------
-- Maintenance/1 (API.md §22)
-- ---------------------------------------------------------------------------

--- The request phase of `execute_deletion { target, plan?, yes? }`: the
--- deletion is planned (loomworks.deletion_plan) after resolution and
--- before any lock; nothing is locked or changed here. In `reset`'s order
--- (§8.5): a target that cannot be deleted (stale, a stray dir not in the
--- current stray set or outside the workspace) is refused; a `plan` the
--- fresh token differs from is refused (`deletion_plan.CHANGED`, exit 1),
--- before the empty check, so a listed plan whose directories vanished is
--- never "nothing to delete"; nothing to delete is refused (exit 0, `stream
--- = "out"`); without `yes` it is `confirm` (`lines`, `plan`); otherwise
--- `accepted`, carrying the plan `deletion_run` executes and whether the
--- listing is still to be shown (`listing`: no `plan` was sent).
--- @param ws loomworks.Workspace
--- @param target table a deletion target (loomworks.deletion_plan header)
--- @param plan string|nil the token a confirmation returned
--- @param yes boolean|nil
--- @return table outcome `refused` | `confirm` | `accepted` (`deletion`, `listing`)
function M.deletion_request(ws, target, plan, yes)
    local dp = require("loomworks.deletion_plan")
    local p = dp.plan(ws, target)
    if p.refusal then return refused(p.refusal) end
    if plan ~= nil and plan ~= p.token then return refused(dp.CHANGED) end
    if dp.is_empty(p) then
        local r = refused(dp.NOTHING, 0)
        r.stream = "out"
        return r
    end
    if not yes then
        return { outcome = "confirm", lines = dp.listing(ws, p), plan = p.token }
    end
    return { outcome = "accepted", deletion = p, listing = plan == nil and dp.listing(ws, p) or nil }
end

--- The run phase of an accepted deletion: take the workspace operation lock,
--- then the build-directory lock of every directory of the plan (exclusive,
--- canonical order; `Workspace:_locked_deletion`), apply external changes
--- (`deletion_plan.resync`), plan again and refuse a different plan
--- (`deletion_plan.CHANGED`) before anything is removed, then execute it
--- (`deletion_plan.execute`). The locks are released once the deletion has
--- settled. `done(outcome)` runs once: `ok` (a `warn` note when a project's
--- downgrade failed after its removal), or `refused` — a held lock (its
--- holder), a changed plan, a stopped deletion (`delete stopped: <reason>`,
--- `opts.stop_reason`), a failed removal. Returns the deletion's Future.
--- @param ws loomworks.Workspace
--- @param deletion loomworks.DeletionTargetPlan the accepted plan
--- @param opts? { stop?: fun(): boolean, stop_reason?: fun(): string }
--- @param done fun(outcome: loomworks.CommandOutcome)
--- @return loomworks.Future
function M.deletion_run(ws, deletion, opts, done)
    local dp = require("loomworks.deletion_plan")
    opts = opts or {}
    local settled = false
    local function finish(r)
        if settled then return end
        settled = true
        done(r)
    end
    local lock_msg
    local f = ws:_locked_deletion("delete", deletion.lock_dirs, function()
        local pok, fresh, verr = pcall(function()
            if not dp.resync(ws) then return nil, "the workspace was unloaded" end
            return dp.verify(ws, deletion)
        end)
        if not pok then finish(refused(fresh)); return false end
        if not fresh then finish(refused(verr)); return false end
        -- A synchronous throw (e.g. the working-copy save failing before any
        -- removal) settles as `refused`; returning false releases the locks.
        local eok, ef = pcall(dp.execute, ws, fresh, { stop = opts.stop })
        if not eok then finish(refused(ef)); return false end
        return ef:next(function(res)
            if res.stopped then
                finish(refused("delete stopped: "
                    .. tostring(opts.stop_reason and opts.stop_reason() or "cancelled")))
            elseif not res.ok then
                finish(refused(res.message))
            else
                local r = ok()
                if res.warn then warn(r, res.warn) end
                finish(r)
            end
            return res.ok == true
        end, function(err)
            finish(refused(err))
            error(err, 0)
        end)
    end, nil, function(msg) lock_msg = msg end)
    f:next(function(v)
        if v == false and not settled then
            finish(refused(lock_msg or "the deletion was refused"))
        end
    end):catch(function(err) finish(refused(err)) end)
    return f
end

--- `execute_deletion { target, plan?, yes? }` in one call (the in-process
--- host): `deletion_request`, and when accepted `deletion_run`, whose final
--- outcome goes to `opts.done`. Returns the request's outcome (`refused`,
--- `confirm` or `accepted`).
--- @param ws loomworks.Workspace
--- @param target table a deletion target
--- @param opts? { plan?: string, yes?: boolean, stop?: fun(): boolean, stop_reason?: fun(): string, done?: fun(outcome: loomworks.CommandOutcome) }
--- @return table outcome
function M.execute_deletion(ws, target, opts)
    opts = opts or {}
    local r = M.deletion_request(ws, target, opts.plan, opts.yes)
    if r.outcome ~= "accepted" then return r end
    M.deletion_run(ws, r.deletion, opts, opts.done or function() end)
    return r
end

return M

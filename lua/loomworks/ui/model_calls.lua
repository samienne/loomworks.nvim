--- loomworks/ui/model_calls.lua — The status page's one route to model writes.
---
--- Step 5o part C0 (spec §19.19): every status-page action and dialog that
--- writes the model calls `M.call(ws, method, params, cb)` here, `method` a
--- catalogue method named with its interface (`"Profiles/1.set_active"`,
--- spec §19.20; API.md §6, §11, §19–§22). The ui never reaches the command
--- layer, the view-model's write adapters or the workspace's write methods
--- itself (a guard checks it, tests/ui_model_calls_spec.lua).
---
--- In C0 each method's body is the in-process write the editor ran before
--- (the view-model's adapters over loomworks.model_commands, or the existing
--- loomworks function), in `in_process` and `daemon` mode alike: no
--- behaviour changes. Part C2 replaces the bodies with calls by id to the
--- workspace daemon; the call sites keep their shape.
---
--- Params mirror the method's (its schema under spec/protocol/interfaces),
--- with the domain object in place of a reference (C2 sends its id). Two
--- transitional params exist only until C2 changes the flow:
---   * `ConfigSets/1.add { candidate }` — the automatic set a candidate token
---     stands for, added when the create-profile picker picks it (the wire's
---     `add` takes `{ name, mappings }`; C2 sends `Profiles/1.create
---     { config_set = { candidate } }` instead);
---   * `Maintenance/1.execute_deletion { confirmed }`,
---     `Workspace/1.delete_user_prefs { root }`, `Maintenance/1.nuke
---     { root }` — the in-process confirmation the user accepted (its plan,
---     dialog context or root); C2 uses the methods' confirm + plan token.
---
--- `cb(r)` gets the outcome (API.md §4.1): `{ outcome = "ok", ... }` with
--- the method's result fields (a created object, `changed`, …), or
--- `{ outcome = "refused", message? }` (no message: already reported). In C0
--- it runs before `call` returns; callers must not rely on that.

local M = {}

local function wv() return require("loomworks.workspace_view") end

--- An `ok, err` adapter's result as an outcome.
--- @param ok any
--- @param err string|nil
--- @param fields? table the result fields of an `ok`
--- @return table
local function outcome(ok, err, fields)
    if not ok then return { outcome = "refused", message = err } end
    local r = { outcome = "ok" }
    for k, v in pairs(fields or {}) do r[k] = v end
    return r
end

--- An object-returning adapter's result (`obj` or `nil, err`) as an outcome
--- carrying it as `field`.
local function created(field, obj, err)
    return outcome(obj ~= nil, err, { [field] = obj })
end

--- The method bodies: `fn(ws, params, cb)`.
--- @type table<string, fun(ws: loomworks.Workspace|nil, p: table, cb: fun(r: table))>
local CALLS = {}

-- ---------------------------------------------------------------------------
-- Workspace/1
-- ---------------------------------------------------------------------------

CALLS["Workspace/1.publish"] = function(ws, _, cb) cb(outcome(wv().publish(ws))) end
CALLS["Workspace/1.revert_to_baseline"] = function(ws, _, cb) cb(outcome(wv().revert_to_baseline(ws))) end
CALLS["Workspace/1.publish_one"] = function(_, p, cb) cb(outcome(wv().publish_one(p.item))) end
CALLS["Workspace/1.revert_one"] = function(_, p, cb) cb(outcome(wv().revert_one(p.item))) end
CALLS["Workspace/1.set_intent"] = function(_, p, cb) cb(outcome(wv().set_intent(p.item, p.intent))) end
--- `changed`: false when the text was already the description.
CALLS["Workspace/1.set_description"] = function(_, p, cb)
    local changed, err = wv().set_description(p.item, p.text)
    cb(outcome(changed ~= nil, err, { changed = changed }))
end
--- The in-process review prompt and trust (spec §17.4); `trust` its result
--- ("trusted", "discarded", "cancelled", "valid" or "error").
CALLS["Workspace/1.trust_accept"] = function(_, _, cb)
    cb(outcome(true, nil, { trust = require("loomworks").trust_user_prefs() }))
end
CALLS["Workspace/1.delete_user_prefs"] = function(_, p, cb)
    require("loomworks").delete_user_prefs(p.root)
    cb(outcome(true))
end

-- ---------------------------------------------------------------------------
-- Profiles/1
-- ---------------------------------------------------------------------------

CALLS["Profiles/1.set_active"] = function(_, p, cb) cb(outcome(wv().activate_profile(p.profile))) end
--- `{ config_set, tool?, activate? }` (`tool` the picked tool entry) →
--- `profile`.
CALLS["Profiles/1.create"] = function(_, p, cb)
    cb(created("profile", wv().execute_create_profile(p.config_set, p.tool, p.activate)))
end
CALLS["Profiles/1.add_tool"] = function(_, p, cb) cb(outcome(wv().add_profile_tool(p.profile, p.tool))) end
CALLS["Profiles/1.remove_tool"] = function(_, p, cb) cb(outcome(wv().remove_profile_tool(p.profile, p.tool))) end

-- ---------------------------------------------------------------------------
-- ConfigSets/1
-- ---------------------------------------------------------------------------

--- `{ name, mappings }` (Project → Configuration), or (C0) `{ candidate }`
--- → `config_set`.
CALLS["ConfigSets/1.add"] = function(ws, p, cb)
    if p.candidate then
        return cb(created("config_set", wv().execute_create_config_set_from_candidate(ws, p.candidate)))
    end
    cb(created("config_set", wv().execute_create_config_set(ws, p.name, p.mappings)))
end
CALLS["ConfigSets/1.update"] = function(_, p, cb)
    cb(outcome(wv().execute_edit_config_set(p.config_set, p.name, p.mappings)))
end
CALLS["ConfigSets/1.remove"] = function(ws, p, cb) cb(outcome(wv().execute_delete_config_set(ws, p.config_set))) end

-- ---------------------------------------------------------------------------
-- Projects/1
-- ---------------------------------------------------------------------------

--- `{ key, type, path?, mappings?, tool? }` (`tool` the picked tool entry)
--- → `project`.
CALLS["Projects/1.add"] = function(ws, p, cb)
    local ok, err, project = wv().execute_add_project(ws, p.key, p.type, p.path,
        { mappings = p.mappings, tool_entry = p.tool })
    cb(outcome(ok, err, { project = project }))
end
CALLS["Projects/1.configuration_save"] = function(_, p, cb)
    cb(outcome(wv().execute_save_configuration(p.project, p.configuration, p.name, p.fields)))
end
CALLS["Projects/1.configuration_remove"] = function(_, p, cb)
    cb(outcome(wv().execute_delete_configuration(p.project, p.configuration)))
end
--- → `launch`.
CALLS["Projects/1.launch_save"] = function(_, p, cb)
    local ok, err, launch = wv().execute_save_launch_config(p.project, p.launch, p.name, p.data)
    cb(outcome(ok, err, { launch = launch }))
end
CALLS["Projects/1.launch_remove"] = function(_, p, cb)
    cb(outcome(wv().execute_delete_launch_config(p.project, p.launch)))
end
CALLS["Projects/1.variable_save"] = function(_, p, cb)
    cb(outcome(wv().execute_save_variable(p.project, p.variable, p.name, p.data)))
end
CALLS["Projects/1.variable_remove"] = function(_, p, cb)
    cb(outcome(wv().execute_delete_variable(p.project, p.variable)))
end
CALLS["Projects/1.type_config_set"] = function(_, p, cb)
    cb(outcome(wv().save_type_config_field(p.project, p.field, p.value)))
end
CALLS["Projects/1.deploy_save"] = function(_, p, cb) cb(outcome(wv().save_deploy(p.project, p.deploy))) end

-- ---------------------------------------------------------------------------
-- Sdks/1 and Toolchains/1
-- ---------------------------------------------------------------------------

--- → `sdk`.
CALLS["Sdks/1.add"] = function(ws, p, cb) cb(created("sdk", wv().add_sdk(ws, p.provider, p.path))) end
CALLS["Sdks/1.remove"] = function(ws, p, cb) cb(outcome(wv().remove_sdk(ws, p.sdk))) end
CALLS["Toolchains/1.rescan"] = function(_, _, cb)
    require("loomworks").rescan_tools()
    cb(outcome(true))
end

-- ---------------------------------------------------------------------------
-- Maintenance/1
-- ---------------------------------------------------------------------------

--- `{ target, confirmed }`: `target` exactly one of `{ profile }`,
--- `{ unit }`, `{ build_dir }` (an orphaned BuildDir), `{ stray_dir }` (the
--- path as listed), `{ orphans = true }`, `{ project }`; `confirmed` (C0)
--- what the user accepted — the profile's DeletionPlan, the project's
--- removal context, the orphan cleanup context (`orphaned_configs`,
--- `stray_dirs`). `cb` runs when the deletion ended; a `build_dir` outcome
--- carries `report` (`kept`).
CALLS["Maintenance/1.execute_deletion"] = function(ws, p, cb)
    local t = p.target or {}
    if t.profile then
        require("loomworks").execute_deletion(p.confirmed, { deactivate_profile = t.profile },
            function() cb(outcome(true)) end)
    elseif t.unit then
        t.unit:delete(function() cb(outcome(true)) end)
    elseif t.build_dir then
        local report = {}
        ws:delete_orphaned_build_dir(t.build_dir.rel_path, nil, { report = report })
            :next(function(ok) cb(outcome(ok == true, nil, { report = report })) end)
            :catch(function(err) cb(outcome(false, tostring(err))) end)
    elseif t.stray_dir then
        wv().execute_delete_stray_dir(ws, t.stray_dir, function(ok, err) cb(outcome(ok, err)) end)
    elseif t.orphans then
        wv().execute_orphan_cleanup(ws, p.confirmed.orphaned_configs, p.confirmed.stray_dirs,
            function(ok) cb(outcome(ok)) end)
    elseif t.project then
        wv().execute_remove_project(ws, t.project, p.confirmed, function(ok, err) cb(outcome(ok, err)) end)
    else
        error("loomworks.ui.model_calls: Maintenance/1.execute_deletion without a target", 3)
    end
end
CALLS["Maintenance/1.nuke"] = function(_, p, cb)
    require("loomworks").nuke_cache(p.root)
    cb(outcome(true))
end

--- The methods the status page calls, sorted (tests).
--- @return string[]
function M.methods()
    local names = {}
    for name in pairs(CALLS) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Call a model method of the workspace `ws` (nil when `params` carry the
--- domain object the method acts on). `cb(r)` gets its outcome (may be nil).
--- @param ws loomworks.Workspace|nil
--- @param method string `"<Interface>/<version>.<method>"`
--- @param params table|nil
--- @param cb fun(r: table)|nil
function M.call(ws, method, params, cb)
    local fn = CALLS[method]
    if not fn then error("loomworks.ui.model_calls: unknown method " .. tostring(method), 2) end
    fn(ws, params or {}, cb or function() end)
end

--- An outcome as the editor's `ok, err`: refused is `false, message`; a
--- `warn` note of an `ok` (a composite whose later step failed, API.md
--- §4.1) is reported as the error it is shown as.
--- @param r table
--- @return boolean ok, string|nil err
function M.result(r)
    if r.outcome ~= "ok" then return false, r.message end
    for i, role in ipairs(r.note_roles or {}) do
        if role == "warn" then return false, r.notes[i] end
    end
    return true
end

return M

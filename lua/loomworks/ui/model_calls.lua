--- loomworks/ui/model_calls.lua — The status page's one route to model writes.
---
--- Step 5o part C0 (spec §19.19): every status-page action and dialog that
--- writes the model calls `M.call(ws, method, params, cb)` here, `method` a
--- catalogue method named with its interface (`"Profiles/1.set_active"`,
--- spec §19.20; API.md §6, §11, §19–§22). The ui never reaches the command
--- layer, the view-model's write adapters or the workspace's write methods
--- itself (a guard checks it, tests/ui_model_calls_spec.lua).
---
--- In-process bodies (C0): each method's body is the in-process write the
--- editor ran before (the view-model's adapters over loomworks.model_commands,
--- or the existing loomworks function). Part C2 replaces them, in `daemon`
--- mode, with calls by id to the workspace daemon; the call sites keep their
--- shape. **C2a** routes `Workspace/1`, `Profiles/1` and `ConfigSets/1`,
--- **C2b** (first half) the `Projects/1` methods whose dialogs need no read
--- of the editor's model beyond `Projects/1.declaration` — the project
--- browser's `candidates` + `add`, `declaration`, `configuration_remove`,
--- `launch_remove`, `variable_save` / `variable_remove` and
--- `type_config_set`, **C2b2-1** `configuration_save` (the configuration
--- editor reads `declaration`), **C2b2-2** `launch_save`, `deploy_save`
--- and `expand_preview` (the launch, deploy and path editors read
--- `declaration`, the workspace view and `expand_preview`), **C2c-1**
--- the SDK section's `Sdks/1` (`detect` — the picker's read — `add`,
--- `remove`) and `L`'s `Toolchains/1.rescan`, and **C2c-2**
--- `Maintenance/1.execute_deletion` (every deletion of the page, the
--- project row's `D` and the project browser's `d` included) and
--- `Maintenance/1.nuke` (`ROUTED` below), **C2d-1** the Profiles
--- section's operations `Build/1.build`, `configure` and `clean` of a
--- profile row or of unit rows (a rebuild is the page's clean, then its
--- build), and **C2d-2** its options float's `Projects/1.unit_options` and
--- device choice (`Profiles/1.set_device` / `clear_device`) — every method
--- here: in `daemon` mode those are only ever calls —
--- refused (the outcome says why) when the daemon cannot carry them, never
--- run in-process (spec §19.16 "Availability").
---
--- A deletion or nuke is confirmed (ui/actions.confirm_deletion, both
--- modes): called without `plan` it answers `confirm { lines, plan }` (or
--- refused — nothing to delete with `stream = "out"`); called again with
--- that `plan` and `yes` it runs. In `daemon` mode the confirmed call is a
--- task the editor owns (Observer:start_owned), followed to its `done`: `cb`
--- runs then — `ok` only for exit 0 — never at the acceptance; the
--- editor's own tasks on the target (every one, for a nuke) are cancelled
--- first, as a clean does. A nuke never sends a root (the daemon nukes its
--- own workspace); after it every row id is stale (the view is re-read).
---
--- Params mirror the method's (its schema under spec/protocol/interfaces).
--- An entity param of a routed method (`item`, `profile`, `config_set`,
--- `project`, `configuration`, `launch`, `sdk`) is the **row** the action
--- was taken on — a `view.Workspace/1` row of the status page (a project's,
--- one of its `configurations[]` / `launches[]`, an SDK's), a `ConfigSets/1.candidates`
--- entry, or a description handle (`helpers.row_item`, `_row` its row) —
--- never a domain object or a key (a variable or `type_config` field is
--- named by its name within its project's row):
---   * `daemon` mode: the row's id, `{ id = row.id }` (API.md §1.2 ItemRef /
---     Ref; a candidate entry `{ candidate }`); a row without one is
---     refused, never looked up by key;
---   * `in-process` mode: the domain object the in-process view bound to
---     the row (loomworks.status_source.object_of); a domain object itself is
---     taken as it is.
--- A `Build/1` operation names a profile row (`profile`) or unit rows
--- (`units`, one of a profile row's `units[]` each — in `daemon` mode sent by
--- its `unit_id`); in `daemon` mode it is a task the editor owns, followed to
--- its end (`cb` then; loomworks.daemon.editor_ops.run_ids), a build asking
--- the artifact-conflict question first from the unit rows' `artifact_block`.
--- `Projects/1.unit_options` names a profile's unit row (`unit`, sent by its
--- `unit_id`); `Profiles/1.set_device` a profile row and a scanned device
--- record (`device`, a loomworks.device_source record, sent by its id).
--- A deletion's `target` is one such row (a profile's, a profile's unit row —
--- sent by its `unit_id` — an orphaned entry's, a project's), a stray
--- directory's path exactly as the view lists it, or `orphans = true`.
--- A `tool` of `Profiles/1.create` is a `Profiles/1.tool_choices` entry; a
--- `mappings` of `ConfigSets/1.add` / `update` is the dialog's project row →
--- configuration choice table (`{ name }`, resolved by name in the project
--- in both modes; sent as project key → configuration name, the wire's
--- form) or a generated template's project key → configuration name.
---
--- `cb(r)` gets the outcome (API.md §4.1): `{ outcome = "ok", ... }` with
--- the method's result fields (a created object — in `daemon` mode its
--- `{ id, key }` — `changed`, …), `{ outcome = "confirm", lines, plan }`
--- (the call asks a confirmation: show `lines`, call again with `plan`), or
--- `{ outcome = "refused", message?, notified? }` (no message, or
--- `notified`: already reported). It
--- may run before `call` returns (in-process) or later (a daemon call, on
--- the main loop); callers must not rely on either.

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

--- The domain object an entity param names, in the `in-process` mode: the
--- object the in-process view bound to the row (a description handle's
--- `_row`), or a domain object given as it is.
--- @param x table|nil
--- @return table|nil
local function object(x)
    if type(x) ~= "table" then return nil end
    if getmetatable(x) ~= nil then return x end
    return require("loomworks.status_source").object_of(x._row or x)
end

--- The in-process bodies: `fn(ws, params, cb)`.
--- @type table<string, fun(ws: loomworks.Workspace|nil, p: table, cb: fun(r: table))>
local CALLS = {}

-- ---------------------------------------------------------------------------
-- Workspace/1
-- ---------------------------------------------------------------------------

CALLS["Workspace/1.publish"] = function(ws, _, cb) cb(outcome(wv().publish(ws))) end
CALLS["Workspace/1.revert_to_baseline"] = function(ws, _, cb) cb(outcome(wv().revert_to_baseline(ws))) end
CALLS["Workspace/1.publish_one"] = function(_, p, cb) cb(outcome(wv().publish_one(object(p.item)))) end
CALLS["Workspace/1.revert_one"] = function(_, p, cb) cb(outcome(wv().revert_one(object(p.item)))) end
CALLS["Workspace/1.set_intent"] = function(_, p, cb) cb(outcome(wv().set_intent(object(p.item), p.intent))) end
--- `changed`: false when the text was already the description.
CALLS["Workspace/1.set_description"] = function(_, p, cb)
    local changed, err = wv().set_description(object(p.item), p.text)
    cb(outcome(changed ~= nil, err, { changed = changed }))
end
--- The in-process review prompt and trust (spec §17.4), which asks its own
--- question (never `confirm`); `trust` its result ("trusted", "discarded",
--- "cancelled", "valid" or "error").
CALLS["Workspace/1.trust_accept"] = function(_, _, cb)
    cb(outcome(true, nil, { trust = require("loomworks").trust_user_prefs() }))
end
--- `{ plan? }`: without `plan` the `confirm` of what would be deleted; with
--- it, the deletion of exactly that (loomworks.model_commands).
CALLS["Workspace/1.delete_user_prefs"] = function(ws, p, cb) cb(wv().delete_user_prefs(ws, p.plan)) end

-- ---------------------------------------------------------------------------
-- Profiles/1
-- ---------------------------------------------------------------------------

--- `config_set` of `create` / `tool_choices` in-process: a candidate entry's
--- `{ candidate }`, else the set's object.
local function set_object(x)
    if type(x) == "table" and x.candidate ~= nil then return { candidate = x.candidate } end
    return object(x)
end

CALLS["Profiles/1.set_active"] = function(_, p, cb) cb(outcome(wv().activate_profile(object(p.profile)))) end
--- `{ config_set, tool?, activate? }` (`tool` a tool_choices entry) →
--- `profile` (and `config_set`, an automatic set added first).
CALLS["Profiles/1.create"] = function(ws, p, cb)
    cb(wv().create_profile(ws, set_object(p.config_set), p.tool and p.tool._entry or nil, p.activate == true))
end
--- `{ config_set }` → `tools` (`{ label, _entry }`); waits for a running
--- tool scan, as the picker did (`ws._tool_waiters`).
CALLS["Profiles/1.tool_choices"] = function(ws, p, cb)
    if ws and ws._tool_state == "scanning" then
        vim.notify("loomworks: waiting for tool detection...", vim.log.levels.INFO)
        ws._tool_waiters[#ws._tool_waiters + 1] = function() CALLS["Profiles/1.tool_choices"](ws, p, cb) end
        return
    end
    local r = wv().profile_tool_choices(ws, set_object(p.config_set))
    if r.outcome ~= "ok" then return cb(r) end
    local tools = {}
    for i, e in ipairs(r.tools) do
        tools[i] = { label = e.tool_label or e.tool_key or "(default)", _entry = e }
    end
    cb({ outcome = "ok", tools = tools })
end
CALLS["Profiles/1.add_tool"] = function(_, p, cb) cb(outcome(wv().add_profile_tool(object(p.profile), p.tool))) end
--- The device choice's write ended (loomworks.device_source, which reported
--- a failure) as an outcome.
local function chosen(cb)
    return function(ok, err)
        if ok then return cb({ outcome = "ok" }) end
        cb({ outcome = "refused", message = err, notified = true })
    end
end
--- `{ profile, device }` (`device` a loomworks.device_source record of its
--- scan; step 5o C2d-2): the profile's device choice.
CALLS["Profiles/1.set_device"] = function(ws, p, cb)
    local profile = object(p.profile)
    if not profile then return cb({ outcome = "refused", message = "no profile (not a row of the workspace view)" }) end
    require("loomworks.device_source").select(ws, profile, p.device, chosen(cb))
end
--- `{ profile }`: the profile's device choice cleared.
CALLS["Profiles/1.clear_device"] = function(ws, p, cb)
    local profile = object(p.profile)
    if not profile then return cb({ outcome = "refused", message = "no profile (not a row of the workspace view)" }) end
    require("loomworks.device_source").clear(ws, profile, chosen(cb))
end
CALLS["Profiles/1.remove_tool"] = function(_, p, cb)
    cb(outcome(wv().remove_profile_tool(object(p.profile), p.tool)))
end

-- ---------------------------------------------------------------------------
-- ConfigSets/1
-- ---------------------------------------------------------------------------

--- `{}` → `sets`: rows `{ name, auto, description?, candidate?, desc? }`,
--- a declared set's row bound to its object, an automatic one's `desc` its
--- mappings.
CALLS["ConfigSets/1.candidates"] = function(ws, _, cb)
    local r = wv().config_set_candidates(ws)
    local sets = {}
    for i, s in ipairs(r.sets) do
        local row = { name = s.name, auto = s.auto, description = s.description, candidate = s.candidate }
        if s.mappings then
            local keys, parts = vim.tbl_keys(s.mappings), {}
            table.sort(keys)
            for _, k in ipairs(keys) do parts[#parts + 1] = k .. "→" .. s.mappings[k] end
            row.desc = table.concat(parts, ", ")
        end
        require("loomworks.status_source").bind(row, s.config_set)
        sets[i] = row
    end
    cb({ outcome = "ok", sets = sets })
end
--- Whether `mappings` is a generated template's (project key →
--- configuration name), not the dialog's rows.
local function template(mappings)
    return type(next(mappings or {})) == "string"
end
--- The dialog's mappings (project row → configuration choice `{ name }`)
--- as objects, or nil + the refusal of the first that does not resolve. The
--- project is the object the in-process view bound to its row; the
--- configuration is resolved by name in it exactly as the daemon resolves a
--- mapping (core_interfaces `mappings_of`, API.md §20): any of the project's
--- configurations (a preset's, a source-missing one) but a removed one, and
--- refused with the daemon's message.
--- @param mappings table
--- @return table|nil objects, table|nil refusal
local function mapping_objects(mappings)
    local out = {}
    for project, choice in pairs(mappings or {}) do
        local po = object(project)
        if not po then return nil, { outcome = "refused", message = "no project (not a row of the workspace view)" } end
        local name = type(choice) == "table" and choice.name or nil
        local co = name ~= nil and po:get_configuration(name) or nil
        if not co or co._removed then
            return nil, { outcome = "refused", message = "no configuration '" .. tostring(name)
                .. "' in project '" .. tostring(po.key) .. "'" }
        end
        out[po] = co
    end
    return out
end
--- `{ name, mappings }` → `config_set`.
CALLS["ConfigSets/1.add"] = function(ws, p, cb)
    if template(p.mappings) then
        -- The template the generated sets offered: exactly that set, or
        -- refused when it changed since it was listed.
        return cb(created("config_set",
            wv().execute_create_config_set_from_candidate(ws, wv().candidate_token(p.name, p.mappings))))
    end
    local m, err = mapping_objects(p.mappings)
    if not m then return cb(err) end
    cb(created("config_set", wv().execute_create_config_set(ws, p.name, m)))
end
CALLS["ConfigSets/1.update"] = function(_, p, cb)
    local m, err = mapping_objects(p.mappings)
    if not m then return cb(err) end
    cb(outcome(wv().execute_edit_config_set(object(p.config_set), p.name, m)))
end
CALLS["ConfigSets/1.remove"] = function(ws, p, cb)
    cb(outcome(wv().execute_delete_config_set(ws, object(p.config_set))))
end

-- ---------------------------------------------------------------------------
-- Projects/1
-- ---------------------------------------------------------------------------

--- The objects of a Projects/1 call's entity params (`fields`: param names)
--- in the `in-process` mode, or nil + the refusal of the first a row does
--- not name (an unbound row: nothing to write).
local function objects(p, fields)
    local out = {}
    for _, f in ipairs(fields) do
        out[f] = object(p[f])
        if out[f] == nil then
            return nil, { outcome = "refused", message = "no " .. f .. " (not a row of the workspace view)" }
        end
    end
    return out
end

--- A Projects/1 body on the objects of its entity params: `fn(o, p)` → its
--- outcome.
local function on_objects(fields, fn)
    return function(_, p, cb)
        local o, err = objects(p, fields)
        if not o then return cb(err) end
        cb(fn(o, p))
    end
end

--- `{ path, type }` (the browser's entry: its absolute directory and the
--- type picked) → `key`, `path`: the project's key and path derived from the
--- directory as the browser did (in-process the derivation only; the
--- daemon's `candidates` also detects what the project would declare).
CALLS["Projects/1.candidates"] = function(ws, p, cb)
    local abs = tostring(p.path):gsub("\\", "/")
    local key, path = wv().derive_key_and_path((ws.root:gsub("\\", "/")), abs, vim.fn.fnamemodify(abs, ":t"))
    cb({ outcome = "ok", key = key, path = path })
end
--- `{ key, type, path?, mappings?, tool? }` (`tool` the picked tool entry)
--- → `project`.
CALLS["Projects/1.add"] = function(ws, p, cb)
    local ok, err, project = wv().execute_add_project(ws, p.key, p.type, p.path,
        { mappings = p.mappings, tool_entry = p.tool })
    cb(outcome(ok, err, { project = project }))
end
--- `{ project }` → the declaration (workspace_view.project_declaration: no
--- ids in-process).
CALLS["Projects/1.declaration"] = on_objects({ "project" }, function(o)
    return wv().project_declaration(o.project)
end)
--- `{ project, configuration?, name, fields }` (`configuration` the row
--- edited; none for a new configuration).
CALLS["Projects/1.configuration_save"] = on_objects({ "project" }, function(o, p)
    local cfg = object(p.configuration)
    if p.configuration ~= nil and cfg == nil then
        return { outcome = "refused", message = "no configuration (not a row of the workspace view)" }
    end
    return outcome(wv().execute_save_configuration(o.project, cfg, p.name, p.fields))
end)
CALLS["Projects/1.configuration_remove"] = on_objects({ "project", "configuration" }, function(o)
    return outcome(wv().execute_delete_configuration(o.project, o.configuration))
end)
--- `{ project, launch?, name, data }` (`launch` the row edited; none for a
--- new launch configuration) → `launch`.
CALLS["Projects/1.launch_save"] = on_objects({ "project" }, function(o, p)
    local launch = object(p.launch)
    if p.launch ~= nil and launch == nil then
        return { outcome = "refused", message = "no launch configuration (not a row of the workspace view)" }
    end
    local ok, err, saved = wv().execute_save_launch_config(o.project, launch, p.name, p.data)
    return outcome(ok, err, { launch = saved })
end)
CALLS["Projects/1.launch_remove"] = on_objects({ "project", "launch" }, function(o)
    return outcome(wv().execute_delete_launch_config(o.project, o.launch))
end)
CALLS["Projects/1.variable_save"] = on_objects({ "project" }, function(o, p)
    return outcome(wv().execute_save_variable(o.project, p.variable, p.name, p.data))
end)
CALLS["Projects/1.variable_remove"] = on_objects({ "project" }, function(o, p)
    return outcome(wv().execute_delete_variable(o.project, p.variable))
end)
CALLS["Projects/1.type_config_set"] = on_objects({ "project" }, function(o, p)
    return outcome(wv().save_type_config_field(o.project, p.field, p.value))
end)
CALLS["Projects/1.deploy_save"] = on_objects({ "project" }, function(o, p)
    return outcome(wv().save_deploy(o.project, p.deploy))
end)
--- `{ project, templates }` → `values` (each template expanded under the
--- active profile; refused without one).
CALLS["Projects/1.expand_preview"] = on_objects({ "project" }, function(o, p)
    return wv().expand_preview(o.project, p.templates)
end)

-- ---------------------------------------------------------------------------
-- Sdks/1 and Toolchains/1
-- ---------------------------------------------------------------------------

--- `{ provider? }` → `providers` (`{ id, label, path_prompt?, found }`,
--- `found` the installations `{ path, version? }`).
--- `{ unit }` (a profile's unit row; step 5o C2d-2) → `options`: its
--- configuration unit's build options, read synchronously from its build
--- directory (the module's `get_options`); refused when there are none (not
--- configured, or a module without options).
CALLS["Projects/1.unit_options"] = function(_, p, cb)
    local o = object(p.unit)
    if o and not o.mark_deleting then o = o._config_unit end -- a unit row's project-in-profile
    if not o then return cb({ outcome = "refused", message = "no configuration unit (not a row of the workspace view)" }) end
    local options = o:options()
    if not options or #options == 0 then
        return cb({ outcome = "refused", message = "no build options available (project may need configure)" })
    end
    cb({ outcome = "ok", options = options })
end

CALLS["Sdks/1.detect"] = function(_, p, cb) cb(wv().sdk_detect(p.provider)) end
--- `{ provider, path }` (`path` absolute) → `sdk`.
CALLS["Sdks/1.add"] = function(ws, p, cb) cb(created("sdk", wv().add_sdk(ws, p.provider, p.path))) end
--- `{ sdk }`: the SDK's row.
CALLS["Sdks/1.remove"] = function(ws, p, cb)
    local o, err = objects(p, { "sdk" })
    if not o then return cb(err) end
    cb(outcome(wv().remove_sdk(ws, o.sdk)))
end
CALLS["Toolchains/1.rescan"] = function(_, _, cb)
    require("loomworks").rescan_tools()
    cb(outcome(true))
end

-- ---------------------------------------------------------------------------
-- Build/1 (step 5o C2d)
-- ---------------------------------------------------------------------------

--- An operation's scope in-process: `{ profile }` (the profile row's
--- object) or `{ units }` (each unit row's configuration unit, its
--- project-in-profile's), or nil + the refusal of a row the in-process view
--- did not bind (or a unit row with no unit yet).
--- @param p { profile?: table, units?: table[] }
--- @return table|nil scope, table|nil refusal
local function op_scope(p)
    local function no(what)
        return nil, { outcome = "refused", message = "no " .. what .. " (not a row of the workspace view)" }
    end
    if p.profile ~= nil then
        local profile = object(p.profile)
        if not profile then return no("profile") end
        return { profile = profile }
    end
    local units = {}
    for _, row in ipairs(p.units or {}) do
        local o = object(row)
        if o and not o.mark_deleting then o = o._config_unit end -- a unit row's project-in-profile
        if not o then return no("configuration unit") end
        units[#units + 1] = o
    end
    if #units == 0 then return nil, { outcome = "refused", message = "an operation names a profile or units" } end
    return { units = units }
end

--- An operation's Future as its outcome through `cb`: ok once it resolved,
--- refused with its error.
--- @param f loomworks.Future
--- @param cb fun(r: table)
local function settle(f, cb)
    f:next(function() cb({ outcome = "ok" }) end,
        function(err) cb({ outcome = "refused", message = tostring(err) }) end)
end

--- `fn(unit)` (a Future) on each unit in turn, its outcome through `cb`: the
--- first rejection stops it.
--- @param units loomworks.ConfigUnit[]
--- @param fn fun(unit: loomworks.ConfigUnit): loomworks.Future
--- @param cb fun(r: table)
local function each_unit(units, fn, cb)
    local function step(i)
        if i > #units then return cb({ outcome = "ok" }) end
        fn(units[i]):next(function() step(i + 1) end,
            function(err) cb({ outcome = "refused", message = tostring(err) }) end)
    end
    step(1)
end

--- `{ profile | units, jobs?, force? }`: the in-process build (it asks its
--- own artifact-conflict question; `force` is the daemon call's).
CALLS["Build/1.build"] = function(_, p, cb)
    local scope, err = op_scope(p)
    if not scope then return cb(err) end
    local opts = p.jobs and { parallel_jobs = p.jobs } or nil
    if scope.profile then return settle(scope.profile:build(opts), cb) end
    local overseer = require("loomworks.overseer")
    each_unit(scope.units, function(unit)
        return overseer.run_configuration_action(unit, "build", nil, opts)
    end, cb)
end
--- `{ profile | units }`.
CALLS["Build/1.configure"] = function(_, p, cb)
    local scope, err = op_scope(p)
    if not scope then return cb(err) end
    if scope.profile then return settle(scope.profile:configure(), cb) end
    local overseer = require("loomworks.overseer")
    each_unit(scope.units, function(unit)
        return overseer.run_configuration_action(unit, "configure")
    end, cb)
end
--- `{ profile | units }`: the module clean (the configuration kept).
CALLS["Build/1.clean"] = function(_, p, cb)
    local scope, err = op_scope(p)
    if not scope then return cb(err) end
    if scope.profile then return settle(scope.profile:clean(), cb) end
    each_unit(scope.units, function(unit) return unit:clean() end, cb)
end

-- ---------------------------------------------------------------------------
-- Maintenance/1
-- ---------------------------------------------------------------------------

--- The deletion targets (API.md §22): exactly one of `profile` (a profile
--- row), `unit` (a profile's unit row), `build_dir` (an orphaned entry's
--- row), `project` (a project row), `stray_dir` (the path exactly as the view
--- lists it) or `orphans = true`.
local TARGETS = { "profile", "unit", "build_dir", "stray_dir", "orphans", "project" }

--- The one kind `t` names, or nil when it names none or several.
--- @param t table|nil
--- @return string|nil
local function target_kind(t)
    local kind
    for _, k in ipairs(TARGETS) do
        if type(t) == "table" and t[k] ~= nil and t[k] ~= false then
            if kind then return nil end
            kind = k
        end
    end
    return kind
end

--- A deletion target's objects in-process (the rows' bound objects:
--- loomworks.deletion_plan's target shape), or nil + the refusal.
--- @param t table|nil
--- @return table|nil target, table|nil refusal
local function deletion_object(t)
    local kind = target_kind(t)
    local function no(what)
        return nil, { outcome = "refused", message = "no " .. what .. " (not a row of the workspace view)" }
    end
    if not kind then
        return nil, { outcome = "refused", message = "a deletion target is exactly one of profile, unit, "
            .. "build_dir, stray_dir, orphans, project" }
    end
    if kind == "stray_dir" then
        if type(t.stray_dir) ~= "string" then return no("stray directory") end
        return { stray_dir = t.stray_dir }
    elseif kind == "orphans" then
        return { orphans = true }
    end
    local o = object(t[kind])
    if kind == "unit" and o and not o.mark_deleting then o = o._config_unit end -- a unit row's project-in-profile
    if kind == "build_dir" and o and getmetatable(o) == nil then o = o.build_dir_obj end -- an orphaned entry
    if o == nil then return no(kind == "build_dir" and "build directory" or kind) end
    return { [kind] = o }
end

--- `{ target, plan?, yes? }` (step 5o C2c-2): without `yes` the `confirm
--- { lines, plan }` of what would be deleted (or refused: a stale target,
--- nothing to delete — `stream = "out"`); with `yes` and the `plan` the
--- confirmation returned, the deletion of exactly that, `cb` once it ended
--- (loomworks.model_commands `execute_deletion`: planned, then the workspace
--- operation lock and every build-directory lock, planned again under them,
--- executed through the Workspace's deletion paths).
CALLS["Maintenance/1.execute_deletion"] = function(ws, p, cb)
    local target, err = deletion_object(p.target)
    if not target then return cb(err) end
    if p.yes and p.plan == nil then
        return cb({ outcome = "refused", message = "a deletion is confirmed with the plan it listed" })
    end
    wv().execute_deletion(ws, target, p.plan, p.yes == true, cb)
end
--- `{ plan?, yes? }`: without `yes` the `confirm` listing what the nuke
--- removes; with it and the plan, the nuke of the workspace (its root: the
--- loaded workspace's, else the refused load's; never a param).
CALLS["Maintenance/1.nuke"] = function(ws, p, cb)
    if p.yes and p.plan == nil then
        return cb({ outcome = "refused", message = "a nuke is confirmed with the plan it listed" })
    end
    cb(wv().nuke(ws, p.plan, p.yes == true))
end

-- ---------------------------------------------------------------------------
-- Daemon calls (step 5o C2a)
-- ---------------------------------------------------------------------------

--- What a refusal of each routed method names (as editor_ops' verbs).
local VERB = {
    ["Workspace/1.publish"] = "publish", ["Workspace/1.publish_one"] = "publish",
    ["Workspace/1.revert_to_baseline"] = "revert", ["Workspace/1.revert_one"] = "revert",
    ["Workspace/1.set_intent"] = "intent", ["Workspace/1.set_description"] = "description",
    ["Workspace/1.trust_accept"] = "trust", ["Workspace/1.delete_user_prefs"] = "working copy deletion",
    ["Profiles/1.set_active"] = "profile activation", ["Profiles/1.create"] = "profile creation",
    ["Profiles/1.tool_choices"] = "toolchain choices", ["Profiles/1.add_tool"] = "toolchain",
    ["Profiles/1.remove_tool"] = "toolchain", ["ConfigSets/1.candidates"] = "configuration sets",
    ["Profiles/1.set_device"] = "device choice", ["Profiles/1.clear_device"] = "device choice",
    ["Projects/1.unit_options"] = "build options",
    ["ConfigSets/1.add"] = "configuration set", ["ConfigSets/1.update"] = "configuration set",
    ["ConfigSets/1.remove"] = "configuration set",
    ["Projects/1.candidates"] = "project", ["Projects/1.add"] = "project",
    ["Projects/1.declaration"] = "project declaration",
    ["Projects/1.configuration_save"] = "configuration", ["Projects/1.configuration_remove"] = "configuration",
    ["Projects/1.launch_save"] = "launch config", ["Projects/1.launch_remove"] = "launch config",
    ["Projects/1.deploy_save"] = "deploy steps", ["Projects/1.expand_preview"] = "preview",
    ["Projects/1.variable_save"] = "variable", ["Projects/1.variable_remove"] = "variable",
    ["Projects/1.type_config_set"] = "project field",
    ["Sdks/1.detect"] = "SDK detection", ["Sdks/1.add"] = "SDK", ["Sdks/1.remove"] = "SDK",
    ["Toolchains/1.rescan"] = "toolchain detection",
    ["Maintenance/1.execute_deletion"] = "deletion", ["Maintenance/1.nuke"] = "nuke",
    ["Build/1.build"] = "build", ["Build/1.configure"] = "configure", ["Build/1.clean"] = "clean",
}

--- In `daemon` mode with no workspace loaded in the editor, why a recovery
--- method is refused: the lw command that does it (spec §19.16 "Model
--- writes"; until the editor can connect to a daemon for a root it has not
--- loaded).
local NO_WORKSPACE = {
    ["Maintenance/1.nuke"] = "the workspace is not loaded in the editor — run lw nuke in a terminal",
    ["Workspace/1.trust_accept"] = "the workspace is not loaded in the editor — run lw trust in a terminal "
        .. "(lw trust --discard discards the working copy)",
    ["Workspace/1.delete_user_prefs"] = "the workspace is not loaded in the editor — "
        .. "run lw trust --discard in a terminal",
}

--- A refused outcome of `method` with `why`.
local function refusal(method, why)
    return { outcome = "refused", message = (VERB[method] or method) .. ": " .. tostring(why) }
end

--- Send `method` with `args` to the workspace daemon of `ws` (the
--- observer's plain call, as editor_ops.plain): `cb` gets the method's
--- result — `ok` (passed through `shape` when given) or `confirm` as the
--- daemon answered — or a refusal naming why: the method not carried now
--- (§19.16 "Availability"), the daemon's `refused` / `declined`, a method
--- it lacks, a failed or unanswered call. Nothing runs in-process.
--- @param ws loomworks.Workspace|nil
--- @param method string
--- @param args table
--- @param cb fun(r: table)
--- @param shape? fun(res: table): table
local function send(ws, method, args, cb, shape)
    local eo = require("loomworks.daemon.editor_ops")
    local obs = eo.carrier(method, ws)
    if not obs then
        local _, mode_obs = eo.daemon_of(ws)
        return cb(refusal(method, mode_obs and mode_obs.state ~= "stopped" and mode_obs:refusal(method)
            or "the workspace is no longer loaded"))
    end
    obs:request(method, args, function(r)
        local res = r.outcome == "ok" and type(r.result) == "table" and r.result or nil
        if res and res.outcome == "ok" then return cb(shape and shape(res) or res) end
        if res and res.outcome == "confirm" then return cb(res) end
        if r.outcome == "degraded" then return cb(refusal(method, obs:refusal(method))) end
        if res and res.outcome == "refused" then
            local out = refusal(method, res.message)
            out.notes, out.note_roles, out.stream = res.notes, res.note_roles, res.stream
            return cb(out)
        end
        if res and res.outcome == "declined" then
            return cb(refusal(method, "the workspace daemon declined it (" .. tostring(res.reason) .. ")"))
        end
        cb(refusal(method, "the call to the workspace daemon failed: "
            .. tostring(r.reason or (res and res.outcome) or "?")))
    end)
end

--- The reference an entity param (a row, or a description handle's `_row`)
--- is sent as: `{ id }`, or nil when the row carries none.
local function id_ref(x)
    local row = type(x) == "table" and (x._row or x) or nil
    if row and row.id ~= nil then return { id = row.id } end
    return nil
end

--- The params' entity refs (`fields`: `{ param, kind }` pairs) as the
--- wire's, or nil + the refusal of the first that has no id.
local function refs(method, p, fields)
    local out = {}
    for _, f in ipairs(fields) do
        local r = id_ref(p[f[1]])
        if not r then return nil, refusal(method, "no " .. f[2] .. " id (not a row of the workspace view)") end
        out[f[1]] = r
    end
    return out
end

--- A project row → configuration choice mapping (the dialog's) or a template's
--- project key → configuration name as the wire's (project key →
--- configuration name; an unmapped project absent).
local function wire_mappings(mappings)
    local out = {}
    for project, cfg in pairs(mappings or {}) do
        if type(project) == "string" then
            out[project] = cfg
        elseif cfg then
            out[project.key] = cfg.name
        end
    end
    return out
end

--- A `create` / `tool_choices` set: a candidate entry's `{ candidate }`, a
--- row's `{ id }`, or nil.
local function set_ref(x)
    if type(x) == "table" and x.candidate ~= nil then return { candidate = x.candidate } end
    return id_ref(x)
end

--- The routed methods' daemon bodies: `fn(ws, params, cb)`.
--- @type table<string, fun(ws: loomworks.Workspace|nil, p: table, cb: fun(r: table))>
local ROUTED = {}

--- A method whose params are its entity refs plus the plain `extra` ones.
local function by_ref(method, fields, extra)
    ROUTED[method] = function(ws, p, cb)
        local args, err = refs(method, p, fields)
        if not args then return cb(err) end
        for _, k in ipairs(extra or {}) do args[k] = p[k] end
        send(ws, method, args, cb)
    end
end

ROUTED["Workspace/1.publish"] = function(ws, _, cb) send(ws, "Workspace/1.publish", {}, cb) end
ROUTED["Workspace/1.revert_to_baseline"] = function(ws, _, cb) send(ws, "Workspace/1.revert_to_baseline", {}, cb) end
by_ref("Workspace/1.publish_one", { { "item", "item" } })
by_ref("Workspace/1.revert_one", { { "item", "item" } })
by_ref("Workspace/1.set_intent", { { "item", "item" } }, { "intent" })
by_ref("Workspace/1.set_description", { { "item", "item" } }, { "text" })
--- `{ plan? }`: without it the daemon's `confirm` (the review, spec §17.4),
--- with it the trust of what it showed.
ROUTED["Workspace/1.trust_accept"] = function(ws, p, cb)
    send(ws, "Workspace/1.trust_accept", { plan = p.plan }, cb)
end
ROUTED["Workspace/1.delete_user_prefs"] = function(ws, p, cb)
    send(ws, "Workspace/1.delete_user_prefs", { plan = p.plan }, cb)
end

by_ref("Profiles/1.set_active", { { "profile", "profile" } })
by_ref("Profiles/1.add_tool", { { "profile", "profile" } }, { "tool" })
by_ref("Profiles/1.remove_tool", { { "profile", "profile" } }, { "tool" })
by_ref("Profiles/1.clear_device", { { "profile", "profile" } })
--- `device`: a `Devices/1` record (loomworks.device_source's scan), sent by
--- its id (step 5o C2d-2).
ROUTED["Profiles/1.set_device"] = function(ws, p, cb)
    local method = "Profiles/1.set_device"
    local args, err = refs(method, p, { { "profile", "profile" }, { "device", "device" } })
    if not args then return cb(err) end
    send(ws, method, args, cb)
end
--- `tool`: a tool_choices entry (the wire's own) as `create` takes it.
ROUTED["Profiles/1.create"] = function(ws, p, cb)
    local set = set_ref(p.config_set)
    if not set then return cb(refusal("Profiles/1.create", "no configuration set id")) end
    local tool = nil
    if p.tool then
        tool = p.tool.sdk and { sdk = p.tool.key } or { module = p.tool.module, key = p.tool.key }
    end
    send(ws, "Profiles/1.create", { config_set = set, tool = tool, activate = p.activate == true or nil }, cb)
end
ROUTED["Profiles/1.tool_choices"] = function(ws, p, cb)
    local set = set_ref(p.config_set)
    if not set then return cb(refusal("Profiles/1.tool_choices", "no configuration set id")) end
    send(ws, "Profiles/1.tool_choices", { config_set = set }, cb)
end

--- `sets` as rows: a declared set's `id` its own.
ROUTED["ConfigSets/1.candidates"] = function(ws, _, cb)
    send(ws, "ConfigSets/1.candidates", {}, cb, function(res)
        local sets = {}
        for i, s in ipairs(res.sets or {}) do
            sets[i] = { id = s.config_set, name = s.name, auto = s.auto, description = s.description,
                candidate = s.candidate }
        end
        return { outcome = "ok", sets = sets }
    end)
end
ROUTED["ConfigSets/1.add"] = function(ws, p, cb)
    send(ws, "ConfigSets/1.add", { name = p.name, mappings = wire_mappings(p.mappings) }, cb)
end
ROUTED["ConfigSets/1.update"] = function(ws, p, cb)
    local args, err = refs("ConfigSets/1.update", p, { { "config_set", "configuration set" } })
    if not args then return cb(err) end
    args.name, args.mappings = p.name, wire_mappings(p.mappings)
    send(ws, "ConfigSets/1.update", args, cb)
end
by_ref("ConfigSets/1.remove", { { "config_set", "configuration set" } })

ROUTED["Projects/1.candidates"] = function(ws, p, cb)
    send(ws, "Projects/1.candidates", { path = p.path, type = p.type }, cb)
end
--- `mappings` as the wire's (absent when empty: an empty table is no JSON
--- object); `tool` a picked tool entry, sent by its key.
ROUTED["Projects/1.add"] = function(ws, p, cb)
    local mappings = wire_mappings(p.mappings)
    local tool = p.tool and { key = p.tool.tool_key or p.tool.key } or nil
    send(ws, "Projects/1.add", { key = p.key, type = p.type, path = p.path,
        mappings = next(mappings) and mappings or nil, tool = tool }, cb)
end
by_ref("Projects/1.declaration", { { "project", "project" } })
--- The configuration editor's save: `configuration` the row edited (none for
--- a new configuration); `fields` the dialog's (an empty `options` /
--- `variables` sent as an object).
ROUTED["Projects/1.configuration_save"] = function(ws, p, cb)
    local method = "Projects/1.configuration_save"
    local args, err = refs(method, p, { { "project", "project" } })
    if not args then return cb(err) end
    if p.configuration ~= nil then
        args.configuration = id_ref(p.configuration)
        if not args.configuration then
            return cb(refusal(method, "no configuration id (not a row of the workspace view)"))
        end
    end
    local fields = vim.deepcopy(p.fields or {})
    for _, k in ipairs({ "options", "variables" }) do
        if type(fields[k]) == "table" and next(fields[k]) == nil then fields[k] = vim.empty_dict() end
    end
    args.name, args.fields = p.name, fields
    send(ws, method, args, cb)
end
by_ref("Projects/1.configuration_remove", { { "project", "project" }, { "configuration", "configuration" } })
--- The launch editor's save: `launch` the row edited (none for a new
--- launch configuration); an empty `env` / `deploy` of `data` is absent on
--- the wire (an empty table is no JSON object; absent or empty removes it).
ROUTED["Projects/1.launch_save"] = function(ws, p, cb)
    local method = "Projects/1.launch_save"
    local args, err = refs(method, p, { { "project", "project" } })
    if not args then return cb(err) end
    if p.launch ~= nil then
        args.launch = id_ref(p.launch)
        if not args.launch then
            return cb(refusal(method, "no launch configuration id (not a row of the workspace view)"))
        end
    end
    local data = vim.deepcopy(p.data or {})
    for _, k in ipairs({ "env", "deploy" }) do
        if type(data[k]) == "table" and next(data[k]) == nil then data[k] = nil end
    end
    args.name, args.data = p.name, data
    send(ws, method, args, cb)
end
by_ref("Projects/1.launch_remove", { { "project", "project" }, { "launch", "launch configuration" } })
--- The project's whole deploy declaration; an empty one is absent (removes it).
ROUTED["Projects/1.deploy_save"] = function(ws, p, cb)
    local args, err = refs("Projects/1.deploy_save", p, { { "project", "project" } })
    if not args then return cb(err) end
    if type(p.deploy) == "table" and next(p.deploy) ~= nil then args.deploy = vim.deepcopy(p.deploy) end
    send(ws, "Projects/1.deploy_save", args, cb)
end
by_ref("Projects/1.expand_preview", { { "project", "project" } }, { "templates" })
by_ref("Projects/1.variable_save", { { "project", "project" } }, { "variable", "name", "data" })
by_ref("Projects/1.variable_remove", { { "project", "project" } }, { "variable" })
by_ref("Projects/1.type_config_set", { { "project", "project" } }, { "field", "value" })

-- (step 5o C2c-1) The SDK section and `L`. `add`'s `path` is absolute (the
-- caller makes a typed one so: the daemon refuses a relative path).
by_ref("Sdks/1.detect", {}, { "provider" })
by_ref("Sdks/1.add", {}, { "provider", "path" })
by_ref("Sdks/1.remove", { { "sdk", "SDK" } })
--- `unit`: a profile's unit row, sent by its `unit_id` (step 5o C2d-2).
ROUTED["Projects/1.unit_options"] = function(ws, p, cb)
    local method = "Projects/1.unit_options"
    local id = type(p.unit) == "table" and p.unit.unit_id or nil
    if id == nil then return cb(refusal(method, "no configuration unit id (not a row of the workspace view)")) end
    send(ws, method, { unit = { id = id } }, cb)
end
ROUTED["Toolchains/1.rescan"] = function(ws, _, cb) send(ws, "Toolchains/1.rescan", {}, cb) end

-- (step 5o C2c-2) The deletions and the nuke: a confirmation (a plain call
-- answering `confirm` or `refused`), then — confirmed — a task the editor
-- owns, followed to its end.

--- Send a confirmed `method` with `args` to the workspace daemon of `ws` as
--- a call whose task the editor owns (Observer:start_owned) and follow it:
--- `cb` once, at its `done` — `ok` for exit 0 (DELETE OK), else a refusal
--- naming the task's end (`delete stopped: …`, a held lock's holder, a
--- failed removal) — or at once when nothing ran: the method not carried
--- now, the daemon's `refused` / `declined`, a method it lacks, a failed
--- call. Never at the acceptance; nothing runs in-process.
--- @param ws loomworks.Workspace|nil
--- @param method string
--- @param args table
--- @param cb fun(r: table)
local function follow(ws, method, args, cb)
    local eo = require("loomworks.daemon.editor_ops")
    local obs = eo.carrier(method, ws)
    if not obs then
        local _, mode_obs = eo.daemon_of(ws)
        return cb(refusal(method, mode_obs and mode_obs.state ~= "stopped" and mode_obs:refusal(method)
            or "the workspace is no longer loaded"))
    end
    obs:start_owned(method, args, {
        on_reply = function(r)
            if r.outcome == "accepted" then return end -- its `done` answers
            if r.outcome == "degraded" then return cb(refusal(method, obs:refusal(method))) end
            if r.outcome == "refused" then
                local out = refusal(method, r.message)
                out.notes, out.note_roles, out.stream = r.notes, r.note_roles, r.stream
                return cb(out)
            end
            if r.outcome == "declined" then
                return cb(refusal(method, "the workspace daemon declined it (" .. tostring(r.reason) .. ")"))
            end
            cb(refusal(method, "the call to the workspace daemon failed: " .. tostring(r.reason or r.outcome)))
        end,
        on_done = function(task, reason)
            if reason then return cb(refusal(method, reason)) end
            if task and task.exit_code == 0 then return cb({ outcome = "ok" }) end
            cb(refusal(method, task and task.error
                or ("its task ended with exit " .. tostring(task and task.exit_code))))
        end,
    })
end

--- A deletion target as the wire's (API.md §22): a row's id (`{ id }`; a
--- unit row's `unit_id`), the stray path exactly as the view listed it, or
--- `orphans`; nil + the refusal of a row without an id (never by its key).
--- @param method string
--- @param t table|nil
--- @return table|nil target, table|nil refusal
local function wire_target(method, t)
    local kind = target_kind(t)
    if not kind then
        return nil, refusal(method, "a deletion target is exactly one of profile, unit, build_dir, stray_dir, "
            .. "orphans, project")
    end
    if kind == "stray_dir" then
        if type(t.stray_dir) ~= "string" then return nil, refusal(method, "no stray directory") end
        return { stray_dir = t.stray_dir } -- verbatim: the daemon matches it against its stray set
    elseif kind == "orphans" then
        return { orphans = true }
    end
    local row = type(t[kind]) == "table" and (t[kind]._row or t[kind]) or nil
    local id = nil
    if row then
        if kind == "unit" then id = row.unit_id else id = row.id end
    end
    if id == nil then
        local what = ({ unit = "configuration unit", build_dir = "build directory" })[kind] or kind
        return nil, refusal(method, "no " .. what .. " id (not a row of the workspace view)")
    end
    return { [kind] = { id = id } }
end

--- The editor's own running tasks a confirmed deletion of `t` would meet on
--- a build-directory lock, by the ids their `start` meta names (API.md §4.2,
--- §22; step 5o C2d-2 — never by key or path): one of the `unit_ids` the
--- daemon's confirmation listed (the units whose build state the plan
--- removes: a project's every unit, also one no profile maps; a profile's
--- not kept; none for orphaned and stray directories), or for a profile its
--- row id. A call whose task has not started yet is matched by the ids it
--- was sent with (a call by row ids). Without ids from a confirmation only a
--- profile's id matches. The ids only pick the tasks stopped first; what is
--- deleted is decided by the target and plan. A task on a build directory
--- only shared with the target's (another unit's) is not matched: the
--- daemon refuses the deletion on its lock, naming it.
--- @param t table
--- @param unit_ids string[]|nil the confirmation's `unit_ids`
--- @return fun(task: loomworks.RemoteTask|nil, call: table|nil): boolean
local function deletion_tasks(t, unit_ids)
    local kind = target_kind(t)
    local row = kind and type(t[kind]) == "table" and (t[kind]._row or t[kind]) or {}
    local profile_id = kind == "profile" and row.id or nil
    local ids = {}
    for _, id in ipairs(type(unit_ids) == "table" and unit_ids or {}) do ids[#ids + 1] = id end
    local want = {}
    for _, id in ipairs(ids) do want[id] = true end
    return function(task, call)
        if task then return task:names_ids(profile_id, ids) end
        if not call then return false end
        if profile_id ~= nil and call.profile_id == profile_id then return true end
        for _, id in ipairs(call.unit_ids or {}) do
            if want[id] then return true end
        end
        return false
    end
end

--- Without `yes` the daemon's confirmation; with it (and the `plan` the
--- confirmation returned — never `yes` alone), the editor's own tasks on the
--- target cancelled first (as a clean does), then the deletion, followed.
ROUTED["Maintenance/1.execute_deletion"] = function(ws, p, cb)
    local method = "Maintenance/1.execute_deletion"
    local target, err = wire_target(method, p.target)
    if not target then return cb(err) end
    if not p.yes then
        return send(ws, method, { target = target }, function(r)
            -- The editor's own running tasks the confirmed deletion cancels
            -- first (spec/ui.md §1.10), after the daemon's listing: every
            -- call editor_ops.cancel_owned_matching stops, a not-yet-started
            -- one by the ids it was sent with too.
            local obs = r.outcome == "confirm" and require("loomworks.daemon.observer").of(ws) or nil
            local match, stopped = deletion_tasks(p.target, r.unit_ids), {}
            for _, call in ipairs(obs and obs:owned_calls() or {}) do
                if match(call.task, call) then
                    stopped[#stopped + 1] = "  " .. (call.task and tostring(call.task.name) or ("task " .. tostring(call.id)))
                end
            end
            if #stopped > 0 then
                table.sort(stopped)
                r.lines = vim.list_extend(vim.list_extend({}, r.lines or {}), { "Will stop running tasks:" })
                vim.list_extend(r.lines, stopped)
            end
            cb(r)
        end)
    end
    if p.plan == nil then return cb(refusal(method, "a deletion is confirmed with the plan it listed")) end
    -- `p.unit_ids` (the confirmation's, editor-side) is not sent.
    require("loomworks.daemon.editor_ops").cancel_owned_matching(ws, deletion_tasks(p.target, p.unit_ids), function()
        follow(ws, method, { target = target, plan = p.plan, yes = true }, cb)
    end)
end
--- The daemon nukes its own workspace: no root is ever sent. Confirmed,
--- every task the editor owns is cancelled first (the daemon refuses while
--- any of its tasks runs; the in-process nuke stops the editor's own).
ROUTED["Maintenance/1.nuke"] = function(ws, p, cb)
    local method = "Maintenance/1.nuke"
    if not p.yes then return send(ws, method, {}, cb) end
    if p.plan == nil then return cb(refusal(method, "a nuke is confirmed with the plan it listed")) end
    require("loomworks.daemon.editor_ops").cancel_owned_matching(ws, function() return true end, function()
        follow(ws, method, { plan = p.plan, yes = true }, cb)
    end)
end

-- (step 5o C2d) The Profiles section's operations: by the profile row's id
-- or the unit rows' `unit_id`s, never by key; a task the editor owns,
-- followed to its end.

--- An operation's scope as row ids (editor_ops.run_ids) and the unit rows it
--- covers (a profile's every unit row), or nil + the refusal of a row
--- without an id.
--- @param method string
--- @param p { profile?: table, units?: table[] }
--- @return table|nil scope, table rows_or_refusal
local function id_scope(method, p)
    if p.profile ~= nil then
        local row = type(p.profile) == "table" and (p.profile._row or p.profile) or {}
        if row.id == nil then return nil, refusal(method, "no profile id (not a row of the workspace view)") end
        local ids = {}
        for _, u in ipairs(row.units or {}) do
            if u.unit_id ~= nil then ids[#ids + 1] = u.unit_id end
        end
        return { profile_id = row.id, unit_ids = ids }, row.units or {}
    end
    local ids, rows = {}, {}
    for _, u in ipairs(p.units or {}) do
        if type(u) ~= "table" or u.unit_id == nil then
            return nil, refusal(method, "no configuration unit id (not a row of the workspace view)")
        end
        ids[#ids + 1], rows[#rows + 1] = u.unit_id, u
    end
    if #ids == 0 then return nil, refusal(method, "an operation names a profile or units") end
    return { unit_ids = ids }, rows
end

--- A routed `Build/1` operation (`op` its editor_ops method): `cb` once its
--- task ended — `ok` for exit 0 — or at once when nothing ran (refused,
--- declined, not carried; `notified` when editor_ops reported it).
--- @param method string
--- @param op "build"|"configure"|"clean"
local function by_ids(method, op)
    ROUTED[method] = function(ws, p, cb)
        local scope, rows = id_scope(method, p)
        if not scope then return cb(rows) end
        local block
        for _, u in ipairs(rows) do
            if u.artifact_block then block = u.artifact_block; break end
        end
        require("loomworks.daemon.editor_ops").run_ids(ws, op, scope,
            { jobs = op == "build" and p.jobs or nil, force = op == "build" and p.force or nil,
                artifact_block = op == "build" and block or nil }, {
                resolve = function() cb({ outcome = "ok" }) end,
                reject = function(err, notified)
                    cb({ outcome = "refused", message = tostring(err), notified = notified or nil })
                end,
            })
    end
end
by_ids("Build/1.build", "build")
by_ids("Build/1.configure", "configure")
by_ids("Build/1.clean", "clean")

--- The methods the status page calls, sorted (tests).
--- @return string[]
function M.methods()
    local names = {}
    for name in pairs(CALLS) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Whether `method` is a call to the workspace daemon in `daemon` mode
--- (step 5o C2a), never run in-process there.
--- @param method string
--- @return boolean
function M.routed(method)
    return ROUTED[method] ~= nil
end

--- Call a model method of the workspace `ws` (nil: the loaded workspace,
--- loomworks.daemon.observer.loaded_workspace).
--- In `daemon` mode it is a call to the workspace daemon (every method is
--- routed, step 5o C2c-2; a guard checks it, tests/ui_model_calls_spec.lua);
--- in the `in-process` mode its in-process body runs. With no workspace
--- loaded, `daemon` mode (the setup selection) refuses every method. `cb(r)`
--- gets its outcome (may be nil).
--- @param ws loomworks.Workspace|nil
--- @param method string `"<Interface>/<version>.<method>"`
--- @param params table|nil
--- @param cb fun(r: table)|nil
function M.call(ws, method, params, cb)
    local fn = CALLS[method]
    if not fn then error("loomworks.ui.model_calls: unknown method " .. tostring(method), 2) end
    params, cb = params or {}, cb or function() end
    -- (No workspace given: the loaded one. Its mode is its runtime
    -- selection's — never whether an observer is attached: in `daemon` mode
    -- with its observer gone a method is refused, not run in-process. With
    -- no workspace loaded at all the mode is the setup selection's; in
    -- `daemon` mode every method is then refused, nothing sent and nothing
    -- run — the recovery methods name their lw command, spec §19.16 "Model
    -- writes".)
    local target = ws or require("loomworks.daemon.observer").loaded_workspace()
    local daemon
    if target then
        daemon = require("loomworks.daemon.editor_ops").daemon_of(target)
    else
        daemon = require("loomworks").runtime_mode() == "daemon"
        if daemon then return cb(refusal(method, NO_WORKSPACE[method] or "the workspace is not loaded")) end
    end
    if daemon then
        local route = ROUTED[method]
        if not route then error("loomworks.ui.model_calls: " .. method .. " is not routed to the daemon", 2) end
        return route(target, params, cb)
    end
    return fn(target, params, cb)
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

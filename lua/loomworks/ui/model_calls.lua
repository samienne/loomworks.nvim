--- loomworks/ui/model_calls.lua — The status page's one route to model writes.
---
--- Step 5o part C0 (spec §19.19): every status-page action and dialog that
--- writes the model calls `M.call(ws, method, params, cb)` here, `method` a
--- catalogue method named with its interface (`"Profiles/1.set_active"`,
--- spec §19.20; API.md §6, §11, §19–§22). The ui never reaches the command
--- layer, the view-model's write adapters or the workspace's write methods
--- itself (a guard checks it, tests/ui_model_calls_spec.lua).
---
--- Each method is a call by id to the workspace daemon (part C2; the
--- editor holds no model, step 6b-α): the call sites keep the
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
--- here: those are only ever calls —
--- refused (the outcome says why) when the daemon cannot carry them, never
--- run in-process (spec §19.16 "Availability").
---
--- A deletion or nuke is confirmed (ui/actions.confirm_deletion): called
--- without `plan` it answers `confirm { lines, plan }` (or refused —
--- nothing to delete with `stream = "out"`); called again with that `plan`
--- and `yes` it runs. The confirmed call is a
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
--- sent as the row's id, `{ id = row.id }` (API.md §1.2 ItemRef / Ref; a
--- candidate entry `{ candidate }`); a row without one is refused, never
--- looked up by key.
--- A `Build/1` operation names a profile row (`profile`) or unit rows
--- (`units`, one of a profile row's `units[]` each — sent by its
--- `unit_id`); it is a task the editor owns, followed to
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
--- configuration choice table (a choice `{ name, id? }`, ui/config_set_editor),
--- each named as an entity param is (sent as the wire's
--- `[{ project = { id }, configuration = { id } }]`, an entry without an id
--- refused) — never by key or name; a
--- `candidate` of `ConfigSets/1.add` is a `ConfigSets/1.candidates` entry
--- (an automatic set, sent as its token).
---
--- `cb(r)` gets the outcome (API.md §4.1): `{ outcome = "ok", ... }` with
--- the method's result fields (a created object — its `{ id, key }` —
--- `changed`, …), `{ outcome = "confirm", lines, plan }`
--- (the call asks a confirmation: show `lines`, call again with `plan`), or
--- `{ outcome = "refused", message?, notified? }` (no message, or
--- `notified`: already reported). It may run before `call` returns (a
--- refusal) or later (a daemon call, on the main loop); callers must not
--- rely on either.

local M = {}

-- ---------------------------------------------------------------------------
-- Deletion targets
-- ---------------------------------------------------------------------------

--- The kinds a deletion target names (exactly one).
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

--- With no workspace loaded in the editor, why a recovery
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
--- @param ws any unused (the editor holds no model)
--- @param method string
--- @param args table
--- @param cb fun(r: table)
--- @param shape? fun(res: table): table
local function send(ws, method, args, cb, shape)
    local eo = require("loomworks.daemon.editor_ops")
    local obs = eo.carrier(method, ws)
    if not obs then
        local _, mode_obs = eo.daemon_of()
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

--- A project row → configuration choice mapping (the dialog's) as the
--- wire's `[{ project = { id }, configuration = { id } }]` (an unmapped
--- project absent), or nil + the refusal of the first row or choice that
--- has no id (never looked up by key).
--- @param method string
--- @param mappings table
--- @return table|nil, table|nil refusal
local function wire_mappings(method, mappings)
    local rows = {}
    for project, cfg in pairs(mappings or {}) do
        if cfg then rows[#rows + 1] = project end
    end
    -- In the rows' order (by project key, as the view lists them), so a
    -- call's args are stable.
    table.sort(rows, function(a, b) return tostring(a.key) < tostring(b.key) end)
    local out = {}
    for _, project in ipairs(rows) do
        local cfg = mappings[project]
        local pref, cref = id_ref(project), id_ref(cfg)
        if not pref then return nil, refusal(method, "no project id (not a row of the workspace view)") end
        if not cref then
            return nil, refusal(method, "no configuration id for '" .. tostring(cfg.name) .. "'")
        end
        out[#out + 1] = { project = pref, configuration = cref }
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

--- `sets` as rows: a declared set's `id` its own; an automatic one's
--- `mappings` as the daemon sent them (each `{ id, key }`).
ROUTED["ConfigSets/1.candidates"] = function(ws, _, cb)
    send(ws, "ConfigSets/1.candidates", {}, cb, function(res)
        local sets = {}
        for i, s in ipairs(res.sets or {}) do
            sets[i] = { id = s.config_set, name = s.name, auto = s.auto, description = s.description,
                candidate = s.candidate, mappings = s.mappings }
        end
        return { outcome = "ok", sets = sets }
    end)
end
--- `{ name, mappings }`, or `{ candidate }` a candidates entry (sent as its
--- token).
ROUTED["ConfigSets/1.add"] = function(ws, p, cb)
    if p.candidate ~= nil then
        local token = type(p.candidate) == "table" and p.candidate.candidate or p.candidate
        return send(ws, "ConfigSets/1.add", { candidate = token }, cb)
    end
    local mappings, err = wire_mappings("ConfigSets/1.add", p.mappings)
    if not mappings then return cb(err) end
    send(ws, "ConfigSets/1.add", { name = p.name, mappings = mappings }, cb)
end
ROUTED["ConfigSets/1.update"] = function(ws, p, cb)
    local args, err = refs("ConfigSets/1.update", p, { { "config_set", "configuration set" } })
    if not args then return cb(err) end
    local mappings, merr = wire_mappings("ConfigSets/1.update", p.mappings)
    if not mappings then return cb(merr) end
    args.name, args.mappings = p.name, mappings
    send(ws, "ConfigSets/1.update", args, cb)
end
by_ref("ConfigSets/1.remove", { { "config_set", "configuration set" } })

ROUTED["Projects/1.candidates"] = function(ws, p, cb)
    send(ws, "Projects/1.candidates", { path = p.path, type = p.type }, cb)
end
--- `mappings` as the wire's — set name → configuration name (API.md §19;
--- absent when empty: an empty table is no JSON object); `tool` a picked
--- tool entry, sent by its key.
ROUTED["Projects/1.add"] = function(ws, p, cb)
    local mappings = {}
    for set, cfg in pairs(p.mappings or {}) do mappings[set] = cfg end
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
--- @param ws any unused (the editor holds no model)
--- @param method string
--- @param args table
--- @param cb fun(r: table)
local function follow(ws, method, args, cb)
    local eo = require("loomworks.daemon.editor_ops")
    local obs = eo.carrier(method, ws)
    if not obs then
        local _, mode_obs = eo.daemon_of()
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
            -- first (spec/plugin.md UI §1.10), after the daemon's listing: every
            -- call editor_ops.cancel_owned_matching stops, a not-yet-started
            -- one by the ids it was sent with too.
            -- (The editor's observer: a `daemon`-mode editor holds no model.)
            local obs = r.outcome == "confirm" and ws == nil and require("loomworks.daemon.observer").current() or nil
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
--- any of its tasks runs).
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
                reject = function(err, notified, not_run)
                    cb({ outcome = "refused", message = tostring(err), notified = notified or nil,
                        not_run = not_run })
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
    for name in pairs(ROUTED) do names[#names + 1] = name end
    table.sort(names)
    return names
end

--- Whether `method` is a call to the workspace daemon (step 5o C2a): every
--- method of the status page is.
--- @param method string
--- @return boolean
function M.routed(method)
    return ROUTED[method] ~= nil
end

--- Call a model method: a call to the workspace daemon (the editor holds no
--- model, step 6b-α; every method is routed, step 5o C2c-2), never run
--- in-process. With no workspace root attached every method is refused,
--- nothing sent — the recovery methods name their lw command (spec §19.16
--- "Model writes"); with a root attached and its observer gone a method is
--- refused as not carried. `cb(r)` gets its outcome (may be nil).
--- @param ws any unused (the editor holds no model)
--- @param method string `"<Interface>/<version>.<method>"`
--- @param params table|nil
--- @param cb fun(r: table)|nil
function M.call(ws, method, params, cb)
    local route = ROUTED[method]
    if not route then error("loomworks.ui.model_calls: unknown method " .. tostring(method), 2) end
    params, cb = params or {}, cb or function() end
    if not require("loomworks.daemon.editor_ops").daemon_of() then
        return cb(refusal(method, NO_WORKSPACE[method] or "the workspace is not loaded"))
    end
    return route(ws, params, cb)
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

--- loomworks/daemon/facade.lua — the plugin's public build, launch and
--- picker functions in `daemon` mode (spec §19.16 "Public API", step 6b-α).
---
--- The editor holds no model in `daemon` mode, so `lw.build_profile`,
--- `lw.build_target`, `lw.pick_profile`, `lw.pick_target`,
--- `lw.pick_target_action`, `lw.launch_target` and `lw.debug_target` act by
--- calls to the workspace daemon, naming its entities by the ids of
--- `view.Workspace/1` and of `Launch/1.targets` (API.md §9.6):
---   * the profile build is `Build/1.build` of the active profile row
---     (ui/model_calls, an owned task, the artifact-conflict question from
---     its unit rows);
---   * a launch target's build is `Launch/1.build`, its run or debug the
---     session tracker's preparation, of a loomworks.daemon.LaunchRef — the
---     profile's default target as `Launch/1.targets` marks it, else the one
---     the picker chooses;
---   * the target picker lists `Launch/1.targets` (one call when it opens)
---     and stores the choice, or removes it, with
---     `Profiles/1.set_default_target`;
---   * the profile picker lists the `profiles` rows and sends
---     `Profiles/1.set_active` (no "None": the protocol has no deactivation);
---   * the getters (`lw.get_profiles`, ...) return plain copies of the view
---     rows with their ids, nil while the view is not held.
--- A call the daemon cannot carry, or refuses, is one notification and
--- changes nothing ("Availability"); nothing runs in-process.

local M = {}

--- Whether the facade acts by calls: the editor's runtime selection is
--- `daemon` (editor_ops.daemon_of with no model).
--- @return boolean
function M.active()
    return (require("loomworks.daemon.editor_ops").daemon_of(nil))
end

local function warn(msg) vim.notify("loomworks: " .. msg, vim.log.levels.WARN) end

--- The `view.Workspace/1` state, or nil while it is not held.
local function workspace_view()
    return require("loomworks.views").get("workspace")
end

--- The active profile's row, or nil (notified: why).
--- @return table|nil
local function active_row()
    local view = workspace_view()
    if not view then
        warn("the workspace is not loaded")
        return nil
    end
    for _, row in ipairs(view.profiles or {}) do
        if row.active then
            if row.id == nil then
                warn("no profile id (not a row of the workspace view)")
                return nil
            end
            return row
        end
    end
    warn("no active profile")
    return nil
end

--- The project row of `view.Workspace/1` with id `id`, or nil.
local function project_row(id)
    local view = workspace_view()
    for _, p in ipairs(view and view.projects or {}) do
        if id ~= nil and p.id == id then return p end
    end
    return nil
end

--- Send a plain request `method` (`Launch/1.targets`,
--- `Profiles/1.set_default_target`); `cb(result)` with an `ok` result, or
--- nothing after the refusal was notified (not carried, refused, declined,
--- failed).
--- @param method string
--- @param args table
--- @param verb string what a refusal names
--- @param cb fun(res: table)
local function request(method, args, verb, cb)
    local ops = require("loomworks.daemon.editor_ops")
    local obs = ops.carrier(method, nil)
    if not obs then
        local _, mode_obs = ops.daemon_of(nil)
        return warn(verb .. ": " .. (mode_obs and mode_obs.state ~= "stopped" and mode_obs:refusal(method)
            or "the workspace is no longer loaded"))
    end
    obs:request(method, args, function(r)
        local res = r.outcome == "ok" and type(r.result) == "table" and r.result or nil
        if res and res.outcome == "ok" then return cb(res) end
        local why
        if r.outcome == "degraded" then
            why = obs:refusal(method)
        elseif res and res.outcome == "refused" then
            why = tostring(res.message)
        elseif res and res.outcome == "declined" then
            why = "the workspace daemon declined it (" .. tostring(res.reason) .. ")"
        else
            why = "the call to the workspace daemon failed: " .. tostring(r.reason or (res and res.outcome) or "?")
        end
        vim.notify("loomworks: " .. verb .. ": " .. why, vim.log.levels.ERROR)
    end)
end

--- `cb(refs)` with the profile row's launchable targets as LaunchRefs
--- (`Launch/1.targets`), in the reply's order.
--- @param row table the profile row
--- @param cb fun(refs: loomworks.daemon.LaunchRef[])
function M.targets(row, cb)
    request("Launch/1.targets", { profile = { id = row.id } }, "launch targets", function(res)
        local launch_ref = require("loomworks.daemon.launch_ref")
        local out = {}
        for _, rec in ipairs(type(res.targets) == "table" and res.targets or {}) do
            if type(rec) == "table" and type(rec.project) == "table" then
                out[#out + 1] = launch_ref.new(row, rec, project_row(rec.project.id))
            end
        end
        cb(out)
    end)
end

--- Store `ref` as the profile row's default target, or (nil) remove the
--- stored choice (`Profiles/1.set_default_target`); `cb()` once stored.
--- @param row table
--- @param ref loomworks.daemon.LaunchRef|nil
--- @param cb? fun()
function M.set_default_target(row, ref, cb)
    local args = { profile = { id = row.id } }
    if ref then args.target = { kind = ref.kind, project = { id = ref.project_id }, name = ref.name } end
    request("Profiles/1.set_default_target", args, "default target", function() if cb then cb() end end)
end

--- The picker's line of a target (as the in-process picker's).
--- @param ref loomworks.daemon.LaunchRef
--- @return string
local function item_label(ref)
    if ref.kind == "launch" then
        return ref.project_key .. " [launch: " .. ref.label .. "]"
            .. require("loomworks.ui.helpers").picker_summary(ref.description)
    elseif ref.kind == "device" then
        return ref.project_key .. " [device: " .. ref.label .. "]"
    end
    return ref.project_key .. ": " .. ref.label
end

--- The target picker of the profile row: lists `Launch/1.targets` with
--- "None (clear target)"; the choice is stored as its default target
--- (`Profiles/1.set_default_target`), "None" removes it. `on_chosen(ref)`
--- once a target was stored (not after "None" or a cancel).
--- @param row table
--- @param on_chosen? fun(ref: loomworks.daemon.LaunchRef)
local function show_picker(row, refs, on_chosen)
    local items = { { label = "None (clear target)" } }
    for _, ref in ipairs(refs) do items[#items + 1] = { label = item_label(ref), ref = ref } end
    vim.ui.select(items, {
        prompt = "Select default target:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        if not choice.ref then return M.set_default_target(row, nil) end
        M.set_default_target(row, choice.ref, function()
            if on_chosen then
                choice.ref.default = true
                on_chosen(choice.ref)
            end
        end)
    end)
end

--- The target picker of the profile row over a fresh `Launch/1.targets`
--- (show_picker).
--- @param row table
--- @param on_chosen? fun(ref: loomworks.daemon.LaunchRef)
function M.pick_target(row, on_chosen)
    M.targets(row, function(refs) show_picker(row, refs, on_chosen) end)
end

--- `cb(ref)` with the active profile's default target (`Launch/1.targets`'s
--- `default` record); with none, the picker first (its choice stored, then
--- `cb`). A stored default that no longer resolves is reported first.
--- @param row table
--- @param cb fun(ref: loomworks.daemon.LaunchRef)
local function with_default(row, cb)
    M.targets(row, function(refs)
        for _, ref in ipairs(refs) do
            if ref.default then return cb(ref) end
        end
        if row.default_target and row.default_target_valid == false then
            warn("target '" .. tostring(row.default_target) .. "' no longer available")
        end
        show_picker(row, refs, cb)
    end)
end

--- `lw.build_profile()`: `Build/1.build` of the active profile row.
function M.build_profile()
    local row = active_row()
    if not row then return end
    require("loomworks.ui.model_calls").call(nil, "Build/1.build", { profile = row }, function(r)
        if r.outcome ~= "ok" and not r.notified then warn(r.message and tostring(r.message) or "build failed") end
    end)
end

--- `lw.build_target()`: `Launch/1.build` of the active profile's default
--- target (the picker first when it has none), one owned task.
function M.build_target()
    local row = active_row()
    if not row then return end
    with_default(row, function(ref)
        local fidget = require("loomworks.fidget")
        local handle = fidget.start_op_action("Building " .. ref:display_name())
        fidget.report(handle, "building...")
        require("loomworks.daemon.editor_ops").build_target(ref, {
            resolve = function() fidget.finish(handle, "built") end,
            reject = function(err) fidget.fail(handle, tostring(err)) end,
        })
    end)
end

--- `lw.pick_target()`: the active profile's target picker.
function M.pick_target_only()
    local row = active_row()
    if row then M.pick_target(row) end
end

--- `lw.pick_target_action()`: "Build" / "Switch target" for a valid default
--- target (as the view's row reports it), else the picker.
function M.pick_target_action()
    local row = active_row()
    if not row then return end
    if not (row.default_target and row.default_target_valid) then return M.pick_target(row) end
    vim.ui.select({ "Build", "Switch target" }, {
        prompt = "Target: " .. tostring(row.default_target),
    }, function(choice)
        if choice == "Build" then
            M.build_target()
        elseif choice then
            M.pick_target(row)
        end
    end)
end

--- `lw.pick_profile()`: the `profiles` rows; the choice is
--- `Profiles/1.set_active`.
function M.pick_profile()
    local view = workspace_view()
    if not view then return warn("the workspace is not loaded") end
    local rows = view.profiles or {}
    if #rows == 0 then return warn("no profiles available") end
    local helpers = require("loomworks.ui.helpers")
    local items = {}
    for _, row in ipairs(rows) do
        items[#items + 1] = {
            label = (row.active and "● " or "  ") .. tostring(row.key) .. " (" .. tostring(row.status) .. ")"
                .. helpers.picker_summary(row.description),
            row = row,
        }
    end
    vim.ui.select(items, {
        prompt = "Select profile:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice or choice.row.active then return end
        require("loomworks.ui.model_calls").call(nil, "Profiles/1.set_active", { profile = choice.row }, function(r)
            if r.outcome ~= "ok" and not r.notified then
                vim.notify("loomworks: " .. tostring(r.message), vim.log.levels.ERROR)
            end
        end)
    end)
end

--- `lw.launch_target()` / `lw.debug_target()`: the session tracker's run
--- or debug of the active profile's default target (the picker first when
--- it has none). While the workspace is unloaded it is refused with that
--- status (§19.16 "Editor operations"), no picker shown.
--- @param mode "launch"|"debug"
function M.launch(mode)
    local tracker = require("loomworks.session_tracker")
    local obs = require("loomworks.daemon.observer").current()
    local unloaded, why = false, nil
    if not obs then
        unloaded, why = true, "the workspace is no longer loaded"
    else
        unloaded, why = obs:workspace_unloaded()
        why = unloaded and ("the workspace is unloaded (" .. tostring(why) .. ")") or nil
    end
    if unloaded then
        return warn("cannot " .. (mode == "debug" and "debug" or "run") .. ": " .. why)
    end
    local row = active_row()
    if not row then return end
    with_default(row, function(ref) tracker.start(ref, mode) end)
end

-- ---------------------------------------------------------------------------
-- The getters (§19.16 "Public API"): plain copies of the view rows, with
-- their ids; nil while the view they read is not held. Writing to a returned
-- table changes nothing.
-- ---------------------------------------------------------------------------

local copy = vim.deepcopy

--- The copies of `rows` keyed by `field` of each row (the getters' documented
--- shape: profiles and projects by key, configuration sets by name).
--- @param rows table[]|nil
--- @param field string
--- @return table<string, table>
local function by(rows, field)
    local out = {}
    for _, row in ipairs(rows or {}) do
        if type(row[field]) == "string" then out[row[field]] = copy(row) end
    end
    return out
end

--- The copy of the first of `rows` whose `active` is true, or nil.
--- @param rows table[]|nil
--- @return table|nil
local function active_of(rows)
    for _, row in ipairs(rows or {}) do
        if row.active then return copy(row) end
    end
    return nil
end

--- `lw.get_profiles()`: `view.Workspace/1`'s `profiles` records, by key.
--- @return table<string, loomworks.ViewProfile>|nil
function M.profiles()
    local view = workspace_view()
    return view and by(view.profiles, "key") or nil
end

--- `lw.get_active_profile()`: the `profiles` record whose `active` is true.
--- @return loomworks.ViewProfile|nil
function M.active_profile()
    local view = workspace_view()
    return view and active_of(view.profiles) or nil
end

--- `lw.get_projects()`: `view.Workspace/1`'s `projects` records, by key.
--- @return table<string, loomworks.ViewProject>|nil
function M.projects()
    local view = workspace_view()
    return view and by(view.projects, "key") or nil
end

--- `lw.get_config_sets()`: its `config_sets` records, by name.
--- @return table<string, loomworks.ViewConfigSet>|nil
function M.config_sets()
    local view = workspace_view()
    return view and by(view.config_sets, "name") or nil
end

--- `lw.get_active_configuration_set()`: the `config_sets` record whose
--- `active` is true.
--- @return loomworks.ViewConfigSet|nil
function M.active_configuration_set()
    local view = workspace_view()
    return view and active_of(view.config_sets) or nil
end

--- `lw.get_tool_entries()`: per configuration set name, the `profiles`
--- records of that set (a profile names its set by `config_set_id`; one of
--- an orphaned set has none and is in no list).
--- @return table<string, loomworks.ViewProfile[]>|nil
function M.tool_entries()
    local view = workspace_view()
    if not view then return nil end
    local out = {}
    for _, set in ipairs(view.config_sets or {}) do
        local list = {}
        for _, row in ipairs(view.profiles or {}) do
            if set.id ~= nil and row.config_set_id == set.id then list[#list + 1] = copy(row) end
        end
        if type(set.name) == "string" then out[set.name] = list end
    end
    return out
end

--- `lw.get_tools_by_type()`: per module type, the distinct `tools` rows
--- (`{ module, key?, label }`) the `profiles` records select, in profile
--- order. The toolchains a module detects are `Toolchains/1.list`, a call.
--- @return table<string, loomworks.ViewProfileTool[]>|nil
function M.tools_by_type()
    local view = workspace_view()
    if not view then return nil end
    local out, seen = {}, {}
    for _, row in ipairs(view.profiles or {}) do
        for _, t in ipairs(row.tools or {}) do
            if type(t.module) == "string" then
                local sig = t.module .. "\0" .. tostring(t.key) .. "\0" .. tostring(t.label)
                if not seen[sig] then
                    seen[sig] = true
                    out[t.module] = out[t.module] or {}
                    table.insert(out[t.module], copy(t))
                end
            end
        end
    end
    return out
end

--- `lw.get_orphaned_configs()`: `view.Workspace/1`'s
--- `orphaned.configurations` records.
--- @return { id?: string, key: string, build_dir?: string }[]|nil
function M.orphaned_configs()
    local view = workspace_view()
    if not view then return nil end
    return copy(view.orphaned and view.orphaned.configurations or {})
end

--- `lw.project_for_buf(bufnr)`: the buffer's `view.ProjectsIndex/1`
--- record, as `lw.buf_project` (§19.13).
--- @param bufnr? integer
--- @return loomworks.ViewProjectRecord|nil
function M.project_for_buf(bufnr)
    local rec = require("loomworks.views").buf_project(bufnr)
    return rec and copy(rec) or nil
end

--- `lw.get_lsp_options(server)`: that server's options in the held
--- `LspConfig/1` state (empty when the state names none for it); nil while
--- the state is not held.
--- @param server string
--- @return table|nil
function M.lsp_options(server)
    local phase, st = require("loomworks.lsp_source").daemon_phase()
    if phase ~= "loaded" or type(st) ~= "table" then return nil end
    local opts = type(st.options) == "table" and st.options[server] or nil
    return type(opts) == "table" and copy(opts) or {}
end

--- `lw.compile_command_for_file` in `daemon` mode (§19.16 "Public API"):
--- refused, nothing read.
M.COMPILE_COMMAND_REFUSAL = "not available with the workspace daemon"

--- The status page's `N` in `daemon` mode (§19.16 "Model writes"): refused,
--- nothing written.
M.CREATE_REFUSAL = "creating a workspace is not available with the workspace daemon — run lw init in a terminal"

return M

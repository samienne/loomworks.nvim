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
---     `Profiles/1.set_active` (no "None": the protocol has no deactivation).
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
        if r.outcome ~= "ok" and not r.notified and r.message then warn(tostring(r.message)) end
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

--- `lw.compile_command_for_file` in `daemon` mode (§19.16 "Public API"):
--- refused, nothing read.
M.COMPILE_COMMAND_REFUSAL = "not available with the workspace daemon"

--- The status page's `N` in `daemon` mode (§19.16 "Model writes"): refused,
--- nothing written.
M.CREATE_REFUSAL = "creating a workspace is not available with the workspace daemon — run lw init in a terminal"

return M

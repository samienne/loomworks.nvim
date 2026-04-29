--- loomworks/ui/v2/view_model/init.lua — Root view model.
---
--- Composes overview + inspector + selection. Subscribes to public
--- loomworks events that should trigger a view refresh, and notifies
--- registered subscribers (typically the view layer) via `subscribe()`.
---
--- Pure presentation: no Snacks, no buffers, no extmarks. The view
--- calls `presentation()` to get a fresh table on every change tick.
---
--- Lifecycle:
---   local vm = ViewModel.new({ workspace_provider = function() return ws end })
---   local unsub = vm:subscribe(function() view:refresh() end)
---   ...
---   vm:dispatch("cursor_to", { section = 1, row = 2 })
---   ...
---   unsub()
---   vm:destroy()

local Selection = require("loomworks.ui.v2.view_model.selection")
local overview  = require("loomworks.ui.v2.view_model.overview")
local inspector = require("loomworks.ui.v2.view_model.inspector")
local activity  = require("loomworks.ui.v2.view_model.activity")

--- @class loomworks.uiv2.ViewModel
--- @field _workspace_provider fun(): loomworks.Workspace|nil
--- @field _selection loomworks.uiv2.Selection
--- @field _section_state table<string, boolean>  -- explicit user collapsed choices
--- @field _subscribers function[]
--- @field _event_handlers table[]   { event, fn } pairs to off() on destroy
local ViewModel = {}
ViewModel.__index = ViewModel

--- Default events that should trigger a refresh.
local DEFAULT_REFRESH_EVENTS = {
    "workspace_changed",
    "active_set_changed",
    "task_started",
    "task_stopped",
    "task_progress",
    "task_result",
    "operation_started",
    "operation_finished",
    "deletion_started",
    "deletion_completed",
    "deletion_failed",
    "tools_detected",
    "devices_changed",
}

--- @param opts { workspace_provider: fun(): loomworks.Workspace|nil, events?: table, refresh_events?: string[] }
--- @return loomworks.uiv2.ViewModel
function ViewModel.new(opts)
    assert(opts and opts.workspace_provider, "workspace_provider is required")
    local self = setmetatable({
        _workspace_provider = opts.workspace_provider,
        _selection = Selection.new(),
        _section_state = {},
        _wire_draft = nil,
        _recent_results = {},   -- ring buffer of completed task results (newest first)
        _recent_results_max = opts.recent_results_max or 10,
        _subscribers = {},
        _event_handlers = {},
    }, ViewModel)

    -- Subscribe to events that should trigger refresh notifications.
    -- The events module is injectable for testing.
    local events_mod = opts.events or require("loomworks.events")
    local refresh_events = opts.refresh_events or DEFAULT_REFRESH_EVENTS
    local function on_event() self:_notify() end
    for _, ev in ipairs(refresh_events) do
        events_mod.on(ev, on_event)
        self._event_handlers[#self._event_handlers + 1] = {
            events = events_mod, event = ev, fn = on_event,
        }
    end

    -- Separate handler for task_result that records completion details into
    -- the recent-results ring buffer. The `on_event` handler above already
    -- triggers a refresh; this one captures the payload.
    local function on_task_result(result)
        if type(result) ~= "table" then return end
        table.insert(self._recent_results, 1, {
            project_key       = result.project_key,
            configuration_key = result.configuration_key,
            action            = result.action,
            success           = result.success and true or false,
            variant           = result.variant,
        })
        while #self._recent_results > self._recent_results_max do
            table.remove(self._recent_results)
        end
    end
    events_mod.on("task_result", on_task_result)
    self._event_handlers[#self._event_handlers + 1] = {
        events = events_mod, event = "task_result", fn = on_task_result,
    }

    return self
end

--- Register a subscriber. Returns an unsubscribe function.
--- @param fn function called with no arguments on every change
--- @return function unsubscribe
function ViewModel:subscribe(fn)
    self._subscribers[#self._subscribers + 1] = fn
    return function()
        for i, sub in ipairs(self._subscribers) do
            if sub == fn then
                table.remove(self._subscribers, i)
                return
            end
        end
    end
end

function ViewModel:_notify()
    for _, fn in ipairs(self._subscribers) do
        local ok, err = pcall(fn)
        if not ok then
            vim.notify("loomworks ui v2: subscriber error: " .. tostring(err), vim.log.levels.ERROR)
        end
    end
end

--- Default collapsed state when no explicit user toggle has been recorded.
local DEFAULT_COLLAPSED = {
    devices        = false,
    cleanup        = true,
    other_profiles = true,
    other_projects = true,
    config_sets    = true,
}

--- Static hint bar for the overview pane.
--- Cursor doesn't drive the inspector — `<CR>` selects the row under
--- cursor and opens it in the inspector. Action keys (a/b/c/D/C)
--- operate on whatever the cursor is on, regardless of inspector state.
local OVERVIEW_HINT_BASE = {
    { key = "<CR>",   label = "select / toggle" },
    { key = "a",      label = "activate" },
    { key = "b",      label = "build" },
    { key = "c",      label = "configure" },
    { key = "D",      label = "delete" },
    { key = "C",      label = "clean" },
    { key = "o",      label = "toggle section" },
    { key = "q",      label = "close" },
}

--- Build a fresh presentation tree. Cheap to call repeatedly.
--- @return table { overview, inspector, selection }
function ViewModel:presentation()
    local ws = self._workspace_provider()
    local ov = overview.build(ws, self._section_state)

    -- Inspector subject is whatever has been explicitly selected (pinned).
    -- Cursor movement no longer drives the inspector — selection is
    -- explicit via `<CR>`/`select_under_cursor`.
    local ref = self._selection:pinned()
    local insp = inspector.build(ws, ref, { wire_draft = self._wire_draft })

    ov.hint_bar = OVERVIEW_HINT_BASE

    local act = activity.build(ws, self._recent_results)
    act.hint_bar = {
        { key = "<C-w>k",  label = "focus overview" },
        { key = "q",       label = "close" },
    }

    return {
        overview  = ov,
        inspector = insp,
        activity  = act,
        selection = {
            cursor        = self._selection:cursor(),
            pinned        = self._selection:pinned(),
            effective_ref = ref,
        },
    }
end

--- Dispatch an action from the view layer.
--- @param action string
--- @param payload? table
function ViewModel:dispatch(action, payload)
    if action == "cursor_to" then
        -- Cursor changes are visual-only and target action keys (b/c/D/C/a).
        -- They no longer drive the inspector subject and skip the notify
        -- loop to avoid re-rendering on every j/k.
        assert(payload and payload.section and payload.row, "cursor_to requires { section, row }")
        self._selection:cursor_to(payload.section, payload.row)
    elseif action == "select_under_cursor" or action == "pin" then
        -- Set inspector subject to whatever the cursor is on.
        local ws = self._workspace_provider()
        local ov = overview.build(ws, self._section_state)
        local c = self._selection:cursor()
        local ref = overview.ref_at(ov, c.section, c.row)
        if ref then
            self._selection:pin(ref)
            self:_notify()
        end
    elseif action == "unpin" then
        self._selection:unpin()
        self:_notify()
    elseif action == "toggle_pin" then
        -- Legacy: toggle the explicit selection. Kept so callers using
        -- the older name continue to work; cursor-driven flicker is no
        -- longer the use case.
        if self._selection:pinned() then
            self._selection:unpin()
        else
            local ws = self._workspace_provider()
            local ov = overview.build(ws, self._section_state)
            local c = self._selection:cursor()
            local ref = overview.ref_at(ov, c.section, c.row)
            if ref then self._selection:pin(ref) end
        end
        self:_notify()
    elseif action == "toggle_section" then
        assert(payload and payload.kind, "toggle_section requires { kind }")
        local current = self._section_state[payload.kind]
        if current == nil then current = DEFAULT_COLLAPSED[payload.kind] or false end
        self._section_state[payload.kind] = not current
        self:_notify()
    elseif action == "drill_in" then
        -- Pin the inspector to a specific ref (typically from inside the
        -- inspector itself, where overview cursor doesn't apply).
        assert(payload and payload.ref, "drill_in requires { ref }")
        self._selection:pin(payload.ref)
        self:_notify()
    elseif action == "act_under_cursor" then
        -- payload = { action = "activate" | "build" | "configure" | "delete" | "clean" }
        assert(payload and payload.action, "act_under_cursor requires { action }")
        self:_dispatch_action_at_cursor(payload.action)
    elseif action == "cycle_publish" then
        self:_cycle_publish_for_inspector_subject()
    elseif action == "set_field" then
        -- payload = { subject = { kind, ... }, field_id = string, value = any }
        assert(payload and payload.subject and payload.field_id, "set_field requires subject + field_id")
        self:_set_field(payload.subject, payload.field_id, payload.value)
    elseif action == "add_item" then
        -- payload = { kind, parent, name, extra? }
        assert(payload and payload.kind and payload.parent and payload.name,
            "add_item requires { kind, parent, name }")
        self:_add_item(payload.kind, payload.parent, payload.name, payload.extra)
    elseif action == "delete_inspector_subject" then
        self:_delete_inspector_subject()
    elseif action == "rename_inspector_subject" then
        assert(payload and payload.new_name, "rename_inspector_subject requires { new_name }")
        self:_rename_inspector_subject(payload.new_name)
    elseif action == "open_wire_deploy_add" then
        assert(payload and payload.parent, "open_wire_deploy_add requires { parent }")
        self:_open_wire_deploy_add(payload.parent)
    elseif action == "open_wire_deploy_edit" then
        assert(payload and payload.subject, "open_wire_deploy_edit requires { subject }")
        self:_open_wire_deploy_edit(payload.subject)
    elseif action == "wire_save" then
        self:_wire_save()
    elseif action == "wire_cancel" then
        self:_wire_cancel()
    elseif action == "select_ref" then
        -- Place cursor onto a known ref (used by view after refresh to follow
        -- expansion changes).
        assert(payload and payload.ref, "select_ref requires { ref }")
        local ws = self._workspace_provider()
        local ov = overview.build(ws, self._section_state)
        local s, r = overview.locate_ref(ov, payload.ref)
        if s and r then
            self._selection:cursor_to(s, r)
            self:_notify()
        end
    else
        error("unknown action: " .. tostring(action))
    end
end

--- Effective collapsed state for a section kind.
--- @param kind string
--- @return boolean
function ViewModel:section_collapsed(kind)
    local explicit = self._section_state[kind]
    if explicit ~= nil then return explicit end
    return DEFAULT_COLLAPSED[kind] or false
end

--- Resolve the target object the cursor is pointing at, for action keys.
--- Returns nil when no actionable target is under the cursor.
--- @return { kind: "profile"|"config_unit"|"orphan_config", target: any, profile: loomworks.Profile|nil }|nil
function ViewModel:resolve_action_target()
    local ws = self._workspace_provider()
    if not ws then return nil end
    local ov = overview.build(ws, self._section_state)
    local c = self._selection:cursor()
    local section = ov.sections[c.section]
    if not section then return nil end
    local ref = section.selectable and section.selectable[c.row]
    if not ref then return nil end

    if ref.kind == "profile" then
        for _, p in pairs(ws._profiles or {}) do
            if p.key == ref.key then
                return { kind = "profile", target = p, profile = p }
            end
        end
    elseif ref.kind == "project" and section.kind == "active_profile_card" then
        local active = ws._active_profile
        if active then
            for _, pp in ipairs(active:projects()) do
                if pp:project_key() == ref.key and pp._config_unit then
                    return {
                        kind = "config_unit",
                        target = pp._config_unit,
                        profile = active,
                    }
                end
            end
        end
    elseif ref.kind == "orphan_config" then
        return { kind = "orphan_config", target = ref.key, profile = nil }
    end
    return nil
end

--- Dispatch a built-in action against the cursor's resolved target.
--- @param action_name string  "activate"|"build"|"configure"|"delete"|"clean"
--- @return boolean dispatched  true when a target was found and the call invoked
function ViewModel:_dispatch_action_at_cursor(action_name)
    local t = self:resolve_action_target()
    if not t then return false end

    if action_name == "activate" then
        if t.kind == "profile" and t.target.activate then
            t.target:activate()
            return true
        end
    elseif action_name == "build" then
        if t.profile and t.profile.build then
            t.profile:build()
            return true
        end
    elseif action_name == "configure" then
        if t.profile and t.profile.configure then
            t.profile:configure()
            return true
        end
    elseif action_name == "delete" then
        if t.kind == "profile" and t.target.delete then
            t.target:delete()
            return true
        elseif t.kind == "config_unit" and t.target.delete then
            t.target:delete()
            return true
        elseif t.kind == "orphan_config" then
            self:_delete_orphan(t.target)
            return true
        end
    elseif action_name == "clean" then
        if t.kind == "profile" and t.target.clean then
            t.target:clean()
            return true
        elseif t.kind == "config_unit" and t.target.clean then
            t.target:clean()
            return true
        end
    end
    return false
end

--- Cycle the _intent value: local → local+shared → shared → local.
--- @param item table  domain object with _intent
local function cycle_intent(item)
    if item._intent == "local" then
        item._intent = "local+shared"
    elseif item._intent == "local+shared" then
        item._intent = "shared"
    else
        item._intent = "local"
    end
end

--- Resolve the inspector's current subject as a publishable domain object.
--- Returns nil if there's no publishable subject.
--- @return table|nil
function ViewModel:_resolve_publishable_subject()
    local ws = self._workspace_provider()
    if not ws then return nil end
    local p = self:presentation()
    local insp = p.inspector
    if not insp or insp.kind == "empty" or insp.missing then return nil end
    if insp.kind == "profile" then
        for _, prof in pairs(ws._profiles or {}) do
            if prof.key == insp.subject then return prof end
        end
    elseif insp.kind == "project" then
        for _, proj in pairs(ws._projects or {}) do
            if proj.key == insp.subject then return proj end
        end
    elseif insp.kind == "config_set" then
        for _, cs in pairs(ws._config_sets or {}) do
            if cs.name == insp.subject then return cs end
        end
    elseif insp.kind == "configuration" then
        for _, proj in pairs(ws._projects or {}) do
            if proj.key == insp.project_key then
                return proj:get_configuration(insp.subject)
            end
        end
    end
    return nil
end

--- Cycle the publish intent on the inspector's current subject and persist.
function ViewModel:_cycle_publish_for_inspector_subject()
    local item = self:_resolve_publishable_subject()
    if not item then return end
    cycle_intent(item)
    -- Persist via workspace's user.json save and trigger refresh.
    local ws = self._workspace_provider()
    if ws and ws._save_user then
        pcall(function() ws:_save_user() end)
    end
    self:_notify()
end

--- Find a project by key.
--- @param ws loomworks.Workspace
--- @param key string
--- @return loomworks.Project|nil
local function find_project(ws, key)
    for _, p in pairs(ws._projects or {}) do
        if p.key == key then return p end
    end
    return nil
end

--- Apply a field edit to the right workspace target.
--- @param subject table   { kind, project_key, launch_name|var_name|... }
--- @param field_id string
--- @param value any
--- @return boolean ok
function ViewModel:_set_field(subject, field_id, value)
    local ws = self._workspace_provider()
    if not ws or not subject then return false end

    if subject.kind == "launch" then
        local proj = find_project(ws, subject.project_key)
        if not proj then return false end
        local launches = proj.launch
        local existing = launches and launches[subject.launch_name]
        if not existing then return false end
        local updated = vim.tbl_extend("force", {}, existing)
        updated[field_id] = value
        local ok = proj:save_launch_config(subject.launch_name, updated)
        if ok then self:_notify() end
        return ok and true or false
    elseif subject.kind == "variable" then
        local proj = find_project(ws, subject.project_key)
        if not proj then return false end
        local decl = proj.variables and proj.variables[subject.var_name]
        if not decl then return false end
        local updated = vim.tbl_extend("force", {}, decl)
        updated[field_id] = value
        local ok = proj:save_variable(subject.var_name, updated)
        if ok then self:_notify() end
        return ok and true or false
    elseif subject.kind == "launch_arg" then
        local proj = find_project(ws, subject.project_key)
        if not proj then return false end
        local launch = proj.launch and proj.launch[subject.launch_name]
        if not launch then return false end
        local args = vim.deepcopy(launch.args or {})
        local idx = subject.index
        if not idx or idx < 1 then return false end
        if value == nil or value == "" then
            -- Empty value removes the arg.
            table.remove(args, idx)
        else
            args[idx] = value
        end
        local updated = vim.tbl_extend("force", {}, launch)
        updated.args = (#args > 0) and args or nil
        local ok = proj:save_launch_config(subject.launch_name, updated)
        if ok then self:_notify() end
        return ok and true or false
    elseif subject.kind == "launch_env" then
        local proj = find_project(ws, subject.project_key)
        if not proj then return false end
        local launch = proj.launch and proj.launch[subject.launch_name]
        if not launch then return false end
        local env = vim.deepcopy(launch.env or {})
        if value == nil or value == "" then
            env[subject.key] = nil
        else
            env[subject.key] = value
        end
        local updated = vim.tbl_extend("force", {}, launch)
        updated.env = next(env) and env or nil
        local ok = proj:save_launch_config(subject.launch_name, updated)
        if ok then self:_notify() end
        return ok and true or false
    elseif subject.kind == "project_type_config_env" then
        local proj = find_project(ws, subject.project_key)
        if not proj or not proj.save_type_config_field then return false end
        local existing = (proj.type_config and proj.type_config[subject.field_name]) or {}
        local updated = vim.deepcopy(existing)
        if value == nil or value == "" then
            updated[subject.key] = nil
        else
            updated[subject.key] = value
        end
        local ok = proj:save_type_config_field(subject.field_name, updated)
        if ok then self:_notify() end
        return ok and true or false
    elseif subject.kind == "profile_default_target" then
        local profile
        for _, p in pairs(ws._profiles or {}) do
            if p.key == subject.profile_key then profile = p; break end
        end
        if not profile then return false end
        if value == nil or value == "" or value == "(none)" then
            if profile.clear_default_target then profile:clear_default_target() end
            self:_notify()
            return true
        end
        -- Format produced by the picker: "project.launch"
        local project_key, launch_name = value:match("^(.-)%.(.+)$")
        if not project_key or not launch_name then return false end
        local proj = find_project(ws, project_key)
        if not proj or not profile.set_default_target then return false end
        profile:set_default_target(proj, nil, launch_name)
        self:_notify()
        return true
    elseif subject.kind == "profile_device" then
        local profile
        for _, p in pairs(ws._profiles or {}) do
            if p.key == subject.profile_key then profile = p; break end
        end
        if not profile then return false end
        if value == nil or value == "" or value == "(none)" then
            if profile.clear_device then profile:clear_device() end
        else
            if profile.set_device then profile:set_device(value) end
        end
        self:_notify()
        return true
    elseif subject.kind == "config_set_mapping" then
        -- Update or remove a project's variant mapping in a configuration set.
        -- value == "" → remove mapping; otherwise set to the configuration matching the value.
        local cs
        for _, c in pairs(ws._config_sets or {}) do
            if c.name == subject.set_name then cs = c; break end
        end
        if not cs or not cs.update_mapping then return false end

        local proj = find_project(ws, subject.project_key)
        if not proj then return false end

        if value == nil or value == "" then
            local ok = cs:update_mapping(proj, nil)
            if ok then self:_notify() end
            return ok and true or false
        end
        local new_cfg = proj:get_configuration(value)
            or (proj.ensure_configuration and proj:ensure_configuration(value))
        if not new_cfg then return false end
        local ok = cs:update_mapping(proj, new_cfg)
        if ok then self:_notify() end
        return ok and true or false
    elseif subject.kind == "wire_draft" then
        if not self._wire_draft then return false end
        local f = field_id  -- wire kinds use the field name as the id directly,
                           -- but boolean fields might pass the toggle as "true"/"false"
        if subject.field == "pre_build" then
            -- Accept boolean directly, or coerce string.
            if type(value) == "string" then
                value = value:lower() == "true" or value == "1" or value:lower() == "yes"
            end
            self._wire_draft.pre_build = value and true or false
        else
            self._wire_draft[subject.field] = value
        end
        self:_notify()
        return true
    elseif subject.kind == "configuration_option" then
        local proj = find_project(ws, subject.project_key)
        if not proj then return false end
        local cfg = proj:get_configuration(subject.config_name)
        if not cfg or not cfg.is_user then return false end

        -- Build the user-override entry from the existing config and
        -- mutate just the one option key.
        local entry = cfg:serialize_user_override() or {}
        local opts = entry.options and vim.deepcopy(entry.options) or {}
        if value == nil or value == "" then
            opts[subject.option_key] = nil
        else
            opts[subject.option_key] = value
        end
        entry.options = next(opts) and opts or nil

        local ok = proj:save_configuration(subject.config_name, entry)
        if ok then self:_notify() end
        return ok and true or false
    end
    return false
end

--- Add a new item under a parent ref. Creates with sensible defaults so
--- the user can edit individual fields with `e` afterward.
--- @param kind "variable"|"launch"|"configuration"|"deploy_step"
--- @param parent table  parent ref
--- @param name string   the new item's name (for deploy_step: destination path)
--- @param extra? table  kind-specific extra data
--- @return boolean ok
function ViewModel:_add_item(kind, parent, name, extra)
    local ws = self._workspace_provider()
    if not ws then return false end

    -- deploy_step: parent is a launch ref; everything else: parent is project.
    if kind == "deploy_step" then
        return self:_add_deploy_step(parent, name, extra)
    end
    if kind == "launch_arg" then
        return self:_add_launch_arg(parent, name)
    end
    if kind == "launch_env" then
        return self:_add_launch_env(parent, name)
    end
    if kind == "config_set_mapping" then
        return self:_add_config_set_mapping(parent, name, extra)
    end
    if kind == "project_type_config_env" then
        return self:_add_project_type_config_env(parent, name)
    end
    -- Workspace-level adds: project, configuration set.
    if parent.kind == "workspace" then
        if kind == "project" then
            local proj_type = extra and extra.type or "cmake"
            local proj, err = ws:add_project(name, proj_type, name)
            if proj then
                self._selection:pin({ kind = "project", key = proj.key })
                self:_notify()
                return true
            end
            ws._core._deps.notify("add project: " .. tostring(err), vim.log.levels.ERROR)
            return false
        elseif kind == "config_set" then
            local cs, err = ws:add_configuration_set(name, {})
            if cs then
                self._selection:pin({ kind = "config_set", key = cs.name })
                self:_notify()
                return true
            end
            ws._core._deps.notify("add configuration set: " .. tostring(err), vim.log.levels.ERROR)
            return false
        end
    end

    if parent.kind ~= "project" then return false end
    local proj = find_project(ws, parent.key)
    if not proj then return false end

    local ok = false
    if kind == "variable" then
        ok = proj:save_variable(name, { type = "string", default = "" })
    elseif kind == "launch" then
        ok = proj:save_launch_config(name, { command = "", args = {} })
    elseif kind == "configuration" then
        local inherits
        for _, cfg in ipairs(proj:get_configurations() or {}) do
            if cfg.prefix == "variant" then inherits = cfg.name; break end
        end
        ok = proj:save_configuration(name, { inherits = inherits })
    end
    if ok then
        local new_ref
        if kind == "variable" then
            new_ref = { kind = "variable", project_key = proj.key, var_name = name }
        elseif kind == "launch" then
            new_ref = { kind = "launch", project_key = proj.key, launch_name = name }
        elseif kind == "configuration" then
            new_ref = { kind = "configuration", project_key = proj.key, config_name = name }
        end
        if new_ref then self._selection:pin(new_ref) end
        self:_notify()
    end
    return ok and true or false
end

--- Append a new arg to a launch's args array.
--- @param parent table  { kind = "launch", project_key, launch_name }
--- @param value string  the arg value
--- @return boolean ok
function ViewModel:_add_launch_arg(parent, value)
    if parent.kind ~= "launch" then return false end
    local ws = self._workspace_provider()
    local proj = find_project(ws, parent.project_key)
    if not proj then return false end
    local launch = proj.launch and proj.launch[parent.launch_name]
    if not launch then return false end
    local args = vim.deepcopy(launch.args or {})
    args[#args + 1] = value
    local updated = vim.tbl_extend("force", {}, launch)
    updated.args = args
    local ok = proj:save_launch_config(parent.launch_name, updated)
    if ok then self:_notify() end
    return ok and true or false
end

--- Add a new env entry to a launch (with an empty value the user can `e`-edit).
--- @param parent table
--- @param key string  env variable name
--- @return boolean ok
function ViewModel:_add_launch_env(parent, key)
    if parent.kind ~= "launch" then return false end
    local ws = self._workspace_provider()
    local proj = find_project(ws, parent.project_key)
    if not proj then return false end
    local launch = proj.launch and proj.launch[parent.launch_name]
    if not launch then return false end
    local env = vim.deepcopy(launch.env or {})
    if env[key] ~= nil then return false end -- already exists; edit instead
    env[key] = ""
    local updated = vim.tbl_extend("force", {}, launch)
    updated.env = env
    local ok = proj:save_launch_config(parent.launch_name, updated)
    if ok then self:_notify() end
    return ok and true or false
end

--- Add a new key (with empty value) to a project's type_config env_dict.
--- @param parent table  { kind = "project_type_config", project_key, field_name }
--- @param key string
--- @return boolean ok
function ViewModel:_add_project_type_config_env(parent, key)
    if parent.kind ~= "project_type_config" then return false end
    local ws = self._workspace_provider()
    if not ws then return false end
    local proj = find_project(ws, parent.project_key)
    if not proj or not proj.save_type_config_field then return false end
    local existing = (proj.type_config and proj.type_config[parent.field_name]) or {}
    if existing[key] ~= nil then return false end
    local updated = vim.deepcopy(existing)
    updated[key] = ""
    local ok = proj:save_type_config_field(parent.field_name, updated)
    if ok then self:_notify() end
    return ok and true or false
end

--- Add a project mapping to a configuration set.
--- @param parent table  { kind = "config_set", key = set_name }
--- @param project_key string  the project being mapped
--- @param extra table  { variant = canonical_name }
--- @return boolean ok
function ViewModel:_add_config_set_mapping(parent, project_key, extra)
    if parent.kind ~= "config_set" then return false end
    if not extra or not extra.variant then return false end
    local ws = self._workspace_provider()
    if not ws then return false end
    local cs
    for _, c in pairs(ws._config_sets or {}) do
        if c.name == parent.key then cs = c; break end
    end
    if not cs or not cs.update_mapping then return false end
    local proj = find_project(ws, project_key)
    if not proj then return false end
    local cfg = proj:get_configuration(extra.variant)
        or (proj.ensure_configuration and proj:ensure_configuration(extra.variant))
    if not cfg then return false end
    local ok = cs:update_mapping(proj, cfg)
    if ok then self:_notify() end
    return ok and true or false
end

--- Open wire mode in "add" form against a launch parent ref.
--- @param parent table   { kind = "launch", project_key, launch_name }
function ViewModel:_open_wire_deploy_add(parent)
    if parent.kind ~= "launch" then return end
    self._wire_draft = {
        mode           = "add",
        parent         = parent,
        destination    = "",
        source_project = "",
        target         = "",
        path           = "",
        configuration  = "",
        pre_build      = false,
    }
    self._selection:pin({ kind = "wire_deploy" })
    self:_notify()
end

--- Open wire mode in "edit" form against an existing deploy_step subject ref.
--- @param subject table  { kind = "deploy_step", project_key, launch_name, destination }
function ViewModel:_open_wire_deploy_edit(subject)
    local ws = self._workspace_provider()
    if not ws then return end
    local proj = find_project(ws, subject.project_key)
    if not proj then return end
    local launch = proj.launch and proj.launch[subject.launch_name]
    if not launch or not launch.deploy then return end
    local descriptor = launch.deploy[subject.destination]
    if not descriptor then return end
    -- v0 wire mode handles single-source descriptors. If the deploy step
    -- is an array, treat the first element as the editable source — a
    -- richer multi-source editor is a follow-up.
    local source = descriptor[1] or descriptor
    self._wire_draft = {
        mode           = "edit",
        parent         = {
            kind = "launch",
            project_key = subject.project_key,
            launch_name = subject.launch_name,
        },
        existing       = subject,
        destination    = subject.destination or "",
        source_project = source.project or "",
        target         = source.target or "",
        path           = source.path or "",
        configuration  = source.configuration or "",
        pre_build      = source.pre_build == true,
    }
    self._selection:pin({ kind = "wire_deploy" })
    self:_notify()
end

--- Persist the current wire draft back to the workspace, then close.
--- @return boolean ok, string|nil error_reason
function ViewModel:_wire_save()
    local draft = self._wire_draft
    if not draft then return false, "no active wire draft" end
    if not draft.parent or draft.parent.kind ~= "launch" then return false, "missing parent" end
    if draft.destination == "" then return false, "destination is empty" end
    if draft.source_project == "" then return false, "source project is empty" end
    if draft.target == "" and draft.path == "" then return false, "must set target or path" end

    local ws = self._workspace_provider()
    if not ws then return false, "no workspace" end
    local proj = find_project(ws, draft.parent.project_key)
    if not proj then return false, "project not found" end
    local launch = proj.launch and proj.launch[draft.parent.launch_name]
    if not launch then return false, "launch not found" end

    local descriptor = { project = draft.source_project }
    if draft.target ~= "" then descriptor.target = draft.target end
    if draft.path ~= "" then descriptor.path = draft.path end
    if draft.configuration and draft.configuration ~= "" then
        descriptor.configuration = draft.configuration
    end
    if draft.pre_build then descriptor.pre_build = true end

    local updated = vim.tbl_extend("force", {}, launch)
    updated.deploy = vim.tbl_extend("force", {}, launch.deploy or {})
    -- In edit mode, if the destination changed, drop the old key first.
    if draft.mode == "edit" and draft.existing
        and draft.existing.destination ~= draft.destination then
        updated.deploy[draft.existing.destination] = nil
    end
    updated.deploy[draft.destination] = descriptor

    local ok = proj:save_launch_config(draft.parent.launch_name, updated)
    if ok then
        self._wire_draft = nil
        self._selection:pin({
            kind = "deploy_step",
            project_key = draft.parent.project_key,
            launch_name = draft.parent.launch_name,
            destination = draft.destination,
        })
        self:_notify()
    end
    return ok and true or false
end

--- Discard the current wire draft.
function ViewModel:_wire_cancel()
    if not self._wire_draft then return end
    -- If editing an existing step, return focus to it; otherwise unpin.
    local existing = self._wire_draft.existing
    self._wire_draft = nil
    if existing then
        self._selection:pin(existing)
    else
        self._selection:unpin()
    end
    self:_notify()
end

--- Add a deploy step to a launch config.
--- @param parent table   launch ref { kind, project_key, launch_name }
--- @param destination string  the deploy step destination (the dict key)
--- @param extra table   { source_project, target?, path?, pre_build? }
--- @return boolean ok
function ViewModel:_add_deploy_step(parent, destination, extra)
    if parent.kind ~= "launch" then return false end
    if not extra or not extra.source_project then return false end
    if not extra.target and not extra.path then return false end

    local ws = self._workspace_provider()
    local proj = find_project(ws, parent.project_key)
    if not proj then return false end
    local launch = proj.launch and proj.launch[parent.launch_name]
    if not launch then return false end

    -- Build the source descriptor.
    local descriptor = { project = extra.source_project }
    if extra.target then descriptor.target = extra.target end
    if extra.path   then descriptor.path   = extra.path end
    if extra.configuration then descriptor.configuration = extra.configuration end
    if extra.pre_build then descriptor.pre_build = true end

    local updated = vim.tbl_extend("force", {}, launch)
    updated.deploy = vim.tbl_extend("force", {}, launch.deploy or {})
    updated.deploy[destination] = descriptor

    local ok = proj:save_launch_config(parent.launch_name, updated)
    if ok then
        self._selection:pin({
            kind = "deploy_step",
            project_key = parent.project_key,
            launch_name = parent.launch_name,
            destination = destination,
        })
        self:_notify()
    end
    return ok and true or false
end

--- Delete the item the inspector is currently showing.
--- Currently supports: deploy_step, variable, launch, configuration.
--- @return boolean ok
function ViewModel:_delete_inspector_subject()
    local ws = self._workspace_provider()
    if not ws then return false end
    local p = self:presentation()
    local insp = p.inspector
    if not insp or insp.kind == "empty" or insp.missing then return false end

    if insp.kind == "deploy_step" and not insp.launch_name then return false end
    if insp.kind == "deploy_step" then
        local proj = find_project(ws, insp.project_key)
        if not proj then return false end
        local launch = proj.launch and proj.launch[insp.launch_name]
        if not launch or not launch.deploy then return false end
        local updated = vim.tbl_extend("force", {}, launch)
        updated.deploy = vim.tbl_extend("force", {}, launch.deploy)
        updated.deploy[insp.subject] = nil
        if not next(updated.deploy) then updated.deploy = nil end
        local ok = proj:save_launch_config(insp.launch_name, updated)
        if ok then
            self._selection:unpin()
            self:_notify()
        end
        return ok and true or false
    elseif insp.kind == "variable" then
        local proj = find_project(ws, insp.project_key)
        if not proj or not proj.delete_variable then return false end
        local ok = proj:delete_variable(insp.subject)
        if ok then
            self._selection:unpin()
            self:_notify()
        end
        return ok and true or false
    elseif insp.kind == "launch" then
        local proj = find_project(ws, insp.project_key)
        if not proj or not proj.launch then return false end
        local updated_launches = vim.tbl_extend("force", {}, proj.launch)
        updated_launches[insp.subject] = nil
        proj.launch = next(updated_launches) and updated_launches or nil
        proj:_mark_user_owned()
        local ok = proj._workspace and proj._workspace:_save_user() or false
        if ok then
            self._selection:unpin()
            self:_notify()
        end
        return ok and true or false
    elseif insp.kind == "configuration" then
        local proj = find_project(ws, insp.project_key)
        if not proj or not proj.delete_configuration then return false end
        local ok = proj:delete_configuration(insp.subject)
        if ok then
            self._selection:unpin()
            self:_notify()
        end
        return ok and true or false
    end
    return false
end

--- Rename the item the inspector is currently showing.
--- Currently supports: configuration, launch, variable. Other kinds
--- (project, config_set, profile) need atomic propagation across cache /
--- profiles / sets and are deferred to a follow-up slice.
--- @param new_name string
--- @return boolean ok
function ViewModel:_rename_inspector_subject(new_name)
    local ws = self._workspace_provider()
    if not ws or not new_name or new_name == "" then return false end
    local p = self:presentation()
    local insp = p.inspector
    if not insp or insp.missing then return false end

    if insp.kind == "configuration" then
        local proj = find_project(ws, insp.project_key)
        if not proj or not proj.rename_configuration then return false end
        local ok, err = proj:rename_configuration(insp.subject, new_name, {})
        if ok then
            self._selection:pin({
                kind = "configuration",
                project_key = proj.key,
                config_name = new_name,
            })
            self:_notify()
            return true
        end
        ws._core._deps.notify("rename: " .. tostring(err), vim.log.levels.ERROR)
        return false
    elseif insp.kind == "launch" then
        local proj = find_project(ws, insp.project_key)
        if not proj or not proj.launch or not proj.launch[insp.subject] then return false end
        if proj.launch[new_name] then return false end -- collision
        local data = vim.deepcopy(proj.launch[insp.subject])
        local updated = vim.tbl_extend("force", {}, proj.launch)
        updated[new_name] = data
        updated[insp.subject] = nil
        proj.launch = updated
        proj:_mark_user_owned()
        local ok = proj._workspace and proj._workspace:_save_user() or false
        if ok then
            self._selection:pin({
                kind = "launch",
                project_key = proj.key,
                launch_name = new_name,
            })
            self:_notify()
        end
        return ok and true or false
    elseif insp.kind == "variable" then
        local proj = find_project(ws, insp.project_key)
        if not proj or not proj.variables or not proj.variables[insp.subject] then return false end
        if proj.variables[new_name] then return false end -- collision
        local decl = vim.deepcopy(proj.variables[insp.subject])
        if not proj.delete_variable or not proj.save_variable then return false end
        local del_ok = proj:delete_variable(insp.subject)
        if not del_ok then return false end
        local save_ok = proj:save_variable(new_name, decl)
        if save_ok then
            self._selection:pin({
                kind = "variable",
                project_key = proj.key,
                var_name = new_name,
            })
            self:_notify()
        end
        return save_ok and true or false
    end
    return false
end

--- Delete an orphan cached config by cache key.
--- @param cache_key string
function ViewModel:_delete_orphan(cache_key)
    local ws = self._workspace_provider()
    if not ws then return end
    -- Locate the orphaned ConfigUnit by id and delete it. Workspace
    -- exposes orphans via the public API; their ConfigUnits are still
    -- registered in _config_units.
    for _, unit in pairs(ws._config_units or {}) do
        if unit.id == cache_key then
            if unit.delete then unit:delete() end
            return
        end
    end
end

--- Tear down event subscriptions and subscriber list.
function ViewModel:destroy()
    for _, h in ipairs(self._event_handlers) do
        h.events.off(h.event, h.fn)
    end
    self._event_handlers = {}
    self._subscribers = {}
end

--- Test helper: expose the selection object directly.
--- @return loomworks.uiv2.Selection
function ViewModel:_selection_for_test()
    return self._selection
end

return ViewModel

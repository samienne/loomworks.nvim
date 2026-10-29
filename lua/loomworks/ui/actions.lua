--- loomworks/ui/actions.lua — Action factories and deletion dialog.
---
--- Action factories capture context at render time and return closures
--- for deferred execution at action time. They call loomworks API
--- functions; the event system triggers UI refresh automatically.

local M = {}

-- ---------------------------------------------------------------------------
-- Profile action factories (take the profile's view row)
-- ---------------------------------------------------------------------------

--- Activate an existing profile.
--- @param row table the profile's `view.Workspace/1` row
--- @param ws? loomworks.Workspace the page's workspace (default: the loaded one)
function M.activate(row, ws)
    return function()
        require("loomworks.ui.model_calls").call(ws, "Profiles/1.set_active", { profile = row }, function(r)
            local ok, err = require("loomworks.ui.model_calls").result(r)
            if not ok then
                vim.notify("loomworks: " .. tostring(err or "the profile was not activated"), vim.log.levels.ERROR)
            end
        end)
    end
end

--- The page's operation `method` (a `Build/1` call through
--- ui/model_calls.lua) on the profile row, followed by a progress handle:
--- `title` while it runs, `done` once it ended successfully, its error
--- otherwise.
--- @param ws loomworks.Workspace|nil
--- @param method string
--- @param params table
--- @param title string
--- @param doing string
--- @param done string
local function profile_op(ws, method, params, title, doing, done)
    local model = require("loomworks.ui.model_calls")
    local fidget = require("loomworks.fidget")
    local handle = fidget.start_op_action(title)
    fidget.report(handle, doing)
    model.call(ws, method, params, function(r)
        local ok, err = model.result(r)
        if ok then return fidget.finish(handle, done) end
        fidget.fail(handle, err or (title .. " failed"))
    end)
end

--- Build a profile (`b`): `Build/1.build { profile }` — step 5o C2d: named
--- by its row (in `daemon` mode its id).
--- @param row table the profile's `view.Workspace/1` row
--- @param ws? loomworks.Workspace the page's workspace (default: the loaded one)
function M.build(row, ws)
    return function()
        profile_op(ws, "Build/1.build", { profile = row }, "Building " .. tostring(row.key),
            "building...", "built")
    end
end

--- Serial build of a profile (`<C-b>`): `jobs = 1`.
--- @param row table the profile's row
--- @param ws? loomworks.Workspace
function M.build_serial(row, ws)
    return function()
        profile_op(ws, "Build/1.build", { profile = row, jobs = 1 }, "Building (serial) " .. tostring(row.key),
            "building (-j1)...", "built")
    end
end

--- Configure a profile (`c`).
--- @param row table the profile's row
--- @param ws? loomworks.Workspace
function M.configure(row, ws)
    return function()
        profile_op(ws, "Build/1.configure", { profile = row }, "Configuring " .. tostring(row.key),
            "configuring...", "configured")
    end
end

--- The unit rows a clean of `rows` is shown to clean in its confirmation: a
--- configured build directory (the row lists one, and a state other than
--- `unconfigured`). Display only: whether there is anything to clean is
--- decided where the clean runs (the daemon refuses on stdout, the
--- in-process clean resolves at once), never here.
--- @param rows table[] view unit rows
--- @return table[]
local function cleanable(rows)
    local out = {}
    for _, u in ipairs(rows or {}) do
        if u.build_dir and u.state ~= "unconfigured" then out[#out + 1] = u end
    end
    return out
end

--- The confirmation of a clean or rebuild (step 5o C2d, spec/ui.md §1.10),
--- built from the view rows, never the editor's model: the running tasks
--- the clean stops first — in `daemon` mode the editor's own calls on the
--- profile or its units (another client's are never stopped: the clean
--- meets their locks), in-process the rows' running builds and configures —
--- and the units it cleans (`cleanable`).
--- @param ws loomworks.Workspace|nil
--- @param title string
--- @param profile_id string|nil the profile row's id (a profile's clean)
--- @param rows table[] the unit rows in scope
--- @param rebuild boolean|nil
--- @return { lines: string[], highlights: table[] }
function M.clean_confirmation(ws, title, profile_id, rows, rebuild)
    local lines, highlights = {}, {}
    local function add(text, hl)
        lines[#lines + 1] = text
        if hl then highlights[#highlights + 1] = { line = #lines, hl_group = hl } end
    end
    add("  " .. title, "DiagnosticWarn")
    add("")
    local running = {}
    local eo = require("loomworks.daemon.editor_ops")
    if eo.daemon_of(ws) then
        local ids = {}
        for _, u in ipairs(rows) do if u.unit_id ~= nil then ids[#ids + 1] = u.unit_id end end
        for _, call in ipairs(eo.owned_on_ids(ws, profile_id, ids)) do
            running[#running + 1] = call.task and call.task.name or ("task " .. tostring(call.id))
        end
    else
        for _, u in ipairs(rows) do
            if u.state == "building" or u.state == "configuring" then
                running[#running + 1] = tostring(u.project or "?") .. ": "
                    .. (u.state == "building" and "build" or "configure") .. " " .. tostring(u.configuration or "?")
            end
        end
    end
    if #running > 0 then
        table.sort(running)
        add("  Will stop running tasks:", "DiagnosticWarn")
        for _, name in ipairs(running) do add("    " .. name, "DiagnosticWarn") end
        add("")
    end
    add(rebuild and "  Will clean build artifacts then rebuild:"
        or "  Will clean build artifacts and reset to configured:", "DiagnosticWarn")
    for _, u in ipairs(cleanable(rows)) do
        add("    " .. tostring(u.project or "?") .. " / " .. tostring(u.configuration or "?"), "DiagnosticWarn")
    end
    add("")
    add("  Press y to confirm, q to cancel", "Comment")
    return { lines = lines, highlights = highlights }
end

--- Rebuild a profile (`R`): confirmed, its clean (`Build/1.clean`), then —
--- only once the clean ended successfully — its build (spec §19.16 "Editor
--- operations"). Nothing to clean is the clean's own answer, never decided
--- from the rows (in `daemon` mode the daemon's refusal on stdout, INFO and
--- ok; in-process resolved at once): the build follows.
--- @param row table the profile's row
--- @param ws? loomworks.Workspace
function M.rebuild(row, ws)
    return function()
        local key = tostring(row.key)
        local ctx = M.clean_confirmation(ws, "Rebuild profile: " .. key, row.id, row.units or {}, true)
        M._show_confirmation(ctx, function()
            local model = require("loomworks.ui.model_calls")
            local fidget = require("loomworks.fidget")
            local handle = fidget.start_op_action("Rebuilding " .. key)
            local function build()
                fidget.report(handle, "building...")
                model.call(ws, "Build/1.build", { profile = row }, function(r)
                    local ok, err = model.result(r)
                    if ok then return fidget.finish(handle, "rebuilt") end
                    fidget.fail(handle, err or "the build failed")
                end)
            end
            fidget.report(handle, "cleaning...")
            model.call(ws, "Build/1.clean", { profile = row }, function(r)
                local ok, err = model.result(r)
                if ok then return build() end
                fidget.fail(handle, err or "the clean failed")
            end)
        end)
    end
end

--- Clean a profile (`C`): confirmed, `Build/1.clean { profile }`. Nothing to
--- clean is the clean's own answer (in `daemon` mode the daemon's stdout
--- line, notified as INFO), never decided from the rows.
--- @param row table the profile's row
--- @param ws? loomworks.Workspace
function M.clean(row, ws)
    return function()
        local key = tostring(row.key)
        local ctx = M.clean_confirmation(ws, "Clean profile: " .. key, row.id, row.units or {})
        M._show_confirmation(ctx, function()
            profile_op(ws, "Build/1.clean", { profile = row }, "Cleaning " .. key, "cleaning...", "cleaned")
        end)
    end
end

--- `D` on a profile row: delete the profile and the build directories only
--- it uses (`Maintenance/1.execute_deletion { profile }`, M.confirm_deletion).
--- @param row table the profile's `view.Workspace/1` row
--- @param ws? loomworks.Workspace the page's workspace (default: the loaded one)
function M.delete_profile(row, ws)
    return function()
        M.confirm_deletion(ws, { title = "Delete profile: " .. tostring(row.key), target = { profile = row },
            description = row.description, done = "profile '" .. tostring(row.key) .. "' removed" })
    end
end

-- ---------------------------------------------------------------------------
-- Configuration action factories (take a profile's unit row)
-- ---------------------------------------------------------------------------

--- A unit row's operation `method` (`Build/1` through ui/model_calls.lua,
--- the row as `units`; step 5o C2d — in `daemon` mode by its `unit_id`). Its
--- failure was reported where it ran (the task, or the call's notification).
--- @param ws loomworks.Workspace|nil
--- @param method string
--- @param params table
--- @param cb? fun(r: table)
local function unit_op(ws, method, params, cb)
    require("loomworks.ui.model_calls").call(ws, method, params, cb or function() end)
end

--- The name a unit row is shown by in a confirmation.
local function unit_label(u)
    return tostring(u.project or "?") .. " / " .. tostring(u.configuration or "?")
end

--- Build a profile's unit (`b` on its row).
--- @param u table the unit's row (one of a profile row's `units`)
--- @param ws? loomworks.Workspace
function M.build_configuration(u, ws)
    return function() unit_op(ws, "Build/1.build", { units = { u } }) end
end

--- @param u table the unit's row
--- @param ws? loomworks.Workspace
function M.build_serial_configuration(u, ws)
    return function() unit_op(ws, "Build/1.build", { units = { u }, jobs = 1 }) end
end

--- @param u table the unit's row
--- @param ws? loomworks.Workspace
function M.configure_configuration(u, ws)
    return function() unit_op(ws, "Build/1.configure", { units = { u } }) end
end

--- Rebuild a unit (`R`): confirmed, its clean, then — only once the clean
--- ended successfully — its build; a failed clean is reported and nothing
--- is built.
--- @param u table the unit's row
--- @param ws? loomworks.Workspace
function M.rebuild_configuration(u, ws)
    return function()
        local ctx = M.clean_confirmation(ws, "Rebuild: " .. unit_label(u), nil, { u }, true)
        M._show_confirmation(ctx, function()
            local function build() unit_op(ws, "Build/1.build", { units = { u } }) end
            unit_op(ws, "Build/1.clean", { units = { u } }, function(r)
                local ok, err = require("loomworks.ui.model_calls").result(r)
                if ok then return build() end
                vim.notify("loomworks: rebuild of " .. unit_label(u) .. " stopped: clean failed ("
                    .. tostring(err) .. ")", vim.log.levels.ERROR)
            end)
        end)
    end
end

--- Clean a unit (`C`): confirmed, `Build/1.clean { units }`; nothing to
--- clean is the clean's own answer (as M.clean).
--- @param u table the unit's row
--- @param ws? loomworks.Workspace
function M.clean_configuration(u, ws)
    return function()
        local ctx = M.clean_confirmation(ws, "Clean: " .. unit_label(u), nil, { u })
        M._show_confirmation(ctx, function()
            unit_op(ws, "Build/1.clean", { units = { u } })
        end)
    end
end

--- `D` on a profile's unit row: delete the unit's build directory and cached
--- state (`Maintenance/1.execute_deletion { unit }`).
--- @param u table the unit's row (one of a profile row's `units`)
--- @param ws? loomworks.Workspace
function M.delete_config(u, ws)
    return function()
        M.confirm_deletion(ws, { title = "Delete: " .. tostring(u.project or "?") .. " / "
            .. tostring(u.configuration or "?"), target = { unit = u }, done = "configuration cleaned" })
    end
end

--- `D` on an orphaned entry's row: delete its build directory and cache
--- entry (`{ build_dir }`; a directory still shared or holding a live build
--- dir is kept, only the entry dropped).
--- @param row table the `orphaned.configurations[]` row
--- @param ws? loomworks.Workspace
function M.delete_orphaned_config(row, ws)
    return function()
        M.confirm_deletion(ws, { title = "Delete orphaned build dir: " .. tostring(row.key),
            target = { build_dir = row },
            -- (A tree another configuration shares, or one holding a live build
            -- dir, is kept: only its entry goes. The outcome cannot say which.)
            done = "orphaned entry deleted (its directory too, unless still in use)" })
    end
end

--- `D` on a stray build directory (on disk, in no cache entry): `{ stray_dir }`,
--- the path exactly as the view lists it (the daemon matches it against its
--- current stray set).
--- @param dir string the path as listed
--- @param ws? loomworks.Workspace
--- @return fun() closure
function M.delete_stray_dir(dir, ws)
    return function()
        M.confirm_deletion(ws, { title = "Delete stray directory", target = { stray_dir = dir },
            done = "stray directory removed" })
    end
end

--- "Clean all" of the orphaned section: every orphaned and stray build
--- directory (`{ orphans = true }`).
--- @param ws? loomworks.Workspace
function M.delete_orphans(ws)
    return function()
        M.confirm_deletion(ws, { title = "Clean Orphaned Build Dirs", target = { orphans = true },
            done = "orphaned build dirs cleaned" })
    end
end

--- `D` on a project row (and the project browser's `d`): delete the
--- project's build state, then its declaration, then its profiles'
--- toolchain downgrade (`{ project }`).
--- @param prow table the project's `view.Workspace/1` row
--- @param ws? loomworks.Workspace
function M.delete_project(prow, ws)
    return function()
        M.confirm_deletion(ws, { title = "Remove project: " .. tostring(prow.key), target = { project = prow },
            description = prow.description, done = "project '" .. tostring(prow.key) .. "' removed" })
    end
end

--- `<C-n>`: nuke the workspace's build state (`Maintenance/1.nuke`); its
--- workspace is the loaded one (nil to model_calls — also while its load is
--- refused).
function M.nuke()
    M.confirm_deletion(nil, { title = "Reset workspace cache", method = "Maintenance/1.nuke",
        done = "workspace cache reset" })
end

--- Whether the page's workspace `ws` is in `daemon` mode (its rows' tasks
--- are then the ones observed through `Tasks/1`, matched by id).
local function daemon_mode(ws)
    return (require("loomworks.daemon.editor_ops").daemon_of(ws))
end

--- The unit ids of a profile row's unit rows (those that carry one).
--- @param row table
--- @return string[]
local function unit_ids_of(row)
    local ids = {}
    for _, u in ipairs(row.units or {}) do ids[#ids + 1] = u.unit_id end
    return ids
end

--- The cancel of a profile row, or nil when there is nothing to cancel
--- (spec §19.16 "Editor operations"; step 5o C2d-2). In `daemon` mode,
--- while the row runs: the running tasks whose `start` meta names the row's
--- profile id or one of its units' ids (editor_ops.cancel_on_ids) — the
--- editor's own cancelled, another client's left to it (`started by … —
--- cancel it there`). In-process: the bound profile's local tasks.
--- @param row table the profile's `view.Workspace/1` row
--- @param ws? loomworks.Workspace
--- @return fun()|nil
function M.cancel_profile(row, ws)
    if not row.running then return nil end
    if daemon_mode(ws) then
        local eo = require("loomworks.daemon.editor_ops")
        local ids = unit_ids_of(row)
        if #eo.tasks_on_ids(ws, row.id, ids) == 0 then return nil end
        return function()
            local n = #eo.cancel_on_ids(ws, row.id, ids)
            if n > 0 then
                vim.notify(string.format("loomworks: cancelled %d task(s) for profile '%s'", n, tostring(row.key)))
            end
        end
    end
    local profile = require("loomworks.status_source").object_of(row)
    if not profile then return nil end
    return function()
        local n = require("loomworks").cancel_tasks_for_profile(profile)
        vim.notify(string.format("loomworks: cancelled %d task(s) for profile '%s'", n, tostring(row.key)))
    end
end

--- The cancel of a profile's unit row `u` (of profile row `row`), or nil
--- when no task runs it (step 5o C2d-2). In `daemon` mode: the running tasks
--- naming the unit's id or the row's profile id — the whole task that runs
--- it, even the profile's build (editor_ops.cancel_on_ids; another client's
--- is left to it). In-process: the unit's live overseer task (chained tasks
--- behind it abort via the Future's cancel token).
--- @param row table the profile's view row
--- @param u table the unit's view row
--- @param ws? loomworks.Workspace
--- @return fun()|nil
function M.cancel_unit(row, u, ws)
    if daemon_mode(ws) then
        if u.unit_id == nil then return nil end
        local eo = require("loomworks.daemon.editor_ops")
        if #eo.tasks_on_ids(ws, row.id, { u.unit_id }) == 0 then return nil end
        return function()
            local names = {}
            for _, t in ipairs(eo.cancel_on_ids(ws, row.id, { u.unit_id })) do names[#names + 1] = t.name end
            if #names > 0 then vim.notify("loomworks: cancelled task " .. table.concat(names, ", ")) end
        end
    end
    local pp = require("loomworks.status_source").object_of(u)
    local unit = pp and pp._config_unit
    if not (unit and unit._task_id) then return nil end
    return function()
        if require("loomworks").cancel_task(unit._task_id) then
            vim.notify("loomworks: cancelled task " .. tostring(unit._task_id))
        end
    end
end

--- The task output of a profile's unit row `u` (of profile row `row`):
--- `<CR>` / `t` (step 5o C2d-2). In `daemon` mode the latest task observed
--- through `Tasks/1` whose `start` meta names the unit's id or the row's
--- profile id — the running one, else the last that ended
--- (editor_ops.tasks_on_ids) — its kept output (ui/remote_output). In-process
--- the bound unit's last overseer task (M.open_task).
--- @param row table the profile's view row
--- @param u table the unit's view row
--- @param ws? loomworks.Workspace
--- @return fun()
function M.open_unit_task(row, u, ws)
    return function()
        if daemon_mode(ws) then
            local tasks = u.unit_id ~= nil
                and require("loomworks.daemon.editor_ops").tasks_on_ids(ws, row.id, { u.unit_id }, true) or {}
            local pick
            for _, t in ipairs(tasks) do
                if not t.finished then pick = t end
            end
            pick = pick or tasks[#tasks]
            if not pick then
                vim.notify("loomworks: no task output available", vim.log.levels.INFO)
                return
            end
            return require("loomworks.ui.remote_output").show(pick)
        end
        local pp = require("loomworks.status_source").object_of(u)
        local unit = pp and pp._config_unit
        if not unit then
            vim.notify("loomworks: no task output available", vim.log.levels.INFO)
            return
        end
        M.open_task(unit)()
    end
end

--- Open the overseer task output for a ConfigUnit.
--- Closes the status page first (terminal buffers can't layer in floats),
--- reopens it with cursor restored when the task output is dismissed.
--- @param unit loomworks.ConfigUnit
function M.open_task(unit)
    return function()
        if not unit:last_task_id() then
            vim.notify("loomworks: no task output available", vim.log.levels.INFO)
            return
        end
        local lw = require("loomworks")
        local status = require("loomworks.ui.status")
        local win_opts = lw.get_task_output_win()
        status.close()
        vim.schedule(function()
            if not unit:open_task_output(win_opts, function()
                status.open()
            end) then
                vim.notify("loomworks: task output buffer no longer available", vim.log.levels.INFO)
                status.open()
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Profile creation flow
-- ---------------------------------------------------------------------------

--- Build the multi-step profile creation picker: a configuration set (a
--- declared one or an automatic candidate, `ConfigSets/1.candidates`), a
--- toolchain (`Profiles/1.tool_choices`), then `Profiles/1.create` — which
--- adds an automatic set itself (step 5o C2a: one call per user action).
--- @param ctx table { view, ws }
--- @return fun() closure
function M.create_profile(ctx)
    return function()
        local ws = ctx.ws or require("loomworks").get_workspace()
        if not ws then return end
        local model = require("loomworks.ui.model_calls")
        model.call(ws, "ConfigSets/1.candidates", {}, function(r)
            if r.outcome ~= "ok" then
                local _, err = model.result(r)
                vim.notify("loomworks: " .. tostring(err or "the configuration sets were not listed"),
                    vim.log.levels.ERROR)
                return
            end
            local items = r.sets
            if #items == 0 then
                vim.notify("loomworks: no configuration sets available (add projects first)", vim.log.levels.INFO)
                return
            end
            vim.ui.select(items, {
                prompt = "Select configuration set:",
                format_item = function(item)
                    if item.auto then
                        return item.name .. " (auto-detected)" .. (item.desc and ("  (" .. item.desc .. ")") or "")
                    end
                    return item.name .. require("loomworks.ui.helpers").picker_summary(item.description)
                end,
            }, function(choice)
                if not choice then return end
                M._create_profile_step2(ws, choice, #((ctx.view or {}).profiles or {}) == 0)
            end)
        end)
    end
end

--- Step 2: pick a toolchain of the set (`Profiles/1.tool_choices`, read when
--- picked, not at render time: a tool scan may have ended since), then
--- create the profile (+ activate it when it is the first).
--- @param ws loomworks.Workspace|nil
--- @param set table the set's row (a `view.Workspace/1` configuration set, or a candidates entry)
--- @param activate boolean
function M._create_profile_step2(ws, set, activate)
    local model = require("loomworks.ui.model_calls")
    model.call(ws, "Profiles/1.tool_choices", { config_set = set }, function(r)
        if r.outcome ~= "ok" then
            local _, err = model.result(r)
            vim.notify("loomworks: " .. tostring(err or "the toolchains were not listed"), vim.log.levels.ERROR)
            return
        end
        -- Always offer an explicit "no tool" pick so the user can deliberately
        -- create a tool-less profile (e.g. to share the workspace with
        -- collaborators on a host without the SDK installed). The build path
        -- refuses to start an incomplete profile, so this entry is the
        -- explicit opt-in: Profiles/1.create gets no tool.
        local picker_items = {}
        for _, e in ipairs(r.tools or {}) do picker_items[#picker_items + 1] = e end
        picker_items[#picker_items + 1] = { _none = true, label = "(no tool — incomplete profile)" }

        vim.ui.select(picker_items, {
            prompt = "Select tool:",
            format_item = function(entry) return entry.label or entry.key or "(default)" end,
        }, function(choice)
            if not choice then return end
            local tool = not choice._none and choice or nil
            model.call(ws, "Profiles/1.create", { config_set = set, tool = tool, activate = activate }, function(c)
                local profile = c.profile
                if not profile then
                    local _, err = model.result(c)
                    vim.notify("loomworks: " .. tostring(err or "the profile was not created"), vim.log.levels.ERROR)
                elseif not activate then
                    vim.notify("loomworks: profile '" .. profile.key .. "' created", vim.log.levels.INFO)
                end
            end)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Options float
-- ---------------------------------------------------------------------------

--- The options float of a profile's unit row `u` (`o`; step 5o C2d-2): its
--- build options as `Projects/1.unit_options` answers them through
--- ui/model_calls.lua — in `daemon` mode by the row's `unit_id`, never the
--- editor's model; in-process from the bound unit, synchronously.
--- @param u table the unit's view row
--- @param ws? loomworks.Workspace
--- @return fun()
function M.show_options(u, ws)
    return function()
        local model = require("loomworks.ui.model_calls")
        model.call(ws, "Projects/1.unit_options", { unit = u }, function(r)
            if r.outcome ~= "ok" then
                if not r.notified then
                    vim.notify("loomworks: " .. tostring(r.message or "no build options available"),
                        vim.log.levels.INFO)
                end
                return
            end
            M._options_float(r.options, u.project)
        end)
    end
end

--- Open the options float on `option_tree` (`OptionGroup` / `Option` nodes)
--- titled with the project key.
--- @param option_tree table[]
--- @param project string|nil
function M._options_float(option_tree, project)
    if not option_tree or #option_tree == 0 then
        vim.notify("loomworks: no build options available (project may need configure)", vim.log.levels.INFO)
        return
    end
    do
        local Tree = require("loomworks.ui.tree")
        local View = require("loomworks.ui.view")

        local function render_options(tree)
            tree._level = 1

            --- Render a single option as a leaf or foldable node.
            local function render_option(opt, fold_prefix)
                local value_str = opt.value
                if opt.choices and #opt.choices > 0 then
                    value_str = value_str .. "  (" .. table.concat(opt.choices, ", ") .. ")"
                end

                local hl
                if opt.value_type == "bool" then
                    hl = opt.value == "ON" and "DiagnosticOk" or "Comment"
                else
                    hl = "Normal"
                end

                local display = opt.key .. " = " .. value_str
                if opt.helpstring then
                    tree:node(display, {
                        fold_key = fold_prefix .. "opt:" .. opt.key,
                        hl = hl,
                    }, function()
                        tree:leaf(opt.helpstring, "Comment")
                    end)
                else
                    tree:leaf(display, hl)
                end
            end

            --- Recursively render option tree nodes.
            local function render_node(node, fold_prefix)
                if node.children then
                    local count = 0
                    local function count_leaves(n)
                        if n.children then
                            for _, child in ipairs(n.children) do count_leaves(child) end
                        else
                            count = count + 1
                        end
                    end
                    count_leaves(node)

                    tree:node(node.label .. " (" .. count .. ")", {
                        fold_key = fold_prefix .. "group:" .. node.label,
                        hl = "Title",
                    }, function()
                        for _, child in ipairs(node.children) do
                            render_node(child, fold_prefix .. node.label .. ":")
                        end
                    end)
                else
                    render_option(node, fold_prefix)
                end
            end

            for _, node in ipairs(option_tree) do
                render_node(node, "options:")
            end
        end

        local tree = Tree.new(render_options)
        local view = View.new({
            widget = tree,
            win = {
                width = 100,
                height = 0.8,
                zindex = 60,
                backdrop = 60,
                title = " " .. tostring(project or "?") .. " — Options ",
                title_pos = "center",
            },
            keymaps = {
                ["<Tab>"] = "toggle_fold",
            },
            events = {},
        })
        view:open()
    end
end

-- ---------------------------------------------------------------------------
-- Confirmation dialog (thin UI wrapper)
-- ---------------------------------------------------------------------------

--- The one confirmation flow of a deletion or nuke, in both modes (step 5o
--- C2c-2; ui/model_calls): call `o.method` (default
--- `Maintenance/1.execute_deletion`) without a plan; its `confirm` shows the
--- listing it answered (`lines`), `y` calls again with exactly the `plan`
--- that confirmation returned and `yes`, so a deletion never removes what
--- the listing did not show (a changed plan is refused). The outcome is
--- reported once the deletion ended — never when it was only accepted:
--- `o.done` on success, the refusal otherwise ("nothing to delete" as INFO).
--- @param ws loomworks.Workspace|nil the page's workspace (nil: the loaded one)
--- @param o { title: string, target?: table, description?: string, done: string, method?: string }
function M.confirm_deletion(ws, o)
    local model = require("loomworks.ui.model_calls")
    local method = o.method or "Maintenance/1.execute_deletion"
    local function failed(r, fallback)
        local _, err = model.result(r)
        vim.notify("loomworks: " .. tostring(err or fallback),
            r.stream == "out" and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
    model.call(ws, method, { target = o.target }, function(r)
        if r.outcome ~= "confirm" then return failed(r, "nothing was deleted") end
        local lines = { "  " .. o.title, "" }
        local highlights = { { line = 1, hl_group = "DiagnosticError" } }
        for _, l in ipairs(r.lines or {}) do
            lines[#lines + 1] = "  " .. l
            highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        end
        if type(o.description) == "string" and o.description ~= "" then
            lines[#lines + 1] = ""
            for _, l in ipairs(vim.split(o.description, "\n", { plain = true })) do
                lines[#lines + 1] = "  " .. l
                highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  Press y to confirm, q to cancel"
        require("loomworks.ui.dialog").show({
            title = "Confirm",
            lines = lines,
            highlights = highlights,
            max_height = 30,
            keys = {
                n = "close",
                y = function(self)
                    self:close()
                    model.call(ws, method, { target = o.target, plan = r.plan, yes = true }, function(d)
                        if d.outcome ~= "ok" then return failed(d, "the deletion failed") end
                        for _, note in ipairs(d.notes or {}) do
                            vim.notify("loomworks: " .. note, vim.log.levels.WARN)
                        end
                        vim.notify("loomworks: " .. o.done, vim.log.levels.INFO)
                    end)
                end,
            },
        })
    end)
end

--- Show a confirmation dialog from pre-computed context.
--- @param ctx { lines: string[], highlights: table[] }
--- @param on_confirm fun()
function M._show_confirmation(ctx, on_confirm)
    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm",
        lines = ctx.lines,
        highlights = ctx.highlights,
        max_height = 20,
        keys = {
            n = "close",
            y = function(self)
                self:close()
                on_confirm()
            end,
        },
    })
end

return M

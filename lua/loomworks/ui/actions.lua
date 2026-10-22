--- loomworks/ui/actions.lua — Action factories and deletion dialog.
---
--- Action factories capture context at render time and return closures
--- for deferred execution at action time. They call loomworks API
--- functions; the event system triggers UI refresh automatically.

local M = {}

--- Get display-friendly project_key and config_key from a ConfigUnit.
--- @param unit loomworks.ConfigUnit
--- @return string project_key, string config_key
local function unit_display_keys(unit)
    local pkey = unit._project and unit._project.key or unit._init_project_key or "?"
    local ckey = unit:config_key() or unit.id
    return pkey, ckey
end

-- ---------------------------------------------------------------------------
-- Profile action factories (take Profile objects)
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

--- Build an existing profile.
--- @param profile loomworks.Profile
function M.build(profile)
    return function()
        local fidget = require("loomworks.fidget")
        local handle = fidget.start_op_action("Building " .. profile.key)
        fidget.report(handle, "building...")
        profile:build()
            :next(function() fidget.finish(handle, "built") end)
            :catch(function(err) fidget.fail(handle, err) end)
    end
end

--- @param profile loomworks.Profile
function M.build_serial(profile)
    return function()
        local fidget = require("loomworks.fidget")
        local handle = fidget.start_op_action("Building (serial) " .. profile.key)
        fidget.report(handle, "building (-j1)...")
        profile:build({ parallel_jobs = 1 })
            :next(function() fidget.finish(handle, "built") end)
            :catch(function(err) fidget.fail(handle, err) end)
    end
end

--- Configure an existing profile.
--- @param profile loomworks.Profile
function M.configure(profile)
    return function()
        local fidget = require("loomworks.fidget")
        local handle = fidget.start_op_action("Configuring " .. profile.key)
        fidget.report(handle, "configuring...")
        profile:configure()
            :next(function() fidget.finish(handle, "configured") end)
            :catch(function(err) fidget.fail(handle, err) end)
    end
end

--- @param profile loomworks.Profile
function M.rebuild(profile)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local items = wv.collect_clean_items(profile)
        local ctx = wv.compute_clean_confirmation_context(ws, "Rebuild profile: " .. profile.key, items, { rebuild = true })
        M._show_confirmation(ctx, function()
            local fidget = require("loomworks.fidget")
            local handle = fidget.start_op_action("Rebuilding " .. profile.key)
            fidget.report(handle, "cleaning...")
            profile:clean()
                :next(function()
                    fidget.report(handle, "building...")
                    return profile:build()
                end)
                :next(function() fidget.finish(handle, "rebuilt") end)
                :catch(function(err) fidget.fail(handle, err) end)
        end)
    end
end

--- @param profile loomworks.Profile
function M.clean(profile)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local items = wv.collect_clean_items(profile)
        local ctx = wv.compute_clean_confirmation_context(ws, "Clean profile: " .. profile.key, items)
        M._show_confirmation(ctx, function()
            local fidget = require("loomworks.fidget")
            local handle = fidget.start_op_action("Cleaning " .. profile.key)
            fidget.report(handle, "cleaning...")
            profile:clean()
                :next(function() fidget.finish(handle, "cleaned") end)
                :catch(function(err) fidget.fail(handle, err) end)
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
-- Configuration action factories (take ConfigUnit objects)
-- ---------------------------------------------------------------------------

--- @param unit loomworks.ConfigUnit
function M.build_configuration(unit)
    return function()
        require("loomworks.overseer").run_configuration_action(unit, "build")
    end
end

--- @param unit loomworks.ConfigUnit
function M.build_serial_configuration(unit)
    return function()
        require("loomworks.overseer").run_configuration_action(unit, "build", nil, { parallel_jobs = 1 })
    end
end

--- @param unit loomworks.ConfigUnit
function M.configure_configuration(unit)
    return function()
        require("loomworks.overseer").run_configuration_action(unit, "configure")
    end
end

--- @param unit loomworks.ConfigUnit
function M.rebuild_configuration(unit)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local items = wv.collect_clean_items_for_unit(unit)
        local pkey, ckey = unit_display_keys(unit)
        local ctx = wv.compute_clean_confirmation_context(ws,
            "Rebuild: " .. pkey .. " / " .. ckey, items, { rebuild = true })
        M._show_confirmation(ctx, function()
            unit:clean(function()
                require("loomworks.overseer").run_configuration_action(unit, "build")
            end)
        end)
    end
end

--- @param unit loomworks.ConfigUnit
function M.clean_configuration(unit)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local items = wv.collect_clean_items_for_unit(unit)
        local pkey, ckey = unit_display_keys(unit)
        local ctx = wv.compute_clean_confirmation_context(ws,
            "Clean: " .. pkey .. " / " .. ckey, items)
        M._show_confirmation(ctx, function() unit:clean() end)
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

--- @param unit loomworks.ConfigUnit
function M.show_options(unit)
    return function()
        local Tree = require("loomworks.ui.tree")
        local View = require("loomworks.ui.view")
        local option_tree = unit:options()
        if not option_tree or #option_tree == 0 then
            vim.notify("loomworks: no build options available (project may need configure)", vim.log.levels.INFO)
            return
        end

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
                title = " " .. (unit._project and unit._project.key or unit._init_project_key or "?") .. " — Options ",
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

--- loomworks/ui/actions.lua — Action factories and deletion dialog.
---
--- Action factories capture context at render time and return closures
--- for deferred execution at action time. They call loomworks API
--- functions; the event system triggers UI refresh automatically.

local M = {}

-- ---------------------------------------------------------------------------
-- Profile action factories (take Profile objects)
-- ---------------------------------------------------------------------------

--- Activate an existing profile.
--- @param profile loomworks.Profile
function M.activate(profile)
    return function() profile:activate() end
end

--- Activate a profile that may not exist yet (config_sets UI).
--- @param config_set loomworks.ConfigurationSet
--- @param tool_entry? table
function M.activate_new(config_set, tool_entry)
    return function()
        config_set:activate(tool_entry)
    end
end

--- Build an existing profile.
--- @param profile loomworks.Profile
function M.build(profile)
    return function() profile:build() end
end

--- Materialize a new profile then build it.
--- @param config_set loomworks.ConfigurationSet
--- @param tool_entry? table
function M.build_new(config_set, tool_entry)
    return function()
        local profile = config_set:ensure_profile(tool_entry)
        if profile then profile:build() end
    end
end

--- Configure an existing profile.
--- @param profile loomworks.Profile
function M.configure(profile)
    return function() profile:configure() end
end

--- Materialize a new profile then configure it.
--- @param config_set loomworks.ConfigurationSet
--- @param tool_entry? table
function M.configure_new(config_set, tool_entry)
    return function()
        local profile = config_set:ensure_profile(tool_entry)
        if profile then profile:configure() end
    end
end

--- @param profile loomworks.Profile
function M.rebuild(profile)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local items = wv.collect_clean_items(profile)
        local ctx = wv.compute_clean_confirmation_context(ws, "Rebuild profile: " .. profile.key, items, { rebuild = true })
        M._show_confirmation(ctx, function() profile:rebuild() end)
    end
end

--- @param profile loomworks.Profile
function M.clean(profile)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local items = wv.collect_clean_items(profile)
        local ctx = wv.compute_clean_confirmation_context(ws, "Clean profile: " .. profile.key, items)
        M._show_confirmation(ctx, function() profile:clean() end)
    end
end

--- @param profile loomworks.Profile
function M.delete_profile(profile)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local plan = profile:plan_deletion()
        local ctx = wv.compute_delete_confirmation_context(ws, "Delete profile: " .. profile.key, plan)
        M._show_confirmation(ctx, function()
            require("loomworks").execute_deletion(plan, { deactivate_profile = profile }, function()
                vim.notify("loomworks: profile '" .. profile.key .. "' removed", vim.log.levels.INFO)
            end)
        end)
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
        local ctx = wv.compute_clean_confirmation_context(ws,
            "Rebuild: " .. unit.project_key .. " / " .. unit.config_key, items, { rebuild = true })
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
        local ctx = wv.compute_clean_confirmation_context(ws,
            "Clean: " .. unit.project_key .. " / " .. unit.config_key, items)
        M._show_confirmation(ctx, function() unit:clean() end)
    end
end

--- @param unit loomworks.ConfigUnit
function M.delete_config(unit)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local plan = unit:plan_deletion()
        local ctx = wv.compute_delete_confirmation_context(ws,
            "Delete: " .. unit.project_key .. " / " .. unit.config_key, plan)
        M._show_confirmation(ctx, function()
            unit:delete(function()
                vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
            end)
        end)
    end
end

--- @param unit loomworks.ConfigUnit
function M.delete_orphaned_config(unit)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        local orphan_plan = {
            items = { {
                project_key = unit.project_key,
                config_key = unit.config_key,
                disposition = "clean",
            } },
            defined_in_config = false,
        }
        local ctx = wv.compute_delete_confirmation_context(ws,
            "Delete orphaned: " .. unit.project_key .. " / " .. unit.config_key, orphan_plan)
        M._show_confirmation(ctx, function()
            unit:delete(function()
                vim.notify("loomworks: orphaned configuration removed", vim.log.levels.INFO)
            end)
        end)
    end
end

--- Delete a stray build directory (not in cache).
--- @param dir string absolute normalized path
--- @return fun() closure
function M.delete_stray_dir(dir)
    return function()
        local wv = require("loomworks.workspace_view")
        local ws = require("loomworks").get_workspace()
        if not ws then return end

        local ctx = wv.compute_delete_stray_dir_context(ws, dir)
        M._show_confirmation(ctx, function()
            wv.execute_delete_stray_dir(ws, dir, function(ok, err)
                if ok then
                    vim.notify("loomworks: stray directory removed", vim.log.levels.INFO)
                else
                    vim.notify("loomworks: failed to delete: " .. (err or "unknown"), vim.log.levels.ERROR)
                end
            end)
        end)
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

--- @param unit loomworks.ConfigUnit
function M.pin_config(unit)
    return function()
        if #unit:referencing_profiles() > 0 then
            vim.notify("loomworks: already pinned " .. unit.project_key .. " / " .. unit.config_key, vim.log.levels.INFO)
            return
        end
        unit:materialize_pinned()
        vim.notify("loomworks: pinned " .. unit.project_key .. " / " .. unit.config_key, vim.log.levels.INFO)
    end
end

-- ---------------------------------------------------------------------------
-- Profile creation flow
-- ---------------------------------------------------------------------------

--- Build the multi-step profile creation picker.
--- @param ctx table { config_sets, tool_entries, lw }
--- @return fun() closure
function M.create_profile(ctx)
    return function()
        local lw = ctx.lw
        local config_sets = ctx.config_sets or {}
        local tool_entries = ctx.tool_entries or {}
        local ws = lw.get_workspace()
        if not ws then return end

        local wv = require("loomworks.workspace_view")
        local items = wv.compute_config_set_candidates(ws, config_sets)

        if #items == 0 then
            vim.notify("loomworks: no configuration sets available (add projects first)", vim.log.levels.INFO)
            return
        end

        vim.ui.select(items, {
            prompt = "Select configuration set:",
            format_item = function(item)
                if item.auto then
                    return item.name .. "  (" .. item.desc .. ")"
                end
                return item.name
            end,
        }, function(choice)
            if not choice then return end

            local cs, err = wv.resolve_config_set_choice(ws, choice)
            if not cs then
                vim.notify("loomworks: " .. (err or "failed"), vim.log.levels.ERROR)
                return
            end
            local is_first = not next(lw.get_profiles())
            M._create_profile_step2(cs, choice.name or choice.real_name, tool_entries, is_first)
        end)
    end
end

--- Step 2: Pick tool, then materialize (+ activate if first profile).
--- @param cs loomworks.ConfigurationSet
--- @param set_name string
--- @param tool_entries table<string, loomworks.ToolEntry[]>
--- @param activate boolean
function M._create_profile_step2(cs, set_name, tool_entries, activate)
    local wv = require("loomworks.workspace_view")

    local entries = tool_entries[set_name] or {}

    if #entries <= 1 then
        local profile = wv.execute_create_profile(cs, entries[1] or nil, activate)
        if profile and not activate then
            vim.notify("loomworks: profile '" .. profile.key .. "' created", vim.log.levels.INFO)
        end
        return
    end

    vim.ui.select(entries, {
        prompt = "Select tool:",
        format_item = function(entry)
            return entry.tool_label or entry.tool_key or "(default)"
        end,
    }, function(choice)
        if not choice then return end
        local profile = wv.execute_create_profile(cs, choice, activate)
        if profile and not activate then
            vim.notify("loomworks: profile '" .. profile.key .. "' created", vim.log.levels.INFO)
        end
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

        -- Render function for the options tree
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
                    -- It's a group
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
                    -- It's an option
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
                title = " " .. unit.project_key .. " — Options ",
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

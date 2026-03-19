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
        local items = M._collect_clean_items(profile)
        M._show_clean_confirmation("Rebuild profile: " .. profile.key, items, function()
            profile:rebuild()
        end, { rebuild = true })
    end
end

--- @param profile loomworks.Profile
function M.clean(profile)
    return function()
        local items = M._collect_clean_items(profile)
        M._show_clean_confirmation("Clean profile: " .. profile.key, items, function()
            profile:clean()
        end)
    end
end

--- @param profile loomworks.Profile
function M.delete_profile(profile)
    return function()
        local plan = profile:plan_deletion()
        M._show_delete_confirmation("Delete profile: " .. profile.key, plan, function()
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
        local items = M._collect_clean_items_for_unit(unit)
        M._show_clean_confirmation("Rebuild: " .. unit.project_key .. " / " .. unit.config_key, items, function()
            unit:clean(function()
                require("loomworks.overseer").run_configuration_action(unit, "build")
            end)
        end, { rebuild = true })
    end
end

--- @param unit loomworks.ConfigUnit
function M.clean_configuration(unit)
    return function()
        local items = M._collect_clean_items_for_unit(unit)
        M._show_clean_confirmation("Clean: " .. unit.project_key .. " / " .. unit.config_key, items, function()
            unit:clean()
        end)
    end
end

--- @param unit loomworks.ConfigUnit
function M.delete_config(unit)
    return function()
        local plan = unit:plan_deletion()
        M._show_delete_confirmation(
            "Delete: " .. unit.project_key .. " / " .. unit.config_key, plan, function()
            unit:delete(function()
                vim.notify("loomworks: configuration cleaned", vim.log.levels.INFO)
            end)
        end)
    end
end

--- @param unit loomworks.ConfigUnit
function M.delete_orphaned_config(unit)
    return function()
        local orphan_items = { {
            project_key = unit.project_key,
            config_key = unit.config_key,
            disposition = "clean",
        } }
        M._show_delete_confirmation(
            "Delete orphaned: " .. unit.project_key .. " / " .. unit.config_key,
            { items = orphan_items, defined_in_config = false },
            function()
                unit:delete(function()
                    vim.notify("loomworks: orphaned configuration removed", vim.log.levels.INFO)
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
-- Clean/rebuild confirmation dialog
-- ---------------------------------------------------------------------------

--- Collect clean items for a profile (project_key, config_key, build_dir).
--- @param profile loomworks.Profile
--- @return table[]
function M._collect_clean_items(profile)
    local items = {}
    for _, pp in ipairs(profile:projects()) do
        items[#items + 1] = {
            project_key = pp.project_key,
            config_key = pp.config_key,
            build_dir = pp:build_dir(),
        }
    end
    return items
end

--- Collect clean items for a single ConfigUnit.
--- @param unit loomworks.ConfigUnit
--- @return table[]
function M._collect_clean_items_for_unit(unit)
    return { {
        project_key = unit.project_key,
        config_key = unit.config_key,
        build_dir = unit:build_dir(),
    } }
end

--- Make a path relative to workspace root for display.
--- @param abs string|nil
--- @return string|nil
local function rel_path(abs)
    if not abs then return abs end
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return abs end
    local ws_root = vim.fs.normalize(ws.root)
    local normalized = vim.fs.normalize(abs)
    if normalized:sub(1, #ws_root) == ws_root then
        local rel = normalized:sub(#ws_root + 1)
        if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
        return rel ~= "" and rel or "."
    end
    return abs
end

--- Show a confirmation dialog for clean/rebuild actions.
--- @param title string
--- @param items table[] { project_key, config_key, build_dir? }
--- @param on_confirm fun()
--- @param opts? { rebuild?: boolean }
function M._show_clean_confirmation(title, items, on_confirm, opts)
    local lw = require("loomworks")
    local lines = {}
    local highlights = {}

    local function add(text, hl)
        lines[#lines + 1] = text
        if hl then
            highlights[#highlights + 1] = { line = #lines, hl_group = hl }
        end
    end

    add("  " .. title, "DiagnosticWarn")
    add("")

    local running_tasks = lw.find_running_tasks_for_items(items)
    local has_running = false
    for _ in pairs(running_tasks) do has_running = true; break end

    if has_running then
        add("  Will stop running tasks:", "DiagnosticWarn")
        for _, info in pairs(running_tasks) do
            add("    " .. info.project_key .. ": " .. info.action .. " " .. info.configuration_key,
                "DiagnosticWarn")
        end
        add("")
    end

    opts = opts or {}
    local desc = opts.rebuild
        and "  Will clean build artifacts then rebuild:"
        or "  Will clean build artifacts and reset to configured:"
    add(desc, "DiagnosticWarn")
    for _, item in ipairs(items) do
        add("    " .. item.project_key .. " / " .. item.config_key, "DiagnosticWarn")
    end
    add("")

    add("  Press y to confirm, q to cancel", "Comment")

    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm",
        lines = lines,
        highlights = highlights,
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

-- ---------------------------------------------------------------------------
-- Deletion confirmation dialog
-- ---------------------------------------------------------------------------

--- Show a confirmation dialog for deleting configurations.
--- @param title string
--- @param plan loomworks.DeletionPlan
--- @param on_confirm fun()
function M._show_delete_confirmation(title, plan, on_confirm)
    local lw = require("loomworks")
    local items = plan.items
    local lines = {}
    local highlights = {}

    local function add(text, hl)
        lines[#lines + 1] = text
        if hl then
            highlights[#highlights + 1] = { line = #lines, hl_group = hl }
        end
    end

    add("  " .. title, "DiagnosticWarn")
    add("")

    local running_tasks = lw.find_running_tasks_for_items(items)
    local running_task_ids = {}
    for task_id in pairs(running_tasks) do
        running_task_ids[#running_task_ids + 1] = task_id
    end

    if #running_task_ids > 0 then
        add("  Will stop running tasks:", "DiagnosticWarn")
        for _, info in pairs(running_tasks) do
            add("    " .. info.project_key .. ": " .. info.action .. " " .. info.configuration_key,
                "DiagnosticWarn")
        end
        add("")
    end

    -- Split items by disposition
    local clean_items, reset_items, keep_items = {}, {}, {}
    for _, item in ipairs(items) do
        if item.disposition == "keep" then
            keep_items[#keep_items + 1] = item
        elseif item.disposition == "reset" then
            reset_items[#reset_items + 1] = item
        else
            clean_items[#clean_items + 1] = item
        end
    end

    if #clean_items > 0 then
        add("  Will remove:", "DiagnosticError")
        for _, item in ipairs(clean_items) do
            local dir = item.build_dir and rel_path(item.build_dir) or nil
            local suffix = dir and ("  " .. dir) or ""
            add("    " .. item.project_key .. " / " .. item.config_key .. suffix, "DiagnosticError")
        end
        add("")
    end

    if #reset_items > 0 then
        add("  Will reset to unconfigured:", "DiagnosticWarn")
        for _, item in ipairs(reset_items) do
            local dir = item.build_dir and rel_path(item.build_dir) or nil
            local suffix = dir and ("  " .. dir) or ""
            add("    " .. item.project_key .. " / " .. item.config_key .. suffix, "DiagnosticWarn")
        end
        add("")
    end

    if #keep_items > 0 then
        add("  Will keep (referenced by another profile):", "Comment")
        for _, item in ipairs(keep_items) do
            add("    " .. item.project_key .. " / " .. item.config_key, "Comment")
        end
        add("")
    end

    if #items == 0 and plan.profile_key then
        add("  No configurations to clean.", "Comment")
        add("")
    end

    add("  Press y to confirm, q to cancel", "Comment")

    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Confirm Delete",
        lines = lines,
        highlights = highlights,
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

--- loomworks/ui/project_browser.lua — Directory browser for adding projects.
---
--- Snacks.win float with Tree widget. Scans workspace directories
--- asynchronously and shows detected project types. Users can add or
--- remove projects from here.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local modules = require("loomworks.modules")
local workspace_view = require("loomworks.workspace_view")

local M = {}

--- @class loomworks.BrowserEntry
--- @field name string directory basename
--- @field abs_path string absolute path
--- @field types { type: string, marker: string }[]
--- @field scanning boolean

--- Build the set of project keys currently in loomworks.json.
--- Returns a set keyed by (relative_path, type) for checking "already added".
--- @param root string
--- @return table<string, table<string, true>>  path -> { type -> true }
local function build_added_set(root)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws or not ws.config or not ws.config.projects then return {} end

    local added = {}
    for key, proj in pairs(ws.config.projects) do
        local rel = proj.path or key
        if not added[rel] then added[rel] = {} end
        added[rel][proj.type] = true
    end
    return added
end

--- Derive the project key and optional path for a browser entry.
--- Root-level: basename as key, path omitted.
--- Nested: relative path as key, explicit path field.
--- @param root string workspace root
--- @param entry loomworks.BrowserEntry
--- @return string key, string|nil path
local function derive_key_and_path(root, entry)
    local rel = entry.abs_path:sub(#root + 2) -- strip root + "/"
    if rel == "" then
        -- Root directory itself — use basename as key, path = "."
        return entry.name, "."
    elseif rel == entry.name then
        -- Root-level child directory
        return entry.name, nil
    else
        -- Nested directory — use relative path as key
        return rel:gsub("/", "_"), rel
    end
end

--- Open the project browser for a workspace root.
--- @param root string absolute workspace root
function M.open(root)
    --- @type table<string, loomworks.BrowserEntry[]>
    local scan_cache = {}
    --- @type table<string, boolean>
    local scanning = {}

    local tree, view

    --- Trigger an async scan for a directory and refresh on completion.
    --- @param abs_path string
    local function scan_dir(abs_path)
        if scan_cache[abs_path] or scanning[abs_path] then return end
        scanning[abs_path] = true
        modules.scan_directory_async(abs_path, nil, function(entries)
            scanning[abs_path] = nil
            scan_cache[abs_path] = entries
            if view and view:is_open() then
                view:refresh()
            end
        end)
    end

    --- Check if a type is already added for a relative path.
    --- @param added table
    --- @param rel string
    --- @param type_name string
    --- @return boolean
    local function is_added(added, rel, type_name)
        return added[rel] and added[rel][type_name] or false
    end

    --- Open the mapping dialog with detected tools for a new project.
    --- Chains decomposed operations on accept via workspace_view.
    --- @param type_info { type: string, marker: string }
    --- @param key string project key
    --- @param path string|nil relative path
    --- @param config_names string[] available configuration names
    --- @param keyed_tools table[] detected keyed tools (may be empty)
    local function open_mapping_dialog(type_info, key, path, config_names, keyed_tools)
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        local raw_config_sets = ws.config.configuration_sets
        local mod = modules.get(type_info.type)
        local has_keyed = mod and mod.has_keyed_tools or false

        local ctx = workspace_view.compute_add_project_context(ws, type_info.type)

        require("loomworks.ui.mapping_dialog").open({
            ws = ws,
            project_key = key,
            project_type = type_info.type,
            available_configs = config_names,
            config_sets = raw_config_sets,
            mod = mod,
            tools = ctx.inherited_tool and {} or keyed_tools,
            has_keyed_tools = has_keyed,
            inherited_tool = ctx.inherited_tool,
            no_tool_profiles = ctx.no_tool_profiles,
            on_accept = function(result)
                local ok, err = workspace_view.execute_add_project(ws, key, type_info.type, path, result, has_keyed)
                if not ok then
                    vim.notify("loomworks: " .. (err or "failed to add project"), vim.log.levels.ERROR)
                end
            end,
            on_cancel = function() end,
        })
    end

    --- Add a project from a browser entry.
    --- If configuration sets exist, opens a mapping dialog first.
    --- For keyed-module types, ensures tool detection completes first.
    --- @param entry loomworks.BrowserEntry
    --- @param type_info { type: string, marker: string }
    local function do_add(entry, type_info)
        local key, path = derive_key_and_path(root, entry)

        -- Check if configuration sets exist
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        local raw_config_sets = ws and ws.config and ws.config.configuration_sets or nil
        local has_config_sets = raw_config_sets and next(raw_config_sets)

        if not has_config_sets then
            -- No config sets: add directly
            local ok, err = ws:add_project(key, type_info.type, path)
            if not ok then
                vim.notify("loomworks: " .. (err or "failed to add project"), vim.log.levels.ERROR)
            end
            return
        end

        -- Detect available configurations for the new project
        local mod = modules.get(type_info.type)
        local config_names = {}
        if mod and mod.info and mod.map_variant then
            local info = mod.info(entry.abs_path, {})
            if info and info.configurations then
                for name in pairs(info.configurations) do
                    config_names[#config_names + 1] = name
                end
                table.sort(config_names)
            end
        end

        if #config_names == 0 then
            -- No detectable configurations: add without mappings
            local ok, err = ws:add_project(key, type_info.type, path)
            if not ok then
                vim.notify("loomworks: " .. (err or "failed to add project"), vim.log.levels.ERROR)
            end
            return
        end

        -- Check if module has keyed tools requiring detection
        local has_keyed = mod and mod.has_keyed_tools or false

        if has_keyed then
            workspace_view.ensure_tools_detected(ws, mod, type_info.type, function(keyed_tools)
                open_mapping_dialog(type_info, key, path, config_names, keyed_tools)
            end)
        else
            open_mapping_dialog(type_info, key, path, config_names, {})
        end
    end

    --- Remove a project that matches a browser entry.
    --- @param entry loomworks.BrowserEntry
    local function do_remove(entry)
        local rel = entry.abs_path:sub(#root + 2)
        if rel == "" then rel = "." end
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        if not ws or not ws.config or not ws.config.projects then return end

        -- Find the project key that matches this path
        local found_key
        for key, proj in pairs(ws.config.projects) do
            local proj_rel = proj.path or key
            if proj_rel == rel or proj_rel == entry.name then
                found_key = key
                break
            end
        end

        if not found_key then
            vim.notify("loomworks: project not found in workspace", vim.log.levels.WARN)
            return
        end

        local ctx = workspace_view.compute_remove_context(ws, found_key)
        if not ctx then return end

        local dialog = require("loomworks.ui.dialog")
        dialog.show({
            title = "Confirm Remove",
            lines = ctx.lines,
            highlights = ctx.highlights,
            keys = {
                n = "close",
                y = function(self)
                    self:close()
                    local ok, err = workspace_view.execute_remove_project(
                        ws, found_key, ctx.project_type, #ctx.downgrade_preview > 0)
                    if not ok then
                        vim.notify("loomworks: " .. (err or "failed to remove"), vim.log.levels.ERROR)
                    end
                end,
            },
        })
    end

    --- Render a single browser entry line.
    --- @param t loomworks.Tree
    --- @param entry loomworks.BrowserEntry
    --- @param added table
    --- @param parent_path string
    local function render_entry(t, entry, added, parent_path)
        local rel = entry.abs_path:sub(#root + 2)
        if rel == "" then rel = "." end
        local types = entry.types
        local has_types = types and #types > 0

        -- Build type tag chunks for post-patch highlighting
        local tag_chunks = {}
        if has_types then
            for _, ti in ipairs(types) do
                local tag_hl = is_added(added, rel, ti.type) and "DiagnosticOk" or "LoomworksActionable"
                tag_chunks[#tag_chunks + 1] = { "  ", nil }
                tag_chunks[#tag_chunks + 1] = { "[" .. ti.type .. ": " .. ti.marker .. "]", tag_hl }
            end
        end

        -- Check if any type is already added
        local any_added = false
        if has_types and added[rel] then
            for _, ti in ipairs(types) do
                if added[rel][ti.type] then
                    any_added = true
                    break
                end
            end
        end
        -- Also check by basename for root-level projects
        if not any_added and added[entry.name] then
            any_added = true
            if not added[rel] then
                rel = entry.name
            end
        end

        if any_added then
            tag_chunks[#tag_chunks + 1] = { "  ", nil }
            tag_chunks[#tag_chunks + 1] = { "✓", "DiagnosticOk" }
        end

        -- Build full display text for the node
        local suffix_parts = {}
        for _, chunk in ipairs(tag_chunks) do
            suffix_parts[#suffix_parts + 1] = chunk[1]
        end
        local display = entry.name .. table.concat(suffix_parts)

        -- Capture the line number where node() will add its line
        local node_ln = #t.lines + 1

        -- Build picker items: add actions for unadded types, remove for added
        local picker_items = {}
        if has_types then
            for _, ti in ipairs(types) do
                if not is_added(added, rel, ti.type)
                    and not is_added(added, entry.name, ti.type) then
                    picker_items[#picker_items + 1] = {
                        label = "Add [" .. ti.type .. "]",
                        callback = function() do_add(entry, ti) end,
                    }
                end
            end
        end
        if has_types then
            for _, ti in ipairs(types) do
                if is_added(added, rel, ti.type)
                    or is_added(added, entry.name, ti.type) then
                    picker_items[#picker_items + 1] = {
                        label = "Remove [" .. ti.type .. "]",
                        callback = function() do_remove(entry) end,
                        destructive = true,
                    }
                end
            end
        end

        -- Build on_enter: always show picker when items exist
        local on_enter_fn = #picker_items > 0 and function()
            vim.ui.select(picker_items, {
                prompt = entry.name .. ":",
                format_item = function(item) return item.label end,
            }, function(choice)
                if choice then choice.callback() end
            end)
        end or nil

        -- Foldable node for directories (can have children)
        t:node(display, {
            fold_key = "browser:" .. entry.abs_path,
            hl = has_types and nil or "Comment",
            direct = on_enter_fn ~= nil,
            on_enter = on_enter_fn,
            on_delete = any_added and function() do_remove(entry) end or nil,
        }, function()
            -- Lazy scan children on fold open
            local child_path = entry.abs_path
            if not scan_cache[child_path] and not scanning[child_path] then
                scan_dir(child_path)
            end
            if scanning[child_path] then
                t:leaf("scanning...", "Comment")
            elseif scan_cache[child_path] then
                local children = scan_cache[child_path]
                if #children == 0 then
                    t:leaf("(no subdirectories)", "Comment")
                else
                    for _, child in ipairs(children) do
                        render_entry(t, child, added, child_path)
                    end
                end
            end
        end)

        -- Apply per-chunk highlights on the node line (after fold prefix + name)
        if #tag_chunks > 0 then
            local line_text = t.lines[node_ln]
            -- Find where the name starts by locating it after the fold prefix
            local name_start = line_text:find(entry.name, 1, true)
            if name_start then
                local col = name_start - 1 + #entry.name
                for _, chunk in ipairs(tag_chunks) do
                    local len = #chunk[1]
                    if chunk[2] then
                        t.highlights[#t.highlights + 1] = {
                            line = node_ln, col_start = col, col_end = col + len, hl_group = chunk[2],
                        }
                    end
                    col = col + len
                end
            end
        end
    end

    local function render_fn(t)
        t._level = 1
        t:leaf("Add Project", "Title")
        t:blank()

        local added = build_added_set(root)
        local root_name = root:match("([^/]+)$") or root

        -- Root is the single top-level foldable node, open by default on first render
        local root_fold_key = "browser:" .. root
        if t._folds[root_fold_key] == nil then
            t._folds[root_fold_key] = true
        end

        -- Treat root as a proper entry with detection
        local root_entry = {
            name = root_name,
            abs_path = root,
            types = modules.detect_all_types(root),
        }
        render_entry(t, root_entry, added, root)

        t:blank()
        t:leaf("[Enter] add  [d] remove  [r] refresh  [q] close", "Comment")
    end

    tree = Tree.new(render_fn)

    -- Capture the current window so we can refocus it when the browser closes
    local parent_win = vim.api.nvim_get_current_win()

    view = View.new({
        widget = tree,
        win = {
            width = 100,
            height = 0.8,
            zindex = 60,
            backdrop = 60,
            title = " Add Project ",
            title_pos = "center",
        },
        keymaps = {
            ["<Tab>"]   = "next_item",
            ["<S-Tab>"] = "prev_item",
            ["l"]       = "open_fold",
            ["h"]       = "close_fold",
            ["<CR>"]    = "enter",
            ["d"]       = "delete",
            ["r"]       = "refresh_browser",
        },
        events = {
            "active_set_changed",
        },
        on_close = function()
            if parent_win and vim.api.nvim_win_is_valid(parent_win) then
                vim.api.nvim_set_current_win(parent_win)
            end
        end,
    })

    -- Add custom action for refresh
    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "refresh_browser" then
            scan_cache = {}
            scanning = {}
            scan_dir(root)
            return { refresh = true }
        end
        if action == "delete" then
            -- Walk up to find entry with on_delete
            for l = line, 1, -1 do
                local w = self.line_meta[l]
                if w and w.on_delete then
                    w.on_delete()
                    return {}
                end
            end
            return {}
        end
        return orig_on_key(self, action, line)
    end

    view:open()

    -- Kick off initial scan
    scan_dir(root)
end

return M

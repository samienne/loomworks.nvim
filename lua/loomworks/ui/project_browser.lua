--- loomworks/ui/project_browser.lua — Directory browser for adding projects.
---
--- Snacks.win float with Tree widget. Scans workspace directories
--- asynchronously and shows detected project types. Users can add or
--- remove projects from here. Adding is `Projects/1.candidates` (the key and
--- path the directory gets) then `Projects/1.add` through
--- loomworks.ui.model_calls (in `daemon` mode the daemon's; step 5o C2b);
--- the projects already added are the workspace view's rows in `daemon`
--- mode. Removing still reads the editor's model (until C2c).

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local modules = require("loomworks.modules")
local workspace_view = require("loomworks.workspace_view")
local model = require("loomworks.ui.model_calls")

local M = {}

--- @class loomworks.BrowserEntry
--- @field name string directory basename
--- @field abs_path string absolute path
--- @field types { type: string, marker: string }[]

--- Build the set of the workspace's projects, keyed by (relative_path,
--- type) for checking "already added": in `daemon` mode from the workspace
--- view's project rows (none while it is not held), else from the editor's
--- model.
--- @return table<string, table<string, true>>  path -> { type -> true }
local function build_added_set()
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return {} end

    local added = {}
    local function add(rel, type_name)
        if not added[rel] then added[rel] = {} end
        added[rel][type_name] = true
    end
    local daemon, obs = require("loomworks.daemon.editor_ops").daemon_of(ws)
    if daemon then
        local view = obs and obs:workspace_view() or nil
        for _, row in ipairs(type(view) == "table" and view.projects or {}) do add(row.path, row.type) end
        return added
    end
    for _, proj in pairs(ws._projects) do add(proj.path or proj.key, proj.type) end
    return added
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

    --- Add a project from a browser entry: its key and path
    --- (`Projects/1.candidates`), then the project, unmapped — configuration
    --- set mappings and tool/SDK selection happen separately via the status
    --- page.
    --- @param entry loomworks.BrowserEntry
    --- @param type_info { type: string, marker: string }
    local function do_add(entry, type_info)
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        if not ws then return end
        local function failed(err)
            vim.notify("loomworks: " .. (err or "failed to add project"), vim.log.levels.ERROR)
        end
        model.call(ws, "Projects/1.candidates", { path = entry.abs_path, type = type_info.type }, function(c)
            if c.outcome ~= "ok" then return failed(c.message) end
            model.call(ws, "Projects/1.add", { key = c.key, type = type_info.type, path = c.path, mappings = {} },
                function(r)
                    local ok, err = model.result(r)
                    if not ok then failed(err) end
                end)
        end)
    end

    --- Remove a project that matches a browser entry.
    --- @param entry loomworks.BrowserEntry
    local function do_remove(entry)
        local rel = entry.abs_path:sub(#root + 2)
        if rel == "" then rel = "." end
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        if not ws then return end

        local project = workspace_view.find_project_by_path(ws, rel, entry.name)
        if not project then
            vim.notify("loomworks: project not found in workspace", vim.log.levels.WARN)
            return
        end

        local ctx = workspace_view.compute_remove_context(ws, project)
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
                    model.call(ws, "Maintenance/1.execute_deletion",
                        { target = { project = project }, confirmed = ctx }, function(r)
                            -- no message when the deletion's lock was refused
                            -- (already reported by the workspace)
                            if r.outcome ~= "ok" and r.message then
                                vim.notify("loomworks: " .. r.message, vim.log.levels.ERROR)
                            end
                        end)
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

        local tag_chunks = {}
        if has_types then
            for _, ti in ipairs(types) do
                local tag_hl = is_added(added, rel, ti.type) and "DiagnosticOk" or "LoomworksActionable"
                tag_chunks[#tag_chunks + 1] = { "  ", nil }
                tag_chunks[#tag_chunks + 1] = { "[" .. ti.type .. ": " .. ti.marker .. "]", tag_hl }
            end
        end
        -- Shell has no marker, so it never appears in `types`. When the
        -- user has declared a shell project at this folder, show a
        -- `[shell: custom]` tag in the listing for parity with detected
        -- types — without it the ✓ checkmark alone is ambiguous.
        if is_added(added, rel, "shell") or is_added(added, entry.name, "shell") then
            tag_chunks[#tag_chunks + 1] = { "  ", nil }
            tag_chunks[#tag_chunks + 1] = { "[shell: custom]", "DiagnosticOk" }
        end

        local any_added = false
        if has_types and added[rel] then
            for _, ti in ipairs(types) do
                if added[rel][ti.type] then
                    any_added = true
                    break
                end
            end
        end
        -- Also catch shell, which isn't in `types`
        if not any_added and (is_added(added, rel, "shell")
                or is_added(added, entry.name, "shell")) then
            any_added = true
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

        local suffix_parts = {}
        for _, chunk in ipairs(tag_chunks) do
            suffix_parts[#suffix_parts + 1] = chunk[1]
        end
        local display = entry.name .. table.concat(suffix_parts)

        -- Capture the line number where node() will add its line
        local node_ln = #t.lines + 1

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

        -- The shell module never auto-detects (no marker), but a project
        -- with a self-managed build system may still want to be declared
        -- against this folder. Always offer it as an explicit picker
        -- entry alongside detected types, distinct-labeled as "(custom)"
        -- so it doesn't visually compete with the recommended type.
        if not is_added(added, rel, "shell")
            and not is_added(added, entry.name, "shell") then
            picker_items[#picker_items + 1] = {
                label = "Add as shell (custom)",
                callback = function()
                    do_add(entry, { type = "shell", marker = "(custom)" })
                end,
            }
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

        -- Surface a Remove for shell separately — `types` doesn't carry
        -- shell entries (no marker), so the loop above won't pick it up
        -- even when shell IS added at this path.
        if is_added(added, rel, "shell")
            or is_added(added, entry.name, "shell") then
            picker_items[#picker_items + 1] = {
                label = "Remove [shell]",
                callback = function() do_remove(entry) end,
                destructive = true,
            }
        end

        local on_enter_fn = #picker_items > 0 and function()
            vim.ui.select(picker_items, {
                prompt = entry.name .. ":",
                format_item = function(item) return item.label end,
            }, function(choice)
                if choice then choice.callback() end
            end)
        end or nil

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

        local added = build_added_set()
        local root_name = root:match("([^/]+)$") or root

        -- Root is the single top-level foldable node, open by default on first render
        local root_fold_key = "browser:" .. root
        if t._folds[root_fold_key] == nil then
            t._folds[root_fold_key] = true
        end

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

    local orig_on_key = tree.on_key
    function tree:on_key(action, line)
        if action == "refresh_browser" then
            scan_cache = {}
            scanning = {}
            scan_dir(root)
            return { refresh = true }
        end
        if action == "delete" then
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

    scan_dir(root)
end

return M

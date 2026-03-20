--- loomworks/ui/status.lua — Workspace status page.
---
--- Thin wiring: creates a Tree widget inside a View, assembles sections
--- with data from the loomworks API. All rendering logic lives in
--- section files; all UI machinery lives in View and Tree.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local actions = require("loomworks.ui.actions")

local M = {}

-- ---------------------------------------------------------------------------
-- Render function — assembles sections
-- ---------------------------------------------------------------------------

local function render_fn(tree)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then
        local err = lw.get_setup_error()
        if err then
            tree._level = 1
            tree:leaf("loomworks.nvim " .. lw._version, "Title")
            tree:blank()
            tree:leaf("Failed to load workspace", "DiagnosticError")
            tree:leaf("Root: " .. err.root, "Comment")
            tree:blank()
            tree:leaf(err.message, "DiagnosticWarn")
        else
            tree:leaf("No workspace loaded.", "Comment")
            tree:blank()
            tree:leaf("Press L to load from:", "Comment")
            tree:leaf("  " .. vim.fn.getcwd(), "DiagnosticInfo")
            tree:blank()
            tree:leaf("Press N to create a new workspace", "Comment")
        end
        return
    end

    tree._level = 1

    -- Header
    tree:leaf("loomworks.nvim " .. lw._version, "Title")
    tree:blank()
    tree:leaf("Workspace: " .. ws.name, "Type")
    tree:leaf("Root:      " .. ws.root, "Comment")
    tree:leaf("[?] help  [L] load  [<C-n>] reset", "Comment")
    tree:blank()

    local active_set = lw.get_active_configuration_set()

    local ctx = {
        lw = lw,
        all_profiles = lw.get_profiles(),
        active_profile = lw.get_active_profile(),
        active_set = active_set,
        config_sets = lw.get_config_sets(),
        tool_entries = lw.get_tool_entries(),
    }

    require("loomworks.ui.sections.profiles")(tree, ctx)
    require("loomworks.ui.sections.orphaned")(tree, ctx)
    require("loomworks.ui.sections.config_sets")(tree, ctx)

    ctx.projects = lw.get_projects()
    require("loomworks.ui.sections.projects")(tree, ctx)

    require("loomworks.ui.sections.lsp")(tree, ctx)
end

-- ---------------------------------------------------------------------------
-- View instance
-- ---------------------------------------------------------------------------

local tree = Tree.new(render_fn)

local view = View.new({
    widget = tree,
    win = {
        position = "float",
        width = 100,
        height = 0.9,
        border = "rounded",
        title = " loomworks ",
        title_pos = "center",
    },
    keymaps = {
        ["<Tab>"]   = "next_item",
        ["<S-Tab>"] = "prev_item",
        ["l"]       = "open_fold",
        ["h"]       = "close_fold",
        ["<CR>"]    = "enter",
        ["b"]     = "build",
        ["R"]     = "rebuild",
        ["c"]     = "configure",
        ["C"]     = "clean",
        ["D"]     = "delete",
        ["t"]     = "task",
        ["p"]     = "pin",
        ["o"]     = "options",
        ["N"]     = "create_workspace",
        ["L"]     = "load",
        ["<C-n>"] = "nuke",
        ["U"]     = "delete_user_prefs",
        ["?"]     = "help",
    },
    events = {
        "task_started",
        "task_stopped",
        "task_result",
        "task_progress",
        "deletion_started",
        "deletion_completed",
        "deletion_failed",
        "active_set_changed",
        "operation_started",
        "operation_finished",
    },
})

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local _saved_cursor = nil

function M.open(win_overrides)
    view:open(win_overrides)
    if _saved_cursor and view:is_open() then
        local win = view._snacks_win and view._snacks_win.win
        if win and vim.api.nvim_win_is_valid(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            local line_count = vim.api.nvim_buf_line_count(buf)
            if _saved_cursor <= line_count then
                vim.api.nvim_win_set_cursor(win, { _saved_cursor, 0 })
            end
        end
        _saved_cursor = nil
    end
end
function M.close()
    -- Save cursor before closing
    if view:is_open() then
        local win = view._snacks_win and view._snacks_win.win
        if win and vim.api.nvim_win_is_valid(win) then
            _saved_cursor = vim.api.nvim_win_get_cursor(win)[1]
        end
    end
    view:close()
end
function M.toggle()  view:toggle() end
function M.refresh() view:refresh() end

function M.is_open()
    return view:is_open()
end

--- Delete a profile interactively (with confirmation dialog).
--- @param profile_key string
function M.delete_profile(profile_key)
    local profile = require("loomworks").get_profiles()[profile_key]
    if not profile then return end
    actions.delete_profile(profile)()
end

--- Delete a configuration interactively (with confirmation dialog).
--- @param project_key string
--- @param config_key string
function M.delete_config(project_key, config_key)
    local unit = require("loomworks").get_config_unit(project_key, config_key)
    actions.delete_config(unit)()
end

return M

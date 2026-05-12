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
    -- Banner: loomworks.json missing on disk (specification.md §2.4).
    -- The workspace continues to function from user.json; :w will publish.
    local config_path = ws.root .. "/loomworks.json"
    if not (vim.uv or vim.loop).fs_stat(config_path) then
        tree:leaf("⚠ loomworks.json not on disk — :w to publish",
            "DiagnosticWarn")
    end
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

    require("loomworks.ui.sections.diagnostics")(tree, ctx)
    require("loomworks.ui.sections.profiles")(tree, ctx)
    require("loomworks.ui.sections.orphaned")(tree, ctx)
    require("loomworks.ui.sections.config_sets")(tree, ctx)

    ctx.projects = lw.get_projects()
    require("loomworks.ui.sections.projects")(tree, ctx)

    require("loomworks.ui.sections.lsp")(tree, ctx)
    require("loomworks.ui.sections.debug")(tree, ctx)
    require("loomworks.ui.sections.sdks")(tree, ctx)
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
        ["<C-b>"] = "build_serial",
        ["R"]     = "rebuild",
        ["c"]     = "configure",
        ["C"]     = "clean",
        ["D"]     = "delete",
        ["t"]     = "task",
        ["o"]     = "options",
        ["P"]     = "publish",
        ["N"]     = "create_workspace",
        ["L"]     = "load",
        ["<C-n>"] = "nuke",
        ["U"]     = "delete_user_prefs",
        ["?"]     = "help",
    },
    is_modified = function()
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        return ws and ws:has_any_modified() or false
    end,
    on_write = function()
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        if not ws then
            vim.notify("loomworks: no workspace", vim.log.levels.WARN)
            return
        end
        local ok, err = ws:publish()
        if not ok then
            vim.notify("loomworks: publish failed: " .. (err or "unknown"), vim.log.levels.ERROR)
        end
    end,
    on_revert = function()
        local lw = require("loomworks")
        local ws = lw.get_workspace()
        if not ws then
            vim.notify("loomworks: no workspace", vim.log.levels.WARN)
            return
        end
        local ok, err = ws:revert_to_baseline()
        if not ok then
            vim.notify("loomworks: revert failed: " .. (err or "unknown"), vim.log.levels.ERROR)
        else
            vim.notify("loomworks: reverted workspace to published baseline", vim.log.levels.INFO)
        end
    end,
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
        "profile_renamed",
    },
})

-- When a profile's key changes (e.g. user adds/removes a tool), the
-- tree's fold state is still keyed by the OLD profile key. Migrate
-- every fold prefix that embeds the profile key so anything the
-- user had open stays open through the rename.
do
    local events = require("loomworks.events")
    local PREFIXES = { "profile:", "toolchain:" }
    events.on("profile_renamed", function(payload)
        if not payload or not payload.old_key or not payload.new_key then return end
        if payload.old_key == payload.new_key then return end
        local folds = tree._folds or {}
        for _, prefix in ipairs(PREFIXES) do
            local old_fk = prefix .. payload.old_key
            local new_fk = prefix .. payload.new_key
            if folds[old_fk] ~= nil then
                folds[new_fk] = folds[old_fk]
                folds[old_fk] = nil
            end
        end
        -- profile_proj fold keys: `profile_proj:<profile_key>:<project_key>`.
        -- Walk and translate any matching entry. Build the rename
        -- map first, then apply — mutating during iteration is
        -- undefined for `pairs`.
        local old_pp_prefix = "profile_proj:" .. payload.old_key .. ":"
        local renames = {}
        for k, v in pairs(folds) do
            if type(k) == "string" and k:sub(1, #old_pp_prefix) == old_pp_prefix then
                local new_k = "profile_proj:" .. payload.new_key
                    .. ":" .. k:sub(#old_pp_prefix + 1)
                renames[k] = { new_k = new_k, v = v }
            end
        end
        for old_k, info in pairs(renames) do
            folds[info.new_k] = info.v
            folds[old_k] = nil
        end
    end)
end

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

return M

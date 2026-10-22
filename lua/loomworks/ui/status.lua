--- loomworks/ui/status.lua — Workspace status page.
---
--- Thin wiring: creates a Tree widget inside a View, assembles sections
--- with data from the loomworks API. All rendering logic lives in
--- section files; all UI machinery lives in View and Tree.

local Tree = require("loomworks.ui.tree")
local View = require("loomworks.ui.view")
local actions = require("loomworks.ui.actions")

local M = {}

--- The editor's in-process workspace model (the page's one read of it: the
--- header's root, the workspace the actions' calls go to, and the model
--- `ref` resolves a row to for the operations not called through
--- ui/model_calls — builds, cleans, cancels — until step 5o C2d).
--- @return loomworks.Workspace|nil
local function model()
    return require("loomworks").get_workspace()
end

-- ---------------------------------------------------------------------------
-- Render function — assembles sections
-- ---------------------------------------------------------------------------

--- Header line: the running loomworks version the header view carries
--- (`loomworks.view.Header/1` `version`, spec §19.13), "dev" when unknown.
--- @param hdr loomworks.ViewHeader
local function header_text(hdr)
    return "loomworks.nvim " .. (hdr.version or "dev")
end

local function render_fn(tree)
    local lw = require("loomworks")
    local ws = model()
    -- The header reads `loomworks.view.Header/1` (spec §19.13 "Two sources,
    -- one shape"): the daemon's while the editor is subscribed to it,
    -- otherwise built in-process.
    local hdr = lw.view_header() or { state = "unloaded" }
    if not ws then
        if hdr.state == "error" or hdr.state == "refused" then
            tree._level = 1
            tree:leaf(header_text(hdr), "Title")
            tree:blank()
            tree:leaf("Failed to load workspace", "DiagnosticError")
            tree:leaf("Root: " .. tostring(hdr.root or ""), "Comment")
            tree:blank()
            tree:leaf(tostring(hdr.error or ""), "DiagnosticWarn")
            if hdr.trust then
                -- A refused .nvim file (spec §17.4): its actions.
                tree:blank()
                if hdr.trust == "user" then
                    tree:leaf("[T] review & trust  [U] discard working copy", "Comment")
                else
                    tree:leaf("[<C-n>] reset build cache", "Comment")
                end
            end
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

    tree:leaf(header_text(hdr), "Title")
    tree:blank()
    if hdr.state == "loaded" then
        tree:leaf("Workspace: " .. tostring(hdr.name or ""), "Type")
    elseif hdr.state == "unloaded" then
        -- The workspace daemon has not loaded the workspace yet (it loads on
        -- the first request that needs it).
        tree:leaf("Workspace: not loaded in the workspace daemon", "Comment")
    else
        tree:leaf("Workspace: the workspace daemon could not load it: " .. tostring(hdr.error or hdr.state),
            "DiagnosticWarn")
    end
    tree:leaf("Root:      " .. tostring(hdr.root or ws.root), "Comment")

    -- The body renders from `loomworks.view.Workspace/1` (spec §19.13 "The
    -- workspace view"): in `daemon` mode only the daemon's (nil while it is
    -- not held), otherwise built from the in-process model. `ref` gives the
    -- sections' actions the model object of a row; progress is overlaid
    -- (API.md §14.4 "Progress is not in the view").
    local body = require("loomworks.status_source").read(ws)
    local view = body.view

    -- Banner when loomworks.json is missing on disk: the workspace still
    -- functions from user.json, and :w will publish it. Only of a loaded
    -- workspace: an unloaded daemon's view says `published = false`.
    if view and body.loaded and not view.published then
        tree:leaf("⚠ loomworks.json not on disk — :w to publish",
            "DiagnosticWarn")
    end
    tree:leaf("[?] help  [L] load  [<C-n>] reset", "Comment")
    -- The header's last line (spec/ui.md §1.1, core §19.1, §19.16): the
    -- runtime mode, its source and the observer's state or one current note.
    local runtime_line, runtime_warn = lw.daemon_runtime_line()
    if runtime_line then
        tree:leaf("Runtime:   " .. runtime_line, runtime_warn and "DiagnosticWarn" or "Comment")
    end
    tree:blank()

    local active_set = lw.get_active_configuration_set()

    local ctx = {
        lw = lw,
        view = view,
        -- The body's mode: a routed action is offered on a row with an id in
        -- `daemon` mode (helpers.actionable).
        mode = body.mode,
        ref = body.ref,
        profile_progress = body.profile_progress,
        unit_progress = body.unit_progress,
        -- For the sections' actions only: the workspace their calls go to
        -- (every status-page model write is a ui/model_calls call, in both
        -- modes), and the in-process model the builds, cleans and cancels
        -- act on (in `daemon` mode until step 5o C2d).
        ws = ws,
        all_profiles = lw.get_profiles(),
        active_profile = lw.get_active_profile(),
        active_set = active_set,
        config_sets = lw.get_config_sets(),
        tool_entries = lw.get_tool_entries(),
    }

    -- A body section while the daemon's view is not held (`daemon` mode):
    -- one line in the warning highlight, as the Debug Adapters section's.
    local function unavailable(title)
        tree:leaf(title, "Title")
        tree:blank()
        tree:leaf("unavailable — " .. tostring(body.why), "DiagnosticWarn")
        tree:blank()
    end

    if view then
        require("loomworks.ui.sections.diagnostics")(tree, ctx)

        -- Suggestions (spec/ui.md §1.1): a single compact advisory line pointing at
        -- `lw health`, shown only when the framework has findings. Not a diagnostic
        -- — it never gates anything; the page keeps only the count (of the
        -- actionable items, headless §16.31).
        local n = view.suggestions
        if n > 0 then
            tree:leaf(n .. (n == 1 and " suggestion" or " suggestions")
                .. " — run `lw health`", "LoomworksStale")
            tree:blank()
        end

        require("loomworks.ui.sections.profiles")(tree, ctx)
        require("loomworks.ui.sections.orphaned")(tree, ctx)
        require("loomworks.ui.sections.config_sets")(tree, ctx)
        require("loomworks.ui.sections.projects")(tree, ctx)
    else
        for _, title in ipairs({ "Diagnostics", "Suggestions", "Profiles", "Orphaned Build Dirs",
            "Configuration Sets", "Projects" }) do
            unavailable(title)
        end
    end

    require("loomworks.ui.sections.lsp")(tree, ctx)
    require("loomworks.ui.sections.debug")(tree, ctx)
    if view then
        require("loomworks.ui.sections.sdks")(tree, ctx)
    else
        tree:blank()
        unavailable("SDKs")
    end

    -- Tasks section lives at the bottom: it's the runtime-state
    -- diagnostic surface, only interesting when something is wrong.
    -- Renders nothing on the steady-state idle case so the bottom of
    -- the page stays quiet unless there's something to look at.
    require("loomworks.ui.sections.tasks")(tree, ctx)
end

-- ---------------------------------------------------------------------------
-- View instance
-- ---------------------------------------------------------------------------

--- Revert (`:e!`; `:e` on a buffer not marked modified — ui/view.lua
--- attach_revert): `Workspace/1.revert_to_baseline`, in `daemon` mode a call
--- to the workspace daemon (step 5o C2a), whose view `update` re-renders
--- the page. In `daemon` mode only `:e!` reverts: the buffer's flag can lag
--- the daemon's working copy (status_source.modified), so a plain `:e` Vim
--- let through only re-renders — never a revert the user did not force.
--- Test seam.
--- @param force boolean `:e!`
function M._on_revert(force)
    local ws = model()
    if not ws then
        vim.notify("loomworks: no workspace", vim.log.levels.WARN)
        return
    end
    if not force and require("loomworks.daemon.editor_ops").daemon_of(ws) then return end
    local calls = require("loomworks.ui.model_calls")
    calls.call(ws, "Workspace/1.revert_to_baseline", {}, function(r)
        local ok, err = calls.result(r)
        if not ok then
            vim.notify("loomworks: " .. (err or "revert failed: unknown"), vim.log.levels.ERROR)
        else
            vim.notify("loomworks: reverted workspace to published baseline", vim.log.levels.INFO)
        end
    end)
end

local tree = Tree.new(render_fn)

--- Test seam: the page's render function.
M._render_fn = render_fn

local view = View.new({
    widget = tree,
    cursor_storage = {
        get = function()
            local ws = model()
            return ws and ws._status_cursor_row
        end,
        set = function(row)
            local ws = model()
            if ws then ws._status_cursor_row = row end
        end,
    },
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
        ["e"]     = "describe",
        ["P"]     = "publish",
        ["N"]     = "create_workspace",
        ["L"]     = "load",
        ["<C-n>"] = "nuke",
        ["U"]     = "delete_user_prefs",
        ["T"]     = "trust",
        ["?"]     = "help",
        ["K"]     = "hover",
    },
    -- Unpublished changes (loomworks.status_source.modified): in `daemon`
    -- mode the daemon's view's `modified` (publish and revert run there, step
    -- 5o C2a), else the editor's model's. Guards `:e` (E37).
    is_modified = function()
        return require("loomworks.status_source").modified(model())
    end,
    -- Publish and revert (`:w`, `:e!`): `Workspace/1.publish` /
    -- `revert_to_baseline`, in `daemon` mode calls to the workspace daemon
    -- (step 5o C2a), whose view `update` re-renders the page.
    on_write = function()
        local ws = model()
        if not ws then
            vim.notify("loomworks: no workspace", vim.log.levels.WARN)
            return
        end
        local calls = require("loomworks.ui.model_calls")
        calls.call(ws, "Workspace/1.publish", {}, function(r)
            local ok, err = calls.result(r)
            if not ok then
                vim.notify("loomworks: " .. (err or "publish failed: unknown"), vim.log.levels.ERROR)
            end
        end)
    end,
    on_revert = function(force) return M._on_revert(force) end,
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
        "daemon_runtime_changed",
        "daemon_view_changed",
        "daemon_debug_adapters",
        "daemon_lsp_config",
        "daemon_task_started",
        "daemon_task_progress",
        "daemon_task_step",
        "daemon_task_stopped",
        "tests_invalidated",
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

--- Test seam: the render function (assembles the page into a Tree).
M._render_fn = render_fn

function M.is_open()
    return view:is_open()
end

return M

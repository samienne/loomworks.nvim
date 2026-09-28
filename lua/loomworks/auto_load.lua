--- loomworks/auto_load.lua — Auto-load decision logic and workspace trigger.
---
--- Pure decision function (decide) + side-effectful trigger (check_cwd).
--- The plugin entry point sets up autocmds that call check_cwd.

local M = {}

--- Decide what action to take for auto-loading.
--- Pure function: no side effects, fully testable.
---
--- @param opts { mode: string|false, config_exists: boolean, user_exists?: boolean, cache_exists: boolean, loaded_root: string|nil, cwd_root: string|nil }
--- @return "load"|"prompt"|"prompt_switch"|"notify"|"skip"
function M.decide(opts)
    if opts.mode == false then return "skip" end
    local has_workspace = opts.config_exists or opts.user_exists
    if not has_workspace then return "skip" end
    if opts.loaded_root then
        if opts.loaded_root == opts.cwd_root then return "skip" end
        return "prompt_switch"
    end

    if opts.mode == "auto" then
        return "load"
    elseif opts.mode == "cached_only" then
        return opts.cache_exists and "load" or "notify"
    elseif opts.mode == "prompt" then
        return opts.cache_exists and "load" or "prompt"
    end

    return "skip"
end

--- Check cwd and perform auto-load if appropriate.
--- Called by autocmds and on plugin load. The root is resolved with the same
--- upward search `lw` uses (root_finder, spec §1.1/§13.2): it walks up from
--- cwd, through submodules to their superproject's workspace, but never past
--- a repository root or a linked worktree's root.
function M.check_cwd()
    local lw = require("loomworks")
    local mode = lw._auto_load_mode()

    local found = require("loomworks.root_finder").find(vim.fn.getcwd())
    -- No workspace on the way up: nothing to load (decide → "skip").
    local cwd_root = found and vim.fs.normalize(found) or nil
    local config_exists, user_exists, cache_exists = false, false, false
    if cwd_root then
        config_exists = vim.uv.fs_stat(cwd_root .. "/loomworks.json") ~= nil
        user_exists = vim.uv.fs_stat(cwd_root .. "/.nvim/loomworks.user.json") ~= nil
        cache_exists = vim.uv.fs_stat(cwd_root .. "/.nvim/loomworks.cache.json") ~= nil
    end

    local ws = lw.get_workspace()
    local loaded_root = ws and ws.root or nil

    local action = M.decide({
        mode = mode,
        config_exists = config_exists,
        user_exists = user_exists,
        cache_exists = cache_exists,
        loaded_root = loaded_root,
        cwd_root = cwd_root,
    })

    if action == "load" then
        lw.setup({ root = cwd_root })
    elseif action == "notify" then
        vim.notify(
            "loomworks: workspace found at " .. cwd_root .. " (run :LoomworksInit to load)",
            vim.log.levels.INFO
        )
    elseif action == "prompt" then
        vim.ui.input(
            { prompt = "Workspace found at " .. cwd_root .. ", load? (y/n) " },
            function(input)
                if input and input:lower() == "y" then
                    lw.setup({ root = cwd_root })
                end
            end
        )
    elseif action == "prompt_switch" then
        local name = vim.fn.fnamemodify(cwd_root, ":t")
        vim.ui.input(
            { prompt = "Switch workspace to " .. name .. "? (y/n) " },
            function(input)
                if input and input:lower() == "y" then
                    lw.setup({ root = cwd_root })
                end
            end
        )
    end
end

return M

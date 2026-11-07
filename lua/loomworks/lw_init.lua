--- loomworks/lw_init.lua — the editor's way to create a workspace (spec
--- plugin.md §13.5): run `lw init` from the host binary the editor selected
--- (loomworks.provision.select; a search-path or explicit lw with no cached
--- probe verdict is probed first, and the plugin-managed lw is downloaded
--- first when the selection wants it), in a terminal window. A thin shim:
--- `lw init` writes the workspace, the editor writes nothing and has no
--- fallback. The process gets the environment of every process started from
--- that binary (§19.16 "Plugin pin": the managed lw's has no LOOMWORKS_LUA or
--- LOOMWORKS_INSTALL_DIR). One run per root at a time.

local M = {}

--- The run in flight per root (from the selection to lw's exit): its
--- terminal window once it has one.
--- @type table<string, { win?: integer }>
M._running = {}

--- The command line that runs `bin` with `args` (tests replace it).
--- @param bin string
--- @param args string[]
--- @return string[]
function M.argv(bin, args)
    return vim.list_extend({ bin }, args)
end

--- Open a terminal window running `lw init` in `root` from `sel`'s binary.
--- The window closes when lw exits 0; otherwise it stays with lw's output.
--- @param run { win?: integer } the root's in-flight record
--- @param root string
--- @param bin string
--- @param sel loomworks.provision.Selection
--- @param args string[]
--- @param cb fun(ok: boolean, err?: string)
--- @return boolean ok, string|nil err
local function spawn(run, root, bin, sel, args, cb)
    local binsel = require("loomworks.provision.select")
    local argv = M.argv(bin, args)
    local buf = vim.api.nvim_create_buf(true, false)
    -- A top-level split at the bottom (win = -1).
    local wok, win = pcall(vim.api.nvim_open_win, buf, true, { split = "below", win = -1 })
    if not wok then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return false, "could not open a terminal window for lw init (" .. tostring(win) .. ")"
    end
    local jopts = {
        cwd = root,
        env = sel.env,
        on_exit = function(_, code)
            vim.schedule(function()
                if code ~= 0 then return cb(false, "lw init exited with " .. tostring(code)) end
                if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
                if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
                cb(true)
            end)
        end,
    }
    -- The spawn copies the environment at once: removing the managed lw's
    -- names around it is exact (loomworks.provision.child_env). The buffer
    -- keeps the terminal's own name (unique per job).
    local ok, job = require("loomworks.provision.child_env").without(binsel.child_unset(sel), function()
        if vim.fn.has("nvim-0.11") == 1 then
            jopts.term = true
            return vim.fn.jobstart(argv, jopts)
        end
        return vim.fn.termopen(argv, jopts)
    end)
    if not ok or type(job) ~= "number" or job <= 0 then
        if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return false, "could not run " .. bin .. " init (" .. tostring(job) .. ")"
    end
    run.win = win
    return true
end

--- Run `lw init [--name <name>]` in `root`. Returns false + why when no lw
--- can be selected (the selection's reason) or a run in `root` is already
--- in flight (its terminal is focused instead when it is shown: true);
--- otherwise true, and `cb(ok, err)` once lw has exited (ok: exit 0) or its
--- probe, download or start failed.
--- opts: binary (the setup option), name, getenv, data (the selection's).
--- @param root string
--- @param opts? { binary?: loomworks.provision.BinarySetting, name?: string, getenv?: function, data?: string }
--- @param cb? fun(ok: boolean, err?: string)
--- @return boolean ok, string|nil err
function M.run(root, opts, cb)
    opts = opts or {}
    cb = cb or function() end
    local key = vim.fs.normalize(root)
    if package.config:sub(1, 1) == "\\" then key = key:lower() end
    local cur = M._running[key]
    if cur then
        if cur.win and vim.api.nvim_win_is_valid(cur.win) then
            vim.api.nvim_set_current_win(cur.win)
            return true
        end
        return false, "lw init is already running in " .. root
    end
    local run = {}
    M._running[key] = run
    local function done(ok, err)
        if M._running[key] == run then M._running[key] = nil end
        cb(ok, err)
    end
    local args = { "init" }
    if opts.name and opts.name ~= "" then vim.list_extend(args, { "--name", opts.name }) end
    local binsel = require("loomworks.provision.select")
    -- Select, then spawn; ok=false + why when nothing was started.
    local function start(probed)
        local bin, source, sel = binsel.resolve(root, { setting = opts.binary, getenv = opts.getenv, data = opts.data })
        if type(sel) ~= "table" then sel = { path = bin, source = source, candidates = {} } end
        -- A search-path or explicit lw with no cached verdict is probed first,
        -- then selected again (as the observer does): an incompatible lw on
        -- PATH then gives way to the managed one. A verdict that could not be
        -- cached is used as unknown, not probed again.
        if bin and sel.probe and not probed then
            require("loomworks.provision.probe").run(sel.probe, nil, function()
                local ok, err = start(true)
                if not ok then done(false, err) end
            end)
            return true
        end
        if bin then return spawn(run, root, bin, sel, args, done) end
        if not sel.download then return false, binsel.none_note(sel, { degraded = false }) end
        -- The wanted plugin-managed lw, downloaded first (as the observer does).
        local want = sel.download
        local setting = opts.binary or {}
        require("loomworks.provision.fetch").ensure(want, { release_url = setting.release_url, getenv = opts.getenv,
            data = opts.data }, function(path, err)
            if not path then
                return done(false, "could not install the plugin-managed lw v" .. tostring(want.version) .. " ("
                    .. tostring(want.asset) .. "): " .. tostring(err))
            end
            local msel = vim.tbl_extend("force", sel, { path = path, source = "managed", download = false })
            local ok, serr = spawn(run, root, path, msel, args, done)
            if not ok then done(false, serr) end
        end)
        return true
    end
    local ok, err = start(false)
    if not ok and M._running[key] == run then M._running[key] = nil end
    return ok, err
end

return M

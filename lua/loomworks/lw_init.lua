--- loomworks/lw_init.lua — the editor's way to create a workspace (spec
--- plugin.md §13.5): run `lw init` from the host binary the editor selected
--- (loomworks.provision.select; the plugin-managed lw is downloaded first when
--- the selection wants it), in a terminal window. A thin shim: `lw init`
--- writes the workspace, the editor writes nothing and has no fallback. The
--- process gets the environment of every process started from that binary
--- (§19.16 "Plugin pin": the managed lw's has no LOOMWORKS_LUA or
--- LOOMWORKS_INSTALL_DIR).

local M = {}

--- True when `dir` holds a workspace (spec §13.2 "Detection order": either
--- file is sufficient).
--- @param dir string
--- @return boolean
function M.has_workspace(dir)
    local uv = vim.uv or vim.loop
    return uv.fs_stat(dir .. "/loomworks.json") ~= nil
        or uv.fs_stat(dir .. "/.nvim/loomworks.user.json") ~= nil
end

--- The command line that runs `bin` with `args` (tests replace it).
--- @param bin string
--- @param args string[]
--- @return string[]
function M.argv(bin, args)
    return vim.list_extend({ bin }, args)
end

--- The selection's reason for choosing no binary, without the Runtime line's
--- "running degraded" (nothing runs degraded here).
--- @param sel? loomworks.provision.Selection
--- @return string
local function why_none(sel)
    local note = require("loomworks.provision.select").none_note(sel)
    return (note:gsub(" — running degraded$", ""))
end

--- Open a terminal window running `lw init` in `root` from `sel`'s binary.
--- @param root string
--- @param bin string
--- @param sel loomworks.provision.Selection
--- @param args string[]
--- @param cb fun(ok: boolean, err?: string)
--- @return boolean ok, string|nil err
local function spawn(root, bin, sel, args, cb)
    local binsel = require("loomworks.provision.select")
    local argv = M.argv(bin, args)
    -- A top-level split at the bottom (win = -1): also from the status
    -- page's floating window.
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_open_win(buf, true, { split = "below", win = -1 })
    local jopts = {
        cwd = root,
        env = sel.env,
        on_exit = function(_, code)
            vim.schedule(function()
                if code == 0 then return cb(true) end
                cb(false, "lw init exited with " .. tostring(code))
            end)
        end,
    }
    -- The spawn copies the environment at once: removing the managed lw's
    -- names around it is exact (loomworks.provision.child_env).
    local ok, job = require("loomworks.provision.child_env").without(binsel.child_unset(sel), function()
        if vim.fn.has("nvim-0.11") == 1 then
            jopts.term = true
            return vim.fn.jobstart(argv, jopts)
        end
        return vim.fn.termopen(argv, jopts)
    end)
    if not ok or type(job) ~= "number" or job <= 0 then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        return false, "could not run " .. bin .. " init (" .. tostring(job) .. ")"
    end
    pcall(vim.api.nvim_buf_set_name, buf, "lw init: " .. root)
    return true
end

--- Run `lw init [--name <name>]` in `root`. Returns false + why when no lw
--- can be selected (the selection's reason); otherwise true, and `cb(ok,
--- err)` once lw has exited (ok: exit 0) or its download failed.
--- opts: binary (the setup option), name, getenv, data (the selection's).
--- @param root string
--- @param opts? { binary?: loomworks.provision.BinarySetting, name?: string, getenv?: function, data?: string }
--- @param cb? fun(ok: boolean, err?: string)
--- @return boolean ok, string|nil err
function M.run(root, opts, cb)
    opts = opts or {}
    cb = cb or function() end
    local args = { "init" }
    if opts.name and opts.name ~= "" then vim.list_extend(args, { "--name", opts.name }) end
    local binsel = require("loomworks.provision.select")
    local bin, source, sel = binsel.resolve(root, { setting = opts.binary, getenv = opts.getenv, data = opts.data })
    if type(sel) ~= "table" then sel = { path = bin, source = source, candidates = {} } end
    if bin then return spawn(root, bin, sel, args, cb) end
    if not sel.download then return false, why_none(sel) end
    -- The wanted plugin-managed lw, downloaded first (as the observer does).
    local want = sel.download
    local setting = opts.binary or {}
    require("loomworks.provision.fetch").ensure(want, { release_url = setting.release_url, getenv = opts.getenv,
        data = opts.data }, function(path, err)
        if not path then
            return cb(false, "could not install the plugin-managed lw v" .. tostring(want.version) .. " ("
                .. tostring(want.asset) .. "): " .. tostring(err))
        end
        local msel = vim.tbl_extend("force", sel, { path = path, source = "managed", download = false })
        local ok, serr = spawn(root, path, msel, args, cb)
        if not ok then cb(false, serr) end
    end)
    return true
end

return M

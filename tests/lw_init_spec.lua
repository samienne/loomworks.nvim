-- The editor initialises a workspace by running `lw init` (spec/plugin.md
-- §13.5): `:LoomworksInit` where no workspace is and the status page's `N`
-- run `lw init` from the host binary the editor selected (the plugin-managed
-- one included: a plugin-only user has no lw on the search path), in a
-- terminal window, and load the workspace when it exits 0. The managed lw's
-- process gets no LOOMWORKS_LUA or LOOMWORKS_INSTALL_DIR (§19.16 "Plugin
-- pin"). With no host binary nothing runs and the error is the selection's.
-- An unprobed lw is probed first; one run per root at a time; the terminal
-- closes on success; `N` where a workspace is runs nothing.

local uv = vim.uv or vim.loop
local binsel = require("loomworks.provision.select")

local REPO = (uv.cwd():gsub("\\", "/"))
local SCRIPT = REPO .. "/tests/fixtures/fake_lw_init.lua"
local NAMES = { "LOOMWORKS_LUA", "LOOMWORKS_INSTALL_DIR", "LOOMWORKS_LW" }
local is_win = package.config:sub(1, 1) == "\\"

local function norm(p)
    p = vim.fs.normalize(uv.fs_realpath(p) or p):gsub("/$", "")
    return is_win and p:lower() or p
end

local function report(file)
    local f = io.open(file, "r")
    if not f then return nil end
    local out = {}
    for line in f:lines() do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then out[k] = v end
    end
    f:close()
    return out
end

describe("initialising a workspace runs lw init (§13.5)", function()
    local lw = require("loomworks")
    local lw_init = require("loomworks.lw_init")
    local probe = require("loomworks.provision.probe")
    local saved, stubs, dirs, loaded, exit_code, rep, expect_bin, saved_binary

    local function stub(mod, key, fn)
        stubs[#stubs + 1] = { mod, key, mod[key] }
        mod[key] = fn
    end

    local function tmpdir()
        local d = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(d, "p")
        dirs[#dirs + 1] = d
        return d
    end

    --- Select `path` from `source`; the fake lw stands in for the binary.
    local function select_lw(path, source)
        stub(binsel, "resolve", function()
            return path, source, { path = path, source = source, label = source, candidates = {} }
        end)
    end

    local function terminals()
        local n = 0
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[b].buftype == "terminal" then n = n + 1 end
        end
        return n
    end

    before_each(function()
        saved, stubs, dirs, loaded = {}, {}, {}, {}
        exit_code = 0
        expect_bin = "/m/lw"
        saved_binary = lw._binary_config
        lw_init._running = {}
        rep = vim.fn.tempname()
        for _, n in ipairs(NAMES) do saved[n] = uv.os_getenv(n) end
        uv.os_setenv("LOOMWORKS_LUA", "/dev/src")
        uv.os_setenv("LOOMWORKS_INSTALL_DIR", "/dev/install")
        uv.os_unsetenv("LOOMWORKS_LW")
        -- The fake lw: the whole command line, the lw arguments last.
        stub(lw_init, "argv", function(bin, args)
            assert.equals(expect_bin, bin)
            return vim.list_extend({ vim.v.progpath, "--headless", "-u", "NONE", "-l", SCRIPT, rep,
                tostring(exit_code) }, args)
        end)
        -- Loading is the editor's ordinary load (§13.4): recorded here.
        stub(lw, "setup", function(o) loaded[#loaded + 1] = o and o.root end)
    end)
    after_each(function()
        for i = #stubs, 1, -1 do
            local s = stubs[i]
            s[1][s[2]] = s[3]
        end
        for _, n in ipairs(NAMES) do
            if saved[n] then uv.os_setenv(n, saved[n]) else uv.os_unsetenv(n) end
        end
        lw._binary_config = saved_binary
        lw_init._running = {}
        probe.reset()
        -- Close the terminal windows the runs opened.
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[b].buftype == "terminal" then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
        end
        for _, d in ipairs(dirs) do vim.fn.delete(d, "rf") end
        os.remove(rep)
    end)

    it("create_workspace runs `lw init` from the managed lw in a terminal and loads the workspace on exit 0",
        function()
            select_lw("/m/lw", "managed")
            local dir = tmpdir()
            local ok, err = lw.create_workspace(dir)
            assert.is_true(ok, err)
            assert.equals(1, terminals())
            assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
            local r = report(rep)
            assert.equals("init", r.args)
            assert.equals(norm(dir), norm(r.cwd))
            -- The managed lw gets no install-folder or source override …
            assert.equals("-", r.LOOMWORKS_LUA)
            assert.equals("-", r.LOOMWORKS_INSTALL_DIR)
            -- … and the editor's own environment is untouched.
            assert.equals("/dev/src", uv.os_getenv("LOOMWORKS_LUA"))
            assert.equals("/dev/install", uv.os_getenv("LOOMWORKS_INSTALL_DIR"))
            assert.same({ norm(dir) }, vim.tbl_map(norm, loaded))
            -- On success the terminal window closes and its buffer is wiped.
            assert.equals(0, terminals())
        end)

    it("an lw from the search path keeps the inherited environment; a name is passed as --name", function()
        select_lw("/m/lw", "PATH")
        local dir = tmpdir()
        assert.is_true((lw.create_workspace(dir, "myws")))
        assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
        local r = report(rep)
        assert.equals("init --name myws", r.args)
        assert.equals("/dev/src", r.LOOMWORKS_LUA)
        assert.equals("/dev/install", r.LOOMWORKS_INSTALL_DIR)
    end)

    it("a failing lw init loads nothing and says how it exited", function()
        select_lw("/m/lw", "managed")
        exit_code = 3
        local done
        local ok = lw_init.run(tmpdir(), {}, function(o, e) done = { o, e } end)
        assert.is_true(ok)
        assert.is_true(vim.wait(20000, function() return done ~= nil end, 20))
        assert.is_false(done[1])
        assert.truthy(tostring(done[2]):find("exited with 3", 1, true))
        assert.same({}, loaded)
        -- The terminal stays, with lw's output.
        assert.equals(1, terminals())
    end)

    it("an unprobed lw on PATH is probed first; an incompatible one gives way to the managed lw", function()
        -- The real selection over a cold probe cache: only the sources are faked.
        probe.reset()
        local path_lw = tmpdir() .. "/lw" .. (is_win and ".exe" or "")
        vim.fn.writefile({ "" }, path_lw)
        stub(binsel, "on_path", function() return path_lw end)
        stub(require("loomworks.provision.managed"), "find", function() return "/m/lw" end)
        local probed = {}
        stub(probe, "run", function(p, _, cb)
            probed[#probed + 1] = p
            probe._cache[probe.key(p)] = { verdict = "incompatible", problems = { "too old" }, degraded = {} }
            vim.schedule(function() cb(probe._cache[probe.key(p)]) end)
        end)
        local dir = tmpdir()
        assert.is_true((lw.create_workspace(dir)))
        -- Nothing runs before the verdict.
        assert.equals(0, terminals())
        assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
        assert.same({ path_lw }, probed)
        -- The managed lw ran (the fake checks the binary), with its environment.
        assert.equals("-", report(rep).LOOMWORKS_LUA)
    end)

    it("the setup option `binary` reaches the real selection (binary.path)", function()
        probe.reset()
        local bin = tmpdir() .. "/mylw" .. (is_win and ".exe" or "")
        vim.fn.writefile({ "" }, bin)
        expect_bin = bin
        lw._binary_config = { path = bin }
        stub(probe, "run", function(p, _, cb)
            probe._cache[probe.key(p)] = { verdict = "compatible", problems = {}, degraded = {} }
            vim.schedule(function() cb(probe._cache[probe.key(p)]) end)
        end)
        local dir = tmpdir()
        assert.is_true((lw.create_workspace(dir)))
        assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
        -- An explicit lw keeps the inherited environment.
        assert.equals("/dev/src", report(rep).LOOMWORKS_LUA)
    end)

    it("a second run in the same root while one is in flight spawns nothing", function()
        select_lw("/m/lw", "managed")
        local dir = tmpdir()
        assert.is_true((lw_init.run(dir, {}, function(ok) if ok then loaded[#loaded + 1] = dir end end)))
        local term_win = vim.api.nvim_get_current_win()
        vim.cmd("wincmd p")
        assert.are_not.equal(term_win, vim.api.nvim_get_current_win())
        -- The running terminal is focused instead.
        assert.is_true((lw_init.run(dir, {})))
        assert.equals(term_win, vim.api.nvim_get_current_win())
        assert.equals(1, terminals())
        assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
        assert.equals(1, #loaded)
        -- While it is still being probed (no terminal yet): refused.
        local held
        stub(binsel, "resolve", function()
            return "/m/lw", "PATH", { path = "/m/lw", source = "PATH", probe = "/m/lw", candidates = {} }
        end)
        stub(probe, "run", function(_, _, cb) held = cb end)
        local dir2 = tmpdir()
        assert.is_true((lw_init.run(dir2, {})))
        local ok, err = lw_init.run(dir2, {})
        assert.is_false(ok)
        assert.truthy(err:find("already running", 1, true))
        assert.equals(0, terminals())
        assert.is_function(held)
    end)

    it("a spawn that throws restores the environment and deletes the buffer", function()
        select_lw("/m/lw", "managed")
        local bufs = #vim.api.nvim_list_bufs()
        local wins = #vim.api.nvim_list_wins()
        stub(vim.fn, "jobstart", function() error("boom") end)
        stub(vim.fn, "termopen", function() error("boom") end)
        local ok, err = lw_init.run(tmpdir(), {})
        assert.is_false(ok)
        assert.truthy(err:find("boom", 1, true))
        -- The managed lw's names were removed around the spawn: back now.
        assert.equals("/dev/src", uv.os_getenv("LOOMWORKS_LUA"))
        assert.equals("/dev/install", uv.os_getenv("LOOMWORKS_INSTALL_DIR"))
        assert.equals(bufs, #vim.api.nvim_list_bufs())
        assert.equals(wins, #vim.api.nvim_list_wins())
        -- Nothing is left in flight.
        assert.is_nil(next(lw_init._running))
    end)

    it("with no host binary nothing runs and the error is the selection's reason, not `run lw init`", function()
        stub(binsel, "resolve", function()
            return nil, nil, { candidates = { { source = "managed", label = "plugin-managed lw",
                verdict = "absent", reason = "no release for this platform" } } }
        end)
        local dir = tmpdir()
        local ok, err = lw.create_workspace(dir)
        assert.is_false(ok)
        assert.truthy(err:find("no release for this platform", 1, true))
        assert.is_nil(err:find("in a terminal", 1, true))
        assert.is_nil(err:find("running degraded", 1, true))
        assert.equals(0, terminals())
        assert.is_nil(report(rep))
    end)

    it("a wanted managed lw is downloaded first, then runs; a failed download is the error", function()
        local want = { version = "9.9.9", asset = "lw-x", sha256 = string.rep("a", 64) }
        stub(binsel, "resolve", function()
            return nil, nil, { download = want, source = "managed", candidates = {} }
        end)
        local fetch = require("loomworks.provision.fetch")
        stub(fetch, "ensure", function(w, _, cb)
            assert.equals(want, w)
            vim.schedule(function() cb("/m/lw") end)
        end)
        local dir = tmpdir()
        assert.is_true((lw.create_workspace(dir)))
        assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
        assert.equals("-", report(rep).LOOMWORKS_LUA) -- the downloaded lw is the managed one
        -- A failed download: nothing runs, the download's error is reported.
        os.remove(rep)
        fetch.ensure = function(_, _, cb) vim.schedule(function() cb(nil, "HTTP 404") end) end
        local done
        assert.is_true(lw_init.run(tmpdir(), {}, function(o, e) done = { o, e } end))
        assert.is_true(vim.wait(5000, function() return done ~= nil end, 10))
        assert.is_false(done[1])
        assert.truthy(done[2]:find("HTTP 404", 1, true))
        assert.is_nil(report(rep))
    end)

    describe(":LoomworksInit (init_command)", function()
        it("loads a directory that holds a workspace, without running lw", function()
            select_lw("/m/lw", "managed")
            local dir = tmpdir()
            vim.fn.writefile({ "{}" }, dir .. "/loomworks.json")
            lw.init_command(dir)
            assert.same({ norm(dir) }, vim.tbl_map(norm, loaded))
            assert.equals(0, terminals())
            assert.is_nil(report(rep))
        end)

        it("runs lw init in a directory that holds none, then loads it", function()
            select_lw("/m/lw", "managed")
            local dir = tmpdir()
            lw.init_command(dir)
            assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
            assert.equals("init", report(rep).args)
            assert.same({ norm(dir) }, vim.tbl_map(norm, loaded))
        end)
    end)

    it("the status page's N runs lw init where no workspace is (no refusal)", function()
        select_lw("/m/lw", "managed")
        local notes = {}
        stub(vim, "notify", function(m) notes[#notes + 1] = m end)
        local dir = tmpdir()
        stub(lw, "workspace_root", function() return dir end)
        local Tree = require("loomworks.ui.tree")
        Tree._create_workspace({})
        assert.is_true(vim.wait(20000, function() return #loaded > 0 end, 20))
        assert.equals(norm(dir), norm(report(rep).cwd))
        for _, m in ipairs(notes) do assert.is_nil(m:find("in a terminal", 1, true)) end
    end)

    it("has_workspace: the directory itself, either file; not a directory below one", function()
        local dir = tmpdir()
        assert.is_false(lw_init.has_workspace(dir))
        vim.fn.mkdir(dir .. "/.nvim", "p")
        vim.fn.writefile({ "{}" }, dir .. "/.nvim/loomworks.user.json")
        assert.is_true(lw_init.has_workspace(dir))
        assert.is_true(lw_init.has_workspace(dir .. "/"))
        vim.fn.mkdir(dir .. "/sub", "p")
        assert.is_false(lw_init.has_workspace(dir .. "/sub"))
    end)

    describe("the status page's N where a workspace is", function()
        local function setup_dir(loaded_here)
            select_lw("/m/lw", "managed")
            local dir = tmpdir()
            vim.fn.writefile({ "{}" }, dir .. "/loomworks.json")
            stub(lw, "workspace_root", function() return dir end)
            stub(lw, "loaded_root", function() return loaded_here and dir or nil end)
            return dir
        end

        it("loads it when it is not loaded, running nothing", function()
            local dir = setup_dir(false)
            require("loomworks.ui.tree")._create_workspace({})
            assert.same({ norm(dir) }, vim.tbl_map(norm, loaded))
            assert.equals(0, terminals())
            assert.is_nil(report(rep))
        end)

        it("says it exists when it is the one loaded, running nothing", function()
            local notes = {}
            stub(vim, "notify", function(m) notes[#notes + 1] = m end)
            local dir = setup_dir(true)
            require("loomworks.ui.tree")._create_workspace({})
            assert.same({ "loomworks: a workspace already exists at " .. dir }, notes)
            assert.same({}, loaded)
            assert.equals(0, terminals())
            assert.is_nil(report(rep))
        end)
    end)
end)

-- Every process the editor starts from the managed binary gets no
-- install-folder or source override (spec §19.16 "Plugin pin"): an exported
-- LOOMWORKS_LUA or LOOMWORKS_INSTALL_DIR in the editor's environment is
-- removed from the relay's and the channel query's environment. A binary the
-- user installed or named (binary.path / LOOMWORKS_LW / PATH) keeps the
-- inherited environment.

local uv = vim.uv or vim.loop
local settings = require("loomworks.daemon.client.settings")
local RC = require("loomworks.daemon.client.relay")
local channel = require("loomworks.provision.channel")
local binsel = require("loomworks.provision.select")
local H = require("tests.daemon_helpers")

local SCRIPT = H.REPO .. "/tests/fixtures/fake_relay_proc.lua"
local NAMES = { "LOOMWORKS_LUA", "LOOMWORKS_INSTALL_DIR" }
local is_win = package.config:sub(1, 1) == "\\"

--- The value of `name` in a "K=V" list (case-insensitive on Windows).
local function lookup(list, name)
    for _, kv in ipairs(list) do
        local k, v = kv:match("^([^=]*)=(.*)$")
        if k and (k == name or (is_win and k:upper() == name)) then return v end
    end
end

--- The env-dumping fake relay's report: { LOOMWORKS_LUA = v|"-", ... }.
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

local function dump_argv(file)
    return { vim.v.progpath, "--headless", "-u", "NONE", "-l", SCRIPT, "env", file }
end

describe("the managed lw gets no LOOMWORKS_LUA or LOOMWORKS_INSTALL_DIR", function()
    local saved, files
    before_each(function()
        saved, files = {}, {}
        for _, n in ipairs(NAMES) do saved[n] = uv.os_getenv(n) end
        -- Windows: a different spelling of the same variable.
        uv.os_setenv(is_win and "loomworks_lua" or "LOOMWORKS_LUA", "/dev/src")
        uv.os_setenv("LOOMWORKS_INSTALL_DIR", "/dev/install")
    end)
    after_each(function()
        for _, n in ipairs(NAMES) do
            if saved[n] then uv.os_setenv(n, saved[n]) else uv.os_unsetenv(n) end
        end
        for _, f in ipairs(files) do os.remove(f) end
        H.cleanup()
    end)
    local function tmpfile()
        local f = vim.fn.tempname()
        files[#files + 1] = f
        return f
    end

    it("the selection unsets both for the managed source only", function()
        assert.same(NAMES, binsel.child_unset({ path = "/m/lw", source = "managed" }))
        for _, src in ipairs({ "binary.path", "LOOMWORKS_LW", "PATH" }) do
            assert.is_nil(binsel.child_unset({ path = "/x/lw", source = src }))
        end
        assert.is_nil(binsel.child_unset(nil))
    end)

    it("a relay environment drops the unset names and keeps everything else", function()
        local env = settings.env("/r", nil, binsel.child_unset({ source = "managed" }))
        assert.is_nil(lookup(env, "LOOMWORKS_LUA"))
        assert.is_nil(lookup(env, "LOOMWORKS_INSTALL_DIR"))
        assert.equals("/r", lookup(env, "LW_ROOT"))
        assert.truthy(lookup(env, "PATH"))
        -- A non-managed source keeps the inherited environment.
        env = settings.env("/r", nil, nil)
        assert.equals("/dev/src", lookup(env, "LOOMWORKS_LUA"))
        assert.equals("/dev/install", lookup(env, "LOOMWORKS_INSTALL_DIR"))
    end)

    it("a relay spawned with the managed selection's unset list lacks both; a plain one keeps them", function()
        local function run(unset)
            local file = tmpfile()
            local done
            local r = assert(RC.connect({ argv = dump_argv(file), root = H.workspace(), form = "ordinary",
                client = "editor", role = "observer", unset = unset }, function() done = true end))
            assert.is_true(vim.wait(20000, function() return done end, 20))
            pcall(function() if r.proc then r.proc:kill("sigkill") end end)
            return report(file)
        end
        assert.same({ LOOMWORKS_LUA = "-", LOOMWORKS_INSTALL_DIR = "-" },
            run(binsel.child_unset({ source = "managed" })))
        assert.same({ LOOMWORKS_LUA = "/dev/src", LOOMWORKS_INSTALL_DIR = "/dev/install" }, run(nil))
    end)

    it("the observer passes the managed selection's unset list to the relay, and none for PATH", function()
        local observer = require("loomworks.daemon.observer")
        local function spawned(source)
            local got
            observer.attach(H.workspace(), {
                getenv = function(n) if n == "LOOMWORKS_RUNTIME" then return "daemon" end end,
                resolve = function() return "/x/lw", source, { path = "/x/lw", source = source,
                    label = source, candidates = {} } end,
                relay = function(ro) got = ro; return { close = function() end } end })
            assert.is_true(vim.wait(2000, function() return got ~= nil end, 10))
            observer.detach()
            return got
        end
        assert.same(NAMES, spawned("managed").unset)
        assert.is_nil(spawned("PATH").unset)
    end)

    it("the channel query (always the managed lw) runs without both", function()
        local file = tmpfile()
        local res
        channel.run("/m/lw", "stable", { argv = dump_argv(file) }, function(r) res = r end)
        assert.is_true(vim.wait(20000, function() return res ~= nil end, 20))
        assert.same({ LOOMWORKS_LUA = "-", LOOMWORKS_INSTALL_DIR = "-" }, report(file))
        -- The editor's own environment is untouched afterwards.
        assert.equals("/dev/src", uv.os_getenv("LOOMWORKS_LUA"))
        assert.equals("/dev/install", uv.os_getenv("LOOMWORKS_INSTALL_DIR"))
    end)
end)

-- References by id resolve straight to their object (spec daemon.md §19.14,
-- §19.20 "References"; API.md §1.2; step 5o part 0): an operation's
-- `{ id }` profile reference is the profile the id names, never looked up
-- again by its key. A key round-trip would put the key through the CLI's
-- profile matcher (§16.9), which reads a bare integer as the positional
-- index: a profile keyed `2` named by id would become the second profile in
-- key order. Called over transport 11 against an in-process server with the
-- build service attached and a real `shell` workspace.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

client.TIMEOUT_MS = 30000

local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- `app` (a shell project running the STEP script), the sets and profiles
--- `2` and `x` (both app=Debug). In key order `2` is first and `x` second.
local function workspace()
    local root = vim.fs.normalize(assert(uv.fs_realpath(H.tmp())))
    for _, d in ipairs({ "app", ".nvim" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
    local step = root .. "/step.lua"
    write(step, H.STEP)
    local nv = (vim.v.progpath:gsub("\\", "/"))
    local function cmd(kind) return { nv, "--headless", "-u", "NONE", "-l", step, kind } end
    write(root .. "/loomworks.json", vim.json.encode({
        projects = {
            app = { path = "app", shell = { build_dir = "${workspace_root}/out/app/${variant}",
                configure_cmd = cmd("configure"), build_cmd = cmd("build"), clean_cmd = cmd("clean"),
                configurations = { Debug = vim.empty_dict() } } },
        },
        configuration_sets = { ["2"] = { app = "Debug" }, x = { app = "Debug" } },
    }))
    local signed = trust.sign("user", trust.encode({ _meta = { version = 2 },
        profiles = { ["2"] = { configuration_set = "2" }, x = { configuration_set = "x" } } }))
    write(root .. "/.nvim/loomworks.user.json", signed)
    return root
end

--- A `loomworks.Build/1` call; returns a record with the reply and the
--- task frames.
local function call(srv, method, args)
    local rec = { events = {} }
    local conn = client.session(srv.address, {
        on_message = function(m) if m.kind == "task" then rec.events[#rec.events + 1] = m end end,
    })
    assert.is_not_nil(conn)
    rec.conn = conn
    conn:call("/build", "loomworks.Build", 1, method, args, function(r, e) rec.reply = r; rec.err = e end,
        envscope.capture())
    function rec.wait_reply() return vim.wait(60000, function() return rec.reply ~= nil or rec.err ~= nil end, 10) end
    function rec.wait_done()
        return vim.wait(60000, function()
            for _, m in ipairs(rec.events) do if m.phase == "done" then return true end end
            return false
        end, 10)
    end
    return rec
end

describe("run_prep.match_targets with a resolved project (step 5o part 0)", function()
    it("matches a Project scope by identity, not by its key", function()
        local app, other = { key = "app" }, { key = "app" }
        local all = {
            { project = app, name = "myexe", kind = "target" },
            { project = other, name = "myexe", kind = "target" },
        }
        local rp = require("loomworks.run_prep")
        local m = rp.match_targets(nil, {}, "myexe", app, nil, all)
        assert.equals(1, #m)
        assert.equals(app, m[1].project)
        -- (A key the user typed still matches by key.)
        assert.equals(2, #rp.match_targets(nil, {}, "myexe", "app", nil, all))
    end)
end)

describe("an operation's { id } reference in the daemon (step 5o part 0)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = workspace()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    --- The live profile keyed `key`, loading the model with a first request.
    local function profile_id(key)
        local r = call(srv, "build", { profile = { key = "x" } })
        assert.is_true(r.wait_reply())
        assert.equals("accepted", r.reply and r.reply.outcome, vim.inspect(r.reply or r.err))
        assert.is_true(r.wait_done())
        r.conn:close()
        local svc = srv.service
        for _, p in ipairs(svc.ws._profiles) do
            if p.key == key then return svc.ids:id(p) end
        end
        error("no profile " .. key)
    end

    it("a profile named by id is that profile, also when its key reads as a profile number", function()
        local id = profile_id("2")
        local r = call(srv, "build", { profile = { id = id } })
        assert.is_true(r.wait_reply())
        assert.is_nil(r.err, vim.inspect(r.err))
        assert.equals("accepted", r.reply.outcome, vim.inspect(r.reply))
        assert.equals("2", r.reply.profile_key)
        assert.is_true(r.wait_done())
        r.conn:close()
    end)

    it("a stale id is refused and changes nothing", function()
        profile_id("2")
        local r = call(srv, "build", { profile = { id = "999.999" } })
        assert.is_true(r.wait_reply())
        assert.equals("refused", r.reply and r.reply.outcome, vim.inspect(r.reply or r.err))
        assert.matches("stale reference", r.reply.message)
        r.conn:close()
    end)
end)

--- The workspace daemon watches loomworks.json and the working copy
--- (spec/core/daemon.md §19.13 "Freshness of views", §19.15 "Live
--- workspace"): another process's change is applied when it is seen, with no
--- request; a file that cannot be parsed never unloads or replaces the model
--- (a load warning names it); a file missing while its `.bak` exists may be a
--- save in progress (§19.4): kept while the `.bak` holds the content last
--- applied, otherwise read as missing (a deletion).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local view_state = require("loomworks.view_state")
local FileTracker = require("loomworks.file_tracker")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local USER = "/.nvim/loomworks.user.json"

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function write(path, s)
    local f = assert(io.open(path, "wb")); f:write(s); f:close()
end

--- The working copy re-signed after `fn(user)`; its signed text.
local function signed_user(root, fn)
    local status, body = trust.verify("user", read(root .. USER))
    assert.equals("valid", status)
    local user = vim.json.decode(body)
    fn(user)
    local signed, serr = trust.sign("user", trust.encode(user))
    if not signed then error(serr) end
    return signed
end

--- A `snapshot` request over a fresh CLI connection (loads the workspace).
local function snapshot(srv)
    local conn = assert(client.session(srv.address, {}))
    local reply
    conn:request({ kind = "snapshot", scope = "all", env = envscope.capture() },
        function(r, e) reply = r or { error = e } end)
    vim.wait(60000, function() return reply ~= nil end, 10)
    pcall(conn.close, conn)
    return reply
end

--- The profile `key` of `ws`, or nil.
local function profile(w, key)
    for _, p in ipairs(w:get_profiles() or {}) do
        if p.key == key and not p._removed then return p end
    end
end

--- The configuration set `name` of `ws`, or nil.
local function config_set(w, name)
    for _, cs in pairs(w:get_config_sets() or {}) do
        if cs.name == name and not cs._removed then return cs end
    end
end

--- The view's load diagnostics whose message contains `needle`.
local function load_diags(ws, needle)
    local out = {}
    for _, d in ipairs(view_state.workspace(ws).diagnostics) do
        if d.source == "load" and d.message:find(needle, 1, true) then out[#out + 1] = d end
    end
    return out
end

describe("the workspace daemon watches its files (§19.13 Freshness of views)", function()
    local root, srv, svc, ws
    local grace
    before_each(function()
        grace = FileTracker.SAVE_GRACE_MS
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        svc = service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        assert.equals("ok", snapshot(srv).outcome)
        ws = svc.ws
        assert.is_not_nil(ws)
        assert.is_not_nil(profile(ws, "dev"))
    end)
    after_each(function()
        FileTracker.SAVE_GRACE_MS = grace
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("applies another process's working-copy edit with no request, and signals the views", function()
        local views = require("loomworks.daemon.views")
        local check, checks = views.check, 0
        views.check = function(...) checks = checks + 1; return check(...) end
        local ok, err = pcall(function()
            write(root .. USER, signed_user(root, function(u)
                u.configuration_sets = { extra = { app = "Debug" } }
            end))
            -- No request and no explicit sync: the watcher alone applies it.
            local seen = vim.wait(15000, function() return config_set(ws, "extra") ~= nil end, 25)
            assert.is_true(seen, "the external edit was not applied without a request")
            assert.equals(ws, svc.ws)
            assert.is_true(checks > 0, "the views were not checked after the change")
        end)
        views.check = check
        if not ok then error(err, 0) end
    end)

    it("a half-written working copy keeps the model and raises a load warning; the next change retries", function()
        local full = signed_user(root, function(u) u.configuration_sets = { extra = { app = "Debug" } } end)
        write(root .. USER, full:sub(1, math.floor(#full / 2)))
        ws._tracker:sync() -- (as before an operation)
        assert.equals(ws, svc.host.current(), "the model was unloaded")
        assert.equals(ws, svc.ws)
        assert.is_not_nil(profile(ws, "dev"))
        local d = load_diags(ws, "loomworks.user.json")
        assert.equals(1, #d, vim.inspect(view_state.workspace(ws).diagnostics))
        assert.equals("warn", d[1].severity)
        -- Once, however often it is seen.
        ws._tracker:sync()
        assert.equals(1, #load_diags(ws, "loomworks.user.json"))
        -- The save completes: applied, the warning goes.
        write(root .. USER, full)
        ws._tracker:sync()
        assert.equals(ws, svc.host.current())
        assert.is_not_nil(config_set(ws, "extra"))
        assert.equals(0, #load_diags(ws, "loomworks.user.json"))
    end)

    it("a well-formed working copy that fails its signature is still refused (§17.4)", function()
        local text = signed_user(root, function(u) u.configuration_sets = { extra = { app = "Debug" } } end)
        write(root .. USER, text:gsub('"_sig": "%x+"', '"_sig": "' .. string.rep("0", 64) .. '"', 1))
        ws._tracker:sync()
        assert.are_not.equals(ws, svc.host.current())
    end)

    it("a working copy missing while its .bak holds the content last applied is a save cut short, never defaults", function()
        FileTracker.SAVE_GRACE_MS = 200
        local path = root .. USER
        local next_text = signed_user(root, function(u) u.configuration_sets = { extra = { app = "Debug" } } end)
        assert(os.rename(path, path .. ".bak"))
        local t0 = vim.uv.now()
        ws._tracker:sync()
        assert.equals(ws, svc.host.current())
        assert.is_not_nil(profile(ws, "dev"), "the working copy was read as defaults")
        -- Still missing past the grace with the .bak holding the content last
        -- applied (a save cut short): still not defaults, and nothing written
        -- in its place.
        vim.wait(5000, function() return vim.uv.now() - t0 > 400 end, 20)
        ws._tracker:sync()
        assert.equals(ws, svc.host.current())
        assert.is_not_nil(profile(ws, "dev"), "the working copy was read as defaults after the grace")
        assert.is_nil(read(path))
        -- The save completes: its content is applied.
        write(path, next_text)
        ws._tracker:sync()
        assert.is_not_nil(config_set(ws, "extra"))
    end)

    it("a working copy deleted after a save reads as missing, never as the .bak's older content", function()
        FileTracker.SAVE_GRACE_MS = 200
        local io_mod = require("loomworks.io")
        local path = root .. USER
        -- Two saves by another process: the .bak keeps the content before the
        -- last one (the "old" set), which the model no longer holds.
        assert(io_mod.write_file_atomic(path,
            signed_user(root, function(u) u.configuration_sets = { old = { app = "Debug" } } end)))
        ws._tracker:sync()
        assert.is_not_nil(config_set(ws, "old"))
        assert(io_mod.write_file_atomic(path,
            signed_user(root, function(u) u.configuration_sets = { extra = { app = "Debug" } } end)))
        ws._tracker:sync()
        assert.is_nil(config_set(ws, "old"))
        assert.is_not_nil(read(path .. ".bak"))
        -- The user deletes the working copy.
        assert(os.remove(path))
        -- Once the grace has passed (however loaded the machine) the deletion
        -- is applied: the model changes, to defaults.
        local function cur() return svc.host.current() or svc.ws end
        vim.wait(15000, function()
            ws._tracker:sync()
            return config_set(cur(), "extra") == nil
        end, 50)
        assert.is_nil(config_set(cur(), "old"), "the deleted working copy was read as the .bak")
        assert.is_nil(config_set(cur(), "extra"), "the deleted working copy was not read as missing")
    end)
end)

--- The workspace daemon watches loomworks.json and the working copy
--- (spec/core/daemon.md §19.13 "Freshness of views", §19.15 "Live
--- workspace"): another process's change is applied when it is seen, with no
--- request; a file that cannot be parsed never unloads or replaces the model
--- (a load warning names it); a file missing while its staged copy exists
--- (`<file>.tmp`, or a transaction's `<file>.txn-<id>`, §19.4) is a save in
--- progress and keeps the model; with no staged copy it is missing.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local view_state = require("loomworks.view_state")
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
    before_each(function()
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

    it("a working copy deleted right after a save that rewrote identical bytes reads as missing (its .bak is no save)", function()
        local io_mod = require("loomworks.io")
        local path = root .. USER
        -- Another save of the same bytes: the .bak now equals the content last applied.
        assert(io_mod.write_file_atomic(path, read(path)))
        ws._tracker:sync()
        assert.equals(read(path), read(path .. ".bak"))
        assert.is_not_nil(profile(ws, "dev"))
        -- The user deletes the working copy: applied at once, as missing.
        assert(os.remove(path))
        ws._tracker:sync()
        local cur = svc.host.current() or svc.ws
        assert.is_nil(profile(cur, "dev"), "the deleted working copy was kept as its .bak")
    end)

    for _, case in ipairs({
        { "<file>.tmp", function(path) return path .. ".tmp" end },
        { "a transaction's <file>.txn-<id>", function(path) return require("loomworks.txn").staged_path(path, "0123abcd") end },
    }) do
        it("a working copy missing while its staged copy (" .. case[1] .. ") exists is a save in progress: kept, then applied", function()
            local path = root .. USER
            local staged = case[2](path)
            local next_text = signed_user(root, function(u) u.configuration_sets = { extra = { app = "Debug" } } end)
            -- Between the save's two renames: staged written, target moved to .bak.
            write(staged, next_text)
            assert(os.rename(path, path .. ".bak"))
            ws._tracker:sync()
            assert.equals(ws, svc.host.current())
            assert.is_not_nil(profile(ws, "dev"), "the working copy was read as defaults")
            ws._tracker:sync()
            assert.equals(ws, svc.host.current())
            assert.is_not_nil(profile(ws, "dev"), "the working copy was read as defaults on the re-check")
            assert.is_nil(read(path), "something was written in its place")
            -- The staged copy is renamed into place: its content is applied.
            assert(os.rename(staged, path))
            ws._tracker:sync()
            assert.is_not_nil(config_set(ws, "extra"))
        end)
    end

    it("a working copy deleted with no staged copy reads as missing", function()
        local path = root .. USER
        assert(os.remove(path))
        ws._tracker:sync()
        local cur = svc.host.current() or svc.ws
        assert.is_nil(profile(cur, "dev"), "the deleted working copy was not read as missing")
    end)
end)

-- loomworks.Sdks/1 and loomworks.Toolchains/1.rescan in the daemon (API.md
-- §11, §21; spec daemon.md §19.14 "As interfaces"; step 5o part B4): detect,
-- add (followed by a toolchain rescan), remove, and rescan, called over
-- transport 11 against an in-process server with the build service attached
-- and a real `shell` workspace. References resolve to the live objects at the
-- boundary (an id, or a key); the write goes through loomworks.model_commands.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

--- The decoded working copy (its signature stripped).
local function working_copy(root)
    local _, content = trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))
    return vim.json.decode(content)
end

describe("loomworks.Sdks/1 and Toolchains/1.rescan (step 5o part B4)", function()
    local root, srv, conn, shell_saved, wait_saved
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        -- A fake SDK provider offering the shell module a capability, and
        -- the shell module one keyed kit per SDK (as profile_sdk_choice_spec).
        package.loaded["loomworks.sdks.fake_b4"] = nil
        package.preload["loomworks.sdks.fake_b4"] = function()
            local SDK = require("loomworks.sdk")
            local P = { id = "fake_b4", api_version = require("loomworks.api_versions").sdk,
                display_name = "Fake B4" }
            function P.validate(path) return not path:find("not-an-sdk", 1, true) and { version = "1" } or nil end
            function P.create_sdk(key, path, version)
                return SDK.new({ key = key, type = "fake_b4", version = version, path = path,
                    resolved = true, provider = P })
            end
            function P.query_capabilities(_, mod) return mod == "shell" and {} or nil end
            function P.detect_all() return { { path = "/opt/fake-b4", version = "1" } } end
            function P.match_version() return true end
            return P
        end
        local shell = require("loomworks.modules").get("shell")
        shell_saved = {}
        for _, k in ipairs({ "kits_from_sdk", "tool_key", "tool_label", "tools_match" }) do
            shell_saved[k] = shell[k] or false
        end
        function shell.kits_from_sdk(_, sdk)
            return { { tool_data = { id = "fake-kit", sdk_key = sdk.key } } }
        end
        function shell.tool_key(td) return td and td.id or nil end
        function shell.tool_label(td) return td and td.id or nil end
        function shell.tools_match(a, b) return (a and a.id) == (b and b.id) end
        wait_saved = service.LOAD_WAIT_MS

        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        conn = assert(client.session(srv.address, {}))
    end)
    after_each(function()
        service.LOAD_WAIT_MS = wait_saved
        L.cleanup()
        if conn then pcall(conn.close, conn) end
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        local shell = require("loomworks.modules").get("shell")
        for k, v in pairs(shell_saved or {}) do shell[k] = v ~= false and v or nil end
        trust._set_key_path(nil)
    end)

    local function call_on(iface, method, args)
        local r, e
        conn:call("/toolchains", iface, 1, method, args or {}, function(res, err) r, e = res, err end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return r ~= nil or e ~= nil end, 10), method .. " never answered")
        return r, e
    end
    local function sdks(method, args) return call_on("loomworks.Sdks", method, args) end
    local function toolchains(method, args) return call_on("loomworks.Toolchains", method, args) end

    --- Load the model (a snapshot) and give the live workspace, its
    --- toolchain detection settled.
    local function loaded()
        local done
        conn:call("/internal", "lw.internal.Snapshot", 1, "get", { scope = "config" }, function() done = true end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return done end, 10))
        local ws = assert(srv.service.ws)
        assert.is_true(vim.wait(60000, function() return ws._tool_state == "scanned" end, 10))
        return ws
    end
    local function id_of(obj) return srv.service.ids:id(obj) end
    local function shell_kits(ws)
        local n = 0
        for _, t in ipairs((ws._tools_by_type or {}).shell or {}) do
            if t.tool_key == "fake-kit" then n = n + 1 end
        end
        return n
    end

    it("detect names the provider and the installations it finds (path and version)", function()
        loaded()
        local r, e = sdks("detect", { provider = "fake_b4" })
        assert.is_nil(e, vim.inspect(e))
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ { id = "fake_b4", label = "Fake B4", found = { { path = "/opt/fake-b4", version = "1" } } } },
            r.providers)
    end)

    it("add declares the SDK and detects again (its kit offered); remove by id drops the declaration", function()
        local ws = loaded()
        assert.equals(0, shell_kits(ws))
        local seq = srv.seq
        local r, e = sdks("add", { provider = "fake_b4", path = root })
        assert.is_nil(e, vim.inspect(e))
        assert.equals("ok", r.outcome, vim.inspect(r))
        local sdk = ws._sdks[#ws._sdks]
        assert.same({ id = id_of(sdk), key = "fake_b4-1" }, r.sdk)
        assert.equals("fake_b4", working_copy(root).sdks["fake_b4-1"].type)
        assert.equals(1, shell_kits(ws), "the rescan took the SDK's kit in before the reply")
        assert.equals(seq + 1, srv.seq, "one changed for the add and its rescan")

        r = sdks("remove", { sdk = { id = id_of(sdk) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_true(sdk._removed)
        assert.is_nil((working_copy(root).sdks or {})["fake_b4-1"])

        r = sdks("remove", { sdk = { id = id_of(sdk) } })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("stale reference", 1, true), r.message)
    end)

    it("add refuses an invalid path and an SDK already declared; remove by key", function()
        loaded()
        local r = sdks("add", { provider = "fake_b4", path = root .. "/not-an-sdk" })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("is not a valid fake_b4 installation", 1, true), r.message)
        assert.equals("ok", sdks("add", { provider = "fake_b4", path = root }).outcome)
        r = sdks("add", { provider = "fake_b4", path = root })
        assert.equals("refused", r.outcome)
        assert.equals("SDK 'fake_b4-1' already added", r.message)
        assert.equals("ok", sdks("remove", { sdk = { key = "fake_b4-1" } }).outcome)
        r = sdks("remove", { sdk = { key = "fake_b4-1" } })
        assert.equals("no SDK 'fake_b4-1'", r.message)
    end)

    it("add refuses a relative path, nothing declared", function()
        local ws = loaded()
        local n = #(ws._sdks or {})
        local r = sdks("add", { provider = "fake_b4", path = "relative/sdk" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("SDK path 'relative/sdk' is not absolute", r.message)
        assert.equals(n, #(ws._sdks or {}))
        assert.is_nil((working_copy(root).sdks or {})["fake_b4-1"])
    end)

    it("rescan detects every type afresh; changed only when the toolchains changed", function()
        local ws = loaded()
        local deps = ws._core._deps
        local calls, result = {}, { shell = {} }
        deps.detect_tools_async = function(_, _, cb, opts)
            calls[#calls + 1] = opts
            cb(vim.deepcopy(result))
        end
        local r = toolchains("rescan")
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals(1, #calls)
        assert.is_true(calls[1].force)
        local seq = srv.seq
        assert.equals("ok", toolchains("rescan").outcome)
        assert.equals(seq, srv.seq, "the same toolchains: no changed")
        result = { shell = { { tool_key = "k", tool_label = "k", tool_data = { id = "k" } } } }
        assert.equals("ok", toolchains("rescan").outcome)
        assert.is_true(srv.seq > seq, "new toolchains: changed before the reply")
    end)

    it("remove detects again: a profile of the SDK's kit no longer resolves to the removed SDK", function()
        local ws = loaded()
        assert.equals("ok", sdks("add", { provider = "fake_b4", path = root }).outcome)
        local sdk = ws._sdks[#ws._sdks]
        local function kit_profile()
            for _, p in ipairs(ws._profiles) do
                if not p._removed and vim.tbl_contains(p._tool_keys or {}, "fake-kit") then return p end
            end
        end
        local mc = require("loomworks.model_commands")
        local r = mc.profile_add_tool(assert(ws._profiles[1], "the workspace has a profile"), "fake-kit")
        assert.equals("ok", r.outcome, r.message)
        local profile = assert(kit_profile(), "a profile of the kit")
        assert.equals(sdk, profile:sdk(), "the profile resolves to the SDK's kit")

        r = sdks("remove", { sdk = { id = id_of(sdk) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals(0, shell_kits(ws), "the removed SDK's kit left the toolchains")
        for _, mod in ipairs(ws._modules) do
            for _, tool in pairs(mod._tools or {}) do
                assert.is_true(tool._removed or tool:sdk() ~= sdk, "a live tool of the removed SDK")
            end
        end
        profile = kit_profile()
        assert.is_true(profile == nil or profile:sdk() ~= sdk, "the profile still resolves to the removed SDK")
    end)

    it("a rescan whose detection does not finish in time replies ok with a warn note; changed when it finishes", function()
        local ws = loaded()
        local finish
        ws._core._deps.detect_tools_async = function(_, _, cb) finish = cb end
        service.LOAD_WAIT_MS = 200
        local seq = srv.seq
        local r = toolchains("rescan")
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ "toolchain detection did not finish in time; it goes on in the background" }, r.notes)
        assert.same({ "warn" }, r.note_roles)
        assert.equals(seq, srv.seq)
        assert.is_function(finish)
        finish({ shell = { { tool_key = "late", tool_label = "late", tool_data = { id = "late" } } } })
        assert.is_true(vim.wait(5000, function() return srv.seq > seq end, 10), "no changed when the late detection finished")
    end)

    it("an add whose rescan does not finish in time is ok with the warn note", function()
        local ws = loaded()
        ws._core._deps.detect_tools_async = function() end
        service.LOAD_WAIT_MS = 200
        local r = sdks("add", { provider = "fake_b4", path = root })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ "SDK 'fake_b4-1' added; toolchain detection did not finish in time; it goes on in the background" },
            r.notes)
    end)

    it("a remove whose rescan does not finish in time is ok with the warn note", function()
        loaded()
        assert.equals("ok", sdks("add", { provider = "fake_b4", path = root }).outcome)
        srv.service.ws._core._deps.detect_tools_async = function() end
        service.LOAD_WAIT_MS = 200
        local r = sdks("remove", { sdk = { key = "fake_b4-1" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ "SDK 'fake_b4-1' removed; toolchain detection did not finish in time; it goes on in the background" },
            r.notes)
        assert.same({ "warn" }, r.note_roles)
    end)

    it("a late detection that changes no toolchain sends no changed", function()
        local ws = loaded()
        local before = vim.deepcopy(ws._tools_by_type)
        local finish
        ws._core._deps.detect_tools_async = function(_, _, cb) finish = cb end
        service.LOAD_WAIT_MS = 200
        local seq = srv.seq
        local r = toolchains("rescan")
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ "warn" }, r.note_roles)
        assert.is_function(finish)
        finish(before)
        assert.is_true(vim.wait(5000, function() return ws._tool_state == "scanned" end, 10))
        assert.is_true(vim.wait(5000, function() return srv.service._late_tools == nil end, 10),
            "the late detection never settled")
        vim.wait(300)
        assert.equals(seq, srv.seq, "the same toolchains: no changed")
    end)

    it("a late detection that finishes after its workspace was torn down sends nothing", function()
        local ws = loaded()
        local finish
        local events = ws._core._deps.events
        ws._core._deps.detect_tools_async = function(_, _, cb) finish = cb end
        service.LOAD_WAIT_MS = 200
        local seq = srv.seq
        assert.equals("ok", toolchains("rescan").outcome)
        assert.is_function(finish)
        ws:teardown()
        assert.is_true(ws._torn_down)
        finish({ shell = { { tool_key = "late", tool_label = "late", tool_data = { id = "late" } } } })
        vim.wait(300)
        -- Even a `tools_detected` from elsewhere does not signal for the torn-down model.
        assert.has_no.errors(function() events.emit("tools_detected") end)
        vim.wait(300)
        assert.equals(seq, srv.seq, "a torn-down workspace's late detection signalled changed")
        assert.is_nil(srv.service._late_tools)
    end)
end)

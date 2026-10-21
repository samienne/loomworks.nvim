-- loomworks.Profiles/1 and loomworks.ConfigSets/1 commands in the daemon
-- (API.md §11, §20; spec daemon.md §19.14 "As interfaces"; step 5o part B2):
-- Profiles set_active, create, tool_choices, add_tool, remove_tool and
-- ConfigSets candidates, add, update, remove, generate_defaults, called over
-- transport 11 against an in-process server with the build service attached
-- and a real `shell` workspace. References resolve to the live objects at the
-- boundary (an id, or a key); the write goes through loomworks.model_commands;
-- a profile's toolchain change and a set rename take the workspace operation
-- lock O.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local op_lock = require("loomworks.op_lock")
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

describe("loomworks.Profiles/1 and ConfigSets/1 commands (step 5o part B2)", function()
    local root, srv, conn
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        conn = assert(client.session(srv.address, {}))
    end)
    after_each(function()
        L.cleanup()
        if conn then pcall(conn.close, conn) end
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    --- A call on `iface` at its object: its result (or error).
    local function call_on(object, iface, method, args)
        local r, e
        conn:call(object, iface, 1, method, args or {}, function(res, err) r, e = res, err end, envscope.capture())
        assert.is_true(vim.wait(60000, function() return r ~= nil or e ~= nil end, 10), method .. " never answered")
        return r, e
    end
    local function profiles(method, args) return call_on("/profiles", "loomworks.Profiles", method, args) end
    local function sets(method, args) return call_on("/projects", "loomworks.ConfigSets", method, args) end

    --- Load the model (a snapshot) and give the live workspace.
    local function loaded()
        local done
        conn:call("/internal", "lw.internal.Snapshot", 1, "get", { scope = "config" }, function() done = true end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return done end, 10))
        return assert(srv.service.ws)
    end

    local function id_of(obj) return srv.service.ids:id(obj) end
    local function find(list, field, value)
        for _, o in pairs(list) do if o[field] == value and not o._removed then return o end end
    end

    it("ConfigSets add → Profiles create (local) → set_active, all by id", function()
        local ws = loaded()
        local r, e = sets("add", { name = "rel", mappings = { app = "Debug" } })
        assert.is_nil(e, vim.inspect(e))
        assert.equals("ok", r.outcome, vim.inspect(r))
        local cs = find(ws._config_sets, "name", "rel")
        assert.same({ id = id_of(cs), key = "rel" }, r.config_set)
        assert.equals("Debug", working_copy(root).configuration_sets.rel.app)

        r = profiles("create", { config_set = { id = r.config_set.id } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        local profile = find(ws._profiles, "key", r.profile.key)
        assert.equals(id_of(profile), r.profile.id)
        assert.is_nil(r.config_set)
        assert.equals("local", profile._intent)
        assert.is_not.equal(profile, ws._active_profile)

        r = profiles("set_active", { profile = { id = id_of(profile) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals(profile, ws._active_profile)
        assert.equals(profile.key, working_copy(root).active_profile)
    end)

    it("create returns an existing profile as it is, its intent kept; activate makes it active", function()
        local ws = loaded()
        local dev = find(ws._profiles, "key", "dev")
        dev._intent = "local+shared"
        local r = profiles("create", { config_set = { key = "dev" }, activate = true })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ id = id_of(dev), key = "dev" }, r.profile)
        assert.equals("local+shared", dev._intent)
        assert.equals(dev, ws._active_profile)
    end)

    it("tool_choices of a set whose modules have no keyed toolchain is empty; a tool not among them is refused",
        function()
            local ws = loaded()
            local r = profiles("tool_choices", { config_set = { key = "dev" } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.same({}, r.tools)
            local count = #ws._profiles
            r = profiles("create", { config_set = { key = "dev" }, tool = { module = "cmake", key = "gcc" } })
            assert.equals("refused", r.outcome, vim.inspect(r))
            assert.matches("no cmake toolchain 'gcc'", r.message, 1, true)
            assert.equals(count, #ws._profiles)
        end)

    it("tool_choices and create refuse at once while toolchains are being detected; nothing is created", function()
        local ws = loaded()
        local count = #ws._profiles
        ws._tool_state = "scanning"
        local ok, err = pcall(function()
            for _, method in ipairs({ "tool_choices", "create" }) do
                local t0 = vim.uv.hrtime()
                local r = profiles(method, { config_set = { key = "dev" } })
                local ms = (vim.uv.hrtime() - t0) / 1e6
                assert.equals("refused", r.outcome, vim.inspect(r))
                assert.equals("toolchains are still being detected", r.message)
                assert.equals(1, r.exit_code)
                assert.is_true(ms < 5000, method .. " waited " .. ms .. " ms")
            end
        end)
        ws._tool_state = "scanned"
        assert(ok, err)
        assert.equals(count, #ws._profiles)
    end)

    it("candidates lists the declared sets by id and the automatic ones by token; create takes a token", function()
        local ws = loaded()
        ws.generate_default_config_sets = function() return { Auto = { app = "Debug" } } end
        local r = sets("candidates")
        assert.equals("ok", r.outcome, vim.inspect(r))
        local dev, auto
        for _, s in ipairs(r.sets) do
            if s.name == "dev" then dev = s elseif s.name == "Auto" then auto = s end
        end
        assert.equals(id_of(find(ws._config_sets, "name", "dev")), dev.config_set)
        assert.is_false(dev.auto)
        assert.is_true(auto.auto)
        assert.is_nil(auto.config_set)
        assert.is_string(auto.candidate)

        r = profiles("tool_choices", { config_set = { candidate = auto.candidate } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        r = profiles("create", { config_set = { candidate = auto.candidate } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_not_nil(find(ws._config_sets, "name", "Auto"))
        assert.equals("local", find(ws._profiles, "key", r.profile.key)._intent)
        -- The set exists now: the token stands for nothing any more.
        r = profiles("create", { config_set = { candidate = auto.candidate } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.matches("changed since it was listed", r.message, 1, true)
    end)

    it("create whose profile save fails after a candidate set was added returns the set, with a warn", function()
        local ws = loaded()
        ws.generate_default_config_sets = function() return { Auto = { app = "Debug" } } end
        local auto
        for _, s in ipairs(sets("candidates").sets) do if s.name == "Auto" then auto = s end end
        local real_add = ws.add_configuration_set
        ws.add_configuration_set = function(...)
            local cs, err = real_add(...)
            ws._no_write = "read-only working copy"
            return cs, err
        end
        local r = profiles("create", { config_set = { candidate = auto.candidate } })
        ws._no_write, ws.add_configuration_set = nil, real_add
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_nil(r.profile)
        assert.is_truthy(r.notes and #r.notes > 0, vim.inspect(r))
        local cs = find(ws._config_sets, "name", "Auto")
        assert.same({ id = id_of(cs), key = "Auto" }, r.config_set)
    end)

    --- Declare a resolved SDK `fake_tc-1` (a fake provider, registered in
    --- this Lua state) that offers the `shell` module capabilities, in the
    --- signed working copy, before the model loads.
    local function with_fake_sdk()
        package.preload["loomworks.sdks.fake_tc"] = function()
            local SDK = require("loomworks.sdk")
            local P = { id = "fake_tc", api_version = require("loomworks.api_versions").sdk,
                display_name = "Fake TC" }
            function P.validate() return { version = "1" } end
            function P.create_sdk(key, path, version)
                return SDK.new({ key = key, type = "fake_tc", version = version, path = path,
                    resolved = true, provider = P })
            end
            function P.query_capabilities(_, mod) return mod == "shell" and {} or nil end
            function P.detect_all() return {} end
            function P.match_version() return true end
            return P
        end
        local _, content = trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))
        local user = vim.json.decode(content)
        user.sdks = { ["fake_tc-1"] = { type = "fake_tc", path = root } }
        local signed = trust.sign("user", trust.encode(user))
        local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
        f:write(signed); f:close()
    end

    it("tool_choices offers a relevant SDK as { sdk = true, key, label }; create takes { sdk = key }", function()
        with_fake_sdk()
        local ws = loaded()
        local sdk = find(ws._sdks, "key", "fake_tc-1")
        assert.is_not_nil(sdk)
        local r = profiles("tool_choices", { config_set = { key = "dev" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ { sdk = true, key = "fake_tc-1", label = sdk:display_name() } }, r.tools)

        -- A set with no profile yet: an SDK-only profile has no tool keys, so
        -- its key is the bare set name (spec §1.6), as dev's toolless one is.
        assert.equals("ok", sets("add", { name = "rel", mappings = { app = "Debug" } }).outcome)
        r = profiles("create", { config_set = { key = "rel" }, tool = { sdk = "fake_tc-1" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        local profile = srv.service.ids:find(r.profile.id, ws._profiles)
        assert.is_not_nil(profile, vim.inspect(r))
        assert.equals(profile.key, r.profile.key)
        assert.equals(sdk, profile._sdk)
        -- Saved to the working copy (as the editor's pick is: a profile entry
        -- carries no `sdk` field, spec §1.6).
        assert.is_not_nil(working_copy(root).profiles[r.profile.key])

        -- Created again: the existing profile, not a duplicate.
        local count = #ws._profiles
        local again = profiles("create", { config_set = { key = "rel" }, tool = { sdk = "fake_tc-1" } })
        assert.equals("ok", again.outcome, vim.inspect(again))
        assert.same(r.profile, again.profile)
        assert.equals(count, #ws._profiles)
    end)

    it("create of an SDK toolchain not among tool_choices' is refused and creates nothing", function()
        with_fake_sdk()
        local ws = loaded()
        local count = #ws._profiles
        -- Not a prefix match either (an exact key, API.md §1.2).
        for _, key in ipairs({ "nope", "fake_tc" }) do
            local r = profiles("create", { config_set = { key = "dev" }, tool = { sdk = key } })
            assert.equals("refused", r.outcome, vim.inspect(r))
            assert.equals("no SDK toolchain '" .. key .. "' for this configuration set (see Profiles/1.tool_choices)",
                r.message)
        end
        assert.equals(count, #ws._profiles)
    end)

    it("add_tool / remove_tool re-derive the key under O, the id kept; refused while O is held", function()
        local ws = loaded()
        ws:get_or_create_tool("shell", "gcc-x", {}, "GCC x")
        local dev = find(ws._profiles, "key", "dev")
        local id = id_of(dev)
        -- A toolchain that does not resolve is refused (API.md §4.1).
        local r = profiles("add_tool", { profile = { id = id }, tool = "typo" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("dev", dev.key)
        r = profiles("add_tool", { profile = { id = id }, tool = "gcc-x" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.are_not.equal("dev", dev.key)
        assert.equals(id, id_of(dev))
        assert.is_nil(op_lock.read(root), "O left behind")

        local before = read(root .. "/.nvim/loomworks.user.json")
        local key = dev.key
        local h = L.hold(op_lock.path(root), "import")
        r = profiles("remove_tool", { profile = { id = id }, tool = "gcc-x" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.matches("pid " .. h.pid, r.message, 1, true)
        assert.equals(key, dev.key)
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
        L.cleanup()

        r = profiles("remove_tool", { profile = { id = id }, tool = "gcc-x" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("dev", dev.key)
    end)

    it("update renames a set under O (its profiles follow), remove keeps its profiles", function()
        local ws = loaded()
        local cs = find(ws._config_sets, "name", "dev")
        local id = id_of(cs)
        local r = sets("update", { config_set = { id = id }, name = "main", mappings = { app = "Debug" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("main", cs.name)
        assert.equals(id, id_of(cs))
        assert.is_not_nil(find(ws._profiles, "_configuration_set_name", "main"))
        assert.is_nil(op_lock.read(root), "O left behind")

        local before = read(root .. "/.nvim/loomworks.user.json")
        local h = L.hold(op_lock.path(root), "import")
        r = sets("update", { config_set = { id = id }, name = "other", mappings = { app = "Debug" } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.matches("pid " .. h.pid, r.message, 1, true)
        assert.equals("main", cs.name)
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
        L.cleanup()

        r = sets("remove", { config_set = { key = "main" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_true(cs._removed == true)
        assert.is_not_nil(find(ws._profiles, "_configuration_set_name", "main"))
    end)

    it("generate_defaults adds the automatic sets and names them in the notes", function()
        local ws = loaded()
        ws.generate_default_config_sets = function() return { Auto = { app = "Debug" } } end
        local r = sets("generate_defaults")
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_not_nil(find(ws._config_sets, "name", "Auto"))
        assert.is_truthy(table.concat(r.notes or {}, "\n"):find("added configuration set 'Auto'", 1, true),
            vim.inspect(r))
    end)

    it("a stale id, an unknown key and an unknown mapping are refused and change nothing", function()
        loaded()
        local before = read(root .. "/.nvim/loomworks.user.json")
        local r = profiles("set_active", { profile = { id = "999.999" } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no profile with id 999.999 (a stale reference)", r.message)
        r = profiles("add_tool", { profile = { key = "nope" }, tool = "x" })
        assert.equals("no profile 'nope'", r.message)
        r = profiles("create", { config_set = { id = "999.999" } })
        assert.equals("no configuration set with id 999.999 (a stale reference)", r.message)
        r = sets("remove", { config_set = { key = "nope" } })
        assert.equals("no configuration set 'nope'", r.message)
        r = sets("add", { name = "x", mappings = { ghost = "Debug" } })
        assert.equals("no project 'ghost'", r.message)
        r = sets("add", { name = "x", mappings = { app = "Nope" } })
        assert.equals("no configuration 'Nope' in project 'app'", r.message)
        local _, e = profiles("add_tool", { profile = { key = "dev" } })
        assert.equals("invalid_args", e and e.code, vim.inspect(e))
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    end)
end)

-- The status page's tool picker: a profile made of an SDK's entry
-- (Workspace:get_tool_entries → workspace_view.execute_create_profile) stores
-- the SDK's kit toolchains as its tool keys (spec §1.6: tool keys carry the
-- SDK; a profile has no separate `sdk` field), so it keeps its SDK across a
-- reload and its key never clashes with the set's toolless profile.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function find(list, field, value)
    for _, o in pairs(list) do if o[field] == value and not o._removed then return o end end
end

describe("tool picker: a profile made of an SDK", function()
    local root, shell_saved

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })

        -- A fake SDK provider offering the shell module capabilities, and
        -- the shell module given one keyed kit per SDK (tool data carrying
        -- `sdk_key`, as cmake's kits do).
        package.preload["loomworks.sdks.fake_tc"] = function()
            local SDK = require("loomworks.sdk")
            local P = { id = "fake_tc", api_version = require("loomworks.api_versions").sdk,
                display_name = "Fake TC" }
            function P.validate() return { version = "1" } end
            function P.create_sdk(key, path, version)
                return SDK.new({ key = key, type = "fake_tc", version = version, path = path,
                    resolved = true, provider = P })
            end
            function P.query_capabilities(_, mod)
                return (mod == "shell" or mod == "meson") and {} or nil
            end
            function P.detect_all() return {} end
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

        local _, content = trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))
        local user = vim.json.decode(content)
        user.sdks = { ["fake_tc-1"] = { type = "fake_tc", path = root } }
        local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
        f:write(trust.sign("user", trust.encode(user))); f:close()
    end)

    after_each(function()
        local shell = require("loomworks.modules").get("shell")
        for k, v in pairs(shell_saved or {}) do shell[k] = v ~= false and v or nil end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    local function load()
        pcall(function() require("loomworks")._core():shutdown() end)
        return assert(cli._load_workspace(root, true))
    end

    it("keeps its SDK toolchain across a reload, distinct from the set's toolless profile", function()
        local ws = load()
        local sdk = find(ws._sdks, "key", "fake_tc-1")
        assert.is_not_nil(sdk)
        local entry
        for _, e in ipairs(ws:get_tool_entries().dev or {}) do
            if e.sdk == sdk then entry = e end
        end
        assert.is_not_nil(entry, "the picker offers the SDK")
        local cs = find(ws._config_sets, "name", "dev")
        local profile, err = require("loomworks.workspace_view").execute_create_profile(cs, entry, false)
        assert.is_not_nil(profile, err)
        assert.are_not.equal("dev", profile.key)
        assert.same({ "fake-kit" }, profile._tool_keys)
        local key = profile.key

        ws = load()
        sdk = find(ws._sdks, "key", "fake_tc-1")
        profile = find(ws._profiles, "key", key)
        assert.is_not_nil(profile, "profile " .. key .. " lost on reload")
        assert.same({ "fake-kit" }, profile._tool_keys)
        assert.equals(sdk, profile:sdk())
        assert.is_not_nil(find(ws._profiles, "key", "dev"))

        -- The picker's entry finds that profile again (not a new one).
        for _, e in ipairs(ws:get_tool_entries().dev or {}) do
            if e.sdk == sdk then entry = e end
        end
        cs = find(ws._config_sets, "name", "dev")
        local count = #ws._profiles
        assert.equals(profile, require("loomworks.workspace_view").execute_create_profile(cs, entry, false))
        assert.equals(count, #ws._profiles)
    end)

    --- A profile made of the SDK's picker entry.
    local function sdk_profile(ws)
        local sdk = find(ws._sdks, "key", "fake_tc-1")
        local entry
        for _, e in ipairs(ws:get_tool_entries().dev or {}) do
            if e.sdk == sdk then entry = e end
        end
        local cs = find(ws._config_sets, "name", "dev")
        return assert(require("loomworks.workspace_view").execute_create_profile(cs, entry, false))
    end

    it("derives its SDK in a single refresh of a workspace with no modules yet", function()
        local ws = load()
        local key = sdk_profile(ws).key
        -- A fresh workspace's refresh: detection (with its SDK kits) is in
        -- hand, but no Module has been assigned yet (`_modules` is set only
        -- after the refresh, which builds the modules itself).
        ws._modules = {}
        ws:remerge()
        local profile = find(ws._profiles, "key", key)
        assert.is_not_nil(profile)
        assert.equals(find(ws._sdks, "key", "fake_tc-1"), profile:sdk())
    end)

    it("keeps one SDK object across a remerge without a rescan", function()
        local ws = load()
        local key = sdk_profile(ws).key
        ws:remerge()
        local sdk = find(ws._sdks, "key", "fake_tc-1")
        local kit
        for _, mod in pairs(ws._modules) do kit = kit or mod:find_tool("fake-kit") end
        assert.equals(sdk, kit:sdk(), "the kit's SDK is the workspace's live one")
        assert.equals(sdk, find(ws._profiles, "key", key):sdk())
    end)

    it("a profile mixing host and kit toolchains has no SDK and no SDK fallback", function()
        local meson = require("loomworks.modules").get("meson")
        local saved = meson.kits_from_sdk
        meson.kits_from_sdk = function(_, sdk)
            return { { tool_data = { id = "fake-meson-kit", sdk_key = sdk.key } } }
        end
        local ok, err = pcall(function()
            local ws = load()
            table.insert(ws._tools_by_type.shell, {
                tool_key = "host-cc", tool_data = { id = "host-cc" }, tool_label = "host-cc" })
            ws:remerge()
            local profile = sdk_profile(ws)
            profile:add_tool("host-cc")
            assert.same({ "fake-kit", "host-cc" }, profile._tool_keys)
            assert.is_nil(profile:sdk())
            assert.is_nil(profile:tool_for("meson"), "no unrequested SDK kit")
            local key = profile.key
            ws:remerge()
            profile = find(ws._profiles, "key", key)
            assert.is_not_nil(profile)
            assert.is_nil(profile:sdk())
            assert.is_nil(profile:tool_for("meson"), "no unrequested SDK kit after a refresh")
        end)
        meson.kits_from_sdk = saved
        assert(ok, err)
    end)

    it("never resolves kits against a replaced SDK's old path before a rescan", function()
        local meson = require("loomworks.modules").get("meson")
        local saved = meson.kits_from_sdk
        local paths = {}
        meson.kits_from_sdk = function(_, sdk)
            paths[#paths + 1] = sdk._path
            return { { tool_data = { id = "fake-meson-kit", sdk_key = sdk.key } } }
        end
        local ok, err = pcall(function()
            local ws = load()
            local key = sdk_profile(ws).key
            local old = find(ws._sdks, "key", "fake_tc-1")
            local old_path = old._path
            -- The user points the SDK at another installation (a user.json
            -- change: a remerge, no tool detection).
            local user = ws:_serialize_user()
            user.sdks["fake_tc-1"].path = root .. "/.nvim"
            ws:remerge(nil, nil, user)
            assert.is_true(old._removed == true, "the replaced SDK is marked removed")
            local profile = find(ws._profiles, "key", key)
            assert.is_not_nil(profile)
            local sdk = profile:sdk()
            assert.is_true(sdk == nil or not sdk._removed, "the profile holds no removed SDK")
            paths = {}
            profile:tool_for("meson")
            for _, p in ipairs(paths) do
                assert.are_not.equal(old_path, p, "kits resolved against the old path")
            end
            -- A mutation re-derives the SDK the same way.
            profile:add_tool("fake-kit2")
            profile:remove_tool("fake-kit2")
            sdk = profile:sdk()
            assert.is_true(sdk == nil or not sdk._removed, "no removed SDK after add/remove_tool")
        end)
        meson.kits_from_sdk = saved
        assert(ok, err)
    end)

    describe("a profile with a persisted sdk whose tools are not detected", function()
        --- The working copy gains a profile with `sdk` and tool keys no
        --- detection produced (a user.json change: a remerge with it).
        local function load_with_profile(tools)
            local ws = load()
            local user = ws:_serialize_user()
            user.profiles["dev:" .. table.concat(tools, "+")] =
                { configuration_set = "dev", tools = tools, sdk = "fake_tc-1" }
            ws:remerge(nil, nil, user)
            local profile
            for _, p in pairs(ws._profiles) do
                if not p._removed and vim.deep_equal(p._tool_keys, tools) then profile = p end
            end
            assert.is_not_nil(profile, "the persisted profile loads")
            local sdk = find(ws._sdks, "key", "fake_tc-1")
            assert.equals(sdk, profile:sdk(), "the persisted sdk resolves")
            return ws, profile, sdk
        end

        it("add_tool keeps it", function()
            local _, profile, sdk = load_with_profile({ "undetected-kit" })
            profile:add_tool("another-undetected-kit")
            assert.equals(sdk, profile:sdk())
            assert.equals("fake_tc-1", profile._sdk_key)
        end)

        it("remove_tool keeps it while a remaining key is unresolved", function()
            local _, profile, sdk = load_with_profile({ "undetected-kit", "undetected-kit2" })
            profile:remove_tool("undetected-kit2")
            assert.equals(sdk, profile:sdk())
            assert.equals("fake_tc-1", profile._sdk_key)
        end)
    end)
end)

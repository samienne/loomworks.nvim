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
            function P.query_capabilities(_, mod) return mod == "shell" and {} or nil end
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
end)

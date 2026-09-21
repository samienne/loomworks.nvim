--- Tests for the suggestion framework and the compiler-cache provider
--- (headless §16.31), plus the `lw health` command's no-workspace path.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local suggestions = require("loomworks.suggestions")
local cpp = require("loomworks.cpp_compilers")
local h = require("tests.helpers")

local orig_lookup = cpp.lookup_path
local function set_present(present)
    cpp.lookup_path = function(name)
        if present[name] then return "/usr/bin/" .. name end
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Framework
-- ---------------------------------------------------------------------------
describe("suggestion framework", function()
    it("aggregates registered providers", function()
        local orig = suggestions._providers
        suggestions._providers = {}
        suggestions.register(function() return { { title = "a", detail = "d", remedy = "r" } } end)
        suggestions.register(function() return { { title = "b" } } end)
        local out = suggestions.collect({})
        assert.equals(2, #out)
        assert.equals("a", out[1].title)
        suggestions._providers = orig
    end)

    it("skips a provider that errors (advisory, never breaks)", function()
        local orig = suggestions._providers
        suggestions._providers = {}
        suggestions.register(function() error("boom") end)
        suggestions.register(function() return { { title = "ok" } } end)
        local out = suggestions.collect({})
        assert.equals(1, #out)
        assert.equals("ok", out[1].title)
        suggestions._providers = orig
    end)

    it("returns nothing for a nil workspace", function()
        assert.same({}, suggestions.collect(nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- Compiler-cache provider
-- ---------------------------------------------------------------------------
describe("compiler-cache suggestion provider", function()
    after_each(function() cpp.lookup_path = orig_lookup end)

    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local function make_ws(projects, cfg_sets)
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = projects,
                configuration_sets = cfg_sets or {},
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        return core:get_workspace()
    end

    it("fires for a C/C++ project with no cache on PATH", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.matches("compiler cache", out[1].title)
        assert.is_string(out[1].detail)
        assert.is_string(out[1].remedy)
    end)

    it("reports an INFO 'using <tool>' item when a cache IS present", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({ ccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.matches("using ccache", out[1].title)
        assert.is_string(out[1].detail)
        assert.is_nil(out[1].remedy) -- informational, no action to take
    end)

    it("does NOT count the affirmative info item in the actionable count", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({ ccache = true })
        -- The provider yields one passive item, but it is informational…
        assert.equals(1, #suggestions.collect(ws))
        -- …so the compact `N suggestions` count sees zero actionable items.
        assert.equals(0, suggestions.count_actionable(ws))
    end)

    it("DOES count the actionable install suggestion", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({}) -- no cache on PATH → actionable nag
        assert.equals(1, suggestions.count_actionable(ws))
    end)

    it("is silent (no info, no nag) when every C/C++ project pinned cache off, even with a cache present", function()
        local ws = make_ws({
            App = { cmake = { configurations = { Debug = { variables = { cache = "off" } },
                                                 Release = { variables = { cache = "off" } } } } },
        })
        set_present({ ccache = true })
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("is silent for a workspace with no C/C++ project", function()
        local ws = make_ws({ Web = { typescript = {} } })
        set_present({})
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("is silent when every C/C++ project pinned cache off", function()
        local ws = make_ws({
            App = { cmake = { configurations = { Debug = { variables = { cache = "off" } },
                                                 Release = { variables = { cache = "off" } } } } },
        })
        set_present({})
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("recommends the platform-preferred tool", function()
        local tool = suggestions._preferred_install_tool()
        assert.is_true(tool == "sccache" or tool == "ccache")
        local ws = make_ws({ App = { cmake = {} } })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.matches(tool, out[1].remedy)
    end)
end)

-- ---------------------------------------------------------------------------
-- Update-availability provider (health-only, network-backed)
-- ---------------------------------------------------------------------------
-- boot.update pulls in luvi-only builtins (openssl via boot.verify) and cannot
-- load under nvim/busted, but the provider requires it through `pcall(require,
-- …)` — so we inject a fake module via package.loaded. boot.paths (real
-- version_gt) DOES load under nvim, so the version comparison stays authentic.
describe("update-check suggestion provider", function()
    local update -- the injected fake, rebuilt per test
    local saved_luaroot, saved_loaded

    before_each(function()
        saved_luaroot = _G.__loomworks_luaroot
        saved_loaded = package.loaded["boot.update"]
        update = { DEFAULT_CHANNEL = "stable" }
        package.loaded["boot.update"] = update
    end)
    after_each(function()
        _G.__loomworks_luaroot = saved_luaroot
        package.loaded["boot.update"] = saved_loaded
    end)

    it("suggests an update when a newer version is on the channel", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return "0.2.0" end
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.equals("Update available", out[1].title)
        assert.matches("0%.1%.0 .+ 0%.2%.0", out[1].detail)
        assert.matches("stable channel", out[1].detail)
        assert.matches("self%-update", out[1].remedy)
    end)

    it("names the resolved channel in the detail", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "unstable" end
        update.resolve_newest_version = function() return "0.2.0-beta.1" end
        local out = suggestions.update_check_provider({})
        assert.equals(1, #out)
        assert.matches("unstable channel", out[1].detail)
    end)

    it("is silent when already up to date", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.2.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return "0.2.0" end
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("treats a pre-release as older than its release (no downgrade suggestion)", function()
        -- Running the full 0.2.0 on stable; the unstable feed reports 0.2.0-rc.1,
        -- which orders BELOW 0.2.0 — must NOT suggest an "update".
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.2.0"
        update.resolve_channel = function() return "unstable" end
        update.resolve_newest_version = function() return "0.2.0-rc.1" end
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("is silent (graceful) on a network / API failure", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return nil, "fetch releases: offline" end
        assert.same({}, suggestions.update_check_provider({}))
    end)

    it("is silent for a dev/fused source with no comparable version", function()
        _G.__loomworks_luaroot = nil
        local called = false
        update.resolve_newest_version = function() called = true; return "9.9.9" end
        update.resolve_channel = function() return "stable" end
        assert.same({}, suggestions.update_check_provider({}))
        assert.is_false(called) -- never even probes the network without a version
    end)

    it("is silent for an unknown channel", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return nil, "unknown update channel" end
        update.resolve_newest_version = function() return "9.9.9" end
        assert.same({}, suggestions.update_check_provider({}))
    end)
end)

-- ---------------------------------------------------------------------------
-- No-passive-network guarantee: the health-only providers stay out of `collect`
-- ---------------------------------------------------------------------------
describe("passive collect never hits the network", function()
    it("runs health-only providers only via collect_health", function()
        local orig_p, orig_h = suggestions._providers, suggestions._health_providers
        local hits = 0
        suggestions._providers = {}
        suggestions._health_providers = { function()
            hits = hits + 1
            return { { title = "network-backed" } }
        end }

        -- Passive count: MUST NOT invoke the health provider.
        local passive = suggestions.collect({})
        assert.equals(0, hits)
        assert.same({}, passive)

        -- Explicit health: DOES invoke it.
        local health = suggestions.collect_health({})
        assert.equals(1, hits)
        assert.equals(1, #health)
        assert.equals("network-backed", health[1].title)

        suggestions._providers, suggestions._health_providers = orig_p, orig_h
    end)
end)

-- ---------------------------------------------------------------------------
-- Channel-override provider (health-only, network-free)
-- ---------------------------------------------------------------------------
describe("channel-override suggestion provider", function()
    local update -- injected fake (boot.update is luvi-only; see note above)
    local saved_loaded
    before_each(function()
        saved_loaded = package.loaded["boot.update"]
        update = { DEFAULT_CHANNEL = "stable" }
        package.loaded["boot.update"] = update
    end)
    after_each(function()
        package.loaded["boot.update"] = saved_loaded
    end)

    it("flags an override that supersedes a non-default channel", function()
        update.url_override = function() return "https://mirror.example/lw" end
        update.resolve_channel = function() return "unstable" end
        local out = suggestions.channel_override_provider({})
        assert.equals(1, #out)
        assert.matches("overridden", out[1].title)
        assert.matches("mirror.example", out[1].detail)
        assert.matches("unstable", out[1].detail)
    end)

    it("is silent when no override is in effect", function()
        update.url_override = function() return nil end
        update.resolve_channel = function() return "unstable" end
        assert.same({}, suggestions.channel_override_provider({}))
    end)

    it("is silent when the overridden channel is the default (ordinary mirror use)", function()
        update.url_override = function() return "https://mirror.example/lw" end
        update.resolve_channel = function() return update.DEFAULT_CHANNEL end
        assert.same({}, suggestions.channel_override_provider({}))
    end)
end)

-- ---------------------------------------------------------------------------
-- collect_health with NO workspace — the workspace-independent providers (update
-- availability, channel override) must still run; only the workspace-SCOPED ones
-- fall silent. This is the `lw health` in a plain dir regression (§16.31).
-- ---------------------------------------------------------------------------
describe("collect_health without a workspace", function()
    local update
    local saved_luaroot, saved_loaded
    before_each(function()
        saved_luaroot = _G.__loomworks_luaroot
        saved_loaded = package.loaded["boot.update"]
        update = { DEFAULT_CHANNEL = "stable" }
        package.loaded["boot.update"] = update
    end)
    after_each(function()
        _G.__loomworks_luaroot = saved_luaroot
        package.loaded["boot.update"] = saved_loaded
    end)

    it("still reports the update-availability item with a nil workspace", function()
        _G.__loomworks_luaroot = "/data/loomworks/lua-0.1.0"
        update.resolve_channel = function() return "stable" end
        update.resolve_newest_version = function() return "0.2.0" end
        update.url_override = function() return nil end

        local out = suggestions.collect_health(nil)
        local titles = {}
        for _, s in ipairs(out) do titles[s.title] = true end
        assert.is_true(titles["Update available"])
    end)

    it("still reports a channel override with a nil workspace", function()
        _G.__loomworks_luaroot = nil -- no update item; isolate the override
        update.url_override = function() return "https://mirror.example/lw" end
        update.resolve_channel = function() return "unstable" end

        local out = suggestions.collect_health(nil)
        local titles = {}
        for _, s in ipairs(out) do titles[s.title] = true end
        assert.is_true(titles["Update channel overridden by release-url"])
    end)

    it("does not error on the workspace-scoped provider with a nil workspace", function()
        -- The compiler-cache provider is workspace-scoped: it must guard nil and
        -- simply contribute nothing rather than throwing.
        assert.same({}, suggestions.compiler_cache_provider(nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- lw health command (no-workspace path)
-- ---------------------------------------------------------------------------
describe("cli.cmd_health", function()
    local cli = require("loomworks.cli")

    it("exits 0 with the worktree hint when no workspace is present", function()
        assert.equals(0, cli.cmd_health(nil))
    end)
end)
